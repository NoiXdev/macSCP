import Foundation

/// Which stored session the connection form's Save would replace, given the
/// name in the field and the mode the form is in.
///
/// A value of its own rather than a condition inside the view, because the
/// step it adds fails without a symptom: `SessionNameCollision.collides` is
/// TOLD which session to leave out, and reading that id off `FormMode` is
/// the part nothing else checks. Editing a stored session must exclude that
/// very session — the field shows its own name, so a form that forgot would
/// warn every single time, and a warning that is always on stops being
/// read. A new connection must exclude nothing: it is not a session yet, so
/// every stored name it matches belongs to someone else. Swap the two arms
/// and the form warns always or never; both compile and both render.
///
/// Here rather than beside the view, and the reason is not that a rule
/// "belongs in Core": both types it speaks are already Core's —
/// `ConnectionViewModel.FormMode` lives in this very directory, and
/// `StoredSession` in `Sessions/`. The App layer contributes nothing to this
/// answer, so a copy over there would only be a second place for the
/// question to be answered differently. That is not hypothetical: the first
/// version of this value sat in `ConnectionFormView.swift` and trimmed the
/// name itself, while `SessionNameCollision.freeName` did not — the warning
/// was right about a name the stepping-aside rule called free. Both now
/// trim in the one place that compares.
public enum SessionNameConflict {
    public static func replacedSession(
        byName name: String, mode: ConnectionViewModel.FormMode,
        in sessions: [StoredSession]
    ) -> StoredSession? {
        let excluded: UUID?
        switch mode {
        case .edit(let sessionID): excluded = sessionID
        case .new: excluded = nil
        }
        // Deliberately hands the name over untouched: `collides` normalizes
        // it the same way `freeName` does, so the two cannot disagree about
        // what the name is.
        return SessionNameCollision.collides(name, with: sessions, excluding: excluded)
    }
}
