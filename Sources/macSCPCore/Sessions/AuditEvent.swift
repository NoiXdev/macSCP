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
