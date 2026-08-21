/// What a session's connection is doing right now. Four states, three
/// colours: `connecting` and `degraded` share amber, because both mean
/// "macSCP does not know yet" and the user's next move is the same — wait
/// or cancel.
public enum ConnectionLiveness: Equatable, Sendable {
    case connecting
    case connected
    /// One probe failed and a second is on its way. Without this state a
    /// single lost packet would look exactly like a severed connection.
    case degraded
    case lost
}

public enum LivenessProbeAction: Equatable, Sendable {
    case skip
    case probe
    case probeAgainNow
    case giveUp
}

public enum LivenessProbePolicy {
    public static func decide(queueIsBusy: Bool, consecutiveFailures: Int) -> LivenessProbeAction {
        if queueIsBusy { return .skip }
        switch consecutiveFailures {
        case 0: return .probe
        case 1: return .probeAgainNow
        default: return .giveUp
        }
    }

    /// Deliberately not a setting: a probe timeout longer than the interval
    /// would let probes overlap, and a user-editable settings file could
    /// produce exactly that.
    public static func probeTimeout(forInterval interval: Int) -> Int {
        max(1, min(10, interval / 2))
    }

    /// How long the probe loop sleeps before rechecking
    /// `keepAliveIntervalSeconds` while that setting reads `0` ("no probe at
    /// all") — a fixed, short beat, not a zero-length sleep (which would
    /// spin the loop) and not the interval itself (which does not exist
    /// while the probe is off). This bounds only how quickly turning the
    /// probe back ON takes effect; WIDENING an already-running interval
    /// (e.g. 600 seconds down to 15, or the reverse) only takes effect once
    /// the current sleep completes, up to the OLD interval's own length —
    /// "applies without restart" holds up to one stale interval, not
    /// instantly.
    public static let idleRecheckSeconds = 5
}

public enum ReconnectBackoff {
    public static func delay(forAttempt attempt: Int) -> Int {
        guard attempt > 1 else { return 5 }
        return min(60, 5 * (1 << min(attempt - 1, 10)))
    }
}

/// What macSCP does when a session's connection is found gone. Persisted by
/// `SettingsStore.reconnectBehaviour`; lives next to the liveness/backoff
/// policy it configures rather than in `Settings/`, since the three cases
/// only make sense read together with `LivenessProbePolicy` and
/// `ReconnectBackoff` above.
public enum ReconnectBehaviour: String, CaseIterable, Sendable {
    /// Nothing happens without a click. The default, because reconnecting
    /// re-authenticates — a keychain read, possibly a passphrase — and a
    /// changed host key is a hard stop that needs a person.
    case offerOnly
    case onceThenAsk
    case automatic
}
