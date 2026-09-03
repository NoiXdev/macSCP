# The test suite's 0% CPU hang — investigation status

**As of:** 2026-08-08. **Not fixed.** What is written here is what is
secured, so the next round does not start from zero.

## Symptom

`swift test` occasionally comes to a stop and never terminates. The
process lives, uses 0.0% CPU, prints nothing further. In the ledger
since M20, seen multiple times: twice in a row in M21 (>10 min and
>7 min, a third run of the same working copy green in 3.4 s), once
during M21/T11, once in isolation on
`ImportConflictBridgeTests/aSecondAskResolvesTheStrandedFirstContinuation`
for over 14 hours.

## Immediate measure (implemented)

`timeout-minutes: 20` on the CI `test` job (`a75b0f5`). **That is the
safety net, not the fix.** Without it, a hang consumes the runner's
six-hour budget and never goes red — it is invisible in the run list and
expensive. Green runs take three to four minutes.

## Established

**The hang is a suspended task that is never resumed.**
Two live specimens were found on the maintainer's machine — orphans from
a session on 2026-08-06, alive for 46 hours at the time of the
investigation — and analyzed before being touched:

- `sample` shows **three threads, all idle**: the main thread in
  `swift_task_asyncMainDrainQueue` → `CFRunLoopRun` → `mach_msg2_trap`, a
  CFNetwork run-loop thread, an empty workqueue thread. **Not a single
  swift-testing or macSCP frame** on any stack except `main`.
- `lldb`: `current_task = id:0, address = 0x0` — no task is running on
  the main thread.

This is not a contradiction but the fingerprint: **a suspended Swift
task has no thread**, it sits on the heap. The harness's async main task
never finishes, so the drain loop never leaves the process.

**Consequence for tooling:** the stack cannot, in principle, say WHICH
test is hanging. Only the run's output can — swift-testing prints every
test on completion, so the last line names the candidate. Whoever
catches a hang must therefore **capture the log and `sample` before
killing the process.** That is what `scripts/hang-hunt` is for.

## Refuted

**`aSecondAskResolvesTheStrandedFirstContinuation` cannot deadlock this
way.** The test spins through 50 `Task.yield()` calls and then waits
with `await first.value` on a continuation that a second task must
resolve — this looked like the cause. It is not:
`ImportConflictBridgeTests` is `@MainActor`, and `await first.value`
**releases the MainActor**, so the second task is guaranteed to run and
free the first. The 50 yields are belt and braces, not load-bearing.

That the one hang ever observed in isolation landed exactly on this test
remains unexplained — but not through this mechanism.

## Not reproducible (two rounds, 280 runs)

| Round | Setup | Result |
|---|---|---|
| 1 | 40× full suite, sequential, quiet machine, own scratch path | 40/40 green, 3.5–6.1 s |
| 2 | 4 concurrent workers × 60× `--filter ImportConflictBridge`, own scratch paths | 240/240 green |

Round 2 deliberately combined the two conditions common to every
documented case and missing from round 1: **load** (every sighting fell
in sessions with subagents building in parallel) and **isolation** (the
one attributable case ran alone). Neither, nor both, sufficed.

The frequency is therefore below 1:280 under these conditions — or it
depends on something neither round had.

## Side finding: killed runs leave orphans

When a hanging `swift test` is killed, **its `swiftpm-testing-helper`
child survives**, gets reparented to `launchd`, and keeps running. The
two analyzed specimens sat around like this for 46 hours. This does not
cause the hang, but it makes it invisible and leaks processes and
memory.

So, after a manual kill, always:

```
pgrep -fl swiftpm-testing-helper
```

## Next step, should it recur

Do not try to provoke it — that cost 280 runs and produced nothing.
Instead, on the next genuine occurrence, capture **immediately**:

```
sample <pid> 3 -mayDie -f /tmp/hang.txt   # before the kill!
```

and note the **last line of the test output**. That is the one data
point still missing: the test's name. With it, the investigation
becomes a targeted question instead of a search.

---

## Addendum 2026-08-29: a second flake — measured, and the first explanation was wrong

