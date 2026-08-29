import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// Login-sets management sheet (M10b/T3, mockup section 3): lists every
/// reusable login (`SessionListViewModel.loginSets`), with single-selection
/// New/Edit/Delete and a merge-suggestion banner on top when
/// `mergeCandidates()` finds manual sessions sharing the same effective
/// login. Shape mirrors `KnownHostsSheet` (M10a/T2) for consistency across
/// the app's management sheets — list + caption footer + destructive
/// `confirmationDialog` — but selection is single (`Edit…` only ever acts on
/// one set) rather than `KnownHostsSheet`'s multi-selection `Table`.
struct LoginSetsSheet: View {
    let sessionList: SessionListViewModel
    /// Opens the import file picker as soon as the sheet appears (M19/T8) —
    /// how the Sessions menu's "Import Logins…" reaches the import, which
    /// lives here and nowhere else.
    var startsImport = false

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: LoginSet.ID?
    @State private var searchText = ""
    @State private var searchIsRegex = false
    /// The backend quick filter (facet design, 2026-08-29). A view, not a
    /// setting: it starts cleared every time the sheet opens, so it can
    /// never name a backend no stored login uses any more.
    @State private var facet: SheetFacetFilter = .all
    /// The single merge suggestion currently shown, or `nil` when none are
    /// left. Recomputed explicitly (not a live computed property) so a
    /// banner action's own re-render doesn't recompute mid-transition —
    /// `refreshMergeCandidate()` is the sole place that reassigns it.
    @State private var mergeCandidate: LoginMergeCandidate?
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingMergeConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var editorTarget: LoginSetEditorTarget?

    // MARK: - Export/import state (M19/T8)

    @State private var exportTarget: ExportTarget?
    @State private var exportDocument: LoginSetExportDocument?
    @State private var showExportFileExporter = false
    /// Assembled by `performExport` from the payload builder's report (sets
    /// with no stored secret, keys that could not be read, keys travelling
    /// without a passphrase, external key paths). Shown once the save panel
    /// has actually written the file — an export that never happened must not
    /// claim anything about its contents.
    @State private var exportNotice: String?
    @State private var showExportNotice = false
    @State private var exportErrorMessage: String?

    @State private var showImportFileImporter = false
    @State private var importFileData: Data?
    @State private var showImportPasswordSheet = false
    /// A decoded payload waiting to be planned — same split as
    /// `ContentView.pendingImport`: planning may open the conflict sheet, and
    /// only one sheet presents at a time, so it must not run while the
    /// password prompt is still up.
    @State private var pendingImport: PendingLoginImport?
    @State private var importConflictBridge = ImportConflictBridge()
    @State private var importResultMessage = ""
    @State private var showImportResultAlert = false
    @State private var importErrorMessage: String?
    /// Guards the `startsImport` auto-open against a second `onAppear`.
    @State private var didAutoStartImport = false

    /// Drives the editor sub-sheet: wraps "new" (no existing set) or "edit"
    /// (a specific set) so `.sheet(item:)` has a stable identity even for
    /// the "new" case, which otherwise has none of its own — same pattern as
    /// `ContentView.ExportSheetItem`.
    private struct LoginSetEditorTarget: Identifiable {
        let id = UUID()
        let existing: LoginSet?
    }

    /// The sets one export run covers, wrapped for `.sheet(item:)` — a plain
    /// array has no identity of its own.
    private struct ExportTarget: Identifiable {
        let id = UUID()
        let sets: [LoginSet]
    }

    private struct PendingLoginImport {
        let payload: LoginSetExportPayload
        let wasEncrypted: Bool
    }

    private var selectedSet: LoginSet? {
        sessionList.loginSets.first { $0.id == selectedID }
    }

    /// Clears BOTH narrowings — what the empty state's "Show all" does. One
    /// of them alone would leave the list just as empty.
    private func clearNarrowings() {
        searchText = ""
        facet = .all
    }

    var body: some View {
        // Hoisted out of the VStack's own scope (M19/T8 review, leftover 5)
        // so `.onChange(of: visibleSets)` below — attached to the VStack
        // itself rather than to the `List` inside it — can still name it.
        let (predicate, searchError) = sheetSearchPredicate(
            text: searchText, isRegex: searchIsRegex)
        // The search and the backend facet applied together, in one call to
        // the shared chaining — so what the list draws, what the export scope
        // resolves against and what the empty state blames are readings of
        // the same pass rather than separate filters.
        let narrowing = facet.narrowing(
            sessionList.loginSets,
            search: predicate,
            searchText: { "\($0.name) \($0.username) \($0.accessKeyID ?? "")" },
            facetValue: { Self.kindLabel($0.kind) })
        let visibleSets = narrowing.visible

        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("loginSets.title", "Logins")).font(.headline)

