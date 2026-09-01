# macSCP M5e — Editor integration + "Open with" settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-clicking a remote file downloads it into a temp directory, opens it in the right app (extension rule → default editor → system association — configurable in the new "Open with" settings tab), and every save automatically uploads it back to the server; cleanup happens on disconnect.

**Architecture:** `SettingsStore` grows `defaultEditorPath` + `fileAssociations` (extension→app path, normalized). New settings tab "Open with" (app selection via a file dialog on `/Applications`, a rule table with add/remove). Core: `EditSessionManager` (@Observable @MainActor) — temp download via the QUEUE (`enqueueAndWait`), a `DispatchSource` file watcher with debounce, auto-upload via the queue with a conflict bypass (writing back IS intended), explicit lifecycle (`stopAll` in teardown, a temp folder per session). App: `EditorResolver` (rule → default → `NSWorkspace` system default) + `NSWorkspace.open(_:withApplicationAt:)`, double-click wiring.

## Global Constraints

- swift-tools 6.0; ALL targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing, TDD red→green.
- LANGUAGE POLICY: comments/identifiers English; new UI strings via `L10n` with an EN source + DE in BOTH `.strings`; `reason:` in English.
- All queue invariants stay (sixth generation!): exactly-once, the cancelAll window, groups, FIFO start, slots, interrupted semantics.
- Edit uploads run as NORMAL queue items (visible in the bar, throttle/parallelism apply), but with a conflict bypass (binding: its own internal `bypassConflictCheck` flag on the job; the existing resume-bypass behavior stays coupled to it unchanged — `resume==true ⇒ bypass`, newly with an additional explicit flag for edit write-backs with `resume:false`).
- Temp files: `FileManager.temporaryDirectory/macscp-edit/<sessionUUID>/<hash(remotePfad)>/<fileName>`; cleanup recursively deletes the session folder (local, FileManager — NOT the remote `delete`).
- NO secrets; settings stay forward-compatible. Gated: `MACSCP_ITEST=1` (rig from the main checkout).
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementers do not push.

**Dependency graph:** `[ T1 (settings store) ∥ T3 (EditSessionManager, RISK) ] → [ T2 (settings tab) ∥ T4 (resolver+wiring) ] → T5 (wrap-up)` — T1 (Settings/) ∥ T3 (Presentation/EditSessionManager + queue flag) file-disjoint; T2 (SettingsView) ∥ T4 (ContentView/EditorResolver) likewise.

---

### Task 1: SettingsStore — default editor + extension rules

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (extend)

**Interfaces (binding for T2/T4):**

```swift
/// Absolute path to the .app bundle used as the default editor for remote
/// files; nil/empty = use the macOS system association. Persisted.
public var defaultEditorPath: String? { get set }

/// Per-extension overrides: normalized extension (lowercase, no leading dot,
/// trimmed) -> absolute .app path. Setting an empty app path removes the rule.
public var fileAssociations: [String: String] { get set }
/// Convenience: association lookup with the SAME normalization applied.
public func associatedApp(forExtension ext: String) -> String?
```

**Binding:** normalization on both set AND read (".PHP"/"php"/" .php " → "php"); empty/whitespace extensions are ignored; persistence roundtrip; forward compatibility stays (unknown keys + the new ones as a JSONValue object/string); defaults nil/[:]. Tests: roundtrip of both fields, normalization, rule removal via an empty path, fixture compatibility (an old settings.json without the new keys loads cleanly; readability of a new file by an old version — simulated via the unknown-key test — continues to pass).

- [x] Red → implement → green → Commit `feat: add default editor and file association settings` (with footer).

---

### Task 2: Settings tab "Open with"

