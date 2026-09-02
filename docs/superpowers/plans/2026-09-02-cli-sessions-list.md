# CLI: `sessions` — the Session List — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `macscp-cli sessions` prints the saved sessions — filterable by
group, kind, name and tag, `--json` like every other command — without
touching the keychain, resolving a login set, or opening a connection.
Item 1 of `docs/superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md`;
item 2 (completion) is not in this plan.

**Architecture:** The query is a pure value in Core —
`SessionCatalog` (`Sources/macSCPCore/Sessions/SessionCatalog.swift`):
built from `[StoredSession]` + `[StoredGroup]`, it answers
`rows(matching: Filter) -> [Row]` where a `Row` carries name, kind, group
path ("Work / Prod"), tags, and a `target` string derived per kind
(`user@host:port` for SSH, `bucket @ endpoint` for S3, the URL for WebDAV)
— and nothing else: no ids of secrets, no key paths, no login-set ids. The
CLI command `SessionsCommand` (`Sources/MacSCPCLI/SessionsCommand.swift`)
parses the filters, reads the store, and prints rows through
`OutputFormatter`. The security constraint becomes structural: the
command file imports nothing that can reach a secret, and a
source-scanning guard with a positive anchor pins that.

**Tech Stack:** Swift 6, Swift Testing, swift-argument-parser (already a
dependency of `MacSCPCLI`), `SessionStore.all()`/`allGroups()`,
`OutputFormatter`, `GlobalOptions.json`.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
  Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **No secret, no keychain, no connection.** The listing reads the session
  store only (`SessionStore`, which by project invariant holds no secrets).
  `SessionsCommand.swift` must not name `SecretStore`, `SecretResolver`,
  `secretSources`, `connect(`, `withConnection(`, `KnownHostsStore` — a
  guard pins that, with a positive check that the file exists and names
  `SessionStore`/`SessionCatalog`. The Core `Row` type carries no `UUID` of
  a secret, no `keyPath`, no `loginSetID`.
- `--json` follows `OutputFormatter`'s rule: switched by the flag only,
  never by a TTY; one JSON object per line; `null` for absent values.
- Filters are ANDed. `--name` is a case-insensitive **substring** match
  (say so in the help text — not a glob, not a regex). `--group` matches
  the group's own name or any ancestor's, case-insensitively. `--kind`
  takes `ssh|s3|webdav`. `--tag` matches exactly, case-insensitively.
- Output order: the store's sidebar order (position within group, groups
  as the sidebar shows them) — use `SidebarOrdering`/`GroupTree` if Core
  already computes that order; do not invent a second ordering.
- Help: every new command/option has a one-line `abstract` AND the
  command gets a `discussion` explaining that `name:/path` in the other
  commands refers to the `name` column printed here.
- `.swiftLanguageMode(.v6)`; warning budget 1 on a fresh scratch path.
- TDD, red first. Commit per task. Do not push.

---

### Task 1: `SessionCatalog` in Core

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionCatalog.swift`
- Test: `Tests/macSCPCoreTests/SessionCatalogTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SessionCatalog: Sendable {
    public struct Filter: Sendable, Equatable {
        public var group: String?; public var kind: ConnectionKind?
        public var name: String?; public var tag: String?
        public init(group: String? = nil, kind: ConnectionKind? = nil, name: String? = nil, tag: String? = nil)
    }
    public struct Row: Sendable, Equatable {
        public let name: String
        public let kind: ConnectionKind
        /// "Work / Prod" — ancestors first, joined by " / "; empty for top level.
        public let groupPath: String
        public let tags: [String]
        /// Per kind: `user@host:port` (SSH), `bucket @ endpoint` (S3), the URL (WebDAV).
        public let target: String
    }
    public init(sessions: [StoredSession], groups: [StoredGroup])
    public func rows(matching filter: Filter) -> [Row]
}
```

- [ ] **Step 1: Red.** Tests, each with a hand-built store in memory (no
  disk): (a) no filter → every session, in sidebar order (build two groups
  and three sessions with explicit `position`s and assert the order; find
  how `SidebarOrdering` derives it — `grep -rn "struct SidebarOrdering\|enum SidebarOrdering" Sources`);
  (b) `--group` matches by ancestor name; (c) `kind`; (d) `name` substring,
  case-insensitive, no glob (`"pro*"` matches nothing); (e) `tag`;
  (f) filters AND; (g) `target` per kind — one SSH (`user@host:port`,
  port shown always), one S3, one WebDAV; (h) **the secrecy shape**:
  `Row` has no property that can carry a `keyPath`, a `loginSetID` or a
  secret id — assert by constructing a session WITH those set and checking
  the row's `Mirror` children names contain none of `keyPath`,
  `loginSetID`, `secretID` (a structural check, not a string search on
  values).
- [ ] **Step 2: Implement** the value. Doc comment: what it is for (the
  CLI list, and item 2's completion later), and why it carries nothing
  a secret could hide behind.
- [ ] **Step 3:** `swift test --filter SessionCatalogTests` green; full unit suite once.
- [ ] **Step 4: Commit** — `feat(sessions): a catalog value that lists and filters stored sessions`

---

### Task 2: `macscp-cli sessions`

**Files:**
- Create: `Sources/MacSCPCLI/SessionsCommand.swift`
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift` (register the subcommand;
  update the dispatcher's doc comment, which enumerates commands by
  milestone — count them), `Sources/MacSCPCLI/OutputFormatter.swift`
  (a `print(rows:asJSON:)` beside `print(items:asJSON:)`)
