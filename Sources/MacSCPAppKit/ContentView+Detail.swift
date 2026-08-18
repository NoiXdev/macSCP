import AppKit
// Only for `NotificationCenter.publisher(for:)` inside `windowChrome(_:)`
// below — the app observes exactly one AppKit notification
// (`NSWindow.willCloseNotification`, to tell the Settings window that this
// window is gone).
import Combine
import SwiftUI
import macSCPCore

/// Detail-pane builders split out of `ContentView.swift`: the two-pane
/// split layout, the window-chrome modifier group, the composed
/// `mainContent`, the tab-identity proxy that drives its `.onChange`, the
/// connected/prompt/form detail view, and the terminal panel it embeds.
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    /// The window's two-pane layout: session sidebar on the left, tab strip
    /// plus detail on the right.
    ///
    /// Split out of `mainContent` (M20 CI fix) so the layout and the modifier
    /// chain that decorates it are two separate inference problems instead of
    /// one. Together they had grown past what the type checker will solve.
    var splitLayout: some View {
    HSplitView {
        SessionSidebar(
            viewModel: sessionListViewModel,
            importedHosts: importedHosts,
            activeSessionID: activeTab.activeStoredSessionID,
            // A running transfer no longer locks the sidebar (M8a): a
            // sidebar click opens a NEW tab instead of tearing the
            // connected one down. Only the active tab's own in-flight
            // connect/reconnect blocks interaction.
            interactionsDisabled: activeTab.isReconnecting
                || activeTab.connectionViewModel.state == .connecting,
            onSelect: { stored in connectFromSidebar(stored) },
            onDelete: { stored in
                // Return value (M11a/T3): the sidebar surfaces
                // `secretFailures` as its own red inline message, the
                // same way `LoginSetsSheet.deleteSelected()` does for
                // `deleteLoginSet`.
                let result = sessionListViewModel.delete(stored)
                for tab in tabsModel.tabs where tab.activeStoredSessionID == stored.id {
                    tab.activeStoredSessionID = nil
                    // Same release as `teardown`'s audit recorder block
                    // (M9b/T4 review, finding 1): leaving `auditRecorder`
                    // and its two sinks wired after the STORE's log file
                    // was just deleted means the next event (teardown's
                    // own `recordDisconnected()` is guaranteed to fire
                    // later) recreates `audit/<id>.json` from scratch —
                    // an unreachable, permanent orphan, since no session
                    // list entry (and no sidebar menu) points at that id
                    // anymore.
                    tab.auditRecorder = nil
                    tab.transferQueue.auditSink = nil
                    tab.session?.remote.auditSink = nil
                }
                return result
            },
            onNew: { newConnection() },
            onSelectImported: { fillFromImported($0) },
            onEdit: { stored in editStored(stored) },
            // The two terminal entries (P3c/T2). "Open Terminal" is
            // `connectFromSidebar` with one argument added, so it cannot
            // drift from what `onSelect` above does; "Open in External
            // Terminal" resolves the session and launches without macSCP
            // connecting at all.
            onOpenTerminal: { stored in openTerminalFromSidebar(stored) },
            onOpenExternalTerminal: { stored in openExternalTerminalFromSidebar(stored) },
            onExport: { scope in exportSheetItem = ExportSheetItem(scope: scope) },
            onImport: { showImportFileImporter = true },
            onShowAuditLog: { stored in auditLogSession = stored },
            // Session-row "Snippet" submenu (Terminal-Snippets, Task 7):
            // same store list the Terminal menu bar reads via
            // `tabCommands.snippetsLoad`, and the identical
            // `triggerSnippet(_:execute:)` that menu calls — safe to reuse
            // unconditionally here because the row only ever offers an
            // enabled entry when it IS the active tab (see
            // `SessionRowSnippetMenuPlan`'s doc comment).
            snippets: tabCommands.snippetsLoad.snippets,
            onRunSnippet: { snippet, execute in triggerSnippet(snippet, execute: execute) },
            onShowKnownHosts: { showKnownHostsSheet = true },
            onShowLogins: { showLoginSetsSheet = true },
            onHideImported: { host in hideImported(host) },
            onShowHiddenImports: { showHiddenImportsSheet = true },
            hiddenImportsCount: hiddenImportAliases.count,
            hiddenImportsErrorMessage: hiddenImportsErrorMessage
        )
        .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

        VStack(spacing: 0) {
            // Hidden in the pristine (single unconnected tab) state — a
            // strip with nothing to switch between would just be clutter
            // (M8a/T4 spec 2).
            if !isPristine {
                TabStripView(
                    tabs: tabsModel.tabs,
                    activeTabID: tabsModel.activeTabID,
                    onActivate: { activate($0) },
                    onClose: { requestClose($0) },
                    onAdd: { tabsModel.addTab(makeTab()) }
                )
            }
            detail
        }
        // The detail minimum must fit inside the window minimum
        // below together with the sidebar minimum (170), otherwise
        // the split view's content overflows the window and gets
        // clipped on both sides instead of shrinking.
        .frame(minWidth: isPristine ? 500 : 590, maxWidth: .infinity)
    }
    }

    /// Window-level chrome: minimum size, tint, title, the `NSWindow` handle,
    /// and the once-per-appearance setup hook.
    /// 
    /// One of three modifier groups `mainContent` composes (M20 CI fix). Each is
    /// its own generic function so the type checker solves three small problems
    /// rather than one it gives up on.
    func windowChrome<Content: View>(_ content: Content) -> some View {
        content
        // Compact form vs. browser: the minimum size depends on the window's
        // pristine state (M5c/T0, M8a/T3) — replaces the global `.frame` from
        // `MacSCPApp.swift`.
        .frame(minWidth: isPristine ? 700 : 930, minHeight: 460)
        .tint(DesignTokens.remoteBlue)
        .navigationTitle(activeTab.titleName.map { "macSCP — \($0)" } ?? "macSCP")
        .background(WindowAccessor {
            window = $0
            updateMainWindowPresence()
        })
        // Tells the Settings window when this window goes away, so its
        // "Manage Data" entries that route HERE can disable themselves
        // instead of swallowing the click (see `updateMainWindowPresence`).
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification),
            perform: handleWindowWillClose)
        // Extracted wholesale into `performWindowSetup()` (M20 CI fix).
        // This closure had grown to ~125 statements in the same inference
        // scope as the `HSplitView` above, and the type checker gave up on
        // the whole `mainContent` expression -- on the CI runner first,
        // which is slower than a dev machine and hits the per-expression
        // time budget sooner. Same failure mode and same remedy as
        // `wireMenuBarBridge()` (M11n/T2) and `handleCloseActiveTabCommand`
        // (M14/T5); this time the whole body moves rather than one closure.
        .task { performWindowSetup() }
        // Destructive confirmation for closing a tab with active transfers
    }

    /// Composed from `splitLayout` plus three modifier groups rather than one
    /// long chain -- see `windowChrome(_:)`.
    var mainContent: some View {
        lifecycleAndToolbar(sheetsAndAlerts(windowChrome(splitLayout)))
    }

    /// See the `.onChange(of: tabIDs)` call in `ContentView+Lifecycle.swift`.
    var tabIDs: [UUID] {
        tabsModel.tabs.map(\.id)
    }

    @ViewBuilder
    var detail: some View {
        let tab = activeTab
        // Captured once per `detail` evaluation (M8a T5 review, finding 3):
        // the sheet's four closures below all read THIS tab's bridge, not
        // `tabsModel.activeTab` at call time. Without this, ⌘1–9 switching
        // the active tab while the sheet is still up would make `onDismiss`/
        // `onCancel`/`onResolve` resolve the NEWLY active tab's prompt
        // instead of the one actually presenting the sheet. Invariant: the
        // sheet always talks to its presenting tab's bridge, for its whole
        // lifetime, regardless of what becomes active afterwards.
        let bridge = tab.conflictBridge
        Group {
            if let session = tab.session {
                // The ONE decision both render conditions below read (P2
                // terminal-chrome milestone, Task 3 review round 1) —
                // `SessionTab.effectivePaneVisibility`, the SAME method the
                // toolbar's `paneToggleState` reads. Neither branch below
                // reads `tab.showsFiles`/`session.terminal.isVisible`
                // directly any more: those two raw booleans can disagree
                // (hide Files, disconnect, reconnect — `showsFiles` stays
                // `false` while a fresh `TerminalPanelViewModel` also
                // starts at `isVisible == false`), and reading them
                // straight into two independent `if`s rendered NEITHER
                // half while the toolbar's Files button, which DID go
                // through `PaneVisibility`'s repair, showed itself as
                // on-and-locked. Computing `visibility` once here and
                // reading `.showsFiles`/`.showsTerminal` off it closes that
                // gap — see `effectivePaneVisibility`'s own doc comment.
                let visibility = tab.effectivePaneVisibility(
                    terminalIsVisible: session.terminal.isVisible, hasShell: activeTabSupportsShell)
                VStack(spacing: 0) {
                    VSplitView {
                        if visibility.showsFiles {
                            HSplitView {
                                BrowserPane(
                                    title: L10n.string("browser.paneLocal", "Local"),
                                    tint: DesignTokens.localAmber,
                                    softTint: DesignTokens.localSoft,
                                    viewModel: session.local,
                                    side: .local,
                                    fileSystem: session.localFS,
                                    pasteboardWriter: { item in
                                        item.kind == .file
                                            ? NSURL(fileURLWithPath: item.path)
                                            : nil
                                    },
                                    onMenuAction: { entry, selection in
                                        switch entry {
                                        case .transferToOtherPane:
                                            transferSelection(
                                                selection, from: .local, in: tab, session: session)
                                        case .transferToSession(let target):
                                            transferToSession(
                                                selection, from: .local, target: target,
                                                in: tab, session: session)
                                        case .copyPath:
                                            copyPaths(of: selection)
                                        case .openInEditor:
                                            break   // never emitted for the local pane (menu model)
                                        case .rename, .infoAndPermissions, .newFolder, .newFile, .delete:
                                            break   // handled inside BrowserPane, never forwarded
                                        case .backendFileAction:
                                            break   // never contributed on the LOCAL pane (fileActions is nil here)
                                        }
                                    },
                                    crossSessionTargets: { CrossSessionTargets.targets(excluding: tab.id, in: tabsModel.tabs) },
                                    visibleColumns: settingsStore.visibleColumns
                                )
                                .frame(minWidth: 280)

                                BrowserPane(
                                    title: L10n.string("browser.paneRemote", "Remote"),
                                    tint: DesignTokens.remoteBlue,
                                    softTint: DesignTokens.remoteSoft,
                                    viewModel: session.remote,
                                    side: .remote,
                                    onDropURLs: { urls in
                                        uploadDropped(urls, in: tab, session: session)
                                    },
                                    onOpenFile: { item in
                                        openInEditor(item, in: tab, session: session)
                                    },
                                    fileSystem: session.remoteFS,
                                    pasteboardWriter: { item in
                                        item.kind == .file
                                            ? remotePromiseProvider(for: item, in: tab, session: session)
                                            : nil
                                    },
                                    onMenuAction: { entry, selection in
                                        switch entry {
                                        case .transferToOtherPane:
                                            transferSelection(
                                                selection, from: .remote, in: tab, session: session)
                                        case .transferToSession(let target):
                                            transferToSession(
                                                selection, from: .remote, target: target,
                                                in: tab, session: session)
                                        case .openInEditor:
                                            if let item = selection.first {
                                                openInEditor(item, in: tab, session: session)
                                            }
                                        case .copyPath:
                                            copyPaths(of: selection)
                                        case .rename, .infoAndPermissions, .newFolder, .newFile, .delete:
                                            break   // handled inside BrowserPane, never forwarded
                                        case .backendFileAction(let action):
                                            // Currently the only backend-contributed action is
                                            // S3's presigned URL (M14/T5) — keyed off `action.id`
                                            // so a future second contribution doesn't need a new
                                            // `BrowserMenuEntry` case, just another `if` here.
                                            // `selection.count == 1` mirrors the menu-model gate
                                            // (`BrowserContextMenu.entries`) that only ever offers
                                            // `backendFileAction` for a single selected file.
                                            if action.id == "s3.presignedURL",
                                                selection.count == 1, let file = selection.first,
                                                let provider = session.remoteFS as? PresignedURLProvider
                                            {
                                                // Same "no leading slash" convention
                                                // `S3FileSystem.objectKey(forPath:)` uses
                                                // internally: normalize first (collapses any
                                                // repeated slashes), then drop the single
                                                // leading one.
                                                let normalizedPath = RemotePath.normalizedAbsolute(file.path)
                                                let key = normalizedPath == "/" ? "" : String(normalizedPath.dropFirst())
                                                presignedSheetItem = PresignedSheetItem(
                                                    itemKey: key, provider: provider)
                                            }
                                        }
                                    },
                                    crossSessionTargets: { CrossSessionTargets.targets(excluding: tab.id, in: tabsModel.tabs) },
                                    fileActions: {
                                        BackendDescriptor.descriptor(for: tab.connectionViewModel.kind)
                                            .fileActions
                                    },
                                    visibleColumns: settingsStore.visibleColumns
                                )
                                .frame(minWidth: 280)
                            }
                            .frame(minHeight: 200)
                            .layoutPriority(1)
                        }

                        if visibility.showsTerminal {
                            terminalPanel(session)
                                .frame(minHeight: 120, idealHeight: 220)
                        }
                    }

                    // Resume banner: displayed when the ACTIVE tab has interrupted
                    // transfers (M5d/T4). Clicking "Resume" re-enqueues them with
                    // that tab's file systems and resume semantics enabled.
                    //
                    // No capability gate needed here (M12/T7b): the banner is
                    // governed by `ProtocolCapabilities.resumeMode`, but an
                    // S3 session can never populate `hasInterrupted` in the
                    // first place today — `S3FileSystem`'s read/write both
                    // throw `.protocolError` immediately (deferred to M13),
                    // so no S3 transfer can ever reach "interrupted" (that
                    // requires a transfer to have started and been cut off
                    // mid-flight). Gating this now would be dead code; M13
                    // is where `resumeMode == .rangeGet`'s actual mechanics
                    // (distinct from SSH's `.append`) need to be wired here.
                    if tab.transferQueue.hasInterrupted {
                        HStack {
                            Text(L10n.string(
                                "transfers.interrupted.banner",
                                "Interrupted transfers can be resumed."))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.string("transfers.interrupted.resume", "Resume")) {
                                tab.transferQueue.retryInterrupted(
                                    source: session.localFS,
                                    destination: session.remoteFS)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }

                    // Edit-open error (M5e/T4): subtle inline message, matching
                    // the resume banner's placement/styling above. Dismissible;
                    // cleared automatically on the next successful editor open.
                    if let editErrorMessage = tab.editErrorMessage {
                        HStack {
                            Text(editErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            Spacer()
                            // Icon-only hit target: the banner text is the
                            // error message and never says that the ✕ dismisses
                            // it, so the glyph needs its own hint — the same
                            // one the identical dismiss button in
                            // `FileSearchBar` carries.
                            Button {
                                tab.editErrorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(L10n.string("common.close", "Close"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }

                    if tab.transfersPanelVisible {
                        TransferQueueBar(viewModel: tab.transferQueue)
                    }
                }
                .onChange(of: tab.transferQueue.items.count) { oldCount, newCount in
                    // A newly enqueued transfer reveals the bar (M11o) — the
                    // pre-M11o auto-appear behavior, now gated by the per-tab
                    // visibility flag. Only an INCREASE reveals; clearing or
                    // finishing items never force-hides.
                    if newCount > oldCount {
                        tab.transfersPanelVisible = true
                    }
                }
                .task(id: session.id) {
                    // Auto-refresh loop (M9c): lives inside the tab's `.id` identity,
                    // so switching tabs (or disconnecting) cancels it and the next
                    // active tab starts its own. Keyed on the SESSION id as a
                    // defensive guard (final review): even a hypothetical
                    // synchronous session swap without a branch flip would
                    // restart the loop against the new session.
                    // Reads the settings fresh every lap
                    // so changes apply without restart; skipped laps just sleep on.
                    while !Task.isCancelled {
                        let seconds = settingsStore.autoRefreshIntervalSeconds
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled, settingsStore.autoRefreshEnabled else { continue }
                        await session.remote.refreshQuietly()
                    }
                }
                .transferConflictSheet(bridge: bridge)
            } else if let candidate = tab.certificateBridge.currentCandidate {
                // Certificate trust prompt (M21/T10): the same "form is
                // hidden entirely while the trust decision is pending" shape
                // `ConnectionFormView.hostKeyPromptView` uses for the SSH
                // case, just driven by `tab.certificateBridge` instead of
                // `viewModel.hostKeyPrompt` — see that bridge's own doc
                // comment for why this state lives on the tab rather than on
                // `tab.connectionViewModel`.
                CertificatePromptView(
                    candidate: candidate,
                    onTrust: { tab.certificateBridge.resolve(trust: true) },
                    onCancel: { tab.certificateBridge.resolve(trust: false) }
                )
                .padding(24)
                .frame(minWidth: 420, maxWidth: 460)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                // Align the form to the top instead of centering it vertically
                // (user feedback 2026-07-10, M5c/T0) — otherwise the compact
                // window has a lot of empty space below the content.
                ConnectionFormView(
                    viewModel: tab.connectionViewModel,
                    groups: sessionListViewModel.groups,
                    sessionList: sessionListViewModel,
                    resolveLoginSetForSubmit: {
                        let form = tab.connectionViewModel
                        let refusals = sessionListViewModel.prepareForSubmit(form: form)
                        for refusal in refusals {
                            form.showFailure(
                                message: SubmitRefusalText.message(for: refusal), field: refusal.field)
                        }
                        return refusals.isEmpty
                    },
                    onSaveEdited: { stored, secret in
                        var stored = stored
                        var effectiveSecret = secret
                        if let newSetID = maybeCreateNewLoginSet(
                            from: tab.connectionViewModel, editedSession: stored
                        ) {
                            // The secret now lives under the new set's id —
                            // don't also duplicate it into the session's own
                            // keychain slot.
                            stored.loginSetID = newSetID
                            effectiveSecret = nil
                        } else if stored.loginSetID != nil {
                            // Set mode: the set already owns the secret.
                            effectiveSecret = nil
                        }
                        // Jump secret (M10c/T3): `stored.jump` was already
                        // built by `validateForEditSave()` (Set mode carries
                        // only `loginSetID`, Manual carries the manual
                        // fields + the EXISTING `secretID` it remembered) --
                        // `updateSession` itself gates on `jump.loginSetID
                        // == nil` before writing this, so passing it
                        // unconditionally is safe in Set/Manual mode.
                        //
                        // Session mode (M11a/T3): `jumpPassword` was just
                        // filled with the REFERENCED session's own resolved
                        // secret (`SessionListViewModel.resolveJumpSession`,
                        // spec §4a) --
                        // passing that through here would copy it into the
                        // jump's supposedly UNUSED `secretID` slot (spec §1:
                        // "ungenutzt") on every save, not just the
                        // manual→session switch `cleanOrphanedJumpSlot`
                        // guards against. `nil` keeps that slot untouched.
                        sessionListViewModel.updateSession(
                            stored, newSecret: effectiveSecret,
                            jumpSecret: tab.connectionViewModel.jumpSourceMode == .session
                                ? nil : tab.connectionViewModel.jumpPassword)
                        tab.connectionViewModel.endEditing()
                    },
                    onCancelEdit: { tab.connectionViewModel.endEditing() },
                    onConnectEdited: { stored in
                        // onSaveEdited may have rewired loginSetID (e.g. "save as new
                        // login set") on its own local copy of `stored`, which never
                        // reaches this closure's parameter. `updateSession` inside
                        // onSaveEdited already reloaded the list synchronously, so look
                        // up the just-persisted session by id and connect with that.
                        let current = sessionListViewModel.sessions.first(where: { $0.id == stored.id }) ?? stored
                        connect(in: tab, stored: current)
                    }
                ) { fs in
                    // Remote home start (M9d): resolved once per connect,
                    // right before the browser session is built, so the
                    // remote pane opens where the user actually lands after
                    // login instead of hardcoded "/". A lookup failure
                    // (older SFTP servers, permission quirks) falls back to
                    // "/" rather than failing the connect.
                    // Accept only usable absolute paths (M9d final review): an
                    // empty/relative realpath result would land the pane in
                    // .failed where "/" always worked.
                    let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
                    let home = resolved.hasPrefix("/") ? resolved : "/"
                    startSession(in: tab, with: fs, startPath: home)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                // Plaintext-transport confirmation (M21/T10): asked by the
                // connector closure (`ContentView.makeTab`) before it ever
                // dispatches a connect whose transport is `.optionalTLS` and
                // whose endpoint is `http://`. Declining resolves the
                // waiting `confirmPlaintext()` call with `false`, which
                // throws `RemoteFSError.connectionFailed` — the connect
                // never happens (see that closure's own comment).
                .confirmationDialog(
                    L10n.string("transport.plaintext.title", "Send credentials unencrypted?"),
                    isPresented: Binding(
                        get: { tab.plaintextConfirmationPending },
                        set: { _ in /* answered exclusively through the buttons below */ }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                        tab.resolvePlaintextConfirmation(confirmed: false)
                    }
                    Button(L10n.string("connection.connect", "Connect"), role: .destructive) {
                        tab.resolvePlaintextConfirmation(confirmed: true)
                    }
                } message: {
                    Text(L10n.string(
                        "transport.plaintext.body",
                        "This connection uses http://, so the password travels in the clear. "
                            + "Use https:// where the server offers it."))
                }
            }
        }
        // Load-bearing identity (M8a/T3 review): forces this whole per-tab
        // subtree — the connected browser layout AND the form branch — to
        // remount on every tab switch. Without it, two connected tabs would
        // share the same SwiftUI view identities: `SSHTerminalView` binds
        // `onOutput` and replays its buffer only in `makeNSView` --
        // `updateNSView` touches font and cursor style and nothing else --
        // so a tab switch would keep rendering/typing into the OLD tab's
        // shell instead of rebinding to the new one. `BrowserPane`/
        // `ConnectionFormView` `@State` would leak across tabs the same way.
        .id(tab.id)
    }

    /// Panel content: a narrow header (host name + snippet picker, Task 8)
    /// above the terminal itself, which shows the running shell or an
    /// ended/empty state. `SSHTerminalView` is deliberately mounted only
    /// while the shell is active, so `onOutput` binds fresh on every reopen —
    /// and, since Task 9, so is the right-click menu it carries: the
    /// surface only offers snippets while there is a shell to send them to.
    ///
    /// The header is drawn for every `state` case below, INCLUDING
    /// `.closed` — deliberately no second, narrower check here. Whether
    /// there is a terminal to show a header for is already decided once, by
    /// the caller in `detail` (`if visibility.showsTerminal { terminalPanel(session) … }`,
    /// `visibility` being `SessionTab.effectivePaneVisibility` — see that
    /// method's doc comment for why this reads it instead of
    /// `session.terminal.isVisible` directly);
    /// this function only ever runs under that same condition, so reusing
    /// it (by drawing the header unconditionally inside here) cannot drift
    /// from it the way a second, independent check inside this `switch`
    /// could. `.closed` while `isVisible` is `true` does not actually occur
    /// today — `TerminalPanelViewModel.toggle()` (which every reveal path
    /// goes through, `ContentView.triggerSnippet` included) drives `state`
    /// out of `.closed` in the same synchronous step
    /// that sets `isVisible = true`, before SwiftUI gets a chance to render
    /// the in-between state — but this function does not rely on that: it
    /// would still be correct (header shown, blank content below it) even if
    /// that ever changed. A shell-less backend (S3/WebDAV) never reaches
    /// this function at all — `toggleTerminal`/`triggerSnippet` both refuse
    /// to set `isVisible` for one (see `ContentView.presentTerminalUnavailable`)
    /// — so its absence here follows the identical rule, not a special case.
    @ViewBuilder
    func terminalPanel(_ session: BrowserSession) -> some View {
        VStack(spacing: 0) {
            TerminalPanelHeader(
                hostTitle: activeTab.displayTitle,
                snippets: tabCommands.snippetsLoad.snippets,
                supportsShell: activeTabSupportsShell,
                onRunSnippet: { snippet, execute in triggerSnippet(snippet, execute: execute) }
            )
            ZStack {
                Color(nsColor: DesignTokens.terminalBackground)
                switch session.terminal.state {
                case .running, .opening:
                    SSHTerminalView(
                        viewModel: session.terminal,
                        settingsStore: settingsStore,
                        // Same list and the same two structural literals the
                        // header above passes (see `TerminalPanelHeader`),
                        // minus its search narrowing: a right-click is not a
                        // search, so the right-click menu always offers all
                        // of them.
                        snippetMenu: SnippetMenuModel.build(
                            snippets: tabCommands.snippetsLoad.snippets,
                            isConnected: true,
                            supportsShell: activeTabSupportsShell),
                        onRunSnippet: { snippet, execute in
                            triggerSnippet(snippet, execute: execute)
                        })
                        // Same inset `TerminalPanelHeader` and the `.ended`
                        // block below use (Terminal-Fassung P2, Task 1) — the
                        // terminal surface previously had none at all and sat
                        // flush against the panel edge; all three now share
                        // `DesignTokens`' one pair instead of each carrying
                        // its own literal (see that enum's doc comment).
                        .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                        .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
                case .ended(let message):
                    VStack(spacing: 8) {
                        Text(message ?? L10n.string("terminal.ended", "Shell ended."))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                        Button(L10n.string("terminal.reopen", "Reopen")) { session.terminal.openIfNeeded() }
                    }
                    // Already 14/8 before the rest of the panel was unified
                    // onto it (Terminal-Fassung P2, Task 1) — now routed
                    // through the same constants as the other two readers
                    // rather than kept as its own matching-by-coincidence
                    // literals. Rendered result unchanged.
                    .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
                    .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                case .closed:
                    Color.clear
                }
            }
        }
        // Mockup: the terminal strip carries a hairline top border — the top
        // of the WHOLE strip (header + terminal), same boundary against the
        // browser panes above it as before the header existed.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
}

/// The terminal panel's header row (Terminal-Snippets milestone, Task 8):
/// the connected tab's display name on the left, a snippet picker on the
/// right. Exists solely because the picker's popover needs somewhere to
/// open FROM — `terminalPanel(_:)` decides WHEN this view is shown at all
/// (see that function's own doc comment); this view only draws it.
///
/// Untested: this is view code with no dedicated view-testing tool in this
/// project (the same boundary `SnippetMenuItems` and `SnippetsSheet`
/// already document) — no test renders this body, opens the popover, or
/// clicks the button. What IS tested is the one new decision it makes
/// beyond what `SnippetMenuItems`/`SnippetMenuModel` already own: which
/// snippets the search narrows the list to — `TerminalSnippetSearch`, below.
private struct TerminalPanelHeader: View {
    /// The active tab's display name (`SessionTab.displayTitle`) — the same
    /// text the window title and tab strip already show for this tab.
    let hostTitle: String
    /// The window's saved snippets, in store order — the same list
    /// `MacSCPApp`'s Terminal menu (Task 6) and `SessionSidebar`'s row
    /// submenu (Task 7) read. This view narrows it by search text (see
    /// `TerminalSnippetSearch`) and hands the NARROWED list to
    /// `SnippetMenuModel.build` — grouping, untagged-last, and the disabled
    /// reason all stay derived from `SnippetMenuModel`, never re-decided
    /// here.
    let snippets: [Snippet]
    /// Whether the active tab's backend has a shell at all (S3/WebDAV never
    /// do). There is no separate `isConnected` parameter: this view only
    /// ever exists while `terminalPanel(_:)` is on screen, which only
    /// happens for a tab that IS connected (see that function's doc
    /// comment), so `SnippetMenuModel.build` below is called with
    /// `isConnected: true` as a structural fact — the same literal
    /// `SessionRowSnippetMenuPlan.build`'s `.active` case passes for the
    /// identical reason.
    let supportsShell: Bool
    let onRunSnippet: (Snippet, Bool) -> Void

    @State private var isSnippetPopoverPresented = false
    @State private var searchText = ""
    @State private var searchIsRegex = false
    /// Highlight only — no action fires from a click (P3d, Task 3): the
    /// spec's precondition for arrow-key navigation of the flat list, which
    /// this phase does not yet wire, but which must not be foreclosed by a
    /// click that already does something.
    @State private var selectedSnippetID: Snippet.ID?
    /// The row currently under the pointer, if any — drives
    /// `commandPreviewLine(for:)`. Distinct from `previewPinnedRow`: this
    /// one clears the instant the pointer leaves the row, the other is a
    /// deliberate right-click choice that stays until something replaces it.
    @State private var hoveredRow: SnippetListPlan.Row?
    /// Set by a row's "Preview" context-menu action. Read only when
    /// `hoveredRow` is `nil`, so a live hover always wins — see
    /// `commandPreviewLine(for:)`'s call site.
    @State private var previewPinnedRow: SnippetListPlan.Row?
    /// Non-`nil` while the P3d Task 2 action window is up for this snippet
    /// (double-click on a row). `.sheet(item:)` below owns dismissal.
    @State private var actionSheetSnippet: Snippet?

    var body: some View {
        HStack(spacing: 8) {
            Text(hostTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                isSnippetPopoverPresented = true
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
            .help(L10n.string("terminal.snippets.button", "Snippets"))
            .popover(isPresented: $isSnippetPopoverPresented) {
                snippetPopover
            }
        }
        // Moves from this header's own former 12/6 to the panel's existing
        // 14/8 rhythm (Terminal-Fassung P2, Task 1, per
        // docs/superpowers/specs/2026-08-10-snippets-runde-2-design.md,
        // "P2 — Terminal-Fassung") — a DELIBERATE visual change (this row
        // gets two points wider/taller), not a regression to revert. Reads
        // the same shared `DesignTokens` constants as the terminal surface
        // and the `.ended` block below, so this row cannot drift apart from
        // them again the way it did before this change.
        .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
        .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
        .background(Color(nsColor: DesignTokens.terminalBackground))
    }

    /// The flat-list popover (P3d, Task 3) — the fourth trigger surface,
    /// and the only one of the four that is NOT a real `NSMenu`; see this
    /// file's own top-level doc comment and the P3d plan for why the other
    /// three (`MacSCPApp`'s menu bar, `SSHTerminalView`'s right-click,
    /// `SessionSidebar`'s host context menu) stay on `SnippetMenuItems`
    /// unchanged. Renders `SnippetListPlan.build(model:)` — Task 1's
    /// projection — instead: one row per snippet (never two, even for a
    /// two-tag snippet — see that type's own doc comment), grouped under
    /// the same tag headings the menus use.
    ///
    /// Three ways to act on a row, deliberately different speeds (the P3d
    /// design doc's own framing): right-click for the fast path (Execute /
    /// Insert / Preview, one gesture, no window), double-click for the
    /// Task 2 action window (deliberate, name + command + three buttons),
    /// hover for a look with no gesture at all. A single click does only
    /// ONE thing — select — never an action; see `selectedSnippetID`'s doc
    /// comment for why that precondition matters even though this phase
    /// does not yet wire arrow-key navigation on top of it.
    ///
    /// Untested, like `TerminalPanelHeader.body` itself: this project has
    /// no SwiftUI rendering harness (`TerminalPanelHeader`'s own doc
    /// comment states the boundary already). Nothing here — the gesture
    /// split between single/double click, the context menu's three
    /// entries, the hover line's content, row selection highlighting — can
    /// be observed by a test; only `SnippetListPlan` (Task 1, tested in
    /// `macSCPCoreTests`) and `TerminalSnippetSearch` (tested below) are.
    @ViewBuilder
    private var snippetPopover: some View {
        let (predicate, searchError) = sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)
        let visibleSnippets = TerminalSnippetSearch.matching(snippets, predicate: predicate)
        let model = SnippetMenuModel.build(
            snippets: visibleSnippets, isConnected: true, supportsShell: supportsShell)
        let sections = SnippetListPlan.build(model: model)
        VStack(alignment: .leading, spacing: 8) {
            SheetSearchField(text: $searchText, isRegex: $searchIsRegex, errorText: searchError)
            if sections.isEmpty {
                Text(searchText.isEmpty
                    ? L10n.string("snippets.empty", "No snippets yet.")
                    : L10n.string("snippets.noMatches", "No matches."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            if let tag = section.tag {
                                Text(tag)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            ForEach(section.rows) { row in
                                snippetRow(row)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
                // The hover line (P3d design doc): a FIXED row, not a
                // tooltip — a tooltip is delayed, truncates, and cannot be
                // read while the pointer is still moving toward it. Always
                // present (never conditionally inserted) so the popover's
                // height is the same whether or not a row is currently
                // hovered/pinned — a line that appeared and disappeared
                // would resize the popover on every hover change, which
                // reads as jitter, not information. `lineLimit(1)` +
                // `.truncationMode(.tail)` were chosen over wrapping for
                // the same reason: wrapping would make the popover's
                // height depend on which snippet is hovered, exactly the
                // instability the fixed line exists to avoid.
                commandPreviewLine
            }
        }
        .padding(12)
        .frame(width: 280)
        .sheet(item: $actionSheetSnippet) { snippet in
            // Task 2's action window, reused verbatim. Insert/Execute both
            // dismiss the sheet AND the popover itself — matching what a
            // right-click Insert/Execute already does below, so a snippet
            // triggered via either path leaves the header in the same
            // state afterward.
            SnippetActionSheet(
                snippet: snippet,
                onInsert: {
                    onRunSnippet(snippet, false)
                    actionSheetSnippet = nil
                    isSnippetPopoverPresented = false
                },
                onExecute: {
                    onRunSnippet(snippet, true)
                    actionSheetSnippet = nil
                    isSnippetPopoverPresented = false
                },
                onCancel: { actionSheetSnippet = nil }
            )
        }
    }

    /// One row of the flat list. Single click selects only (see
    /// `selectedSnippetID`'s doc comment); double-click opens the Task 2
    /// action window, gated on `!row.isDisabled` the same way the menu
    /// surfaces gate their own per-snippet `Menu` — a disabled row still
    /// SHOWS what it would do (name, and its command via hover/Preview),
    /// it just cannot be made to do it, matching `SnippetMenuItems`'
    /// `.disabled(entry.isDisabled)` on its per-snippet `Menu`.
    ///
    /// The double/single-click split uses SwiftUI's documented
    /// `exclusively(before:)` composition (`TapGesture(count: 2)` tried
    /// first) rather than two independent `.onTapGesture` modifiers: the
    /// latter fires the count-1 gesture immediately, before SwiftUI can
    /// know a second tap is coming, so a double-click would ALSO select
    /// first and open the action window a moment later on top of that —
    /// visible flicker, and a spurious selection change on every
    /// double-click. `exclusively` makes double-click win outright when it
    /// occurs, at the cost of every single click waiting out the standard
    /// double-click interval before selecting — an accepted trade against
    /// that flicker, not a limit anyone measured against.
    @ViewBuilder
    private func snippetRow(_ row: SnippetListPlan.Row) -> some View {
        Text(row.displayName)
            .font(.system(size: 12))
            .foregroundStyle(
                Color(nsColor: DesignTokens.terminalText)
                    .opacity(row.isDisabled ? 0.45 : 1))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                selectedSnippetID == row.snippet.id
                    ? DesignTokens.remoteSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredRow = row
                } else if hoveredRow?.id == row.id {
                    hoveredRow = nil
                }
            }
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        // A double-click always selects, same as a single
                        // click — it only additionally opens the action
                        // window, and only when the row's actions are
                        // available at all.
                        selectedSnippetID = row.snippet.id
                        guard !row.isDisabled else { return }
                        actionSheetSnippet = row.snippet
                    }
                    .exclusively(before: TapGesture(count: 1).onEnded {
                        selectedSnippetID = row.snippet.id
                    })
            )
            .contextMenu {
                if !row.isDisabled {
                    Button(L10n.string("menu.snippets.execute", "Execute")) {
                        onRunSnippet(row.snippet, true)
                        isSnippetPopoverPresented = false
                    }
                    Button(L10n.string("menu.snippets.insert", "Insert")) {
                        onRunSnippet(row.snippet, false)
                        isSnippetPopoverPresented = false
                    }
                }
                // Preview stays offered even for a disabled row (no
                // connection / no shell): it only reveals the command
                // text, the same thing hovering already does, so there is
                // nothing here a disabled row needs protecting from.
                Button(L10n.string("snippets.list.preview", "Preview")) {
                    previewPinnedRow = row
                }
            }
    }

    /// The fixed bottom line `snippetPopover` reserves for the hovered (or
    /// right-click-"Preview"-pinned) row's command. A live hover always
    /// wins over a pin — moving the pointer over a different row updates
    /// the line immediately, the same way a real tooltip would track the
    /// pointer, and the pin only matters again once the pointer leaves the
    /// list entirely (`onHover`'s `else` branch above only clears
    /// `hoveredRow`, never `previewPinnedRow`).
    private var commandPreviewLine: some View {
        Text(SnippetPreviewLine.row(hovered: hoveredRow, pinned: previewPinnedRow)?.snippet.command
            ?? L10n.string("snippets.list.hoverHint", "Point at a snippet to see its command."))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

/// Narrows the terminal header popover's snippet list to a search predicate
/// BEFORE handing the result to `SnippetMenuModel.build` (Task 8) — pulled
/// out of `TerminalPanelHeader` so it is a plain function
/// `Tests/macSCPAppKitTests/` can call directly. This is the one new
/// decision the popover makes that `SnippetMenuItemsTests`/
/// `SnippetMenuModelTests` do not already cover; everything downstream of
/// its result (grouping, untagged-last, disabled reason) is
/// `SnippetMenuModel`'s, unchanged.
///
/// Matches on "name command" — the same two fields `SnippetsSheet`'s own
/// inline search filters on — so a snippet findable in the management sheet
/// is findable here too.
enum TerminalSnippetSearch {
    static func matching(
        _ snippets: [Snippet], predicate: FileSearch.FileSearchPredicate
    ) -> [Snippet] {
        snippets.filter { predicate.matches("\($0.name) \($0.command)") }
    }
}

/// Chooses which row's command the popover's fixed bottom line shows (P3d,
/// Task 3) — pulled out of `TerminalPanelHeader` for the same reason
/// `TerminalSnippetSearch` above was in Task 8: a plain function
/// `Tests/macSCPAppKitTests/` can call directly, rather than a decision
/// left inline in the view body where nothing can observe it.
///
/// A live hover (`hovered`) always wins over a right-click "Preview" pin
/// (`pinned`): moving the pointer onto a different row should update the
/// line immediately, the same way a real tooltip would track the pointer,
/// regardless of which row was pinned earlier. The pin only surfaces again
/// once the pointer leaves the list entirely and `hovered` goes back to
/// `nil` — see `TerminalPanelHeader.snippetRow(_:)`'s `onHover` closure,
/// which clears `hoveredRow` but never `previewPinnedRow`.
enum SnippetPreviewLine {
    static func row(
        hovered: SnippetListPlan.Row?, pinned: SnippetListPlan.Row?
    ) -> SnippetListPlan.Row? {
        hovered ?? pinned
    }
}
