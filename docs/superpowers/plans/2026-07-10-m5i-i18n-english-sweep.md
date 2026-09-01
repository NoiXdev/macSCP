# macSCP M5i — i18n & English-Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The complete tree satisfies the language policy from CLAUDE.md: source-code comments English only; ALL user-visible strings go through localization with English as the default and a working German translation (app starts in German → German UI).

**Architecture:** Classic `.lproj` localization instead of `.xcstrings` (SwiftPM processes `en.lproj/Localizable.strings` + `de.lproj/Localizable.strings` natively — the M5c finding: xcstrings gets copied verbatim, never compiled). Two resource bundles: the App target (UI strings) and the Core target (error/status messages that originate in Core: `message(for:)`, ConnectionViewModel validation, host-key warning texts). Both use a bundle helper following the pattern of `SettingsResources` (SwiftPM's generated `Bundle.module` accessor fatalErrors when there's no bundle beside it — the pattern lives in `SettingsView.swift`).

**Tech Stack:** Foundation localization only; no new dependencies.

## Global Constraints

- swift-tools 6.0; ALL targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing.
- NO behavior change other than the language/lookup layer: all 219 tests stay green (adjusted assertions check through the same lookup, never through hardcoded language-literal duplicates).
- The comment sweep is PURELY mechanical: translate meaning 1:1, preserve technical terms/invariant phrasing precisely (e.g. "exactly-once", "hard stop"), NO rewording of logic, no code changes in the same hunk besides the comment.
- Security-critical texts (host-key mismatch warning!) must keep their full sharpness in BOTH languages ("Möglicher Man-in-the-Middle" / "Possible man-in-the-middle attack").
- Gated tests: `MACSCP_ITEST=1` (rig from the main checkout), `MACSCP_KEYCHAIN=1`.
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementers do not push.

**Dependency graph:** `[ T1 (App layer) ∥ T2 (Core layer + tests) ] → T3 (wrap-up)` — file-disjoint except for `Package.swift` (T1 only changes the MacSCPApp block [xcstrings→lproj in the same Resources folder: NO manifest change needed], T2 only adds `resources` to the macSCPCore target — merge is conflict-free, or trivial).

---

### Task 1: App layer — UI strings in `.lproj` (EN/DE) + comments to English

