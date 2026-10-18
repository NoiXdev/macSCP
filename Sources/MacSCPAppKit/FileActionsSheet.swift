import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// File action management sheet: lists every stored `FileAction` in store
/// order — the order the context menu offers them in — with New, Edit,
/// Duplicate and Remove, and Export and Import under the three-dot menu.
///
/// The shape is `SnippetsSheet`'s: no view-model layer, the store is read and
/// written directly, a single selection, a fixed frame, and the footer's
/// `SheetOverflowMenu`. What differs is what a stored value MEANS. A snippet
/// is typed by the user; an action's command is filled in with file names
/// that come from a server, so everything that can reach the store passes
/// `FileActionTemplate.firstProblem` first — the editor before Save, and
/// `FileActionAuthoring.review` before an import.
///
/// **Names are untrusted text here.** An action can be imported from a file,
/// and a name carrying a bidirectional override or a line break would
/// mislabel the row. Every name and command shown is drawn through
/// `FileActionPlanDisplay`, which marks such a scalar instead of passing it
/// to a `Text`.
///
/// Presented from the Terminal menu, next to "Manage Snippets…". View code
/// with no test that draws it; `FileActionEditorWiringGuardTests` holds the
/// wiring, and `FileActionAuthoringTests` the import review.
struct FileActionsSheet: BoundedView {
    /// The size `FileActionsSheet` bounds itself to, applied with `.sheetBound(Self.bound)`.
    static let bound: SheetBound = .size(width: 640, height: 440)

    let store: FileActionStore

    @Environment(\.dismiss) private var dismiss

    @State private var load: FileActionsLoad = .loaded([])
    @State private var selectedID: FileAction.ID?
    @State private var editorTarget: FileActionEditorTarget?
    @State private var isShowingRemoveConfirm = false
    @State private var errorMessage: String?

    @State private var exportDocument: FileActionExportDocument?
    @State private var showExportFileExporter = false
    @State private var showImportFileImporter = false
    @State private var importResultMessage = ""
    @State private var showImportResultAlert = false

    /// Wraps "new" (no existing action) or "edit" (a specific one) so
    /// `.sheet(item:)` has a stable identity even for the "new" case.
    private struct FileActionEditorTarget: Identifiable {
        let id = UUID()
        let existing: FileAction?
    }

    private var actions: [FileAction] { load.actions }

    private var selectedAction: FileAction? {
        actions.first { $0.id == selectedID }
    }

    /// A store that cannot be read wins over an action error: it explains why
    /// the list is empty, and every action against such a store fails for
    /// that same reason.
    private var displayedError: String? {
        if load.isUnreadable {
            return L10n.string(
                "fileAction.sheet.load.error",
                "The file actions file couldn't be read. It exists but can't be decoded — no action was lost, and nothing will be written over it.")
        }
        return errorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("fileAction.sheet.title", "File Actions")).font(.headline)