- Test: `Tests/macSCPCoreTests/CLISessionsCommandGuardTests.swift` (the
  source-scanning guard) — and, if the CLI's roundtrip suite
  (`CLIRoundtripITests`, gated) has a pattern for running the binary
  against a temp store, one gated case that runs `sessions --json` and
  parses a line.

- [ ] **Step 1: Red — the guard first.** A source-scanning test over
  `Sources/MacSCPCLI/SessionsCommand.swift` (locate the file from
  `#filePath` the way the other guards do): POSITIVE — the file exists and
  contains `SessionStore(` and `SessionCatalog(`; NEGATIVE — it contains
  none of `SecretStore`, `SecretResolver`, `secretSources(`, `connect(`,
  `withConnection(`, `KnownHostsStore`. Also a self-test that plants
  `secretSources(` in a fixture string and expects the scanner to flag it.
  Red because the file does not exist yet.
- [ ] **Step 2: Implement.**

```swift
struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List the saved sessions.",
        discussion: """
            Every other command addresses a session as name:/path — the name \
            is the first column here. Filters combine; --name matches a \
            case-insensitive substring, not a pattern. Nothing here reads \
            the keychain or opens a connection.
            """)
    @OptionGroup var options: GlobalOptions
    @Option(name: .long, help: "Only sessions in this group or one of its subgroups.") var group: String?
    @Option(name: .long, help: "Only this backend: ssh, s3 or webdav.") var kind: ConnectionKind?
    @Option(name: .long, help: "Only names containing this text (case-insensitive substring).") var name: String?
    @Option(name: .long, help: "Only sessions carrying this tag.") var tag: String?

    func run() async throws {
        let store = SessionStore(directory: SessionStore.defaultDirectory)
        let catalog = SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
        let rows = catalog.rows(matching: .init(group: group, kind: kind, name: name, tag: tag))
        OutputFormatter.print(rows: rows, asJSON: options.json)
    }
}
```

  `ConnectionKind` needs `ExpressibleByArgument` — add the conformance in
  the CLI target (`ConflictAction+ArgumentParser.swift` shows where such
  conformances live). Columns: `name`, `kind`, `target`, `group`, `tags`
  (tab-separated like `ls`); JSON keys the same, `group` and `tags` may be
  `""`/`[]` — pick the representation `OutputFormatter.print(items:)`'s
  doc would pick and say why.
- [ ] **Step 3:** Guard green; `swift build`; `swift run macscp-cli sessions --help`
  output pasted into the report; if a temp-store roundtrip is feasible
  (`CLIRoundtripITests` pattern with `MACSCP_ITEST=1`), one case; full
  unit suite; warnings on a fresh scratch path.
- [ ] **Step 4: Commit** — `feat(cli): list the saved sessions with filters and --json`

---

### Task 3: Entry and index

**Files:**
- Modify: `docs/superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md`, `docs/BACKLOG.md`

- [ ] **Step 1:** "Done 2026-09-0x — item 1": the value, the command, the
  guard, the filters as they are (substring, not glob), what is NOT there
  (completion; remote paths). Index row to match.
- [ ] **Step 2: Commit** — `docs(backlog): the CLI lists sessions; completion stays open`

## What is explicitly not in this plan

- Completion (item 2) — its own design question (session names only vs remote paths).
- Any change to how other commands parse `name:/path`.
- Printing anything a login set or keychain holds.
