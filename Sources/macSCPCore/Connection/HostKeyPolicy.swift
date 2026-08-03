import Foundation

/// What to do about an UNKNOWN host key. Deliberately says nothing about a
/// MISMATCH: that is a hard stop decided in `HostKeyValidation` before any
/// decider is consulted, and no policy value can soften it (M3c invariant).
public enum HostKeyPolicy: String, CaseIterable, Sendable {
    /// Ask the user when possible; refuse when there is nobody to ask.
    case ask
    /// Never trust anything new, not even interactively.
    case reject
    /// Trust unknown keys without asking — the `--accept-new` opt-in, for
    /// first-time provisioning. Says nothing about mismatches.
    case acceptNew
}

public enum HostKeyDecision: Equatable, Sendable {
    case prompt
    case accept
    case reject
}

extension HostKeyPolicy {
    /// Pure decision, so every combination is provable in a test rather than
    /// argued about. Note the asymmetry: `.ask` without a terminal becomes
    /// `.reject`, never `.accept` — a missing human is not consent.
    public static func decision(for policy: HostKeyPolicy, hasTTY: Bool) -> HostKeyDecision {
        switch policy {
        case .reject: return .reject
        case .acceptNew: return .accept
        case .ask: return hasTTY ? .prompt : .reject
        }
    }
}
