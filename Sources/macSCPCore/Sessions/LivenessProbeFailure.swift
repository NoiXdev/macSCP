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
/// Carries no raw error. `reason` is `DialSupport.reason(for:)`'s fixed
/// sentence, passed through the log's userinfo filter and with the probed
/// path replaced — see `classify(_:probedPath:)`.
public enum LivenessProbeFailure: Equatable, Sendable {
    /// The deadline won: no answer within `seconds`.
    case timeout(seconds: Int)
    /// The probe's `stat` threw. `typeName` is the error's Swift type name;
    /// `closedConnection` is whether the error is one of the shapes that
    /// mean the connection itself is gone.
    case error(typeName: String, reason: String, closedConnection: Bool)
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
        case .error(_, _, let closedConnection): return closedConnection ? .connectionClosed : .other
        case .cancelled: return .other
        }
    }

    /// What the probe's `stat` threw, classified. Pure: the same error and
    /// path always give the same value.
    ///
    /// `probedPath` is the path the probe stats — the session's home, which
    /// typically names the account (`/home/<user>`). `DialSupport.reason(for:)`
    /// prints the path for `notFound` and `permissionDenied`, so the path is
    /// replaced by `<home>` here; a path of `/` is left alone, because
    /// replacing every slash would destroy the sentence and `/` names no one.
    public static func classify(_ error: any Error, probedPath: String) -> LivenessProbeFailure {
        if error is CancellationError { return .cancelled }
        var reason = URLText.withoutUserinfo(DialSupport.reason(for: error))
        if probedPath.count > 1 {
            reason = reason.replacingOccurrences(of: probedPath, with: "<home>")
        }
        return .error(
            typeName: String(describing: type(of: error)), reason: reason,
            closedConnection: closesConnection(error))
    }

    /// `RemoteFSError.connectionFailed` is what `CitadelFileSystem` maps a
    /// dead channel to (`mapSFTPError`); the raw shapes are checked too, so
    /// an error that reached the probe unmapped is still read correctly.
    private static func closesConnection(_ error: any Error) -> Bool {
        if case RemoteFSError.connectionFailed = error { return true }
        return CitadelFileSystem.isConnectionLoss(error)
    }
}

/// The diagnostic log's lines about a tab's liveness and its SSH
/// connections (lost-connection cause, 2026-09-19). Built here, as plain
/// functions over values, so a test can read the exact text a call site
/// logs; the call sites pass these straight to `DiagnosticLog.shared.log`.
///
/// A tab is named by its id only — a UUID minted per tab, the same form the
/// window-move lines name a seed by. No host, no user, no path.
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

    /// `detail=` last: it is a sentence, and everything before it is one
    /// word per key.
    private static func fields(_ failure: LivenessProbeFailure) -> String {
        switch failure {
        case .timeout(let seconds):
            return "cause=timeout kind=\(failure.kind.rawValue) after=\(seconds)s"
        case .error(let typeName, let reason, _):
            return "cause=error kind=\(failure.kind.rawValue) type=\(typeName) detail=\(reason)"
        case .cancelled:
            return "cause=cancelled kind=\(failure.kind.rawValue)"
        }
    }
}
