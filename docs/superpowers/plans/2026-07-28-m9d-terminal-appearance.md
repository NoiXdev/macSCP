# M9d — Terminal Appearance + Remote Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configurable terminal font/size/cursor with live application (colors stay CI) + the remote pane starts in the remote home on connect instead of `/`.

**Architecture:** Four forward-compatible SettingsStore properties + a `TerminalCursorStyle` enum (Core, tested); `SSHTerminalView` reads them in `makeNSView` and applies changes in `updateNSView` only on an actual difference; new Settings tab "Terminal" with a monospace font popup and a preview; `RemoteFileSystem.homeDirectoryPath()` (Citadel `realpath "."`, Local `NSHomeDirectory()`, Mock configurable) — `startSession` resolves the home once.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftTerm (font/caret/cursorStyle APIs), NSFontManager (fixed-pitch list).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9d-terminal-appearance-design.md` — binding. Branch: **develop**.
- Colors/theme UNCHANGED (DesignTokens Tiefsee/Phosphor); only font, size (9…24 clamped on both set AND read), cursor style (block default/bar/underline; unknown raw value reads as block) + blink (default true).
- Live application in `updateNSView` ONLY on an actual change (comparison) — regular re-renders must not touch the terminal; font fallback: name not resolvable ⇒ system monospace, never a broken terminal.
- Remote home: resolved ONCE on connect via `homeDirectoryPath()`; error ⇒ silent fallback to `/`; no re-resolving later.
- All new UI text EN/DE; code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 456 tests / 36 suites); gated suites in T1 (implementer, rig needed for the Citadel home test) and T3; tests run SYNCHRONOUSLY in the foreground.
- TDD for Core; App target untestable → T2 delivers a build + behavior description.

## Schedule

T1 (Core: settings + cursor enum + FS home, incl. gated test) → T2 (App: terminal tab + SSHTerminalView + home wiring) → T3 wrap-up (coordinator).

---

### Task 1: Settings properties, TerminalCursorStyle, homeDirectoryPath (Core)

**Files:**
- Create: `Sources/macSCPCore/Settings/TerminalCursorStyle.swift`
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`, `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`, `Sources/macSCPCore/SSH/CitadelFileSystem.swift`, `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystem.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`, `Tests/macSCPCoreTests/TerminalCursorStyleTests.swift` (new), `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (gated), `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` or the mock tests (mock home)

**Interfaces:**
- Produces (T2 relies on this exactly):
  - `public enum TerminalCursorStyle: String, Codable, CaseIterable, Sendable { case block, bar, underline }`
  - `SettingsStore.terminalFontName: String?` (default nil), `terminalFontSize: Int` (13, clamped 9…24 setter+getter), `terminalCursorStyle: TerminalCursorStyle` (block; unknown raw reads block), `terminalCursorBlink: Bool` (true)
  - `RemoteFileSystem.homeDirectoryPath() async throws -> String` (protocol extension; ALL conformers implement it)
  - `MockRemoteFileSystem`: configurable home (default `/`) + optional error mode

- [x] **Step 1: Failing tests.** `TerminalCursorStyleTests.swift` (new):

```swift
import Testing
@testable import macSCPCore

@Suite("TerminalCursorStyle")
struct TerminalCursorStyleTests {
    @Test func rawValuesAreStable() {
        #expect(TerminalCursorStyle.block.rawValue == "block")
        #expect(TerminalCursorStyle.bar.rawValue == "bar")
        #expect(TerminalCursorStyle.underline.rawValue == "underline")
        #expect(TerminalCursorStyle.allCases.count == 3)
    }

    @Test func sixCursorCombinationsAreDistinct() {
        // The (style, blink) pair is the app-layer's mapping input to
        // SwiftTerm's six cursor modes — pin that all six pairs exist and
        // are distinguishable.
        var seen = Set<String>()
        for style in TerminalCursorStyle.allCases {
            for blink in [true, false] {
                seen.insert("\(style.rawValue)-\(blink)")
            }
        }
        #expect(seen.count == 6)
    }
}
```

`SettingsStoreTests` extension (file pattern): defaults (nil/13/block/true), size clamping on the setter (8→9, 99→24) AND the getter (raw JSON 0→9, 1000→24), unknown cursor raw (`"weird"` in raw JSON) reads as `.block`, roundtrip of all four, old settings.json ⇒ defaults. VM/Mock: test that a configured mock home is returned by `homeDirectoryPath()` and that the error mode throws.

- [x] **Step 2: Prove red**, then implement: enum trivial; settings follow the `showHiddenFiles`/`autoRefreshIntervalSeconds` pattern (look up the string-optional helper for `terminalFontName`, or add a `stringValue/setString` analog if it doesn't exist — check the `fileAssociations`/`defaultEditorPath` pattern); `terminalCursorStyle` stores the raw-value string, getter `TerminalCursorStyle(rawValue:) ?? .block`.
- [x] **Step 3: FS API.** Protocol doc comment: „Resolves the connection's home directory (login landing point). Used once at session start; callers fall back to "/" on failure." Citadel: the SFTP `realpath` capability exists (Citadel `SFTPClient` — look up the exact method name, ~`getRealPath(atPath: ".")`); error mapping like the other Citadel methods. Local: `NSHomeDirectory()`. Mock: `var homePath: String = "/"` + error flag, construction-compatible for all existing tests (defaults!).
- [x] **Step 4: Gated test** (in the Docker suite, following its conventions; start the rig from the MAIN checkout, `docker compose -f docker/test-server/compose.yml start`, then LEAVE IT RUNNING):

```swift
    @Test func homeDirectoryPathResolvesAbsoluteAndListable() async throws {
        // connect helper of the suite (port 2222)
        // let home = try await fs.homeDirectoryPath()
        // #expect(home.hasPrefix("/"))
        // _ = try await fs.list(path: home)   // landing point must be listable
    }
