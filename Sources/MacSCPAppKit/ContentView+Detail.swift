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
    ///
    /// Also mounts one `LivenessProbeRunner` per tab `LivenessProbeCoverage
    /// .tabsToProbe` selects (connection-liveness plan, Task 4, fix rounds
    /// 1 through 3) — deliberately here and not inside `detail`, which
    /// SwiftUI mounts only for the active tab; see `LivenessProbeRunner`'s
    /// own doc comment for why a background tab needs its probe running
    /// too, and `LivenessProbeCoverage`'s own doc comment for why WHICH
    /// tabs get probed is a question answered by that type, not decided
    /// inline here.
    var splitLayout: some View {
    HSplitView {
        SessionSidebar(
            viewModel: sessionListViewModel,
            importedHosts: importedHosts,
            activeSessionID: activeTab.activeStoredSessionID,
            // A running transfer no longer locks the sidebar (M8a): a
            // sidebar connect opens a NEW tab instead of tearing the
            // connected one down. Only the active tab's own in-flight
            // connect/reconnect blocks interaction.
            interactionsDisabled: activeTab.isReconnecting
                || activeTab.connectionViewModel.state == .connecting,
            // The sidebar's whole ability to reach a host, as three values
            // it can hold and hand on but not fire: `apply`, the only code
            // that runs one, is `fileprivate` to the file declaring the
            // effect types, and the sidebar's own way in states an input
            // instead of picking an activation. See
            // `SessionRowConnectEffect` for what that does and does not
            // buy. The two terminal effects sit beside the entries they
            // belong to rather than here.
            onConnect: SessionRowConnectEffect { stored in connectFromSidebar(stored) },
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
            // `connectFromSidebar` with one argument filled in — both are a
            // single line onto `sidebarStart`, so it cannot drift from what
            // the sidebar's own connect does, including the already-open
            // query that start raises (C2); "Open in External
            // Terminal" resolves the session and launches without macSCP
            // connecting at all — the program it launches is what dials.
            // Both are effect values for the same reason `onConnect` is: a
            // stray click reaching either one reaches the user's host.
            onOpenTerminal: SessionRowTerminalEffect { stored in openTerminalFromSidebar(stored) },
            onOpenExternalTerminal: SessionRowExternalTerminalEffect { stored in openExternalTerminalFromSidebar(stored) },
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
            hiddenImportsErrorMessage: hiddenImportsErrorMessage,
            // E1, read here rather than in the sidebar: the setting is a
            // fact about what the window offers, and the sidebar reacts to
            // the value without knowing where it comes from.
            showsTagFilterBar: settingsStore.sidebarTagFilterEnabled
        )
        // Opens at the width this window was last left at and can be
        // dragged anywhere inside `SettingsStore.sidebarWidthRange` — see
        // that range for where its two ends come from. The old hardcoded
        // ceiling of 260 was the whole complaint: the divider simply
        // stopped there, and nothing about the width survived a relaunch.
        .frame(
            minWidth: CGFloat(SettingsStore.sidebarWidthRange.lowerBound),
            idealWidth: sidebarOpeningWidth,
            maxWidth: CGFloat(SettingsStore.sidebarWidthRange.upperBound))
        // Publishes the width the split view actually gave the sidebar, so
        // the recorder below sees it together with the container it sits in.
        // A background changes nothing about the sidebar's own size.
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarMeasuredWidthKey.self, value: proxy.size.width)
            }
        }

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
                    onAdd: { tabsModel.addTab(makeTab()) },
                    menuEntries: { tabMenuEntries(for: $0) },
                    onMenuEntry: { tab, entry in handleTabMenuEntry(entry, for: tab) },
                    onReorder: { draggedID, target in
                        tabsModel.move(tabID: draggedID, onto: target.id)
                    }
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
    // One probe per tab `LivenessProbeCoverage.tabsToProbe` selects (Task
    // 4, fix rounds 1 through 3) — see that type's own doc comment for why
    // the coverage decision is asked of it rather than made here. Zero-size
    // and non-hit-testing, so this changes nothing about layout or input;
    // `ForEach` drops a tab's runner (cancelling its `.task`) the instant
    // that tab leaves the selected set.
    .background {
        ForEach(LivenessProbeCoverage.tabsToProbe(from: tabsModel.tabs)) { tab in
            LivenessProbeRunner(
                tab: tab, settingsStore: settingsStore,
                onGiveUp: { await handleLivenessGiveUp($0) })
        }
    }
    // Connect-attempt liveness mirror (Task 6): one per tab, not only the
    // active one — see `ConnectAttemptLivenessMirror`'s own doc comment for
    // why. Zero-size and non-hit-testing, the same shape as the probe
    // runners above; a second `.background` layer composes with the first
    // rather than replacing it.
    .background {
        ForEach(tabsModel.tabs) { tab in
            ConnectAttemptLivenessMirror(tab: tab)
        }
    }
    // Unattended reconnect (Task 7): one per tab, for the same reason the
    // two `.background` layers above are — a tab whose connection dropped
    // while it was NOT the one on screen is the tab that most needs this.
    // Same zero-size, non-hit-testing shape; a third `.background` layer
    // composes with the two above rather than replacing either.
    .background {
        ForEach(tabsModel.tabs) { tab in
            ReconnectRunner(
                tab: tab, settingsStore: settingsStore,
                targetIsKnown: { reconnectTarget(for: $0) != nil },
                onAttempt: { reconnect($0) })
        }
    }
    // Writes the dragged sidebar width back to `SettingsStore` — see
    // `SidebarWidthRecorder` for what it takes to tell a drag apart from
    // the split view rearranging itself. The sidebar's measured width
    // arrives as a preference, the container's width from the reader here,
    // so both describe the same layout. Zero-size and non-hit-testing, the
    // same shape as the three `.background` layers above; a fourth layer
    // composes with them rather than replacing any.
    .backgroundPreferenceValue(SidebarMeasuredWidthKey.self) { measuredSidebarWidth in
        GeometryReader { proxy in
            SidebarWidthRecorder(
                settingsStore: settingsStore,
                sample: SidebarWidthSample(
                    container: proxy.size.width, sidebar: measuredSidebarWidth))
        }
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
                                        case .rename, .infoAndPermissions, .newFolder, .newFile,
                                            .delete, .computeChecksum:
                                            break   // handled inside BrowserPane, never forwarded
                                        case .backendFileAction:
                                            break   // never contributed on the LOCAL pane (fileActions is nil here)
                                        }
                                    },
                                    crossSessionTargets: { CrossSessionTargets.targets(excluding: tab.id, in: tabsModel.tabs) },
                                    visibleColumns: settingsStore.visibleColumns,
                                    checksumAlgorithm: settingsStore.checksumAlgorithm,
                                    // "local" is not a `ConnectionKind`, so
                                    // there is no descriptor and no capability
                                    // flag to read here — the local file
                                    // system is asked instead, which for it is
                                    // the same question. See
                                    // `ChecksumAvailability`.
                                    supportsChecksum: ChecksumAvailability.isOffered(
                                        byLocalFileSystem: session.localFS)
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
                                        case .rename, .infoAndPermissions, .newFolder, .newFile,
                                            .delete, .computeChecksum:
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
                                    visibleColumns: settingsStore.visibleColumns,
                                    checksumAlgorithm: settingsStore.checksumAlgorithm,
                                    // The capability, not the kind. Every
                                    // backend conforms to the checksum
                                    // protocol — WebDAV does so in order to
                                    // SAY it has none — so only the flag can
                                    // tell an offer from an empty one.
                                    supportsChecksum: ChecksumAvailability.isOffered(
                                        for: tab.connectionViewModel.kind)
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
                // The single "no session yet" surface (connection-liveness
                // plan, Task 6): `ConnectionSurfacePlan.surface` decides
                // between the ordinary form and "Connecting…" — see that
                // type's own doc comment for why a pending host-key prompt
                // forces the form back regardless of `tab.liveness`. `Group`
                // keeps the plaintext-confirmation dialog below attached to
                // BOTH branches: the connector closure in `ContentView
                // .makeTab` can raise that confirmation WHILE `.connecting`
                // is showing (it asks before dispatching the dial, which
                // runs after `ConnectionViewModel.connect()` has already
                // set `state = .connecting`), so the dialog must not be
                // reachable only from the form branch.
                Group {
                    // Connecting surface branch (connection-liveness plan, Task 6)
                    let surface = ConnectionSurfacePlan.surface(
                        for: tab.liveness,
                        hostKeyPromptPending: tab.connectionViewModel.hostKeyPrompt != nil,
                        connectAttemptFailed: tab.connectFailure != nil)
                    if surface == .connecting {
                        ConnectingAttemptView(onCancel: {
                            // Best-effort on the dial itself (see
                            // `ConnectionViewModel.cancelConnecting()`'s own
                            // doc comment) — what makes the tab usable again
                            // is forcing `state` back on the FOREGROUND and
                            // running the one teardown path, not waiting for
                            // the abandoned dial to notice anything.
                            // `cancelConnecting()` also moves Core's own
                            // attempt token, so the abandoned dial's
                            // eventual writes (state, a host-key card) are
                            // refused at the source — see that method's own
                            // doc comment. `reconnectAttempt`/
                            // `isReconnecting` are the identical App-layer
                            // fix for the stored-session path's own lock
                            // (Critical 1, fix round 1): without resetting
                            // them HERE, the sidebar would stay disabled
                            // until the abandoned Task's own deferred
                            // cleanup finally ran.
                            tab.connectionViewModel.cancelConnecting()
                            tab.reconnectAttempt = UUID()
                            tab.isReconnecting = false
                            Task { await teardown(tab, reason: .userRequested) }
                        })
                    }
                    // Lost surface branch (connection-liveness plan, Task 7)
                    //
                    // Also `ReconnectWiringGuardTests`' anchor for this
                    // branch; that suite's own doc comment explains what it
                    // scans from here.
                    //
                    // The content is `LostConnectionPlan.content`'s, not
                    // assembled here: what a given reason says, and whether
                    // "Reconnect" is offered at all, is the one decision on
                    // this surface a test can actually check
                    // (`ReconnectPlanTests`), and it stays checkable only
                    // while this branch does no deciding of its own.
                    else if surface == .lost {
                        LostConnectionView(
                            content: LostConnectionPlan.content(
                                reason: tab.lostConnection?.reason ?? .probeGaveUp,
                                targetIsKnown: reconnectTarget(for: tab) != nil,
                                behaviour: settingsStore.reconnectBehaviour,
                                attempts: tab.lostConnection?.automaticAttempts ?? 0),
                            onReconnect: { reconnect(tab) },
                            onDismiss: { dismissLostConnection(tab) })
                    }
                    // Failed-connect surface branch (failed-connect surface plan, Task 3)
                    //
                    // Also `ReconnectWiringGuardTests`' anchor for this
                    // branch, the same way the lost branch above is one.
                    //
                    // Every action here delegates: Retry — offered only
                    // when there is a stored session to dial — to
                    // `retryConnect(_:)`, which redials through the one
                    // shared `connect(in:stored:)` a sidebar connect uses, so
                    // this surface adds no second place a security rule
                    // could be forgotten; Edit and "Edit session" to the
                    // functions the sidebar's own Edit already goes
                    // through; Close to the ordinary tab-close entry point,
                    // warnings and all. What the surface SAYS is
                    // `ConnectFailurePlan.content`'s answer, and the
                    // technical text is `ConnectFailureDetailText.read`'s —
                    // this branch decides nothing of its own.
                    else if surface == .failed {
                        ConnectFailureView(
                            content: ConnectFailurePlan.content(
                                hasStoredSession: failedConnectTarget(for: tab) != nil),
                            details: ConnectFailureDetailText.read(
                                from: tab.connectionViewModel.state),
                            onRetry: { retryConnect(tab) },
                            onEdit: { dismissConnectFailure(tab) },
                            onEditSession: { editFailedSession(tab) },
                            onClose: { requestClose(tab) })
                    } else {
                        // Align the form to the top instead of centering it
                        // vertically (user feedback 2026-07-10, M5c/T0) —
                        // otherwise the compact window has a lot of empty
                        // space below the content.
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
                            // Save without dialing — the form's own route
                            // into `SessionListViewModel.save`, and what the
                            // tab menu's "Save as Session…" ultimately lands
                            // on. Validation already ran inside the button.
                            onSaveNew: { saveFormAsSession(in: tab) },
                            onCancelEdit: { tab.connectionViewModel.endEditing() },
                            onConnectEdited: { stored in
                                // onSaveEdited may have rewired loginSetID (e.g. "save as new
                                // login set") on its own local copy of `stored`, which never
                                // reaches this closure's parameter. `updateSession` inside
                                // onSaveEdited already reloaded the list synchronously, so look
                                // up the just-persisted session by id and connect with that.
                                let current = sessionListViewModel.sessions.first(where: { $0.id == stored.id }) ?? stored
                                connect(in: tab, stored: current)
                            },
                            // Read fresh at Connect-button-click time, inside
                            // `ConnectionFormView`'s own handler, NOT here —
                            // see `ConnectionFormView.currentReconnectAttempt`'s
                            // own doc comment for why a closure (fix round 3)
                            // rather than a plain value captured at THIS
                            // render.
                            currentReconnectAttempt: { tab.reconnectAttempt }
                        // Ad-hoc connect completion (connection-liveness plan, Task 6)
                        ) { fs, myAttempt in
                            // `myAttempt` is the token `ConnectionFormView`'s
                            // own Connect handler captured BEFORE dialing —
                            // see that view's `currentReconnectAttempt` doc
                            // comment for why capturing there (not here,
                            // after the dial) is what fix round 3 settled on
                            // as the one rule both connect paths share.
                            await handleAdHocConnected(fs, in: tab, attempt: myAttempt)
                        }
                    }
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

