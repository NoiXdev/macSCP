import Foundation

/// What a running tunnel's lifecycle reports to `TunnelStatePlan.next(_:on:)`
/// — never anything a tunnel's owner (`TunnelManager`, App layer, a later
/// task) has not itself observed. `retryDue` carries no payload: it is a
/// timer firing, not a report about the connection, so the attempt number
/// it applies to is whatever `TunnelState.reconnecting(attempt:)` already
/// holds.
public enum TunnelEvent: Sendable, Equatable {
    /// The context menu (or autostart) asked the tunnel to run.
    case start
    /// The SSH connection came up. Reported for completeness; the plan
    /// treats it as a no-op — see `TunnelStatePlan.next(_:on:)`'s doc
    /// comment for why.
    case connected
    /// The listener is up (local/dynamic) or the remote registration is
    /// acknowledged (remote): the tunnel can now carry traffic.
    case listening
    /// One more connection was accepted and pumped.
    case connectionAccepted
    /// One pumped connection finished (either side closed).
    case connectionClosed
    /// One accepted connection could not be carried: its channel through the
    /// server could not be opened, or (remote forward) its local target
    /// could not be reached. The forward itself is still up. A SOCKS5 client
    /// that never named a destination is not reported — that is the
    /// client's failure, not the tunnel's.
    case connectionFailed(TunnelFailureKind)
    /// The tunnel's own SSH connection dropped. `reconnects` carries the
    /// profile's own `reconnects` flag, not a retry state — it says whether
    /// this LOSS should be retried at all.
    case connectionLost(reconnects: Bool)
    /// A reconnect attempt has produced a live connection and forward — the
    /// event that takes a tunnel out of `reconnecting` and back toward
    /// `active`.
    ///
    /// **Not the backoff timer firing**, which is what this comment used to
    /// say and what its name suggests. `TunnelRunner` feeds it AFTER the
    /// retry's dial has succeeded, immediately before `listening`, and the
    /// reason is this table's own shape: `reconnecting(k) + connectionLost
    /// → reconnecting(k + 1)` is the only row that increments an attempt,
    /// and it is reachable only while the state is still `reconnecting`. Fed
    /// at the timer, the state would already be `connecting`, so a retry
    /// that failed would take `connecting + connectionLost →
    /// reconnecting(1)` and reset the count every time — flattening
    /// `BackoffPlan`'s 2, 4, 8, 16 … into 2, 2, 2, 2 …. Measured by
    /// `TunnelRunnerTests.aFailedRetryKeepsClimbing`, which goes red against
    /// exactly that placement.
    ///
    /// One consequence for a caller: a SUCCESSFUL reconnect therefore
    /// publishes a transient `connecting` between `reconnecting(k)` and
    /// `active(0)`, because this event lands one step before `listening`.
    case retryDue
    /// A step failed in a way that ends the run outright (a listener could
    /// not bind, autostart met `.needsConfirmation`'s own precondition
    /// turning into an outright failure, etc.). Carries the kind, never a
    /// sentence and never a secret — same rule as `TunnelState.failed`.
    case failed(TunnelFailureKind)
    /// The context menu (or the quit chain's `stopAll()`) asked the tunnel
    /// to stop.
    case stop
    /// Autostart met an unknown host key or a missing secret and refused
    /// rather than prompt.
    case needsConfirmation
}

