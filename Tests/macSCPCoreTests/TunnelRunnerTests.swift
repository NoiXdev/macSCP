import Foundation
import MacSCPTestSupport
import NIOCore
import Testing

@testable import macSCPCore

/// `TunnelRunner` — one profile's whole lifecycle, driven with a fake
/// connection factory, fake runtimes and an injected sleeper, so nothing
/// here dials, binds or waits on a real clock.
///
/// Every wait is an `await` on the runner's own state stream or on
/// `pollUntil`, never a semaphore or a `wait()` (CLAUDE.md, "Tests never
/// block the cooperative pool"), and no assertion carries a wall-clock
/// ceiling: the backoff is measured by what the injected sleeper was ASKED
/// for, not by how long anything took.
@Suite("Tunnel runner", .timeLimit(.minutes(1)))
struct TunnelRunnerTests {

    // MARK: - The clean sequence

    @Test func aCleanStartReachesActiveAndStopReturnsToStopped() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        #expect(await runner.state == .active(connections: 0))
        #expect(runtimes.startedKinds.count == 1)

        await runner.stop()
        #expect(await runner.state == .stopped)
        // The collector consumes the stream on a task of its own, so the
        // last yield has to be waited for before the whole sequence is read
        // — not asserted on whatever happened to have arrived by now.
        try await states.waitFor(.stopped)
        #expect(states.recorded == [.connecting, .active(connections: 0), .stopped])
    }

    /// The connection and the forward are both released on `stop()` — the
    /// runner leaks neither.
    @Test func stopStopsTheRuntimeAndDisconnectsTheConnection() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 1080)
        let runner = TunnelRunner(
            profile: dynamicProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        await runner.stop()

        #expect(connections.made.count == 1)
        #expect(connections.made[0].disconnectCount == 1)
        #expect(runtimes.made.count == 1)
        #expect(runtimes.made[0].stopCount == 1)
    }

    /// Accepted connections count up and down through the observer the
    /// runner hands the runtime.
    @Test func acceptedConnectionsAreCounted() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        runtimes.made[0].observer?(.opened)
        try await states.waitFor(.active(connections: 1))
        runtimes.made[0].observer?(.closed(bytesIn: 3, bytesOut: 4, duration: .milliseconds(1)))
        try await states.waitFor(.active(connections: 0))

        await runner.stop()
    }

    // MARK: - Reconnect

    /// A loss after a HEALTHY period starts the backoff over: three drops,
    /// each of whose reconnects succeeds, ask the sleeper for 2 seconds
    /// every time — never 2, 4, 8.
    ///
    /// That is the plan's own table, not a choice made here: `active(n) +
    /// connectionLost(reconnects: true) → reconnecting(1)`. Only
    /// CONSECUTIVE failed retries climb (`aFailedRetryKeepsClimbing` below
    /// is the 2, 4, 8 pin), which is the behaviour that matters — a tunnel
    /// that has been carrying traffic for an hour should not wait a minute
    /// after its first blip because it once reconnected six times.
    ///
    /// This test was written asserting 2, 4, 8 and run red first for that
    /// reason: it timed out waiting for `reconnecting(attempt: 2)`, which
    /// is what proved the reset is real rather than assumed.
    @Test func aLossAfterAHealthyPeriodStartsTheBackoffOver() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let sleeper = TunnelRecordedSleeper()
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: sleeper.sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        for drop in 1...3 {
            connections.made[drop - 1].drop()
            try await states.waitFor(.reconnecting(attempt: 1))
            try await states.waitFor(.active(connections: 0))
        }

        #expect(sleeper.slept == [.seconds(2), .seconds(2), .seconds(2)])
        // A fresh connection and a fresh runtime per attempt — everything
        // is single-use, and the old one is released before the new one.
        #expect(connections.made.count == 4)
        #expect(runtimes.made.count == 4)
        #expect(connections.made.prefix(3).allSatisfy { $0.disconnectCount == 1 })
        #expect(runtimes.made.prefix(3).allSatisfy { $0.stopCount == 1 })

        await runner.stop()
    }

    /// A retry whose DIAL fails keeps retrying and keeps climbing — the
    /// attempt number is not reset by a failed reconnect.
    @Test func aFailedRetryKeepsClimbing() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts([2, 3], with: TunnelFailure.connectFailed(reason: "refused"))
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let sleeper = TunnelRecordedSleeper()
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: sleeper.sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        connections.made[0].drop()
        try await states.waitFor(.reconnecting(attempt: 3))
        try await states.waitFor(.active(connections: 0))

        #expect(sleeper.slept == [.seconds(2), .seconds(4), .seconds(8)])
        await runner.stop()
    }

    /// `reconnects == false`: one loss ends the run, with the plan's own
    /// mapped sentence, and nothing is ever slept on.
    @Test func aLossWithoutReconnectsFailsAtOnce() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let sleeper = TunnelRecordedSleeper()
        let runner = TunnelRunner(
            profile: localProfile(reconnects: false), connect: connections.connect,
            runtimes: runtimes, sleeper: sleeper.sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        connections.made[0].drop()
        try await states.waitFor(.failed(reason: "connection lost"))

        #expect(sleeper.slept.isEmpty)
        #expect(connections.made[0].disconnectCount == 1)
        #expect(runtimes.made[0].stopCount == 1)
    }

    /// `stop()` during the backoff sleep ends the run: the sleeper is
    /// cancelled, no further attempt is made, and the runner settles at
    /// `.stopped`.
    @Test func stopDuringBackoffEndsTheRun() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let sleeper = TunnelParkingSleeper()
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: sleeper.sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        connections.made[0].drop()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await pollUntil("the backoff sleep to be entered") { sleeper.entered >= 1 }

        await runner.stop()

        #expect(await runner.state == .stopped)
        #expect(sleeper.cancelled == 1)
        // Exactly one connection was ever dialled: the retry never ran.
        #expect(connections.made.count == 1)
        #expect(runtimes.made.count == 1)
    }

    // MARK: - Confirmation

    /// An unknown host key under the refusing decider — what autostart
    /// hands in — is `.needsConfirmation`, not `.failed`.
    @Test func anUnknownHostKeyUnderRefusingNeedsConfirmation() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: HostKeyError.rejectedByUser)
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080), sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .refusing)
        try await states.waitFor(.needsConfirmation)
        #expect(await runner.state == .needsConfirmation)
    }

    /// A session with no stored secret is the same answer: connect it once
    /// by hand.
    @Test func aSessionWithNoSecretNeedsConfirmation() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: StoredSessionConnectionError.secretRequired)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080), sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .refusing)
        try await states.waitFor(.needsConfirmation)
    }

    /// A key MISMATCH is a hard stop, never a confirmation prompt — the
    /// architecture invariant, held here as the negative beside the two
    /// positives above.
    @Test func aHostKeyMismatchFailsAndIsNeverAConfirmation() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts(
            [1],
            with: HostKeyError.mismatch(host: "h", expected: "SHA256:a", presented: "SHA256:b"))
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080), sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .refusing)
        try await states.waitForFailure()
        let reachedConfirmation = states.recorded.contains(.needsConfirmation)
        #expect(reachedConfirmation == false)
    }

    /// A first-attempt dial failure is `.failed` with the MAPPED sentence,
    /// even for a profile that reconnects: nothing has ever worked yet, so
    /// there is nothing to recover.
    @Test func aFirstAttemptDialFailureFails() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: TunnelFailure.connectFailed(reason: "no route"))
        let sleeper = TunnelRecordedSleeper()
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080), sleeper: sleeper.sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitForFailure()
        #expect(sleeper.slept.isEmpty)
    }

    /// A forward that ends on its own AFTER the server confirmed it — the
    /// remote-forward shape Task 4 handed off as reporting to nobody — is a
    /// connection loss like any other.
    @Test func aRuntimeThatEndsOnItsOwnIsALoss() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 45_000)
        let sleeper = TunnelRecordedSleeper()
        let runner = TunnelRunner(
            profile: remoteProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: sleeper.sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        runtimes.made[0].endOnItsOwn()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await states.waitFor(.active(connections: 0))

        #expect(sleeper.slept == [.seconds(2)])
        await runner.stop()
    }

    /// `start()` twice is one run, not two: the second call finds a run in
    /// flight and does nothing.
    @Test func aSecondStartIsIgnoredWhileRunning() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        await runner.start(decider: .asking { _ in true })

        #expect(connections.made.count == 1)
        await runner.stop()
    }

    /// A stopped runner starts again — `needsConfirmation` and `stopped`
    /// are both `start`-able states in the plan's own table.
    @Test func aStoppedRunnerCanBeStartedAgain() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        await runner.stop()
        try await states.waitFor(.stopped)
        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        #expect(connections.made.count == 2)
        await runner.stop()
    }
}

// MARK: - Fixtures

private func localProfile(reconnects: Bool = false) -> TunnelProfile {
    TunnelProfile(
        sessionID: UUID(), name: "web",
        kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
        reconnects: reconnects)
}

private func dynamicProfile(reconnects: Bool = false) -> TunnelProfile {
    TunnelProfile(
        sessionID: UUID(), name: "socks",
        kind: .dynamic(bind: "127.0.0.1", localPort: 1080), reconnects: reconnects)
}

private func remoteProfile(reconnects: Bool = false) -> TunnelProfile {
    TunnelProfile(
        sessionID: UUID(), name: "back",
        kind: .remote(
            bind: "127.0.0.1", remotePort: 45_000, localHost: "127.0.0.1", localPort: 22),
        reconnects: reconnects)
}
