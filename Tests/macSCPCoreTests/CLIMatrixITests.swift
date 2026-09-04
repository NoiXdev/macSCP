import Foundation
import Testing
@testable import macSCPCore

// The CLI matrix: the built `macscp-cli` binary, driven against every
// backend the Docker rig offers, through `Support/CLIMatrix.swift`.
//
// Gated behind MACSCP_ITEST, like every other suite that needs the rig, and
// started from the MAIN checkout (the seed mounts are relative to the
// compose file). One suite per backend, each `.serialized`: the cases in a
// suite work in the same remote directory and would otherwise see each
// other's files.
//
// What is NOT written out by hand: which backends exist (`CLIMatrix
// .fixture(for:name:)` is exhaustive over `ConnectionKind`, and
// `everyConnectionKindHasAMatrixSuite` below fails the moment a fourth one
// has no suite), which commands exist (`CLIMatrix.subcommands(binary:)`
// reads the binary's own `--help`), and whether a backend can be asked for
// an operation at all (`CLIMatrix.supports(_:named:operation:)` asks the
// backend's `ProtocolCapabilities`).

private let rigIsEnabled = ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"

// MARK: - The shared cases

/// The case bodies, written once and run once per backend. A body takes the
/// `kind` from its suite and asks the rig for everything else, so nothing in
/// here branches on which backend it is running against.
enum CLIMatrixCases {
    /// `ls --json` reports a file that is really there.
    ///
    /// The fixture is seeded through the BACKEND's own `RemoteFileSystem`,
    /// never through `put`, so this case fails only for a reason that is
    /// about `ls`. And it asserts the entry's fields — not merely that the
    /// command exited 0 — because an `ls` that prints nothing at all also
    /// exits 0.
    ///
    /// `--json` means one JSON object per line, not one array
    /// (`GlobalOptions.json`, and `OutputFormatter.print(items:asJSON:)`
    /// which prints them one at a time); `CLIMatrix.listing` decodes every
    /// non-empty line and throws on one it cannot read, rather than dropping
    /// it.
    ///
    /// BOTH kinds, from one listing: a file with a known size and a
    /// directory beside it. `directory` is the field that decides how every
    /// consumer of this output treats an entry, and a listing that reported
    /// everything as a file would still satisfy an assertion made only
    /// against the seeded file. The directory's own `size` is deliberately
    /// not asserted — SFTP reports the inode's size for one and S3's
    /// `CommonPrefixes` has none, so a shared expectation there would say
    /// something about the rig rather than about `ls`.
    static func listsASeededFileAsJSON(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "ls-json") { rig, fileSystem, litter in
            let fileName = "cli-matrix-ls-\(UUID().uuidString).txt"
            let remotePath = rig.remotePath(fileName)
            let payload = Data("cli-matrix listing fixture\n".utf8)
            await litter.file(remotePath)
            try await rig.seed(fileSystem, path: remotePath, content: payload)

            let directoryName = "cli-matrix-lsdir-\(UUID().uuidString)"
            let directoryPath = rig.remotePath(directoryName)
            await litter.tree(directoryPath)
            try await fileSystem.createDirectory(at: directoryPath)

            // `--accept-new` is NOT written into the vector: five of the
            // six subcommands take the connection flags and `sessions` does
            // not, so the flag is asked for per command
            // (`CLIMatrix.hostKeyFlags(for:binary:)`, which reads that
            // command's own help).
            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "ls", binary: binary)
            let result = try await rig.run(
                ["ls"] + flags + ["--json", rig.target(rig.remoteRoot)])
            #expect(result.status == 0, "ls failed on \(kind.rawValue): \(result.stderrText)")

            let listed = try CLIMatrix.listing(result.stdoutText)
            #expect(!listed.isEmpty, "ls --json printed nothing on \(kind.rawValue)")

