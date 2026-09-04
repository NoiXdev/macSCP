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

            let refused = try await SubprocessRunner.run(
                binary, arguments: [command, "--recursive", "a", "b"])
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
        let refused = try await SubprocessRunner.run(
            binary, arguments: ["put", "--on-conflict", "rename", "a", "b"])
        #expect(refused.status != 0, "put accepted --on-conflict rename")
        #expect(refused.stderrText.contains("rename"))
    }
}
