# M7b — Kontextmenü & Dialoge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rechtsklick-Kontextmenü in beiden Panes (Übertragen-Submenü, Öffnen, Umbenennen, Info & Rechte, Neuer Ordner, Pfad kopieren, Löschen) mit den zugehörigen Sheets — auf den M7a-FS-APIs.

**Architecture:** Eine VM-Aktionsschicht (`RemoteBrowserViewModel` kapselt rename/chmod/delete/createFolder inkl. Refresh und lokalisierter Fehlertexte) plus ein UNIT-TESTBARES Menü-Modell in Core (`BrowserContextMenu.entries(for:side:)` — Lektion aus M7a: App-Target-Code ist untestbar, das Test-Target hängt nur an `macSCPCore`); der AppKit-Teil ist eine dünne `NSMenu`-Brücke im Tabellen-Coordinator, die Dialoge sind Pane-lokale SwiftUI-Sheets.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, AppKit `NSMenu`/`NSMenuDelegate`, SwiftUI-Sheets, PolishedButtonStyle.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-m7b-context-menu-design.md` — bindend. Branch: **develop**.
- Review-Auflagen aus M7a (bindend): **kein Rechte-Editor für `.symlink`-Zeilen** (`setPermissions` folgt auf beiden Backends dem Ziel) — der Menüpunkt „Informationen & Rechte…" entfällt für Symlinks (Spec-Präzisierung); Protokoll-Doku-Zeile dazu; `MockRemoteFileSystem.rename` ist shallow für Verzeichnisse — Fix in T1, BEVOR VM-Tests darauf bauen.
- Kein Verhalten bestehender Wege ändert sich (Doppelklick-Editor via `onOpenFile`, Toolbar-Buttons, Drag&Drop, Queue-Invarianten).
- Fehlermeldungen über das bestehende lokalisierte Mapping (`RemoteBrowserViewModel.message(for:path:)` bzw. `TransferQueueViewModel.message(for:)`); kein `String(describing:)`.
- Alle neuen UI-Texte katalogisiert EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); Code + Kommentare NUR Englisch.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 340 Tests / 28 Suiten); gated Suiten nur in T4.
- TDD für Core-Logik (VM-Aktionen, Menü-Modell, Permissions-Modell, Namens-Validierung).
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 (Core-Logik) → T2 (Menü) → T3 (Sheets) → T4 Abschluss (Koordinator).

---

### Task 1: VM-Aktionsschicht + Permissions-/Namens-Modell

**Files:**
- Create: `Sources/macSCPCore/Presentation/PosixPermissions.swift`
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift` (Aktions-Methoden nach `refresh()` Zeile ~72)
- Modify: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift` (eine Doku-Zeile an `setPermissions`)
- Modify: `Tests/macSCPCoreTests/MockRemoteFileSystem.swift` (Dir-Rename-Fix)
- Test: `Tests/macSCPCoreTests/PosixPermissionsTests.swift` (neu), `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystemTests.swift`

**Interfaces:**
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `RemoteBrowserViewModel.rename(_ item: RemoteFileItem, to newName: String) async -> String?` (nil = Erfolg; sonst lokalisierte Fehlermeldung — Sheet zeigt sie inline)
  - `RemoteBrowserViewModel.createFolder(named name: String) async -> String?`
  - `RemoteBrowserViewModel.applyPermissions(_ permissions: UInt32, to item: RemoteFileItem) async -> String?`
  - `RemoteBrowserViewModel.deleteItems(_ doomed: [RemoteFileItem]) async -> String?`
  - `RemoteBrowserViewModel.isValidEntryName(_ name: String) -> Bool` (static)
  - `struct PosixPermissions` (siehe unten)

- [ ] **Step 1: Mock-Dir-Rename-Fix (Vorbedingung, TDD)** — failing Test in `MockRemoteFileSystemTests.swift`:

```swift
    @Test func renameDirectoryRekeysDescendants() async throws {
        let fs = MockRemoteFileSystem(tree: [
            "/": [dirItem("/dir")],
            "/dir": [fileItem("/dir/a.txt", content: "a")],
        ])
        try await fs.rename(from: "/dir", to: "/renamed")
        let root = try await fs.list(path: "/")
        #expect(root.map(\.name) == ["renamed"])
        let children = try await fs.list(path: "/renamed")
        #expect(children.map(\.name) == ["a.txt"])
        await #expect(throws: RemoteFSError.self) { _ = try await fs.list(path: "/dir") }
    }
