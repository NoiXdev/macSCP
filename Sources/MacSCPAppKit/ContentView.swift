import AppKit
import SwiftUI
import macSCPCore

/// The continuation bridge this sheet is presented through
/// (`ConflictPromptBridge`, with `ConflictPromptItem`) lives in Core, next to
/// the queue that drives it — it is pure state machine, and the app target
/// has no tests to hold its resumption rules honest. See
/// `Sources/macSCPCore/Presentation/ConflictPromptBridge.swift`; the
/// presentation contract it must be presented under is
/// `transferConflictSheet(bridge:)`, right below the sheet itself.

/// Conflict sheet content. Its own view type because of the local toggle
/// state (`applyToAll`) — SwiftUI instantiates it fresh for every sheet
/// presentation.
private struct ConflictSheetView: View {
    let conflict: TransferConflict
    let onResolve: (ConflictResolution, Bool) -> Void
    let onCancel: () -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("conflict.title", "File already exists"))
                .font(.headline)
            Text(String(format: L10n.string(
                "conflict.message", "“%@” already exists in “%@”."),
                conflict.fileName, conflict.destinationDirectory))
                .foregroundStyle(.secondary)
            if conflict.isPartOfFolderTransfer {
                Text(L10n.string(
                    "conflict.folderHint",
                    "Canceling stops the whole folder transfer; files already copied are kept."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L10n.string("conflict.applyToAll", "Apply to all further items"), isOn: $applyToAll)
            HStack {
                Spacer()
                Button(conflict.isPartOfFolderTransfer
                    ? L10n.string("conflict.cancelFolder", "Cancel folder transfer")
                    : L10n.string("common.cancel", "Cancel"),
                    role: .cancel) { onCancel() }
                Button(L10n.string("conflict.rename", "Rename")) { onResolve(.rename, applyToAll) }
                Button(L10n.string("conflict.skip", "Skip")) { onResolve(.skip, applyToAll) }
                Button(L10n.string("conflict.overwrite", "Overwrite"), role: .destructive) {
                    onResolve(.overwrite, applyToAll)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Escape/click-outside must NOT resolve the prompt without fulfilling
        // the continuation — that would leave `cancelAll`/the queue hanging.
        // Resolution happens exclusively through the buttons.
        .interactiveDismissDisabled(true)
    }
}

extension View {
    /// The ONE way the conflict sheet is presented, so the contract below
    /// cannot drift or be reinvented next to it.
    ///
    /// Three deliberate choices, each of which the bridge's exactly-once
    /// argument depends on (see `ConflictPromptBridge` in Core):
    ///
    /// 1. **The binding's setter is inert.** SwiftUI writes `nil` to it when it
    ///    decides the sheet should go away — but that write says nothing about
    ///    WHICH prompt it refers to, and by the time it lands the queue may
    ///    already be asking about the next file (one remote `stat` between two
    ///    conflicts, against a ~250 ms dismissal animation). Answering
    ///    "whatever is current" there returned `nil` — cancel — for a conflict
    ///    the user had not been asked about yet, and a cancelled item takes its
    ///    whole group with it: the folder transfer died after the user pressed
    ///    "Skip". The getter alone drives presentation, and `resolve` clearing
    ///    `currentPrompt` is what dismisses the sheet.
    /// 2. **The safety net names its prompt.** `onDisappear` fires on the
    ///    content view being torn down, which is the only hook that still has
    ///    `item` — so the net can say "the sheet for THIS prompt went away" and
    ///    `dismiss(promptID:)` can ignore it unless that prompt is still the
    ///    open, unanswered one. There is no `onDismiss:` here for exactly that
    ///    reason: it carries no item, so it structurally cannot name one.
    /// 3. **Every button routes into the bridge NAMING ITS OWN PROMPT**, and
    ///    the sheet itself is `.interactiveDismissDisabled(true)`, so
    ///    Escape/click-outside cannot strand a continuation for the net to have
    ///    to catch. The buttons pass `item.id` for the same reason the net
    ///    does: a tap delivered twice (double click, or a repeated press of
    ///    `Overwrite`'s `.defaultAction` shortcut) while this sheet animates
    ///    out would otherwise answer the NEXT conflict — the queue has already
    ///    asked it.
    func transferConflictSheet(bridge: ConflictPromptBridge) -> some View {
        sheet(item: Binding(
            get: { bridge.currentPrompt },
            set: { _ in /* see 1. above — deliberately inert */ })
        ) { item in
            ConflictSheetView(
                conflict: item.conflict,
                onResolve: { resolution, applyToAll in
                    bridge.resolve(
                        promptID: item.id, (resolution: resolution, applyToAll: applyToAll))
                },
                onCancel: { bridge.dismiss(promptID: item.id) }
            )
            .onDisappear { bridge.dismiss(promptID: item.id) }
        }
    }
}

/// Mediates access to the enclosing `NSWindow` — SwiftUI offers no API of
/// its own for this. `view.window` is only set AFTER the `NSView` has been
/// hooked into the window hierarchy, hence the `DispatchQueue.main.async`
/// detour (M5c/T0).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

struct ContentView: View {
    /// Passed in from `MacSCPApp` (same instance as the `Settings` scene —
    /// no singleton, per the v2 multi-window rule). Wired into every tab's
    /// queue at tab creation and kept in sync via `.onChange` (M5c/T4 queue
    /// parallelism, M5c/T5 bandwidth limits).
    let settingsStore: SettingsStore
    /// App-global bandwidth ceilings (M8a/T2), created once in `MacSCPApp`.
    /// Every tab's queue resolves its throttle from this one instance, so
    /// limits apply in aggregate across tabs (M8a/T3).
    let bandwidthLimiter: BandwidthLimiter
    /// App-wide per-session audit log store (M9b), created once in
    /// `MacSCPApp` (no singleton) — shared by `sessionListViewModel` (log
    /// cleanup on delete) and every stored-session tab's `AuditRecorder`
    /// (see `attachAuditRecorder`).
    let auditStore: AuditLogStore
    /// THIS window's menu bridge (M8a/T4), published as a focused scene
    /// value in `windowChrome(_:)` and read back by `MacSCPCommands`
    /// through `@FocusedValue` — so the menus act on the window in front
    /// without any closure having to ask whether it is that window
    /// (Detachable Tabs plan, Task 2 fix round 1). One instance per window:
    /// `@State`, so it survives every re-init of this struct.
    ///
    /// A caller may inject one (tests do); production passes nothing and
    /// gets the window's own.
    @State var tabCommands: TabCommands
    /// The Settings window's route into a main window — app-wide, and the
    /// one bridge that could not become per window. See
    /// `SettingsWindowBridge`.
    let settingsBridge: SettingsWindowBridge
    /// App-global update-check state (M11b/T2), created once in
    /// `MacSCPApp` (no singleton, same pattern as the stores above). Its
    /// result alert lives here because this is the app's one window — the
    /// same place the app-global import/export result alerts already live,
    /// despite those also being triggered from the app-wide Sessions menu.
    let updateModel: UpdateCheckModel
    /// Menu-bar status bridge (M11n), created once in `MacSCPApp` (no
    /// singleton, same pattern as the stores above) and shared with the
    /// AppKit `MenuBarController` there. This view mirrors `tabsModel.tabs`
    /// into it — once in `publishToMenuBarIfKey()`, run from
    /// `performWindowSetup()`, and again whenever the `.onChange(of: tabIDs)`
    /// in the same file's modifier chain fires — and sets its window-raising
    /// closures in `publishToMenuBarIfKey()` alone (both in
    /// `ContentView+Lifecycle.swift`); see `MenuBarStatusModel`'s doc
    /// comment.
    let menuBarModel: MenuBarStatusModel
    /// Assigned in `init` (not a bare default value) so it can pass
    /// `auditStore` through — mirrors `_tabsModel` below.
    @State var sessionListViewModel: SessionListViewModel
    /// The Keychain-backed secret store `maybeCreateNewLoginSet(from:
    /// editedSession:)` and the ad-hoc "save as session" path
    /// (`startSession`'s `shouldSaveSession` branch) both read to check
    /// for an existing managed-key passphrase, alongside `managedKeyStore`
    /// below (connection-liveness plan, Task 6 fix round 3, review item
    /// "Important — the seam is only half there"). A `let`, not
    /// constructed inline at each call site — those two call sites used to
    /// build their own `KeychainSecretStore()` on the spot, unreachable by
    /// any test seam; routing both through this one property is what lets
    /// `ContentView.init`'s `secretStore:` parameter isolate them the same
    /// way `sessionListViewModel:` isolates `startSession`'s OWN keychain
    /// write.
    let secretStore: any SecretStore
    /// The managed-key store the same two call sites read alongside
    /// `secretStore` above — same reasoning, same fix.
    let managedKeyStore: ManagedKeyStore
    /// Window-scoped tab collection (M8a/T3). Everything that used to be
    /// window-wide session state (connection form, session, queue, conflict
    /// bridge, title, edit error, reconnect flag) now lives per tab in
    /// `SessionTab`; only `window`, `lastBrowserSize`, `importedHosts`,
    /// `sessionListViewModel` and the two injected stores stay window-wide.
    @State var tabsModel: TabsViewModel<SessionTab>
    @State var importedHosts: [SSHConfigHost] = []
    /// The full, unfiltered `~/.ssh/config` parse (M11f/T2) — read from disk
    /// exactly once in `performWindowSetup()`, run from the `.task` in
    /// `ContentView+Detail.swift`. `refreshImportedHosts()` re-derives
    /// `importedHosts`/`hiddenImportAliases` from THIS, never by re-reading
    /// the config file, so hiding/unhiding an entry can never race a
    /// concurrent edit of the file the user made in a text editor.
    @State var fullImportedHosts: [SSHConfigHost] = []
    /// Aliases currently hidden from the IMPORTED sidebar section (M11f/T2),
    /// freshly read from `HiddenImportStore` by every `refreshImportedHosts()`
    /// call. Its count drives the Sessions-menu/background-menu "Hidden
    /// Imports…" title (see `tabCommands.hiddenImportsCount` below).
    @State var hiddenImportAliases: [String] = []
    /// Red inline message after `HiddenImportStore.hide`/`allHidden` throws
    /// (M11f/T2 review, findings 1+2) — same pattern as
    /// `SessionSidebar.jumpRestoreErrorMessage`. Both `hideImported` and
    /// `refreshImportedHosts` write here so a store failure is reported
    /// instead of silently leaving the row in place (hide) or failing open
    /// (refresh); cleared on the next successful `refreshImportedHosts`.
    @State var hiddenImportsErrorMessage: String?
    /// Handed over by `WindowAccessor` — basis for the active resize calls
    /// on state transitions (M5c/T0).
    @State var window: NSWindow?
    /// "Keep on Top" (Detachable Tabs plan, Task 4): per window, not
    /// persisted — Task 5's restoration seed is where a sticky flag would
    /// travel across launches, and this task adds nothing there. Applied
    /// to `window` through `WindowLevelPlan.level(keepOnTop:)` in
    /// `windowChrome(_:)`'s `.onChange` and in the `WindowAccessor` closure
    /// itself, and mirrored onto `tabCommands.keepOnTop` the same way
    /// `isActiveTabConnected` mirrors below — see `body`'s `.onChange(of:
    /// keepOnTop, …)`.
    @State var keepOnTop = false
    /// What this window was opened with (Detachable Tabs plan, Task 2):
    /// `nil` for the PRIMARY window — the one SwiftUI opens for the
    /// value-keyed `WindowGroup` with no value at launch — and a real seed
    /// for a window opened by `openWindow(value:)` when a tab was moved out
    /// of another one. `claimSeededTabs()` is what consumes it, once, on
    /// this window's setup pass.
    ///
    /// A RESTORED window is opened with a seed too, and the same setup
    /// pass consumes it — but through the other half of the type: it
    /// carries described tabs rather than live ids, so the claim comes
    /// back empty and `restoreDescribedWindow()` builds the tabs instead.
    /// See `WindowSeed` for the two halves.
    let seed: WindowSeed?
    /// Where a closing window writes its description (Detachable Tabs
    /// plan, Task 5). One instance for the whole app, passed down like the
    /// other app-scope stores — a stateless struct over a directory, so
    /// sharing it costs nothing and spelling the directory twice would be
    /// the risk.
    let restorationStore: WindowRestorationStore
    /// What this LAUNCH still has to restore (Detachable Tabs plan,
    /// Task 5) — `nil` in a `ContentView` built outside the app (every
    /// test that constructs one), which restores nothing.
    ///
    /// Both halves are handed over exactly once: the primary window takes
    /// its own description here, and it is also the window that opens the
    /// others, because `openWindow(value:)` needs an environment value
    /// `MacSCPApp.init` does not have.
    let restorationLaunch: WindowRestorationLaunch?
    /// This window's identity in `TabRegistry` (Detachable Tabs plan, Task
    /// 2). `@State`, so it is created once per window and survives every
    /// re-init of this struct — a fresh `WindowID` per body evaluation would
    /// make the registry believe a new window had opened on every repaint.
    @State var windowID = WindowID()
    /// Opens a second window for a moved tab — see `moveToNewWindow(_:)`.
    /// Not `private`: the move itself lives in `ContentView+Lifecycle.swift`.
    @Environment(\.openWindow) var openWindow
    /// Whether THIS window is the key one — the per-window signal the
    /// menu-bar bridge is gated on (see `publishToMenuBarIfKey()`). An
    /// environment value rather than a `didBecomeKey` observer: it needs no
    /// subscription and no polling, and `.onChange(…, initial: true)` sees
    /// every transition in both directions.
    @Environment(\.controlActiveState) var controlActiveState
    /// Last browser window size, remembered on disconnect — the next
    /// connect grows to it instead of the minimum size, if it's larger.
    @State var lastBrowserSize: CGSize?
    /// The width the session sidebar comes up at, read from `SettingsStore`
    /// once, when the window is built.
    ///
    /// Read once and never written again, deliberately: while the window is
    /// open the live width belongs to the split view, which is what the
    /// user's drag actually moves. Feeding a changing value back into the
    /// sidebar's ideal width would push against that drag. What flows the
    /// other way — the dragged width back into `SettingsStore` — is
    /// `SidebarWidthRecorder`'s job, and it deliberately does not come back
    /// through here.
    @State var sidebarOpeningWidth: CGFloat
    /// Tab pending a destructive close confirmation (active transfers) — nil
    /// when no confirmation is showing (M8a/T4).
    @State var closeRequest: SessionTab?
    /// Warning text for `closeRequest`, frozen at the moment the dialog is
    /// requested (M8b review, finding 4). The dialog's `message:` builder
    /// re-evaluates on every render; recomputing `TabCloseWarning.message`
    /// there instead of reading this snapshot would let the text go blank
    /// mid-dialog if the underlying transfers finish while it's still open —
    /// blank text under a destructive "Close" button.
    @State var closeWarningText: String = ""
    /// The tab whose SIBLINGS a pending "Close Other Tabs" would close —
    /// nil when no such confirmation is showing. The tab held here is the
    /// one that SURVIVES, which is also the one the menu was opened on.
    @State var closeOthersRequest: SessionTab?
    /// Warning text for `closeOthersRequest`, frozen for the same reason
    /// `closeWarningText` is: the dialog reads a snapshot rather than
    /// recomputing counts that can change while it is on screen.
    @State var closeOthersWarningText: String = ""

    // MARK: - Session already open ("Sitzung ist schon offen", C2)

    /// Everything the "already open" query needs, captured when the query
    /// is raised: what was asked for, where the existing session is, and
    /// how the row wanted it shown.
    struct AlreadyOpenSessionRequest: Identifiable {
        let id = UUID()
        /// What the sidebar row asked to start.
        let stored: StoredSession
        /// The tab "Go to Existing Tab" activates. An id rather than the
        /// tab itself: the tab can be closed while the query is up, and
        /// `TabsViewModel.activate(_:)` answers an id naming no tab by
        /// leaving the active tab alone.
        let existingTabID: UUID
        /// The row's pane override, carried through the query so "Open
        /// Anyway" starts the SAME thing that was asked for —
        /// `.terminalOnly` for the row's "Open Terminal" entry, `nil` for
        /// an ordinary connect. Without it, answering the query would
        /// quietly turn an "Open Terminal" into a plain connect.
        let paneVisibility: PaneVisibility?
        /// The snippet the overview's Run asked to have run once the
        /// connection is up, carried through the query for exactly the
        /// reason `paneVisibility` above is: "Open Anyway" has to start the
        /// SAME thing that was asked for. `nil` for every other start.
        ///
        /// It rides on the QUESTION rather than being parked on a tab
        /// (session overview plan, Task 3, fix round 1). A snippet armed
        /// before the answer would have to be un-armed by "Go to Existing
        /// Tab" and by Cancel and by a dismissal, and the tab it sat on is
        /// not necessarily the tab an answer opens; here the three answers
        /// need no clearing rule at all — two of them simply drop the
        /// request, and the third hands this to `startWithoutAsking`.
        let pendingSnippet: Snippet?
    }

    /// A sidebar start that stopped because some tab already holds the
    /// stored session it named — drives the query in
    /// `ContentView+Sheets.swift`, and is `nil` whenever none is showing.
    ///
    /// No frozen message text beside it, unlike `closeRequest` and its
    /// `closeWarningText`: that pair exists because `TabCloseWarning
    /// .message` is recomputed from transfers that keep finishing while the
    /// dialog is up, so the text could go blank mid-dialog. What this query
    /// says is the session's NAME, and the request already carries the
    /// `StoredSession` itself — a value, taken when the query was raised
    /// and unable to change afterwards.
    @State var alreadyOpenRequest: AlreadyOpenSessionRequest?

    // MARK: - Audit log (M9b/T3)

    /// Session whose audit log sheet is open, or `nil` when none is —
    /// `StoredSession` drives `.sheet(item:)` directly (it's already
    /// `Identifiable`). Opened from the sidebar's "Audit Log…" entry, works
    /// whether or not that session is currently connected.
    @State var auditLogSession: StoredSession?

    // MARK: - Connection diagnostics

    /// This window's diagnostics panel — open or not — and the one place its
    /// run is stopped.
    ///
    /// Filled by `showDiagnostics(for:)` alone, the window's single entry that
    /// every door goes through, from a `DiagnosticsTarget`: a VALUE taken at
    /// the moment the user asked, so a tab that reconnects or a row that is
    /// renamed cannot change what the open panel is diagnosing. Presenting it
    /// measures nothing; the diagnosis starts on the panel's own button
    /// (decision of 2026-09-02), and ends with the sheet or the tab.
    ///
    /// An object rather than an optional value: `endDiagnostics()` has to
    /// cancel as well as forget — see `DiagnosticsPresenter`.
    @State var diagnostics = DiagnosticsPresenter()

    // MARK: - Known hosts (M10a/T2)

    /// Drives the known-hosts management sheet — opened from the Sessions
    /// menu (⌘⇧K) and the sidebar's background context menu. No item payload
    /// needed (unlike `auditLogSession`): the sheet always shows the same,
    /// window-wide store.
    @State var showKnownHostsSheet = false

    // MARK: - Server certificates

    /// Drives the server-certificate management sheet — opened from the
    /// Sessions menu, and from Settings' "Manage Data"
    /// (`presentServerCertificatesFromSettings`). Same no-item-payload shape
    /// as `showKnownHostsSheet` above; the certificate list used to be a
    /// second section inside that sheet and is now its own overlay (see
    /// `ServerCertificatesSheet`).
    @State var showServerCertificatesSheet = false

    // MARK: - Login sets (M10b/T3)

    /// Drives the login-sets management sheet — opened from the Sessions
    /// menu (⌘⇧L), the sidebar's background context menu, and Settings'
    /// "Manage Data" (`presentLoginSetsFromSettings`). Same no-item-payload
    /// shape as `showKnownHostsSheet` above (always the same window-wide
    /// `sessionListViewModel`).
    @State var showLoginSetsSheet = false
    /// Arms the login-sets sheet to open its file picker straight away
    /// (M19/T8): the Sessions menu's "Import Logins…" opens the SAME sheet the
    /// import lives in, rather than growing a second import implementation
    /// here — and the sheet is where the result belongs anyway, since the
    /// imported sets appear in its list.
    @State var loginSetsSheetStartsImport = false

    // MARK: - Session overview (session overview plan, Task 2)

    /// The stored session the sidebar is pointing at, as reported by
    /// `SessionSidebar.onSelectSession`.
    ///
    /// An id and not a `StoredSession`, so the overview always describes the
    /// record as it stands: it is resolved against the live list on every
    /// render (`overviewSession`), which is also what makes a deleted session
    /// disappear from the detail pane without a second rule to clear this.
    ///
    /// Window-scoped rather than per-tab, matching where the sidebar is: one
    /// sidebar, one selection, and switching tabs does not move the pointer.
    @State var overviewSessionID: UUID?

    /// The session `overviewSessionID` names, or `nil` — no selection, or a
    /// selection whose session is gone.
    var overviewSession: StoredSession? {
        guard let overviewSessionID else { return nil }
        return sessionListViewModel.sessions.first { $0.id == overviewSessionID }
    }

    /// The group and login-set NAMES behind the two ids a session carries,
    /// read off the window's own lists.
    ///
    /// One line, and it exists so the resolution is asked once per render
    /// rather than once per name: the detail pane needs both halves, and
    /// calling `SessionOverviewNames.resolve` twice would walk both lists
    /// twice to build the same pair.
    func overviewNames(for session: StoredSession) -> (group: String?, loginSet: String?) {
        SessionOverviewNames.resolve(
            for: session, groups: sessionListViewModel.groups,
            loginSets: sessionListViewModel.loginSets)
    }

    // MARK: - Hidden imports (M11f/T2)

    /// Drives the hidden-imports management sheet — opened from the
    /// Sessions menu (⌘⇧I), the sidebar's background context menu, and
    /// Settings' "Manage Data" (`presentHiddenImportsFromSettings`). Same
    /// no-item-payload shape as `showKnownHostsSheet`/`showLoginSetsSheet`
    /// above: the sheet always reflects `fullImportedHosts` plus a fresh
    /// `HiddenImportStore` read of its own.
    @State var showHiddenImportsSheet = false

    // MARK: - SSH keys (M18/T5)

    /// Drives the SSH-key management sheet — opened from the Sessions menu.
    /// Same no-item-payload shape as `showKnownHostsSheet`/
    /// `showLoginSetsSheet`/`showHiddenImportsSheet` above: `SSHKeysSheet`
    /// always reflects the same window-wide `ManagedKeyStore` directory.
    @State var showSSHKeysSheet = false

    // MARK: - Snippets (Terminal-Snippets milestone)

    /// Drives the snippet management sheet — opened from the Terminal menu.
    /// Same no-item-payload shape as `showSSHKeysSheet` above; the sheet
    /// reads and writes `snippetStore` directly.
    @State var showSnippetsSheet = false

    /// The snippet a multi-line insert was just refused for — drives the
    /// refusal alert below. Non-nil only between `triggerSnippet` hitting
    /// `SnippetSendPlan.refusedMultilineInsert` and the alert's own
    /// dismissal or "Execute" action.
    @State var pendingMultilineInsertRefusal: Snippet?

    /// One snippet-variable prompt waiting for the user's values
    /// (Snippet-Variablen, Task 6) — drives `SnippetVariablePromptSheet`
    /// below. Non-nil only between `triggerSnippet` finding at least one
    /// declaration and the sheet's own "Run"/"Cancel" action; a snippet
    /// with no declarations never sets this at all, which is exactly what
    /// keeps that case sheet-free.
    struct PendingSnippetVariablePrompt: Identifiable {
        let id = UUID()
        let snippet: Snippet
        /// The caller's original Insert/Execute choice — carried through
        /// the prompt so confirming it can hand the SAME choice to
        /// `runSnippet`, unchanged by the detour through this sheet.
        let execute: Bool
        /// One entry per declaration: the remembered value if
        /// `SnippetVariableMemoryStore` had one, else `defaultValue` —
        /// computed once by `triggerSnippet` before presenting the sheet,
        /// not looked up again inside it.
        let initialValues: [String: String]
    }

    @State var pendingSnippetVariablePrompt: PendingSnippetVariablePrompt?

    /// One refused snippet, shown as a dry run instead of the prompt
    /// (Snippet-Probelauf, Task 4) — drives `SnippetDryRunSheet` below.
    /// Non-nil only between `triggerSnippet` finding a
    /// `SnippetVariableSubstitution.Problem` and the sheet's own "Send
    /// anyway"/"Close" action.
    ///
    /// Carries the `SnippetDryRun`, not a finished sentence. The sheet
    /// shows four things — the resolved command, the send form, the reason
    /// and the colouring — and only the reason is a sentence;
    /// `snippetDryRunRefusalText` is still the one mapping that produces
    /// it, so nothing downstream switches over
    /// `SnippetVariableSubstitution.Problem` a second time. `values` and
    /// `execute` ride along because "Send anyway" has to send exactly what
    /// was shown, not a second reading of the same snippet.
    ///
    /// This is the one piece of snippet state that holds a substituted
    /// value at all (inside `dryRun.resolvedCommand`). It reaches the
    /// screen and nothing else: the audit line and the export both read
    /// `snippet.command`, the template.
    struct PendingSnippetDryRun: Identifiable {
        let id = UUID()
        let snippet: Snippet
        /// The caller's original Insert/Execute choice, carried through
        /// unchanged for the same reason `PendingSnippetVariablePrompt`
        /// carries it.
        let execute: Bool
        /// The values the dry run was described with — the remembered ones,
        /// or each declaration's default. Nothing new was typed to get
        /// here: the refusal happens before the prompt would open.
        let values: [String: String]
        let dryRun: SnippetDryRun
    }

    @State var pendingSnippetDryRun: PendingSnippetDryRun?

    // MARK: - Session export/import (M9a/T3)

    /// Wraps `ExportScope` so it can drive `.sheet(item:)` — `ExportScope`
    /// itself has no stable identity of its own that covers all three cases
    /// (`.all` has none at all).
    struct ExportSheetItem: Identifiable {
        let id = UUID()
        let scope: SessionListViewModel.ExportScope
    }

    @State var exportSheetItem: ExportSheetItem?

    /// A decoded session-import payload plus whether the file it came from was
    /// itself encrypted (which the result alert's plaintext notice needs).
    struct PendingSessionImport {
        let payload: SessionExportPayload
        let wasEncrypted: Bool
    }

    // MARK: - Share link (M14/T5)

    /// Wraps the single selected remote file's S3 key plus the presigned
    /// provider captured at presentation time — the same "capture now,
    /// not later" discipline `detail`'s `bridge`/`tab` locals already use for
    /// the conflict sheet, so the sheet keeps talking to the file system it
    /// was opened against even if the active tab changes underneath it.
    struct PresignedSheetItem: Identifiable {
        let id = UUID()
        /// The object key (no leading slash) `PresignedURLSheet` pre-fills
        /// for both GET (read-only) and PUT (editable) — see
        /// `RemotePath.normalizedAbsolute` at the call site for how a
        /// `RemoteFileItem.path` becomes this.
        let itemKey: String
        let provider: any PresignedURLProvider
    }

    @State var presignedSheetItem: PresignedSheetItem?
    /// Set by `performExport` right before `showExportFileExporter`, and
    /// cleared by the `fileExporter` completion handler — which decides
    /// whether the "exported without password" alert is needed (spec M9a
    /// §3.3) from `exportMissingPasswordCount`, not from this property.
    @State var exportDocument: SessionExportDocument?
    @State var showExportFileExporter = false
    @State var exportMissingPasswordCount = 0
    @State var showExportMissingPasswordAlert = false
    @State var exportErrorMessage: String?

    @State var showImportFileImporter = false
    /// Bytes read from the chosen import file, held between the initial
    /// `probe` and the (optional) password prompt's `decode` attempt.
    @State var importFileData: Data?
    @State var showImportPasswordSheet = false
    /// A successfully decoded payload waiting to be planned and applied
    /// (M19/T8). Planning can open the conflict sheet, and SwiftUI presents
    /// only one sheet per view at a time — so an import that came through the
    /// password prompt decodes while that prompt is up and plans only once it
    /// has closed. Without the split, the conflict sheet would never appear
    /// and the password sheet would wait on it forever.
    @State var pendingImport: PendingSessionImport?
    /// Bridges the shared `ImportConflictSheet`'s callbacks to the
    /// `ImportConflictArbiter`'s decider for SESSION imports (login-set
    /// imports own an instance of the same bridge inside `LoginSetsSheet`).
    @State var importConflictBridge = ImportConflictBridge()
    @State var importResultMessage: String = ""
    @State var showImportResultAlert = false
    @State var importErrorMessage: String?

    // MARK: - Import from another program (Cyberduck import, 2026-09-03)

    /// The loaded preview the import sheet is showing, or nil while no such
    /// import is running. Built and LOADED by `presentExternalImport(folder:
    /// securityScoped:)` — which `beginExternalImport()` and the picker
    /// completion both reach — before the sheet is presented (design §4), so
    /// a missing default folder can raise the picker below instead of an
    /// error inside a sheet, and the sheet itself starts nothing when it
    /// appears. Written on the main actor after an `await`: the folder read
    /// itself runs off it.
    @State var externalImport: ImportFromSourceViewModel?
    /// The folder picker shown when the source's own bookmark folder is not
    /// where it should be (the program is not installed, or its data lives
    /// elsewhere). `.folder` rather than a file type: what is picked is the
    /// directory the source reads its bookmarks out of.
    @State var showExternalImportFolderPicker = false

    // MARK: - External terminal (M11d/T2)

    /// One requested external-terminal open, captured between the moment the
    /// toolbar button/menu entry fires and the moment the password hint (if
    /// shown) is answered — `performExternalOpen` needs all three values.
    struct ExternalTerminalRequest {
        let config: SSHConnectionConfig
        let target: TerminalTarget
        let customPath: String?

        /// Stores the config with its plaintext secrets emptied.
        ///
        /// The launch path reads none of them — `SSHCommandBuilder` passes
        /// no secret to `ssh`, which is exactly what the hint tells the
        /// user — so holding one here would buy nothing and cost a
        /// plaintext password sitting in view state for as long as the
        /// alert stays open, in a place neither `disconnect` nor
        /// `ConnectionViewModel.clearRetainedSecrets()` reaches. Redacting
        /// on the way in makes that state unrepresentable, instead of
        /// adding a third clearing path that every later change would have
        /// to remember.
        init(config: SSHConnectionConfig, target: TerminalTarget, customPath: String?) {
            self.config = config.redactingSecrets()
            self.target = target
            self.customPath = customPath
        }
    }

    /// Non-nil while the "external terminals can't receive a saved password"
    /// hint is showing (spec §4 item 6) — drives its alert below.
    @State var pendingPasswordHintRequest: ExternalTerminalRequest?
    /// Set by `performExternalOpen` on `ExternalTerminalLauncher.LaunchError`
    /// — drives the error alert below (spec §4 item 7).
    @State var externalTerminalErrorMessage: String?
    /// Set when a shell-only command (⌘T/toolbar Terminal button, or the
    /// "Terminal" menu's two entries) is invoked while the active tab's
    /// backend has no shell (M12/T7b, e.g. an S3 session) — drives the
    /// alert below. Both the toolbar button and the menu bridge closures are
    /// ALSO disabled for this condition (belt-and-suspenders): this message
    /// is the "no silent no-op" fallback for any path that reaches the
    /// action despite the disabled state.
    @State private var terminalUnavailableAlertMessage: String?

    init(
        settingsStore: SettingsStore, bandwidthLimiter: BandwidthLimiter, auditStore: AuditLogStore,
        settingsBridge: SettingsWindowBridge? = nil,
        tabCommands: TabCommands? = nil,
        updateModel: UpdateCheckModel, menuBarModel: MenuBarStatusModel,
        sessionListViewModel: SessionListViewModel? = nil,
        secretStore: (any SecretStore)? = nil,
        managedKeyStore: ManagedKeyStore? = nil,
        seed: WindowSeed? = nil,
        restorationStore: WindowRestorationStore? = nil,
        restorationLaunch: WindowRestorationLaunch? = nil
    ) {
        self.seed = seed
        // Same defaulting rule as `auditStore`'s directory and
        // `managedKeyStore`'s above: production passes the app's own
        // instance (`MacSCPApp.windowContent(seed:)`), and a caller that
        // passes nothing gets one over the ordinary storage directory.
        // Nothing is written through it unless `settingsStore
        // .restoresWindows` is on, which is off by default — so a test
        // that constructs a `ContentView` and never touches that setting
        // cannot write into the running user's data through this.
        self.restorationStore = restorationStore
            ?? WindowRestorationStore(directory: WindowRestorationStore.defaultDirectory)
        self.restorationLaunch = restorationLaunch
        self.settingsStore = settingsStore
        self.bandwidthLimiter = bandwidthLimiter
        self.auditStore = auditStore
        _tabCommands = State(initialValue: tabCommands ?? TabCommands())
        self.settingsBridge = settingsBridge ?? SettingsWindowBridge()
        self.updateModel = updateModel
        self.menuBarModel = menuBarModel
        _sidebarOpeningWidth = State(initialValue: CGFloat(settingsStore.sidebarWidth))
        _tabsModel = State(initialValue: TabsViewModel(
            initial: Self.makeTab(settingsStore: settingsStore, limiter: bandwidthLimiter)))
        // Test seam (connection-liveness plan, Task 6 fix round 2, review-
        // mandated; `secretStore`/`managedKeyStore` added in fix round 3,
        // review item "the seam is only half there" — `ContentView` still
        // built its OWN `KeychainSecretStore()`/`ManagedKeyStore(directory:
        // SessionStore.defaultDirectory)` at two other call sites,
        // `maybeCreateNewLoginSet(from:editedSession:)` and the ad-hoc
        // "save as session" path inside `startSession`, both reachable by
        // a test exercising private-key auth). Every one of these three
        // parameters defaults to `nil`, which preserves production
        // behavior byte-for-byte — `MacSCPApp.swift`, the one production
        // call site, passes nothing for any of them, so production still
        // gets the real, Keychain- and default-directory-backed instances
        // built here exactly as before these parameters existed. Passing
        // non-nil values is how a test points the whole session store, the
        // Keychain read `maybeCreateNewLoginSet`/`startSession` make to
        // check for a managed-key passphrase, and the managed-key store
        // itself at a temporary directory and an in-memory `SecretStore`
        // instead — the seam that makes it possible for a `ContentView`-
        // level test to exist at all without touching this machine's real
        // keychain or real `sessions-v2.json`. `secretStore`/
        // `managedKeyStore` resolve FIRST, so a test that supplies them but
        // leaves `sessionListViewModel` as `nil` still gets a default
        // `SessionListViewModel` built from the SAME resolved `secretStore`
        // — one isolated secret store for the whole window, not two that
        // could silently disagree.
        //
        // Built as INITIAL values here, at construction, rather than
        // properties a test reassigns afterward: an `@State` property's
        // `wrappedValue` setter is documented as requiring installation
        // into a live SwiftUI view graph to persist a mutation, which
        // nothing in this project's test suite ever does (see
        // `LivenessGiveUpOrderingTests`' own doc comment on that same
        // boundary) — measured directly while building fix round 2:
        // reassigning `view.sessionListViewModel` from a test, then
        // reading it back with no intervening call, still returned the
        // ORIGINAL value `ContentView.init` built. Choosing the initial
        // value here sidesteps that limitation entirely, since it is a
        // plain constructor argument, not a later mutation. `secretStore`/
        // `managedKeyStore` are plain `let` properties, not `@State` —
        // unlike `sessionListViewModel` they are never reassigned after
        // `init`, so they need none of `@State`'s machinery and the same
        // limitation does not apply to them; they are included in this
        // same paragraph because they are resolved alongside it, not
        // because they share its risk.
        let resolvedSecretStore: any SecretStore = secretStore ?? KeychainSecretStore()
        self.secretStore = resolvedSecretStore
        let resolvedKeyStore = managedKeyStore
            ?? ManagedKeyStore(directory: SessionStore.defaultDirectory)
        self.managedKeyStore = resolvedKeyStore
        // Named in full because `SessionListViewModel.init` no longer
        // defaults any of its stores. What each one is here, precisely —
        // this branch is NOT production-only, and reading it as such is the
        // mistake this comment exists to prevent:
        //
        // - `store:` and `loginSetStore:` are hardwired to
        //   `SessionStore.defaultDirectory`. Nothing else can be passed in
        //   at this level, and `SessionListViewModel.init` calls
        //   `reload()` — so a test that constructs `ContentView` and leaves
        //   `sessionListViewModel:` nil (still the parameter's default)
        //   reads the running user's real `sessions-v2.json` and
        //   `logins.json`. That is the residual the store-capability commit
        //   did NOT close: it made omitting a store a compile error one
        //   level down, in `SessionListViewModel`, not here.
        // - `secrets:` and `keys:` are `resolvedSecretStore` /
        //   `resolvedKeyStore`, i.e. whatever a test injected — the SAME
        //   resolved stores the rest of the view uses, not second ones
        //   built here.
        // - `auditStore:` is a required `ContentView.init` parameter, so it
        //   is whatever the caller passed; all 32 constructions under
        //   `Tests/` (counted in the pass that writes this) pass one built
        //   on a directory the test itself made.
        //
        // The way to close the residual is to make the two hardwired stores
        // parameters as well, so that omitting them cannot compile. Until
        // then this is a runtime hazard, not a type-level guarantee.
        _sessionListViewModel = State(initialValue: sessionListViewModel ?? SessionListViewModel(
            store: SessionStore(directory: SessionStore.defaultDirectory),
            secrets: resolvedSecretStore,
            auditStore: auditStore,
            loginSetStore: LoginSetStore(directory: SessionStore.defaultDirectory),
            keys: resolvedKeyStore
        ))
    }

    /// The mounted tab. Every view below renders THIS tab's state; switching
    /// tabs re-resolves all of it (sheet, banners, queue bar, toolbar).
    var activeTab: SessionTab { tabsModel.activeTab }

    /// The PRIMARY window is the one SwiftUI opened for the value-keyed
    /// `WindowGroup` with no seed (`MacSCPApp.primaryWindow()`). Two things
    /// belong to it alone and to no window opened by a move: the what's-new
    /// sheet (attached in `MacSCPApp` itself) and the update-check result
    /// alert below — both are decisions taken once per PROCESS, and a
    /// second window presenting either would show the user the same thing
    /// twice.
    var isPrimaryWindow: Bool { seed == nil }

    /// The AppKit autosave name under which the primary window's frame is
    /// remembered — see `applyFrameAutosave(to:)`. One constant, read at the
    /// single call site, so the string cannot come to differ between the
    /// place that writes the frame and the place that reads it.
    static let primaryFrameAutosaveName = "macSCP.primary"

    /// "Fresh window" state: a single, unconnected tab. Drives the compact
    /// form geometry — with a second tab around, the window keeps its
    /// browser size even while the active tab shows a form.
    var isPristine: Bool {
        tabsModel.isLastTab && !tabsModel.activeTab.isConnected
    }

    /// Mirrored into `tabCommands.isActiveTabConnected` via `.onChange` below
    /// (M11d/T2) — `MacSCPApp`'s "Terminal" menu lives in a separate Scene
    /// that doesn't observe `tabsModel`, so this is the value it reads to
    /// enable/disable its two entries.
    private var isActiveTabConnected: Bool { activeTab.isConnected }

    /// Mirrored into `tabCommands.activeTabSupportsShell` via `.onChange`
    /// below (M12/T7b), same rationale/mechanism as `isActiveTabConnected`
    /// above — the active tab's backend has no shell for an S3 session, and
    /// `MacSCPApp`'s "Terminal" menu needs to know that too.
    var activeTabSupportsShell: Bool {
        BackendDescriptor.descriptor(for: activeTab.connectionViewModel.kind).capabilities.supportsShell
    }

    /// Mirrored into `tabCommands.activeTabTerminalToggleIsUnlocked` via
    /// `.onChange` below (whole-phase review, Fix 2), same
    /// rationale/mechanism as `activeTabSupportsShell` above: the "Terminal"
    /// menu's Show/Hide entry lives in a Scene that cannot see `tabsModel`,
    /// and without this it stayed enabled while `toggleTerminal`'s own pane-
    /// lock guard silently swallowed the click.
    ///
    /// Reads `SessionTab.paneToggleState` — the same method the toolbar's
    /// own `.disabled` reads — so the menu entry and the toolbar button
    /// agree by construction rather than by two spellings of one rule.
    /// `true` while nothing is connected: the lock has no opinion there, and
    /// `isActiveTabConnected` already disables the entry.
    var activeTabTerminalToggleIsUnlocked: Bool {
        guard let session = activeTab.session else { return true }
        return activeTab.paneToggleState(
            for: .terminal, terminalIsVisible: session.terminal.isVisible,
            hasShell: activeTabSupportsShell
        ).isEnabled
    }

    /// The snippet store this window reads and writes (Terminal-Snippets
    /// milestone). A stateless struct over a fixed directory — the same
    /// shape and the same directory the known-hosts sheet's `KnownHostsStore`
    /// is built with below, so constructing one per use costs nothing and
    /// keeps the directory named in a single place.
    var snippetStore: SnippetStore {
        SnippetStore(directory: SessionStore.defaultDirectory)
    }

    /// The remembered-variable-values store this window reads and writes
    /// (Snippet-Variablen, Task 6). `SnippetVariableMemoryStore` is a
    /// class, not a struct like `SnippetStore` above (see that type's own
    /// doc comment for why) — but it is held the SAME way: constructed
    /// fresh every time it is needed, never cached across calls. That is a
    /// deliberate choice, not an oversight (Task 4's report flagged this
    /// exact question for this task to decide): every access here runs
    /// synchronously on the main actor, triggered by one discrete user
    /// action — opening the prompt (`triggerSnippet` reading `value`) or
    /// confirming it (`rememberOptedInValues` writing `remember`) — so
    /// there is never a second access from this window in flight at the
    /// same time to race against. `AuditLogStore`'s private serial queue
    /// exists because an in-memory cache is shared across MULTIPLE
    /// long-lived holders (`SessionListViewModel`, every `AuditRecorder`)
    /// that can append concurrently; nothing here shares an instance at
    /// all. A future caller that DOES need a cached, shared instance
    /// (repeated reads outside a single user action) should add that
    /// queue then, deliberately, instead of this property growing one by
    /// accident. `nil` when the file exists but fails to decode — the
    /// prompt still opens, it just has nothing remembered to pre-fill with
    /// (falls back to `defaultValue`), and a remember write on confirm is
    /// silently skipped rather than blocking the command that was just
    /// confirmed.
    var snippetVariableMemoryStore: SnippetVariableMemoryStore? {
        try? SnippetVariableMemoryStore(directory: SessionStore.defaultDirectory)
    }

    var body: some View {
        // Split from `mainContent` (M11d/T2 build fix): the External
        // Terminal `.onChange`/two `.alert`s below, chained directly onto
        // the already-large modifier chain, made the type checker time out
        // ("unable to type-check this expression in reasonable time") —
        // splitting the chain into two smaller expressions fixes that
        // without changing behavior.
        mainContent
            // Keeps `tabCommands.isActiveTabConnected` in sync (M11d/T2) —
            // see that property's doc comment for why `MacSCPApp`'s
            // "Terminal" menu needs this mirrored instead of reading
            // `tabsModel` directly. `initial: true` seeds it once at first
            // render too, not just on later transitions.
            .onChange(of: isActiveTabConnected, initial: true) { _, newValue in
                tabCommands.isActiveTabConnected = newValue
            }
            // Keeps `tabCommands.activeTabSupportsShell` in sync (M12/T7b) —
            // see that property's doc comment; mirrors `isActiveTabConnected`
            // above for the identical reason.
            .onChange(of: activeTabSupportsShell, initial: true) { _, newValue in
                tabCommands.activeTabSupportsShell = newValue
            }
            // Keeps `tabCommands.activeTabTerminalToggleIsUnlocked` in sync
            // (whole-phase review, Fix 2) — see that property's doc comment.
            // Same mirror shape as the two above; without it the flag would
            // sit on its `true` default forever and the menu entry would be
            // enabled while the click cannot land.
            .onChange(of: activeTabTerminalToggleIsUnlocked, initial: true) { _, newValue in
                tabCommands.activeTabTerminalToggleIsUnlocked = newValue
            }
            // Keeps `tabCommands.keepOnTop` in sync (Detachable Tabs plan,
            // Task 4) — same mirror shape as the three above, and applies
            // `WindowLevelPlan`'s decision to THIS window's `NSWindow` in
            // the same place: `window` may still be nil at the `initial:
            // true` firing (before `WindowAccessor` has resolved it), in
            // which case this is a no-op and the `WindowAccessor` closure
            // in `windowChrome(_:)` is what applies the level once the
            // window exists.
            .onChange(of: keepOnTop, initial: true) { _, newValue in
                tabCommands.keepOnTop = newValue
                window?.level = WindowLevelPlan.level(keepOnTop: newValue)
            }
            // Mirrors `hiddenImportAliases.count` into the command bridge
            // (M11f/T2, same rationale as `isActiveTabConnected` above):
            // `MacSCPApp`'s "Sessions" menu lives in a separate Scene that
            // doesn't observe this view's `@State`, so the "Hidden
            // Imports…" title's count suffix has to be mirrored here too.
            .onChange(of: hiddenImportAliases.count, initial: true) { _, newValue in
                tabCommands.hiddenImportsCount = newValue
                settingsBridge.hiddenImportsCount = newValue
            }
            // Password-login hint (M11d/T2, spec §4 item 6): shown once
            // before the FIRST external-terminal open of a
            // password-authenticated session, since macSCP cannot hand a
            // saved password to an outside process — ssh prompts there
            // instead. "Don't show again" persists the flag before opening;
            // "Open" opens without persisting it, so the hint reappears
            // next time.
            .alert(
                L10n.string("externalTerminal.passwordHint.title", "Password Login"),
                isPresented: passwordHintPresented
            ) {
                Button(L10n.string("externalTerminal.passwordHint.dontShowAgain", "Don't show again")) {
                    if let request = pendingPasswordHintRequest {
                        settingsStore.externalTerminalPasswordHintShown = true
                        Task {
                            await performExternalOpen(
                                config: request.config, target: request.target, customPath: request.customPath)
                        }
                    }
                    pendingPasswordHintRequest = nil
                }
                Button(L10n.string("externalTerminal.passwordHint.open", "Open")) {
                    if let request = pendingPasswordHintRequest {
                        Task {
                            await performExternalOpen(
                                config: request.config, target: request.target, customPath: request.customPath)
                        }
                    }
                    pendingPasswordHintRequest = nil
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(L10n.string(
                    "externalTerminal.passwordHint.message",
                    "macSCP can't hand a saved password to an external terminal — ssh will ask you for it there."))
            }
            // External-terminal launch failures (M11d/T2, spec §4 item 7):
            // `ExternalTerminalLauncher.LaunchError` is mapped to a concrete
            // message (app name/path, or the write-failure reason) in
            // `performExternalOpen` below.
            .alert(
                L10n.string("externalTerminal.error.title", "Couldn't Open External Terminal"),
                isPresented: externalTerminalErrorPresented
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(externalTerminalErrorMessage ?? "")
            }
            // Shell-only shortcut invoked on a non-shell backend (M12/T7b) —
            // see `terminalUnavailableAlertMessage`'s doc comment.
            .alert(
                L10n.string("shortcut.unavailableForProtocol.title", "Not Available"),
                isPresented: Binding(
                    get: { terminalUnavailableAlertMessage != nil },
                    set: { isPresented in if !isPresented { terminalUnavailableAlertMessage = nil } })
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(terminalUnavailableAlertMessage ?? "")
            }
            // Multi-line insert refused (Snippet-Mehrzeilig, Task 4): the
            // remote has no bracketed paste, and inserting a multi-line
            // command as plain keystrokes would run its leading lines. Offer
            // to execute the whole thing instead, since that path is always
            // safe — see `SnippetSendPlan`.
            .alert(
                L10n.string("snippets.insert.multilineRefused.title", "This snippet has several lines"),
                isPresented: Binding(
                    get: { pendingMultilineInsertRefusal != nil },
                    set: { if !$0 { pendingMultilineInsertRefusal = nil } }),
                presenting: pendingMultilineInsertRefusal
            ) { snippet in
                Button(L10n.string("snippets.insert.multilineRefused.execute", "Execute")) {
                    pendingMultilineInsertRefusal = nil
                    triggerSnippet(snippet, execute: true)
                }
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {
                    pendingMultilineInsertRefusal = nil
                }
            } message: { _ in
                Text(L10n.string(
                    "snippets.insert.multilineRefused.body",
                    "The remote shell cannot take a multi-line command without running it. Execute it instead?"))
            }
            // Snippet-variables prompt (Snippet-Variablen, Task 6): shown
            // instead of sending anything the moment `triggerSnippet` sees a
            // declaration. Cancelling clears the pending state and reaches
            // neither `rememberOptedInValues` nor `runSnippet` — nothing is
            // sent. Confirming remembers the opted-in values FIRST, then
            // resolves and sends — see `PendingSnippetVariablePrompt`'s doc
            // comment for why `execute` travels through unchanged.
            .sheet(item: $pendingSnippetVariablePrompt) { prompt in
                SnippetVariablePromptSheet(
                    snippet: prompt.snippet, initialValues: prompt.initialValues,
                    onConfirm: { values in
                        pendingSnippetVariablePrompt = nil
                        rememberOptedInValues(for: prompt.snippet, values: values)
                        runSnippet(prompt.snippet, execute: prompt.execute, values: values)
                    },
                    onCancel: { pendingSnippetVariablePrompt = nil }
                )
            }
            // Declared values refused (Snippet-Probelauf, Task 4): the
            // snippet's declarations do not hold up, so the prompt never
            // opens and nothing is sent by itself. Instead of an alert
            // carrying only the reason, the dry run shows what WOULD go to
            // the shell -- and under it a "Send anyway", because macSCP
            // cannot tell where the value would end up but the person
            // reading the resolved command can. That is the whole trade:
            // the way past the refusal is opened by reading it, not by
            // clicking through it.
            //
            // Shown on a refusal and on nothing else. Triggering a snippet
            // whose declarations hold up is unchanged -- no dry run, no
            // extra step. A confirmation everybody clicks through is worth
            // nothing on the one occasion it matters.
            .sheet(item: $pendingSnippetDryRun) { pending in
                SnippetDryRunSheet(
                    snippetName: pending.snippet.name,
                    dryRun: pending.dryRun,
                    // Sends the dry run that was SHOWN, not a second
                    // description of the same snippet: `sendSnippet` takes
                    // the value rather than the three inputs it was built
                    // from, so the bytes that go out are the ones the
                    // reader just read. Describing again would re-read the
                    // remote's bracketed-paste mode, and a send form that
                    // changed between the sheet opening and this button
                    // being pressed is exactly the surprise a dry run
                    // exists to remove.
                    onSendAnyway: {
                        pendingSnippetDryRun = nil
                        sendSnippet(
                            pending.dryRun, of: pending.snippet, execute: pending.execute)
                    },
                    onClose: { pendingSnippetDryRun = nil }
                )
            }
    }

    /// Re-reads `snippets.json` into the command bridge (Terminal-Snippets
    /// milestone).
    ///
    /// A read failure raises no alert here — the menu says it instead, with a
    /// disabled notice entry, because `snippetsLoad` carries the read outcome
    /// rather than a bare list (see `SnippetsLoad`). A missing store is not a
    /// failure: `SnippetStore.all()` answers an absent file with an empty
    /// array, so anything that does throw is a file that exists and cannot be
    /// decoded. The management sheet reports the same state in its own error
    /// slot, and it is the place where the user can act on it.
    func reloadSnippets() {
        tabCommands.snippetsLoad = SnippetsLoad(reading: snippetStore)
    }

    /// Sends one snippet's keystrokes to the active tab's shell.
    ///
    /// `execute` is the caller's choice, not this method's (Terminal-Snippets,
    /// Task 6): every trigger surface offers both an Insert and an Execute
    /// action per snippet, and `execute` says which one fired. It passes
    /// straight through to `SnippetSendPlanner.plan(command:execute:
    /// bracketedPaste:)`, which is where the actual byte-level guarantee
    /// ("inserting never appends a terminator") and the multi-line refusal
    /// decision are pinned — this method does not re-decide either.
    ///
    /// Capability guard as in `toggleTerminal` above: the menu entry is
    /// already disabled for a non-shell backend, and this re-checks anyway so
    /// no path can reach a silent no-op.
    ///
    /// **No key-window guard here** (session overview plan, Task 3), and
    /// none on the menu bridge either any more (Detachable Tabs plan, Task 2
    /// fix round 1). The guard existed for an APP-WIDE command set: one
    /// `tabCommands.runSnippet` closure served every window, so the Terminal
    /// menu could fire against a window that was not the one in front.
    /// `TabCommands` is per window now and published as a focused scene
    /// value, so the menu can only reach the front window's closure — being
    /// focused is the precondition, not something a closure re-checks.
    ///
    /// Every other caller of this method is a control inside one window (the
    /// terminal panel's header and its right-click menu, the sidebar row's
    /// snippet submenu, the multi-line refusal alert's "Execute", and the
    /// session overview's Run), where such a check could only ever be true —
    /// and, because `window` is `@State`, having it here also made the whole
    /// send path unreachable from a test (a `ContentView` built outside a
    /// SwiftUI hierarchy reads `window` as `nil`).
    ///
    /// The panel is revealed and the shell opened first, because the panel is
    /// closed until the user opens it and a snippet must work on a tab that
    /// has just connected. Revealing it goes through `TerminalPanelViewModel.
    /// toggle()` — the same call the toolbar button and the Terminal menu
    /// make — followed by `persistActivePaneVisibility()`, exactly like
    /// those two (whole-phase review, Fix 3). Before that this method wrote
    /// `isVisible = true` itself and saved nothing: a snippet opened the
    /// terminal and the session did not remember it, and being spelled
    /// differently from every other reveal is what kept
    /// `PaneVisibilityWiringGuardTests` from noticing.
    ///
    /// `openIfNeeded()` still runs unconditionally afterwards, and is not
    /// redundant with the `toggle()` above: the panel can already be visible
    /// with the shell in `.ended` (the "Reopen" case), where nothing would
    /// reveal anything but the shell still has to come back up. `openIfNeeded()` reaches `.running` only after the
    /// shell channel is up, so `send(_:)` here usually runs while the shell
    /// is still opening — `TerminalPanelViewModel` holds those bytes and
    /// sends them once it runs (see `pendingBytes` there). That waiting
    /// policy deliberately lives in Core, where it is under test, not here.
    ///
    /// A failed open leaves the panel in `.ended(message)`, which
    /// `terminalPanel(_:)` renders as its error text with a "Reopen" button —
    /// the tab's existing channel for a terminal that would not start, and
    /// the reason no second message is raised here.
    ///
    /// A snippet with declared variables (Snippet-Variablen, Task 6) is
    /// intercepted BEFORE any of the above: it is first run through
    /// `SnippetVariableSubstitution.firstDeclarationProblem`, and a problem
    /// there raises `pendingSnippetDryRun` and stops -- no prompt, no
    /// bytes. That dry run offers "Send anyway" (Snippet-Probelauf, Task
    /// 4), so the refusal is a thing to read past rather than a wall; a
    /// snippet whose declarations DO hold up never sees it, because a
    /// confirmation step everybody clicks through is worth nothing on the
    /// one occasion it matters. Otherwise, instead of opening the panel
    /// and sending anything, `pendingSnippetVariablePrompt` is set and this
    /// method returns. `SnippetVariablePromptSheet`'s own "Run" action
    /// (wired in `body` below) is what eventually calls `runSnippet` with
    /// the confirmed values — see that sheet's doc comment for why
    /// cancelling it reaches neither `runSnippet` nor a remembered write.
    /// A snippet with NO declarations skips this branch entirely and falls
    /// straight through to `runSnippet` with an empty `values` dictionary
    /// — the exact same path (and, since `SnippetVariableSubstitution
    /// .resolve` returns `command` verbatim when `variables` is empty, the
    /// exact same resolved text) this method sent before variables existed.
    func triggerSnippet(_ snippet: Snippet, execute: Bool) {
        guard activeTabSupportsShell else {
            presentTerminalUnavailable()
            return
        }
        guard activeTab.session?.terminal != nil else { return }
        guard snippet.variables.isEmpty else {
            // The editor blocks Save on the same check, but an IMPORTED
            // snippet's declarations never passed that editor -- and since
            // import carries declarations over, a shared file can arrive
            // with an attacker-chosen default under a template that reads
            // harmlessly. So the refusal is repeated on the run path, where
            // it is the last thing before a value is asked for at all.
            //
            // `skipsPlaceholderPlacementCheck` is passed rather than
            // ignored, because a snippet whose owner switched the placement
            // check off has to be runnable -- a waiver the editor honours
            // and the trigger does not would be a switch with no effect.
            // Passing it here does not weaken the paragraph above: the
            // waiver cannot arrive from a file (`ExportedSnippet` does not
            // name it), so it is only ever set by somebody who ticked the
            // box in this app.
            let store = snippetVariableMemoryStore
            let initialValues = snippetVariablePromptValues(for: snippet) {
                store?.value(snippetID: snippet.id, name: $0)
            }
            if SnippetVariableSubstitution.firstDeclarationProblem(
                command: snippet.command, variables: snippet.variables,
                skipsPlacementCheck: snippet.skipsPlaceholderPlacementCheck) != nil {
                // The refusal opens the dry run, and the dry run is the
                // only thing that opens here: `describing` asks the same
                // function again, with the same arguments, so the reason
                // shown is the verdict this branch was taken on rather
                // than a second opinion about it.
                pendingSnippetDryRun = PendingSnippetDryRun(
                    snippet: snippet, execute: execute, values: initialValues,
                    dryRun: SnippetDryRun.describing(
                        snippet, values: initialValues, execute: execute,
                        bracketedPaste: bracketedPasteOnActiveTab))
                return
            }
            pendingSnippetVariablePrompt = PendingSnippetVariablePrompt(
                snippet: snippet, execute: execute, initialValues: initialValues)
            return
        }
        runSnippet(snippet, execute: execute, values: [:])
    }

    /// The part of `triggerSnippet` from the values onward — extracted so
    /// `SnippetVariablePromptSheet`'s "Run" action can reach it too, with
    /// the confirmed `values` in hand.
    ///
    /// Describes the run and hands the description to `sendSnippet`. The
    /// resolve that used to sit here is inside `SnippetDryRun.describing`
    /// (still a no-op substitution when `snippet.variables` is empty — see
    /// `SnippetVariableSubstitution.resolve`'s own doc comment), and so is
    /// the send plan, which is the point: what a snippet would send is
    /// described in one place, and the dry-run sheet's "Send anyway"
    /// reaches `sendSnippet` with the description the reader just saw
    /// instead of coming back through here for a second one.
    func runSnippet(_ snippet: Snippet, execute: Bool, values: [String: String]) {
        sendSnippet(
            SnippetDryRun.describing(
                snippet, values: values, execute: execute,
                bracketedPaste: bracketedPasteOnActiveTab),
            of: snippet, execute: execute)
    }

    /// Whether the active tab's remote has announced bracketed paste.
    /// `false` for a tab with no terminal at all, which is the same answer
    /// a remote that never announced the mode gets — and `sendSnippet`
    /// leaves without sending anything in that case anyway.
    var bracketedPasteOnActiveTab: Bool {
        activeTab.session?.terminal.remoteWantsBracketedPaste ?? false
    }

    /// Turns a described dry run into bytes on the wire — the ONE place
    /// that does, which is what lets the dry-run sheet's "Send anyway"
    /// send exactly what it showed instead of describing the snippet a
    /// second time.
    ///
    /// `snippet` travels alongside the dry run rather than being recovered
    /// from it, because the two things wanted here are the TEMPLATE (for
    /// the audit line) and the resolved bytes (for the wire), and
    /// `SnippetDryRun` deliberately carries only the second.
    ///
    /// Only an EXECUTION is an event: an inserted snippet still sits in the
    /// prompt and can be edited before it runs. Recorded from `send`'s
    /// delivery callback rather than after the call, so a shell that never
    /// opens -- the bytes buffered and then discarded -- leaves no entry
    /// claiming the snippet ran. `SnippetAuditDetail.text(for:)` reads
    /// `snippet.command` — the TEMPLATE, never the dry run's resolved
    /// command — so a typed value never reaches the audit log; see
    /// `SnippetAuditDetailTests.variableValuesStayOutOfTheAuditLog`, and
    /// `SnippetVariablePromptWiringGuardTests` for the call site itself.
    func sendSnippet(_ dryRun: SnippetDryRun, of snippet: Snippet, execute: Bool) {
        guard let terminal = activeTab.session?.terminal else { return }
        if !terminal.isVisible {
            terminal.toggle()
            persistActivePaneVisibility()
        }
        terminal.openIfNeeded()

        guard case .send(let bytes) = dryRun.plan else {
            // The remote cannot take a multi-line paste without running it,
            // and this entry promised to insert. Explain instead of sending
            // bytes that would execute -- see `SnippetSendPlan`.
            pendingMultilineInsertRefusal = snippet
            return
        }
        guard execute else {
            terminal.send(bytes)
            return
        }
        let recorder = activeTab.auditRecorder
        terminal.send(bytes) {
            recorder?.recordAction(
                AuditEvent(kind: .snippetExecuted, detail: SnippetAuditDetail.text(for: snippet)))
        }
    }

    /// Persists every opted-in value (`SnippetVariable.remembersLastValue
    /// == true`) from a just-confirmed prompt, called from that sheet's
    /// "Run" action before `runSnippet`. Best-effort: `snippetVariableMemoryStore`
    /// being `nil` (an unreadable `snippet-variables.json`) or `remember`
    /// itself throwing (a failed write) is swallowed rather than blocking
    /// the command the user just confirmed — the same swallowed-write
    /// posture `SnippetStore.remove(id:)`'s cleanup step already takes for
    /// this same store (see its `VariableCleanupOutcome` doc comment): a
    /// remembered value is a convenience for NEXT time, never a
    /// precondition for running the command THIS time.
    func rememberOptedInValues(for snippet: Snippet, values: [String: String]) {
        guard let store = snippetVariableMemoryStore else { return }
        for variable in snippet.variables where variable.remembersLastValue {
            guard let value = values[variable.name] else { continue }
            try? store.remember(value, snippetID: snippet.id, name: variable.name)
        }
    }

    // MARK: - Run a snippet from the session overview (session overview plan, Task 3)

    /// The overview's "Run" on one snippet: open the connection, then run it
    /// once this tab has a shell.
    ///
    /// **It adds no way to connect.** The dial is `connectFromSidebar` — the
    /// same entry the overview's own Connect action resolves to, and the
    /// same one the sidebar row's Connect entry reaches — so the already-open
    /// query, the tab rule, TOFU, the keychain rules, the plaintext
    /// confirmation and the attempt token are the ones that path already
    /// applies, not a second set. This method's whole substance is the
    /// hand-off: it parks the snippet on the tab that is about to dial, and
    /// `deliverPendingSnippetRun(on:)` picks it up from there.
    ///
    /// **It does not pick the tab, and fix round 1 is why.** The first
    /// version armed `activeTab` itself, right after the dial, on the
    /// argument that the overview is only ever on screen for an unconnected
    /// active tab and that `TabsViewModel.sidebarConnectTarget` hands such a
    /// tab back as the target. Both halves are true and the conclusion was
    /// still the wrong shape: it made this function repeat the tab rule
    /// instead of asking it. The snippet now travels down the same call as
    /// the pane override does, and `startWithoutAsking` — where the tab rule
    /// actually runs — is the one place it is armed.
    ///
    /// **A start that asks instead of dialling carries it too.** A session
    /// another tab already holds raises the query rather than connecting
    /// (`sidebarStart`), and the snippet goes onto the REQUEST: "Open
    /// Anyway" starts what was asked for, snippet included, while "Go to
    /// Existing Tab" and Cancel drop the request and the snippet with it.
    /// Before the fix that answer connected with the snippet silently
    /// dropped.
    ///
    /// **The return value is the query's**, discardable, handed back for the
    /// reason `sidebarStart`'s own doc comment gives: setting the `@State`
    /// is the one line no test here can observe, so what it would be set to
    /// is returned instead.
    @discardableResult
    func runSnippetAfterConnecting(
        _ snippet: Snippet, on stored: StoredSession
    ) -> AlreadyOpenSessionRequest? {
        connectFromSidebar(stored, pendingSnippet: snippet)
    }

    /// Steps (2) through (4) of that sequence, evaluated fresh every time
    /// one of the facts it reads changes — `PendingSnippetRunner` is the view
    /// that watches them and calls this.
    ///
    /// **Nothing here is timed.** "The terminal is open" is
    /// `TerminalPanelViewModel.state == .running`, the tab's own published
    /// state; there is no sleep, no deadline and no retry count. A dial that
    /// never settles simply never reaches the send, which is the same thing
    /// the connecting surface is already saying on screen.
    ///
    /// The order of the guards is the design:
    ///
    /// 1. **No session yet.** Wait while the tab is still dialling; drop the
    ///    snippet once it has stopped without one. That is step (3) — a
    ///    failed connect sends nothing, and the failed-connect surface is
    ///    what the user sees. `isReconnecting` is the token that separates
    ///    the two, and `connect(in:stored:)` clears it in a `defer` that runs
    ///    after `startSession` on the success path, so this branch cannot
    ///    catch a successful attempt mid-hand-off.
    /// 2. **A different session.** The tab connected to something else, so
    ///    the snippet is dropped rather than run against a host the user did
    ///    not pick.
    /// 3. **Not the tab on screen.** `triggerSnippet` acts on `activeTab`,
    ///    so delivering into a background tab would send the command to the
    ///    wrong shell. It stays pending instead; the runner's own signal
    ///    includes which tab is active, so coming back to it delivers.
    /// 4. **The shell's own state, one case at a time** (fix round 1,
    ///    Critical). `.closed` is the only case that opens one:
    ///    `openIfNeeded()` is what makes a shell at all — a session whose
    ///    saved pane visibility hides the terminal opens none by itself, and
    ///    this sequence would otherwise wait for a `.running` nobody was
    ///    going to produce — and it does NOT reveal the panel; revealing (and
    ///    persisting that) stays `sendSnippet`'s job, at the moment there is
    ///    something to show. `.opening` waits. `.running` sends.
    ///
    ///    `.ended` gives up, and that case is the whole reason this is a
    ///    `switch` rather than the unconditional `openIfNeeded()` this
    ///    method shipped with. `TerminalPanelViewModel.openIfNeeded()`
    ///    returns early for `.opening` and `.running` but REOPENS from
    ///    `.ended` — and every one of those attempts is a state change, which
    ///    is exactly what wakes `PendingSnippetRunner` again. A shell that
    ///    will not open therefore became a loop: a tight main-actor spin for
    ///    a backend whose opener throws at once (a session with no shell —
    ///    see `startSession`'s own opener), and repeated shell-channel opens
    ///    against the server for an SSH one. One attempt, then the snippet is
    ///    dropped and the failure is said out loud, because nothing else on
    ///    screen would say it: the panel was never revealed, so its own
    ///    `.ended` text and Reopen button are not visible.
    ///
    /// **Cleared on the way out, whatever the outcome.** This method is
    /// called again for every later change of the facts above, and
    /// `triggerSnippet` can return without sending anything at all (it opens
    /// the variable prompt for a snippet that declares any — the sheet's own
    /// "Run" continues the sequence from there, exactly as it does for the
    /// terminal's snippet menu, and it does NOT come back through here). The
    /// clear is what makes the hand-off exactly-once in both cases: a second
    /// `.running`, or a prompt the user is still filling in, cannot start a
    /// second run of the same snippet.
    ///
    /// It sits before the send rather than after it, and the honest version
    /// of why: measured on 2026-09-04, moving it after leaves
    /// `SnippetAfterConnectSequenceTests` green — nothing `triggerSnippet`
    /// does re-enters this method within the same turn, so today the two
    /// orders are equivalent. Deleting it altogether is what that suite
    /// catches. Written this way because the exactly-once property should
    /// not rest on that equivalence holding for whatever the send path
    /// grows next.
    func deliverPendingSnippetRun(on tab: SessionTab) {
        guard let pending = tab.pendingSnippetRun else { return }
        guard let session = tab.session else {
            if !tab.isReconnecting { tab.pendingSnippetRun = nil }
            return
        }
        guard tab.activeStoredSessionID == pending.storedSessionID else {
            tab.pendingSnippetRun = nil
            return
        }
        guard tabsModel.activeTab.id == tab.id else { return }
        let terminal = session.terminal
        switch terminal.state {
        case .closed:
            terminal.openIfNeeded()
            return
        case .opening:
            return
        case .ended:
            tab.pendingSnippetRun = nil
            presentTerminalUnavailable(L10n.string(
                "overview.snippets.shellDidNotOpen",
                "The snippet was not sent: this session's shell did not open."))
            return
        case .running:
            break
        }
        tab.pendingSnippetRun = nil
        triggerSnippet(pending.snippet, execute: true)
    }

    /// Title for the update-check result alert (M11b/T2, spec §4) — one per
    /// `UpdateCheckResult` case, `""` while no dialog is showing (`nil`).
    /// `SwiftUI` evaluates this even during dismissal, so it must not force-
    /// unwrap `presentedResult`. Delegates to `UpdateAlertContent` (M11b
    /// final review, Finding I2) so this copy can never drift from
    /// `UpdateCheckModel`'s `NSAlert` fallback.
    var updateAlertTitle: String {
        UpdateAlertContent.title(for: updateModel.presentedResult)
    }

    /// Message body matching `updateAlertTitle` above — see
    /// `UpdateAlertContent.message` for the wording of each case.
    var updateAlertMessage: String {
        UpdateAlertContent.message(for: updateModel.presentedResult)
    }

    // MARK: - Connecting

    // MARK: - Login sets (M10b/T3)

    /// Manual mode + "Save as new login set": creates the set from the
    /// form's current fields and returns its id, or `nil` when the toggle
    /// isn't active (or the form is in Set mode, where there's nothing new
    /// to create). The name is the field's trimmed value, or
    /// `suggestedSetName(forLabel:)` when left blank (spec §3).
    ///
    /// `editedSession` is the session being edited when this runs from the
    /// edit-save path (`nil` for a brand-new connection). In edit mode
    /// `form.password` is intentionally empty ("leave empty to keep the
    /// existing secret" — see `ConnectionViewModel.beginEditing`), so an
    /// empty field here does NOT mean "no secret": it means the session's
    /// existing keychain secret must MOVE onto the new set rather than be
    /// dropped, or the session becomes unreachable after the rewire (B1).
    ///
    /// M17 review fix: a managed key's passphrase lives in the Keychain
    /// under its own `key.id` slot (`ManagedKeyPassphrase.resolve`'s doc
    /// comment) -- a session's or login set's own secret slot must never
    /// duplicate it. The decision of whether that applies now lives in
    /// `SessionSecretPolicy.usesStoredManagedPassphrase` (Core), which this
    /// function calls with `ContentView`'s own `managedKeyStore`/
    /// `secretStore` (real Keychain-backed in production, test-seamed —
    /// fix round 3 — otherwise); see that type's doc comments for why an
    /// unanswerable probe counts as "has a slot" rather than "does not".
    func maybeCreateNewLoginSet(
        from form: ConnectionViewModel, editedSession: StoredSession? = nil
    ) -> UUID? {
        guard form.loginMode == .manual, form.saveAsNewLoginSet else { return nil }

        // One path for every protocol (M22/T9). The `if form.kind == .s3`
        // branch this replaces was the only kind-aware one: everything else
        // fell through to a generic branch building
        // `LoginSet(name:username:authKind:keyPath:)`, whose `kind` DEFAULTS
        // to `.ssh` — so a WebDAV form would have written WebDAV credentials
        // into an SSH-kind set, invisible in the kind-filtered picker that
        // would then have to offer it. M22/T7 kept this control S3-only to
        // keep that unreachable; asking the descriptor to build the set is
        // what makes it correct instead of merely unreachable.
        let descriptor = BackendDescriptor.descriptor(for: form.kind)
        let trimmedName = form.newLoginSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The suggested name is the login's own identity: whichever field the
        // backend marks as identifying it (`username`, `accessKeyID`) — read
        // back off the set the descriptor just built, so this needs no branch.
        let draft = descriptor.loginSet(id: UUID(), name: "", from: form.values)
        let name = trimmedName.isEmpty
            ? sessionListViewModel.suggestedSetName(
                forLabel: draft.accessKeyID ?? draft.username)
            : trimmedName
        let newSet = descriptor.loginSet(id: draft.id, name: name, from: form.values)

        // The secret is whichever field the backend's credential schema shows
        // right now — SSH's password row under password auth, its passphrase
        // row under private-key auth, and NOTHING for an agent login, whose
        // set never carries a secret (M10d/T4). `saveLoginSet` already refuses
        // to write one for `.agent`; resolving to "no secret field" here also
        // skips the (then-discarded) keychain lookup for the edited session's
        // own secret.
        let typed = descriptor.credentialSchema.visibleSecretField(
            in: form.values, namespace: descriptor.fieldNamespace)
            .map { form.values.raw["\(descriptor.fieldNamespace).\($0.id)"] ?? "" }
        let carried: String? = typed == nil ? nil
            : SessionSecretPolicy.usesStoredManagedPassphrase(
                kind: form.kind, authChoice: form.authChoice, keyPath: form.keyPath,
                keys: managedKeyStore,
                secrets: secretStore) ? ""
            : ((typed ?? "").isEmpty
                ? (editedSession.flatMap { sessionListViewModel.password(for: $0) })
                : typed)
        sessionListViewModel.saveLoginSet(newSet, secret: carried)
        return newSet.id
    }

    /// Writes what a form holds as a NEW stored session, and nothing else —
    /// no tab bookkeeping, no window title, no connection.
    ///
    /// Lifted out of `startSession` in the tab-context-menu fix round: this
    /// code used to live inside that function's `shouldSaveSession` branch,
    /// which made "remember this connection" reachable only through the
    /// success path of a dial. A user whose ad-hoc connection was already
    /// running could not have it saved without opening a second one to the
    /// same server. Separating the two is what lets the form's own Save
    /// button (`saveFormAsSession(in:)`) write a session with no connection
    /// attempt at all, WITHOUT a second persistence path beside this one —
    /// both callers run exactly these lines.
    ///
    /// What the caller still owns is what differs between them: binding the
    /// tab to the result, the window title, and clearing
    /// `shouldSaveSession`.
    ///
    /// Set mode references the picked login set directly. Manual mode +
    /// "Save as new login set" creates the set FIRST, then references it —
    /// either way `password:` is safely ignored by `save` once `loginSetID`
    /// is non-nil (see its doc comment).
    ///
    /// ONE save for every protocol (M23/T7), and the place the last two
    /// `"unused"` placeholders died: the backend's own adapter writes its
    /// own fields out of `form.values`, so this call site does not know that
    /// S3 has a bucket and SSH has a port -- nor parks a literal in
    /// `host`/`username` for a backend that has neither.
    ///
    /// What the three branches it replaced did, and where it went:
    /// * S3/WebDAV built a `StoredS3Config`/`StoredWebDAVConfig` from the
    ///   form -> `descriptor.apply` inside `save`.
    /// * Each named its own secret field -> `SessionSecretPolicy.
    ///   valueToPersist`, which now asks the schema which row is the visible
    ///   secret.
    /// * The SSH branch alone passed `authKind`/`keyPath` -> both live in
    ///   `form.values` and are written by SSH's own `apply`.
    /// * S3/WebDAV passed NO jump and NO jump secret; the SSH branch passed
    ///   `form.buildJumpSpec()` (no `existingSecretID`: this is a brand-new
    ///   session, unlike `validateForEditSave`'s own call) and suppressed the
    ///   jump secret in session mode (spec §1: the `secretID` slot stays
    ///   unused while `sessionID` is set). Both survive verbatim --
    ///   `buildJumpSpec()` returns nil unless `jumpEnabled`, which the S3 and
    ///   WebDAV forms never offer, so the hardcoded `nil` those two branches
    ///   carried needs no `kind` check here.
    func persistFormAsSession(_ form: ConnectionViewModel) -> StoredSession? {
        let newSetID = maybeCreateNewLoginSet(from: form)
        return sessionListViewModel.save(
            name: form.saveName.trimmingCharacters(in: .whitespacesAndNewlines),
            values: form.values,
            password: SessionSecretPolicy.valueToPersist(
                resolvedSecret: form.resolvedSecret, kind: form.kind, authChoice: form.authChoice,
                keyPath: form.keyPath,
                keys: managedKeyStore,
                secrets: secretStore),
            kind: form.kind,
            groupID: form.selectedGroupID,
            loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID,
            jump: form.buildJumpSpec(),
            jumpSecret: form.jumpSourceMode == .session ? nil : form.jumpPassword,
            tags: form.tags)
    }

    /// The connection form's own "Save" button, outside edit mode: write
    /// what is on screen as a stored session **without dialing**.
    ///
    /// This is what makes the tab menu's "Save as Session…" honest. That
    /// entry prefills this form from a connection that is already up; before
    /// this button existed the only way to get the form's contents into
    /// `sessions.json` was to press Connect, so remembering a running
    /// connection meant opening a second one to the same server and saving
    /// THAT.
    ///
    /// The rules come from `ConnectionViewModel.validateForNewSave()` (run
    /// by the button itself, so a refusal highlights the offending field the
    /// way Connect's does) and the write from `persistFormAsSession`, the
    /// same lines a saved connect runs. A `nil` result means
    /// `SessionListViewModel.save` refused — it has already published its
    /// own `errorMessage`, which the sidebar shows, exactly as for a saved
    /// connect.
    ///
    /// Afterwards the form goes into EDIT mode on the session it just wrote,
    /// rather than staying a "new connection" form holding the same values a
    /// second time. Three things follow from that, all of them wanted:
    /// pressing Save again updates that session instead of writing a
    /// near-duplicate under a new id; "Save & connect" is right there for a
    /// user who did want to open it as well; and `beginEditing` rebuilds
    /// `values` from the stored session, which means the plaintext secret
    /// copied in from the running connection is gone from this form the
    /// moment it has been written to the keychain — the form's own
    /// empty-means-unchanged rule takes over from there.
    func saveFormAsSession(in tab: SessionTab) {
        let form = tab.connectionViewModel
        guard let stored = persistFormAsSession(form) else { return }
        form.shouldSaveSession = false
        form.beginEditing(stored)
    }

    /// After a successful connect: build the panes of THIS tab and save the
    /// session if requested. `storedName` is the display name for the tab/
    /// window title when connecting to an already-stored session
    /// (`connect(in:stored:)`). It exists because
    /// `connectionViewModel.saveName` cannot be trusted here: the field
    /// survives toggling "Save as session" off and earlier sessions, so an
    /// UNSAVED connection could inherit a stale, unrelated name (M5f/T5
    /// review).
    // NOTE (M9d): `startSession` stays SYNCHRONOUS deliberately. Its two call
    // sites are already inside `async` contexts (the connect button's `Task`
    // in `ConnectionFormView`, and `connect(in:stored:)`'s `Task` below), so
    // the remote home directory is resolved there — with `await` — and
    // handed in as `startPath`. Marking `startSession` itself `async` was
    // tried first and had to be reverted: it made the compiler apply
    // stricter concurrency checking to the WHOLE function body, which then
    // flagged the `shellProvider` capture in the `openShell` closure below.
    // That particular objection is gone — `RemoteShellProvider` is `Sendable`
    // now — but the function stays sync anyway, because resolving the home
    // directory exactly once per connect is what the two call sites want.
    func startSession(
        in tab: SessionTab, with fs: any RemoteFileSystem, storedName: String? = nil,
        startPath: String = "/"
    ) {
        // Clear any stale edit error from a previous session so a late
        // openInEditor task cannot misattribute its failure to this session.
        tab.editErrorMessage = nil
        let form = tab.connectionViewModel
        let shellProvider = fs as? RemoteShellProvider
        // One UUID, shared by the session and its edit manager (M5e/T4) — see
        // `BrowserSession.id`'s doc comment.
        let sessionID = UUID()
        let queue = tab.transferQueue
        // Only pay for the per-entry `FileManager.attributesOfItem` syscall
        // (and the macOS permission prompt it can trigger on Desktop/
        // Documents/Downloads) when the owner or group column is actually
        // visible (M18a). Read once at session start: the local file system
        // is built here and lives for the session's lifetime, so a
        // visibility change made in Settings while this session is already
        // open takes effect on the NEXT connect, not live — acceptable for
        // this fix, matching how `visibleColumns` is otherwise threaded
        // through as a snapshot at each call site.
        let wantsOwnerGroup = settingsStore.visibleColumns.contains(.owner)
            || settingsStore.visibleColumns.contains(.group)
        // One `StuckPaths` per session, shared by both `LocalFileSystem`
        // instances below (local-listing-never-blocks final fix round): a
        // path either instance's `metadata(for:)` proves stuck is then
        // skipped by the OTHER instance too, so the tester's own home
        // folder — the folder one keeps returning to — does not spend a
        // fresh thread rediscovering the same stuck entry on every visit.
        let stuckPaths = StuckPaths()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup, stuckPaths: stuckPaths),
            remoteFS: fs,
            local: RemoteBrowserViewModel(
                fs: LocalFileSystem(fetchesOwnerGroup: wantsOwnerGroup, stuckPaths: stuckPaths),
                startPath: NSHomeDirectory(),
                logCategory: "browser.local"),
            remote: RemoteBrowserViewModel(fs: fs, startPath: startPath, logCategory: "browser.remote"),
            terminal: TerminalPanelViewModel(openShell: { term, cols, rows in
                guard let shellProvider else {
                    throw RemoteFSError.protocolError(
                        reason: "This connection does not support a terminal.")
                }
                return try await shellProvider.openShell(
                    terminal: term, cols: cols, rows: rows)
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: queue),
            // Both callers of `startSession` already resolved this via
            // `homeDirectoryPath()` before calling in (see this function's
            // own `startPath` parameter doc comment) — captured here too for
            // the liveness probe, see `BrowserSession.homePath`'s doc comment.
            homePath: startPath
        )
        // Fresh liveness for a fresh session (Task 4, fix round 1):
        // `SessionTab.liveness` lives on the tab, not the session (see that
        // property's own doc comment for why), so it needs its own reset
        // here rather than getting one for free from `BrowserSession`'s
        // memberwise init the way it used to.
        tab.liveness = .connected
        // Nothing left to describe (connection-liveness plan, Task 7): this
        // tab has a live session again, so the record of the connection
        // that dropped — including the attempt counter an unattended
        // schedule was pacing itself by — goes with the state it explained.
        // A later drop starts a fresh episode from `handleLivenessGiveUp`,
        // at attempt zero.
        tab.lostConnection = nil
        // Hidden-files toggle (M7a/T4): applied once here at session start,
        // kept in sync afterwards by the `.onChange` observer above.
        tab.session?.local.showHiddenFiles = settingsStore.showHiddenFiles
        tab.session?.remote.showHiddenFiles = settingsStore.showHiddenFiles
        // The tab's queue is created ONCE (in `SessionTab.init`, together with
        // its limiter/concurrency/decider wiring) and OUTLIVES each session of
        // that tab (M5d/T3): interrupted transfers stay in the bar across a
        // disconnect/reconnect so `retryInterrupted` can resume them.

        // Grow the window to the browser size (user feedback 2026-07-10,
        // M5c/T0) — to the last remembered browser size, if any and larger
        // than the minimum size. Gated on actual window GEOMETRY, not tab
        // connectivity (M8a/T3 review): "no tab connected" is not the same
        // as "window is form-sized" — a second form tab plus a manually
        // resized window would otherwise let a later connect yank the
        // window back down. The target is clamped to at least the current
        // frame size and the resize only fires when the window is smaller
        // than that target in either dimension, so a connect can only grow
        // the window, never shrink it.
        if let window {
            let targetSize = CGSize(
                width: max(lastBrowserSize?.width ?? 0, 930),
                height: max(lastBrowserSize?.height ?? 0, 620))
            if window.frame.width < targetSize.width || window.frame.height < targetSize.height {
                resizeWindow(
                    toWidth: max(targetSize.width, window.frame.width),
                    height: max(targetSize.height, window.frame.height))
            }
        }

        var titleName = storedName
        // M31: hoisted out of the branch below so the audit recorder can be
        // attached for BOTH cases -- see the comment at the attach itself.
        var storedSession: StoredSession?
        if form.shouldSaveSession {
            let stored = persistFormAsSession(form)
            storedSession = stored
            tab.activeStoredSessionID = stored?.id
            form.shouldSaveSession = false
            titleName = stored?.name ?? titleName
        }

        // Audit recorder (M9b/T3, un-nested in M31). This used to sit INSIDE
        // the branch above, so the audit trail depended on whether the
        // connection was SAVED rather than on whether it happened: an
        // unsaved connect logged nothing at all -- not even the M21
        // plaintext-transport note, which `attachAuditRecorder` writes.
        // `AdHocAudit.logSessionID` supplies the fixed id for that case.
        //
        // `displaySummary` (M22/T11), not host/username directly: a legacy S3
        // or WebDAV session still carries the `"unused"` placeholder in those
        // two (a freshly saved one no longer does, since M23/T7), which is
        // what used to leave "connected to unused as unused" in the audit
        // trail for anything but SSH. The saved case keeps reading it from
        // the SESSION verbatim, so nothing about an existing session's log
        // changes; only the ad-hoc case reads the form, which is its only
        // source.
        //
        // `form.jumpHost` (M-1 fix, final review), not `stored.jump?.host`:
        // for a session-mode jump `form.jumpHost` already holds the freshly
        // resolved host (`SessionListViewModel.resolveJumpSession` filled it
        // before `connect()` ran, a few lines above `buildJumpSpec()` reads
        // the very same field) -- using `stored.jump?.host` instead happened
        // to read the identical value here (it's the trimmed copy of this
        // same field), but only by accident, not by construction;
        // `form.jumpHost` is the one field guaranteed to be current in both
        // connect paths.
        let auditDescriptor = BackendDescriptor.descriptor(
            for: storedSession?.kind ?? form.kind)
        attachAuditRecorder(
            to: tab,
            sessionID: AdHocAudit.logSessionID(storedID: storedSession?.id),
            summary: storedSession.map {
                auditDescriptor.displaySummary(auditDescriptor.sessionValues($0))
            } ?? auditDescriptor.displaySummary(form.values),
            viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)

        // Tab/window title: a stored session's name when this connection is
        // actually backed by one (just saved above, or passed in by
        // `connect(in:stored:)`), otherwise the backend's own `displaySummary`
        // (M22/T11) — NOT the old hand-rolled "\(form.username)@\(form.host)",
        // which read SSH-only fields and left a WebDAV tab titled "tim@" (its
        // real user name lives on `WebDAVField.username`, its host on
        // `SSHField.host` was simply never written). Window chrome (proper
        // name + user data), deliberately not localized (no catalog key).
        tab.titleName = titleName?.isEmpty == false
            ? titleName!
            : BackendDescriptor.descriptor(for: form.kind).displaySummary(form.values)
    }

    /// Completes the AD-HOC connect form's own attempt after
    /// `ConnectionViewModel.connect()` has already succeeded (connection-
    /// liveness plan, Task 6 fix round 2) — `ContentView.detail`'s
    /// `onConnected` closure calls this instead of inlining the hand-off,
    /// so `Tests/macSCPAppKitTests/` can drive it directly (the same move
    /// `handleLivenessGiveUp(_:)` made for the probe's give-up path — see
    /// that method's own doc comment).
    ///
    /// `attempt` is `tab.reconnectAttempt`'s value the CALLER captured the
    /// moment its closure started running, before `fs.homeDirectoryPath()`
    /// — not read fresh in here, which would defeat the whole point: Cancel
    /// moves `tab.reconnectAttempt` unconditionally (see that property's
    /// own doc comment) the instant it runs, and the guard below only means
    /// something if it compares against a value captured BEFORE the
    /// vulnerable `await`, not after.
    ///
    /// The bug this closes (Critical, fix round 2 review): `form.connect()`
    /// already refuses to hand back a result for an attempt Core itself
    /// superseded, but by the time `fs` reaches this function `Connection
    /// ViewModel.state` has already moved to `.idle` — the dial succeeded —
    /// so a Cancel that lands during `fs.homeDirectoryPath()` below is
    /// invisible to Core entirely. Left ungated, `startSession` would run
    /// unconditionally: it sets `tab.session`, publishes `.connected`, and —
    /// with the form's "save as session" toggle on — persists a NEW
    /// `StoredSession` and writes its secret to the keychain, all for a
    /// connection the user had already clicked Cancel on.
    func handleAdHocConnected(
        _ fs: any RemoteFileSystem, in tab: SessionTab, attempt: UUID
    ) async {
        // Remote home start (M9d): resolved once per connect, right before
        // the browser session is built, so the remote pane opens where the
        // user actually lands after login instead of hardcoded "/". A
        // lookup failure (older SFTP servers, permission quirks) falls back
        // to "/" rather than failing the connect.
        // Accept only usable absolute paths (M9d final review): an
        // empty/relative realpath result would land the pane in .failed
        // where "/" always worked.
        let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
        let home = resolved.hasPrefix("/") ? resolved : "/"
        guard tab.reconnectAttempt == attempt else {
            // The dial itself succeeded — `fs` is a live, open connection —
            // but the hand-off it was for has been superseded. Nothing
            // else owns this connection: `tab.session` is (and stays) nil
            // on this path, so the only other place a `disconnect()` call
            // could come from — `teardown(_:)`, gated on `tab.session !=
            // nil` — will never reach it, and `deinit` cleanup is against
            // this project's own rules (see the architecture invariants).
            // Left uncalled, the connection the user cancelled would stay
            // open on the remote host until the whole process exits
            // (fix round 3, review-measured).
            await fs.disconnect()
            return
        }
        startSession(in: tab, with: fs, startPath: home)
    }

    // MARK: - Pane visibility (P2 terminal-chrome milestone, Task 4)

    /// Restores `tab`'s pane visibility to what was last saved for `stored`,
    /// right after `startSession` has built a fresh `BrowserSession` for it.
    /// A no-op when `tab.session` is somehow absent (defensive only — the
    /// caller always calls this immediately after `startSession`, which sets
    /// it).
    ///
    /// A fresh `TerminalPanelViewModel.isVisible` always starts `false`, so
    /// making the terminal come up visible again means CALLING THE SAME
    /// TOGGLE the toolbar's Terminal button calls in `.builtIn` mode —
    /// `TerminalPanelViewModel.toggle()` — rather than reaching into its
    /// `isVisible` property directly and separately deciding whether to open
    /// a shell. There is only ever one "make the terminal appear" path; this
    /// is that path, run once at connect time instead of by a click. Opening
    /// a shell here is therefore the intended reading of "opens as it last
    /// stood": the shell channel multiplexes over the connection `fs` just
    /// established (architecture invariant — one SSH connection per window,
    /// SFTP and the terminal share it), so this adds no second connection,
    /// no extra host-key/TOFU prompt, and no separate audit entry (shell
    /// opens are not an `AuditEvent.Kind` case) — nothing a user would
    /// experience as a surprise.
    ///
    /// The DECISION — which halves the saved value means, with `hasShell`
    /// folded in — moved to `SessionTab.applyRestoredPaneVisibility` in the
    /// whole-phase re-review (item 2), so it can be tested at all; what is
    /// left here is the one thing that cannot be: calling `toggle()` on the
    /// session this method was handed. See that method for the rest of this
    /// comment's reasoning, which now lives next to the code it describes.
    ///
    /// `hasShell` is folded in through `tab.effectivePaneVisibility` itself —
    /// the SAME method `paneToggleState` and the render condition call — not
    /// a hand-rebuilt `PaneVisibility(showsFiles:showsTerminal:)` that
    /// happens to compute the identical fold today (fix round 1: the first
    /// draft of this method did exactly that, which is drift waiting to
    /// happen — two call sites computing the same thing independently can
    /// start disagreeing the moment either one changes, and
    /// `PaneRenderConditionGuardTests` cannot see this file, only
    /// `ContentView+Detail.swift`). Reusing the method itself means there is
    /// only ever one place that fold is written down. `tab.showsFiles` is
    /// set to the RAW saved value first — never the repaired one — matching
    /// how `showsFiles` behaves everywhere else in this type: the repair is
    /// something every read site applies fresh via `effectivePaneVisibility`,
    /// never something baked back into the stored raw boolean.
    ///
    /// This is the STORED-session path only, and deliberately still is
    /// (whole-phase review, Fix 1). The ad-hoc connect path needs no
    /// counterpart here: `showsFiles` lives on `BrowserSession` now, so a
    /// connect with nothing saved comes up on the default because the
    /// session it just built has never been told otherwise — not because
    /// some second call site remembered to reset it. What this method adds
    /// is the one thing that cannot be structural: putting a DECIDED value
    /// on screen.
    ///
    /// Which value that is, it does not decide (P3c/T2): the caller passes
    /// it — the session's saved one for an ordinary connect, or
    /// `PaneVisibility.terminalOnly` for the sidebar's "Open Terminal"
    /// entry. Taking a `PaneVisibility` rather than the `StoredSession` is
    /// what keeps this method the single reveal path for both instead of
    /// growing a second one beside it.
    func restorePaneVisibility(
        for tab: SessionTab, visibility: PaneVisibility, descriptor: BackendDescriptor
    ) {
        guard let session = tab.session else { return }
        let opensTerminal = tab.applyRestoredPaneVisibility(
            visibility, hasShell: descriptor.capabilities.supportsShell)
        if opensTerminal {
            session.terminal.toggle()
        }
    }

    /// Persists the active tab's current pane visibility into its stored
    /// session, if it is connected to one (P2 terminal-chrome milestone,
    /// Task 4) — called after every Files/Terminal toggle click, in addition
    /// to the in-memory flip those toggles already perform, so a reopened
    /// session comes up showing what was last on screen instead of the
    /// default.
    ///
    /// Reads `SessionTab.effectivePaneVisibility` — the SAME method the
    /// toolbar's `paneToggleState` and the render condition read — so what
    /// gets written is exactly what is now on screen, not a re-derivation
    /// that could disagree with it.
    ///
    /// A no-op for an ad-hoc (unsaved) connection, which has no
    /// `StoredSession` to persist into.
    func persistActivePaneVisibility() {
        guard let sessionID = activeTab.activeStoredSessionID, let session = activeTab.session
        else { return }
        let visibility = activeTab.effectivePaneVisibility(
            terminalIsVisible: session.terminal.isVisible, hasShell: activeTabSupportsShell)
        sessionListViewModel.updatePaneVisibility(for: sessionID, to: visibility)
    }

    /// Sidebar connect — a double click on a row, Return on the selected
    /// row, or the row's own "Connect" entry, never a single click (see
    /// `SessionRowActivation`). One line onto `sidebarStart`, which is
    /// where the already-open query and the tab rule both live.
    /// `pendingSnippet` is the session overview's Run and nothing else — a
    /// snippet to hand the connection once it has a shell (Task 3). It
    /// travels as an argument of the ordinary connect rather than as a
    /// second entry point, which is what keeps "Run" from being a fourth
    /// way onto the host: this is still the one call, and everything it
    /// applies still applies.
    @discardableResult
    func connectFromSidebar(
        _ stored: StoredSession, pendingSnippet: Snippet? = nil
    ) -> AlreadyOpenSessionRequest? {
        sidebarStart(stored, paneVisibility: nil, pendingSnippet: pendingSnippet)
    }

    /// Sidebar row "Open Terminal" (P3c/T2): the SAME start a sidebar row
    /// performs, differing in one argument — the session comes up showing
    /// the terminal instead of the file browser.
    ///
    /// The already-open query, the tab rule (`sidebarConnectTarget`), the
    /// in-flight guard, an already-connected session, and every failure
    /// path are therefore not "the same as Connect" by inspection but by
    /// construction: this method is `connectFromSidebar` with the pane
    /// override filled in, and both are one line onto `sidebarStart`. Two
    /// entries that behaved differently for no reason would only confuse.
    func openTerminalFromSidebar(_ stored: StoredSession) {
        sidebarStart(stored, paneVisibility: .terminalOnly)
    }

    /// What a sidebar row's start actually does ("Sitzung ist schon offen",
    /// C2): when a tab already holds this stored session, raise the query
    /// and start nothing; otherwise go ahead exactly as before.
    ///
    /// Identity is `SessionTab.activeStoredSessionID` and nothing else —
    /// an ad-hoc connection to the same host never counts, because a typed
    /// connection can carry other credentials, another key, another jump
    /// host. Comparing hosts would be guessing at an equality this program
    /// does not know.
    ///
    /// The ACTIVE tab holding the session is not a special case: the query
    /// is raised for it too, and jumping is then a no-op — the right effect
    /// of that choice rather than a reason to withhold it, since "open
    /// another one" means exactly what it means anywhere else.
    ///
    /// Reconnecting in place never reaches here (`reconnect(_:)` calls
    /// `connect(in:stored:)` directly), which is correct: that is the same
    /// tab, and nothing about it is doubled.
    ///
    /// **The return value is what the query would be raised with.** It is
    /// discardable and every caller in this file discards it. Setting the
    /// `@State` is the one line no test of this project can observe — a
    /// `ContentView` built outside a SwiftUI hierarchy drops writes to
    /// `@State` (measured in `ConnectAttemptHandoffTests`' "Isolation,
    /// round 2") — so the value it would be set to is handed back instead
    /// of only being parked, and `AlreadyOpenSessionTests` reads it there.
    @discardableResult
    func sidebarStart(
        _ stored: StoredSession, paneVisibility: PaneVisibility?, pendingSnippet: Snippet? = nil
    ) -> AlreadyOpenSessionRequest? {
        guard let existing = tabsModel.tabHolding(
            stored.id, storedSessionIDOf: \.activeStoredSessionID)
        else {
            startWithoutAsking(
                stored, paneVisibility: paneVisibility, pendingSnippet: pendingSnippet)
            return nil
        }
        let request = AlreadyOpenSessionRequest(
            stored: stored, existingTabID: existing.id, paneVisibility: paneVisibility,
            pendingSnippet: pendingSnippet)
        alreadyOpenRequest = request
        return request
    }

    /// The start itself, with no question asked — the tab rule picks the
    /// target (the active tab when it is unconnected, otherwise a FRESH
    /// tab, so a running session is never torn down by a sidebar connect,
    /// M8a spec 1.2) and the connect runs.
    ///
    /// This is what "Open Anyway" means, and it is the same function a
    /// start reaches when no tab holds the session at all — not a second
    /// copy of that path. A second copy is how the answer to the query
    /// would start drifting from the behaviour it is offering.
    ///
    /// `pendingSnippet` is the session overview's Run (Task 3, fix round 1),
    /// and this is the ONE place it is armed: the tab rule picks the target
    /// here, so this is the first moment anybody knows which tab the snippet
    /// belongs to. Arming for the query's own answer therefore costs
    /// nothing extra — "Open Anyway" comes back through this same function
    /// with the snippet the request carried.
    ///
    /// Armed only when the target is not already dialling, mirroring
    /// `connect(in:stored:)`'s own top-of-function guard: that call is about
    /// to return without doing anything, and a snippet left behind would
    /// wait for somebody else's attempt to produce a shell. The target is
    /// never a CONNECTED tab (`sidebarConnectTarget` answers a connected
    /// active tab with a fresh one), so `connect`'s reconnect-in-place
    /// teardown — which clears `pendingSnippetRun` — cannot run here and
    /// take this write back.
    func startWithoutAsking(
        _ stored: StoredSession, paneVisibility: PaneVisibility?, pendingSnippet: Snippet? = nil
    ) {
        let target = tabsModel.sidebarConnectTarget(
            activeTabIsConnected: activeTab.isConnected, makeTab: makeTab)
        if let pendingSnippet, !target.isReconnecting {
            target.pendingSnippetRun = SessionTab.PendingSnippetRun(
                snippet: pendingSnippet, storedSessionID: stored.id)
        }
        connect(in: target, stored: stored, paneVisibility: paneVisibility)
    }

    /// "Go to Existing Tab" — the whole of that choice.
    ///
    /// It closes nothing and merges nothing: the other tab keeps its
    /// session, and this window simply looks at it. When the tab named here
    /// is already the active one, activating it changes nothing, which is
    /// what that answer means in that situation.
    func jumpToOpenSession(_ request: AlreadyOpenSessionRequest) {
        // Nothing to clear for the overview's Run (session overview plan,
        // Task 3, fix round 1). A snippet asked for while this query was
        // raised rode on the REQUEST, never on a tab, so this answer drops
        // it by discarding the request — and the clear that used to stand
        // here could take a snippet away from a dial the active tab was
        // already running for something else.
        tabsModel.activate(request.existingTabID)
    }

    /// Fills the tab's form from the store + keychain and connects right
    /// away. No teardown of any other tab.
    ///
    /// `paneVisibility` overrides which halves the session comes up
    /// showing (P3c/T2). `nil` means "whatever this session saved", the P2
    /// behaviour, and it is what every caller passes except the sidebar
    /// start (`startWithoutAsking`), which forwards whatever the row asked
    /// for — `.terminalOnly` for the "Open Terminal" entry and `nil` for an
    /// ordinary connect. That override is the ONLY thing that entry changes
    /// about a connect: it comes through this same method, so the tab rule,
    /// the reconnect guard, the fill, the failure handling and the audit
    /// record are not a second implementation that could drift from this
    /// one. Nothing is persisted either way — see `PaneVisibility
    /// .terminalOnly`.
    func connect(
        in tab: SessionTab, stored: StoredSession, paneVisibility: PaneVisibility? = nil
    ) {
        guard !tab.isReconnecting else { return }
        // Connecting to a DIFFERENT session ends the episode the lost
        // surface was describing (connection-liveness plan, Task 7): the
        // user has moved on, and a failure now belongs to what they just
        // asked for, not to the connection that dropped earlier — which
        // would otherwise send them back to a surface offering to redial
        // something else entirely. `reconnect(_:)` passes the SAME id, so
        // its own failures still return to the surface that explains them.
        if tab.lostConnection?.storedSessionID != stored.id { tab.lostConnection = nil }
        tab.isReconnecting = true // synchronous — locks this tab immediately, before the first await
        // Attempt-scoped (connection-liveness plan, Task 6 fix round 1,
        // measured by review — Critical 1): Cancel releases `isReconnecting`
        // directly rather than waiting for THIS Task's own `defer`, which
        // stays suspended on `await form.connect()` for as long as the
        // abandoned dial keeps running. Without `reconnectAttempt`, that
        // deferred release would still fire once the abandoned dial finally
        // settles — clearing `isReconnecting` for whatever attempt is
        // current AT THAT LATER MOMENT, not this one. See
        // `SessionTab.reconnectAttempt`'s own doc comment.
        let myAttempt = UUID()
        tab.reconnectAttempt = myAttempt
        Task {
            defer {
                if tab.reconnectAttempt == myAttempt { tab.isReconnecting = false }
            }
            // Defensive only: the sidebar rule always hands over an
            // unconnected tab. Reconnecting in place still tears THIS tab's
            // session down first, never anyone else's.
            if tab.isConnected { await teardown(tab, reason: .userRequested) }
            let form = tab.connectionViewModel
            let descriptor = BackendDescriptor.descriptor(for: stored.kind)
            // ONE fill for every protocol, shared with the sidebar's
            // "Open in External Terminal" entry — see `fillForm`. A `false`
            // means it already published the reason on THIS form, which is
            // on screen, so there is nothing more to show here.
            guard try fillForm(form, from: stored) else { return }

            // The dial's origin (failed-connect surface plan, Task 3;
            // rebound to the attempt by the two-open-questions design, M3).
            // It travels as an argument rather than being parked on the tab
            // first: `connect(origin:)` records it only for a call it
            // actually turns into an attempt, so a dial refused because
            // this form is already connecting leaves nothing behind for a
            // later attempt to inherit. See `ConnectionViewModel
            // .attemptOrigin`.
            if let fs = await form.connect(origin: stored.id) {
                // Accept only usable absolute paths (M9d final review): an
                // empty/relative realpath result would land the pane in
                // .failed where "/" always worked.
                let resolved = (try? await fs.homeDirectoryPath()) ?? "/"
                let home = resolved.hasPrefix("/") ? resolved : "/"
                // Hand-off guard (connection-liveness plan, Task 6 fix
                // round 2, Critical — measured by review): `form.connect()`
                // already refuses to return a result for an attempt Core
                // itself has superseded (`ConnectionViewModel
                // .currentAttempt`), but Cancel can still land in the
                // window AFTER that `await` returns and BEFORE this line —
                // `await fs.homeDirectoryPath()` above is itself an `await`,
                // and during it `ConnectionViewModel.state` is already
                // `.idle` (the dial succeeded), not `.connecting`, so
                // nothing Core-side observes a Cancel that arrives here.
                // `tab.reconnectAttempt` is the one thing Cancel moves
                // UNCONDITIONALLY (see that property's own doc comment) —
                // checking it here, immediately before the hand-off, is
                // what stops this exact attempt from setting `tab.session`,
                // `activeStoredSessionID`, restoring pane visibility, or
                // writing an audit record for a connection the user already
                // backed out of.
                guard tab.reconnectAttempt == myAttempt else {
                    // Same reasoning as `handleAdHocConnected`'s own
                    // refusal branch: `fs` is a live, open connection with
                    // nothing else left to close it (`tab.session` stays
                    // nil on this path, so `teardown(_:)` never reaches it,
                    // and `deinit` cleanup is against this project's own
                    // rules) — left uncalled, it would stay open until the
                    // process exits (fix round 3, review-measured).
                    await fs.disconnect()
                    return
                }
                startSession(in: tab, with: fs, storedName: stored.name, startPath: home)
                tab.activeStoredSessionID = stored.id
                // Pane visibility (P2 terminal-chrome milestone, Task 4):
                // restore what was last shown for THIS stored session, now
                // that `startSession` has built a fresh `BrowserSession` for
                // it. Reuses `descriptor` (already resolved above for
                // `stored.kind`) rather than re-deriving it.
                //
                // Three answers can exist at once, and which wins is
                // `WindowRestorationPlan.paneVisibility`'s to say (P3c/T2
                // for the first two, Detachable Tabs plan Task 5 for the
                // third): the caller's override — the sidebar's "Open
                // Terminal" — then the shape a RESTORED tab was described
                // with, then the value P2 saved on the session itself,
                // which is byte-for-byte what an ordinary Connect used to
                // get here. Resolved HERE rather than inside
                // `restorePaneVisibility`, which stays the "put a value
                // back" step and gains no opinion about where it came from.
                //
                // The restored description is cleared as it is used: it
                // describes the launch this tab came back from, not every
                // later connect the user makes on it.
                let restoredPanes = tab.restoredPaneVisibility
                tab.restoredPaneVisibility = nil
                restorePaneVisibility(
                    for: tab,
                    visibility: WindowRestorationPlan.paneVisibility(
                        override: paneVisibility, restored: restoredPanes,
                        stored: stored.paneVisibility),
                    descriptor: descriptor)
                // Audit recorder (M9b/T3): this IS the stored-session connect
                // path — attach right after `activeStoredSessionID`, once
                // `tab.session` (set inside `startSession`) exists.
                //
                // `form.jumpHost` (M-1 fix, final review), not
                // `stored.jump?.host`: for a session-mode jump the latter is
                // the snapshot taken at SAVE time, not the host actually
                // dialed just now -- if the bastion session moved since, the
                // audit entry would record a stale carrier host, defeating
                // reference semantics. `form.jumpHost` was just resolved
                // fresh above (`resolvedJump(for:)`/the manual fallback) and
                // is correct by construction; `jumpEnabled` gates it to `nil`
                // when there is no jump at all.
                // `displaySummary` (M22/T11), not `stored.host`/`stored.username`
                // directly — a legacy non-SSH session still carries the
                // `"unused"` placeholder in those two, which is what used to
                // leave "connected to unused as unused" in the audit trail.
                // Reuses the `descriptor` the fill above already resolved.
                attachAuditRecorder(
                    to: tab, sessionID: stored.id,
                    summary: descriptor.displaySummary(descriptor.sessionValues(stored)),
                    viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)
            } else if tab.reconnectAttempt == myAttempt, let reason = form.lastFailureReason {
                // The `connectFailed` audit row (session overview plan, Task
                // 2), and the ONE place this app writes one: this is the
                // stored-session connect path, the same one `retryConnect`
                // and the lost surface's Reconnect come back through, so a
                // second appender for those would be a second chance to get
                // the sentence wrong.
                //
                // Two conditions, and each rules out a different non-event:
                //
                // * `lastFailureReason != nil` means a dial actually reached
                //   the wire and threw. `form.connect()` also answers `nil`
                //   for a refusal decided before any of that — an empty save
                //   name, a login set that no longer resolves — and for an
                //   attempt Core itself superseded. Neither is a connect that
                //   failed, and a log full of them would say this session is
                //   unreliable when nothing was ever dialled. See
                //   `ConnectionViewModel.lastFailureReason`.
                // * `tab.reconnectAttempt == myAttempt` is the same
                //   hand-off guard the success path above uses: a Cancel that
                //   landed during the dial has already moved that token, and
                //   an attempt the user backed out of leaves no record.
                //
                // The sentence is Core's fixed one, never the error's own
                // text — `DialSupport.reason(for:)` is public for exactly
                // this, and its doc comment explains what an arbitrary
                // error's description can carry out of a URL-shaped
                // endpoint field. The recorder is built here rather than
                // taken from `tab.auditRecorder`: that one is attached on a
                // SUCCESSFUL connect and is nil (or another session's) at
                // this point.
                AuditRecorder(sessionID: stored.id, store: auditStore)
                    .recordConnectFailed(reason: reason)
            }
        }
    }


    /// The stored session a lost tab's "Reconnect" would redial, or `nil`
    /// (connection-liveness plan, Task 7).
    ///
    /// Resolved against the LIVE session list every time it is asked, not
    /// remembered: `SessionTab.lostConnection` keeps only the id, because a
    /// session can be edited — or deleted — while its tab sits on the lost
    /// surface. A deleted one turns "Reconnect" off (`LostConnectionPlan
    /// .content`'s `targetIsKnown`) and stops the unattended schedule
    /// (`ReconnectPlan.step`), instead of offering a button that dials
    /// something that is no longer there.
    ///
    /// `nil` for an ad-hoc connection too — one typed into the form and
    /// never saved has no `storedSessionID` at all, and `teardown(_:)` has
    /// already cleared the form's secrets by the time this surface appears,
    /// so there is nothing left to redial with.
    func reconnectTarget(for tab: SessionTab) -> StoredSession? {
        guard let id = tab.lostConnection?.storedSessionID else { return nil }
        return sessionListViewModel.sessions.first(where: { $0.id == id })
    }

    /// Rebuilds a lost connection (connection-liveness plan, Task 7) —
    /// from the surface's "Reconnect" button and from `ReconnectRunner`'s
    /// unattended schedule alike.
    ///
    /// One line of substance, and that is the point: this dials through
    /// `connect(in:stored:)`, the SAME function a sidebar connect goes
    /// through, so TOFU stays the hard stop it is, the keychain rules are
    /// the ones `fillForm(_:from:)` already applies, the plaintext
    /// confirmation still gets asked, and the attempt token/`isReconnecting`
    /// lock still guard the hand-off. The design spec calls this out as the
    /// load-bearing decision of its recovery section: a second dial here
    /// would be a second place a security rule could be forgotten.
    /// `ReconnectWiringGuardTests` pins it by scanning this function's own
    /// comment-stripped source, and `ReconnectPathTests` drives the real
    /// call end to end.
    func reconnect(_ tab: SessionTab) {
        guard let stored = reconnectTarget(for: tab) else { return }
        connect(in: tab, stored: stored)
    }

    /// Leaves the lost surface for the ordinary connection form
    /// (connection-liveness plan, Task 7).
    ///
    /// Clears BOTH facts: `liveness` is what `ConnectionSurfacePlan` reads
    /// to pick the surface, `lostConnection` is what would otherwise send
    /// the next failed attempt straight back to it
    /// (`ConnectAttemptLivenessPlan.write`) and keep an unattended schedule
    /// alive behind a form the user is typing into.
    func dismissLostConnection(_ tab: SessionTab) {
        tab.lostConnection = nil
        tab.liveness = nil
    }

    /// The stored session this tab's FAILED ATTEMPT dialed, if it is still
    /// in the list (failed-connect surface plan, Task 3).
    ///
    /// Resolved live rather than remembered, exactly as
    /// `reconnectTarget(for:)` is and for the same reason: `ConnectFailure`
    /// keeps only an id, and a session can be deleted — from another window
    /// — while its tab sits on this surface. A deleted one turns "Edit
    /// session" off and turns Retry into the ad-hoc case, instead of
    /// offering two controls that cannot work.
    func failedConnectTarget(for tab: SessionTab) -> StoredSession? {
        guard let id = tab.connectFailure?.storedSessionID else { return nil }
        return sessionListViewModel.sessions.first(where: { $0.id == id })
    }

    /// The failed-connect surface's "Try again" (failed-connect surface
    /// plan, Task 3).
    ///
    /// One line of substance, and — as with `reconnect(_:)` above — that is
    /// the point: it dials through `connect(in:stored:)`, the SAME function
    /// a sidebar connect goes through, so TOFU stays the hard stop it is, the
    /// keychain and login-set rules are the ones `fillForm(_:from:)`
    /// applies, the plaintext confirmation still gets asked, and the
    /// attempt token and `isReconnecting` lock still guard the hand-off. A
    /// dial written out here instead would be a second place every one of
    /// those could be forgotten, which is the property
    /// `ReconnectWiringGuardTests` exists to hold.
    ///
    /// The guard is the same shape as `reconnect(_:)`'s and means the same
    /// thing: nothing to dial, so nothing happens. It is not reachable from
    /// the surface — `ConnectFailurePlan` omits the button entirely without
    /// a stored session (round 2, after review; round 1 offered it and made
    /// it return the user to the form, which is a button that does the
    /// opposite of its name). It stays because a target can be deleted from
    /// another window between the render and the click.
    func retryConnect(_ tab: SessionTab) {
        guard let stored = failedConnectTarget(for: tab) else { return }
        connect(in: tab, stored: stored)
    }

    /// Leaves the failed-connect surface for the ordinary connection form
    /// (failed-connect surface plan, Task 3) — the surface's own "Edit",
    /// and the way every sidebar command that fills the form gets past it.
    ///
    /// Clears only `connectFailure`: that is the single fact
    /// `ConnectionSurfacePlan` reads for this surface, `liveness` is
    /// already `nil` for a tab showing it, and the FORM is deliberately
    /// left exactly as the failed attempt filled it — "Edit" means "change
    /// something and try again", and blanking the fields it is named for
    /// would be the opposite.
    func dismissConnectFailure(_ tab: SessionTab) {
        tab.connectFailure = nil
    }

    /// The failed-connect surface's "Edit session" (failed-connect surface
    /// plan, Task 3): the durable change, as opposed to "Edit"'s one-off.
    ///
    /// Goes through `editStored(_:)`, the same function the sidebar's own
    /// "Edit…" entry uses, so the editor is opened one way. The surface is
    /// only ever rendered for the ACTIVE tab (`ContentView.detail` renders
    /// that one tab's content), which is the tab `editStored`'s own target
    /// rule then picks — and it picks it because a tab showing this surface
    /// is unconnected by construction.
    ///
    /// Deliberately no `dismissConnectFailure(_:)` of its own (round 2,
    /// after review): `editStored` resolves its target through
    /// `formTarget()`, which returns `nil` while a dial is in flight and
    /// then opens nothing — so clearing the surface here first would leave
    /// the tab on the form with no editor and no explanation. `formTarget()`
    /// already clears both surfaces on the path where it DOES hand a tab
    /// back, which is the one path that needs it.
    func editFailedSession(_ tab: SessionTab) {
        guard let stored = failedConnectTarget(for: tab) else { return }
        editStored(stored)
    }

    /// Fills `form` from a stored session — the ONE fill both callers of a
    /// stored session's data share (P3c/T2): the connect below, and the
    /// sidebar's "Open in External Terminal" entry, which resolves the very
    /// same form and hands the result to a launcher instead of dialling it.
    /// Writing these steps a second time for the second caller is the defect
    /// this milestone exists to avoid; `ConnectionViewModel
    /// .resolveConfigWithoutDialing()` is its Core-side half.
    ///
    /// Returns `false` when it refused, having published the reason on
    /// `form` (`showFailure`) exactly as this code did when it was inline —
    /// so the caller that HAS this form on screen needs to do nothing, and
    /// the caller that does not can read the message back off `form.state`
    /// and put it somewhere the user can see. The `field:` each refusal
    /// carries is meaningful only to the on-screen form; nothing is lost by
    /// the other caller ignoring it.
    ///
    /// Every branch here is the code that used to live inline in
    /// `connect(in:stored:paneVisibility:)`, moved unchanged — the comments
    /// below still describe their own decisions and their own review
    /// history.
    ///
    /// `throws` because it always could: the resolution calls inside catch
    /// `LoginResolveError` and nothing else, and anything else they raise
    /// (a keychain read, say) travelled straight out of the enclosing `Task`
    /// when this code was inline. Declaring it keeps that shape visible
    /// instead of turning it into a `try?` that would swallow the difference
    /// between "refused for a reason" and "something went wrong".
    func fillForm(_ form: ConnectionViewModel, from stored: StoredSession) throws -> Bool {
        // ONE fill for every protocol (M23/T7). `kind` FIRST (M22/T8):
        // assigning it resets `values` to that backend's defaults, so a
        // fill that ran before it would be wiped by the protocol switch;
        // the explicit reset below is what covers the case where `kind`
        // does NOT change (two SSH sessions in a row) and its guarded
        // `didSet` therefore does nothing.
        //
        // `sessionValues` replaces the three per-protocol field lists --
        // and never copies `host`/`username` for an S3 or WebDAV session,
        // which is where the `"unused"` placeholder used to enter the form.
        form.kind = stored.kind
        let descriptor = BackendDescriptor.descriptor(for: stored.kind)
        // `editBaseline`, NOT `defaultValues`: this form IS `stored` -- a
        // saved session, not a new one -- so it must not inherit S3's
        // new-form region assumption (`BackendDescriptor.editBaseline`'s
        // doc comment). A session whose S3 block is missing shows EMPTY S3
        // fields and fails `firstViolation` at the first required field in
        // declaration order -- today that is the endpoint, not the region
        // -- the same as `ConnectionViewModel.beginEditing`.
        form.values = descriptor.editBaseline
        form.values.merge(descriptor.sessionValues(stored))
        // NOT a name macSCP invents, so deliberately no
        // `SessionNameCollision.freeName` here (unlike `fillFromImported`
        // and `saveAsSession`): this form IS `stored`, and stepping aside
        // would show the user a renamed copy of the session they opened.
        form.saveName = stored.name
        form.tags = stored.tags
        form.shouldSaveSession = false

        // Resolve what this session should actually connect with (M10b/T3):
        // its own data for a manual session, or its set's credentials --
        // a dangling `loginSetID` throws rather than silently falling
        // back (`LoginResolver`'s doc comment). Identical for all three
        // backends since M22/T9; only the SECRET field differed, which
        // `fillSecret` now names for whichever backend is active (the S3
        // branch filled `s3SecretAccessKey`, the other two `password`).
        do {
            if let resolved = try sessionListViewModel.resolvedCredentials(for: stored) {
                form.applyResolvedCredentials(resolved)
            } else if descriptor.requiresSecret(form.values) {
                // M-6: an agent login reads no keychain at all -- avoid
                // the residual lookup on this path too. `requiresSecret`
                // is false for exactly that case and true for S3/WebDAV,
                // which is what the `authKind != .agent` guard meant.
                form.fillSecret(sessionListViewModel.password(for: stored) ?? "")
            }
            // M17: if this key is a managed key with a stored
            // passphrase and none was typed, resolve it from the
            // Keychain so the user need not re-enter it. Inert outside
            // SSH: no other backend has a private-key auth choice.
            //
            // `managedKeyStore`/`secretStore` (connection-liveness plan,
            // Task 6 fix round 4, review-mandated): this call site builds
            // its own `ManagedKeyStore(directory: SessionStore
            // .defaultDirectory)`/`KeychainSecretStore()` inline until this
            // fix, unseamed and reachable through `connect(in:stored:)` —
            // the SAME call path `ConnectAttemptHandoffTests`' own stored-
            // session scenario drives — for any stored session using
            // private-key auth. Routed through the same two properties
            // `maybeCreateNewLoginSet(from:editedSession:)` and
            // `startSession`'s own `shouldSaveSession` branch already use.
            if form.authChoice == .privateKey {
                form.password = ManagedKeyPassphrase.resolve(
                    keyPath: form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                    typed: form.password,
                    store: managedKeyStore,
                    secrets: secretStore)
            }
            form.loginMode = stored.loginSetID != nil ? .set : .manual
            form.selectedLoginSetID = stored.loginSetID
        } catch is LoginResolveError {
            // Missing set (target, M10c/T3): do NOT connect -- show the
            // form instead, with the mismatch surfaced through its
            // existing error field (spec §2/§6). The user picks a login
            // or enters credentials. Falls back to the session's own raw
            // values so the form isn't left half-filled: the same
            // `editBaseline` + `sessionValues` merge as above, which leaves
            // every secret field blank because `editBaseline` does -- and,
            // for S3, leaves a missing region blank rather than guessed, for
            // the same reason the merge above uses `editBaseline` and not
            // `defaultValues`.
            //
            // Kept in its OWN do/catch, independent of the jump's below
            // (final review M-1): sharing one catch meant a JUMP-only
            // `.missingSet` also reset this (valid) target resolution --
            // a dangling jump set discarded a perfectly good target
            // login pick.
            form.values = descriptor.editBaseline
            form.values.merge(descriptor.sessionValues(stored))
            form.loginMode = .manual
            form.selectedLoginSetID = nil
            // A stale jump block from a DIFFERENT session's form must not
            // survive this early return (F-1 fix): the jump `do`/`catch`
            // below is never reached on this path, so apply the same
            // raw-jump fallback it would have applied. The S3 and WebDAV
            // branches this replaces returned WITHOUT it and so leaked a
            // stale jump into the form on a dangling-set stop.
            applyRawJumpFallback(form, from: stored)
            form.showFailure(message: L10n.string(
                "loginSets.missingSet",
                "The stored login for this connection was not found. Choose a login or enter credentials."))
            return false
        }

        // Jump (M10c/T3, extended M11a/T3): same resolution as above,
        // for the jump's OWN login — `resolvedJumpLogin` is `nil` only
        // when the session has no jump at all; a resolved jump fills
        // the manual-looking fields regardless of whether it came from
        // a set or the jump's own manual secret, exactly like the
        // target's resolution above. In its OWN do/catch (final review
        // M-1, see comment above): a jump-only failure must fall back on
        // the JUMP side only, leaving the target fields resolved above
        // untouched.
        //
        // Session mode (`jump.sessionID` non-nil, spec §4b) branches
        // FIRST: host/port and the login all come from the REFERENCED
        // session via `resolvedJump(for:)`, unlike the manual/set branch
        // below which only ever resolves the jump's OWN fields via
        // `resolvedJumpLogin`. Each branch keeps its OWN nested do/catch
        // (rather than one shared catch for both) so a session-mode
        // failure highlights `.jumpSession` — the only field the
        // session-mode UI actually renders — while a manual/set failure
        // keeps highlighting `.jumpHost` exactly as before this feature.
        if let jump = stored.jump {
            form.jumpEnabled = true
            if let sessionID = jump.sessionID {
                // Set BEFORE the throwing call below: on a failure the
                // form stays in session mode with this selection intact,
                // so the picker and the `.jumpSession` highlight the
                // failure attaches to are both visible — switching back
                // to manual with raw fallback values would hide the very
                // field the error is about.
                form.jumpSourceMode = .session
                form.jumpSessionID = sessionID
                do {
                    if let resolved = try sessionListViewModel.resolvedJump(for: stored) {
                        form.jumpHost = resolved.host
                        form.jumpPort = String(resolved.port)
                        form.jumpUsername = resolved.login.username
                        form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolved.login.authKind)
                        form.jumpKeyPath = resolved.login.keyPath ?? ""
                        form.jumpPassword = resolved.login.secret ?? ""
                    }
                } catch LoginResolveError.missingJumpSession {
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.session.missing",
                            "The connection used as jump host no longer exists."),
                        field: .jumpSession)
                    return false
                } catch LoginResolveError.jumpChainNotSupported {
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.session.chainNotSupported",
                            "The selected jump host connects through another jump host; "
                                + "chains are not supported."),
                        field: .jumpSession)
                    return false
                } catch LoginResolveError.jumpSessionNotSSH {
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.session.notSSH",
                            "Only SSH connections can be used as a jump host."),
                        field: .jumpSession)
                    return false
                } catch is LoginResolveError {
                    // The REFERENCED session's own login set is dangling
                    // (`.missingSet`) -- same wording the login-set
                    // dangling-reference paths already use elsewhere.
                    form.showFailure(
                        message: L10n.string(
                            "loginSets.missingSet",
                            "The stored login for this connection was not found. "
                                + "Choose a login or enter credentials."),
                        field: .jumpSession)
                    return false
                }
            } else {
                form.jumpSourceMode = .manual
                form.jumpSessionID = nil
                form.jumpHost = jump.host
                form.jumpPort = String(jump.port)
                form.jumpLoginMode = jump.loginSetID != nil ? .set : .manual
                form.jumpSelectedLoginSetID = jump.loginSetID
                do {
                    if let resolvedJump = try sessionListViewModel.resolvedJumpLogin(for: stored) {
                        form.jumpUsername = resolvedJump.username
                        form.jumpAuthChoice = ConnectionViewModel.authChoice(for: resolvedJump.authKind)
                        form.jumpKeyPath = resolvedJump.keyPath ?? ""
                        form.jumpPassword = resolvedJump.secret ?? ""
                    }
                } catch LoginResolveError.jumpSetNotSSH {
                    // The jump is bound to a login set of another
                    // protocol (M28/T7). This is the only catch site the
                    // case can reach, because it is the only one that
                    // resolves a jump spec whose `sessionID` is nil: the
                    // three others —
                    // `SessionListViewModel.resolveJumpSession`,
                    // `ConnectionFormView.jumpSessionSummary` and the
                    // session-mode branch just above — all build or pass
                    // a spec carrying a `sessionID`, and
                    // `LoginResolver.resolveJump(...sessions:...)` only
                    // delegates to the throwing overload when that is
                    // nil; with a `sessionID` it resolves the REFERENCED
                    // session's own login instead, where a set of the
                    // wrong kind is `.kindMismatch`. (The remaining catch
                    // above is the TARGET's resolution, not a jump's.)
                    //
                    // Only the CATCH sites are enumerated above, not the
                    // call sites: `SessionListViewModel.exportPayload`
                    // calls the same overload with a possibly-nil
                    // `sessionID` too, but swallows the throw with `try?`
                    // and falls back to the spec's raw values, so the
                    // export writes no jump password and counts the jump
                    // under its missing-password tally instead of
                    // surfacing a refusal.
                    //
                    // The raw fallback is what keeps the refusal
                    // meaningful on THIS path: it clears
                    // `jumpSelectedLoginSetID` and returns the block to
                    // Manual, so a following submit does not walk
                    // `SessionListViewModel.resolveJumpLoginSet` into
                    // `fillJumpForm` and copy the very credentials this
                    // refusal is about into the form. It also blanks
                    // `jumpPassword` — the set's secret was never read.
                    // Editing such a session
                    // (`ConnectionViewModel.beginEditing`) reaches the
                    // same submit with no resolution and no fallback at
                    // all; the `kind` guard inside
                    // `SessionListViewModel.resolveJumpLoginSet` is what
                    // covers that route.
                    applyRawJumpFallback(form, from: stored)
                    form.showFailure(
                        message: L10n.string(
                            "form.jump.set.notSSH",
                            "The jump host uses a stored login that is not an SSH login. "
                                + "Choose an SSH login for the jump host, or enter its "
                                + "user name and password here."),
                        field: .jumpHost)
                    return false
                } catch is LoginResolveError {
                    // Missing set (jump only): the target fields resolved
                    // above stay untouched — only the jump falls back to
                    // its raw manual-looking values, and `field:
                    // .jumpHost` (not the target's `.host`) highlights
                    // the right row. Shares the fallback with the target
                    // catch above (F-1 fix) so both early-return paths
                    // leave the jump block in the identical,
                    // fully-reset-or-fully-raw state.
                    applyRawJumpFallback(form, from: stored)
                    form.showFailure(
                        message: L10n.string(
                            "loginSets.missingSet",
                            "The stored login for this connection was not found. "
                                + "Choose a login or enter credentials."),
                        field: .jumpHost)
                    return false
                }
            }
        } else {
            form.clearJumpFields()
        }
        return true
    }

    /// Fills the jump block from the session's own raw JumpSpec values (no set
    /// resolution), or clears it entirely when the session has no jump. Used by
    /// three of `fillForm`'s seven early-return failure paths — the target's
    /// dangling-set stop and the two jump-LOGIN-set failures — so a stale
    /// jump block from a previous form state can never survive into a
    /// different session's connect. The four jump-SESSION failures skip it
    /// on purpose: they leave the form in session mode so the user can see
    /// which reference broke.
    ///
    /// `jumpSourceMode`/`jumpSessionID` are also reset here (F-2 fix, final
    /// review): the `if let jump` branch below fills only the manual-looking
    /// fields, so without this a stale `jumpSourceMode == .session` +
    /// `jumpSessionID` from a DIFFERENT, still-open form (e.g. an unconnected
    /// tab left in session mode with bastion X preselected) would survive
    /// into THIS session's (B's) connect: the picker would show X preselected
    /// while the manual fields hold B's raw jump values, and a subsequent
    /// Connect would silently route through X instead of B's own jump host.
    /// The `else` branch already resets both via `clearJumpFields()`.
    private func applyRawJumpFallback(_ form: ConnectionViewModel, from stored: StoredSession) {
        if let jump = stored.jump {
            form.jumpEnabled = true
            form.jumpSourceMode = .manual
            form.jumpSessionID = nil
            form.jumpHost = jump.host
            form.jumpPort = String(jump.port)
            form.jumpUsername = jump.username
            form.jumpAuthChoice = ConnectionViewModel.authChoice(for: jump.authKind)
            form.jumpKeyPath = jump.keyPath ?? ""
            form.jumpPassword = ""
            form.jumpLoginMode = .manual
            form.jumpSelectedLoginSetID = nil
        } else {
            form.clearJumpFields()
        }
    }

    /// Sidebar "Edit…" click: prefill the form for in-place editing — in the
    /// active tab when it is unconnected, otherwise in a fresh tab (a running
    /// session is never displaced). Deliberately no auto-connect: the user
    /// reviews/changes fields, then picks Save or Save & connect.
    func editStored(_ stored: StoredSession) {
        guard let tab = formTarget() else { return }
        tab.connectionViewModel.beginEditing(stored)
    }

    /// Import click: fill the form from the ssh-config entry — deliberately
    /// WITHOUT connecting (the import knows no secrets). Same target rule as
    /// "Edit…".
    func fillFromImported(_ host: SSHConfigHost) {
        guard let tab = formTarget() else { return }
        // Same statement "New connection" makes (session overview plan, Task
        // 2): this fills the FORM, so the detail pane stops being about a
        // stored session. The sidebar's imported row clears its own selection
        // as well; this covers the call arriving from anywhere else.
        overviewSessionID = nil
        let form = tab.connectionViewModel
        form.exitEditMode()
        form.clearPassword()
        form.host = host.hostName ?? host.alias
        form.port = String(host.port ?? 22)
        form.username = host.user ?? ""
        // The other INVENTED name, same rule as "Save as Session": the alias
        // comes out of `~/.ssh/config`, not out of the user's fingers, so it
        // steps aside from a stored session of that name rather than
        // replacing it on save. A form filled FROM a stored session is
        // where a matching name is the normal case instead — that is
        // `fillForm` and `ConnectionViewModel.beginEditing`, and both fill
        // this field straight from `stored.name`.
        form.saveName = SessionNameCollision.freeName(
            basedOn: host.alias, avoiding: sessionListViewModel.sessions)
        form.shouldSaveSession = false
        if let identityFile = host.identityFile {
            form.authChoice = .privateKey
            form.keyPath = identityFile
        } else {
            form.authChoice = .password
            form.keyPath = ""
        }
    }

    /// Recomputes `importedHosts` (the sidebar's VISIBLE list) and
    /// `hiddenImportAliases` from `fullImportedHosts` and a fresh
    /// `HiddenImportStore` read (M11f/T2). Called once at startup (right
    /// after `fullImportedHosts` is populated in `.task`) and again after
    /// every hide/unhide — deliberately WITHOUT re-parsing
    /// `~/.ssh/config`, since hiding/unhiding never changes what is
    /// actually in that file. A store read failure (rare: e.g. a corrupt
    /// `hidden-imports.json`) reports `hiddenImportsErrorMessage` rather than
    /// failing silently (M11f/T2 review, finding 2) — a corrupted store would
    /// otherwise resurface every hidden host AND drop the Sessions-menu count
    /// with no indication anything went wrong. Success clears the message,
    /// matching `SessionSidebar.jumpRestoreErrorMessage`'s established pattern.
    ///
    /// On a read failure the visible list falls back to the FULL set rather
    /// than to whatever it held before (M11f/T2 re-review): hiding is a
    /// cosmetic display filter, so it must never subtract from a host list
    /// that WAS read successfully on the strength of preference data that
    /// was not. Keeping the previous list would strand the user at startup,
    /// where `importedHosts` is still empty when this first runs — the whole
    /// IMPORTED section would vanish on every launch, and the sheet (which
    /// re-reads the same broken file) offers no way back. `hiddenImportAliases`
    /// is deliberately left alone: a stale count keeps the menu entry
    /// discoverable, which is where the user goes to investigate.
    func refreshImportedHosts() {
        do {
            let aliases = try HiddenImportStore(directory: SessionStore.defaultDirectory).allHidden()
            hiddenImportAliases = aliases
            importedHosts = ImportedHostPartition.split(hosts: fullImportedHosts, hiddenAliases: aliases).visible
            hiddenImportsErrorMessage = nil
        } catch {
            importedHosts = fullImportedHosts
            hiddenImportsErrorMessage = String(
                format: L10n.string(
                    "sidebar.hiddenImports.error %1$@ %2$@",
                    "Could not update hidden imports: %1$@ — you can delete %2$@ to reset the list."),
                String(describing: error),
                HiddenImportStore(directory: SessionStore.defaultDirectory).fileURL.path(percentEncoded: false))
        }
    }

    /// Sidebar imported-row context menu "Hide" (M11f/T2, spec: no
    /// confirmation dialog — this reports FAILURE only, never a success
    /// confirmation). A rare disk-write failure previously just left the
    /// row visible for another try with zero feedback (M11f/T2 review,
    /// finding 1); now it is captured separately, `refreshImportedHosts()`
    /// still runs unconditionally (the read usually still works even when
    /// the write just failed), and the write error is re-applied AFTER —
    /// same "capture separately, reload, reapply after" pattern as
    /// `HiddenImportsSheet.unhide`, so a successful `refreshImportedHosts()`
    /// read can't silently swallow this call's own write failure.
    func hideImported(_ host: SSHConfigHost) {
        var hideError: String?
        do {
            try HiddenImportStore(directory: SessionStore.defaultDirectory).hide(host.alias)
        } catch {
            hideError = String(
                format: L10n.string(
                    "sidebar.hiddenImports.error %1$@ %2$@",
                    "Could not update hidden imports: %1$@ — you can delete %2$@ to reset the list."),
                String(describing: error),
                HiddenImportStore(directory: SessionStore.defaultDirectory).fileURL.path(percentEncoded: false))
        }
        refreshImportedHosts()
        if let hideError {
            hiddenImportsErrorMessage = hideError
        }
    }

    /// Sidebar `hiddenImportsErrorBanner`'s close button and its own
    /// six-second auto-dismiss (dev-build follow-up, 2026-09-03) — the
    /// third red caption, left open by `ece5aaf9`, which gave the other two
    /// (`viewModel.errorMessage` via `SessionListViewModel.dismissError()`,
    /// and the sidebar's own local `jumpRestoreErrorMessage`) this same
    /// treatment. `hiddenImportsErrorMessage` reaches `SessionSidebar` as a
    /// plain `let`, so the clear has to happen here, on the property that
    /// actually owns it — the same one `refreshImportedHosts()`'s success
    /// path already sets to `nil`. Does not touch anything else a later
    /// `hideImported`/`refreshImportedHosts` call sets; a later failure
    /// still shows again, because nothing here latches the channel shut.
    func dismissHiddenImportsError() {
        hiddenImportsErrorMessage = nil
    }

    /// Sidebar "New connection": blank the active tab's form when it is
    /// unconnected (M6a — without this, host/username/name from a previous
    /// edit stay prefilled), otherwise open a fresh empty tab. The toolbar
    /// "Disconnect" deliberately keeps the fields (reconnect convenience) —
    /// only this path blanks them.
    func newConnection() {
        let tab = activeTab
        if tab.isConnected {
            addTabRegistering(makeTab())
            return
        }
        guard !tab.isReconnecting else { return }
        // A tab sitting on the lost-connection surface is "unconnected" by
        // `isConnected`, so this path reuses it — but the surface, not the
        // form, is what `ConnectionSurfacePlan` puts on screen for it
        // (connection-liveness plan, Task 7). Without this the fields would
        // be blanked behind an error view and the command would look like
        // it did nothing.
        dismissLostConnection(tab)
        // Same argument for the failed-connect surface (failed-connect
        // surface plan, Task 3): a tab showing it is "unconnected" too, so
        // without this the blanked fields would sit behind an error view
        // and the command would look like it did nothing.
        dismissConnectFailure(tab)
        tab.connectionViewModel.endEditing()
        // The user asked for an empty form (session overview plan, Task 2).
        // Verified 2026-09-04 (final fix round, item 4): this function has
        // exactly one caller, `ContentView+Detail.swift:77`'s `onNew:`,
        // reached only from `SessionSidebar.startNewConnection()` — which
        // already clears the sidebar's own selection via
        // `onSelectSession(nil)` immediately before calling this. ⌘N is
        // bound to "New Tab" (`MacSCPApp.swift`, `tabCommands.newTab`), a
        // different function entirely, and no Sessions-menu entry reaches
        // this one either. The clear stays here anyway: this function does
        // not lean on its one caller having already arranged it, so "asking
        // for a new connection blanks the overview" stays true on its own
        // rather than on trust that every future caller repeats the
        // sidebar's own clearing step.
        overviewSessionID = nil
    }

    /// Target tab for the form-filling actions ("Edit…", ssh-config import,
    /// and the tab menu's "Save as Session…", which lives in
    /// `ContentView+Lifecycle.swift` and is why this is no longer
    /// `private`): the active tab if it is unconnected and idle, otherwise a
    /// new tab. `nil` while the active tab is mid-connect (the click is
    /// ignored, as it is today).
    func formTarget() -> SessionTab? {
        let tab = activeTab
        if tab.isConnected {
            let fresh = makeTab()
            addTabRegistering(fresh)
            return fresh
        }
        guard !tab.isReconnecting else { return nil }
        // Same reason as `newConnection()` above (connection-liveness plan,
        // Task 7): every caller of this fills the FORM, which a tab still
        // showing the lost-connection surface would not be displaying.
        dismissLostConnection(tab)
        // And past the failed-connect surface (failed-connect surface plan,
        // Task 3), for the identical reason.
        dismissConnectFailure(tab)
        return tab
    }

    /// Toolbar "Disconnect": tears this tab's session down and returns it to
    /// the form. The tab's queue survives — interrupted transfers stay
    /// resumable after a reconnect, exactly as before.
    func disconnectToForm(_ tab: SessionTab) {
        guard !tab.isReconnecting else { return }
        tab.isReconnecting = true // synchronous — prevents double teardown (would corrupt lastBrowserSize)
        Task {
            defer { tab.isReconnecting = false }
            await teardown(tab, reason: .userRequested)
            shrinkIfPristine()
        }
    }

    /// Sets the localized "not available for this connection type" message
    /// (M12/T7b) — the shared fallback for every shell-only command path
    /// (toolbar button, ⌘T, both "Terminal" menu entries) that reaches its
    /// action despite already being disabled for the active tab's backend.
    ///
    /// The argument is `nil` at every caller but one: the four shortcut
    /// refusals all mean the same thing and say the standard sentence. The
    /// exception is `deliverPendingSnippetRun(on:)`, whose shell did not
    /// come up — "isn't available for this connection type" would be the
    /// wrong sentence there, and a second alert for one more sentence would
    /// be a second surface saying the same kind of thing.
    func presentTerminalUnavailable(_ message: String? = nil) {
        terminalUnavailableAlertMessage = message ?? L10n.string(
            "shortcut.unavailableForProtocol",
            "This shortcut isn't available for this connection type.")
    }

    // MARK: - External terminal (M11d/T2)

    /// Entry point for both routes to an external terminal (the toolbar
    /// button when `terminalTarget != .builtIn`, and the "Terminal" menu's
    /// "Open in External Terminal" entry, which ignores the setting
    /// entirely). Shows the password hint first when it applies (spec §4
    /// item 6); otherwise opens immediately.
    func requestExternalTerminal(for tab: SessionTab) {
        // No session, or somehow no resolved config for one (never happens
        // in practice — a connected tab always has one, set by
        // `ConnectionViewModel.connect()` on success): nothing to open.
        guard tab.isConnected, let config = tab.connectionViewModel.lastConnectedConfig else { return }
        requestExternalTerminal(config: config)
    }

    /// Sidebar row "Open in External Terminal" (P3c/T2): resolves what this
    /// session WOULD connect with and hands it to the external terminal.
    /// macSCP itself does not connect, opens no tab, and touches no other
    /// tab's form.
    ///
    /// The form is a throwaway, built here and gone when this method
    /// returns. Two reasons it is not a tab's form: filling a visible form
    /// would overwrite whatever the user has typed into the unconnected tab
    /// on screen, and — the reason that matters more — the resolved config
    /// carries a plaintext secret, so the object holding it must not outlive
    /// the call. The two places that DO hold a config past their call keep no
    /// secret in it: `lastConnectedConfig` and the password hint's request
    /// both store `redactingSecrets()`. This route creates no third one.
    /// Its connector throws rather than dialling: the one path that could
    /// turn this into a connection is closed structurally, not by
    /// convention. Nothing here calls it.
    ///
    /// Both refusals — the fill's (a dangling login set, a jump that no
    /// longer resolves) and the resolution's (a missing secret, a jump the
    /// config rejects) — are shown, in the same alert an
    /// `ExternalTerminalLauncher.LaunchError` uses. They have to be shown
    /// HERE: `resolveConfigWithoutDialing` publishes nothing by design
    /// (P3c/T1), and the throwaway form the fill publishes onto is on no
    /// screen, so an ignored failure would be a silent no-op.
    func openExternalTerminalFromSidebar(_ stored: StoredSession) {
        let form = ConnectionViewModel(connector: { _, _ in
            throw RemoteFSError.connectionFailed(
                reason: "the external-terminal route resolves a configuration and never dials it")
        })
        do {
            guard try fillForm(form, from: stored) else {
                presentExternalTerminalFailure(form.state)
                return
            }
        } catch {
            // Not a refusal but a failure (see `fillForm`'s `throws`). The
            // connect path lets this escape its `Task` and shows nothing;
            // here there is a place to put it, so it goes there — same
            // `localizedDescription` fallback `performExternalOpen` uses for
            // an error it has no specific wording for.
            externalTerminalErrorMessage = error.localizedDescription
            return
        }
        switch form.resolveConfigWithoutDialing() {
        case .failed(let failure):
            presentExternalTerminalFailure(failure)
        case .resolved(let config):
            // Defensive: the entry is hidden for every backend without a
            // shell (`SessionRowTerminalMenuPlan`), and SSH is the only one
            // that has one, so a non-SSH config cannot arrive here.
            guard case .ssh(let ssh) = config else { return }
            requestExternalTerminal(config: ssh)
        }
    }

    /// Puts a `ConnectionViewModel.State` that refused into the external
    /// terminal's own error alert (P3c/T2) — the same surface a launch
    /// failure uses, so the sidebar route has no failure display of its own.
    ///
    /// The `field:` such a state carries is dropped on purpose: it names a
    /// row of a connection form, and this route has none on screen. Only the
    /// message is shown, and a message never contains a secret (Core builds
    /// them from `CoreL10n` keys). A state that is not `.failed` cannot
    /// reach here, and would show nothing if it did.
    private func presentExternalTerminalFailure(_ state: ConnectionViewModel.State) {
        guard case .failed(let message, _) = state else { return }
        externalTerminalErrorMessage = message
    }

    /// The shared body of both external-terminal routes (P3c/T2): picks the
    /// app to launch and shows the password hint before the first launch of
    /// a password login, or opens straight away.
    ///
    /// Split out of `requestExternalTerminal(for:)` rather than duplicated,
    /// so the sidebar route cannot bypass that hint — the point of the hint
    /// is that an external terminal gets NO saved password and `ssh` will
    /// prompt for it there, which is as true for a session macSCP never
    /// connected to as for one it did.
    func requestExternalTerminal(config: SSHConnectionConfig) {
        // The menu route ignores `terminalTarget` (it always means
        // "external"); the toolbar route already checked it before calling
        // here, but `.builtIn` still needs a concrete target to launch.
        // Review finding (M11d fix round 1): honour a validly configured
        // custom app here instead of always substituting Terminal.app —
        // a user who set a custom app but left the main setting on
        // "Built-in" would otherwise silently get Apple Terminal. Only fall
        // back to Terminal.app when no usable custom app is configured.
        let customPath = settingsStore.customTerminalAppPath
        let target: TerminalTarget
        if settingsStore.terminalTarget == .builtIn {
            target = ExternalTerminalLauncher.isValidCustomApp(atPath: customPath) ? .custom : .terminalApp
        } else {
            target = settingsStore.terminalTarget
        }

        // Redacted once, up front, and used on BOTH branches below: neither
        // reads a secret (`ExternalTerminalLauncher.open` only ever hands
        // `config` to `SSHCommandBuilder`, which reads host/port/username/key
        // *path*/jump — never a password or passphrase, `ssh` prompts for it
        // itself), so there is no reason for only the hint branch to redact.
        // The `if case .password` gate below still works after redaction:
        // `redactingSecrets()` keeps the auth CASE, only emptying the
        // payload.
        let redacted = config.redactingSecrets()

        if case .password = redacted.auth, !settingsStore.externalTerminalPasswordHintShown {
            pendingPasswordHintRequest = ExternalTerminalRequest(
                config: redacted, target: target, customPath: customPath)
            return
        }
        Task {
            await performExternalOpen(config: redacted, target: target, customPath: customPath)
        }
    }

    /// Writes and launches the disposable script via `ExternalTerminalLauncher`;
    /// any `LaunchError` becomes a concrete alert message (spec §4 item 7) —
    /// never a silent failure or a fallback to a different app. `async`
    /// because `ExternalTerminalLauncher.open` now awaits `NSWorkspace`'s
    /// own launch completion (review finding I-2) instead of firing it with
    /// `completionHandler: nil`; callers wrap this in `Task { }`.
    private func performExternalOpen(config: SSHConnectionConfig, target: TerminalTarget, customPath: String?) async {
        do {
            try await ExternalTerminalLauncher.open(config: config, target: target, customPath: customPath)
        } catch ExternalTerminalLauncher.LaunchError.applicationNotFound(let name) {
            externalTerminalErrorMessage = String(
                format: L10n.string("externalTerminal.error.applicationNotFound %@", "Couldn't find \u{201C}%@\u{201D}."),
                name)
        } catch ExternalTerminalLauncher.LaunchError.noCustomAppChosen {
            externalTerminalErrorMessage = L10n.string(
                "externalTerminal.error.noCustomAppChosen", "No app has been chosen yet.")
        } catch ExternalTerminalLauncher.LaunchError.scriptWriteFailed(let reason) {
            externalTerminalErrorMessage = String(
                format: L10n.string(
                    "externalTerminal.error.scriptWriteFailed %@", "Couldn't write the launch script: %@"),
                reason)
        } catch ExternalTerminalLauncher.LaunchError.launchFailed(let reason) {
            externalTerminalErrorMessage = String(
                format: L10n.string("externalTerminal.error.launchFailed %@", "Couldn't launch the app: %@"),
                reason)
        } catch {
            externalTerminalErrorMessage = error.localizedDescription
        }
    }
}