/// Mounts the liveness probe for exactly one tab (connection-liveness plan,
/// Task 4, fix rounds 1 through 3).
///
/// The probe used to be a second `.task(id: session.id)` inside
/// `ContentView.detail`'s own body. `detail` is built from `let tab =
/// activeTab` and only ever renders that ONE tab's content — background
/// tabs exist in `tabsModel.tabs` for switching, but their content is never
/// mounted while they are not active — so a BACKGROUND tab's probe never
/// ran at all, and `SessionTab.liveness` stayed at whatever it was the
/// moment that tab stopped being active. Task 5's tab-strip dot needs a
/// live value for every tab shown in the strip at once, not just the
/// selected one.
///
/// `ContentView.splitLayout` mounts one of these per tab
/// `LivenessProbeCoverage.tabsToProbe` selects, in a `ForEach` that lives in
/// the tree regardless of which tab is active — so a background tab now
/// keeps probing. WHICH tabs that is lives in `LivenessProbeCoverage`, a
/// plain function over the tab list, not decided by this view or by
/// `splitLayout` — a source-text scan can prove a view calls that function,
/// but cannot prove the function itself covers the right tabs; that
/// property is `LivenessProbeCoverageTests`' job, on a value this project
/// can actually run in a test. The `.task(id:)` shape is kept deliberately:
/// `ForEach` drops a tab's row (and with it, cancels its task) the moment
/// that tab leaves the selected set, and this view's own `.task(id: tab
/// .session?.id)` still restarts the loop on a disconnect/reconnect the
/// same way the original did — the cancellation guarantee this whole
/// approach depends on did not change, only where the mounted view lives.
///
/// Renders nothing observable: `body` is a zero-size `Color.clear`, purely
/// a mount point for `.task(id:)`. Draws no indicator itself — that is Task
/// 5's job, reading `tab.liveness`.
/// Which tabs should have a running liveness probe (connection-liveness
/// plan, Task 4, fix round 3) — pulled out of `ContentView.splitLayout` so
/// `Tests/macSCPAppKitTests/` can drive it directly, the same move this
/// codebase already made for `SnippetListPlan`/`SnippetMenuModel`/
/// `SnippetSendPlan`: a view detail is not observable in this project's
/// test setup, but a plain function over the tab list is.
///
/// Every CONNECTED tab, regardless of which one is active. Restricting
/// this to only the active tab is the exact "only the active tab was
/// probed" regression fix round 1 closed — `LivenessProbeCoverageTests`
/// pins that restriction back OUT by mutation, on this function directly,
/// rather than on `ContentView.splitLayout`'s view body, which this
/// project has no way to run in a test. An unconnected tab is excluded on
/// its own basis (no session, nothing to `stat`), never on which tab
/// happens to be selected.
@MainActor
enum LivenessProbeCoverage {
    static func tabsToProbe(from tabs: [SessionTab]) -> [SessionTab] {
        tabs.filter { $0.isConnected }
    }
}

