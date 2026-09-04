import Foundation

/// The session overview's "recent connections" list, derived from a
/// session's own audit log and from nothing else.
///
/// There is no per-session history store, and this design deliberately does
/// not add one (design §"Not in this design"): the audit log already records
/// every connect, disconnect and transfer, so a second store would be a
/// second truth to keep in step. What this type does is read that record the
/// way a person reads it — a `connected` opens a session, a `disconnected`
/// closes it, and whatever happened in between belongs to it.
///
/// A namespace with one entry point rather than a value anybody holds; the
/// rows are the product.
public struct ConnectionHistory: Sendable, Equatable {
    /// One connection attempt, as the overview shows it.
    public struct Row: Sendable, Equatable, Identifiable {
        /// How the attempt ended.
        ///
        /// `.connected(duration: nil)` is a session that is STILL OPEN — or
        /// one that was never closed, because the app did not live long
        /// enough to record the disconnect. The two are indistinguishable in
        /// the log, and neither has a duration, so neither gets one
        /// fabricated.
        public enum Outcome: Sendable, Equatable {
            case connected(duration: Duration?)
            /// The fixed sentence the failing event carried, verbatim. This
            /// type never composes one: the sentence comes from
            /// `DialSupport.reason(for:)` at the point the connect failed
            /// (see `AuditEvent.Kind.connectFailed`).
            case failed(reason: String)
        }

        /// The id of the event that OPENED this row — the `connected` or the
        /// `connectFailed`. Reusing that id rather than minting a fresh one
        /// keeps a row stable across a re-derivation, which is what a
        /// SwiftUI list needs to not lose its selection when the log grows.
        public let id: UUID
        public let startedAt: Date
        public let outcome: Outcome
        public let uploads: Int
        public let downloads: Int
        public let failedTransfers: Int
        /// The bytes moved during this connection, when the log says.
        ///
        /// **Always `nil` today, and honestly so.** `AuditEvent` carries no
        /// byte count in any field, and no site that appends one writes a
        /// byte count into its `detail` either: a finished transfer reads
        /// `"upload report.pdf → /var/www"` (`AuditRecorder.recordTransfer`),
        /// which names direction, file and destination and nothing else.
        /// Counted 2026-09-04 over every `AuditEvent(` construction site
        /// under `Sources/` (excluding the one in this comment): TWENTY-FIVE
        /// — `RemoteBrowserViewModel` fifteen, `AuditRecorder` eight, and one
        /// each in `ContentView` and `ContentView+Lifecycle`. None of the
        /// twenty-five names a byte count, and `AuditEvent` declares no field
        /// that could carry one.
        ///
        /// So the field is the shape the view renders against, and `nil` is
        /// its one value until an event carries the number. `0` would be a
        /// claim that nothing moved, which is a different and false
        /// sentence; deriving one from the detail text is not possible
        /// because the text does not contain one.
        public let bytes: Int64?

        public init(
            id: UUID, startedAt: Date, outcome: Outcome,
            uploads: Int, downloads: Int, failedTransfers: Int, bytes: Int64?
        ) {
            self.id = id
            self.startedAt = startedAt
            self.outcome = outcome
            self.uploads = uploads
            self.downloads = downloads
            self.failedTransfers = failedTransfers
            self.bytes = bytes
        }
    }

    /// Pairs `connected` … `disconnected`, counts the transfers between
    /// them, keeps the last `limit`, newest first.
    ///
    /// **Order.** `events` is read in the order it arrives, which is the
    /// order `AuditLogStore` keeps (append order, oldest first). It is
    /// deliberately NOT re-sorted by timestamp: two events recorded in the
    /// same millisecond would then be free to swap, and a `disconnected`
    /// that landed before its own `connected` would pair with the wrong
    /// session. Append order is the record of what happened; a timestamp is
    /// a field on it.
    ///
    /// **What counts as a transfer.** `.transferFinished` split by direction
    /// into `uploads`/`downloads`, and `.transferFailed` into
    /// `failedTransfers` — exactly the two kinds the design names.
    /// `.transferCancelled`, `.editUpload` and `.crossSessionTransfer` are
    /// deliberately outside: a cancelled transfer moved nothing, and the
    /// other two are their own kinds precisely because the audit log wanted
    /// them told apart from a plain transfer.
    ///
    /// **What is dropped.** Transfers recorded before the first `connected`
    /// belong to no session and are counted nowhere. A `disconnected` with
    /// no open session before it closes nothing.
    ///
    /// - Parameter now: reserved for the view model that calls this and read
    ///   by nothing here. An open session's duration is `nil` rather than
    ///   "elapsed so far" (see `Outcome`), which is the one use a clock
    ///   would have had. Kept because the signature is what Task 2 builds
    ///   against; it should be removed if Task 2 finds no use for it either.
    public static func rows(from events: [AuditEvent], limit: Int = 10, now: Date = Date()) -> [Row]
    {
        var rows: [Row] = []
        var open: OpenSession?

        func close(_ session: OpenSession, at end: Date?) {
            rows.append(session.row(endedAt: end))
        }

        for event in events {
            switch event.kind {
            case .connected:
                // An unclosed session followed by a new connect is what a
                // crash leaves behind: it ended, nothing recorded when.
                if let previous = open { close(previous, at: nil) }
                open = OpenSession(id: event.id, startedAt: event.timestamp)
            case .disconnected:
                guard let previous = open else { continue }
                close(previous, at: event.timestamp)
                open = nil
            case .connectFailed:
                // Its own row, and it does not disturb an open session: a
                // failed connect while another one is up is a second attempt,
                // not the end of the first.
                rows.append(
                    Row(
                        id: event.id, startedAt: event.timestamp,
                        outcome: .failed(reason: event.detail),
                        uploads: 0, downloads: 0, failedTransfers: 0, bytes: nil))
            case .transferFinished:
                switch event.transferVerb {
                case .upload: open?.uploads += 1
                case .download: open?.downloads += 1
                case nil: continue
                }
            case .transferFailed:
                open?.failedTransfers += 1
            case .transferCancelled, .editUpload, .crossSessionTransfer, .rename, .delete,
                .permissions, .newFolder, .newFile, .snippetExecuted, .plaintextConfirmed:
                // Not a connection boundary and not a transfer this list
                // counts. Spelled out rather than left to a `default`, so a
                // kind added later has to be classified here instead of
                // silently joining the ignored set.
                continue
            }
        }

        if let previous = open { close(previous, at: nil) }

        return Array(rows.suffix(max(0, limit)).reversed())
    }

    /// A `connected` that has not been closed yet, with its running counts.
    private struct OpenSession {
        let id: UUID
        let startedAt: Date
        var uploads = 0
        var downloads = 0
        var failedTransfers = 0

        func row(endedAt: Date?) -> Row {
            Row(
                id: id, startedAt: startedAt,
                outcome: .connected(duration: endedAt.map { duration(to: $0) }),
                uploads: uploads, downloads: downloads, failedTransfers: failedTransfers,
                bytes: nil)
        }

        /// Clamped at zero: a `disconnected` stamped before its own
        /// `connected` is a clock that moved, not a session that lasted a
        /// negative time, and a negative `Duration` would render as one.
        private func duration(to end: Date) -> Duration {
            .seconds(max(0, end.timeIntervalSince(startedAt)))
        }
    }
}
