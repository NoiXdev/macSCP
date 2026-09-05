import SwiftUI
import macSCPCore

/// The per-window menu bridge, published as a focused scene value.
///
/// `TabCommands` is created by each `ContentView` and handed to SwiftUI
/// with `.focusedSceneValue(\.tabCommands, …)`; `MacSCPCommands` below
/// reads it back with `@FocusedValue`. That is the whole reason this key
/// exists, and it replaced something worse (Detachable Tabs plan, Task 2
/// fix round 1): one app-wide `TabCommands` that every window overwrote,
/// with each closure carrying a `window?.isKeyWindow` guard to work out
/// afterwards whether it should act. Two windows made that unworkable —
/// the closures belonged to whichever window ran its setup last, and the
/// mirrored enabled-state values to whichever window changed last,
/// including a BACKGROUND one. A focused value asks the question SwiftUI
/// already knows the answer to.
///
/// `nil` means no macSCP window is focused (the Settings window is in
/// front, or the app has no window at all): every entry below is disabled
/// or does nothing, which is exactly what the key-window guards were
/// trying to express.
private struct TabCommandsFocusedValueKey: FocusedValueKey {
    typealias Value = TabCommands
}

extension FocusedValues {
    var tabCommands: TabCommands? {
        get { self[TabCommandsFocusedValueKey.self] }
        set { self[TabCommandsFocusedValueKey.self] = newValue }
    }
}

/// Every menu this app adds to the menu bar.
///
/// A `Commands` type of its own rather than an inline `.commands { … }`
/// closure in `MacSCPApp.body`, because `@FocusedValue` is a dynamic
/// property: it belongs to a type SwiftUI can re-evaluate when the focused
/// window changes, and `App.body` is not that type.
///
/// `settingsStore` and `updateModel` are the two app-global objects the
/// menus read directly — a hidden-files toggle and an update check are not
/// window-scoped, and neither goes through the focused bridge.
struct MacSCPCommands: Commands {
    let settingsStore: SettingsStore
    let updateModel: UpdateCheckModel
    /// The focused window's bridge — see `TabCommandsFocusedValueKey`.
    @FocusedValue(\.tabCommands) private var tabCommands: TabCommands?

