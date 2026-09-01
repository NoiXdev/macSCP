# P3 — Order: Host Tags, Sidebar Filter, Snippet Exchange

Decided 2026-08-18. Formally supersedes the sketch section "P3 — Order" from
`2026-08-10-snippets-round-2-design.md`. The three decisions made there
continue to hold unchanged and are not renegotiated here: groups remain the
storage, tags the view onto it; host tags and snippet tags are independent
vocabularies; the exchange format gets no crypto path.

## The measured starting state

Checked, not assumed:

- **The sidebar has no search field and no filter.** `SessionSidebar`
  runs unfiltered through `SessionListViewModel.sessions(inGroup:)`. Neither
  `searchText` nor a filter function exists. A tag filter is therefore not
  "one more filter," it's the first filtering element at all.
- **The sidebar has no empty state.** If the list is empty, nothing renders.
  The existing red error lines only cover error cases.
- **Groups are native `Section(isExpanded:)` blocks**, collapsed groups sit
  in a `Set<UUID>` in view state.
- **The "IMPORTED" section** (`~/.ssh/config`) is its own section next to
  the groups.
- **`StoredSession`** today carries `id`, `name`, `groupID`, `loginSetID`,
  `kind`, the three backend configurations, and `paneVisibility`. The two
  non-connection fields `groupID` and `paneVisibility` are both read via
  `decodeIfPresent` and carried through export
  (`ExportedSession.paneVisibility`, `encodeIfPresent`).
- **The snippet tag rule** lives in `Snippet.init`: trim, drop empties, drop
  exact duplicates (case is preserved), order of first occurrence.
- **The envelope machinery** is already generic: `ExportEnvelopeCodec`
  with `encode/probe/decode` over an arbitrary `Codable` payload, and
  `password: String?` — with `nil` the result is a plaintext payload with
  `encrypted: false`. Two formats use it: `macscp-sessions` and
  `macscp-logins`. The conflict arbiter (`ImportConflict`,
  `ImportConflictArbiter`) is shared by both planners.
- **`SnippetStore`** writes `snippets.json` as a **bare array with no
  version field**. No export or import path for snippets exists.

## The cut: two sub-phases

P3 bundles two efforts that share nothing but the word "tag." They are
built and closed separately.

| Phase | Content | Why separate |
|---|---|---|
| **P3a** | host tags on `StoredSession`, form field, export/import, chip filter in the sidebar, empty state | its own, self-contained subject |
| **P3b** | exchange format `macscp-snippets`, codec, planner, export/import sheets | shares no file with P3a except the tag rule |

The reason is not tidiness for its own sake. The whole-phase review at the
end has, in recent passes, delivered findings that no task review could see
precisely because it was looking at **one** coherent thing. Two unrelated
subsystems in one pass weaken the review step that delivers the most here.

---

## P3a — Host tags and sidebar filter

### One rule, two vocabularies

The normalization from `Snippet.init` moves to Core as **one** function.
`Snippet` and `StoredSession` both call the same function. The vocabularies
stay separate — a host tag hides no snippet, the binding remains explicitly
rejected — but the *rule* is not written down twice.

This is not a style question. Two copies of a rule that drift apart without
a test noticing is the mistake this project has paid for repeatedly of
late: most recently in P2, where a literally re-implemented visibility rule
could produce an empty window.

**Checkable:** a test that runs both callers against the same inputs and
requires the same result. It must turn red if either side reimplements the
rule itself.

### The field

`tags: [String]` on `StoredSession`, up top next to `groupID` and
`paneVisibility` — **not** in the backend field bag `FieldValues`, because a
tag is not a connection property but a property of the stored session.

- `decodeIfPresent` with a default of `[]`. An existing `sessions.json`
  without the field loads unchanged and behaves exactly as today.
- Carried through export, the way `paneVisibility` demonstrates.
- Entry in the connection form via the same token field used for snippets
  (`SnippetTagField`), provided it can be reused without contortion;
  otherwise a field that looks the same and uses the same rule. That is to
  be **measured** while building, not asserted up front.

### The filter

A chip row above the list, populated from the tags actually assigned.
Exactly one tag is active, or none.

- With a tag active, **groups with no match disappear entirely**, and the
  "IMPORTED" section disappears too — it can never match. The list then
  shows exactly the hosts with that tag, nothing else.
- The filter state is **not persisted**. It is a view, not a setting, and
  starts empty on every launch.
