import Foundation

/// What ⌘Q does about the windows that are still open (Quit Teardown plan,
/// Task 1).
///
/// Before this plan the answer was "nothing": `applicationWillTerminate` is
/// synchronous, `ContentView.teardown(_:reason:)` is main-actor `async`, and
/// a synchronous callback cannot await one — so no held tab's four stages
/// ran, and the audit log never saw a `disconnected` row for a session the
/// user quit out of (`docs/BACKLOG.md`, "Quit tears down nothing").
/// `applicationShouldTerminate(_:)` is the callback that CAN wait: it
/// returns `.terminateLater` and the app calls
/// `NSApp.reply(toApplicationShouldTerminate:)` when it is finished.
///
/// This type holds the parts of that sequence that are decisions and text
/// rather than AppKit calls, so they can be driven from a test — the
/// delegate's own body cannot be, since running it would terminate the test
/// process.
enum QuitSequence {
    /// Defer the quit iff anything is still connected.
    ///
    /// `liveTabCount` is counted over every tab the registry knows —
    /// including a tab parked for a move into a window that never appeared,
    /// which belongs to no window and is therefore reachable from nowhere
    /// else. A tab counts as live when it holds a `session`; a tab sitting
    /// on a connection form has nothing to tear down.
    ///
    /// Zero means `.now` rather than "defer and finish instantly": a
    /// deferral is a round trip through AppKit and a reply, and an app with
    /// nothing connected should quit the moment it is asked to.
    ///
    /// A RUNNING TUNNEL defers the quit too (port-forwarding plan, Task 6),
    /// and it has to be counted separately because it is reachable from
    /// nowhere else: a forwarding belongs to no tab and to no window, so an
    /// app with three tunnels up and not one connected tab has
    /// `liveTabCount == 0`. Without this argument that app would quit
    /// through the `.now` branch, which runs no `stopAll()` — every
    /// forwarding would be dropped by process exit rather than stopped, with
    /// no `tunnel <name> stop` line and no `cancel-tcpip-forward` sent to
    /// the server that is still listening for one.
    static func decision(liveTabCount: Int, runningTunnelCount: Int) -> QuitDecision {
        liveTabCount == 0 && runningTunnelCount == 0 ? .now : .later
    }

    /// The deferred path's steps, in the order the delegate runs them —
    /// `QuitSequenceTests` pins the delegate's own body against this array
    /// positionally.
    ///
    /// The order is not arbitrary at either end:
    ///
    /// - `writeRestoration` is FIRST because a teardown clears
    ///   `tab.activeStoredSessionID`, which is exactly what
    ///   `ContentView.describeForRestoration(_:)` writes into the seed. Ask
    ///   the windows to describe themselves after the teardown and they
    ///   describe themselves empty — every restored tab comes back blank.
    /// - `teardownParked` is before `teardownWindows` because a parked tab
    ///   is in NO window (see `TabRegistry.park`), so no window's closure
    ///   can reach it; the sweep is its only route.
    /// - `logQuit`, `flush` and `reply` are last, in that order, because the
    ///   line has to describe a finished sequence, the flush has to include
    ///   that line, and the reply is what lets the process go.
    /// - `stopTunnels` is before `teardownWindows` because a forwarding is
    ///   in no window either (`TunnelManager` is process-wide, and holds the
    ///   runners), so no window's closure can reach one; and it is before
    ///   rather than after so that the `tunnel … stop` lines are written
    ///   while the log is still being flushed by this same sequence.
    static let steps: [QuitStep] = [
        .writeRestoration, .teardownParked, .stopTunnels, .teardownWindows,
        .logQuit, .flush, .reply,
    ]

