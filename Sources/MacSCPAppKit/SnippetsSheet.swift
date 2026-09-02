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
    /// What was remembered for one declaration of one snippet, or `nil`.
    ///
    /// A READ, and the editor's whole access to the remembered values: the
    /// "Test" button (Snippet-Probelauf, Task 4) opens the same prompt the
    /// trigger path opens, seeded the same way, and a closure that returns
    /// a value has no way to store one — so a rehearsal cannot pre-fill the
    /// next real run. `SnippetDryRunEntranceGuardTests
    /// .theEditorsRehearsalRemembersNothing` holds the other half of that:
    /// nothing in this file reaches `remember`.
    let rememberedValue: (Snippet.ID, String) -> String?

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
                // Export and Import act on a file on disk, so they sit under
                // the three-dot menu, while New/Edit/Delete above act on the
                // list selection and stay visible (backlog 2026-08-20,
                // point 5) — the same move `LoginSetsSheet` and `SSHKeysSheet`
                // already made. Delete… would fit under the menu just as well
                // and deliberately does not go there: it is destructive.
                //
                // The single-snippet export in the row's `.contextMenu` stays
                // where it is: it is not the footer's action, it always means
                // the right-clicked row, and it exports unconfirmed.
                //
                // Enablement is `snippetsCanExport`
                // (`SnippetsPresentation.swift`), which also rules out an
                // unreadable store explicitly rather than leaning on
                // `visibleSnippets` happening to be empty in that case too.
                // It now decides whether the entry EXISTS rather than
                // whether it is greyed out, which is what replaces the
                // disabled state the footer button carried before. Spelled as
                // prose deliberately: writing that modifier out here would
                // hand the source-text guards in this target a second copy of
                // an anchor they scan for.
                SheetOverflowMenu(
                    actions: SheetOverflowAction.offered(
                        canExport: snippetsCanExport(
                            load: load, visibleSnippets: visibleSnippets),
                        canImport: true)
                ) { action in
                    switch action {
                    case .export:
                        // Arms the export confirmation with the resolved
                        // scope — the selection when it is one of the rows on
                        // screen, otherwise every row on screen, per
                        // `ListExportScope`. `snippetsCanExport` already ruled
                        // out an empty visible list, so the resolved scope
                        // always has at least one snippet in it.
                        pendingExport = ListExportScope.resolve(
                            selectedID: selectedID, from: visibleSnippets)
                    case .import:
                        showImportFileImporter = true
                    }
                }
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
                rememberedValue: rememberedValue, onSaved: { reload() })
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

    /// Builds the payload from exactly the snippets handed in, mapping each
    /// stored `Snippet` to the export's own `ExportedSnippet` — this
    /// function does no filtering of its own. Two callers reach it: the
    /// export confirmation's own button, passing the resolved scope held in
    /// `pendingExport`, and the row menu, passing exactly the one
    /// right-clicked snippet. Encodes the payload and arms `fileExporter`.
    /// Mirrors `LoginSetsSheet.performExport`, minus the options/password
    /// step that codec has no parameter for (see `SnippetExportCodec`'s own
    /// doc comment on why).
    private func performExport(_ snippets: [Snippet]) {
        do {
            let data = try SnippetExportCodec.encode(
                SnippetExportPayload(snippets: snippets.map(ExportedSnippet.init)))
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
    /// Passed straight down from `SnippetsSheet` — see its own doc comment
    /// for why the editor holds a read and nothing else.
    let rememberedValue: (Snippet.ID, String) -> String?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var tags: [String]
    /// Variable declarations, held as editable drafts rather than
    /// `SnippetVariable` directly — see `VariableDraft`'s own doc comment for
    /// why.
    @State private var variableDrafts: [VariableDraft]
    /// Which declaration rows are drawn open. Starts empty — every
    /// declaration this editor loaded opens closed — and is never read from
    /// or written to anything outside this view: the design rules out a
    /// remembered fold state in any form.
    @State private var folding = SnippetVariableFolding()
    /// `Snippet.skipsPlaceholderPlacementCheck` while it is being edited.
    /// A plain `Bool` rather than a draft type: unlike a declaration it has
    /// no half-typed intermediate state a checkbox could be in.
    @State private var skipsPlacementCheck: Bool
    @State private var errorMessage: String?

    /// One dry run of the draft, waiting to be shown. Non-nil only between
    /// the "Test" button (or the value prompt it opens) and the dry-run
    /// sheet's own dismissal.
    @State private var pendingTestRun: PendingTestRun?
    /// The values prompt for a test run — `SnippetVariablePromptSheet`, the
    /// same one the trigger path opens.
    @State private var pendingTestValues: PendingTestValues?

    /// The id the draft is saved under: `existing`'s, or one made once when
    /// this editor opened. Fixed at init rather than computed, because both
    /// `draftSnippet` readers would otherwise get a different new snippet
    /// each time they looked.
    private let draftID: UUID

    private struct PendingTestValues: Identifiable {
        let id = UUID()
        let snippet: Snippet
        let initialValues: [String: String]
    }

    private struct PendingTestRun: Identifiable {
        let id = UUID()
        let snippetName: String
        let dryRun: SnippetDryRun
    }

    init(
        existing: Snippet?, allSnippets: [Snippet], store: SnippetStore,
        rememberedValue: @escaping (Snippet.ID, String) -> String?,
        onSaved: @escaping () -> Void
    ) {
        self.existing = existing
        self.allSnippets = allSnippets
        self.store = store
        self.rememberedValue = rememberedValue
        self.onSaved = onSaved
        self.draftID = existing?.id ?? UUID()
        _name = State(initialValue: existing?.name ?? "")
        _command = State(initialValue: existing?.command ?? "")
        _tags = State(initialValue: existing?.tags ?? [])
        _variableDrafts = State(
            initialValue: (existing?.variables ?? []).map(VariableDraft.init(variable:)))
        _skipsPlacementCheck = State(
            initialValue: existing?.skipsPlaceholderPlacementCheck ?? false)
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

    /// What is wrong with the current variable declarations, or `nil` —
    /// the sentence to show, and which rows it is about.
    ///
    /// The checks themselves live in `snippetVariablesFault`, which is
    /// where they can be tested without a view: an invalid or duplicate
    /// name, and the command-side mistakes
    /// `SnippetVariableSubstitution.firstDeclarationProblem` catches (an
    /// unused placeholder, one sitting inside quotes, a command whose
    /// quoting it cannot analyse at all). An empty `variableDrafts` yields
    /// `nil`, matching a snippet with no variables at all.
    ///
    /// The names handed over are `VariableDraft.variable`'s, already
    /// trimmed there, so what blocks Save is what a save would write.
    ///
    /// `skipsPlacementCheck` travels with them so the checkbox below the
    /// variables actually unblocks Save. It removes ONE of
    /// `firstDeclarationProblem`'s questions — where a `{{NAME}}` sits —
    /// and neither of the two name checks: an invalid or duplicate name
    /// still blocks Save with the waiver ticked, as does a declaration
    /// whose placeholder appears nowhere in the command.
    private var variablesFault: SnippetVariablesFault? {
        snippetVariablesFault(
            command: command, variables: variables,
            skipsPlacementCheck: skipsPlacementCheck)
    }

    /// What the editor says about a `{{NAME}}` in the command that no
    /// declaration carries, or `nil`.
    ///
    /// Separate from `variablesFault` on purpose, and it does not reach
    /// `isSaveDisabled`: `SnippetVariableSubstitution` decides what may be
    /// sent, and an undeclared placeholder was sendable before this line
    /// existed and stays sendable — it goes to the shell as the literal
    /// characters it is. The user is told because the command then does
    /// something other than what its author believes, and nothing said so.
    private var undeclaredPlaceholderHint: String? {
        snippetUndeclaredPlaceholderHint(command: command, variables: variables)
    }

    /// What the editor says about a `{{NAME}}` that IS declared, but as an
    /// environment variable, or `nil`.
    ///
    /// The sibling of `undeclaredPlaceholderHint`, not a reworded version of
    /// it: an environment declaration IS a declaration, so calling it
    /// undeclared would be wrong in a different way than for a name nothing
    /// declares. Same reason it stays out of `isSaveDisabled` too —
    /// `SnippetVariableSubstitution` decides what may be sent and none of
    /// that changed here either.
    private var environmentPlaceholderHint: String? {
        snippetEnvironmentPlaceholderHint(command: command, variables: variables)
    }

    /// The rows the variables section draws, each carrying whether the
    /// current fault is about it — the input the fold rule reads.
    ///
    /// Built by walking the drafts and asking the fault about each
    /// position, rather than by subscripting the drafts with the fault's
    /// offsets: `variables` is `variableDrafts.map(\.variable)`, so the two
    /// are aligned by construction, and this direction stays total even if
    /// that ever stopped being true.
    private var foldRows: [SnippetVariableFoldRow] {
        let fault = variablesFault
        return zip(variableDrafts.indices, variableDrafts).map { index, draft in
            SnippetVariableFoldRow(
                id: draft.id, hasProblem: fault?.declarations.contains(index) ?? false)
        }
    }

    /// Only the required-fields check plus whatever `variablesFault`
    /// reports (Task 5). `command` may contain a newline by the time this is
    /// evaluated — both a pasted multi-line string and a typed Return reach
    /// `SnippetCommandEditor`'s bound `command` as one — but nothing here
    /// needs to reject that; `Snippet`'s initializer accepts it too.
    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || variablesFault != nil
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
                // `variables:` is what the completion list on the opening
                // braces is built from (part 2 of the editor's operation)
                // -- handed over whole, so the one rule about what belongs
                // in a command as `{{NAME}}` is applied in one place for
                // both entrances.
                SnippetCommandEditor(
                    text: $command, accessibilityLabel: commandLabel, variables: variables)
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
                // Absent rather than disabled while there is no command to
                // rehearse: a greyed-out control asks the reader to work
                // out why, and the empty Command field above already says
                // it. Not tied to `isSaveDisabled` either — a draft whose
                // declarations are refused is exactly the one worth
                // testing, and its dry run is what explains the refusal.
                if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(L10n.string("snippets.editor.test", "Test")) { startTestRun() }
                        .buttonStyle(.polished)
                }
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
        // The values for a test run, asked with the trigger path's own
        // prompt. Confirming reaches `testRun` and NOTHING else: no
        // `rememberOptedInValues`, no store, no send — see this view's
        // `rememberedValue` for why that is structural rather than a rule
        // somebody has to keep.
        .sheet(item: $pendingTestValues) { prompt in
            SnippetVariablePromptSheet(
                snippet: prompt.snippet, initialValues: prompt.initialValues,
                onConfirm: { values in
                    pendingTestValues = nil
                    pendingTestRun = testRun(of: prompt.snippet, values: values)
                },
                onCancel: { pendingTestValues = nil }
            )
        }
        // No "Send anyway" here: there is no shell attached to an editor,
        // so the button is not drawn at all rather than drawn and disabled.
        .sheet(item: $pendingTestRun) { run in
            SnippetDryRunSheet(
                snippetName: run.snippetName, dryRun: run.dryRun, onSendAnyway: nil,
                onClose: { pendingTestRun = nil })
        }
    }

    /// Built from `allSnippets`/`tags` on every call rather than cached —
    /// `SnippetTagField` calls this fresh on every keystroke anyway (see its
    /// doc comment), so there is no separate "is this stale" question to
    /// answer.
    private func tagSuggestions(for query: String) -> [(tag: String, count: Int)] {
        SnippetTagSuggestions.matching(query, in: allSnippets, excluding: tags)
    }

    /// The snippet as the fields currently stand: what Save would write,
    /// and what the "Test" button rehearses.
    ///
    /// One construction for both. A rehearsal built from its own reading of
    /// the fields could differ from the snippet that gets saved — most
    /// easily in `skipsPlaceholderPlacementCheck`, where the difference is
    /// exactly whether the dry run is refused.
    private var draftSnippet: Snippet {
        Snippet(
            id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command, tags: tags, variables: variables,
            skipsPlaceholderPlacementCheck: skipsPlacementCheck)
    }

    /// Shows what the draft would send, and sends nothing.
    ///
    /// A draft with declarations goes through `SnippetVariablePromptSheet`
    /// first — the SAME prompt the trigger path opens, seeded from the same
    /// remembered values (`snippetVariablePromptValues`). A second prompt
    /// shape would be a second truth about what a value is.
    ///
    /// `execute: true` and `bracketedPaste: false` are not guesses about a
    /// remote: this editor is not attached to one. An execution is the form
    /// the planner never refuses, so the rehearsal describes what the
    /// snippet IS rather than reporting a refusal that belongs to a
    /// connection nobody has opened yet.
    private func startTestRun() {
        let snippet = draftSnippet
        guard snippet.variables.isEmpty else {
            pendingTestValues = PendingTestValues(
                snippet: snippet,
                initialValues: snippetVariablePromptValues(for: snippet) {
                    rememberedValue(snippet.id, $0)
                })
            return
        }
        pendingTestRun = testRun(of: snippet, values: [:])
    }

    private func testRun(of snippet: Snippet, values: [String: String]) -> PendingTestRun {
        PendingTestRun(
            snippetName: snippet.name,
            dryRun: SnippetDryRun.describing(
                snippet, values: values, execute: true, bracketedPaste: false))
    }

    private func save() {
        do {
            try store.save(draftSnippet)
            onSaved()
            dismiss()
        } catch {
            errorMessage = L10n.string("snippets.editor.error.save", "Couldn't save the snippet.")
        }
    }

    // MARK: - Variables (Task 5)

    /// The variables section: one card per declaration (`variableRow`), the
    /// two bulk fold actions beside the add button, the hint text the brief
    /// requires (a value becomes a single shell word; an environment
    /// variable outlives a multi-line run), the hint about a `{{NAME}}` in
    /// the command that no declaration carries (a display, which blocks
    /// nothing), and — whenever `variablesFault` is non-nil — the reason
    /// Save is disabled. That last text is the point
    /// of this whole block: a greyed-out Save button alone does not say WHY,
    /// and a user who cannot tell why does not experiment, they give up
    /// (brief, Step 2).
    ///
    /// "Expand all" and "collapse all" appear only when they would do
    /// something — absent, not disabled, which is what
    /// `SnippetVariableFolding.offersExpandAll`/`offersCollapseAll` decide.
    @ViewBuilder
    private var variablesSection: some View {
        // Deliberately NOT a `FormRow`: an open variable row carries nine
        // controls of its own — fold, name, kind, insert, remove, prompt,
        // placement, default, remember — and a tenth while a choice lists
        // its values, so this block keeps the sheet's full width instead of
        // the 300pt that would be left beside a label column (maintainer's
        // visual check, 2026-08-21).
        //
        // Read once, per body evaluation, and handed to both the bulk
        // buttons and every row: each read runs the declaration checks, so
        // one read is also one answer to "which row is at fault".
        let rows = foldRows
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("snippets.variables.title", "Variables"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Spacer()
                // Both carry the chevron their per-row control uses, so
                // the bulk action and the single one read as the same verb.
                if folding.offersExpandAll(rows) {
                    Button {
                        folding.expandAll(rows)
                    } label: {
                        Label(
                            L10n.string("snippets.variables.expandAll", "Expand all"),
                            systemImage: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .help(L10n.string(
                        "snippets.variables.expandAll.hint", "Opens every variable."))
                }
                if folding.offersCollapseAll(rows) {
                    Button {
                        folding.collapseAll(rows)
                    } label: {
                        Label(
                            L10n.string("snippets.variables.collapseAll", "Collapse all"),
                            systemImage: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    // Says the part the label cannot: the ones with a
                    // problem stay open, which is what makes this button
                    // double as "show me only the problems".
                    .help(L10n.string(
                        "snippets.variables.collapseAll.hint",
                        "Closes every variable, except any with a problem."))
                }
                Button {
                    // Opened as it is created: a row nobody can type into
                    // is not a row. It is unnamed and therefore faulty at
                    // this instant anyway — what this call buys is the
                    // keystroke AFTER the name becomes valid, when the row
                    // would otherwise shut under the cursor.
                    let added = VariableDraft()
                    variableDrafts.append(added)
                    folding.open(added.id)
                } label: {
                    Label(
                        L10n.string("snippets.variables.add", "Add variable"),
                        systemImage: "plus")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DesignTokens.inkSecondary)
            }

            // `rows` is built from `variableDrafts` in order, so zipping the
            // two pairs each row with its own draft; the identity stays the
            // draft's own `id`, for the reason `VariableDraft` documents.
            ForEach(Array(zip(rows, $variableDrafts)), id: \.0.id) { entry in
                variableRow(entry.1, row: entry.0) {
                    variableDrafts.removeAll { $0.id == entry.0.id }
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

            // The per-snippet exit from the placement check. Its label
            // names what is switched off -- WHERE values may stand in this
            // command -- rather than saying "check off", which is a switch
            // whose effect is learned from the damage. The footnote below
            // it carries the two facts a label cannot: values are still
            // quoted, and the setting does not travel with an export.
            //
            // Never disabled. A snippet with no declarations yet is exactly
            // where somebody may want to tick this first, and a greyed-out
            // checkbox would explain neither itself nor when it would come
            // back.
            Toggle(
                L10n.string(
                    "snippets.editor.skipPlacementCheck",
                    "Don't check where values are placed in this command"),
                isOn: $skipsPlacementCheck)
                .toggleStyle(.checkbox)
                .font(.caption)
            Text(L10n.string(
                "snippets.editor.skipPlacementCheck.hint",
                """
                Only for this snippet, and it is not shared: an imported snippet always \
                arrives with the check on. Values are still quoted, but macSCP stops \
                requiring each one to stand as a plain, unquoted argument — and where it \
                does not, quoting alone cannot keep a value from being read as shell code.
                """))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let variablesFault {
                Text(variablesFault.message).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            // Amber and not red, because it blocks nothing: the snippet
            // saves and sends exactly as before. The sentence exists
            // because what it describes is otherwise silent -- a `{{NAME}}`
            // nothing declares reaches the shell as the characters it is,
            // and the command then does something other than what its
            // author believes.
            //
            // `fixedSize` vertically for the reason the hint above it
            // documents: without it the sentence lays out on one line and
            // the sheet's fixed width truncates it mid-word.
            if let undeclaredPlaceholderHint {
                Text(undeclaredPlaceholderHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Same amber, same reasoning: this sentence blocks nothing
            // either. Two sentences rather than one merged string, so each
            // catalog entry stays a whole sentence and both may show at
            // once when a command carries one of each.
            if let environmentPlaceholderHint {
                Text(environmentPlaceholderHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One declaration's card, open or closed.
    ///
    /// Open: name + kind + insert + remove on the first line, prompt on its
    /// own line, the allowed-values field only for `.selection`
    /// (comma-separated — this row has no nested list editor of its own),
    /// placement + default value together, then the remember checkbox.
    ///
    /// Closed: one line — `snippetCollapsedVariableSummary` — beside the
    /// same fold, insert and remove controls. A declaration's six fields —
    /// name, kind, prompt, placement, default and remember — are more form
    /// than sheet at three declarations, and the width is not where the
    /// space is.
    ///
    /// The fold control is drawn only where folding is possible: a row with
    /// a problem stays open and offers nothing that would close it, so the
    /// reader is never asked to work out why a control is greyed out.
    ///
    /// Chrome matches `SnippetCommandEditor`'s card (`DesignTokens.card` +
    /// hairline border) so the two multi-field blocks in this sheet read as
    /// the same kind of thing.
    @ViewBuilder
    private func variableRow(
        _ draft: Binding<VariableDraft>, row: SnippetVariableFoldRow,
        onRemove: @escaping () -> Void
    ) -> some View {
        let isExpanded = folding.isExpanded(row)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if folding.canCollapse(row) {
                    let foldLabel = isExpanded
                        ? L10n.string("snippets.variables.collapse", "Collapse")
                        : L10n.string("snippets.variables.expand", "Expand")
                    Button {
                        folding.toggle(row)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(foldLabel)
                    .help(foldLabel)
                }
                if isExpanded {
                    TextField(
                        L10n.string("snippets.variables.name", "Name"), text: draft.name,
                        prompt: Text(L10n.string("snippets.variables.name", "Name")))
                    Picker("", selection: draft.isSelection) {
                        Text(L10n.string("snippets.variables.kind.freeText", "Free text"))
                            .tag(false)
                        Text(L10n.string("snippets.variables.kind.selection", "Choice")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                } else {
                    Text(snippetCollapsedVariableSummary(for: draft.wrappedValue.variable))
                        .font(.caption)
                        .foregroundStyle(DesignTokens.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The way into the command that does not need the name
                // typed -- for when it is no longer remembered. Drawn only
                // where it is possible: a declaration whose placement is
                // the environment does not belong in the command as
                // `{{NAME}}` at all, and one whose name is not a shell
                // identifier would put text there that nothing fills in.
                // Absent rather than greyed out, the same choice the fold
                // control and the "Test" button already make.
                if snippetBelongsInCommandAsPlaceholder(draft.wrappedValue.variable) {
                    let insertLabel = L10n.string(
                        "snippets.variables.insert", "Insert in command")
                    Button {
                        command = snippetCommandInsertingPlaceholder(
                            draft.wrappedValue.variable.name, into: command)
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(insertLabel)
                    .help(insertLabel)
                }
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

            if isExpanded {
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
                            "snippets.variables.placement.placeholder",
                            "Placeholder in the command"))
                            .tag(SnippetVariable.Placement.placeholder)
                        Text(L10n.string(
                            "snippets.variables.placement.environment", "Environment variable"))
                            .tag(SnippetVariable.Placement.environment)
                    }
                    .labelsHidden()
                    TextField(
                        L10n.string("snippets.variables.default", "Default"),
                        text: draft.defaultValue,
                        prompt: Text(L10n.string("snippets.variables.default", "Default")))
                }

                Toggle(
                    L10n.string("snippets.variables.remember", "Remember last value"),
                    isOn: draft.remembersLastValue)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
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
