import SwiftUI
import macSCPCore

/// Snippet management sheet (Terminal-Snippets milestone, Task 3): lists
/// every saved `Snippet`, with single-selection New/Edit/Delete and a
/// search field filtering on name and command — the same shape
/// `LoginSetsSheet` uses (single selection, footer buttons, fixed
/// `.frame(width: 720, height: 460)`, row `.contextMenu`, `SheetSearchField`
/// + `sheetSearchPredicate`, the M18 "clear the selection when the search
/// filters it out" fix). Unlike `LoginSetsSheet` there is no view-model
/// layer between this sheet and its store — `SnippetStore` is read and
/// written directly, closer to how `SSHKeysSheet`'s own sub-sheets
/// (`GenerateKeySheet`, `RenameKeySheet`) thread a store straight through
/// and own their save/error/dismiss cycle.
///
/// Presented from the Terminal menu (Task 4) — this file only builds the
/// sheet, it does not trigger it.
///
/// This is view code with no dedicated view-testing tool in this project
/// (M29 made that gap explicit): no test in this repo renders this body or
/// clicks anything in it, the same boundary `LoginSetsSheet`/`SSHKeysSheet`
/// already live with. What IS tested is the decision the body renders —
/// `SnippetsLoad`, which decides whether this sheet may say "No snippets
/// yet." — in `SnippetsPresentationTests`.
struct SnippetsSheet: View {
    let store: SnippetStore

    @Environment(\.dismiss) private var dismiss

    /// The last read of the store — the OUTCOME, not just a list, so an
    /// unreadable file cannot be shown as "no snippets yet" (see
    /// `SnippetsLoad`).
    @State private var load: SnippetsLoad = .loaded([])
    @State private var selectedID: Snippet.ID?
    @State private var searchText = ""
    @State private var searchIsRegex = false
    @State private var editorTarget: SnippetEditorTarget?
    @State private var isShowingDeleteConfirm = false
    @State private var errorMessage: String?

    /// Wraps "new" (no existing snippet) or "edit" (a specific one) so
    /// `.sheet(item:)` has a stable identity even for the "new" case —
    /// same pattern as `LoginSetsSheet.LoginSetEditorTarget`.
    private struct SnippetEditorTarget: Identifiable {
        let id = UUID()
        let existing: Snippet?
    }

    private var snippets: [Snippet] { load.snippets }

    private var selectedSnippet: Snippet? {
        snippets.first { $0.id == selectedID }
    }

    /// The one message the sheet shows. A store that cannot be read wins over
    /// an action error: it explains why the list is empty, and every action
    /// against such a store fails for that same reason (`save`/`remove` read
    /// the file before writing), so the read message is the informative one.
    private var displayedError: String? {
        if load.isUnreadable {
            return L10n.string(
                "snippets.load.error",
                "The snippets file couldn't be read. It exists but can't be decoded — no snippet was lost, and nothing will be written over it.")
        }
        return errorMessage
    }

