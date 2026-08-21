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
    /// Set by `performDelete` when `SnippetStore.remove(id:)` returns
    /// `.skipped`: the snippet itself is gone, but its remembered variable
    /// values could not be cleared (a corrupt or unwritable
    /// `snippet-variables.json`). Kept separate from `errorMessage` because
    /// the deletion did NOT fail — showing this in the same red "action
    /// failed" slot would tell the user their delete didn't work when it
    /// did.
    @State private var variablesCleanupWarning: String?

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
            // Orange, not red (same distinction `TransferQueueBar` draws for
            // `.interrupted`): the delete itself succeeded, this only warns
            // that a follow-up cleanup step did not.
            if let variablesCleanupWarning {
                Text(variablesCleanupWarning).font(.caption).foregroundStyle(.orange).lineLimit(2)
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
            Button(L10n.string("snippets.export.confirm", "Export")) {
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
            variablesCleanupWarning = nil
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
            variablesCleanupWarning = nil
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
                variablesCleanupWarning = nil
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
                let summary = SnippetCommandSummary.firstLine(of: snippet.command)
                HStack(spacing: 4) {
                    Text(summary.text)
                    if summary.moreLines > 0 {
                        Text(String(
                            format: L10n.string("snippets.command.moreLines %lld", "+%lld more"),
                            summary.moreLines))
                            .foregroundStyle(DesignTokens.inkTertiary)
                    }
                }
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
            let outcome = try store.remove(id: selectedSnippet.id)
            errorMessage = nil
            variablesCleanupWarning =
                outcome == .skipped
                ? L10n.string(
                    "snippets.delete.variablesError",
                    "The snippet was deleted, but its remembered values couldn't be cleared.")
                : nil
        } catch {
            errorMessage = L10n.string("snippets.delete.error", "Couldn't delete the snippet.")
            variablesCleanupWarning = nil
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

/// New/Edit sub-sheet: name, a command that may now span lines (snippet
/// editor, part 2), and tags. Shape mirrors `SSHKeysSheet.RenameKeySheet` —
/// it threads the store straight through and owns its own save/error/dismiss
/// cycle, since there is no view model between this sheet and `SnippetStore`
/// the way `LoginSetsSheet` has `SessionListViewModel`.
///
/// `Snippet`'s initializer is not failable and performs no validation of its
/// own — it just stores what it is given, `command` included. `command` is
/// bound to `SnippetCommandEditor`, which accepts a pasted multi-line string
/// as-is and now inserts a typed Return as a line break too (see that
/// file's own doc comment) — Save moved off plain Return onto ⌘Return so
/// the two no longer collide.
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
    /// Variable declarations, held as editable drafts rather than
    /// `SnippetVariable` directly — see `VariableDraft`'s own doc comment for
    /// why.
    @State private var variableDrafts: [VariableDraft]
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
        _variableDrafts = State(
            initialValue: (existing?.variables ?? []).map(VariableDraft.init(variable:)))
    }

    private var isEditing: Bool { existing != nil }

    /// The declarations `variableDrafts` currently resolves to — recomputed
    /// from the drafts on every access rather than cached, the same "no
    /// separate staleness question" reasoning `tagSuggestions` already
    /// documents for its own per-keystroke rebuild.
    private var variables: [SnippetVariable] { variableDrafts.map(\.variable) }

    /// What the editor shows below Tags: the command as it would actually
    /// be sent, with a stand-in for every declared value.
    ///
    /// It calls the same `SnippetVariableSubstitution.resolve` the run path
    /// calls — deliberately, not a second renderer that could agree with it
    /// today and drift tomorrow. So the preview also shows what the run
    /// path does with things the template alone does not reveal: an
    /// `.environment` variable appearing as a prepended assignment rather
    /// than in place, a value being single-quoted, and a `{{NAME}}` that
    /// matches no declaration staying in the text as inert literal
    /// characters.
    private var commandPreview: String {
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: two drafts
        // may share a name while the user is still typing, and that is a
        // validation error to report, not a reason to trap.
        let sample = Dictionary(
            variables.map { ($0.name, previewValue(for: $0)) },
            uniquingKeysWith: { first, _ in first })
        return SnippetVariableSubstitution.resolve(
            command: command, variables: variables, values: sample)
    }

    /// The stand-in for one variable: its default, else the first option of
    /// a choice, else a neutral word — the point is that the preview reads
    /// like a finished command, not that the value is meaningful.
    private func previewValue(for variable: SnippetVariable) -> String {
        if !variable.defaultValue.isEmpty { return variable.defaultValue }
        if case .selection(let options) = variable.kind, let first = options.first {
            return first
        }
        return L10n.string("snippets.editor.preview.sample", "sample")
    }

    /// What is wrong with the current variable declarations, or `nil`. Both
    /// checks named in the brief: an invalid or duplicate name is caught
    /// here directly, and `SnippetVariableSubstitution
    /// .firstDeclarationProblem` catches the command-side mistakes (an
    /// unused placeholder, one sitting inside quotes, a command whose
    /// quoting it cannot analyse at all). An empty `variableDrafts`
    /// short-circuits every check below to `nil`, matching a snippet with no
    /// variables at all.
    ///
    /// The name loop below is not the only enforcement of
    /// `SnippetVariable.isValidName` any more: `firstDeclarationProblem`
    /// checks it too, and `SnippetVariableSubstitution.resolve` skips a
    /// declaration that fails it, because import can carry a declaration in
    /// from a file without it ever passing this field. The loop stays
    /// because it is the only one of the three that can say WHICH field the
    /// user has to fix while they are typing in it.
    private var variablesError: String? {
        for draft in variableDrafts {
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !SnippetVariable.isValidName(trimmedName) {
                return L10n.string(
                    "snippets.variables.error.invalidName",
                    "A variable name must start with a letter or underscore and may contain only letters, digits and underscores.")
            }
        }
        let trimmedNames = variableDrafts.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Set(trimmedNames).count != trimmedNames.count {
            return L10n.string(
                "snippets.variables.error.duplicateName", "Two variables share a name.")
        }
        guard
            let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: variables)
        else { return nil }
        return snippetVariableProblemText(for: problem)
    }

    /// Only the required-fields check plus the two `variablesError` can
    /// raise (Task 5). `command` may contain a newline by the time this is
    /// evaluated — both a pasted multi-line string and a typed Return reach
    /// `SnippetCommandEditor`'s bound `command` as one — but nothing here
    /// needs to reject that; `Snippet`'s initializer accepts it too.
    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || variablesError != nil
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
                // Snippet editor part 1: an NSTextView, because a SwiftUI
                // TextField cannot colour text while it is being typed. The
                // command may now span lines (snippet editor, part 2); a
                // typed Return inserts one, the same as a pasted multi-line
                // string -- see `SnippetCommandEditor`'s own doc comment.
                // `accessibilityLabel` hands it the same localized string
                // this row's own (VoiceOver-hidden) label uses, so the field keeps an
                // accessible name of its own (`FormRow`'s doc comment, M6a).
                // The chrome lives here, not in the representable: it has
                // to match the `.roundedBorder` fields above and below,
                // and an `NSScrollView` cannot draw a rounded border.
                SnippetCommandEditor(text: $command, accessibilityLabel: commandLabel)
                    .frame(height: SnippetCommandEditor.intrinsicHeight(for: command))
                    // `FormRow` aligns on `.firstTextBaseline`, and SwiftUI
                    // cannot read one out of an `NSViewRepresentable` -- the
                    // label ended up about a line and a half above the field
                    // it names. The editor knows where its first baseline
                    // sits; this hands that number to the row.
                    .alignmentGuide(.firstTextBaseline) { _ in
                        SnippetCommandEditor.firstBaselineOffset
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(DesignTokens.hairline, lineWidth: 1))
            }

            variablesSection

            FormRow(label: L10n.string("snippets.tags.label", "Tags")) {
                SnippetTagField(tags: $tags, suggestions: tagSuggestions)
            }

            if !command.isEmpty {
                FormRow(label: L10n.string("snippets.editor.preview", "Preview")) {
                    Text(commandPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesignTokens.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) { save() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
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
        let snippet = Snippet(
            id: existing?.id ?? UUID(), name: trimmedName, command: command,
            tags: tags, variables: variables)
        do {
            try store.save(snippet)
            onSaved()
            dismiss()
        } catch {
            errorMessage = L10n.string("snippets.editor.error.save", "Couldn't save the snippet.")
        }
    }

    // MARK: - Variables (Task 5)

    /// The variables section: one card per declaration (`variableRow`), an
    /// add button, the hint text the brief requires (a value becomes a
    /// single shell word; an environment variable outlives a multi-line
    /// run), and — whenever `variablesError` is non-nil — the reason Save is
    /// disabled. That last text is the point of this whole block: a greyed-
    /// out Save button alone does not say WHY, and a user who cannot tell
    /// why does not experiment, they give up (brief, Step 2).
    @ViewBuilder
    private var variablesSection: some View {
        // Deliberately NOT a `FormRow`: a variable row carries six controls
        // of its own, so this block keeps the sheet's full width instead of
        // the 300pt that would be left beside a label column (maintainer's
        // visual check, 2026-08-21).
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("snippets.variables.title", "Variables"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Spacer()
                Button {
                    variableDrafts.append(VariableDraft())
                } label: {
                    Label(
                        L10n.string("snippets.variables.add", "Add variable"),
                        systemImage: "plus")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DesignTokens.inkSecondary)
            }

            ForEach($variableDrafts) { draft in
                variableRow(draft) {
                    variableDrafts.removeAll { $0.id == draft.wrappedValue.id }
                }
            }

            // `fixedSize` vertically: without it this row proposes an
            // unbounded width, the sentence lays out on one line and the
            // sheet's fixed width truncates it mid-word.
            Text(L10n.string(
                "snippets.variables.hint",
                "A value is inserted as a single shell word. An environment variable is exported ahead of the command and stays set in the session after the run."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let variablesError {
                Text(variablesError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    /// One declaration's card: name + kind + remove on the first line,
    /// prompt on its own line, the allowed-values field only for `.selection`
    /// (comma-separated — this row has no nested list editor of its own),
    /// placement + default value together, then the remember checkbox.
    /// Chrome matches `SnippetCommandEditor`'s card (`DesignTokens.card` +
    /// hairline border) so the two multi-field blocks in this sheet read as
    /// the same kind of thing.
    @ViewBuilder
    private func variableRow(
        _ draft: Binding<VariableDraft>, onRemove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(
                    L10n.string("snippets.variables.name", "Name"), text: draft.name,
                    prompt: Text(L10n.string("snippets.variables.name", "Name")))
                Picker("", selection: draft.isSelection) {
                    Text(L10n.string("snippets.variables.kind.freeText", "Free text")).tag(false)
                    Text(L10n.string("snippets.variables.kind.selection", "Choice")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                // Reuses the app's one generic "Remove" word
                // (`SettingsView`'s file-association rows use the very same
                // key for the very same minus-circle affordance) rather than
                // adding a near-duplicate string for one more icon-only
                // button.
                .accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))
                .help(L10n.string("settings.openWith.rules.remove", "Remove"))
            }

            TextField(
                L10n.string("snippets.variables.prompt", "Prompt"), text: draft.prompt,
                prompt: Text(L10n.string("snippets.variables.prompt", "Prompt")))

            if draft.wrappedValue.isSelection {
                TextField(
                    "", text: draft.selectionValuesText,
                    prompt: Text(verbatim: "a, b, c"))
            }

            HStack(spacing: 8) {
                Picker("", selection: draft.placement) {
                    Text(L10n.string(
                        "snippets.variables.placement.placeholder", "Placeholder in the command"))
                        .tag(SnippetVariable.Placement.placeholder)
                    Text(L10n.string(
                        "snippets.variables.placement.environment", "Environment variable"))
                        .tag(SnippetVariable.Placement.environment)
                }
                .labelsHidden()
                TextField(
                    L10n.string("snippets.variables.default", "Default"), text: draft.defaultValue,
                    prompt: Text(L10n.string("snippets.variables.default", "Default")))
            }

            Toggle(
                L10n.string("snippets.variables.remember", "Remember last value"),
                isOn: draft.remembersLastValue)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.card))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.hairline, lineWidth: 1))
    }
}

/// One variable declaration while it is being edited (Task 5).
///
/// `SnippetVariable`'s own stored properties are `let` — deliberately, so
/// nothing later in the app can mutate a declaration in place — which means
/// SwiftUI's controls cannot bind straight into one. This draft is the
/// mutable stand-in: `variableRow` binds its fields, and `variable` converts
/// back to the immutable type the store and `Snippet` actually hold.
///
/// Carries its own `id`, separate from `name`, so `ForEach` keeps a stable
/// identity for a row even while two drafts temporarily share a name — the
/// exact state `variablesError`'s duplicate-name check exists to let the
/// user be in while they fix it. Using `name` itself as the `ForEach` id
/// would instead make SwiftUI's identity collide at the same moment the
/// error text appears.
private struct VariableDraft: Identifiable {
    let id = UUID()
    var name = ""
    var prompt = ""
    /// Whether this draft is `.selection` rather than `.freeText` — kept as
    /// a separate flag instead of switching on `SnippetVariable.Kind`
    /// directly, because `selectionValuesText` needs somewhere to live even
    /// while `.freeText` is selected (the user may flip back and forth
    /// without losing what they typed).
    var isSelection = false
    /// The allowed values for `.selection`, as one comma-separated field —
    /// this row has no per-option list editor of its own. Split, trimmed and
    /// emptied entries dropped in `variable`.
    var selectionValuesText = ""
    var placement: SnippetVariable.Placement = .placeholder
    var defaultValue = ""
    var remembersLastValue = false

    init() {}

    init(variable: SnippetVariable) {
        name = variable.name
        prompt = variable.prompt
        placement = variable.placement
        defaultValue = variable.defaultValue
        remembersLastValue = variable.remembersLastValue
        switch variable.kind {
        case .freeText:
            isSelection = false
        case .selection(let options):
            isSelection = true
            selectionValuesText = options.joined(separator: ", ")
        }
    }

    /// The declaration this draft resolves to — built fresh from the current
    /// field values, not cached, the same reasoning `SnippetEditorView
    /// .variables` documents for its own rebuild-on-access. `name`/`prompt`
    /// are trimmed here so a save cannot carry leading/trailing whitespace
    /// that `SnippetVariable.isValidName` would have rejected outright had
    /// it been part of `name` itself.
    var variable: SnippetVariable {
        let kind: SnippetVariable.Kind
        if isSelection {
            let options = selectionValuesText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            kind = .selection(options)
        } else {
            kind = .freeText
        }
        return SnippetVariable(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind, placement: placement, defaultValue: defaultValue,
            remembersLastValue: remembersLastValue)
    }
}
