import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// `@MainActor` because `FileActionActivity` is, like `ArchiveActivity`: the
/// pane reads it from SwiftUI. Nothing in here blocks the main actor -- every
/// wait is an `await` on a signal. No real process is spawned: the runner is
/// injected, and the one real runner's pure half is tested through its
/// `resolve` seam.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct FileActionActivityTests {
    private static let first = FileActionInvocation(executable: "wc", arguments: ["-l", "/d/a"])
    private static let second = FileActionInvocation(executable: "wc", arguments: ["-l", "/d/b"])
    private static let plan = FileActionPlan.invocations([first, second])

    /// Records every invocation it is asked to run and answers with the next
    /// scripted status. Optionally parks the first one until released, on
    /// `AsyncSignal` -- awaited, never a semaphore.
    private final class RecordingRunner: FileActionRunner, Sendable {
        private struct State {
            var seen: [FileActionInvocation] = []
            var statuses: [Int32]
        }
        private let state: Mutex<State>
        private let startedFirst = AsyncSignal()
        private let released = AsyncSignal()
        private let parksFirst: Bool
        private let throwing: Bool

        init(statuses: [Int32] = [], parksFirst: Bool = false, throwing: Bool = false) {
            state = Mutex(State(statuses: statuses))
            self.parksFirst = parksFirst
            self.throwing = throwing
        }

        var seen: [FileActionInvocation] { state.withLock { $0.seen } }
        func whenFirstStarted() async { _ = await startedFirst.wait() }
        func release() { released.signal() }

        struct Boom: Error {}

        func run(_ invocation: FileActionInvocation) async throws -> Int32 {
            let isFirst = state.withLock { state -> Bool in
                state.seen.append(invocation)
                return state.seen.count == 1
            }
            if isFirst, parksFirst {
                startedFirst.signal()
                // Not cancellation-aware on purpose: the activity must not
                // start the NEXT invocation after a cancel whether or not a
                // runner noticed the cancel itself.
                _ = await released.wait()
            }
            if throwing { throw Boom() }
            return state.withLock { $0.statuses.isEmpty ? 0 : $0.statuses.removeFirst() }
        }
    }

    // MARK: - Shape

    @Test func anIdleActivityIsNotRunningAndHasNoOutcome() {
        let activity = FileActionActivity()
        #expect(activity.isRunning == false)
        #expect(activity.state == .idle)
        #expect(activity.lastOutcome == nil)
    }

    @Test func waitingOnAnIdleActivityReturnsWithoutARun() async {
        let activity = FileActionActivity()
        await activity.waitUntilIdle()
        #expect(activity.state == .idle)
    }

    // MARK: - Order

    @Test func everyInvocationRunsInOrderAndTheRunEndsFinished() async {
        let activity = FileActionActivity()
        let runner = RecordingRunner(parksFirst: true)
        #expect(activity.run(Self.plan, title: "Count", using: runner))
        await runner.whenFirstStarted()
        // Read BEFORE the runner is released: afterwards the state is idle and
        // this would pass over an activity that never reported running.
        #expect(activity.state == .running(title: "Count"))
        #expect(activity.isRunning)

        runner.release()
        await activity.waitUntilIdle()
        #expect(runner.seen == [Self.first, Self.second])
        #expect(activity.lastOutcome == FileActionActivity.Outcome(title: "Count", ending: .finished))
        #expect(activity.isRunning == false)
    }

    @Test func aSecondRunIsRefusedWhileOneRunsAndKeepsTheFirstsTitle() async {
        let activity = FileActionActivity()
        let runner = RecordingRunner(parksFirst: true)
        #expect(activity.run(Self.plan, title: "One", using: runner))
        await runner.whenFirstStarted()
        let other = RecordingRunner()
        #expect(activity.run(Self.plan, title: "Two", using: other) == false)
        #expect(activity.state == .running(title: "One"))
        #expect(other.seen.isEmpty)
        runner.release()
        await activity.waitUntilIdle()
    }

    // MARK: - Cancel

    /// The runner here ignores the cancel, so what stops the second
    /// invocation is the activity's own check between the two.
    @Test(.timeLimit(.minutes(5)))
    func cancellingDuringARunStartsNoFurtherInvocation() async {
        let activity = FileActionActivity()
        let runner = RecordingRunner(parksFirst: true)
        activity.run(Self.plan, title: "Count", using: runner)
        await runner.whenFirstStarted()
        activity.cancel()
        runner.release()
        await activity.waitUntilIdle()
        #expect(runner.seen == [Self.first])
        #expect(activity.lastOutcome?.ending == .cancelled)
        #expect(activity.isRunning == false)
    }

    @Test func aRunnerThatThrowsCancellationErrorEndsAsCancelledNotAsAFailure() async {
        struct Cancelling: FileActionRunner {
            func run(_ invocation: FileActionInvocation) async throws -> Int32 {
                throw CancellationError()
            }
        }
        let activity = FileActionActivity()
        activity.run(Self.plan, title: "t", using: Cancelling())
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome?.ending == .cancelled)
    }

    // MARK: - Failure

    @Test func aRunnerThatThrowsEndsTheActivityAsCouldNotRunAndStopsTheRest() async {
        let activity = FileActionActivity()
        let runner = RecordingRunner(throwing: true)
        activity.run(Self.plan, title: "Count", using: runner)
        await activity.waitUntilIdle()
        #expect(activity.isRunning == false)
        #expect(activity.lastOutcome?.ending == .couldNotRun)
        #expect(runner.seen == [Self.first])
    }

    @Test func aNonZeroStatusEndsTheRunWithThatStatusAndStopsTheRest() async {
        let activity = FileActionActivity()
        let runner = RecordingRunner(statuses: [3, 0])
        activity.run(Self.plan, title: "Count", using: runner)
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome?.ending == .failed(status: 3))
        #expect(runner.seen == [Self.first])
    }

    @Test func aTimeoutIsItsOwnEnding() async {
        struct Slow: FileActionRunner {
            func run(_ invocation: FileActionInvocation) async throws -> Int32 {
                throw FileActionTimedOut()
            }
        }
        let activity = FileActionActivity()
        activity.run(Self.plan, title: "t", using: Slow())
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome?.ending == .timedOut)
    }

    @Test func aNewRunForgetsTheLastOutcomeAndDismissClearsIt() async {
        let activity = FileActionActivity()
        activity.run(Self.plan, title: "A", using: RecordingRunner(statuses: [1]))
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome != nil)
        let runner = RecordingRunner(parksFirst: true)
        activity.run(Self.plan, title: "B", using: runner)
        await runner.whenFirstStarted()
        #expect(activity.lastOutcome == nil)
        runner.release()
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome != nil)
        activity.dismissOutcome()
        #expect(activity.lastOutcome == nil)
    }

    // MARK: - Core executes nothing for the remote path

    /// Shell lines are TYPED into the user's shell by the pane. The activity
    /// must have no way to run them: it refuses the plan and never reaches
    /// the runner.
    @Test func aShellLinesPlanIsNeverHandedToTheRunner() async {
        let activity = FileActionActivity()
        let runner = RecordingRunner()
        let started = activity.run(.shellLines(["wc -l '/d/a'"]), title: "t", using: runner)
        await activity.waitUntilIdle()
        #expect(started == false)
        #expect(runner.seen.isEmpty)
        #expect(activity.isRunning == false)
        #expect(activity.lastOutcome?.ending == .notRunnableHere)
    }

    // MARK: - The remote path keeps what the sheet showed

    /// The send path does not drop or normalise a byte of a line. A NUL can
    /// no longer arrive from a SELECTION on the remote path (the planner
    /// refuses a control character there), but it can still arrive from the
    /// user's own prompted value, and what is sent must be exactly what the
    /// confirmation sheet showed.
    @Test func aNulInAPromptedValueReachesTheBytesTheShellIsSent() throws {
        let note = SnippetVariable(
            name: "NOTE", prompt: "", kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
        let action = FileAction(
            name: "n", command: "echo {{NOTE}}", variables: [note], runsOn: [.remote])
        let plan = try FileActionPlanner.plan(
            action: action,
            selection: [RemoteFileItem(name: "x", path: "/d/x", kind: .file)],
            side: .remote, promptedValues: ["NOTE": "a\u{0}b"]).get()
        guard case .shellLines(let lines) = plan else {
            Issue.record("expected shell lines")
            return
        }
        #expect(lines.count == 1)
        let expected = Array(("echo 'a\u{0}b'").utf8) + [0x0D]
        for bracketed in [false, true] {
            let sent = SnippetSendPlanner.plan(
                command: lines[0], execute: true, bracketedPaste: bracketed)
            #expect(sent == .send(expected))
        }
        // The positive beside it: the NUL is in what was sent at all.
        #expect(expected.contains(0))
    }

    // MARK: - The local runner's executable lookup (its pure half)

    @Test func aPathWithASlashIsUsedAsGiven() {
        #expect(LocalFileActionRunner.resolve("/usr/bin/wc", isExecutable: { $0 == "/usr/bin/wc" })
            == "/usr/bin/wc")
        #expect(LocalFileActionRunner.resolve("/nowhere/wc", isExecutable: { _ in false }) == nil)
    }

    @Test func aBareNameIsLookedForInTheFixedDirectoriesInOrder() {
        let asked = Mutex<[String]>([])
        let found = LocalFileActionRunner.resolve("wc", isExecutable: { path in
            asked.withLock { $0.append(path) }
            return path == "/bin/wc"
        })
        #expect(found == "/bin/wc")
        #expect(asked.withLock { $0 } == ["/usr/bin/wc", "/bin/wc"])
        #expect(LocalFileActionRunner.resolve("nope", isExecutable: { _ in false }) == nil)
    }
}
