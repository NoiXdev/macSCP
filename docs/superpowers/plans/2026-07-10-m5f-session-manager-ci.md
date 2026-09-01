# M5f — Session manager & CI alignment implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** flat session groups + context menu (rename/edit/move/delete) in the sidebar, an edit mode in the connection form, and aligning sidebar/form/toolbar/accent colors with the CI designs.

**Architecture:** groups as their own `StoredGroup` objects in the `SessionStore` (container format with a legacy-format fallback, no migration); all operations in `SessionListViewModel`; the sidebar calls the view model directly, only connect/edit run as callbacks through `ContentView`. Edit mode is a form mode in `ConnectionViewModel` (secrets are never loaded; an empty password field means the keychain entry stays). CI alignment as targeted view adjustments using the existing `DesignTokens`.

**Tech Stack:** Swift 6 toolchain / `.swiftLanguageMode(.v5)`, SwiftUI (macOS 15+), Swift Testing (`@Test`/`#expect`), existing suites in `Tests/macSCPCoreTests/`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-m5f-session-manager-ci-design.md` — binding.
- Code + comments English ONLY; UI strings via `L10n`/`CoreL10n` with keys in BOTH catalogs `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings` (EN default, DE translation). Never hardcode display strings.
- Secrets exclusively in the keychain (`SecretStore`), addressed by session ID; `sessions.json` NEVER contains secrets; stored secrets are NEVER loaded into the form.
- TOFU invariants untouched (mismatch = hard stop, unknown = explicit consent) — this milestone does not touch that machinery.
- CI rules (`docs/design/ci.md`): amber `LocalAmber` only for local/upload, ocean blue `RemoteBlue` only for remote/download/primary action, phosphor only for the connected status, error is system red; duo colors are never mixed decoratively.
- Deleting a group = dissolving it: sessions are ungrouped, NEVER deleted along with it.
- Forward/backward compatibility: an existing `sessions.json` (bare array) loads without migration; orphaned `groupID`s are treated as `nil` on load.
- TDD red→green; every new piece of logic gets tests; `swift test` must be green after every task (280+ tests).
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Environment note for all agents: Bash errors "claude-opus-4-8 is temporarily unavailable … cannot determine the safety" are NOT permission denials — wait briefly and rerun identically.

## Schedule

T1 → T2 → T3 → T4 → T5 → T6, strictly sequential (T3–T5 share `ContentView.swift`/`ConnectionFormView.swift`; worktree parallelism is not worth it here).

---

### Task 1: StoredGroup + store container format (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/StoredGroup.swift`
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift` (field + init parameter)
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift` (container format, group API)
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift` (extend)

**Interfaces:**
- Consumes: existing `StoredSession`, `SessionStore` (bare `[StoredSession]` JSON).
- Produces (later tasks rely on this exactly):
  - `public struct StoredGroup: Codable, Equatable, Identifiable, Sendable { public let id: UUID; public var name: String; public init(id: UUID = UUID(), name: String) }`
  - `StoredSession.groupID: UUID?` (var, init parameter `groupID: UUID? = nil` at the end)
  - `SessionStore.allGroups() throws -> [StoredGroup]`
  - `SessionStore.upsertGroup(_ group: StoredGroup) throws`
  - `SessionStore.dissolveGroup(id: UUID) throws` (removes the group AND ungroups its sessions in ONE write)
  - `SessionStore.all()` / `upsert(_:)` / `delete(id:)` unchanged in signature; `all()` returns sessions with orphaned `groupID`s cleaned up.

- [x] **Step 1: write failing tests** — add to `SessionStoreTests.swift` (follow the file's existing suite structure/temp-dir pattern):

```swift
@Test func groupsRoundtripThroughTheStore() throws {
    let store = SessionStore(directory: tempDir)
    let group = StoredGroup(name: "Customers")
    try store.upsertGroup(group)
    let session = StoredSession(name: "web", host: "h", username: "u", groupID: group.id)
    try store.upsert(session)

    #expect(try store.allGroups() == [group])
    #expect(try store.all().first?.groupID == group.id)
}

