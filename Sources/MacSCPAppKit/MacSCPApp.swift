import SwiftUI
import macSCPCore

/// One window's menu bridge (M8a/T4): `MacSCPCommands` holds no reference
/// to `ContentView` — the menu items call these closures, and `ContentView`
/// assigns them (in `wireTabCommands()`) to its own tab-lifecycle methods.
/// `@Observable` for consistency with the app's other cross-layer bridges
/// (`ConflictPromptBridge`); the closures themselves are read once per
/// invocation, not observed reactively.
///
/// **Per window, not per app** (Detachable Tabs plan, Task 2 fix round 1).
/// Each `ContentView` owns one and publishes it with
/// `.focusedSceneValue(\.tabCommands, …)`; the menus read the FOCUSED
/// window's instance back with `@FocusedValue`. Before that there was one
/// instance for the whole app, and every closure carried a
/// `window?.isKeyWindow` guard to decide after the fact whether it was the
/// right window — which a second window broke twice over: the closures
/// belonged to whichever window ran its setup last, and the mirrored
/// enabled-state values to whichever window changed last, background
/// windows included. None of those guards survives; being focused is now
/// the precondition for being read at all.
///
/// What could NOT become per window is on `SettingsWindowBridge` — see
/// that type for why.
@MainActor
@Observable
final class TabCommands {
    var newTab: (() -> Void)?
    var closeActiveTab: (() -> Void)?
    var selectTab: ((Int) -> Void)?
    /// Sessions menu bridge (M10a/T2): "Known Hosts…" opens the management
    /// sheet; the export/import closures bind to `ContentView`'s EXISTING
    /// M9a handlers (`exportSheetItem`/`showImportFileImporter`) — the
    /// sidebar's own "Export All…"/"Import…" entries are untouched.
    var showKnownHosts: (() -> Void)?
    /// "Server Certificates…" — same bridge shape as
    /// `showKnownHosts` above, opens the server-certificate management sheet.
    /// Its own entry rather than a section inside the known-hosts sheet; see
    /// `ServerCertificatesSheet`'s doc comment.
    var showServerCertificates: (() -> Void)?
    /// "Logins…" (M10b/T3) — same bridge shape as
    /// `showKnownHosts` above, opens the login-sets management sheet.
    var showLogins: (() -> Void)?
    /// "Hidden Imports…" (M11f/T2) — same bridge shape as
    /// `showKnownHosts`/`showLogins` above, opens the hidden-imports
    /// management sheet.
    var showHiddenImports: (() -> Void)?
    /// "SSH Keys…" (M18/T5) — same bridge shape as
    /// `showKnownHosts`/`showLogins`/`showHiddenImports` above, opens the
    /// SSH-key management sheet (replaces the M17 Settings tab).
    var showSSHKeys: (() -> Void)?
    /// Opens the ad-hoc connection log (M31). Its own entry rather than a
    /// parameter on the existing audit hook, because there is no session to
    /// pass -- the ad-hoc log's session is a value the App layer builds.
    var showAdHocAuditLog: (() -> Void)?
    /// Mirrors `ContentView`'s `hiddenImportAliases.count` (M11f/T2, same
    /// rationale as `isActiveTabConnected` below): the "Hidden Imports…"
    /// menu title's count suffix needs this observed value since `MacSCPApp`
    /// builds a separate Scene that does not see `ContentView`'s `@State`.
    var hiddenImportsCount = 0
    var exportAllSessions: (() -> Void)?
    var importSessions: (() -> Void)?
    /// "Import Logins…" (M19/T8) — opens the login-sets sheet with its file
    /// picker armed. Exporting logins lives in that sheet only (it needs a
    /// selection to scope), so there is no menu counterpart for it.
    var importLogins: (() -> Void)?
    /// "From Cyberduck…" (2026-09-03) — reads Cyberduck's bookmark folder
    /// and opens the import preview. Its own entry rather than a mode of
    /// `importSessions` above: that one takes a `.macscpsessions` file the
    /// user picks, this one takes another program's data directory and shows
    /// a preview before anything is written.
    var importFromCyberduck: (() -> Void)?
    /// Terminal menu (M11d/T2): these two entries always offer BOTH ways to
    /// open a session's shell, regardless of `SettingsStore.terminalTarget`
    /// — the setting only picks what ⌘T/the toolbar button do, it never
    /// takes either capability away.
    var toggleTerminal: (() -> Void)?
    var openExternalTerminal: (() -> Void)?
    /// Transfer-bar toggle (M11o): the "Show/Hide Transfers" menu entry and
    /// ⌘⇧Y drive this. Each window fills in its own closure, which toggles
    /// that window's active tab's `transfersPanelVisible`, and the menu
    /// reaches only the focused window's — there is no key-window check
    /// anywhere on this bridge any more. Enabled state mirrors
    /// `isActiveTabConnected` (same as the Terminal entries).
    var toggleTransfers: (() -> Void)?
    /// Mirrors `ContentView`'s active tab connection state (M11d/T2): this
    /// `TabCommands` instance is the only thing `MacSCPApp`'s `.commands`
    /// closure observes, and that closure builds a separate Scene that does
    /// NOT see `ContentView`'s own `tabsModel` — so the enabled state of the
    /// two Terminal menu entries above has to be mirrored here explicitly
    /// (see `ContentView`'s `.onChange(of: isActiveTabConnected)`).
    var isActiveTabConnected = false
    /// Capability gate (M12/T7b): `false` while the active tab's backend
    /// has no shell (S3) — `ContentView` mirrors
    /// `BackendDescriptor.descriptor(for:).capabilities.supportsShell` here
    /// the same way it mirrors `isActiveTabConnected` above, for the same
    /// reason (this Scene doesn't see `tabsModel`). Defaults `true` so the
    /// menu behaves exactly as before this feature until the mirror runs.
    var activeTabSupportsShell = true
    /// Pane lock (P2 terminal-chrome milestone; whole-phase review, Fix 2):
    /// `false` while the terminal is the last visible half, so turning it off
    /// would empty the window. `ContentView` mirrors
    /// `SessionTab.paneToggleState(for: .terminal, …).isEnabled` here the
    /// same way it mirrors `activeTabSupportsShell` above, and for the same
    /// reason (this Scene cannot see `tabsModel`).
    ///
    /// It exists because `toggleTerminal`'s closure checks the lock and
    /// returns — and a menu entry that is enabled and does nothing is exactly
    /// what `PaneToggleState`'s own doc comment rules out ("disabled rather
    /// than silently inert, so the user can see why a click does not land").
    /// The toolbar button got this right from the start via its own
    /// `.disabled`; the menu entry lives in another Scene and could only get
    /// it through a mirror.
    ///
    /// Defaults `true` for the same reason `activeTabSupportsShell` does: the
    /// menu must behave exactly as before until the mirror has run once. The
    /// disconnected case is not this flag's business — `isActiveTabConnected`
    /// already covers it.
    var activeTabTerminalToggleIsUnlocked = true
    /// Whether the "Show/Hide Terminal" entry can do anything at all: a
    /// connected tab, on a backend with a shell, whose terminal half is not
    /// the last visible one. The menu's `.disabled` reads THIS rather than
    /// re-spelling the three conditions, so the entry and
    /// `toggleTerminal`'s own guards cannot drift apart on what "would not
    /// land" means.
    ///
    /// "Open in External Terminal" deliberately does NOT read this: that
    /// route never touches `TerminalPanelViewModel.isVisible`, so the pane
    /// lock has nothing to say about it (documented deliberate asymmetry,
    /// Task 3).
    var canToggleTerminal: Bool {
        isActiveTabConnected && activeTabSupportsShell && activeTabTerminalToggleIsUnlocked
    }
    /// The saved snippets, mirrored for the Terminal menu's snippet entries
    /// (Terminal-Snippets milestone) — same rationale as `hiddenImportsCount`
    /// above: this Scene cannot see `ContentView`'s `@State`, and here the
    /// menu needs the whole list, not just a count, because there is one
    /// entry per snippet. `ContentView` fills it from `SnippetStore` during
    /// window setup and again whenever the management sheet closes, which is
    /// the only place a snippet can be created, edited or deleted.
    ///
    /// Carries the read OUTCOME, not just a list: a store that cannot be read
    /// must not look like an empty one in the menu (see `SnippetsLoad`).
    var snippetsLoad: SnippetsLoad = .loaded([])
    /// Triggers one snippet in the active tab's shell — `ContentView`
    /// describes the run (`SnippetDryRun.describing`, which is where the
    /// send plan is made) and sends the resulting bytes to that tab's
    /// `TerminalPanelViewModel`. Same
    /// bridge shape as `toggleTerminal` above.
    /// `execute` is the trigger's own choice (Terminal-Snippets, Task 6):
    /// every snippet offers both an Insert and an Execute action, so this
    /// bridge carries WHICH ONE fired rather than deciding for it.
    var runSnippet: ((Snippet, Bool) -> Void)?
    /// "Manage Snippets…" — same bridge shape as `showLogins` above, opens
    /// the snippet management sheet in the focused window.
    var showSnippets: (() -> Void)?
    /// "Move Tab to New Window" (Detachable Tabs plan, Task 2) — the Window
    /// menu's route to the action the tab strip's context menu also offers.
    /// Same bridge shape as the entries above; it moves the ACTIVE tab of
    /// the window this bridge belongs to, which — the bridge being read
    /// through `@FocusedValue` — is the window in front, and the only tab a
    /// menu with no click target can mean.
    var moveTabToNewWindow: (() -> Void)?
    /// Whether that entry can do anything: `false` while the front window
    /// holds a single tab, because moving the only tab of a window into a
    /// new window closes one window and opens another holding the same
    /// thing. Mirrored from `ContentView` for the same reason
    /// `isActiveTabConnected` is — this Scene cannot see `tabsModel`.
    ///
    /// Defaults `false`, unlike the mirrors above, and deliberately: a
    /// window comes up with exactly one tab, so `false` is the true value
    /// until the mirror has run, and the entry is greyed rather than
    /// enabled-and-inert in the moment before it does.
    var canMoveTabToNewWindow = false
    /// "Keep on Top" (Detachable Tabs plan, Task 4): mirrors `ContentView`'s
    /// own `keepOnTop` `@State`, the same way `canMoveTabToNewWindow` mirrors
    /// its tab count — this Scene cannot see that `@State` directly. The
    /// Window menu's checkmark reads this rather than a constant, so it
    /// always shows the FOCUSED window's sticky state, not whichever
    /// window last changed it.
    var keepOnTop = false
    /// Toggles `ContentView`'s `keepOnTop` for the window this bridge
    /// belongs to — same bridge shape as `moveTabToNewWindow` above: the
    /// menu never flips `keepOnTop` itself, it only asks the focused
    /// window to.
    var toggleKeepOnTop: (() -> Void)?
}