    var body: some View {
        let (predicate, searchError) = sheetSearchPredicate(
            text: searchText, isRegex: searchIsRegex)
        let visibleSnippets = snippets.filter {
            predicate.matches("\($0.name) \($0.command)")
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("snippets.sheet.title", "Snippets")).font(.headline)

            if let displayedError {
                Text(displayedError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)
                .padding(.bottom, 4)

            if visibleSnippets.isEmpty {
                Spacer(minLength: 0)
                // Only an actually-read store may be called empty. For an
                // unreadable one the space stays blank and the message above
                // says what happened — claiming "No snippets yet." there
                // would be the sheet telling the user their snippets are
                // gone when the file still holds every one of them.
                if !load.isUnreadable {
                    Text(searchText.isEmpty
                        ? L10n.string("snippets.empty", "No snippets yet.")
                        : L10n.string("snippets.noMatches", "No matches."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Spacer(minLength: 0)
            } else {
                List(visibleSnippets, selection: $selectedID) { snippet in
                    row(snippet)
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("snippets.new", "New…")) {
                    editorTarget = SnippetEditorTarget(existing: nil)
                }
                .buttonStyle(.polished)
                Button(L10n.string("snippets.edit", "Edit…")) {
                    if let selectedSnippet {
                        editorTarget = SnippetEditorTarget(existing: selectedSnippet)
                    }
                }
                .buttonStyle(.polished)
                .disabled(selectedSnippet == nil)
                Button(L10n.string("snippets.delete", "Delete…"), role: .destructive) {
                    isShowingDeleteConfirm = true
                }
                .buttonStyle(.polished)
                .disabled(selectedSnippet == nil)
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        // Same M18 search regression fix `LoginSetsSheet` carries, attached
        // to the enclosing VStack rather than the `List` so it still runs
        // once a search filters every row away and the `List` is removed
        // from the tree.
        .onChange(of: visibleSnippets) { _, newValue in
            if let selectedID, !newValue.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { reload() }
        .sheet(item: $editorTarget) { target in
            SnippetEditorView(existing: target.existing, store: store, onSaved: { reload() })
        }
        .confirmationDialog(
            L10n.string("snippets.delete.title", "Delete this snippet?"),
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("snippets.delete.confirm", "Delete"), role: .destructive) {
                performDelete()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    private func reload() { load = SnippetsLoad(reading: store) }

    @ViewBuilder
    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snippet.name).font(.system(size: 13))
                    if snippet.runsImmediately {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.localAmber)
                            .help(L10n.string(
                                "snippets.runsImmediately.help", "Runs immediately when triggered"))
                    }
                }
                Text(snippet.command)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        // Row context menu, same trigger-sharing pattern as
        // `LoginSetsSheet.row`: selection is set first so the action targets
        // the right-clicked row even if it wasn't already selected.
        .contextMenu {
            Button(L10n.string("snippets.edit", "Edit…")) {
                selectedID = snippet.id
                editorTarget = SnippetEditorTarget(existing: snippet)
            }
            Button(L10n.string("snippets.delete", "Delete…"), role: .destructive) {
                selectedID = snippet.id
                isShowingDeleteConfirm = true
            }
        }
    }

    /// Reuses the app's one generic "will be deleted" phrasing
    /// (`BrowserPane`'s single-item delete uses the same key) rather than
    /// adding a near-duplicate — this dialog has no usage count or other
    /// side effect to name, unlike `LoginSetsSheet`'s or `SSHKeysSheet`'s.
    private var deleteConfirmMessage: String {
        guard let selectedSnippet else { return "" }
        return String(
            format: L10n.string("delete.message.single", "“%@” will be deleted."),
            selectedSnippet.name)
    }

    private func performDelete() {
        guard let selectedSnippet else { return }
        do {
            try store.remove(id: selectedSnippet.id)
            errorMessage = nil
        } catch {
            errorMessage = L10n.string("snippets.delete.error", "Couldn't delete the snippet.")
        }
        selectedID = nil
        reload()
    }
}

/// New/Edit sub-sheet: name, a single-line command, and the "Run
/// immediately" toggle. Shape mirrors `SSHKeysSheet.RenameKeySheet` — it
/// threads the store straight through and owns its own save/error/dismiss
/// cycle, since there is no view model between this sheet and `SnippetStore`
/// the way `LoginSetsSheet` has `SessionListViewModel`.
///
/// `Snippet.init?` is failable and refuses a `command` containing `\n` or
/// `\r` (see its own doc comment). This view does not re-check that rule
/// itself — it constructs the `Snippet` through the same initializer and
/// surfaces a `nil` result as an inline error.
private struct SnippetEditorView: View {
    let existing: Snippet?
    let store: SnippetStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var runsImmediately: Bool
    @State private var errorMessage: String?

    init(existing: Snippet?, store: SnippetStore, onSaved: @escaping () -> Void) {
        self.existing = existing
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _command = State(initialValue: existing?.command ?? "")
        _runsImmediately = State(initialValue: existing?.runsImmediately ?? false)
    }

    private var isEditing: Bool { existing != nil }

    /// Only the required-fields check — NOT the single-line rule, which
    /// `save()` finds out by asking `Snippet.init?` itself. Disabling Save
    /// pre-emptively for a pasted-in line break would silently discard the
    /// signal this view is supposed to surface.
    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing
                ? L10n.string("snippets.editor.titleEdit", "Edit Snippet")
                : L10n.string("snippets.editor.titleNew", "New Snippet"))
                .font(.title3.bold())

            let nameLabel = L10n.string("snippets.editor.name", "Name")
            FormRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }
            let commandLabel = L10n.string("snippets.editor.command", "Command")
            FormRow(label: commandLabel) {
                TextField(commandLabel, text: $command, prompt: Text(verbatim: ""))
            }
            FormRow(label: "") {
                Toggle(
                    L10n.string("snippets.editor.runsImmediately", "Run immediately"),
                    isOn: $runsImmediately
                )
                .toggleStyle(.checkbox)
            }

            // Credentials note (Terminal-Snippets design doc, "Snippets
            // enthalten keine Zugangsdaten"): the reason, not a bare
            // prohibition. The store is plain JSON, so it holds no
            // passwords by construction — and even a typed one would still
            // show up in `ps` while running and in the shell history on the
            // far host, so hiding it here would not actually protect it.
            Text(L10n.string(
                "snippets.editor.credentialsNote",
                "Don't put credentials here: the store is plain JSON, and a command line is visible in ps and in the shell history on the far host anyway."))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) { save() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .textFieldStyle(.roundedBorder)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snippet = Snippet(
            id: existing?.id ?? UUID(), name: trimmedName, command: command,
            runsImmediately: runsImmediately)
        else {
            errorMessage = L10n.string(
                "snippets.editor.error.multiline", "The command can't contain a line break.")
            return
        }
        do {
            try store.save(snippet)
            onSaved()
            dismiss()
        } catch {
            errorMessage = L10n.string("snippets.editor.error.save", "Couldn't save the snippet.")
        }
    }
}
