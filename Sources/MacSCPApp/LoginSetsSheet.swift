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

    /// What the footer's "Export…" covers: the selection when it is one of the
    /// rows on screen, otherwise every row on screen. `selectedSet` reads from
    /// the FULL list, so the membership check is what keeps a selection that
    /// the search has filtered away from silently widening — or narrowing —
    /// the scope. The export sheet then states the count before anything is
    /// written.
    private func exportScope(within visibleSets: [LoginSet]) -> [LoginSet] {
        if let selectedSet, visibleSets.contains(where: { $0.id == selectedSet.id }) {
            return [selectedSet]
        }
        return visibleSets
    }

    var body: some View {
        // Hoisted out of the VStack's own scope (M19/T8 review, leftover 5)
        // so `.onChange(of: visibleSets)` below — attached to the VStack
        // itself rather than to the `List` inside it — can still name it.
        let (predicate, searchError) = sheetSearchPredicate(
            text: searchText, isRegex: searchIsRegex)
        let visibleSets = sessionList.loginSets.filter {
            predicate.matches("\($0.name) \($0.username) \($0.accessKeyID ?? "")")
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("loginSets.title", "Logins")).font(.headline)

            if let mergeCandidate {
                mergeBanner(mergeCandidate)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)
                .padding(.bottom, 4)

            if visibleSets.isEmpty {
                Spacer(minLength: 0)
                Text(searchText.isEmpty
                    ? L10n.string("loginSets.empty", "No login sets yet.")
                    : L10n.string("loginSets.noMatches", "No matches."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
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
                // Export scope (M19/T8, corrected in review): the selected set
                // when there is one, otherwise everything the LIST CURRENTLY
                // SHOWS — never everything that exists. With an active search
                // the two differ, and M18's regression fix above clears the
                // selection as soon as the selected row is filtered out, so
                // "no selection" is the NORMAL state while searching: falling
                // back to `sessionList.loginSets` meant filtering 60 logins
                // down to 3, hitting "Export…", and writing all 60 — with
                // their passwords, if that switch was on. Edit and Delete were
                // hardened against exactly this in M18; export was not.
                Button(L10n.string("logins.export.action", "Export…")) {
                    exportTarget = ExportTarget(sets: exportScope(within: visibleSets))
                }
                .buttonStyle(.polished)
                .disabled(visibleSets.isEmpty)
                Button(L10n.string("logins.import.action", "Import…")) {
                    showImportFileImporter = true
                }
                .buttonStyle(.polished)
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
        // see — Export was already immune via `exportScope`'s own membership
        // check. Attaching to the VStack instead covers both branches of the
        // `if visibleSets.isEmpty` above, so the selection is cleared
        // whichever one is on screen.
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
            if set.kind == .s3 {
                badge(label: L10n.string("loginSets.badge.s3", "S3"),
                      soft: DesignTokens.s3Soft, ink: DesignTokens.s3Violet)
            } else {
                authKindBadge(set.authKind)
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
            // Single-set export (M19/T8) — the footer button covers "all" (or
            // whatever is selected); this one always means THIS row.
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

    private func subtitle(for set: LoginSet) -> String {
        if set.kind == .s3 {
            return String(
                format: L10n.string("loginSets.subtitle.s3 %@", "%@ · S3"),
                set.accessKeyID ?? "")
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
                candidate.sessionIDs.count, candidate.username))
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
    /// target set name (spec §4) — the banner itself only names the
    /// username/count, this dialog is where the concrete connections show up
    /// before the user commits.
    private var mergeConfirmMessage: String {
        guard let mergeCandidate else { return "" }
        let names = mergeCandidate.sessionIDs
            .compactMap { id in sessionList.sessions.first { $0.id == id }?.name }
            .joined(separator: ", ")
        let targetName = sessionList.suggestedSetName(forUsername: mergeCandidate.username)
        return String(
            format: L10n.string(
                "loginSets.merge.confirmMessage %@ %@",
                "%@ will be merged into the login \u{201C}%@\u{201D}."),
            names, targetName)
    }

    private func applyMerge() {
        guard let mergeCandidate else { return }
        let targetName = sessionList.suggestedSetName(forUsername: mergeCandidate.username)
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

/// New/Edit sub-sheet (spec §1-2): name, username, Password|SSH-key segments
/// — the same field pattern `ConnectionFormView`'s auth block uses (SecureField
/// with a "leave empty to keep" prompt while editing, key path + "Choose…"
/// fileImporter, optional passphrase). Purely local state; `existing == nil`
/// for "New…" builds a fresh `LoginSet` on save, `existing != nil` for
/// "Edit…" keeps that set's id.
private struct LoginSetEditorView: View {
    let existing: LoginSet?
    let onSave: (LoginSet, String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var username: String
    @State private var authChoice: ConnectionViewModel.AuthChoice
    @State private var keyPath: String
    @State private var secret: String = ""
    @State private var showKeyImporter = false
    @State private var kind: ConnectionKind
    @State private var accessKeyID: String
    /// Drives the SSH-keys management sheet's "Manage keys…" link (M18/T5) —
    /// same locally opened sheet pattern `ConnectionFormView` uses, in place
    /// of the M17 `SettingsLink` to the Settings tab.
    @State private var showSSHKeysSheet = false

    init(existing: LoginSet?, onSave: @escaping (LoginSet, String?) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: existing?.name ?? "")
        _username = State(initialValue: existing?.username ?? "")
        // Three-way mapping (M10d/T4): reuses the SAME Core helper
        // `ConnectionViewModel.authChoice(for:)` the target/jump prefill
        // paths use, instead of a two-way ternary that would silently
        // misdisplay `.agent` as Password.
        _authChoice = State(initialValue: ConnectionViewModel.authChoice(for: existing?.authKind ?? .password))
        _keyPath = State(initialValue: existing?.keyPath ?? "")
        _kind = State(initialValue: existing?.kind ?? .ssh)
        _accessKeyID = State(initialValue: existing?.accessKeyID ?? "")
    }

    private var isEditing: Bool { existing != nil }

    /// Save disabled until the required fields for the chosen kind are
    /// non-empty, trimmed (M15). SSH: name + username. S3: name + access
    /// key ID (the secret is optional on edit — "leave empty to keep").
    private var isSaveDisabled: Bool {
        let nameEmpty = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch kind {
        case .ssh:
            return nameEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .s3:
            return nameEmpty || accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing
                ? L10n.string("loginSets.editor.titleEdit", "Edit login")
                : L10n.string("loginSets.editor.titleNew", "New login"))
                .font(.title3.bold())

            let nameLabel = L10n.string("loginSets.editor.name", "Name")
            EditorRow(label: nameLabel) {
                TextField(nameLabel, text: $name, prompt: Text(verbatim: ""))
            }

            let kindLabel = L10n.string("loginSets.editor.kind", "Type")
            EditorRow(label: kindLabel) {
                Picker(kindLabel, selection: $kind) {
                    Text(L10n.string("loginSets.kind.ssh", "SSH")).tag(ConnectionKind.ssh)
                    Text(L10n.string("loginSets.kind.s3", "S3")).tag(ConnectionKind.s3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if kind == .ssh {
                let usernameLabel = L10n.string("loginSets.editor.username", "Username")
                EditorRow(label: usernameLabel) {
                    TextField(usernameLabel, text: $username, prompt: Text(verbatim: ""))
                }

                let authLabel = L10n.string("connection.field.authMethod", "Authentication")
                EditorRow(label: authLabel) {
                    Picker(authLabel, selection: $authChoice) {
                        Text(L10n.string("connection.auth.password", "Password"))
                            .tag(ConnectionViewModel.AuthChoice.password)
                        Text(L10n.string("connection.auth.privateKey", "SSH key"))
                            .tag(ConnectionViewModel.AuthChoice.privateKey)
                        Text(L10n.string("connection.auth.agent", "Agent"))
                            .tag(ConnectionViewModel.AuthChoice.agent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if authChoice == .password {
                    let passwordLabel = L10n.string("connection.auth.password", "Password")
                    EditorRow(label: passwordLabel) {
                        SecureField(
                            passwordLabel, text: $secret,
                            prompt: isEditing
                                ? Text(L10n.string("loginSets.editor.keepSecret", "leave empty to keep"))
                                : Text(verbatim: ""))
                    }
                } else if authChoice == .privateKey {
                    let keyPathLabel = L10n.string("connection.field.keyPath", "Key path")
                    // Managed keys eligible to fill `keyPath` (M17/T5) — only
                    // ed25519 (`KeyType.isConnectable`); RSA/ECDSA never show up
                    // here since `SSHPrivateKeyLoader` can't load them anyway.
                    let connectableKeys = Self.connectableManagedKeys()
                    EditorRow(label: keyPathLabel) {
                        HStack(spacing: 6) {
                            TextField(
                                keyPathLabel, text: $keyPath,
                                prompt: Text(L10n.string(
                                    "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519")))
                            Button("…") { showKeyImporter = true }
                                .buttonStyle(.polished)
                                .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                            // Additive (M17/T5): only appears when at least one
                            // managed key can be used to connect — no empty menu.
                            if !connectableKeys.isEmpty {
                                Menu(L10n.string("keys.picker.managed", "Managed key")) {
                                    ForEach(connectableKeys) { key in
                                        Button("\(key.name) — \(Self.shortFingerprint(key.fingerprint))") {
                                            keyPath = Self.managedKeyPath(for: key)
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                    EditorRow(label: "") {
                        Button(L10n.string("keys.picker.manage", "Manage keys…")) {
                            showSSHKeysSheet = true
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.inkTertiary)
                    }
                    let passphraseLabel = L10n.string("connection.field.passphrase", "Passphrase (optional)")
                    EditorRow(label: passphraseLabel) {
                        SecureField(
                            passphraseLabel, text: $secret,
                            prompt: isEditing
                                ? Text(L10n.string("loginSets.editor.keepSecret", "leave empty to keep"))
                                : Text(verbatim: ""))
                    }
                }
                // .agent (M10d/T4): only Name + Username apply (spec §5.2) — no
                // secret/key row, and Save-gating below stays name+username only.
            } else {
                let accessKeyLabel = L10n.string("loginSets.editor.accessKeyID", "Access Key ID")
                EditorRow(label: accessKeyLabel) {
                    TextField(accessKeyLabel, text: $accessKeyID, prompt: Text(verbatim: ""))
                }
                let secretLabel = L10n.string("loginSets.editor.secretAccessKey", "Secret Access Key")
                EditorRow(label: secretLabel) {
                    SecureField(
                        secretLabel, text: $secret,
                        prompt: isEditing
                            ? Text(L10n.string("loginSets.editor.keepSecret", "leave empty to keep"))
                            : Text(verbatim: ""))
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { onCancel() }
                    .buttonStyle(.polished)
                Button(L10n.string("common.save", "Save")) {
                    let set: LoginSet
                    switch kind {
                    case .ssh:
                        set = LoginSet(
                            id: existing?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            // Three-way mapping (M10d/T4): same Core helper as
                            // the initializer above — a two-way ternary here
                            // would silently save an agent-mode set as `.password`.
                            authKind: ConnectionViewModel.storedAuthKind(for: authChoice),
                            keyPath: authChoice == .privateKey
                                ? keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                                : nil)
                    case .s3:
                        set = LoginSet(
                            id: existing?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            username: "",
                            authKind: .password,
                            keyPath: nil,
                            kind: .s3,
                            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    onSave(set, secret.isEmpty ? nil : secret)
                }
                .buttonStyle(.polishedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaveDisabled)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                keyPath = url.path(percentEncoded: false)
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
}

private extension LoginSetEditorView {
    /// Managed ed25519 keys available to fill `keyPath` from (M17/T5).
    /// Filters on `KeyType.isConnectable` — `SSHPrivateKeyLoader` can only
    /// load ed25519, so rsa/ecdsa keys never appear in the picker menu.
    static func connectableManagedKeys() -> [ManagedKey] {
        let store = ManagedKeyStore(directory: SessionStore.defaultDirectory)
        // A key whose stored `fileName` does not address a file inside the
        // key directory has no usable path, so it is not offerable either.
        return (try? store.all())?
            .filter { $0.type.isConnectable && store.privateKeyURL(for: $0) != nil } ?? []
    }

    /// The private-key file path a managed key resolves to, in the shape
    /// `keyPath` expects (absolute, not percent-encoded). Empty — i.e. "no
    /// key" — for a key whose stored `fileName` does not address a file
    /// inside the key directory; `connectableManagedKeys` already keeps
    /// those out of the picker.
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

/// Narrower cousin of `ConnectionFormView`'s private `FormRow` (90pt label
/// column instead of 110pt, to fit this sheet's 380pt editor width).
private struct EditorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .frame(width: 90, alignment: .trailing)
            content
        }
    }
}