```

(Helper-Namen `dirItem`/`fileItem` bzw. die Konstruktions-API an die tatsächliche Mock-Init-Form der Datei anpassen — Assertions unverändert.) Rot beweisen, dann im Mock-`rename` alle Schlüssel mit Präfix `from + "/"` in `tree`/`files`/`written`/`writeModes`/`permissionsByPath` auf das neue Präfix umschreiben und die Item-`path`/`name`-Felder der umgehängten Einträge aktualisieren; grün beweisen.

- [ ] **Step 2: `PosixPermissions`** — failing Tests (`PosixPermissionsTests.swift`, neu):

```swift
import Testing
@testable import macSCPCore

@Suite("PosixPermissions")
struct PosixPermissionsTests {
    @Test func rawValueIsMaskedToLow12Bits() {
        #expect(PosixPermissions(rawValue: 0o100644).rawValue == 0o644)
    }

    @Test func octalStringRoundtrip() {
        #expect(PosixPermissions(rawValue: 0o640).octalString == "640")
        #expect(PosixPermissions(rawValue: 0o4755).octalString == "4755")
        #expect(PosixPermissions(octalString: "640")?.rawValue == 0o640)
        #expect(PosixPermissions(octalString: "4755")?.rawValue == 0o4755)
        #expect(PosixPermissions(octalString: "9") == nil)
        #expect(PosixPermissions(octalString: "") == nil)
        #expect(PosixPermissions(octalString: "77777") == nil)
    }

    @Test func bitAccessorsMatchOctal() {
        var p = PosixPermissions(rawValue: 0o640)
        #expect(p[.owner, .read] && p[.owner, .write] && !p[.owner, .execute])
        #expect(p[.group, .read] && !p[.group, .write])
        #expect(!p[.other, .read])
        p[.other, .read] = true
        #expect(p.rawValue == 0o644)
    }
}
```

Rot, dann Implementierung (`Sources/macSCPCore/Presentation/PosixPermissions.swift`):

```swift
import Foundation

/// The low 12 POSIX permission bits as a value type the permissions sheet
/// binds to (M7b): rwx grid and octal field stay in sync through it.
public struct PosixPermissions: Equatable, Sendable {
    public enum Class: CaseIterable, Sendable { case owner, group, other }
    public enum Right: CaseIterable, Sendable { case read, write, execute }

    public private(set) var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & 0o7777
    }

    /// 3–4 digit octal form ("640", "4755"). Never padded beyond 3 digits.
    public var octalString: String {
        let s = String(rawValue, radix: 8)
        return s.count < 3 ? String(repeating: "0", count: 3 - s.count) + s : s
    }

    /// Parses a 1–4 digit octal string; nil for anything else.
    public init?(octalString: String) {
        guard (1...4).contains(octalString.count),
              octalString.allSatisfy({ "01234567".contains($0) }),
              let value = UInt32(octalString, radix: 8) else { return nil }
        self.init(rawValue: value)
    }

    private static func mask(_ c: Class, _ r: Right) -> UInt32 {
        let shift: UInt32 = c == .owner ? 6 : (c == .group ? 3 : 0)
        let bit: UInt32 = r == .read ? 0o4 : (r == .write ? 0o2 : 0o1)
        return bit << shift
    }

    public subscript(c: Class, r: Right) -> Bool {
        get { rawValue & Self.mask(c, r) != 0 }
        set {
            if newValue { rawValue |= Self.mask(c, r) }
            else { rawValue &= ~Self.mask(c, r) }
        }
    }
}
```

- [ ] **Step 3: VM-Aktionen** — failing Tests in `RemoteBrowserViewModelTests.swift` (Mock-Konventionen der Datei):

```swift
    @Test @MainActor func renameRefreshesAndFollowsSelection() async {
        let fs = MockRemoteFileSystem(tree: ["/": [fileItem("/old.txt", content: "x")]])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let old = vm.items[0]
        let error = await vm.rename(old, to: "new.txt")
        #expect(error == nil)
        #expect(vm.items.map(\.name) == ["new.txt"])
        #expect(vm.selectedItems.map(\.name) == ["new.txt"])
    }

    @Test @MainActor func renameCollisionReturnsLocalizedMessage() async {
        let fs = MockRemoteFileSystem(tree: ["/": [
            fileItem("/a.txt", content: "a"), fileItem("/b.txt", content: "b")]])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let error = await vm.rename(vm.items[0], to: "b.txt")
        #expect(error != nil)
        #expect(vm.items.count == 2)   // nothing changed
    }

    @Test @MainActor func invalidNamesAreRejected() {
        #expect(!RemoteBrowserViewModel.isValidEntryName(""))
        #expect(!RemoteBrowserViewModel.isValidEntryName("a/b"))
        #expect(!RemoteBrowserViewModel.isValidEntryName("."))
        #expect(!RemoteBrowserViewModel.isValidEntryName(".."))
        #expect(RemoteBrowserViewModel.isValidEntryName(".env"))
        #expect(RemoteBrowserViewModel.isValidEntryName("normal name.txt"))
    }

    @Test @MainActor func deleteItemsRemovesAllAndRefreshes() async {
        let fs = MockRemoteFileSystem(tree: [
            "/": [fileItem("/a.txt", content: "a"), dirItem("/dir"), fileItem("/keep.txt", content: "k")],
            "/dir": [fileItem("/dir/x.txt", content: "x")],
        ])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let doomed = vm.items.filter { $0.name != "keep.txt" }
        let error = await vm.deleteItems(doomed)
        #expect(error == nil)
        #expect(vm.items.map(\.name) == ["keep.txt"])
        #expect(vm.selectedItems.isEmpty)
    }

    @Test @MainActor func createFolderRefreshesAndSelects() async {
        let fs = MockRemoteFileSystem(tree: ["/": []])
        let vm = RemoteBrowserViewModel(fs: fs)
        await vm.load()
        let error = await vm.createFolder(named: "fresh")
        #expect(error == nil)
        #expect(vm.items.map(\.name) == ["fresh"])
        #expect(vm.selectedItems.map(\.name) == ["fresh"])
    }