struct LivenessProbeRunner: View {
    let tab: SessionTab
    let settingsStore: SettingsStore
    /// Routes to `ContentView.handleLivenessGiveUp(_:)` — passed in rather
    /// than called directly because this type has no access to
    /// `ContentView`'s own instance state, only to what its caller
    /// (`ContentView.splitLayout`) hands it. `handleLivenessGiveUp` is the
    /// real function a test drives to prove the `teardown(_:)`-then-`.lost`
    /// order holds (`LivenessGiveUpOrderingTests`); the probe loop's
    /// `.giveUp` case delegates to it rather than inlining that order a
    /// second time, so there is exactly one place that order is written.
    let onGiveUp: (SessionTab) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: tab.session?.id) {
                // Nothing to probe without a session. The session is NOT
                // captured here for the probe itself to use — each probe
                // re-reads it inside `LivenessProbeStep.perform`, so a tab
                // that disconnected and reconnected while a probe was in
                // flight cannot have the old connection's answer written
                // onto the new one.
                guard tab.session != nil else { return }
                var consecutiveFailures = 0
                // Liveness probe (Task 4): reads settings fresh every lap so
                // a mid-session change applies without restart; skipped laps
                // just sleep on — the same shape `detail`'s own auto-refresh
                // loop uses.
                while !Task.isCancelled {
                    // The switch, not a sentinel interval, decides whether
                    // this tab probes at all — `keepAliveIntervalSeconds`
                    // always reads 15…600 now (a stored `0` reads back as
                    // the default), so there is no interval value left that
                    // could mean "off". Sleep a fixed beat and recheck
                    // rather than spin, so turning the switch back on later
                    // takes effect without restarting the tab. NARROWING an
                    // already-running interval instead only takes effect
                    // once the current sleep call completes, up to the OLD,
                    // LARGER interval's own length — see
                    // `LivenessProbePolicy.idleRecheckSeconds`'s own doc
                    // comment for that asymmetry stated precisely.
                    guard settingsStore.keepAliveEnabled else {
                        try? await Task.sleep(for: .seconds(LivenessProbePolicy.idleRecheckSeconds))
                        continue
                    }
                    let interval = settingsStore.keepAliveIntervalSeconds
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { continue }
                    probing: while !Task.isCancelled {
                        let action = LivenessProbePolicy.decide(
                            queueIsBusy: tab.transferQueue.isActive,
                            consecutiveFailures: consecutiveFailures)
                        switch action {
                        case .skip:
                            // Running traffic proves the connection better
                            // than any probe would (design spec §2.1) — so
                            // the VISIBLE state says so too, not just the
                            // internal failure count: `consecutiveFailures`
                            // resets here for the same reason a stale
                            // `.degraded` from before the busy gap must not
                            // keep reading `.degraded` for the traffic's
                            // whole duration (fix round 2) — carrying either
                            // one across the gap would let a later give-up,
                            // or a stale dot, stand on evidence that
                            // predates the very traffic that disproved it.
                            consecutiveFailures = 0
                            tab.liveness = .connected
                            break probing
                        case .probe, .probeAgainNow:
                            let timeoutSeconds = LivenessProbePolicy.probeTimeout(forInterval: interval)
                            // The race AND the write of its result both live
                            // in `LivenessProbeStep.perform` — see that
                            // type's own doc comment for why they cannot be
                            // separated: the guard that makes the write
                            // legitimate has to sit between them, and a
                            // write spelled out here would be a write with
                            // no guard in front of it.
                            let result = await LivenessProbeStep.perform(
                                on: tab, timeoutSeconds: timeoutSeconds)
                            guard result != .abandoned else { return }
                            if result == .alive {
                                consecutiveFailures = 0
                                break probing
                            } else {
                                consecutiveFailures += 1
                                // Loop again immediately, without sleeping
                                // the full interval: `decide` now sees the
                                // incremented failure count and answers
                                // `.probeAgainNow` (one immediate retry) or
                                // `.giveUp`.
                            }
                        case .giveUp:
                            // Delegates to `onGiveUp` rather than inlining
                            // `teardown(_:)`-then-`.lost` here a second
                            // time (fix round 3) — see `onGiveUp`'s own doc
                            // comment for why, and `handleLivenessGiveUp`'s
                            // for the order itself and why it matters.
                            //
                            // No cancellation guard of its own, unlike the
                            // probe arm: this one is reached only by
                            // the enclosing `while !Task.isCancelled`, and
                            // `decide` is synchronous, so nothing can
                            // suspend between that check and this call on
                            // the main actor. A guard here would restate a
                            // condition that cannot have changed.
                            await onGiveUp(tab)
                            return
                        }
                    }
                }
            }
    }
}

/// One liveness probe and the write of its answer, together (connection-
/// liveness plan, whole-branch final review, finding I-1) — the race and
/// the `tab.liveness` write cannot be separated, because the guard that
/// makes the write legitimate is what has to sit between them.
///
/// `LivenessProbeRace.run` is deliberately NOT cancellation-aware: it
/// resolves a `withCheckedContinuation` from two unstructured tasks, so
/// cancelling the probing task does not make it return early — only the
/// operation finishing or `LivenessProbePolicy.probeTimeout(forInterval:)`
/// elapsing does (see `LivenessProbeRace`'s own doc comment for why that
/// shape was chosen, and what the structured alternative did instead). The
/// probing task therefore resumes AFTER it was cancelled, up to a full
/// probe timeout later, and a write placed straight after the `await` would
/// land on a tab whose session `teardown(_:)` has already torn down and
/// whose `liveness` it has already cleared to `nil`.
///
/// Two things that write would do, both closed by refusing it:
///
/// - a liveness dot on a tab that is sitting on the connection form with no
///   session at all, which is the same "state that outlives what it
///   describes" class that moved `liveness` onto the tab in the first
///   place, attacked from the other side;
/// - worse, the loss of the way to abandon a dial. `ConnectionSurfacePlan
///   .surface` answers `.form` for `.connected` and for `.degraded` alike,
///   so a stale write arriving during the reconnect-in-place dial replaces
///   the "Connecting…" surface, and with it the Cancel control, while that
///   dial is still running.
///
/// The guard is two conditions, not one. `Task.isCancelled` catches the
/// cancelled runner; re-reading `tab.session` and comparing its id catches
/// the tab that disconnected and reconnected during the flight, where the
/// task is alive and healthy and the answer in hand is nevertheless about a
/// connection that no longer exists.
///
/// `LivenessProbeCancellationTests` drives this function inside a task it
/// cancels mid-flight, against a `stat` that never responds — the real
/// race, really cancelled — and pins that nothing is written.
@MainActor
enum LivenessProbeStep {
    /// What one probe settled on. `.abandoned` is not a failure and must
    /// not be counted as one: it says the question stopped being worth
    /// answering, not that the peer failed to answer it.
    enum Result: Equatable {
        /// The peer answered inside the deadline; the tab now reads `.connected`.
        case alive
        /// The deadline won, or the `stat` failed; the tab now reads `.degraded`.
        case failed
        /// Cancelled, or the session went away, while the probe was in
        /// flight. NOTHING was written and the caller must stop.
        case abandoned
    }

    static func perform(on tab: SessionTab, timeoutSeconds: Int) async -> Result {
        guard let session = tab.session else { return .abandoned }
        let alive = await LivenessProbeRace.run(timeoutSeconds: timeoutSeconds) {
            (try? await session.remoteFS.stat(path: session.homePath)) != nil
        }
        guard !Task.isCancelled, tab.session?.id == session.id else { return .abandoned }
        tab.liveness = alive ? .connected : .degraded
        return alive ? .alive : .failed
    }
}

/// Races an async operation against a deadline, `false` if the deadline
/// wins (connection-liveness plan, Task 4, fix round 1) — pulled out of
/// `LivenessProbeRunner` so `Tests/macSCPAppKitTests/` can drive it directly
/// with a fake `RemoteFileSystem` whose `stat` never resumes: the exact case
/// the previous shape (`withTaskGroup`) could not survive. Its caller is
/// `LivenessProbeStep.perform`, which is where the answer this returns is
/// turned into a write, and where the guard in front of that write lives.
///
/// `withTaskGroup` implicitly awaits every remaining child before its own
/// scope returns, even one abandoned via `cancelAll()` — that is a
/// structured-concurrency guarantee, not a bug, but it defeats a timeout
/// when the abandoned child cannot finish early. Citadel's own path into
/// NIO ends in a bare `EventLoopFuture.get()` with no cancellation handler,
/// so a cancelled `stat` against a connection that has actually died does
/// not finish early — measured at 3.00s against a 1s deadline with the
/// `withTaskGroup` shape, on the exact case this whole probe exists to
/// catch: a connection that dies silently, where `stat` never returns at
/// all. With that shape the probe hangs instead of timing out, and the
/// state stays `.connected` — the opposite of the intent.
///
/// Two unstructured `Task`s race instead of one structured child: neither
/// is a child `run(timeoutSeconds:operation:)` itself awaits, so returning
/// does not wait on whichever one loses. The abandoned operation may keep
/// running in the true background afterward — cancelling it is best-effort
/// only, for the same reason `EventLoopFuture.get()` defeated the previous
/// shape's own cancellation — but that no longer blocks the caller.
///
/// Exactly-once resumption (this project's standing continuation invariant;
/// see `ConflictPromptBridge`'s doc comment for the fuller treatment): `run`
/// is `@MainActor`, so its synchronous `withCheckedContinuation` closure —
/// where `Box` is constructed and both racing tasks are created — runs on
/// the main actor without ever yielding, which is what guarantees both
/// `box.operationTask` and `box.timeoutTask` are assigned before either
/// task's own `@MainActor`-isolated body can start.
///
/// The two racing calls to `resume(with:)` are NOT symmetric —
/// `LivenessProbeRaceTests
/// .aStatThatNeverRespondsStillReportsFailureWithinTheDeadline` is exactly
/// the case where the operation task's own call never happens at all,
/// because `await operation()` never returns to reach it. "At least once"
/// instead comes from the timeout task alone: `Task.sleep` completes on
/// its own schedule regardless of what `operation` does, so its call to
/// `resume(with:)` is guaranteed no matter how the race goes. "At most
/// once" comes from `Box.resume(with:)` itself — the only place the
/// continuation is taken and resumed, reachable only by hopping onto the
/// main actor, so whichever call (one or two) arrives is serialized, and
/// `continuation == nil` on a second call is what makes a double
/// resumption (which would trap) impossible.
@MainActor
enum LivenessProbeRace {
    static func run(
        timeoutSeconds: Int, operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = Box(continuation: continuation)
            box.operationTask = Task { @MainActor in
                let succeeded = await operation()
                box.resume(with: succeeded)
            }
            box.timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                box.resume(with: false)
            }
        }
    }

    @MainActor
    private final class Box {
        private var continuation: CheckedContinuation<Bool, Never>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// The only place `continuation` is taken and resumed — see this
        /// type's own doc comment for the exactly-once argument.
        func resume(with value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            operationTask?.cancel()
            timeoutTask?.cancel()
            continuation.resume(returning: value)
        }
    }
}