/// The Settings window's route into a main window, and the one bridge in
/// this app that is deliberately NOT per window.
///
/// The "Manage Data" section presents login sets, server certificates and
/// hidden imports through a MAIN window's sheets rather than opening a
/// second copy of each in the Settings window. It cannot use the focused
/// value `TabCommands` travels on (`MacSCPCommands.swift`): when these
/// entries are clicked the Settings window IS the focused one, so the
/// focused bridge is `nil` by definition. So this stays an app-wide object
/// every window writes into, and "the main window" means the window that
/// wrote last — the same meaning it had when there was only ever one.
///
/// It was carved out of `TabCommands` in the Detachable Tabs plan, Task 2
/// fix round 1, when that type became per window: these five members are
/// the ones that could not travel with it.
@MainActor
@Observable
final class SettingsWindowBridge {
    /// Settings-window route to the login-sets sheet ("Manage Data"
    /// section).
    ///
    /// Deliberately a SEPARATE closure from `TabCommands.showLogins`: that
    /// one belongs to the focused window and would be `nil` here, because
    /// the Settings window is the focused one when this fires. It exists at
    /// all because Settings must not present its own copy of
    /// `LoginSetsSheet` — see the wiring comment in
    /// `ContentView.wireTabCommands()` for the exact hazard.
    var showLoginsFromSettings: (() -> Void)?
    /// Settings-window route to the server-certificate sheet — same shape as
    /// `showLoginsFromSettings` above; the reason is trust, not state (see
    /// `ContentView.presentServerCertificatesFromSettings()`).
    var showServerCertificatesFromSettings: (() -> Void)?
    /// Settings-window route to the hidden-imports sheet — same shape and
    /// same reason as `showLoginsFromSettings` above.
    var showHiddenImportsFromSettings: (() -> Void)?
    /// Whether a main window EXISTS: the three routed entries above have
    /// nowhere to go without one, so the "Manage Data" section disables them
    /// rather than letting the click vanish. `ContentView` keeps this in sync
    /// from `updateMainWindowPresence()`/`handleWindowWillClose(_:)`, and it
    /// starts `false` — no window has resolved yet at that point.
    ///
    /// Existence, not visibility: the routed handlers raise the window before
    /// presenting, and raising deminiaturizes and unhides it, so a minimized
    /// window or a hidden app is still a window those entries work on. Asking
    /// `isVisible` here would grey them out (or worse, leave them enabled on a
    /// stale `true`) for states in which the action would have succeeded.
    var hasMainWindow = false
    /// The hidden-import count the "Manage Data" entry's title shows.
    ///
    /// The SAME number also lives on `TabCommands`, and the duplication is
    /// deliberate rather than an oversight: the Sessions menu's own "Hidden
    /// Imports…" title shows the FOCUSED window's count, and this one shows
    /// the count of whichever window the "Manage Data" entries would route
    /// to. With one window open the two are the same number; with two open
    /// they are answers to different questions.
    var hiddenImportsCount = 0
}

