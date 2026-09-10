# Shell completion from Settings — design

**Status:** approved by the maintainer in chat on 2026-09-08; plan at
`docs/superpowers/plans/2026-09-08-shell-completion-settings.md`.

## Goal

Settings › Command-Line Tool gains a section that tells the user how to
turn on tab completion for `macscp-cli` in their shell, with one copyable
line per shell — always the form that loads the script from the
installed tool at shell start, so a CLI update never leaves a stale
script behind:

- zsh: `source <(macscp-cli --generate-completion-script zsh)`
- bash: `source <(macscp-cli --generate-completion-script bash)`
- fish: `macscp-cli --generate-completion-script fish | source`

## Starting point (verified in the tree, 2026-09-08)

- `macscp-cli --generate-completion-script <shell>` is
  swift-argument-parser's built-in; measured on the debug binary: zsh
  429 lines (`#compdef macscp-cli`), bash 653 lines, fish 262 lines.
  `MacSCPCLI.main()` treats a completion request like `--help` (exit 0).
- Settings › Command-Line Tool is `CLISettingsSection` in
  `Sources/MacSCPAppKit/SettingsView.swift:1513`: a status line, an
  Install/Repair button, and a "System-Wide Installation" section whose
  one command is shown in monospace with a **Copy Command** button
  (`NSPasteboard.general`). `CLIToolInstaller`
  (`Sources/macSCPCore/CLI/CLIToolInstaller.swift`) knows the bundled
  tool's URL (`toolURL`), the shortcut state (`CLIInstallState`:
  `notInstalled`, `installed`, `stale`, `occupied`, `translocated`) and
  renders `systemWideInstallCommand`.
- The CLI-completion backlog entry
  (`docs/superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md`,
  item 2) left "shipping and setup" open: whether the install script
  generates the script or the app documents the command. This design
  answers it: the app documents the command, and the command generates
  at shell start.

## Maintainer decisions (chat, 2026-09-08)

1. **All three shells the CLI can generate for**: zsh, bash, fish.
2. **Always the `source <(…)` form** (fish: `… | source`), never a
   generated file dropped into a completions directory — the line stays
   correct across updates because it asks the installed tool each time.
3. **One picker, one line, one copy button**, not three lines at once.

## The section

Placed after "System-Wide Installation", header "Shell Completion":

- A segmented picker over the shells, preselected from the login shell
  (`ProcessInfo.processInfo.environment["SHELL"]`'s last path component:
  `zsh` → zsh, `bash` → bash, `fish` → fish, anything else → zsh, which
  is macOS's default).
- The line for the selected shell in monospace (`.textSelection`), and a
  **Copy Command** button that puts exactly that line on the pasteboard.
- One sentence naming the file the line belongs in for that shell
  (`~/.zshrc`; `~/.bashrc` — or `~/.bash_profile` on macOS, where
  Terminal opens login shells; `~/.config/fish/config.fish`), and that it
  loads the current completion from the installed tool at every shell
  start. For zsh, one more clause: the completion system must be
  initialised (`autoload -Uz compinit && compinit` before the line — the
  stock macOS zsh does this by default).
- **The tool's name in the line follows the install state**: while the
  shortcut is `installed`, the line says `macscp-cli`; in every other
  state (`notInstalled`, `stale`, `occupied`, `translocated`) the line
  carries the bundled tool's full path, quoted for the shell, so it
  works without the shortcut — and the footer says that installing the
  shortcut shortens it. The pane already re-reads the state on
  appearance, so the line follows an Install click. **Except
  `translocated`** (the app runs from a disk image's temporary copy):
  that path disappears when the app quits, so the section shows no line
  and no copy button there, only the sentence to move the app to
  Applications first — the same reason the Install button is withheld
  in that state (Task 1 review, 2026-09-10).

## Where the text comes from

One pure function in Core, `ShellCompletionRecipe`
(`Sources/macSCPCore/CLI/ShellCompletionRecipe.swift`):

```swift
public enum ShellCompletionRecipe {
    public enum Shell: String, CaseIterable, Sendable { case zsh, bash, fish }
    public static func line(for shell: Shell, tool: String) -> String
    public static func shell(fromLoginShellPath path: String?) -> Shell
    public static func quotedForShell(_ path: String) -> String  // single-quoted, ' escaped
}
```

`line(for:tool:)` is the ONE place the three spellings live; the
Settings section and the tests read it. `Shell` is the ONE list of
shells; a test drives the built binary's `--generate-completion-script`
for every case and asserts exit 0 and a non-empty script whose first
line is what swift-argument-parser emits for that shell — so a shell
added to the enum without CLI support goes red, and a shell the CLI
grows (swift-argument-parser adds one) is noticed only by reading its
release notes (recorded limit: the CLI's own list is not enumerable
from outside).

## Tests

- `ShellCompletionRecipeTests` (Core, ungated): the three lines verbatim
  for `tool: "macscp-cli"`; a tool path with a space and an apostrophe
  quoted correctly for each shell; `shell(fromLoginShellPath:)` for
  `/bin/zsh`, `/opt/homebrew/bin/bash`, `/opt/homebrew/bin/fish`, `nil`,
  `/bin/sh` → zsh.
- `CLICompletionScriptTests` (through the built binary, ungated): for
  every `Shell` case, `--generate-completion-script <shell>` exits 0 with
  a non-empty script; and, where the shell is installed on the machine
  (`/bin/zsh` always; bash `/bin/bash`; fish only if found on PATH —
  skipped otherwise, stated), the recipe's line sourced in that shell
  exits 0 (`zsh -c 'autoload -Uz compinit && compinit -D && <line>'`,
  `bash -c '<line>'`, `fish -c '<line>'`), with the tool path pointing at
  the built binary. Bounded by the suite's `.timeLimit`, no clock
  assertion.
- `CLISettingsCompletionGuardTests` (App, source guard): the section
  reads `ShellCompletionRecipe.line(` and iterates
  `ShellCompletionRecipe.Shell.allCases` (positive) and spells none of
  the three commands as a literal (negative beside it); the copy button
  copies the same `line(` the label shows (both derived from one
  property); every catalogue key the section reads resolves in all four
  catalogs.

## Limits

- The line completes `macscp-cli` invoked by that name (or by the
  quoted full path shown); a user who installs the tool under another
  name edits the line by hand.
- zsh needs `compinit` initialised; the section says so and does not
  detect it.
- Remote paths after `name:` are still not completed (the backlog's
  item 2 decision: session names only — and that completer is the one
  deferred for the `sessions`/`tunnels` verbs).

## Not in this design

Writing into shell configuration files; generating a static script into
a completions directory; a completion for the app-side verbs' `--session`
(deferred, see the CLI plan).