            let entry = try #require(
                listed.first { $0.name == fileName },
                "ls --json did not report the seeded file on \(kind.rawValue)")
            #expect(entry.directory == false)
            #expect(entry.size == UInt64(payload.count))
            #expect(!entry.path.isEmpty)

            let directoryEntry = try #require(
                listed.first { $0.name == directoryName },
                "ls --json did not report the seeded directory on \(kind.rawValue)")
            #expect(directoryEntry.directory, "ls --json called a directory a file")
            #expect(!directoryEntry.path.isEmpty)
        }
    }

    // MARK: - mkdir

    /// `mkdir` creates something the backend itself calls a directory.
    ///
    /// NOT gated on `directoriesAreReal`. S3 has that axis `false` and
    /// creates the directory anyway — `S3FileSystem.createDirectory` PUTs
    /// the conventional trailing-slash marker key, and `stat` reads it back
    /// as a `CommonPrefixes` directory — so gating here would skip a case
    /// that passes, which is the worst kind of skip: one that reports a
    /// capability as the reason for a coverage hole it did not cause. The
    /// axis describes whether a directory is a first-class server-side
    /// object, not whether `mkdir` works.
    static func mkdirCreatesADirectory(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "mkdir") { rig, fileSystem, litter in
            let name = "cli-matrix-mkdir-\(UUID().uuidString)"
            let remotePath = rig.remotePath(name)
            // Registered BEFORE the command runs: a failure between here and
            // the assertions must still take the directory with it, and
            // removing a path that was never created is not an error on any
            // of the three (`removeRemoteTree` swallows the attempt and only
            // the survival of the entry is recorded).
            await litter.tree(remotePath)

            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "mkdir", binary: binary)
            let result = try await rig.run(["mkdir"] + flags + [rig.target(remotePath)])
            #expect(result.status == 0, "mkdir failed on \(kind.rawValue): \(result.stderrText)")

            let item = try await fileSystem.stat(path: remotePath)
            #expect(item.isDirectory, "mkdir made something that is not a directory")
            #expect(item.name == name)
        }
    }

    // MARK: - put and get

    /// `put` uploads the bytes, under the local file's own name, into the
    /// remote directory it was given.
    ///
    /// The bytes are read back through the BACKEND, not through `get`: a
    /// `put` case that verified itself with `get` would pass on any mistake
    /// the two share.
    static func putUploadsALocalFile(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "put") { rig, fileSystem, litter in
            try await CLIMatrix.withLocalDirectory { localDirectory in
                let name = "cli-matrix-put-\(UUID().uuidString).txt"
                let payload = Data("cli-matrix put fixture\n".utf8)
                let localFile = localDirectory.appendingPathComponent(name)
                try payload.write(to: localFile)

                let remotePath = rig.remotePath(name)
                await litter.file(remotePath)

                let binary = try CLIMatrix.binaryURL()
                let flags = try await CLIMatrix.hostKeyFlags(for: "put", binary: binary)
                let result = try await rig.run(
                    ["put"] + flags
                        + [localFile.path(percentEncoded: false), rig.target(rig.remoteRoot)])
                #expect(result.status == 0, "put failed on \(kind.rawValue): \(result.stderrText)")

                let item = try await fileSystem.stat(path: remotePath)
                #expect(item.isDirectory == false)
                #expect(item.size == UInt64(payload.count))
                let readBack = try await rig.read(fileSystem, path: remotePath)
                #expect(readBack == payload, "put wrote different bytes on \(kind.rawValue)")
            }
        }
    }

    /// `get` downloads a file seeded through the backend into a local
    /// directory, keeping the remote name.
    static func getDownloadsARemoteFile(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "get") { rig, fileSystem, litter in
            try await CLIMatrix.withLocalDirectory { localDirectory in
                let name = "cli-matrix-get-\(UUID().uuidString).txt"
                let payload = Data("cli-matrix get fixture\n".utf8)
                let remotePath = rig.remotePath(name)
                await litter.file(remotePath)
                try await rig.seed(fileSystem, path: remotePath, content: payload)

                let binary = try CLIMatrix.binaryURL()
                let flags = try await CLIMatrix.hostKeyFlags(for: "get", binary: binary)
                let result = try await rig.run(
                    ["get"] + flags
                        + [rig.target(remotePath), localDirectory.path(percentEncoded: false)])
                #expect(result.status == 0, "get failed on \(kind.rawValue): \(result.stderrText)")

                let downloaded = localDirectory.appendingPathComponent(name)
                #expect(
                    FileManager.default.fileExists(atPath: downloaded.path(percentEncoded: false)),
                    "get wrote no file named \(name) on \(kind.rawValue)")
                let bytes = try? Data(contentsOf: downloaded)
                #expect(bytes == payload, "get wrote different bytes on \(kind.rawValue)")
            }
        }
    }

    /// `--on-conflict`, one case per value the CORE enum defines.
    ///
    /// Parameterised over `ConflictAction.allCases` and decided by an
    /// EXHAUSTIVE switch, so a fourth action does not compile until someone
    /// writes what it should do to the remote file — the same structural
    /// boundary the backend axis has. `theConflictActionsAreTheOnesCoreDefines`
    /// below ties that enum to what the binary actually advertises, so the
    /// two cannot drift apart silently either.
    ///
    /// Every arm asserts the REMOTE CONTENT, not just the exit code: `skip`
    /// and `overwrite` both exit 0, and the only thing that tells them apart
    /// is which bytes are on the server afterwards.
    static func putOverAnExistingFile(
        _ kind: ConnectionKind, action: ConflictAction
    ) async throws {
        try await CLIMatrix.withRig(kind, label: "conflict") { rig, fileSystem, litter in
            try await CLIMatrix.withLocalDirectory { localDirectory in
                let name = "cli-matrix-conflict-\(UUID().uuidString).txt"
                let original = Data("cli-matrix original\n".utf8)
                let replacement = Data("cli-matrix replacement, longer\n".utf8)
                let localFile = localDirectory.appendingPathComponent(name)
                try replacement.write(to: localFile)

                let remotePath = rig.remotePath(name)
                await litter.file(remotePath)
                try await rig.seed(fileSystem, path: remotePath, content: original)

                let binary = try CLIMatrix.binaryURL()
                let flags = try await CLIMatrix.hostKeyFlags(for: "put", binary: binary)
                let result = try await rig.run(
                    ["put"] + flags
                        + [localFile.path(percentEncoded: false), rig.target(rig.remoteRoot),
                           "--on-conflict", action.rawValue])

                let expectedStatus: Int32
                let expectedContent: Data
                switch action {
                case .fail:
                    expectedStatus = CLIExitCode.conflict.rawValue
                    expectedContent = original
                case .skip:
                    expectedStatus = CLIExitCode.success.rawValue
                    expectedContent = original
                case .overwrite:
                    expectedStatus = CLIExitCode.success.rawValue
                    expectedContent = replacement
                }

                #expect(
                    result.status == expectedStatus,
                    """
                    put --on-conflict \(action.rawValue) exited \(result.status) on \
                    \(kind.rawValue): \(result.stderrText)
                    """)
                let readBack = try await rig.read(fileSystem, path: remotePath)
                #expect(
                    readBack == expectedContent,
                    "put --on-conflict \(action.rawValue) left the wrong bytes on \(kind.rawValue)")
            }
        }
    }

    /// A DIRECTORY source is refused by both single-file transfers, and
    /// refused before anything is written.
    ///
    /// This is the matrix's row for the brief's `put --recursive` and
    /// `get --recursive`: neither flag exists. Measured 2026-09-04 against
    /// the built binary — `macscp-cli help put` and `help get` advertise
    /// `--on-conflict` and no `--recursive`, and `TransferSourceGuard
    /// .checkNotDirectory` refuses a directory source outright — so the
    /// behaviour to pin per backend is the refusal, and the absence of the
    /// flag itself is pinned once, against the binary, in
    /// `neitherTransferCommandOffersARecursiveFlag`.
    ///
    /// It is NOT a capability skip: no axis of `ProtocolCapabilities`
    /// governs it, and it is not a backend's limitation at all — all three
    /// refuse it identically, because the refusal is the CLI's own.
    static func aDirectoryIsRefusedByBothTransfers(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "tree") { rig, fileSystem, litter in
            try await CLIMatrix.withLocalDirectory { localDirectory in
                let binary = try CLIMatrix.binaryURL()

                // put: a local directory as the source.
                let treeName = "cli-matrix-tree-\(UUID().uuidString)"
                let localTree = localDirectory.appendingPathComponent(treeName, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: localTree, withIntermediateDirectories: true)
                try Data("leaf\n".utf8).write(to: localTree.appendingPathComponent("leaf.txt"))

                // Registered before the command runs, not after: `put` is
                // expected to refuse a directory source outright, but if a
                // regression ever let something through, the cleanup below
                // must still find it rather than leaving it on the rig.
                await litter.tree(rig.remotePath(treeName))

                let putFlags = try await CLIMatrix.hostKeyFlags(for: "put", binary: binary)
                let putResult = try await rig.run(
                    ["put"] + putFlags
                        + [localTree.path(percentEncoded: false), rig.target(rig.remoteRoot)])
                #expect(
                    putResult.status == CLIExitCode.usage.rawValue,
                    "put of a directory exited \(putResult.status) on \(kind.rawValue)")
                #expect(putResult.stderrText.contains("single file only"))
                #expect(
                    try await isAbsent(fileSystem, path: rig.remotePath(treeName)),
                    "put of a directory left something on the \(kind.rawValue) rig")

                // get: a remote directory as the source.
                let remoteDirectory = rig.remotePath("cli-matrix-getdir-\(UUID().uuidString)")
                await litter.tree(remoteDirectory)
                try await fileSystem.createDirectory(at: remoteDirectory)

                let destination = localDirectory.appendingPathComponent("out", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)
                let getFlags = try await CLIMatrix.hostKeyFlags(for: "get", binary: binary)
                let getResult = try await rig.run(
                    ["get"] + getFlags
                        + [rig.target(remoteDirectory), destination.path(percentEncoded: false)])
                #expect(
                    getResult.status == CLIExitCode.usage.rawValue,
                    "get of a directory exited \(getResult.status) on \(kind.rawValue)")
                #expect(getResult.stderrText.contains("single file only"))
                let written = try FileManager.default.contentsOfDirectory(
                    atPath: destination.path(percentEncoded: false))
                #expect(written.isEmpty, "get of a directory wrote \(written) locally")
            }
        }
    }

    // MARK: - rm

    /// `rm` deletes a plain file, and the file is really gone afterwards.
    static func rmDeletesAFile(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "rm") { rig, fileSystem, litter in
            let name = "cli-matrix-rm-\(UUID().uuidString).txt"
            let remotePath = rig.remotePath(name)
            // Still registered: `rm` is the thing under test, so a case that
            // fails because the file survived must not also leave it there.
            await litter.file(remotePath)
            try await rig.seed(fileSystem, path: remotePath, content: Data("cli-matrix rm\n".utf8))

            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "rm", binary: binary)
            let result = try await rig.run(["rm"] + flags + [rig.target(remotePath)])
            #expect(result.status == 0, "rm failed on \(kind.rawValue): \(result.stderrText)")
            #expect(
                try await isAbsent(fileSystem, path: remotePath),
                "rm exited 0 and left \(name) on the \(kind.rawValue) rig")
        }
    }

    /// A directory is refused without `--recursive`, survives the refusal
    /// with its contents, and goes away with the flag.
    ///
    /// The refusal is asserted with the CONTENTS still there afterwards, not
    /// merely with an exit code: "refused" and "deleted, then reported an
    /// error" are the same exit code and different rigs.
    static func rmRefusesADirectoryUntilRecursive(_ kind: ConnectionKind) async throws {
        try await CLIMatrix.withRig(kind, label: "rmtree") { rig, fileSystem, litter in
            let directory = rig.remotePath("cli-matrix-rmtree-\(UUID().uuidString)")
            let child = "\(directory)/cli-matrix-child.txt"
            await litter.tree(directory)
            try await fileSystem.createDirectory(at: directory)
            try await rig.seed(fileSystem, path: child, content: Data("cli-matrix child\n".utf8))

            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "rm", binary: binary)

            let refused = try await rig.run(["rm"] + flags + [rig.target(directory)])
            #expect(
                refused.status == CLIExitCode.usage.rawValue,
                "rm of a directory exited \(refused.status) on \(kind.rawValue)")
            #expect(refused.stderrText.contains("--recursive"))
            let survivor = try await fileSystem.stat(path: child)
            #expect(survivor.isDirectory == false, "the refused rm changed \(child)")

            let removed = try await rig.run(
                ["rm"] + flags + ["--recursive", rig.target(directory)])
            #expect(
                removed.status == 0,
                "rm --recursive failed on \(kind.rawValue): \(removed.stderrText)")
            #expect(
                try await isAbsent(fileSystem, path: directory),
                "rm --recursive exited 0 and left the tree on the \(kind.rawValue) rig")
        }
    }

    /// The session root is refused by `--recursive` alone AND by
    /// `--allow-root-delete` alone, and a file under the root survives both.
    ///
    /// The two flags are NEVER passed together here, on any backend. That is
    /// the combination the guard exists to allow, and allowing it against
    /// this rig means `deleteTree("/")` — every object in `macscp-seed`,
    /// every file on a WebDAV container that has no volume. The case pins
    /// the refusals; the acceptance is `TransferSourceGuard`'s own unit
    /// test's business, where it costs nothing.
    static func rmRefusesTheSessionRootWithoutTheEscapeHatch(
        _ kind: ConnectionKind
    ) async throws {
        try await CLIMatrix.withRig(kind, label: "rmroot") { rig, fileSystem, litter in
            let name = "cli-matrix-rmroot-\(UUID().uuidString).txt"
            let remotePath = rig.remotePath(name)
            await litter.file(remotePath)
            try await rig.seed(
                fileSystem, path: remotePath, content: Data("cli-matrix survivor\n".utf8))

            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "rm", binary: binary)
            let root = rig.target("/")

            let withoutTheHatch = try await rig.run(["rm"] + flags + ["--recursive", root])
            #expect(
                withoutTheHatch.status == CLIExitCode.usage.rawValue,
                "rm --recursive on the root exited \(withoutTheHatch.status) on \(kind.rawValue)")
            #expect(withoutTheHatch.stderrText.contains("--allow-root-delete"))

            let withoutRecursive = try await rig.run(["rm"] + flags + ["--allow-root-delete", root])
            #expect(
                withoutRecursive.status == CLIExitCode.usage.rawValue,
                "rm --allow-root-delete alone exited \(withoutRecursive.status)")
            #expect(withoutRecursive.stderrText.contains("--recursive"))

            let survivor = try await fileSystem.stat(path: remotePath)
            #expect(survivor.isDirectory == false, "a refused root delete changed \(name)")
        }
    }

    // MARK: - Host keys

    /// An unknown host key is refused under `--non-interactive`, records
    /// nothing, and is then accepted — exactly once — under `--accept-new`.
    ///
    /// The store is FRESH, so the rig's key is unknown to it: `CLIMatrix
    /// .make` creates the temporary directory the child gets as
    /// `MACSCP_STORAGE_DIRECTORY`, and the `known_hosts.json` beside the
    /// session file does not exist yet. That is also why this case does NOT
    /// go through `withRig`: the verification connection that scaffold opens
    /// accepts unknown keys itself (`.asking { _ in true }`), and it would
    /// write the rig's key into the very store this case needs empty.
    ///
    /// What `--non-interactive` adds here is stated rather than overclaimed:
    /// the child's stdin is the null device (`SubprocessRunner`), so
    /// `CLIEnvironment.hasTTY` is false and `HostKeyPolicy.decision` turns
    /// plain `.ask` into `.reject` as well. In THIS harness the flag and its
    /// absence therefore reach the same refusal, and only a pty could tell
    /// them apart; the flag is passed because it is what an unattended
    /// caller passes, and the decision table itself is pinned by
    /// `HostKeyPolicy`'s own unit tests. The discriminator that IS measured
    /// here is `--accept-new`, which turns the same refusal into a connect.
    ///
    /// Which backends are asked is derived, not listed — `hasHostKeys` reads
    /// the connection config the CLI builds, and S3 and WebDAV authenticate
    /// no host key at all. Their branch is not a bare `return`: a backend
    /// that has no host keys must still CONNECT with `--non-interactive` and
    /// leave the store empty, so the gate is measured on both sides rather
    /// than merely believed on one. A gate stuck at `false` fails the
    /// refusal below; a gate stuck at `true` fails on S3 and WebDAV, which
    /// exit 0 where it would demand 11.
    static func anUnknownHostKeyIsRefusedUntilAccepted(_ kind: ConnectionKind) async throws {
        let rig = try CLIMatrix.make(for: kind, label: "hostkey")
        defer { rig.tearDown() }
        let target = rig.target(rig.remoteRoot)
        #expect(try rig.recordedHostKeys().isEmpty, "a fresh store already knows a host key")

        guard try rig.hasHostKeys(operation: "the unknown-host-key refusal") else {
            let result = try await rig.run(["ls", "--non-interactive", "--json", target])
            #expect(
                result.status == 0,
                """
                ls --non-interactive failed on \(kind.rawValue), which authenticates no \
                host key: \(result.stderrText)
                """)
            #expect(
                try rig.recordedHostKeys().isEmpty,
                "\(kind.rawValue) recorded a host key it has no host keys for")
            return
        }

        let refused = try await rig.run(["ls", "--non-interactive", "--json", target])
        #expect(
            refused.status == CLIExitCode.hostKeyUnknown.rawValue,
            "an unknown host key exited \(refused.status) on \(kind.rawValue)")
        // "Refused" and "connected, then complained" are not the same thing,
        // and the exit code alone cannot tell them apart: nothing may have
        // been listed, and nothing may have been remembered.
        #expect(refused.stdoutText.isEmpty, "a refused connect listed something")
        #expect(
            try rig.recordedHostKeys().isEmpty,
            "a refused connect recorded the host key anyway on \(kind.rawValue)")

        let accepted = try await rig.run(["ls", "--accept-new", "--json", target])
        #expect(
            accepted.status == 0,
            "ls --accept-new failed on \(kind.rawValue): \(accepted.stderrText)")
        let recorded = try rig.recordedHostKeys()
        #expect(
            recorded.count == 1,
            "--accept-new recorded \(recorded.count) host keys on \(kind.rawValue)")
    }

    /// A REMEMBERED host key that changes is a hard stop, and `--accept-new`
    /// does not soften it.
    ///
    /// The invariant this pins is the security-critical one: `--accept-new`
    /// says something about UNKNOWN keys and nothing about a mismatch, and
    /// `HostKeyValidation.evaluate` never consults a decider for one. The
    /// planted key is derived from the key the rig really presented (last
    /// byte inverted, same host and port), so nothing here carries key
    /// material and the two fingerprints cannot accidentally agree.
    ///
    /// The last assertion is the one that would go unnoticed: a mismatch
    /// that re-TOFU'd would exit non-zero all the same while quietly
    /// replacing the remembered key, so the STORE is read afterwards and the
    /// planted key must still be the one on file.
    static func aChangedHostKeyIsAHardStop(_ kind: ConnectionKind) async throws {
        let rig = try CLIMatrix.make(for: kind, label: "hostkeymismatch")
        defer { rig.tearDown() }
        guard try rig.hasHostKeys(operation: "the host-key mismatch stop") else { return }
        let target = rig.target(rig.remoteRoot)

        let accepted = try await rig.run(["ls", "--accept-new", "--json", target])
        #expect(
            accepted.status == 0,
            "ls --accept-new failed on \(kind.rawValue): \(accepted.stderrText)")

        let planted = try rig.plantADifferentHostKey()
        let refused = try await rig.run(["ls", "--accept-new", "--json", target])
        #expect(
            refused.status == CLIExitCode.hostKeyMismatch.rawValue,
            "a changed host key exited \(refused.status) on \(kind.rawValue)")
        #expect(refused.stdoutText.isEmpty, "a refused connect listed something")

        let after = try rig.recordedHostKeys()
        #expect(after.count == 1, "the mismatch left \(after.count) keys on file")
        #expect(
            after.first?.publicKeyBase64 == planted.publicKeyBase64,
            "the mismatch overwrote the remembered key instead of stopping")
    }

    // MARK: - The secret's route

    /// `--password-command` really delivers the secret, and the value
    /// reaches no argument vector, no file and no output.
    ///
    /// How the secret travels: the child's ENVIRONMENT, under
    /// `CLIMatrix.secretRelayVariable` — a name no backend reads (pinned by
    /// `noBackendReadsTheSecretRelayVariable`), with every backend's own
    /// secret variable removed. The argv carries the command TEXT, and that
    /// text names the variable rather than containing the value, so the
    /// secret is in no `ps` listing on either side. Nothing is written to
    /// disk: a helper SCRIPT would be a second copy of the same relay plus a
    /// file to create, chmod and remove, and the value would still have to
    /// come from the environment for the script to be safe to write at all.
    ///
    /// Three runs, because the positive one alone proves nothing — the
    /// backends' secrets are also in this test process's own environment,
    /// and a child that inherited one would succeed for the wrong reason:
    ///   - the CONTROL, with no secret anywhere and no helper: must fail
    ///     authentication, which is what makes the run below meaningful;
    ///   - the helper, which must succeed AND name itself as the source that
    ///     answered (`--verbose`), so "the environment answered" cannot pass
    ///     for "the command answered";
    ///   - a FAILING helper, whose error must name the command's failure and
    ///     nothing else.
    static func theSecretComesFromThePasswordCommand(_ kind: ConnectionKind) async throws {
        let rig = try CLIMatrix.make(for: kind, label: "pwcmd")
        defer { rig.tearDown() }
        let binary = try CLIMatrix.binaryURL()
        let flags = try await CLIMatrix.hostKeyFlags(for: "ls", binary: binary)
        let options = try await CLIMatrix.advertisedOptions(for: "ls", binary: binary)
        #expect(options.contains("--password-command"), "ls advertises no --password-command")
        let target = rig.target(rig.remoteRoot)

        let control = try await rig.runWithoutASecret(["ls"] + flags + ["--json", target])
        #expect(
            control.status == CLIExitCode.auth.rawValue,
            "\(kind.rawValue) connected with no secret at all (exit \(control.status))")

        // The command text: a shell reading the relay variable. It is built
        // here and checked for the value before it is ever passed, so a
        // future edit that interpolated the secret into it fails rather than
        // ships.
        let command = "printf %s \"$\(CLIMatrix.secretRelayVariable)\""
        let commandCarriesTheSecret = rig.leaksSecret(command)
        #expect(commandCarriesTheSecret == false, "the --password-command argument carries a secret")

        let delivered = try await rig.run(
            ["ls"] + flags + ["--json", "--verbose", "--password-command", command, target],
            secretRelayedThrough: CLIMatrix.secretRelayVariable)
        #expect(
            delivered.status == 0,
            "--password-command did not deliver on \(kind.rawValue): \(delivered.stderrText)")
        // The label comes from the source type itself, not from a string
        // written here: renaming it moves both sides at once.
        let label = PasswordCommandSecretSource(command: "true").label
        #expect(
            delivered.stderrText.contains("secret source: \(label)"),
            "another source answered on \(kind.rawValue)")
        #expect(!(try CLIMatrix.listing(delivered.stdoutText)).isEmpty, "nothing was listed")

        let deliveredStdoutLeaks = rig.leaksSecret(delivered.stdoutText)
        let deliveredStderrLeaks = rig.leaksSecret(delivered.stderrText)
        #expect(deliveredStdoutLeaks == false)
        #expect(deliveredStderrLeaks == false)

        let broken = try await rig.runWithoutASecret(
            ["ls"] + flags + ["--json", "--password-command", "exit 3", target])
        #expect(
            broken.status == CLIExitCode.auth.rawValue,
            "a failing --password-command exited \(broken.status) on \(kind.rawValue)")
        #expect(broken.stderrText.contains("\(label) failed"))
        let brokenStderrLeaks = rig.leaksSecret(broken.stderrText)
        #expect(brokenStderrLeaks == false)
    }

    // MARK: - Shared reading

    /// Whether the entry is gone, distinguishing "not there" from "the
    /// question could not be asked": anything but `.notFound` propagates and
    /// fails the case with its own error rather than being counted as
    /// absence.
    private static func isAbsent(
        _ fileSystem: any RemoteFileSystem, path: String
    ) async throws -> Bool {
        do {
            _ = try await fileSystem.stat(path: path)
            return false
        } catch RemoteFSError.notFound {
            return true
        }
    }
}

