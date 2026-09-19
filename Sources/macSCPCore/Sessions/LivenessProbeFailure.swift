import Foundation

/// Why one liveness probe did not come back alive (lost-connection cause,
/// 2026-09-19).
///
/// Before this type the probe reduced its `stat` to a `Bool` and threw the
/// error away, so a tab marked lost could not say whether the server had
/// closed the connection or had merely not answered inside the deadline —
/// the one question a lost connection through a jump host raised and the
/// app could not answer (findings of 2026-09-19).
///
/// A CLOSED SET, deliberately (review of 2026-09-19, item 1): three cases, a
/// whole-second deadline, a `Bool`, and the error's Swift type name. No
/// sentence from an error is kept — not `DialSupport.reason(for:)`'s and not
/// a `localizedDescription` — because both can name a path
/// (`nothing at <path>`), a host (`HostKeyError.mismatch`) or whatever a
/// foreign error's description happens to hold. Round 1 of this work kept
/// such a sentence, filtered; the filter was best-effort and the claim above
/// it was not. Dropping the sentence is what makes the claim structural: a
/// value of this type cannot carry text that a server, an error or a form
/// composed.
public enum LivenessProbeFailure: Equatable, Sendable {
    /// The deadline won: no answer within `seconds`.
    case timeout(seconds: Int)
    /// The probe's `stat` threw. `typeName` is the error's Swift type name
    /// — a name written in this repository or in a package it builds
    /// against, never a value; `closedConnection` is whether the error is
    /// one of the shapes that mean the connection itself is gone.
    case error(typeName: String, closedConnection: Bool)
    /// The probe's `stat` ended in a `CancellationError`.
    case cancelled

    /// The coarse cause the lost-connection surface names in a fixed,
    /// localized sentence. No text of its own — only the case.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case timeout
        case connectionClosed = "closed"
        case other
    }

    public var kind: Kind {
        switch self {
        case .timeout: return .timeout
        case .error(_, let closedConnection): return closedConnection ? .connectionClosed : .other
        case .cancelled: return .other
        }
    }

    /// What the probe's `stat` threw, classified. Pure: the same error
    /// always gives the same value.
    ///
    /// It takes the error and nothing else. Round 1 passed the probed path
    /// as well, to mask it inside a sentence; the sentence is gone (see this
    /// type's own doc comment), and a parameter that no longer takes part in
    /// the answer would read as a promise that something is being masked.
    public static func classify(_ error: any Error) -> LivenessProbeFailure {
        if error is CancellationError { return .cancelled }
        return .error(
            typeName: String(describing: type(of: error)),
            closedConnection: ConnectionLossShapes.matchesOrWasMapped(error))
    }
}

/// The diagnostic log's lines about a tab's liveness and its SSH
/// connections (lost-connection cause, 2026-09-19). Built here, as plain
/// functions over values, so a test can read the exact text a call site
/// logs; the call sites pass these straight to `DiagnosticLog.shared.log`.
///
/// A tab is named by its id only — a UUID minted per tab, the same form the
/// window-move lines name a seed by. Everything else these lines hold comes
/// from a closed set: the cases of `LivenessProbeFailure` and
/// `TransportCloseEvent`, a whole-second deadline, and an error's Swift type
/// name. No host, no user, no path, and no sentence any error, server or
/// form composed — see `LivenessProbeFailure`'s own doc comment for why that
/// is a property of the values rather than of a filter.
///
/// `DiagnosticLogSecrecyGuardTests` scans this enum's body the way it scans
/// a call site's arguments (review of 2026-09-19, item 2), so the boundary
/// `DiagnosticLog.log(_:_:_:reason:)` draws for error text holds here too.
public enum LivenessLogLines {
    /// One line per failed probe, at `info`.
    public static func probeFailed(tab: UUID, failure: LivenessProbeFailure) -> String {
        "liveness probe failed tab=\(tab) \(fields(failure))"
    }

    /// One line when the tab is marked lost, at `error`. Carries the last
    /// probe's cause in full, so a log kept at `error` level alone still
    /// says why.
    public static func connectionLost(tab: UUID, lastFailure: LivenessProbeFailure?) -> String {
        "liveness gave up, connection lost tab=\(tab) \(lastFailure.map(fields) ?? "cause=unknown")"
    }

    /// One line per SSH connection that closed, at `info`.
    public static func transportClosed(tab: UUID, event: TransportCloseEvent) -> String {
        "ssh connection closed tab=\(tab) hop=\(event.hop.rawValue) by=\(event.initiator.rawValue)"
    }

    /// One word per key, and every value a closed-set case, a number or a
    /// type name.
    private static func fields(_ failure: LivenessProbeFailure) -> String {
        switch failure {
        case .timeout(let seconds):
            return "cause=timeout kind=\(failure.kind.rawValue) after=\(seconds)s"
        case .error(let typeName, _):
            return "cause=error kind=\(failure.kind.rawValue) type=\(typeName)"
        case .cancelled:
            return "cause=cancelled kind=\(failure.kind.rawValue)"
        }
    }
}