    /// The deferred path's own `app quit` line: counts and one verdict, and
    /// nothing else.
    ///
    /// No window id, no tab id, no host and no path — a quit line is read to
    /// answer "did the teardown finish, and for how many windows", and every
    /// identifier that could answer a different question is an identifier
    /// that could carry something a user typed. `forced` is `true` when
    /// `QuitWatchdog.bound` won the race, which is the one fact this line
    /// exists to preserve: a quit that stopped starting teardowns rather
    /// than finishing them.
    ///
    /// Built here rather than interpolated at the call site so a test can
    /// read the text without a `DiagnosticLog` (and so there is one spelling
    /// of it, not two).
    static func quitLine(windows: Int, tornDown: Int, forced: Bool) -> String {
        "quit windows=\(windows) tornDown=\(tornDown) forced=\(forced)"
    }

    /// The tunnel step's own line, or `nil` when there is nothing to say.
    ///
    /// **Only the forced outcome is written**, and that is the whole
    /// decision: a step that finished inside its bound is the ordinary case
    /// and needs no line, while a step the bound cut short leaves a
    /// forwarding still stopping as the process exits — a server may go on
    /// holding a remote forward nobody cancelled, and that is a fact a log
    /// read afterwards has to be able to explain. It is a separate line
    /// rather than a field on `quitLine` because it is decided before the
    /// window teardown even starts, and `forced=` there already means
    /// something else (the WINDOW chain's watchdog).
    ///
    /// Carries the outcome and nothing else: no count, no name, no host.
    static func tunnelStopLine(_ outcome: BoundedStepOutcome) -> String? {
        outcome == .timedOut ? "quit tunnels forced=true" : nil
    }
}

/// Quit now, or quit once the teardown is done.
enum QuitDecision: Equatable, Sendable {
    /// `NSApplication.TerminateReply.terminateNow` — nothing is connected.
    case now
    /// `NSApplication.TerminateReply.terminateLater`, followed by a reply
    /// once the sequence below has run.
    case later
}

/// One step of the deferred quit. A named step rather than a comment, so
/// the order is a value a test can compare against and the delegate's body
/// can be pinned to it.
enum QuitStep: Equatable, Sendable, CaseIterable {
    /// `windows.json`, written from every still-open window's describer.
    case writeRestoration
    /// The unclaimed parked seeds, torn down through `TabTeardown.run`.
    case teardownParked
    /// Every running forwarding, stopped through `TunnelManager.stopAll()`.
    ///
    /// **Raced against `QuitWatchdog.bound`, in its own group**
    /// (`AppDelegate.runBoundedTunnelStop()`), and the runners are stopped
    /// concurrently inside it. Round 1 awaited them one at a time with no
    /// bound at all, which was wrong twice over: a runner parked in a dial
    /// is bounded by `connectTimeoutSeconds` (10 s by default, up to 120 s),
    /// so the sequential wait was n × that number in front of a quit whose
    /// watchdog is 15 s. The five-second `RemoteForward.stop()` close this
    /// comment used to name is only the teardown AFTER a dial has finished —
    /// never the ceiling on the step.
    case stopTunnels
    /// Every open window's registered closure, in registration order.
    case teardownWindows
    /// The diagnostic log's `app quit …` line — see
    /// `QuitSequence.quitLine(windows:tornDown:forced:)`.
    case logQuit
    /// `DiagnosticLog.shared.flushSynchronously()`.
    case flush
    /// `NSApp.reply(toApplicationShouldTerminate: true)`.
    case reply
}