// MARK: - One suite per backend

@Suite("CLIMatrixSSH", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixSSHITests {
    static let kind: ConnectionKind = .ssh

    @Test func listsASeededFileAsJSON() async throws {
        try await CLIMatrixCases.listsASeededFileAsJSON(Self.kind)
    }

    @Test func mkdirCreatesADirectory() async throws {
        try await CLIMatrixCases.mkdirCreatesADirectory(Self.kind)
    }

    @Test func putUploadsALocalFile() async throws {
        try await CLIMatrixCases.putUploadsALocalFile(Self.kind)
    }

    @Test func getDownloadsARemoteFile() async throws {
        try await CLIMatrixCases.getDownloadsARemoteFile(Self.kind)
    }

    @Test(arguments: ConflictAction.allCases)
    func putOverAnExistingFile(action: ConflictAction) async throws {
        try await CLIMatrixCases.putOverAnExistingFile(Self.kind, action: action)
    }

    @Test func aDirectoryIsRefusedByBothTransfers() async throws {
        try await CLIMatrixCases.aDirectoryIsRefusedByBothTransfers(Self.kind)
    }

    @Test func rmDeletesAFile() async throws {
        try await CLIMatrixCases.rmDeletesAFile(Self.kind)
    }

    @Test func rmRefusesADirectoryUntilRecursive() async throws {
        try await CLIMatrixCases.rmRefusesADirectoryUntilRecursive(Self.kind)
    }

    @Test func rmRefusesTheSessionRootWithoutTheEscapeHatch() async throws {
        try await CLIMatrixCases.rmRefusesTheSessionRootWithoutTheEscapeHatch(Self.kind)
    }

    @Test func anUnknownHostKeyIsRefusedUntilAccepted() async throws {
        try await CLIMatrixCases.anUnknownHostKeyIsRefusedUntilAccepted(Self.kind)
    }

    @Test func aChangedHostKeyIsAHardStop() async throws {
        try await CLIMatrixCases.aChangedHostKeyIsAHardStop(Self.kind)
    }

    @Test func theSecretComesFromThePasswordCommand() async throws {
        try await CLIMatrixCases.theSecretComesFromThePasswordCommand(Self.kind)
    }
}

@Suite("CLIMatrixS3", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixS3ITests {
    static let kind: ConnectionKind = .s3

    @Test func listsASeededFileAsJSON() async throws {
        try await CLIMatrixCases.listsASeededFileAsJSON(Self.kind)
    }

    @Test func mkdirCreatesADirectory() async throws {
        try await CLIMatrixCases.mkdirCreatesADirectory(Self.kind)
    }

    @Test func putUploadsALocalFile() async throws {
        try await CLIMatrixCases.putUploadsALocalFile(Self.kind)
    }

    @Test func getDownloadsARemoteFile() async throws {
        try await CLIMatrixCases.getDownloadsARemoteFile(Self.kind)
    }

    @Test(arguments: ConflictAction.allCases)
    func putOverAnExistingFile(action: ConflictAction) async throws {
        try await CLIMatrixCases.putOverAnExistingFile(Self.kind, action: action)
    }

    @Test func aDirectoryIsRefusedByBothTransfers() async throws {
        try await CLIMatrixCases.aDirectoryIsRefusedByBothTransfers(Self.kind)
    }

    @Test func rmDeletesAFile() async throws {
        try await CLIMatrixCases.rmDeletesAFile(Self.kind)
    }

    @Test func rmRefusesADirectoryUntilRecursive() async throws {
        try await CLIMatrixCases.rmRefusesADirectoryUntilRecursive(Self.kind)
    }

    @Test func rmRefusesTheSessionRootWithoutTheEscapeHatch() async throws {
        try await CLIMatrixCases.rmRefusesTheSessionRootWithoutTheEscapeHatch(Self.kind)
    }

    @Test func anUnknownHostKeyIsRefusedUntilAccepted() async throws {
        try await CLIMatrixCases.anUnknownHostKeyIsRefusedUntilAccepted(Self.kind)
    }

    @Test func aChangedHostKeyIsAHardStop() async throws {
        try await CLIMatrixCases.aChangedHostKeyIsAHardStop(Self.kind)
    }

    @Test func theSecretComesFromThePasswordCommand() async throws {
        try await CLIMatrixCases.theSecretComesFromThePasswordCommand(Self.kind)
    }
}

@Suite("CLIMatrixWebDAV", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixWebDAVITests {
    static let kind: ConnectionKind = .webdav

    @Test func listsASeededFileAsJSON() async throws {
        try await CLIMatrixCases.listsASeededFileAsJSON(Self.kind)
    }

    @Test func mkdirCreatesADirectory() async throws {
        try await CLIMatrixCases.mkdirCreatesADirectory(Self.kind)
    }

    @Test func putUploadsALocalFile() async throws {
        try await CLIMatrixCases.putUploadsALocalFile(Self.kind)
    }

    @Test func getDownloadsARemoteFile() async throws {
        try await CLIMatrixCases.getDownloadsARemoteFile(Self.kind)
    }

    @Test(arguments: ConflictAction.allCases)
    func putOverAnExistingFile(action: ConflictAction) async throws {
        try await CLIMatrixCases.putOverAnExistingFile(Self.kind, action: action)
    }

    @Test func aDirectoryIsRefusedByBothTransfers() async throws {
        try await CLIMatrixCases.aDirectoryIsRefusedByBothTransfers(Self.kind)
    }

    @Test func rmDeletesAFile() async throws {
        try await CLIMatrixCases.rmDeletesAFile(Self.kind)
    }

    @Test func rmRefusesADirectoryUntilRecursive() async throws {
        try await CLIMatrixCases.rmRefusesADirectoryUntilRecursive(Self.kind)
    }

    @Test func rmRefusesTheSessionRootWithoutTheEscapeHatch() async throws {
        try await CLIMatrixCases.rmRefusesTheSessionRootWithoutTheEscapeHatch(Self.kind)
    }

    @Test func anUnknownHostKeyIsRefusedUntilAccepted() async throws {
        try await CLIMatrixCases.anUnknownHostKeyIsRefusedUntilAccepted(Self.kind)
    }

    @Test func aChangedHostKeyIsAHardStop() async throws {
        try await CLIMatrixCases.aChangedHostKeyIsAHardStop(Self.kind)
    }

    @Test func theSecretComesFromThePasswordCommand() async throws {
        try await CLIMatrixCases.theSecretComesFromThePasswordCommand(Self.kind)
    }
}

// MARK: - sessions

/// The one subcommand that opens no connection, so the one suite in the
/// matrix that is not per backend: `sessions` reads the store and nothing
/// else. It still needs the built binary, so it is gated with the rest.
///
/// The store it reads carries a session for EVERY backend — built through
/// the same per-kind fixture the rig suites use — spread over two top-level
/// groups, one subgroup and two tags (`CLISessionCatalogFixture`). Every
/// expectation below is computed from that fixture's own `entries`, and each
/// one is checked for being non-empty first: a filter that matched nothing
/// and an expectation that expected nothing agree perfectly.
@Suite("CLIMatrixSessions", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixSessionsITests {
    private static func withFixture(
        _ body: (CLISessionCatalogFixture, [String]) async throws -> Void
    ) async throws {
        let fixture = try CLISessionCatalogFixture.make()
        defer { fixture.tearDown() }
        // Asked for, never written in: `sessions` declares `JSONOptions`,
        // so it takes none of the connection flags and REFUSES one it is
        // handed (`theConnectionFlagsAreAskedForPerCommand`).
        let flags = try await CLIMatrix.hostKeyFlags(
            for: "sessions", binary: try CLIMatrix.binaryURL())
        try await body(fixture, flags)
    }

    private static func rows(
        _ result: SubprocessResult, arguments: String
    ) throws -> [CLISessionRow] {
        #expect(result.status == 0, "sessions \(arguments) exited \(result.status): \(result.stderrText)")
        return try CLIMatrix.sessionRows(result.stdoutText)
    }

    /// Unfiltered, every stored session is reported — with its group path,
    /// its tags, its kind and a target — and the printed object carries no
    /// field beyond the ones `SessionCatalog.Row` declares.
    ///
    /// That last check is the security-relevant one, and it is why the keys
    /// are read from the JSON rather than only decoded: `CLISessionRow`
    /// decodes the five fields it knows and would ignore a sixth. A field
    /// added to `Row` — a key path, a login-set id, a secret handle of any
    /// shape — reaches stdout, and a shell history, without any decode
    /// failing. The count comes from `Row` itself through `Mirror`, so it is
    /// not a number written here that would have to be maintained.
    @Test func everySessionInTheStoreIsListed() async throws {
        try await Self.withFixture { fixture, flags in
            let result = try await fixture.run(["sessions"] + flags + ["--json"])
            let rows = try Self.rows(result, arguments: "--json")
            #expect(rows.count == fixture.entries.count)
            #expect(Set(rows.map(\.name)) == Set(fixture.entries.map(\.name)))

            for entry in fixture.entries {
                let row = try #require(
                    rows.first { $0.name == entry.name },
                    "sessions --json did not report \(entry.kind.rawValue)")
                #expect(row.kind == entry.kind.rawValue)
                #expect(row.group == entry.groupPath)
                #expect(row.tags == entry.tags)
                #expect(!row.target.isEmpty, "the \(entry.kind.rawValue) row has no target")
            }

            let declaredFields = Mirror(
                reflecting: SessionCatalog.Row(
                    name: "n", kind: .ssh, groupPath: "", tags: [], target: "t")
            ).children.count
            for keys in try CLIMatrix.sessionRowKeys(result.stdoutText) {
                #expect(
                    keys.count == declaredFields,
                    "sessions --json printed \(keys.sorted()); Row declares \(declaredFields) fields")
                #expect(keys.contains("name"), "sessions --json printed no name")
            }
        }
    }

    /// `--group` matches a group AND its subgroups, which is what its own
    /// help says ("Only sessions in this group or one of its subgroups").
    ///
    /// The parent query is asserted to reach something NESTED, not merely to
    /// return the right count: a filter that only ever matched the immediate
    /// group would return a plausible answer for the child query and a short
    /// one here. The child query beside it is what stops the opposite
    /// mistake — a filter matching any ancestor OR descendant would pull the
    /// parent's own session into the child's answer.
    @Test func theGroupFilterReachesIntoSubgroups() async throws {
        try await Self.withFixture { fixture, flags in
            let parent = CLISessionCatalogFixture.parentGroup
            let child = CLISessionCatalogFixture.childGroup
            let expectedParent = fixture.entries.filter { $0.ancestry.contains(parent) }
            let expectedChild = fixture.entries.filter { $0.ancestry.contains(child) }
            #expect(expectedParent.count > expectedChild.count, "the fixture lost its subgroup")
            #expect(!expectedChild.isEmpty, "the fixture has nothing in the subgroup")

            let inParent = try Self.rows(
                await fixture.run(["sessions"] + flags + ["--json", "--group", parent]),
                arguments: "--group \(parent)")
            #expect(Set(inParent.map(\.name)) == Set(expectedParent.map(\.name)))
            #expect(
                inParent.contains { $0.group.contains(" / ") },
                "--group \(parent) reached nothing in a subgroup")

            let inChild = try Self.rows(
                await fixture.run(["sessions"] + flags + ["--json", "--group", child]),
                arguments: "--group \(child)")
            #expect(Set(inChild.map(\.name)) == Set(expectedChild.map(\.name)))

            // The empty answer, with the two non-empty ones above as its
            // positives: a filter that matched nothing at all would satisfy
            // this line alone.
            let nowhere = try Self.rows(
                await fixture.run(["sessions"] + flags + ["--json", "--group", "cli-matrix-nogroup"]),
                arguments: "--group cli-matrix-nogroup")
            #expect(nowhere.isEmpty, "an unknown group matched \(nowhere.map(\.name))")
        }
    }

    /// `--tag` selects the sessions carrying it, and does so regardless of
    /// case (`SessionCatalog`'s own rule — `caseInsensitiveCompare`).
    ///
    /// The tag is asserted to DISCRIMINATE first: a fixture where every
    /// session carried it would make both spellings pass while proving
    /// nothing about the filter.
    @Test func theTagFilterIgnoresCase() async throws {
        try await Self.withFixture { fixture, flags in
            let tag = CLISessionCatalogFixture.firstTag
            let expected = fixture.entries.filter { $0.tags.contains(tag) }
            #expect(!expected.isEmpty, "the fixture carries no \(tag)")
            #expect(expected.count < fixture.entries.count, "every session carries \(tag)")

            for spelling in [tag, tag.uppercased()] {
                let listed = try Self.rows(
                    await fixture.run(["sessions"] + flags + ["--json", "--tag", spelling]),
                    arguments: "--tag \(spelling)")
                #expect(
                    Set(listed.map(\.name)) == Set(expected.map(\.name)),
                    "--tag \(spelling) selected \(listed.map(\.name))")
            }
        }
    }

    /// Filters combine with AND, which is what the command's discussion
    /// claims ("Filters combine").
    ///
    /// The pair is chosen so the answer is SMALLER than either half alone —
    /// asserted, not assumed — because an implementation that ORed them, or
    /// that ignored one of the two, returns one of those halves.
    @Test func theFiltersCombine() async throws {
        try await Self.withFixture { fixture, flags in
            let group = CLISessionCatalogFixture.parentGroup
            let tag = CLISessionCatalogFixture.secondTag
            let byGroup = fixture.entries.filter { $0.ancestry.contains(group) }
            let byTag = fixture.entries.filter { $0.tags.contains(tag) }
            let byBoth = fixture.entries.filter {
                $0.ancestry.contains(group) && $0.tags.contains(tag)
            }
            #expect(!byBoth.isEmpty, "the fixture has nothing in \(group) tagged \(tag)")
            #expect(byBoth.count < byGroup.count && byBoth.count < byTag.count)

            let listed = try Self.rows(
                await fixture.run(
                    ["sessions"] + flags + ["--json", "--group", group, "--tag", tag]),
                arguments: "--group \(group) --tag \(tag)")
            #expect(Set(listed.map(\.name)) == Set(byBoth.map(\.name)))
        }
    }

    /// `--kind`, asked once per backend — the matrix's own axis, applied to
    /// the one subcommand that never connects to any of them.
    @Test(arguments: ConnectionKind.allCases)
    func theKindFilterAsksForEveryBackend(kind: ConnectionKind) async throws {
        try await Self.withFixture { fixture, flags in
            let expected = fixture.entries.filter { $0.kind == kind }
            #expect(!expected.isEmpty, "the fixture has no \(kind.rawValue) session")
            let listed = try Self.rows(
                await fixture.run(["sessions"] + flags + ["--json", "--kind", kind.rawValue]),
                arguments: "--kind \(kind.rawValue)")
            #expect(Set(listed.map(\.name)) == Set(expected.map(\.name)))
            #expect(listed.allSatisfy { $0.kind == kind.rawValue })
        }
    }

    /// `--name` is a case-insensitive SUBSTRING, not a pattern and not an
    /// exact match — its own help says so.
    ///
    /// The needle is taken from a session's own name (its trailing UUID
    /// segment) rather than written here, so it is unique to that session by
    /// construction and cannot start matching a second one.
    @Test func theNameFilterIsACaseInsensitiveSubstring() async throws {
        try await Self.withFixture { fixture, flags in
            let entry = try #require(fixture.entries.first)
            let needle = String(entry.name.suffix(12))
            #expect(
                fixture.entries.filter { $0.name.contains(needle) }.count == 1,
                "the needle is not unique to one session")

            let listed = try Self.rows(
                await fixture.run(["sessions"] + flags + ["--json", "--name", needle.uppercased()]),
                arguments: "--name \(needle.uppercased())")
            #expect(listed.map(\.name) == [entry.name])
        }
    }
}