    var body: some Commands {
        // "Check for Updates…" (M11b/T2), directly under "About macSCP"
        // (spec §4). App-global, not routed through the focused
        // `tabCommands` bridge like the tab/session commands below — the
        // check itself doesn't depend on which window is focused, it
        // just compares the running bundle against the latest GitHub
        // release. Disabled while a check is already running (spec §4
        // multi-click guard); a manual click always presents a result,
        // shown via `updateModel.presentedResult` in the PRIMARY window's
        // alert (see `ContentView.isPrimaryWindow`: one check writes one
        // result, and every window attaching the alert raised its own
        // copy of it).
        CommandGroup(after: .appInfo) {
            Button(L10n.string("menu.checkForUpdates", "Check for Updates…")) {
                Task { await updateModel.check(manual: true, settingsStore: settingsStore) }
            }
            .disabled(updateModel.isChecking)
        }
        // Replaces the default "New Window" (⌘N) — this is a single-window,
        // multi-tab app (M8a/T4): ⌘N opens a new TAB instead. "Close Tab"
        // (⌘W) lives in the same group; it shadows the system "Close"
        // command with the same shortcut (there is no dedicated
        // `CommandGroupPlacement` to replace it outright), routing through
        // `tabCommands.closeActiveTab` which falls back to closing the
        // window when the active tab is the last, unconnected one.
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("menu.newTab", "New Tab")) {
                tabCommands?.newTab?()
            }
            .keyboardShortcut("n", modifiers: .command)
            // Disabled — not absent — when no macSCP window is focused
            // (Detachable Tabs plan, Task 2 fix round 1). This item shadows
            // the system "Close" command with the same shortcut, and with
            // the focused value gone (the Settings window in front, say)
            // there is no window's tabs for it to act on; a disabled item
            // lets the shadowed system command take ⌘W instead of eating it.
            Button(L10n.string("menu.closeTab", "Close Tab")) {
                tabCommands?.closeActiveTab?()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabCommands == nil)
        }
        // The Window menu's own entries: "Move Tab to New Window"
        // (Detachable Tabs plan, Task 2) and, below the divider, ⌘1–⌘9,
        // which jump to tab n (1-indexed) and no-op past the tab count
        // (`ContentView.selectTab(atIndex:)`). ⌃Tab cycling was left out
        // — it could not be verified in this headless environment (no
        // NSEvent monitor per the M8a/T4 brief); flagged for the T5 smoke.
        CommandGroup(after: .windowList) {
            // "Move Tab to New Window" (Detachable Tabs plan, Task 2):
            // the Window menu's route to the action the tab strip's
            // context menu offers on right-click, resolving the SAME
            // catalogue key so the two can never read differently. No
            // keyboard shortcut: none has been asked for, and this
            // group's shortcuts belong to ⌘1–9 below.
            //
            // `.disabled` rather than absent, which is the opposite of
            // what the context menu does with the same rule: a menu-bar
            // entry that comes and goes is harder to find than one that
            // is greyed, while a context menu is read top to bottom on
            // every open. `canMoveTabToNewWindow` carries the count from
            // the front window (see `TabCommands`).
            Button(L10n.string("window.moveTabToNewWindow", "Move Tab to New Window")) {
                tabCommands?.moveTabToNewWindow?()
            }
            .disabled(tabCommands?.canMoveTabToNewWindow != true)
            // "Keep on Top" (Detachable Tabs plan, Task 4): a checkmark
            // item rather than a plain `Button`, so the item itself shows
            // the focused window's sticky state — the same information a
            // `Toggle`'s binding would show inline in an ordinary view.
            // The binding's getter/setter both go through the focused
            // `tabCommands` box: the getter shows what IS true, the setter
            // never computes the next value itself, it only asks the
            // focused window to flip it (`toggleKeepOnTop`), the same
            // "menu never owns the state" shape `moveTabToNewWindow` above
            // it uses. Disabled — not absent — with no window focused, the
            // same rule "New Tab"/"Close Tab" follow above.
            Toggle(L10n.string("window.keepOnTop", "Keep on Top"), isOn: Binding(
                get: { tabCommands?.keepOnTop ?? false },
                set: { _ in tabCommands?.toggleKeepOnTop?() }
            ))
            .disabled(tabCommands == nil)
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(String(format: L10n.string("menu.selectTab", "Tab %lld"), n)) {
                    tabCommands?.selectTab?(n - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.string("menu.toggleHidden", "Show/Hide Hidden Files")) {
                settingsStore.showHiddenFiles.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button(L10n.string("menu.transfers.toggle", "Show/Hide Transfers")) {
                tabCommands?.toggleTransfers?()
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(tabCommands?.isActiveTabConnected != true)
        }
        // "Sessions" menu (M10a/T2, mockup section 4): bundles the
        // management sheets and the sidebar's existing export/import
        // actions in one menu-bar home. Same focused bridge as the other
        // `tabCommands` entries above — `ContentView.wireTabCommands()`
        // fills in its own window's closures, and only the focused
        // window's are reachable from here.
        CommandMenu(L10n.string("menu.sessions", "Sessions")) {
            Button(L10n.string("menu.knownHosts", "Known Hosts…")) {
                tabCommands?.showKnownHosts?()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            // "Server Certificates…": no shortcut — ⇧⌘K and ⇧⌘L are
            // taken, and "SSH Keys…"/"Hidden Imports…" set the precedent
            // that a management sheet does not need one.
            Button(L10n.string("menu.serverCertificates", "Server Certificates…")) {
                tabCommands?.showServerCertificates?()
            }
            Button(L10n.string("menu.logins", "Logins…")) {
                tabCommands?.showLogins?()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            // "SSH Keys…" (M18/T5): opens the SSH-key management sheet —
            // same focused bridge as the other entries in this menu.
            Button(L10n.string("menu.sshKeys", "SSH Keys…")) {
                tabCommands?.showSSHKeys?()
            }
            // "Hidden Imports…" (M11f/T2): the count suffix is the ONLY
            // way back once every imported entry is hidden and the
            // IMPORTED sidebar section itself disappears — see
            // `hiddenImportsMenuTitle(count:)`.
            Button(hiddenImportsMenuTitle(count: tabCommands?.hiddenImportsCount ?? 0)) {
                tabCommands?.showHiddenImports?()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            // "Ad-hoc Connection Log…" (M31): the audit trail of every
            // connection that was never saved. It has no sidebar row to
            // open it from -- its session is a value, not a record.
            Button(L10n.string("menu.adHocAuditLog", "Ad-hoc Connection Log…")) {
                tabCommands?.showAdHocAuditLog?()
            }
            Divider()
            Button(L10n.string("menu.exportAllSessions", "Export All Sessions…")) {
                tabCommands?.exportAllSessions?()
            }
            Button(L10n.string("menu.importSessions", "Import Sessions…")) {
                tabCommands?.importSessions?()
            }
            Button(L10n.string("menu.importLogins", "Import Logins…")) {
                tabCommands?.importLogins?()
            }
            // "From Cyberduck…" — beside the two entries above because
            // it ends in the same place they do (the store), and reads
            // as the third answer to "where do these sessions come
            // from". No shortcut: it is a once-in-a-while migration,
            // not a working action.
            Button(L10n.string("menu.importFromCyberduck", "From Cyberduck…")) {
                tabCommands?.importFromCyberduck?()
            }
        }
        // "Terminal" menu (M11d/T2, spec §4): always offers BOTH ways to
        // open a session's shell — the toolbar button/⌘T follow
        // `SettingsStore.terminalTarget`, but these two entries never
        // change with that setting, so switching it never takes a
        // capability away. Both disabled while the active tab has no
        // connected session (`tabCommands.isActiveTabConnected`, kept in
        // sync by `ContentView`), OR the active backend has no shell
        // (`tabCommands.activeTabSupportsShell`, M12/T7b — e.g. an S3
        // session). "Show/Hide Terminal" is additionally disabled while
        // the pane lock would refuse the click (whole-phase review, Fix
        // 2) — see `TabCommands.canToggleTerminal`; the external route
        // is not subject to that lock.
        CommandMenu(L10n.string("menu.terminal", "Terminal")) {
            Button(L10n.string("menu.terminal.toggle", "Show/Hide Terminal")) {
                tabCommands?.toggleTerminal?()
            }
            .disabled(tabCommands?.canToggleTerminal != true)
            Button(L10n.string("menu.terminal.openExternal", "Open in External Terminal")) {
                tabCommands?.openExternalTerminal?()
            }
            .disabled(tabCommands?.isActiveTabConnected != true || tabCommands?.activeTabSupportsShell != true)
            snippetMenuItems
        }
    }

    /// The snippet half of the "Terminal" menu (Terminal-Snippets milestone,
    /// Task 6): renders `SnippetMenuModel` through the shared
    /// `SnippetMenuItems` view — the SAME rendering a session's context
    /// menu, the terminal header popover and the terminal's right-click
    /// menu (Tasks 7/8) will reuse, so all four surfaces read one computed
    /// model instead of four hand-guessed ones. Two actions per snippet,
    /// "Insert" and "Execute" — never a per-snippet flag, see
    /// `SnippetMenuItems`'s doc comment.
    ///
    /// `shortcutOrder` carries the STORE order (`tabCommands.snippetsLoad.
    /// snippets`, unsorted): ⌃⌘1–3 insert the first three snippets in THAT
    /// order, not the tag-grouped order `SnippetMenuModel.groups` presents
    /// them in — see `SnippetMenuPlan.build`'s doc comment. Execute never
    /// gets a shortcut at all: a keystroke that fires a command on a remote
    /// host the instant it is pressed has no good failure mode — there is no
    /// undo and no confirmation.
    ///
    /// An unreadable store is not silence: it gets a disabled notice entry
    /// (see `SnippetsLoad`). That state lives only at the App layer —
    /// `SnippetMenuModel` is built from the already-unwrapped `[Snippet]`
    /// list, so it has no way to tell "empty" from "unreadable" apart —
    /// which is why this check stays here instead of moving into
    /// `SnippetMenuItems`. Disabled entries are this menu's existing way of
    /// saying "not available right now" — the two pre-existing entries use
    /// them for a missing connection — and "Manage Snippets…" stays enabled
    /// right below it, which is where the user can go look.
    @ViewBuilder
    private var snippetMenuItems: some View {
        let snippetsLoad = tabCommands?.snippetsLoad ?? .loaded([])
        let model = SnippetMenuModel.build(
            snippets: snippetsLoad.snippets,
            isConnected: tabCommands?.isActiveTabConnected ?? false,
            supportsShell: tabCommands?.activeTabSupportsShell ?? true)
        SnippetMenuItems(
            model: model, shortcutOrder: snippetsLoad.snippets
        ) { snippet, execute in
            tabCommands?.runSnippet?(snippet, execute)
        }
        Divider()
        if snippetsLoad.isUnreadable {
            Button(L10n.string(
                "menu.snippets.unreadable", "Snippets Couldn't Be Read")) {}
                .disabled(true)
        }
        // Not disabled with the entries above: editing snippets needs no
        // connection, the same way the Sessions menu's management sheets
        // are reachable without one.
        Button(L10n.string("menu.snippets.manage", "Manage Snippets…")) {
            tabCommands?.showSnippets?()
        }
    }
}