/// Wired into `MacSCPApp` through `@NSApplicationDelegateAdaptor` below —
/// SwiftUI's own `App` protocol has no termination callback of its own, and
/// `NSApplication.willTerminateNotification` (a prior round's choice, now
/// replaced) cannot be waited on synchronously: the notification fires from
/// a plain `NotificationCenter` block, and a callback that starts a `Task`
/// and returns has no guarantee the process outlives that `Task` ever being
/// scheduled — on an ordinary Cmd+Q that race can lose both the "app quit"
/// line and whatever was still buffered. `applicationWillTerminate(_:)` is a
/// real `NSApplicationDelegate` callback: AppKit holds the process open
/// until it returns, so a synchronous call inside it is guaranteed to run
/// before the process can exit — which is exactly what `flushSynchronously()`
/// needs (Diagnostic Log plan, Task 2 round 1).
///
/// No other code under `Sources/MacSCPAppKit` reads `NSApp.delegate` or
/// relies on `applicationDidFinishLaunching` (checked with `grep -rn
/// "NSApp.delegate\|applicationDidFinishLaunching" Sources/MacSCPAppKit`
/// before adding this — no matches), so installing this adaptor changes
/// nothing this app already depended on `NSApp.delegate` being.
/// What the deferred quit still has to tear down, in one main-actor box.
///
/// It exists for a type-system reason, not a design one: `TaskGroup
/// .addTask`'s closure must be `Sendable`, and a `[SessionTab]` is not (the
/// type is `@MainActor`), nor is a list of `@MainActor` closures. A
/// `@MainActor final class` is implicitly `Sendable`, so the box crosses the
/// boundary and its contents never do — the child that reads it is
/// `@MainActor` as well, and runs on the same actor the values already
/// belong to.
@MainActor
private final class QuitWorkList {
    /// Tabs parked for a window that never appeared, already taken out of
    /// the registry by `AppDelegate.sweepUnclaimedMoves()`.
    let parked: [SessionTab]
    /// Every open window's teardown, in the order the windows appeared.
    let windows: [(WindowID, TabRegistry.WindowTeardown)]

