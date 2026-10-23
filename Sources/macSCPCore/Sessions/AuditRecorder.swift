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
    /// - `.failed(cause)` → `.transferFailed`, `isError: true`, the cause's own
    ///   sentence as `errorMessage`
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
        case .failed(let cause):
            // The status carries the CAUSE since 2026-09-25; the audit line
            // keeps the sentence it always wrote, rendered from that cause
            // (`TransferFailureKind.message`) rather than passed in
            // pre-rendered. The text is unchanged, composition for
            // composition.
            store.append(
                AuditEvent(
                    kind: .transferFailed, detail: baseDetail, isError: true,
                    errorMessage: cause.message),
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

    // MARK: - S3 bucket settings (Task 12)

    /// What an Object Lock write was. `AuditEvent.Kind.objectLockChanged`
    /// covers all three, and only one of them -- a COMPLIANCE retention -- is
    /// irreversible, so a trail in which the three read alike would not do
    /// the job the kind exists for. The kind cannot separate them; the
    /// `detail` composed from this does.
    public enum ObjectLockChange: Sendable, Equatable {
        /// A file's retention: the mode and the date it was written with.
        case retention(ObjectRetention, key: String, bucket: String)
        /// A file's legal hold: placed (`true`) or released (`false`).
        case legalHold(Bool, key: String, bucket: String)
        /// A bucket's default retention, which applies to files added after.
        case bucketDefault(days: Int, mode: RetentionMode, bucket: String)
    }

    /// Logs a bucket the user created from the bucket list.
    ///
    /// `failure` is the FIXED sentence the sheet already shows for a create
    /// the store did not do -- never the error's own text, which can carry the
    /// endpoint the user typed. `nil` is a create that went through. **No
    /// default value**, for the reason `BucketVersioningModel.init(current:
    /// bucketHasObjectLock:)` gives: a default is what lets a caller leave a
    /// refusal reading as done without saying so. The same goes for the three
    /// methods after this one.
    ///
    /// A create that failed after the bucket existed (the versioning request
    /// that follows it) is recorded as a failure too, and its sentence says
    /// the bucket exists. The detail is the attempt, whichever way it went.
    ///
    /// `bucketDefault` is the bucket's DEFAULT RETENTION as the caller read
    /// it back, or `nil` when there is none to report -- which covers both a
    /// bucket that has none and a read that did not answer, so the caller's
    /// own `failure` sentence is what tells those apart. `createBucket` takes
    /// only a `BucketProtection` and so cannot set a default, which is why a
    /// default that is present is worth a line of its own: it was set by
    /// somebody else at some other time, and it is the one piece of evidence
    /// available that the bucket is not new. The mode and the day count go in
    /// because they are what a reader of the trail decides from, and neither
    /// is a secret.
    ///
    /// **No default value**, on this parameter as on the others, and for the
    /// same reason: `nil` is a real answer about an irreversible setting, and
    /// a call site that had not thought about it would get that answer
    /// without saying so. **Ten call sites spell it**, counted 2026-10-23
    /// with this command, which prints one line per OCCURRENCE (`grep -o`,
    /// not `grep -c`, which counts lines -- several of these share a line
    /// with nothing and one shares a file with another):
    ///
    ///     /usr/bin/grep -rn -o -e 'recordBucketCreated(' Sources Tests --include='*.swift'
    ///
    /// It prints **14**, and the four that are not call sites are named one
    /// by one: the declaration below, the copy of the pattern in the command
    /// above, the copy inside the withdrawal at the end of this paragraph,
    /// and a string literal in the source-scanning guard
    /// `BucketSettingsAuditTests.createMakesOneRecordingCallPerArmItCanTake`.
    /// 14 - 4 = 10: six calls in `CreateBucketSheet.swift`, one per arm of
    /// `create`, and four in `AuditRecorderBucketSettingsTests.swift`.
    ///
    /// **Two of those four are this paragraph's own**, which is why the
    /// figure moves whenever the prose does -- and it did: the corrected
    /// version first said 13, counted before the withdrawal below was
    /// written, and re-running the command AFTER writing it returned 14. That
    /// is not a corner case here; it is the second time in two attempts that
    /// this one figure was changed by the sentence reporting it.
    ///
    /// **The quotes around `'*.swift'` are load-bearing.** Written bare, the
    /// shell expands `--include=*.swift` against the working directory before
    /// `grep` sees it: in zsh that is `no matches found` and a count of 0,
    /// which is how the first version of this paragraph shipped a figure
    /// whose command could not reproduce it. Measured 2026-10-23, both forms,
    /// in this repository.
    ///
    /// **Corrected 2026-10-23, same day, before the push.** This paragraph
    /// read, verbatim: "Four call sites in the sheet and four in
    /// `AuditRecorderBucketSettingsTests` spell it; counted 2026-10-23 with
    /// `/usr/bin/grep -rn -o -e 'recordBucketCreated(' Sources Tests --include=*.swift`,
    /// which prints 11 OCCURRENCES (`grep -o`, one per occurrence, not
    /// `grep -c`, which counts lines): this declaration, five calls in
    /// `CreateBucketSheet.swift` -- one per arm of `create` -- four in that
    /// Core test file, and one inside the source-scanning guard
    /// `BucketSettingsAuditTests.createMakesOneRecordingCallPerArmItCanTake`,
    /// which is a string literal rather than a call." Three things were wrong
    /// with it: the total (11, not 13), the sheet's share (five, where
    /// `create` has six arms and six calls), and a command that does not run
    /// in the form it was committed.
    public func recordBucketCreated(
        bucket: String, protection: BucketProtection,
        bucketDefault: (days: Int, mode: RetentionMode)?, failure: String?
    ) {
        var detail = "created bucket \(bucket)"
        switch protection {
        case .none: break
        case .versioned: detail += " with versioning"
        case .lockedAndVersioned: detail += " with versioning and Object Lock"
        }
        if let bucketDefault {
            detail +=
                "; the bucket already had a \(bucketDefault.mode.rawValue) default retention of "
                + "\(bucketDefault.days) \(bucketDefault.days == 1 ? "day" : "days")"
        }
        appendBucketSetting(.bucketCreated, detail: detail, failure: failure)
    }

    /// Logs a bucket's versioning moved to `state`, or refused.
    public func recordVersioningChanged(bucket: String, to state: BucketVersioning, failure: String?) {
        appendBucketSetting(
            .versioningChanged, detail: "versioning of bucket \(bucket) set to \(state.rawValue)",
            failure: failure)
    }

    /// Logs a bucket's CORS rules saved, or refused. Only the COUNT is
    /// written: a rule's origins and headers are the user's configuration,
    /// not an audit fact, and the count is what tells a save from a clear.
    /// An empty save is worded as a clear because that is what the store
    /// makes of it (`S3BucketSettings.setCORS`).
    public func recordCORSChanged(bucket: String, ruleCount: Int, failure: String?) {
        let detail =
            ruleCount == 0
            ? "CORS configuration of bucket \(bucket) cleared"
            : "CORS rules of bucket \(bucket) set to \(ruleCount) \(ruleCount == 1 ? "rule" : "rules")"
        appendBucketSetting(.corsChanged, detail: detail, failure: failure)
    }

    /// Logs an Object Lock write, or its refusal. A retention's line names the
    /// mode and the date (UTC, the internet date-time form), which is the one
    /// fact a COMPLIANCE write cannot be reconstructed from afterwards.
    public func recordObjectLockChanged(_ change: ObjectLockChange, failure: String?) {
        let detail: String
        switch change {
        case .retention(let retention, let key, let bucket):
            detail =
                "retention of \(bucket)/\(key) set to \(retention.mode.rawValue) until "
                + Self.utcText(retention.retainUntil)
        case .legalHold(let on, let key, let bucket):
            detail = "legal hold on \(bucket)/\(key) \(on ? "placed" : "released")"
        case .bucketDefault(let days, let mode, let bucket):
            detail = "default retention of bucket \(bucket) set to \(mode.rawValue) for \(days) days"
        }
        appendBucketSetting(.objectLockChanged, detail: detail, failure: failure)
    }

    private func appendBucketSetting(_ kind: AuditEvent.Kind, detail: String, failure: String?) {
        store.append(
            AuditEvent(kind: kind, detail: detail, isError: failure != nil, errorMessage: failure),
            for: sessionID)
    }

    /// `2027-01-15T08:00:00Z`: UTC and fixed, so a line reads the same
    /// whichever zone or locale reads it back. A formatter per call, not a
    /// shared one: `ISO8601DateFormatter` is not `Sendable`.
    private static func utcText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
