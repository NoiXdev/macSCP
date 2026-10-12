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

/// How a remote action reaches the user's own shell: the pane is handed this
/// by the window, because the terminal belongs to the tab and not to a pane.
///
/// Only the remote pane gets one. The local pane spawns instead, and has no
/// shell to type into.
struct FileActionShell {
    /// Whether the shell's remote has announced bracketed paste, which
    /// `SnippetSendPlanner` needs to know to send a multi-line command.
    let wantsBracketedPaste: () -> Bool
    /// Opens the tab's terminal if it is closed and hands it the bytes, the
    /// way a snippet is sent. `false` when the tab has no shell at all.
    let type: ([UInt8]) -> Bool
}

extension BrowserPane {
    /// Builds the plan and opens the confirmation sheet. **Nothing runs
    /// here** — the sheet's confirm button is what starts it, through
    /// `runFileAction(_:)`.
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

    /// Starts what the user confirmed. The two paths are deliberately
    /// different, and the difference is the design's central claim:
    ///
    /// - **Remote: typed, not executed.** The resolved lines go to the
    ///   session's shell through the path a snippet takes, so Core executes
    ///   nothing and the user watches the command run where they would read
    ///   it anyway.
    /// - **Local: spawned, with no shell.** The argv is handed to
    ///   `FileActionActivity`, which owns the work. This function starts no
    ///   task of its own: a run owned by nothing survives the tab that
    ///   started it, and the teardown's one `cancel()` would find nothing to
    ///   cancel (`FileActionPaneWiringGuardTests` holds that in place).
    func runFileAction(_ request: FileActionRequest) {
        guard case .success(let plan) = request.outcome else { return }
        switch plan {
        case .shellLines(let lines):
            typeIntoShell(lines)
        case .invocations:
            let runner = LocalFileActionRunner(
                currentDirectory: URL(fileURLWithPath: viewModel.currentPath, isDirectory: true))
            if !viewModel.fileActionActivity.run(plan, title: request.action.name, using: runner) {
                fileActionAlertMessage = L10n.string(
                    "fileAction.run.busy",
                    "Another action is still running in this pane. Wait for it to finish, or cancel it.")
            }
        }
    }

    /// Sends each line, in order, as a snippet's Execute would.
    ///
    /// Every line goes through `SnippetSendPlanner`, the decision the
    /// snippet surfaces share, and its bytes reach the shell unchanged: a
    /// NUL inside a quoted value is kept, because `FileActionPlanner` does not
    /// refuse one on this path and the confirmation sheet drew it as a
    /// marker. Dropping or normalising it here would make the sheet and the
    /// shell disagree about what ran.
    ///
    /// A failure of one line does not stop the rest: nothing reads the
    /// shell's output, so there is nothing to decide on.
    private func typeIntoShell(_ lines: [String]) {
        guard let shell else {
            fileActionAlertMessage = Self.noShellSentence
            return
        }
        let bracketedPaste = shell.wantsBracketedPaste()
        for line in lines {
            switch SnippetSendPlanner.plan(
                command: line, execute: true, bracketedPaste: bracketedPaste)
            {
            case .send(let bytes):
                guard shell.type(bytes) else {
                    fileActionAlertMessage = Self.noShellSentence
                    return
                }
            case .refusedMultilineInsert:
                // Only an insert is ever refused, and this sends with execute.
                return
            }
        }
    }

    private static var noShellSentence: String {
        L10n.string(
            "fileAction.run.noShell",
            "This action is typed into a shell, and this connection has none.")
    }
}
