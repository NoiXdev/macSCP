# M10a — Known Hosts Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** View and manage all host keys remembered via TOFU (table, search, copy fingerprint, remove with confirmation) — reachable via a new "Sessions" menu (⌘⇧K), the sidebar background menu, and a TOFU prompt footnote.

**Architecture:** `KnownHostKey.addedAt: Date?` (decode-compatible via the existing normalizing custom decoder) + `allKeys()`/`remove(host:port:)` in the store (Core, TDD); `KnownHostsSheet` exactly per mockup; the new "Sessions" menu via the existing `TabCommands` bridge.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI, NSPasteboard.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m10a-known-hosts-design.md` — binding. Mockup: `docs/design/assets/m10-mockups.html` sections 1+4. Branch: **develop**.
- TOFU INVARIANTS UNTOUCHED: find/upsert/validator unchanged, mismatch remains a hard stop; NO editing/adding entries — `remove` is the only new write path.
- `addedAt` optional + decode-compatible (`decodeIfPresent`; legacy reads nil ⇒ display "—"); the custom decoder remains the ONLY decode path (M3d rule); `upsert` stamps `Date()` on replacement too.
- All new UI text EN/DE; code + comments ONLY English; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 470 tests / 37 suites); gated suites only in T3; tests SYNCHRONOUS in the foreground.
- TDD for Core; App target untestable → T2 delivers a build + behavior description.

## Schedule

T1 (Core: addedAt + allKeys + remove) → T2 (App: sheet + Sessions menu + sidebar + TOFU footnote) → T3 wrap-up (coordinator).

---

### Task 1: addedAt + allKeys + remove (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/KnownHostsStore.swift`
- Test: `Tests/macSCPCoreTests/KnownHostsStoreTests.swift` (existing file — follow its pattern)

**Interfaces:**
- Produces (T2 relies on this exactly):
  - `KnownHostKey.addedAt: Date?` (public let; init parameter with default `Date()`; decoder `decodeIfPresent`)
  - `KnownHostsStore.allKeys() throws -> [KnownHostKey]` (sorted host, then port)
  - `KnownHostsStore.remove(host: String, port: Int) throws` (lowercased match; no-op when absent; persisted atomically)