@Test func legacyPlainArrayFileLoadsWithoutGroups() throws {
    let legacy = """
    [{"authKind":"password","host":"legacy.example","id":"11111111-1111-1111-1111-111111111111",\
    "name":"old","port":22,"username":"tim"}]
    """
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try legacy.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: tempDir)

    #expect(try store.allGroups().isEmpty)
    let sessions = try store.all()
    #expect(sessions.count == 1)
    #expect(sessions.first?.name == "old")
    #expect(sessions.first?.groupID == nil)
}

@Test func dissolveGroupUngroupsItsSessionsInOneWrite() throws {
    let store = SessionStore(directory: tempDir)
    let group = StoredGroup(name: "Temp")
    try store.upsertGroup(group)
    try store.upsert(StoredSession(name: "a", host: "h", username: "u", groupID: group.id))
    try store.dissolveGroup(id: group.id)

    #expect(try store.allGroups().isEmpty)
    #expect(try store.all().first?.groupID == nil)
}

@Test func orphanedGroupIDIsTreatedAsNilOnLoad() throws {
    let store = SessionStore(directory: tempDir)
    try store.upsert(StoredSession(name: "a", host: "h", username: "u", groupID: UUID()))
    #expect(try store.all().first?.groupID == nil)
}

@Test func groupRenamePersistsViaUpsertGroup() throws {
    let store = SessionStore(directory: tempDir)
    var group = StoredGroup(name: "Old")
    try store.upsertGroup(group)
    group.name = "New"
    try store.upsertGroup(group)
    #expect(try store.allGroups() == [group])
    #expect(try store.allGroups().count == 1)
}
```

- [x] **Step 2: run red** — `swift test --filter SessionStore` → FAIL ("cannot find 'StoredGroup'", "extra argument 'groupID'").

- [x] **Step 3: implement**

`StoredGroup.swift` (new):

```swift
import Foundation

/// A flat session group shown as a collapsible sidebar section.
/// Deleting a group DISSOLVES it: member sessions become ungrouped,
/// they are never deleted with the group.
public struct StoredGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
```

`StoredSession.swift`: insert `public var groupID: UUID?` after `keyPath`; the init gets `groupID: UUID? = nil` as the last parameter and assigns it. (Optional → old JSON without the field decodes to `nil`; no custom decoder needed.)

`SessionStore.swift`: private container format + fallback; switch the existing public methods to `load()`/`persist(_:)`:

```swift
/// On-disk container (current format). Legacy files are a bare
/// `[StoredSession]` array — `load()` falls back to that shape, so old
/// installations keep working without a migration step.
private struct StoreFile: Codable {
    var groups: [StoredGroup] = []
    var sessions: [StoredSession] = []
}

private func load() throws -> StoreFile {
    guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
        return StoreFile()
    }
    let data = try Data(contentsOf: fileURL)
    var file: StoreFile
    if let container = try? JSONDecoder().decode(StoreFile.self, from: data) {
        file = container
    } else {
        file = StoreFile(groups: [], sessions: try JSONDecoder().decode([StoredSession].self, from: data))
    }
    // Defensive: a groupID whose group no longer exists behaves like nil.
    let knownIDs = Set(file.groups.map(\.id))
    for index in file.sessions.indices where file.sessions[index].groupID.map({ !knownIDs.contains($0) }) == true {
        file.sessions[index].groupID = nil
    }
    return file
}

private func persist(_ file: StoreFile) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(file).write(to: fileURL, options: .atomic)
}

public func all() throws -> [StoredSession] { try load().sessions }
public func allGroups() throws -> [StoredGroup] { try load().groups }

public func upsert(_ session: StoredSession) throws {
    var file = try load()
    if let index = file.sessions.firstIndex(where: { $0.id == session.id }) {
        file.sessions[index] = session
    } else {
        file.sessions.append(session)
    }
    try persist(file)
}

public func delete(id: UUID) throws {
    var file = try load()
    file.sessions.removeAll { $0.id == id }
    try persist(file)
}