/// What the tab's connection area should show while it has no active
/// session (connection-liveness plan, Task 6) — the ONE surface Task 6's
/// `.connecting` case renders through, which Task 7 then added its own
/// `lost` case to without touching this type's call site in
/// `ContentView.detail`, and which the failed-connect surface plan's Task 3
/// added `failed` to — that one DID change the call site, which now passes
/// a third fact (see `ConnectionSurfacePlan.surface`). Named per the design
/// spec's own framing
/// (`docs/superpowers/specs/2026-08-21-connection-state-design.md` §4):
/// one and the same tab area for connecting, connected and lost.
enum ConnectionAttemptSurface: Equatable {
    /// The ordinary new-connection/edit form (`ConnectionFormView`).
    case form
    /// "Connecting…" with a Cancel control (Task 6).
    case connecting
    /// The lost-connection surface: what happened, and the way back (Task
    /// 7) — `LostConnectionView`, driven by `LostConnectionPlan.content`.
    case lost
    /// The failed-connect surface: an attempt that never reached a session
    /// (failed-connect surface plan, Task 3) — `ConnectFailureView`, driven
    /// by `ConnectFailurePlan.content`. Distinct from `.lost`, which is
    /// about a connection that existed and dropped.
    case failed
}

/// Decides `ConnectionAttemptSurface` from the facts `ContentView
/// .detail` already has in hand — pulled out as a plain function so
/// `Tests/macSCPAppKitTests/` can exercise every combination directly,
/// rather than the decision living inline in a view body this project has
/// no way to render (the same move `LivenessDotPlan`, Task 5, made for the
/// tab-strip dot).
enum ConnectionSurfacePlan {
    /// `hostKeyPromptPending` is `tab.connectionViewModel.hostKeyPrompt !=
    /// nil` at the call site. TOFU's trust card lives INSIDE
    /// `ConnectionFormView` (`hostKeyPromptView`), unlike the WebDAV/S3
    /// certificate prompt, which is a sibling surface `ContentView.detail`
    /// already checks before ever reaching this function
    /// (`tab.certificateBridge.currentCandidate`) — so a `.connecting`
    /// surface that hid `ConnectionFormView` unconditionally would hide the
    /// one thing on screen a first connection to an unknown host needs
    /// answered. TOFU is a hard stop in this project (see the architecture
    /// invariants), never bypassed by a UI surface picking the wrong
    /// branch — this override is what keeps that true here.
    ///
    /// `.lost` (Task 7) is answered here rather than by a second, parallel
    /// decision in `ContentView.detail`, so the host-key override above
    /// covers it too: an automatic reconnect that raises a trust card while
    /// the tab still reads `.lost` must show that card, not an error view
    /// explaining that the connection dropped.
    ///
    /// `connectAttemptFailed` is `tab.connectFailure != nil` at the call
    /// site (failed-connect surface plan, Task 3) — a connect attempt that
    /// ended on the wire, with nothing connected and no earlier connection
    /// to explain. Before this task every such attempt left `liveness` at
    /// `nil` and therefore landed in the `.form` group below, which is the
    /// maintainer's complaint this surface answers: the tab fell back to
    /// the entry mask as if nothing had been asked for.
    ///
    /// It is consulted ONLY in the `nil` arm, deliberately. `.lost` is
    /// answered above it, so a reconnect that fails from the lost surface
    /// still returns to the surface that explains the drop rather than
    /// being reclassified as a fresh failure. `.connected`/`.degraded` keep
    /// answering `.form` unconditionally: a tab with a live session does
    /// not render this area at all (`ContentView.detail` reaches this
    /// function only while `tab.session == nil`), and letting a stale
    /// failure speak for a connected tab would be a new way to be wrong
    /// about a tab that is fine.
    static func surface(
        for liveness: ConnectionLiveness?, hostKeyPromptPending: Bool,
        connectAttemptFailed: Bool
    ) -> ConnectionAttemptSurface {
        guard !hostKeyPromptPending else { return .form }
        switch liveness {
        case .connecting: return .connecting
        case .lost: return .lost
        case .connected, .degraded: return .form
        case nil: return connectAttemptFailed ? .failed : .form
        }
    }
}

/// Why a tab's connection is gone, at the coarseness the lost-connection
/// surface and the reconnect policy both read (connection-liveness plan,
/// Task 7).
enum LostConnectionReason: Equatable {
    /// The liveness probe gave up on a session that had been connected.
    case probeGaveUp
    /// A reconnect attempt failed for a reason another attempt might not
    /// hit — a timeout, a refused connection, a host that is still booting.
    case reconnectFailed
    /// The last attempt stopped at something only a person can answer: an
    /// unknown or changed host key, or a key passphrase macSCP does not
    /// have. Repeating it unattended would only raise the same question
    /// again on a schedule, so this reason stops background retrying
    /// outright — see `ReconnectPlan.step`. Comes from Core's own
    /// `ConnectFailureKind.needsPerson`, never from reading a message.
    case needsPerson
}

/// What a tab remembers about a connection that dropped (connection-
/// liveness plan, Task 7) — stored on `SessionTab.lostConnection`.
///
/// Carries an id and an enum, never a host name, a server message or a
/// typed value: the design spec's §10 rule (no secret and no user-typed
/// value on the error view) is a property of what this type is able to
/// hold, not a habit at the call site. `LostConnectionContent`, what
/// actually reaches the screen, has the same shape for the same reason.
struct LostConnection: Equatable {
    var reason: LostConnectionReason
    /// The stored session to redial, or `nil` for an ad-hoc connection —
    /// one typed into the form and never saved, whose secrets
    /// `ContentView.teardown(_:)` has already cleared, so there is nothing
    /// left to redial WITH. That case offers the form back instead of a
    /// Reconnect button; see `LostConnectionPlan.content`.
    var storedSessionID: UUID?
    /// How many unattended attempts this episode has already started.
    /// Drives `ReconnectBackoff.delay(forAttempt:)` and, under
    /// `.onceThenAsk`, the "once" itself. Counts attempts STARTED, not
    /// attempts finished — an attempt that is still dialing must not be
    /// started a second time by the same schedule.
    var automaticAttempts = 0
}

/// What a tab remembers about a connect attempt that failed on the wire
/// (failed-connect surface plan, Task 3) — stored on `SessionTab
/// .connectFailure`, and the fact `ConnectionSurfacePlan` reads to put the
/// failed-connect surface up instead of the form.
///
/// The same shape, and the same reason, as `LostConnection` above: an
/// optional id and nothing else. There is no field a host name, a typed
/// value or a server message could be put into, so what the SURFACE can
/// show is bounded by what this type can hold. The full technical text the
/// details dialog shows is deliberately NOT kept here — it is read from
/// `ConnectionViewModel`'s own published `.failed` state when the dialog
/// asks for it (`ConnectFailureDetailText.read(from:)`), so there is one text,
/// the one the layer below published, and no second copy that could drift
/// from it or outlive the attempt it describes.
struct ConnectFailure: Equatable {
    /// The stored session the failed attempt dialed, or `nil` when it was
    /// ad-hoc — typed into the form and never saved, so there is nothing
    /// stored to open an editor on. Resolved against the LIVE session list
    /// when read (`ContentView.failedConnectTarget(for:)`), never trusted
    /// as a session that still exists, for the same reason
    /// `LostConnection.storedSessionID` is not: a session can be deleted
    /// while its tab sits on this surface.
    var storedSessionID: UUID?
}

/// The lost-connection surface's whole content (connection-liveness plan,
/// Task 7): catalog keys and their English defaults, and two booleans.
///
/// There is deliberately no `String` field here that a host name, a server
/// error, or a form value could be put into — that is what makes the design
/// spec's §10 rule (the error view must contain no secret and no value the
/// user typed) checkable rather than merely intended. `ReconnectPlanTests`
/// pins that every reachable content value is one of a fixed, enumerated
/// set of catalog keys.
///
/// The two button labels are fields here rather than literals in the view
/// (round 2, after review): with them left in the view, this type covered
/// the text on the surface but not all of it, and the claim that the key
/// scan is exhaustive was true only of the part that happened to live here.
/// Everything the surface renders now comes through this type.
struct LostConnectionContent: Equatable {
    struct Message: Equatable {
        let key: String
        let fallback: String
    }

    let title: Message
    let body: Message
    /// A second line under the body, when there is something to add about
    /// what macSCP is doing on its own. `nil` when the body already says
    /// everything.
    let hint: Message?
    /// The redial button, or `nil` when there is nothing to redial.
    let reconnectButton: Message?
    /// The way back to the ordinary connection form. Always offered — even
    /// with a redial available, leaving the surface has to be possible.
    let dismissButton: Message
}

