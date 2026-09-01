# M11d — External Terminal (Design)

Date: 2026-07-29 · Status: approved by the maintainer ("go ahead")

## Goal

Open the SSH session either in the built-in terminal OR in an external
terminal app (Terminal.app, iTerm, a freely chosen app).

**Maintainer decisions (2026-07-29):**

1. For connections with a saved PASSWORD, it opens anyway;
   `ssh` asks there itself. The first time, a notice with "don't show
   again". The password NEVER leaves the keychain — no
   passing it along, no copying to the clipboard (explicitly
   rejected: the clipboard is readable by any running app).
2. Start via a short-lived `.command` script + `open -a`, NOT via
   AppleScript.

## 1. Command building (Core, pure)

- `SSHCommandBuilder.arguments(for config: SSHConnectionConfig) -> [String]`
  — pure function, returns the `ssh` ARGUMENT LIST (not a string):
  - `-p <port>` only when `port != 22`
  - `-l <username>`
  - `-i <keyPath>` only with `authKind == .privateKey`
  - `-J <user>@<host>[:<port>]` if a jump is set (port only when
    != 22). The jump is already resolved by this point — for a
    session-referenced jump (M11a), the App supplies the
    resolved values.
  - Agent auth (`.agent`) needs NO argument (`ssh` finds the agent
    via `SSH_AUTH_SOCK` itself).
  - the host last.
- Passwords appear NOWHERE (neither as an argument nor in the environment).
- `SSHCommandBuilder.shellCommand(for:) -> String` puts every argument
  INDIVIDUALLY in single quotes and escapes contained quotes per the
  POSIX pattern (`'` ⇒ `'\''`). This closes off spaces and special
  characters in paths/usernames as an attack vector.

## 2. Script + start (App)

- `TerminalScriptWriter` (App layer, but the CONTENT comes from a
  pure Core function `SSHCommandBuilder.scriptContents(for:)`):
  shebang `#!/bin/sh`, self-deletion (`rm -f -- "$0"` immediately before
  the `exec`, so the script doesn't linger even for a long session),
  then `exec ssh <quoted args>`.
- Location: `<temp>/macscp-terminal/<uuid>.command`, permissions 0700 (only
  the user). Swept on App start like the editor temp files from M5e
  (the same pattern, its own subfolder).
- Start: `NSWorkspace.shared.open([scriptURL], withApplicationAt: appURL,
  configuration:)`, i.e. the `open -a` equivalent. Works with ANY
  terminal app; NO AppleScript automation, hence NO
  extra TCC/automation permission needed (the App is not
  sandboxed, but runs under Hardened Runtime — an AppleScript solution
  would need `com.apple.security.automation.apple-events` plus
  user consent and app-specific scripts).

## 3. Setting + operation

- `SettingsStore.terminalTarget: TerminalTarget`
  (`enum TerminalTarget: String, Codable`: `builtIn`, `terminalApp`,
  `iTerm`, `custom`) plus `customTerminalAppPath: String?`.
  Forward compatible (old `settings.json` ⇒ `builtIn`).
- Settings' terminal tab: selection `Built-in | Terminal.app |
  iTerm | Custom App…` (for "custom app" a `fileImporter` on
  `/Applications`, the path is what's stored).
- The setting determines what **⌘T** and the toolbar button do.
- ADDITIONALLY both paths are always explicitly reachable: a menu item
  "Open in External Terminal" (even with `builtIn`) and — with
  an external target configured — the built-in terminal stays reachable via
  its own item. Nobody loses a capability because of the setting.
- Password connections: open anyway; the FIRST time a notice
  ("macSCP can't hand the saved password to an external terminal —
  `ssh` will ask you for it there.") with "Don't show
  again", persisted as `externalTerminalPasswordHintShown: Bool`.

## 4. Errors, honestly

- Chosen app not present (uninstalled, invalid path) ⇒ a concrete
  message with the name/path; NO silent fallback to another app
  and NO silent switch to the built-in terminal.
- Script write failure ⇒ its own message.
- Both are their own typed cases, not a catch-all error message.

## 5. Tests

- Argument building: password auth (only `-l` + host), key auth (`-i`),
  agent auth (no extra argument), port 22 vs. non-default, jump with and
  without a non-default port, jump + key at the same time.
- Quoting: space in the key path, single quote in the username,
  semicolon/backtick in the host (the result must be harmless).
- Script content: shebang, self-deletion before `exec`, exactly one `exec ssh`,
  no password occurring.
- NO test starts a process or opens an app.
- Settings: forward compatibility (old JSON ⇒ `builtIn`), roundtrip
  of all cases incl. `custom` + path.

## 6. Breakdown

T1 Core (argument building, quoting, script content) → T2 App (settings
selection, start, menu items, password notice, error cases, sweep, EN/DE) →
T3 wrap-up. NO release.

## 7. Deliberately NOT in M11d

No passing along of passwords (not via clipboard,
environment variable, `sshpass` or similar either); no AppleScript and no
app-specific automation; no opening in the remote pane's current
working directory (backlog: `-t "cd … && exec $SHELL"`);
no adoption of the terminal appearance settings (font/cursor
continue to apply only to the built-in terminal).
