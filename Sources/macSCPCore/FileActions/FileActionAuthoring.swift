import Foundation

/// What an author's text becomes on its way into the store: the editor's
/// save, and the import of somebody else's file.
///
/// Both routes meet here because they have the same job — decide what may be
/// stored — and the import is the one that matters. `FileActionExportCodec`
/// decodes without validating, so an imported action may declare no side or
/// carry a placeholder in a position the gate refuses. The context menu
/// declines to OFFER such an action; this is what keeps it from being STORED.
public enum FileActionAuthoring {
    /// `command` without leading or trailing blanks and line breaks.
    ///
    /// A command pasted into a text field commonly ends in a newline, and
    /// the gate refuses a line feed anywhere in a command (for a
    /// local-capable action because it separates commands, so `wc -l x\n` is
    /// not one simple command; on every side because a line feed is a C0
    /// control character —
    /// `FileActionTemplate.Problem.commandHoldsAControlCharacter`). Trimming
    /// on save is the decision: the line feed there is an accident of
    /// copying and never what the author meant, so refusing it would blame a
    /// command that is otherwise fine.
    ///
    /// Only the ends. A line break in the middle stays, so the gate sees it
    /// and refuses the action rather than this function deciding what the
    /// author meant by it.
    public static func normalizedCommand(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why an imported action was not stored.
    public enum Reason: Equatable, Sendable {
        /// The gate refused it: `FileActionTemplate.firstProblem`.
        case template(FileActionTemplate.Problem)
        /// It has no name, so it would be an unlabelled menu item.
        case emptyName
    }

    /// One imported action that was not stored. `name` is what the file
    /// said, untrusted text: whatever shows it must not draw a control or
    /// bidirectional character as itself.
    public struct Refused: Equatable, Sendable {
        public let name: String
        public let reason: Reason

        public init(name: String, reason: Reason) {
            self.name = name
            self.reason = reason
        }
    }

    /// What an import would do.
    public struct ImportReview: Equatable, Sendable {
        /// To store, in file order, each with a fresh identity.
        public let accepted: [FileAction]
        /// Not stored, in file order, with the reason.
        public let refused: [Refused]
        /// Valid actions skipped because the user already has one with the
        /// same content (or an earlier entry of this file did), so
        /// importing the same file twice does not double the menu.
        public let alreadyPresent: Int

        public init(accepted: [FileAction], refused: [Refused], alreadyPresent: Int) {
            self.accepted = accepted
            self.refused = refused
            self.alreadyPresent = alreadyPresent
        }
    }

    /// Validates every entry of `payload` against the gate and sorts it into
    /// accepted, refused and already present.
    ///
    /// The refusal is checked on the action as it WOULD be stored — name and
    /// command normalised — so what is judged is what would be written.
    /// Refusals are checked before duplicates: an invalid action is never
    /// "already present", whatever the store holds.
    public static func review(
        _ payload: FileActionExportPayload, existing: [FileAction]
    ) -> ImportReview {
        var accepted: [FileAction] = []
        var refused: [Refused] = []
        var alreadyPresent = 0
        for entry in payload.actions {
            let imported = entry.imported()
            let action = FileAction(
                id: imported.id,
                name: imported.name.trimmingCharacters(in: .whitespacesAndNewlines),
                command: normalizedCommand(imported.command),
                variables: imported.variables, runsOn: imported.runsOn,
                perSelection: imported.perSelection)
            if action.name.isEmpty {
                refused.append(Refused(name: entry.name, reason: .emptyName))
                continue
            }
            if let problem = FileActionTemplate.firstProblem(in: action) {
                refused.append(Refused(name: entry.name, reason: .template(problem)))
                continue
            }
            if (existing + accepted).contains(where: { sameContent($0, action) }) {
                alreadyPresent += 1
                continue
            }
            accepted.append(action)
        }
        return ImportReview(accepted: accepted, refused: refused, alreadyPresent: alreadyPresent)
    }

    /// Everything but the identity. An import mints a fresh id, so equality
    /// of whole values could never say "already there".
    private static func sameContent(_ lhs: FileAction, _ rhs: FileAction) -> Bool {
        lhs.name == rhs.name && lhs.command == rhs.command && lhs.variables == rhs.variables
            && lhs.runsOn == rhs.runsOn && lhs.perSelection == rhs.perSelection
    }
}