    init(parked: [SessionTab], windows: [(WindowID, TabRegistry.WindowTeardown)]) {
        self.parked = parked
        self.windows = windows
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The quit sequence (Quit Teardown plan, Task 1).
    ///
    /// **Why this callback and not `applicationWillTerminate`.** ⌘Q closes
    /// no window, so no window's close path runs and nothing tears a held
    /// tab down. `applicationWillTerminate` cannot fix that: it is
    /// synchronous, AppKit holds the process open only until it returns, and
    /// `TabTeardown.run(_:reason:)` is main-actor `async` — blocking the
    /// main thread to await it deadlocks, and starting a `Task` and
    /// returning gives the process permission to exit first. This callback
    /// is the one that can wait: `.terminateLater` defers the quit, and
    /// `NSApp.reply(toApplicationShouldTerminate: true)` is what releases
    /// it. That is why the four-stage order had to leave `ContentView`
    /// (see `TabTeardown`): a delegate has no view to call it on.
    ///
    /// **The order is `QuitSequence.steps`**, and
    /// `QuitSequenceTests.theDelegateRunsTheQuitStepsInOrder` pins this
    /// body against it positionally. The `.later` case is written FIRST so
    /// that reading is possible — it is the branch that runs all six steps,
    /// and `.now` repeats three of the same calls.
    ///
    /// **`.now` is not a shortcut past the teardown.** It is chosen only
    /// when `liveTabCount` is zero, counted over every tab the registry
    /// knows — parked ones included — so there is provably no session to
    /// close. The parked sweep still runs, because the RECORD of a move
    /// that never landed is written whether or not the tab was connected;
    /// with nothing live, the tabs it hands back have no session and their
    /// teardown would be a no-op, so this branch discards them and stays
    /// synchronous.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let liveTabCount = TabRegistry.shared.allTabs().filter { $0.session != nil }.count
        switch QuitSequence.decision(liveTabCount: liveTabCount) {
        case .later:
            // FIRST, and synchronously, before any teardown can run: a
            // teardown clears `tab.activeStoredSessionID`, which is exactly
            // what `describeForRestoration(_:)` writes into a seed. Ask the
            // windows afterwards and every restored tab comes back blank.
            writeRestorationSeeds()
            let windowTeardowns = TabRegistry.shared.allWindowTeardowns()
            Task { @MainActor in
                let parked = sweepUnclaimedMoves()
                let outcome = await runBoundedQuitTeardown(
                    parked: parked, windows: windowTeardowns)
                DiagnosticLog.shared.log(
                    .info, "app",
                    QuitSequence.quitLine(
                        windows: windowTeardowns.count,
                        tornDown: outcome.tornDown,
                        forced: outcome.forced))
                DiagnosticLog.shared.flushSynchronously()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .now:
            writeRestorationSeeds()
            _ = sweepUnclaimedMoves()
            DiagnosticLog.shared.log(.info, "app", "quit")
            DiagnosticLog.shared.flushSynchronously()
            return .terminateNow
        }
    }

    /// The whole deferred teardown, raced against `QuitWatchdog.bound`.
    ///
    /// **The race is two children of one group**, and the first to finish
    /// wins: the teardown chain (parked tabs, then every window's closure in
    /// registration order) and a sleeper. `group.cancelAll()` then cancels
    /// the loser.
    ///
    /// **What cancelling the chain does, exactly.** `TabTeardown.run`
    /// deliberately does not check `Task.isCancelled` — a teardown abandoned
    /// half way would leave a shell open on a connection whose queue had
    /// already been swept. So the chain checks between items instead: a
    /// cancelled chain finishes the tab or window it is already inside,
    /// under that tab's own per-stage bounds, and starts no further one. The
    /// real ceiling on a quit is therefore this bound plus at most one more
    /// window's bounded teardown, and `forced=true` in the log line is what
    /// tells a reader the difference.
    ///
    /// `tornDown` counts WINDOW closures that ran to completion, which is
    /// the number the log line reports beside `windows=`; the parked sweep
    /// is reported by its own `info` line per seed.
    ///
    /// The work list travels in a `QuitWorkList` rather than as two plain
    /// arrays: a task group's child closure must be `Sendable`, and neither
    /// `[SessionTab]` (main-actor isolated) nor a list of main-actor
    /// closures is. A `@MainActor` class IS `Sendable`, and the child that
    /// reads it is `@MainActor` too, so nothing crosses an actor at all.
    @MainActor
    private func runBoundedQuitTeardown(
        parked: [SessionTab], windows: [(WindowID, TabRegistry.WindowTeardown)]
    ) async -> (tornDown: Int, forced: Bool) {
        let work = QuitWorkList(parked: parked, windows: windows)
        return await withTaskGroup(of: QuitRaceOutcome.self) { group in
            group.addTask { await Self.runTeardownChain(work) }
            group.addTask {
                try? await Task.sleep(for: QuitWatchdog.bound)
                return .watchdogFired
            }
            // Whoever answers first decides `forced`; the other child is
            // cancelled and then drained, because a task group awaits its
            // children before it returns either way. Draining is also how
            // the chain's own count is read when the watchdog won it.
            let first = await group.next() ?? .watchdogFired
            group.cancelAll()
            var tornDown = 0
            if case .chainFinished(let count) = first { tornDown = count }
            for await outcome in group {
                if case .chainFinished(let count) = outcome { tornDown = count }
            }
            return (tornDown, first == .watchdogFired)
        }
    }

    /// The chain the group races: every parked tab, then every window's
    /// closure, in order, through the one teardown owner.
    ///
    /// **Cancellation is checked BETWEEN items and never inside one.**
    /// `TabTeardown.run` does not check it at all, on purpose — a teardown
    /// abandoned half way leaves a shell open on a connection whose queue is
    /// already swept, which is worse than either end state. So the watchdog
    /// stops this chain from STARTING further work; the item it is inside
    /// finishes under its own per-stage bounds.
    ///
    /// The returned count is window closures completed, so a chain the
    /// watchdog cut short reports fewer than it was handed — which is
    /// exactly what `tornDown=` beside `windows=` is read for.
    @MainActor
    private static func runTeardownChain(_ work: QuitWorkList) async -> QuitRaceOutcome {
        var tornDown = 0
        for tab in work.parked {
            if Task.isCancelled { return .chainFinished(tornDown: tornDown) }
            await TabTeardown.run(tab, reason: .userRequested)
        }
        for (_, runWindowTeardown) in work.windows {
            if Task.isCancelled { return .chainFinished(tornDown: tornDown) }
            await runWindowTeardown()
            tornDown += 1
        }
        return .chainFinished(tornDown: tornDown)
    }

    /// The last synchronous moment the process has, and all that is left of
    /// what this callback used to do.
    ///
    /// Everything else moved to `applicationShouldTerminate(_:)` above —
    /// AppKit calls that one first on every route that reaches this one at
    /// all, so a restoration write, a parked sweep or an `app quit` line
    /// here would be a second copy of work already done, and on the deferred
    /// path it would run AFTER the reply.
    ///
    /// The flush stays because it is cheap and it is the only guaranteed
    /// point after the reply: the teardown chain's own lines (a
    /// `TeardownStage` abandonment goes to `os.Logger`, but the parked
    /// sweep's `info` lines do not) are already flushed by the sequence
    /// itself, and anything appended between the reply and the process
    /// actually ending would otherwise be lost. It is defensive, not load
    /// bearing.
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.shared.flushSynchronously()
    }