- [x] **Step 1: Failing tests** (in `KnownHostsStoreTests.swift`, following the file's fixture pattern — reuse temp directory + example keys):

```swift
    // allKeysListsSorted: three upserts (b.example:22, a.example:2222, a.example:22)
    //   -> allKeys() returns [a.example:22, a.example:2222, b.example:22].
    // removeDeletesExactMatchOnly: upsert a:22 + a:2222; remove(host:"A.EXAMPLE",
    //   port:22) -> allKeys() contains only a:2222 (case-insensitive via
    //   lowercased match); remove(host:"missing", port:9) does not throw, changes
    //   nothing.
    // upsertStampsAddedAt: fresh upsert -> allKeys().first?.addedAt != nil;
    //   second upsert of the same host with a different key blob -> addedAt
    //   re-stamped (>= first value; avoid a simple nil check + inequality via
    //   an injected sleep — instead: remember the first addedAt, briefly
    //   Task.sleep(50ms), upsert again, #expect(newer > older)).
    // legacyEntriesReadWithNilAddedAt: write raw JSON WITHOUT the addedAt field
    //   directly into known_hosts.json (matching the file's format) ->
    //   allKeys().first?.addedAt == nil; fingerprintSHA256 still derivable.
    // roundtripKeepsAddedAt: upsert -> new store object on the same
    //   directory -> addedAt survives (Codable roundtrip).
```

- [x] **Step 2: Prove red.** `swift test --filter KnownHostsStoreTests` → FAIL.

- [x] **Step 3: Implementation.**

```swift
    // In KnownHostKey:
    /// When this key was last trusted (TOFU accept or re-accept). Optional
    /// for decode compatibility: entries written before M10a read as nil
    /// (the UI shows an em dash).
    public let addedAt: Date?

    public init(host: String, port: Int, keyType: String,
                publicKeyBase64: String, addedAt: Date? = Date()) { … }

    // Decoder: pass addedAt via container.decodeIfPresent(Date.self, forKey: .addedAt)
    // through the normalizing init; add .addedAt to CodingKeys.

    // In KnownHostsStore:
    /// All remembered keys, host-then-port sorted — the management sheet's
    /// data source (M10a).
    public func allKeys() throws -> [KnownHostKey] {
        try all().sorted {
            $0.host == $1.host ? $0.port < $1.port : $0.host < $1.host
        }
    }

    /// Forgets a host key (M10a): the host becomes UNKNOWN again — the next
    /// connect runs the normal TOFU prompt. This is the only mutation the
    /// management UI offers; fingerprints are never editable.
    public func remove(host: String, port: Int) throws {
        var keys = try all()
        keys.removeAll { $0.host == host.lowercased() && $0.port == port }
        try persist(keys)
    }
```

  Leave `upsert` unchanged (the init default does the stamping) — BUT check where `KnownHostKey` is constructed in the TOFU validator (grep `KnownHostKey(`): existing callers keep compiling via the default; none may set `addedAt: nil` explicitly.

- [x] **Step 4: Green + full suite.** `swift test` → 470 + 5 (record the actual number).

- [x] **Step 5: Commit.** `feat: list, date and remove known host keys`

---

### Task 2: Sheet + Sessions menu + sidebar + TOFU footnote (App)

**Files:**
- Create: `Sources/MacSCPApp/KnownHostsSheet.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Sessions menu), `Sources/MacSCPApp/ContentView.swift` (sheet state + TabCommands closure + sidebar callback), `Sources/MacSCPApp/SessionSidebar.swift` (background menu entry), `Sources/MacSCPApp/ConnectionFormView.swift` (TOFU prompt footnote), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (App target; smoke in T3)

**Interfaces:**
- Consumes: `allKeys()`/`remove(host:port:)`/`addedAt` (T1), `KnownHostsStore(directory: SessionStore.defaultDirectory)` (the same location the connector in ContentView uses it from — look it up), `TabCommands` bridge (M8a; extend with a closure `showKnownHosts: (() -> Void)?`), sidebar callback pattern, TOFU prompt view in `ConnectionFormView` (the trust decision from M3c — find the spot).

**Behavior requirements (Spec §2/§3, binding):**
1. `KnownHostsSheet(store:)` per mockup section 1 (~720 pt): table Host/Port/key-type badge/fingerprint (monospaced, inkSecondary)/Added (`dd.MM.yyyy`, "—" when nil); multi-selection (SwiftUI `Table` with `selection: Set<…>` OR List — document the choice); case-insensitive search over host+fingerprint; footer counter ("%lld Hosts" / "%lld of %lld"), "Copy Fingerprint" (single selection; `NSPasteboard.general.clearContents()` + `setString`), "Remove…" (destructive, confirmationDialog: EN "The host will be treated as unknown on the next connect (new trust prompt)." / DE „Beim nächsten Verbinden wird der Host wie ein unbekannter behandelt (neuer Vertrauens-Prompt)."; multi-selection states the count), "Close". Load on onAppear; load error ⇒ red message in the sheet. After remove: reload, clear selection.
2. Sessions menu in `MacSCPApp.commands`: `CommandMenu(L10n.string("menu.sessions", "Sessions"))` with "Known Hosts…" ⌘⇧K (`tabCommands.showKnownHosts?()`, key-window guard like the other entries), divider, "Export All Sessions…" and "Import Sessions…" — the same handlers as the sidebar entries (via new TabCommands closures `exportAllSessions`/`importSessions`, which ContentView binds to the EXISTING handlers; sidebar entries remain unchanged).
3. Sidebar background menu: "Known Hosts…" with a separator above the export/import entries (callback `onShowKnownHosts` following the pattern).
4. TOFU prompt (`ConnectionFormView`, M3c trust view): a subtle footnote/link line "Manage known hosts…"/„Bekannte Hosts verwalten…" under the buttons — opens the sheet OVER the form (own sheet state in ConnectionFormView with direct store access OR callback upward — pick the smaller solution and document it); the prompt stays open and functional.
5. Keys EN/DE (suggested): `menu.sessions`, `menu.knownHosts`, `knownHosts.title`, `knownHosts.search`, `knownHosts.column.host/port/keyType/fingerprint/added`, `knownHosts.count %lld`, `knownHosts.countFiltered %lld %lld`, `knownHosts.copyFingerprint`, `knownHosts.remove`, `knownHosts.remove.title`, `knownHosts.remove.message`, `knownHosts.remove.messageMany %lld`, `knownHosts.remove.confirm`, `knownHosts.empty`, `knownHosts.loadError %@`, `tofu.manageKnownHosts`. Cross-check both catalogs by grep.

- [x] **Step 1:** Sheet. **Step 2:** Menu + TabCommands. **Step 3:** Sidebar + TOFU footnote. **Step 4:** Keys + cross-check. **Step 5:** `swift build` (0 errors, no new warnings) + full `swift test` (T1 state). **Step 6:** Commit `feat: manage known host keys from a dedicated sheet`.

---

### Task 3: Final verification (coordinator)

- [x] Gated suites: 475/475 zero skips (final reviewer repeats independently).
- [ ] Visual smoke test — **delegated to the maintainer** (checklist in the summary).
- [x] Plan checkboxes, ledger, Opus final review ("Ready to merge: Yes" on the first pass; two pre-push polish points followed), push, CI, rig stop, memory, summary.
