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

    // MARK: - Connections that could not be carried

    /// A connection the forward could not carry is counted while the tunnel
    /// stays `active`, the latest kind rides along, and the next connection
    /// that opens resets both — through the seams the runner hands the
    /// runtime, not through the plan alone.
    @Test func aFailedConnectionIsCountedAndTheNextOpenResetsTheCount() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        try await states.waitFor(
            .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed))
        runtimes.made[0].onConnectionFailure(.connectFailed(reason: "refused"))
        try await states.waitFor(
            .active(connections: 0, failedConnections: 2, lastFailure: .connectFailed))

        runtimes.made[0].observer?(.opened)
        try await states.waitFor(.active(connections: 1))
        #expect(await runner.state == .active(connections: 1, failedConnections: 0, lastFailure: nil))

        await runner.stop()
    }

    /// The reports reach the plan in the order the forward made them. An
    /// `opened` followed at once by a failure — one connection that opened
    /// and, a moment later, another whose channel the server refused — must
    /// end counted, not reset by an `opened` that overtook it.
    @Test func connectionReportsKeepTheirOrder() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 1080)
        let runner = TunnelRunner(
            profile: dynamicProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        // Many pairs, and the WHOLE published sequence compared, not only
        // the last state: one pair delivered out of order anywhere shows up
        // as a wrong element, where a final-state check sees only the last
        // pair.
        let pairs = 200
        var expected: [TunnelState] = [.connecting, .active(connections: 0)]
        for pair in 1...pairs {
            runtimes.made[0].observer?(.opened)
            runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "refused"))
            expected.append(.active(connections: pair))
            expected.append(
                .active(connections: pair, failedConnections: 1, lastFailure: .channelOpenFailed))
        }
        try await states.waitFor(
            .active(connections: pairs, failedConnections: 1, lastFailure: .channelOpenFailed))
        #expect(states.recorded == expected)

        await runner.stop()
    }

    /// Reports a stopped attempt had buffered never reach the next attempt.
    ///
    /// Review of `b9ee7d22` measured the opposite: `releaseCurrent()`
    /// finished the stream without waiting for its reader, which went on
    /// draining — 20,000 failures on attempt 1, then stop and start, and the
    /// NEW attempt's `active` read `failedConnections: 26`. A stale `opened`
    /// would add a phantom connection too, so one is buffered last.
    ///
    /// Two reads: the reader count right after `stop()` returns — exact,
    /// and what a reader that never ends turns red — and every state
    /// published after the first `.stopped`.
    @Test func reportsFromAStoppedAttemptDoNotReachTheNext() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        #expect(await runner.reportReaders == 1)

        for _ in 1...20_000 {
            runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        }
        runtimes.made[0].observer?(.opened)
        await runner.stop()
        #expect(await runner.reportReaders == 0)
        try await states.waitFor(.stopped)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        await runner.stop()
        try await states.waitFor(.stopped)

        let recorded = states.recorded
        let firstStop = try #require(recorded.firstIndex(of: .stopped))
        let staleAfterStop = recorded[(firstStop + 1)...].contains { state in
            guard case .active(let open, let failed, let last) = state else { return false }
            return open != 0 || failed != 0 || last != nil
        }
        #expect(staleAfterStop == false)
        #expect(await runner.reportReaders == 0)
    }

    /// Reports a stopping attempt still has buffered are DROPPED, not
    /// applied: no `.active` is published once `stop()` has begun.
    ///
    /// The reader used to drain them all into the plan first — one
    /// intermediate `.active` and one `.debug` line per report — before the
    /// `.stopped` (BACKLOG, "A stopped forwarding attempt's buffered
    /// connection reports still publish intermediate `.active` states while
    /// they drain"). The order is made deterministic by the gated runtime:
    /// the reports are sent only once its `stop()` has been ENTERED, which
    /// is after the runner's stop began and before the report stream is
    /// finished, so every one of them sits in the buffer of a live reader.
    ///
    /// Two controls: the reader is still awaited (`reportReaders == 0` the
    /// moment `stop()` returns), and the NEXT attempt's reports are applied
    /// again — a runner that dropped every report from the first stop on
    /// would satisfy the first half.
    @Test func reportsBufferedWhileStoppingAreDroppedNotPublished() async throws {
        let latch = TunnelLatch()
        defer { latch.release() }
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080, firstStopGate: latch)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        let stopped = TunnelCallCounter()
        _ = Task {
            await runner.stop()
            stopped.record()
        }
        try await pollUntil("the first runtime's stop to be parked") {
            runtimes.made[0].stopEntered == 1
        }
        for _ in 1...20_000 {
            runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        }
        runtimes.made[0].observer?(.opened)
        latch.release()
        try await pollUntil("the stop to return") { stopped.count == 1 }
        #expect(await runner.reportReaders == 0)
        try await states.waitFor(.stopped)

        let recorded = states.recorded
        #expect(recorded.count == 3, "\(recorded.count) states published, expected 3")
        let publishedWhileStopping = recorded.dropFirst(2).dropLast().count
        #expect(publishedWhileStopping == 0)
        #expect(recorded.last == .stopped)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        runtimes.made[1].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        try await states.waitFor(
            .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed))
        await runner.stop()
        try await states.waitFor(.stopped)
    }

    /// A reconnect forgets the failures: they belonged to the forward that
    /// was lost.
    @Test func aReconnectForgetsTheFailedConnections() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        try await states.waitFor(
            .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed))

        connections.made[0].drop()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await states.waitFor(.active(connections: 0, failedConnections: 0, lastFailure: nil))

        await runner.stop()
    }

    /// A connection that fails BECAUSE the SSH connection dropped under it —
    /// its channel through the server was still opening — takes the tunnel
    /// straight to `.reconnecting`, with no "1 connection failed" in
    /// between. The failure belongs to the loss, and the loss's own state
    /// is what describes it.
    ///
    /// Recorded 2026-09-17 in `docs/BACKLOG.md` ("…a reconnect can show a
    /// transient failure count"): the report stream carried the failure,
    /// the reader applied it, and `active(failedConnections: 1)` was
    /// published before the `.reconnecting` the drop produced.
    ///
    /// The events arrive in the order a real drop produces them: the
    /// transport goes down first (`goDown()`, NIO's inactive flag), then
    /// what it carried is failed — the in-flight connection's channel open,
    /// and an established pair closing — and the disconnect signal comes
    /// LAST (Citadel's `Task`). So the failure reaches the runner while its
    /// attempt is still fully held, which is the window only the
    /// `isConnected` half of the rule covers; the pair's close is the sync
    /// point that proves the failure was read in that window, because the
    /// report stream keeps its order. Measured 2026-09-18: a first version
    /// that fired the signal FIRST stayed green 10 of 10 with the
    /// `isConnected` check removed — the failure then only ever landed
    /// after the attempt was released, or after its stream was finished.
    ///
    /// The whole published sequence is compared, not only the absence of a
    /// count, and the NEW attempt's failure is the control: it is counted,
    /// so the rule is about the attempt that dropped, not about failures.
    @Test func aDropWithAConnectionInFlightGoesStraightToReconnecting() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        runtimes.made[0].observer?(.opened)
        try await states.waitFor(.active(connections: 1))

        connections.made[0].goDown()
        runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "the connection dropped"))
        runtimes.made[0].observer?(.closed(bytesIn: 1, bytesOut: 1, duration: .milliseconds(1)))
        try await states.waitFor("the open pair's close") { state in
            guard case .active(let open, _, _) = state else { return false }
            return open == 0
        }
        connections.made[0].drop()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await states.waitFor(.active(connections: 0))

        runtimes.made[1].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        try await states.waitFor(
            .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed))
        await runner.stop()
        try await states.waitFor(.stopped)

        #expect(
            states.recorded == [
                .connecting, .active(connections: 0), .active(connections: 1),
                .active(connections: 0), .reconnecting(attempt: 1), .connecting,
                .active(connections: 0),
                .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed),
                .stopped,
            ])
    }

    /// The other half of the same rule: a failure the reader delivers while
    /// a LOST attempt is being released is not counted either — even with
    /// the SSH connection still up, which is the shape of a forward that
    /// ended by itself. The attempt is over; its `.reconnecting` is what
    /// describes it.
    ///
    /// Deterministic through the gated runtime: the failure is sent while
    /// the lost attempt's release is parked in the runtime's `stop()`,
    /// after the runner let go of the attempt and before it awaited the
    /// reader.
    @Test func aFailureDrainedFromAnEndedForwardIsNotCounted() async throws {
        let latch = TunnelLatch()
        defer { latch.release() }
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 45_000, firstStopGate: latch)
        let runner = TunnelRunner(
            profile: remoteProfile(reconnects: true), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        runtimes.made[0].endOnItsOwn()
        try await pollUntil("the lost attempt's release to be parked in its stop") {
            runtimes.made[0].stopEntered == 1
        }
        #expect(connections.made[0].isConnected)
        runtimes.made[0].onConnectionFailure(.connectFailed(reason: "refused"))
        latch.release()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await states.waitFor(.active(connections: 0))
        await runner.stop()
        try await states.waitFor(.stopped)

        #expect(
            states.recorded == [
                .connecting, .active(connections: 0), .reconnecting(attempt: 1), .connecting,
                .active(connections: 0), .stopped,
            ])
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
        try await states.waitFor(.failed(.connectionLost))
        #expect(await runner.failureReason == "connection lost")

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
        connections.failAttempts([1], with: StoredSessionConnectionError.secretRequired(checked: []))
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

    /// A bind that could not be taken names the PORT in the failure the
    /// user reads — the one thing they need in order to free it.
    ///
    /// Round 2, IMPORTANT: `DialSupport.reason(for:)` had no `TunnelFailure`
    /// arm and `TunnelFailure` is not `LocalizedError`, so this reached both
    /// the state and the log as Foundation's generic
    /// "The operation couldn't be completed. (macSCPCore.TunnelFailure error
    /// 0.)" — the port dropped, and a case index in its place.
    @Test func aPortAlreadyInUseNamesThePortInTheFailureReason() async throws {
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        runtimes.failStarts([1], with: TunnelFailure.portInUse(port: 8080))
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitForFailure()

        let reported: TunnelFailureKind? = states.recorded.compactMap {
            if case .failed(let kind) = $0 { return kind }
            return nil
        }.first
        #expect(reported == .portInUse(port: 8080))
        #expect(await runner.failureReason == "port 8080 is already in use")
        // The connection dialled for a forward that never bound is released.
        #expect(connections.made[0].disconnectCount == 1)
    }

    /// Neither production path to `.failed` leaves the reason unset: a
    /// first-attempt dial failure sets `lastFailureReason` to
    /// `DialSupport.reason(for:)`'s mapped sentence in the same actor step
    /// as `apply(.failed(…))` (`TunnelRunner.swift`, the `run(decider:id:)`
    /// `.failed` arm), and a loss on a profile that does not reconnect sets
    /// it to the kind's own sentence in the `.lost` arm's fallthrough. Task
    /// 2 of the review-follow-ups plan measured both and found no third
    /// path; this pins that measurement so a future one that skips the
    /// assignment goes red here rather than only in `TunnelStateLine`'s
    /// `reason ?? kind.sentence` fallback, which would silently print the
    /// kind's sentence and hide the gap.
    @Test func aFailedStateAlwaysCarriesAFailureReason() async throws {
        let dialFailureConnections = TunnelFakeConnections()
        dialFailureConnections.failAttempts(
            [1], with: TunnelFailure.connectFailed(reason: "no route"))
        let dialFailureRunner = TunnelRunner(
            profile: localProfile(reconnects: true), connect: dialFailureConnections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080), sleeper: TunnelRecordedSleeper().sleep)
        let dialFailureStates = TunnelStateCollector(dialFailureRunner.states)
        await dialFailureRunner.start(decider: .asking { _ in true })
        try await dialFailureStates.waitForFailure()
        #expect(await dialFailureRunner.failureReason != nil)

        let lossConnections = TunnelFakeConnections()
        let lossRunner = TunnelRunner(
            profile: localProfile(reconnects: false), connect: lossConnections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080), sleeper: TunnelRecordedSleeper().sleep)
        let lossStates = TunnelStateCollector(lossRunner.states)
        await lossRunner.start(decider: .asking { _ in true })
        try await lossStates.waitFor(.active(connections: 0))
        lossConnections.made[0].drop()
        try await lossStates.waitFor(.failed(.connectionLost))
        #expect(await lossRunner.failureReason != nil)
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

    /// A run that ended BY ITSELF leaves the runner startable: the terminal
    /// `.needsConfirmation` this task introduces is only a recovery path if
    /// `start(decider:)` works afterwards without anyone calling `stop()`
    /// first.
    ///
    /// Fix round 1: `task` used to be cleared only in `stop()`, so after a
    /// terminal state `start(decider:)` was a silent no-op — no state, no
    /// log line, no dial. The whole "connect this session once by hand, then
    /// start the tunnel again" story was dead, and nothing said so.
    @Test func aRunnerThatNeedsConfirmationCanBeStartedAgainWithoutStopping() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: StoredSessionConnectionError.secretRequired(checked: []))
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .refusing)
        try await states.waitFor(.needsConfirmation)

        // No `stop()` in between — that is the whole point.
        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        #expect(connections.made.count == 1)

        await runner.stop()
    }

    /// The same for a terminal `.failed`, which additionally needs the
    /// plan's `(.failed, .start) → .connecting` row: without it the runner
    /// would dial while its state still read `.failed`.
    @Test func aFailedRunnerCanBeStartedAgainWithoutStopping() async throws {
        let connections = TunnelFakeConnections()
        connections.failAttempts([1], with: TunnelFailure.connectFailed(reason: "no route"))
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitForFailure()

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.connecting)
        try await states.waitFor(.active(connections: 0))

        await runner.stop()
    }

    /// A dial that `stop()` cancelled, whose decider then reports the host
    /// key as refused, must NOT publish `.needsConfirmation` on the way out
    /// of a stop.
    ///
    /// Fix round 1: cancellation used to be classified AFTER `needsAPerson`,
    /// so a stop that landed while the dial was in flight ended in
    /// `.needsConfirmation` — a state the user never asked for, plus a
    /// `needs confirmation` line in the log — instead of `.stopped`.
    @Test func aDialCancelledByStopIsNotAConfirmation() async throws {
        let dialling = TunnelCallCounter()
        let connect: TunnelRunner.Connect = { _ in
            dialling.record()
            // Parks until `stop()` cancels the run task, then reports what a
            // refusing decider reports.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            throw HostKeyError.rejectedByUser
        }
        let runner = TunnelRunner(
            profile: localProfile(), connect: connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080),
            sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .refusing)
        try await pollUntil("the dial to be in flight") { dialling.count == 1 }
        await runner.stop()

        #expect(await runner.state == .stopped)
        let reachedConfirmation = states.recorded.contains(.needsConfirmation)
        #expect(reachedConfirmation == false)
    }

    /// The race the fix round's CRITICAL names: `stop()` clears `task` and
    /// then SUSPENDS on the run task's own teardown, leaving the actor free.
    /// A `start(decider:)` that lands in that window used to see
    /// `task == nil`, dial a second connection and bind a second forward —
    /// and the resuming `stop()` would tear THOSE down and publish
    /// `.stopped` over a tunnel that was up.
    ///
    /// Driven exactly: the first runtime's `stop()` parks on a latch this
    /// test holds, so the window stays open for as long as the test needs
    /// rather than for however long a scheduler happens to give it.
    ///
    /// The assertion that catches the defect is `connections.made.count == 1`
    /// WHILE the window is open — in the pre-fix code the restart dials
    /// there and then; in the fixed code it cannot dial until the stop has
    /// finished. The full published sequence afterwards is the second half:
    /// `.stopped` belongs to the stop the user asked for, and the restart's
    /// `.connecting`/`.active` follow it in that order rather than being
    /// swallowed (the state was still `.active` inside the window, and
    /// `(.active, .start)` is not a row in the plan's table, so every event
    /// the second run published there would have been a no-op).
    @Test func aStartThatLandsWhileStopIsSuspendedWaitsForIt() async throws {
        let latch = TunnelLatch()
        // A failing expectation below would otherwise leave the gated
        // teardown parked for the rest of the process: `TunnelLatch.wait()`
        // ignores cancellation on purpose, so nothing else ends it.
        defer { latch.release() }
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080, firstStopGate: latch)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        let stopping = Task { await runner.stop() }
        // The first runtime's `stop()` has been ENTERED and is parked, so
        // the run task cannot finish and the stop is suspended on it.
        try await pollUntil("the first runtime's stop to be parked") {
            runtimes.made[0].stopEntered == 1
        }

        let entered = TunnelCallCounter()
        let restarting = Task {
            entered.record()
            await runner.start(decider: .asking { _ in true })
        }
        try await pollUntil("the restart task to begin") { entered.count == 1 }
        // The restart is ON the chain, not merely running: `queuedCommands`
        // is bumped in the same actor step that appends to it. Round 2 used
        // a 50× `Task.yield()` loop here, which proved only that a `Task`
        // had been scheduled — the window could have been released before
        // the restart ever reached the actor, and the test would have passed
        // for the wrong reason.
        try await pollUntil("the restart to be queued") {
            await runner.queuedCommands == 3
        }
        #expect(connections.made.count == 1)
        #expect(runtimes.made.count == 1)

        latch.release()
        await stopping.value
        await restarting.value
        try await states.waitFor(.stopped)
        try await states.waitFor(.connecting)
        try await states.waitFor(.active(connections: 0))

        #expect(connections.made.count == 2)
        // The first stop released the FIRST run's resources and nothing
        // else.
        #expect(connections.made[0].disconnectCount == 1)
        #expect(runtimes.made[0].stopCount == 1)
        #expect(connections.made[1].disconnectCount == 0)
        #expect(runtimes.made[1].stopCount == 0)
        #expect(await runner.state == .active(connections: 0))
        #expect(
            states.recorded == [
                .connecting, .active(connections: 0), .stopped,
                .connecting, .active(connections: 0),
            ])

        await runner.stop()
        try await states.waitFor(.stopped)
        #expect(connections.made[1].disconnectCount == 1)
    }

    /// The mirror of the window above, and the one round 1 got wrong: a
    /// STOP that arrives while a START is already waiting must still be the
    /// last word.
    ///
    /// Round 1 gave `stop()` a coalescing branch — "a stop already in
    /// flight does the same work, so just await it and return" — which is
    /// sound only if nothing can begin a run between that first stop
    /// finishing and this one returning. A parked `start` is exactly that:
    /// stop A runs, start B is parked behind it, stop C coalesces onto A;
    /// A finishes, C returns satisfied, and B then resumes and dials. The
    /// caller's last command was stop and the tunnel comes up anyway, with a
    /// live SSH connection `stop()`'s own doc comment promises is gone.
    ///
    /// The fix is one command chain in actor-entry order, so C is queued
    /// BEHIND B and undoes it. This test drives that order deliberately: A
    /// is parked on a latch, and B and C are each let onto the actor before
    /// the next is started.
    @Test func aStopThatArrivesWhileAStartIsWaitingWins() async throws {
        let latch = TunnelLatch()
        defer { latch.release() }
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 8080, firstStopGate: latch)
        let runner = TunnelRunner(
            profile: localProfile(), connect: connections.connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))

        // A: parked on the first runtime's teardown.
        let stopA = Task { await runner.stop() }
        try await pollUntil("the first runtime's stop to be parked") {
            runtimes.made[0].stopEntered == 1
        }

        // B: queued behind A.
        let enteredB = TunnelCallCounter()
        let startB = Task {
            enteredB.record()
            await runner.start(decider: .asking { _ in true })
        }
        try await pollUntil("the start to begin") { enteredB.count == 1 }
        try await pollUntil("the start to be queued behind the stop") {
            await runner.queuedCommands == 3
        }

        // C: queued behind B — which is the whole property.
        let enteredC = TunnelCallCounter()
        let stopC = Task {
            enteredC.record()
            await runner.stop()
        }
        try await pollUntil("the second stop to begin") { enteredC.count == 1 }
        try await pollUntil("the second stop to be queued behind the start") {
            await runner.queuedCommands == 4
        }

        latch.release()
        await stopA.value
        await startB.value
        await stopC.value

        #expect(await runner.state == .stopped)
        // The arrival-order assertion: TWO connections were dialled, so B
        // took effect and C then undid it. One would mean C overtook B — the
        // tunnel stopped, but by a stop that ran before the start it was
        // supposed to follow, which is a different (and equally wrong)
        // ordering from the one this test is about.
        #expect(connections.made.count == 2)
        // Whatever B dialled — a whole connection, or none at all — is gone.
        let leaked = connections.made.filter { $0.disconnectCount == 0 }
        #expect(leaked.isEmpty)
        #expect(runtimes.made.allSatisfy { $0.stopCount == 1 })
        #expect(states.recorded.last == .stopped)
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
