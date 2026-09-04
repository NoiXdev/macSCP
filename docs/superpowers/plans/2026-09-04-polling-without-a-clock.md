# Polling Without a Clock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every test that waits for a condition waits through one shared
helper that carries no wall-clock deadline of its own, under a harness
time limit that turns a real hang into a red naming the test.

**Architecture:** A new plain target `MacSCPTestSupport` (under
`Tests/`, no `Testing` import, so both test targets can depend on it)
holds `pollUntil(_:every:_:)`: it evaluates the condition, sleeps a
short interval, and repeats until the condition holds; it ends only when
its task is cancelled, which is what a suite-level
`.timeLimit(.minutes(1))` does. The twelve `waitUntil`-style helpers with
a `let deadline = ContinuousClock.now + …` collapse onto it; the
iteration-bounded `Task.yield` helpers (`EditSessionManagerTests`,
`TransferQueueViewModelTests`) stay, they never read a clock. A
source-scanning guard keeps the deadline shape out of `Tests/`.

**Tech Stack:** Swift 6 strict, SwiftPM (`swift-tools-version` 6.0),
Swift Testing (`.timeLimit` trait), `ContinuousClock`/`Task.sleep`.

**Spec:** `docs/BACKLOG.md`, row "Wall-clock ceilings still in the
tree" (measured 2026-09-04: 8 files carry a `let deadline =
ContinuousClock.now + …` helper — `TerminalPanelViewModelTests`,
`ConnectionViewModelTests`, `SubprocessRunnerTests`,
`WebDAVFileSystemIntegrationTests`, `LoopbackHTTPStub`,
`AlreadyOpenSessionTests`, `ReconnectPathTests`,
`ConnectAttemptHandoffTests`; `grep -rn "func waitUntil" Tests` finds 12
definitions and 79 call sites). The rule is CLAUDE.md, "A wall-clock
ceiling in a test measures the runner": a floor is fine, a ceiling can
always be defeated by a slow machine. Measured reds behind the rule: CI
run 33814867360 (an empty operation at 15.34 s against a 15 s ceiling),
run 33819886384 (a 12 s probe-side timer beaten by a 33 s resume), and
the 10.149 s red of `TerminalPanelViewModelTests.neverFiresWhenTheOpenFails`
under a 5 s poll (backlog row).

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No wall-clock ceiling in any test: no `let deadline = ContinuousClock.now + …`, no `elapsed < …`, no `Task.sleep` whose expiry is compared against something the runner must schedule. A floor (`elapsed >= …`) is allowed. The only clock is the harness `.timeLimit`, and it is `.minutes(1)` unless a suite's doc comment says why it needs more.
- Tests never block the cooperative pool: no `syncShutdownGracefully()`, `wait()`, `DispatchSemaphore`; every wait is an `await`.
- No `#require` on a non-optional; `#expect` prints its source text, so a value a test must not leak is computed into a `Bool` first.
- A negative source-scanning check needs a positive check beside it; a comment that quotes code near a scanner's anchor moves the anchor — describe in prose.
- A number written into a comment, a commit body or a backlog row is counted at the moment it is written (`grep -c`, `wc -l`).
- The migration changes no assertion's meaning: a caller that asserted `#expect(satisfied, "why")` keeps an assertion with the same description — see the recipe in Task 2.
- Every suite that calls `pollUntil` carries `.timeLimit(.minutes(1))` at the suite level (or on each of its tests).

---

### Task 1: The `MacSCPTestSupport` target and `pollUntil`

**Files:**
- Modify: `Package.swift` (a new `.target(name: "MacSCPTestSupport", path: "Tests/MacSCPTestSupport", swiftSettings: [.swiftLanguageMode(.v6)])` placed before the two test targets; both `.testTarget`s gain `"MacSCPTestSupport"` in `dependencies`)
- Create: `Tests/MacSCPTestSupport/PollUntil.swift`
- Test: `Tests/macSCPCoreTests/PollUntilTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// Evaluates `condition` until it is true, sleeping `interval` between
  /// evaluations. Carries NO deadline of its own: the only way out of a
  /// condition that never holds is cancellation of the calling task, which
  /// a Swift Testing `.timeLimit` trait performs — so every suite that
  /// calls this carries one. `what` is printed on cancellation so the
  /// harness's "time limit exceeded" red says which wait it was.
  public func pollUntil(
      _ what: String,
      every interval: Duration = .milliseconds(5),
      isolation: isolated (any Actor)? = #isolation,
      _ condition: () async -> Bool
  ) async throws
  ```
  `isolation: #isolation` is what lets a `@MainActor` test pass a closure
  that reads main-actor state without a hop: the function runs on the
  caller's actor.