/// Builds `LostConnectionContent` (connection-liveness plan, Task 7) —
/// a plain function over three facts, for the same reason `LivenessDotPlan`
/// (Task 5) and `ConnectionSurfacePlan` (Task 6) are: no test in this
/// project renders SwiftUI, so the decision has to live somewhere a test
/// can call.
enum LostConnectionPlan {
    /// `targetIsKnown` is "this tab's dropped connection names a stored
    /// session that is still in the list" — resolved at the call site
    /// against `SessionListViewModel.sessions`, because a session can be
    /// deleted while its tab sits on this surface, and offering to redial
    /// something that no longer exists is a button that cannot work.
    ///
    /// `attempts` is `LostConnection.automaticAttempts`. It matters only to
    /// `.onceThenAsk`, which is the behaviour whose whole state is "has the
    /// one attempt happened yet" — and which round 1 left with no hint at
    /// all, so a user could not tell that macSCP was about to try by
    /// itself, nor afterwards that it already had. That invisibility, not
    /// the delay before the attempt, was the friction.
    static func content(
        reason: LostConnectionReason, targetIsKnown: Bool, behaviour: ReconnectBehaviour,
        attempts: Int
    ) -> LostConnectionContent {
        let body: LostConnectionContent.Message
        switch reason {
        case .probeGaveUp:
            body = .init(
                key: "connection.lost.body.probe",
                fallback: "The host stopped answering, so macSCP closed the session.")
        case .reconnectFailed:
            body = .init(
                key: "connection.lost.body.retryFailed",
                fallback: "macSCP could not reach the host again.")
        case .needsPerson:
            body = .init(
                key: "connection.lost.body.needsPerson",
                fallback: "The last attempt stopped at a question only you can answer.")
        }

        let hint: LostConnectionContent.Message?
        if !targetIsKnown {
            hint = .init(
                key: "connection.lost.hint.noSavedSession",
                fallback: "This connection was not saved, so reconnecting means filling the form in again.")
        } else if reason == .needsPerson {
            // Deliberately no "macSCP keeps trying" hint even under
            // `.automatic`: this reason is exactly the case where it does
            // NOT keep trying (`ReconnectPlan.step`), and a hint promising
            // otherwise would be the surface contradicting the policy.
            hint = .init(
                key: "connection.lost.hint.stopped",
                fallback: "macSCP is not retrying on its own until you have answered it.")
        } else {
            switch behaviour {
            case .automatic:
                hint = .init(
                    key: "connection.lost.hint.automatic",
                    fallback: "macSCP keeps trying on its own, waiting longer between attempts.")
            case .onceThenAsk:
                hint = attempts == 0
                    ? .init(
                        key: "connection.lost.hint.onceUpcoming",
                        fallback: "macSCP will try once on its own in a moment.")
                    : .init(
                        key: "connection.lost.hint.onceDone",
                        fallback: "macSCP already tried once on its own.")
            case .offerOnly:
                hint = nil
            }
        }

        return LostConnectionContent(
            title: .init(key: "connection.lost.title", fallback: "Connection lost"),
            body: body,
            hint: hint,
            reconnectButton: targetIsKnown
                ? .init(key: "connection.lost.reconnect", fallback: "Reconnect") : nil,
            dismissButton: .init(
                key: "connection.lost.dismiss", fallback: "Back to the form"))
    }
}

/// What a failed-connect surface says, and which actions it offers
/// (failed-connect surface plan, Task 2). Shown instead of the ordinary
/// form after a connect attempt ends in `ConnectFailureKind.other` —
/// timeout, name resolution, refused — as opposed to `.needsPerson`, which
/// already has its own surface (a host-key or passphrase prompt) untouched
/// by this task.
///
/// Same structural shape as `LostConnectionContent`, and for the same
/// reason: only `(key, fallback)` message pairs and one flag decide what
/// shows, so there is no field a host name, a server message, or a raw
/// error string could occupy. The general message is safe by construction,
/// not by promise — the full technical text belongs to the details dialog
/// (`ConnectFailureDetailsSheet`, Task 3), never to this type; what this
/// type carries for that dialog is its LABEL and its headline, both catalog
/// keys like everything else here.
struct ConnectFailureContent: Equatable {
    struct Message: Equatable {
        let key: String
        let fallback: String
    }

    let title: Message
    /// The general sentence under the headline — and, for an ad-hoc
    /// attempt, the sentence that says what to do next.
    ///
    /// Two keys, chosen by the same `hasStoredSession` flag that decides
    /// `retryButton` and `editSessionButton` (maintainer decision,
    /// 2026-08-25, recorded in the design spec under the surface's own
    /// section). A stored-session failure keeps the plain line: Retry is
    /// right there and needs no explanation. An ad-hoc failure has no
    /// Retry at all, so its only way forward is a button labelled for
    /// EDITING — and a surface that offers that without saying why leaves
    /// someone hunting for a button that is not there.
    ///
    /// This deliberately softens the spec's original "one general message"
    /// rule. It is still one message per case and still a fixed catalog
    /// key: what varies is which of two fixed keys, never the text itself,
    /// so the structural property this whole type exists for is untouched.
    let body: Message
    /// Redial through the same connection path a fresh attempt uses.
    ///
    /// `nil` for an ad-hoc attempt (round 2, after review), for exactly the
    /// reason `editSessionButton` is: there is nothing stored to dial. The
    /// values an ad-hoc retry would use live on the form, and the form's
    /// own Connect button is the one place an ad-hoc dial happens — adding
    /// a second dial site to serve this button is the trade this whole
    /// surface exists to refuse. Round 1 offered the button anyway and had
    /// it hand the tab back to the form: no dial, no "Connecting…", which
    /// is precisely the behaviour the maintainer complained about, under a
    /// button named for the opposite. An action that cannot act is worse
    /// than an action that is not offered.
    let retryButton: Message?
    /// The form, prefilled with what was just typed. A one-off change:
    /// this button never touches a stored session.
    let editButton: Message
    /// The session editor — a durable change to what is stored. `nil` for
    /// an ad-hoc connection, which was never saved and so has nothing
    /// stored to edit.
    ///
    /// Deliberately a second, separate button from `editButton` rather than
    /// one button that behaves differently by context: a one-off "is it the
    /// port?" attempt must not silently rewrite the stored session, and a
    /// genuine error in the session must stay fixable for good. Two
    /// intentions; a surface offering only one forces the wrong one onto
    /// whichever case it does not fit.
    let editSessionButton: Message?
    /// Close the tab. Always offered — the way off this surface, redial or
    /// not, the same as `LostConnectionContent.dismissButton`.
    let closeButton: Message
    /// Opens the details dialog (failed-connect surface plan, Task 3). The
    /// LABEL is a catalog key like every other string on the surface; the
    /// dialog's own body is the one raw text in this whole feature, and it
    /// is not carried by this type — see `ConnectFailureDetailText`.
    let detailsButton: Message
    /// The details dialog's own headline. A field here rather than a
    /// literal in the dialog for the reason `LostConnectionContent`'s own
    /// doc comment gives for its two button labels: a type that covers the
    /// text of a surface has to cover all of it, or the claim that the keys
    /// are enumerable is true only of the part that happens to live here.
    let detailsTitle: Message
}

/// Builds `ConnectFailureContent` (failed-connect surface plan, Task 2)
/// from the one fact the surface needs beyond its own fixed text: whether
/// the failed attempt started from a tab with a stored session. A plain
/// function over that one flag, the same move `LostConnectionPlan` and
/// `ConnectionSurfacePlan` made before it — nothing in this project renders
/// SwiftUI, so the decision of what shows has to live somewhere a test can
/// call, not inline in a view body.
enum ConnectFailurePlan {
    /// `hasStoredSession` is "this tab's failed attempt was dialed from a
    /// stored session" — resolved at the call site, the same place
    /// `LostConnectionPlan.content`'s `targetIsKnown` is.
    static func content(hasStoredSession: Bool) -> ConnectFailureContent {
        ConnectFailureContent(
            title: .init(
                key: "connection.failed.title", fallback: "No connection possible"),
            body: hasStoredSession
                ? .init(
                    key: "connection.failed.body",
                    fallback: "macSCP could not connect to the host.")
                : .init(
                    key: "connection.failed.body.adHoc",
                    fallback: "macSCP could not connect to the host. Edit the connection to "
                        + "check its settings and connect again."),
            retryButton: hasStoredSession
                ? .init(key: "connection.failed.retry", fallback: "Try again") : nil,
            editButton: .init(key: "connection.failed.edit", fallback: "Edit"),
            editSessionButton: hasStoredSession
                ? .init(key: "connection.failed.editSession", fallback: "Edit session") : nil,
            closeButton: .init(key: "connection.failed.close", fallback: "Close"),
            detailsButton: .init(key: "connection.failed.details", fallback: "Details…"),
            detailsTitle: .init(
                key: "connection.failed.details.title", fallback: "Connection details"))
    }
}

/// Whether an unattended reconnect attempt is due, and when (connection-
/// liveness plan, Task 7) — the whole `offerOnly`/`onceThenAsk`/`automatic`
/// rule as a plain function, so `ReconnectRunner` below is left with
/// nothing but a sleep and a call.
///
/// The spacing itself is Core's (`ReconnectBackoff.delay(forAttempt:)`,
/// pinned by `ConnectionLivenessTests`): 5 seconds, doubling, capped at 60,
/// with no give-up limit. `.onceThenAsk` uses the same first delay rather
/// than firing immediately, so the two behaviours differ in how many
/// attempts they make and in nothing else.
enum ReconnectPlan {
    enum Step: Equatable {
        case wait(seconds: Int)
        case stop
    }

    /// `liveness` and `lost` are read together on purpose: an attempt is
    /// due only while the tab is actually sitting on the lost surface. A
    /// tab that is mid-attempt (`.connecting`), reconnected (`.connected`)
    /// or back at the form (`nil`) must not have a second attempt fired
    /// underneath it.
    static func step(
        liveness: ConnectionLiveness?, lost: LostConnection?,
        targetIsKnown: Bool, behaviour: ReconnectBehaviour
    ) -> Step {
        guard liveness == .lost, let lost, targetIsKnown else { return .stop }
        // The design spec's own exception (§3, restated in this task's
        // brief): even under `.automatic`, an attempt that ran into a
        // host-key decision or a key passphrase ends in the error view and
        // is NOT repeated in the background.
        guard lost.reason != .needsPerson else { return .stop }
        switch behaviour {
        case .offerOnly:
            return .stop
        case .onceThenAsk:
            guard lost.automaticAttempts < 1 else { return .stop }
        case .automatic:
            break
        }
        return .wait(seconds: ReconnectBackoff.delay(forAttempt: lost.automaticAttempts + 1))
    }
}