public func upsertGroup(_ group: StoredGroup) throws {
    var file = try load()
    if let index = file.groups.firstIndex(where: { $0.id == group.id }) {
        file.groups[index] = group
    } else {
        file.groups.append(group)
    }
    try persist(file)
}

public func dissolveGroup(id: UUID) throws {
    var file = try load()
    file.groups.removeAll { $0.id == id }
    for index in file.sessions.indices where file.sessions[index].groupID == id {
        file.sessions[index].groupID = nil
    }
    try persist(file)
}
```

Important: a `try?` decode of `StoreFile` also does NOT accept `[]` (array ≠ object) — that is exactly why the fallback works. `Note:` an empty array `[]` decodes as `[StoredSession]` ✓.

- [x] **Step 4: run green** — `swift test --filter SessionStore` PASS, then `swift test` fully PASS (existing `StoredSessionCompatTests` must stay green unchanged).

- [x] **Step 5: commit** — `git add -A && git commit -m "feat: add flat session groups to the session store"` (+ footer).

---

### Task 2: SessionListViewModel — group CRUD + update semantics (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Modify: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` ONLY if new `core.*` error texts are needed (pattern: existing `core.session.*` keys; for group errors `core.session.groupSaveFailed %@` EN "Could not save group: %@" / DE "Gruppe konnte nicht gespeichert werden: %@")
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (extend; `InMemorySecretStore` already exists there as a helper)

**Interfaces:**
- Consumes: Task 1 API (`StoredGroup`, `allGroups`, `upsertGroup`, `dissolveGroup`, `groupID`).
- Produces:
  - `public private(set) var groups: [StoredGroup]` (creation order, NOT sorted)
  - `public func sessions(inGroup groupID: UUID?) -> [StoredSession]`
  - `public func renameSession(_ session: StoredSession, to newName: String)` (trims; empty = no-op)
  - `public func updateSession(_ updated: StoredSession, newSecret: String?)` — `nil` OR empty = the keychain secret stays; non-empty = `savePassword` overwrites
  - `@discardableResult public func createGroup(named name: String) -> StoredGroup?` (trims; empty → nil, nothing created)
  - `public func renameGroup(_ group: StoredGroup, to newName: String)` (trims; empty = no-op)
  - `public func dissolveGroup(_ group: StoredGroup)`
  - `public func moveSession(_ session: StoredSession, toGroup groupID: UUID?)`
  - `save(name:host:port:username:password:authKind:keyPath:groupID:)` — existing method + `groupID: UUID? = nil`; when updating via name match, does an existing group assignment survive if the `groupID` argument is `nil`? NO — decision: the argument ALWAYS wins (explicit choice in the form; the picker is visible when saving and `nil` there means "No group").