```

- [ ] **Step 4: Rot, dann implementieren** — in `RemoteBrowserViewModel`:

```swift
    // MARK: - Browser actions (M7b)

    /// Entry-name validation for rename/new-folder sheets: non-empty, no
    /// path separator, not the two directory pseudo-entries.
    public static func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// Renames `item` within the current directory. Returns nil on success
    /// (after refreshing; the selection follows the renamed entry), or a
    /// localized error message for inline display in the sheet.
    public func rename(_ item: RemoteFileItem, to newName: String) async -> String? {
        let destination = RemotePath.join(currentPath, newName)
        do {
            try await fs.rename(from: item.path, to: destination)
        } catch {
            return Self.message(for: error, path: item.path)
        }
        await load()
        if let renamed = items.first(where: { $0.path == destination }) {
            selectedItems = [renamed]
        }
        return nil
    }

    /// Creates a folder in the current directory, refreshes, selects it.
    public func createFolder(named name: String) async -> String? {
        let path = RemotePath.join(currentPath, name)
        // `createDirectory` is idempotent by contract — an existing DIRECTORY
        // would be silently "created". A colliding name must surface in the
        // sheet instead, so probe first.
        if items.contains(where: { $0.name == name }) {
            return Self.message(
                for: RemoteFSError.protocolError(reason: "destination already exists: \(path)"),
                path: path)
        }
        do {
            try await fs.createDirectory(at: path)
        } catch {
            return Self.message(for: error, path: path)
        }
        await load()
        if let created = items.first(where: { $0.path == path }) {
            selectedItems = [created]
        }
        return nil
    }

    /// Applies the low 12 permission bits to `item`, then refreshes.
    public func applyPermissions(_ permissions: UInt32, to item: RemoteFileItem) async -> String? {
        do {
            try await fs.setPermissions(path: item.path, permissions: permissions)
        } catch {
            return Self.message(for: error, path: item.path)
        }
        await load()
        return nil
    }

    /// Deletes all `doomed` entries sequentially via `deleteTree` (a plain
    /// file behaves like `delete`; a symlink is removed as the link). Stops
    /// at the first failure and returns its localized message — already
    /// deleted entries stay deleted (documented in the spec). Refreshes in
    /// both outcomes so the pane reflects reality.
    public func deleteItems(_ doomed: [RemoteFileItem]) async -> String? {
        var failure: String?
        for item in doomed {
            do {
                try await fs.deleteTree(at: item.path)
            } catch {
                failure = Self.message(for: error, path: item.path)
                break
            }
        }
        await load()
        return failure
    }
```

Doku-Zeile an `RemoteFileSystem.setPermissions` (Zeile ~46) ergänzen:

```swift
    /// NOTE: both implementations follow symlinks (chmod semantics) — the
    /// UI must not offer the permission editor for `.symlink` entries (M7b).
```

- [ ] **Step 5: Grün** — volle `swift test` (340 + neue).
- [ ] **Step 6: Commit** — `feat: browser action layer, posix permissions model, mock dir rename`.

---

### Task 2: Menü-Modell + NSMenu-Brücke

**Files:**
- Create: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (Coordinator: Menü + Delegate; Representable: neuer Callback)
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (Callback durchreichen)
- Modify: `Sources/MacSCPApp/ContentView.swift` (Transfer-/Editor-Verdrahtung, Pfad kopieren)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj` (Menü-Keys)
- Test: `Tests/macSCPCoreTests/BrowserContextMenuTests.swift` (neu)

