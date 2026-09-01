# Terminal Snippets (Design)

**As of:** 2026-08-10. A backlog feature never commissioned, first design.

## What it is

Reusable command lines that can be inserted into the SSH terminal panel.
Maintained globally, triggered via a menu.

The attachment point is narrow: `TerminalPanelViewModel.send(_ bytes:
[UInt8])` sends bytes to the given tab's shell. A snippet is
"text → bytes → send". The substance of the milestone is not in the
mechanics but in two decisions about risk.

## The two risk decisions

### Inserting is the default, executing is marked

A snippet lands in the input line; the user presses Enter. They see
beforehand what would run on which host.

However, every snippet can be flagged as **runs immediately**
(maintainer decision, 2026-08-10). The objection raised against this was:
the decision is made at **creation** time but takes effect at
**trigger** time, where nobody remembers any more which entries are live.

**The design resolves the objection instead of overruling it:** two
sections in the menu — inserting ones on top, executing ones below under
their own heading. A grouping carries this meaning more reliably than an
icon on the entry, and it sidesteps the M19a icon rule as well.

**Correction to the first draft:** it had proposed a dedicated "Snippets"
menu. While sizing the plan, it turned out there **already is a
`CommandMenu("Terminal")`**, with "Show/Hide Terminal" and "Open in
External Terminal". Snippets belong there, not in a second entry point
for the same thing.

### Snippets contain no credentials

The store is JSON, and the project rule is unambiguous: secrets live
exclusively in the keychain, JSON stores never contain any.

Three counterproposals came up during brainstorming. They are recorded
here because they sound plausible and **do not hold up**:

| Proposal | Why it doesn't hold |
|---|---|
| Passwordless SSH instead of passwords | Solves a different problem. macSCP's **own** connection has supported keys and agent since M10d. The snippet problem sits deeper: commands that need a password **on the target host** (`mysql -p`, `sudo`, a second hop). For the second hop, **agent forwarding** would be the answer — explicitly excluded in M10d and tracked in the backlog as its own milestone. |
| Delete history afterward | Protects nothing and does damage. The command sits in `ps` during execution, where any other user of the machine sees it — nothing after the fact helps against that. On top of that, macSCP would be manipulating someone else's shell history, shell-specific (bash/zsh/fish differ), and would delete entries the user wanted to keep. |
| A dedicated shell instead of the login shell | Sidesteps the history file, but `ps` remains. And the panel would no longer be **the user's own** shell: prompt, aliases, environment would be gone. High cost, partial benefit, and a change to the whole terminal instead of to snippets. |

**What holds:** credentials do not belong on the command line — neither
in a snippet nor typed by hand. The tools have their own paths
(`mysql --defaults-file`, `sudo -S` via stdin, SSH with a key).
The editor says so, with reasoning, instead of faking security.

Anyone who later needs real credentials in the terminal gets them via
**agent forwarding** as its own feature — not via a password field on
snippets.

## Model and storage

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var runsImmediately: Bool
}
```

`SnippetStore` writes `snippets.json` into the same directory as
`known_hosts.json` and `managed_keys.json` — the same construction as
`KnownHostsStore`: stateless, atomic writes, no secrets.

**Global, not per host.** Like login sets and managed keys. Nobody has
asked for binding to individual sessions, and that would drag along
export, import, and groups.

## A snippet is exactly one command line

**Embedded line breaks are rejected on save.** Otherwise "insert" would
be a lie: every line but the last would run immediately, without
anyone pressing Enter. Multi-line scripts are a different feature.

The rejection is a store/model rule, not a form detail — it must also
hold for a hand-edited `snippets.json`.

## Triggering

`send(Array(command.utf8))`, followed by the line-terminator byte when
`runsImmediately`. That is all it is; the far end is a real PTY and
shows the inserted text in its own input line.

> **Which byte is to be checked, not guessed.** On a terminal, the
> Enter key usually sends **CR** (`0x0D`), not LF
> (`0x0A`) — a `\n` can be inert under a PTY's line discipline,
> and then a snippet marked "runs immediately" executes nothing.
> The implementer determines what SwiftTerm and the far end actually
> send for the Enter key, and pins the result in a test.
> **This spec deliberately does not commit to an answer**; it only
> commits to the answer being measured.

**Without a connected session in the active tab, the menu entries are
disabled** — there is no `send` target, and an entry that fires into
nothing is worse than one that is greyed out.

The condition is not to be reinvented: the two existing entries in the
Terminal menu already use
`!tabCommands.isActiveTabConnected || !tabCommands.activeTabSupportsShell`.
Snippets adopt the same one.

## Management

A sheet like login sets and SSH keys: list, search field (the
`SheetSearchField` from M18 already exists), create, edit,
delete. The credentials notice lives there.

**The shortcuts catalog from M11q is kept in sync**: it is hand
maintained, and its own doc comment names this as a requirement for
every shortcut change.

## What explicitly does **not** belong here

- **Placeholders** (`{{path}}`, current directory).
- **Export/import.** The envelope machinery from M19 exists for this,
  but nobody has asked for it; snippets contain no secrets, and a later
  rebuild is cheap.
- **Binding to hosts, groups, or protocols.**
- **Multi-line scripts.**
- **Agent forwarding** — its own milestone, see above.

## Success criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | An inserted snippet ends **without** a line terminator | test over the generated bytes |
| 2 | An executing snippet ends with **exactly one** line terminator, namely the one the Enter key sends | test over the generated bytes; the byte is measured, not assumed (see above) |
| 3 | A command with a line break is rejected | test, including for a hand-written store content |
| 4 | The store survives a write and read unchanged | round-trip test |
| 5 | A missing store returns an empty list, not an error | test — the same guarantee as `KnownHostsStore` |
| 6 | Executing snippets appear in the menu in their own section | review; app-side, no test possible |
| 7 | Without a connected session, the entries are disabled | review; app-side |
| 8 | The store never contains a secret | review; the rule is a doc commitment on the type |
| 9 | All four catalogs carry the new keys | existing guard test, `plutil -lint` |
| 10 | The shortcuts catalog names the new shortcut | review against the catalog |

## Testability, honestly

Store, model, the newline rejection, and the byte encoding sit in Core
and are fully testable. **The menu wiring is app-side and stays
unpinned** — the same boundary M29 exposed: there is no view test
tooling in the project, and that is a deliberate decision.

Criteria 6 and 7 are therefore review points, not tests, and the
closing report must say so.

## For the release notes

**One sentence.** Frequently used commands can be saved as snippets and
inserted into the terminal.

## Open, deliberately not part of this

- Agent forwarding (its own milestone, backlog since M10d).
- Placeholders, export/import, multi-line scripts.
- M29-P3: hollowing out the rest of `ContentView`.
- The release backlog: 410 commits ahead of `origin/main`.
