# macSCP — Project Rules

## Language policy (maintainer decision, 2026-07-10)

- **Code and comments: English only.** All identifiers, doc comments, inline
  comments, test names, and log/error `reason:` strings in Core are written in
  English. No German in source files.
- **App UI: localized.** User-facing strings live in
  `Resources/<locale>.lproj/Localizable.strings` under both localized
  targets, `MacSCPAppKit` and `macSCPCore`, in **four languages**: `en` —
  the default, and the source text every other catalog is measured against —
  plus `de`, `fr`, `pl`. Plural forms sit beside them in
  `Localizable.stringsdict`. The German catalogs address the user as **du**;
  `GermanAddressFormTests` holds them to it.
- Never hardcode a display string. Look it up through `L10n.string(_:_:)` /
  `L10n.text(_:_:)` in the App, `CoreL10n.string(_:)` in Core. Core-layer
  user-facing messages (e.g. transfer error texts) live in Core's own
  catalog where they must; prefer mapping raw errors to localized text at
  the App layer.
- **Not `String(localized:)`, not `LocalizedStringKey`, not a String Catalog
  (`.xcstrings`), not `Bundle.module`** — this paragraph used to prescribe
  all four, and the tree has never used any of them. Counted 2026-08-28:
  zero occurrences of the first two, no `.xcstrings` anywhere, and
  `Bundle.module` only inside the comments explaining why both helpers avoid
  it — SwiftPM's generated accessor calls `fatalError` when it cannot find
  the resource bundle, which a stripped launch really can. `L10n` and
  `CoreL10n` search a wider candidate list and fall back to the key text
  instead of trapping. Adding a String Catalog is a migration to design, not
  a file to drop in: the plural categories differ per language (`pl` carries
  `few`/`many` where `de`, `en` and `fr` carry only `one`/`other`). The
  localization checks read `.xcstrings` since `cb624e5`, so one would at
  least not go unexamined.
- **Every written artifact is English.** `docs/` — plans, specs, designs,
  backlog entries, ADRs, the SDD ledger — plus commit messages, PR
  descriptions and branch names. There is no internal-German exception any
  more; the one that used to stand here was retired on 2026-09-01 and the
  existing corpus was translated in the same pass.
- **The conversation is not an artifact.** Chat with the maintainer happens
  in the maintainer's language — German, here. That is the whole split:
  what gets written down is English so any contributor can read it; what
  gets said is whatever the two people in the room speak. A German answer
  in chat is not a violation of this rule, and rewriting one into English
  is not compliance with it.
- **Translating a document must not restate it.** These documents are a
  measurement record: numbers, file paths, identifiers, commit hashes,
  command lines, code blocks and quoted output are data, and they are
  copied, never rendered. A translation that improves a claim has
  falsified it — including tightening a hedge. Where a sentence marks
  something as unmeasured, assumed, or withdrawn, the English keeps that
  marking exactly as strong as it was.
- Public-facing texts (README intro, taglines, landing copy) contain **no
  tech-stack terms** (see global user CLAUDE.md) and exist in English first.
- Migration status: the German-comment and hardcoded-string sweep completed
  2026-07-10 (milestone M5i). The format described above was corrected on
  2026-08-28 to match the tree — it had prescribed a String Catalog and two
  SwiftUI lookup APIs that no code here has ever used, which is how a rule
  file quietly instructs the next contributor to build something the rest of
  the project does not speak.

## Build & test

- Swift Package Manager, swift-tools 6.0, **all targets
  `.swiftLanguageMode(.v6)`**, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green. New logic ships
  with tests; prove regressions red first.
- Unit suite: `swift test`. Gated suites: `MACSCP_ITEST=1` (Docker SSH rig),
  `MACSCP_KEYCHAIN=1` (writes to the real keychain), `MACSCP_PIPE_TIMING=1` (one gated case that counts pipe chunks from the CLI's line-buffered stdout — it measures the reader's scheduling as much as the binary, so it runs on request), and `MACSCP_SATURATION=1`
  (one test that parks the whole GCD global queue to prove the subprocess
  runner's readers need no thread — it cannot share a parallel run, measured
  on CI run 33705649537; run it alone).
- Docker rig: `docker compose -f docker/test-server/compose.yml up -d`
  (127.0.0.1:2222, testuser/testpass). **Always start it from the main
  checkout, never from a git worktree** (the seed mount is relative to the
  compose file). `PerSourcePenalties` is disabled in the rig config.
- Never commit key material or secrets; test keys are generated at runtime
  via `ssh-keygen`. Secrets live exclusively in the macOS Keychain
  (`SecretStore`); JSON stores never contain them.

## Tests never block the cooperative pool

