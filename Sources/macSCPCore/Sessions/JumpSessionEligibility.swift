import Foundation

/// Which saved sessions are valid picks for the "use a saved connection as
/// jump host" picker (M11a). One hop is the rule (spec §2): a session that
/// itself has a jump is excluded so the picker can never offer a chain, and
/// the session currently being edited is excluded to prevent self-reference.
/// Only SSH sessions are offered (M24/T4): a jump dials through a bastion, and
/// only an SSH session has a host and port to dial — an S3 or WebDAV session
/// has neither. Sorted like the sidebar (name, case-insensitive).
///
/// This filter alone is not the fix. It only shapes what the picker offers
/// FROM NOW ON; a `jump.sessionID` already pointing at a non-SSH session
/// (creatable since M12, before this filter existed) still reaches
/// `LoginResolver.resolveJump`, whose own `kind == .ssh` guard is the actual
/// hard stop — this filter is hygiene on top of it, not a replacement.
public enum JumpSessionEligibility {
    public static func eligible(
        for editingSessionID: UUID?, in sessions: [StoredSession]
    ) -> [StoredSession] {
        sessions
            .filter { $0.kind == .ssh && $0.id != editingSessionID && $0.jump == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