```

- [x] **Step 5: Green + full suite (incl. `MACSCP_ITEST=1 swift test`) + commit.** `swift test` → 456 + ~10 (record the actual number). Commit `feat: add terminal appearance settings and remote home resolution`

---

### Task 2: Terminal tab, SSHTerminalView live application, home start (App)

**Files:**
- Modify: `Sources/MacSCPApp/SSHTerminalView.swift`, `Sources/MacSCPApp/SettingsView.swift`, `Sources/MacSCPApp/ContentView.swift` (startSession: resolve home + extend the terminal-view call site with settingsStore), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (App target; smoke in T3)

**Interfaces:**
- Consumes: everything from T1; the `SSHTerminalView(viewModel:)` call site in `ContentView.terminalPanel`; `startSession(in:with:storedName:)`.

**Behavior requirements:**
1. `SSHTerminalView` gets `let settingsStore: SettingsStore`. `makeNSView`: font via a private helper `resolvedFont()` (`terminalFontName` → `NSFont(name:size:)`, otherwise `NSFont.monospacedSystemFont(ofSize:weight:.regular)`; size = `terminalFontSize`), cursor via mapping (style, blink) → the SwiftTerm cursor API (look up the concrete SwiftTerm API: `TerminalView`/`Terminal` offers a cursor-style setter — e.g. `setCursorStyle` on `Terminal`; document in the report). Colors/replay/first-responder lines UNCHANGED.
2. `updateNSView`: compute the current target font + target cursor; ONLY reset if `terminal.font` (name+size) or the remembered cursor state (stored in the coordinator) differs. Comment: regular re-renders must not touch the terminal.
3. Settings tab "Terminal" (after "Open with"): font popup — entries: "System (SF Mono)" (nil) + all fixed-pitch families (`NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask)` reduced to families, alphabetical); size stepper 9…24; cursor picker (3 styles, localized labels) + toggle "Blink"; below it a preview: `Text("deploy@web-01:~ $ ls -la")` in the chosen font/size on `DesignTokens.terminalBackground` with the phosphor text color, r6 corners.
4. Home start in `startSession`: BEFORE `BrowserSession` creation, `let home = (try? await fs.homeDirectoryPath()) ?? "/"` and `RemoteBrowserViewModel(fs: fs, startPath: home)`. (Is `startSession` already async-capable? Check — it's called from async contexts; if sync, move the home lookup into the connect flow before it. Document the solution in the report.)
5. Keys EN/DE (proposal): `settings.tab.terminal` "Terminal"/"Terminal", `settings.terminal.font` "Font"/"Schrift", `settings.terminal.systemFont` "System (SF Mono)"/"System (SF Mono)", `settings.terminal.size %lld` "Size: %lld pt"/„Größe: %lld pt", `settings.terminal.cursor` "Cursor"/"Cursor", `settings.terminal.cursor.block/bar/underline` "Block"/"Bar"/"Underline" (DE Block/Balken/Unterstrich), `settings.terminal.cursorBlink` "Blinking"/"Blinken", `settings.terminal.preview` (preview line stays unlocalized sample text — NO key needed, note in the report). Grep cross-check both catalogs.

- [x] **Step 1:** SSHTerminalView. **Step 2:** Settings tab + keys. **Step 3:** Home start. **Step 4:** `swift build` (0 errors, no new warnings) + full `swift test` (T1 state). **Step 5:** Commit `feat: make the terminal appearance configurable and start in the remote home`.

---

### Task 3: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green, zero skips (470/470; the final reviewer additionally ran twice).
- [ ] Visual smoke — **delegated to the maintainer** (wrapper is running; checklist in the milestone summary): connect → remote pane starts in HOME (rig: testuser home) instead of `/`; open terminal → settings: switch font (e.g. Menlo), change size, cursor bar/blinking → open terminal picks it up LIVE without losing content; invalid size clamps; preview follows; restart retains the values; regressions: ⌘T replay, resize→window-change, CI colors unchanged.
- [x] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1; "No" with one Important [double-connect leak via async handoff, proved empirically] → fix commit dfe19ea → re-review "Ready to merge: Yes"), fixes, push develop, CI, rig `stop`, memory update, milestone summary (+ M10 order Known Hosts → Login Sets → Jump Host next; M9e ssh-agent possibly folded into the M10b design — login-set auth kind "Agent"; release bundling still open).