Measured on 2026-09-02, with `sample` on a hung CI process: three test
threads parked in `EventLoopGroup.syncShutdownGracefully()` inside a
`defer`, one more `futureResult.wait()` per offer above it. Swift Testing
runs every test on the cooperative thread pool, and that pool is exactly
as wide as the machine has cores. The CI runner has three; three
parameterised cases blocked three threads; the other 3300 tests never got
a thread, and the run sat at 0 % CPU until the timeout. Ten local cores
hid it completely — the suite was green here every time.

So, in test targets: no `syncShutdownGracefully()`, no
`futureResult.wait()`, no `DispatchSemaphore.wait()` — every wait is an
`await` (`shutdownGracefully()`, `.get()`, an `AsyncStream` or a
continuation). A blocking wait that "returns at once" today is a hang on
a smaller machine tomorrow. The record of the measurement is
`docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`.

## A wall-clock ceiling in a test measures the runner

Three tests were fixed for this in the same week (2026-09-02/03), all
the same shape: a fixed upper bound on elapsed time, red not because the
code was slow but because the three-core CI runner was. **Only ONE of
the reds below is on the connection-tools plan** (run 33727757421, head
`64854401`); every other red cited here sits on a head that predates the
plan's base `112dbc97`, and one of the three fixes does too. Counted
2026-09-03, per commit with `git merge-base --is-ancestor <commit>
112dbc97` and per run with `gh run view <id> --json headSha`.

- `AsyncSignalTests.swift` (`c8eebbd3`, **before** the plan): a 200 ms
  latch's `elapsed < .seconds(10)` came back at **10.377285583 s** on
  run 33707411271 (`aadbafca`), and at **15.677233083 s** on run
  33705649537 (`126c5c88`). The same run 33707411271 printed
  `ambient=14.668071541 seconds gap=0.17032175 seconds` from
  `ConnectMainActorLivenessTests`: **14.67 s is the AMBIENT control** —
  the largest main-actor tick gap that suite measures with nothing under
  test — and 0.17 s is the gap it measured while the dial ran. The
  runner's own idle stall was two orders of magnitude worse than the
  thing being measured, which is the whole argument of this section.
- `ConnectionDiagnosticsTests.swift` (`35e456da`, **on** the plan): two
  cases came back after **20.680103625 s** and
  **20.671590291999998 s** on run 33727757421 (`64854401`). Their
  deadlines are not the same:
  `aStepThatOverrunsTheTimeoutIsReportedAsTimedOut` uses
  `stepTimeout: .milliseconds(200)` against a 30 s sleep, and
  `aProbeThatIgnoresCancellationDoesNotHoldTheStepPastItsDeadline` uses
  `stepTimeout: .seconds(1)` against a 12 s uncancellable probe. The
  outcome each asserted (`.timedOut`, `stillRunning`) was already
  correct; only the `elapsed < .seconds(10)` ceiling on top of it was
  red.
- The subprocess timeout test (fixed **on** the plan in
  `a4c59a2b`/`b6e181f3`, but every red is on a **pre-plan** head): a 2 s
  bound raced Foundation's
  `readabilityHandler`, which only reaches `stderrSoFar` once the
  Dispatch global queue hands it a thread — on a starved runner the
  bound won the race and the assertion read empty text. Observed as
  `(text → "").contains(marker → …)` at `SubprocessRunnerTests.swift:117`
  on run 33698102652 (`0ef63269`), and again at `:114`/`:119` on run
  33705649537. The fix was not a wider bound; it was synchronising on
  the reader (an `onStderrChunk` seam raising a latch, awaited before
  the bound is asserted on) instead of on the clock.

One thing this section cannot cite, and the reason the counting rule
above applies to it too: run 33741778350 (`4456836d`, on the plan) is
red with **one issue attributed to no test at all** — its 10623-line job
log carries no `✘ Test <name> … failed` line, only the run summary. It
is evidence that the log loses verdict lines under interleaved output
(`docs/BACKLOG.md`, "CI logs lose lines"), not evidence of a ceiling.

