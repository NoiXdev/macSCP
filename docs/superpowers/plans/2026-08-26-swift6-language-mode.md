# Swift 6 Language Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear the warnings, bring `macSCPCore` to `.swiftLanguageMode(.v6)` and lock the stack against regrowth.

**Architecture:** No app rebuild. The intervention is a compiler semantics switchover plus the adjustments it forces — mostly in test doubles that today use `NSLock` in `async` methods.

**Order:** from our own stuff to foreign stuff, and from `macSCPCore` upward. Every task ends with a green suite.

---

## The measured starting state (2026-08-26)

The backlog entry spoke of "around 1200 warnings." That was a line count.
Recounted, there are **37 distinct sites**; the same sites get printed on
average seventeen times over multiple compile passes.

| File | Sites | Kind |
|---|---|---|
| `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` | 14 | `lock`/`unlock` from async context |
| `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` | 7 | same |
| `Tests/macSCPCoreTests/S3UploaderTests.swift` | 3 | same |
| `Tests/macSCPCoreTests/GitHubReleaseFetcherTests.swift` | 3 | mutating a captured `var` concurrently |
| `Tests/macSCPCoreTests/TagSuggestionRankingEquivalenceTests.swift` | 2 | `try` without a throwing call |
| `Tests/macSCPCoreTests/ConnectFailureSecrecyTests.swift` | 2 | `try` without a throwing call |
| `Tests/macSCPCoreTests/LoginSetExportImportTests.swift` | 2 | unused value |
| `Tests/macSCPCoreTests/AgentAuthTests.swift` | 1 | `syncShutdownGracefully` blocking |
| `Sources/macSCPCore/SSH/CitadelFileSystem.swift` | 2 | non-`Sendable` capture; missing `@preconcurrency` |
| `Sources/macSCPCore/RemoteFS/TransferEngine.swift` | 1 | non-`Sendable` capture |

**34 of the 37 are in tests, 3 in `Sources`.**

Measured separately, by trying the switchover and reverting it:
`macSCPCore` alone throws **seven errors** under `.v6`. Warnings and
errors are nearly disjoint — the v5 mode does not even diagnose most of
these cases.

**On the count, because it was off on the first attempt:** a `.v6` build
shows only five. The compiler stops not only at the first failing
*target*, but also **within a file at the first error**. This plan's
first measurement therefore named six and was itself a lower bound. The
complete list comes from `.v5` with `-Xswiftc -strict-concurrency=complete`,
where the same checks run as warnings and every file is checked to the
end. The error list is at Task 4+5.

What the build does **not** reach as long as `macSCPCore` does not build:
`MacSCPAppKit`, `MacSCPCLI` and both test targets. What awaits us there
is **unknown, not zero** — an interim finding from Task 1 names 31
error sites in other test files as soon as only `macSCPCoreTests` is
switched over. That is Task 6, and that is why Task 6 has a checkpoint
instead of an assignment.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English
  only**; catalog values are translations, German uses "du."
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **No test reaches a real keychain, session store, or configuration.**
- **No line numbers, no location references in comments.** Every number
  and every enumeration of call sites is counted in the pass that writes it.
- **Behavior stays the same.** This work changes concurrency annotations
  and test doubles, not what the app does. If a task changes functional
  behavior, that is a bug in the task, not progress.
- **Silently defusing a lock is not a fix.** `@preconcurrency`,
  `nonisolated(unsafe)` and `@unchecked Sendable` suppress the
  diagnostic without eliminating the data race. Every such site needs
  the argument in the comment for **why there is no race at this site**
  — not just a note that the compiler would otherwise complain.
- **Green locally is not evidence for CI.** This machine has Swift
  6.3.3, CI has an older toolchain, and the two judge concurrency
  inference differently — that cost a red build on 2026-08-26
  (`docs/superpowers/specs/2026-08-26-backlog-toolchain-deviation.md`).
  For every task from Task 4 onward: **green means green on CI**, and
  the coordinator waits for the run before the next task starts.
- The app is not launched, `scripts/release` is not run.

---

### Task 1: The locks in the test doubles

**Files:**
- Modify: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (14),
  `Tests/macSCPCoreTests/WebDAVFileSystemTests.swift` (7),
  `Tests/macSCPCoreTests/S3UploaderTests.swift` (3)

**The measured current state:** all 24 are the same pattern — a
`private let lock = NSLock()` in a test double whose `async` methods
call `lock()`/`unlock()`. Both methods are `noasync`; in v6 mode that is
an error.

**What already knows the way:** `Tests/macSCPCoreTests/S3FileSystemTests.swift`
uses an `actor` for the same purpose — the call sites there read
`let requests = await transport.requests`.