/// The pure state machine a running tunnel's state moves through. Contains
/// no I/O, no timers, no SSH — `TunnelRunner` (a later task) is the thing
/// that turns real events (a channel closing, a backoff timer firing) into
/// `TunnelEvent` values and feeds them through here; this type only ever
/// computes what state one such event produces next.
public enum TunnelStatePlan {
    /// The full transition table, exactly as implemented below — every row
    /// not listed here returns `state` unchanged (a `TunnelRunner` bug
    /// reported an event that could not apply, or an event arrived after
    /// the tunnel already moved on; neither is a reason to crash or to
    /// guess a state nobody asked for).
    ///
    /// | From | Event | To |
    /// |---|---|---|
    /// | `stopped` | `start` | `connecting` |
    /// | `needsConfirmation` | `start` | `connecting` |
    /// | `connecting` | `connected` | `connecting` (unchanged — see below) |
    /// | `connecting` | `listening` | `active(0, 0, nil)` |
    /// | `active(n, f, k)` | `connectionAccepted` | `active(n+1, 0, nil)` |
    /// | `active(n, f, k)` | `connectionClosed` | `active(max(0, n−1), f, k)` |
    /// | `active(n, f, _)` | `connectionFailed(kind)` | `active(n, f+1, kind)` |
    /// | `active` or `connecting` | `connectionLost(reconnects: true)` | `reconnecting(1)` |
    /// | `active` or `connecting` | `connectionLost(reconnects: false)` | `failed(.connectionLost)` |
    /// | `reconnecting(k)` | `retryDue` | `connecting` |
    /// | `failed` | `start` | `connecting` |
    /// | `reconnecting(k)` | `connectionLost` | `reconnecting(k+1)` |
    /// | any | `failed(kind)` | `failed(kind)` |
    /// | any | `stop` | `stopped` |
    /// | `connecting` | `needsConfirmation` | `needsConfirmation` |
    ///
    /// **`connected` is a no-op.** NIO's own connect/listen split means the
    /// SSH connection coming up and the forward itself being usable are two
    /// separate moments — a `local`/`dynamic` listener has to bind, a
    /// `remote` registration has to be acknowledged by the server — so
    /// `connected` alone does not yet make the tunnel `active`. It is kept
    /// as its own event (rather than dropped) so a caller can log or show
    /// "connecting…" progress without the plan inventing a state for it;
    /// `listening` is the event that actually advances to `active(0)`.
    ///
    /// **A failed connection is counted, never a lifecycle change.** The
    /// forward is up, so `failed` would be untrue; `connectionFailed` only
    /// moves `active`'s `failedConnections`/`lastFailure`, the next
    /// `connectionAccepted` clears them, and every other state ignores it.
    /// A reconnect clears them by construction: its `active` comes from
    /// `listening`, which starts at `0`/`nil`.
    ///
    /// **`reconnecting(k) + connectionLost → reconnecting(k+1)`, regardless
    /// of the event's own `reconnects` flag.** That flag is the profile's
    /// setting, fixed for the profile's whole run, so a tunnel that is
    /// already `reconnecting` only ever got there because the flag was
    /// `true` (a `false` flag routes the very first loss straight to
    /// `failed`, per the row above); a further loss while reconnecting
    /// keeps retrying rather than re-reading a flag that cannot have
    /// changed.
    public static func next(_ state: TunnelState, on event: TunnelEvent) -> TunnelState {
        switch (state, event) {
        // A failed tunnel restarts from the context menu — the design says
        // so, and `TunnelRunner.runEnded(_:)` makes it reachable by clearing
        // its own task when a run ends by itself. Without this row the
        // runner would dial while its state still read `failed`, so the
        // sidebar would show a failure over a connection being made.
        case (.stopped, .start), (.needsConfirmation, .start), (.failed, .start):
            return .connecting

        case (.connecting, .connected):
            return .connecting

        case (.connecting, .listening):
            return .active(connections: 0)

        // A connection that opened proves the forward carries traffic
        // again, so the failures before it are history; a close says
        // nothing about them either way and leaves them.
        case (.active(let connections, _, _), .connectionAccepted):
            return .active(connections: connections + 1, failedConnections: 0, lastFailure: nil)

        case (.active(let connections, let failed, let last), .connectionClosed):
            return .active(
                connections: max(0, connections - 1), failedConnections: failed, lastFailure: last)

        case (.active(let connections, let failed, _), .connectionFailed(let kind)):
            return .active(connections: connections, failedConnections: failed + 1, lastFailure: kind)

        case (.active, .connectionLost(let reconnects)), (.connecting, .connectionLost(let reconnects)):
            return reconnects ? .reconnecting(attempt: 1) : .failed(.connectionLost)

        case (.reconnecting, .retryDue):
            return .connecting

        case (.reconnecting(let attempt), .connectionLost):
            return .reconnecting(attempt: attempt + 1)

        case (_, .failed(let kind)):
            return .failed(kind)

        case (_, .stop):
            return .stopped

        case (.connecting, .needsConfirmation):
            return .needsConfirmation

        default:
            return state
        }
    }
}

/// Reconnect backoff: 2 s, doubling on every attempt, capped at 60 s — the
/// series `2, 4, 8, 16, 32, 60, 60, …` for attempts `1, 2, 3, 4, 5, 6, 7,
/// …`. Pure and injectable: `TunnelRunner` (a later task) reads a `Duration`
/// from here and hands it to whatever timer it actually schedules, so a
/// test never has to wait on a real clock for this.
public enum BackoffPlan {
    /// `attempt` is 1-based (`TunnelState.reconnecting(attempt:)`'s own
    /// numbering); `attempt <= 0` is treated as `1` — the first attempt's
    /// delay — rather than as an error, since a caller only ever reaches
    /// this with a `reconnecting` state's attempt count, which starts at 1
    /// and only grows.
    public static func delay(attempt: Int) -> Duration {
        let effectiveAttempt = max(1, attempt)
        // 2^effectiveAttempt seconds (2 * 2^(n-1) == 2^n) — the exponent is
        // clamped to 6 BEFORE shifting, not after computing, so a caller
        // passing an unbounded reconnect counter cannot overflow `Int` on
        // the way to a result the cap would have discarded anyway: 2^6 = 64
        // already exceeds the 60 s cap, so no exponent above 6 changes the
        // answer.
        let clampedExponent = min(effectiveAttempt, 6)
        let seconds = min(60, 1 << clampedExponent)
        return .seconds(seconds)
    }
}
