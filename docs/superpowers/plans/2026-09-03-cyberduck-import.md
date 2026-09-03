# Cyberduck Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** File → Import → "From Cyberduck…" reads Cyberduck's bookmark
folder, shows every bookmark in a preview with a checkbox and a status
(new / known unchanged / known changed with the field diff / not
supported), and imports or updates the selected ones through the
existing import planner; imported sessions carry their provenance so a
later run recognises them. Spec:
`docs/superpowers/specs/2026-09-03-cyberduck-import-design.md`
(approved 2026-09-03).

**Architecture:** Core `Sessions/ExternalImport/`: `BookmarkSource`
(protocol, two methods), `ExternalBookmark`, `CyberduckBookmarkSource`
(plist parsing), `ImportPreviewPlanner` (pure: bookmarks × store ×
switches → rows; rows → `SessionExportPayload` with `replacesExisting`),
`CyberduckSecretReader` (keychain, optional). `StoredSession` and
`ExportedSession` gain `importSource`, `importID`, `importedAt`. App:
one sheet, one view model, one menu entry; the result flows into the
existing `applyImport`.

**Tech Stack:** Swift 6, `PropertyListSerialization`, Security.framework
(`SecItemCopyMatching`), Swift Testing; keychain tests gated
`MACSCP_KEYCHAIN=1`.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No test reads the maintainer's real Cyberduck folder or keychain items; the default-folder locator is tested against an injected home directory; keychain tests write their own item under Cyberduck's shape and delete it in a `defer`.
- Secrets: never printed, logged, or embedded in an error or a failure message; a secret read from the keychain goes only into the session's own `SecretStore` slot through the existing applier; Bools before expectations in any test that holds a secret value.
- Matching is by `importSource`+`importID` first, then `FieldVocabulary`'s connection key (host case-folded, port, user, kind) — never by name. No second copy of the key: call the vocabulary.
- Every display string through `L10n.string(_:_:)`; four catalogs `en`/`de`/`fr`/`pl` in the App target; German du.
- Guards: negative checks with positive anchors; scanners on `SwiftSource` views (`Tests/macSCPAppKitTests/SwiftSourceStripping.swift`); no symbol spelled that could be read.
- No blocking wait on the cooperative pool; the keychain call runs on a queue and is awaited.
- Additive persistence: the three new fields decode as `nil` when absent (`LegacyStoredSession` convention); no migration writes.

---