/// Mirrors `SessionTab.connectionViewModel.state` into `SessionTab
/// .liveness` while a connect attempt for THIS tab is running (connection-
/// liveness plan, Task 6) — mounted per tab in `ContentView.splitLayout`'s
/// `.background`, for every tab and not only the active one, for the same
/// reason `LivenessProbeRunner` is (see that type's own doc comment):
/// switching away from a connecting tab must not stop THAT tab's own dot
/// and surface from tracking its own attempt.
///
/// `tab.liveness` is the single fact Task 5's tab-strip dot and this task's
/// `ConnectionSurfacePlan` both read — this is the one place that drives it
/// INTO `.connecting`, so the dot and the surface cannot read two
/// independently-derived answers to "is this tab connecting right now".
///
/// `initial: true` (fix round 1, connection-liveness plan Task 6): without
/// it, `.onChange` only fires on a change witnessed AFTER this view has
/// mounted — a brand-new tab whose connect attempt starts before SwiftUI
/// gets a render pass to mount this view's row would have its very FIRST
/// `.connecting` transition missed entirely, leaving `tab.liveness` at
/// `nil` (dot blank, connecting surface never shown) until some LATER
/// transition happened to fire the observer. `initial: true` also
/// evaluates the closure once with the CURRENT value the moment the view
/// appears, closing that gap.
///
/// Two of `ConnectionViewModel.State`'s three cases write something here.
/// `.connecting` always means an attempt for this tab just started, and
/// always publishes `.connecting`. `.idle` is left alone: it is reached
/// both by a SUCCESSFUL dial (`ConnectionViewModel.connect()`'s own
/// success-path write) — where publishing `.connected` is `ContentView
/// .startSession`'s job, moments later, once the home-directory lookup
/// finishes, so resetting to `nil` here first would flash the form back for
/// that window — AND by `cancelConnecting()` (fix round 1: Cancel now
/// forces `state` to `.idle` too) — where `teardown(_:)`, called from the
/// SAME `onCancel` that calls `cancelConnecting()`, is already the thing
/// resetting `tab.liveness` to `nil`; this mirror does not need to race it.
/// `.failed` means the attempt just ended with nothing connected, and
/// resets to `nil` — but ONLY while `tab.session == nil`, and only while
/// this tab is not describing a dropped connection (see the Task 7
/// paragraph below). `.failed` is not exclusively a "just tried and failed
/// to connect" signal (`showFailure` is also how a validation refusal
/// unrelated to dialing — e.g. an empty save name — reaches this same
/// `state`), and this tab's own
/// `connectionViewModel` is never touched by anything while the tab IS
/// connected in today's App (the form that could touch it is not even
/// mounted then — see `ConnectionSurfacePlan`). Guarding on `tab.session`
/// rather than relying on that as an invariant is what keeps a latent path
/// from ever nilling a CONNECTED tab's liveness out from under it.
///
/// Task 7 added the one case this switch could not express before: a tab
/// whose connection was already LOST and whose failed attempt was the
/// reconnect from that surface. Clearing to `nil` there would drop the user
/// back onto the connection form the moment an unattended retry failed —
/// with the lost surface, its explanation and its Reconnect button gone,
/// and (under `.automatic`) the next retry still scheduled behind it. The
/// decision now lives in `ConnectAttemptLivenessPlan.write`, a plain
/// function, for the reason every other decision on this branch was pulled
/// out of a view body: nothing here can be rendered in a test.
struct ConnectAttemptLivenessMirror: View {
    let tab: SessionTab

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: tab.connectionViewModel.state, initial: true) { _, newState in
                // Liveness mirror write (connection-liveness plan, Task 7)
                switch ConnectAttemptLivenessPlan.write(
                    for: newState, hasSession: tab.session != nil,
                    describesLostConnection: tab.lostConnection != nil,
                    failureKind: tab.connectionViewModel.lastFailureKind)
                {
                case .connecting:
                    tab.liveness = .connecting
                    // A new attempt is what this tab is about now, so the
                    // previous one's failure stops speaking for it. Every
                    // dial reaches `.connecting` — the stored-session one
                    // and the form's own — so this one line is what keeps
                    // the failed surface from outliving the attempt that
                    // raised it, without a second clearing rule per path.
                    tab.connectFailure = nil
                case .lost(let reason):
                    // The reason is refreshed in the same step as the state
                    // it explains: an attempt that stopped at a host key or
                    // a passphrase must reach `.needsPerson` BEFORE
                    // `ReconnectRunner` re-reads this tab, or the very
                    // schedule that rule exists to stop would be decided on
                    // the reason of the attempt BEFORE it.
                    tab.lostConnection?.reason = reason
                    tab.liveness = .lost
                case .failedConnect:
                    // Failed-connect surface (failed-connect surface plan,
                    // Task 3). `liveness` still goes to `nil` — no
                    // connection exists, and the tab-strip dot's own
                    // reading of this tab is unchanged by this task — and
                    // the surface is chosen by `connectFailure` instead,
                    // which is why `ConnectionSurfacePlan` takes it as its
                    // own argument rather than deriving it from `liveness`.
                    tab.liveness = nil
                    // The origin comes from the ATTEMPT that failed (M3),
                    // not from a tab property written before the dial: a
                    // dial the form refused never became an attempt and so
                    // never wrote one. See `ConnectionViewModel
                    // .attemptOrigin`.
                    tab.connectFailure = ConnectFailure(
                        storedSessionID: tab.connectionViewModel.attemptOrigin)
                case .clear:
                    tab.liveness = nil
                    tab.connectFailure = nil
                case .leaveAlone:
                    break
                }
                // No origin to consume here (M3). It used to be cleared on
                // every state that was not `.connecting`, because it lived
                // on the tab and could outlive the dial that wrote it — a
                // refused dial changes no state, so that clear never ran
                // for the one case it was needed. `ConnectionViewModel
                // .attemptOrigin` is now assigned with the attempt itself
                // and replaced by the next one, so there is nothing left
                // here that could go stale.
            }
    }
}

/// What `ConnectAttemptLivenessMirror` writes for one `ConnectionViewModel
/// .State` (connection-liveness plan, Task 7) — the mirror's whole decision
/// as a plain function, so `Tests/macSCPAppKitTests/` can drive every
/// combination instead of a `.onChange` closure this project cannot render.
///
/// The three `State` cases, and why each answers as it does, are set out in
/// `ConnectAttemptLivenessMirror`'s own doc comment; the one case that is
/// new here is `.failed` on a tab that is describing a lost connection,
/// which goes back to `.lost` rather than clearing.
enum ConnectAttemptLivenessPlan {
    enum Write: Equatable {
        case connecting
        /// Back to the lost surface, with the reason this attempt earned.
        case lost(LostConnectionReason)
        /// Onto the failed-connect surface (failed-connect surface plan,
        /// Task 3): the attempt reached the wire and failed there, on a tab
        /// that has no session and no earlier connection to explain. Split
        /// out of `.clear`, which is where every failed first attempt used
        /// to land — and `.clear` means "show the form", which is exactly
        /// the fallback this surface replaces.
        case failedConnect
        case clear
        case leaveAlone
    }

    /// `failureKind` is `ConnectionViewModel.lastFailureKind`, read at the
    /// call site right after the state change that carries it. It is
    /// consulted only on the `.failed`-while-lost path: it is what turns
    /// "the reconnect failed" into "the reconnect stopped at something only
    /// a person can answer", which is the difference between a schedule
    /// that keeps running and one that stops (`ReconnectPlan.step`).
    static func write(
        for state: ConnectionViewModel.State, hasSession: Bool,
        describesLostConnection: Bool, failureKind: ConnectFailureKind?
    ) -> Write {
        switch state {
        case .connecting:
            return .connecting
        case .failed:
            guard !hasSession else { return .leaveAlone }
            guard describesLostConnection else {
                // Failed-connect surface (Task 3). `.other` is the design
                // spec's own boundary for it: a timeout, a name that did
                // not resolve, a refused connection. `.needsPerson` — an
                // unknown or changed host key, a missing passphrase, and
                // every pre-dial refusal, which are `.needsPerson` by
                // construction (see `ConnectFailureKind`) — keeps clearing
                // to the form, because the form is where the question that
                // stopped the attempt is actually asked and where its text
                // has always lived. A `nil` verdict is not a failed dial
                // this surface knows how to describe, and falls the same
                // way.
                return failureKind == .other ? .failedConnect : .clear
            }
            return .lost(failureKind == .needsPerson ? .needsPerson : .reconnectFailed)
        case .idle:
            return .leaveAlone
        }
    }
}

