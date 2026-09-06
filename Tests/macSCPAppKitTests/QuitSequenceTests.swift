import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// The quit sequence: what ⌘Q decides, in which order it does it, and who
/// is allowed to run a teardown (Quit Teardown plan, Task 1).
///
/// Before this plan ⌘Q ran no teardown at all (`docs/BACKLOG.md`, "Quit
/// tears down nothing"): `applicationWillTerminate` is synchronous while
/// `ContentView.teardown(_:reason:)` is main-actor `async`, so the delegate
/// could only record that a parked seed existed. `applicationShouldTerminate`
/// is the callback that can defer — it returns `.terminateLater` and the app
/// replies when it is finished — and this suite pins the sequence that
/// deferral runs.
///
/// **What is a value test here and what is a source guard.** The decision,
/// the step order, the log line and the registry's hand-out are values, so
/// they are driven directly. The delegate's own body cannot be driven from a
/// test — running it would terminate the test process — so the ORDER inside
/// it is read from source, positionally, the same way this target's other
/// wiring guards read a view body. Every positional pin below is also a
/// presence check: a needle that has moved out of the body fails on "not
/// found" before any ordering claim is made.
@Suite("Quit sequence")
@MainActor
struct QuitSequenceTests {

    // MARK: - The decision

    /// Nothing live: the app has nothing to tear down, so it must not make
    /// the user wait for a deferral it would spend on an empty loop.
    @Test func nothingLiveQuitsImmediately() {
        #expect(QuitSequence.decision(liveTabCount: 0, runningTunnelCount: 0) == .now)
    }

    /// A forwarding is reachable from no tab and no window, so it is counted
    /// on its own: an app with tunnels up and nothing connected must still
    /// take the deferred path, which is the only one that stops them
    /// (port-forwarding plan, Task 6).
    @Test func aRunningTunnelDefersTheQuitWithNoTabAtAll() {
        #expect(QuitSequence.decision(liveTabCount: 0, runningTunnelCount: 1) == .later)
        #expect(QuitSequence.decision(liveTabCount: 0, runningTunnelCount: 4) == .later)
    }

    /// One live tab is already enough to defer — the whole point of the
    /// deferral is the `disconnected` audit row that tab's teardown writes.
    @Test func oneLiveTabDefersTheQuit() {
        #expect(QuitSequence.decision(liveTabCount: 1, runningTunnelCount: 0) == .later)
        #expect(QuitSequence.decision(liveTabCount: 7, runningTunnelCount: 0) == .later)
    }

    // MARK: - The step order

