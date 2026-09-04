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
    static func listsASeededFileAsJSON(_ kind: ConnectionKind) async throws {
        let rig = try CLIMatrix.make(for: kind, label: "ls-json")
        defer { rig.tearDown() }
        let fileSystem = try await rig.connect()
        let fileName = "cli-matrix-ls-\(UUID().uuidString).txt"
        let remotePath = rig.remotePath(fileName)
        let payload = Data("cli-matrix listing fixture\n".utf8)

        // `defer` bodies cannot `await`, so the cleanup both exits need is a
        // closure both exits call — the throwing one included. The WebDAV
        // container has no volume: what a case leaves behind stays there
        // until the container is recreated.
        let cleanUp: () async -> Void = {
            await rig.removeRemote(fileSystem, path: remotePath)
            await fileSystem.disconnect()
        }

        do {
            try await rig.seed(fileSystem, path: remotePath, content: payload)

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
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}

// MARK: - One suite per backend

@Suite("CLIMatrixSSH", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixSSHITests {
    static let kind: ConnectionKind = .ssh

    @Test func listsASeededFileAsJSON() async throws {
        try await CLIMatrixCases.listsASeededFileAsJSON(Self.kind)
    }
}

@Suite("CLIMatrixS3", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixS3ITests {
    static let kind: ConnectionKind = .s3

    @Test func listsASeededFileAsJSON() async throws {
        try await CLIMatrixCases.listsASeededFileAsJSON(Self.kind)
    }
}

@Suite("CLIMatrixWebDAV", .enabled(if: rigIsEnabled), .serialized)
struct CLIMatrixWebDAVITests {
    static let kind: ConnectionKind = .webdav

    @Test func listsASeededFileAsJSON() async throws {
        try await CLIMatrixCases.listsASeededFileAsJSON(Self.kind)
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
}
