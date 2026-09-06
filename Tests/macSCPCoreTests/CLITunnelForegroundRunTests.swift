import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The loop `macscp-cli tunnels start` runs: one line per published state,
/// a signal that ends it with 0, and a terminal state that ends it with the
/// code and the sentence `TunnelExit` gives.
///
/// Driven against a REAL `TunnelRunner` wherever the property is about the
/// runner's own sequence — with `TunnelRunnerFakes`' fake connections,
/// runtimes and sleeper, so nothing dials, binds or waits on a clock — and
/// against a scripted tunnel for the two properties the runner cannot be
/// made to produce on demand: a stop that parks, and a terminal `failed`
/// after a dial that already succeeded.
///
/// Every wait is an `await` on `pollUntil` (CLAUDE.md, "Tests never block
/// the cooperative pool"), and nothing here asserts an elapsed time.
@Suite("CLI tunnels start foreground loop", .timeLimit(.minutes(1)))
struct CLITunnelForegroundRunTests {

    // MARK: - The clean sequence

    /// One line per change and no duplicates: `connecting`, the `active`
    /// line carrying the port the runtime bound, the count climbing and
    /// falling, and `stopped` — after which the code is 0.
    ///
    /// The count lines are what make "one line per CHANGE" a real claim:
    /// they are two more `active` states, and a loop that re-rendered the
    /// same state would show here.
    @Test func everyChangeIsOneLineAndASignalLeavesWithZero() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: runner, stops: stops, decider: .refusing, json: false,
                verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }

        try await pollUntil("the forward to bind") { !runtimes.made.isEmpty }
        runtimes.made[0].observer?(.opened)
        try await pollUntil("the accepted connection to be counted") {
            out.lines.contains("active port=8080 connections=1")
        }
        runtimes.made[0].observer?(.closed(bytesIn: 3, bytesOut: 4, duration: .milliseconds(1)))
        try await pollUntil("the closed connection to be counted") {
            out.lines.filter { $0 == "active port=8080" }.count == 2
        }

        signal.yield()
        let code = try await run.result()

        #expect(code == .success)
        #expect(
            out.lines == [
                "connecting", "active port=8080", "active port=8080 connections=1",
                "active port=8080", "stopped",
            ])
        #expect(out.notes.isEmpty)
    }

    /// Nothing is left running: the forward is stopped exactly once and the
    /// connection disconnected exactly once by the time `drive` hands back.
    ///
    /// What this does NOT pin is `drive`'s own `await runner.stop()`, and
    /// the difference was measured rather than assumed: with that call
    /// deleted the test stayed GREEN (mutation probe, 2026-09-06), because
    /// `TunnelRunner` publishes `.stopped` only after `releaseCurrent()` has
    /// already run — so both counts are 1 the moment the line this loop
    /// breaks on exists at all. That property belongs to `drive` and is
    /// pinned on a tunnel that does not release anything by itself, in
    /// `theTunnelIsStoppedBeforeTheCodeComesBack` below. What IS pinned here
    /// is the pair of ONCEs: a loop that stopped a second time, or left the
    /// runner's own teardown to run twice, reads 2.
    @Test func theStopIsOverBeforeTheCodeComesBack() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: runner, stops: stops, decider: .refusing, json: false,
                verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }
        try await pollUntil("the forward to bind") { !runtimes.made.isEmpty }
        signal.yield()
        _ = try await run.result()

        #expect(runtimes.made[0].stopCount == 1)
        #expect(connections.made[0].disconnectCount == 1)
    }

    /// `--json` puts the same sequence out as one object per line.
    @Test func theJSONFormReachesTheSameSequence() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: runner, stops: stops, decider: .refusing, json: true,
                verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }
        try await pollUntil("the forward to bind") { !runtimes.made.isEmpty }
        signal.yield()
        _ = try await run.result()

        let decoded = try out.lines.map(TunnelStateJSONLine.decode)
        #expect(decoded.map(\.state) == ["connecting", "active", "stopped"])
        #expect(decoded[1].port == 8080)
    }

    // MARK: - The three ways a run ends badly

    /// A forward that cannot bind on the FIRST attempt is a failure: 13,
    /// with the runner's own mapped sentence on stderr.
    @Test func aForwardThatCannotBindLeavesWithThirteen() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        runtimes.failStarts([1], with: TunnelFailure.bindFailed(reason: "port 8080 in use"))
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()

        let code = await TunnelForegroundRun.drive(
            runner: runner, stops: AsyncStream { _ in }, decider: .refusing, json: false,
            verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)

        #expect(code == .connection)
        #expect(out.lines == ["connecting", "failed"])
        #expect(out.notes.count == 1)
        #expect(out.notes.first?.hasPrefix("Error: ") == true)
    }

    /// A session with no secret this tool can reach is `needsConfirmation`,
    /// and the dial's own error is what makes it 10 rather than 11.
    @Test func aSessionWithNoSecretLeavesWithTen() async throws {
        let record = TunnelDialFailureRecord()
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: StoredSessionConnectionError.secretRequired)
        let runner = TunnelRunner(
            profile: localProfile(), connect: recording(connections.connect, into: record),
            runtimes: TunnelFakeRuntimes(boundPort: 8080),
            sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()

        let code = await TunnelForegroundRun.drive(
            runner: runner, stops: AsyncStream { _ in }, decider: .refusing, json: false,
            verbose: false, dialFailure: record, output: out.output)

        #expect(code == .auth)
        #expect(out.lines == ["connecting", "needs confirmation"])
        #expect(out.notes == [CLIErrorMapping.message(for: StoredSessionConnectionError.secretRequired)])
    }

    /// The same state, a different cause: an unknown key the decider refused
    /// is 11.
    @Test func anUnknownHostKeyLeavesWithEleven() async throws {
        let record = TunnelDialFailureRecord()
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: HostKeyError.rejectedByUser)
        let runner = TunnelRunner(
            profile: localProfile(), connect: recording(connections.connect, into: record),
            runtimes: TunnelFakeRuntimes(boundPort: 8080),
            sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()

        let code = await TunnelForegroundRun.drive(
            runner: runner, stops: AsyncStream { _ in }, decider: .refusing, json: false,
            verbose: false, dialFailure: record, output: out.output)

        #expect(code == .hostKeyUnknown)
        #expect(out.lines == ["connecting", "needs confirmation"])
    }

    // MARK: - Reconnect, and what `--verbose` says about it

    @Test func verboseNamesTheBackoffTheRunnerIsAboutToWait() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: runner, stops: stops, decider: .refusing, json: false,
                verbose: true, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }
        try await pollUntil("the first forward to bind") { !runtimes.made.isEmpty }
        connections.made[0].drop()
        try await pollUntil("the reconnect to be announced") {
            out.lines.contains("reconnecting attempt=1")
        }
        signal.yield()
        _ = try await run.result()

        #expect(out.notes.contains("backoff seconds=2"))
    }

    /// The same run without `--verbose` says nothing about the backoff. The
    /// positive above is what keeps this negative from passing on a build
    /// that lost the line altogether.
    @Test func aQuietRunSaysNothingAboutTheBackoff() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let out = ForegroundOutputCollector()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: runner, stops: stops, decider: .refusing, json: false,
                verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }
        try await pollUntil("the first forward to bind") { !runtimes.made.isEmpty }
        connections.made[0].drop()
        try await pollUntil("the reconnect to be announced") {
            out.lines.contains("reconnecting attempt=1")
        }
        signal.yield()
        _ = try await run.result()

        #expect(!out.notes.contains { $0.hasPrefix("backoff") })
    }

    // MARK: - The two properties the real runner cannot be asked for

    /// A dial that FAILED and a dial that then SUCCEEDED: the second clears
    /// the first, so a later failure with no error of its own is 13 and not
    /// the 10 the stale record would have made it.
    ///
    /// Driven against a scripted tunnel because the runner cannot publish
    /// this sequence: after its first successful attempt every dial failure
    /// that is not a `needsConfirmation` becomes a LOSS, so a terminal
    /// `failed` after a recorded-then-cleared dial is unreachable through
    /// its own table (counted 2026-09-06 against `TunnelRunner.run` and
    /// `outcome(for:isRetry:)`). The record's own reset is measured
    /// separately in `CLITunnelDialFailureRecordTests`; this is the
    /// composition — that `drive` reads the record as it stands when the
    /// terminal state arrives.
    @Test func aClearedDialFailureDoesNotDecideALaterOne() async throws {
        let record = TunnelDialFailureRecord()
        _ = try? await record.dialing { throw PasswordCommandError.launchFailed }
        try await record.dialing {}
        let tunnel = ScriptedForegroundTunnel(boundPort: 8080)
        let out = ForegroundOutputCollector()

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: tunnel, stops: AsyncStream { _ in }, decider: .refusing, json: false,
                verbose: false, dialFailure: record, output: out.output)
        }
        try await pollUntil("the run to start") { await tunnel.startCount == 1 }
        tunnel.publish(.failed(reason: "the forward could not bind"))

        #expect(try await run.result() == .connection)
        #expect(out.notes == ["Error: the forward could not bind"])
    }

    /// `drive` stops the tunnel before it returns, whatever the tunnel did
    /// on its own.
    ///
    /// The scripted tunnel releases nothing when it publishes — which is
    /// exactly what the real runner does NOT do, and why this cannot be
    /// measured against it: `TunnelRunner` has already torn everything down
    /// by the time it publishes a terminal state, so its counts are right
    /// whether or not this loop asks. Here the ask is the only thing that
    /// could set `stopEntered`, so deleting it is red.
    @Test func theTunnelIsStoppedBeforeTheCodeComesBack() async throws {
        let tunnel = ScriptedForegroundTunnel(boundPort: 8080)
        let out = ForegroundOutputCollector()

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: tunnel, stops: AsyncStream { _ in }, decider: .refusing, json: false,
                verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }
        try await pollUntil("the run to start") { await tunnel.startCount == 1 }
        tunnel.publish(.failed(reason: "the forward could not bind"))
        let code = try await run.result()
        let stops = await tunnel.stopEntered

        #expect(code == .connection)
        #expect(stops == 1, "the run returned without stopping the tunnel")
    }

    /// A SECOND signal leaves at once, even though the stop the first one
    /// asked for is still running.
    ///
    /// The scripted tunnel's `stop()` parks until this test releases it,
    /// which is the only way to hold that window open deliberately — the
    /// same device `TunnelFakeRuntimes(firstStopGate:)` uses on the runner.
    /// The postconditions are read BEFORE the latch is opened (CLAUDE.md,
    /// "Tests that watch a defect heal"): the run has already returned
    /// while the stop is still inside its own body.
    @Test func aSecondSignalLeavesWhileTheStopIsStillRunning() async throws {
        let gate = TunnelLatch()
        let tunnel = ScriptedForegroundTunnel(boundPort: 8080, stopGate: gate)
        let out = ForegroundOutputCollector()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = ForegroundRun {
            await TunnelForegroundRun.drive(
                runner: tunnel, stops: stops, decider: .refusing, json: false,
                verbose: false, dialFailure: TunnelDialFailureRecord(), output: out.output)
        }
        try await pollUntil("the run to start") { await tunnel.startCount == 1 }
        signal.yield()
        try await pollUntil("the first stop to be entered") { await tunnel.stopEntered == 1 }

        signal.yield()
        let code = try await run.result()
        let finishedStops = await tunnel.stopFinished

        #expect(code == .success)
        #expect(out.lines.last == "stopped")
        #expect(finishedStops == 0, "the run waited for the stop it was told to abandon")

        gate.release()
    }
}

