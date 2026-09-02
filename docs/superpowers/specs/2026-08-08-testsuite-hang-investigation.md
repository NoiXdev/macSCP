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

Sixteen red of nineteen full runs, twenty-five of twenty-five green alone. The failing assertion
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