- [x] **Step 1: failing tests** (excerpt — all in `SessionListViewModelTests.swift`; follow the file's setup pattern):

```swift
@Test @MainActor func groupCRUDRoundtrip() throws {
    let vm = makeViewModel() // existing helper pattern: temp store + InMemorySecretStore
    let group = vm.createGroup(named: "  Customers ")
    #expect(group?.name == "Customers")
    #expect(vm.groups.map(\.name) == ["Customers"])

    vm.renameGroup(group!, to: "Clients")
    #expect(vm.groups.map(\.name) == ["Clients"])

    #expect(vm.createGroup(named: "   ") == nil)
    #expect(vm.groups.count == 1)
}

@Test @MainActor func dissolveKeepsSessionsAndUngroupsThem() throws {
    let vm = makeViewModel()
    let group = vm.createGroup(named: "G")!
    let stored = vm.save(name: "s", host: "h", port: 22, username: "u",
                         password: "pw", groupID: group.id)!
    vm.dissolveGroup(group)
    #expect(vm.groups.isEmpty)
    #expect(vm.sessions.count == 1)
    #expect(vm.sessions.first?.groupID == nil)
    #expect(vm.password(for: stored) == "pw") // secret untouched
}

@Test @MainActor func moveAndFilterByGroup() throws {
    let vm = makeViewModel()
    let group = vm.createGroup(named: "G")!
    let stored = vm.save(name: "s", host: "h", port: 22, username: "u", password: "pw")!
    vm.moveSession(stored, toGroup: group.id)
    #expect(vm.sessions(inGroup: group.id).map(\.name) == ["s"])
    #expect(vm.sessions(inGroup: nil).isEmpty)
}

@Test @MainActor func renameSessionTrimsAndRejectsEmpty() throws {
    let vm = makeViewModel()
    let stored = vm.save(name: "old", host: "h", port: 22, username: "u", password: "pw")!
    vm.renameSession(stored, to: "  new ")
    #expect(vm.sessions.first?.name == "new")
    vm.renameSession(vm.sessions.first!, to: "   ")
    #expect(vm.sessions.first?.name == "new")
}

@Test @MainActor func updateSessionKeepsSecretWhenNewSecretIsNilOrEmpty() throws {
    let vm = makeViewModel()
    let stored = vm.save(name: "s", host: "h", port: 22, username: "u", password: "keep")!
    var updated = stored
    updated.host = "h2"
    vm.updateSession(updated, newSecret: nil)
    #expect(vm.password(for: stored) == "keep")
    vm.updateSession(updated, newSecret: "")
    #expect(vm.password(for: stored) == "keep")
    vm.updateSession(updated, newSecret: "next")
    #expect(vm.password(for: stored) == "next")
    #expect(vm.sessions.first?.host == "h2")
}
```

- [x] **Step 2: red** — `swift test --filter SessionListViewModel` → FAIL (unknown methods).

- [x] **Step 3: implement** — all methods follow the file's existing do/catch-reload-errorMessage pattern; `reload()` additionally loads `groups = try store.allGroups()` (unsorted). Core pieces:

```swift
public func sessions(inGroup groupID: UUID?) -> [StoredSession] {
    sessions.filter { $0.groupID == groupID }
}

public func renameSession(_ session: StoredSession, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var updated = session
    updated.name = trimmed
    updateSession(updated, newSecret: nil)
}

public func updateSession(_ updated: StoredSession, newSecret: String?) {
    do {
        try store.upsert(updated)
        if let newSecret, !newSecret.isEmpty {
            try secrets.savePassword(newSecret, for: updated.id)
        }
        reload()
    } catch {
        reload()
        errorMessage = String(
            format: CoreL10n.string("core.session.saveFailed %@"), String(describing: error))
    }
}

@discardableResult
public func createGroup(named name: String) -> StoredGroup? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let group = StoredGroup(name: trimmed)
    do { try store.upsertGroup(group); reload(); return group }
    catch {
        reload()
        errorMessage = String(
            format: CoreL10n.string("core.session.groupSaveFailed %@"), String(describing: error))
        return nil
    }
}
```

`renameGroup`/`dissolveGroup`/`moveSession` analogously (`moveSession`: a copy with `groupID` set → `updateSession(_, newSecret: nil)`). `save(...)` gets `groupID: UUID? = nil` and sets it in both branches (update + create).

- [x] **Step 4: green** — `swift test --filter SessionListViewModel`, then the full `swift test`.
- [x] **Step 5: commit** — `feat: add group CRUD and secret-preserving updates to the session list`.

---

### Task 3: sidebar — groups, context menus, inline rename, drag-and-drop, CI look (app)

**Files:**
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (extensive body rebuild)
- Modify: `Sources/MacSCPApp/ContentView.swift:181-198` (new callback `onEdit`)
- Modify: `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings` (new keys, see below)
- Test: no unit test (pure SwiftUI view; logic lives in T2) — verification via the T6 smoke test.

**Interfaces:**
- Consumes: the full T2 API; `DesignTokens.remoteBlue`, `DesignTokens.statusPhosphor`.
- Produces: `SessionSidebar` with an additional parameter `onEdit: (StoredSession) -> Void`; ContentView passes it through (T4 implements the handler; T3 wires it provisionally with `{ _ in }` and a `// wired in M5f/T4` comment, so T3 stays independently buildable).

Behavior (from the spec, binding):
- Order: "SESSIONS" label → ungrouped (`viewModel.sessions(inGroup: nil)`) → per group (creation order) a collapsible section → "IMPORTED" section unchanged.
- Collapse state: `@State private var collapsedGroups: Set<UUID> = []` (not persisted).
- Session context menu: Connect (`onSelect`) · Edit… (`onEdit`) · Rename (starts inline edit) · "Move to" as a `Menu` with: "No group" (only when grouped), all groups (checkmark/disabled for the current one), a divider, "New group…" (creates via alert and then moves) · Delete (role: .destructive → `confirmationDialog`).
- Delete confirmation (`confirmationDialog`): title with the session name, text mentions keychain deletion, destructive confirm button.
- Group header context menu: Rename (inline) · Dissolve (`dissolveGroup`).
- Background context menu (`.contextMenu` on the list/empty area): New connection (`onNew`) · New group….
- "New group…": `.alert` with a `TextField` (confirming calls `createGroup`; an empty name creates nothing — the VM guard is enough, the alert can simply close).
- Inline rename (session AND group): `@State private var renamingID: UUID?` + `@State private var renameDraft: String = ""` + `@FocusState`; the row shows a `TextField` instead of `Text`, `.onSubmit` commits (`renameSession`/`renameGroup`), Escape (`.onExitCommand`) and losing focus both abort (no silent commit).
- Drag-and-drop: session row `.draggable(session.id.uuidString)`; group header `.dropDestination(for: String.self)` → `moveSession(toGroup: group.id)`; the "SESSIONS" label likewise with `toGroup: nil`. (String payload is enough; parse the UUID from the string, ignore unknown IDs.)
- Look: active session `.background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.remoteBlue.opacity(0.12)))` + `.fontWeight(.semibold)` + `.foregroundStyle(DesignTokens.remoteBlue)`; phosphor dot as before; hover state via an `.onHover` state with a `Color.secondary.opacity(0.08)` background; section labels `.font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)` + `.textCase(.uppercase)` behavior via already-uppercase catalog text.
- `interactionsDisabled` stays on the overall container.

New L10n keys (EN → DE), in BOTH catalogs under `/* Session manager (M5f) */`:

```
"sidebar.connect" = "Connect"; / "Verbinden";
"sidebar.edit" = "Edit…"; / "Bearbeiten…";
"sidebar.rename" = "Rename"; / "Umbenennen";
"sidebar.moveTo" = "Move to"; / "Verschieben nach";
"sidebar.noGroup" = "No group"; / "Keine Gruppe";
"sidebar.newGroup" = "New group…"; / "Neue Gruppe…";
"sidebar.newGroup.title" = "New group"; / "Neue Gruppe";
"sidebar.newGroup.placeholder" = "Group name"; / "Gruppenname";
"sidebar.newGroup.create" = "Create"; / "Anlegen";
"sidebar.group.dissolve" = "Dissolve group"; / "Gruppe auflösen";
"sidebar.delete.confirmTitle %@" = "Delete “%@”?"; / "„%@“ löschen?";
"sidebar.delete.confirmMessage" = "The saved credentials are removed as well."; / "Die gespeicherten Zugangsdaten werden mit entfernt.";
"common.create" = "Create"; / "Anlegen";
```

("sidebar.delete" = "Delete"/"Löschen" already exists.)

- [x] **Step 1: implement** (view rebuild per the spec above; structure guideline):

```swift
List {
    Button(action: onNew) { Label(L10n.string("sidebar.newConnection", "New connection"), systemImage: "plus") }
        .buttonStyle(.plain)

    sessionRows(viewModel.sessions(inGroup: nil))          // ungrouped

    ForEach(viewModel.groups) { group in
        Section(isExpanded: Binding(
            get: { !collapsedGroups.contains(group.id) },
            set: { expanded in
                if expanded { collapsedGroups.remove(group.id) }
                else { collapsedGroups.insert(group.id) }
            }
        )) {
            sessionRows(viewModel.sessions(inGroup: group.id))
        } header: {
            groupHeader(group)   // label + context menu + dropDestination + inline rename
        }
    }

    importedSection  // unchanged, extracted from the existing code
}
```

`sessionRows(_:)` and `groupHeader(_:)` as private `@ViewBuilder` helpers; row content (dot, name/text field, hover, active look, contextMenu, draggable, help) in a private `SessionRow` sub-view, to keep the body readable.

- [x] **Step 2: verify the build** — `swift build` error-free; `swift test` fully green (no Core changes).
- [x] **Step 3: quick manual sanity check** (the coordinator does the full smoke in T6): build and start the app, create a group, move a session via the context menu, inline rename, delete confirmation.
- [x] **Step 4: commit** — `feat: add groups, context menus and CI styling to the session sidebar`.

---

### Task 4: edit mode in the connection form (Core + App)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (`onEdit` handler, save callbacks, group picker data flow, `save(...)` call gets `groupID`)
- Modify: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` + app catalogs (keys below)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (extend)

**Interfaces:**
- Consumes: T2 (`updateSession(_:newSecret:)`, `groups`), T3 (`onEdit` callback slot).
- Produces (ConnectionViewModel):
  - `public enum FormMode: Equatable, Sendable { case new, edit(sessionID: UUID) }`
  - `public private(set) var mode: FormMode = .new`
  - `public var selectedGroupID: UUID?` (applies to new-with-save AND edit)
  - `public func beginEditing(_ stored: StoredSession)` — fills host/port/username/authChoice/keyPath/saveName/selectedGroupID, sets `password = ""` (NEVER loaded from the keychain), `mode = .edit(sessionID: stored.id)`, `state = .idle`
  - `public func endEditing()` — `mode = .new`, form fields back to the initial state (as `teardownSession` leaves them: empty fields, `authChoice = .password`)
  - `public func validateForEditSave() -> StoredSession?` — validates host/port(numeric)/username/name (password may be empty; for `.privateKey`, keyPath must be set); on success returns the assembled `StoredSession` with the `sessionID` from the mode and `groupID = selectedGroupID`; on error it sets `state = .failed(...)` with the same `core.connect.*` messages as `connect()` and returns `nil`.

Behavior:
- ContentView `onEdit(stored)`: like `connectStored`, first `await teardownSession()` (the detail pane becomes the form), then `connectionViewModel.beginEditing(stored)`. No auto-connect.
- FormView in edit mode (`case .edit = viewModel.mode`):
  - Title `connection.editTitle` ("Edit session" / "Session bearbeiten").
  - Password/passphrase field: placeholder `connection.field.password.unchanged` ("unchanged" / "unverändert"); field empty on entry.
  - Save toggle + session name field: toggle hidden, name field always visible (label `connection.field.saveName`).
  - Group picker (`connection.field.group` "Group"/"Gruppe"): options "No group" (`sidebar.noGroup`, tag `UUID?.none`) + all `groups` (parameter `groups: [StoredGroup]`, passed from ContentView as `sessionListViewModel.groups`). The same picker appears in new mode as soon as `shouldSaveSession == true`.
  - Buttons: **Back** (`common.back`, calls `onCancelEdit`) · **Save** (`common.save` "Save"/"Speichern", calls `onSaveEdited(session, newSecret)`) · **Save & connect** (`connection.saveAndConnect` "Save & connect"/"Speichern & verbinden", `.keyboardShortcut(.defaultAction)`, prominent button).
  - `newSecret` rule for the callback: `viewModel.password.isEmpty ? nil : viewModel.password`.
- New FormView parameters: `groups: [StoredGroup]`, `onSaveEdited: (StoredSession, String?) -> Void`, `onCancelEdit: () -> Void` (with default values `[]`/no-ops, so T3 callers don't break).
- ContentView handlers:
  - `onSaveEdited`: `sessionListViewModel.updateSession(session, newSecret: secret); connectionViewModel.endEditing()`
  - "Save & connect": the FormView calls `onSaveEdited` followed by `onConnectEdited(session)`; ContentView implements `onConnectEdited` as `connectStored(session)` (loads the secret from the keychain — automatically covers "empty = unchanged"). Callback signature: `onConnectEdited: (StoredSession) -> Void = { _ in }`.
  - `startSession` save block (ContentView:449-467): add `groupID: connectionViewModel.selectedGroupID`.
- Edit mode shows NO connect button and no TOFU-prompt branch (that only exists in the connect path; `hostKeyPrompt` stays nil in edit mode, because a connection is never made — no special handling needed).

New keys: `connection.editTitle`, `connection.field.password.unchanged`, `connection.field.group`, `connection.saveAndConnect`, `common.save` (EN/DE as above) — app catalog; no new Core keys (validation reuses existing `core.connect.*`).

- [x] **Step 1: failing tests** (`ConnectionViewModelTests.swift`):

```swift
@Test @MainActor func beginEditingPrefillsEverythingExceptTheSecret() {
    let vm = makeViewModel() // existing helper/connector stub pattern of the file
    let stored = StoredSession(name: "web", host: "h", port: 2222, username: "u",
                               authKind: .privateKey, keyPath: "/k", groupID: UUID())
    vm.password = "leftover"
    vm.beginEditing(stored)

    #expect(vm.mode == .edit(sessionID: stored.id))
    #expect(vm.host == "h" && vm.port == "2222" && vm.username == "u")
    #expect(vm.saveName == "web" && vm.keyPath == "/k")
    #expect(vm.authChoice == .privateKey)
    #expect(vm.selectedGroupID == stored.groupID)
    #expect(vm.password.isEmpty) // never loaded from the keychain
}

@Test @MainActor func validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession() {
    let vm = makeViewModel()
    let stored = StoredSession(name: "web", host: "h", username: "u")
    vm.beginEditing(stored)
    vm.host = "new.example"

    let result = vm.validateForEditSave()
    #expect(result?.id == stored.id)
    #expect(result?.host == "new.example")
    #expect(vm.state == .idle)
}

@Test @MainActor func validateForEditSaveRejectsInvalidPort() {
    let vm = makeViewModel()
    vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
    vm.port = "abc"
    #expect(vm.validateForEditSave() == nil)
    #expect(vm.state == .failed(message: CoreL10n.string("core.connect.portNumeric"), field: .port))
}

@Test @MainActor func endEditingReturnsToNewMode() {
    let vm = makeViewModel()
    vm.beginEditing(StoredSession(name: "web", host: "h", username: "u"))
    vm.endEditing()
    #expect(vm.mode == .new)
    #expect(vm.host.isEmpty && vm.saveName.isEmpty)
}
```

- [x] **Step 2: red** — `swift test --filter ConnectionViewModel` → FAIL.
- [x] **Step 3: implement Core** (mode/beginEditing/endEditing/validateForEditSave per the interface above; the validation order and messages are identical to `connect()`: host empty → `.host`, port not numeric → `.port`, username empty → `.username`, name empty → `.saveName`, for `.privateKey` an empty keyPath → `.keyPath`).
- [x] **Step 4: green** — the filtered suite, then the full `swift test`.
- [x] **Step 5: implement the app part** (FormView branches + ContentView handlers + catalogs per the spec above) and verify `swift build`.
- [x] **Step 6: commit** — `feat: add edit mode for stored sessions to the connection form`.

---

### Task 5: toolbar, window title, global tint, form proportions (App)

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift:229-250` (header HStack → `.toolbar`), `:181-207` (tint), `startSession`/`teardownSession` (window title)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (tint on the settings scene)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (prominent primary button)
- Test: no unit test (pure presentation) — verification in T6.

**Interfaces:**
- Consumes: `DesignTokens.remoteBlue`; the existing `WindowAccessor` (`window` state in ContentView); `connectionViewModel.saveName`/`username`/`host`.
- Produces: no new APIs.

Behavior:
- Header row (ContentView:233-249) is removed; instead, on the `detail` container:

```swift
.toolbar {
    if let session {
        ToolbarItemGroup(placement: .primaryAction) {
            uploadButton(session)      // existing builders, unchanged semantics
            downloadButton(session)
            Button { session.terminal.toggle() } label: {
                Label(L10n.string("browser.terminalToggle", "Terminal"), systemImage: "terminal")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help(L10n.string("browser.terminalToggleHelp", "Show/hide terminal (⌘T)"))
            Button(L10n.string("browser.disconnect", "Disconnect")) { disconnectToForm() }
                .disabled(transferQueue.isActive)
        }
    }
}
```

  (Placed on the outer `HSplitView` container in `body`, so the toolbar belongs to the window; `if let session` keeps it empty in the disconnected state.)
- Window title: in `startSession`, after the save block, `window?.title = "macSCP — " + (activeSessionName ?? "\(connectionViewModel.username)@\(connectionViewModel.host)")`, where `activeSessionName` is the saved name (`connectionViewModel.saveName`, if not empty); in `teardownSession` back to `window?.title = "macSCP"`. The title is pure window chrome (product name "macSCP" + payload data) — no catalog key needed.
- Global tint: `.tint(DesignTokens.remoteBlue)` on the root container in `ContentView.body` AND on `SettingsView` in `MacSCPApp.swift`.
- Primary button: in `ConnectionFormView`, "Connect" (new mode) and "Save & connect" (edit mode) get `.buttonStyle(.borderedProminent)` (color comes from the tint). The remaining buttons stay standard.
- Form proportions: limit the `Form` block to `.frame(maxWidth: 460)` and keep the surrounding VStack horizontally centered as before (mockup proportion ~420–460 pt); alert/highlight behavior from the design review fix (6e03c7a) untouched.
- CI guard: upload/download button labels keep their semantic colors (existing builders unchanged); the blue tint must not override amber elements (TransferQueueBar sets its colors explicitly — verify no `.tint` inheritance overrides them; if it does, counter it explicitly there).

- [x] **Step 1: implement** per the spec.
- [x] **Step 2: build + full suite** — `swift build`, `swift test` green.
- [x] **Step 3: commit** — `feat: move session actions into a native toolbar and adopt the CI accent`.

---

### Task 6: completion verification

- [x] `swift test` overall; bring the rig up (`docker compose -f docker/test-server/compose.yml up -d`, ONLY from the main checkout), `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` fully green.
- [x] **Legacy-file compatibility, for real:** back up the existing `~/Library/Application Support/macSCP/sessions.json`; start the app → existing sessions appear; create a group → the file is now in container format; restart the app → everything still there.
- [x] **Visual smoke (screen free):**
  - Sidebar: create a "Customers" group (background context menu), place a session via "Move to", drag it back out again; collapse the group; inline-rename both a session AND a group (Enter commits, Escape aborts); delete shows a confirmation with the name; the active session is highlighted blue with a phosphor dot.
  - Edit roundtrip: create a session (connect with "Save as session", group selectable in the picker) → disconnect → context menu "Edit…" → form prefilled, password field empty with "unchanged" → change the host, leave the password EMPTY → "Save & connect" → the connection succeeds (proves: the secret was preserved) → edit again, type a wrong password → save → connecting fails with an auth error (proves: the secret was overwritten) → correct it.
  - Toolbar/title: connected shows "macSCP — ‹Name›" + toolbar actions; disconnected shows "macSCP" with no items; ⌘T still works.
  - Colors: Connect/Save & connect prominent in ocean blue; pane badges stay amber/blue; the transfer bar unchanged duo colors; spot-check DE + EN (one view with `-AppleLanguages '(en)'`).
- [x] Check off the checkboxes in the plan, commit `docs: mark M5f plan tasks as completed` (+ footer).

## Outlook

Next up: M6 — release (icon, DMG with lproj markers + SPM bundles, README, polish backlog from the ledger).
