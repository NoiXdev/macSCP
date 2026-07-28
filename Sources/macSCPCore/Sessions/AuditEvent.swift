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
        case transferFinished
        case transferFailed
        case transferCancelled
        case rename
        case delete
        case permissions
        case newFolder
        case editUpload
        case crossSessionTransfer
    }
}
