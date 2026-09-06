import Foundation

/// Is this session name already taken, and by which session.
///
/// One implementation, two matchings — because two callers ask the question
/// for two different reasons and only one of them is free to choose the
/// answer.
///
/// * **A writer that REFUSES** — the command line's `sessions add` — wants
///   the human answer: `"Prod"`, `" prod "` and `"prod"` are the same name to
///   the person who has to find the session again later, and letting all
///   three into one store makes a list nobody can read. Refusing more than
///   strictly necessary costs the caller one error message; it cannot make a
///   wrong thing happen. That is `.caseInsensitive`.
/// * **A warning that DESCRIBES** — the connection form's "Saving replaces
///   the existing session X" — has no such freedom. It is measured against
///   what `SessionListViewModel.save` will actually do, and `save` finds its
///   target with `==` against the stored names as they stand. A
///   case-insensitive warning on that path names a session that saving would
///   leave untouched, which is not a clumsy sentence but a false one. That is
///   `.exactAsSaved`, and `SessionNameCollision.collides` is the caller that
///   asks for it.
///
/// The two are here rather than in two files precisely because they are one
/// decision seen from two sides: what a name IS (trimmed, because no write
/// path ever hands `save` untrimmed text) is answered once, in `asSaved`, and
/// only the comparison on top of it differs.
///
/// `matching:` has NO default. Which of the two a caller wants is the whole
/// question this type exists to ask, and a default answers it for whoever
/// forgets — silently handing a future App call site the command line's
/// rule, which would put a false sentence in front of a person rather than
/// an extra refusal in front of a script.
public enum SessionNameRule {
    /// How two names are compared.
    public enum Matching: Sendable {
        /// Both sides trimmed, compared without case. The human answer.
        case caseInsensitive
        /// The asked name trimmed, the stored names as they stand, compared
        /// with `==` — a mirror of `SessionListViewModel.save`.
        ///
        /// One direction only, and deliberately: `save` does not trim the
        /// STORED names either. No known writer produces a stored name with
        /// surrounding whitespace (`SessionImportPlanner` trims on purpose),
        /// so this mirrors `save` rather than repairing the store. Should
        /// such a name exist it is a different name, and folding the two
        /// together would step aside from a name saving would have left
        /// alone.
        case exactAsSaved
    }

    /// A name as `SessionListViewModel.save` will receive it.
    ///
    /// Neither write path ever hands `save` what a name field holds:
    /// `ContentView.persistFormAsSession` trims before calling `save`, and
    /// `ConnectionViewModel.validateForEditSave` trims before building the
    /// session it hands to `updateSession`. A caller that trimmed for the
    /// warning and forgot to trim for the stepping-aside had exactly one
    /// broken half with the other half's test green beside it; that happened,
    /// which is why the trim lives here and not at the call sites.
    public static func asSaved(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `asked` and a `stored` name are the same name under
    /// `matching`.
    ///
    /// The comparison `conflict(_:among:excluding:matching:)` applies, on
    /// its own, for the callers that hold something other than a
    /// `StoredSession` — the command line's tunnel profiles, which are
    /// addressed by name per session and so ask the identical question
    /// about a different type. It was a hand-written second copy of the
    /// fold in `StoreEditing.profiles(named:on:)` until 2026-09-07, which
    /// is the shape this file exists to prevent: the trim and the case
    /// folding are ONE decision, and a second spelling of it is how
    /// `add DB` and `rm db` come to disagree.
    public static func matches(_ asked: String, _ stored: String, matching: Matching) -> Bool {
        let candidate = asSaved(asked)
        switch matching {
        case .caseInsensitive: return asSaved(stored).lowercased() == candidate.lowercased()
        case .exactAsSaved: return stored == candidate
        }
    }

    /// The session `name` conflicts with, or `nil` when none does.
    ///
    /// `excluding` is the session currently being edited: a form editing a
    /// stored session shows that session's own name, and reporting that it
    /// conflicts with itself would make the warning appear always — an
    /// always-visible warning stops being read. A caller creating something
    /// new excludes nothing, because it is not a session yet.
    ///
    /// The FIRST match is returned, not all of them: every caller either
    /// names one session in a sentence or refuses, and neither gets better
    /// with a list.
    public static func conflict(
        _ name: String,
        among sessions: [StoredSession],
        excluding: UUID? = nil,
        matching: Matching
    ) -> StoredSession? {
        sessions.first { session in
            guard session.id != excluding else { return false }
            return matches(name, session.name, matching: matching)
        }
    }
}
