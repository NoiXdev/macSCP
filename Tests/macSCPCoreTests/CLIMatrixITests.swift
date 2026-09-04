import Foundation
import Synchronization
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
            // seven subcommands take the connection flags, and `sessions`
            // and `diagnose` do not — so the flag is asked for per command
            // (`CLIMatrix.hostKeyFlags(for:binary:)`, which reads that
            // command's own help). Counted 2026-09-04.
            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "ls", binary: binary)
            let result = try await rig.run(
                ["ls"] + flags + ["--json", rig.target(rig.remoteRoot)])
            // The leak question first, computed before any message below
            // could quote this run's output — its environment carries the
            // backend's secret (CLAUDE.md, "A value a test must not leak
            // has two exits, not one").
            let leaks = rig.leaksSecret(result)
            #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")
            #expect(
                result.status == 0,
                """
                ls failed on \(kind.rawValue) (exit \(result.status), stderr \
                \(result.stderrText.count) bytes)
                """)

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
            // Leak question first — this run's environment carries the
            // backend's secret (CLAUDE.md, "A value a test must not leak
            // has two exits, not one").
            let leaks = rig.leaksSecret(result)
            #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")
            #expect(
                result.status == 0,
                """
                mkdir failed on \(kind.rawValue) (exit \(result.status), stderr \
                \(result.stderrText.count) bytes)
                """)

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
                // Leak question first — this run's environment carries the
                // backend's secret (CLAUDE.md, "A value a test must not leak
                // has two exits, not one").
                let leaks = rig.leaksSecret(result)
                #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")
                #expect(
                    result.status == 0,
                    """
                    put failed on \(kind.rawValue) (exit \(result.status), stderr \
                    \(result.stderrText.count) bytes)
                    """)

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
                // Leak question first — this run's environment carries the
                // backend's secret (CLAUDE.md, "A value a test must not leak
                // has two exits, not one").
                let leaks = rig.leaksSecret(result)
                #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")
                #expect(
                    result.status == 0,
                    """
                    get failed on \(kind.rawValue) (exit \(result.status), stderr \
                    \(result.stderrText.count) bytes)
                    """)

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
                // Leak question first — this run's environment carries the
                // backend's secret (CLAUDE.md, "A value a test must not leak
                // has two exits, not one").
                let leaks = rig.leaksSecret(result)
                #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")

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
                    \(kind.rawValue) (stderr \(result.stderrText.count) bytes)
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
            // Leak question first — this run's environment carries the
            // backend's secret (CLAUDE.md, "A value a test must not leak
            // has two exits, not one").
            let leaks = rig.leaksSecret(result)
            #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")
            #expect(
                result.status == 0,
                """
                rm failed on \(kind.rawValue) (exit \(result.status), stderr \
                \(result.stderrText.count) bytes)
                """)
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
            // Leak question first — this run's environment carries the
            // backend's secret (CLAUDE.md, "A value a test must not leak
            // has two exits, not one").
            let removedLeaks = rig.leaksSecret(removed)
            #expect(removedLeaks == false, "the run printed the secret on \(kind.rawValue)")
            #expect(
                removed.status == 0,
                """
                rm --recursive failed on \(kind.rawValue) (exit \(removed.status), stderr \
                \(removed.stderrText.count) bytes)
                """)
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
            // The leak question comes FIRST, and no message below carries a
            // byte of either stream: every one of these runs has the
            // backend's secret in its environment, and a failure message is
            // the one place a test's own output is read by a person.
            let leaks = rig.leaksSecret(result)
            #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")
            #expect(
                result.status == 0,
                """
                ls --non-interactive exited \(result.status) on \(kind.rawValue), which \
                authenticates no host key
                """)
            #expect(
                try rig.recordedHostKeys().isEmpty,
                "\(kind.rawValue) recorded a host key it has no host keys for")
            return
        }

        let refused = try await rig.run(["ls", "--non-interactive", "--json", target])
        let refusedLeaks = rig.leaksSecret(refused)
        #expect(refusedLeaks == false, "the refused run printed the secret on \(kind.rawValue)")
        #expect(
            refused.status == CLIExitCode.hostKeyUnknown.rawValue,
            "an unknown host key exited \(refused.status) on \(kind.rawValue)")
        // "Refused" and "connected, then complained" are not the same thing,
        // and the exit code alone cannot tell them apart: nothing may have
        // been listed, and nothing may have been remembered.
        let refusedListedNothing = refused.stdoutText.isEmpty
        #expect(refusedListedNothing, "a refused connect listed something on \(kind.rawValue)")
        #expect(
            try rig.recordedHostKeys().isEmpty,
            "a refused connect recorded the host key anyway on \(kind.rawValue)")

        let accepted = try await rig.run(["ls", "--accept-new", "--json", target])
        let acceptedLeaks = rig.leaksSecret(accepted)
        #expect(acceptedLeaks == false, "the accepted run printed the secret on \(kind.rawValue)")
        #expect(
            accepted.status == 0,
            "ls --accept-new exited \(accepted.status) on \(kind.rawValue)")
        // The positive beside the emptiness above: an `ls` that printed
        // nothing at all would satisfy "the refusal listed nothing" for a
        // reason that has nothing to do with the refusal. Counted, not
        // printed.
        let acceptedListed = try CLIMatrix.listing(accepted.stdoutText).count
        #expect(acceptedListed > 0, "the accepted connect listed nothing on \(kind.rawValue)")
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
        let acceptedLeaks = rig.leaksSecret(accepted)
        #expect(acceptedLeaks == false, "the accepted run printed the secret on \(kind.rawValue)")
        #expect(
            accepted.status == 0,
            "ls --accept-new exited \(accepted.status) on \(kind.rawValue)")
        // The positive companion to the emptiness asserted after the plant:
        // this same command, against this same rig, DOES list something
        // while the remembered key is the right one.
        let acceptedListed = try CLIMatrix.listing(accepted.stdoutText).count
        #expect(acceptedListed > 0, "the accepted connect listed nothing on \(kind.rawValue)")

        let planted = try rig.plantADifferentHostKey()
        let refused = try await rig.run(["ls", "--accept-new", "--json", target])
        let refusedLeaks = rig.leaksSecret(refused)
        #expect(refusedLeaks == false, "the refused run printed the secret on \(kind.rawValue)")
        #expect(
            refused.status == CLIExitCode.hostKeyMismatch.rawValue,
            "a changed host key exited \(refused.status) on \(kind.rawValue)")
        let refusedListedNothing = refused.stdoutText.isEmpty
        #expect(refusedListedNothing, "a refused connect listed something on \(kind.rawValue)")

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
        let controlLeaks = rig.leaksSecret(control)
        #expect(controlLeaks == false, "the control run printed the secret on \(kind.rawValue)")
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
        // This is the run that HAS the secret to leak, so its two streams are
        // reduced to `Bool`s and to counts before anything else looks at
        // them, and no expectation below interpolates a byte of either. A
        // failure message quoting the stderr of this run would be the
        // disclosure the case exists to forbid — and it would be printed
        // exactly when someone is reading.
        let deliveredStdoutLeaks = rig.leaksSecret(delivered.stdoutText)
        let deliveredStderrLeaks = rig.leaksSecret(delivered.stderrText)
        #expect(deliveredStdoutLeaks == false, "the delivered run's stdout carries the secret")
        #expect(deliveredStderrLeaks == false, "the delivered run's stderr carries the secret")
        // The label comes from the source type itself, not from a string
        // written here: renaming it moves both sides at once.
        let label = PasswordCommandSecretSource(command: "true").label
        let namedTheHelper = delivered.stderrText.contains(
            "\(CLIMatrix.secretSourceNote)\(label)")
        #expect(
            delivered.status == 0,
            "--password-command did not deliver on \(kind.rawValue) (exit \(delivered.status))")
        #expect(namedTheHelper, "another source answered on \(kind.rawValue)")
        let deliveredListed = try CLIMatrix.listing(delivered.stdoutText).count
        #expect(deliveredListed > 0, "nothing was listed on \(kind.rawValue)")

        let broken = try await rig.runWithoutASecret(
            ["ls"] + flags + ["--json", "--password-command", "exit 3", target])
        let brokenLeaks = rig.leaksSecret(broken)
        let brokenNamedTheHelper = broken.stderrText.contains("\(label) failed")
        #expect(brokenLeaks == false, "the failing run's output carries the secret")
        #expect(
            broken.status == CLIExitCode.auth.rawValue,
            "a failing --password-command exited \(broken.status) on \(kind.rawValue)")
        #expect(brokenNamedTheHelper, "the error does not name the helper on \(kind.rawValue)")
    }

    // MARK: - diagnose

    /// `diagnose <session> --scope ping --json` measures the universal half
    /// of the path to the session's own machine: the resolve, one TCP
    /// connection attempt and the ICMP echo.
    ///
    /// The ids are compared against `DiagnosticStepID`'s own constants, in
    /// order — `--scope ping` names exactly those three, and the resolve is
    /// in every scope (`DiagnosticScope.runs(_:)`).
    ///
    /// **The exit code is derived, not pinned, and the ICMP row is why.**
    /// That cell is a property of the RUNNER: on the implementer's machine
    /// (macOS 15, Darwin 25.6.0, measured 2026-09-04) the echo on loopback
    /// comes back with replies and the command exits 0; a runner whose
    /// sandbox refuses the unprivileged datagram socket reports
    /// `unavailable` — still 0, because `unavailable` is not a problem — and
    /// one that opens the socket and hears nothing reports `failed` and
    /// exits 16. So the case asks Core's own rule what the rows it got
    /// should exit with (`CLIMatrix.expectedExitCode(for:)`, which rebuilds
    /// a report from them and calls `DiagnoseRendering.exitCode(for:)`) and
    /// PRINTS the icmp row, so the log of this run says which of the three
    /// this machine did.
    ///
    /// The two rows that are NOT runner-dependent are asserted outright:
    /// 127.0.0.1 resolves, and the rig's port is listening. Without them a
    /// walk whose every row came back `unavailable` would satisfy
    /// everything else here — the derived exit code included, since that
    /// walk exits 0 too.
    ///
    /// The endpoint is compared against the one the BACKEND derives from the
    /// stored session (`BackendDescriptor.endpoint`), which is what makes
    /// this three cases rather than the same run three times: SSH is
    /// diagnosed at the rig's sshd port, S3 at the MinIO endpoint's and
    /// WebDAV at the vhost's, and a `diagnose` reading the wrong field would
    /// measure a port that merely happens to be open.
    static func diagnosePingMeasuresTheUniversalSteps(_ kind: ConnectionKind) async throws {
        let rig = try CLIMatrix.make(for: kind, label: "diagnose-ping")
        defer { rig.tearDown() }

        let result = try await rig.run(
            ["diagnose", rig.session.name, "--scope", "ping", "--json", "--verbose"])
        // The leak question first, computed before any message below could
        // quote this run's output: its environment carries the backend's
        // secret (CLAUDE.md, "A value a test must not leak has two exits").
        let leaks = rig.leaksSecret(result)
        #expect(leaks == false, "the run printed the secret on \(kind.rawValue)")

        let (streamed, summary) = try CLIMatrix.diagnosis(result.stdoutText)
        #expect(
            streamed.map(\.id) == [
                DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
            ], "the ping scope printed \(streamed.map(\.id)) on \(kind.rawValue)")
        // The rows the observer streamed and the rows the summary carries are
        // one measurement printed twice; a summary built from anything else
        // would be a second answer nobody reading the output could tell from
        // the first.
        #expect(summary.steps == streamed, "the summary disagrees with the rows it followed")
        #expect(summary.completion == CLIMatrix.completionKey(for: .complete))

        let ok = try #require(CLIMatrix.outcomeKey(for: .ok))
        let resolve = try #require(streamed.first { $0.id == DiagnosticStepID.resolve })
        let tcp = try #require(streamed.first { $0.id == DiagnosticStepID.tcp })
        let icmp = try #require(streamed.first { $0.id == DiagnosticStepID.icmp })
        #expect(resolve.outcome == ok, "the rig's host did not resolve on \(kind.rawValue)")
        #expect(tcp.outcome == ok, "the rig's port refused the connection on \(kind.rawValue)")
        // The runner-dependent row: recorded, not asserted — see the doc
        // comment. It carries no secret to print; `detail` is the echo's own
        // reply counts.
        print("""
            CLIMatrix: diagnose --scope ping on \(kind.rawValue) — exit \(result.status), \
            icmp \(icmp.outcome), \(icmp.reason ?? icmp.detail)
            """)

        let expected = try CLIMatrix.expectedExitCode(for: streamed)
        #expect(
            result.status == expected,
            "diagnose exited \(result.status) on \(kind.rawValue) for rows Core exits \(expected) for")

        // `--verbose` says which secret source answered, and this scope
        // asked none — so the line is absent rather than reporting "none",
        // which reads as a finding about the session's credential when it
        // means nothing looked (`DiagnosticScope.resolvesASecret`). The
        // POSITIVE that keeps this negative from going quietly stale sits in
        // `diagnoseDial` below, on the same backend and the same flag: there
        // the line must be present.
        let noted = result.stderrText.contains(CLIMatrix.secretSourceNote)
        #expect(noted == false, "the ping scope reported a secret source on \(kind.rawValue)")

        var values = rig.descriptor.editBaseline
        values.merge(rig.descriptor.sessionValues(rig.session))
        let backendEndpoint = try #require(
            rig.descriptor.endpoint(values), "\(kind.rawValue) derives no endpoint at all")
        let named = try #require(summary.endpoint, "the summary named no endpoint")
        #expect(
            named.host == backendEndpoint.host && named.port == backendEndpoint.port,
            "the diagnosis measured \(named.host):\(named.port) on \(kind.rawValue)")
    }

    /// `diagnose <session> --scope dial --json` runs the backend's OWN
    /// connection attempt — and the host key is the one thing it will not
    /// decide.
    ///
    /// Three measurements on a store that starts empty:
    ///
    /// 1. A backend that authenticates a host key (`CLIMatrix.hasHostKeys`)
    ///    comes back `failed` against a fresh store, with the sentence Core
    ///    writes for a refused key, and exits 16. The dial answers the
    ///    host-key question with `HostKeyDecider.refusing`
    ///    (`DialProbes.sshConnect`), unconditionally, and `diagnose`
    ///    advertises no `--accept-new` that could change it
    ///    (`theConnectionFlagsAreAskedForPerCommand`). The store is read
    ///    afterwards and must STILL be empty: a probe that TOFU'd on the
    ///    user's behalf would be writing a consent nobody gave, and it would
    ///    satisfy every other assertion here.
    /// 2. The key is then remembered the way the rest of the matrix
    ///    remembers it — one `ls --accept-new` run, the command
    ///    `anUnknownHostKeyIsRefusedUntilAccepted` measures that acceptance
    ///    on — and exactly one key lands on file.
    /// 3. The same diagnosis, unchanged, now comes back `ok` and exits 0.
    ///
    /// A backend with no host keys has nothing to refuse: its dial is `ok`
    /// on the fresh store already and records nothing. That branch is not a
    /// bare `return` for the reason the host-key case states — a gate stuck
    /// at `true` must fail on S3 and WebDAV, not merely skip them.
    static func diagnoseDialMeasuresTheBackendsOwnConnect(_ kind: ConnectionKind) async throws {
        let rig = try CLIMatrix.make(for: kind, label: "diagnose-dial")
        defer { rig.tearDown() }
        let ok = try #require(CLIMatrix.outcomeKey(for: .ok))
        #expect(try rig.recordedHostKeys().isEmpty, "a fresh store already knows a host key")

        let fresh = try await diagnoseDial(rig)
        if try rig.hasHostKeys(operation: "the diagnose host-key refusal") {
            // The reason is Core's own sentence for a refused key, asked for
            // rather than transcribed: a reworded refusal moves this with it.
            let failed = try #require(CLIMatrix.outcomeKey(for: .failed("")))
            let refusal = DialSupport.reason(for: HostKeyError.rejectedByUser)
            #expect(
                fresh.dial.outcome == failed,
                "an unknown host key came back \(fresh.dial.outcome) on \(kind.rawValue)")
            #expect(fresh.dial.reason == refusal, "the dial refused for another reason")
            #expect(
                fresh.status == CLIExitCode.diagnosis.rawValue,
                "a failed dial exited \(fresh.status) on \(kind.rawValue)")
            let recordedByTheDiagnosis = try rig.recordedHostKeys()
            #expect(
                recordedByTheDiagnosis.isEmpty,
                "the diagnosis remembered \(recordedByTheDiagnosis.count) host key(s)")

            let binary = try CLIMatrix.binaryURL()
            let flags = try await CLIMatrix.hostKeyFlags(for: "ls", binary: binary)
            let accepted = try await rig.run(
                ["ls"] + flags + ["--json", rig.target(rig.remoteRoot)])
            let acceptedLeaks = rig.leaksSecret(accepted)
            #expect(acceptedLeaks == false, "the accepting run printed the secret")
            #expect(
                accepted.status == 0,
                "ls --accept-new exited \(accepted.status) on \(kind.rawValue)")
            let remembered = try rig.recordedHostKeys()
            #expect(remembered.count == 1, "--accept-new recorded \(remembered.count) host keys")
        } else {
            #expect(
                fresh.dial.outcome == ok,
                "the dial came back \(fresh.dial.outcome) on \(kind.rawValue)")
            #expect(fresh.status == 0, "the dial exited \(fresh.status) on \(kind.rawValue)")
            #expect(
                try rig.recordedHostKeys().isEmpty,
                "\(kind.rawValue) recorded a host key it has no host keys for")
        }

        let known = try await diagnoseDial(rig)
        #expect(
            known.dial.outcome == ok,
            "the dial came back \(known.dial.outcome) on \(kind.rawValue) with the key known")
        #expect(known.status == 0, "the dial exited \(known.status) on \(kind.rawValue)")
    }

    /// One `--scope dial` run, decoded: the two rows it must print, the exit
    /// code Core's rule gives for them, and the dial row itself for the
    /// caller to read.
    ///
    /// Shared by the two runs above so the shape is asserted on both — the
    /// second one is the interesting one and would otherwise be checked less
    /// than the first.
    private static func diagnoseDial(_ rig: CLIMatrix) async throws
        -> (dial: CLIDiagnosedStep, status: Int32)
    {
        let result = try await rig.run(
            ["diagnose", rig.session.name, "--scope", "dial", "--json", "--verbose"])
        let leaks = rig.leaksSecret(result)
        #expect(leaks == false, "the dial run printed the secret on \(rig.kind.rawValue)")
        // The positive half of the ping case's absence: this scope DOES ask
        // a secret source, so `--verbose` names one. Which one is not
        // asserted — the two HTTP dials answer without a credential at all
        // and leave the chain on its "none" label, which is the honest
        // answer to "who answered" and still a line that was printed.
        let noted = result.stderrText.contains(CLIMatrix.secretSourceNote)
        #expect(noted, "the dial scope reported no secret source on \(rig.kind.rawValue)")

        let (streamed, summary) = try CLIMatrix.diagnosis(result.stdoutText)
        #expect(
            streamed.map(\.id) == [DiagnosticStepID.resolve, DiagnosticStepID.dial],
            "the dial scope printed \(streamed.map(\.id)) on \(rig.kind.rawValue)")
        #expect(summary.steps == streamed, "the summary disagrees with the rows it followed")
        let expected = try CLIMatrix.expectedExitCode(for: streamed)
        #expect(
            result.status == expected,
            """
            diagnose exited \(result.status) on \(rig.kind.rawValue) for rows Core exits \
            \(expected) for
            """)
        let dial = try #require(
            streamed.first { $0.id == DiagnosticStepID.dial },
            "the dial scope printed no dial row on \(rig.kind.rawValue)")
        // Recorded for the same reason the ping case records its icmp row:
        // the caller runs this twice, and which of the two runs produced
        // which exit code is the whole measurement.
        print("""
            CLIMatrix: diagnose --scope dial on \(rig.kind.rawValue) — exit \(result.status), \
            dial \(dial.outcome), \(dial.reason ?? dial.detail)
            """)
        return (dial, result.status)
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

    @Test func diagnosePingMeasuresTheUniversalSteps() async throws {
        try await CLIMatrixCases.diagnosePingMeasuresTheUniversalSteps(Self.kind)
    }

    @Test func diagnoseDialMeasuresTheBackendsOwnConnect() async throws {
        try await CLIMatrixCases.diagnoseDialMeasuresTheBackendsOwnConnect(Self.kind)
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

    @Test func diagnosePingMeasuresTheUniversalSteps() async throws {
        try await CLIMatrixCases.diagnosePingMeasuresTheUniversalSteps(Self.kind)
    }

    @Test func diagnoseDialMeasuresTheBackendsOwnConnect() async throws {
        try await CLIMatrixCases.diagnoseDialMeasuresTheBackendsOwnConnect(Self.kind)
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

    @Test func diagnosePingMeasuresTheUniversalSteps() async throws {
        try await CLIMatrixCases.diagnosePingMeasuresTheUniversalSteps(Self.kind)
    }

    @Test func diagnoseDialMeasuresTheBackendsOwnConnect() async throws {
        try await CLIMatrixCases.diagnoseDialMeasuresTheBackendsOwnConnect(Self.kind)
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

// MARK: - diagnose, the runs that are not per backend

/// The `diagnose` cases that no backend axis applies to: the trace, which
/// walks a PATH and not a protocol, and the two refusals, which never reach a
/// connect at all.
///
/// An SSH rig supplies both the coordinates and the environment. The
/// coordinates are read off the rig's own session (`BackendDescriptor
/// .endpoint`), so this file writes no host and no port; the environment is
/// `rig.run`'s, which removes every backend's secret variable and sets only
/// this one's — which is what keeps the refusals, the two children here that
/// connect to nothing, from being the ones that inherit a developer's
/// exported `AWS_SECRET_ACCESS_KEY`.
@Suite("CLIMatrixDiagnose", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixDiagnoseITests {
    /// `diagnose --host … --scope trace --json` reports the path as hops,
    /// each carrying the four cells the trace table writes and an ending
    /// that table has a word for.
    ///
    /// **The hop COUNT is not asserted, and could not honestly be.** A trace
    /// to the loopback address ends at its first hop here (measured
    /// 2026-09-04: one hop, `destination`); a runner that refuses the socket
    /// the walk needs reports `unavailable` and carries no table at all; and
    /// either is a correct answer about the machine it ran on. The count is
    /// printed instead, so the log says which this run got.
    ///
    /// What IS asserted is the shape, and it is derived on both sides: a
    /// hop's keys are the trace table's own columns through the same
    /// `DiagnosticReport.header` derivation the renderer applies, and every
    /// hop's outcome cell is one of the words
    /// `ConnectionDiagnostics.traceTable(_:)` writes
    /// (`CLIMatrix.namedHopOutcomes` — the three constants plus every
    /// `unreachable (code N)`, expanded rather than prefix-matched). A cell
    /// that went empty, or that started carrying a raw error, is red.
    ///
    /// `hops` is REQUIRED of a trace that came back `ok`: a successful trace
    /// with no table is a row that says the path was walked and nothing
    /// about where it went.
    @Test func theTraceReportsItsHopsWithANamedEnding() async throws {
        let rig = try CLIMatrix.make(for: .ssh, label: "diagnose-trace")
        defer { rig.tearDown() }
        let endpoint = try Self.rigEndpoint(rig)

        let result = try await rig.run([
            "diagnose", "--host", endpoint.host, "--port", "\(endpoint.port)",
            "--scope", "trace", "--json",
        ])
        let leaks = rig.leaksSecret(result)
        #expect(leaks == false, "the trace run printed the secret")

        let (streamed, summary) = try CLIMatrix.diagnosis(result.stdoutText)
        #expect(
            streamed.map(\.id) == [DiagnosticStepID.resolve, DiagnosticStepID.trace],
            "the trace scope printed \(streamed.map(\.id))")
        #expect(summary.steps == streamed, "the summary disagrees with the rows it followed")
        let named = try #require(summary.endpoint, "the summary named no endpoint")
        #expect(
            named.host == endpoint.host && named.port == endpoint.port,
            "the --host form measured \(named.host):\(named.port)")
        let expected = try CLIMatrix.expectedExitCode(for: streamed)
        #expect(
            result.status == expected,
            "diagnose exited \(result.status) for rows Core exits \(expected) for")

        let trace = try #require(streamed.first { $0.id == DiagnosticStepID.trace })
        print("""
            CLIMatrix: diagnose --scope trace — \(trace.outcome), \
            \(trace.hops?.count ?? 0) hop(s)
            """)
        guard trace.outcome == CLIMatrix.outcomeKey(for: .ok) else { return }
        let hops = try #require(trace.hops, "an ok trace carried no hops at all")
        for hop in hops {
            #expect(
                Set(hop.keys) == CLIMatrix.hopKeys,
                "a hop carries \(Set(hop.keys).sorted()), not the trace table's columns")
            let ending = hop[DiagnosticReport.header(DiagnosticTraceColumn.outcome)] ?? ""
            #expect(
                CLIMatrix.namedHopOutcomes.contains(ending),
                "a hop ended in '\(ending)', which the trace table has no word for")
        }
    }

    /// Rows print AS EACH STEP FINISHES — the design `diagnose` exists for
    /// (`ConnectionDiagnostics.run(scope:onStep:)`, streamed straight to
    /// `OutputFormatter.print(step:asJSON:)`) — and not all at once when the
    /// process is about to end. `Swift.print` writes through C `stdout`,
    /// which is block-buffered whenever its destination is not a terminal —
    /// exactly what this test's pipe is — so without a fix nothing reaches
    /// the reader until either a few KB have accumulated or the child exits
    /// and libc's own `exit()` flushes the buffer as its last act before
    /// dying. `DiagnoseCommand.run()` line-buffers `stdout` at its own top
    /// for exactly this reason.
    ///
    /// Measured as a FLOOR, never a ceiling (CLAUDE.md, "A wall-clock
    /// ceiling in a test measures the runner"): the assertion is a COUNT,
    /// not an elapsed time — `chunkCount > 1`, read through
    /// `SubprocessRunner`'s `onStdoutChunk` seam (never a raw `Process` of
    /// this suite's own; CLAUDE.md, "every child in tests through
    /// `SubprocessRunner`"), never a clock anywhere in this case.
    ///
    /// **This is NOT "did the first row beat the child's own exit" — that
    /// was tried first and measured to hold on BOTH sides of the fix.**
    /// `Foundation.exit()`'s libc teardown flushes stdio and only THEN
    /// tears the process down, so the pipe write that carries a
    /// block-buffered child's one giant chunk always completes — and so
    /// becomes visible to this reader — a hair before the kernel's
    /// process-death notification reaches `Process.terminationHandler`.
    /// Measured directly (`.build/debug/macscp-cli diagnose --host
    /// 127.0.0.1 --port 2222 --scope complete --json` piped to a raw
    /// `os.read` loop, 2026-09-04): WITHOUT the fix, exactly ONE chunk of
    /// 1126 bytes arrives, and an ordering check built the way the
    /// original brief asked for it read `true` regardless — a check that
    /// cannot go red is not a check, it is decoration. WITH the fix, the
    /// same run produces SIX chunks (73, 88, 114, 109, 139, 603 bytes),
    /// one flush per row plus the summary, which is the actual property
    /// "rows print as each step finishes" is a claim about. Chunk COUNT is
    /// what tells the two apart; chunk ORDER against the exit does not, so
    /// this asserts the former.
    ///
    /// `--scope complete` is the scope with the most steps (resolve, TCP,
    /// ICMP, trace, dial, contributions, plus the summary line) — the
    /// widest margin between "one chunk" and "several".
    ///
    /// Red without the `setvbuf` fix in `DiagnoseCommand.run()`: RESULT —
    /// `chunkCount == 1` (measured against the rig 2026-09-04, matching the
    /// raw-pipe measurement above). Green with the fix: `chunkCount == 6`
    /// on the same run, same rig.
    @Test func rowsArriveInMoreThanOneChunk() async throws {
        let rig = try CLIMatrix.make(for: .ssh, label: "diagnose-streaming")
        defer { rig.tearDown() }
        let endpoint = try Self.rigEndpoint(rig)

        // Counts non-empty stdout reads only — the empty chunk that marks
        // EOF is not a row and would inflate a broken run's count from 1 to
        // 2, right where this floor is drawn.
        let chunkCount = Mutex(0)

        let result = try await rig.run(
            [
                "diagnose", "--host", endpoint.host, "--port", "\(endpoint.port)",
                "--scope", "complete", "--json",
            ],
            onStdoutChunk: { chunk in
                guard !chunk.isEmpty else { return }
                chunkCount.withLock { $0 += 1 }
            })

        let leaks = rig.leaksSecret(result)
        #expect(leaks == false, "the streaming run printed the secret")

        let count = chunkCount.withLock { $0 }
        #expect(
            count > 1,
            """
            --scope complete's stdout arrived in \(count) chunk(s) — a \
            block-buffered child delivers its whole run as one, only at \
            the end, instead of one flush per row as it lands
            """)

        let (streamed, summary) = try CLIMatrix.diagnosis(result.stdoutText)
        #expect(!streamed.isEmpty, "the streaming run measured nothing")
        #expect(summary.steps == streamed, "the summary disagrees with the rows it followed")
    }

    /// The two refusals a diagnosis makes before measuring anything, and the
    /// exit code that says "you asked for the wrong thing" rather than "the
    /// path is broken".
    ///
    /// * A session name the store does not hold → `SessionReferenceError`
    ///   through `CLIErrorMapping`, exit 2.
    /// * `--host` with a scope whose only step beyond the resolve
    ///   authenticates → `DiagnoseUsageError.scopeNeedsASession`, exit 2: a
    ///   bare endpoint names no Keychain slot for a secret source to answer
    ///   for, so the row would say nothing was measured and nothing else.
    ///
    /// **The positive beside the two negatives**, and it is not decoration:
    /// the same `--host` with a scope Core permits is NOT refused, and it
    /// prints rows. Without that, a build that refused every `--host` form
    /// would satisfy both refusals above — and the refusal is about the
    /// scope, not about the flag.
    ///
    /// Which scopes fall on which side is read from
    /// `DiagnoseUsageError.refusal(forEndpointScope:)` — Core's own
    /// exhaustive switch — rather than chosen here, and both messages come
    /// from `CLIErrorMapping.message(for:)` asked about the very error each
    /// refusal throws, so a reworded sentence moves both sides at once.
    ///
    /// Neither refusal reaches a connect, and both still go through
    /// `rig.run` (see `neitherTransferCommandOffersARecursiveFlag` for the
    /// same reasoning): the child's environment is scrubbed by construction.
    @Test func theUsageRefusalsExitTwoWithoutMeasuringAnything() async throws {
        let rig = try CLIMatrix.make(for: .ssh, label: "diagnose-usage")
        defer { rig.tearDown() }
        let usage = CLIExitCode.usage.rawValue
        let endpoint = try Self.rigEndpoint(rig)

        let missing = "no-such-session-\(UUID().uuidString)"
        let unknown = try await rig.run(["diagnose", missing, "--scope", "ping", "--json"])
        let unknownLeaks = rig.leaksSecret(unknown)
        #expect(unknownLeaks == false, "the refused run printed the secret")
        #expect(unknown.status == usage, "an unknown session exited \(unknown.status)")
        #expect(unknown.stdoutText.isEmpty, "a refused diagnosis printed rows anyway")
        #expect(
            unknown.stderrText.contains(
                CLIErrorMapping.message(for: SessionReferenceError.unknown(missing))),
            "the refusal does not name the session that was not found")

        // The refused scope and the permitted one both come from Core's own
        // split, so a scope that changed sides moves this case with it.
        let refusedScope = try #require(
            DiagnosticScope.allCases.first {
                DiagnoseUsageError.refusal(forEndpointScope: $0) != nil
            }, "no scope needs a session at all")
        let permittedScope = try #require(
            DiagnosticScope.allCases.first {
                DiagnoseUsageError.refusal(forEndpointScope: $0) == nil
            }, "every scope needs a session")

        let refused = try await rig.run([
            "diagnose", "--host", endpoint.host, "--scope", refusedScope.rawValue,
        ])
        let refusedLeaks = rig.leaksSecret(refused)
        #expect(refusedLeaks == false, "the refused run printed the secret")
        #expect(
            refused.status == usage,
            "--host --scope \(refusedScope.rawValue) exited \(refused.status)")
        #expect(refused.stdoutText.isEmpty, "a refused diagnosis printed rows anyway")
        let refusal = try #require(DiagnoseUsageError.refusal(forEndpointScope: refusedScope))
        #expect(
            refused.stderrText.contains(CLIErrorMapping.message(for: refusal)),
            "the refusal does not name the scope it refused")

        let measured = try await rig.run([
            "diagnose", "--host", endpoint.host, "--scope", permittedScope.rawValue, "--json",
        ])
        let measuredLeaks = rig.leaksSecret(measured)
        #expect(measuredLeaks == false, "the permitted run printed the secret")
        #expect(
            measured.status != usage,
            "--host --scope \(permittedScope.rawValue) was refused too")
        let (streamed, _) = try CLIMatrix.diagnosis(measured.stdoutText)
        #expect(!streamed.isEmpty, "the permitted --host scope measured nothing")
    }

    /// The rig's own coordinates as an endpoint, through the backend that
    /// owns them — the same merge `DiagnoseCommand` does for a stored
    /// session (`editBaseline`, then the record). Nothing here spells a host
    /// or a port.
    private static func rigEndpoint(_ rig: CLIMatrix) throws -> Endpoint {
        var values = rig.descriptor.editBaseline
        values.merge(rig.descriptor.sessionValues(rig.session))
        return try #require(
            rig.descriptor.endpoint(values), "\(rig.kind.rawValue) derives no endpoint")
    }
}

