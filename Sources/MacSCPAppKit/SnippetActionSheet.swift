import SwiftUI
import macSCPCore

/// The window a double-click on a row of the flattened snippet list opens
/// (P3d, Task 2): the snippet's name, its command in plain text, and three
/// actions — Insert, Execute, Cancel. This file only builds the view; Task 3
/// wires the double-click gesture that presents it and decides how (a
/// `.sheet(item:)`, most likely, given every other multi-outcome prompt in
/// this app — `ImportConflictSheet`, the M5b transfer conflict sheet — uses
/// that shape).
///
/// This is a NEW view, not a reuse of `SnippetMenuItems`' per-snippet
/// submenu: that submenu is still what the three `NSMenu` surfaces
/// (menu bar, terminal right-click, session context menu) render, and stays
/// untouched by this phase — see that type's own doc comment. This window
/// exists only for the flattened popover Task 3 is about to build.
///
/// ## The keyboard assignment is a maintainer decision, not a default
///
/// `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md` (P3d) fixes it:
/// **Esc cancels**, **Return inserts**, **⌘Return executes**. On macOS,
/// Return activates a dialog's DEFAULT button. Putting Execute on Return
/// would let double-click + Return start a command on a remote host in two
/// keystrokes — more casual than the nested submenu this phase replaces,
/// the opposite of what replacing it is for. Return on Insert is harmless:
/// the text lands in the terminal's prompt, and the user still presses
/// Return themselves, after reading it, to actually run anything.
///
/// The three shortcuts below follow the app-wide sheet convention this
/// project already documents (`KeyboardShortcutsCatalog`'s hand-maintained
/// mirror, group 6: `.keyboardShortcut(.defaultAction)` for Return,
/// `role: .cancel` for Escape) plus one addition specific to this window:
/// Execute's own `⌘Return`, which no other sheet in this app needs because
/// no other sheet has a second, riskier action worth a keystroke.
///
/// **Pinned** by `SnippetActionSheetKeyboardShortcutGuardTests`, the same
/// source-text-scan idiom `SnippetMenuItemsKeyboardShortcutGuardTests`
/// established for the identical risk one layer up (Insert/Execute on the
/// menu submenu): a future refactor moving `.defaultAction` onto Execute
/// would compile and every other test would stay green. Chosen deliberately
/// over adding nothing: this view's three buttons are plain SwiftUI
/// modifiers with no type standing between them and the wrong shortcut
/// landing on the wrong one (unlike `SnippetMenuPlan.Entry`, which has no
/// FIELD an execute shortcut could travel through — there is no equivalent
/// per-row model here to lean on structurally). The new guard is kept
/// smaller than its precedent: this file has three flat, top-level buttons
/// and no wrapping function like `insertButton` to isolate by brace
/// counting, so the scanner only needs to find each button's own block by
/// its localization key and read the one modifier line that follows it.
struct SnippetActionSheet: View {
    let snippet: Snippet
    let onInsert: () -> Void
    let onExecute: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("snippets.action.title", "Snippet")).font(.headline)
            Text(snippet.name).font(.title3.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("snippets.action.command", "Command"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(snippet.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(L10n.string("snippets.action.cancel", "Cancel"), role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.polished)
                Button(L10n.string("snippets.action.execute", "Execute")) {
                    onExecute()
                }
                .buttonStyle(.polished)
                .keyboardShortcut(.return, modifiers: .command)
                Button(L10n.string("snippets.action.insert", "Insert")) {
                    onInsert()
                }
                .buttonStyle(.polishedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
