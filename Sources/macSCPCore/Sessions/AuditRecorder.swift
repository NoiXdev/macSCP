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
    public func recordConnected(host: String, username: String) {
        store.append(
            AuditEvent(kind: .connected, detail: "connected to \(host) as \(username)"),
            for: sessionID)
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
    public func recordTransfer(_ item: TransferQueueViewModel.Item, targetTitle: String?) {
        let verb = item.direction == .upload ? "upload" : "download"
        let baseDetail = "\(verb) \(item.fileName)"

        switch item.status {
        case .finished:
            if item.isEditUpload {
                store.append(AuditEvent(kind: .editUpload, detail: baseDetail), for: sessionID)
            } else if item.destinationTabID != nil {
                let target = targetTitle ?? "unknown session"
                store.append(
                    AuditEvent(kind: .crossSessionTransfer, detail: "to “\(target)”: \(item.fileName)"),
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
