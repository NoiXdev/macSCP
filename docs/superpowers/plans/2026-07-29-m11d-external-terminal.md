# M11d — External Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open the SSH session either in the built-in terminal or in an external terminal app (Terminal.app, iTerm, freely chosen app), without a password ever leaving the app.

**Architecture:** A pure `SSHCommandBuilder` (argument list → POSIX quoting → script content), so everything security-relevant is testable; the App writes a short-lived `.command` (0700, its own temp subfolder with a startup sweep following the M5e pattern) and opens it with the chosen app — no AppleScript, no automation permission.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, AppKit (`NSWorkspace`), SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11d-external-terminal-design.md` — binding. Branch: **develop**.
- **NO password leaves the App** — not as an argument, not in the environment, not on the clipboard, not in the script. For password connections, `ssh` itself asks.
- Quoting is security-relevant: every argument INDIVIDUALLY in single quotes, contained `'` per the POSIX pattern (`'\''`). A test must prove that special characters (semicolon, backtick, `$(...)`, space, quote) cannot break out.
- No AppleScript, no app-specific automation, no new entitlements.
- Script: permissions 0700, its own temp subfolder, self-deletion before `exec`, startup sweep (pattern: `EditSessionManager`).
- Errors honest and typed: a missing/invalid app and write failures are their own cases; NO silent fallback to another app or to the built-in terminal.
- The setting takes away no capability: both paths stay reachable via menu items.
- NO test starts a process or opens an app.
- All new UI text EN/DE in BOTH App catalogs; code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 670 tests / 50 suites); gated suites in T3; tests run SYNCHRONOUSLY in the foreground; TDD red→green for Core.
- NO release, no merge to main.

## Schedule

T1 (Core: argument building + quoting + script content) → T2 (App: settings, start, menus, notice, errors, sweep) → T3 wrap-up (coordinator).

---

### Task 1: SSHCommandBuilder (Core)

**Files:**
- Create: `Sources/macSCPCore/SSH/SSHCommandBuilder.swift`
- Test: `Tests/macSCPCoreTests/SSHCommandBuilderTests.swift` (new)

**Interfaces:**
- Consumes: `SSHConnectionConfig` (incl. `AuthMethod` with `.password`/`.privateKey`/`.agent` and `Jump`).
- Produces (T2 relies on this exactly):
  - `SSHCommandBuilder.arguments(for config: SSHConnectionConfig) -> [String]`
  - `SSHCommandBuilder.shellCommand(for config: SSHConnectionConfig) -> String` (the quoted `ssh …` line)
  - `SSHCommandBuilder.scriptContents(for config: SSHConnectionConfig) -> String` (full script text)

**Behavior requirements (spec §1/§2, binding):**
1. `arguments`: order `["-p","<port>"]` (ONLY when `port != 22`), `["-l","<username>"]`, `["-i","<keyPath>"]` (ONLY with `.privateKey`), `["-J","<jumpUser>@<jumpHost>[:<jumpPort>]"]` (ONLY when `config.jump != nil`; `:<port>` only when `!= 22`), lastly `config.host`. `.agent` and `.password` produce NO additional argument.
2. A password must appear in NO output — not even a key's passphrase (only the path is passed).
3. `shellCommand`: `ssh` followed by the arguments, each INDIVIDUALLY in single quotes, contained `'` as `'\''`. The result must reproduce exactly the argument list from (1) for a POSIX shell.
4. `scriptContents`: first line `#!/bin/sh`, then a line that removes the script itself (`rm -f -- "$0"`), then `exec ` + `shellCommand`. Exactly ONE `exec ssh` in the text.
5. Pure functions — no filesystem, no process, no environment.

- [x] **Step 1: Failing tests**

```swift
    // SSHCommandBuilderTests:
    // passwordAuthOnlyUsesLoginAndHost: port 22, .password ->
    //   ["-l","tim","example.com"] (KEIN -p, kein -i).
    // nonDefaultPortAddsDashP: port 2222 -> beginnt mit ["-p","2222"].
    // privateKeyAddsIdentity: .privateKey(keyPath: "/k") -> enthält
    //   ["-i","/k"]; die Passphrase taucht NICHT auf (Config mit
    //   passphrase "geheim" -> shellCommand enthält "geheim" NICHT).
    // agentAuthAddsNothing: .agent -> gleiche Argumente wie .password.
    // jumpAddsDashJ: jump (host "b", user "j", port 22) -> enthält
    //   ["-J","j@b"]; mit port 2022 -> ["-J","j@b:2022"].
    // jumpAndKeyTogether: beides gesetzt -> beide Argumente vorhanden.
    // quotingIsSafe (parametrisiert): Key-Pfad "/pfad mit leer/id",
    //   Benutzername "ti'm", Host "a;rm -rf /", Host "$(whoami)",
    //   Host "`id`" -> shellCommand enthält KEINE unmaskierte Metazeichen-
    //   Wirkung: jedes Argument steht vollständig in Single-Quotes und
    //   jedes enthaltene ' ist als '\'' maskiert (Assertion über den
    //   erzeugten String, plus Gegenprobe: Zerlegen des Strings nach
    //   POSIX-Quoting-Regeln ergibt wieder exakt `arguments(for:)`).
    // scriptContentsShape: beginnt mit "#!/bin/sh", enthält
    //   'rm -f -- "$0"' VOR dem exec, genau ein "exec ssh",
    //   und kein Passwort/keine Passphrase.
```

