import Foundation

/// Two questions about a session name, asked in one place because more than
/// one call site needs them and a second copy would drift.
///
/// Both use the SAME comparison `SessionListViewModel.save` uses to find the
/// session it overwrites — exact, case sensitive — **on the same value it
/// will receive**. Matching the operator and not the operand is the same bug
/// under a nicer name: a rule that judged names differently than saving does
/// would either step aside from a name saving would have left alone, or call
/// a name free that saving then overwrites.
///
/// That is why `asSaved` lives here and not at the call sites. Neither
/// write path ever sees what a name field holds:
/// `ContentView.persistFormAsSession` trims before calling
/// `SessionListViewModel.save`, and `ConnectionViewModel
/// .validateForEditSave` trims before building the session it hands to
/// `updateSession`. A caller that trimmed for the warning and forgot to
/// trim for the stepping-aside had exactly one broken half, with the other
/// half's test green beside it; that happened.
///
/// Trimming in one place makes that harder to write, not impossible: one
/// line — `collides(name.lowercased(), …)` at a caller — still diverges
/// with the whole suite green. What holds this is the tests on both
/// functions, not the arrangement of them.
public enum SessionNameCollision {
    /// The name as `SessionListViewModel.save` will receive it.
    ///
    /// One direction only: the stored names it is compared against are NOT
    /// trimmed, because `save` does not compare them trimmed either. This
    /// mirrors `save`, it does not repair the store — the import path
    /// already trims deliberately (`SessionImportPlanner`, which says in so
    /// many words that import must not be the one path storing a name with
    /// surrounding whitespace), so no known writer produces such a name.
    /// Should one exist, it is a different name, and a rule that folded the
    /// two together would step aside from a name saving would have left
    /// alone.
    private static func asSaved(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The session `name` would replace, or `nil` if none. `excluding` is the
    /// session currently being edited: a form editing a stored session shows
    /// that session's own name, and warning that it replaces itself would
    /// make the warning appear always — and an always-visible warning stops
    /// being read.
    public static func collides(
        _ name: String, with existing: [StoredSession], excluding: UUID?
    ) -> StoredSession? {
        let candidate = asSaved(name)
        return existing.first { $0.name == candidate && $0.id != excluding }
    }

    /// `desired` if it is free, otherwise the first free `"<desired> N"` —
    /// in the form it will be saved in, since the answer goes into the name
    /// field and a name on screen that saving silently turns into a
    /// different one is the failure this whole rule is here to prevent.
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
        let base = asSaved(desired)
        let taken = Set(existing.map(\.name))
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }
}