// MARK: - What makes the matrix a matrix

/// The derivation guards. None of these needs the rig or the binary, so they
/// run in the ordinary `swift test` — which is where a fourth backend, or a
/// seventh subcommand, is actually going to be added.
@Suite("CLIMatrixCoverage")
struct CLIMatrixCoverageTests {
    /// The one place the three suites above are enumerated, and it is
    /// checked against `ConnectionKind.allCases` rather than against a
    /// number. A fourth protocol turns this red until it has a suite —
    /// which is the whole reason the suites carry a `kind` at all.
    @Test func everyConnectionKindHasAMatrixSuite() {
        let covered: Set<ConnectionKind> = [
            CLIMatrixSSHITests.kind,
            CLIMatrixS3ITests.kind,
            CLIMatrixWebDAVITests.kind,
        ]
        #expect(covered == Set(ConnectionKind.allCases))
    }

    /// Every kind has rig coordinates, and the session they produce is
    /// really in the temporary store under the name the reference uses.
    /// Reads the store back rather than trusting `upsert`: the CLI resolves
    /// `name:/path` out of that file, so "the fixture exists" means "the
    /// file says so".
    @Test(arguments: ConnectionKind.allCases)
    func everyConnectionKindHasARigFixture(kind: ConnectionKind) throws {
        let rig = try CLIMatrix.make(for: kind, label: "fixture")
        defer { rig.tearDown() }

        #expect(rig.kind == kind)
        #expect(rig.session.kind == kind)
        let stored = try SessionStore(directory: rig.storageDirectory).all()
        #expect(stored.count == 1)
        let resolved = try SessionReference.parse(rig.target(rig.remoteRoot)).resolve(in: stored)
        #expect(resolved.id == rig.session.id)
        // The secret has exactly one route to the child, and a backend that
        // named no variable would have none.
        #expect(rig.descriptor.secretEnvironmentVariable != nil)
    }