**Files:**
- Modify: `Sources/MacSCPApp/SettingsView.swift`, both `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Binding:**
1. A second tab "Open with"/„Öffnen mit" (symbol `doc.badge.gearshape` or similar), window height may grow (~460×360).
2. Default editor section: shows the chosen app's name (from the path, `FileManager.displayName`) or "System default"/„System-Standard"; buttons "Choose…"/„Auswählen…" (`.fileImporter`, `allowedContentTypes: [.application]`, starting at `/Applications`) and "Reset"/„Zurücksetzen" (→ nil).
3. Rules section: a table/list of `fileAssociations` (sorted by extension): extension | app name | remove button (−). Below it an add row: a text field for the extension (placeholder "php") + a "Choose app…" button → fileImporter → the rule is set with the normalized extension. A duplicate extension overwrites (store semantics).
4. New L10n keys (EN source + DE) for the tab, labels, buttons, placeholder, footnote ("Rules take precedence over the default editor; the system association is the fallback." / „Regeln gehen vor Standard-Editor; System-Zuordnung ist der Fallback.").
5. Verification: build + suite unchanged; headless launch; visual in T5.

- [x] Implement → green → Commit `feat: add open-with settings tab` (with footer).

---

### Task 3: EditSessionManager (Core) — RISK

**Files:**
- Create: `Sources/macSCPCore/Presentation/EditSessionManager.swift`
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (ONLY: an internal `bypassConflictCheck` flag on the job + a public `enqueueEditUpload(...)` method — signature below)
- Test: `Tests/macSCPCoreTests/EditSessionManagerTests.swift`, extend queue tests

**Interfaces (binding for T4):**

```swift
@Observable @MainActor
public final class EditSessionManager {
    public struct ActiveEdit: Identifiable, Equatable {
        public let id: UUID
        public let remotePath: String
        public let localURL: URL
        public let fileName: String
    }
    public private(set) var activeEdits: [ActiveEdit] { get }

    public init(sessionID: UUID, queue: TransferQueueViewModel)

    /// Downloads the remote file into the session temp dir via the queue
    /// (enqueueAndWait), registers a debounced file watcher, and returns the
    /// local URL for the caller to open. Re-invoking for an already-active
    /// remotePath returns the existing local URL (no second download/watcher).
    public func beginEditing(
        remotePath: String, fileName: String,
        source: any RemoteFileSystem, destinationForUploads: any RemoteFileSystem
    ) async throws -> URL

    /// Stops all watchers and deletes the session temp directory. Idempotent.
    public func stopAll() async
}

