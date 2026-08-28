import Foundation

/// What the connection form's Save would do to a stored session that
/// already carries the name in the name field — and therefore what the form
/// is allowed to say about it.
///
/// **Two cases because the two save paths do two different things.** That is
/// the whole reason this type is not just "the session that collides":
///
/// * A new connection is written by `SessionListViewModel.save`, which finds
///   its target with `sessions.first(where: { $0.name == name })` and
///   mutates it in place. It really does replace, taking the existing
///   session's group, tags, login-set binding, jump spec and keychain slot
///   with it. → `replaces`.
/// * An edit is written by `SessionListViewModel.updateSession`, which
///   upserts by **id**. Nothing is replaced: the session whose name was
///   matched survives untouched, and the store ends up holding two sessions
///   of that name (pinned by `SessionListViewModelTests
///   .updateSessionUpsertsByIdSoARenameCanDuplicateAName`). → `duplicates`.
///
/// The first version of this feature said "saving replaces" on both paths.
/// In edit mode that is not a clumsy sentence, it is a false one, and a
/// warning that describes an outcome which does not happen is worse than no
/// warning: the point of showing it before saving is that it can be
/// believed. Two names colliding is still worth saying — it just has to be
/// said as what it is.
///
/// **The other half, which fails silently either way:** which session to
/// exclude. Editing must exclude the very session being edited — the field
/// shows its own name, so a form that forgot would warn every single time,
/// and a warning that is always on stops being read. A new connection must
/// exclude nothing: it is not a session yet. Swap those and the form warns
/// always or never, compiling and rendering all the same.
///
/// Here rather than beside the view because both types it speaks are Core's
/// — `ConnectionViewModel.FormMode` lives in this directory, `StoredSession`
/// in `Sessions/`. The App layer contributes nothing to the answer, so a
/// copy over there would only be a second place to answer it differently.
/// It carries its own catalogue key for the same reason the backends carry
/// `badgeLabelKey`: which sentence belongs to which outcome is part of the
/// decision, not a detail of the view that renders it.
public enum SessionNameConflict: Equatable, Sendable {
    /// Saving would overwrite this session. The new-connection path.
    case replaces(StoredSession)
    /// Saving would leave this session alone and produce a second session
    /// of the same name. The edit path.
    case duplicates(StoredSession)

    public var session: StoredSession {
        switch self {
        case .replaces(let session), .duplicates(let session): return session
        }
    }

    /// The App catalogue key for this outcome's sentence, formatted with
    /// `session.name`.
    public var messageKey: String {
        switch self {
        case .replaces: return "connection.saveName.replaces %@"
        case .duplicates: return "connection.saveName.duplicates %@"
        }
    }

    /// The English source text, and the fallback when the resource bundle
    /// cannot be located — the same pairing every `L10n.string` call site
    /// supplies.
    public var messageDefault: String {
        switch self {
        case .replaces:
            return "Saving replaces the existing session \u{201C}%@\u{201D}."
        case .duplicates:
            return "Another session is already called \u{201C}%@\u{201D}."
        }
    }

    public static func build(
        name: String, mode: ConnectionViewModel.FormMode, in sessions: [StoredSession]
    ) -> SessionNameConflict? {
        // The mode decides both halves at once, and they are the same
        // question asked twice: which session is this form, and what does
        // this form's Save call.
        let excluded: UUID?
        let outcome: (StoredSession) -> SessionNameConflict
        switch mode {
        case .edit(let sessionID):
            excluded = sessionID
            outcome = SessionNameConflict.duplicates
        case .new:
            excluded = nil
            outcome = SessionNameConflict.replaces
        }
        // Hands the name over untouched: `collides` normalizes it the same
        // way `freeName` does, and the tests on both hold them to it.
        return SessionNameCollision.collides(name, with: sessions, excluding: excluded)
            .map(outcome)
    }
}