    /// Describes every window still open and replaces `windows.json` with
    /// the result (Detachable Tabs plan, Task 5 fix round 1).
    ///
    /// **This is the only place the file is written**, and the reason is
    /// the fact `sweepUnclaimedMoves()` below already records: **⌘Q closes
    /// no windows.** The first version of restoration wrote a window's
    /// description from its own `willClose` handler, which described
    /// exactly the wrong set — every window the user deliberately closed
    /// during a session accumulated in the file, and the windows actually
    /// on screen at quit, the ones "restore windows" is about, were never
    /// described at all.
    ///
    /// Unlike the parked-move teardown this callback cannot perform, this
    /// one is a thing it CAN guarantee: `describeAllWindows()` is a
    /// synchronous read of values that returns a `[WindowSeed]`, and
    /// `replace(_:whenEnabled:)` is one synchronous file write. Nothing
    /// here awaits, so nothing here depends on the process outliving a
    /// task that may never be scheduled.
    ///
    /// Both stores are built here rather than handed down from
    /// `MacSCPApp`. `SettingsStore` persists on every set, so a store
    /// constructed now reads the value the user last chose; and
    /// `WindowRestorationStore` is a stateless struct over a directory
    /// both sides resolve the same way. An `NSApplicationDelegateAdaptor`
    /// instance is built by SwiftUI before `MacSCPApp.init` can reach it,
    /// so the alternative would be a mutable app-wide handle for the sake
    /// of two values that are cheap and unambiguous to read.
    ///
    /// With the setting off the file is deleted rather than skipped — see
    /// `WindowRestorationStore.replace(_:whenEnabled:)`.
    @MainActor
    private func writeRestorationSeeds() {
        let settings = SettingsStore(directory: SettingsStore.defaultDirectory)
        let store = WindowRestorationStore(directory: WindowRestorationStore.defaultDirectory)
        store.replace(
            TabRegistry.shared.describeAllWindows(), whenEnabled: settings.restoresWindows)
    }

    /// Every tab still parked for a window that never appeared, at the
    /// moment the process is ending (Detachable Tabs plan, Task 2 fix
    /// round 3; it TEARS DOWN as of the Quit Teardown plan, Task 1).
    ///
    /// **This used to guarantee the RECORD and deliberately not more**, and
    /// the two reasons it gave are worth keeping, because the second is what
    /// made the first fixable:
    ///
    /// 1. **No bound could apply to a teardown started from
    ///    `applicationWillTerminate`.** That callback is synchronous and
    ///    AppKit holds the process open only until it returns, while the
    ///    teardown and its `TeardownStage` bounds are `async` and
    ///    main-actor isolated — and the main thread is the thread standing
    ///    inside it. Blocking it to await them deadlocks; starting a `Task`
    ///    and returning gives the process permission to exit first.
    /// 2. **The four-stage order has one owner.** `cancelAll` →
    ///    `stopAll` → `shutdown` → `disconnect` is an architecture
    ///    invariant (`CLAUDE.md`), and spelling it a second time here would
    ///    be the second copy this project's rules exist to prevent.
    ///
    /// Both are answered rather than argued around (Quit Teardown plan,
    /// Task 1): the sweep moved to `applicationShouldTerminate(_:)`, which
    /// CAN wait, and the order moved out of `ContentView` into
    /// `TabTeardown`, which a delegate can call. So this function now hands
    /// its tabs to a caller that tears them down — under
    /// `QuitWatchdog.bound` — instead of only writing that they existed.
    ///
    /// What it still does itself is the record: one `info` line per seed,
    /// written BEFORE the teardown starts, so a diagnostic report shows a
    /// move that never landed even if the teardown is the thing that hangs.
    /// The residue a hard exit can still leave is swept at the NEXT launch
    /// by `EditSessionManager.sweepOrphanedTempDirectories()` and
    /// `ExternalTerminalLauncher.sweepOrphanedTempDirectories()` in
    /// `MacSCPApp.init`.
    ///
    /// The same sweep for a single window is that window's own close path,
    /// `ContentView.releaseUnclaimedSeedsOnClose()`; this is the one case
    /// that path cannot cover, because ⌘Q closes no window.
    @MainActor
    private func sweepUnclaimedMoves() -> [SessionTab] {
        let taken = TabRegistry.shared.takeAllPendingSeeds()
        for seed in taken {
            DiagnosticLog.shared.log(
                .info, "app", TabMoveLogLines.tornDownUnclaimed(seedID: seed.seedID))
        }
        return taken.flatMap(\.tabs)
    }
}