/// The record itself: what it keeps, and what a successful dial does to it.
@Suite("CLI tunnels start dial failure record")
struct CLITunnelDialFailureRecordTests {
    @Test func aFailedDialIsRecordedAsItsMappedCodeAndMessage() async throws {
        let record = TunnelDialFailureRecord()
        await #expect(throws: PasswordCommandError.self) {
            try await record.dialing { throw PasswordCommandError.launchFailed }
        }
        #expect(record.current?.code == .auth)
        #expect(record.current?.message == CLIErrorMapping.message(for: PasswordCommandError.launchFailed))
    }

    /// The reset. A dial that succeeds clears whatever an earlier attempt
    /// recorded — without it the exit code of a later, unrelated failure is
    /// decided by an error that has since been recovered from.
    @Test func aSuccessfulDialClearsWhatAnEarlierOneRecorded() async throws {
        let record = TunnelDialFailureRecord()
        _ = try? await record.dialing { throw PasswordCommandError.launchFailed }
        #expect(record.current != nil, "nothing was recorded, so nothing is being cleared")

        let answer = try await record.dialing { 7 }

        #expect(answer == 7)
        #expect(record.current == nil)
    }

    @Test func anUntouchedRecordHoldsNothing() {
        #expect(TunnelDialFailureRecord().current == nil)
    }
}

