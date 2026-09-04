import Foundation

/// Maps queue-item terminal transitions and browser-action outcomes to
/// `AuditEvent`s and appends them to one session's audit log (M9b). Mirrors
/// `AuditLogStore`'s throw-free contract: every method here is a plain,
/// non-throwing call — a broken log must never disturb a transfer or file
/// action.
public struct AuditRecorder: Sendable {
    public let sessionID: UUID
    private let store: AuditLogStore

    public init(sessionID: UUID, store: AuditLogStore) {
        self.sessionID = sessionID
        self.store = store
    }

    /// Logs a successful connect. The App layer calls this once a stored
    /// session's connection succeeds.
    ///
    /// `viaJumpHost` (M11e/T2) names a jump ("ProxyJump") hop this connect
    /// went through — pass `stored.jump?.host` (or the form's jump-block
    /// host, when a jump is actually enabled). Defaulted to `nil` so
    /// existing callers keep compiling and the no-jump detail stays
    /// byte-identical to before. SECURITY: only the jump HOST ever appears
    /// here — never the bastion's username, secret, or a forced port; a
    /// port is present only if it was already baked into the host string.
    public func recordConnected(host: String, username: String, viaJumpHost: String? = nil) {
        var detail = "connected to \(host) as \(username)"
        if let viaJumpHost {
            detail += " via \(viaJumpHost)"
        }
        store.append(AuditEvent(kind: .connected, detail: detail), for: sessionID)
    }

    /// Logs a successful connect using the backend's own `displaySummary`
    /// (M22/T11) — the same label the sidebar and tab title show — instead of
    /// the `host`/`username` pair above, which only SSH ever fills. Before
    /// this existed, a stored S3 or WebDAV session's `host`/`username`
    /// columns carried the `"unused"` placeholder (see
    /// `ContentView.attachAuditRecorder`'s call sites), so the audit trail
    /// read "connected to unused as unused" for every non-SSH connect.
    ///
    /// Kept alongside `recordConnected(host:username:viaJumpHost:)` rather
    /// than replacing it: that sibling's exact detail text
    /// ("connected to HOST as USERNAME") is pinned by existing tests and
    /// remains a valid, independently useful shape for a caller that already
    /// has a real host/username pair in hand.
    public func recordConnected(summary: String, viaJumpHost: String? = nil) {
        var detail = "connected to \(summary)"
        if let viaJumpHost {
            detail += " via \(viaJumpHost)"
        }
        store.append(AuditEvent(kind: .connected, detail: detail), for: sessionID)
    }

    /// Logs a connect that did NOT succeed (session overview plan, Task 2) —
    /// the producer for the `connectFailed` kind Task 1 added, and the row
    /// the session overview offers "Open diagnosis" on.
    ///
    /// `reason` is stored verbatim, and the caller owes it a FIXED sentence:
    /// `DialSupport.reason(for:)`, which is public for exactly this call and
    /// documents why an error's own text must not be stored instead — the
    /// two URL-shaped backends compose their free-text failures out of an
    /// endpoint field that takes `scheme://KEY:SECRET@host` as ordinary
    /// input. Nothing is composed here: unlike `recordConnected`, which
    /// builds "connected to HOST as USER", there is no shape to add.
    ///
    /// `isError: true`, which is what the audit sheet's "Errors" facet
    /// selects on (`AuditLogSheet.matches`'s `.errors` arm returns
    /// `event.isError` and reads no kind) and what paints the row red there.
    /// Recorded as an ordinary event, a failed connect would sit outside
    /// that facet entirely. The session overview's own red row is decided
    /// differently — by `ConnectionHistory.Row.Outcome.failed`, which this
    /// kind produces regardless of the flag — so this line is about the
    /// sheet, not about both surfaces.
    public func recordConnectFailed(reason: String) {
        store.append(
            AuditEvent(kind: .connectFailed, detail: reason, isError: true), for: sessionID)
    }

    /// Logs a teardown/disconnect. The App layer calls this from the tab's
    /// teardown flow, before the recorder itself is released.
    public func recordDisconnected() {
        store.append(AuditEvent(kind: .disconnected, detail: "disconnected"), for: sessionID)
    }

    /// Maps a queue item's CURRENT status to an audit event, per the M9b
    /// design spec §3:
    /// - `.finished` + `isEditUpload` → `.editUpload`
    /// - `.finished` + `destinationTabID != nil` → `.crossSessionTransfer`,
    ///   detail names `targetTitle` (or "unknown session" if the target tab
    ///   is already gone)
    /// - `.finished` (plain) → `.transferFinished`
    /// - `.failed(message)` → `.transferFailed`, `isError: true`
    /// - `.cancelled` → `.transferCancelled`
    /// - `.queued`/`.running`/`.skipped`/`.interrupted` → no event; this is
    ///   the queue's single terminal-transition sink, so a plain `.skipped`/
    ///   `.interrupted` item (or a non-terminal one) is deliberately silent —
    ///   not every terminal state is audit-worthy (M9b spec §1).
    ///
    /// The spec (binding, maintainer-approved) requires "Richtung, Name,
    /// Ziel" (direction, name, destination) — its own worked example is
    /// `upload report.pdf → /var/www` (M9b/T4 review, finding 3). Every
    /// detail below therefore names `item.destinationDirectory`, not just
    /// the file name.
    public func recordTransfer(_ item: TransferQueueViewModel.Item, targetTitle: String?) {
        // Through `AuditEvent.TransferVerb` rather than a literal pair: the
        // overview's recent-connections list reads the direction back out of
        // this text (`AuditEvent.transferVerb`), and a second spelling of the
        // word here is exactly what would let the reader and the writer drift
        // apart in silence. The detail shape itself is unchanged — spec M9b
        // requires "direction, name, destination", e.g.
        // `upload report.pdf → /var/www`.
        let verb = AuditEvent.TransferVerb(item.direction).rawValue
        let baseDetail = "\(verb) \(item.fileName) → \(item.destinationDirectory)"

        switch item.status {
        case .finished:
            if item.isEditUpload {
                store.append(AuditEvent(kind: .editUpload, detail: baseDetail), for: sessionID)
            } else if item.destinationTabID != nil {
                let target = targetTitle ?? "unknown session"
                store.append(
                    AuditEvent(
                        kind: .crossSessionTransfer,
                        detail: "to “\(target)”: \(item.fileName) → \(item.destinationDirectory)"),
                    for: sessionID)
            } else {
                store.append(AuditEvent(kind: .transferFinished, detail: baseDetail), for: sessionID)
            }
        case .failed(let message):
            store.append(
                AuditEvent(kind: .transferFailed, detail: baseDetail, isError: true, errorMessage: message),
                for: sessionID)
        case .cancelled:
            store.append(AuditEvent(kind: .transferCancelled, detail: baseDetail), for: sessionID)
        case .queued, .running, .skipped, .interrupted:
            return
        }
    }

    /// Appends a pre-built event — the four browser actions (rename,
    /// createFolder, applyPermissions, deleteItems) construct their own
    /// `AuditEvent` (kind/detail/error already resolved) and pass it through
    /// here unmodified.
    public func recordAction(_ event: AuditEvent) {
        store.append(event, for: sessionID)
    }
}