struct MacSCPApp: App {
    /// Installs `AppDelegate` above as `NSApp.delegate` — this is the ONLY
    /// thing that makes `applicationWillTerminate(_:)` run. `@State`/
    /// `@NSApplicationDelegateAdaptor` are both property wrappers SwiftUI
    /// resolves before `body` is ever asked for, so declaration order here
    /// doesn't matter the way it would for a plain stored property, but it
    /// is listed first as the thing the whole app's lifecycle depends on.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Single instance for the whole app — passed to `ContentView` and the
    /// `Settings` scene below (M5c/T3: no singleton, per the v2 multi-window
    /// rule).
    @State private var settingsStore: SettingsStore
    /// App-global bandwidth ceilings (M8a/T2): one shared instance for the
    /// whole app, passed to `ContentView` so every tab's queue (T3) resolves
    /// its throttle from the same buckets — limits apply in aggregate across
    /// tabs, not per tab.
    @State private var bandwidthLimiter = BandwidthLimiter()
    /// App-wide per-session audit log persistence (M9b) — one instance for
    /// the whole app, passed to `ContentView` (no singleton, same pattern as
    /// `settingsStore`/`bandwidthLimiter` above). A stateless struct over a
    /// fixed directory, so a plain default-initialized `@State` is enough.
    @State private var auditStore = AuditLogStore(directory: AuditLogStore.defaultDirectory)
    /// Tab menu command bridge (M8a/T4) — see `TabCommands`.
    @State private var settingsBridge = SettingsWindowBridge()
    /// App-global update-check state (M11b/T2) — see `UpdateCheckModel`'s
    /// doc comment for why this lives here rather than in `ContentView`'s
    /// per-tab machinery.
    @State private var updateModel = UpdateCheckModel()
    /// The releases `decideWhatsNew(store:)` decided to show this launch —
    /// see that function's doc comment. `showWhatsNew` drives the sheet's
    /// presentation; this carries what it should show once presented.
    @State private var whatsNewReleases: [ChangelogRelease] = []
    /// Whether the "What's New" sheet should be showing. Set once in
    /// `init` from `decideWhatsNew(store:)`'s result and flipped back to
    /// `false` by the sheet's own Close button (`WhatsNewSheet.onClose`).
    @State private var showWhatsNew = false
    /// Menu-bar status bridge (M11n) — one instance for the whole app,
    /// passed to `ContentView` (which mirrors its tabs into it) and to the
    /// `MenuBarController` below, same no-singleton pattern as the other
    /// app-global stores above.
    @State private var menuBarModel: MenuBarStatusModel
    /// What this launch still has to restore. Filled in `init` from the
    /// file, handed out once per half — see `WindowRestorationLaunch`.
    @State private var restorationLaunch: WindowRestorationLaunch

    /// AppKit menu-bar status item (M11n, re-landed). Retained for the app's
    /// lifetime; reads `menuBarModel` and shows/hides itself from
    /// `settingsStore.menuBarEnabled`. Replaces the SwiftUI `MenuBarExtra`,
    /// which loops SwiftUI layout on macOS 26 — see `MenuBarController`.
    private let menuBarController: MenuBarController
    /// The language that was in effect when THIS process launched (M11p):
    /// captured once in `init`, alongside the `AppleLanguages` override
    /// applied below. `GeneralSettingsTab` compares this against the live
    /// `store.selectedLanguage` to decide whether to show the relaunch
    /// button — a change only takes effect on a fresh launch.
    let launchLanguage: AppLanguage
    /// The running bundle's `CFBundleShortVersionString`, captured once in
    /// `init` for `WhatsNewSheet`'s title — empty when it could not be
    /// read (`decideWhatsNew(store:)` already declined to show anything in
    /// that case, so an empty title is never actually presented).
    let whatsNewCurrentVersion: String

