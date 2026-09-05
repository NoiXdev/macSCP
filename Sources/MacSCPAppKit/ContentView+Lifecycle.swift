import AppKit
import SwiftUI
import macSCPCore

/// Tab lifecycle and window setup split out of `ContentView.swift`: appearance
/// lifecycle/toolbar wiring, tab construction/teardown, the window's one-time
/// setup pass, the menu-bar and window-presence bridges, and window geometry
/// (resize/shrink).
///
/// Extraction only (no behavior change) -- see `ContentView.swift` for the
/// surrounding state and the rest of the window's modifier groups.
extension ContentView {
    /// Appearance lifecycle, the toolbar, and the settings observers that keep
    /// live state in sync after `performWindowSetup()` seeded it.
    /// 
    /// See `windowChrome(_:)` for why these are grouped.
    func lifecycleAndToolbar<Content: View>(_ content: Content) -> some View {
        content
        // never resurface as a stale, unrequested dialog the next time a
        // fresh window opens.
        // Only the PRIMARY window claims to be the presenter: it is the one
        // that attaches the alert (`ContentView+Sheets.swift`), so a
        // detached window saying "yes, somebody is mounted" would send a
        // manual check's result to an alert nobody shows, instead of to
        // `UpdateCheckModel`'s own `NSAlert` fallback.
        .onAppear { if isPrimaryWindow { updateModel.hasPresentationTarget = true } }
        .onDisappear {
            if isPrimaryWindow {
                updateModel.hasPresentationTarget = false
                updateModel.presentedResult = nil
            }
        }
        // Session actions live in the window's native toolbar (M5f/T5) —
        // attached at the outer container so it belongs to the window, not
        // the detail pane. Empty (no items) while the active tab is
        // disconnected.
        .toolbar {
            if let session = activeTab.session {
                ToolbarItemGroup(placement: .primaryAction) {
                    uploadButton(in: activeTab, session: session)
                    downloadButton(in: activeTab, session: session)
                    // Files toggle (P2 terminal-chrome milestone, Task 3):
                    // the pane pair's second half, next to Terminal below.
                    // No keyboard shortcut — ⌘T stays on Terminal, and
                    // nothing has asked for one here yet. Both toggles read
                    // their on/enabled state from `SessionTab.paneToggleState`,
                    // which asks `PaneVisibility` (Task 2) rather than
                    // re-deriving the "last visible half is locked" rule —
                    // see that method's doc comment.
                    Button {
                        activeTab.applyFilesToggleClick(
                            terminalIsVisible: session.terminal.isVisible,
                            hasShell: activeTabSupportsShell)
                        persistActivePaneVisibility()
                    } label: {
                        Label(L10n.string("browser.filesToggle", "Files"), systemImage: "folder")
                    }
                    .disabled(!activeTab.paneToggleState(
                        for: .files, terminalIsVisible: session.terminal.isVisible,
                        hasShell: activeTabSupportsShell
                    ).isEnabled)
                    .help(L10n.string("browser.filesToggleHelp", "Show/hide files"))
                    Button {
                        // Capability guard (M12/T7b): re-checked here too,
                        // same belt-and-suspenders rationale as the
                        // `tabCommands.toggleTerminal`/`openExternalTerminal`
                        // closures — the button/⌘T are already disabled
                        // below for a non-shell backend, but a silent no-op
                        // is never the fallback (spec).
                        guard activeTabSupportsShell else {
                            presentTerminalUnavailable()
                            return
                        }
                        // ⌘T/toolbar follow the setting (spec §4 item 5):
                        // `.builtIn` toggles the panel exactly like before
                        // this feature existed, anything else opens
                        // externally. Both routes stay reachable regardless
                        // — the "Terminal" menu (`tabCommands`) always
                        // offers the other one too. In `.builtIn` mode this
                        // ALSO re-checks the pane lock (Task 3): the
                        // `.disabled` below already blocks the click when
                        // Files is hidden and terminal is the only visible
                        // half, but external-terminal mode never touches
                        // `isVisible` at all, so the lock check only
                        // matters for this branch.
                        if settingsStore.terminalTarget == .builtIn {
                            guard activeTab.paneToggleState(
                                for: .terminal, terminalIsVisible: session.terminal.isVisible,
                                hasShell: activeTabSupportsShell
                            ).isEnabled else { return }
                            session.terminal.toggle()
                            persistActivePaneVisibility()
                        } else {
                            requestExternalTerminal(for: activeTab)
                        }
                    } label: {
                        Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(settingsStore.terminalTarget == .builtIn
                        ? !activeTab.paneToggleState(
                            for: .terminal, terminalIsVisible: session.terminal.isVisible,
                            hasShell: activeTabSupportsShell
                        ).isEnabled
                        : !activeTabSupportsShell)
                    .help(settingsStore.terminalTarget == .builtIn
                        ? L10n.string("browser.terminalToggleHelp", "Show/hide terminal (⌘T)")
                        : L10n.string("browser.terminalOpenExternalHelp", "Open in external terminal (⌘T)"))
                    Button {
                        activeTab.transfersPanelVisible.toggle()
                    } label: {
                        Label(L10n.string("browser.transfersToggle", "Transfers"),
                              systemImage: "tray.full")
                    }
                    .help(L10n.string("browser.transfersToggleHelp",
                                      "Show/hide transfers (⌘⇧Y)"))
                    // Diagnostics (design §1, the tab's door — its toolbar
                    // surface; the failed-connect surface is the other):
                    // offered
                    // while connected, because "it connects but it is slow /
                    // it drops" is as much a question for the probes as "it
                    // will not connect at all". Never disabled — every step
                    // is measured fresh, and the answer to a connection that
                    // is behaving badly is the same walk as for one that
                    // never came up.
                    //
                    // The click OPENS the panel; it measures nothing. That
                    // split is the decision of 2026-09-02 and belongs to
                    // `showDiagnostics(for:)`, which every other door calls
                    // too.
                    Button {
                        showDiagnostics(for: .tab(activeTab))
                    } label: {
                        Label(
                            L10n.string("diagnostics.menu", "Diagnose…"),
                            systemImage: "stethoscope")
                    }
                    .help(L10n.string(
                        "diagnostics.menuHelp", "Check this connection and copy a report"))
                    Button(L10n.string("browser.disconnect", "Disconnect")) {
                        disconnectToForm(activeTab)
                    }
                    .disabled(activeTab.transferQueue.isActive)
                }
            }
        }
        // Settings live-wiring (M5c/T4+T5): the concurrency observer targets
        // EVERY tab's queue (M8a/T3), the limit observers the shared limiter.
        // A change affects FUTURE slot assignments/items only — see the
        // properties' doc comments in `TransferQueueViewModel`.
        .onChange(of: settingsStore.maxConcurrentTransfers) { _, newValue in
            for tab in tabsModel.tabs {
                tab.transferQueue.maxConcurrent = newValue
            }
        }
        .onChange(of: settingsStore.uploadLimitKBs) { _, newValue in
            bandwidthLimiter.uploadLimitBytesPerSec = newValue * 1024
        }
        .onChange(of: settingsStore.downloadLimitKBs) { _, newValue in
            bandwidthLimiter.downloadLimitBytesPerSec = newValue * 1024
        }
        // Hidden-files toggle (M7a/T4): applies to the panes of EVERY
        // connected tab (M8a/T3), not just the active one — a background tab
        // would otherwise show a stale listing when it comes forward.
        .onChange(of: settingsStore.showHiddenFiles) { _, newValue in
            for tab in tabsModel.tabs {
                guard let session = tab.session else { continue }
                session.local.showHiddenFiles = newValue
                session.remote.showHiddenFiles = newValue
                Task {
                    await session.local.refresh()
                    await session.remote.refresh()
                }
            }
        }
        // Keeps `menuBarModel.tabs` synced with the window's tab list
        // (M11n/T2) — `SessionTab` is a class (`Identifiable`, not
        // `Equatable`), so `[SessionTab]` itself can't drive `.onChange`
        // directly; `tabIDs` (an `Equatable` proxy for "the tab set changed":
        // add/close/reorder) drives it instead, and the handler re-reads the
        // full array from `tabsModel.tabs`. Extracted as a typed computed
        // property (not an inline `.map(\.id)`) — inlined here it pushed the
        // surrounding modifier chain over the type checker's "reasonable
        // time" budget (same failure class as `passwordHintPresented` in
        // `ContentView+Sheets.swift`).
        .onChange(of: tabIDs) { _, _ in
            publishToMenuBarIfKey()
            // Detachable Tabs plan, Task 2: a tab that arrived by any route
            // (⊕, ⌘N, a sidebar row, a claim) is registered to this window,
            // and the Window menu's move entry follows the count it is
            // disabled on. Both are cheap and idempotent — see
            // `registerHeldTabs()`.
            registerHeldTabs()
            tabCommands.canMoveTabToNewWindow = tabsModel.tabs.count > 1
            // A window that has just lost its last tab, or gained its
            // first, changes `TabRegistry.windowCount` — which is what the
            // Settings pane's entries are enabled on (fix round 2).
            updateMainWindowPresence()
        }
        // The menu-bar status item shows the KEY window's tabs (Detachable
        // Tabs plan, Task 2 fix round 1) — see `publishToMenuBarIfKey()`.
        // `initial: true` publishes at first render too, so the item is not
        // empty until the first activation.
        .onChange(of: controlActiveState, initial: true) { _, _ in
            publishToMenuBarIfKey()
        }
    }

    // MARK: - Tab lifecycle

    /// Mutable box carrying the `SessionTab` a connector closure belongs to —
    /// filled in immediately after that tab is constructed, in `makeTab`
    /// below. Needed because the closure is built and handed to
    /// `ConnectionViewModel.init` BEFORE the `SessionTab` that will own it
    /// exists, so it cannot simply capture the tab the way
    /// `ConnectionViewModel.connectSSH()` captures its OWN `self` to build
    /// the host-key decider (see `CertificatePromptBridge`'s own doc
    /// comment).
    ///
    /// `@unchecked Sendable`: `tab` is written exactly once, synchronously,
    /// right after `SessionTab.init` returns and before `makeTab` returns —
    /// by the time the connector closure can actually run (the earliest is a
    /// later, user-triggered `connect()`), the box is already stable. Every
    /// read of `tab` funnels straight into `SessionTab`'s own
    /// `@MainActor`-isolated interface (`await`ed methods), never touching
    /// its state directly from here.
    final class SessionTabBox: @unchecked Sendable {
        var tab: SessionTab!
    }

    /// Builds a fresh form tab: own connection view model, own queue (wired
    /// once here to the shared limiter, the settings concurrency and the
    /// tab's OWN conflict bridge). Static so `init` can seed `tabsModel`
    /// with the window's first tab.
    static func makeTab(
        settingsStore: SettingsStore, limiter: BandwidthLimiter
    ) -> SessionTab {
        let certificateBridge = CertificatePromptBridge()
        let box = SessionTabBox()
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { config, decider in
                // Plaintext confirmation (M21/T10): asked BEFORE dispatching
                // anything, so a refusal never opens a connection at all.
                // Reset first (see `pendingPlaintextConfirmation`'s own doc
                // comment on why), then set only on an actual confirm.
                await box.tab.resetPendingPlaintextConfirmation()
                if PlaintextTransportGate.requiresConfirmation(for: config) {
                    guard await box.tab.confirmPlaintext() else {
                        throw RemoteFSError.connectionFailed(
                            reason: "the user declined to send credentials over an unencrypted connection")
                    }
                    await box.tab.markPlaintextConfirmed()
                }
                // Certificate decider (M21/T10): unknown WebDAV/S3
                // certificates now reach `CertificatePromptView` instead of
                // being refused outright, which is what the command-line
                // driver still does for want of an interactive prompt (see
                // `MacSCPCLI/SessionConnecting.swift`). A MISMATCH
                // never reaches `certificateBridge.ask`
                // in the first place — `WebDAVSessionDelegate
                // .decideCertificate` refuses it before ever consulting the
                // decider — and surfaces instead as a thrown
                // `ServerCertificateError.mismatch`, which
                // `ConnectionViewModel.failedState(for:)` already maps to its
                // own honest, localized alert text (mirrors `HostKeyError`
                // case for case): nothing to intercept here.
                // Since M22/T10 each backend opens its own connection: the
                // descriptor's own connect closure is what carries SSH's
                // known-hosts store and WebDAV's trust store, so there is no
                // central dispatcher left to route through. That closure is
                // module-internal to Core; `openConnection` is the only way
                // into it from here, which is why this call cannot be
                // written any other way.
                //
                // Read HERE, at the moment this connect attempt actually
                // runs, not once at `makeTab` time: capturing the `Int` up
                // front would have baked in whatever the setting was when
                // the tab was CREATED, silently ignoring any later change
                // (the Settings UI is what makes that observable).
                //
                // Hop explicitly instead of reading `settingsStore` — which
                // is `@MainActor` — as if this closure were already on that
                // actor. `Connector` is a nonisolated `@Sendable` function
                // type, so whether the closure counts as main-actor-isolated
                // is left to closure-isolation inference, and that inference
                // differs between toolchains: the direct read compiles under
                // Swift 6.3 and is rejected by the older compiler CI builds
                // with. `MainActor.run` is accepted by both and costs
                // nothing when the caller already is the main actor, which
                // it always is here (`ConnectionViewModel` is `@MainActor`).
                let connectTimeoutSeconds = await MainActor.run {
                    settingsStore.connectTimeoutSeconds
                }
                return try await BackendDescriptor.openConnection(
                    config, hostKey: decider,
                    certificate: .asking { candidate in await certificateBridge.ask(candidate) },
                    timeoutSeconds: connectTimeoutSeconds)
            }),
            certificateBridge: certificateBridge,
            limiter: limiter,
            maxConcurrent: settingsStore.maxConcurrentTransfers
        )
        box.tab = tab
        return tab
    }

    func makeTab() -> SessionTab {
        Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)
    }

    /// A fresh tab that `window` already owns (Detachable Tabs plan, Task 3
    /// fix round 1).
    ///
    /// The window is a parameter rather than `windowID`, because the one
    /// caller that is NOT about this window is the one that matters:
    /// `acceptDroppedTab(_:)` builds the replacement tab that stands in for
    /// a tab dragged OUT of the source window, and it must land in that
    /// window's registry entry, not in the receiving window's. A helper
    /// that assumed `windowID` would have been silently wrong exactly
    /// there.
    ///
    /// Only the registry is written: the model this tab goes into is
    /// `TabDetachSequence`'s to add to, which is why this is not
    /// `addTabRegistering(_:)` below.
    func makeTab(registeringIn window: WindowID) -> SessionTab {
        let tab = makeTab()
        TabRegistry.shared.register(tab, in: window)
        return tab
    }

    /// The one way a tab enters THIS window (Detachable Tabs plan, Task 3
    /// fix round 1): into the model and into the registry, in one
    /// statement. See `TabAdmission` for why the pair is written once
    /// rather than at each of the five sites that make a tab, and
    /// `TabRegistrationWiringGuardTests` for what holds it to that.
    func addTabRegistering(_ tab: SessionTab) {
        TabAdmission.add(tab, to: tabsModel, in: TabRegistry.shared, window: windowID)
    }

    /// "Duplicate Tab"'s own admission: the same door, placing the arriving
    /// tab right after `sourceTab` instead of at the far end of the strip.
    /// Still the one route a tab enters this window by — it reaches
    /// `TabAdmission.add` exactly as `addTabRegistering(_:)` does, with the
    /// source tab's id forwarded as `after:`.
    func addTabRegistering(_ tab: SessionTab, after sourceTab: SessionTab) {
        TabAdmission.add(
            tab, to: tabsModel, in: TabRegistry.shared, window: windowID, after: sourceTab.id)
    }

    /// Attaches this tab's audit recorder once it connects to a STORED
    /// session (M9b/T3) — called from both places `activeStoredSessionID`
    /// gets assigned: `connect(in:stored:)` and `startSession`'s "Save &
    /// connect" path. Never called for an ad-hoc connect. Must run AFTER
    /// `tab.session` is populated (`startSession` always sets it first), so
    /// `tab.session?.remote.auditSink` below has something to wire.
    ///
    /// The recorder is captured by value in both closures (it's a plain
    /// `Sendable` struct over `sessionID` + `auditStore`); the queue sink
    /// additionally resolves a finished item's `destinationTabID` against
    /// `tabsModel` to the target tab's `displayTitle` for the
    /// cross-session-transfer detail — a target tab that's already gone
    /// resolves to `nil`, which `AuditRecorder.recordTransfer` renders as
    /// "unknown session".
    func attachAuditRecorder(
        to tab: SessionTab, sessionID: UUID, summary: String,
        viaJumpHost: String? = nil
    ) {
        let recorder = AuditRecorder(sessionID: sessionID, store: auditStore)
        tab.auditRecorder = recorder
        recorder.recordConnected(summary: summary, viaJumpHost: viaJumpHost)
        // Plaintext-transport audit trail (M21/T10): the connector closure
        // set this right after the user confirmed connecting over
        // `http://`; this is the first point afterward where a `sessionID`
        // (and with it, a recorder) exists to log it against. See
        // `SessionTab.pendingPlaintextConfirmation`'s own doc comment for
        // why it is safe to consume unconditionally here.
        if tab.pendingPlaintextConfirmation {
            recorder.recordAction(AuditEvent(
                kind: .plaintextConfirmed,
                detail: "connected without TLS after an explicit confirmation"))
            tab.pendingPlaintextConfirmation = false
        }
        // The destination of a cross-session transfer is resolved through
        // `TabRegistry`, not through this window's model (Detachable Tabs
        // plan, Task 3 fix round 1). The model answer was right only while
        // every tab lived in one window: once a tab can be moved or dragged
        // into another one, the target of a transfer that is still running
        // is routinely in a DIFFERENT window's model, and this closure would
        // resolve it to `nil` — which `AuditRecorder.recordTransfer` renders
        // as "unknown session". The registry knows every live tab in every
        // window, so it answers for both cases and for neither wrongly; a
        // tab already released (closed, or its window closed) still resolves
        // to `nil`, which is the honest answer there.
        //
        // The old `[weak tabsModel]` capture is gone with the lookup it
        // served (M9b/T4 review, finding 5, which existed because this sink
        // is retained by `tab.transferQueue` for the tab's whole lifetime
        // and a strong capture would have pinned every `@State` box on
        // `ContentView` alive). Nothing of `ContentView` is captured here
        // any more — `recorder` is a plain `Sendable` struct and
        // `TabRegistry.shared` is a process-wide singleton — so the concern
        // it answered no longer arises rather than being answered again.
        tab.transferQueue.auditSink = { item in
            let targetTitle = item.destinationTabID.flatMap { id in
                TabRegistry.shared.tab(for: id)?.displayTitle
            }
            recorder.recordTransfer(item, targetTitle: targetTitle)
        }
        tab.session?.remote.auditSink = { event in recorder.recordAction(event) }
    }

    /// This window's route into the one teardown owner, `TabTeardown.run(
    /// _:reason:)` — plus the one step of a tab's teardown that needs the
    /// WINDOW rather than the tab.
    ///
    /// The four-stage order (`cancelAll` → `editManager.stopAll` →
    /// `terminal.shutdown` → `remote.disconnect`) and everything it resets
    /// live in `TabTeardown`, which is where the App's quit reaches them
    /// too: `AppDelegate` has no `ContentView`, and neither has a tab parked
    /// for a window that never appeared. See that type's doc comment for the
    /// order, the bounds, and what each reset is for.
    ///
    /// `stopDiagnostics(of:)` is what stayed here, and it could not move:
    /// it reads `ContentView.diagnostics`, this window's own
    /// `DiagnosticsPresenter`, which nothing on the tab can reach. It stops
    /// the RUN and leaves the panel up — see `DiagnosticsPresenter
    /// .stopRun(openedFor:)` for why stopping and dismissing are two
    /// different decisions on a path that also runs for a liveness give-up
    /// nobody asked for.
    ///
    /// **Its callers, counted at this commit** (2026-09-05, `grep -n "await
    /// teardown(" Sources/MacSCPAppKit/*.swift`): eight `await teardown(`
    /// call sites, in eight functions. Seven of them are a deliberate
    /// "leave this connection" and pass `.userRequested` —
    /// `disconnectToForm` (the toolbar "Disconnect" button), `performClose`
    /// (closing a tab), `performCloseOthers` (closing every other tab), the
    /// reconnect-in-place branch of `connect(in:stored:)`,
    /// `ConnectingAttemptView`'s `onCancel` in `ContentView+Detail.swift`,
    /// and the two close-path loops in this file, `tearDownHeldTabs(_:from:)`
    /// and `tearDownUnclaimedSeeds(_:)`. The eighth is
    /// `handleLivenessGiveUp(_:)` below, the only one that passes
    /// `.connectionLost` and the only one that is not a user action.
    ///
    /// The count matters to `DiagnosticsLifecycleTests`, which drives
    /// `handleLivenessGiveUp` by name and the others by their shape —
    /// `teardown` of a tab the panel was not opened for — rather than by
    /// calling `performCloseOthers` or the reconnect branch. So an
    /// `endDiagnostics()` added back into either of those two for tidiness
    /// goes red nowhere.
    ///
    /// The app's quit does NOT come through here: it runs each window's
    /// registered closure, which reaches the same two loops below, and
    /// reaches a parked tab through `TabTeardown.run` directly.
    func teardown(_ tab: SessionTab, reason: CancelReason) async {
        await TabTeardown.run(tab, reason: reason)
        stopDiagnostics(of: tab)
    }

    /// The liveness probe's own route off a session (connection-liveness
    /// plan, Task 4, fix round 3): `LivenessProbeRunner`'s `.giveUp` case
    /// calls this instead of inlining its own two statements, so the order
    /// that makes `.lost` observable afterward is a single, real function a
    /// test can call directly — this project has no way to run a
    /// `.task(id:)` closure embedded in a view body in a test, so the
    /// order used to be provable only by reading the source, which is
    /// exactly what let a previous round's reviewer swap these two lines
    /// and still pass every test.
    ///
    /// `teardown(_:)` clears `tab.liveness` to `nil` unconditionally (see
    /// that function's own doc comment) — writing `.lost` only AFTER this
    /// function's own call to it returns is what keeps this route's value
    /// from being cleared by that same reset.
    ///
    /// The stored session id is read BEFORE the teardown and written back
    /// after it (connection-liveness plan, Task 7): `teardown(_:)` clears
    /// `activeStoredSessionID` along with the session, so after it runs
    /// there is nothing left on the tab naming the connection that just
    /// dropped — and that id is exactly what "Reconnect" needs. Reading it
    /// first changes nothing about the order the two WRITES happen in,
    /// which is what `LivenessGiveUpOrderingTests` pins.
    func handleLivenessGiveUp(_ tab: SessionTab) async {
        let storedSessionID = tab.activeStoredSessionID
        // `reason: .connectionLost` (connection-liveness plan, Task 8): this
        // is the ONE call site that means an actual drop rather than a
        // deliberate disconnect, so the queue's own items read "connection
        // lost" instead of "cancelled" — see `teardown(_:reason:)`. Pinned
        // behaviorally by `LivenessGiveUpOrderingTests
        // .givingUpMarksQueuedTransfersConnectionLost` (fix round 1): that test
        // drives this exact path with real queue items and fails if this
        // literal is ever `.userRequested` instead.
        await teardown(tab, reason: .connectionLost)
        tab.lostConnection = LostConnection(
            reason: .probeGaveUp, storedSessionID: storedSessionID)
        tab.liveness = .lost
    }

    /// Activates a tab (strip click) and resets its attention indicator —
    /// visiting a tab acknowledges whatever failures it accumulated while in
    /// the background (M8a/T4 spec: reset on every activation call site).
    /// Guarded on the activation actually happening: `TabsViewModel.activate`
    /// no-ops for a stale/unknown id, and the reset must never fire for a
    /// tab the user did not actually visit.
    func activate(_ id: UUID) {
        tabsModel.activate(id)
        guard tabsModel.activeTabID == id else { return }
        tabsModel.activeTab.seenFailureCount = tabsModel.activeTab.transferQueue.totalFailureCount
    }

    /// ⌘1–⌘9 target: 1-indexed, no-op outside the current tab range.
    func selectTab(atIndex index: Int) {
        guard tabsModel.tabs.indices.contains(index) else { return }
        activate(tabsModel.tabs[index].id)
    }

    /// Everything this window does once, when it first appears: reading the
    /// SSH config inventory, seeding the bandwidth limiter, the due-check for
    /// updates, and wiring the menu-bar and menu-command bridges.
    ///
    /// A method rather than an inline `.task` closure, and deliberately so:
    /// see the comment at the call site. Nothing here is async -- the work is
    /// synchronous setup, and `.task` is only the hook that runs it once per
    /// window appearance.
    func performWindowSetup() {
        // Full inventory, read once (M11f/T2) — `refreshImportedHosts()`
        // below (and every later hide/unhide) re-splits THIS instead of
        // re-parsing the config file.
        fullImportedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath)
        refreshImportedHosts()
        // Seed the shared limiter from the settings once per window; the
        // `.onChange` observers below keep it in sync afterwards. KBs → bytes/s.
        bandwidthLimiter.uploadLimitBytesPerSec = settingsStore.uploadLimitKBs * 1024
        bandwidthLimiter.downloadLimitBytesPerSec = settingsStore.downloadLimitKBs * 1024
        // Startup automatic update check (M11b/T2, spec §3): fires at
        // most once a day and only if due — `checkAutomaticallyIfDue`
        // no-ops instantly when disabled or not yet due, and otherwise
        // starts its own detached `Task`, so this never blocks the
        // window from appearing. `isChecking`'s synchronous guard (see
        // `UpdateCheckModel`) keeps this safe even if a second window
        // somehow ran this same `.task` concurrently.
        updateModel.checkAutomaticallyIfDue(settingsStore: settingsStore)
        // Menu-bar status bridge wiring (M11n/T2) — extracted into its
        // own method (like `refreshImportedHosts()` above) rather than
        // inlined here: this `.task` closure is already large enough
        // that the type checker times out on it (M11d/M11f review
        // precedent for this exact failure mode).
        publishToMenuBarIfKey()
        // Windows (Detachable Tabs plan, Task 2). Claim FIRST, register
        // second: `claimSeededTabs()` is what makes this window's model
        // hold the tabs it was opened for, and `registerHeldTabs()` is what
        // tells the registry which window every live tab belongs to — over
        // the model as it stands once the claim is done. A seedless window
        // (the primary one) claims nothing and simply registers its own
        // fresh tab.
        claimSeededTabs()
        // Restoration (Detachable Tabs plan, Task 5), after the claim and
        // before the registration, for the same reason the claim runs
        // where it does: what this window holds has to be settled before
        // the registry is told about it. The two are mutually exclusive by
        // construction — a seed carries live ids or described tabs, never
        // both — so exactly one of them ever changes this window's model.
        restoreDescribedWindow()
        // Only the primary window does this, and only once per launch.
        // `openWindow(value:)` is an environment value, which
        // `MacSCPApp.init` — where the seeds are read — cannot reach; this
        // is the earliest place that can.
        openRestoredWindows()
        registerHeldTabs()
        // Now that this window is counted, the Settings pane's answer can be
        // recomputed from the registry (fix round 2) — `WindowAccessor` may
        // have asked before this pass ran, when the count did not yet
        // include this window.
        updateMainWindowPresence()
        // Third, and only after the claim: a drop arriving in ANOTHER window
        // resolves this window's model through the registry (Detachable Tabs
        // plan, Task 3) — `TabRegistry.registerModel(_:for:)` holds it
        // weakly, and `releaseHeldTabsOnClose()` is where it is given up.
        TabRegistry.shared.registerModel(tabsModel, for: windowID)
        // Fourth: how this window describes itself, for the quit that
        // restores it (Detachable Tabs plan, Task 5 fix round 1). A
        // closure, asked once at `applicationWillTerminate`, because the
        // answer changes with every tab opened, closed or connected and a
        // stored value would have to be refreshed by all of them. Same
        // capture shape as the `TabCommands` closures in
        // `wireTabCommands()` below — what a captured `ContentView` copy
        // reaches is SwiftUI's own `@State` storage, not a snapshot.
        TabRegistry.shared.registerWindowDescriber({ describeThisWindow() }, for: windowID)
        // Fifth: what this window does to everything it holds when the APP
        // quits (Quit Teardown plan, Task 1). ⌘Q closes no window, so this
        // window's `willClose` handler never runs at quit and its two
        // close-time sweeps would never happen; this closure is the same
        // sequence in the same order, in the AWAITABLE form the quit needs
        // (`releaseUnclaimedSeedsOnClose()` and `releaseHeldTabsOnClose()`
        // both hand their teardown to a free `Task` — right for a
        // notification handler that cannot suspend, useless to a caller
        // that must know when it finished). Same capture shape as the
        // describer above.
        TabRegistry.shared.registerWindowTeardown({
            await releaseUnclaimedSeedsOnCloseAndWait()
            await releaseHeldTabsOnCloseAndWait()
        }, for: windowID)
        // Snippet list for the Terminal menu, read once per window — a
        // synchronous `snippets.json` read, which is why it is here and not
        // in `wireTabCommands()` below (Task 2 fix round 1: it briefly was,
        // and ran on every window activation). The management sheet's own
        // close is what refreshes it afterwards.
        reloadSnippets()
        // Command bridge wiring (M8a/T4) — a method rather than inline, for
        // the same type-checker reason as `publishToMenuBarIfKey()` above.
        wireTabCommands()
    }

    /// Fills in THIS window's own menu bridge, once, when the window
    /// appears.
    ///
    /// `MacSCPCommands` holds no reference to this view, so the menu items
    /// call back through the closures assigned here (M8a/T4). Every one of
    /// them used to open with a `window?.isKeyWindow` guard; none does now
    /// (Detachable Tabs plan, Task 2 fix round 1). `TabCommands` is per
    /// window and published as a focused scene value
    /// (`ContentView+Detail.swift`), so the menus can only ever reach the
    /// bridge of the window that is in front — being focused is the
    /// precondition for being called at all, rather than something each
    /// closure re-checks after the fact.
    ///
    /// That is also why this runs once rather than on every activation: a
    /// bridge nobody else writes into needs no refreshing, and the values
    /// mirrored onto it from `ContentView.body`'s `.onChange(…, initial:
    /// true)` observers describe this window and only this window.
    func wireTabCommands() {
        // Key-window guard (M8a T5 review, finding 1): the `Settings`
        // scene shares this exact ⌘N/⌘W/⌘1–9 command set (SwiftUI attaches
        // one `.commands` menu app-wide, not per window/scene), so with
        // Settings focused these closures would otherwise still fire
        // against THIS window's tabs instead of Settings — e.g. ⌘W would
        // tear down a tab instead of closing the Settings window. Each
        // closure checks that this window is actually key before acting.
        tabCommands.canMoveTabToNewWindow = tabsModel.tabs.count > 1
        // "Move Tab to New Window" (Detachable Tabs plan, Task 2) — the
        // Window menu's route to the same action the tab's context menu
        // offers. The entry is `.disabled` on `canMoveTabToNewWindow` set
        // just above, and this closure adds no second check of that count,
        // for the reason `handleTabMenuEntry` states.
        tabCommands.moveTabToNewWindow = {
            moveToNewWindow(tabsModel.activeTab)
        }
        // "Keep on Top" (Detachable Tabs plan, Task 4) — the menu never
        // flips `keepOnTop` itself, it only asks THIS window to; the
        // `.onChange(of: keepOnTop, …)` in `ContentView.body` is what
        // mirrors the new value back onto `tabCommands.keepOnTop` and
        // applies it to `window.level`.
        tabCommands.toggleKeepOnTop = {
            keepOnTop.toggle()
        }
        tabCommands.newTab = {
            addTabRegistering(makeTab())
        }
        tabCommands.selectTab = { index in
            selectTab(atIndex: index)
        }
        // Extracted into its own method (M14/T5 build fix — see
        // `publishToMenuBarIfKey()`'s doc comment above for the exact same
        // failure mode): inlined here, this closure's `if`/`else` body
        // was the straw that finally tipped the surrounding `.task`
        // closure over the type checker's "unable to type-check this
        // expression in reasonable time" limit. A plain function
        // reference assignment is far cheaper for the checker than a
        // multi-statement closure literal in the same inference scope.
        tabCommands.closeActiveTab = handleCloseActiveTabCommand
        // Sessions menu bridge (M10a/T2) — same shape as the
        // tab commands above. Export/import route through the EXISTING
        // M9a state (`exportSheetItem`/`showImportFileImporter`), not a
        // duplicate handler.
        tabCommands.showKnownHosts = {
            showKnownHostsSheet = true
        }
        // "Server Certificates…" — same shape, opens the
        // server-certificate management sheet.
        tabCommands.showServerCertificates = {
            showServerCertificatesSheet = true
        }
        // "Logins…" (M10b/T3) — same shape, opens the
        // login-sets management sheet.
        tabCommands.showLogins = {
            loginSetsSheetStartsImport = false
            showLoginSetsSheet = true
        }
        // "Import Logins…" (M19/T8) — opens the same sheet, with its file
        // picker already armed.
        tabCommands.importLogins = {
            loginSetsSheetStartsImport = true
            showLoginSetsSheet = true
        }
        // "Hidden Imports…" (M11f/T2) — same shape, opens the
        // hidden-imports management sheet.
        tabCommands.showHiddenImports = {
            showHiddenImportsSheet = true
        }
        // "Ad-hoc Connection Log…" (M31): the audit trail of connections that
        // were never saved. It is reached from the menu rather than from a
        // sidebar row, because its session is a VALUE, not a record -- there
        // is no row to right-click. `AuditLogSheet` needs nothing from that
        // session but its id and its name, so building one here is enough;
        // nothing persists it.
        tabCommands.showAdHocAuditLog = {
            auditLogSession = StoredSession(
                id: AdHocAudit.sessionID,
                name: L10n.string("audit.adhoc.name", "Ad-hoc connections"),
                kind: .ssh)
        }
        // "SSH Keys…" (M18/T5) — same shape, opens the
        // SSH-key management sheet.
        tabCommands.showSSHKeys = {
            showSSHKeysSheet = true
        }
        // Settings "Manage Data" bridge — the two entries that must NOT get
        // their own copy of the sheet in the Settings window. Extracted into
        // methods rather than inlined closures for the same type-checker
        // reason as `handleCloseActiveTabCommand` above.
        settingsBridge.showLoginsFromSettings = presentLoginSetsFromSettings
        settingsBridge.showServerCertificatesFromSettings = presentServerCertificatesFromSettings
        settingsBridge.showHiddenImportsFromSettings = presentHiddenImportsFromSettings
        tabCommands.exportAllSessions = {
            exportSheetItem = ExportSheetItem(scope: .all)
        }
        tabCommands.importSessions = {
            showImportFileImporter = true
        }
        // "From Cyberduck…" — same shape as every other entry on
        // this bridge. Reading the folder happens here, before any sheet is
        // presented, so an absent folder can raise the picker instead.
        tabCommands.importFromCyberduck = {
            beginExternalImport()
        }
        // "Terminal" menu bridge (M11d/T2) — same shape as
        // the tab commands above. Unlike the toolbar button, these two
        // ALWAYS route to their own specific action regardless of
        // `settingsStore.terminalTarget` (spec §4 item 5).
        //
        // Capability guard (M12/T7b): the menu entry is already
        // disabled for a non-shell backend (`MacSCPApp`'s
        // `tabCommands.activeTabSupportsShell`), but this closure
        // re-checks anyway — belt-and-suspenders against any path that
        // reaches it regardless (spec: "no silent no-op").
        //
        // Pane-lock guard (P2 terminal-chrome milestone, Task 3): this menu
        // entry has no `.disabled` binding tied to the pane lock the way
        // the toolbar button does (it lives in a different Scene, wired
        // from `MacSCPApp.swift`), so it is the one caller that MUST check
        // `paneToggleState` itself rather than relying on a `.disabled` a
        // caller elsewhere already applied — otherwise this is the one
        // remaining path that could turn Terminal off while Files is
        // hidden and empty the window. A locked click is a no-op here,
        // same as `PaneVisibility.applyingClick` itself defines for the
        // Files toggle: not a capability problem needing
        // `presentTerminalUnavailable()`, just a click that doesn't land.
        tabCommands.toggleTerminal = {
            guard activeTabSupportsShell else {
                presentTerminalUnavailable()
                return
            }
            guard let terminal = activeTab.session?.terminal else { return }
            guard activeTab.paneToggleState(
                for: .terminal, terminalIsVisible: terminal.isVisible,
                hasShell: activeTabSupportsShell
            ).isEnabled else { return }
            terminal.toggle()
            persistActivePaneVisibility()
        }
        // Transfer-bar menu bridge (M11o) — same shape as
        // the other tab commands; toggles the active tab's per-tab flag.
        tabCommands.toggleTransfers = {
            activeTab.transfersPanelVisible.toggle()
        }
        tabCommands.openExternalTerminal = {
            guard activeTabSupportsShell else {
                presentTerminalUnavailable()
                return
            }
            requestExternalTerminal(for: activeTab)
        }
        // Snippets in the Terminal menu (Terminal-Snippets milestone). The
        // list itself is seeded by `reloadSnippets()` in
        // `performWindowSetup()`, not here — this only wires the two entry
        // points. `presentSnippets` is a method reference rather than an
        // inline closure, for the same type-checker reason as
        // `handleCloseActiveTabCommand` above.
        tabCommands.runSnippet = { snippet, execute in
            triggerSnippet(snippet, execute: execute)
        }
        tabCommands.showSnippets = presentSnippets
    }

    /// Publishes THIS window's tabs and window-raising closures to the
    /// menu-bar status item — but only while this window is the key one.
    ///
    /// `MacSCPApp` owns a separate AppKit `MenuBarController` with no
    /// reference to this view, so the menu's row taps and the "Show macSCP"
    /// item call back through these closures (M11n).
    ///
    /// **Why it is gated** (Detachable Tabs plan, Task 2 fix round 1):
    /// `MenuBarStatusModel` is one object for the whole app, and with more
    /// than one window every one of them mirrored its own tabs into it — so
    /// the item listed whichever window published last, background windows
    /// included. The key window's tabs are the ones a menu-bar list means.
    ///
    /// **Why `controlActiveState` and not a `didBecomeKey` observer**: it is
    /// a per-window SwiftUI environment value, so it needs no notification
    /// subscription and no polling, and it re-runs this through
    /// `.onChange(…, initial: true)` on every transition in either
    /// direction. `MenuBarController` is AppKit and cannot read a focused
    /// scene value the way `MacSCPCommands` does, which is why this one
    /// bridge is published rather than read.
    ///
    /// The two closures raise THIS window rather than searching `NSApp
    /// .windows` for a candidate: they are re-assigned by whichever window
    /// is key, so the window they should raise is the one assigning them.
    func publishToMenuBarIfKey() {
        guard controlActiveState == .key else { return }
        // WEAKLY (fix round 2): these closures outlive the publish, and a
        // strong reference to an `NSWindow` that has since closed both keeps
        // it alive and lets `makeKeyAndOrderFront` put a closed window back
        // on screen. Weak, a stale closure raises nothing — and the window's
        // own close path clears the whole publication anyway
        // (`clearMenuBarIfMine()`), so this is the second line of defence,
        // not the first.
        let ownWindow = window
        menuBarModel.publish(
            tabs: tabsModel.tabs,
            from: windowID,
            focusTab: { [weak ownWindow] id in
                NSApplication.shared.activate(ignoringOtherApps: true)
                ownWindow?.makeKeyAndOrderFront(nil)
                // Route through the `activate(_:)` wrapper, not `tabsModel.activate`
                // directly (M11n final review): a menu-bar row tap is an activation
                // call site and must clear the tab's attention indicator (reset
                // `seenFailureCount`) just like a tab-strip click or ⌘1–9.
                activate(id)
            },
            showMainWindow: { [weak ownWindow] in
                NSApplication.shared.activate(ignoringOtherApps: true)
                ownWindow?.makeKeyAndOrderFront(nil)
            })
    }

    /// Takes this window's tabs out of the menu-bar status item when it
    /// closes — but only if they are the ones showing (fix round 2).
    ///
    /// `MenuBarStatusModel.clearIfPublished(by:)` is what makes that "only
    /// if" true: a background window closing must not wipe the front
    /// window's list. Whichever window is key next publishes its own from
    /// `publishToMenuBarIfKey()`.
    func clearMenuBarIfMine() {
        menuBarModel.clearIfPublished(by: windowID)
    }

    /// `tabCommands.closeActiveTab` handler (⌘W) — extracted out of the
    /// `.task` closure above (M14/T5 build fix) purely to keep that closure
    /// small enough for the type checker.
    ///
    /// It used to open with a `window?.isKeyWindow` guard whose else-branch
    /// forwarded Close to whichever window WAS key. Both are gone
    /// (Detachable Tabs plan, Task 2 fix round 1): this bridge now reaches
    /// the menu only while THIS window is the focused one, so the guard
    /// could no longer be false, and the forwarding it protected has moved
    /// to where it belongs — the menu item is `.disabled` with no focused
    /// window, which lets the system Close command it shadows take ⌘W (see
    /// `MacSCPCommands`).
    func handleCloseActiveTabCommand() {
        let tab = tabsModel.activeTab
        if tabsModel.isLastTab && !tab.isConnected {
            // The only tab left, already a pristine form: Cmd-W closes the
            // WINDOW via the system path instead of the tab-close flow
            // (there is nothing left to revert to).
            window?.performClose(nil)
        } else {
            requestClose(tab)
        }
    }

    /// Mirrors "this window EXISTS" onto `SettingsWindowBridge` — the
    /// app-wide bridge the Settings window's "Manage Data" entries route
    /// through, which cannot be a focused value because the Settings window
    /// is the focused one when those entries are clicked.
    ///
    /// The three "Manage Data" entries that route here are `.disabled` when
    /// this is `false`. Without it they would still be clickable with no main
    /// window (⌘W on the last, unconnected tab closes the window while the app
    /// keeps running) and would silently do nothing — and in that list, unlike
    /// in the Sessions menu, the user has no window context to explain it: two
    /// rows would open a sheet and three would not react at all.
    ///
    /// Existence, NOT visibility, and the reason is in the handlers rather
    /// than here: they raise the window with `makeKeyAndOrderFront`, which
    /// deminiaturizes and unhides it, so a window that exists is a window the
    /// action works on. That is what keeps this mirror and those guards in
    /// agreement — not that the two spell the same expression, but that
    /// "exists" is a property no state transition can change without also
    /// changing `window` here or closing the window outright. An earlier
    /// version of this pair asked `isVisible` on both sides: same text, but
    /// the guard read it live at click time while this snapshot was only
    /// rewritten from `WindowAccessor` and `willClose` — and neither
    /// miniaturization (⌘M) nor hiding the app goes through either of them.
    /// An enabled row whose click did nothing was the result, which is the
    /// exact defect this mirror was added to remove.
    ///
    /// Writes only on a real change: `@Observable` notifies on every set, this
    /// runs from `WindowAccessor.updateNSView` (i.e. on ordinary body
    /// updates), and `MacSCPApp`'s Scene body reads `tabCommands` — an
    /// unconditional assignment would invalidate the commands/Settings graph
    /// on every repaint of this window. The three mirrors next to it are all
    /// written from `.onChange` for the same reason; M11n was a render storm
    /// over a bridge in this repo already.
    func updateMainWindowPresence() {
        writeMainWindowPresence(closingThisWindow: false)
    }

    /// The one place `SettingsWindowBridge.hasMainWindow` is written.
    ///
    /// `MainWindowPresence.remains(windowCount:closingOneOfThem:)` decides
    /// it, from `TabRegistry.windowCount` rather than from this window's own
    /// `NSWindow` — see that type for why a per-window answer was wrong (any
    /// window's close greyed the Settings entries while others were still
    /// open).
    ///
    /// Write-on-change, for the reason `updateMainWindowPresence()`'s doc
    /// comment gives: `@Observable` notifies on every set, this runs from
    /// `WindowAccessor.updateNSView` on ordinary body updates, and the
    /// Settings scene reads the bridge.
    func writeMainWindowPresence(closingThisWindow: Bool) {
        let present = MainWindowPresence.remains(
            windowCount: TabRegistry.shared.windowCount,
            closingOneOfThem: closingThisWindow)
        if settingsBridge.hasMainWindow != present {
            settingsBridge.hasMainWindow = present
        }
    }

    /// The PRIMARY window remembers where it was; a window opened by a move
    /// does not (Detachable Tabs plan, Task 2 fix round 2).
    ///
    /// `MacSCPApp`'s `WindowGroup` declares `.restorationBehavior(.disabled)`
    /// so macOS does not reopen one window per moved tab at the next launch
    /// — and SwiftUI has no per-value knob, so that switch is thrown for the
    /// whole group, taking the primary window's frame with it. An AppKit
    /// frame autosave name puts exactly that much back: the position and
    /// size of the one window that is always there, and nothing about which
    /// windows existed.
    ///
    /// A seeded window deliberately gets none. Two windows sharing one
    /// autosave name would each write the other's frame away, and a window
    /// that exists only because a tab was dragged into it has no remembered
    /// place to come back to in the first place.
    func applyFrameAutosave(to window: NSWindow?) {
        guard isPrimaryWindow else { return }
        window?.setFrameAutosaveName(Self.primaryFrameAutosaveName)
    }

    /// `NSWindow.willCloseNotification` for THIS window — the one moment
    /// `updateMainWindowPresence()` cannot catch, since SwiftUI does not re-run
    /// `WindowAccessor` on the way out and `window` is therefore still
    /// non-nil. Hence the explicit `false` rather than a recompute. Every
    /// other window's close (sheets, the Settings window itself, the menu-bar
    /// panel) is filtered out by the identity check.
    ///
    /// Same write-on-change rule as `updateMainWindowPresence()` above: this
    /// notification fires for every window in the app, and the guard already
    /// drops the ones that are not ours, but the assignment stays conditional
    /// so a repeated close of an already-absent window cannot re-notify.
    /// Also where this window lets go of its tabs (Detachable Tabs plan,
    /// Task 2): a window closing tears down exactly what it still holds AT
    /// THIS MOMENT — a tab that has already moved to another window is gone
    /// from `tabsModel` and is therefore not touched — and only then asks
    /// the registry to forget them. See `releaseHeldTabsOnClose()`.
    func handleWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Not an unconditional `false` any more (fix round 2): another
        // window may still be open, and the Settings entries route into any
        // of them. This window is still counted at this moment — its tabs
        // are released only after teardown — so it excludes itself.
        writeMainWindowPresence(closingThisWindow: true)
        clearMenuBarIfMine()
        // BEFORE the held tabs (fix round 3), and the order is the claim:
        // an unclaimed seed's tab belongs to no window, so this is the last
        // moment anything can reach it, and `releaseHeldTabsOnClose()`
        // starts an async teardown that this sweep must not be racing.
        // A window the user closed is not one to bring back (Detachable
        // Tabs plan, Task 5 fix round 1). Nothing is WRITTEN here: the
        // restoration file is written once, at quit, from the windows
        // still registered — see `AppDelegate.writeRestorationSeeds()`.
        TabRegistry.shared.unregisterWindowDescriber(for: windowID)
        // And what this window would have done at quit (Quit Teardown plan,
        // Task 1) — BEFORE the two sweeps below, which are that very
        // sequence, running now. A window is torn down exactly once: either
        // here, because the user closed it, or by the quit sweep, because it
        // was still open. Unregistering first is what makes the two
        // mutually exclusive even while the `Task` those sweeps start is
        // still in flight — the quit can no longer be handed a closure that
        // would sweep an already-swept window.
        TabRegistry.shared.unregisterWindowTeardown(for: windowID)
        releaseUnclaimedSeedsOnClose()
        releaseHeldTabsOnClose()
    }

    /// How this window describes itself for restoration (Detachable Tabs
    /// plan, Task 5 fix round 1).
    ///
    /// Called by the closure this window hands `TabRegistry
    /// .registerWindowDescriber(_:for:)`, at one moment only: the quit
    /// sweep in `AppDelegate.writeRestorationSeeds()`. It reads and
    /// returns; it writes nothing, touches no file, and asks no question
    /// that could suspend — `applicationWillTerminate` is synchronous and
    /// on the main thread.
    ///
    /// The primary window describes itself too, marked as such: it is the
    /// one window a launch cannot OPEN (being seedless is what makes it
    /// primary), so its tabs are handed to the window SwiftUI opens by
    /// itself. See `WindowSeed.isPrimary`.
    ///
    /// What it describes is deliberately less than what is on screen: per
    /// tab, the stored session's id and the panes it was showing; per
    /// window, whether it floated. No host, no username, no path, no
    /// secret — see `TabSeed`.
    func describeThisWindow() -> WindowSeed {
        WindowSeed(
            tabs: tabsModel.tabs.map(describeForRestoration),
            keepOnTop: keepOnTop,
            isPrimary: isPrimaryWindow)
    }

    /// One tab, as little of it as a later launch needs.
    ///
    /// The session id is `WindowRestorationPlan.sessionID(active:
    /// restored:)`: `activeStoredSessionID` wins when the tab is
    /// connected, and `restoredSessionID` — what THIS tab was itself
    /// restored pointing at — is the fallback for a tab that came back
    /// from `windows.json` and was never connected. Without the fallback
    /// (final review, Detachable Tabs plan), a tab restored once and then
    /// quit again untouched described itself with `sessionID: nil` and
    /// came back blank a second time — `activeStoredSessionID` is written
    /// only by a connect, and the designed path is a click that connects,
    /// but nothing forces that click before a second quit.
    ///
    /// Both are `nil` for an ad-hoc connection and for an untouched form,
    /// and the tab comes back empty either way — an ad-hoc connection
    /// exists only in the form the user typed it into, and writing its
    /// host and username to a file is the thing not saving a session was
    /// meant to avoid.
    func describeForRestoration(_ tab: SessionTab) -> TabSeed {
        TabSeed(
            sessionID: WindowRestorationPlan.sessionID(
                active: tab.activeStoredSessionID, restored: tab.restoredSessionID),
            paneVisibility: paneVisibilityForRestoration(of: tab))
    }

    /// What a tab is showing right now, in the one form that survives a
    /// quit.
    ///
    /// A CONNECTED tab is asked through `effectivePaneVisibility(
    /// terminalIsVisible:hasShell:)`, the single place this project turns
    /// the two independent flags into a `PaneVisibility` — the toolbar and
    /// the render conditions read the same method, so what gets written is
    /// what was on screen rather than a re-derivation that could disagree.
    ///
    /// A DISCONNECTED tab has no panes to read, so it answers with the
    /// pane visibility it was itself restored with, if it was, and
    /// otherwise with the default a session with no recorded preference
    /// gets. A tab that came back from a restoration and was never
    /// connected therefore keeps THIS — its pane visibility — across a
    /// second quit instead of quietly flattening to the default;
    /// `describeForRestoration(_:)` above answers the matching question
    /// for which session the tab points at, through
    /// `WindowRestorationPlan.sessionID(active:restored:)`.
    func paneVisibilityForRestoration(of tab: SessionTab) -> PaneVisibility {
        guard let session = tab.session else {
            return tab.restoredPaneVisibility ?? .filesOnly
        }
        let hasShell = BackendDescriptor.descriptor(for: tab.connectionViewModel.kind)
            .capabilities.supportsShell
        return tab.effectivePaneVisibility(
            terminalIsVisible: session.terminal.isVisible, hasShell: hasShell)
    }

    /// Tears down every move this window started that no window ever
    /// claimed (Detachable Tabs plan, Task 2 fix round 3).
    ///
    /// A parked tab is in no window — no strip, no menu, nothing on screen
    /// says it exists — and the window that parked it is the only thing
    /// that ever knew about it. So when that window goes, the tab goes with
    /// it, through the SAME `teardown(_:reason:)` every held tab runs, and
    /// so through the same one owner and its bounds (`TabTeardown.run`).
    /// `TabRegistry` hands the tabs over and does nothing else to them: the
    /// App layer tears down, the registry keeps references, and
    /// `TabRegistryNoTeardownGuardTests` holds that boundary from the other
    /// side.
    ///
    /// One `info` line per seed, written BEFORE the teardown starts, so the
    /// record survives even if the teardown does not.
    ///
    /// This is the fire-and-forget form, for the `willClose` handler, which
    /// cannot suspend. `releaseUnclaimedSeedsOnCloseAndWait()` below is the
    /// same thing awaited, for the app's quit.
    func releaseUnclaimedSeedsOnClose() {
        let tabs = takeUnclaimedSeedsOnClose()
        guard !tabs.isEmpty else { return }
        Task { @MainActor in await tearDownUnclaimedSeeds(tabs) }
    }

    /// The same sweep and the same teardown, awaited (Quit Teardown plan,
    /// Task 1).
    ///
    /// The app's quit runs this window's close sequence and has to know when
    /// it is done — it replies to AppKit afterwards — so it cannot use the
    /// `Task`-and-return form above. Both spellings share the two halves
    /// below, so there is one sweep and one teardown loop, not two of each.
    func releaseUnclaimedSeedsOnCloseAndWait() async {
        await tearDownUnclaimedSeeds(takeUnclaimedSeedsOnClose())
    }

    /// The synchronous half: takes this window's unclaimed seeds out of the
    /// registry and writes their record. Separate from the teardown so it
    /// happens in the caller's own turn, before anything can suspend — a
    /// seed still in the registry at a suspension point is a seed the quit
    /// sweep could take a second time.
    private func takeUnclaimedSeedsOnClose() -> [SessionTab] {
        let stranded = TabRegistry.shared.takePendingSeeds(from: windowID)
        for seed in stranded {
            DiagnosticLog.shared.log(
                .info, "app", TabMoveLogLines.tornDownUnclaimed(seedID: seed.seedID))
        }
        return stranded.flatMap(\.tabs)
    }

    /// The async half: the ordinary teardown, one parked tab at a time.
    private func tearDownUnclaimedSeeds(_ tabs: [SessionTab]) async {
        for tab in tabs {
            await teardown(tab, reason: .userRequested)
        }
    }

    // MARK: - Windows

    /// Tears down every tab this window still holds and then releases them
    /// from the registry (Detachable Tabs plan, Task 2).
    ///
    /// "Still holds" is the whole point: the list is read HERE, when the
    /// window is already closing, so a tab that left for another window
    /// earlier is not in it and keeps its connection. That is the plan's
    /// invariant ("a window closing tears down exactly the tabs it holds at
    /// that moment") and the reason this reads `tabsModel.tabs` rather than
    /// the registry — the model is what this window owns.
    ///
    /// Teardown is the existing sequence, unchanged and unduplicated:
    /// `teardown(_:reason:)`, and through it the one owner, `TabTeardown
    /// .run(_:reason:)`, which is where the two bounded stages are named.
    /// It is async and a `willClose` handler is not, so it runs in a task —
    /// which is also why the window id and the held tabs are captured as
    /// values first, before anything can suspend.
    ///
    /// **This never ends the process.** `AppDelegate
    /// .applicationShouldTerminate(_:)` is what writes the diagnostic log's
    /// `app quit` line, flushes it and lets the process go, and it is
    /// reached by quitting the app, never by closing a window: closing one
    /// window of several must leave every other window's connections alone.
    /// Nothing here terminates anything.
    ///
    /// This is the fire-and-forget form. `releaseHeldTabsOnCloseAndWait()`
    /// below is the same thing awaited, for the app's quit — which needs to
    /// know when it finished, because it replies to AppKit afterwards.
    func releaseHeldTabsOnClose() {
        let closingWindow = windowID
        let held = takeHeldTabsOnClose(from: closingWindow)
        Task { @MainActor in await tearDownHeldTabs(held, from: closingWindow) }
    }

    /// The same list and the same teardown, awaited (Quit Teardown plan,
    /// Task 1) — see `releaseUnclaimedSeedsOnCloseAndWait()` for why the
    /// quit needs a form it can wait on, and why both forms share the two
    /// halves below rather than spelling the loop twice.
    func releaseHeldTabsOnCloseAndWait() async {
        let closingWindow = windowID
        await tearDownHeldTabs(takeHeldTabsOnClose(from: closingWindow), from: closingWindow)
    }

    /// The synchronous half: the tabs this window holds AT THIS MOMENT, and
    /// the model lookup given up in the same turn.
    ///
    /// The unregistration happens here, before anything can suspend: from
    /// this moment a drag let go on another window's strip must not be able
    /// to name this window as a source. The teardown is what still has to
    /// happen; the lookup is not part of it.
    private func takeHeldTabsOnClose(from closingWindow: WindowID) -> [SessionTab] {
        let held = tabsModel.tabs
        TabRegistry.shared.unregisterModel(for: closingWindow)
        return held
    }

    /// The async half: the ordinary teardown, one held tab at a time, and
    /// only then the registry release — a tab is forgotten after its
    /// connection is closed, never before.
    private func tearDownHeldTabs(_ held: [SessionTab], from closingWindow: WindowID) async {
        for tab in held {
            await teardown(tab, reason: .userRequested)
        }
        TabRegistry.shared.release(held.map(\.id), from: closingWindow)
    }

    /// Registers everything this window's model currently holds, so the
    /// registry knows which window each live tab belongs to.
    ///
    /// Called from `performWindowSetup()` and from the `.onChange(of:
    /// tabIDs)` in this file's modifier chain, which together cover every
    /// way a tab can arrive in this window — the ⊕ button, ⌘N, a sidebar
    /// row opened in a new tab, and a claim from a seed. Registering is
    /// idempotent (`TabRegistry.register(_:in:)` relocates a known tab
    /// rather than duplicating it), so re-running it costs nothing and
    /// needs no bookkeeping of its own.
    ///
    /// It only ever ADDS: a tab missing from the model is not released
    /// here, because "missing from this model" is also what a tab parked
    /// for a move looks like, and releasing it would drop the very tab the
    /// new window is about to claim. Releasing happens where it is meant
    /// to — a closed tab (`performClose`) and a closed window
    /// (`releaseHeldTabsOnClose`).
    func registerHeldTabs() {
        for tab in tabsModel.tabs {
            TabRegistry.shared.register(tab, in: windowID)
        }
    }

    /// Takes over the tabs this window was opened for (Detachable Tabs
    /// plan, Task 2): the seed carries ids, the registry carries the tabs
    /// parked under that seed by the window they left.
    ///
    /// The window was built with a fresh form tab of its own — every
    /// `ContentView` is (`init` seeds `tabsModel` with one) — so the
    /// claimed tabs are added FIRST and the placeholder detached after:
    /// `addTab` makes the last claimed tab active, so detaching the
    /// placeholder never leaves `activeTabID` naming a tab that is gone
    /// (`TabsViewModel.activeTab` traps on an id it cannot resolve).
    ///
    /// An empty claim leaves the window exactly as it was, with its own
    /// fresh tab. That is what a window SwiftUI RESTORED from a previous
    /// launch gets — its seed names ids no live tab carries — and it is
    /// deliberately not an error: Task 5 is what turns such a seed back
    /// into real, disconnected tabs.
    func claimSeededTabs() {
        guard let seed else { return }
        let placeholders = tabsModel.tabs.map(\.id)
        let claimed = TabRegistry.shared.claim(seedID: seed.id, into: windowID)
        guard !claimed.isEmpty else { return }
        for tab in claimed { addTabRegistering(tab) }
        for id in placeholders { tabsModel.detach(tabID: id) }
    }

    /// Rebuilds the tabs this window was DESCRIBED with (Detachable Tabs
    /// plan, Task 5) — the other half of `claimSeededTabs()` above, and
    /// what that method's doc comment has been pointing at since Task 2.
    ///
    /// Where the description comes from depends on which window this is,
    /// and there is no third case:
    ///
    /// - A window opened by `openRestoredWindows()` carries it in its own
    ///   seed, exactly like a moved tab's window does.
    /// - The PRIMARY window has no seed — being seedless is what makes it
    ///   primary — so it takes its description off the launch, once.
    ///
    /// The placeholder dance is `claimSeededTabs()`'s, for the same
    /// reason: every `ContentView` is built holding one fresh form tab, so
    /// the rebuilt tabs are added FIRST and the placeholder detached
    /// after, because `addTab` makes the last added tab active and
    /// `TabsViewModel.activeTab` traps on an id it cannot resolve.
    ///
    /// An empty description is left alone rather than treated as an error.
    /// That covers a move seed (which describes nothing), a launch that is
    /// not restoring, and a window whose description survived but whose
    /// sessions did not — all three come up with the window's own fresh
    /// tab, which is what the app does anyway.
    func restoreDescribedWindow() {
        guard let description = seed ?? restorationLaunch?.takePrimarySeed() else { return }
        // Outside the tab guard below (fix round 1): a window that floated
        // floats again whether or not any of its tabs could be rebuilt.
        // The sticky flag is the window's fact, not a property of what it
        // happens to hold.
        keepOnTop = description.keepOnTop
        guard !description.tabs.isEmpty else { return }
        let placeholders = tabsModel.tabs.map(\.id)
        for described in description.tabs {
            addTabRegistering(makeRestoredTab(from: described))
        }
        for id in placeholders { tabsModel.detach(tabID: id) }
    }

    /// One restored tab: a NEW tab, pointed at the session it had,
    /// connected to nothing.
    ///
    /// **The session is pointed at, not loaded into the form** (fix round
    /// 1). The first version called `ConnectionViewModel.beginEditing(_:)`,
    /// the sidebar's "Edit…" prefill, which puts the form in `.edit` mode
    /// and offers "Save" / "Save & connect" — a tab that came back looking
    /// like an unsaved draft of a session that is saved already. What this
    /// project shows for "a session, not connected" is
    /// `SessionOverviewView`, with Connect, Edit and Diagnose; the tab
    /// carries the session's id (`SessionTab.restoredSessionID`) and
    /// `ContentView+Detail.swift`'s overview branch reads it ahead of the
    /// window-wide `overviewSessionID`, so N restored tabs each show their
    /// own session rather than all showing the sidebar's one selection.
    ///
    /// Only an id is carried, never a resolved `StoredSession`: the
    /// overview branch resolves it against the live list on every render,
    /// which is what makes a session deleted since the description was
    /// written simply disappear instead of coming back as a stale copy.
    /// Nothing about the session is read here at all, so nothing about it
    /// can be read from a file that never held it.
    ///
    /// The described pane visibility is parked on the tab rather than
    /// applied: there are no panes on a disconnected tab. See
    /// `SessionTab.restoredPaneVisibility`.
    func makeRestoredTab(from described: TabSeed) -> SessionTab {
        let tab = makeTab()
        tab.restoredPaneVisibility = described.paneVisibility
        tab.restoredSessionID = described.sessionID
        return tab
    }

    /// Opens one window per remaining description (Detachable Tabs plan,
    /// Task 5).
    ///
    /// It runs from the PRIMARY window's setup pass because that is the
    /// earliest place `openWindow(value:)` can be called at all — it is an
    /// environment value, and `MacSCPApp.init`, where the file is read,
    /// has no environment. `takeSeedsToOpen()` answers once, so a primary
    /// window that appears a second time opens nothing again.
    ///
    /// Each seed carries its own fresh `id`, so the value-keyed
    /// `WindowGroup` opens a window per description instead of raising the
    /// first one repeatedly — see `WindowSeed`.
    func openRestoredWindows() {
        guard isPrimaryWindow, let restorationLaunch else { return }
        for restored in restorationLaunch.takeSeedsToOpen() {
            openWindow(value: restored)
        }
    }

    /// "Move Tab to New Window" — the one route out of both surfaces that
    /// offer it (the tab's context menu and the Window menu).
    ///
    /// The order is the contract, and `TabDetachSequence` owns it rather
    /// than this call site (fix round 1): decide, detach, put a fresh tab in
    /// the leaver's place if the model would otherwise be empty, park, and
    /// OPEN the new window — all before anything closes. `NSWindow.close()`
    /// is synchronous and tears its scene down where it stands, so closing
    /// first would strand a parked tab, with a live connection and no
    /// window, whenever the open was refused or lost.
    ///
    /// **The close waits for the CLAIM, not for a turn** (fix round 2). The
    /// new window claims its seed from its own setup pass, which is a later
    /// display pass rather than a later main-actor turn; a next-turn close
    /// (with its reclaim) ran first, took the tab back, and left the new
    /// window blank. So the registry is asked to say when the tab has
    /// actually been taken over — that is the `onClaimed` handler below —
    /// and this window asks itself to close only then, through the same
    /// `TabWindowCloseRequest` the cross-window drag already posts.
    ///
    /// Until the claim arrives the tab stays parked and this window keeps
    /// what it has (its remaining tabs, or the fresh one that took the
    /// leaver's place). If no window ever claims it, nothing gives it back
    /// — `TabRegistry`'s doc comment states that limit and why there is no
    /// honest signal to end it earlier — and it is torn down by
    /// `releaseUnclaimedSeedsOnClose()` when this window closes, or by the
    /// quit sweep in `AppDelegate`. The log line below is what makes the
    /// interval visible in a diagnostic report.
    ///
    /// No precondition is re-asked here. The context-menu entry exists only
    /// because `TabContextMenu.entries` offered it, and the Window menu's
    /// own entry is disabled on the same count via
    /// `TabCommands.canMoveTabToNewWindow` — asking again here is how two
    /// answers to one question start to disagree (see
    /// `handleTabMenuEntry`'s doc comment).
    func moveToNewWindow(_ tab: SessionTab) {
        let seed = WindowSeed(tabIDs: [tab.id])
        let ownWindowID = windowID
        // Logged AFTER the call, and only when something actually parked
        // (Task 6 closeout): logging before `move` ran risked naming a seed
        // that never held a tab at all — `move` returns `Outcome.none`
        // exactly when `tabID` was not in `model` (see its own doc comment),
        // and nothing parks or opens a window in that case either.
        let outcome = TabDetachSequence.move(
            tab.id, outOf: tabsModel, parkingUnder: seed, from: ownWindowID,
            in: TabRegistry.shared,
            replacement: { makeTab(registeringIn: windowID) },
            openWindow: { openWindow(value: $0) },
            onClaimed: { claimed in
                guard claimed.closesWindow else { return }
                // Posted on the turn after the claim, not inside it: the
                // claim runs from the NEW window's setup pass, and
                // `NSWindow.close()` is synchronous — closing this window
                // from inside another window's setup is the shape Task 3
                // already avoids in `acceptDroppedTab`. Waiting a turn HERE
                // is not the turn-count the Critical was about: the signal
                // has already arrived, and only the acting on it is
                // deferred.
                Task { @MainActor in TabWindowCloseRequest.post(ownWindowID) }
            })
        guard outcome != .none else { return }
        DiagnosticLog.shared.log(
            .info, "app", TabMoveLogLines.parked(seedID: seed.id, tabCount: seed.tabIDs.count))
    }

    /// A tab was dragged out of ANOTHER window's strip and let go on this
    /// window's (Detachable Tabs plan, Task 3).
    ///
    /// The payload is the only thing that says where it came from — a drop
    /// destination is told nothing else — so the source window's model is
    /// resolved through the registry. A `nil` there is an ordinary outcome,
    /// not an error: the source window closed while the drag was in flight,
    /// or the payload is from a previous launch of nothing at all. Refusing
    /// is the whole handling.
    ///
    /// `TabDetachSequence.moveBetweenWindows` does the rest in ONE
    /// main-actor turn — the close decision while the source still holds the
    /// tab, the handover through `TabRegistry.move(_:from:to:targetWindow:)`,
    /// and a fresh tab in the leaver's place if the source would otherwise
    /// be left empty (`TabsViewModel.activeTab` traps on an emptied model,
    /// and a body runs over the source before it can close).
    ///
    /// **The replacement tab is made by THIS window**, which is the one
    /// place this differs from the menu's path. `makeTab()` reads
    /// `settingsStore` and `bandwidthLimiter`, and both are app-scope state
    /// `MacSCPApp` hands to every `ContentView` — so the tab it builds is
    /// the same tab the source window would have built. The alternative,
    /// asking the source window for one, cannot be done inside this turn,
    /// and the turn is what keeps the model from being seen empty.
    ///
    /// The close is not performed here: this window cannot close another
    /// one. See `TabWindowCloseRequest` for why the answer travels back as a
    /// notification, and why it is posted a turn later.
    func acceptDroppedTab(_ payload: TabDragPayload) {
        guard let source = TabRegistry.shared.model(for: payload.sourceWindowID) else { return }
        let outcome = TabDetachSequence.moveBetweenWindows(
            payload.tabID, from: source, sourceWindow: payload.sourceWindowID,
            to: tabsModel, targetWindow: windowID, in: TabRegistry.shared,
            replacement: { makeTab(registeringIn: payload.sourceWindowID) })
        guard outcome.closesWindow else { return }
        let leavingWindow = payload.sourceWindowID
        Task { @MainActor in TabWindowCloseRequest.post(leavingWindow) }
    }

    /// This window was the SOURCE of a cross-window drag and has nothing of
    /// its own left (Detachable Tabs plan, Task 3). Posted by the window the
    /// tab arrived in; every window receives it and only the one it names
    /// acts, the same filter `handleWindowWillClose(_:)` applies to
    /// `NSWindow.willCloseNotification`.
    ///
    /// Closing runs the ordinary path from here on: `willClose` →
    /// `releaseHeldTabsOnClose()` → teardown of exactly what this window
    /// still holds, which by now is the fresh tab put in the leaver's place
    /// and nothing else. The tab that left is already registered to the
    /// other window and is not touched.
    func handleWindowShouldCloseAfterMove(_ notification: Notification) {
        guard TabWindowCloseRequest.windowID(from: notification) == windowID else { return }
        window?.close()
    }

    /// Tab close entry point (strip ✕, ⌘W): a tab with active transfers OF
    /// ITS OWN, or that is currently the DESTINATION of another tab's
    /// cross-session transfer (M8b/T4), requires destructive confirmation
    /// (`closeRequest`, bound to the confirmation dialog above); an
    /// otherwise-idle tab closes immediately.
    func requestClose(_ tab: SessionTab) {
        let incoming = TabCloseWarning.hasIncomingTransfers(for: tab.id, in: tabsModel.tabs)
        if tab.transferQueue.isActive || incoming {
            // Freeze the warning text NOW (M8b review, finding 4) — the
            // dialog reads this snapshot for its whole lifetime instead of
            // recomputing per render, so it can't go blank if the transfers
            // it describes finish while the confirmation is still up.
            closeWarningText = TabCloseWarning.message(
                activeTransfers: tab.transferQueue.isActive, incomingTransfers: incoming)
            closeRequest = tab
        } else {
            Task { await performClose(tab) }
        }
    }

    /// Closes a tab: tab-local teardown first, then either removal from the
    /// model (the last tab is not removable — `TabsViewModel.closeTab`
    /// returns false and it simply stays as a torn-down form tab, reverting
    /// the window to the compact size via `shrinkIfPristine`) or, with
    /// another tab around, removal from the model. Only when the CLOSED tab
    /// was the active one does the auto-activated neighbor get its attention
    /// indicator reset (same rule as `activate(_:)`) — closing a background
    /// tab must not acknowledge failures on the untouched active tab.
    func performClose(_ tab: SessionTab) async {
        await teardown(tab, reason: .userRequested)
        if !tabsModel.isLastTab {
            let wasActive = tab.id == tabsModel.activeTabID
            tabsModel.closeTab(tab.id)
            // The registry forgets a tab only after its teardown has run
            // (Detachable Tabs plan): the last tab is NOT released, because
            // `closeTab` refuses to remove it — it stays in this window as a
            // torn-down form tab, which is still a tab this window holds.
            TabRegistry.shared.release([tab.id], from: windowID)
            if wasActive {
                tabsModel.activeTab.seenFailureCount =
                    tabsModel.activeTab.transferQueue.totalFailureCount
            }
        }
        shrinkIfPristine()
    }

    // MARK: - Tab context menu

    /// The one route out of the tab strip's context menu: every entry
    /// `TabContextMenu.entries` can produce lands here, and every case does
    /// something. Nothing in this switch re-asks whether the entry should
    /// have been offered — its precondition was already decided (and
    /// tested) in Core, and asking again here is how two answers to one
    /// question start to disagree.
    ///
    /// That rule is why the pane arm carries no capability re-check of its
    /// own. The Terminal toolbar button and the `tabCommands.toggleTerminal`
    /// bridge both carry one, and neither is a precedent for this arm — for
    /// two different reasons. The toolbar button's own `.disabled` already
    /// reads `SessionTab.paneToggleState` on the live value; its in-closure
    /// guard is belt-and-suspenders over a control it owns, which is what
    /// its comment there calls it. The bridge is the one that genuinely
    /// needs its own check: its entry is built in `MacSCPApp`'s separate
    /// Scene, which cannot see `tabsModel`, so what disables it is a flag
    /// mirrored across rather than the value itself. This arm has neither
    /// problem: a `.pane` entry exists only because
    /// `toggleState(for:hasShell:)` reported it enabled, which already folds
    /// in the missing shell and the lock on the last visible half.
    ///
    /// The pane arm ignores the `PaneAction` it was handed: that value is
    /// the entry's LABEL — which of "Show"/"Hide" the user read — and the
    /// half it names is what gets flipped either way. Acting on the label
    /// instead would be a second answer to "is this half visible", asked at
    /// the moment of the click rather than at the moment the menu was built.
    ///
    /// The move case forwards the step it was handed instead of turning it
    /// into a number: a direction translated here is a translation nothing
    /// can call with a value, and the pair of numbers that used to stand in
    /// this switch could be swapped without a single test noticing (final
    /// review, I1). `TabsViewModel.move(tabID:oneStep:)` takes the step, and
    /// takes it where both directions are asked for by their names.
    func handleTabMenuEntry(_ entry: TabMenuEntry, for tab: SessionTab) {
        switch entry {
        case .close:
            requestClose(tab)
        case .closeOthers:
            requestCloseOthers(of: tab)
        case .move(let step):
            tabsModel.move(tabID: tab.id, oneStep: step)
        case .moveToNewWindow:
            moveToNewWindow(tab)
        case .pane(let toggle, _):
            togglePane(toggle, in: tab)
        case .openExternalTerminal:
            requestExternalTerminal(for: tab)
        case .saveAsSession:
            saveAsSession(from: tab)
        case .duplicateTab:
            duplicateTab(tab)
        }
    }

    /// "Duplicate Tab" — a fresh tab carrying the SAME stored session as
    /// `tab`, inserted right after it (`addTabRegistering(_:after:)`)
    /// rather than appended at the end of the strip.
    ///
    /// `TabDuplicationPlan` (Core) is asked with the one fact `tab` itself
    /// carries — the stored session it is connected to, or merely pointed
    /// at (`active ?? restored`, the same rule `describeForRestoration`
    /// reads off this tab for window restoration) — and decides everything
    /// about what happens next: `.connect` dials that session on the
    /// duplicate AT ONCE, a second, independent connection (one SSH
    /// connection per TAB is the invariant, not one per stored session);
    /// `.overview` points the duplicate at the session without connecting,
    /// the same idiom `restoredSessionID` already carries for a restored,
    /// unconnected tab; `.none` — no stored session at all, a pristine
    /// "New connection" tab or one dialed ad hoc — makes this a no-op,
    /// defensively: `tabMenuEntries(for:)` never offers `.duplicateTab` for
    /// that case in the first place.
    ///
    /// `connect(in:stored:)` directly, not `connectFromSidebar`/
    /// `sidebarStart`: duplicating is an explicit request for a SECOND tab
    /// on the same session, so the "this session is already open" query
    /// `sidebarStart` would raise has nothing to ask here.
    func duplicateTab(_ tab: SessionTab) {
        let storedSessionID = WindowRestorationPlan.sessionID(
            active: tab.activeStoredSessionID, restored: tab.restoredSessionID)
        switch TabDuplicationPlan.plan(sourceConnected: tab.isConnected, storedSessionID: storedSessionID) {
        case .none:
            return
        case .connect(let sessionID):
            guard let stored = sessionListViewModel.sessions.first(where: { $0.id == sessionID })
            else { return }
            let duplicate = makeTab()
            addTabRegistering(duplicate, after: tab)
            connect(in: duplicate, stored: stored)
        case .overview(let sessionID):
            let duplicate = makeTab()
            addTabRegistering(duplicate, after: tab)
            duplicate.restoredSessionID = sessionID
        }
    }

    /// Which entries one tab's context menu offers.
    ///
    /// Asked here rather than in the strip because two of the seven facts
    /// are positional — where this tab sits, and how many there are — and a
    /// position that reaches a view is a position that can be shifted
    /// inside it. Both are read off the model in the same expression that
    /// uses them; `TabContextMenu.entries` decides everything about WHICH
    /// entries exist, in Core, where its own tests reach it.
    ///
    /// The two pane facts come from `SessionTab.paneToggleState(for:
    /// terminalIsVisible:hasShell:)` — the same method the toolbar's two
    /// buttons read for their own `.disabled`, and the same one
    /// `activeTabTerminalToggleIsUnlocked` mirrors into the "Terminal"
    /// menu. No `PaneVisibility` is assembled here: `SessionTab.
    /// effectivePaneVisibility` is the single assembly point outside Core
    /// (see its doc comment), and a second one would let this menu and the
    /// window it hangs off disagree about which halves are on screen —
    /// which is the defect that method exists to have removed.
    ///
    /// A tab with no session reads as "no terminal visible" rather than
    /// guarding out: there is no `TerminalPanelViewModel` to ask before one
    /// is connected, and `isConnected` already withholds both pane entries
    /// in that state. Guarding out instead would take the CLOSE entry away
    /// from every disconnected tab.
    ///
    /// A tab that is no longer in the model has no menu rather than a menu
    /// decided from a made-up position — the same reading `move` takes of
    /// an id it does not know.
    func tabMenuEntries(for tab: SessionTab) -> [TabMenuEntry] {
        guard let index = tabsModel.tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        let capabilities = BackendDescriptor
            .descriptor(for: tab.connectionViewModel.kind).capabilities
        let terminalIsVisible = tab.session?.terminal.isVisible ?? false
        return TabContextMenu.entries(
            atIndex: index,
            ofTabCount: tabsModel.tabs.count,
            supportsShell: capabilities.supportsShell,
            isAdHoc: tab.activeStoredSessionID == nil,
            isConnected: tab.isConnected,
            hasStoredSession: WindowRestorationPlan.sessionID(
                active: tab.activeStoredSessionID, restored: tab.restoredSessionID) != nil,
            filesToggle: tab.paneToggleState(
                for: .files, terminalIsVisible: terminalIsVisible,
                hasShell: capabilities.supportsShell),
            terminalToggle: tab.paneToggleState(
                for: .terminal, terminalIsVisible: terminalIsVisible,
                hasShell: capabilities.supportsShell))
    }

    /// "Close Other Tabs": everything except `tab` goes, whether or not
    /// `tab` is the active one — the menu hangs off a particular row and
    /// the user means that row.
    ///
    /// One question for the whole group, asked only when there is something
    /// to warn about (`TabCloseWarning.bulkMessage` answers empty
    /// otherwise), and the text is frozen here for the same reason
    /// `requestClose` freezes its own: a dialog that recomputes its counts
    /// per render can go blank while it is on screen.
    func requestCloseOthers(of tab: SessionTab) {
        let closing = tabsModel.tabsToClose(besides: tab.id)
        guard !closing.isEmpty else { return }
        let message = TabCloseWarning.bulkMessage(
            tabsClosing: closing.count,
            transferring: TabCloseWarning.transferringCount(among: closing),
            incoming: TabCloseWarning.incomingCount(among: closing, in: tabsModel.tabs))
        if message.isEmpty {
            Task { await performCloseOthers(of: tab) }
        } else {
            closeOthersWarningText = message
            closeOthersRequest = tab
        }
    }

    /// Tears every other tab down through `teardown(_:reason:)`, one at a
    /// time, then removes them and leaves `tab` active.
    ///
    /// WHICH tabs go, and who is active afterwards, are both
    /// `TabsViewModel`'s answers (`tabsToClose(besides:)` /
    /// `closeOthers(besides:)`) and are tested there — the design's most
    /// emphatic rule about this feature is "all but the CLICKED tab, not all
    /// but the active one", and a view is the wrong place to keep a rule
    /// nothing can check. What is left here is the part that is not a
    /// decision: running each tab's teardown, in the invariant order, before
    /// the model forgets it exists.
    ///
    /// The list is captured before the loop so a tab cannot be missed while
    /// the model shrinks underneath it — and the model is only touched once,
    /// after every teardown has finished.
    ///
    /// The attention indicator is reset only when the tab that was active is
    /// among the ones closing — the same rule `performClose` follows: a tab
    /// the user did not actually visit must not have its failures
    /// acknowledged for it.
    ///
    /// **The release list comes from `closeOthersReportingRemoved`, not
    /// from `closing`** (Detachable Tabs plan, Task 6 closeout). `closing`
    /// is a snapshot taken before the teardown loop's `await`s, and a
    /// cross-window drag can land a tab in THIS window during one of those
    /// suspensions — `TabRegistry` already has it registered here by the
    /// time the model closes everything but `tab.id`, regardless of what
    /// `closing` named. Releasing only `closing`'s ids would leave such an
    /// arrival in the registry's bookkeeping for a window that no longer
    /// holds it — the same staleness the fix above closed for the ordinary
    /// case, reopened by a tab neither list saw coming.
    /// `TabsViewModel.closeOthersReportingRemoved(besides:)` answers what
    /// actually left, an arrival included, whether or not it ever went
    /// through this function's teardown loop; see its own doc comment.
    func performCloseOthers(of tab: SessionTab) async {
        let closing = tabsModel.tabsToClose(besides: tab.id)
        let survivorTakesOver = tabsModel.activeTabID != tab.id
        for other in closing {
            await teardown(other, reason: .userRequested)
        }
        let removedIDs = tabsModel.closeOthersReportingRemoved(besides: tab.id)
        // The same release `performClose` does, for the same reason and in
        // the same order — after teardown, never before (Detachable Tabs
        // plan, Task 3 fix round 1; this path was missing it, so a tab
        // closed this way stayed resolvable through `TabRegistry.tab(for:)`
        // and kept being answered by `tabs(in:)` for a window that no
        // longer had it).
        TabRegistry.shared.release(removedIDs, from: windowID)
        if survivorTakesOver {
            tab.seenFailureCount = tab.transferQueue.totalFailureCount
        }
        shrinkIfPristine()
    }

    /// Flips one half of a tab that is ALREADY connected, and dials
    /// nothing. The tab context menu's `.pane` entry is the only caller.
    ///
    /// It replaced `openTerminalPane`, which revealed the terminal and
    /// refused to hide one. That refusal was not caution but the shape of
    /// the entry it served: "Open Terminal" could only mean one direction.
    /// The menu now offers whichever direction applies, decided in Core
    /// from the same `PaneToggleState` the toolbar reads, so a one-way call
    /// would leave "Hide Terminal" doing nothing.
    ///
    /// Deliberately not `openTerminalFromSidebar`, which looks similar and
    /// is not: that one goes through `sidebarStart` — which may first ask
    /// whether to jump to a tab already holding the session — and from
    /// there through `connect(in:stored:paneVisibility:)`, which opens a
    /// NEW connection. That is the right thing for a stored
    /// session in the sidebar and the wrong thing entirely for a tab whose
    /// session is up. What changes pane visibility on a LIVE tab is
    /// `TerminalPanelViewModel.toggle()` — the same call the toolbar's
    /// Terminal button and the "Terminal" menu's Show/Hide entry make, and
    /// the only call that owns the shell's lifecycle — followed by
    /// `persistActivePaneVisibility()` so the session remembers what is on
    /// screen, exactly as a click on that button would. The files half goes
    /// through `SessionTab.applyFilesToggleClick`, which the toolbar's
    /// Files button also calls; neither half writes a bare bool.
    ///
    /// The pane lock is not re-checked here, and the difference from the
    /// toolbar button and the `tabCommands.toggleTerminal` bridge — both of
    /// which DO check it right before their own `toggle()` — is worth being
    /// precise about. `TerminalPanelViewModel.toggle()` carries no lock of
    /// its own, so somebody has to hold it before every call. Each of the
    /// three holds it somewhere else: the toolbar button in its `.disabled`,
    /// which reads `SessionTab.paneToggleState` live; the bridge in its own
    /// closure, because the entry that reaches it is disabled by a flag
    /// mirrored into another Scene rather than by that value; and this one
    /// in the entry's very existence, since `TabContextMenu.entries`
    /// produces the terminal entry only while `PaneToggleState.isEnabled`,
    /// which is false exactly when the terminal is the last visible half.
    /// The files half needs no such argument at all: `applyingClick`
    /// repairs "neither visible" back to files-only by itself. See
    /// `handleTabMenuEntry` for why this arm re-asks nothing.
    ///
    /// The tab is activated first: it is the tab whose half is being
    /// switched, and changing a pane in a tab the user cannot see would be
    /// an invisible result. Activating also makes
    /// `persistActivePaneVisibility()` describe this tab rather than
    /// whichever one happened to be in front — which is why the activation
    /// is checked rather than assumed before either branch runs.
    func togglePane(_ toggle: PaneToggle, in tab: SessionTab) {
        activate(tab.id)
        guard tabsModel.activeTabID == tab.id, let session = tab.session else { return }
        switch toggle {
        case .files:
            activeTab.applyFilesToggleClick(
                terminalIsVisible: session.terminal.isVisible,
                hasShell: activeTabSupportsShell)
            persistActivePaneVisibility()
        case .terminal:
            session.terminal.toggle()
            persistActivePaneVisibility()
        }
    }

    /// "Save as Session…" on a connected ad-hoc tab: fills the connection
    /// FORM with what this tab is currently connected with and arms its
    /// "Save session" switch, so the user names it and reviews the fields
    /// before anything is written. There is no second save path — the form
    /// reaches the same `SessionListViewModel.save` every saved connect
    /// does, and it is also what already answers whether the secret goes
    /// along.
    ///
    /// The values come from `ConnectionViewModel.values`, the form's own
    /// single source of truth, and not from `lastConnectedConfig`: that is
    /// an `SSHConnectionConfig?` and carries neither S3 nor WebDAV.
    ///
    /// **`values` is not the whole form, and copying it alone silently drops
    /// a bastion.** Several things the form reads — and that a saved session
    /// is built from — are stored properties beside `values`, not inside it.
    /// `jumpEnabled` is the dangerous one: the jump's host, port, user name,
    /// secret and key path all live in `values`, but the flag that says the
    /// block is IN USE does not, and `buildJumpSpec()` returns `nil` without
    /// it. A session only reachable through its bastion would have been
    /// saved as a direct one, with nothing on screen to show it. The rest of
    /// what this type carries is the same class of fact: the login-set
    /// binding, the jump's own source/login mode, the group and the tags.
    ///
    /// Deliberately NOT carried: `saveAsNewLoginSet`/`newLoginSetName`.
    /// Those are an instruction to a SUBMISSION ("while saving this, also
    /// make a login set out of it"), not a property of the connection —
    /// carrying them would act on an intention the user expressed about a
    /// different act. They are reset instead, so a stale tick left on the
    /// TARGET tab's own form cannot ride along either.
    ///
    /// `kind` is assigned BEFORE `values`, because changing it resets
    /// `values` to that backend's defaults (see its `didSet`) — the other
    /// order would wipe what was just copied in. `exitEditMode()` runs
    /// before both and clears the jump block wholesale, which is why every
    /// jump field is restored after it and not before.
    ///
    /// Same target rule as "Edit…" and the ssh-config import
    /// (`formTarget()`): the active tab when it is free to show a form,
    /// otherwise a fresh tab, so the running session this is saving is
    /// never displaced by the form that saves it.
    func saveAsSession(from tab: SessionTab) {
        let source = tab.connectionViewModel
        let carried = CarriedFormState(source)
        // An INVENTED name — the user never typed this one, it is the tab's
        // title. `SessionListViewModel.save` upserts by name, so a title
        // that happens to match a stored session would replace it together
        // with its group, tags, login set, jump spec and keychain secret.
        // Stepping aside is right here and wrong for the form that edits a
        // stored session: there the field shows that session's OWN name,
        // and stepping aside would rename it instead of updating it.
        let name = SessionNameCollision.freeName(
            basedOn: tab.displayTitle, avoiding: sessionListViewModel.sessions)
        guard let target = formTarget() else { return }
        let form = target.connectionViewModel
        form.exitEditMode()
        carried.apply(to: form)
        form.saveName = name
        form.shouldSaveSession = true
    }

    /// Everything `saveAsSession(from:)` moves from a running tab's form to
    /// the form that will save it: `values` plus every stored property the
    /// form reads that is NOT inside `values`.
    ///
    /// A named type rather than a dozen assignments in a row, so the list
    /// can be read as a list — this is the thing that was wrong once, and a
    /// missing line in a run of assignments is invisible.
    ///
    /// `@MainActor` on the TYPE, not `nonisolated(unsafe)` on anything:
    /// every property it reads and writes belongs to a `@MainActor`
    /// `ConnectionViewModel`, and a statement about the type is one both
    /// this toolchain and CI's older one read the same way.
    @MainActor
    struct CarriedFormState {
        let kind: ConnectionKind
        let values: FieldValues
        let selectedGroupID: UUID?
        let tags: [String]
        let loginMode: ConnectionViewModel.LoginMode
        let selectedLoginSetID: UUID?
        /// The flag that turns the jump fields in `values` from inert data
        /// into a hop. See `saveAsSession(from:)`'s doc comment.
        let jumpEnabled: Bool
        let jumpLoginMode: ConnectionViewModel.LoginMode
        let jumpSelectedLoginSetID: UUID?
        let jumpSourceMode: ConnectionViewModel.JumpSourceMode
        let jumpSessionID: UUID?

        init(_ form: ConnectionViewModel) {
            kind = form.kind
            values = form.values
            selectedGroupID = form.selectedGroupID
            tags = form.tags
            loginMode = form.loginMode
            selectedLoginSetID = form.selectedLoginSetID
            jumpEnabled = form.jumpEnabled
            jumpLoginMode = form.jumpLoginMode
            jumpSelectedLoginSetID = form.jumpSelectedLoginSetID
            jumpSourceMode = form.jumpSourceMode
            jumpSessionID = form.jumpSessionID
        }

        /// `kind` first: its `didSet` resets `values` to the backend's
        /// defaults whenever it actually changes.
        func apply(to form: ConnectionViewModel) {
            form.kind = kind
            form.values = values
            form.selectedGroupID = selectedGroupID
            form.tags = tags
            form.loginMode = loginMode
            form.selectedLoginSetID = selectedLoginSetID
            form.jumpEnabled = jumpEnabled
            form.jumpLoginMode = jumpLoginMode
            form.jumpSelectedLoginSetID = jumpSelectedLoginSetID
            form.jumpSourceMode = jumpSourceMode
            form.jumpSessionID = jumpSessionID
            // An intent about a different submission — see
            // `saveAsSession(from:)`'s doc comment.
            form.saveAsNewLoginSet = false
            form.newLoginSetName = ""
        }
    }

    // MARK: - Window geometry

    /// Actively grows/shrinks the window (animated) to the target size while
    /// keeping the top-left corner fixed — AppKit counts `origin.y` from the
    /// bottom, so it's adjusted by the height difference. Growing downward
    /// while the window sits low on its screen can push the computed bottom
    /// edge below the visible area (AppKit's `constrainFrameRect` only
    /// guards the top edge), so the target frame is clamped to the window's
    /// own screen's `visibleFrame` via `clampedToVisibleArea` (M18a/T5b,
    /// `macSCPCore`) before `setFrame` — a frame that's already fully
    /// inside comes back unchanged. If the window can't resolve a screen
    /// (`window.screen` and `NSScreen.main` both `nil`), the frame is set
    /// unclamped rather than dropping the resize.
    ///
    /// This is NOT where a *launch-time* off-screen window comes from
    /// (M18a/T5). That launch position is restored by AppKit's own frame
    /// autosave, which SwiftUI's `WindowGroup` installs for us: the key
    /// `"NSWindow Frame MacSCPApp.ContentView-1-AppWindow-1"` in the app's
    /// user defaults holds `x y w h` plus the SCREEN frame that was current
    /// when it was saved. When the display arrangement changes between runs
    /// (external display detached, or re-arranged above/below the built-in),
    /// AppKit can restore the window onto coordinates no attached screen
    /// covers any more. The app sets no `frameAutosaveName` and persists no
    /// geometry of its own — `lastBrowserSize` below is in-memory `@State`
    /// and is a SIZE only, never an origin. The clamp added here only
    /// bounds frames *this function itself* computes; it does not touch,
    /// and cannot fix, that launch-time restore — do not fold the two
    /// concerns together.
    func resizeWindow(toWidth width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let current = window.frame
        let newOrigin = NSPoint(x: current.origin.x, y: current.origin.y + current.height - height)
        var newFrame = NSRect(origin: newOrigin, size: CGSize(width: width, height: height))
        if let screen = window.screen ?? NSScreen.main {
            newFrame = clampedToVisibleArea(newFrame, visible: screen.visibleFrame)
        }
        window.setFrame(newFrame, display: true, animate: true)
    }

    /// Remembers the browser size and shrinks back to the compact form size
    /// — but ONLY when the action left the window with a single unconnected
    /// tab (M8a/T3). With another tab still around, the window keeps its size.
    func shrinkIfPristine() {
        guard isPristine, let window else { return }
        let size = window.frame.size
        guard size.width > 700 || size.height > 460 else { return }
        lastBrowserSize = size
        resizeWindow(toWidth: 700, height: 460)
    }
}