// MARK: - What makes the matrix a matrix

/// The derivation guards. None of these needs the rig or the binary, so they
/// run in the ordinary `swift test` — which is where a fourth backend, or an
/// eighth subcommand, is actually going to be added (the seventh, `diagnose`,
/// arrived on 2026-09-04).
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
        // The NAMES, not a count written here: three static constants sit
        // beside this, and a number would be a fourth copy of them that
        // nothing keeps in step.
        #expect(
            Set(try store.allGroups().map(\.name)) == Set(CLISessionCatalogFixture.groupNames))
        #expect(
            try store.allGroups().count == CLISessionCatalogFixture.groupNames.count,
            "the fixture wrote a duplicate group name")
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
    /// The positive: the real drives ARE found. A scan that returned nothing
    /// satisfies every absence above.
    ///
    /// The fixture itself is `CLIMatrix.drivenScanFixture`, in the helper
    /// file, and it is there for a reason this test cannot state about
    /// itself: the file-level scan reads THIS file, so a fixture written
    /// here would put its command names into the driven set from a string
    /// literal — and `everySubcommandTheBinaryOffersIsDrivenByACase` would
    /// then count a command no case drives. Measured 2026-09-04 with
    /// `scripts/mutation-probe` (the real `mkdir` case and its three
    /// wrappers deleted): GREEN with the fixture here, RED with it in the
    /// helper. Nothing in this test spells a subcommand name either — the
    /// expected set lives beside the fixture, so the two cannot drift apart.
    @Test func theDrivenScanReadsCallsAndNotComments() throws {
        #expect(
            try CLIMatrix.drivenSubcommands(inSource: CLIMatrix.drivenScanFixture)
                == CLIMatrix.drivenScanFixtureNames)
        #expect(!CLIMatrix.drivenScanFixtureNames.isEmpty, "the fixture expects nothing at all")
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
    /// help wraps — all seven rows fit, the widest still `get`'s at 72
    /// columns (recounted 2026-09-04, with `diagnose` at 69) — so this
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
    /// through a fixture's own `run` and ignores comment lines). So an EIGHTH
    /// subcommand turns this red the day it is added — which is the guard
    /// this matrix existed without until now, and the reason `sessions` could
    /// have gone uncovered through two green tasks. It did exactly that on
    /// 2026-09-04: the seventh, `diagnose`, arrived in one commit and left
    /// this red until the cases above drove it.
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
    /// TWO subcommands declare their own option group rather than
    /// `GlobalOptions`, and for the same reason. `sessions` takes
    /// `JSONOptions` (`Sources/MacSCPCLI/SessionsCommand.swift`) because it
    /// opens no connection and resolves no secret; `diagnose` takes
    /// `DiagnoseOptions` (`Sources/MacSCPCLI/DiagnoseCommand.swift`) because
    /// it resolves a secret but decides no host key — its dial answers that
    /// question with `HostKeyDecider.refusing` inside Core, so
    /// `--accept-new` would be advertised and never read.
    ///
    /// So this asserts BOTH halves — `hostKeyFlags` gives `ls` the flag and
    /// gives those two nothing — and then the reason: the binary really does
    /// refuse the flag it does not declare. Without those runs the two
    /// halves would only be agreeing with each other about a help screen.
    ///
    /// The list at the end is SORTED, not in the binary's help order: which
    /// commands answer no is the claim, and reordering the subcommands is
    /// not a change to it.
    @Test func theConnectionFlagsAreAskedForPerCommand() async throws {
        let binary = try CLIMatrix.binaryURL()
        #expect(try await CLIMatrix.hostKeyFlags(for: "ls", binary: binary) == ["--accept-new"])
        #expect(try await CLIMatrix.hostKeyFlags(for: "sessions", binary: binary) == [])
        #expect(try await CLIMatrix.hostKeyFlags(for: "diagnose", binary: binary) == [])

        // The `diagnose` probe needs a TARGET, and the reason is worth
        // writing down: ArgumentParser reports a `validate()` complaint
        // before an unknown option, so `macscp-cli diagnose --accept-new`
        // alone answers "Name a stored session, or pass --host" and exits 64
        // without ever mentioning the flag (measured 2026-09-04). A probe
        // that read THAT as the refusal would pass for a build that accepted
        // `--accept-new` happily. `sessions` takes no argument, so its
        // vector is the bare one.
        //
        // Through `rig.run`, like the other guards in this suite, so the
        // child's environment is scrubbed; and the subcommand name comes out
        // of `probes` rather than sitting as a literal after `run([`, so
        // this guard does not enter `CLIMatrix.drivenSubcommands`'s driven
        // set (see that function's doc comment).
        let rig = try CLIMatrix.make(for: .ssh, label: "connection-flags")
        defer { rig.tearDown() }
        let probes = [["sessions", "--accept-new"], ["diagnose", rig.session.name, "--accept-new"]]
        for probe in probes {
            let refused = try await rig.run(probe)
            #expect(refused.status != 0, "\(probe[0]) accepted a flag it does not declare")
            #expect(
                refused.stderrText.contains("--accept-new"),
                "\(probe[0]) refused --accept-new without naming it")
        }

        // Counted rather than asserted as a number: every subcommand the
        // binary offers is asked, and the ones that answer no are named.
        let names = try await CLIMatrix.subcommands(binary: binary)
        var without: [String] = []
        for name in names where try await !CLIMatrix.takesConnectionFlags(name, binary: binary) {
            without.append(name)
        }
        #expect(
            without.sorted() == ["diagnose", "sessions"],
            "the commands without the connection flags moved")
    }

    /// Neither transfer command offers `--recursive`, and the binary refuses
    /// it rather than ignoring it.
    ///
    /// This is where the brief's `put --recursive` and `get --recursive`
    /// rows land: the flags do not exist. `TransferSourceError.isDirectory`'s
    /// own doc comment says why — "The CLI's `get`/`put` are single-file
    /// transfers only; recursive directory transfers are the GUI queue's
    /// job" — so the gap is a decision, not an oversight, and this pins it
    /// as one.
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
        // file that skips it. `command` is a variable, not a literal string
        // right after `run([`, so this guard does not enter
        // `CLIMatrix.drivenSubcommands`'s driven set the way a real case's
        // drive does — see that function's doc comment for the rule.
        let command = "put"
        let refused = try await rig.run([command, "--on-conflict", "rename", "a", "b"])
        #expect(refused.status != 0, "\(command) accepted --on-conflict rename")
        #expect(refused.stderrText.contains("rename"))
    }
}
