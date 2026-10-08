import Foundation
import Testing

@testable import macSCPCore

/// A channel that records what it was asked to run. Exists so everything
/// above the seam is testable with no server at all.
final actor RecordingArchiveChannel: ArchiveCommandChannel {
    private(set) var lines: [String] = []
    private(set) var stdins: [Data?] = []
    private(set) var listedLines: [String] = []
    private(set) var listedLimits: [Int] = []
    private let exitStatus: Int
    private let listingEntries: [String]

    init(exitStatus: Int = 0, listingEntries: [String] = []) {
        self.exitStatus = exitStatus
        self.listingEntries = listingEntries
    }

    func run(_ line: ArchiveCommandLine, stdin: Data?) async throws -> Int {
        lines.append(line.text)
        stdins.append(stdin)
        return exitStatus
    }

    func listing(of line: ArchiveCommandLine, limit: Int) async throws -> [String] {
        listedLines.append(line.text)
        listedLimits.append(limit)
        return listingEntries
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ArchiveCommandChannelTests {
    @Test func aChannelIsHandedTheLineAndTheBytesSeparately() async throws {
        let channel = RecordingArchiveChannel()
        let plan = try ArchivePlan.compress(
            .tarGz,
            selection: [RemoteFileItem(name: "a b", path: "/d/a b", kind: .file)],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
        #expect(status == 0)
        #expect(await channel.lines == ["cd '/d' && tar --null -T - -czf './out.tar.gz'"])
        #expect(await channel.stdins == [Data("a b\0".utf8)])
    }

    /// The second requirement exists from the start, although Task 7 is the
    /// first caller: adding it later would mean editing every fake in two
    /// finished test files, and a reviewer cannot tell a deliberate
    /// extension from a forgotten one.
    @Test func alistingIsHandedTheLineAndTheBoundSeparately() async throws {
        let channel = RecordingArchiveChannel(listingEntries: ["a b", "c/"])
        let plan = try ArchivePlan.compress(
            .tarGz,
            selection: [RemoteFileItem(name: "a b", path: "/d/a b", kind: .file)],
            workingDirectory: "/d", archiveName: "out.tar.gz")
        let entries = try await channel.listing(of: plan.remoteCommandLine(), limit: 4096)
        #expect(entries == ["a b", "c/"])
        #expect(await channel.listedLines == ["cd '/d' && tar --null -T - -czf './out.tar.gz'"])
        #expect(await channel.listedLimits == [4096])
    }

    @Test func exit127IsReadAsAMissingTool() {
        #expect(ArchiveCommandExitFailure(exitCode: 127).isToolMissing)
        #expect(ArchiveCommandExitFailure(exitCode: 1).isToolMissing == false)
    }
}

/// The rig half: a real `exec` channel over the Docker SSH server, with real
/// `tar`, `zip` and `unzip` on the far side.
///
/// Runs only with MACSCP_ITEST=1 and a running Docker test server
/// (`docker compose -f docker/test-server/compose.yml up -d`, from the MAIN
/// checkout — the seed mount is relative to the compose file).
///
/// What only a real far side can show: that bytes written to an `exec`
/// channel reach a tool's standard input, that the tool sees END-OF-INPUT
/// and therefore terminates at all, and that a far side which exits BEFORE
/// reading its standard input still reports its own exit status rather than
/// a channel error raised by the half-close.
///
/// The bounds here are `.timeLimit`, which is a hang bound and not a
/// wall-clock ceiling on an assertion: a regression in this seam does not
/// return a wrong answer, it never returns.
@Suite(
    "An archive command over the Docker SSH server",
    .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct ArchiveCommandChannelRigTests {
    private func connect() async throws -> CitadelFileSystem {
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnownHostsStore(directory: directory)
        let make = {
            try await CitadelFileSystem.connect(
                config: config, connectTimeout: .seconds(30), knownHosts: store,
                onUnknownHostKey: .asking { _ in true })
        }
        // Cushions the container's reconnect throttling, like every other
        // gated suite here.
        do {
            return try await make()
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return try await make()
        }
    }

    private func upload(_ bytes: Data, to path: String, over fs: CitadelFileSystem) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(bytes)
        continuation.finish()
        try await fs.write(path: path, contents: stream)
    }

    @Test("a selection reaches the far side through stdin and the archive appears")
    func aselectionReachesTheFarSideThroughStdinAndTheArchiveAppears() async throws {
        let fs = try await connect()
        let home = try await fs.homeDirectoryPath()
        let dir = home + "/archive-itest-\(UUID().uuidString)"
        defer {
            Task {
                try? await fs.deleteTree(at: dir)
                await fs.disconnect()
            }
        }
        try await fs.createDirectory(at: dir)
        // A name no shell could survive unquoted, written through SFTP so
        // the test does not depend on the thing it is testing.
        let awkward = "it's a $(test) file"
        try await upload(Data("payload\n".utf8), to: dir + "/" + awkward, over: fs)

        let plan = try ArchivePlan.compress(
            .tarGz,
            selection: [RemoteFileItem(name: awkward, path: dir + "/" + awkward, kind: .file)],
            workingDirectory: dir, archiveName: "out.tar.gz")
        let channel = try #require(fs as (any ArchiveCommandChannel)?)
        let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)

        #expect(status == 0)
        let listed = try await fs.list(path: dir).map(\.name)
        #expect(listed.contains("out.tar.gz"))
        // The awkward name still exists, i.e. nothing executed it away.
        #expect(listed.contains(awkward))

        // And the archive holds the SELECTION, which is the claim the case
        // is named for. Without this the case passes when nothing at all is
        // written to standard input: `tar --null -T -` reading an empty
        // list writes an empty archive and exits 0, so the two expectations
        // above are satisfied by a run that carried no selection. Measured
        // with `scripts/mutation-probe` on 2026-10-08: the no-stdin plant
        // was caught only by the listing case until this arrived.
        let inside = ArchivePlan(
            operation: .extract(.tarGz), workingDirectory: dir,
            tool: "tar", words: [.flag("-tzf"), .operand("./out.tar.gz")], stdin: nil)
        let entries = try await channel.listing(of: inside.remoteCommandLine(), limit: 64 * 1024)
        #expect(entries == [awkward])
    }

    /// A tool the far side does not have exits 127 WHILE macSCP is still
    /// writing the name list, so OpenSSH sends CHANNEL_EOF mid-write and the
    /// half-close then runs in `.halfClosedRemote`, where `sendChannelEOF`
    /// throws. If the closure lets that throw out, the caller sees a channel
    /// error and `isToolMissing` never sees 127 — the masking
    /// `0.12.1-noix.4` exists to remove, returning by another path.
    @Test("a missing tool is reported 127 even while stdin is still being written")
    func amissingToolIsReported127EvenWhileStdinIsStillBeingWritten() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let channel = try #require(fs as (any ArchiveCommandChannel)?)
        let home = try await fs.homeDirectoryPath()
        // Big enough that the write is STILL IN FLIGHT when the far side
        // gives up: the overlap is the whole point of the case, and the
        // count is measured rather than guessed. At 20_000 names (~218 kB)
        // this case passed with the tolerance REMOVED — the write and the
        // half-close both completed before the far side's 127 came back, so
        // it discriminated nothing. At 400_000 (~5.2 MB, past the session
        // channel's outbound window) it is red the moment either call is
        // allowed to throw out of the closure: `ChannelError.eof` from the
        // write, `ChannelError.alreadyClosed` from the half-close. Both
        // measured 2026-10-08 with `scripts/mutation-probe` against the
        // Docker rig; the derivation is in this task's report.
        let manyNames = Data(
            (0..<400_000).map { "name-\($0)" }.joined(separator: "\n").utf8)
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: home,
            tool: "macscp-no-such-archiver",
            words: [.flag("-r"), .flag("-@"), .operand("./out.zip")],
            stdin: manyNames)
        await #expect(throws: ArchiveCommandExitFailure(exitCode: 127)) {
            try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
        }
    }

    /// A tool that IS there and refuses its arguments: the status is its
    /// own, not 127, so `isToolMissing` has something to be false about
    /// against a real shell.
    @Test("a tool that refuses its arguments reports its own status, not 127")
    func atoolThatRefusesItsArgumentsReportsItsOwnStatus() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let channel = try #require(fs as (any ArchiveCommandChannel)?)
        let home = try await fs.homeDirectoryPath()
        let plan = ArchivePlan(
            operation: .compress(.tarGz), workingDirectory: home,
            tool: "tar", words: [.flag("--macscp-no-such-option")],
            stdin: Data("name\n".utf8))
        do {
            _ = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
            Issue.record("a tool that refuses its arguments must not exit 0")
        } catch let failure as ArchiveCommandExitFailure {
            #expect(failure.exitCode != 0)
            #expect(failure.isToolMissing == false)
        }
    }

    /// The listing half of the protocol, against a real archive. The plan
    /// that will carry a listing line arrives in Task 7; what is measured
    /// here is the channel's own contract — standard output split one entry
    /// per line, and a bound that refuses rather than truncates.
    @Test("a listing comes back one entry per line, and a small bound refuses it")
    func alistingComesBackOneEntryPerLineAndASmallBoundRefusesIt() async throws {
        let fs = try await connect()
        let home = try await fs.homeDirectoryPath()
        let dir = home + "/archive-itest-\(UUID().uuidString)"
        defer {
            Task {
                try? await fs.deleteTree(at: dir)
                await fs.disconnect()
            }
        }
        try await fs.createDirectory(at: dir)
        try await upload(Data("one\n".utf8), to: dir + "/first.txt", over: fs)
        try await upload(Data("two\n".utf8), to: dir + "/second.txt", over: fs)

        let channel = try #require(fs as (any ArchiveCommandChannel)?)
        let pack = try ArchivePlan.compress(
            .zip,
            selection: [
                RemoteFileItem(name: "first.txt", path: dir + "/first.txt", kind: .file),
                RemoteFileItem(name: "second.txt", path: dir + "/second.txt", kind: .file),
            ],
            workingDirectory: dir, archiveName: "out.zip")
        #expect(try await channel.run(pack.remoteCommandLine(), stdin: pack.stdin) == 0)

        let list = ArchivePlan(
            operation: .extract(.zip), workingDirectory: dir,
            tool: "unzip", words: [.flag("-Z1"), .operand("./out.zip")], stdin: nil)
        let entries = try await channel.listing(of: list.remoteCommandLine(), limit: 64 * 1024)
        #expect(entries.sorted() == ["first.txt", "second.txt"])

        // By CASE, not by `(any Error).self`: a bound that let
        // `RemoteCommandOutputTooLarge` escape untranslated, or that threw
        // `ArchiveCommandExitFailure(exitCode: 0)`, would satisfy "some
        // error was thrown" and leave refuses-rather-than-truncates
        // unpinned. The reason TEXT is deliberately not asserted — it is
        // not a contract — only that this is a channel-level protocol
        // failure and not the far side's exit status.
        do {
            let fitted = try await channel.listing(of: list.remoteCommandLine(), limit: 4)
            Issue.record("a listing past the bound must not come back: \(fitted)")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected a protocol error, got \(error)")
                return
            }
        }
    }

    /// A far side that exits 0 WITHOUT having been handed its standard
    /// input must not read as success.
    ///
    /// `run` swallows a failed write on purpose — when the far side has
    /// gone, its exit status is the better answer — but a swallowed write is
    /// otherwise indistinguishable from one that landed, and the two differ
    /// exactly here: a tool that is alive and gets a short or empty name
    /// list archives what it was given and exits 0. `tar --null -T -` on an
    /// empty list writes an empty archive and exits 0 (measured by this
    /// task's `no-stdin` probe), so a truncated selection would be reported
    /// as a finished archive and no listing afterwards would contradict it.
    ///
    /// `true` is the far side here because it is the shortest tool that
    /// exits 0 without reading a byte: the 5.2 MB write cannot complete
    /// (nothing drains the channel's window), so it fails, and the status
    /// is nevertheless 0. Pinned against the rig rather than against a
    /// fake: the behaviour lives in `CitadelFileSystem`'s closure, which no
    /// double can stand in for.
    @Test("a command that exits 0 without having been given its stdin is not a success")
    func acommandThatExitsZeroWithoutItsStandardInputIsNotASuccess() async throws {
        let fs = try await connect()
        defer { Task { await fs.disconnect() } }
        let channel = try #require(fs as (any ArchiveCommandChannel)?)
        let home = try await fs.homeDirectoryPath()
        let manyNames = Data(
            (0..<400_000).map { "name-\($0)" }.joined(separator: "\n").utf8)
        let plan = ArchivePlan(
            operation: .compress(.tarGz), workingDirectory: home,
            tool: "true", words: [], stdin: manyNames)
        do {
            let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
            Issue.record("an unwritten standard input must not return success (\(status))")
        } catch let error as RemoteFSError {
            guard case .protocolError = error else {
                Issue.record("expected a protocol error, got \(error)")
                return
            }
        } catch let failure as ArchiveCommandExitFailure {
            // Not the answer this case wants, and worth naming rather than
            // letting it read as "some error, fine": `true` exits 0, so an
            // exit status here would mean the far side was not the one the
            // plan names.
            Issue.record("expected a protocol error, got exit \(failure.exitCode)")
        }
    }
}