/// The ceiling on the deferred quit.
enum QuitWatchdog {
    /// Fifteen seconds, argued from the bounds the teardown itself already
    /// carries rather than picked as a round number.
    ///
    /// **Upward, from one tab's worst case.** `TabTeardown.run` gives two of
    /// its four stages a five-second bound each (`TeardownStage.boundSeconds`)
    /// and `remote.disconnect()` carries its own inside
    /// `CitadelFileSystem.disconnect()` — measured against a `docker pause`d
    /// peer at 5.002063 s / 5.304208 s / 5.333977 s across three runs, which
    /// is that inner bound plus the parent closes. So one frozen tab costs
    /// roughly three bounds, and only one of the two stage bounds was ever
    /// measured to fire (`terminal.shutdown()`; see `TeardownStage`). Fifteen
    /// seconds is that worst case with the second stage bound spent too — one
    /// whole tab, not a fraction of one.
    ///
    /// **Downward, from the user.** A window with several frozen tabs would
    /// otherwise multiply that: four tabs, three bounds each, is a minute of
    /// an app that will not close. The cap is what says the quit is the
    /// user's to take back.
    ///
    /// **What it actually bounds, said plainly: this is the point after
    /// which no further TAB is started, not a hard ceiling on the quit.**
    /// Nothing here can stop a suspension inside Citadel or NIO from taking
    /// as long as it takes. When the bound wins, the teardown chain is
    /// CANCELLED, and cancellation is read between items and never inside
    /// one — at both levels: `QuitTeardownChain.run` checks between parked
    /// tabs and between windows, and each window's own two loops
    /// (`ContentView.tearDownHeldTabs(_:from:)`,
    /// `tearDownUnclaimedSeeds(_:)`) check between the tabs they hold. So
    /// when this bound elapses, at most ONE tab's teardown is still running,
    /// and it runs to its own end: two `TeardownStage` bounds plus
    /// `disconnect()`'s, on top of a `cancelAll` that carries no bound at
    /// all (see `TabTeardown.run`, which measured it under six milliseconds
    /// against a frozen peer three runs out of three — measured, not
    /// guaranteed). A quit can therefore outlast this number by roughly one
    /// tab's worth, and that is the honest statement of what it buys.
    ///
    /// Fix round 1 is what made "one tab" true: before it, the per-tab loops
    /// checked nothing, so a cancelled window still ran every tab it held
    /// and the overrun scaled with the tab count.
    ///
    /// `forced=true` in the quit line is what tells a reader the bound won.
    /// `QuitWatchdog` is production code and a wall clock here is
    /// deliberate; CLAUDE.md's rule against wall-clock ceilings is about
    /// TESTS, and no test asserts how long a quit took.
    static let bound: Duration = .seconds(15)
}

/// Which of the deferred quit's two racing children finished first.
///
/// A single result type because a `TaskGroup` has one `ChildTaskResult`:
/// the teardown chain reports how many window closures it got through
/// (which is what `forced=` and `tornDown=` are read from), and the sleeper
/// reports only that it woke up.
enum QuitRaceOutcome: Equatable, Sendable {
    /// The teardown chain returned — with the number of WINDOW closures
    /// that ran to completion. It is fewer than the windows handed out iff
    /// the chain was cancelled part-way.
    case chainFinished(tornDown: Int)
    /// `QuitWatchdog.bound` elapsed first.
    case watchdogFired
}

/// Which way a bounded step ended.
enum BoundedStepOutcome: Equatable, Sendable {
    /// The work finished inside the bound.
    case finished
    /// The bound elapsed first. The work was NOT cancelled — see
    /// `BoundedStep.run`.
    case timedOut
}

