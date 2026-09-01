# Snippets Round 2 + De-Kernelizing the App Layer (Design)

**Status:** 2026-08-10. Prompted by the maintainer feedback after the first
dev build of the terminal snippets (`1.2.0-dev`, build 891).

## The Finding

The first cut was usable for someone who knows the code, and unfindable for
everyone else. The maintainer's question, verbatim, was "where do I run
snippets against a host????" — and the answer was: only via the menu bar
under "Terminal", nowhere else. That was my recommendation in the first
brainstorming session and it was too narrow.

On top of that came an objection to the "runs immediately" marker: the
decision is made at **creation** time, but takes effect at **trigger** time,
where the host is fixed and visible. The first draft cushioned this with
grouping in the menu; that is not enough.

## The Resolution: Running Moves

The checkbox disappears from the snippet. In its place come **two actions at
every trigger surface**: "Insert" and "Run". This puts the sharp decision
exactly where the context is visible, and a snippet goes back to being what
it should be: text.

This is stricter than the current state, not looser. Today a snippet can be
live without anyone noticing; afterward every run has to be clicked.

## The Cut

The feedback comprises eleven points — three on the data model, four on the
window layout, the rest on trigger surfaces. That is not one milestone, but
five phases. P2 has been decided since 2026-08-12, P3 remains a sketch:

| Phase | Content | Why this order |
|---|---|---|
| **PV** | Pre-trial: can SwiftUI views in this package be tested at all? | The result determines what P0 looks like — and the question gets answered, not guessed |
| **P0** | De-kernelizing `ContentView`: sub-views into their own files, pure logic moved to Core with tests | P1 adds a header, a popover, and a context menu — those would otherwise land **in** the monolith and make it bigger |
| **P1** | Snippets reachable: flag gone → two actions, tags, context menu on the host, terminal header with popover, right-click in the terminal | answers the actual finding |
| **P2** | Terminal framing: margin 14/8, two toolbar switches for files and terminal, state per saved session | layout work, unrelated to snippets — the tab type is dropped, see below |
| **P3** | Organization: host tags on `StoredSession` + sidebar filter, snippet import/export | last, because P1 is what shows how tags feel before they migrate to the session model a second time |

The **bulk runner** (run a snippet against n filtered hosts, output view) is
explicitly **not** part of this. It is its own tool — n parallel
connections, partial failures, cancellation, keeping n output streams
readable — and gets its own brainstorming session. P3's host filter is the
selection mechanism it later builds on.

---

## PV — Pre-trial: are views testable?

**The question.** The app layer is untested today — that is the boundary
that M29 exposed, and it let three bugs through in Round 1. Before another
phase takes that boundary as a given, it gets checked.

**What needs to be clarified**, in this order:

1. Can a SwiftUI view from `MacSCPAppKit` even be instantiated in
   `macSCPAppKitTests` and examined for its content — whether via hierarchy
   inspection or via a rendered snapshot?
2. Does this coexist with **Swift Testing** (`@Test`/`#expect`)? The common
   tools are XCTest-oriented; whether the two can coexist in the same
   target is open.
3. Does it run in **CI without a GUI session**? A tool that only works
   locally shifts the problem rather than solving it.
4. What does it cost in dependencies? The package has few today, and a test
   dependency that pins a toolchain version is expensive.

**Time-boxed.** The pre-trial is a trial, not a milestone: it ends with a
yes **plus a runnable example test against a real view of this project**,
or with a proven no plus a reason. A "probably works" is not a result.

**The result is a fork, not a mandate.** If it comes out positive, the
maintainer decides whether P0 covers the views too. If it comes out
negative, P0 falls back to the alternative: move as much decision logic to
Core as possible, so that only drawing is left in the views.

This spec deliberately does **not** commit to view tests being possible.
Round 1 showed what an unchecked assumption in a spec costs: there it said
`\n`, and the correct value was `0x0D`.

---

## P0 — De-kernelizing the app layer

### The starting state, measured

