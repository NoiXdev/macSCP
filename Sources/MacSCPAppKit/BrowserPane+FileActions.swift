import SwiftUI
import macSCPCore

/// What the confirmation sheet is about: the action, what it will run, and
/// the selection it was built from.
struct FileActionRequest: Identifiable {
    let id = UUID()
    let action: FileAction
    let selection: [RemoteFileItem]
    let outcome: Result<FileActionPlan, FileActionPlanner.Refusal>
}

extension BrowserPane {
    /// Builds the plan and opens the confirmation sheet. **Nothing runs
    /// here** — the sheet's confirm button is what would start it, and the
    /// run itself is not written yet: `FileActionConfirmSheet`'s `onRun` is
    /// the place it attaches.
    ///
    /// The side is the pane's own `side`, the single source for which pane
    /// this is. It is not derived from `supportsArchiving`, which says what
    /// the pane can do and is `false` on a remote pane that cannot archive.
    func beginFileAction(_ action: FileAction, selection: [RemoteFileItem]) {
        fileActionRequest = FileActionRequest(
            action: action, selection: selection,
            outcome: FileActionPlanner.plan(
                action: action, selection: selection, side: side))
    }
}
