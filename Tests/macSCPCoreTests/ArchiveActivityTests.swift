import Testing
import Foundation
@testable import macSCPCore

/// `@MainActor` because `ArchiveActivity` is, like `RemoteBrowserViewModel`:
/// the pane reads it from SwiftUI. Nothing in here blocks the main actor --
/// every wait is an `await` on a continuation.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ArchiveActivityTests {
    /// A runner that parks until the test releases it, so the running state
    /// can be read WHILE it is running. Parked on `AsyncSignal`, awaited --
    /// never a semaphore, which would block a cooperative thread, and never a
    /// bare continuation, which does not observe the cancellation this
    /// suite's own time limit raises.
    ///
    /// Parks until released OR cancelled, because a runner that ignores
    /// cancellation is not what the real ones are: both end their child when
    /// the task is cancelled.
    private final class ParkedRunner: ArchiveRunner, Sendable {
        private let started = AsyncSignal()
        private let released = AsyncSignal()
        private let result: Result<ArchiveOutcome, ArchiveFailure>

        init(result: Result<ArchiveOutcome, ArchiveFailure> = .success(.finished)) {
            self.result = result
        }

        func whenStarted() async { _ = await started.wait() }
        var hasStartedForTest: Bool { started.isRaised }
        func releaseNow() { released.signal() }

        func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome {
            started.signal()
            _ = await released.wait()
            if Task.isCancelled { return .cancelled }
            return try result.get()
        }

        func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] { [] }
    }

    private static func zipPlan() throws -> ArchivePlan {
        try ArchivePlan.compress(
            .zip, selection: [RemoteFileItem(name: "a", path: "/d/a", kind: .file)],
            workingDirectory: "/d", archiveName: "out.zip")
    }

    @Test func aPaneRunsOneOperationAndReportsItWhileItRuns() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        let plan = try Self.zipPlan()

        activity.start(plan, runner: runner)
        await runner.whenStarted()
        // Read BEFORE the healing: once the runner is released the state
        // reaches `.idle` and this assertion would pass over a model that
        // never reported running at all.
        #expect(activity.state == .running(title: "out.zip"))
        #expect(activity.operation == .compress(.zip))

        runner.releaseNow()
        await activity.waitUntilIdle()
        #expect(activity.state == .idle)
        #expect(activity.operation == nil)
        #expect(activity.lastOutcome == .finished)
    }

    @Test func aSecondOperationIsRefusedWhileOneRuns() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        let plan = try Self.zipPlan()
        #expect(activity.start(plan, runner: runner))
        await runner.whenStarted()
        #expect(activity.start(plan, runner: runner) == false)
        // Still the first one's title, read before anything heals.
        #expect(activity.state == .running(title: "out.zip"))
        runner.releaseNow()
        await activity.waitUntilIdle()
    }

    @Test func cancellingEndsItAsCancelledAndNotAsAFailure() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        activity.start(try Self.zipPlan(), runner: runner)
        await runner.whenStarted()
        activity.cancel()
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome == .cancelled)
    }

    /// Waiting on an idle model returns at once: the helper is an `await`
    /// over a continuation the finishing task raises, so it must also cope
    /// with there being nothing to finish.
    @Test func waitingOnAnIdleModelReturnsWithoutAnOperation() async {
        let activity = ArchiveActivity()
        await activity.waitUntilIdle()
        #expect(activity.state == .idle)
        #expect(activity.lastOutcome == nil)
    }

    @Test func aRunnerFailureIsKeptAsTheFailureItWas() async throws {
        for failure in [
            ArchiveFailure.toolMissing(tool: "zip"), .exited(status: 3), .timedOut,
        ] {
            let activity = ArchiveActivity()
            let runner = ParkedRunner(result: .failure(failure))
            activity.start(try Self.zipPlan(), runner: runner)
            await runner.whenStarted()
            runner.releaseNow()
            await activity.waitUntilIdle()
            #expect(activity.lastOutcome == .failed(failure))
        }
    }

    /// A runner that throws something that is not an `ArchiveFailure` -- a
    /// dropped connection, say -- becomes a sentence of its own. Its text is
    /// not kept: the error's description is a far side's.
    private struct Unrelated: Error, CustomStringConvertible {
        let description = "secret-looking text from a far side"
    }

    private actor ThrowingRunner: ArchiveRunner {
        func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome { throw Unrelated() }
        func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] { [] }
    }

    @Test func anUnrelatedErrorBecomesCouldNotRunAndKeepsNoText() async throws {
        let activity = ArchiveActivity()
        activity.start(try Self.zipPlan(), runner: ThrowingRunner())
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome == .couldNotRun)
    }

    @Test func thePreparationRunsBeforeTheRunnerAndItsFailureStopsTheRun() async throws {
        let activity = ArchiveActivity()
        let runner = ParkedRunner()
        activity.start(try Self.zipPlan(), runner: runner, prepare: { throw Unrelated() })
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome == .couldNotRun)
        // The runner was never asked: parking would have hung the wait above.
        #expect(runner.hasStartedForTest == false)
    }

    @Test func aNewRunClearsTheLastOutcomeAndADismissClearsItToo() async throws {
        let activity = ArchiveActivity()
        activity.start(try Self.zipPlan(), runner: ThrowingRunner())
        await activity.waitUntilIdle()
        #expect(activity.lastOutcome == .couldNotRun)

        let runner = ParkedRunner()
        activity.start(try Self.zipPlan(), runner: runner)
        await runner.whenStarted()
        #expect(activity.lastOutcome == nil)
        runner.releaseNow()
        await activity.waitUntilIdle()

        activity.start(try Self.zipPlan(), runner: ThrowingRunner())
        await activity.waitUntilIdle()
        activity.dismissOutcome()
        #expect(activity.lastOutcome == nil)
    }

    // MARK: - The title

    @Test func theTitleIsTheNameTheOperationIsAbout() throws {
        let zip = try Self.zipPlan()
        #expect(zip.title == "out.zip")

        // A compressed file is created as `<name>.gz` although the plan's
        // only operand is the source.
        let gz = try ArchivePlan.compress(
            .gz, selection: [RemoteFileItem(name: "big.log", path: "/d/big.log", kind: .file)],
            workingDirectory: "/d", archiveName: "big.log.gz")
        #expect(gz.title == "big.log.gz")

        let extract = try ArchivePlan.extract(
            RemoteFileItem(name: "-v.zip", path: "/d/-v.zip", kind: .file),
            format: .zip, workingDirectory: "/d", into: .subfolder("sub"))
        #expect(extract.title == "-v.zip")
    }
}