            Text(L10n.string(
                "fileAction.sheet.intro",
                "Your own commands, offered in the file menu. Each one runs on the files you select."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let displayedError {
                Text(displayedError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            if actions.isEmpty {
                Spacer(minLength: 0)
                // Only an actually-read store may be called empty.
                if !load.isUnreadable {
                    Text(L10n.string("fileAction.sheet.empty", "No file actions yet."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Spacer(minLength: 0)
            } else {
                List(actions, selection: $selectedID) { action in
                    row(action)
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("fileAction.sheet.new", "New…")) {
                    editorTarget = FileActionEditorTarget(existing: nil)
                }
                .buttonStyle(.polished)
                Button(L10n.string("fileAction.sheet.edit", "Edit…")) {
                    if let selectedAction {
                        editorTarget = FileActionEditorTarget(existing: selectedAction)
                    }
                }
                .buttonStyle(.polished)
                .disabled(selectedAction == nil)
                Button(L10n.string("fileAction.sheet.duplicate", "Duplicate")) {
                    if let selectedAction { duplicate(selectedAction) }
                }
                .buttonStyle(.polished)
                .disabled(selectedAction == nil)
                Button(L10n.string("fileAction.sheet.remove", "Remove…"), role: .destructive) {
                    isShowingRemoveConfirm = true
                }
                .buttonStyle(.polished)
                .disabled(selectedAction == nil)
                SheetOverflowMenu(
                    actions: SheetOverflowAction.offered(
                        canExport: !actions.isEmpty && !load.isUnreadable, canImport: true)
                ) { action in
                    switch action {
                    case .export:
                        performExport(
                            ListExportScope.resolve(selectedID: selectedID, from: actions))
                    case .import:
                        showImportFileImporter = true
                    }
                }
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .sheetBound(Self.bound)
        .onAppear { reload() }
        .sheet(item: $editorTarget) { target in
            FileActionEditor(existing: target.existing, store: store, onSaved: { reload() })
        }
        .confirmationDialog(
            L10n.string("fileAction.sheet.remove.title", "Remove this action?"),
            isPresented: $isShowingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("fileAction.sheet.remove.confirm", "Remove"), role: .destructive) {
                performRemove()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
        .fileExporter(
            isPresented: $showExportFileExporter,
            document: exportDocument,
            contentType: .macscpFileActions,
            // Not localized, like the snippet and login exports: the trailing
            // extension is what ties the file to this app.
            defaultFilename: "macSCP File Actions.macscpactions"
        ) { result in
            handleExportResult(result)
        }
        .fileImporter(
            isPresented: $showImportFileImporter,
            allowedContentTypes: [.macscpFileActions, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportFileSelection(result)
        }
        .alert(
            L10n.string("import.result.title", "Import Complete"),
            isPresented: $showImportResultAlert
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importResultMessage)
        }
    }

    private func reload() { load = FileActionsLoad(reading: store) }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ action: FileAction) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FileActionPlanDisplay.attributed(FileActionPlanDisplay.runs(of: action.name)))
                    .font(.system(size: 13))
                    .lineLimit(1)
                let summary = SnippetCommandSummary.firstLine(of: action.command)
                HStack(spacing: 4) {
                    Text(FileActionPlanDisplay.attributed(
                        FileActionPlanDisplay.runs(of: summary.text)))
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
                // A stored action the gate refuses is never offered in a
                // menu. It can only be a hand-edited file, so the list says
                // so instead of leaving the user to wonder.
                if let problem = FileActionTemplate.firstProblem(in: action) {
                    Text(fileActionNotOfferedText(for: problem))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(fileActionSidesText(action.runsOn))
                .font(.caption)
                .foregroundStyle(DesignTokens.inkSecondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(L10n.string("fileAction.sheet.edit", "Edit…")) {
                selectedID = action.id
                editorTarget = FileActionEditorTarget(existing: action)
            }
            Button(L10n.string("fileAction.sheet.duplicate", "Duplicate")) {
                selectedID = action.id
                duplicate(action)
            }
            Button(L10n.string("sheets.export", "Export…")) {
                selectedID = action.id
                performExport([action])
            }
            Button(L10n.string("fileAction.sheet.remove", "Remove…"), role: .destructive) {
                selectedID = action.id
                isShowingRemoveConfirm = true
            }
        }
    }

    // MARK: - Remove and duplicate

    private var removeConfirmMessage: String {
        guard let selectedAction else { return "" }
        return String(
            format: L10n.string("delete.message.single", "“%@” will be deleted."),
            FileActionPlanDisplay.visible(selectedAction.name))
    }

    private func performRemove() {
        guard let selectedAction else { return }
        do {
            try store.remove(id: selectedAction.id)
            errorMessage = nil
        } catch {
            errorMessage = L10n.string(
                "fileAction.sheet.error.remove", "Couldn't remove the action.")
        }
        selectedID = nil
        reload()
    }

    /// A copy under a new identity, named after the original. Saved as it
    /// stands: a copy has exactly the original's problems, so it is no new
    /// way into the store — a stored action the gate refuses stays refused,
    /// and the row says so.
    private func duplicate(_ action: FileAction) {
        let copy = FileAction(
            name: String(
                format: L10n.string("fileAction.sheet.copyName", "%@ copy"), action.name),
            command: action.command, variables: action.variables, runsOn: action.runsOn,
            perSelection: action.perSelection)
        do {
            try store.save(copy)
            errorMessage = nil
            selectedID = copy.id
        } catch {
            errorMessage = L10n.string(
                "fileAction.editor.error.save", "Couldn't save the action.")
        }
        reload()
    }

    // MARK: - Export

    /// Encodes exactly the actions handed in. The export type has no field
    /// the store does not, and no snippet can be in it: the codec is the
    /// actions one.
    private func performExport(_ actions: [FileAction]) {
        do {
            let data = try FileActionExportCodec.encode(
                FileActionExportPayload(actions: actions.map(ExportedFileAction.init)))
            exportDocument = FileActionExportDocument(data: data)
            errorMessage = nil
            showExportFileExporter = true
        } catch {
            errorMessage = String(format: L10n.string(
                "export.error.encodeFailed %@", "Could not prepare the export: %@"),
                String(describing: error))
        }
    }

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

    // MARK: - Import

    /// `fileImporter` completion. Reads the chosen file with security-scoped
    /// access, then `probe`s before it `decode`s.
    ///
    /// **`probe` answers whether the file is ENCRYPTED and THROWS for a file
    /// of another kind**, so a snippets or sessions export arrives here as a
    /// thrown `.notAnExportFile`, which is the "not an actions file" case; it
    /// is not a `Bool` to read. Its answer is ignored: this format has no
    /// password, and a file claiming encryption makes `decode` throw
    /// `.passwordRequired`, which maps to the same generic refusal.
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
                _ = try FileActionExportCodec.probe(data)
                let payload = try FileActionExportCodec.decode(data)
                errorMessage = nil
                applyImport(payload)
            } catch let error as SessionExportError {
                errorMessage = fileActionImportErrorText(for: error)
            } catch {
                errorMessage = ImportFeedbackText.readErrorMessage(error)
            }
        }
    }

    /// Reviews the payload against the gate and stores what passed. The codec
    /// does not validate, so this is the only thing between an imported
    /// action and the store: nothing reaches `store.save` that
    /// `FileActionAuthoring.review` did not accept, and what it refused is
    /// told to the user by name and reason.
    private func applyImport(_ payload: FileActionExportPayload) {
        let review = FileActionAuthoring.review(payload, existing: actions)
        var storeFailures = 0
        for action in review.accepted {
            do {
                try store.save(action)
            } catch {
                storeFailures += 1
            }
        }
        reload()
        selectedID = nil
        importResultMessage = fileActionImportResultText(
            review: review, storeFailures: storeFailures)
        showImportResultAlert = true
    }
}
