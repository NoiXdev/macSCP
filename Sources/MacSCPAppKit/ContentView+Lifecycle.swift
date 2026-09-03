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
        .onAppear { updateModel.hasPresentationTarget = true }
        .onDisappear {
            updateModel.hasPresentationTarget = false
            updateModel.presentedResult = nil
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
            menuBarModel.tabs = tabsModel.tabs
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
        // `[weak tabsModel]` (M9b/T4 review, finding 5): `TabsViewModel` is a
        // class, and this sink is retained by `tab.transferQueue` for the
        // tab's whole lifetime — a plain (implicit `self`) capture would
        // deviate from this file's weak-capture convention and pin every
        // `@State` box on `ContentView` (a full struct copy, including
        // `tabsModel`'s own storage) alive if the window ever dies without
        // running `teardown` (which nils this sink out).
        tab.transferQueue.auditSink = { [weak tabsModel] item in
            let targetTitle = item.destinationTabID.flatMap { id in
                tabsModel?.tabs.first(where: { $0.id == id })?.displayTitle
            }
            recorder.recordTransfer(item, targetTitle: targetTitle)
        }
        tab.session?.remote.auditSink = { event in recorder.recordAction(event) }
    }

    /// Tab-local teardown, in the invariant order: bridge dismiss →
    /// `cancelAll` → `editManager.stopAll` → `terminal.shutdown` →
    /// `remote.disconnect`. Touches ONLY this tab; other tabs' sessions,
    /// queues and forms are untouched.
    ///
    /// `reason` (connection-liveness plan, Task 8; required — see
    /// `CancelReason`'s own doc comment for why a
    /// `Bool` default was rejected) forwards straight into
    /// `cancelAll(reason:)`: the ONE caller that passes `.connectionLost` is
    /// `handleLivenessGiveUp(_:)` below, so the running transfer fails with
    /// a "connection lost" reason and every queued item is marked and kept
    /// — every OTHER caller here passes `.userRequested` (a deliberate
    /// disconnect, not a drop), which keeps the plain `.cancelled` this
    /// function always produced. The order itself (`cancelAll` first,
    /// everything else after) is unchanged by this parameter — it only
    /// changes what `cancelAll` writes onto the queue's own items, not when
    /// it runs.
    ///
    /// **What is bounded here, and what is not.** Three of the four stages
    /// carry a wall-clock bound; the first one does not.
    ///
    /// - `editManager.stopAll()` and `terminal.shutdown()` are bounded HERE,
    ///   through `TeardownStage.runBounded` — see that type for the
    ///   measurements behind the five seconds and for which of the two was
    ///   measured to need it (`terminal.shutdown()`; it did not return
    ///   inside a 20-second watchdog against a frozen peer, in three runs
    ///   out of three).
    /// - `remote.disconnect()` carries its own bound INSIDE
    ///   `CitadelFileSystem.disconnect()` (`7ac7f7e`) and is deliberately
    ///   not wrapped again: measured against that same frozen peer it
    ///   returned in 5.002063 s / 5.304208 s / 5.333977 s.
    /// - `transferQueue.cancelAll(reason:)` is **not bounded** — neither
    ///   here nor inside itself. It was wrapped for one commit (`eed1c8a`)
    ///   and the maintainer removed the wrapper on 2026-08-28, because the
    ///   bound was measured to catch nothing and to cost something. Against
    ///   the frozen peer, with an open PTY shell AND an 8 MB download
    ///   running at the moment of the freeze, `cancelAll` returned in
    ///   0.004462916 s / 0.004904750 s / 0.005558917 s — three runs out of
    ///   three, none of them near a bound. What the wrapper cost is
    ///   visible right below: `BoundedClose` runs its operation in a
    ///   separate task, so wrapping this call makes `teardown` suspend
    ///   BEFORE the queue is swept, and a transfer that fails completely
    ///   inside that one extra main-actor turn then keeps its own error
    ///   text instead of reading "Connection lost." (one that merely starts
    ///   is still marked correctly). Swift has no version with both: an
    ///   async function cannot be run synchronously up to its first
    ///   suspension point inside another task.
    ///
    /// **So the guarantee this function can make is narrower than "it always
    /// reaches its end".** What holds is: whatever `cancelAll` does, the
    /// three stages after it are bounded, so once `cancelAll` returns this
    /// function reaches its end within roughly
    /// `2 × TeardownStage.boundSeconds + CitadelFileSystem
    /// .sftpCloseBoundSeconds`. `cancelAll` itself has no such ceiling: it
    /// awaits every running transfer to unwind (step 3) and is documented as
    /// able to block on an open decider prompt — which is why
    /// `conflictBridge.cancelOpenPrompt()` runs first, and why the
    /// measurement above, not an argument, is what says this is safe today.
    /// If a teardown is ever seen to hang before the first stage bound can
    /// fire, this is the stage to measure first.
    ///
    /// A bound around this whole function instead of one per stage was
    /// considered and rejected by the maintainer: it would abandon the
    /// invariant order wherever it stood and could not name the stage that
    /// hung.
    func teardown(_ tab: SessionTab, reason: CancelReason) async {
        tab.editErrorMessage = nil
        if let session = tab.session {
            // MUST run before `cancelAll(reason:)`: an open conflict sheet would
            // otherwise keep the decider prompt open, which `cancelAll`
            // (documented) hangs on until it's answered — deadlock on disconnect.
            tab.conflictBridge.cancelOpenPrompt()
            // Called directly, NOT through `TeardownStage.runBounded` (see
            // this function's doc comment): a bound would put a suspension
            // point in front of the sweep, and the queue sweep running in
            // teardown's own first main-actor turn is worth more than a
            // bound that three frozen-peer runs measured at under six
            // milliseconds.
            await tab.transferQueue.cancelAll(reason: reason)
            // Binding order (M5e/T4 plan): AFTER `cancelAll` (any in-flight
            // edit download/upload has already been cancelled/settled by the
            // queue, so `stopAll` isn't racing a still-running transfer) and
            // BEFORE `terminal.shutdown`/`disconnect` (teardown proceeds
            // outward from the queue to the connection).
            await TeardownStage.stopEditWatchers.runBounded { [editManager = session.editManager] in
                await editManager.stopAll()
            }
            await TeardownStage.shutDownTerminal.runBounded { [terminal = session.terminal] in
                await terminal.shutdown()
            }
            await session.remote.disconnect()
            // Audit recorder teardown (M9b/T3): only present for a stored
            // session (`attachAuditRecorder` never runs for an ad-hoc
            // connect), so this is a no-op otherwise. `recordDisconnected()`
            // FIRST, then release the recorder and BOTH sinks it wired.
            if let recorder = tab.auditRecorder {
                recorder.recordDisconnected()
                tab.auditRecorder = nil
                tab.transferQueue.auditSink = nil
                session.remote.auditSink = nil
            }
        }
        let form = tab.connectionViewModel
        // `clearRetainedSecrets()` (not the narrower `clearPassword()`):
        // this tab's `connectionViewModel` survives past this teardown, so
        // its `lastConnectedConfig` (the external-terminal launcher's own
        // copy of the same secret) must be forgotten here too, or it would
        // keep the first connect's plaintext password in memory across
        // every later disconnect/reconnect in this tab (review finding,
        // M11d fix round 1).
        form.clearRetainedSecrets()
        form.authChoice = .password
        form.keyPath = ""
        // Reset any pending edit context: a stale `.edit(sessionID:)`
        // surviving into the next Save would overwrite the wrong stored
        // session (M5f/T4 review).
        form.exitEditMode()
        tab.session = nil
        tab.activeStoredSessionID = nil
        tab.titleName = nil
        // Stale liveness (connection-liveness plan, Task 4, fix round 2;
        // recounted for the tab-context-menu plan's final review): this
        // function has exactly five OTHER callers — `disconnectToForm` (the
        // toolbar "Disconnect" button), `performClose` (closing a tab),
        // `performCloseOthers` (closing every other tab), the
        // reconnect-in-place branch of `connect(in:stored:)`, and
        // `ConnectingAttemptView`'s `onCancel` in `ContentView+Detail.swift`
        // — and every one of them is a deliberate "leave this connection".
        // There is no connection left to describe afterward, so a dot left
        // reading `.degraded`/`.lost` from before this call would be
        // describing a session that is no longer there.
        // The ONE exception is `handleLivenessGiveUp`, which writes
        // `.lost` AFTER calling this function precisely so that write is
        // not the one this line clears.
        tab.liveness = nil
        // Same rule, same sentence, for the lost-connection record (Task
        // 7): every one of those five callers is leaving this connection on
        // purpose, and a record of a DROP would be describing something
        // that did not happen. `handleLivenessGiveUp` is the same one
        // exception it is for `liveness` — it writes this afterwards,
        // deliberately after this line has run.
        tab.lostConnection = nil
        // And the third fact describing a connection that is over
        // (failed-connect surface plan, review round 1): a FAILED ATTEMPT.
        // Measured before this line existed: on a window with one tab —
        // the normal case at launch — typing a host, timing out and
        // pressing "Close" ran `performClose`, which tears the tab down
        // but does NOT remove the last tab, and the failed-connect surface
        // stayed up with all four buttons while the window shrank around
        // it. A button named "Close" that visibly does nothing is the
        // exact complaint this whole surface was written to answer.
        //
        // The sibling surface never had this defect because it hangs off
        // `liveness == .lost`, which this function's own `tab.liveness`
        // reset clears; this one hangs off a property teardown did not
        // touch. Same sentence as the other two resets, therefore: every one
        // of those five callers is leaving this connection on purpose, so a
        // record of an attempt that failed is describing something the tab
        // has been taken past.
        tab.connectFailure = nil
        // And the run of a diagnosis of THIS tab — the run, not the panel.
        //
        // Stopping it explicitly, not by letting the sheet's own
        // `.onDisappear` do it: `DiagnosticsViewModel.run()` starts a free
        // `Task`, which no view teardown touches, and closing a tab does not
        // dismiss the sheet at all. Without this the walk continues — the
        // remaining steps under their budgets, and the SSH dial holding
        // Citadel's uncancellable `openSFTP` timer — dialling a server the
        // window has just finished with. CLAUDE.md, "The UI owns lifecycles
        // explicitly … no `deinit` cleanup".
        //
        // What it does NOT do any more is close the panel. This function has
        // six callers and `handleLivenessGiveUp` is not a user action at all:
        // the session dropping is exactly why somebody opened Diagnose… on
        // this tab, and dismissing the sheet there threw away the only thing
        // that could say whether the host stopped resolving, the port stopped
        // accepting, or the auth started failing. Two of the others
        // (`performCloseOthers`, the reconnect-in-place branch) were closing a
        // panel belonging to a different connection entirely.
        //
        // `DiagnosticsLifecycleTests` drives `handleLivenessGiveUp` by name,
        // and the OTHER TWO by their shape — `teardown` of a tab the panel was
        // not opened for — not by calling `performCloseOthers` or the
        // reconnect branch. That distinction is the point of writing it down:
        // an `endDiagnostics()` added back into either of those two functions
        // for tidiness goes red nowhere.
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
        wireMenuBarBridge()
        // Command bridge wiring (M8a/T4): `MacSCPApp` has no reference to
        // this view, so the menu items call back through these closures.
        //
        // Key-window guard (M8a T5 review, finding 1): the `Settings`
        // scene shares this exact ⌘N/⌘W/⌘1–9 command set (SwiftUI attaches
        // one `.commands` menu app-wide, not per window/scene), so with
        // Settings focused these closures would otherwise still fire
        // against THIS window's tabs instead of Settings — e.g. ⌘W would
        // tear down a tab instead of closing the Settings window. Each
        // closure checks that this window is actually key before acting.
        tabCommands.newTab = {
            guard window?.isKeyWindow == true else { return }
            tabsModel.addTab(makeTab())
        }
        tabCommands.selectTab = { index in
            guard window?.isKeyWindow == true else { return }
            selectTab(atIndex: index)
        }
        // Extracted into its own method (M14/T5 build fix — see
        // `wireMenuBarBridge()`'s doc comment above for the exact same
        // failure mode): inlined here, this closure's `if`/`else` body
        // was the straw that finally tipped the surrounding `.task`
        // closure over the type checker's "unable to type-check this
        // expression in reasonable time" limit. A plain function
        // reference assignment is far cheaper for the checker than a
        // multi-statement closure literal in the same inference scope.
        tabCommands.closeActiveTab = handleCloseActiveTabCommand
        // Sessions menu bridge (M10a/T2) — same key-window guard as the
        // tab commands above. Export/import route through the EXISTING
        // M9a state (`exportSheetItem`/`showImportFileImporter`), not a
        // duplicate handler.
        tabCommands.showKnownHosts = {
            guard window?.isKeyWindow == true else { return }
            showKnownHostsSheet = true
        }
        // "Server Certificates…" — same key-window guard, opens the
        // server-certificate management sheet.
        tabCommands.showServerCertificates = {
            guard window?.isKeyWindow == true else { return }
            showServerCertificatesSheet = true
        }
        // "Logins…" (M10b/T3) — same key-window guard, opens the
        // login-sets management sheet.
        tabCommands.showLogins = {
            guard window?.isKeyWindow == true else { return }
            loginSetsSheetStartsImport = false
            showLoginSetsSheet = true
        }
        // "Import Logins…" (M19/T8) — opens the same sheet, with its file
        // picker already armed.
        tabCommands.importLogins = {
            guard window?.isKeyWindow == true else { return }
            loginSetsSheetStartsImport = true
            showLoginSetsSheet = true
        }
        // "Hidden Imports…" (M11f/T2) — same key-window guard, opens the
        // hidden-imports management sheet.
        tabCommands.showHiddenImports = {
            guard window?.isKeyWindow == true else { return }
            showHiddenImportsSheet = true
        }
        // "Ad-hoc Connection Log…" (M31): the audit trail of connections that
        // were never saved. It is reached from the menu rather than from a
        // sidebar row, because its session is a VALUE, not a record -- there
        // is no row to right-click. `AuditLogSheet` needs nothing from that
        // session but its id and its name, so building one here is enough;
        // nothing persists it.
        tabCommands.showAdHocAuditLog = {
            guard window?.isKeyWindow == true else { return }
            auditLogSession = StoredSession(
                id: AdHocAudit.sessionID,
                name: L10n.string("audit.adhoc.name", "Ad-hoc connections"),
                kind: .ssh)
        }
        // "SSH Keys…" (M18/T5) — same key-window guard, opens the
        // SSH-key management sheet.
        tabCommands.showSSHKeys = {
            guard window?.isKeyWindow == true else { return }
            showSSHKeysSheet = true
        }
        // Settings "Manage Data" bridge — the two entries that must NOT get
        // their own copy of the sheet in the Settings window. Extracted into
        // methods rather than inlined closures for the same type-checker
        // reason as `handleCloseActiveTabCommand` above.
        tabCommands.showLoginsFromSettings = presentLoginSetsFromSettings
        tabCommands.showServerCertificatesFromSettings = presentServerCertificatesFromSettings
        tabCommands.showHiddenImportsFromSettings = presentHiddenImportsFromSettings
        tabCommands.exportAllSessions = {
            guard window?.isKeyWindow == true else { return }
            exportSheetItem = ExportSheetItem(scope: .all)
        }
        tabCommands.importSessions = {
            guard window?.isKeyWindow == true else { return }
            showImportFileImporter = true
        }
        // "Terminal" menu bridge (M11d/T2) — same key-window guard as
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
            guard window?.isKeyWindow == true else { return }
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
        // Transfer-bar menu bridge (M11o) — same key-window guard as
        // the other tab commands; toggles the active tab's per-tab flag.
        tabCommands.toggleTransfers = {
            guard window?.isKeyWindow == true else { return }
            activeTab.transfersPanelVisible.toggle()
        }
        tabCommands.openExternalTerminal = {
            guard window?.isKeyWindow == true else { return }
            guard activeTabSupportsShell else {
                presentTerminalUnavailable()
                return
            }
            requestExternalTerminal(for: activeTab)
        }
        // Snippets in the Terminal menu (Terminal-Snippets milestone) —
        // seeds the mirrored list once, then wires the two entry points.
        // Both handlers are method references rather than inline closures,
        // for the same type-checker reason as `handleCloseActiveTabCommand`
        // above; each carries the key-window guard itself.
        reloadSnippets()
        tabCommands.runSnippet = triggerSnippet
        tabCommands.showSnippets = presentSnippets
    }

    /// Menu-bar status bridge wiring (M11n), called once from `.task`:
    /// seeds `menuBarModel.tabs` and sets its window-raising closures.
    /// `MacSCPApp` owns a separate AppKit `MenuBarController` with no
    /// reference to this view, so the menu's row taps and "Show macSCP" item
    /// call back through these closures — same shape as the `tabCommands` bridge
    /// below, minus the key-window guard (there is nothing to guard against:
    /// raising/activating this one window is always the right action,
    /// whichever window happened to be key when the menu-bar item was
    /// clicked).
    func wireMenuBarBridge() {
        menuBarModel.tabs = tabsModel.tabs
        menuBarModel.focusTab = { id in
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            // Route through the `activate(_:)` wrapper, not `tabsModel.activate`
            // directly (M11n final review): a menu-bar row tap is an activation
            // call site and must clear the tab's attention indicator (reset
            // `seenFailureCount`) just like a tab-strip click or ⌘1–9.
            activate(id)
        }
        menuBarModel.showMainWindow = {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    /// `tabCommands.closeActiveTab` handler (⌘W) — extracted out of the
    /// `.task` closure above (M14/T5 build fix) purely to keep that closure
    /// small enough for the type checker; behavior is unchanged from the
    /// inline version.
    func handleCloseActiveTabCommand() {
        guard window?.isKeyWindow == true else {
            // Not our window: route Close to whichever window IS key
            // (typically Settings) via the system path instead of silently
            // doing nothing.
            NSApp.keyWindow?.performClose(nil)
            return
        }
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

    /// Mirrors "this window EXISTS" onto `TabCommands`, for the same reason
    /// `isActiveTabConnected`/`hiddenImportsCount` are mirrored there: the
    /// Settings scene cannot see this view's `@State`.
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
        let present = window != nil
        if tabCommands.hasMainWindow != present {
            tabCommands.hasMainWindow = present
        }
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
    func handleWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        if tabCommands.hasMainWindow {
            tabCommands.hasMainWindow = false
        }
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
        case .pane(let toggle, _):
            togglePane(toggle, in: tab)
        case .openExternalTerminal:
            requestExternalTerminal(for: tab)
        case .saveAsSession:
            saveAsSession(from: tab)
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
    func performCloseOthers(of tab: SessionTab) async {
        let closing = tabsModel.tabsToClose(besides: tab.id)
        let survivorTakesOver = tabsModel.activeTabID != tab.id
        for other in closing {
            await teardown(other, reason: .userRequested)
        }
        tabsModel.closeOthers(besides: tab.id)
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
