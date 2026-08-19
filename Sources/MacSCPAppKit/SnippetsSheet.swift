import SwiftUI
import UniformTypeIdentifiers
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
    /// The filter row's current chip (Task 5): starts at `.all`, same as the
    /// row itself always starts on the "All" chip.
    @State private var tagFilter: SnippetTagFilter = .all
    @State private var editorTarget: SnippetEditorTarget?
    @State private var isShowingDeleteConfirm = false
    @State private var errorMessage: String?

    // MARK: - Export (P3b/T3)

    @State private var exportDocument: SnippetExportDocument?
    @State private var showExportFileExporter = false
    /// Non-nil while the export confirmation is up: the snippets the user
    /// is about to write, held rather than recomputed so the confirmed set
    /// and the written set are the SAME array — not two separate
    /// evaluations of `ListExportScope.resolve(...)` that could disagree.
    @State private var pendingExport: [Snippet]?

    // MARK: - Import (P3b/T4)

    @State private var showImportFileImporter = false
    /// Feeds every naming collision through the shared `ImportConflictSheet`
    /// — the same bridge, sheet, and arbiter shape `LoginSetsSheet`'s import
    /// already drives (`SnippetImportPlanner`'s own doc comment: both import
    /// flows are meant to feel identical).
    @State private var importConflictBridge = ImportConflictBridge()
    @State private var importResultMessage = ""
    @State private var showImportResultAlert = false

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
            predicate.matches("\($0.name) \($0.command)") && tagFilter.matches($0)
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("snippets.sheet.title", "Snippets")).font(.headline)

            if let displayedError {
                Text(displayedError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            SnippetTagFilterRow(snippets: snippets, selection: $tagFilter)
                .padding(.bottom, 4)

            if visibleSnippets.isEmpty {
                Spacer(minLength: 0)
                // Only an actually-read store may be called empty. For an
                // unreadable one the space stays blank and the message above
                // says what happened — claiming "No snippets yet." there
                // would be the sheet telling the user their snippets are
                // gone when the file still holds every one of them.
                if !load.isUnreadable {
                    Text(snippetsAreFiltered(searchText: searchText, tagFilter: tagFilter)
                        ? L10n.string("snippets.noMatches", "No matches.")
                        : L10n.string("snippets.empty", "No snippets yet."))
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
                // Arms the export confirmation with the resolved scope — the
                // selection when it is one of the rows on screen, otherwise
                // every row on screen, per `ListExportScope`. Enablement is
                // `snippetsCanExport` (`SnippetsPresentation.swift`), which
                // also rules out an unreadable store explicitly rather than
                // leaning on `visibleSnippets` happening to be empty in that
                // case too.
                Button(L10n.string("snippets.export", "Export…")) {
                    // `snippetsCanExport` already rules out an empty visible
                    // list, so the resolved scope always has at least one
                    // snippet in it.
                    pendingExport = ListExportScope.resolve(
                        selectedID: selectedID, from: visibleSnippets)
                }
                .buttonStyle(.polished)
                .disabled(!snippetsCanExport(load: load, visibleSnippets: visibleSnippets))
                Button(L10n.string("snippets.import", "Import…")) {
                    showImportFileImporter = true
                }
                .buttonStyle(.polished)
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
            SnippetEditorView(
                existing: target.existing, allSnippets: snippets, store: store,
                onSaved: { reload() })
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
        // MARK: Export (P3b/T3)
        .alert(
            L10n.string("snippets.export.confirm.title", "Export snippets?"),
            isPresented: Binding(
                get: { pendingExport != nil },
                set: { if !$0 { pendingExport = nil } })
        ) {
            Button(L10n.string("snippets.export", "Export…")) {
                if let pendingExport { performExport(pendingExport) }
                pendingExport = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                pendingExport = nil
            }
        } message: {
            Text(String(
                format: L10n.string(
                    "snippets.export.confirm.message %lld",
                    "%lld snippets will be written to the file."),
                pendingExport?.count ?? 0))
        }
        .fileExporter(
            isPresented: $showExportFileExporter,
            document: exportDocument,
            contentType: .macscpSnippets,
            // NOT localized, unlike everything else in this file, and the
            // same literal both siblings use (`ContentView+Sheets`'s
            // "macSCP Sessions.macscpsessions", `LoginSetsSheet`'s
            // "macSCP Logins.macscplogins"). The trailing extension is
            // load-bearing: a translator editing past the dot produces a
            // file macOS does not associate with this app and the importer's
            // own `allowedContentTypes` filter then hides. It was the one
            // localized `defaultFilename` in the project, and all four
            // catalogs carried the identical untranslated English string
            // anyway.
            defaultFilename: "macSCP Snippets.macscpsnippets"
        ) { result in
            handleExportResult(result)
        }
        // MARK: Import (P3b/T4)
        .fileImporter(
            isPresented: $showImportFileImporter,
            allowedContentTypes: [.macscpSnippets, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportFileSelection(result)
        }
        // Same shared modifier the session and login-set imports use, so
        // all three flows present one sheet rather than each inventing its
        // own — see `importConflictSheet(bridge:)`.
        .importConflictSheet(bridge: importConflictBridge)
        .alert(
            L10n.string("import.result.title", "Import Complete"),
            isPresented: $showImportResultAlert
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importResultMessage)
        }
    }

    private func reload() { load = SnippetsLoad(reading: store) }

    /// Builds the payload from exactly the snippets handed in — this
    /// function does no filtering of its own. Two callers reach it: the
    /// export confirmation's own button, passing the resolved scope held in
    /// `pendingExport`, and the row menu, passing exactly the one
    /// right-clicked snippet. Encodes the payload and arms `fileExporter`.
    /// Mirrors `LoginSetsSheet.performExport`, minus the options/password
    /// step that codec has no parameter for (see `SnippetExportCodec`'s own
    /// doc comment on why).
    private func performExport(_ snippets: [Snippet]) {
        do {
            let data = try SnippetExportCodec.encode(SnippetExportPayload(snippets: snippets))
            exportDocument = SnippetExportDocument(data: data)
            errorMessage = nil
            showExportFileExporter = true
        } catch {
            errorMessage = String(format: L10n.string(
                "export.error.encodeFailed %@", "Could not prepare the export: %@"),
                String(describing: error))
        }
    }

    /// `fileExporter` completion — reuses the sheet's one error slot rather
    /// than adding a dedicated alert (unlike `LoginSetsSheet`'s export,
    /// which has one): there is no per-export notice to show on success
    /// (nothing here is ever omitted the way a missing secret or an
    /// external key file is for login sets), so the only outcome worth
    /// surfacing at all is a write failure, and this sheet already has a
    /// place for that.
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            errorMessage = nil
        case .failure(let error):
            errorMessage = String(format: L10n.string(
                "export.error.writeFailed %@", "Could not write the export file: %@"),
                String(describing: error))
        }
        exportDocument = nil
    }

    // MARK: - Import (P3b/T4)

    /// `fileImporter` completion. Reads the chosen file with security-scoped
    /// access (same reason `LoginSetsSheet.handleImportFileSelection` does —
    /// the URL comes from an `NSOpenPanel` outside this app's own sandbox
    /// container), then `probe`s before `decode`s, mirroring the flow both
    /// other import paths use.
    ///
    /// Unlike those two, `probe`'s returned Bool is never read here — and
    /// deliberately so, because it is not always `false`: this codec never
    /// WRITES an encrypted file, but a foreign file claiming our format with
    /// `"encrypted" : true` probes as `true` (see `SnippetExportCodec
    /// .probe`'s own doc comment). Reading that Bool would only lead to a
    /// password prompt this format has no key path for; ignoring it lets
    /// `decode` refuse the file with `.passwordRequired`, which
    /// `snippetImportErrorText` maps to the same generic refusal as any
    /// other unreadable file. So the call's only job is to fail fast —
    /// through the SAME typed
    /// `SessionExportError` `decode` would throw — on a file of the wrong
    /// kind (a session or login-set export) or one that is unreadable.
    /// `decode` would catch either case on its own, so the explicit `probe`
    /// call is redundant work, kept only for shape parity with the shared
    /// flow.
    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = ImportFeedbackText.readErrorMessage(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try SnippetExportCodec.probe(data)
                let payload = try SnippetExportCodec.decode(data)
                errorMessage = nil
                Task { await applyImport(payload) }
            } catch let error as SessionExportError {
                errorMessage = snippetImportErrorText(for: error)
            } catch {
                errorMessage = ImportFeedbackText.readErrorMessage(error)
            }
        }
    }

    /// Plan → apply through the SHARED arbiter and the one conflict sheet
    /// both other import flows present (`LoginSetsSheet.applyImport` is the
    /// direct precedent). A cancelled run writes nothing and shows no
    /// result alert at all — `plan.cancelled` says so, and the `guard`
    /// below is what keeps Cancel actually meaning "nothing happened"
    /// rather than "whatever had already been planned got written anyway".
    ///
    /// The actual write (`applySnippetImportPlan`) and the result-text
    /// composition (`snippetImportResultText`) live in
    /// `SnippetsPresentation.swift`, not here — same reason `SnippetsLoad`
    /// does: this file has no test target of its own to hold a View's
    /// private methods honest.
    private func applyImport(_ payload: SnippetExportPayload) async {
        let bridge = importConflictBridge
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let plan = await SnippetImportPlanner.plan(
            existing: snippets, incoming: payload, arbiter: arbiter)
        guard !plan.cancelled else { return }

        let applied = applySnippetImportPlan(plan, to: store)
        reload()
        selectedID = nil
        importResultMessage = snippetImportResultText(plan: plan, applied: applied)
        showImportResultAlert = true
    }

    @ViewBuilder
    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name).font(.system(size: 13))
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
            // Single-snippet export (P3f) — the footer covers the resolved
            // scope and confirms first; this one always means THIS row,
            // unconfirmed.
            //
            // No `snippetsCanExport` guard needed here: a row only exists
            // when `visibleSnippets` is non-empty, and an unreadable store
            // yields no snippets at all — so both of that guard's
            // conditions already hold whenever this menu can be opened.
            Button(L10n.string("snippets.export", "Export…")) {
                selectedID = snippet.id
                performExport([snippet])
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

/// The list's tag filter row (Task 5): "All", one chip per tag (with how
/// many snippets carry it — `SnippetTagSuggestions.all(in:)`, the same
/// ranking `SnippetTagField`'s suggestion list uses), then "No Tag" for
/// snippets with no tags at all. Selecting a chip sets `selection`
/// accordingly; `SnippetTagFilter`'s own single-case shape (see its doc
/// comment) is what keeps this single-valued — there is nothing here to
/// enforce beyond writing one case into the binding per tap.
///
/// The pill is `TagFilterChip` and the horizontal-scroll shell is
/// `TagFilterScrollRow` (P3a/T6 fix round 1), both shared with the
/// sidebar's host-tag filter row — this row keeps its own per-tag COUNT
/// formatting and "No Tag" chip as CONTENT inside that shell, which the
/// sidebar's simpler row has no equivalent for.
private struct SnippetTagFilterRow: View {
    let snippets: [Snippet]
    @Binding var selection: SnippetTagFilter

    var body: some View {
        TagFilterScrollRow {
            TagFilterChip(
                title: L10n.string("snippets.filter.all", "All"),
                isSelected: selection == .all,
                onSelect: { selection = .all })
            ForEach(SnippetTagSuggestions.all(in: snippets), id: \.tag) { entry in
                TagFilterChip(
                    title: String(
                        format: L10n.string(
                            "snippets.filter.tagCount %1$@ %2$lld", "%1$@ (%2$lld)"),
                        entry.tag, entry.count),
                    isSelected: selection == .tag(entry.tag),
                    onSelect: { selection = .tag(entry.tag) })
            }
            let untaggedCount = snippets.filter { $0.tags.isEmpty }.count
            if untaggedCount > 0 {
                TagFilterChip(
                    title: String(
                        format: L10n.string(
                            "snippets.filter.tagCount %1$@ %2$lld", "%1$@ (%2$lld)"),
                        L10n.string("snippets.filter.untagged", "No Tag"), untaggedCount),
                    isSelected: selection == .untagged,
                    onSelect: { selection = .untagged })
            }
        }
    }
}

/// New/Edit sub-sheet: name, a single-line command, and tags. Shape mirrors
/// `SSHKeysSheet.RenameKeySheet` — it threads the store straight through and
/// owns its own save/error/dismiss cycle, since there is no view model
/// between this sheet and `SnippetStore` the way `LoginSetsSheet` has
/// `SessionListViewModel`.
///
/// `Snippet.init?` is failable and refuses a `command` containing any
/// character Swift considers a newline (see its own doc comment). This view
/// does not re-check that rule itself — it constructs the `Snippet` through
/// the same initializer and surfaces a `nil` result as an inline error.
private struct SnippetEditorView: View {
    let existing: Snippet?
    /// The sheet's already-loaded list, passed straight through (Task 5)
    /// rather than re-read here: it is what `SnippetTagSuggestions` needs to
    /// suggest existing tags, and `SnippetsSheet` already has it as its own
    /// `SnippetsLoad` outcome — reading the store a second time here would
    /// be a second, independent read that could disagree with the parent's
    /// (e.g. if the file changed between the two reads).
    let allSnippets: [Snippet]
    let store: SnippetStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var tags: [String]
    @State private var errorMessage: String?

    init(
        existing: Snippet?, allSnippets: [Snippet], store: SnippetStore,
        onSaved: @escaping () -> Void
    ) {
        self.existing = existing
        self.allSnippets = allSnippets
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _command = State(initialValue: existing?.command ?? "")
        _tags = State(initialValue: existing?.tags ?? [])
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
            FormRow(label: L10n.string("snippets.tags.label", "Tags")) {
                SnippetTagField(tags: $tags, suggestions: tagSuggestions)
            }
            // Credentials note (Terminal-Snippets design doc, "Snippets
            // enthalten keine Zugangsdaten"): the reason, not a bare
            // prohibition. The store is plain JSON, so it holds no
            // passwords by construction — and even a typed one would still
            // show up in `ps` while running and in the shell history on the
            // far host, so hiding it here would not actually protect it.
            Text(L10n.string(
                "snippets.editor.credentialsNote",
                """
                Don't put credentials here: the store is plain JSON, a command line is \
                visible in ps and in the shell history on the far host anyway, and \
                running it also keeps the command in this session's log.
                """))
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

    /// Built from `allSnippets`/`tags` on every call rather than cached —
    /// `SnippetTagField` calls this fresh on every keystroke anyway (see its
    /// doc comment), so there is no separate "is this stale" question to
    /// answer.
    private func tagSuggestions(for query: String) -> [(tag: String, count: Int)] {
        SnippetTagSuggestions.matching(query, in: allSnippets, excluding: tags)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snippet = Snippet(
            id: existing?.id ?? UUID(), name: trimmedName, command: command,
            tags: tags)
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