/// Runs a piece of work with a ceiling on how long the CALLER waits for it.
///
/// **Why this is not a `TaskGroup` around the work itself**, which is what
/// round 1 wrote and what fix round 2 replaced. The work here is
/// `TunnelManager.stopAll()`, whose every `stop()` ends in
/// `TunnelRunner.command(_:)` at `await mine.value` on a
/// `Task<Void, Never>` — and that ignores the awaiting task's cancellation
/// (the runner's own `performStop()` doc comment says so, and says why:
/// abandoning the run task would let it publish a state after `.stopped`).
/// So a child task holding that await cannot be cancelled, `group.cancelAll()`
/// was a no-op, and the group waited for the work regardless of the bound.
/// The step was bounded in the comment and unbounded in the code.
///
/// What bounds it instead is a task the caller can ABANDON: the work runs
/// unstructured, its completion is signalled through an `AsyncStream`
/// (whose iteration does answer cancellation), and the race is between that
/// signal and the sleeper. When the sleeper wins, the work task is left
/// running — deliberately: it is mid-teardown, cancelling it would neither
/// stop it nor help, and the process is about to exit anyway. The caller
/// stops waiting; that is the whole of what "bounded" means here.
///
/// `sleeper` is injected so a test measures what this ASKED for rather than
/// waiting for it (CLAUDE.md, "A wall-clock ceiling in a test measures the
/// runner").
@MainActor
enum BoundedStep {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    static func run(
        bound: Duration,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        _ body: @escaping @MainActor @Sendable () async -> Void
    ) async -> BoundedStepOutcome {
        let (done, signal) = AsyncStream<Void>.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Unstructured on purpose: nothing awaits this handle, so the race
        // below can walk away from it.
        Task { @MainActor in
            await body()
            signal.yield(())
            signal.finish()
        }
        return await withTaskGroup(of: BoundedStepOutcome.self) { group in
            group.addTask {
                for await _ in done { break }
                return .finished
            }
            group.addTask {
                try? await sleeper(bound)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            // Both children answer cancellation — an `AsyncStream`
            // iteration and a sleeper whose contract says so — so this
            // really does end the loser, unlike the version that tried to
            // cancel the work.
            group.cancelAll()
            return first
        }
    }
}

/// What the deferred quit still has to tear down, in one main-actor box.
///
/// It exists for a type-system reason, not a design one: `TaskGroup
/// .addTask`'s closure must be `Sendable`, and a `[SessionTab]` is not (the
/// type is `@MainActor`), nor is a list of `@MainActor` closures. A
/// `@MainActor final class` is implicitly `Sendable`, so the box crosses the
/// boundary and its contents never do — the chain that reads it is
/// `@MainActor` as well, and runs on the same actor the values already
/// belong to.
@MainActor
final class QuitWorkList {
    /// Tabs parked for a window that never appeared, already taken out of
    /// the registry by `AppDelegate.sweepUnclaimedMoves()`.
    let parked: [SessionTab]
    /// Every open window's teardown, in the order the windows appeared.
    let windows: [(WindowID, TabRegistry.WindowTeardown)]

    init(parked: [SessionTab], windows: [(WindowID, TabRegistry.WindowTeardown)]) {
        self.parked = parked
        self.windows = windows
    }
}

/// The chain the quit's task group races against `QuitWatchdog.bound`:
/// every parked tab, then every window's own close sequence, in order,
/// through the one teardown owner.
///
/// It lives here rather than on `AppDelegate` because it makes no AppKit
/// call at all — which is what lets a test drive it with recording closures
/// in place of real windows, and turn "a cancelled chain starts no further
/// item" into a measured property instead of a read of the source (fix
/// round 1).
@MainActor
enum QuitTeardownChain {
    /// **Cancellation is checked BETWEEN items and never inside one.**
    /// `TabTeardown.run` does not check it at all, on purpose — a teardown
    /// abandoned half way leaves a shell open on a connection whose queue is
    /// already swept, which is worse than either end state. The same rule
    /// applies one level down, inside a window's closure: its two loops
    /// (`ContentView.tearDownHeldTabs(_:from:)` and
    /// `tearDownUnclaimedSeeds(_:)`) check between TABS, so a cancelled
    /// window stops after the tab it is inside rather than after all of
    /// them.
    ///
    /// The returned count is window closures completed, so a chain the
    /// watchdog cut short reports fewer than it was handed — which is
    /// exactly what `tornDown=` beside `windows=` is read for.
    static func run(_ work: QuitWorkList) async -> QuitRaceOutcome {
        var tornDown = 0
        for tab in work.parked {
            if Task.isCancelled { return .chainFinished(tornDown: tornDown) }
            await TabTeardown.run(tab, reason: .userRequested)
        }
        for (_, runWindowTeardown) in work.windows {
            if Task.isCancelled { return .chainFinished(tornDown: tornDown) }
            await runWindowTeardown()
            tornDown += 1
        }
        return .chainFinished(tornDown: tornDown)
    }
}