/// Runs the unattended part of the reconnect (connection-liveness plan,
/// Task 7) — mounted per tab in `ContentView.splitLayout`'s `.background`,
/// for every tab and not only the active one, the same shape and the same
/// reason as `LivenessProbeRunner` and `ConnectAttemptLivenessMirror`: a
/// background tab whose connection dropped is exactly the tab whose owner
/// is not watching it.
///
/// Holds no state of its own. WHETHER an attempt is due and after how long
/// is `ReconnectPlan.step`'s answer, HOW MANY attempts have run lives on
/// `SessionTab.lostConnection` (so it survives this view being torn down
/// and remounted between attempts, which `.task(id:)` guarantees will
/// happen), and the attempt itself is `ContentView.reconnect(_:)` —
/// which dials through the ordinary `connect(in:stored:)`, the same path a
/// sidebar connect takes. That last point is the load-bearing security
/// decision of this task and is guarded by `ReconnectWiringGuardTests`:
/// a second dial here would be a second place to forget TOFU.
///
/// The step is decided twice — once when the task starts, once after the
/// sleep. Not belt-and-braces: `RunKey` cannot contain whether the stored
/// session still exists (that lives in `SessionListViewModel`, and is
/// resolved through `targetIsKnown` at decision time), so a session deleted
/// during the wait would otherwise be redialled by a schedule that was
/// decided before it went away.
struct ReconnectRunner: View {
    let tab: SessionTab
    let settingsStore: SettingsStore
    /// Whether this tab's dropped connection still names a stored session
    /// that is in the list right now — a closure, not a value, so it is
    /// answered when the decision is made rather than when this view was
    /// last rendered.
    let targetIsKnown: (SessionTab) -> Bool
    let onAttempt: (SessionTab) -> Void

    /// Restarts the task whenever anything the schedule was decided from
    /// changes: the tab leaving (or re-entering) `.lost`, an attempt having
    /// been counted, and the setting itself — so changing the behaviour in
    /// Settings applies to a tab already sitting on the lost surface.
    private struct RunKey: Equatable {
        let liveness: ConnectionLiveness?
        let lost: LostConnection?
        let behaviour: ReconnectBehaviour
    }

    private var runKey: RunKey {
        RunKey(
            liveness: tab.liveness, lost: tab.lostConnection,
            behaviour: settingsStore.reconnectBehaviour)
    }

    private var step: ReconnectPlan.Step {
        ReconnectPlan.step(
            liveness: tab.liveness, lost: tab.lostConnection,
            targetIsKnown: targetIsKnown(tab),
            behaviour: settingsStore.reconnectBehaviour)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: runKey) {
                // Reconnect schedule (connection-liveness plan, Task 7)
                guard case .wait(let seconds) = step else { return }
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, case .wait = step else { return }
                // Counted BEFORE the dial, and in the same synchronous
                // step: the count is of attempts STARTED. Incrementing
                // afterwards would let a slow attempt be scheduled a second
                // time on the old count, and would make `.onceThenAsk`
                // depend on how long a dial takes.
                tab.lostConnection?.automaticAttempts += 1
                onAttempt(tab)
            }
    }
}

/// The width the split view actually gave the sidebar, carried up from the
/// sidebar's own background to `SidebarWidthRecorder` beside the split
/// container.
///
/// A preference rather than a second piece of view state for one reason:
/// the recorder has to see this width and the container's width as they
/// were in ONE layout pass. Two `@State` values, each written by its own
/// reader, can be read a pass apart — and a container width from before a
/// window resize next to a sidebar width from after it is exactly the pair
/// that looks like a drag.
private struct SidebarMeasuredWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    /// The sidebar publishes exactly one value; this exists because the
    /// protocol requires it. Last non-zero wins, so a pass that measures
    /// nothing cannot overwrite a real measurement with 0.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// One layout pass, as the two widths a width change has to be judged by.
private struct SidebarWidthSample: Equatable {
    let container: CGFloat
    let sidebar: CGFloat
}

/// Writes the sidebar's width back to `SettingsStore` after the user drags
/// the split divider.
///
/// Measured rather than bound, because `HSplitView` reports no drag: the
/// divider moves the sidebar's width, and the only place that width can be
/// read is the layout it produced. Which means everything else that moves
/// the sidebar's width arrives here looking identical to a drag — and one
/// of those is destructive. A pristine window (one unconnected tab) holds
/// its content to 700 points against a 500-point detail minimum, leaving
/// 200 for the sidebar, well under the 340 `SettingsStore
/// .sidebarWidthRange` allows. Disconnecting the last tab shrinks the
/// window to exactly that; a recorder that wrote down every width it saw
/// would take a sidebar the user had dragged to 340 and store 200 in its
/// place, having been told nothing by the user at all.
///
/// So a width is only written when the container it sits in is the same
/// width it was — a divider drag moves the sidebar inside a container that
/// does not move, and every squeeze comes from a container that does. The
/// comparison is between SETTLED samples, not between consecutive ones:
/// during a window resize the two widths change in whatever order SwiftUI
/// delivers them, and a pair caught mid-resize can show a still-old
/// container beside an already-squeezed sidebar. Waiting for the whole
/// thing to stop and comparing the endpoints has no such ordering to get
/// wrong.
///
/// The first settled sample after this view is built is never written: it
/// is the width the window opened at, which is where it came from.
///
/// Disk cost: `SettingsStore` writes the whole settings.json on every
/// assignment, and a divider drag produces a layout pass per mouse point.
/// The settle interval is what keeps those apart — a drag costs ONE write,
/// when the pointer comes to rest, not one per point crossed.
private struct SidebarWidthRecorder: View {
    let settingsStore: SettingsStore
    let sample: SidebarWidthSample

    /// The last sample that survived the settle interval — the baseline the
    /// next settled one is judged against. `nil` until the first one
    /// settles, which is why the opening width is never written back.
    @State private var settled: SidebarWidthSample?

    /// Long enough to sit out a drag (the pointer keeps moving, so the task
    /// keeps restarting) and a window resize, short enough that letting go
    /// of the divider and quitting straight afterwards still saves the
    /// width.
    private static let settleSeconds = 0.4

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: sample) {
                try? await Task.sleep(for: .seconds(Self.settleSeconds))
                guard !Task.isCancelled else { return }
                // A pass that measured nothing is not a sample at all: let
                // it become the baseline and the real measurement arriving
                // after it would read as the user having dragged the
                // sidebar down to nothing.
                guard sample.sidebar > 0 else { return }
                let previous = settled
                settled = sample
                guard let previous, previous.container == sample.container else { return }
                let width = Int(sample.sidebar.rounded())
                guard width != settingsStore.sidebarWidth else { return }
                settingsStore.sidebarWidth = width
            }
    }
}

/// The lost-connection surface (connection-liveness plan, Task 7): what
/// happened, and the way back. Shown instead of `ConnectionFormView` while
/// `ConnectionSurfacePlan.surface(for:hostKeyPromptPending:connectAttemptFailed:)`
/// answers
/// `.lost`.
///
/// Every string on it comes from `LostConnectionContent`, which holds
/// catalog keys and nothing else — see that type's own doc comment for why
/// the design spec's "no secret, no user-typed value" rule is a property of
/// the type here rather than a rule someone has to remember. In particular
/// this surface does NOT show the host, the account, the failure text the
/// server sent, or anything from the form.
private struct LostConnectionView: View {
    let content: LostConnectionContent
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(DesignTokens.statusLost)
            Text(L10n.string(content.title.key, content.title.fallback))
                .font(.title2.bold())
            Text(L10n.string(content.body.key, content.body.fallback))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint = content.hint {
                Text(L10n.string(hint.key, hint.fallback))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                if let reconnect = content.reconnectButton {
                    Button(L10n.string(reconnect.key, reconnect.fallback), action: onReconnect)
                        .buttonStyle(.polished)
                }
                Button(
                    L10n.string(content.dismissButton.key, content.dismissButton.fallback),
                    action: onDismiss)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
    }
}

/// The failed-connect surface (failed-connect surface plan, Task 3): the
/// attempt did not get through, and what can be done about it. Shown
/// instead of `ConnectionFormView` while `ConnectionSurfacePlan
/// .surface(for:hostKeyPromptPending:connectAttemptFailed:)` answers
/// `.failed`.
///
/// The maintainer's own words for why it exists: after a real timeout
/// against an unreachable host, the connection form simply came back, and
/// being handed the entry mask again reads as "nothing happened" rather
/// than as an answer.
///
/// Every string on the surface itself comes from `ConnectFailureContent`,
/// which holds catalog keys and nothing else — the same property
/// `LostConnectionView` has, for the same reason, and
/// `ReconnectWiringGuardTests` scans this body to keep it true. The one
/// piece of text that is NOT a catalog key is the technical message, and it
/// is not on this surface: it lives behind the details control, in a dialog
/// of its own (`ConnectFailureDetailsSheet`, in its own file so that this
/// view cannot read the string at all), which is the maintainer's
/// decision — a general sentence here, everything precise one click away
/// for debugging.
private struct ConnectFailureView: View {
    let content: ConnectFailureContent
    /// The technical text, or `nil` when the layer below published none —
    /// in which case the details control is not offered at all rather than
    /// opening an empty dialog.
    ///
    /// An opaque `ConnectFailureDetailText`, not a `String`, and that is
    /// the whole point: this view tests it for `nil` and hands it to the
    /// dialog. Naming its string here does not compile, and reflecting it
    /// here — which does compile, and used to print the server's own
    /// message — now yields a placeholder. See that type's own doc comment
    /// for where exactly that boundary runs, and for why a `String?` here,
    /// which is what round 1 had, gave this surface the structural
    /// guarantee and the raw server text side by side.
    let details: ConnectFailureDetailText?
    let onRetry: () -> Void
    let onEdit: () -> Void
    let onEditSession: () -> Void
    let onClose: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(DesignTokens.statusLost)
            Text(L10n.string(content.title.key, content.title.fallback))
                .font(.title2.bold())
            Text(L10n.string(content.body.key, content.body.fallback))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if let retry = content.retryButton {
                    Button(L10n.string(retry.key, retry.fallback), action: onRetry)
                        .buttonStyle(.polished)
                }
                Button(
                    L10n.string(content.editButton.key, content.editButton.fallback),
                    action: onEdit)
                if let editSession = content.editSessionButton {
                    Button(
                        L10n.string(editSession.key, editSession.fallback),
                        action: onEditSession)
                }
                Button(
                    L10n.string(content.closeButton.key, content.closeButton.fallback),
                    action: onClose)
            }
            if details != nil {
                Button(
                    L10n.string(content.detailsButton.key, content.detailsButton.fallback)
                ) {
                    showsDetails = true
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
        .sheet(isPresented: $showsDetails) {
            if let details {
                ConnectFailureDetailsSheet(
                    title: content.detailsTitle, details: details,
                    onClose: { showsDetails = false })
            }
        }
    }
}

