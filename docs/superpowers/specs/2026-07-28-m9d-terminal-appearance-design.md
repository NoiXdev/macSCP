# M9d — Terminal appearance + remote-home start (design)

Date: 2026-07-28 · Status: approved by the maintainer (design confirmed
as one block, "go ahead directly")

## Goal

Configurable terminal appearance (monospace font, font size, cursor
style) with live application to open terminals; colors stay fixed CI
(deep sea/phosphor). Folded-in mini-fix: the remote pane opens the
remote HOME (SFTP `realpath "."`) on connect instead of `/`.

**Maintainer decisions (2026-07-28):** scope = font + size + cursor
style; colors/theme fixed (CI). Remote-home fix in this milestone.

## 1. Settings (Core)

`SettingsStore`, forward-compatible as before:

- `terminalFontName: String?` — nil (default) = system monospace (SF
  Mono).
- `terminalFontSize: Int` — default 13, clamped 9…24 on set AND read.
- `terminalCursorStyle: TerminalCursorStyle` — enum (string raw value)
  with `block` (default), `bar`, `underline`; unknown stored values read
  as the default.
- `terminalCursorBlink: Bool` — default `true`.
- `TerminalCursorStyle` lives in Core (testable) and, together with the
  blink flag, provides the mapping onto SwiftTerm's six cursor modes
  (blink/steady × block/underline/bar) — as a pure function along the
  lines of `swiftTermStyleName`, or mapped directly in the app layer;
  the MAPPING (6 combinations) is tested Core-side as an enum+flag pair.

## 2. Application (App, SSHTerminalView)

- `makeNSView` reads font/size/cursor from `SettingsStore` (injected as
  a parameter, no singleton) instead of the hardcoded 13-pt line.
- `updateNSView` (empty today) applies changes LIVE: re-resolve and set
  the font object (SwiftTerm reflows; resize→SSH window-change runs
  through the existing delegate), set the cursor style. Touch it only on
  an actual change (comparison), so regular SwiftUI re-renders do not
  disturb the terminal.
- Font resolution: stored name → `NSFont(name:size:)`; no longer present
  → system monospace fallback. Never a blank/broken terminal.
- Colors/theme: UNCHANGED (DesignTokens deep sea/phosphor).

## 3. Settings UI

- New tab "Terminal" (after "Öffnen mit"): font popup (fixed-pitch
  system fonts only, top entry "System (SF Mono)" = nil), size stepper
  9–24, cursor picker (Block/Balken/Unterstrich) + toggle "Blinken",
  below it a small live preview line in the deep-sea look (statically
  rendered example text with the chosen font/size).
- Keys EN/DE.

## 4. Remote home on connect

- `RemoteFileSystem` protocol: `homeDirectoryPath() async throws ->
  String`.
  - `CitadelFileSystem`: SFTP `realpath "."` (Citadel `getRealPath`).
  - `LocalFileSystem`: `NSHomeDirectory()`.
  - `MockRemoteFileSystem`: configurable (default `/`).
- `startSession` resolves the home ONCE on connect and creates the
  remote VM with this `startPath`; on error ⇒ silent fallback to `/`
  (behavior as before). No re-resolving on refresh/navigation.

## 5. Tests

- Store: defaults, clamping 9–24 (set/read, raw JSON), unknown cursor
  raw value reads as `block`, round trip, old settings.json without
  keys ⇒ defaults.
- Cursor mapping: 6 combinations (3 styles × blink on/off) unambiguous.
- FS: mock `homeDirectoryPath` (configured + error case); gated Citadel
  test: `homeDirectoryPath()` returns an absolute path (starts with `/`)
  and `list` on it works.
- App (popup, live application, preview): visual smoke (T3).

## 6. Deliberately NOT in M9d

- No color/theme selection (CI stays fixed); no ANSI palette settings.
- No line-spacing/padding setting.
- No per-session terminal settings (global suffices).