    /// The capability gate's sensitivity, measured on the two axes where the
    /// three real backends genuinely disagree — one where S3 is the odd one
    /// out and one where it is the only one that has it, so a gate stuck at
    /// `true` and a gate stuck at `false` are both red.
    ///
    /// Both directions on purpose: a skip mechanism that never skips reads
    /// exactly like one that has nothing to skip.
    @Test func anOperationIsGatedByTheBackendsOwnCapabilities() throws {
        // The `defer` sits ABOVE the loop on purpose: it reads `rigs` at
        // scope exit, so a `make` that throws on the third kind still tears
        // down the first two. Registered after the loop, as it was, those
        // two temporary directories outlived the run.
        var rigs: [ConnectionKind: CLIMatrix] = [:]
        defer { rigs.values.forEach { $0.tearDown() } }
        for kind in ConnectionKind.allCases {
            rigs[kind] = try CLIMatrix.make(for: kind, label: "capabilities")
        }

        for (kind, rig) in rigs {
            let real = rig.supports(
                \.directoriesAreReal, named: "directoriesAreReal", operation: "a directory case")
            #expect(real == (kind != .s3), "directoriesAreReal is wrong for \(kind.rawValue)")

            let presigned = rig.supports(
                \.supportsPresignedURL, named: "supportsPresignedURL", operation: "a share case")
            #expect(presigned == (kind == .s3), "supportsPresignedURL is wrong for \(kind.rawValue)")
        }
    }

