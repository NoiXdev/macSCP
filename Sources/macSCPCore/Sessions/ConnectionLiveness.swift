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
}

public enum ReconnectBackoff {
    public static func delay(forAttempt attempt: Int) -> Int {
        guard attempt > 1 else { return 5 }
        return min(60, 5 * (1 << min(attempt - 1, 10)))
    }
}
