import Testing

@testable import macSCPCore

/// The rule that makes a forwarding nobody can use stop reading healthy
/// (maintainer answer, 2026-09-19): three connection failures in a row with
/// no success between them, and the next successful connection clears it.
///
/// Nothing here is a lifecycle change — the 2026-09-16 ruling stands, and
/// `isDegraded` is a question asked OF `.active`, never a case beside it.
/// The rule is therefore driven through `TunnelStatePlan.next(_:on:)` rather
/// than by building `.active(connections:failedConnections:lastFailure:)`
/// values by hand: what the surfaces read has to be what the report stream
/// actually produces, and the plan is the only thing that turns a report
/// into a state.
///
/// Pure, with no clock: every case below is a fold over events.
@Suite("A forwarding that keeps failing stops reading healthy")
struct TunnelDegradedRuleTests {
    /// `count` connection failures in a row, folded through the plan from
    /// `state` (a forwarding that has just started, by default).
    private static func failing(
        _ count: Int, from state: TunnelState = .active(connections: 0)
    ) -> TunnelState {
        var current = state
        for _ in 0..<count {
            current = TunnelStatePlan.next(current, on: .connectionFailed(.channelOpenFailed))
        }
        return current
    }

    /// The threshold, stated once and read from the type rather than spelled
    /// again in the cases below — the positive check beside every negative
    /// one here.
    @Test func theThresholdIsThreeInARow() {
        #expect(TunnelState.failuresBeforeDegraded == 3)
    }

    @Test func aForwardingThatHasFailedNothingReadsHealthy() {
        #expect(TunnelState.active(connections: 0).isDegraded == false)
        #expect(TunnelState.active(connections: 4).isDegraded == false)
    }

    @Test func twoFailuresInARowStillReadHealthy() {
        #expect(Self.failing(1).isDegraded == false)
        #expect(Self.failing(2).isDegraded == false)
    }

    @Test func theThirdFailureInARowStopsReadingHealthy() {
        #expect(Self.failing(3).isDegraded)
        #expect(Self.failing(9).isDegraded)
    }

    /// A success between them is what "in a row" means: the count the plan
    /// keeps IS the run length, so two, one carried connection, two more is
    /// never three in a row.
    @Test func aSuccessBetweenResetsTheCount() {
        let carried = TunnelStatePlan.next(Self.failing(2), on: .connectionAccepted)
        #expect(carried.isDegraded == false)
        #expect(Self.failing(2, from: carried).isDegraded == false)
    }

    @Test func aSuccessAfterThreeReadsHealthyAgain() {
        let degraded = Self.failing(3)
        #expect(degraded.isDegraded)
        #expect(TunnelStatePlan.next(degraded, on: .connectionAccepted).isDegraded == false)
    }

    /// A connection ENDING says nothing about whether the forwarding can
    /// carry one, so it neither sets nor clears the mark.
    @Test func aConnectionClosingLeavesTheMarkWhereItWas() {
        let degraded = TunnelStatePlan.next(Self.failing(3), on: .connectionClosed)
        #expect(degraded.isDegraded)
        let healthy = TunnelStatePlan.next(Self.failing(2), on: .connectionClosed)
        #expect(healthy.isDegraded == false)
    }

    /// A stop clears it because the state it produces is not `.active` at
    /// all, and the restart after it starts its own run of failures.
    @Test func aStopAndTheRestartAfterItClearTheCount() {
        let stopped = TunnelStatePlan.next(Self.failing(4), on: .stop)
        #expect(stopped.isDegraded == false)

        let started = TunnelStatePlan.next(stopped, on: .start)
        let listening = TunnelStatePlan.next(started, on: .listening)
        #expect(listening.isDegraded == false)
        #expect(Self.failing(2, from: listening).isDegraded == false)
    }

    /// A reconnect clears it by construction: the `.active` it ends at comes
    /// from `listening`, which starts at `0`/`nil`.
    @Test func aReconnectClearsTheCount() {
        let lost = TunnelStatePlan.next(Self.failing(5), on: .connectionLost(reconnects: true))
        #expect(lost.isDegraded == false)
        let retrying = TunnelStatePlan.next(lost, on: .retryDue)
        let listening = TunnelStatePlan.next(retrying, on: .listening)
        #expect(listening.isDegraded == false)
    }

    /// No state other than `.active` is ever degraded — driven over every
    /// case rather than over the ones that came to mind, so a seventh
    /// `TunnelState` cannot answer this quietly.
    @Test func noStateOutsideActiveIsEverDegraded() {
        let others: [TunnelState] = [
            .stopped, .connecting, .reconnecting(attempt: 4), .failed(.connectionFailed),
            .needsConfirmation,
        ]
        for state in others {
            #expect(state.isDegraded == false, "\(state) read as degraded")
        }
    }
}