    /// The relay variable the `--password-command` cases carry the secret in
    /// is read by no backend.
    ///
    /// If it collided with one — `MACSCP_PASSWORD`, `AWS_SECRET_ACCESS_KEY`,
    /// or whatever a fourth backend names — the positive run in
    /// `theSecretComesFromThePasswordCommand` would still pass, while
    /// testing `EnvironmentSecretSource` instead of the helper command. So
    /// the name is compared against every backend's own
    /// `secretEnvironmentVariable`, derived from `ConnectionKind.allCases`.
    @Test func noBackendReadsTheSecretRelayVariable() {
        let readByABackend = ConnectionKind.allCases.compactMap {
            BackendDescriptor.descriptor(for: $0).secretEnvironmentVariable
        }
        #expect(!readByABackend.isEmpty, "no backend names a secret variable at all")
        #expect(!readByABackend.contains(CLIMatrix.secretRelayVariable))
    }

    /// Every backend has a session in the `sessions` fixture, and the
    /// fixture really spreads them over groups and tags.
    ///
    /// Needs neither the rig nor the binary — the fixture only writes a
    /// store — so a fourth protocol is caught here in the ordinary `swift
    /// test`, the run where it will actually be added. The placement checks
    /// beside it are what stop the filter cases above from quietly asserting
    /// on empty sets if the placement rule ever changes.
    @Test func everyBackendHasASessionInTheFilterFixture() throws {
        let fixture = try CLISessionCatalogFixture.make()
        defer { fixture.tearDown() }
        #expect(Set(fixture.entries.map(\.kind)) == Set(ConnectionKind.allCases))
        #expect(fixture.entries.count == ConnectionKind.allCases.count)

        let grouped = fixture.entries.filter { !$0.ancestry.isEmpty }
        #expect(!grouped.isEmpty, "the fixture puts nothing in a group")
        #expect(
            fixture.entries.contains { $0.ancestry.count > 1 },
            "the fixture has no session in a subgroup")
        let tags = Set(fixture.entries.flatMap(\.tags))
        #expect(
            tags == [CLISessionCatalogFixture.firstTag, CLISessionCatalogFixture.secondTag],
            "the fixture no longer carries both tags")

        // The store on disk is what the CLI reads, so that is what is read
        // back — not the value the fixture returned.
        let store = SessionStore(directory: fixture.directory)
        #expect(try store.all().count == fixture.entries.count)
        #expect(try store.allGroups().count == 3)
    }

    /// The driven-subcommand scan reads CALLS, and neither comments nor the
    /// matrix's own introspection runs.
    ///
    /// Three hazards, each with its positive on the same fixture:
    /// 1. A commented-out drive must not count as coverage — the exact way a
    ///    guard goes green while the case it counts is disabled.
    /// 2. `SubprocessRunner.run(binary, arguments: […])` is how the guards
    ///    ask the binary about a flag it does not declare; those are not
    ///    cases, and `help` is not a subcommand the matrix drives at all
    ///    (it is ArgumentParser's own, and it is absent from the
    ///    `SUBCOMMANDS:` block — measured 2026-09-04).
    /// 3. A drive whose call spans two lines, which most of them do here,
    ///    must still be read.
    ///
    /// The positive: the two real drives ARE found. A scan that returned
    /// nothing satisfies both absences.
    ///
    /// The live lines of the fixture below name only commands the matrix
    /// really drives, deliberately: the file-level scan reads THIS file too,
    /// so an invented name written outside a comment here would count itself
    /// as coverage.
    @Test func theDrivenScanReadsCallsAndNotComments() throws {
        let source = """
            let result = try await rig.run(
                ["mkdir"] + flags + [rig.target(remotePath)])
            let listed = try await fixture.run(["sessions"] + flags + ["--json"])
            // let skipped = try await rig.run(["nevermind"])
            /// A drive of rig.run(["alsonot"]) described in prose.
            let asked = try await SubprocessRunner.run(binary, arguments: ["help", name])
            """
        #expect(try CLIMatrix.drivenSubcommands(inSource: source) == ["mkdir", "sessions"])
        #expect(try CLIMatrix.drivenSubcommands(inSource: "").isEmpty)
    }

    /// The `--help` parse, against the shape ArgumentParser really prints —
    /// the footer line, which is indented exactly like a subcommand row and
    /// is separated from the block only by the blank line before it, and a
    /// WRAPPED abstract, whose continuation is indented to column 26
    /// (measured 2026-09-04 against `macscp-cli ls --help`).
    ///
    /// `get`'s abstract here is the real one, padded past 80 columns so it
    /// wraps: the continuation's first token is `directory.`, which the
    /// column-blind parse returned as a subcommand name. Nothing in today's
    /// help wraps — all six rows fit, the widest at 72 columns — so this
    /// fixture is the only place the hazard is reachable, and the assertion
    /// is that `directory.` is absent while every real name is present.
    @Test func theSubcommandParseReadsNamesAndStopsAtTheBlock() {
        let help = """
            USAGE: macscp-cli <subcommand>

            OPTIONS:
              -h, --help              Show help information.

            SUBCOMMANDS:
              ls                      List a remote directory.
              get                     Download a remote file into a local
                                      directory.
              sessions                List the saved sessions.

              See 'macscp-cli help <subcommand>' for detailed help.
            """
        #expect(CLIMatrix.parseSubcommands(help) == ["ls", "get", "sessions"])
        #expect(CLIMatrix.parseSubcommands("USAGE: macscp-cli <subcommand>").isEmpty)
    }

    /// The OPTION parse, against the two shapes that make a substring check
    /// wrong, and the one that makes a per-line check wrong.
    ///
    /// 1. An abstract that NAMES another option. `--allow-root-delete`'s
    ///    real abstract says "Required together with --recursive …", so
    ///    `help.contains("--recursive")` answers yes for a command that does
    ///    not offer it. The fixture keeps that sentence and asserts
    ///    `--recursive` is absent from the names — which is exactly the
    ///    question `neitherTransferCommandOffersARecursiveFlag` puts to
    ///    `put` and `get`, so a parse that read prose would turn that guard
    ///    into a comment that runs.
    /// 2. The USAGE line, which lists options too and sits outside the
    ///    `OPTIONS:` block.
    /// 3. A `(values: …)` list that WRAPS — `--on-conflict`'s does, between
    ///    `default:` and `fail)`, in today's real help (measured 2026-09-04
    ///    against `macscp-cli help put`) — so the values are read off the
    ///    joined entry, not off a line.
    ///
    /// The negatives above each sit beside a positive on the same fixture:
    /// every option that IS declared is named, and the wrapped value list IS
    /// read. A parse that returned nothing would satisfy the absences and
    /// fail those.
    @Test func theOptionParseReadsTheNamesAndNotTheAbstracts() {
        let help = """
            USAGE: macscp-cli rm <target> [--recursive] [--allow-root-delete]

            ARGUMENTS:
              <target>                Remote path, e.g. prod:/tmp/old.log

            OPTIONS:
              --accept-new            Trust unknown host keys without asking.
              --on-conflict <on-conflict>
                                      What to do if the destination exists: fail,
                                      skip or overwrite. (values: fail, skip,
                                      overwrite; default: fail)
              --allow-root-delete     Required together with --recursive to delete
                                      a session root.
              -h, --help              Show help information.
            """
        #expect(
            CLIMatrix.parseOptionNames(help)
                == ["--accept-new", "--on-conflict", "--allow-root-delete", "-h", "--help"])
        #expect(
            CLIMatrix.parseAllowedValues(of: "--on-conflict", in: help)
                == ["fail", "skip", "overwrite"])
        #expect(CLIMatrix.parseAllowedValues(of: "--accept-new", in: help) == nil)
        #expect(CLIMatrix.parseAllowedValues(of: "--nothing-like-this", in: help) == nil)
        #expect(CLIMatrix.parseOptionNames("USAGE: macscp-cli rm <target>").isEmpty)
    }
}

