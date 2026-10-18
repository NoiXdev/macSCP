import SwiftUI
import macSCPCore

/// The values prompt shown before a snippet with declared variables runs
/// (Snippet-Variablen, Task 6): one field per declaration, "Run" or
/// "Cancel". `ContentView.triggerSnippet` presents this INSTEAD of sending
/// anything the moment it sees `snippet.variables` is non-empty; a snippet
/// with no declarations never reaches this view at all.
///
/// Presented by every surface that needs values before it does something
/// with a template — to RUN a snippet, to DESCRIBE one (the snippet
/// editor's "Test" button, Snippet-Probelauf, Task 4), and to RUN a file
/// action (the file-actions work of 2026-10-12, which wraps the action's
/// declarations in a `Snippet` for this sheet). Counted while writing this
/// and re-run afterwards, 2026-10-12, from the repository root:
/// `/usr/bin/grep -rn 'SnippetVariablePromptSheet($' Sources/` prints
/// three lines. The `$` is an end anchor, which both the BSD grep at
/// `/usr/bin/grep` and the ugrep a Claude session's `grep` function runs
/// agree on at the end of a pattern (checked side by side) — and it is
/// what keeps THIS sentence out of its own answer: a presentation puts the
/// opening parenthesis last on the line, and the sentence quoting the
/// command does not. The unanchored form prints four lines, the fourth
/// being this comment. The kinds are named above rather than counted here
/// all the same, so that a fourth surface makes the sentence incomplete
/// rather than false.
///
/// Deliberately the same view for all of them — a second prompt shape would
/// be a second answer to "what is a value here", and the rehearsal would be
/// the half that drifted. What differs is entirely in the caller's
/// `onConfirm`: the editor's reaches `SnippetDryRun.describing` and stops
/// there, remembering nothing; the file action's goes on to its own
/// confirmation sheet.
///
/// Cancelling sends nothing: `onCancel` is the only other way out besides
/// `onConfirm`, and neither `SnippetVariableSubstitution.resolve` nor
/// `SnippetVariableMemoryStore.remember` is reached unless the user
/// actually presses "Run" — both live in the caller's `onConfirm` closure,
/// not here. This view only collects `values` and hands them back; it has
/// no store access of its own.
///
/// Each field starts from `initialValues[variable.name]` — the remembered
/// value if there is one, else `SnippetVariable.defaultValue`. Every
/// presenter computes that through `snippetVariablePromptValues` before
/// presenting this sheet — the file action's through
/// `fileActionPromptValues`, which forwards to it — and this view looks
/// nothing up itself, which is what keeps them from opening on different
/// values for the same declarations.
///
/// ## The empty-`.selection` decision (carried forward from Task 5)
///
/// A `.selection` declaration can be saved with zero options — nothing in
/// the editor (Task 5) rejects that today. A `Picker` built from an empty
/// list has nothing to offer and nothing valid to show as selected, so
/// this view does not build one for that case: an empty-option declaration
/// instead renders as a disabled field holding whatever `initialValues`
/// supplied, with a caption explaining why it cannot be edited. The run
/// still proceeds using that fixed value — the declaration is what is
/// broken, not the trigger, and refusing to run over one bad declaration
/// would strand every OTHER variable's value the user just typed into the
/// same sheet.
///
/// Untested, like `SnippetActionSheet`/`TerminalPanelHeader` before it: no
/// SwiftUI rendering harness exists in this project (see those views' own
/// doc comments for the same boundary).
struct SnippetVariablePromptSheet: BoundedView {
    /// The size `SnippetVariablePromptSheet` bounds itself to, applied with `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .width(380)

    let snippet: Snippet
    let onConfirm: (_ values: [String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String]

    init(
        snippet: Snippet, initialValues: [String: String],
        onConfirm: @escaping (_ values: [String: String]) -> Void, onCancel: @escaping () -> Void
    ) {
        self.snippet = snippet
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                format: L10n.string("snippets.variables.promptTitle %@", "Values for \u{201C}%@\u{201D}"),
                snippet.name)
            )
            .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(snippet.variables, id: \.name) { variable in
                    field(for: variable)
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.polished)
                Button(L10n.string("snippets.variables.promptRun", "Run")) {
                    onConfirm(values)
                }
                .buttonStyle(.polishedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
    }

    /// One declaration's field. `variable.prompt` is what the declaration
    /// was written with (a free-form label, e.g. "Database"), falling back
    /// to the raw `name` only if a declaration somehow carries an empty one
    /// — the editor (Task 5) does not enforce a non-empty prompt.
    @ViewBuilder
    private func field(for variable: SnippetVariable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variable.prompt.isEmpty ? variable.name : variable.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
            switch variable.kind {
            case .freeText:
                TextField("", text: binding(for: variable))
                    .textFieldStyle(.roundedBorder)
            case .selection(let options) where !options.isEmpty:
                Picker("", selection: binding(for: variable)) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
            case .selection:
                // Zero options — see this type's own doc comment.
                TextField("", text: binding(for: variable))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Text(L10n.string(
                    "snippets.variables.promptNoOptions",
                    "No options are configured for this variable."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for variable: SnippetVariable) -> Binding<String> {
        Binding(
            get: { values[variable.name] ?? variable.defaultValue },
            set: { values[variable.name] = $0 })
    }
}