- [x] **Step 2: Prove red.** `swift test --filter SSHCommandBuilder` → FAIL.
- [x] **Step 3: Implementation.**
- [x] **Step 4: Green + full suite.** `swift test` → 670 + new.
- [x] **Step 5: Commit.** `feat: build an ssh command line for external terminals`

---

### Task 2: Setting, start, menus, notice (App)

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (three new values), `Sources/MacSCPApp/ContentView.swift` (toolbar button/⌘T behavior + start + error alert + notice), `Sources/MacSCPApp/MacSCPApp.swift` (menu items), the settings view with the terminal tab (grep `terminalFontName`), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Create: `Sources/MacSCPApp/ExternalTerminalLauncher.swift`
- Test: settings forward-compatibility + roundtrip in the existing settings test file

**Interfaces:**
- Consumes (T1): `SSHCommandBuilder.scriptContents(for:)`; existing: `EditSessionManager`'s sweep pattern (`macscp-edit`) as the model for its own folder, the running session's `SSHConnectionConfig` (incl. resolved jump — the same values the connect used).
- Produces: `SettingsStore.terminalTarget: TerminalTarget` (`builtIn`/`terminalApp`/`iTerm`/`custom`, default `builtIn`), `SettingsStore.customTerminalAppPath: String?`, `SettingsStore.externalTerminalPasswordHintShown: Bool`.

**Behavior requirements (spec §3/§4, binding):**
1. Settings forward compatible (old JSON ⇒ `builtIn`, nil, false); roundtrip of all cases incl. `custom` + path.
2. `ExternalTerminalLauncher.open(config:target:customPath:)`: writes `scriptContents` to `<temp>/macscp-terminal/<uuid>.command` with permissions **0700**, opens it with the target app via `NSWorkspace` (`open(_:withApplicationAt:configuration:)`); throws typed errors `applicationNotFound(String)` and `scriptWriteFailed(String)`.
3. App resolution: `terminalApp` ⇒ bundle ID `com.apple.Terminal`, `iTerm` ⇒ `com.googlecode.iterm2`, `custom` ⇒ stored path. Not found/invalid ⇒ `applicationNotFound` with the name/path in the message; NO fallback.
4. Startup sweep for `<temp>/macscp-terminal` analogous to `EditSessionManager` (look there and use the same pattern).
5. ⌘T and the toolbar button follow `terminalTarget`: `builtIn` ⇒ today's toggling; otherwise ⇒ external open. ADDITIONALLY two menu items that always offer both paths ("Show/Hide Terminal" and "Open in External Terminal"), both active only with a connected session.
6. Password notice: if the session's auth is `.password` and `externalTerminalPasswordHintShown == false`, BEFORE opening show a notice (EN "macSCP can't hand a saved password to an external terminal — ssh will ask you for it there." / DE „macSCP kann ein gespeichertes Passwort nicht an ein externes Terminal übergeben — ssh fragt dort danach.") with "Don't show again"/„Nicht mehr anzeigen" (sets the flag) and "Open"/„Öffnen". Then open.
7. Errors from (2)/(3) appear as an alert with the concrete message.
8. All new keys EN/DE in both App catalogs; grep cross-check.

- [x] **Step 1:** Settings values + tests (red→green). **Step 2:** Launcher + sweep. **Step 3:** ⌘T/toolbar + menu items. **Step 4:** Password notice + error alerts. **Step 5:** Settings UI (selection + app picker). **Step 6:** L10n + cross-check. **Step 7:** `swift build` (0 errors, no new warnings) + full `swift test`. **Step 8:** Commit `feat: open the session in an external terminal`.

---

### Task 3: Final verification (coordinator)

- [x] Gated suites at the final state: rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips, no leftovers; rig `stop`.
- [x] Visual smoke — delegated to the maintainer (checklist: selection in settings incl. "custom app"; ⌘T follows the setting; both menu items work; opening with a key connection connects without prompting; a password connection shows the notice and `ssh` asks in the terminal; an uninstalled/invalid app shows the concrete message; after starting, no script remains in `<temp>/macscp-terminal`).
- [x] Plan checkboxes, ledger, Opus final review (package via `git merge-base origin/develop HEAD`), fix rounds until "Yes", push develop, `gh run watch`, memory, summary. NO release.