    init() {
        // Sweep any orphaned edit temp directories left behind by a
        // hard-killed previous run (M6a) — first, before anything else
        // touches the temp tree.
        EditSessionManager.sweepOrphanedTempDirectories()
        // Same sweep for orphaned external-terminal launch scripts (M11d/T2)
        // — see `ExternalTerminalLauncher.sweepOrphanedTempDirectories`.
        ExternalTerminalLauncher.sweepOrphanedTempDirectories()
        // Without an app bundle (started via `swift run`) the process runs
        // as an accessory — only the regular policy brings a window and a
        // Dock icon. A real `.app` bundle lands in M6.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Build the settings store and the menu-bar bridge here (not as
        // property initializers) so the AppKit `MenuBarController` can share
        // the very same instances the views observe.
        let store = SettingsStore(directory: SettingsStore.defaultDirectory)

        // Apply the chosen UI language before any localized lookup (M11p).
        // `L10n`/`CoreL10n` defer to Foundation's AppleLanguages resolution,
        // so setting this here (before `body` builds any menu/view) is early
        // enough for a fresh launch; a change made while running needs a
        // relaunch (the bundle tables cache). `.system` clears the override.
        let language = store.selectedLanguage
        if let code = language.localeCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        launchLanguage = language

        // Diagnostic log (Diagnostic Log plan, Task 2): configure the sink
        // from the persisted setting BEFORE anything else in this process
        // could log, then write the first line so a log file always
        // identifies the build that wrote it. Placed right beside the
        // What's New decision below — both are "the first thing this launch
        // decides" — rather than inside `decideWhatsNew(store:)` itself,
        // which is unrelated to logging and already documents its own,
        // narrower contract.
        DiagnosticLog.shared.configure(level: store.diagnosticLogLevel)
        let launchVersion = Self.bundleVersion
        let launchBuild = Self.bundleBuild
        DiagnosticLog.shared.log(.info, "app", "launch version=\(launchVersion) build=\(launchBuild)")

        // "app quit" (Diagnostic Log plan, Task 2 round 1): logged from
        // `AppDelegate.applicationWillTerminate`, not from here — see that
        // type's own doc comment for why a `NotificationCenter` observer
        // (this file's prior approach) could not guarantee the line, or the
        // rest of the buffer, actually reached disk before the process
        // exited.

        // "What's New" decision (What's New plan, Task 2) — see
        // `decideWhatsNew(store:)`'s own doc comment for exactly when
        // `lastSeenVersion` gets written and why that happens inside it,
        // synchronously, rather than after the sheet is dismissed.
        let whatsNew = Self.decideWhatsNew(store: store)
        whatsNewCurrentVersion = whatsNew.current
        _whatsNewReleases = State(initialValue: whatsNew.releases)
        _showWhatsNew = State(initialValue: !whatsNew.releases.isEmpty)

        // Window restoration (Detachable Tabs plan, Task 5), beside the
        // What's New decision above because it is the same kind of thing:
        // something this launch decides ONCE, before any window exists.
        //
        // The read CONSUMES the file, in both directions: read then
        // deleted with the setting on, deleted unread with it off. A seed
        // file describes one quit and is used by exactly one launch —
        // otherwise a launch that crashed before its quit sweep ran would
        // reopen its predecessor's windows forever, and a run with the
        // setting off would leave a file behind for the next run with it
        // on to restore a generation of windows two quits old.
        //
        // NOTHING here connects. The windows come back with their tabs
        // showing the sessions they had and no connection behind them;
        // the first connect is the user's click, which is the promise the
        // settings footer makes and `WindowRestorationWiringGuardTests`
        // keeps. `openWindow(value:)` is not reachable from here either —
        // it is an environment value — so the primary window's setup pass
        // is what opens the rest (`ContentView.openRestoredWindows()`).
        let restoration = WindowRestorationStore(
            directory: WindowRestorationStore.defaultDirectory)
        let restoredWindows = restoration.consumeAtLaunch(whenEnabled: store.restoresWindows)
        _restorationLaunch = State(initialValue: WindowRestorationLaunch(
            flag: store.restoresWindows, stored: restoredWindows))

        let model = MenuBarStatusModel()
        _settingsStore = State(initialValue: store)
        _menuBarModel = State(initialValue: model)
        menuBarController = MenuBarController(model: model, settingsStore: store)
    }