- [x] **Step 1: Write the failing tests**

```swift
import Testing
import MacSCPTestSupport

@Suite("pollUntil", .timeLimit(.minutes(1)))
struct PollUntilTests {
    /// A condition that holds on the third evaluation returns after
    /// exactly three evaluations — the helper polls, it does not race.
    @Test func returnsOnceTheConditionHolds() async throws {
        var evaluations = 0
        try await pollUntil("three evaluations", every: .milliseconds(1)) {
            evaluations += 1
            return evaluations == 3
        }
        #expect(evaluations == 3)
    }

    /// A condition that never holds ends only through cancellation: the
    /// task is cancelled from outside, the helper throws
    /// `CancellationError`, and the test proves the evaluation count kept
    /// growing until then (a positive companion — a helper that returned
    /// at once would count one).
    @Test func endsOnlyThroughCancellation() async throws {
        let counter = EvaluationCounter()
        let waiter = Task {
            try await pollUntil("never", every: .milliseconds(1)) {
                await counter.bump() >= 0 && false
            }
        }
        while await counter.value < 5 { await Task.yield() }
        waiter.cancel()
        var thrown: (any Error)?
        do { try await waiter.value } catch { thrown = error }
        #expect(thrown is CancellationError)
        #expect(await counter.value >= 5)
    }

    /// The closure runs on the caller's actor: a main-actor test reads a
    /// main-actor property inside the condition without a hop.
    @MainActor
    @Test func theConditionRunsOnTheCallersActor() async throws {
        @MainActor final class Flag { var isSet = false }
        let flag = Flag()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            flag.isSet = true
        }
        try await pollUntil("the flag") { flag.isSet }
        #expect(flag.isSet)
    }
}

private actor EvaluationCounter {
    var value = 0
    func bump() -> Int { value += 1; return value }
}
```