// TransferQueueViewModel gains:
/// Enqueues an editor write-back: uploads localURL back to remoteDirectory/
/// fileName, BYPASSING the conflict check by design (writing back is the
/// user's explicit intent). Behaves like a normal item otherwise (bar, limits,
/// slots, interrupted classification).
public func enqueueEditUpload(
    fileName: String, localURL: URL,
    source: any RemoteFileSystem, destination: any RemoteFileSystem,
    remoteDirectory: String
) -> UUID
```

**Binding:**
1. Temp layout as in the global constraints; the folder is created on `beginEditing`.
2. Download via `queue.enqueueAndWait` (appears in the bar as a download).
3. Watcher: `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:[.write,.rename,.delete])` on the file; editors do atomic saves (rename-swap!) — binding: after `.rename`/`.delete`, reopen the FD (the file at the same path) and keep watching; debounce 500 ms (several events in a row → ONE upload); every detected change → `enqueueEditUpload`.
4. Watcher callbacks hop onto the MainActor; no retain cycles (the source is held by the manager, cancel in stopAll / no deinit — UI-owned as always, NO deinit cleanup: stopAll is the caller's obligation).
5. `stopAll`: cancel all sources, close FDs, recursively delete the session temp folder; idempotent; running edit uploads in the queue are left untouched (they may still be reading the file — order: stop the watcher first, then delete; an upload of a just-deleted file that is currently running ends as a normal .failed — accepted, document it).
6. Queue flag: `bypassConflictCheck` on the job (internal); `resolveConflictIfNeeded` checks `job.resume || job.bypassConflictCheck`; all existing paths unchanged (flag defaults to false everywhere else).
7. Tests (mock FS, TestSignals, injectable time for the debounce where needed — make the debounce testable via an injectable scheduler/Task.sleep hook): beginEditing downloads via the queue and returns a URL (the file exists locally, content == mock remote); a double beginEditing of the same file → the same URL, no second download (queue item count!); a simulated file change (write locally + a watcher event, or a direct handler call if DispatchSource is too flaky in tests → then cut the event-handler path as a testable internal method and keep the DispatchSource layer thin) → exactly ONE enqueueEditUpload after the debounce (two rapid changes → ONE upload); enqueueEditUpload bypasses the conflict check (the target exists, NO decider call, item finished); stopAll deletes the temp folder + a further change triggers NOTHING any more; an atomic save simulated (rename away + a new file at the path) → the watcher survives and fires.

- [x] Red → implement → green (filter + total) → Commit `feat: add edit session manager with auto-upload` (with footer).

---

### Task 4: EditorResolver + double-click wiring (App)

**Files:**
- Create: `Sources/MacSCPApp/EditorResolver.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/RemoteFileTableView.swift` (only if a double-click-on-file callback is missing — check: double-click on a directory already exists), both `.strings` (error text, see below)

**Binding:**
1. `EditorResolver.applicationURL(forFileName:settings:) -> URL?`: (1) `settings.associatedApp(forExtension:)` of the file's extension → a URL if the path exists; (2) `defaultEditorPath` → a URL if it exists; (3) an `NSWorkspace.shared.urlForApplication(toOpen: localURL)` fallback… ordering detail: the system association needs the LOCAL URL — resolution is therefore two-staged: rule/default resolved beforehand from the file name; the system fallback only after the download, using the local URL; if all of that yields nothing → `NSWorkspace.shared.open(localURL)` (opens with whatever) as the last stage. A configured app path that does not exist → falls through to the next stage + a one-time log entry.
2. `BrowserSession` gets an `editManager: EditSessionManager` (initialized in `startSession` with the session UUID + `transferQueue`); `teardownSession` calls `await editManager.stopAll()` AFTER `cancelAll` and BEFORE `terminal.shutdown` (document the order).
3. Double-click on a remote FILE (kind == .file): `Task { let url = try await editManager.beginEditing(...); then app resolution + NSWorkspace.open([url], withApplicationAt: appURL, configuration:) or the fallback open }`; on error → a subtle red message following the existing pattern (new L10n key `edit.openFailed` EN "Could not open file for editing: %@" / DE „Datei konnte nicht zum Bearbeiten geöffnet werden: %@").
4. Symlinks/directories: unchanged behavior (dir = cd; symlink = nothing).
5. Build + suite green; headless launch.

- [x] Implement → green → Commit `feat: open remote files in the configured editor` (with footer).

---

### Task 5: Final verification

- [x] `swift test` overall; rig up, `MACSCP_ITEST=1` full, `MACSCP_KEYCHAIN=1` 2/2.
- [x] **Visual edit roundtrip (free screen):** in Settings "Open with": set up a `txt` rule → TextEdit; create a `.txt` remotely (docker exec), double-click → a download item appears in the bar → TextEdit opens the file; change the text + ⌘S → an upload item automatically appears in the bar → `docker exec cat` shows the change; a SECOND save → again exactly one upload. Default-editor case (remove the rule, set the default to e.g. TextEdit, double-click a `.conf` file → opens in TextEdit). System-fallback case (reset the default, `.txt` → opens in the system editor). Disconnect → the temp folder is gone (`ls /tmp/...macscp-edit/`), the TextEdit document stays open (documented as OK), saving again triggers nothing more.
- [x] Checkboxes, commit `docs: mark M5e plan tasks as completed` (with footer).

## Outlook

After this, M6 — release: app icon (variant A), lproj markers + SPM bundles in the .app, a notarized DMG, README/docs (EN, without stack terms), the polish backlog (global throttle bucket, applyToAll recheck, sheet default action, wiring/removing core.transfer.interrupted, the delete consumer's partial-file cleanup, auto-reconnect backoff evaluation).