### Task 1: Provenance on the record and in the export

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift` (three fields), `SessionExportCodec.swift` (`ExportedSession` carries them), `SessionDuplication.swift` (`copy` drops them), the applier that turns an `ExportedSession` into a `StoredSession` (grep `SessionImportPlanner`/`applyImport` for where `fields` become a record — set the three from the export)
- Test: `Tests/macSCPCoreTests/SessionProvenanceTests.swift`

**Interfaces (produced):**
```swift
extension StoredSession {
    public var importSource: String?   // "cyberduck"; nil for hand-made sessions
    public var importID: String?       // the source's own id (Cyberduck UUID)
    public var importedAt: Date?
}
extension ExportedSession { public var importSource: String?; public var importID: String?; public var importedAt: Date? }
```

- [ ] Red first: a record encoded without the keys decodes with all three `nil`; a record with them round-trips; an export carries them and an import restores them; `SessionDuplication.copy` returns a record with all three `nil`; a legacy JSON fixture (copy an existing one from the tests) still loads.
- [ ] Implement; `swift test`; commit `feat(sessions): a session remembers where it was imported from`.

### Task 2: The bookmark source and Cyberduck's files

**Files:**
- Create: `Sources/macSCPCore/Sessions/ExternalImport/BookmarkSource.swift`, `ExternalBookmark.swift`, `CyberduckBookmarkSource.swift`
- Test: `Tests/macSCPCoreTests/CyberduckBookmarkSourceTests.swift` + fixtures under `Tests/macSCPCoreTests/Fixtures/Cyberduck/*.duck` (written by the task, synthetic hosts: `sftp-key.duck` with `Private Key File`, `sftp-password.duck`, `s3-bucket.duck` with `Path`, `s3-nobucket.duck`, `ftp.duck`, `davs.duck`, `labels.duck` with `Labels`, `malformed.duck` (not a plist), `noname.duck` without `Nickname`)

**Interfaces (produced):**
```swift
public protocol BookmarkSource: Sendable {
    static var id: String { get }                      // "cyberduck"
    static var displayNameKey: String { get }          // catalog key for the source's name
    func locate(home: URL) -> URL?                     // the default folder if it exists
    func read(from folder: URL) throws -> [ExternalBookmark]
}
public enum ExternalProtocol: Sendable, Equatable { case sftp, s3, unsupported(String) }
public struct ExternalBookmark: Sendable, Equatable, Identifiable {
    public let id: String            // externalID
    public let source: String
    public let nickname: String?
    public let `protocol`: ExternalProtocol
    public let host: String
    public let port: Int?
    public let username: String?
    public let keyPath: String?
    public let path: String?         // S3 bucket (may be empty)
    public let labels: [String]
    public let fileName: String
    public let unreadable: String?   // set instead of the rest for a malformed file (file name + reason)
}
public struct CyberduckBookmarkSource: BookmarkSource { public init() }
```
`locate(home:)` returns `home/Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks` when it exists. `read` parses every `*.duck` with `PropertyListSerialization`; `Protocol` `sftp` → `.sftp`, `s3` → `.s3`, anything else → `.unsupported(name)`; `Port` parsed as Int; missing `Nickname` → nil (the planner falls back to the host); a file that fails to parse yields an `ExternalBookmark` with `unreadable` set and the file name as `id`.

- [ ] Red first against the fixtures (every field per fixture; the malformed one; sort order = nickname then host); `locate` against a temp home with and without the folder; commit `feat(import): a bookmark source reads Cyberduck's files`.

### Task 3: The preview planner

**Files:**
- Create: `Sources/macSCPCore/Sessions/ExternalImport/ImportPreviewPlanner.swift`
- Test: `Tests/macSCPCoreTests/ImportPreviewPlannerTests.swift`

**Interfaces (produced):**
```swift
public struct ImportSwitches: Sendable, Equatable { public var takeSecrets: Bool; public var takeLabelsAsTags: Bool; public var groupID: UUID?; public var createGroupNamed: String? }
public struct FieldChange: Sendable, Equatable { public let field: String; public let old: String; public let new: String }   // field = catalog key of the field name
public enum PreviewStatus: Sendable, Equatable { case new, knownUnchanged(UUID), knownChanged(UUID, [FieldChange]), unsupported(String), unreadable(String) }
public struct PreviewRow: Sendable, Equatable, Identifiable { public let id: String; public let bookmark: ExternalBookmark; public let status: PreviewStatus; public var selected: Bool }
public enum ImportPreviewPlanner {
    public static func preview(_ bookmarks: [ExternalBookmark], against sessions: [StoredSession], switches: ImportSwitches) -> [PreviewRow]
    public static func payload(for rows: [PreviewRow], sessions: [StoredSession], switches: ImportSwitches) -> SessionExportPayload   // selected rows only
}
```
Defaults: `.new` selected; `.knownChanged` selected; `.knownUnchanged` unselected; `.unsupported`/`.unreadable` unselected and not selectable. Matching order: `importSource == "cyberduck" && importID == bookmark.id`, else `FieldVocabulary`'s connection key over the sessions of the bookmark's kind. Change list: host, port, username, keyPath, bucket/endpoint, nickname; labels only when `takeLabelsAsTags`. `payload(for:)` builds `ExportedSession`s: for `.knownChanged` the stored record's id and `replaces: <that id>` (a new optional on `ExportedSession` the downstream planner honours: replace by id, no arbiter question), the Cyberduck-known fields — including the nickname as the name — written over the record, group/position/pane visibility copied from the store, tags replaced only with the switch, secrets only with theirs; the payload's `groups` carry every group the rows reference (the function takes the group catalogue); (corrected 2026-09-03 after Task 3 measured that `replacesExisting` did not exist on the export type and that the maintainer's decision overwrites the name); for `.new` a fresh id, `groupID` from the switches, `importSource`/`importID`/`importedAt` set on both kinds. S3 mapping per the spec §3 (`s3.amazonaws.com` → AWS default; else custom endpoint host:port; empty `Path` → bucket-list mode).

- [ ] Red first: the three match outcomes; a changed nickname alone is `.knownChanged` and is never a match criterion; the labels switch moves `labels` in/out of the change list; the payload keeps the store's name/group/notes/colour on an update, replaces tags only with the switch, marks `replacesExisting`, sets provenance on new and updated; unsupported and unreadable rows are never in the payload. Commit `feat(import): the preview planner tells new from known and changed`.

### Task 4: Secrets from Cyberduck's keychain items

**Files:**
- Create: `Sources/macSCPCore/Sessions/ExternalImport/CyberduckSecretReader.swift`
- Test: `Tests/macSCPCoreTests/CyberduckSecretReaderTests.swift` (gated `MACSCP_KEYCHAIN=1`)

```swift
public struct CyberduckSecretReader: Sendable {
    public init()
    /// The Internet-password item Cyberduck stores for a bookmark (server = host, account = username, port, protocol sftp → kSecProtocolTypeSSH, s3 → kSecProtocolTypeHTTPS); nil when absent or refused. Runs on its own queue; the macOS consent prompt belongs to the caller's UI moment.
    public func secret(for bookmark: ExternalBookmark) async -> String?
}
```
- [ ] Red first (gated): write an item under Cyberduck's shape with `SecItemAdd`, read it back through the reader, delete in a `defer`; a bookmark without a username yields nil without a query; the secret value never appears in any failure text (Bools first). Commit `feat(import): Cyberduck's keychain items, read on request`.

### Task 5: The sheet, the menu entry, the switches

**Files:**
- Create: `Sources/MacSCPAppKit/Presentation/ImportFromSourceViewModel.swift` (`@MainActor @Observable`: `load(source:folder:)`, `rows`, `switches`, `summary`, `toggle(row:)`, `selectAll/none`, `payload()`), `Sources/MacSCPAppKit/ImportFromSourceSheet.swift`
- Modify: the File → Import menu (beside `menu.importSessions`), `ContentView+ExportImport.swift` (a `PendingSessionImport` from the sheet's payload goes into the existing `applyImport`; with `takeSecrets` the applier asks `CyberduckSecretReader` per selected row before planning and puts the values on the `ExportedSession.password`), the result alert (one more line: updated count; secrets not read count); four App catalogs (`menu.importFromCyberduck`, the sheet's title/status/switch/summary keys, the field names for the change list)
- Test: `Tests/macSCPAppKitTests/ImportFromSourceViewModelTests.swift` (rows/summary/toggle on a fake source), `ImportFromCyberduckGuardTests.swift` (menu entry wired to the sheet; the sheet renders the four statuses; both switches bound to the view model; no `onAppear` import; positive anchors), catalogs complete (`swift test --filter Localiz`, `GermanAddressForm`)

- [ ] Red first, implement, full suite green, commit `feat(import): import from Cyberduck — preview, selection, update`.

### Task 6: Closeout

- [ ] `docs/BACKLOG.md` row (new: "Cyberduck import", Done with commits; open follow-ups: WebDAV bookmarks after a measurement, FileZilla/Transmit sources), the spec's status line; commit `docs(backlog): Cyberduck import shipped; FileZilla and Transmit are the next sources`.