- [ ] **Step 1: Choose the replacement, on ONE file, measured rather than
  guessed.** Three candidates, each with a different price:

  | Approach | Price |
  |---|---|
  | `NSLock.withLock { }` | smallest intervention — **but measure first whether it even ends the diagnostic** |
  | `Mutex` from `Synchronization` | fits the minimum target macOS 15, is `Sendable` — new import in the tests |
  | `actor` | the actually correct form; **changes every call site to `await`** |

  Take `S3UploaderTests.swift` (3 sites, smallest surface), implement
  **all three**, build each time, and write in the report which one
  actually ends the warning and what it costs in call sites. Only then decide.

- [ ] **Step 2:** Apply the chosen form to the other two files.
- [ ] **Step 3:** Full suite green, and `swift build --build-tests` shows
  **zero** sites for these three files. Both in the report with the
  counted number before and after.
- [ ] **Step 4: Commit** — `refactor(tests): take the locks out of async test doubles`

---

### Task 2: The remaining ten warnings in the tests

**Files:**
- Modify: `GitHubReleaseFetcherTests.swift` (3), `TagSuggestionRankingEquivalenceTests.swift` (2),
  `ConnectFailureSecrecyTests.swift` (2), `LoginSetExportImportTests.swift` (2),
  `AgentAuthTests.swift` (1)

**Four different kinds, each with its own question:**

- [ ] **Step 1: Mutating a captured `var` (3, `GitHubReleaseFetcherTests`).**
  This is the only one of the four that **names a real data race**.
  Check whether the test actually writes concurrently there. If so, it
  is a test bug, not an annotation problem — then fix it so the test
  still asserts the same thing afterward.
- [ ] **Step 2: `try` without a throwing call (4, in two files).** Remove
  the `try`. **First check whether the called expression used to throw**
  — an orphaned `try` is often the remnant of a signature that changed,
  and then the question is whether the test still checks what it should.
- [ ] **Step 3: Unused value (2, `LoginSetExportImportTests`).** Why is it
  unused? If a test binds a value and never looks at it, an assertion
  may be missing. Clarify that first, then either add an assertion or
  remove the binding — say in the report which of the two and why.
- [ ] **Step 4: `syncShutdownGracefully` (1, `AgentAuthTests`).** Blocks
  the calling thread from async context — the same class as the race
  fix in `LoopbackHTTPStub` from the same day. Switch to the
  asynchronous counterpart.
- [ ] **Step 5:** Full suite green; counted warnings in `Tests/` are **zero**.
- [ ] **Step 6: Commit** — `refactor(tests): clear the last Swift 6 warnings`

---