**Files:**
- Create: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`, `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings`
- Delete: `Sources/MacSCPApp/Resources/Localizable.xcstrings`
- Modify: ALL files under `Sources/MacSCPApp/` (strings + comments): `ContentView.swift`, `ConnectionFormView.swift`, `SessionSidebar.swift`, `TransferQueueBar.swift`, `SettingsView.swift`, `SSHTerminalView.swift`, `RemoteFileTableView.swift`, `RemoteFilePromise.swift`, `BrowserPane.swift`, `TransferRateFormatting.swift` (comments only), `DesignTokens.swift`, `MacSCPApp.swift`, `FileListFormatter` consumers if on the App side.

**Binding:**
1. **Inventory first** (document in the report): `grep -n` across all App files for string literals in `Text(`, `Label(`, `Button(`, `.help(`, `placeholder`, `Toggle(`, `TabItem`, alert/sheet texts, window titles. Every user-visible string gets a key.
2. Key convention: flat, prefix-grouped, do NOT use English as the key language — keys are stable identifiers (`connection.title`, `connection.field.host`, `transfers.pending %lld`, `conflict.title`, `conflict.overwrite`, `terminal.ended`, `sidebar.imported`, `settings.tab.transfers`, …). EN `.strings` = default texts (the previous German texts translated sensibly into English), DE `.strings` = the previous German texts.
3. Lookup: one small app-wide helper `L10n.string(_ key:)`/`L10n.text(_ key:)` (rename/generalization of `SettingsResources` — ONE source, `SettingsView` moves along with it). SwiftUI views use `Text(L10n…)`/`String(localized:bundle:)` forms; format strings (e.g. "%lld pending") go through `String(format: L10n.string(…), n)` or `String(localized:)` interpolation.
4. The 5 Settings strings from the xcstrings catalog move 1:1 into the `.strings` files; xcstrings gets deleted. `Package.swift` stays unchanged (the Resources folder is already declared; `.process` handles lproj correctly).
5. **App-layer comment sweep:** every German comment (MARK lines included) → precise English.
6. **DE render proof (binding, headless):** a small executable check — e.g. `swift test` with a NEW unit test in the App… the App has no test target → instead: mini-verification via `swift run`?? Not needed, too complicated: BINDING is a bundle-lookup test in the CORE test target — doesn't work (App bundle). Instead: verification script in the report — a `defaults`-free direct check: the built `.build/debug/macSCP_MacSCPApp.bundle` MUST contain `de.lproj/Localizable.strings` and `en.lproj/Localizable.strings` (`ls` in the report) AND a 10-line Swift snippet (swiftc, temporary, not committed) loads the bundle and asserts `localizedString(forKey: "connection.title", …, table: nil)` differs correctly between the two lprojs. Visual proof of the app running in German follows in T3.
7. No string stays hardcoded (search in the report: `grep -rn '"' Sources/MacSCPApp --include='*.swift'` filtered for remaining visible literals — justified exceptions: pure symbols, SF Symbol names, format constants, bundle IDs).

- [x] Inventory → create `.strings` EN+DE → convert views → comments EN → bundle proof → `swift build && swift test` (219 green, no new tests needed) → headless launch check → commit `refactor: localize app ui strings and translate comments to english` (with footer).

---

### Task 2: Core layer — localize messages + comments to English + locale-stable tests

**Files:**
- Create: `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`, `Sources/macSCPCore/Resources/de.lproj/Localizable.strings`, `Sources/macSCPCore/Resources/CoreL10n.swift` (bundle helper)
- Modify: `Package.swift` (macSCPCore target ONLY: `resources: [.process("Resources")]`)
- Modify: ALL files under `Sources/macSCPCore/` and `Sources/MacSCPCLI/` (comments; message producers onto lookup), all `Tests/macSCPCoreTests/*` (comments + assertions).

**Binding:**
1. **Message inventory** (report): all user-visible strings originating in Core — `TransferQueueViewModel.message(for:)` (4 cases + fallback), conflict/rename errors ("No free name available…"), `ConnectionViewModel` validations ("Port must be a number." etc.) + host-key texts (first-connection/mismatch warning — FULL sharpness in both languages), terminal messages ("Shell ended…", "…does not support a terminal."), do `RemoteFSError` reasons leak through? — per policy reasons are ENGLISH (log-like character): reasons are NOT localized, they get normalized to English; the surrounding UI message is localized.
2. Same key schema (`core.transfer.notFound %@`, `core.connect.portNumeric`, `core.hostkey.mismatch %@ %@ %@`, …); EN = default text, DE = previous German text. Lookup via `CoreL10n` (bundle-probing pattern like `SettingsResources`, but for the Core bundle `macSCP_macSCPCore.bundle`; in tests `Bundle.module` works normally — the helper defensively probes `Bundle.module` paths WITHOUT fatalError).
3. **Test adjustment (critical, binding):** tests that assert exact German messages will henceforth check against the SAME lookup (a `CoreL10n` call in the test) — never against newly hardcoded literals. This makes the tests locale-independent and pins the key wiring. UI status labels ("skipped"/"cancelled"/"waiting") are APP strings (T1) — Core status stays an enum.
4. **Core+Tests+CLI comment sweep:** prioritize the three mixed files (`TransferEngine`, `TransferQueueViewModel`, `CitadelFileSystem`), then all the rest (RemoteFS/, SSH/, Sessions/, Presentation/, Settings/, CLI, all tests). MARK lines included. Bring along German IDENTIFIERS (if any — grep for umlaut suspicion/`ae|oe|ue`) as long as it doesn't break the public API; the public API is already English.
5. Incorporate the two doc notes from the M5c final review (in English): extend the post-write-check comment to cover the benign cancel-after-last-chunk case; that's comment work, handled here too.
6. `RemoteFSError` reason strings that are German today (e.g. "Pfad existiert als Datei: …", "known_hosts nicht lesbar: …", "Shell konnte nicht geöffnet werden…", "Diese Verbindung unterstützt kein Terminal.") → normalize to ENGLISH (policy: reasons = English log strings); wherever a UI shows them 1:1 today, the German rendering now comes through the localized wrapper message (`message(for:)` path). Tests that check reasons move over to the English reasons.

- [x] Inventory → resources+helper → convert message producers → reasons EN → tests onto lookup/EN reasons → comment sweep → `swift build && swift test` (219 green) → gated NOT needed (T3) → commit `refactor: localize core messages and translate comments to english` (with footer).

---

### Task 3: Final verification

- [x] `swift test` overall (219 expected) + rig up, `MACSCP_ITEST=1` full (219-equivalent gated), `MACSCP_KEYCHAIN=1` 2/2 — the gated suites prove that the reason normalization doesn't break any integration paths.
- [x] **Remaining-grep proof:** `grep -rn` across `Sources/ Tests/` for remaining German comments/strings (umlaut search `[äöüÄÖÜß]` + spot checks of common words) — result EMPTY except for `de.lproj` files and justified exceptions (documented in the commit).
- [x] **Visual language proof** (screen free): start the app normally → UI ENGLISH (default, since the system… the system is German → the app follows the system: GERMAN! So: start normally → GERMAN visible (form "Neue Verbindung" etc. from de.lproj — now REALLY from the catalog); then start with English forced (`defaults write dev.noidee.macscp.dev AppleLanguages '("en")'` or launch argument `-AppleLanguages "(en)"` via `open --args`) → UI ENGLISH. Note both screenshots in the ledger; then REMOVE the defaults override again.
- [x] Brief functional smoke test (connect, one transfer, one conflict sheet in the active language).
- [x] Check the boxes, commit `docs: mark M5i plan tasks as completed` (with footer).

## Outlook

After that: M5d (resume + reconnect + partial-file cleanup), M5e (editor integration), M6 (release; there: DMG packaging must carry both lprojs along, the applyToAll recheck one-liner, the global throttle bucket, the sheet default-action review).
