import Foundation

/// Which saved sessions are valid picks for the "use a saved connection as
/// jump host" picker (M11a). One hop is the rule (spec §2): a session that
/// itself has a jump is excluded so the picker can never offer a chain, and
/// the session currently being edited is excluded to prevent self-reference.
/// Sorted like the sidebar (name, case-insensitive).
public enum JumpSessionEligibility {
    public static func eligible(
        for editingSessionID: UUID?, in sessions: [StoredSession]
    ) -> [StoredSession] {
        sessions
            .filter { $0.id != editingSessionID && $0.jump == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