- If the last host with the active tag disappears (renamed, deleted, tag
  removed), the filter falls back to "no tag" instead of leaving an empty
  list standing.

### The empty state

The sidebar gets an empty state it does not have today. Without one, a
filter with no matches would be a silently empty window. Two distinguishable
cases, not one shared text:

- **no sessions exist at all** — the state of a fresh install
- **filter active, no match** — with a way back (clear the filter)

The second case is the reason for the first: it arrives regardless as soon
as the filter exists, and a shared text for both would talk about a filter
on a fresh install that nobody set.

### The decision logic belongs in Core

Which groups and which sessions are visible with an active tag, and which
of the two empty states applies, is a pure function of (sessions, groups,
active tag) — and belongs in Core as a testable type, not in the view body.
P2 showed how expensive the other option is: a display decision in the view
body there could only be secured with a source-scanning guard.

---

## P3b — Exporting and importing snippets

### The format

`macscp-snippets` via `ExportEnvelopeCodec`, with **`password: nil`,
always**. The signature accepts a password; this codec never passes one,
and that is pinned, not merely commented.

Snippets contain no credentials — the store is JSON, secrets live
exclusively in the keychain. Encryption would fake a security that isn't
there. This is the same rationale as in round 1 and it hasn't changed.

Its own UTType following the existing pattern
(`dev.noix.macscp.snippets`, conforming to `.json`).

### The planner

Its own planner on the **shared** `ImportConflictArbiter` — not a second
arbiter alongside it. **Duplicate by name**, as with login sets: an
imported "Clean up Docker" collides with an existing entry of the same
name, and the user decides overwrite, keep, or both.

The comparison follows the same trim rule as the tags, so that
"Clean up Docker " and "Clean up Docker" don't land as two entries.

### The interface

Export and import sheets following the pattern of the session sheets,
including selection at export time. The shared conflict sheet from M19 is
reused.

---

## What explicitly does not belong here

- **The bulk runner** (one snippet against n filtered hosts, an output
  view) stays out of scope. It's its own tool — n parallel connections,
  partial failures, cancellation, n readable output streams — and gets its
  own brainstorming session. P3a's filter is the selection mechanism it
  will build on.
- **A version field for `snippets.json`.** The store stays the bare array.
  The exchange file gets its version through the envelope. Migrating the
  store is a separate task.
- **Any binding between host tags and snippet tags.**
- **Multi-select in the filter** (two tags at once). One tag is enough for
  the purpose; the mechanism can be extended later without anyone having
  to answer the and/or question now.

## Success criteria

1. A `sessions.json` without `tags` loads unchanged and shows no tags.
2. A host with tag `docker` appears with filter `docker` active; a host
   without that tag does not; "IMPORTED" disappears.
3. Tags survive export and import.
4. Both empty states are distinguishable and, in the filter case, can be
   left again.
5. Snippets can be exported and read back in; a same-named snippet
   produces a conflict, not a silent overwrite.
6. The exported snippet file is plaintext and contains no field that
   claims encryption.

## Testability, honestly

What tests can hold: the tag rule and its shared use, the visibility
computation including the empty state as a Core type, migration against a
literal legacy file, the export round trip, the planner's duplicate rule,
and that the snippet codec never passes a password.

What tests do **not** hold here: that the chip row looks good in the
window, that the token field feels right in the connection form, and that
the sidebar actually behaves as described with the filter active. The App
target has no view-instantiation tooling; in P2 all that was left for this
was a source-scanning guard, whose limits are documented. These points
belong in the maintainer's visual review at the end of the phase and are
listed there by name, not silently passed over.

---

## Addendum 2026-08-18: Terminal from the host context menu (P3c)

Maintainer feedback after P3a's dev build. **Not** part of P3b; its own
small phase.

A stored session's context menu gets two entries under "Connect":

- **"Open Terminal"** — connects within macSCP and comes up **without the
  file browser**, i.e. terminal only. The mechanism for this has existed
  since P2: a session can decide its own visible halves.
- **"Open in External Terminal"** — hands off to the configured terminal
  program; macSCP builds **no** connection of its own in the process.

**Both are separate entries** (maintainer decision), not one entry that
follows the "terminal target" setting: the decision is made per click, not
in advance in settings. The setting stays what it's for — what the
terminal button in the toolbar does.

**Both appear only if the session has a shell.** For S3 and WebDAV,
`BackendDescriptor.capabilities.supportsShell` says no, and then the
entries don't exist — not greyed out, simply absent, because a
permanently dead entry on an S3 bucket explains nothing.

