import Foundation

/// A single audit event: a user action or system event observed during a session.
/// The `detail` field contains finished English plain text; the UI is responsible
/// for localizing the `Kind` label only.
public struct AuditEvent: Codable, Equatable, Sendable, Identifiable {
    /// Unique identifier for this event.
    public let id: UUID

    /// Timestamp when the event was recorded.
    public let timestamp: Date

    /// The kind of event that occurred.
    public let kind: Kind

    /// Finished English plain text describing the event in detail.
    /// Example: "transferred 42 files to /path/on/remote", or
    /// "failed: permission denied (code 13)". The UI localizes only
    /// the `kind` label, not this text.
    public let detail: String

    /// Whether this event represents an error condition.
    public let isError: Bool

    /// Error message if `isError` is true; nil otherwise.
    public let errorMessage: String?

    /// Creates a new audit event with optional defaults.
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        detail: String,
        isError: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
        self.isError = isError
        self.errorMessage = errorMessage
    }

    /// The category of event that occurred.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case connected
        case disconnected
        /// A connect attempt that did NOT succeed (session overview).
        ///
        /// The `detail` carries the FIXED sentence the diagnostics module
        /// produces for the error — `DialSupport.reason(for:)` — and never a
        /// raw error's own text. That is the whole reason this kind exists
        /// rather than an `isError: true` `.connected`: a transport error is
        /// exactly the kind of value that carries the configuration it was
        /// dialling with, and the two URL-shaped backends compose their free
        /// text out of an endpoint field that accepts
        /// `scheme://KEY:SECRET@host` as ordinary input. See
        /// `DialSupport.reason(for:)`'s own doc comment for the measurement.
        ///
        /// Appended by the App at the point a connect fails; the overview's
        /// recent-connections list turns it into a failed row
        /// (`ConnectionHistory.Row.Outcome.failed`).
        case connectFailed
        case transferFinished
        case transferFailed
        case transferCancelled
        case rename
        case delete
        case permissions
        case newFolder
        case newFile
        case editUpload
        case crossSessionTransfer
        /// A snippet the user ran in the session's terminal (P3e). Only
        /// EXECUTIONS are recorded: an inserted snippet still sits in the
        /// prompt and can be edited before it runs, so logging it as run
        /// would be a false entry. Free-typed input is never recorded --
        /// the client cannot tell a password prompt from any other input
        /// (see the P3e feasibility note in the design spec), so there is
        /// no honest way to log it.
        case snippetExecuted
        /// The user confirmed connecting over an unencrypted (`http://`)
        /// endpoint despite `PlaintextTransportGate.requiresConfirmation`
        /// (M21/T10) — recorded once the connect succeeds, at the same spot
        /// `.connected` is recorded, so the audit trail shows exactly when a
        /// session ran with credentials in the clear.
        case plaintextConfirmed
        /// A bucket the user created from the bucket list (S3 bucket
        /// settings). This kind and the three after it are recorded by the
        /// sheets that apply them, through `AuditRecorder.recordBucketCreated`,
        /// `recordVersioningChanged`, `recordCORSChanged` and
        /// `recordObjectLockChanged`: those sheets do not go through
        /// `RemoteBrowserViewModel`, so its `auditSink` never carries them.
        /// The kinds after `objectLockChanged` come with the version-history
        /// work and are recorded through their own methods (see
        /// `versionRestored`; `metadataChanged` has no recorder yet).
        ///
        /// (Withdrawn wording, verbatim: "The four kinds from here on are
        /// recorded by the sheets that apply them, through
        /// `AuditRecorder.recordBucketCreated`, `recordVersioningChanged`,
        /// `recordCORSChanged` and `recordObjectLockChanged`". Four more cases
        /// were appended after `objectLockChanged`, so "from here on" no
        /// longer meant those four, and the list of recorders was short.)
        case bucketCreated
        /// A bucket's versioning moved to another state.
        case versioningChanged
        /// A bucket's CORS rules were saved, or cleared.
        case corsChanged
        /// An Object Lock write: a file's retention, a file's legal hold, or
        /// a bucket's default retention. ONE kind for the three, so the
        /// `detail` is what tells them apart -- see
        /// `AuditRecorder.recordObjectLockChanged`. A COMPLIANCE retention is
        /// the only write macSCP makes that cannot be undone, and this is its
        /// trace.
        case objectLockChanged
        /// An object's older version was restored: written again as a NEW
        /// version, so the history keeps every entry it had. Has a recorder,
        /// `AuditRecorder.recordVersionRestored`, and no caller yet: the
        /// version sheet task wires it.
        ///
        /// (Withdrawn wording, verbatim: "Recorded through
        /// `AuditRecorder.recordVersionRestored`. Like the bucket-settings
        /// kinds, not carried by `RemoteBrowserViewModel`'s `auditSink`." It
        /// described a producer, and none exists yet.)
        case versionRestored
        /// One version of an object was removed for good: no marker is left
        /// and nothing can bring it back. Has a recorder,
        /// `AuditRecorder.recordVersionDeleted`, whose `detail` says
        /// "permanently", and no caller yet: the version sheet task wires it.
        /// (Withdrawn wording, verbatim: "Recorded through
        /// `AuditRecorder.recordVersionDeleted`".)
        case versionDeleted
        /// A delete marker was removed, so the version beneath it is the
        /// object's current content again. Has a recorder,
        /// `AuditRecorder.recordDeleteMarkerLifted`, and no caller yet: the
        /// version sheet task wires it. (Withdrawn wording, verbatim:
        /// "Recorded through `AuditRecorder.recordDeleteMarkerLifted`.")
        case deleteMarkerLifted
        /// An object's metadata was rewritten. **Nothing produces this kind
        /// yet.** It belongs to Plan B, "S3 Metadata, ACL Display and the
        /// Connection Manager's Bucket Implementation"
        /// (`docs/superpowers/plans/2026-10-23-s3-metadata-and-acls.md`), and
        /// is declared here so that the switches that must name every kind
        /// (`AuditLogSheet.Filter.segment(of:)`, `ConnectionHistory.rows`)
        /// are extended once, with the version-history kinds. It has its
        /// catalogue labels and its switch arms and no recorder: that plan
        /// writes the recorder and the producer.
        case metadataChanged
    }
}

