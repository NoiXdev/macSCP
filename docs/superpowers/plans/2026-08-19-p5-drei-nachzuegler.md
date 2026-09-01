# P5 — Three Stragglers from P3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three named gaps from the P3 wrap-ups: silent history loss
in the log, wrong plural forms, and a log entry that claims a delivery
that never happened.

**Architecture:** Three independent tasks, ordered by risk.
Task 1 prevents data loss and goes first.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, Swift Testing.

## Global Constraints

- Code, comments, identifiers, test names: **English only.**
- The four catalogs (en/de/fr/pl) keep identical key sets.
- Never write a line number into a comment.
- **No comment claims something the code does not do.** And: whoever
  writes a number or an enumeration of call sites counts them
  (`CLAUDE.md`, section "Comments that describe other code").
- Tests: TDD red→green. `swift test` green at the end of each task.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: A broken entry must not erase a log (Core)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditLogStore.swift`
- Test: `Tests/macSCPCoreTests/AuditLogStoreDecodingTests.swift` (new)

**The bug, measured:** `loadIfNeeded` decodes the whole array in one
go and swallows every error:

```swift
cache[sessionID] = (try? JSONDecoder().decode([AuditEvent].self, from: data)) ?? []
```

A single entry that fails to decode turns this into `[]`. The next
`append` rewrites the file with **only the new entry** — the whole
history of that session is gone, without a warning.

Reachable through any event kind an older app version does not know:
`AuditEvent.Kind` is a `String` enum, and an unknown `rawValue` throws
while decoding. Applies to every kind ever added
(`crossSessionTransfer`, `plaintextConfirmed`, `snippetExecuted`).

**Two changes, both necessary:**

1. **Decode element-wise.** A broken entry then costs only that
   one, not the other 999.
2. **Do not overwrite an incompletely read log.** Otherwise the
   older version permanently wipes out the entries the newer version
   produced, on the next `append`. Remember, per session, that
   something was discarded on load, and **skip persisting** for
   that session for as long as that holds. The entry still lands in the
   cache, so the running session does see it — only the file stays
   untouched.

- [ ] **Step 1: Write the failing tests**

New file `Tests/macSCPCoreTests/AuditLogStoreDecodingTests.swift`. First
look at the existing `AuditLogStore` tests (reuse the naming and temp-directory
setup). The tests:

1. **An unknown `kind` costs only its own entry.** Write a JSON file by
   hand with three entries, one of them with
   `"kind": "somethingFromTheFuture"`. `events(for:)` returns the other
   two.
2. **A partially read log is not overwritten.** After loading from (1), an
   `append`; then read the file raw again and check that the
   unknown entry is **still there**.
3. **A clean log behaves unchanged:** load, append, the file
   contains the old plus the new entries.

Build the JSON file from an `AuditEvent` array that you encode, then
replace a `kind` value in the text at a specific point — that way the
rest of the format is guaranteed to be real, instead of hand-built.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "AuditLogStore"` — tests 1 and 2 red.

- [ ] **Step 3: Implement**

In `loadIfNeeded`: instead of decoding `[AuditEvent].self` in one pass,
decode a `[FailableEvent]`, where `FailableEvent` is a private wrapper
whose `init(from:)` stores `try? container.decode(AuditEvent.self)`.
Count the `nil` cases. Set the cache to the successes, and if `nil > 0`,
remember the session in a `Set<UUID>`
(e.g. `partiallyRead`). In `persist` (or wherever the write happens),
return early if the session is in there.

Comment the second half so that it is clear **why** nothing is
written — otherwise the early return reads like a bug.

- [ ] **Step 4: Run the tests to verify they pass**