Open until planning: whether "Open Terminal" opens a new tab or uses the
active one, and what happens if the session is already connected. Both are
to be measured against the code when planning, not guessed.

## Addendum 2026-08-18: Snippet selection in the terminal (P3d) — decided

**Current state, measured against the code (not derived from the
screenshot).** The popover in the terminal header bar
(`ContentView+Detail.swift`) already has a search field with a regex
checkbox and renders `SnippetMenuItems` below it. There, **every row is a
submenu** with "Insert" and "Run":

```
Snippet name  ▸  Insert
                 Run
```

**A click therefore already triggers nothing today.** The casualness the
original feedback targeted does not exist in this selection — it was
avoided in round 2 for the same reason. Four trigger surfaces render this
same view: popover, right-click in the terminal, host context menu, menu
bar.

**Maintainer finding (2026-08-18):** the problem is the **submenus** —
opening, moving sideways, hitting the target, uncomfortable in the narrow
popover.

**This phase is therefore a usability improvement, not a security fix.**
That is stated explicitly so nobody later assumes a hole was closed here.

### What gets built

The list becomes **flat**. The submenus go away; the tag groups remain as
headers within the flat list.

Three paths to an action, deliberately at different speeds:

- **Right-click on the row** → Run, Insert, Preview. The fast path: one
  gesture, no window.
- **Double-click** → an action window with Insert, Run, Cancel, and the
  command shown in plain text above them.
- **Hover** → the command appears as a **fixed line at the bottom of the
  popover**, not as a tooltip. A tooltip arrives with a delay, truncates
  long commands, and can't be read while the mouse is moving.

**A single click only selects** and triggers nothing — a precondition for
the list being operable with the arrow keys.

### Keyboard shortcuts in the action window (maintainer decision)

- **Esc** cancels.
- **Return** sits on **"Insert,"** not "Run."
- **⌘Return** runs.

Rationale, which belongs to the decision: in a macOS dialog, Return
triggers the default button. If it sat on "Run," a double-click plus
Return would start a command on a remote machine with two keystrokes —
more casual than today's path via the submenu, even though this rework is
meant to achieve the opposite. On "Insert," Return is harmless: the text
lands in the input field, and the user presses Return themselves after
reading it.

### To clarify when planning

Whether "Preview" in the context menu opens the same window without the
actions, or just highlights the command line; how the four trigger
surfaces share the new view (the menu bar **needs** a real `NSMenu` and
cannot render a flat list — the paths presumably diverge here, and that is
to be measured against the code); and what happens to the ⌃⌘n shortcut
that today hangs only off the Insert entry.

---

## Discarded: the original version of this addendum

Maintainer feedback after the dev build. **Not** part of P3b or P3c.

The selection in the terminal should stop being a list that does something
immediately on click. Instead:

- **Double-click on a row** opens a window with the actions **Insert**,
  **Run**, and **Cancel** — the decision is thus made after seeing, not
  before.
- **On hover** the row shows the command that would run.
- **Context menu on every row** with Run, Insert, Preview.

The reasoning behind this is the same as for "run immediately" in round 2:
a click that starts a command on a remote machine must not be a side
effect of a selection action.

### Addendum: keyboard operation in the action window

The row's context menu carries **the same three options** as the window.
And the window gets keyboard shortcuts on all three actions, so fast
operation stays possible — **Esc cancels**.

**The conflict to be decided here:** in a macOS dialog, Return triggers the
default button. If Return sat on "Run," a double-click plus Return would
start a command on a remote machine with two keystrokes — and eliminating
exactly that casualness is the point of this rework. A shortcut for "Run"
is not thereby ruled out, but it should be one that isn't hit by accident.
Decide during brainstorming, not in passing.

**To clarify before planning** (not guessed, against the code and with the
maintainer): what a single click still does then; whether "Preview" is the
same window without the actions or something of its own; whether the
command on hover is shown as a tooltip or as a fixed line in the popover.
The maintainer also sent a screenshot of today's selection (search field,
"Regex" checkbox, expand menu) — the current state is to be **measured
against the code** when planning, not derived from the image.

## Addendum 2026-08-18: Terminal log (P3e)

Maintainer feedback after the dev build. Its own phase, **after** P3b.