**Resolved and explained.** This entry stays, because the explanation is
worth more than the bug.

`S3RedirectAuthorizationMeasurementTests` occasionally failed, sighted
independently twice. The explanation first noted here — tight wait
times under load — **is refuted.** 80 full runs across four rounds:

| Round | Setup | S3 suite red |
|---|---|---|
| 1 | four parallel builds as load | 3 / 20 |
| 2 | same load, instrumented | 3 / 20 |
| 3 | **with no load at all** | **7 / 20** |
| 4 | no load, `URLCache.shared` cleared per case | **0 / 20** |

**Without load, the rate was higher.** Load is a bystander. And it was
not the wait time either: in each of the 13 failures, another
**60 seconds elapsed unused** afterward (`extra=60.01 s`), where a green
run runs through the same wait in microseconds. There is no bound that
would have covered that — a larger one would only have lengthened every
red run.

### The cause: `URLCache.shared`

`S3FileSystem` runs over `URLSession.shared` and therefore over
`URLCache.shared` — a **persistent on-disk cache shared by all
processes**. The stub's 301 and 308 responses are cacheable and get
keyed to `http://127.0.0.1:<ephemeral port>/bucket?…`. Ephemeral ports
recur: if a run hits a port for which an **earlier `swift test`
process** has left an entry, the disk answers the signed request, and
the stub never sees it.

Evidenced across two processes: PROC1 sets up the stubs, PROC2 —
separate, with no listener of its own — finds `cachedEntry=true
status=308` and follows the Location, without ever touching the first
origin. Caching was measured for **301 and 308**, not for 302/303/307.

That the pattern usually looked harmless (two issues) has a reason: the
second stub is created first, so `p1 == p2 + 1` always holds, and the
stale Location points to the second stub of the *currently running*
case.

**The security guarantee itself never failed.** What failed each time
was a **positive** check — "the first origin was never reached" — and it
failed correctly. That is exactly what it exists for, alongside the
negative one.

### What follows from this

- **In the test:** the cache key must not recur. A bucket name unique
  per run is enough and changes no guarantee — better than
  `removeAllCachedResponses()`, which would also clear the developer's
  cache and other suites'.
- **In production, and this is the heavier part:** see
  `2026-08-29-backlog-s3-shares-the-url-session.md`.

### A lesson beyond this case

The first explanation was plausible, fit the observations, and was
wrong. It came from a **correlation** — both sightings occurred during
a build — and was only refuted once someone measured without load and
the rate rose. A cause inferred from coincidence is a hypothesis until
a round has deliberately tried to rule it out.

## Noted 2026-09-02 — the main-actor liveness suite in the full gated run