- [x] **Step 2: Run to verify it fails**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head`
Expected: `no such module 'MacSCPTestSupport'` (the target does not exist).

- [x] **Step 3: Add the target and the helper**

`Package.swift`, before the two `.testTarget`s:

```swift
        // Shared by both test targets, which cannot share a source file
        // (SwiftPM compiles each target from its own directory). It imports
        // no test library, so it is a plain target; the two test targets
        // depend on it.
        .target(
            name: "MacSCPTestSupport",
            path: "Tests/MacSCPTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

and `"MacSCPTestSupport"` appended to both `.testTarget` dependency
lists.

`Tests/MacSCPTestSupport/PollUntil.swift`:

```swift
/// Evaluates `condition` until it is true, sleeping `interval` between
/// evaluations.
///
/// Carries NO deadline of its own. The tree used to hold twelve
/// `waitUntil` helpers, eight of them with a `let deadline =
/// ContinuousClock.now + …` — a wall-clock ceiling, and on a starved
/// three-core CI runner a ceiling measures the runner, not the property
/// (CLAUDE.md, "A wall-clock ceiling in a test measures the runner").
/// The only way out of a condition that never holds is cancellation of
/// the calling task, which a Swift Testing `.timeLimit` trait performs;
/// every suite that calls this carries one, and `PollingGuardTests`
/// checks that it does. On cancellation the name of the wait is printed
/// so the harness's "time limit exceeded" red says which wait it was.
///
/// `isolation` defaults to the caller's actor (`#isolation`), so a
/// main-actor test can read main-actor state in the condition without a
/// hop, and a nonisolated test gets a nonisolated poll.
public func pollUntil(
    _ what: String,
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async throws {
    while !(await condition()) {
        do {
            try await Task.sleep(for: interval)
        } catch {
            print("pollUntil: cancelled while waiting for \(what)")
            throw error
        }
    }
}
```

- [x] **Step 4: Run the new suite**

Run: `swift test --filter PollUntilTests 2>&1 | tail -3`
Expected: `Test run with 3 tests in 1 suite passed`.

- [x] **Step 5: Full suite, zero warnings, commit**

Run: `swift build --build-tests 2>&1 | grep -c "warning:"` → `0`; `swift test 2>&1 | tail -1` → green.

```bash
git add Package.swift Tests/MacSCPTestSupport/PollUntil.swift Tests/macSCPCoreTests/PollUntilTests.swift
git commit -m "test: a shared pollUntil with no deadline of its own, under the harness time limit"
```

---

### Task 2: Migrate `macSCPCoreTests`

**Files:**
- Modify: `Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift` (the file-level `waitUntil` at :32, 200 × 10 ms; the struct-level `waitUntil(_:timeout:)` at :1010 with its 5 s deadline; every caller of both)
- Modify: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (the file-level `waitUntil(_:timeout:sourceLocation:_:)` at :2269 and the cancellation watchdog described at :2291; every caller)
- Modify: `Tests/macSCPCoreTests/LoopbackHTTPStub.swift` (`waitForRequests(atLeast:within:)` at :100 — drop `within`, poll without a deadline; every caller)
- Modify: `Tests/macSCPCoreTests/WebDAVFileSystemIntegrationTests.swift` (`waitForTerminalStatus(…)` at :435)
- Modify: `Tests/macSCPCoreTests/SubprocessRunnerTests.swift:455-465` (the 10 s release deadline in the gated saturation test: each latch is awaited without a timeout — `done.wait()` with no `timeout:` if `AsyncSignal` offers it, else `pollUntil("block \(index) released") { done.isRaised }`)

**Interfaces:**
- Consumes: `pollUntil(_:every:isolation:_:)` from Task 1.

**The recipe.** The old helpers came in two shapes; both become a
`try await pollUntil` plus, where the old helper asserted, the same
assertion kept beside it:

Shape A — asserting helper returning `Bool`:

```swift
// before
let ready = await waitUntil("the panel ended", timeout: .seconds(5)) {
    if case .ended = vm.state { return true } else { return false }
}
guard ready else { return }

// after
try await pollUntil("the panel ended") {
    if case .ended = vm.state { return true } else { return false }
}
```

The `guard`/`#expect` on the Bool disappears: a wait that ends has
satisfied the condition, and a wait that does not end is the harness's
red, which names the test and (through the printed line) the wait.

Shape B — poll-then-assert:

```swift
// before
try await waitUntil(vm.output.count == 1)   // 200 × 10 ms, then #expect
#expect(vm.output.count == 1)

// after
try await pollUntil("one output chunk") { vm.output.count == 1 }
#expect(vm.output.count == 1)
```

The trailing `#expect` stays where the old helper had one: it is the
assertion the reader sees, and it is what a later regression that makes
the condition true and then false again would catch.

Every suite touched gains `.timeLimit(.minutes(1))` on its `@Suite` line
(a `struct` with only `@Test`s and no `@Suite` gets one added: `@Suite(.timeLimit(.minutes(1)))`).

- [x] **Step 1: Red first** — change one caller in `TerminalPanelViewModelTests` to `pollUntil` before the import exists in that file: `swift build --build-tests` fails with `cannot find 'pollUntil' in scope`. Add `import MacSCPTestSupport`; green. (The red here is the compile error; the behavioural claim — no deadline — is Task 1's.)
- [x] **Step 2: Migrate every caller** in the five files; delete the five helper definitions; count: `grep -c "pollUntil(" <file>` per file goes into the commit body, and `grep -rn "let deadline = ContinuousClock.now" Tests/macSCPCoreTests` must come back empty.
- [x] **Step 3: Run** `swift test 2>&1 | tail -1` (green) and `MACSCP_ITEST=1 swift test --filter "WebDAVFileSystem|LoopbackHTTP" 2>&1 | tail -1` (green; the rig is up), zero warnings.
- [x] **Step 4: Commit** `test(core): the Core suites poll through pollUntil, no deadline of their own`.

---

### Task 3: Migrate `macSCPAppKitTests`

**Files:**
- Modify: `Tests/macSCPAppKitTests/AlreadyOpenSessionTests.swift` (`waitUntil` at :112)
- Modify: `Tests/macSCPAppKitTests/ReconnectPathTests.swift` (`waitUntil` at :99)
- Modify: `Tests/macSCPAppKitTests/ConnectAttemptHandoffTests.swift` (`waitUntil` at :160, whose doc comment says the copy exists because the target "does not depend on `macSCPCoreTests`" — that sentence goes, the target now depends on `MacSCPTestSupport`)
- Modify: `Tests/macSCPAppKitTests/SSHTerminalViewSizingTests.swift` (`waitUntil` at :366, 200 × 10 ms, and the sibling actor-hop helper right below it — both onto `pollUntil`)
- Modify: `Tests/macSCPAppKitTests/LivenessProbeCancellationTests.swift` (`waitUntilTheProbeIsInFlight` at :161: keep the name, its body becomes `try await pollUntil("the probe reaching stat") { remoteFS.statHasBeenCalled }`; the `Issue.record` on the deadline goes — the harness red carries the printed wait name)

**Interfaces:**
- Consumes: `pollUntil(_:every:isolation:_:)` from Task 1; the recipe from Task 2 applies unchanged.

- [x] **Step 1: Red first** — same compile-error red as Task 2, then `import MacSCPTestSupport`.
- [x] **Step 2: Migrate every caller**, delete the five helper definitions, `.timeLimit(.minutes(1))` on every suite touched; `grep -rn "let deadline = ContinuousClock.now\|advanced(by: .seconds" Tests/macSCPAppKitTests` comes back empty.
- [x] **Step 3: Run** `swift test 2>&1 | tail -1` green, zero warnings.
- [x] **Step 4: Commit** `test(app): the App suites poll through pollUntil, no deadline of their own`.

---

### Task 4: The guard, and the backlog row

**Files:**
- Create: `Tests/macSCPCoreTests/PollingGuardTests.swift`
- Modify: `docs/BACKLOG.md` (row "Wall-clock ceilings still in the tree" → Done, with the counts)

**Interfaces:**
- Consumes: nothing new; it scans `Tests/` from `#filePath`.

- [x] **Step 1: Write the guard**

```swift
import Foundation
import Testing

/// Keeps the wall-clock deadline shape out of the test tree, now that
/// every poll goes through `pollUntil`. Two negative checks, each pinned
/// by a positive one beside it, per CLAUDE.md "Guards that name what
/// they watch".
@Suite("Polling guard")
struct PollingGuardTests {
    private static var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPCoreTests
            .deletingLastPathComponent()   // Tests
    }

    /// Every Swift file under Tests/, minus this guard and the helper.
    private static func sources() throws -> [(path: String, text: String)] {
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)!
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.path
            if path.hasSuffix("PollingGuardTests.swift") || path.hasSuffix("PollUntil.swift") { continue }
            result.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    /// Positive: the helper is in use. Without this, the negative checks
    /// below could pass over an empty tree.
    @Test func theTreePollsThroughTheSharedHelper() throws {
        let callers = try Self.sources().filter { $0.text.contains("pollUntil(") }
        #expect(callers.count >= 10, "\(callers.count) files call pollUntil")
    }

    /// Negative: no test builds its own deadline from the clock.
    @Test func noTestCarriesItsOwnDeadline() throws {
        let offenders = try Self.sources().filter {
            $0.text.contains("let deadline = ContinuousClock.now")
                || $0.text.contains("ContinuousClock.now.advanced(by:")
        }.map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Negative: no elapsed-time ceiling. The floor (`>=`, `>`) is allowed.
    @Test func noTestAssertsAnElapsedCeiling() throws {
        let pattern = try NSRegularExpression(pattern: #"elapsed\s*<=?\s*\."#)
        let offenders = try Self.sources().filter {
            pattern.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil
        }.map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Positive for the two negatives above, the other way round: a floor
    /// exists in the tree, so the ceiling regex is looking at real
    /// `elapsed` comparisons, not at nothing.
    @Test func aFloorExistsSoTheCeilingCheckHasSomethingToRead() throws {
        let floors = try Self.sources().filter { $0.text.contains("elapsed >= ") || $0.text.contains("elapsed > ") }
        #expect(!floors.isEmpty)
    }

    /// Every file that calls `pollUntil` declares a time limit, so a
    /// condition that never holds is a red, not a hang. Positive pairing:
    /// the caller list is the one the first test counted.
    @Test func everyCallerOfPollUntilDeclaresATimeLimit() throws {
        let callers = try Self.sources().filter { $0.text.contains("pollUntil(") }
        let withoutLimit = callers.filter { !$0.text.contains(".timeLimit(") }.map(\.path)
        #expect(!callers.isEmpty)
        #expect(withoutLimit.isEmpty, "\(withoutLimit)")
    }
}
```

- [x] **Step 2: Run it** — `swift test --filter PollingGuardTests 2>&1 | tail -2`: green after Tasks 2–3; then plant a violation (`scripts/mutation-probe --filter PollingGuardTests --apply "perl -0pi -e 's/try await pollUntil\(\"the panel ended\"\)/let deadline = ContinuousClock.now + .seconds(5); _ = deadline; try await pollUntil(\"the panel ended\")/' Tests/macSCPCoreTests/TerminalPanelViewModelTests.swift"`) and record the RESULT line (must be RED) in the commit body.
- [x] **Step 3: The backlog row** → `**Done 2026-09-04**` with: the target name, the number of helper definitions removed (count them in the diff of Tasks 2–3), the number of `pollUntil` callers (`grep -rc "pollUntil(" Tests | awk -F: '{s+=$2} END {print s}'`), the guard's five checks, the probe's RESULT line, and what stays open (the `Task.yield` iteration-bounded helpers, which read no clock, and any `Task.sleep(for:)` whose expiry a test compares against scheduled work — re-find with `grep -rn "asyncAfter\|Task.sleep(for: .seconds" Tests/`).
- [x] **Step 4: Commit** `test: a guard keeps the deadline shape out of the tree, and the backlog says so`.
