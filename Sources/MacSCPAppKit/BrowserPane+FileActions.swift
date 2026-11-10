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

/// An action that declares variables, waiting for their values. Held from the
/// moment the menu entry is chosen until the user answers the prompt; nothing
/// has been planned yet, because the plan needs the values.
struct FileActionPrompt: Identifiable {
    let id = UUID()
    let action: FileAction
    let selection: [RemoteFileItem]
    let snippet: Snippet
    let initialValues: [String: String]
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
    /// way a snippet is sent. `false` when the tab has no shell at all, or
    /// when the terminal refused the bytes: see `refusedInput`.
    let type: ([UInt8]) -> Bool
    /// Whether the terminal refused input of this attempt because its
    /// opening buffer was full. Read after `type` returned `false`, to tell
    /// "no shell" from "a shell that has not opened yet and cannot hold
    /// more": the second is already worded by the terminal panel. The flag
    /// can still be set once the shell runs, but a running shell takes every
    /// send, so `type` is not `false` then.
    let refusedInput: () -> Bool
}

/// How typing a file action's lines into the shell ended.
enum FileActionTypingOutcome: Equatable {
    /// Every line was handed to the terminal, or the planner declined to
    /// send one (which it does only for an insert, never for these lines).
    case typed
    /// The tab has no shell to type into.
    case noShell
    /// The terminal refused a line because its opening buffer could not hold
    /// it. That line was NOT typed and neither was anything after it.
    case refusedByTerminal
}

extension FileActionShell {
    /// Sends each line, in order, as a snippet's Execute would, and stops at
    /// the first line the terminal does not take.
    ///
    /// Every line goes through `SnippetSendPlanner`, the decision the
    /// snippet surfaces share, and its bytes reach the shell unchanged: a
    /// control character in a prompted value is kept, because the
    /// confirmation sheet drew it as a marker. Dropping or normalising it
    /// here would make the sheet and the shell disagree about what ran. The
    /// same character in a SELECTION-derived value never gets here:
    /// `FileActionPlanner` refuses it, since these lines are typed and the
    /// line editor acts on a C0 byte whatever quotes surround it.
    ///
    /// Stopping is the point: a later, shorter line must not be typed
    /// without the refused one before it. A refused line is told apart from
    /// a missing shell by `refusedInput`, read after `type` returned `false`.
    func typeLines(_ lines: [String]) -> FileActionTypingOutcome {
        let bracketedPaste = wantsBracketedPaste()
        for line in lines {
            switch SnippetSendPlanner.plan(
                command: line, execute: true, bracketedPaste: bracketedPaste)
            {
            case .send(let bytes):
                guard type(bytes) else {
                    return refusedInput() ? .refusedByTerminal : .noShell
                }
            case .refusedMultilineInsert:
                // Only an insert is ever refused, and this sends with execute.
                return .typed
            }
        }
        return .typed
    }
}

extension BrowserPane {
    /// Builds the plan and opens the confirmation sheet. **Nothing runs
    /// here** — the sheet's confirm button is what starts it, through
    /// `runFileAction(_:)`.
    ///
    /// The side is the pane's own `side`, the single source for which pane
    /// this is. It is not derived from `supportsArchiving`, which says what
    /// the pane can do and is `false` on a remote pane that cannot archive.
    ///
    /// **An action that declares variables asks for their values first.**
    /// The planner fills a declared placeholder from `promptedValues` and,
    /// given none, with the empty string, so planning such an action here
    /// would type or spawn it with an empty argument where its author
    /// expected a value. The prompt is the snippet trigger's own sheet and
    /// remembers nothing; confirming it plans, cancelling it does not.
    func beginFileAction(_ action: FileAction, selection: [RemoteFileItem]) {
        guard action.variables.isEmpty else {
            fileActionPrompt = FileActionPrompt(
                action: action, selection: selection,
                snippet: fileActionPromptSnippet(for: action),
                initialValues: fileActionPromptValues(for: action))
            return
        }
        presentFileActionRequest(action, selection, promptedValues: [:])
    }

    /// Plans with the values given and opens the confirmation sheet. The one
    /// place a plan is made for the menu, so the values the user typed are
    /// the values the sheet shows and the run sends.
    func presentFileActionRequest(
        _ action: FileAction, _ selection: [RemoteFileItem], promptedValues: [String: String]
    ) {
        fileActionRequest = FileActionRequest(
            action: action, selection: selection,
            outcome: FileActionPlanner.plan(
                action: action, selection: selection, side: side,
                promptedValues: promptedValues))
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

    /// Types the lines into the tab's shell and says why not when it cannot.
    /// The loop, and the reason a line stops it, are
    /// `FileActionShell.typeLines(_:)`'s.
    private func typeIntoShell(_ lines: [String]) {
        guard let shell else {
            fileActionAlertMessage = Self.noShellSentence
            return
        }
        switch shell.typeLines(lines) {
        case .typed:
            return
        case .noShell:
            fileActionAlertMessage = Self.noShellSentence
        case .refusedByTerminal:
            // No alert: the terminal panel shows its own sentence for as
            // long as the refusal is recorded
            // (`TerminalPanelViewModel.inputRefused`), and "this connection
            // has none" would be false of it.
            return
        }
    }

    private static var noShellSentence: String {
        L10n.string(
            "fileAction.run.noShell",
            "This action is typed into a shell, and this connection has none.")
    }
}