/// "Connecting…" with a Cancel control (connection-liveness plan, Task 6) —
/// shown instead of `ConnectionFormView` while `ConnectionSurfacePlan
/// .surface(for:hostKeyPromptPending:connectAttemptFailed:)` answers
/// `.connecting`. The design
/// spec's own framing for this surface
/// (`docs/superpowers/specs/2026-08-21-connection-state-design.md` §4):
/// the connection attempt becomes a cancellable task on the same tab area,
/// so the rest of the window — other tabs, the sidebar once this one's own
/// dial ends — stays usable instead of the tab looking like a dead modal
/// with nothing to click.
///
/// The headline has its OWN catalog key (`connection.connecting.title`,
/// fix round 1) rather than reusing the tab-strip dot's tooltip key
/// (`tabs.liveness.connectingHelp`, Task 5): the two read the same today,
/// but a tooltip and a headline are different UI roles that can legitimately
/// need different wording later, and sharing one key would silently change
/// this surface's text the next time someone edits the dot's tooltip for
/// its OWN reasons.
private struct ConnectingAttemptView: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.string("connection.connecting.title", "Connecting…"))
                .font(.title2.bold())
            Text(L10n.string(
                "connection.connecting.body",
                "macSCP is waiting for the host to respond."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.string("common.cancel", "Cancel"), action: onCancel)
                .buttonStyle(.polished)
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
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
        // docs/superpowers/specs/2026-08-10-snippets-round-2-design.md,
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
    /// Mostly untested, like `TerminalPanelHeader.body` itself: this
    /// project has no SwiftUI rendering harness (`TerminalPanelHeader`'s
    /// own doc comment states the boundary already). The gesture split
    /// between single/double click, the hover line's content, row
    /// selection highlighting, and `hoveredRow`'s clearing when the search
    /// filter drops its row cannot be observed by a test; `SnippetListPlan`
    /// (Task 1, tested in `macSCPCoreTests`), `TerminalSnippetSearch`
    /// (tested below), and — since the final fix pass — the row context
    /// menu's contents (`SnippetRowContextMenu`, rendered into a real
    /// `NSMenu` by `TerminalContextMenuTests`) are.
    @ViewBuilder
    private var snippetPopover: some View {
        let (sections, searchError) = filteredSections(text: searchText, isRegex: searchIsRegex)
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
                // Dismiss, then trigger on the NEXT runloop turn — not in
                // the same closure. `onRunSnippet` can itself request a new
                // presentation: the multi-line-insert refusal alert, and
                // since snippet variables, the value prompt SHEET. Clearing
                // the two flags does not take the popover off screen; that
                // happens when SwiftUI next applies state. Requesting a
                // sheet before it does means asking to present over a
                // popover that is still up, and the request is dropped
                // without a trace.
                //
                // An earlier version did the dismissals first and called
                // straight through, with a comment claiming that put the
                // request "in its own update cycle". It did not — one
                // closure is one update. The alert survived it; the sheet
                // did not, which is how this surfaced (maintainer report,
                // 2026-08-21: via the terminal's snippet button neither
                // Insert nor Execute did anything once the snippet declared
                // a variable).
                onInsert: {
                    actionSheetSnippet = nil
                    isSnippetPopoverPresented = false
                    DispatchQueue.main.async { onRunSnippet(snippet, false) }
                },
                onExecute: {
                    actionSheetSnippet = nil
                    isSnippetPopoverPresented = false
                    DispatchQueue.main.async { onRunSnippet(snippet, true) }
                },
                onCancel: { actionSheetSnippet = nil }
            )
        }
        // The search field (or the regex toggle beside it) can narrow
        // `sections` out from under an active hover: `snippetRow(_:)`'s own
        // `onHover` only clears `hoveredRow` when THAT row's view reports
        // the pointer leaving it, and a row that just got filtered out of
        // existence never gets the chance to report anything. Recomputed
        // here, at the same filtered-set computation `filteredSections`
        // already does for the body above, rather than a second piece of
        // state tracking whether the existing one has gone stale.
        .onChange(of: searchText) { _, _ in clearHoveredRowIfFilteredOut() }
        .onChange(of: searchIsRegex) { _, _ in clearHoveredRowIfFilteredOut() }
    }

    /// The narrowed, grouped, per-row shape `snippetPopover` renders —
    /// pulled out of that view's body so `clearHoveredRowIfFilteredOut()`
    /// can recompute the identical filtered set without duplicating the
    /// search predicate, `SnippetMenuModel.build` and `SnippetListPlan.build`
    /// pipeline a second time.
    private func filteredSections(
        text: String, isRegex: Bool
    ) -> (sections: [SnippetListPlan.Section], searchError: String?) {
        let (predicate, searchError) = sheetSearchPredicate(text: text, isRegex: isRegex)
        let visibleSnippets = TerminalSnippetSearch.matching(snippets, predicate: predicate)
        let model = SnippetMenuModel.build(
            snippets: visibleSnippets, isConnected: true, supportsShell: supportsShell)
        return (SnippetListPlan.build(model: model), searchError)
    }

    /// `hoveredRow`'s row can vanish from `sections` when the search text
    /// or the regex toggle changes without the pointer moving at all — see
    /// `snippetPopover`'s `.onChange` doc comment for why `onHover` alone
    /// cannot catch this. Leaves `hoveredRow` untouched when it is `nil`
    /// already or its row is still present, so a hover that survives the
    /// search narrowing keeps showing its command uninterrupted.
    private func clearHoveredRowIfFilteredOut() {
        guard let hovered = hoveredRow else { return }
        let (sections, _) = filteredSections(text: searchText, isRegex: searchIsRegex)
        let stillVisible = sections.contains { $0.rows.contains { $0.id == hovered.id } }
        if !stillVisible {
            hoveredRow = nil
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
                SnippetRowContextMenu(
                    row: row,
                    // Same shape, and the same reason, as the action
                    // sheet's onInsert/onExecute above: dismiss here, and
                    // let the trigger run once SwiftUI has actually taken
                    // the popover down, so a sheet or alert `onRunSnippet`
                    // asks for is not aimed at a screen the popover still
                    // owns.
                    onExecute: {
                        isSnippetPopoverPresented = false
                        DispatchQueue.main.async { onRunSnippet(row.snippet, true) }
                    },
                    onInsert: {
                        isSnippetPopoverPresented = false
                        DispatchQueue.main.async { onRunSnippet(row.snippet, false) }
                    },
                    onPreview: { previewPinnedRow = row }
                )
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
        let text: String
        if let command = SnippetPreviewLine.row(hovered: hoveredRow, pinned: previewPinnedRow)?
            .snippet.command
        {
            let summary = SnippetCommandSummary.firstLine(of: command)
            if summary.moreLines > 0 {
                text = summary.text + " " + String(
                    format: L10n.string("snippets.command.moreLines %lld", "+%lld more"),
                    summary.moreLines)
            } else {
                text = summary.text
            }
        } else {
            text = L10n.string("snippets.list.hoverHint", "Point at a snippet to see its command.")
        }
        return Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

/// The row context menu's content (P3d, Task 3), pulled out of
/// `TerminalPanelHeader.snippetRow(_:)` for the same reason
/// `TerminalSnippetSearch` and `SnippetPreviewLine` were pulled out below: a
/// standalone type `Tests/macSCPAppKitTests/` can render on its own, rather
/// than a menu built inline in a view body where nothing can observe its
/// structure. `TerminalContextMenuTests` renders it into a real `NSMenu` via
/// `NSHostingMenu`, the same technique that suite already uses for
/// `SnippetMenuItems`.
///
/// Execute and Insert are gated on `!row.isDisabled` — a disabled row (no
/// connection, or a backend with no shell) still shows what it would do,
/// it just cannot be made to do it, matching `SnippetMenuItems`'
/// `.disabled(entry.isDisabled)` on its own per-snippet `Menu`. Preview
/// stays offered regardless: it only reveals the command text, the same
/// thing hovering already does, so there is nothing here a disabled row
/// needs protecting from.
struct SnippetRowContextMenu: View {
    let row: SnippetListPlan.Row
    let onExecute: () -> Void
    let onInsert: () -> Void
    let onPreview: () -> Void

    var body: some View {
        if !row.isDisabled {
            Button(L10n.string("menu.snippets.execute", "Execute"), action: onExecute)
            Button(L10n.string("menu.snippets.insert", "Insert"), action: onInsert)
        }
        Button(L10n.string("snippets.list.preview", "Preview"), action: onPreview)
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