`ConnectMainActorLivenessTests` ("Connect against an unresponsive host:
main-actor liveness") derives its ceiling from an ambient gap measurement
and compares a wall-clock gap against it. Measured today, on the same
machine, no code change to dialing in between:

| run | context | result |
|---|---|---|
| full gated run | under load (clean build + review agent in parallel) | **red**, suite-level |
| full gated run | unloaded | green |
| full gated run | unloaded | green |
| full gated run | unloaded | **red**: `largestGap 0.70099 s` vs `ceiling 0.69847 s` — 2.5 ms over |
| full gated run | reviewer agent active, run took 90 s | **red**, 2 issues (later the same day) |
| full gated run | re-review agent active, run took 107 s | **red**, 1 issue (later still) |
| suite alone, ×12 | unloaded | green, 4.85–4.91 s each |
| full gated run | final-review agent active, run took 90 s (2026-09-02, later) | **red**, 1 issue: `largestGap 0.71431 s` vs `ceiling 0.66580 s` |
| suite alone, ×1 | unloaded (right after) | green, 4.86 s |
| full gated run | unloaded, run took 86 s (2026-09-02, later) | green |
| full gated run | unloaded, run took 89 s (2026-09-02, later still) | **red**, 1 issue: `largestGap 1.02735 s` vs `ceiling 0.54754 s` |
| suite alone, ×2 | unloaded (right after) | green |
| full gated run | implementer agent's own run, 3479 tests (2026-09-02, later) | **red**, 1 issue |
| suite alone, ×1 | unloaded (right after) | green, 4/4 |
| full gated run | unloaded, 3479 tests, run took 95 s (2026-09-02, later) | **red**, 1 issue: `largestGap 0.69317 s` vs `ceiling 0.68968 s` — 3.5 ms over |
| suite alone, ×1 | unloaded (right after) | green, 4.90 s |
| full gated run | implementer agent's own run, 3479 tests (2026-09-02, later) | **red**, 1 issue: `largestGap 0.669 s` vs `ceiling 0.434 s` |
| suite alone, ×1 | unloaded (right after) | green, 4/4 |
| full gated run | two review agents active, 3503 tests, run took 91 s (2026-09-02, evening) | **red**, 1 issue: `largestGap 0.74265 s` vs `ceiling 0.41437 s` |
| suite alone, ×1 | unloaded (right after) | green, 4/4 |
| full gated run | implementer agent's own run, 3539 tests (2026-09-02, later) | **red**, 1 issue: `largestGap 0.716 s` vs `ceiling 0.698 s` |
| suite alone, ×1 | unloaded (right after) | green, 4/4 |
| full gated run | review agent active, 3623 tests, run took 105 s (2026-09-02, evening) | **red**, 1 issue: `largestGap 1.137 s` vs `ceiling 0.3 s` |
| suite alone, ×1 | unloaded (right after) | green, 4.88 s |
| full gated run | review agent active, 3639 tests, run took 100 s (2026-09-02, night) | **red**, 1 issue: `largestGap 1.324 s` vs `ceiling 0.3 s` |
| suite alone, ×1 | unloaded (right after) | green |
| full gated run | implementer agent's own run, 3642 tests (2026-09-02, night) | **red**, 1 issue: `largestGap 1.137 s` vs `ceiling 0.715 s` |
| suite alone, ×1 | unloaded (right after) | green, 4/4 |
| full gated run | implementer agent's own run, 3642 tests (2026-09-02, night, RFC 8332 task) | **red**, 1 issue |
| suite alone, ×1 | unloaded (right after) | green, 4/4 |
| full gated run | review agent active, 3642 tests, run took 96 s (2026-09-02, night) | **red**, 1 issue: `largestGap 1.072 s` vs `ceiling 0.3 s` |
| suite alone, ×1 | unloaded (right after) | green |
| full gated run | 3712 tests, run took 117 s (2026-09-02, late night) | **red**, 1 issue: `largestGap 1.027 s` vs `ceiling 0.739 s` |
| suite alone, ×1 | unloaded (right after) | green |

Seventeen red of twenty full runs, twenty-six of twenty-six green alone — the last row before the rebuild (`../plans/2026-09-03-liveness-assertion-rebuild.md`). The failing assertion
is a wall-clock ceiling — the shape `TeardownStageTests` was moved away
from on 2026-08-28 for the same reason. This is the "test harness stalls
its own main actor" side finding from B-1 (2026-08-28), now with a
sensitivity number attached. Not fixed here; not a defect of the code
under test. Whoever takes it on: the assertion needs a form that does not
race the rest of the suite, and the entry above holds the M20 hang this
probably shares a cause with.

## Measured 2026-09-02 — one hang, sampled on CI, and its cause

The push `539dc59` (file keys of every type + S3 bucket list) hung CI
deterministically: on macos-15 (Xcode 16.4, Swift 6.1.2, three cores) the
Unit-Tests step printed all 3340 `started` lines within two seconds and
then nothing — zero completions in six minutes, twice. Locally (Swift
6.3.3, ten cores) the same tree ran green in 12 s, repeatedly.

Bisected with draft PRs: the tree minus the file-keys commits was green in
two minutes; the last green base plus only the file-keys commits hung. A
sampler branch then ran `swift test` in the background, waited 150 s, and
took `sample <pid> 3` of the still-running test process. The call graph
shows the process idle (0:13 CPU): the main thread in its run loop, one
NIO event-loop thread in `kevent`, and **three Swift Testing worker
threads all in the same place** —
`SSHPrivateKeyLoaderTests.offeredPublicKeyPrefixes` → `$defer #1` →
`EventLoopGroup.syncShutdownGracefully()` → `_dispatch_semaphore_wait_slow`
(`ecdsaCurveReachesItsOwnOffer` twice, `rsaKeyOffersSHA2Only` once). The
helper also blocked on `futureResult.wait()` per offer.

Why that stops everything: Swift Testing runs tests on the cooperative
thread pool, whose width is the core count. Three cores, three threads;
three parameterised cases each blocked a thread in a semaphore; no other
test — 3300 of them — could be scheduled. It is not a lock cycle and not
a slow test: it is a pool with every thread parked. Ten cores hide it
because the blocked three leave seven.

**Fix (`cdf46be`):** the helper is async and every wait is an `await`
(`futureResult.get()`, `shutdownGracefully()`); verified by CI run
33645664083 on that push: Unit-Tests green in 2 min 55 s where the two
runs before it had produced nothing in six. **What it does not settle:** whether the intermittent M20 hang
at the top of this entry has the same shape. It has the same symptom (a
test process parked at 0 % CPU) and this tree has more blocking waits on
the cooperative pool — `SSHAgentClientTests` waits on `EmbeddedChannel`
futures (which complete synchronously, so the wait returns at once),
`EmbeddedKeyPorterTests` and the gated `LivenessProbeDropIntegrationTests`
use a `DispatchSemaphore` — and production code parks a thread in
`AgentBackedPrivateKey` (NIOSSH's synchronous signing API) too. Each of
those is a candidate for the M20 hang on a small machine; none is
measured. A guard that forbids `syncShutdownGracefully(` and
`DispatchSemaphore` in test targets outside a named allowlist would keep
the fixed shape from coming back; the `sample` step on a branch is the
tool that finds the next one.

Process note: pushes to an existing pull-request branch from this session
triggered no workflow run (PRs 4, 5 and the sampler's second push), while
PR creation and pushes to `develop` did — so the verification ran on
`develop` itself, with the fix pushed alone ahead of unreviewed work.

**Follow-up named 2026-09-02 (night):** three ungated CLI suites run the
built binary and wait with `Process.waitUntilExit()` /
`DispatchGroup.wait` inside a synchronous `@Test`
(`CLISessionsJSONRoundtripTests`, `CLISessionNameCompletionTests`,
`CLIRootHelpTests`) — the same pool-blocking shape, parked one thread
each while a subprocess runs. Not yet a hang (the waits are short and the
runner has more threads than such tests), but exactly the shape the rule
above forbids; the fix is an async runner (`terminationHandler` bridged
through a continuation) shared by the three. Recorded by the review of
`d3e25bd`, which copied the sibling's pattern faithfully.

**Closed 2026-09-03:** it became a hang after all. The push `0175e90`
(CLI completion) left the three CLI subprocess tests reporting empty
output after 60 s on CI (run 33681669890, 22 issues, the other 3387 tests
"passed after 80 s" — a whole-suite stall) and a diagnostic run of the
same tree hung to the 20-minute timeout with no child ever observed. The
waits were replaced by an `async` runner (`Tests/macSCPCoreTests/Support/
SubprocessRunner.swift`: `Process.terminationHandler` raises an
`AsyncSignal` latch that the caller awaits — no `CheckedContinuation`, the
shape round 1 rejected; readers are `FileHandle.readabilityHandler`
sources, which park no thread), every child process in the suite goes through it, and a
guard scans `Tests/` for the blocking patterns (allowlist: the AppKit
target's `defer`-bound docker calls and the liveness plant). Three CI runs
measured the fix on the three-core runner: 33693297919 at `e16b14ae`
(suite in 40.7 s, one new runner test red — readers used
`readDataToEndOfFile`), 33698102652 at `0ef63269` (35.2 s, the same two
tests red — incremental `availableData` readers still parked a global-queue
thread each, and a starved process never ran them: "waited 9.951 s for the
2.0 s bound"), 33701218149 at `ae5501ff` (**green**, 3743 tests in 34.98 s,
Unit-Tests step 00:50–00:55 UTC). Two more rounds followed for the
pipes' lifetime and a pool-saturation proof: 33705649537 at `126c5c88`
(red — the saturation test held the global queue for 23.5 s on three
cores and pushed two neighbours past their bounds; it now runs only under
`MACSCP_SATURATION=1`), 33707411271 at `aadbafca` (red — one 200 ms latch
sleep fired after 10.38 s against a 10 s ceiling; the ceiling was dropped,
the floor and the outcome stay), 33707786680 at `c8eebbd3` (**green**,
3750 tests in 31.88 s, step 02:28–02:34 UTC; liveness test1 ambient
14.99 s, gap 0.17 s). The plan is
`docs/superpowers/plans/2026-09-03-subprocess-runner-async.md`.

## Decided 2026-09-02 (night) — the liveness assertion gets rebuilt

Sixteen red of nineteen full gated runs today, twenty-five of
twenty-five green alone: the property (`ConnectMainActorLivenessTests`:
the main actor keeps running while a real dial stalls) is real, the
shape (a wall-clock gap under a fixed ceiling, while 3700 other tests
compete for the same cores) is not. The maintainer chose the rebuild
over an isolated run and over leaving it. Plan to follow:
`2026-09-03-liveness-assertion-rebuild.md` — the measurement stays, the
comparison becomes relative to a control measured under the same load
in the same run (or the dial's stall is proved by a probe that cannot be
starved), and the full-run tally in this entry stops growing.

**Closed 2026-09-03** — see "Rebuilt 2026-09-03 — the ceiling, the numbers, what stays open" below.

## Rebuilt 2026-09-03 — the ceiling, the numbers, what stays open

The tally in "Noted 2026-09-02" above closes at **seventeen of twenty
full gated runs red, twenty-six of twenty-six green alone**, under the
old ceiling (`max(ambient, .milliseconds(300))`). It does not grow
further; everything measured against the rebuilt assertion is recorded
here instead. This section is data copied from the rebuild's own
records — `.superpowers/sdd/2026-09-03-liveness-assertion-rebuild/`
(`task-1-report.md`, `task-1b-report.md`, `task-1-review.md`,
`task-1-rereview.md`) — not re-derived.

### The rebuilt assertion

`ceiling(forAmbient:)` is now
`min(max(ambient * 3, .seconds(2)), .seconds(4))`. Both timing dials now
run at least 5 s: the fake connector's total dial is 5.0 s (an unchanged
600 ms synchronous block, deliberately capped there, plus a 4400 ms
`Task.sleep` suspension); the stalled-dial test's `connectTimeout` is 6 s,
with an elapsed guard of `> 5 s`. A second elapsed guard was added to the
fake-connector test this round, pinning `> 4 s`.

### The measurements

- **Planted (5 s main-actor block), suite alone, ×10:** 10 of 10 red in
  both timing tests, gaps 5.000–5.019 s against a 2.0 s ceiling, ambient
  0.025–0.044 s.
- **Unplanted, suite alone, ×10:** 10 of 10 green, 13.75–13.85 s per run.
- **`MACSCP_ITEST=1 swift test` ×10:** the liveness suite green 10 of 10
  (23.1–61.5 s per run; both timing tests actually executed every time,
  never skipped by the endpoint's availability probe). Of those ten full
  runs, run 2 was red elsewhere
  (`TerminalPanelViewModelTests.neverFiresWhenTheOpenFails`) and run 4
  **hung** in
  `aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound`
  (`macSCPAppKitTests`), killed after 2215 s — the hang family this
  record tracks, reproduced 2026-09-03. It did not recur in the two full
  runs of fix round 1.
- **Fix round 1's planted full gated run** (2026-09-03,
  `MACSCP_ITEST=1 swift test`, 3723 tests, 95.684 s): test 1 red with a
  gap of 5.028 s against a ceiling of 4.0 s at an ambient of 5.726 s — the
  uncapped `ambient * 3` would have set 17.2 s and let the plant pass;
  test 2 red with a gap of 5.010 s against a ceiling of 2.0 s at an
  ambient of 0.030 s. After the fix: alone, green in 13.809 s; the full
  gated run green, 3723 tests in 87.772 s, the liveness suite in
  22.722 s.
- **A green run now prints its numbers.** The two lines, alone, green:

  ```
  liveness: test1 ambient=0.029770375 seconds gap=0.03185825 seconds ceiling=2.0 seconds
  liveness: test2 ambient=0.036180709 seconds gap=0.03333475 seconds ceiling=2.0 seconds
  ```

- **First measurement on the 3-core CI runner:** run 33693297919 at
  `e16b14ae` (2026-09-02 23:03–23:10 UTC): the liveness suite passed in
  40.681 s, the whole suite ran 3732 tests in 40.691 s (the run was red
  for one unrelated new SubprocessRunner test, tracked in its own plan).
  This is one green, not a tally.

### Deferred minors, recorded rather than actioned

- The 600 ms `usleep` in the fake connector parks a cooperative-pool
  thread by design — bounded, pre-existing, and load-bearing: it is what
  makes the `ranOnMainThread == false` check worth making, as the worst
  case a real connector's synchronous body could produce. It is the one
  allowed exception to this file's rule against a blocking wait in a test
  target, named here so the next person does not rediscover it as a
  violation.
- The "0.67–1.32 s" noise range quoted in the suite's doc comment covers
  only the twelve of the seventeen red tally rows above that recorded a
  gap; five red rows recorded no number.
- The elapsed guards (`> 4 s` on the fake-connector test, `> 5 s` on the
  stalled-dial test) pin the dial's floor, not its ceiling: they prove
  the dial ran at least that long, not that it did not run far longer
  under load. Test 1 took 14.6 s in the fix round 1 green full run and
  20.3 s in its planted run, for a 5 s dial — the guard does not see
  that, and is not meant to; it exists to catch a trimmed sleep, not slow
  scheduling.

### Measured on CI, 2026-09-03

The printed lines from the three-core runner, two runs (the ambient window
there is far wider than the cap, the gaps are not):

```
33698102652: liveness: test1 ambient=9.387292333 seconds gap=0.56635025 seconds ceiling=4.0 seconds
33698102652: liveness: test2 ambient=0.1779855 seconds gap=0.170422584 seconds ceiling=2.0 seconds
33701218149: liveness: test1 ambient=13.997288875 seconds gap=0.169570416 seconds ceiling=4.0 seconds
33701218149: liveness: test2 ambient=0.162261292 seconds gap=0.177697167 seconds ceiling=2.0 seconds
```

Three runs — one red for a runner test (33698102652), two green — with an
ambient of 9.4 s, 14.0 s and 15.0 s against a 4 s cap: the cap binds on CI
in every run so far, and the largest gap stayed under 0.6 s. That is three
data points, not a tally.

### What stays open

- **The frozen-peer hang is reproduced, its cause not measured.** Run 4
  of the ten `MACSCP_ITEST=1 swift test` runs above hung in
  `aReadHandleCloseAgainstAStillFrozenPeerReturnsInsideTheBound`
  (`macSCPAppKitTests`), killed after 2215 s. It did not recur in fix
  round 1's two full runs, but one non-reproduction is not evidence it is
  gone. This is the hang family the top of this entry tracks.
- **The false-red regime above the 4 s cap is reachable.** An ambient of
  5.726 s was observed in a full gated run (fix round 1's planted run,
  above) — above the cap and above the 4.7 s instrument floor named in
  the suite's own doc comment (measured 2026-08-28, a bare ticker over a
  different suite population, not re-measured here). No *unplanted* gap
  above 4 s has been seen yet,
  so whether noise alone ever produces one is unmeasured. The two printed
  lines make this countable going forward: a grep over CI output for
  `liveness: test` lines against an ambient of 1.333 s (where the cap
  starts to bind) or a gap approaching 4.0 s turns the open question into
  a log search instead of another planted run.
- **The elapsed guard pins only the floor**, as recorded above under
  deferred minors — a run where load stretches the dial itself is still
  invisible to it.