The log from M9b (`AuditEvent`, `AuditLogStore`, sheet) gets terminal
events. Measured: `AuditEvent.Kind` today knows **no** shell case — it is
extended, not rebuilt.

**Maintainer decision:** what gets logged is snippet execution **and**
self-typed commands, the latter **toggleable via a setting**.

**Protection against logged passwords doesn't come from a text filter**,
but from the terminal's state: if the remote side requests hidden input
(echo off, as with `sudo`), the log writes only a note ("hidden input")
and **not the content at all**.

That's the better construction because it uses a signal instead of
guessing. A pattern filter that catches 95% builds trust the remaining 5%
don't justify — and that 5% is exactly the case where a password ends up
in a file.

### Before planning: check feasibility, don't assume it

**Open and explicitly unresolved:** whether the client side can reliably
detect that the remote side has turned echo off. With SSH, the remote PTY
turns echo off; the client then simply doesn't get the characters back.
Whether SwiftTerm derives a reliable state from that — via the terminal
modes or otherwise — is **to be measured against the code and the
library**, before anything is planned.

If the check comes out negative, the decision has to be made anew, rather
than falling back to building a pattern filter after all. The fallback
options would then be: log only snippets, or log typed commands only with
an explicit warning in the settings text.

Also to clarify when planning: whether a line is logged on submission or
on completion, what happens to a line that never ends with Return, and
whether the log is read per session or globally.

## Addendum 2026-08-18: Export from the context menu, everywhere (P3f)

Maintainer feedback. Its own phase.

Exporting should not only go through buttons in sheets, but **everywhere
via the context menu** — at the row you're already standing on.

**To be measured against the code before planning**, which lists today
show exportable things and what their context menu can already do:
sessions and groups in the sidebar, login sets, snippets, possibly SSH
keys. For each location it must be clarified whether "Export" there means
the same thing as the existing button (selection, filter, scope) or
something narrower — a context menu on *one* row suggests "just this one,"
while the button in the sheet today exports the visible set.

This inconsistency is the actual design point of the phase and belongs in
brainstorming, not a quick fix: "Export" must not mean two different
scopes in two places without that being visible.

## Addendum 2026-08-18: The password hint holds a resolved configuration (P3g)

From the whole-phase review of P3c task 2. **Its own, small phase.**

`pendingPasswordHintRequest` holds an `SSHConnectionConfig` — which can
carry a plaintext password — for as long as the one-time password hint is
open. Both of the hint's buttons clear it, as does every SwiftUI dismissal
of the dialog. But `disconnect` and `clearRetainedSecrets` **do not reach
it**.

This is a pre-existing state from M11d, not a new bug. P3c broadens it,
though: previously the path was only reachable from a **connected** tab,
now also for a session macSCP has **never** connected to.

It is also exactly what the doc comment of `resolveConfigWithoutDialing`
warns about: "a second property holding a resolved config would be a
second place that clearing does not reach."

**To clarify when planning:** whether the cleanup paths should cover it
too, whether the hint needs to hold the configuration at all (instead of
resolving it fresh after confirmation), and whether a window closing
during the hint needs its own path. Not a blocker — but a place where a
password sits longer than necessary, and this project cleans up such
places instead of documenting them.

## Addendum 2026-08-19: Feasibility of "detect hidden input" (P3e) — answered

The open question from the P3e spec was: does the client side detect at
all that the remote side has turned echo off (i.e., a password prompt is
running)? **Answer: no, not reliably.**

- SSH does not negotiate echo (unlike Telnet). A `sudo` prompt turns off
  the pty's `ECHO` flag server-side via a `termios` ioctl — invisible on
  the wire. The client only sees that no more output bytes are coming.
- SwiftTerm keeps no record of this: SRM (mode 12, "Local Echo") is
  explicitly a stub in `Terminal`, `setMode` has that branch commented
  out, and it fires no `TerminalDelegate` callback. Even implemented, it
  would help nothing: `sudo`/`login` send no SRM sequences.
- A "are my bytes coming back?" comparison would be a heuristic with a
  guessed time threshold — banners, tab completion, and prompt redraws
  break any naive correlation. So it's the same pattern matching already
  rejected once, just dressed up as timing.

**Consequence for P3e:** free keyboard input cannot be logged by content
without building exactly the leak the filter was meant to prevent. What
remains to decide: log snippet execution by content (the text is known
and, by rule, secret-free), log typed input only as metadata (timestamp,
extent, no content) — or not at all. That is now a product decision, not
a technical one.
