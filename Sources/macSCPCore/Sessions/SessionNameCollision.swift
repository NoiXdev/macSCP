import Foundation

/// Two questions about a session name, asked in one place because two call
/// sites need them and a second copy would drift.
///
/// Both use the SAME comparison `SessionListViewModel.save` uses to find the
/// session it overwrites — exact, case sensitive. That is the point rather
/// than an implementation detail: a rule that judged names differently than
/// saving does would either step aside from a name saving would have left
/// alone, or call a name free that saving then overwrites.
public enum SessionNameCollision {
    /// The session `name` would replace, or `nil` if none. `excluding` is the
    /// session currently being edited: a form editing a stored session shows
    /// that session's own name, and warning that it replaces itself would
    /// make the warning appear always — and an always-visible warning stops
    /// being read.
    public static func collides(
        _ name: String, with existing: [StoredSession], excluding: UUID?
    ) -> StoredSession? {
        existing.first { $0.name == name && $0.id != excluding }
    }

    /// `desired` if it is free, otherwise the first free `"<desired> N"`.
    ///
    /// Only for names macSCP invents. What the user typed is never rewritten:
    /// an app that silently edits typed text is worse than one that
    /// overwrites, because afterwards nobody trusts what they type.
    ///
    /// The suffix is appended, never parsed: `"web 2"` is a name in its own
    /// right, so the next free form of it is `"web 2 2"` rather than
    /// `"web 3"`. Parsing would guess at what a name means.
    public static func freeName(
        basedOn desired: String, avoiding existing: [StoredSession]
    ) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains(desired) else { return desired }
        var counter = 2
        while taken.contains("\(desired) \(counter)") { counter += 1 }
        return "\(desired) \(counter)"
    }
}