    /// `CFBundleShortVersionString`/`CFBundleVersion` off `Bundle.main`, read
    /// the same way `UpdateCheckModel.check(manual:settingsStore:)` reads
    /// the short version (`UpdateCheckModel.swift:136`) — `"unknown"` when
    /// unresolvable (`swift run` outside a `.app`, or a malformed bundle),
    /// same fallback text that call site uses for its own user agent.
    private static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    private static var bundleBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
    }

    /// Decides which releases (if any) "What's New" should show this
    /// launch, and records the running version as `store.lastSeenVersion`
    /// IMMEDIATELY as part of making that decision — before `body` ever
    /// builds the sheet, let alone before the user sees or dismisses it.
    ///
    /// Recording at decision time rather than at dismissal is deliberate:
    /// `init` runs once per process launch, and a crash mid-sheet (or the
    /// app quitting before the user closes it) must not leave the same
    /// release list queued to reappear next launch as though nothing had
    /// been acknowledged — the decision itself, not the user's reaction to
    /// it, is what "seen" means here. It mirrors how
    /// `UpdateCheckModel.check(manual:settingsStore:)` already writes
    /// `settingsStore.lastUpdateCheck` right after the attempt rather than
    /// after any alert it raises is dismissed.
    ///
    /// Returns an empty `current` and `[]` releases when the running
    /// bundle carries no `CFBundleShortVersionString` at all (`swift run`
    /// outside a `.app`, or a malformed bundle) — there is no "current"
    /// version to decide against, so nothing is shown and nothing is
    /// recorded either; a `nil` read is left exactly as unresolved as it
    /// was, rather than guessed at. A resolvable `current` with no
    /// `CHANGELOG.md` bundled (`ChangelogResource.load()` returns `nil`
    /// under `swift test`/`swift run`, or a build assembled without
    /// `scripts/package-app`/the dev-build recipe) still records
    /// `current`, just against an empty release list, exactly as
    /// `WhatsNewModel.releasesToShow` would for a `lastSeen` already
    /// caught up.
    ///
    /// The same is true of a resolvable but NON-NUMERIC `current` — a dev
    /// build's `"dev-<hash>"` (Round 1 ruling, `WhatsNewModel
    /// .releasesToShow`'s doc comment): `store.lastSeenVersion = current`
    /// below runs unconditionally, after `WhatsNewModel` has already
    /// decided `toShow` — a dev build never shows the sheet, but it still
    /// records the exact string it ran under, so a LATER numeric release
    /// compares against that recorded dev string rather than against
    /// whatever real version predates it (which `releasesToShow` treats as
    /// a fresh install per that same ruling, showing nothing either way,
    /// but with the true `lastSeen` on record either way).
    private static func decideWhatsNew(
        store: SettingsStore
    ) -> (current: String, releases: [ChangelogRelease]) {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return ("", []) }

        let releases = ChangelogResource.load().map(ChangelogParser.parse) ?? []
        let toShow = WhatsNewModel.releasesToShow(
            current: current, lastSeen: store.lastSeenVersion, in: releases)
        store.lastSeenVersion = current
        return (current, toShow)
    }

    /// The PRIMARY window: the one SwiftUI opens for the value-keyed
    /// `WindowGroup` with no seed at launch.
    ///
    /// It is the only window that presents "What's New", and that is the
    /// whole difference between the two branches. The decision was taken
    /// ONCE PER PROCESS, in `init` (`decideWhatsNew(store:)`, which also
    /// records `lastSeenVersion` there and then), so `showWhatsNew` is
    /// app-scope `@State`: a second window attaching the same sheet would
    /// present the same release notes again, over a window the user opened
    /// to move a tab into.
    @ViewBuilder
    private func primaryWindow() -> some View {
        windowContent(seed: nil)
            // "What's New" (What's New plan, Task 2): `showWhatsNew` was
            // decided once, in `init`, by `decideWhatsNew(store:)` — this
            // only presents what that decision already made.
            .sheet(isPresented: $showWhatsNew) {
                WhatsNewSheet(
                    currentVersion: whatsNewCurrentVersion, releases: whatsNewReleases,
                    onClose: { showWhatsNew = false })
            }
    }

    /// A window opened by moving a tab out of another one — see
    /// `primaryWindow()` above for what it deliberately does NOT carry.
    @ViewBuilder
    private func detachedWindow(seed: WindowSeed) -> some View {
        windowContent(seed: seed)
    }

    /// Everything both windows are: the same `ContentView` over the same
    /// app-global stores, told which seed (if any) it opened with.
    ///
    /// The diagnostic-log observer lives here rather than in one branch
    /// because a level change has to take effect while ANY window is open —
    /// including after the primary one has been closed. `configure(level:)`
    /// is idempotent, so several windows reacting to one change reconfigure
    /// the same sink to the same level; what it costs is one `level=` line
    /// per open window.
    @ViewBuilder
    private func windowContent(seed: WindowSeed?) -> some View {
        ContentView(
            settingsStore: settingsStore, bandwidthLimiter: bandwidthLimiter,
            auditStore: auditStore, settingsBridge: settingsBridge, updateModel: updateModel,
            menuBarModel: menuBarModel, seed: seed,
            restorationLaunch: restorationLaunch)
            // Diagnostic log (Diagnostic Log plan, Task 2): the General
            // settings pane's picker writes `settingsStore
            // .diagnosticLogLevel` directly (`SettingsView.swift`), so
            // this is the one place a level change reconfigures the
            // sink — reusing `configure(level:)`'s own "takes effect at
            // once" contract rather than re-deriving it here.
            .onChange(of: settingsStore.diagnosticLogLevel) { _, newLevel in
                DiagnosticLog.shared.configure(level: newLevel)
                DiagnosticLog.shared.log(.info, "app", "level=\(newLevel.rawValue)")
            }
    }

    var body: some Scene {
        // The minimum size depends on the connection state (compact form vs.
        // browser) — it lives conditionally in `ContentView` instead of here
        // globally (M5c/T0).
        // Value-keyed (Detachable Tabs plan, Task 2): each window instance
        // is identified by the `WindowSeed` it was opened with, which is
        // what lets `openWindow(value:)` open a SECOND window for a tab that
        // moved out of this one. SwiftUI opens the group's own window with a
        // `nil` value at launch — that one is the PRIMARY window, and the
        // two branches below are what "primary" means in code.
        WindowGroup("macSCP", for: WindowSeed.self) { $seed in
            if let seed {
                detachedWindow(seed: seed)
            } else {
                primaryWindow()
            }
        }
        // Every menu this app adds lives in `MacSCPCommands`
        // (`MacSCPCommands.swift`): it reads the focused window's
        // `TabCommands` through `@FocusedValue`, which `App.body` — not a
        // dynamic-property type — cannot do.
        // SYSTEM window restoration stays off (Detachable Tabs plan,
        // Task 2 fix round 1), and Task 5 did not turn it back on. A
        // value-keyed group persists its `WindowSeed`s, so without this
        // macOS would reopen every detached window on the next launch with
        // a seed nobody parked anything under: a window per moved tab,
        // each holding one fresh, empty form tab.
        //
        // The app's own restoration (Task 5) is a different mechanism and
        // deliberately so: it is off unless `SettingsStore.restoresWindows`
        // says otherwise, it reads `windows.json` in `init` above, and it
        // rebuilds TABS — each showing its stored session, connected to
        // nothing — rather than window frames. The one frame that is
        // remembered is the primary window's, through AppKit's own autosave
        // name (`ContentView.applyFrameAutosave(to:)`).
        .restorationBehavior(.disabled)
        .commands { MacSCPCommands(settingsStore: settingsStore, updateModel: updateModel) }

        // Opened via Cmd-, or the app menu's "Settings…" item (M5c/T3).
        // `updateModel` passed through (M11h/T2) so the General tab's "Check
        // Now" button can drive the SAME `UpdateCheckModel` instance as the
        // app-menu item above — one shared `isChecking`/`presentedResult`,
        // not a second check path. `settingsBridge` passed through for the
        // "Manage Data" section's two window-scoped entries (logins, hidden
        // imports), which reach the main window's sheets instead of opening
        // a second copy of their own.
        Settings {
            SettingsView(store: settingsStore, updateModel: updateModel,
                         launchLanguage: launchLanguage, settingsBridge: settingsBridge)
                .tint(DesignTokens.remoteBlue)
        }

        // The menu-bar status item is an AppKit `NSStatusItem` driven by
        // `menuBarController` (created in `init`), NOT a SwiftUI scene —
        // `MenuBarExtra` loops SwiftUI layout on macOS 26. See
        // `MenuBarController`.
    }

}