| File | Lines |
|---|---|
| `ContentView.swift` | 3464 (of which ~3330 in **one** `View` struct starting at `struct ContentView`) |
| `SettingsView.swift` | 1306 |
| `RemoteFileTableView.swift` | 1050 |
| `LoginSetsSheet.swift` | 1048 |
| `ConnectionFormView.swift` | 1001 |
| **App layer total** | 15 909 |

A fifth of the app layer sits in one file. Only `ContentView` is the
subject of this phase; the other four stay where they are.

### Two kinds of work, deliberately in one phase

**Splitting** moves lines around and makes them readable. **Extracting**
makes them checkable. Only the second has lasting value — it is exactly the
line M29-P2 drew with the submit path, where M28's Critical was for the
first time held by a test afterward.

Candidates for the move to Core are anything that makes a **decision**
rather than drawing something: which warning message appears, when a
command hits a backend without a shell, which route is taken to the
external terminal, which state transition follows an event.

**The list of extractions is a hypothesis, not a mandate.** The plan
measures the file and names the actual cuts; this spec only fixes what is
searched for.

### The guarantee

**Splitting changes no behavior.** Extracting changes structure *and*
produces tests — a move to Core without a test is not a move, it is a
relocation.

### The countermeasure against the real danger

Views are untested in this project (the boundary from M29), and the most
dangerous class of bug is the silent swallow: a `@State` that migrates into
the wrong struct while moving breaks nothing visibly — it just stops
updating, and **no test goes red**.

Therefore: **small, individually committed steps**, build plus full suite
per extraction. A `git bisect` then finds the culprit, instead of having to
judge a 3000-line diff all at once. A dev build at the end of the phase is
mandatory, and the closing report states explicitly that visual inspection
is the maintainer's responsibility.

---

## P1 — Snippets reachable

