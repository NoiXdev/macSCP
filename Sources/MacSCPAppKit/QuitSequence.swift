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
    static func decision(liveTabCount: Int) -> QuitDecision {
        liveTabCount == 0 ? .now : .later
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
    static let steps: [QuitStep] = [
        .writeRestoration, .teardownParked, .teardownWindows, .logQuit, .flush, .reply,
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
    /// **What it actually bounds.** Not a kill: nothing here can stop a
    /// suspension inside Citadel or NIO from taking as long as it takes.
    /// When this bound wins, the teardown chain is CANCELLED, and a
    /// cancelled chain finishes the window it is inside — under that
    /// window's own per-stage bounds — and starts no further one. So the
    /// real ceiling is this bound plus at most one window's bounded
    /// teardown, and the log line says `forced=true` so a reader knows the
    /// difference. `QuitWatchdog` is production code and a wall clock here
    /// is deliberate; CLAUDE.md's rule against wall-clock ceilings is about
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