            if let mergeCandidate {
                mergeBanner(mergeCandidate)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)

            SheetFacetPicker(
                values: SheetFacetFilter.values(of: sessionList.loginSets) {
                    Self.kindLabel($0.kind)
                },
                label: L10n.string("loginSets.facet.kind", "Backend"),
                filter: $facet)
                .padding(.bottom, 4)

            if visibleSets.isEmpty {
                Spacer(minLength: 0)
                SheetListEmptyState(
                    emptiness: narrowing.emptiness,
                    noRowsMessage: L10n.string("loginSets.empty", "No login sets yet."),
                    noSearchMatchesMessage: L10n.string("loginSets.noMatches", "No matches."),
                    onShowAll: clearNarrowings)
                Spacer(minLength: 0)
            } else {
                List(visibleSets, selection: $selectedID) { set in
                    row(set)
                }
            }

            HStack {
                Text(String(
                    format: L10n.string("loginSets.count %lld", "%lld logins"),
                    sessionList.loginSets.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("loginSets.new", "New…")) {
                    editorTarget = LoginSetEditorTarget(existing: nil)
                }
                .buttonStyle(.polished)
                Button(L10n.string("loginSets.edit", "Edit…")) {
                    if let selectedSet {
                        editorTarget = LoginSetEditorTarget(existing: selectedSet)
                    }
                }
                .buttonStyle(.polished)
                .disabled(selectedSet == nil)
                Button(L10n.string("loginSets.delete", "Delete…"), role: .destructive) {
                    isShowingDeleteConfirm = true
                }
                .buttonStyle(.polished)
                .disabled(selectedSet == nil)
                // Export and Import act on a file on disk, so they sit under
                // the three-dot menu, while New/Edit/Delete above act on the
                // list selection and stay visible (backlog 2026-08-20,
                // point 5). Delete… would fit under the menu just as well and
                // deliberately does not go there: it is destructive.
                //
                // With nothing visible there is nothing to export, so the
                // entry is left out rather than shown greyed — which also
                // replaces the `.disabled(visibleSets.isEmpty)` this button
                // carried before.
                //
                // Export scope (M19/T8, corrected in review; the rule itself
                // now lives at `ListExportScope`): with an active search, M18's
                // regression fix above clears the selection as soon as the
                // selected row is filtered out, so "no selection" is the
                // NORMAL state while searching — falling back to the full
                // `sessionList.loginSets` meant filtering 60 logins down to
                // 3, hitting "Export…", and writing all 60 — with their
                // passwords, if that switch was on. Edit and Delete were
                // hardened against exactly this in M18; export was not.
                SheetOverflowMenu(
                    actions: SheetOverflowAction.offered(
                        canExport: !visibleSets.isEmpty, canImport: true)
                ) { action in
                    switch action {
                    case .export:
                        exportTarget = ExportTarget(sets: ListExportScope.resolve(
                            selectedID: selectedID, from: visibleSets))
                    case .import:
                        showImportFileImporter = true
                    }
                }
                Button(L10n.string("common.close", "Close")) { dismiss() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        // M18 search regression fix, hoisted onto the enclosing container
        // (M19/T8 review, leftover 5): attaching this to the `List` directly
        // left it covered only while `visibleSets` was non-empty — the `List`
        // is removed from the tree entirely once a search matches nothing,
        // taking the `onChange` with it. Edit…/Delete… are gated on
        // `selectedSet`, which reads the FULL `sessionList.loginSets`, so
        // with the search showing "No matches" they stayed enabled and acted
        // on (and the delete dialog named) a row the user could no longer
        // see — Export was already immune via `ListExportScope.resolve`'s own
        // membership check. Attaching to the VStack instead covers both
        // branches of the `if visibleSets.isEmpty` above, so the selection
        // is cleared whichever one is on screen.
        .onChange(of: visibleSets) { _, newValue in
            if let selectedID, !newValue.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear {
            refreshMergeCandidate()
            // "Import Logins…" from the Sessions menu opens this sheet with
            // the picker armed; the guard keeps a re-appear (e.g. after a
            // sub-sheet closes) from re-opening it.
            if startsImport && !didAutoStartImport {
                didAutoStartImport = true
                showImportFileImporter = true
            }
        }
        // Editor sub-sheet (Step 2/spec §1-2): one view for both New… and
        // Edit…, distinguished by `target.existing`.
        .sheet(item: $editorTarget) { target in
            LoginSetEditorView(
                existing: target.existing,
                onSave: { set, secret in
                    sessionList.saveLoginSet(set, secret: secret)
                    editorTarget = nil
                },
                onCancel: { editorTarget = nil }
            )
        }
        .confirmationDialog(
            L10n.string("loginSets.delete.title", "Delete this login?"),
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("loginSets.delete.confirm", "Delete"), role: .destructive) {
                deleteSelected()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteConfirmMessage)
        }
        .confirmationDialog(
            L10n.string("loginSets.merge.confirmTitle", "Merge these connections?"),
            isPresented: $isShowingMergeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("loginSets.merge.confirm", "Merge"), role: .destructive) {
                applyMerge()
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(mergeConfirmMessage)
        }
        // MARK: Export (M19/T8)
        .sheet(item: $exportTarget) { target in
            LoginSetExportSheet(
                sets: target.sets,
                onExport: { options in performExport(sets: target.sets, options: options) })
        }
        .fileExporter(
            isPresented: $showExportFileExporter,
            document: exportDocument,
            contentType: .macscpLogins,
            defaultFilename: "macSCP Logins.macscplogins"
        ) { result in
            handleExportResult(result)
        }
        .alert(
            L10n.string("export.error.title", "Export Failed"),
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { isPresented in if !isPresented { exportErrorMessage = nil } })
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert(
            L10n.string("export.result.title", "Export Complete"),
            isPresented: $showExportNotice
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(exportNotice ?? "")
        }
        // MARK: Import (M19/T8)
        .fileImporter(
            isPresented: $showImportFileImporter,
            allowedContentTypes: [.macscpLogins, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportFileSelection(result)
        }
        .sheet(isPresented: $showImportPasswordSheet, onDismiss: {
            // Same two reasons as `ContentView`'s copy: the ciphertext must
            // not linger in view state whichever way the sheet closed, and
            // planning (which may open the conflict sheet) can only run once
            // this sheet is gone.
            importFileData = nil
            if let pending = pendingImport {
                pendingImport = nil
                Task { await applyImport(pending) }
            }
        }) {
            ImportPasswordSheet(
                onSubmit: { password in
                    guard let data = importFileData else { return nil }
                    switch decodeImport(data: data, password: password) {
                    case .ready(let pending):
                        pendingImport = pending
                        return nil
                    case .retry(let message):
                        return message
                    case .failed:
                        return nil
                    }
                },
                onCancel: {
                    importFileData = nil
                    pendingImport = nil
                }
            )
        }
        // Same modifier the session import uses (`ContentView`), so both
        // flows share one presentation contract — see
        // `importConflictSheet(bridge:)`.
        .importConflictSheet(bridge: importConflictBridge)
        .alert(
            L10n.string("import.error.title", "Import Failed"),
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { isPresented in if !isPresented { importErrorMessage = nil } })
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
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

    @ViewBuilder
    private func row(_ set: LoginSet) -> some View {
        HStack(spacing: 10) {
            // SSH is the only kind whose badge says something: its three auth
            // kinds are a real choice the user made. Every other protocol
            // authenticates one way, so its badge names the PROTOCOL — taken
            // from the backend descriptor (M22/T9), not hand-picked here, so a
            // fourth backend needs no edit at this site.
            if set.kind == .ssh {
                authKindBadge(set.authKind)
            } else {
                badge(label: Self.kindLabel(set.kind),
                      soft: DesignTokens.s3Soft, ink: DesignTokens.s3Violet)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(set.name).font(.system(size: 13))
                Text(subtitle(for: set))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
            }
            Spacer()
            // "Key file missing" (M19/T8): a set imported from a file that
            // carried no key file points at a path that exists only on the
            // exporting machine. Display-only — nothing is changed, the list
            // just says so instead of letting the next connect fail.
            if set.keyFileIsMissing {
                Label(
                    L10n.string("loginSets.keyMissing", "Key file missing"),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.localAmber)
                    .help(L10n.string(
                        "loginSets.keyMissing.help",
                        "This key file does not exist on this Mac. Choose a key in the editor."))
            }
            Text(usageText(sessionList.usageCount(of: set.id)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // Row context menu (M18/T3): reuses the same footer triggers
        // (`editorTarget`, `isShowingDeleteConfirm`) so behavior stays in
        // sync with the "Edit…"/"Delete…" buttons — selection is set first
        // so the action targets the right-clicked row even if it wasn't
        // already selected.
        .contextMenu {
            Button(L10n.string("loginSets.edit", "Edit…")) {
                selectedID = set.id
                editorTarget = LoginSetEditorTarget(existing: set)
            }
            // Single-set export (M19/T8) — the footer's Export… entry, now
            // under the three-dot menu, covers "all" (or whatever is
            // selected); this one always means THIS row.
            Button(L10n.string("logins.export.action", "Export…")) {
                selectedID = set.id
                exportTarget = ExportTarget(sets: [set])
            }
            Button(L10n.string("loginSets.delete", "Delete…"), role: .destructive) {
                selectedID = set.id
                isShowingDeleteConfirm = true
            }
        }
    }

    @ViewBuilder
    private func authKindBadge(_ kind: StoredSession.AuthKind) -> some View {
        let (label, soft, ink) = badgeStyle(for: kind)
        badge(label: label, soft: soft, ink: ink)
    }

    @ViewBuilder
    private func badge(label: String, soft: Color, ink: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(soft, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(ink)
    }

    /// Label + colors for `authKindBadge` above, one three-way switch
    /// (M10d/T4 added `.agent`) instead of the two-way `isKey ? : `
    /// ternary this replaced — a ternary can only ever pick one of two
    /// outcomes, so a third kind falling through it would silently render
    /// as PASS.
    private func badgeStyle(for kind: StoredSession.AuthKind) -> (label: String, soft: Color, ink: Color) {
        switch kind {
        case .privateKey:
            return (L10n.string("loginSets.badge.key", "KEY"), DesignTokens.remoteSoft, DesignTokens.remoteBlue)
        case .agent:
            return (L10n.string("loginSets.badge.agent", "AGENT"), DesignTokens.agentSoft, DesignTokens.agentGreen)
        case .password:
            return (L10n.string("loginSets.badge.pass", "PASS"), DesignTokens.localSoft, DesignTokens.localAmber)
        }
    }

    /// A protocol's own name, from its backend descriptor — the same source
    /// the sidebar and the tab strip already use for their kind badges.
    static func kindLabel(_ kind: ConnectionKind) -> String {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    private func subtitle(for set: LoginSet) -> String {
        if set.kind != .ssh {
            // "<identity> · <protocol>". The identity is whichever column the
            // set actually carries: S3 sets hold an access key and an empty
            // user name, WebDAV the reverse. Reading the optional first needs
            // no branch on `kind` (same idiom as `loginSetLabel`).
            return String(
                format: L10n.string("loginSets.subtitle.kind %@ %@", "%@ · %@"),
                set.accessKeyID ?? set.username, Self.kindLabel(set.kind))
        }
        switch set.authKind {
        case .privateKey:
            return String(
                format: L10n.string("loginSets.subtitle.key %@ %@", "%@ · SSH key (%@)"),
                set.username, set.keyPath ?? "")
        case .agent:
            return String(
                format: L10n.string("loginSets.subtitle.agent %@", "%@ · Agent"), set.username)
        case .password:
            return String(
                format: L10n.string("loginSets.subtitle.password %@", "%@ · Password"), set.username)
        }
    }

    private func usageText(_ count: Int) -> String {
        if count == 1 { return L10n.string("loginSets.usage.one", "1 connection") }
        return String(format: L10n.string("loginSets.usage.many %lld", "%lld connections"), count)
    }

    private var deleteConfirmMessage: String {
        guard let selectedSet else { return "" }
        let count = sessionList.usageCount(of: selectedSet.id)
        return String(
            format: L10n.string(
                "loginSets.delete.message %lld",
                "%lld connections will keep these credentials stored directly again."),
            count)
    }

    /// Deletes the selected set (spec §3: affected connections are restored
    /// to "manual" with the set's own values copied back — see
    /// `SessionListViewModel.deleteLoginSet`'s doc comment). A partial
    /// keychain-restore failure is surfaced as a red inline message (pattern:
    /// `KnownHostsSheet.removeSelected`'s `knownHosts.removeError`), never
    /// silently dropped.
    private func deleteSelected() {
        guard let selectedSet else { return }
        let result = sessionList.deleteLoginSet(selectedSet)
        selectedID = nil
        if result.secretFailures > 0 {
            deleteErrorMessage = String(
                format: L10n.string(
                    "loginSets.deleteError %lld",
                    "Could not restore the stored password for %lld connections."),
                result.secretFailures)
        } else {
            deleteErrorMessage = nil
        }
        refreshMergeCandidate()
    }

    // MARK: - Merge banner (spec §4)

    private func refreshMergeCandidate() {
        mergeCandidate = sessionList.mergeCandidates().first
    }

    @ViewBuilder
    private func mergeBanner(_ candidate: LoginMergeCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\u{1F4A1}")
            Text(String(
                format: L10n.string(
                    "loginSets.merge.banner %lld %@",
                    "%lld connections use the same login \u{201C}%@\u{201D}."),
                candidate.sessionIDs.count, candidate.displayLabel))
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("loginSets.merge.ignore", "Ignore")) {
                sessionList.ignoreMerge(candidate)
                refreshMergeCandidate()
            }
            .buttonStyle(.polished)
            Button(L10n.string("loginSets.merge.action", "Merge…")) {
                isShowingMergeConfirm = true
            }
            .buttonStyle(.polishedProminent)
        }
        .padding(10)
        .background(DesignTokens.remoteSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Lists the affected session NAMES (resolved from `sessionIDs`) plus the
    /// target set name (spec §4) — the banner itself only names the display
    /// label/count (the user name for SSH and WebDAV, the access key ID for
    /// S3), this dialog is where the concrete connections show up before the
    /// user commits.
    private var mergeConfirmMessage: String {
        guard let mergeCandidate else { return "" }
        let names = mergeCandidate.sessionIDs
            .compactMap { id in sessionList.sessions.first { $0.id == id }?.name }
            .joined(separator: ", ")
        let targetName = sessionList.suggestedSetName(forLabel: mergeCandidate.displayLabel)
        return String(
            format: L10n.string(
                "loginSets.merge.confirmMessage %@ %@",
                "%@ will be merged into the login \u{201C}%@\u{201D}."),
            names, targetName)
    }

    private func applyMerge() {
        guard let mergeCandidate else { return }
        let targetName = sessionList.suggestedSetName(forLabel: mergeCandidate.displayLabel)
        _ = sessionList.applyMerge(mergeCandidate, name: targetName)
        refreshMergeCandidate()
    }

    // MARK: - Export (M19/T8)

    /// Builds the payload, encodes it, and arms the `fileExporter` — mirrors
    /// `ContentView.performExport` for sessions, including the "return a
    /// message to keep the sheet open" contract.
    private func performExport(sets: [LoginSet], options: LoginSetExportOptions) -> String? {
        let result = sessionList.loginSetExportPayload(
            for: sets, includeSecrets: options.includeSecrets,
            includeKeyFiles: options.includeKeyFiles)
        do {
            let data = try LoginSetExportCodec.encode(result.payload, password: options.password)
            exportDocument = LoginSetExportDocument(data: data)
            exportNotice = exportNoticeText(for: result)
            showExportFileExporter = true
            return nil
        } catch {
            return String(format: L10n.string(
                "export.error.encodeFailed %@", "Could not prepare the export: %@"),
                String(describing: error))
        }
    }

    /// Everything the finished file does NOT contain, in one alert body — or
    /// `nil` when it contains everything that was asked for, in which case no
    /// alert is shown at all.
    private func exportNoticeText(
        for result: SessionListViewModel.LoginSetExportResult
    ) -> String? {
        var lines: [String] = []
        if result.missingSecretCount > 0 {
            lines.append(String(format: L10n.string(
                "logins.export.missingSecrets %lld", "Exported without a password: %lld"),
                result.missingSecretCount))
        }
        if result.externalKeyCount > 0 {
            lines.append(String(format: L10n.string(
                "logins.export.externalKeys %lld",
                "Key files not embedded (not managed by macSCP): %lld"),
                result.externalKeyCount))
        }
        // The key travels, its passphrase does not — the receiving side will
        // have to type it. Saying so beats an "it just does not connect there"
        // discovery later.
        if result.keysWithoutPassphrase > 0 {
            lines.append(String(format: L10n.string(
                "logins.export.keysWithoutPassphrase %lld",
                "Key files exported without their passphrase: %lld"),
                result.keysWithoutPassphrase))
        }
        if !result.keyErrors.isEmpty {
            lines.append(String(format: L10n.string(
                "logins.export.keyErrors %@", "Key files that could not be read: %@"),
                result.keyErrors.joined(separator: ", ")))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if exportNotice != nil { showExportNotice = true }
        case .failure(let error):
            exportErrorMessage = String(format: L10n.string(
                "export.error.writeFailed %@", "Could not write the export file: %@"),
                String(describing: error))
        }
        // Drop the encoded bytes (which may hold plaintext secrets and key
        // material) as soon as the panel has resolved, however it resolved —
        // the same hygiene `ContentView.handleExportResult` applies.
        exportDocument = nil
    }

    // MARK: - Import (M19/T8)

    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = readErrorMessage(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if try LoginSetExportCodec.probe(data) {
                    importFileData = data
                    showImportPasswordSheet = true
                } else if case .ready(let pending) = decodeImport(data: data, password: nil) {
                    Task { await applyImport(pending) }
                }
            } catch let error as SessionExportError {
                importErrorMessage = importErrorText(for: error)
            } catch {
                importErrorMessage = readErrorMessage(error)
            }
        }
    }

    private enum ImportDecodeOutcome {
        case ready(PendingLoginImport)
        case retry(String)
        case failed
    }

    /// Decode only — see `pendingImport`. No key material and no secret ever
    /// reaches a message: the envelope errors are typed, and the fallback
    /// prints the Cocoa error of a FILE READ, which never saw the payload.
    private func decodeImport(data: Data, password: String?) -> ImportDecodeOutcome {
        do {
            return .ready(PendingLoginImport(
                payload: try LoginSetExportCodec.decode(data, password: password),
                wasEncrypted: password != nil))
        } catch SessionExportError.wrongPasswordOrCorrupted {
            return .retry(
                L10n.string("import.password.wrong", "Wrong password, or the file is corrupted."))
        } catch let error as SessionExportError {
            importErrorMessage = importErrorText(for: error)
            return .failed
        } catch {
            importErrorMessage = readErrorMessage(error)
            return .failed
        }
    }

    /// Plan → apply. Conflicts are resolved through the SHARED arbiter and the
    /// same `ImportConflictSheet` the session import uses. A cancelled run
    /// reports nothing at all.
    private func applyImport(_ pending: PendingLoginImport) async {
        let bridge = importConflictBridge
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let plan = await LoginSetImportPlanner.plan(
            existing: sessionList.loginSets, incoming: pending.payload, arbiter: arbiter)
        importFileData = nil
        guard !plan.cancelled else { return }
        let result = sessionList.applyLoginSetImport(plan)
        importResultMessage = importResultText(
            result, includesSecrets: pending.payload.includesSecrets,
            encrypted: pending.wasEncrypted)
        showImportResultAlert = true
        selectedID = nil
        refreshMergeCandidate()
    }

    private func importResultText(
        _ result: SessionListViewModel.LoginSetImportResult, includesSecrets: Bool, encrypted: Bool
    ) -> String {
        var lines = [String(format: L10n.string(
            "logins.import.result %lld %lld %lld",
            "%lld imported, %lld replaced, %lld skipped"),
            result.imported, result.replaced, result.skipped)]
        if result.renamed > 0 {
            lines.append(String(format: L10n.string(
                "logins.import.renamed %lld", "Imported under a new name: %lld"), result.renamed))
        }
        if result.keysImported > 0 {
            lines.append(String(format: L10n.string(
                "logins.import.keysImported %lld", "Key files imported: %lld"),
                result.keysImported))
        }
        if !result.missingKeyPaths.isEmpty {
            lines.append(String(format: L10n.string(
                "logins.import.missingKeys %@", "Key file missing on this Mac: %@"),
                result.missingKeyPaths.joined(separator: ", ")))
        }
        if !result.keyFailures.isEmpty {
            lines.append(String(format: L10n.string(
                "logins.import.keyFailures %@", "Key files that could not be imported: %@"),
                result.keyFailures.joined(separator: ", ")))
        }
        // Same honesty as the session import: a replace from a secret-free
        // file drops the stored credential rather than keeping a hidden one.
        if result.secretsRemoved > 0 {
            lines.append(String(format: L10n.string(
                "logins.import.secretsRemoved %lld",
                "Stored passwords removed because the file had none: %lld"),
                result.secretsRemoved))
        }
        // The counterpart to the export sheet's "Exported without a password"
        // line (M28/T4): without this, a set that arrived with no secret only
        // surfaces the day a connection using it fails.
        if result.secretsMissing > 0 {
            lines.append(String(format: L10n.string(
                "logins.import.withoutPassword %lld", "Arrived without a password: %lld"),
                result.secretsMissing))
        }
        // Same shared line the session summary uses: a stale secret the
        // Keychain refused to delete is still bound to the replaced set.
        if result.secretRemovalFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.secretsRemoveFailed %lld",
                "Stored passwords that could not be removed: %lld"),
                result.secretRemovalFailures))
        }
        if result.secretFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.passwordFailures %lld", "Passwords that could not be saved: %lld"),
                result.secretFailures))
        }
        if result.storeFailures > 0 {
            lines.append(String(format: L10n.string(
                "import.result.storeFailures %lld", "Not saved due to an error: %lld"),
                result.storeFailures))
        }
        if includesSecrets && !encrypted {
            lines.append(L10n.string(
                "import.result.plaintextNotice", "The file contained unencrypted passwords."))
        }
        return lines.joined(separator: "\n")
    }

