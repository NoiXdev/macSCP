import Foundation

/// Read-only overview of the app's keyboard shortcuts (M11q). This is a
/// HAND-MAINTAINED mirror — there is no central shortcut registry. The real
/// bindings live across six sites; when a shortcut changes at ANY of them,
/// update this catalog too:
///   1. SwiftUI `.keyboardShortcut` in `MacSCPApp.swift` menus (⌘N, ⌘W,
///      ⌘1–9, ⌘⇧., ⌘⇧Y, ⌘⇧K, ⌘⇧L, ⌘⇧I, ⌃⌘1–3; ⌘, is the SwiftUI Settings
///      default).
///   2. The ⌘T terminal toolbar button in `ContentView.swift`.
///   3. `KeyboardDrivenTableView` hardcoded keyCodes in
///      `RemoteFileTableView.swift`, resolved via `BrowserKeyCommand` (Core).
///   4. ⌘F / search-Esc wiring (`RemoteFileTableView.swift`,
///      `FileSearchBar.swift`).
///   5. Path-bar completion keys in `PathBar.swift` (⇥ / ⇧⇥ / ⎋ / ⏎).
///   6. Sheet `.keyboardShortcut(.defaultAction)` (⏎) and `role: .cancel` (⎋).
/// The `shortcut` strings are FIXED display glyphs and are NOT localized;
/// the labels are localized via `L10n`.
enum KeyboardShortcutsCatalog {
    struct Row: Identifiable {
        let id = UUID()
        let labelKey: String
        let labelDefault: String
        let shortcut: String
    }

    struct Group: Identifiable {
        let id = UUID()
        let titleKey: String
        let titleDefault: String
        let rows: [Row]
    }

    static let groups: [Group] = [
        Group(titleKey: "settings.shortcuts.group.tabs", titleDefault: "Tabs & Windows", rows: [
            Row(labelKey: "settings.shortcuts.label.newTab", labelDefault: "New Tab", shortcut: "⌘N"),
            Row(labelKey: "settings.shortcuts.label.closeTab", labelDefault: "Close Tab", shortcut: "⌘W"),
            Row(labelKey: "settings.shortcuts.label.selectTab", labelDefault: "Select Tab 1–9", shortcut: "⌘1–9"),
            Row(labelKey: "settings.shortcuts.label.settings", labelDefault: "Settings", shortcut: "⌘,"),
        ]),
        Group(titleKey: "settings.shortcuts.group.view", titleDefault: "View", rows: [
            Row(labelKey: "settings.shortcuts.label.hiddenFiles", labelDefault: "Show/Hide Hidden Files", shortcut: "⌘⇧."),
            Row(labelKey: "settings.shortcuts.label.transfers", labelDefault: "Show/Hide Transfers", shortcut: "⌘⇧Y"),
            Row(labelKey: "settings.shortcuts.label.terminal", labelDefault: "Show/Hide Terminal", shortcut: "⌘T"),
        ]),
        Group(titleKey: "settings.shortcuts.group.sessions", titleDefault: "Sessions", rows: [
            Row(labelKey: "settings.shortcuts.label.knownHosts", labelDefault: "Known Hosts", shortcut: "⌘⇧K"),
            Row(labelKey: "settings.shortcuts.label.logins", labelDefault: "Logins", shortcut: "⌘⇧L"),
            Row(labelKey: "settings.shortcuts.label.hiddenImports", labelDefault: "Hidden Imports", shortcut: "⌘⇧I"),
        ]),
        // The Terminal menu's snippet entries are built from the saved
        // snippets, so only a fixed prefix of them can carry a shortcut at
        // all: the INSERT action of the first three snippets, in STORE
        // order — not the tag-grouped order the menu displays them in (see
        // `SnippetMenuPlan.build`). EXECUTE never gets one, by deliberate
        // design (not a per-snippet flag): a keystroke that fires a command
        // on a remote host the instant it is pressed has no good failure
        // mode.
        Group(titleKey: "settings.shortcuts.group.snippets", titleDefault: "Snippets", rows: [
            Row(labelKey: "settings.shortcuts.label.insertSnippet",
                labelDefault: "Insert snippet 1–3", shortcut: "⌃⌘1–3"),
        ]),
        Group(titleKey: "settings.shortcuts.group.browser", titleDefault: "File browser", rows: [
            Row(labelKey: "settings.shortcuts.label.goUp", labelDefault: "Go to parent folder", shortcut: "⌘↑"),
            Row(labelKey: "settings.shortcuts.label.open", labelDefault: "Open", shortcut: "⌘↓ / ⌘O"),
            Row(labelKey: "settings.shortcuts.label.info", labelDefault: "Info & Permissions", shortcut: "⌘I"),
            Row(labelKey: "settings.shortcuts.label.delete", labelDefault: "Delete", shortcut: "⌘⌫"),
            Row(labelKey: "settings.shortcuts.label.transferItem", labelDefault: "Transfer to other pane", shortcut: "␣"),
            Row(labelKey: "settings.shortcuts.label.rename", labelDefault: "Rename", shortcut: "⏎"),
            Row(labelKey: "settings.shortcuts.label.clearSelection", labelDefault: "Clear selection", shortcut: "⎋"),
            Row(labelKey: "settings.shortcuts.label.search", labelDefault: "Search", shortcut: "⌘F"),
        ]),
        Group(titleKey: "settings.shortcuts.group.pathbar", titleDefault: "Path bar", rows: [
            Row(labelKey: "settings.shortcuts.label.complete", labelDefault: "Complete path", shortcut: "⇥"),
            Row(labelKey: "settings.shortcuts.label.cycleBack", labelDefault: "Previous candidate", shortcut: "⇧⇥"),
            Row(labelKey: "settings.shortcuts.label.cancel", labelDefault: "Cancel", shortcut: "⎋"),
            Row(labelKey: "settings.shortcuts.label.navigate", labelDefault: "Go to path", shortcut: "⏎"),
        ]),
        Group(titleKey: "settings.shortcuts.group.sheets", titleDefault: "Dialogs", rows: [
            Row(labelKey: "settings.shortcuts.label.confirm", labelDefault: "Confirm", shortcut: "⏎"),
            Row(labelKey: "settings.shortcuts.label.cancel", labelDefault: "Cancel", shortcut: "⎋"),
        ]),
    ]
}