### Task 3: The three in `Sources`

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift`,
  `Sources/macSCPCore/SSH/CitadelFileSystem.swift`

- [ ] **Step 1: `TransferEngine` — `AsyncThrowingStream.Iterator` in a
  `@Sendable` closure.** An iterator is stateful; passing it across a
  closure boundary is exactly what the diagnostic warns about. Clarify
  whether the iterator is actually served from only one place there. If
  so, the argument belongs in the comment; if not, it is a bug in
  shipped code and the finding outweighs this task —
  **then report instead of fixing.**
- [ ] **Step 2: `CitadelFileSystem` — `SFTPFile` in a `@Sendable` closure.**
  Same question, same rule.
- [ ] **Step 3: `@preconcurrency import Citadel`.** That is a suppression,
  not a fix. It is nonetheless correct here because the annotations
  belong to a foreign package — but the comment must say **what**
  remains unchecked as a result, not just that the compiler then stays quiet.
- [ ] **Step 4:** Full suite green; counted warnings in the whole project: **zero**.
- [ ] **Step 5: Commit** — `refactor(core): answer the last Sendable warnings`

---

### Task 4+5: `macSCPCore` to `.v6` — all seven errors

> **Merged on 2026-08-26**, after the exploration pulled both
> checkpoints. All errors sit in `macSCPCore`; the target does not
> compile until all of them are gone. Separate tasks could neither turn
> green nor carry a commit whose message would be true.

**Files:**
- Modify: `Package.swift` (only the `macSCPCore` line),
  `Sources/macSCPCore/Presentation/FileListFormatter.swift`,
  `Sources/macSCPCore/S3/S3ListParser.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVSessionDelegate.swift`,
  `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift`,
  `Sources/macSCPCore/SSH/CitadelShell.swift`

**Corrected measurement.** The plan was written against six errors; there
are **seven**, and the composition is different. The reason for the
counting error belongs in the task because it affects every further
count: **the compiler also stops within a file at the first error.** A
`.v6` build therefore shows only five. The complete list comes from
`.v5` with `-Xswiftc -strict-concurrency=complete`, where the same
checks run as warnings and every file is checked to the end.

| Error | belongs to |
|---|---|
| `FileListFormatter.byteFormatter` not `Sendable` | us |
| `S3ListParser.dateFormatterWithFractionalSeconds` | us |
| `S3ListParser.dateFormatter` | us |
| `WebDAVSessionDelegate`: `Task {` in the server-trust arm | us |
| `AgentBackedPrivateKey`: `NIOSSHUserAuthenticationOffer` | **fork** |
| `CitadelShell`: `let pump = Task {` captures `SSHClient` | **Citadel** |
| `CitadelShell`: `pending?.resume(with:)` with `TTYStdinWriter` | **Citadel** |

`SSHAuthenticationMethod` was in the original plan and **no longer
exists** — Task 3's `@preconcurrency import Citadel` also took care of it.

**Order: foreign → ours → flip.** The foreign ones first, because they
determine the surface; the flip last in the same commit, so that there
is no intermediate state where the target does not build.

- [ ] **Step 1: The three foreign types.** `NIOSSHUserAuthenticationOffer`
  (fork), `SSHClient` and `TTYStdinWriter` (Citadel). Choose a
  workaround and record **both** things in the comment: why there is no
  race at this site, and that Apple has carried the first type as
  `Sendable` since 2023, but the fork never got the merge. Pointer to
  `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`.
- [ ] **Step 2: The three formatters.** "Create per use" is ruled out,
  counted rather than assumed: `sizeString` hangs off the view-based
  data-source callback of an `NSTableView` — per visible row **and**
  column, on every `reloadData` and while scrolling, so it is not
  bounded by the file count. `parseDate` runs in the XMLParser delegate
  per `<LastModified>`, up to 1000 objects per `ListObjectsV2` page.
  `Mutex` following Task 1's pattern.
- [ ] **Step 3: `WebDAVSessionDelegate`.** Clarified: `URLSession` calls
  the delegate methods on its own serial queue (`delegateQueue: nil`),
  and in the server-trust arm exactly one site calls the
  `completionHandler` exactly once — the `Task` after
  `decideCertificate`. **Forward to a dedicated method with a `sending`
  parameter, do not remove the `Task`**: that would shift when the
  certificate decision happens, and that would be a behavior change in
  security-relevant code.
- [ ] **Step 4: Flip.** `.v5` → `.v6`, **only** for `macSCPCore`.
- [ ] **Step 5: Count the new warnings.** The flip brings, measured, **six
  new warning sites** (`HTTPTransport`, `TransferEngine` ×2,
  `CitadelFileSystem` ×2, `AgentBackedPrivateKey`), which do not exist
  under `.v5`. List them in the report. Whether they get eliminated in
  this task or belong in their own decides on their kind — but **leaving
  them standing quietly would be the relapse into exactly the state**
  this plan is ending.
- [ ] **Step 6:** Full suite green **and CI green**. An eighth error is
  expected here that does not appear locally: this SDK carries
  `DateFormatter` as `Sendable`, `ByteCountFormatter` and
  `ISO8601DateFormatter` not — whether the older CI toolchain has the
  same annotations is **not measured**.
- [ ] **Step 7: Commit** — `build(core): move macSCPCore to the Swift 6 language mode`

---

### Task 6: Measure what the upper layers cost

**Files:** none initially — this is a measurement with a decision point.

**Why its own task:** The build currently stops at `macSCPCore`. What
`MacSCPAppKit`, `MacSCPCLI` and the two test targets throw off under
`.v6` is **unknown, not zero**. `MacSCPAppKit` is SwiftUI and full of
`@MainActor` — expect notably more there than in Core.

- [ ] **Step 1:** All remaining targets to `.v6`, build, count errors and
  group by target **and kind**.
- [ ] **Step 2: Decision point.** If the number is in the same order of
  magnitude as in Core (single digit to low double digit), fix it in
  this task. If it is significantly larger, **stop**, report the
  grouping and request a separate plan. A task of unknown size does not
  become small by starting it.
- [ ] **Step 3:** Full suite green **and CI green**.
- [ ] **Step 4: Commit** — `build: move the remaining targets to the Swift 6 language mode`

---

### Task 7: The lock against regrowth

**Files:**
- Modify: `.github/workflows/ci.yml`

**Why this task tips the balance:** fixing 37 warnings buys nothing
lasting. On 2026-08-26, six new ones appeared in one morning and were
noticed only by chance. Without a lock, the stack regrows exactly as
fast as it was cleared.

- [ ] **Step 1:** Decide between `-warnings-as-errors` and a counted
  ceiling. The question it hinges on: **warnings from dependencies**. Do
  the packages still build under this flag? Measure that, do not
  assume it — today all sites do come from our own code, but the flag
  also acts on foreign targets.
- [ ] **Step 2:** Build in the lock and **prove that it engages**:
  deliberately introduce a warning, see CI go red, revert. A gate that
  was never red is a claim.
- [ ] **Step 3: Commit** — `ci: fail the build on new compiler warnings`

---

## What is explicitly not part of this

- **No dependency jumps.** Citadel is already on the newest tag
  (0.12.1); swift-nio, SwiftTerm and swift-crypto are separate matters
  with their own questions — see the dependency entry.
- **No tackling the swift-nio-ssh fork.** Task 5 builds workarounds and
  documents the situation; whether the fork should go away is a
  maintainer decision, not a side effect.
- **No behavior rebuild.** Where a warning names a real race, it gets
  fixed; where it demands an annotation, it gets annotated. Everything
  else is a different task.
