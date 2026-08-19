import SwiftUI
import macSCPCore

/// The values prompt shown before a snippet with declared variables runs
/// (Snippet-Variablen, Task 6): one field per declaration, "Run" or
/// "Cancel". `ContentView.triggerSnippet` presents this INSTEAD of sending
/// anything the moment it sees `snippet.variables` is non-empty; a snippet
/// with no declarations never reaches this view at all.
///
/// Cancelling sends nothing: `onCancel` is the only other way out besides
/// `onConfirm`, and neither `SnippetVariableSubstitution.resolve` nor
/// `SnippetVariableMemoryStore.remember` is reached unless the user
/// actually presses "Run" — both live in `ContentView`'s `onConfirm`
/// closure, not here. This view only collects `values` and hands them
/// back; it has no store access of its own.
///
/// Each field starts from `initialValues[variable.name]` — the remembered
/// value if there is one, else `SnippetVariable.defaultValue` — a fallback
/// `ContentView.triggerSnippet` computes before presenting this sheet, not
/// something this view looks up itself.
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
struct SnippetVariablePromptSheet: View {
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
        .frame(width: 380)
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
