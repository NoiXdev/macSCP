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
/// That comparison is not written here any more. It is
/// `SessionNameRule.conflict(_:among:excluding:matching:)` under
/// `.exactAsSaved`, together with the trim (`SessionNameRule.asSaved`) that
/// makes it compare the value `save` will receive rather than the value a
/// name field holds. The command line's `sessions add` asks the same
/// function a different way — `.caseInsensitive`, because a writer that
/// REFUSES may refuse more
/// than saving would overwrite, while a warning that DESCRIBES may not. That
/// difference is spelled once, in `SessionNameRule.Matching`, instead of
/// twice by accident.
///
/// One place makes divergence harder to write, not impossible: one line —
/// `conflict(name.lowercased(), …)` at a caller — still diverges with the
/// whole suite green. What holds this is the tests on both functions, not
/// the arrangement of them.
public enum SessionNameCollision {
    /// The name as `SessionListViewModel.save` will receive it.
    private static func asSaved(_ name: String) -> String {
        SessionNameRule.asSaved(name)
    }

    /// The session `name` would replace, or `nil` if none. `excluding` is the
    /// session currently being edited: a form editing a stored session shows
    /// that session's own name, and warning that it replaces itself would
    /// make the warning appear always — and an always-visible warning stops
    /// being read.
    public static func collides(
        _ name: String, with existing: [StoredSession], excluding: UUID?
    ) -> StoredSession? {
        SessionNameRule.conflict(
            name, among: existing, excluding: excluding, matching: .exactAsSaved)
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