// MARK: - Doubles

/// Collects what the loop wrote, keeping stdout lines and stderr notes
/// apart — which is the point of the split: a `--json` consumer reads only
/// the first.
final class ForegroundOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var noted: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return noted
    }

    var output: TunnelForegroundOutput {
        TunnelForegroundOutput(
            line: { [self] line in lock.withLock { written.append(line) } },
            note: { [self] note in lock.withLock { noted.append(note) } })
    }
}

/// A `drive` running on a task of its own, waited for CANCELLABLY.
///
/// `Task<CLIExitCode, Never>.value` ignores the awaiting task's
/// cancellation, so a `drive` that never returns parks the test PAST its
/// `.timeLimit` instead of failing at it — the shape `docs/BACKLOG.md` calls
/// "A test parked on a bare continuation outlives its time limit". Measured
/// here on 2026-09-06: the mutation probe for the second-signal path (the
/// signal stream abandoned after its first element) HUNG this suite for ten
/// minutes rather than turning it red, and this type is what turned the same
/// plant into a verdict. `pollUntil` sleeps, so cancellation ends it.
final class ForegroundRun: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CLIExitCode?
    private var task: Task<Void, Never>?

    init(_ body: @escaping @Sendable () async -> CLIExitCode) {
        task = nil
        task = Task { [self] in
            let code = await body()
            lock.withLock { value = code }
        }
    }

    var code: CLIExitCode? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func result() async throws -> CLIExitCode {
        try await pollUntil("the foreground run to return") { self.code != nil }
        guard let code else { throw ForegroundRunError.noResult }
        return code
    }
}