**Interfaces:**
- Consumes: T1 (nur konzeptionell — die Menü-AKTIONEN verdrahtet T3 für die Sheets; T2 verdrahtet transfer/open/copyPath vollständig).
- Produces:
  - `public enum BrowserPaneSide: Sendable { case local, remote }`
  - `public enum BrowserMenuEntry: Equatable, Sendable { case transferToOtherPane, openInEditor, rename, infoAndPermissions, newFolder, copyPath, delete }`
  - `public enum BrowserContextMenu { public static func entries(for selection: [RemoteFileItem], side: BrowserPaneSide) -> [BrowserMenuEntry] }`
  - Coordinator-/Pane-Callback `onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)?` (Items = die Selektion, auf die das Menü wirkt; bei `newFolder` darf sie leer sein).

- [ ] **Step 1: Failing Tests** (`BrowserContextMenuTests.swift`):

```swift
import Testing
@testable import macSCPCore

@Suite("BrowserContextMenu")
struct BrowserContextMenuTests {
    private func file(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .file, size: 1)
    }
    private func symlink(_ name: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: "/\(name)", kind: .symlink, size: nil)
    }

    @Test func backgroundShowsOnlyNewFolder() {
        #expect(BrowserContextMenu.entries(for: [], side: .remote) == [.newFolder])
    }

    @Test func singleRemoteFileShowsEverything() {
        #expect(BrowserContextMenu.entries(for: [file("a")], side: .remote) == [
            .transferToOtherPane, .openInEditor, .rename, .infoAndPermissions,
            .newFolder, .copyPath, .delete,
        ])
    }

    @Test func localPaneNeverOffersEditor() {
        #expect(!BrowserContextMenu.entries(for: [file("a")], side: .local)
            .contains(.openInEditor))
    }

    @Test func symlinkGetsNoTransferNoEditorNoPermissions() {
        let entries = BrowserContextMenu.entries(for: [symlink("l")], side: .remote)
        #expect(entries == [.rename, .newFolder, .copyPath, .delete])
    }

    @Test func multiSelectionDropsSingleOnlyEntries() {
        let entries = BrowserContextMenu.entries(
            for: [file("a"), file("b")], side: .remote)
        #expect(entries == [.transferToOtherPane, .newFolder, .copyPath, .delete])
    }

    @Test func symlinkOnlyMultiSelectionHasNoTransfer() {
        let entries = BrowserContextMenu.entries(
            for: [symlink("l1"), symlink("l2")], side: .remote)
        #expect(entries == [.newFolder, .copyPath, .delete])
    }

    @Test func directoriesGetNoEditor() {
        let dir = RemoteFileItem(name: "d", path: "/d", kind: .directory, size: nil)
        #expect(!BrowserContextMenu.entries(for: [dir], side: .remote)
            .contains(.openInEditor))
    }
}
```

- [ ] **Step 2: Rot, dann Modell implementieren:**

```swift
import Foundation

/// Which pane a context menu belongs to (M7b) — the editor entry exists
/// only on the remote side.
public enum BrowserPaneSide: Sendable { case local, remote }

/// Context-menu entries in display order. The AppKit layer maps these to
/// localized NSMenuItems; keeping the decision logic here makes it unit-
/// testable (the test target only links macSCPCore — M7a lesson).
public enum BrowserMenuEntry: Equatable, Sendable {
    case transferToOtherPane   // submenu "Transfer" — M8 adds per-session targets
    case openInEditor          // remote FILES only (M5e path)
    case rename                // single selection only
    case infoAndPermissions    // single, NEVER for symlinks (chmod follows links)
    case newFolder             // always (also on background click)
    case copyPath              // any non-empty selection
    case delete                // any non-empty selection
}

public enum BrowserContextMenu {
    /// Menu model for a selection. Empty selection = background click.
    public static func entries(
        for selection: [RemoteFileItem], side: BrowserPaneSide
    ) -> [BrowserMenuEntry] {
        guard !selection.isEmpty else { return [.newFolder] }
        var entries: [BrowserMenuEntry] = []
        if selection.contains(where: { $0.kind != .symlink }) {
            entries.append(.transferToOtherPane)
        }
        if selection.count == 1, let only = selection.first {
            if side == .remote && only.kind == .file {
                entries.append(.openInEditor)
            }
            entries.append(.rename)
            if only.kind != .symlink {
                entries.append(.infoAndPermissions)
            }
        }
        entries.append(.newFolder)
        entries.append(.copyPath)
        entries.append(.delete)
        return entries
    }
}
```

- [ ] **Step 3: Coordinator-Brücke** — in `RemoteFileTableView`:
  - Representable: neues Property `var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)?`; in `makeNSView` `table.menu = NSMenu()` + `table.menu?.delegate = context.coordinator`; in `updateNSView` (VOR den Guards, bei den anderen Rebinds) `context.coordinator.onMenuAction = onMenuAction`.
  - Coordinator: `var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)?` + `NSMenuDelegate`:

```swift
        // MARK: - Context menu (M7b)

        /// Finder behavior: right-click on an unselected row selects it
        /// first (and reports the change); right-click inside the current
        /// selection keeps it; a click below the rows targets the pane
        /// background (empty selection → "New Folder" only).
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            let clicked = table.clickedRow
            var selection: [RemoteFileItem] = []
            if clicked >= 0, clicked < items.count {
                if !table.selectedRowIndexes.contains(clicked) {
                    table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                    onSelect([items[clicked]])
                }
                selection = table.selectedRowIndexes.compactMap {
                    $0 < items.count ? items[$0] : nil
                }
            }
            menu.removeAllItems()
            let side: BrowserPaneSide = onOpenFile != nil ? .remote : .local
            for entry in BrowserContextMenu.entries(for: selection, side: side) {
                if entry == .delete, menu.items.isEmpty == false {
                    menu.addItem(.separator())
                }
                menu.addItem(makeItem(entry, selection: selection))
            }
        }

        private func makeItem(_ entry: BrowserMenuEntry, selection: [RemoteFileItem]) -> NSMenuItem {
            switch entry {
            case .transferToOtherPane:
                // Submenu now with a single target — M8 hooks per-session
                // targets into the same submenu.
                let parent = NSMenuItem(
                    title: L10n.string("menu.transfer", "Transfer"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.addItem(actionItem(
                    title: L10n.string("menu.transfer.otherPane", "To the other pane"),
                    entry: entry, selection: selection))
                parent.submenu = submenu
                return parent
            case .openInEditor:
                return actionItem(title: L10n.string("menu.openEditor", "Open"), entry: entry, selection: selection)
            case .rename:
                return actionItem(title: L10n.string("menu.rename", "Rename…"), entry: entry, selection: selection)
            case .infoAndPermissions:
                return actionItem(title: L10n.string("menu.info", "Info & Permissions…"), entry: entry, selection: selection)
            case .newFolder:
                return actionItem(title: L10n.string("menu.newFolder", "New Folder…"), entry: entry, selection: selection)
            case .copyPath:
                return actionItem(title: L10n.string("menu.copyPath", "Copy Path"), entry: entry, selection: selection)
            case .delete:
                let item = actionItem(title: L10n.string("menu.delete", "Delete…"), entry: entry, selection: selection)
                return item
            }
        }

        private func actionItem(
            title: String, entry: BrowserMenuEntry, selection: [RemoteFileItem]
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(menuItemFired(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuActionBox(entry: entry, selection: selection)
            return item
        }

        @objc private func menuItemFired(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? MenuActionBox else { return }
            onMenuAction?(box.entry, box.selection)
        }
```

  plus die kleine Box-Klasse (Datei-Ende, neben `Coordinator`):

```swift
/// NSMenuItem.representedObject needs a class — boxes the menu action.
private final class MenuActionBox {
    let entry: BrowserMenuEntry
    let selection: [RemoteFileItem]
    init(entry: BrowserMenuEntry, selection: [RemoteFileItem]) {
        self.entry = entry
        self.selection = selection
    }
}
```

  Hinweis Side-Erkennung: `onOpenFile != nil ⇒ .remote` nutzt die bestehende Verdrahtung (nur das Remote-Pane setzt `onOpenFile`) — dokumentieren; falls der Reviewer das zu implizit findet, ist ein explizites `side: BrowserPaneSide`-Property am Representable die saubere Alternative (dann auch in `BrowserPane` durchreichen). IMPLEMENTIERE direkt die explizite Variante (`let side: BrowserPaneSide` als Representable-/Pane-Parameter) — sie ist selbstdokumentierend.
- [ ] **Step 4: Pane/ContentView-Verdrahtung** — `BrowserPane` bekommt `let side: BrowserPaneSide` und `var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem]) -> Void)? = nil`, reicht beides an `RemoteFileTableView`. `ContentView` setzt `side: .local` / `.remote` und verdrahtet in T2 NUR diese Fälle im Handler (Rest kommt in T3):

```swift
                onMenuAction: { entry, selection in
                    switch entry {
                    case .transferToOtherPane:
                        transferSelection(selection, from: .local, session: session)
                    case .openInEditor:
                        if let item = selection.first { openInEditor(item, session: session) }
                    case .copyPath:
                        copyPaths(of: selection)
                    default:
                        break   // sheets arrive with T3
                    }
                }
```

  Neue Helper in `ContentView`:

```swift
    /// Context-menu transfer: same per-item enqueue the toolbar buttons use.
    private func transferSelection(
        _ selection: [RemoteFileItem], from side: BrowserPaneSide, session: BrowserSession
    ) {
        for item in selection where item.kind != .symlink {
            switch (side, item.kind) {
            case (.local, .directory):
                transferQueue.enqueueTree(
                    directoryName: item.name, direction: .upload,
                    source: session.localFS, sourceDirectory: item.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() })
            case (.local, _):
                transferQueue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.localFS, sourcePath: item.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() })
            case (.remote, .directory):
                transferQueue.enqueueTree(
                    directoryName: item.name, direction: .download,
                    source: session.remoteFS, sourceDirectory: item.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() })
            case (.remote, _):
                transferQueue.enqueue(
                    fileName: item.name, direction: .download,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() })
            }
        }
    }

    /// "Copy Path": one absolute path per line.
    private func copyPaths(of selection: [RemoteFileItem]) {
        let text = selection.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
```

  REFAKTOR im selben Zug: `uploadButton`/`downloadButton` rufen `transferSelection` (DRY — deren Schleifen entfallen; Verhalten identisch, bestehende Hilfetexte/Disable-Logik bleiben).
- [ ] **Step 5: Menü-Keys** — EN: `"menu.transfer" = "Transfer"; "menu.transfer.otherPane" = "To the other pane"; "menu.openEditor" = "Open"; "menu.rename" = "Rename…"; "menu.info" = "Info & Permissions…"; "menu.newFolder" = "New Folder…"; "menu.copyPath" = "Copy Path"; "menu.delete" = "Delete…";` — DE: `"Übertragen"; "Zum anderen Fenster"; "Öffnen"; "Umbenennen…"; "Informationen & Rechte…"; "Neuer Ordner…"; "Pfad kopieren"; "Löschen…";`
- [ ] **Step 6: Grün** — volle Suite; Build sauber.
- [ ] **Step 7: Commit** — `feat: context menu in both panes with transfer, open, copy path`.

---

### Task 3: Sheets — Umbenennen, Neuer Ordner, Info & Rechte, Löschen

**Files:**
- Create: `Sources/MacSCPApp/BrowserSheets.swift` (NameEntrySheet + InfoPermissionsSheet)
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (Sheet-States + Präsentation + restliche Menü-Fälle)
- Modify: `Sources/MacSCPApp/ContentView.swift` (Menü-Handler: rename/info/newFolder/delete an das Pane delegieren — die Sheets leben im Pane, der Handler dort braucht die Fälle nicht mehr; prüfen und die Verantwortung sauber EINEM Ort geben: die vier Dialog-Fälle behandelt `BrowserPane` INTERN, `ContentView` behält nur transfer/openInEditor/copyPath)
- Modify: beide `Localizable.strings`
- Test: keine neuen Unit-Tests (View-Schicht; Logik ist in T1 getestet) — bestehende Suite bleibt grün.

**Interfaces:**
- Consumes: T1-VM-Methoden (exakte Signaturen oben), `PosixPermissions`, T2-Menü (`BrowserMenuEntry`, `onMenuAction`).
- Produces: `struct NameEntrySheet: View`, `struct InfoPermissionsSheet: View` (beide in `BrowserSheets.swift`).

- [ ] **Step 1: Pane-interne Behandlung** — in `BrowserPane`:

```swift
    @State private var renameTarget: RemoteFileItem?
    @State private var infoTarget: RemoteFileItem?
    @State private var deleteRequest: [RemoteFileItem]?
    @State private var showNewFolderSheet = false
    @State private var deleteErrorMessage: String?
```

  Der `onMenuAction`-Callback des Panes wird zweistufig: Das Pane fängt `rename`/`infoAndPermissions`/`newFolder`/`delete` selbst ab (setzt die States) und reicht NUR die übrigen Fälle an den externen Callback weiter:

```swift
                RemoteFileTableView(
                    ...,
                    onMenuAction: { entry, selection in
                        switch entry {
                        case .rename: renameTarget = selection.first
                        case .infoAndPermissions: infoTarget = selection.first
                        case .newFolder: showNewFolderSheet = true
                        case .delete: deleteRequest = selection
                        default: onMenuAction?(entry, selection)
                        }
                    }
                )
```

- [ ] **Step 2: NameEntrySheet** (`BrowserSheets.swift`) — geteilt für Umbenennen/Neuer Ordner:

```swift
import SwiftUI
import macSCPCore

/// Shared name-entry sheet for Rename and New Folder (M7b). `onConfirm`
/// returns nil on success (sheet closes) or a localized error message
/// (shown inline, sheet stays open).
struct NameEntrySheet: View {
    let title: String
    let confirmLabel: String
    let initialName: String
    let onConfirm: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(title, text: $name, prompt: nil)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .disabled(isWorking)
                .onSubmit { confirm() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { dismiss() }
                    .buttonStyle(.polished)
                    .disabled(isWorking)
                Button(confirmLabel) { confirm() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !RemoteBrowserViewModel.isValidEntryName(name))
            }
        }
        .padding(20)
        .onAppear { name = initialName }
    }

    private func confirm() {
        guard RemoteBrowserViewModel.isValidEntryName(name), !isWorking else { return }
        isWorking = true
        let candidate = name
        Task { @MainActor in
            let error = await onConfirm(candidate)
            isWorking = false
            if let error { errorMessage = error } else { dismiss() }
        }
    }
}
```

  Präsentation im Pane:

```swift
            .sheet(item: $renameTarget) { target in
                NameEntrySheet(
                    title: L10n.string("sheet.rename.title", "Rename"),
                    confirmLabel: L10n.string("sheet.rename.confirm", "Rename"),
                    initialName: target.name,
                    onConfirm: { newName in await viewModel.rename(target, to: newName) })
            }
            .sheet(isPresented: $showNewFolderSheet) {
                NameEntrySheet(
                    title: L10n.string("sheet.newFolder.title", "New Folder"),
                    confirmLabel: L10n.string("sheet.newFolder.confirm", "Create"),
                    initialName: L10n.string("sheet.newFolder.defaultName", "untitled folder"),
                    onConfirm: { name in await viewModel.createFolder(named: name) })
            }
```

  (`RemoteFileItem` braucht dafür `Identifiable` — falls noch nicht konform: `extension RemoteFileItem: Identifiable { public var id: String { path } }` in Core, mit Doku-Satz.)
- [ ] **Step 3: InfoPermissionsSheet** (`BrowserSheets.swift`):

```swift
/// Info & permissions sheet (M7b): metadata block plus the rwx grid and
/// octal field bound through `PosixPermissions`. Never offered for
/// symlinks (the menu model excludes them — chmod follows links).
struct InfoPermissionsSheet: View {
    let item: RemoteFileItem
    let onApply: (UInt32) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var permissions = PosixPermissions(rawValue: 0)
    @State private var octalText = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var hasPermissions: Bool { item.permissions != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                infoRow(L10n.string("info.path", "Path"), item.path)
                infoRow(L10n.string("info.kind", "Kind"), kindLabel)
                infoRow(L10n.string("info.size", "Size"), FileListFormatter.sizeString(for: item))
                infoRow(L10n.string("info.modified", "Modified"), FileListFormatter.dateString(for: item))
            }
            Divider()
            Text(L10n.string("info.permissions", "Permissions"))
                .font(.system(size: 12, weight: .semibold))
            if hasPermissions {
                permissionsGrid
                HStack(spacing: 8) {
                    Text(L10n.string("info.octal", "Octal"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.inkSecondary)
                    TextField("", text: $octalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: octalText) { _, newValue in
                            if let parsed = PosixPermissions(octalString: newValue) {
                                permissions = parsed
                            }
                        }
                }
            } else {
                Text(L10n.string(
                    "info.permissionsUnavailable",
                    "Permissions are not available for this entry."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(L10n.string("common.close", "Close"), role: .cancel) { dismiss() }
                    .buttonStyle(.polished)
                    .disabled(isWorking)
                if hasPermissions {
                    Button(L10n.string("common.apply", "Apply")) { apply() }
                        .buttonStyle(.polishedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear {
            permissions = PosixPermissions(rawValue: item.permissions ?? 0)
            octalText = permissions.octalString
        }
        .onChange(of: permissions) { _, newValue in
            octalText = newValue.octalString
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .directory: return L10n.string("info.kind.directory", "Folder")
        case .file: return L10n.string("info.kind.file", "File")
        case .symlink: return L10n.string("info.kind.symlink", "Symbolic link")
        case .other: return L10n.string("info.kind.other", "Other")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(DesignTokens.inkSecondary)
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private var permissionsGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text(L10n.string("info.perm.read", "Read"))
                Text(L10n.string("info.perm.write", "Write"))
                Text(L10n.string("info.perm.execute", "Execute"))
            }
            .font(.system(size: 11, weight: .semibold))
            permissionRow(L10n.string("info.perm.owner", "Owner"), .owner)
            permissionRow(L10n.string("info.perm.group", "Group"), .group)
            permissionRow(L10n.string("info.perm.other", "Others"), .other)
        }
    }

    private func permissionRow(_ label: String, _ c: PosixPermissions.Class) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).gridColumnAlignment(.leading)
            ForEach([PosixPermissions.Right.read, .write, .execute], id: \.self) { right in
                Toggle("", isOn: Binding(
                    get: { permissions[c, right] },
                    set: { permissions[c, right] = $0 }
                ))
                .labelsHidden()
                .disabled(isWorking)
            }
        }
    }

    private func apply() {
        guard !isWorking else { return }
        isWorking = true
        let value = permissions.rawValue
        Task { @MainActor in
            let error = await onApply(value)
            isWorking = false
            if let error { errorMessage = error } else { dismiss() }
        }
    }
}
```

  Präsentation im Pane:

```swift
            .sheet(item: $infoTarget) { target in
                InfoPermissionsSheet(
                    item: target,
                    onApply: { perms in await viewModel.applyPermissions(perms, to: target) })
            }
```
- [ ] **Step 4: Lösch-Bestätigung** — im Pane (Alert statt Sheet; destruktiver roter Button):

```swift
            .alert(
                L10n.string("delete.title", "Delete?"),
                isPresented: Binding(
                    get: { deleteRequest != nil },
                    set: { if !$0 { deleteRequest = nil } }
                ),
                presenting: deleteRequest
            ) { doomed in
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) {}
                Button(L10n.string("delete.confirm", "Delete"), role: .destructive) {
                    let items = doomed
                    Task { @MainActor in
                        deleteErrorMessage = await viewModel.deleteItems(items)
                    }
                }
            } message: { doomed in
                Text(deleteMessage(for: doomed))
            }
            .alert(
                L10n.string("delete.failedTitle", "Delete failed"),
                isPresented: Binding(
                    get: { deleteErrorMessage != nil },
                    set: { if !$0 { deleteErrorMessage = nil } }
                )
            ) {
                Button(L10n.string("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(deleteErrorMessage ?? "")
            }
```

```swift
    private func deleteMessage(for doomed: [RemoteFileItem]) -> String {
        let base: String
        if doomed.count == 1, let only = doomed.first {
            base = String(format: L10n.string(
                "delete.message.single", "“%@” will be deleted."), only.name)
        } else {
            base = String(format: L10n.string(
                "delete.message.many", "%lld items will be deleted."), Int64(doomed.count))
        }
        let folderHint = doomed.contains { $0.kind == .directory }
            ? " " + L10n.string(
                "delete.message.recursive", "Folders are deleted with their entire contents.")
            : ""
        return base + folderHint + " " + L10n.string(
            "delete.message.permanent", "This action cannot be undone.")
    }
```

- [ ] **Step 5: Katalog-Keys** — EN/DE für: `sheet.rename.title/confirm`, `sheet.newFolder.title/confirm/defaultName`, `common.close`, `common.apply`, `info.path/kind/size/modified/permissions/octal/permissionsUnavailable`, `info.kind.directory/file/symlink/other`, `info.perm.read/write/execute/owner/group/other`, `delete.title/confirm/failedTitle`, `delete.message.single/many/recursive/permanent`. DE-Texte: „Umbenennen"/„Umbenennen", „Neuer Ordner"/„Erstellen"/„unbenannter Ordner", „Schließen", „Übernehmen", „Pfad"/„Art"/„Größe"/„Geändert"/„Rechte"/„Oktal"/„Für diesen Eintrag sind keine Rechte verfügbar.", „Ordner"/„Datei"/„Symbolischer Link"/„Sonstiges", „Lesen"/„Schreiben"/„Ausführen"/„Besitzer"/„Gruppe"/„Andere", „Löschen?"/„Löschen"/„Löschen fehlgeschlagen", „„%@" wird gelöscht."/„%lld Objekte werden gelöscht."/„Ordner werden mit ihrem gesamten Inhalt gelöscht."/„Diese Aktion kann nicht widerrufen werden."
- [ ] **Step 6: Grün** — volle Suite; Build sauber (neue Dateien warnungsfrei).
- [ ] **Step 7: Commit** — `feat: rename, new-folder, info-permissions and delete dialogs`.

---

### Task 4: Abschluss-Verifikation (Koordinator, kein Subagent)

- [ ] Gated Suiten (Rig aus dem Haupt-Checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün.
- [ ] Visueller Smoke (Dev-Wrapper): Menü in BEIDEN Panes (Hintergrund-Klick → nur „Neuer Ordner…"); Rechtsklick auf unselektierte Zeile selektiert; Umbenennen inkl. Kollision (Fehlertext im Sheet, Sheet bleibt offen); chmod am Rig mit `docker exec ls -l`-Beweis (0644→0600); Symlink-Zeile: kein Übertragen/Öffnen/Info; rekursives Löschen mit rotem Confirm (Ordner-Hinweis) + `docker exec`-Beweis; Neuer Ordner (Default-Name, Auswahl folgt); Pfad kopieren (Mehrfachauswahl → mehrzeilig, pbpaste-Beweis); Übertragen-Submenü 2er-Auswahl → 2 Queue-Items; Editor-„Öffnen" aus dem Menü; Doppelklick/Toolbar/Drag-Regression.
- [ ] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ Frage an den Maintainer: Release v1.1.0 von diesem Stand?).
