import Testing
import Foundation
@testable import macSCPCore

@Suite(.timeLimit(.minutes(5)))
struct ArchiveRunnerTests {
    /// A real `zip` over a real directory. No network, no rig: the local
    /// runner's whole job is argv plus bytes, and this is the cheapest place
    /// to prove a hostile name survives it.
    @Test func theLocalRunnerCompressesAnApostropheAndADollarSign() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let awkward = "it's $(not) run"
        try Data("payload\n".utf8).write(to: dir.appendingPathComponent(awkward))

        let plan = try ArchivePlan.compress(
            .zip,
            selection: [RemoteFileItem(
                name: awkward, path: dir.appendingPathComponent(awkward).path, kind: .file)],
            workingDirectory: dir.path, archiveName: "out.zip")
        let outcome = try await LocalArchiveRunner().run(plan)

        #expect(outcome == .finished)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("out.zip").path))
        // Still there: the name was data, not code.
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(awkward).path))
    }

    /// A tool that exits 0 without reading its standard input, over a list far
    /// larger than a pipe holds. The names reach `tar --null -T -` and
    /// `zip -@` only on stdin, so this must not be `.finished`: the remote
    /// half has refused the same shape since the stdin write was made to be
    /// remembered. `/usr/bin/true` is the tool because it ends at once with
    /// 0, which makes the outcome the same under every schedule.
    @Test func aLocalToolThatLeavesItsInputUnreadIsNotAFinishedRun() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let plan = ArchivePlan(
            operation: .compress(.tarGz), workingDirectory: dir.path,
            tool: "true", words: [],
            stdin: Data(repeating: 0x61, count: 4 * 1024 * 1024))
        await #expect(throws: ArchiveStandardInputIncomplete.self) {
            try await LocalArchiveRunner().run(plan)
        }
    }

    /// The positive control for the case above: the same runner, a tool that
    /// reads all of its input, finishes.
    @Test func aLocalToolThatReadsAllOfItsInputFinishes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let plan = ArchivePlan(
            operation: .compress(.tarGz), workingDirectory: dir.path,
            tool: "wc", words: [.flag("-c")],
            stdin: Data(repeating: 0x61, count: 4 * 1024 * 1024))
        let outcome = try await LocalArchiveRunner().run(plan)
        #expect(outcome == .finished)
    }

    @Test func theLocalRunnerReportsAMissingToolApart() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: dir.path,
            tool: "macscp-no-such-archiver", words: [.operand("x")], stdin: nil)
        await #expect(throws: ArchiveFailure.toolMissing(tool: "macscp-no-such-archiver")) {
            try await LocalArchiveRunner().run(plan)
        }
    }

    @Test func theRemoteRunnerHandsThePlanToItsChannel() async throws {
        let channel = RecordingArchiveChannel()
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        let outcome = try await RemoteArchiveRunner(channel: channel).run(plan)
        #expect(outcome == .finished)
        // Both halves travel: the line, and the selection on stdin. The names
        // reach `tar --null -T -` ONLY on stdin, and an empty list there
        // writes an empty archive and exits 0.
        #expect(await channel.lines == [try plan.remoteCommandLine().text])
        #expect(await channel.stdins == [plan.stdin])
        #expect(plan.stdin != nil)
    }

    /// The positive half and the negative half sit together: a backend that
    /// answers the capability yields a runner, one that does not yields none.
    @Test func aBackendIsAskedForTheCapabilityInsideTheModule() async throws {
        #expect(RemoteArchiveRunner(backend: RecordingArchiveChannel()) != nil)
        #expect(RemoteArchiveRunner(backend: LocalFileSystem()) == nil)
    }

    @Test func theRemoteRunnerTurns127IntoAMissingTool() async throws {
        let channel = FailingArchiveChannel(exitCode: 127)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.toolMissing(tool: "zip")) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    /// A channel may also RETURN a status instead of throwing it; the runner
    /// must not read a returned non-zero as success.
    @Test func aReturnedNonZeroStatusIsNotASuccess() async throws {
        let channel = RecordingArchiveChannel(exitStatus: 3)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.exited(status: 3)) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    /// A cancel arriving after a failed exit must not hide the failure. The
    /// recording double does not look at cancellation, so the status is
    /// reached with the task already cancelled.
    @Test func aCancelAfterANonZeroStatusDoesNotHideTheFailure() async throws {
        let channel = RecordingArchiveChannel(exitStatus: 3)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        let task = Task { try await RemoteArchiveRunner(channel: channel).run(plan) }
        task.cancel()
        await #expect(throws: ArchiveFailure.exited(status: 3)) {
            try await task.value
        }
    }

    @Test func theRemoteRunnerKeepsAnyOtherExitStatusAsItIs() async throws {
        let channel = FailingArchiveChannel(exitCode: 12)
        let plan = try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
        await #expect(throws: ArchiveFailure.exited(status: 12)) {
            try await RemoteArchiveRunner(channel: channel).run(plan)
        }
    }

    @Test func aLocalToolThatExitsNonZeroIsAFailure() async throws {
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "false", words: [], stdin: nil)
        await #expect(throws: ArchiveFailure.exited(status: 1)) {
            try await LocalArchiveRunner().run(plan)
        }
    }

    /// `env` exits 127 when the command it is asked to run is not there,
    /// which is the status path (the executable itself exists).
    @Test func aLocalToolThatExits127IsAMissingTool() async throws {
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "env", words: [.operand("macscp-no-such-archiver")], stdin: nil)
        await #expect(throws: ArchiveFailure.toolMissing(tool: "env")) {
            try await LocalArchiveRunner().run(plan)
        }
    }

    /// `tail -f /dev/null` never ends by itself, so the only way out is the
    /// bound. No elapsed-time assertion: the outcome is the property.
    @Test func aLocalRunPastItsBudgetIsTimedOutAndCarriesNoText() async throws {
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "tail", words: [.flag("-f"), .operand("/dev/null")], stdin: nil)
        await #expect(throws: ArchiveFailure.timedOut) {
            try await LocalArchiveRunner(timeout: .milliseconds(300)).run(plan)
        }
    }

    @Test func cancellingALocalRunEndsItAsCancelled() async throws {
        let plan = ArchivePlan(
            operation: .compress(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "tail", words: [.flag("-f"), .operand("/dev/null")], stdin: nil)
        let task = Task { try await LocalArchiveRunner().run(plan) }
        task.cancel()
        let outcome = try await task.value
        #expect(outcome == .cancelled)
    }

    /// A FLOOR, not a ceiling: the runner must not return before the tool
    /// has finished. A ceiling here would measure the machine, which this
    /// project has three CI reds on record for.
    @Test func theLocalRunnerDoesNotReturnBeforeTheArchiveExists() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<200 {
            try Data(repeating: 0x41, count: 4096)
                .write(to: dir.appendingPathComponent("f\(index)"))
        }
        let selection = (0..<200).map { index in
            RemoteFileItem(
                name: "f\(index)", path: dir.appendingPathComponent("f\(index)").path,
                kind: .file)
        }
        let plan = try ArchivePlan.compress(
            .zip, selection: selection, workingDirectory: dir.path,
            archiveName: "many.zip")
        _ = try await LocalArchiveRunner().run(plan)

        // The floor, stated as a COUNT rather than as an outcome: if `run`
        // returned before `zip` had finished, the archive would hold fewer
        // than the 200 entries that went in. An earlier version of this case
        // asserted only `== .finished` on a second run, which every
        // implementation passes including one that returns immediately --
        // a test that could not fail is worse than no test, so it was
        // replaced rather than kept.
        let listed = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", "./many.zip"],
            currentDirectory: dir,
            timeout: ArchiveBudget.run)
        let entryCount = listed.stdoutText
            .split(separator: "\n", omittingEmptySubsequences: true).count
        #expect(entryCount == 200)
    }

    // MARK: Listing (the extract dialog's source of entry names)

    private static func scratchDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Makes `name` (a `.zip`) holding files called `entries`, with the real
    /// `zip`, and returns the directory.
    private static func zip(holding entries: [String], as name: String) async throws -> URL {
        let dir = try scratchDirectory()
        for entry in entries {
            try Data("x".utf8).write(to: dir.appendingPathComponent(entry))
        }
        let plan = try ArchivePlan.compress(
            .zip,
            selection: entries.map {
                RemoteFileItem(name: $0, path: dir.appendingPathComponent($0).path, kind: .file)
            },
            workingDirectory: dir.path, archiveName: name)
        _ = try await LocalArchiveRunner().run(plan)
        return dir
    }

    @Test func theLocalListingReturnsOneElementPerEntry() async throws {
        let dir = try await Self.zip(holding: ["alpha", "it's $(x)"], as: "ar.zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ArchivePlan.listing(of: "ar.zip", format: .zip, workingDirectory: dir.path)
        let entries = try await LocalArchiveRunner().listing(plan, limit: 4096)
        #expect(entries == ["alpha", "it's $(x)"])
    }

    /// The bound is in BYTES of standard output and is inclusive: output of
    /// exactly `limit` bytes is kept, one byte more is refused. `"aaaa\n"` and
    /// `"bbbb\n"` are 10 bytes. The refusal is the property; the numbers only
    /// place it.
    @Test func theLocalListingRefusesPastItsByteBoundAndKeepsExactlyAtIt() async throws {
        let dir = try await Self.zip(holding: ["aaaa", "bbbb"], as: "ar.zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ArchivePlan.listing(of: "ar.zip", format: .zip, workingDirectory: dir.path)

        let atTheBound = try await LocalArchiveRunner().listing(plan, limit: 10)
        #expect(atTheBound == ["aaaa", "bbbb"])

        await #expect(throws: ArchiveListingTooLarge(limit: 9)) {
            try await LocalArchiveRunner().listing(plan, limit: 9)
        }
    }

    /// A listing past the bound must never come back SHORT: a truncated list
    /// under-reports collisions. Asserted as "no list at all" with a bound
    /// far below the output.
    @Test func aLocalListingPastItsBoundYieldsNoPartialList() async throws {
        let names = (0..<50).map { "entry-number-\($0)" }
        let dir = try await Self.zip(holding: names, as: "ar.zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ArchivePlan.listing(of: "ar.zip", format: .zip, workingDirectory: dir.path)
        var returned: [String]?
        var thrown: (any Error)?
        do { returned = try await LocalArchiveRunner().listing(plan, limit: 16) } catch { thrown = error }
        #expect(returned == nil)
        // The refusal is the bound's, not some other failure that also
        // happens to return no list.
        #expect(thrown is ArchiveListingTooLarge)
    }

    @Test func aLocalListingOfAMissingArchiveIsAFailureNotAnEmptyList() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ArchivePlan.listing(of: "absent.zip", format: .zip, workingDirectory: dir.path)
        var returned: [String]?
        var failure: ArchiveFailure?
        do {
            returned = try await LocalArchiveRunner().listing(plan, limit: 4096)
        } catch let error as ArchiveFailure {
            failure = error
        }
        #expect(returned == nil)
        if case .exited? = failure {} else {
            Issue.record("expected ArchiveFailure.exited, got \(String(describing: failure))")
        }
    }

    /// `yes` never stops by itself, so the only way this call can return is
    /// the bound ending the child: it proves the bound acts WHILE output
    /// arrives and does not merely check the total afterwards. No
    /// wall-clock assertion; the suite's hang bound is the ceiling.
    @Test func theBoundEndsAChildThatWouldNeverStopWriting() async throws {
        let plan = ArchivePlan(
            operation: .extract(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "yes", words: [], stdin: nil)
        await #expect(throws: ArchiveListingTooLarge(limit: 100)) {
            try await LocalArchiveRunner().listing(plan, limit: 100)
        }
    }

    @Test func aLocalListingPastItsBudgetIsTimedOut() async throws {
        let plan = ArchivePlan(
            operation: .extract(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "tail", words: [.flag("-f"), .operand("/dev/null")], stdin: nil)
        await #expect(throws: ArchiveFailure.timedOut) {
            try await LocalArchiveRunner(timeout: .milliseconds(300)).listing(plan, limit: 4096)
        }
    }

    @Test func aLocalListingToolThatIsNotThereIsAMissingTool() async throws {
        let plan = ArchivePlan(
            operation: .extract(.zip), workingDirectory: NSTemporaryDirectory(),
            tool: "macscp-no-such-archiver", words: [.operand("x")], stdin: nil)
        await #expect(throws: ArchiveFailure.toolMissing(tool: "macscp-no-such-archiver")) {
            try await LocalArchiveRunner().listing(plan, limit: 4096)
        }
    }

    @Test func theRemoteListingHandsTheChannelTheLineAndTheByteBound() async throws {
        let channel = RecordingArchiveChannel(listingEntries: ["a", "b/"])
        let plan = try ArchivePlan.listing(of: "ar.zip", format: .zip, workingDirectory: "/d")
        let entries = try await RemoteArchiveRunner(channel: channel).listing(plan, limit: 777)
        #expect(entries == ["a", "b/"])
        #expect(await channel.listedLines == [plan.remoteCommandLine().text])
        #expect(await channel.listedLimits == [777])
    }

    @Test func aRemoteListingThatFailsMapsTheSameWayARunDoes() async throws {
        let plan = try ArchivePlan.listing(of: "ar.zip", format: .zip, workingDirectory: "/d")
        await #expect(throws: ArchiveFailure.toolMissing(tool: "unzip")) {
            try await RemoteArchiveRunner(channel: FailingArchiveChannel(exitCode: 127))
                .listing(plan, limit: 4096)
        }
        await #expect(throws: ArchiveFailure.exited(status: 9)) {
            try await RemoteArchiveRunner(channel: FailingArchiveChannel(exitCode: 9))
                .listing(plan, limit: 4096)
        }
    }
}
