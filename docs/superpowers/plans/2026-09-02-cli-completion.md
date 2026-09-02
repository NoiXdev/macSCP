# CLI Completion: Static Scripts Plus Session Names — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `macscp-cli` completes its subcommands and flags in zsh, bash and
fish through `swift-argument-parser`'s generated scripts, and completes
the `name:` half of every `name:/path` target from the saved sessions —
read through `SessionCatalog`, touching no secret, no keychain, no
connection. Item 2 of the CLI entry, on the maintainer's decision of
2026-09-02, plus item 3 (the root command's `discussion` for `name:/path`).

**Architecture:** `swift-argument-parser` already emits the scripts
(`macscp-cli --generate-completion-script zsh|bash|fish`); what is
missing is the dynamic half. Every command that takes a target
(`ls`, `get`, `put`, `rm`, `mkdir` — the arguments that go through
`SessionReference.parse`) declares its `@Argument(completion: .custom(...))`
with ONE shared completer, `SessionNameCompletion`, which (a) returns
nothing unless the word being completed has no `/` yet (once the path
starts, the shell's file completion is wrong anyway and a remote listing
is out of the question — no connection), (b) lists `SessionCatalog(...).rows(matching:)`
names with a trailing `:`, filtered by the typed prefix, (c) opens the
store the same way `SessionsCommand` does and NOTHING else — the
forbidden-symbol guard that already covers `SessionsCommand`
(`CLISessionsCommandGuardTests`) is extended to the completer's file with
the same list (no `SecretStore`, `SecretResolver`, `connect(`,
`withConnection(`, `KnownHostsStore`, `RemoteFileSystem`, …). The custom
completion runs in a subprocess the shell script spawns
(`macscp-cli ---completion ...`), so it must be fast and silent: no
logging, no prompts, an empty list on any error.

**Tech Stack:** `swift-argument-parser` (the version pinned in
`Package.resolved` — read `CompletionKind.custom`'s exact closure
signature in `.build/checkouts/swift-argument-parser/Sources/ArgumentParser/Parsable Properties/CompletionKind.swift`
before writing the completer; the signature changed across 1.x releases),
`SessionCatalog`, `SessionStore`, the guard suites under
`Tests/macSCPCoreTests/CLI*`.

**Source:** `docs/superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md`
("Decided 2026-09-02 — item 2"), `2026-08-03-m20-cli-design.md`.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **The completer reads the session store and nothing else.** No secret,
  keychain, known-hosts, login set, or connection symbol in its file —
  pinned by the extended forbidden-symbol guard (negative checks beside
  the positive anchor `SessionCatalog(`).
- **Silent and fast:** no output on stderr, no prompt, an empty list on
  any failure; the guard also forbids `print(`/`FileHandle.standardError`
  in the completer beyond the list it returns.
- **Names only, never paths:** the completer never suggests a remote
  path (it cannot know one without connecting).
- The generated scripts are not committed; the README shows the one
  command that emits them.
- Swift 6; warning budget 1; TDD red first; commit per task; do not push.

---

### Task 1: The completer and its guard

**Files:**
- Create: `Sources/MacSCPCLI/SessionNameCompletion.swift`
  (`enum SessionNameCompletion { static let kind: CompletionKind; static func complete(prefix: String) -> [String] }`)
- Modify: `Sources/MacSCPCLI/LsCommand.swift`, `GetCommand.swift`,
  `PutCommand.swift`, `RmCommand.swift`, `MkdirCommand.swift` — the
  target `@Argument`s gain `completion: SessionNameCompletion.kind`
  (`put`'s SOURCE is a local file: leave it on the default file
  completion; only the `name:/path` side gets the completer)
- Test: `Tests/macSCPCoreTests/CLISessionNameCompletionTests.swift`
  (ungated: with a temp session store holding "Work", "Web-01",
  "Prod / DB" — the catalog's naming — `complete(prefix: "W")` →
  `["Web-01:", "Work:"]` (sorted, trailing colon), `complete(prefix: "Web-01:/")`
  → `[]`, an unreadable store → `[]` and no throw; the store is opened
  through the same injection point `SessionsCommand` uses — read it) and
  the extended guard in `CLISessionsCommandGuardTests.swift` (scan the
  new file with the same forbidden list + `print(`; positive anchor
  `SessionCatalog(`; count the five commands' target arguments carrying
  `completion:` — a positive count check, so a sixth command without it
  turns red when added).

- [ ] Red → green; `swift build`'s `macscp-cli --generate-completion-script zsh` emits a script naming the five commands (assert in a test that runs the binary the way `CLISessionsJSONRoundtripTests` does, bundle-relative); commit `feat(cli): complete session names from the store, and nothing else`.

### Task 2: The root command explains `name:/path`

**Files:**
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift` (`discussion:` on the root
  `CommandConfiguration`: what `name:/path` is, that the name is a saved
  session, that `sessions` lists them, that tab completion offers the
  names; one paragraph; the exact text is the implementer's, in the
  register of the existing `SessionsCommand` discussion)
- Test: the existing help-text test style (grep `Tests` for `--help`
  assertions on the CLI) — the root help contains `name:/path`.

- [ ] Red → green; commit `docs(cli): the root help explains name:/path`.

### Task 3: Closeout

- [ ] README's CLI section: the three `--generate-completion-script`
  lines and where each shell sources them; `docs/superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md`
  ("Done — items 2 and 3"), `docs/BACKLOG.md` row; commit
  `docs(backlog): CLI completion and the name:/path help, done`.

## What is explicitly not in this plan

- No remote path completion (would need a connection).
- No completion for `--group`/`--tag` values (cheap later, same completer
  family; not asked).
