import Testing
@testable import macSCPCore

@Suite("TunnelStatePlan")
struct TunnelStatePlanTests {
    private typealias Row = (state: TunnelState, event: TunnelEvent, expected: TunnelState)

    /// Every row of `TunnelStatePlan.next(_:on:)`'s own transition table,
    /// one entry per row — a change to the table is a change to this list,
    /// not a surprise in the implementation alone. Built with individual
    /// `append` calls rather than one large array literal: the latter gives
    /// the type checker one huge expression to solve across many
    /// same-named enum cases, which is slow enough to time out; each
    /// `append` call here is its own small, independently-checked
    /// expression.
    private static let rows: [Row] = {
        var rows: [Row] = []
        rows.append((.stopped, .start, .connecting))
        rows.append((.needsConfirmation, .start, .connecting))
        rows.append((.connecting, .connected, .connecting))
        rows.append((.connecting, .listening, .active(connections: 0)))
        rows.append((.active(connections: 3), .connectionAccepted, .active(connections: 4)))
        rows.append((.active(connections: 1), .connectionClosed, .active(connections: 0)))
        rows.append((.active(connections: 0), .connectionClosed, .active(connections: 0)))
        rows.append(
            (.active(connections: 2), .connectionLost(reconnects: true), .reconnecting(attempt: 1)))
        rows.append((.connecting, .connectionLost(reconnects: true), .reconnecting(attempt: 1)))
        rows.append(
            (.active(connections: 2), .connectionLost(reconnects: false),
             .failed(.connectionLost)))
        rows.append(
            (.connecting, .connectionLost(reconnects: false), .failed(.connectionLost)))
        rows.append((.reconnecting(attempt: 1), .retryDue, .connecting))
        rows.append((.reconnecting(attempt: 4), .retryDue, .connecting))
        rows.append(
            (.reconnecting(attempt: 1), .connectionLost(reconnects: true), .reconnecting(attempt: 2)))
        rows.append(
            (.reconnecting(attempt: 2), .connectionLost(reconnects: true), .reconnecting(attempt: 3)))
        // The `reconnects` flag is ignored once already `.reconnecting` —
        // see `TunnelStatePlan.next(_:on:)`'s own doc comment for why — so
        // a `false` flag here still advances the attempt count rather than
        // failing.
        rows.append(
            (.reconnecting(attempt: 1), .connectionLost(reconnects: false), .reconnecting(attempt: 2)))
        rows.append((.stopped, .failed(.unknown), .failed(.unknown)))
        rows.append((.connecting, .failed(.bindFailed), .failed(.bindFailed)))
        rows.append(
            (.active(connections: 1), .failed(.portInUse(port: 8080)), .failed(.portInUse(port: 8080))))
        rows.append((.reconnecting(attempt: 2), .failed(.connectionFailed), .failed(.connectionFailed)))
        rows.append((.connecting, .stop, .stopped))
        rows.append((.active(connections: 5), .stop, .stopped))
        rows.append((.reconnecting(attempt: 3), .stop, .stopped))
        rows.append((.failed(.unknown), .stop, .stopped))
        rows.append((.stopped, .stop, .stopped))
        rows.append((.connecting, .needsConfirmation, .needsConfirmation))
        // A failed tunnel restarts from the context menu — the design says
        // so, and without this row `TunnelRunner.start(decider:)` would dial
        // with the state stuck at `.failed`, so the UI would show a failure
        // while a connection was being made. Added in Task 5's fix round 1
        // together with the runner clearing its own `task` when a run ends
        // by itself; before that, a terminal state could not be restarted at
        // all and the gap was invisible.
        rows.append((.failed(.bindFailed), .start, .connecting))
        return rows
    }()

    @Test("table row", arguments: Self.rows)
    private func transition(_ row: Row) {
        #expect(TunnelStatePlan.next(row.state, on: row.event) == row.expected)
    }

    private typealias UnknownRow = (state: TunnelState, event: TunnelEvent)

    /// Unknown combinations return the state unchanged — the table's own
    /// documented default, not merely an implementation detail.
    private static let unknownRows: [UnknownRow] = {
        var rows: [UnknownRow] = []
        rows.append((.stopped, .connected))
        rows.append((.stopped, .listening))
        rows.append((.stopped, .connectionAccepted))
        rows.append((.stopped, .retryDue))
        rows.append((.active(connections: 0), .start))
        rows.append((.needsConfirmation, .listening))
        rows.append((.needsConfirmation, .connected))
        return rows
    }()

    @Test("unknown combination leaves the state unchanged", arguments: Self.unknownRows)
    private func unknownCombinationIsUnchanged(_ row: UnknownRow) {
        #expect(TunnelStatePlan.next(row.state, on: row.event) == row.state)
    }

    @Test(
        "backoff series", arguments: [
            (0, 2), (1, 2), (2, 4), (3, 8), (4, 16), (5, 32), (6, 60), (7, 60), (8, 60),
        ]
    )
    func backoffDelay(attempt: Int, expectedSeconds: Int) {
        #expect(BackoffPlan.delay(attempt: attempt) == .seconds(expectedSeconds))
    }
}