### Model

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var tags: [String]
}
```

`runsImmediately` is removed.

### Migrating existing stores

When decoding a `snippets.json` from the first cut:

- `runsImmediately` is **ignored**. A snippet previously marked as
  executing becomes an ordinary one. Information is lost, deliberately —
  the marker was the thing meant to go away. Running remains possible,
  just per trigger.
- `tags` is missing and becomes the empty list.

The existing rejection of embedded newlines (`\n`, `\r`) in the command
stays unchanged and remains a **model rule**, which also applies to a
hand-edited file.

### Tag rule (maintainer decision 2026-08-10)

- **Trim only.** Outer whitespace is dropped; capitalization is preserved
  as typed.
- A tag that is empty after trimming is rejected.
- **Exact** duplicates on the same snippet are dropped. `Docker` and
  `docker` are two different tags and both stay — that is the consequence
  of the decision and is not quietly softened.
- The rule lives on the model, not the form, and thus also applies to a
  hand-edited file.
- **The order stays as entered.** `tags` is a list, not a set; sorting
  happens only at display time.

**The duplicate risk is dampened at input, not at storage:** the suggestion
list searches **case-insensitively**. Someone typing `doc` gets an existing
`Docker` offered and picks it, instead of creating a second one. What gets
stored is nonetheless exactly what was typed.

### The tag input field

Token field instead of free text: each set tag is a chip with a remove
button. Typing opens a suggestion list with the existing tags plus counts;
the **last entry is always** "create *x* as a new tag". A new tag is thus
never created accidentally — exactly there is where duplicates otherwise
arise.

The same field is reused for host tags in P3.

### Filter in the management sheet

A chip row under the existing search field: "All" plus one chip per tag
with a count, plus a "no tag" chip — otherwise exactly the snippets that
have not yet been sorted into a tag become unfindable.

**Single-valued, not multi-valued.** One chip at a time. Multi-selection
would need an and/or semantics that nobody has asked for; if the bulk
runner needs it later, that is its own decision.

### The bytes

`SnippetKeystrokes.bytes(for:execute:)` — the flag moves from the snippet
to the call. The `0x0D` **measured** in Round 1 (CR, which is what pressing
Enter actually sends via SwiftTerm's `insertNewline` → `EscapeSequences.cmdRet`)
stays unchanged and stays pinned.

**Inserting never appends a line ending**, regardless of the caller. That
is a guarantee with a test, not a caller detail.

### `SnippetMenuModel` (Core)

One type, four surfaces. Input: the snippets, an optional tag filter, the
connection state. Output: the finished structure — groups per tag
(untagged snippets last), title and the two actions per entry, and the
reason in the disabled case.

The reason for one type instead of four derivations: the app layer is
practically untestable, Core fully is — and the project has already paid
the lesson that **two code locations answering the same question drift
apart**. With four it would be worse.

`SnippetsLoad` stays unchanged: an **unreadable** store must never look
like an **empty** one.

### The four trigger surfaces

| Surface | Content |
|---|---|
| "Terminal" menu bar | Submenu per tag instead of a flat list. ⌃⌘1–3 **insert** the first three snippets in storage order |
| Context menu on the host (sidebar) | "Snippet" entry with the same groups |
| Terminal header | host on the left, snippet button on the right, popover with search field and groups |
| Right-click in the terminal | the same entries |

**Running gets no keyboard shortcut.** A keystroke that runs immediately on
a host has no good failure case.

Disabling everywhere uses the condition the two existing terminal entries
already use (`!isActiveTabConnected || !activeTabSupportsShell`); on the
host context menu, correspondingly via
`BackendDescriptor…capabilities.supportsShell`, so S3 and WebDAV sessions
show the entry grayed out instead of running into nothing.

The **shortcuts catalog from M11q is kept up to date** — it is maintained
by hand and its own doc comment names that as a requirement.

### What must be measured instead of assumed

1. **Does SwiftTerm already occupy the right-click?** Usually with
   "Paste". If so, this attaches to the existing menu rather than
   overwriting it. The implementer determines this and records the
   result.
2. **How much margin does the terminal panel actually have today?** The
   number gets measured, not estimated — and only changed in P2.

This spec deliberately does not commit on either point. Round 1 showed
what that costs: there it said `\n` in the spec, and the correct value was
`0x0D`.

---

## P2 — Terminal framing (decided 2026-08-12)

The original draft envisioned a **dedicated terminal tab type**
("Open terminal only" would build only a shell, no SFTP). **Dropped.**
Two reasons, the second is the better one:

1. My description was too optimistic. Establishing the connection yields
   a `RemoteFileSystem` — **the file system is the connection**;
   `BrowserSession` is built from it in one step and the terminal attaches
   as a child channel. A session without SFTP would be a change to what
   "connected" means, not a flag.
2. The maintainer's proposal is simpler **and** covers more: the
   visibility of both halves is toggled in the toolbar, where the terminal
   switch (⌘T) and the transfers switch already sit. A pure terminal is
   then not a tab **type**, but a **state** any tab can enter and leave
   again.

### What gets built

- **Margin around the terminal: 14 horizontal / 8 vertical.** Measured:
  the terminal today sits **flush with no margin at all**, while the panes
  and the `.ended` text block in the same panel already use 14/8. The value
  is thus the existing rhythm, not an invented one. The header built in P1
  uses 12/6 and gets aligned to match, so header and terminal area do not
  end up two points apart.
- **A second toolbar switch, "Files"**, next to the existing "Terminal".
  Both toggle the visibility of their half.
- **The last active switch is locked** — both off would produce an empty
  window. It is shown as visibly disabled, not silently ineffective.
- **Without a shell there is no terminal switch** (S3, WebDAV): it stays
  gray, making "Files" the only one and thus locked.

### The state survives — per saved session

**Maintainer decision 2026-08-12.** `prod-web` will from now on open the
way it was last left. That is the most useful of the three variants (the
others were: don't remember at all, or a global default) — but it has a
consequence that belongs here rather than surprising later:

**It moves into the `StoredSession` format and thus into export/import.**
Since M23-P3 the format is a bag that tolerates extra fields without
migration, and the import arbiter already handles unknown fields. So it is
not a format break — but it is also **no longer a pure view rebuild**, and
the export round-trip tests need to carry it too.

A separate window remains excluded: multi-window is v2 per project rule.

## P3 — Organization (sketch — superseded)

> **Decided and split since 2026-08-18.** The worked-out version lives in
> `2026-08-18-p3-ordnung-design.md` and splits P3 into
> **P3a** (host tags + sidebar filter) and **P3b** (snippet exchange).
> The three decisions below continue to apply there unchanged.

- **Host tags** on `StoredSession`: a field in the form, carried in
  export/import, filter in the sidebar. Groups from M5f remain the
  storage, tags become the view onto it — they do not replace each other.
- **No connection to snippet tags.** A host tag hides no snippet; the two
  vocabularies are independent. The binding ("a snippet tagged `docker`
  only appears on hosts tagged `docker`") is explicitly rejected.
- **Snippet import/export** via the envelope machinery from M19. Snippets
  contain no secrets; the format therefore needs no crypto path, but does
  need the same conflict arbiter.

---

## Snippets still contain no credentials

Unchanged from Round 1, and the reason stays the same: the store is JSON,
and secrets live exclusively in the keychain. The three counter-proposals
raised in the first brainstorming session (passwordless SSH, retroactively
deleting history, a dedicated shell instead of the login shell) are
rejected with reasoning in
`docs/superpowers/specs/2026-08-10-terminal-snippets-design.md`.

Anyone who needs real credentials in the terminal gets them via
**agent forwarding** — its own milestone, in the backlog since M10d.

The import/export in P3 changes nothing about this: a format without
secrets needs no encryption, and none gets invented that would only
pretend to provide security.

---

## Success criteria

| # | Criterion | Proof |
|---|---|---|
| 1 | A `snippets.json` from Round 1 loads; `runsImmediately` disappears, `tags` is empty | test against a literal legacy file |
| 2 | Inserting **never** appends a line ending, running exactly one (`0x0D`) | test on the generated bytes, both call types |
| 3 | A tag is trimmed, empty ones rejected, exact duplicates dropped, case preserved | test, also for a hand-written store |
| 4 | The suggestion list finds `Docker` given input `doc` | test on the suggestion matcher |
| 5 | `SnippetMenuModel` groups by tags, untagged last, and returns the disabled reason | test |
| 6 | An unreadable store does not look like an empty one | existing test stays green |
| 7 | All four trigger surfaces show the same entries | review — they read from **one** model, that is the proof in the code |
| 8 | Without a connected session or without a shell, the entries are disabled | review; app-side |
| 9 | P0 changes no behavior | full suite per step + dev build; **visual inspection is the maintainer's responsibility** |
| 10 | All four catalogs carry the new keys | existing guard test, `plutil -lint` |
| 11 | The shortcuts catalog names the shortcuts correctly | review against the catalog |
| 12 | PV ends with a runnable example test against a real view **or** a proven no | the test runs, or the report names the reason — "probably" does not count |

## Testability, honestly

Model, migration, tag rule, suggestion matcher, `SnippetMenuModel`, and the
byte generation live in Core and are fully pinned.

**The four trigger surfaces themselves stay unpinned — pending PV.** If the
pre-trial comes out positive and the maintainer decides to bring in the
tool, this paragraph changes; until then it stands.

It is the same boundary as last time — and it let three bugs through in
Round 1 that only the whole-branch review found: the wrong closing byte,
dropped bytes before opening the shell, and a `try?` that made an unreadable
store indistinguishable from an empty one. None of them would have made a
test go red.

The closing report says this again explicitly, instead of presenting
visual inspections as proof. Criteria 7, 8, and 9 are review points, not
tests.

## What explicitly does **not** belong here

- **The bulk runner** over filtered hosts plus output view — its own
  brainstorming session, its own milestone.
- **Multi-line commands and syntax highlighting.** Both only get an honest
  home with the runner: as long as "insert" is the normal case, a
  multi-line snippet would run everything but the last line immediately,
  without anyone having pressed Enter.
- **Placeholders** (`{{path}}`, current directory).
- **Binding snippets to hosts, groups, or protocols.**
- **Agent forwarding.**
- **Multi-window** (v2).
- `SettingsView`, `RemoteFileTableView`, `LoginSetsSheet`, and
  `ConnectionFormView` — P0 touches only `ContentView`.

## For the release notes

**One sentence.** Snippets can be organized with tags and inserted or run
directly at the host or in the terminal.