    /// Same two typed conditions `ContentView.importErrorText` maps, worded
    /// for the login format.
    private func importErrorText(for error: SessionExportError) -> String {
        switch error {
        case .notAnExportFile:
            return L10n.string("logins.import.notExport", "Not a macSCP logins file.")
        case .unsupportedVersion:
            return L10n.string(
                "import.error.newerVersion",
                "This file was created by a newer version of macSCP.")
        case .passwordRequired, .wrongPasswordOrCorrupted, .randomnessUnavailable:
            return L10n.string("import.password.wrong", "Wrong password, or the file is corrupted.")
        }
    }

    private func readErrorMessage(_ error: Error) -> String {
        String(format: L10n.string(
            "import.error.readFailed %@", "Could not read the file: %@"),
            String(describing: error))
    }
}

/// New/Edit sub-sheet (spec §1-2), schema-driven since M22/T9: a name, a
/// protocol picker over EVERY `ConnectionKind`, and the chosen backend's
/// `credentialSchema` rendered by the same `SchemaFormView` the connection
/// form uses.
///
/// The hand-written version this replaces enumerated SSH and S3 in its
/// picker, spelled out their rows by hand, gated Save on a `switch` that
/// returned "always disabled" for `.webdav`, and carried a
/// `preconditionFailure` for `.webdav` on the save path. That is why a
/// WebDAV login set could not be created at all — and why the WebDAV
/// connection form's login-set picker was always empty. Nothing in here
/// names a protocol any more, so the next backend arrives with its schema
/// and no edit to this file.
private struct LoginSetEditorView: View {
    let existing: LoginSet?
    let onSave: (LoginSet, String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var kind: ConnectionKind
    /// Every credential field the chosen backend declares, in the same shape
    /// `LoginResolver.resolve` returns and `ConnectionViewModel` binds to.
    @State private var values: FieldValues
    @State private var showKeyImporter = false
    /// Drives the SSH-keys management sheet's "Manage keys…" link (M18/T5) —
    /// same locally opened sheet pattern `ConnectionFormView` uses, in place
    /// of the M17 `SettingsLink` to the Settings tab.
    @State private var showSSHKeysSheet = false

    init(existing: LoginSet?, onSave: @escaping (LoginSet, String?) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        let kind = existing?.kind ?? .ssh
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: kind)
        _values = State(initialValue: Self.initialValues(for: kind, existing: existing))
    }