    /// The order the delegate is held to below, as a value: restoration
    /// seeds first (a teardown clears `activeStoredSessionID`, so describing
    /// the windows afterwards would describe them empty), the parked sweep
    /// before the windows (a parked tab is in no window, so no window's
    /// closure can reach it), then the quit line, the flush and the reply
    /// last.
    @Test func theStepsAreInTheOrderTheDelegateRunsThem() {
        #expect(QuitSequence.steps == [
            .writeRestoration, .teardownParked, .stopTunnels, .teardownWindows,
            .logQuit, .flush, .reply,
        ])
    }

    /// The line the deferred path writes, counts only — window and tab ids
    /// are not in it, and neither is anything a user typed.
    @Test func theQuitLineCarriesCountsAndTheWatchdogVerdict() {
        #expect(
            QuitSequence.quitLine(windows: 2, tornDown: 2, forced: false)
                == "quit windows=2 tornDown=2 forced=false")
        #expect(
            QuitSequence.quitLine(windows: 3, tornDown: 1, forced: true)
                == "quit windows=3 tornDown=1 forced=true")
    }

    // MARK: - The registry hands out, it never runs

    /// Collects the closure calls a test's own loop makes, so "each ran
    /// exactly once, in this order" is a value rather than a count.
    @MainActor
    private final class TeardownRecorder {
        private(set) var ran: [String] = []
        func record(_ name: String) { ran.append(name) }
    }

    /// Registration order, and — the half that matters for the invariant —
    /// nothing has run at the moment the registry hands them back. The
    /// running is done by the loop in THIS test; `TabRegistry` awaits
    /// nothing (`TabRegistryNoTeardownGuardTests` reads its source for
    /// exactly that).
    @Test func theRegistryHandsWindowTeardownsBackInRegistrationOrder() async {
        let registry = TabRegistry()
        let recorder = TeardownRecorder()
        let first = WindowID()
        let second = WindowID()
        registry.registerWindowTeardown({ recorder.record("first") }, for: first)
        registry.registerWindowTeardown({ recorder.record("second") }, for: second)

        let handed = registry.allWindowTeardowns()
        #expect(handed.map(\.0) == [first, second])
        #expect(recorder.ran.isEmpty, "the registry ran a teardown closure by itself")

        for (_, run) in handed { await run() }
        #expect(recorder.ran == ["first", "second"])
    }

    /// A window that closed is not torn down a second time at quit: its
    /// close path unregisters, and the quit sweep then has nothing of its
    /// to hand out.
    @Test func anUnregisteredWindowIsNotHandedOutAgain() {
        let registry = TabRegistry()
        let recorder = TeardownRecorder()
        let closing = WindowID()
        let staying = WindowID()
        registry.registerWindowTeardown({ recorder.record("closing") }, for: closing)
        registry.registerWindowTeardown({ recorder.record("staying") }, for: staying)

        registry.unregisterWindowTeardown(for: closing)
        #expect(registry.allWindowTeardowns().map(\.0) == [staying])
    }

    /// Re-registering keeps the position a window first appeared in — the
    /// same rule `registerWindowDescriber(_:for:)` follows, because a window
    /// runs its setup pass more than once.
    @Test func reRegisteringKeepsTheWindowsFirstPosition() async {
        let registry = TabRegistry()
        let recorder = TeardownRecorder()
        let first = WindowID()
        let second = WindowID()
        registry.registerWindowTeardown({ recorder.record("first") }, for: first)
        registry.registerWindowTeardown({ recorder.record("second") }, for: second)
        registry.registerWindowTeardown({ recorder.record("first again") }, for: first)

        let handed = registry.allWindowTeardowns()
        #expect(handed.map(\.0) == [first, second])
        for (_, run) in handed { await run() }
        #expect(recorder.ran == ["first again", "second"])
    }

    // MARK: - Source guards

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/QuitSequenceTests.swift`; three
    /// `deletingLastPathComponent()` calls recover the repo root regardless
    /// of `swift test`'s working directory — the recipe
    /// `TabRegistryNoTeardownGuardTests` uses.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourcesRoot = repoRoot.appendingPathComponent("Sources")
    private static let appFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift")
    private static let tabTeardownFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabTeardown.swift")
    private static let stageFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TeardownStage.swift")
    private static let lifecycleFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
    private static let quitSequenceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/QuitSequence.swift")

    /// The signature wraps over three lines in the source, so the anchor is
    /// the part that cannot: the name and its opening parenthesis.
    private static let shouldTerminateDeclaration = "func applicationShouldTerminate("
    private static let boundedTeardownDeclaration = "private func runBoundedQuitTeardown("
    private static let boundedTunnelStopDeclaration = "private func runBoundedTunnelStop("
    /// Anchored on the RETURN TYPE, not on `static func run(`: that
    /// declaration's parameter list carries a default closure argument, so
    /// the first `{` after the name opens the DEFAULT VALUE and a
    /// brace-balanced read from there scans `try await Task.sleep(for: $0)`
    /// instead of the function. Measured 2026-09-06 — the check failed on
    /// that four-word body, which is at least loud; a negative check
    /// anchored the same way would have passed over it in silence.
    private static let boundedStepDeclaration = "async -> BoundedStepOutcome"
    private static let teardownChainDeclaration =
        "static func run(_ work: QuitWorkList) async -> QuitRaceOutcome"

    /// The strict (comments-and-string-literals-blanked) view of one file —
    /// a guard reading raw source cannot tell a call from a sentence about a
    /// call (CLAUDE.md, "Source-scanning guards read comments too"), and this
    /// file's own prose names every needle below.
    private static func strictSource(of file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            String(contentsOf: file, encoding: .utf8))
    }

    /// The character index of `needle`'s first occurrence in `text`, or
    /// `nil`. Indices into the same string are what the ordering claims
    /// below compare; nothing here converts them back to a position in the
    /// file.
    private static func firstIndex(of needle: String, in text: String) -> Int? {
        guard let range = text.range(of: needle) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// The seven needles, in the order `QuitSequence.steps` says they must
    /// occur, spelled once — counted 2026-09-06, when `runBoundedTunnelStop(`
    /// joined them for `QuitStep.stopTunnels`. That step is a call to the
    /// delegate's own bounded wrapper rather than to `TunnelManager.shared
    /// .stopAll(` directly (fix round 1 gave it a bound of its own); what
    /// the wrapper does is read in `theDeferredQuitBoundsTheTunnelStop`
    /// below, the same split `runBoundedQuitTeardown(` already has.
    /// `sweepUnclaimedMoves(` is the parked sweep and
    /// `runBoundedQuitTeardown(` is the window loop — both are calls, so a
    /// rename turns the guard red (nothing left to find) rather than
    /// silently satisfying it.
    private static let orderedNeedles = [
        "writeRestorationSeeds(",
        "sweepUnclaimedMoves(",
        "runBoundedTunnelStop(",
        "runBoundedQuitTeardown(",
        "QuitSequence.quitLine(",
        "flushSynchronously(",
        "reply(toApplicationShouldTerminate:",
    ]

    /// The delegate's body, read positionally. Each needle is asserted
    /// PRESENT first — an ordering claim over a needle that is not there is
    /// no claim at all — and only then are the positions compared.
    ///
    /// The `switch` puts `.later` first precisely so this reading is
    /// possible: `.now` repeats `writeRestorationSeeds(`,
    /// `sweepUnclaimedMoves(` and `flushSynchronously(`, and a first-
    /// occurrence pin can only be read if the deferred path — the one with
    /// all seven steps — comes first in the source.
    @Test func theDelegateRunsTheQuitStepsInOrder() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.shouldTerminateDeclaration, in: source)
        #expect(
            body.contains("QuitSequence.decision(liveTabCount:"),
            "the scanned span is not applicationShouldTerminate's body")

        var positions: [Int] = []
        for needle in Self.orderedNeedles {
            guard let index = Self.firstIndex(of: needle, in: body) else {
                Issue.record("applicationShouldTerminate's body no longer calls \"\(needle)\"")
                continue
            }
            positions.append(index)
        }
        #expect(positions.count == Self.orderedNeedles.count)
        #expect(positions == positions.sorted(), """
            applicationShouldTerminate runs the quit steps out of order — found, by first \
            occurrence: \(zip(Self.orderedNeedles, positions).map { "\($0.0)@\($0.1)" })
            """)
    }

    /// The tunnel step carries the SAME bound as the teardown chain
    /// (port-forwarding plan, Task 6, fix round 1): `stopAll()` waits for
    /// every runner's run task, and a runner parked in a dial is bounded by
    /// `connectTimeoutSeconds` — up to 120 s — which unbounded sat in front
    /// of a quit whose watchdog is 15 s.
    ///
    /// Read from the wrapper's own body, positionally-free: what is claimed
    /// is that the race exists, stops the tunnels, and reads its constant
    /// from the one place that names it. How long a quit takes is asserted
    /// nowhere (CLAUDE.md, "A wall-clock ceiling in a test measures the
    /// runner").
    @Test func theDeferredQuitBoundsTheTunnelStop() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.boundedTunnelStopDeclaration, in: source)
        #expect(
            body.contains("TunnelManager.shared.stopAll("),
            "the bounded tunnel step no longer stops the tunnels")
        #expect(
            body.contains("BoundedStep.run("),
            "the tunnel stop no longer runs under a bound")
        #expect(
            body.contains("QuitWatchdog.bound"),
            "the tunnel stop no longer reads QuitWatchdog.bound")

        // The bound itself is `BoundedStep`'s, and it is DRIVEN below
        // (`aBoundedStepReturnsWhenTheBoundElapsesEvenIfTheWorkNeverDoes`)
        // rather than only read here — round 1's version passed a source
        // read of exactly this shape while bounding nothing at all.
        let step = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.boundedStepDeclaration,
            in: try Self.strictSource(of: Self.quitSequenceFile))
        #expect(step.contains("withTaskGroup"), "the bounded step no longer races anything")
        #expect(step.contains("group.cancelAll()"), "the loser of the race is no longer cancelled")
    }

    // MARK: - The bound, driven

    /// A fake `stopAll()` that parks the way the real one can — and, the
    /// half that matters, parks UNCANCELLABLY.
    ///
    /// `TunnelRunner.stop()` ends at `await mine.value` on a
    /// `Task<Void, Never>`, which ignores its awaiter's cancellation (its
    /// own `performStop()` doc comment says so, and says why). A fake that
    /// parked on something cancellable would let round 1's `TaskGroup`
    /// version pass this suite — measured 2026-09-06: with a cancellable
    /// park, planting that version back is GREEN, because `cancelAll()` then
    /// really does end the work. The defect was never "the group forgot to
    /// cancel"; it was "the work cannot be cancelled", and only a fake with
    /// that property can tell the two apart.
    @MainActor
    private final class ParkingStopper {
        private(set) var entered = 0
        private(set) var finished = false
        private var release: AsyncStream<Void>.Continuation?

        func stopAll() async {
            entered += 1
            let (parked, continuation) = AsyncStream<Void>.makeStream(of: Void.self)
            release = continuation
            await Task { @MainActor in
                for await _ in parked { break }
            }.value
            finished = true
        }

        /// Lets the parked work end, so the test leaves no task suspended
        /// behind it.
        func releaseTheWork() { release?.finish() }
    }

    /// Carries a result out of an unstructured task — the test never awaits
    /// that task's `value`, which would be the very uncancellable wait this
    /// suite is about.
    @MainActor
    private final class OutcomeBox {
        private(set) var outcome: BoundedStepOutcome?
        func record(_ value: BoundedStepOutcome) { outcome = value }
    }

    /// The property the comment claims: the CALLER stops waiting when the
    /// bound elapses, even though the work has not finished and cannot be
    /// cancelled.
    ///
    /// The sleeper is injected and returns at once, so nothing here waits on
    /// a clock (CLAUDE.md, "A wall-clock ceiling in a test measures the
    /// runner"), and the step is read through a box rather than awaited —
    /// under a version that does not bound, the poll is what the suite's
    /// `.timeLimit` ends, which is a verdict; `await step.value` would be a
    /// hang.
    @Test func aBoundedStepReturnsWhenTheBoundElapsesEvenIfTheWorkNeverDoes() async throws {
        let stopper = ParkingStopper()
        let box = OutcomeBox()
        _ = Task { @MainActor in
            box.record(
                await BoundedStep.run(bound: QuitWatchdog.bound, sleeper: { _ in }) {
                    await stopper.stopAll()
                })
        }

        try await pollUntil("the bounded step returned") { box.outcome != nil }
        #expect(box.outcome == .timedOut)
        #expect(stopper.entered == 1, "the bounded step never started the work")
        #expect(
            stopper.finished == false,
            "the work finished by itself — this test proves nothing about the bound")

        stopper.releaseTheWork()
        try await pollUntil("the abandoned work ended") { stopper.finished }
    }

    @MainActor
    private final class Done {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// The bound is production, not a test ceiling (CLAUDE.md, "A wall-clock
    /// ceiling in a test measures the runner"): nothing here asserts how
    /// long a quit takes, only that the race exists and reads its constant
    /// from the one place that names it.
    @Test func theDeferredQuitRacesTheWatchdog() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.boundedTeardownDeclaration, in: source)
        #expect(body.contains("withTaskGroup"), "the quit teardown no longer races anything")
        #expect(
            body.contains("QuitWatchdog.bound"),
            "the quit teardown's sleeper no longer reads QuitWatchdog.bound")
        #expect(body.contains("Task.sleep("), "the watchdog child no longer sleeps")
        #expect(body.contains("group.cancelAll()"), "the loser of the race is no longer cancelled")
        #expect(
            body.contains("QuitTeardownChain.run("),
            "the race no longer runs the teardown chain")

        // The chain itself: the one owner for a parked tab, the window
        // closures in order, and the cancellation check that is what makes
        // the watchdog mean anything. It moved to QuitSequence.swift in fix
        // round 1 so a test could drive it — see
        // `aCancelledChainStartsNoFurtherWindow` below, which measures the
        // property this source read only describes.
        let chain = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.teardownChainDeclaration,
            in: try Self.strictSource(of: Self.quitSequenceFile))
        #expect(
            chain.contains("TabTeardown.run("),
            "the quit no longer tears parked tabs down through the one owner")
        #expect(
            chain.contains("await runWindowTeardown()"),
            "the quit no longer runs each window's own teardown closure")
        #expect(
            chain.components(separatedBy: "Task.isCancelled").count - 1 == 2, """
            the chain no longer checks cancellation before BOTH of its loops — the parked \
            sweep and the window loop each need their own check, or the watchdog stops \
            meaning anything for whichever one lost it.
            """)
    }

    /// The window's own two loops check cancellation between TABS (fix
    /// round 1). Without this, a cancelled window still tore down every tab
    /// it held, so the overrun past `QuitWatchdog.bound` scaled with the tab
    /// count instead of being one tab.
    ///
    /// A source guard rather than a value test, and the reason is worth
    /// writing down: both loops are methods on `ContentView`, a SwiftUI
    /// view this project has no way to construct in a test (see
    /// `ViewTestabilitySpike`). The property they share with the chain IS
    /// measured, on the chain, by `aCancelledChainStartsNoFurtherWindow`
    /// below; this says the same check is in the two places a test cannot
    /// reach.
    ///
    /// POSITIVE first in both: the loop still tears a tab down at all. A
    /// `!contains`-shaped claim over a body that no longer runs `teardown`
    /// would pass while doing nothing (CLAUDE.md, "Guards that name what
    /// they watch").
    @Test func eachWindowsOwnLoopsStopBetweenTabsWhenCancelled() throws {
        let source = try Self.strictSource(of: Self.lifecycleFile)
        for declaration in [
            "private func tearDownUnclaimedSeeds(_ tabs: [SessionTab]) async",
            "private func tearDownHeldTabs(_ held: [SessionTab], from closingWindow: WindowID) async",
        ] {
            let body = try TransferQueueBarCancelGuardTests.declarationBody(
                of: declaration, in: source)
            let tearsDown = Self.firstIndex(of: "await teardown(", in: body)
            let checks = Self.firstIndex(of: "if Task.isCancelled { return }", in: body)
            #expect(tearsDown != nil, "\(declaration) no longer tears any tab down")
            #expect(checks != nil, """
                \(declaration) no longer stops between tabs when the quit's watchdog cancels \
                it — one frozen window would run every tab it holds past the bound.
                """)
            if let tearsDown, let checks {
                #expect(checks < tearsDown, """
                    \(declaration) checks cancellation AFTER tearing a tab down rather than \
                    before — the check has to sit between tabs, never inside one.
                    """)
            }
        }
    }

    // MARK: - A cancelled chain starts nothing further

    /// A one-shot gate, opened once and awaited any number of times before
    /// or after. `AsyncStream` buffers the yield, so the two sides need no
    /// ordering between them and nothing blocks a thread (CLAUDE.md, "Tests
    /// never block the cooperative pool" — every wait here is an `await`).
    @MainActor
    private final class Gate {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            var escaping: AsyncStream<Void>.Continuation!
            stream = AsyncStream { escaping = $0 }
            continuation = escaping
        }

        func open() {
            continuation.yield(())
            continuation.finish()
        }

        func wait() async {
            for await _ in stream { return }
        }
    }

    /// The property `QuitWatchdog.bound` is worth anything for: once the
    /// chain is cancelled, it starts no further window.
    ///
    /// **No clock anywhere** (CLAUDE.md, "A wall-clock ceiling in a test
    /// measures the runner"). The ordering is forced by a seam instead: the
    /// first window's closure signals that it has been entered and then
    /// parks on a gate, so the cancellation provably lands while the chain
    /// is INSIDE the first item. Which items ran is then a recorded value,
    /// not a race.
    ///
    /// The window closures are the real production seam — `TabRegistry
    /// .WindowTeardown` is exactly `@MainActor () async -> Void` — so
    /// nothing here is a stand-in for the shape under test.
    @Test func aCancelledChainStartsNoFurtherWindow() async {
        let entered = Gate()
        let release = Gate()
        let recorder = TeardownRecorder()
        let work = QuitWorkList(
            parked: [],
            windows: [
                (WindowID(), { @MainActor @Sendable in
                    recorder.record("first")
                    entered.open()
                    await release.wait()
                }),
                (WindowID(), { @MainActor @Sendable in recorder.record("second") }),
                (WindowID(), { @MainActor @Sendable in recorder.record("third") }),
            ])

        let chain = Task { @MainActor in await QuitTeardownChain.run(work) }
        await entered.wait()
        chain.cancel()
        release.open()
        let outcome = await chain.value

        #expect(recorder.ran == ["first"], """
            a cancelled chain went on to start further windows — the watchdog would then \
            bound nothing at all.
            """)
        #expect(outcome == .chainFinished(tornDown: 1), """
            the chain reported \(outcome) — the count must be the windows that actually \
            finished, which is what tornDown= beside windows= is read for.
            """)
    }

    /// The control beside it: an UNCANCELLED chain runs every window, in
    /// registration order, exactly once. Without this, the expectation above
    /// would be satisfied by a chain that never ran anything past its first
    /// item for any reason at all.
    @Test func anUncancelledChainRunsEveryWindowInOrder() async {
        let recorder = TeardownRecorder()
        let work = QuitWorkList(
            parked: [],
            windows: [
                (WindowID(), { @MainActor @Sendable in recorder.record("first") }),
                (WindowID(), { @MainActor @Sendable in recorder.record("second") }),
                (WindowID(), { @MainActor @Sendable in recorder.record("third") }),
            ])

        let outcome = await QuitTeardownChain.run(work)
        #expect(recorder.ran == ["first", "second", "third"])
        #expect(outcome == .chainFinished(tornDown: 3))
    }

    /// Both ends of the window's own registration, in the two places its
    /// life is already bracketed — and the ORDER inside the close handler,
    /// which is what keeps a window from being torn down twice.
    ///
    /// A window that closed runs its close sequence itself, in its
    /// `willClose` handler. If the quit sweep could still be handed that
    /// window's closure it would run the same two sweeps again, on a window
    /// whose tabs are already released. Unregistering FIRST — before
    /// `releaseUnclaimedSeedsOnClose()` and `releaseHeldTabsOnClose()`, both
    /// of which hand their teardown to a free `Task` — makes the two
    /// mutually exclusive even while that `Task` is still in flight.
    @Test func aWindowRegistersItsQuitTeardownAndGivesItUpBeforeItCloses() throws {
        let source = try Self.strictSource(of: Self.lifecycleFile)
        let setup = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func performWindowSetup()", in: source)
        #expect(
            setup.contains("TabRegistry.shared.registerWindowTeardown("),
            "the window no longer tells the registry what it does at quit")

        let closing = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func handleWindowWillClose(_ notification: Notification)", in: source)
        let unregister = Self.firstIndex(
            of: "TabRegistry.shared.unregisterWindowTeardown(", in: closing)
        let unclaimed = Self.firstIndex(of: "releaseUnclaimedSeedsOnClose()", in: closing)
        let held = Self.firstIndex(of: "releaseHeldTabsOnClose()", in: closing)
        #expect(unregister != nil, """
            the window's close path no longer unregisters its quit teardown — the quit sweep             would run this window's close sequence a second time.
            """)
        #expect(unclaimed != nil, "the close path no longer sweeps this window's parked seeds")
        #expect(held != nil, "the close path no longer releases the tabs it holds")
        if let unregister, let unclaimed, let held {
            #expect(unregister < unclaimed && unregister < held, """
                the window's close path unregisters its quit teardown AFTER starting its own                 sweeps — a quit arriving in between would be handed a closure for a window                 that is already tearing itself down.
                """)
        }
    }

    // MARK: - One owner for the stage names

    /// Every `.swift` file under `Sources/`.
    private static func swiftFiles(under directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// The two `TeardownStage` cases are named in exactly two files: the
    /// type that declares them and `TabTeardown.swift`, the one owner of the
    /// four-stage order (CLAUDE.md, "The UI owns lifecycles explicitly"; the
    /// plan's "no second copy of the four stages anywhere").
    ///
    /// **POSITIVE first**, and not decoration: a whole-tree scan that found
    /// the names nowhere would satisfy a bare "no third file" negative
    /// perfectly (CLAUDE.md, "Guards that name what they watch"). So the two
    /// files that MUST name them are asserted to, as real `runBounded` call
    /// sites and as real `case` declarations, before the negative is read.
    @Test func onlyTheOneOwnerNamesTheTeardownStages() throws {
        let owner = try Self.strictSource(of: Self.tabTeardownFile)
        #expect(
            owner.contains("TeardownStage.stopEditWatchers.runBounded"),
            "TabTeardown.swift no longer runs the edit-watcher stage")
        #expect(
            owner.contains("TeardownStage.shutDownTerminal.runBounded"),
            "TabTeardown.swift no longer runs the terminal stage")

        let declaration = try Self.strictSource(of: Self.stageFile)
        #expect(declaration.contains("case stopEditWatchers"))
        #expect(declaration.contains("case shutDownTerminal"))

        var naming: [String] = []
        for file in Self.swiftFiles(under: Self.sourcesRoot) {
            let source = try Self.strictSource(of: file)
            guard source.contains(".stopEditWatchers") || source.contains(".shutDownTerminal")
            else { continue }
            naming.append(file.lastPathComponent)
        }
        #expect(naming.sorted() == ["TabTeardown.swift", "TeardownStage.swift"], """
            the teardown stages are named in \(naming.sorted()) — a second copy of the \
            four-stage order is exactly what the one-owner invariant forbids.
            """)
    }
}