/// The command axis, read from the binary rather than written down. Needs
/// the built binary, so it is gated with the rest of the matrix.
@Suite("CLIMatrixCommands", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixCommandsITests {
    /// Every name the parse pulled out of `--help` is a subcommand the
    /// binary actually answers to.
    ///
    /// The discriminator is the USAGE line, not the exit code, and that is a
    /// measurement rather than a preference: `macscp-cli help <anything>`
    /// exits 0 whatever it is handed (measured 2026-09-04 — `help
    /// definitely-not-a-subcommand` exits 0 and prints the ROOT help), so an
    /// exit-code check would buy a parse that returned stray help prose. A
    /// real subcommand's help says `USAGE: macscp-cli <name> …`; an unknown
    /// one falls back to `USAGE: macscp-cli <subcommand>`. Both halves are
    /// asserted, so the check is not merely satisfiable by the fallback.
    @Test func theSubcommandsComeFromTheBinaryItself() async throws {
        let binary = try CLIMatrix.binaryURL()
        let names = try await CLIMatrix.subcommands(binary: binary)
        #expect(names.contains("ls"), "the binary offers no ls: \(names)")

        for name in names {
            let result = try await SubprocessRunner.run(binary, arguments: ["help", name])
            #expect(result.status == 0, "help \(name) exited \(result.status)")
            #expect(
                result.stdoutText.contains("USAGE: macscp-cli \(name)"),
                "\(name) is not a subcommand the binary answers to")
        }

        // The other half of the discriminator: an unknown name reaches the
        // ROOT usage line, which is exactly what the per-name check above
        // would have to be blind to in order to pass by accident.
        let notACommand = try await SubprocessRunner.run(
            binary, arguments: ["help", "definitely-not-a-subcommand"])
        #expect(notACommand.stdoutText.contains("USAGE: macscp-cli <subcommand>"))
    }

    /// Every subcommand the binary offers is driven by a case in this file.
    ///
    /// The two sides are both READ rather than written down: the offered set
    /// comes from the binary's own `--help`, and the driven set from the
    /// source of the cases (`CLIMatrix.drivenSubcommands`, which counts a run
    /// through a fixture's own `run` and ignores comment lines). So a SEVENTH
    /// subcommand turns this red the day it is added — which is the guard
    /// this matrix existed without until now, and the reason `sessions` could
    /// have gone uncovered through two green tasks.
    ///
    /// Set equality, not containment, in both directions on purpose: a case
    /// driving a name the binary does not offer is a case that cannot be
    /// doing what it says. And the negatives have their positives — the
    /// offered set is non-empty and contains a name that has been there since
    /// the first subcommand, and the driven set contains the one this task
    /// added.
    @Test func everySubcommandTheBinaryOffersIsDrivenByACase() async throws {
        let binary = try CLIMatrix.binaryURL()
        let offered = Set(try await CLIMatrix.subcommands(binary: binary))
        #expect(!offered.isEmpty, "the binary offers no subcommands at all")
        #expect(offered.contains("ls"), "the binary offers no ls: \(offered.sorted())")

        let driven = try CLIMatrix.drivenSubcommands(inFileAt: #filePath)
        #expect(driven.contains("sessions"), "the scan reads no drives at all")
        #expect(
            driven == offered,
            """
            the matrix drives \(driven.sorted()); the binary offers \
            \(offered.sorted()) — every subcommand needs at least one case
            """)
    }

    /// The connection flags are not universal, and a uniform argument vector
    /// that assumes they are does not merely carry a useless flag — it is
    /// refused.
    ///
    /// `sessions` declares `JSONOptions`, not `GlobalOptions`
    /// (`Sources/MacSCPCLI/SessionsCommand.swift`), because it opens no
    /// connection and resolves no secret. So this asserts BOTH halves —
    /// `hostKeyFlags` gives `ls` the flag and `sessions` nothing — and then
    /// the reason: the binary really does refuse `sessions --accept-new`.
    /// Without that last run the two halves would only be agreeing with each
    /// other about a help screen.
    @Test func theConnectionFlagsAreAskedForPerCommand() async throws {
        let binary = try CLIMatrix.binaryURL()
        #expect(try await CLIMatrix.hostKeyFlags(for: "ls", binary: binary) == ["--accept-new"])
        #expect(try await CLIMatrix.hostKeyFlags(for: "sessions", binary: binary) == [])

        let refused = try await SubprocessRunner.run(
            binary, arguments: ["sessions", "--accept-new"])
        #expect(refused.status != 0, "sessions accepted a flag it does not declare")
        #expect(refused.stderrText.contains("--accept-new"))

        // Counted rather than asserted as a number: every subcommand the
        // binary offers is asked, and the one that answers no is named.
        let names = try await CLIMatrix.subcommands(binary: binary)
        var without: [String] = []
        for name in names where try await !CLIMatrix.takesConnectionFlags(name, binary: binary) {
            without.append(name)
        }
        #expect(without == ["sessions"], "the commands without the connection flags moved")
    }

    /// Neither transfer command offers `--recursive`, and the binary refuses
    /// it rather than ignoring it.
    ///
    /// This is where the brief's `put --recursive` and `get --recursive`
    /// rows land: the flags do not exist. `TransferSourceGuard`'s own doc
    /// comment says why — "The CLI's `get`/`put` are single-file transfers
    /// only; recursive directory transfers are the GUI queue's job" — so
    /// the gap is a decision, not an oversight, and this pins it as one.
    ///
    /// A negative check with a positive beside it, per CLAUDE.md: `rm` IS
    /// asked for the same two flags first, so a scan that had gone blind
    /// (an `OPTIONS:` heading that moved, a parse that returned nothing)
    /// fails HERE rather than reporting the absence it was looking for. And
    /// the refusal run is the second half: a help screen agreeing with a
    /// parser about a help screen proves nothing about the binary.
    ///
    /// It goes RED the day either flag lands, which is the point — a
    /// recursive transfer needs a real per-backend tree case, not a row that
    /// keeps passing because the command it describes never ran.
    @Test func neitherTransferCommandOffersARecursiveFlag() async throws {
        let rig = try CLIMatrix.make(for: .ssh, label: "recursive-gap")
        defer { rig.tearDown() }
        let binary = try CLIMatrix.binaryURL()
        let rmOptions = try await CLIMatrix.advertisedOptions(for: "rm", binary: binary)
        #expect(rmOptions.contains("--recursive"), "the option scan reads no options at all")
        #expect(rmOptions.contains("--allow-root-delete"))

        for command in ["put", "get"] {
            let options = try await CLIMatrix.advertisedOptions(for: command, binary: binary)
            #expect(options.contains("--on-conflict"), "\(command) advertises no --on-conflict")
            #expect(
                !options.contains("--recursive"),
                "\(command) now offers --recursive; the matrix needs a real tree case for it")

            // Through the rig, not a bare `SubprocessRunner.run`: this refusal
            // never reaches a connect, but routing it through `rig.run` still
            // gets every backend's secret variable scrubbed from the child's
            // environment by construction, same as every other command here.
            let refused = try await rig.run([command, "--recursive", "a", "b"])
            #expect(refused.status != 0, "\(command) accepted a --recursive it does not declare")
            #expect(refused.stderrText.contains("--recursive"))
        }
    }

    /// The `--on-conflict` values the binary advertises are exactly the ones
    /// `ConflictAction` defines, and `rename` is not among them.
    ///
    /// The matrix's conflict axis is parameterised over
    /// `ConflictAction.allCases`; this is what keeps that from being a claim
    /// about Core alone. An action added to the enum but never wired into
    /// the CLI, or a value the CLI accepts that the enum does not name,
    /// fails here — and the parameterised cases' exhaustive `switch` fails
    /// to compile until someone says what the new action does to the remote
    /// file.
    ///
    /// `rename` is asserted absent because the brief asked for it: there is
    /// no rename-on-conflict anywhere in this project's transfer planning
    /// (`TransferPlan.jobs` has three arms), so it is not an S3 limitation
    /// to gate on — it is a value no backend is ever offered.
    @Test func theConflictActionsAreTheOnesCoreDefines() async throws {
        let rig = try CLIMatrix.make(for: .ssh, label: "conflict-gap")
        defer { rig.tearDown() }
        let binary = try CLIMatrix.binaryURL()
        let fromCore = ConflictAction.allCases.map(\.rawValue)
        for command in ["put", "get"] {
            let advertised = try #require(
                try await CLIMatrix.allowedValues(
                    of: "--on-conflict", for: command, binary: binary),
                "\(command) advertises no value list for --on-conflict")
            #expect(
                advertised == fromCore,
                "\(command) advertises \(advertised); ConflictAction defines \(fromCore)")
        }

        #expect(!fromCore.contains("rename"), "ConflictAction gained rename; the matrix needs it")
        // Through the rig (see `neitherTransferCommandOffersARecursiveFlag`
        // above): the refusal happens before any connect, but `rig.run`
        // still scrubs every backend's secret variable from the child's
        // environment, so this bare parse refusal is not the one call in the
        // file that skips it.
        let refused = try await rig.run(["put", "--on-conflict", "rename", "a", "b"])
        #expect(refused.status != 0, "put accepted --on-conflict rename")
        #expect(refused.stderrText.contains("rename"))
    }
}
