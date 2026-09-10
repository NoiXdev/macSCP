# Shell completion from Settings — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings › Command-Line Tool shows, per shell (zsh, bash, fish), the one line that loads `macscp-cli`'s completion at shell start, with a Copy Command button, following the install state.

**Architecture:** One pure Core type, `ShellCompletionRecipe`, owns the shell list and the three spellings; `CLISettingsSection` in the App renders a picker over `Shell.allCases`, the recipe's line for the selected shell, and a copy button — the same shape the section's existing system-wide command uses. Tests drive the recipe, the built binary's `--generate-completion-script` for every shell, and the real shells where installed.

**Tech Stack:** Swift 6 strict, SwiftUI (AppKit target), Swift Testing, `SubprocessRunner` from Tests/macSCPCoreTests/Support.

## Global Constraints

- Design: `docs/superpowers/specs/2026-09-08-shell-completion-settings-design.md` (approved 2026-09-08). Maintainer decisions: all three shells; always the `source <(…)` / `| source` form; one picker, one line, one copy button.
- Swift 6 strict, `.swiftLanguageMode(.v6)`, macOS 15; Swift Testing, red first (recorded); tests never block the cooperative pool (every wait an `await`; child processes through `SubprocessRunner`); no wall-clock ceilings (`.timeLimit` traits only); no `#require` on a non-optional; nothing secret is involved, but no real host names in tests either.
- Every App string through `L10n.string(_:_:)` in en/de/fr/pl (German du); no hardcoded display string; the three command lines are NOT display strings — they come from `ShellCompletionRecipe`, never from a catalogue.
- Source-scanning guards: a negative check has a positive beside it; guards read `SwiftSource.blankingCommentsAndStrings` output and derive symbols; comments naming callers or counts are counted in the same pass; scripted edits assert anchors and read back insertion points; the report is written from the diff.
- Zero warnings (`swift build --build-tests`). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI (the dev build is the sight check).

---

### Task 1: The recipe, the section, the tests

**Files:**
- Create: `Sources/macSCPCore/CLI/ShellCompletionRecipe.swift`
- Modify: `Sources/MacSCPAppKit/SettingsView.swift` (`CLISettingsSection`, after the "System-Wide Installation" section)
- Modify: the four App catalogs `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (keys `settings.cli.completion.header`, `.intro`, `.copy`, `.where.zsh`, `.where.bash`, `.where.fish`, `.zshCompinit`, `.footer.notInstalled`, `.footer.installed` — pick the final set and count it in the guard)
- Test: `Tests/macSCPCoreTests/ShellCompletionRecipeTests.swift`, `Tests/macSCPCoreTests/CLICompletionScriptTests.swift`, `Tests/macSCPAppKitTests/CLISettingsCompletionGuardTests.swift`

**Interfaces:**
- Produces: `public enum ShellCompletionRecipe { public enum Shell: String, CaseIterable, Sendable { case zsh, bash, fish }; public static func line(for shell: Shell, tool: String) -> String; public static func shell(fromLoginShellPath path: String?) -> Shell; public static func quotedForShell(_ path: String) -> String }` — `line` returns exactly `source <(TOOL --generate-completion-script zsh)`, `source <(TOOL --generate-completion-script bash)`, `TOOL --generate-completion-script fish | source`, where TOOL is `tool` verbatim (the caller passes `macscp-cli` or an already-quoted path); `quotedForShell` wraps in single quotes with `'` → `'\''` (valid in all three shells); `shell(fromLoginShellPath:)` maps the last path component `zsh`/`bash`/`fish`, anything else or nil → `.zsh`.
- Consumes: `CLIToolInstaller.toolURL` (read the property's real name in `Sources/macSCPCore/CLI/CLIToolInstaller.swift`; the section already builds the installer from the bundled tool's URL), `CLIInstallState`.

- [x] **Step 1: Failing tests.** `ShellCompletionRecipeTests`: the three lines for `tool: "macscp-cli"` verbatim; `quotedForShell("/Applications/mac SCP.app/Contents/MacOS/macscp-cli")` and a path containing `'`; `shell(fromLoginShellPath:)` for `/bin/zsh`, `/opt/homebrew/bin/bash`, `/opt/homebrew/bin/fish`, `/bin/sh`, `nil`. `CLICompletionScriptTests`: for every `Shell.allCases`, run the built binary (`locateCLIBinary()` pattern from `CLISessionsJSONRoundtripTests`) with `--generate-completion-script <raw>` → status 0, non-empty stdout, first line `#compdef macscp-cli` for zsh / `#!/bin/bash` for bash / a `function __macscp-cli` line for fish; then, for each shell whose interpreter exists (`/bin/zsh`, `/bin/bash`, fish via `/usr/bin/env fish` if `which fish` finds one — otherwise record a skip through `Issue.record`? no: use a `withKnownIssue`-free explicit `#expect(true)`-free path: just `return` after printing nothing; state in the doc that fish is measured only where installed), run the interpreter with `-c` on `line(for:tool: quotedForShell(binaryPath))` (zsh prefixed by `autoload -Uz compinit && compinit -D && `) → status 0. `CLISettingsCompletionGuardTests`: positive — `SettingsView.swift`'s `CLISettingsSection` body contains `ShellCompletionRecipe.line(` and `ShellCompletionRecipe.Shell.allCases`; negative beside it — the blanked source contains none of `--generate-completion-script`, `source <(`, `| source` as literals (they must come from the recipe); every `settings.cli.completion.` key the section reads (derived by regex over the blanked source) resolves in all four catalogs; the German values contain no `Sie`.
- [x] **Step 2: Run** `swift test --filter "ShellCompletionRecipe|CLICompletionScript|CLISettingsCompletion"` → FAIL (types/keys missing).
- [x] **Step 3: Implement.** Core recipe; the section: `@State private var shell = ShellCompletionRecipe.shell(fromLoginShellPath: ProcessInfo.processInfo.environment["SHELL"])`, a `Picker` (`.segmented`) over `Shell.allCases` labelled by `rawValue` (a shell's name is not localized), the line as `Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)`, the copy button writing the same `line` to `NSPasteboard.general`, the "where" sentence per shell and the zsh compinit clause, the footer per install state; `toolName` = `CLIToolInstaller.toolName` when `state == .installed`, else `ShellCompletionRecipe.quotedForShell(installer.toolURL.path)`.
- [x] **Step 4: Run** the filter → PASS; `swift test` green; catalogue parity green; zero warnings. Mutation probes (record): change the fish line to `source <(…)` → recipe test red; drop the picker's `allCases` → guard red; spell the zsh line literally in the view → guard red.
- [x] **Step 5: Commit** `feat(settings): shell completion for the command-line tool, one copyable line per shell`.

---

### Task 2: Closeout

- [x] `docs/BACKLOG.md`: the CLI-completion row (`2026-08-20-backlog-cli-completion-hosts.md`) gets its "shipping and setup" answered (documented in Settings, generated at shell start), pointing at the design; the README's "Command line" section gains one sentence and the zsh line; the design's status line → implemented with the commit; the plan's checkboxes. Commit `docs(backlog): shell completion is documented in Settings`.

## Self-review

- Spec coverage: picker/line/copy/where/compinit/install-state → Task 1; docs → Task 2.
- Placeholders: none.
- Type consistency: `ShellCompletionRecipe.Shell`, `line(for:tool:)`, `quotedForShell(_:)`, `shell(fromLoginShellPath:)` are the names used in the view and all three tests.