extension AuditEvent {
    /// The verb that opens a transfer event's `detail`, and the ONLY
    /// structural trace of a transfer's direction an `AuditEvent` carries.
    ///
    /// `AuditEvent` has no direction field and no byte count: the audit log's
    /// detail is finished English plain text, and a transfer's line reads
    /// `"<verb> <file> → <destination>"`. So the direction has to be read
    /// back out of that text, and this type is the one place the vocabulary
    /// is written down — `AuditRecorder.recordTransfer` composes the detail
    /// from it, `transferVerb` below reads it back. Two spellings of one
    /// word in two files is exactly the second copy this project's comment
    /// rules are about.
    ///
    /// TWO cases, one per `TransferDirection` case, and
    /// `everyVerbIsRecognizedAtTheHeadOfADetail` counts them against
    /// `allCases` rather than against the number written here.
    public enum TransferVerb: String, Sendable, CaseIterable {
        case upload
        case download

        /// The verb a transfer in this direction is recorded under.
        /// Exhaustive, so a third `TransferDirection` case does not compile
        /// until it has one.
        public init(_ direction: TransferDirection) {
            switch direction {
            case .upload: self = .upload
            case .download: self = .download
            }
        }
    }

    /// The direction this event's `detail` names, or `nil` when it names
    /// none.
    ///
    /// `nil` is the honest answer for every non-transfer kind, and also for
    /// `.crossSessionTransfer`, whose detail opens with the target session
    /// rather than with a verb (`AuditRecorder.recordTransfer`). Matching
    /// requires the trailing space, so a detail that merely CONTAINS the
    /// word "upload" somewhere in a file name is not mistaken for one.
    public var transferVerb: TransferVerb? {
        TransferVerb.allCases.first { detail.hasPrefix("\($0.rawValue) ") }
    }
}
