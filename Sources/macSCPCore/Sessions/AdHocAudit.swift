import Foundation

/// Where a connection that was never saved writes its audit trail (M31).
///
/// The audit log is keyed by session id, and an unsaved connection has no
/// `StoredSession` -- so until now the whole trail was skipped, the M21
/// plaintext-transport note included. One FIXED id gives every such
/// connection the same log, which the existing per-session audit sheet can
/// show like any other.
///
/// It is a value, not a record: nothing writes it to `sessions.json`, it has
/// no sidebar row, and it can be neither connected to, renamed, deleted nor
/// exported. Entries stay distinguishable because `recordConnected(summary:)`
/// already puts host and user into the detail text.
public enum AdHocAudit {
    /// Hardcoded rather than derived: a derived id would change whenever its
    /// input changed, and an ad-hoc log that silently moves to a new id is
    /// an unreachable log.
    public static let sessionID = UUID(uuidString: "AD400C00-0000-4000-8000-000000000001")!

    /// The id this connect should log under. The one place that decides it,
    /// so no call site has to remember the rule -- and the reason it lives
    /// here rather than in the view: `ContentView` has no tests.
    public static func logSessionID(storedID: UUID?) -> UUID {
        storedID ?? sessionID
    }
}