enum ForegroundRunError: Error {
    case noResult
}

/// A tunnel that publishes exactly what a test tells it to.
///
/// Not a replacement for the real runner — every sequence that CAN be
/// produced by driving `TunnelRunner` with the existing fakes is measured
/// that way above. This exists for the two that cannot: a `stop()` that
/// parks, and a terminal state after a dial the record has already
/// cleared.
actor ScriptedForegroundTunnel: ForegroundTunnel {
    nonisolated let states: AsyncStream<TunnelState>
    private nonisolated let continuation: AsyncStream<TunnelState>.Continuation
    private let port: Int
    private let stopGate: TunnelLatch?
    private(set) var startCount = 0
    private(set) var stopEntered = 0
    private(set) var stopFinished = 0

    init(boundPort: Int, stopGate: TunnelLatch? = nil) {
        port = boundPort
        self.stopGate = stopGate
        (states, continuation) = AsyncStream.makeStream(of: TunnelState.self)
    }

    var boundPort: Int? { port }

    func start(decider: HostKeyDecider) async {
        startCount += 1
        continuation.yield(.connecting)
    }

    func stop() async {
        stopEntered += 1
        await stopGate?.wait()
        stopFinished += 1
        continuation.yield(.stopped)
    }

    nonisolated func publish(_ state: TunnelState) {
        continuation.yield(state)
    }
}

/// Wraps a fake connect so its failures land in a record, the way the
/// command line's own dial does.
private func recording(
    _ connect: @escaping TunnelRunner.Connect, into record: TunnelDialFailureRecord
) -> TunnelRunner.Connect {
    { decider in
        try await record.dialing { try await connect(decider) }
    }
}

private func localProfile(reconnects: Bool = false) -> TunnelProfile {
    TunnelProfile(
        sessionID: UUID(), name: "web",
        kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
        reconnects: reconnects)
}