Rule: assert the outcome and the ordering a bound is supposed to
produce, not how long producing it took. A floor (`elapsed >= …`, "this
did not return early") is fine — a slow machine cannot defeat it, only a
broken one. A ceiling always can.

## Architecture invariants

- TOFU host-key handling is security-critical: a key **mismatch is a hard
  stop** (the user decider is never consulted); unknown keys require explicit
  consent; there is no accept-anything path.
- One SSH connection per tab; SFTP and the terminal shell multiplex over
  it as child channels. Connection/session state belongs to the window scope,
  never to an app-wide singleton. Multi-window is here: a tab moves between
  windows carrying its connection, and the process-wide `TabRegistry` holds
  ownership — which window has which tab — never state. Nothing in Core
  knows about windows.
- The UI owns lifecycles explicitly (queue `cancelAll` → terminal `shutdown`
  → `disconnect` in `teardownSession`); no `deinit` cleanup.
- Transfer queue invariants: FIFO start order, exactly-once waiter
  continuations, `cancelAll` leaves no orphaned shells/transfers, group
  `onCompleted` fires exactly once.

## Comments that describe other code

Two rules, measured in the comment audit of 2026-08-19
(`docs/superpowers/specs/2026-08-19-p4-comment-audit.md`): 15% of the
statements about callers were wrong — but only in files that had recently
been restructured. In a file untouched since a milestone: none.

1. **Extracting a function, renaming it, or changing who calls it means
   searching, in the same pass, for comments that name those callers —
   including in files the diff does not touch.** That is exactly where the
   damage happens: the comment becomes wrong without ever showing up in the
   diff.

2. **Writing a number or an enumeration of call sites into a comment means
   counting them in that same moment.** Across four correction rounds,
   *every* follow-on error sat in a number or a list; prose without
   cardinality stayed correct. "Three call sites" is a claim about the rest
   of the project, and it always sounds plausible while you write it.

Applies to reviews too: a number in a comment is something to verify, not
evidence.

## A report says what the diff shows

Measured 2026-09-03, Task 3 of the connection-tools plan, round 2: round
1's own report claimed two doc corrections — `hopTimeout`'s comment,
`NetworkTrace.walk`'s `- Parameter timeout:` — that were not in the
tree. A scripted edit ran two `.replace(...)` calls whose old text did
not match (the wrapping had drifted from what had been transcribed by
hand), the script printed `ok` because nothing asserted the match, and
the report was written from what the edit intended rather than from
what it did. It is the "Comments that describe other code" failure mode
above, one layer up, with the report standing in for the comment.

So: every scripted replacement asserts its anchor before writing
(`assert old in s`, or the language's equivalent) — a silent miss
becomes a loud one instead. And a report is written from the diff, never
from the intent: read back what actually changed before describing it
as done.

## Guards that name what they watch

Measured on 2026-08-27, across a tab-menu wiring guard that survived five
correction rounds and a prefill guard that went silent without anyone
noticing.

Source-scanning guards are subject to the rule above, and to one of their
own:

1. **Only a NEGATIVE check can go stale in silence.** A check that requires
   something present (`contains`, a count that must match, a whole-body
   equality) fails loudly the moment the thing it names moves. A check that
   requires something ABSENT — `!contains`, or a filter expected to come
   back empty — starts matching nothing and passes. It reads exactly like a
   check that is satisfied.

   `replacedSession` was renamed to `nameConflict` in the same commit that
   left the guard's no-blocking filter naming the old symbol. The filter
   matched nothing, the suite stayed green, and the violation it existed to
   catch — a disabled Save button — could be planted freely. Every other
   negative check in that suite was pinned by a positive check nearby; this
   was the one that was not, which is precisely why it was the one that
   went stale.

   **So: a negative check needs a positive check beside it**, asserting that
   the thing it scans is there at all. Without one it is not a guard, it is
   a comment that runs.

2. **A guard that spells a symbol it could read instead is waiting for a
   rename.** Walk the name back from a call site, derive a catalogue key
   from the type that owns it. A literal is a second copy of a name, and
   this project's rule about second copies applies to tests as much as to
   comments.

3. **Mutation testing verifies a guard's sensitivity, never its scope.**
   Probes derived from the author's own enumeration test the places the
   author already thought of. Across five rounds on one guard, every hole
   was found by a fresh reader planting a violation the enumeration did not
   contain — and none by the author's own battery. When a scan keeps buying
   one spelling and revealing another, that is the evidence that the
   property wants a structural boundary (a type that will not compile the
   violation) rather than another anchor. A probe that never ran proves
   nothing either way: `scripts/mutation-probe` reports `BUILD FAILED`
   as its own outcome, distinct from red or green, because a harness that
   greps only for failing test names read a build failure — zero tests
   ran — as an all-clear (measured 2026-09-03).

## A value a test must not leak has two exits, not one

Measured on 2026-08-30, while proving that a substituted placeholder value
reaches no audit line, export or error message.

`#expect` reports **the source text of the expression it checks**, not only
the values. So a secret written literally into an expectation leaks through
a failure message — the very thing the test exists to forbid. Keep such a
value in a named constant and compute the `Bool` before the expectation
(`#expect(inAuditLine == false)`), so neither the value nor its spelling can
reach the output.

The second exit is the one everybody remembers: the code under test. The
first is the test itself, and it opens only when the test fails, which is
exactly when someone is looking.

## Source-scanning guards read comments too

Measured on 2026-08-29, twice in one task.

1. **A comment that quotes the code it describes is indistinguishable from
   that code to a scanner.** An explanatory comment quoting
   `.disabled(!snippetsCanExport(…))` verbatim moved another guard's anchor
   onto the wrong button — the guard was reading the comment. This project
   writes long explanatory comments AND scans source; the two collide
   exactly here. Describe the code in prose near a scanner, or expect the
   scanner to find your description.

2. **A negative check whose SPAN is wrong can never match, and reads like
   one that is satisfied.** A check looked for `.disabled(` inside an
   argument list, while a real greying attaches after the trailing closure —
   so it could not have matched a violation anywhere. It was exposed only
   because the planted probe **would not compile**: the violation could not
   be written in the place the check was looking. When a probe cannot be
   expressed where a check searches, that is not a difficult probe, it is a
   check pointed at the wrong region.

## Tests that watch a defect heal

Measured on 2026-08-28, in the teardown-bound sequence: one run that was
green while the defect was present, and one fixture that turned out to be a
race rather than a guard.

1. **A check that reads after the healing is not a check.** The frozen-peer
   test froze the peer, ran teardown, thawed the peer, and then read
   `enteredAt` and `liveness`. By that point the abandoned teardown had
   caught up and written exactly the values the test wanted. It passed while
   the defect it existed for was present; only the elapsed time was red.
   Snapshot every postcondition BEFORE the thaw, the restart, the retry —
   before whatever makes the system well again. A test that cleans up after
   itself must read first and heal second.

2. **A guard's sensitivity is a number, and the number is measured by
   repetition.** When a fixture pinned a property only incidentally,
   re-planting the violation turned it red in **4 of 6** runs — which reads
   exactly like a guard on the run that happens to be red. Its replacement
   was measured at 10 of 10 against the same violation, and 5 of 5 against a
   second one the old fixture had let through. One red run is not evidence
   that a check catches something; it is evidence that it can.

## Forks are a debt with a review date

Measured 2026-09-01/02: two dependencies are consumed from forks under
the NoiXdev org, both wired by same-identity override in `Package.swift`
with an `exact:` tag — `NoiXdev/swift-nio-ssh` (from `Wellz26`, itself a
fork of `apple/swift-nio-ssh`; tags 0.3.7 = pre-line fix, 0.3.8 = the
upstream security patches, 0.3.9 = `hostKeyAlgorithmNames`, 0.3.10 =
`userAuthAlgorithmName`) and
`NoiXdev/Citadel` (from `orlandos-nl/Citadel` at 0.12.1; tags
`0.12.1-noix.N` carry upstream PR #135, the ECDSA parser and the RFC 8332
blob typing, and from `.3` on depend on the NoiXdev nio-ssh fork). The record
of what each fork carries and why lives in
`docs/superpowers/specs/2026-08-20-backlog-dependencies.md`; every fork
change is written there with the measurement that justified it.

A fork exists to carry a fix upstream does not have yet. That is a debt,
and its interest is paid by checking, not by remembering:

1. **Check both forks at every release and before every fork change**
   (a rebase, a cherry-pick, a new tag). For each: `git fetch upstream`
   in the fork clone, `git log --oneline <fork-base>..upstream/main`
   classified security / correctness / feature / noise, and
   `gh api repos/<upstream>/security-advisories`. A security commit
   upstream is cherry-picked first, before any feature work, as 0.3.8
   was. Write the count and the date into the dependencies record even
   when the count is zero — a zero measured on a date is evidence, a
   zero remembered is not.
2. **Ask, each time, whether the fork can be retired.** The fork is done
   when upstream carries what the fork carries: the RSA-SHA2 PR merged,
   an equivalent of `hostKeyAlgorithmNames` landed, the pre-line fix
   applied. When that is true, the override in `Package.swift` goes back
   to the upstream URL and a released tag, the fork record gets a
   "Retired" line, and the fork repository is archived — not deleted,
   the record points into it.
3. **Upstream what the fork carries.** Every change the fork makes that
   is not a cherry-pick is a PR candidate against upstream; open it, and
   name the PR in the fork record. A fork that never sends anything back
   grows its distance forever.
4. **A fork change is reviewed like any code here**, red first, with the
   fork's own suite green, a real observed red in the commit message and
   no fabricated hash (both happened once, 2026-09-01, and were caught
   before the push).

## Git

- Conventional Commits (enforced by CI); commit messages in English.
- Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Commit/push only on explicit request; the coordinator pushes per milestone
  after the final whole-branch review and watches CI (`gh run watch`).