    /// A brand-new set starts at the backend's own defaults — SSH's
    /// `password` auth kind among them, so its picker is not blank — and an
    /// existing set writes its stored values over those.
    ///
    /// Never the secret: it stays in the Keychain, and an empty secret row
    /// means "keep the stored one", which is what the row's placeholder says.
    private static func initialValues(
        for kind: ConnectionKind, existing: LoginSet?
    ) -> FieldValues {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        var values = descriptor.defaultValues
        // Only when the set IS of this kind: switching the picker away and
        // back must not carry an SSH set's user name into an S3 access key.
        if let existing, existing.kind == kind {
            values.merge(descriptor.loginSetValues(existing))
        }
        return values
    }

    private var isEditing: Bool { existing != nil }
    private var descriptor: BackendDescriptor { .descriptor(for: kind) }

    /// Save stays disabled until the set has a name and every field the
    /// schema currently marks required is filled (M15: trimmed, so a row of
    /// spaces does not count).
    ///
    /// A query against the schema instead of the `switch` over
    /// `ConnectionKind` this replaces. That switch is where `.webdav`
    /// returned `true` unconditionally, which disabled Save for a protocol
    /// the picker did not even offer — a dead end that no compiler and no
    /// test could see, because "disabled" is a perfectly valid answer.
    private var isSaveDisabled: Bool {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace).isEmpty
    }

    /// Whatever the schema says the secret row IS right now — SSH's
    /// "Password" under password auth, its "Passphrase (optional)" under
    /// private-key auth, and nothing at all for an agent login, whose set
    /// carries no secret (M10d). Reading a FIXED field instead would save an
    /// agent set's stale password, or file a passphrase under the password
    /// slot.
    private var secret: String {
        guard let field = descriptor.credentialSchema.visibleSecretField(
            in: values, namespace: descriptor.fieldNamespace)
        else { return "" }
        return values.raw["\(descriptor.fieldNamespace).\(field.id)"] ?? ""
    }

    /// True while the SSH key-path row is on screen — the one place this
    /// editor still adds affordances of its own (see `sshKeyFileRow`).
    private var showsKeyFileAffordances: Bool {
        kind == .ssh && values[SSHField.authKind] == StoredSession.AuthKind.privateKey.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing
                ? L10n.string("loginSets.editor.titleEdit", "Edit login")
                : L10n.string("loginSets.editor.titleNew", "New login"))
                .font(.title3.bold())

            let nameLabel = L10n.string("loginSets.editor.name", "Name")
            FormRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }

            // Every kind, from `ConnectionKind.allCases` with the descriptor's
            // own badge label — the same source the sidebar, the tab strip and
            // the connection form's type switcher already use. The
            // hand-enumerated two-tag picker this replaces is what made
            // `.webdav` unreachable.
            let kindLabel = L10n.string("loginSets.editor.kind", "Type")
            FormRow(label: kindLabel) {
                Picker(kindLabel, selection: $kind) {
                    ForEach(ConnectionKind.allCases, id: \.self) { kind in
                        Text(LoginSetsSheet.kindLabel(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SchemaFormView(
                schemas: [descriptor.credentialSchema], values: $values,
                namespace: descriptor.fieldNamespace, isEditMode: isEditing,
                resolve: resolveOptions)

            if showsKeyFileAffordances { sshKeyFileRow }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { onCancel() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) {
                    let set = descriptor.loginSet(
                        id: existing?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        from: values)
                    onSave(set, secret.isEmpty ? nil : secret)
                }
                .buttonStyle(.polishedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .textFieldStyle(.roundedBorder)
        // Switching the protocol starts that backend's form clean, the same
        // rule `ConnectionViewModel.kind` follows: the namespaced storage
        // already keeps an S3 access key out of a WebDAV set, but a stale row
        // must not be shown either.
        .onChange(of: kind) { _, newKind in
            values = Self.initialValues(for: newKind, existing: existing)
        }
        // The managed-key picker writes an id; `keyPath` is what is stored, so
        // the pick is translated here exactly as `ConnectionFormView` does.
        .onChange(of: values.raw[Self.managedKeyKey] ?? "") { _, newID in
            guard !newID.isEmpty,
                  let key = ManagedKeysLoad.connectableKeys()
                      .first(where: { $0.id.uuidString == newID })
            else { return }
            values[SSHField.keyPath] = Self.managedKeyPath(for: key)
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                values[SSHField.keyPath] = url.path(percentEncoded: false)
            }
        }
        // "Manage keys…" (M18/T5): a third sheet layer on top of this
        // editor's own `.sheet(item:)` presentation from `LoginSetsSheet`
        // (which is itself opened over `ConnectionFormView`/`ContentView`) —
        // SwiftUI presents each `.sheet` modally over whichever one is
        // already up, so nesting this deep is unremarkable.
        .sheet(isPresented: $showSSHKeysSheet) {
            SSHKeysSheet()
        }
    }

    /// Browse-for-a-key-file and "Manage keys…" — the same two affordances
    /// `ConnectionFormView` places beside its schema-rendered `keyPath` row,
    /// for the same reason: both open App-only UI (an `NSOpenPanel` and a
    /// sheet) that no schema vocabulary describes.
    private var sshKeyFileRow: some View {
        FormRow(label: "") {
            HStack(spacing: 6) {
                // "…" is a pure symbol (ellipsis "browse" affordance), not
                // natural-language text — identical in every locale.
                Button("…") { showKeyImporter = true }
                    .buttonStyle(.polished)
                    .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                Button(L10n.string("keys.picker.manage", "Manage keys…")) {
                    showSSHKeysSheet = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
            }
        }
    }

    /// The App's half of the generic renderer's contract: managed keys live
    /// in a store Core cannot see.
    private func resolveOptions(_ source: OptionSource) -> [FieldOption] {
        switch source {
        case .fixed(let options):
            return options
        case .managedKeys:
            return ManagedKeysLoad.connectableKeys().map { key in
                FieldOption(
                    id: key.id.uuidString, labelKey: "",
                    labelDefault: "\(key.name) — \(Self.shortFingerprint(key.fingerprint))")
            }
        }
    }
}

private extension LoginSetEditorView {
    /// The stored key of the managed-key picker, watched above — the same
    /// namespaced key `FieldValues`'s typed subscripts build.
    static var managedKeyKey: String {
        "\(SSHField.namespace).\(SSHField.managedKeyID.rawValue)"
    }

    /// The private-key file path a managed key resolves to, in the shape
    /// `keyPath` expects (absolute, not percent-encoded). Empty — i.e. "no
    /// key" — for a key whose stored `fileName` does not address a file
    /// inside the key directory; `ManagedKeysLoad.connectableKeys` already
    /// keeps those out of the picker.
    static func managedKeyPath(for key: ManagedKey) -> String {
        ManagedKeyStore(directory: SessionStore.defaultDirectory)
            .privateKeyURL(for: key)?.path(percentEncoded: false) ?? ""
    }

    /// The first ~12 characters after the `SHA256:` prefix, for a compact
    /// menu row label (`ManagedKey.fingerprint` is the full base64 digest).
    static func shortFingerprint(_ fingerprint: String) -> String {
        guard let range = fingerprint.range(of: "SHA256:") else { return fingerprint }
        return String(fingerprint[range.upperBound...].prefix(12))
    }
}
