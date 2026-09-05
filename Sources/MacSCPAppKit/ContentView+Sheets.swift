import AppKit
import SwiftUI
import macSCPCore

/// Sheet and alert wiring split out of `ContentView.swift`: every sheet,
/// dialog, and file importer/exporter this window owns
/// (`sheetsAndAlerts(_:)`), the two computed `Binding`s only that group
/// needs, and the four "Settings → Manage Data" presentation functions that
/// route a Settings-window entry back to this window's own sheets.
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    /// Every sheet, alert, dialog, and file importer/exporter this window owns.
    ///
    /// See `windowChrome(_:)` for why these are grouped.
    func sheetsAndAlerts<Content: View>(_ content: Content) -> some View {
        content
        // (M8a/T4) — mirrors `SessionSidebar`'s delete-confirmation pattern.
        // An idle tab bypasses this and closes immediately (`requestClose`).
        .confirmationDialog(
            L10n.string("tabs.close.title", "Close tab?"),
            isPresented: Binding(
                get: { closeRequest != nil },
                set: { isPresented in if !isPresented { closeRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("tabs.close.confirm", "Close"), role: .destructive) {
                if let tab = closeRequest {
                    closeRequest = nil
                    Task { await performClose(tab) }
                }
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                closeRequest = nil
            }
        } message: {
            Text(closeWarningText)
        }
        // Bulk close confirmation ("Close Other Tabs") — the same shape as
        // the single-tab dialog, asked ONCE for the whole group.
        // Declining cancels the entire operation rather than sparing the
        // busy tabs; see `TabCloseWarning.bulkMessage`. Tabs that are all
        // idle never reach this: `requestCloseOthers` closes them straight
        // away, exactly as `requestClose` does for one idle tab.
        .confirmationDialog(
            L10n.string("tabs.closeOthers.title", "Close other tabs?"),
            isPresented: Binding(
                get: { closeOthersRequest != nil },
                set: { isPresented in if !isPresented { closeOthersRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("tabs.close.confirm", "Close"), role: .destructive) {
                if let tab = closeOthersRequest {
                    closeOthersRequest = nil
                    Task { await performCloseOthers(of: tab) }
                }
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                closeOthersRequest = nil
            }
        } message: {
            Text(closeOthersWarningText)
        }
        // "Session is already open" (C2) — the same shape as the two close
        // dialogs above, and non-destructive: both answers do something, so
        // neither carries a role. Only what is possible is offered, per this
        // project's standing UI rule; there is nothing here to grey out.
        // Cancel is the third way out and is simply closing the query.
        .confirmationDialog(
            L10n.string("tabs.alreadyOpen.title", "This session is already open"),
            isPresented: Binding(
                get: { alreadyOpenRequest != nil },
                set: { isPresented in if !isPresented { alreadyOpenRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("tabs.alreadyOpen.jump", "Go to Existing Tab")) {
                if let request = alreadyOpenRequest {
                    alreadyOpenRequest = nil
                    jumpToOpenSession(request)
                }
            }
            Button(L10n.string("tabs.alreadyOpen.openAnyway", "Open Anyway")) {
                if let request = alreadyOpenRequest {
                    alreadyOpenRequest = nil
                    // The pane override travels with the request, so
                    // answering an "Open Terminal" this way still opens the
                    // terminal — and so does the session overview's pending
                    // snippet, so answering a "Run" this way still runs it
                    // (session overview plan, Task 3, fix round 1). Both are
                    // the same rule: this answer starts what was asked for.
                    startWithoutAsking(
                        request.stored, paneVisibility: request.paneVisibility,
                        pendingSnippet: request.pendingSnippet)
                }
            }
            Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                alreadyOpenRequest = nil
            }
        } message: {
            Text(alreadyOpenMessage)
        }
        // Export sheet (M9a/T3): one view for all three scopes, opened by
        // the sidebar's context menus via `exportSheetItem`.
        .sheet(item: $exportSheetItem) { item in
            SessionExportSheet(
                viewModel: sessionListViewModel,
                scope: item.scope,
                onExport: { options in performExport(scope: item.scope, options: options) }
            )
        }
        // Share-link sheet (M14/T5): opened from the remote pane's
        // "Share Link…" context-menu entry (an S3-only `backendFileAction`,
        // see `detail`) — never offered for SSH, since its descriptor's
        // `fileActions` is empty.
        .sheet(item: $presignedSheetItem) { item in
            PresignedURLSheet(
                itemKey: item.itemKey, provider: item.provider, settingsStore: settingsStore)
        }
        // Audit log sheet (M9b/T3): opened from the sidebar context menu,
        // available whether or not the session is currently connected — it
        // reads straight from `auditStore`, independent of any tab.
        .sheet(item: $auditLogSession) { stored in
            AuditLogSheet(session: stored, store: auditStore)
        }
        // Diagnostics panel: opened from the tab (toolbar or failed-connect
        // surface), the sidebar's session menu and the connect-error dialog,
        // all through `showDiagnostics(for:)`. Presenting it runs nothing —
        // the panel's own button does, and only it (decision of 2026-09-02).
        //
        // Every way out goes through `endDiagnostics()`, which cancels before
        // it forgets: the Close button, Esc and a click outside all set the
        // binding to nil, and the panel's own `.onDisappear` cancels a second
        // time for the dismissals SwiftUI performs without asking the binding.
        .sheet(
            item: Binding(
                get: { diagnostics.open },
                set: { if $0 == nil { endDiagnostics() } })
        ) { model in
            DiagnosticsPanel(model: model, onClose: { endDiagnostics() })
        }
        // Known-hosts sheet (M10a/T2) — same directory the connector's
        // `KnownHostsStore` uses (`makeTab`), so it reflects the same
        // TOFU state the connect flow reads from.
        .sheet(isPresented: $showKnownHostsSheet) {
            KnownHostsSheet(store: KnownHostsStore(directory: SessionStore.defaultDirectory))
        }
        // Server-certificate sheet — same directory the WebDAV connector's
        // `TrustedCertificateStore` uses, so it reflects the same TOFU state
        // the connect flow reads from.
        .sheet(isPresented: $showServerCertificatesSheet) {
            ServerCertificatesSheet(
                store: TrustedCertificateStore(directory: SessionStore.defaultDirectory))
        }
        // Login-sets sheet (M10b/T3) — shares `sessionListViewModel` (not a
        // fresh store) so the Sessions-menu/sidebar entry point and the
        // form's own local "Manage logins…" sheet (`ConnectionFormView`)
        // always show the exact same, up-to-date list.
        .sheet(isPresented: $showLoginSetsSheet, onDismiss: {
            loginSetsSheetStartsImport = false
        }) {
            LoginSetsSheet(
                sessionList: sessionListViewModel, startsImport: loginSetsSheetStartsImport)
        }
        // SSH-keys sheet (M18/T5) — standalone overlay replacement for the
        // M17 Settings tab; owns its own `ManagedKeyStore` instance the same
        // way `showKnownHostsSheet` above does for `KnownHostsStore` (there
        // is no shared observable object to pass in, unlike
        // `showLoginSetsSheet`'s `sessionListViewModel`).
        .sheet(isPresented: $showSSHKeysSheet) {
            SSHKeysSheet()
        }
        // Snippets sheet (Terminal-Snippets milestone) — same window-scoped
        // presentation as `showSSHKeysSheet` above. The sheet is the only
        // place a snippet can be added, edited or deleted, so re-reading the
        // store on dismiss is enough to keep the Terminal menu's entries
        // current.
        // `rememberedValue` is a READ and nothing else (Snippet-Probelauf,
        // Task 4): the editor's "Test" button opens the same value prompt
        // the trigger path opens, seeded from the same remembered values —
        // but a closure that returns a value cannot store one, so a
        // rehearsal cannot pre-fill the next real run. It goes through
        // `snippetVariableMemoryStore` per call rather than capturing an
        // instance, which is that property's own "constructed fresh, never
        // cached" discipline (see its doc comment).
        .sheet(isPresented: $showSnippetsSheet, onDismiss: { reloadSnippets() }) {
            SnippetsSheet(
                store: snippetStore,
                rememberedValue: { snippetID, name in
                    snippetVariableMemoryStore?.value(snippetID: snippetID, name: name)
                })
        }
        // Hidden-imports sheet (M11f/T2) — `fullImportedHosts` is the SAME
        // full inventory `refreshImportedHosts()` reads from, so the sheet's
        // "still in config"/"orphaned" split matches the sidebar exactly.
        // `onChange` re-derives `importedHosts`/`hiddenImportAliases` after
        // every unhide, so the sidebar's IMPORTED section and the menu
        // count stay live while the sheet is still open.
        .sheet(isPresented: $showHiddenImportsSheet) {
            HiddenImportsSheet(
                store: HiddenImportStore(directory: SessionStore.defaultDirectory),
                hosts: fullImportedHosts,
                onChange: { refreshImportedHosts() }
            )
        }
        .fileExporter(
            isPresented: $showExportFileExporter,
            document: exportDocument,
            contentType: .macscpSessions,
            defaultFilename: "macSCP Sessions.macscpsessions"
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
            isPresented: $showExportMissingPasswordAlert
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(String(
                format: L10n.string("export.missingPasswords %lld", "Exported without password: %lld"),
                exportMissingPasswordCount))
        }
        // Import flow (M9a/T3): file picker → probe → optional password
        // sheet → decode/plan/apply → result/error alert. No auto-connect
        // after import (spec M9a §3.5).
        .fileImporter(
            isPresented: $showImportFileImporter,
            allowedContentTypes: [.macscpSessions, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportFileSelection(result)
        }
        .sheet(isPresented: $showImportPasswordSheet, onDismiss: {
            // Covers every dismissal path, including ESC/click-outside,
            // which bypasses the sheet's own Cancel button and its
            // `onCancel` handler below (M9a final review, Finding 4) — the
            // pending ciphertext must not linger in view state either way.
            importFileData = nil
            // Planning happens HERE, not in the sheet: it may open the
            // conflict sheet, which cannot present while this one is up
            // (M19/T8). A cancelled prompt leaves `pendingImport` nil and
            // nothing runs.
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
                        // Parked for `onDismiss` above; dismissing is what
                        // clears the way for the conflict sheet.
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
        // Import from another program (Cyberduck import, 2026-09-03): the
        // folder picker for the case where the source's own folder is not
        // where it should be, and the preview sheet.
        //
        // Pressing Import DISMISSES first and applies afterwards, for the
        // same reason the password sheet does (see `showImportPasswordSheet`
        // above): planning can open the connection-conflict sheet, and
        // SwiftUI presents one sheet per view at a time.
        .fileImporter(
            isPresented: $showExternalImportFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleExternalImportFolderSelection(result)
        }
        .sheet(item: $externalImport) { model in
            ImportFromSourceSheet(model: model) {
                externalImport = nil
                Task { await applyExternalImport(model) }
            }
        }
        // Shared import conflict sheet (M19/T7) for SESSION imports — the
        // login-set import presents the same view through the same modifier
        // inside `LoginSetsSheet`, so the resumption contract documented on
        // `importConflictSheet(bridge:)` covers both flows.
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
        // Update-check result (M11b/T2, spec §4): a manual "Check for
        // Updates…" always shows one of these four outcomes; the startup
        // automatic only ever reaches this alert for `.updateAvailable`
        // (see `UpdateCheckModel.check`, which stays silent otherwise).
        //
        // The PRIMARY window presents it, and no other (Detachable Tabs
        // plan, Task 2 fix round 1): one check writes one
        // `updateModel.presentedResult`, and with the alert attached to
        // every window each open window raised its own copy of it — the
        // same duplication the what's-new sheet was gated for.
        .alert(
            updateAlertTitle,
            isPresented: Binding(
                get: { isPrimaryWindow && updateModel.presentedResult != nil },
                set: { isPresented in if !isPresented { updateModel.presentedResult = nil } })
        ) {
            if case .updateAvailable(_, _, let url) = updateModel.presentedResult {
                Button(L10n.string("update.openReleasePage", "Open Release Page")) {
                    NSWorkspace.shared.open(url)
                }
                Button(L10n.string("update.later", "Later"), role: .cancel) {}
            } else {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            }
        } message: {
            Text(updateAlertMessage)
        }
        // Marks this `ContentView` as the (only) presenter of
        // `updateModel.presentedResult` while it's actually in the view
        // hierarchy (M11b final review, Finding I2): a manual check that
        // finds nobody mounted falls back to a plain `NSAlert` instead (see
        // `UpdateCheckModel.check`/`presentFallbackAlert`). On disappear —
        // this window closing — any leftover `presentedResult` is cleared
        // too, so a check that completed just as the window went away can
    }

    /// Extracted from the `.alert(isPresented:)` call in `body` (M11d/T2 build
    /// fix): inlined there, the whole modifier chain's combined closures made
    /// the type checker time out ("unable to type-check this expression in
    /// reasonable time") — a named computed `Binding` sidesteps that without
    /// changing behavior.
    var passwordHintPresented: Binding<Bool> {
        Binding(
            get: { pendingPasswordHintRequest != nil },
            set: { isPresented in if !isPresented { pendingPasswordHintRequest = nil } })
    }

    /// What the "already open" query says (C2): the session's name, read
    /// from the request's own `StoredSession` snapshot.
    ///
    /// It says "in a tab", not "in another tab", because the tab holding
    /// the session may well be the one in front — the query is raised then
    /// too, and a message claiming otherwise would be plainly wrong on
    /// screen.
    ///
    /// Empty while no query is up: `confirmationDialog`'s `message:`
    /// builder is evaluated on every render, including renders in which
    /// `alreadyOpenRequest` has just been cleared by an answer.
    var alreadyOpenMessage: String {
        guard let name = alreadyOpenRequest?.stored.name else { return "" }
        return String(
            format: L10n.string(
                "tabs.alreadyOpen.message %@", "“%@” is already open in a tab."),
            name)
    }

    /// Same fix as `passwordHintPresented` above, for the error alert.
    var externalTerminalErrorPresented: Binding<Bool> {
        Binding(
            get: { externalTerminalErrorMessage != nil },
            set: { isPresented in if !isPresented { externalTerminalErrorMessage = nil } })
    }

    /// "Manage Snippets…" — the Terminal menu's route to the snippet
    /// management sheet, assigned to `TabCommands.showSnippets` in
    /// `wireTabCommands()`.
    ///
    /// It carried a `window?.isKeyWindow` guard until fix round 2 of the
    /// Detachable Tabs plan's Task 2, when the last one in the app was
    /// found here: `TabCommands` is per window and published as a focused
    /// scene value, so the menu can only ever reach the front window's
    /// closure — which is what that guard was asking. Re-adding it would be
    /// a second answer to a question SwiftUI has already answered, and it
    /// would also make this function unreachable from a test, since
    /// `window` is `@State` and a `ContentView` built outside a SwiftUI
    /// hierarchy reads it as `nil`.
    func presentSnippets() {
        showSnippetsSheet = true
    }

    /// Settings "Manage Data" → "Logins…": raises THIS window and opens the
    /// login-sets sheet that already lives here, instead of letting the
    /// Settings window present a second copy.
    ///
    /// Why the detour. `LoginSetsSheet` does not only edit login sets — via
    /// `SessionListViewModel.deleteLoginSet`/`applyMerge`/
    /// `applyLoginSetImport` it rewrites the SESSIONS that reference a set
    /// (username/authKind/keyPath restored onto them, `loginSetID` cleared).
    /// A Settings-side copy would need a second `SessionListViewModel` — and
    /// the view model is window scope by design, so the copy in this window
    /// would keep serving the pre-rewrite records to the sidebar. That is not
    /// only a display problem: a sheet in the Settings window is modal to
    /// THAT window only, so this window's sidebar stays clickable while it is
    /// open, and one drag onto a group (`updateSession`, which upserts the
    /// stale record) would put the dangling `loginSetID` straight back on
    /// disk. A refresh-on-dismiss cannot close that hole, because the damage
    /// is reachable before the dismissal. Routing here sidesteps all of it:
    /// one view model, and the sheet is modal to the window whose state it
    /// edits.
    ///
    /// No key-window guard (unlike `tabCommands.showLogins`): Settings is key
    /// when this fires, which is the whole point. What stands in for it is
    /// EXISTENCE of the window, nothing more.
    ///
    /// It deliberately does not ask whether the window is visible. It is about
    /// to call `makeKeyAndOrderFront`, which deminiaturizes and unhides a
    /// window that exists — so "currently on screen" was never the
    /// precondition for this action succeeding, only "there is a window". The
    /// earlier `window.isVisible` check made ⌘M (and hiding the app) look like
    /// a closed window to this code and turned the entry into the silent
    /// no-op it exists to avoid.
    func presentLoginSetsFromSettings() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        loginSetsSheetStartsImport = false
        showLoginSetsSheet = true
    }

    /// Settings "Manage Data" → "Server Certificates…": routed for a
    /// different reason than the other two, since `TrustedCertificateStore`
    /// is a stateless read-modify-write struct and no state here is derived
    /// from it.
    ///
    /// What is at stake is the trust decision, not the data. These are TOFU
    /// entries, and revoking one from a window that is NOT modal to the
    /// browser means the user can be editing trust while a WebDAV connect in
    /// this window is at (or about to raise) its certificate prompt. There is
    /// no reason to allow that interleaving, and none to reason about it
    /// later. Presenting the sheet on the window that owns the connect
    /// removes the question.
    ///
    /// The sheet is also `900×460` against the Settings window's `680×620`
    /// — a 220pt overhang, far past the 40pt the 720-wide sheets already
    /// have there. Narrowing it would break it where it is currently right;
    /// the window width is fixed for the other sections. Routing settles the
    /// geometry too, but the trust argument is the load-bearing one.
    func presentServerCertificatesFromSettings() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        showServerCertificatesSheet = true
    }

    /// Settings "Manage Data" → "Hidden Imports…": same detour, same reasons
    /// as `presentLoginSetsFromSettings()` above, one store lower in the
    /// stack. `HiddenImportsSheet` is handed this window's `fullImportedHosts`
    /// snapshot and calls back into `refreshImportedHosts()` after every
    /// unhide, which is what keeps the sidebar's IMPORTED section and the
    /// Sessions-menu count live WHILE the sheet is open. A Settings-side copy
    /// would have neither end of that wire, and both lists would drift — in
    /// both directions, since this window's own "Hide" context menu stays
    /// reachable behind a sheet that is modal to Settings.
    func presentHiddenImportsFromSettings() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        showHiddenImportsSheet = true
    }
}