`swift test --filter "AuditLogStore"` green, then the full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/AuditLogStore.swift Tests/macSCPCoreTests/AuditLogStoreDecodingTests.swift
git commit -m "fix(core): keep an audit log a bad entry cannot erase"
```

---

### Task 2: Plural forms for the two count messages

**Files:**
- Create: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.stringsdict`
- Modify: the same four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/PluralCatalogTests.swift` (new)

**Why:** `"%lld snippets will be written to the file."` reads as "1
snippets" for a single selection — and since P3h, one is the
**common case** for snippets (select a line → export). Two keys are
affected: `snippets.export.confirm.message %lld` and, the same wording,
`logins.export.summary %lld`.

**Why `.stringsdict` and not two strings:** Polish has three
plural categories (one/few/many), and French treats zero like the
singular. A two-way branch in code would be wrong for two of the four
languages.

**To check beforehand (do not guess):**
- `L10n.string` calls `NSLocalizedString(key, bundle:, value:, comment:)`.
  Confirm with a test case that a `.stringsdict` entry is found through
  it, and that `String(format:)` picks the right form from it.
- `Package.swift` declares `.process("Resources/<lang>.lproj")`. Check
  that a `.stringsdict` placed there ends up in the bundle.
- The existing catalog guards compare `Localizable.strings`. If a key
  no longer belongs there, it has to disappear from all four
  equally, otherwise key parity breaks.
  **Recommendation: leave the key in `.strings`** (the `.stringsdict`
  wins at runtime) — then all the guards stay unaffected and the
  fallback text keeps existing. Decide based on your measurement and
  justify it in the report.

- [ ] **Step 1: Write the failing test**

`Tests/macSCPAppKitTests/PluralCatalogTests.swift`: for both keys and
all four languages, resolve the forms for 1 and for 2 and check that they
differ. For Polish, also 5 (category *many*).

How you force the language in the test needs to be read off the
existing L10n tests — if a language cannot be targeted specifically
there, check the `.stringsdict` files structurally instead (contains
`NSStringPluralRuleType`, has the keys `one`/`few`/`many` for `pl`)
and say in the report that runtime resolution was not testable.

- [ ] **Step 2: Run it to verify it fails** — the files do not exist.

- [ ] **Step 3: Implement**

Four `.stringsdict` files, each with both keys. English/German: `one`/`other`.
French: `one` (covers 0 and 1) / `other`. Polish: `one`/`few`/`many`.
Phrase the sentences in parallel with today's versions in `.strings`.

- [ ] **Step 4: Run the tests** — filter green, then the full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPAppKit/Resources Tests/macSCPAppKitTests/PluralCatalogTests.swift
git commit -m "fix(app): give the two export counts real plural forms"
```

---

### Task 3: No log entry without delivery

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`triggerSnippet`)
- Test: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (extend)

**The bug, measured:** `send` is fire-and-forget. At `state ==
.opening` the bytes land in `pendingBytes`; if opening fails, the error
branch sets `pendingBytes = []` — the bytes never go out. The
audit entry "ran snippet …" is still written, because `triggerSnippet` logs
right after the `send` call. Realistic with an account that has
`ForceCommand`, which rejects the shell channel.

**Design:** `send` gets an optional callback that fires **only**
if the bytes actually went out:

```swift
public func send(_ bytes: [UInt8], onDelivered: (@MainActor () -> Void)? = nil)
```

The default value `nil` leaves every existing call site unchanged.

- With an existing `shell`: fire after a successful `shell.send`. With
  today's `try?`, that means only on success — the swallowed error must
  **not** count as delivery.
- At `state == .opening`: remember the callback alongside the buffered
  bytes (`pendingBytes` is a flat byte array, multiple sends merge —
  so you need a parallel list of callbacks) and fire it when flushing.
- On **every** path that discards `pendingBytes`, discard the remembered
  callbacks along with it, without firing them. Count these spots
  yourself instead of relying on this description.

In `ContentView.triggerSnippet`, the logging moves into the callback.
The comment there currently claims exactly the opposite ("recorded
after the send CALL … a shell that fails to open drops the bytes and leaves
this entry standing") — it has to go too.

- [ ] **Step 1: Write the failing tests**

In the existing `TerminalPanelViewModel` suite (reuse the setup and fake shell from
there):

1. With a running shell, the callback fires exactly once.
2. Bytes buffered during `.opening`: the callback fires only when flushed.
3. If opening fails, the callback **never** fires.

- [ ] **Step 2: Run them to verify they fail** — the signature does not exist yet.

- [ ] **Step 3: Implement** — Core first, then the app side.

- [ ] **Step 4: Run the tests** — filter green, then the full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/TerminalPanelViewModel.swift Sources/MacSCPAppKit/ContentView.swift Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift
git commit -m "fix(core): report snippet delivery instead of assuming it"
```
