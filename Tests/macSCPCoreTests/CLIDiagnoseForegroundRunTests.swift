import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// What `macscp-cli diagnose --scope throughput` does with Ctrl-C
/// (`DiagnoseForegroundRun`), through the seam `tunnels start` is tested
/// through: a `stops` stream the case yields into, in place of the signals
/// `TunnelStartCommand.interrupts()` turns into elements.
///
/// The fake diagnoses park on an `AsyncSignal` — until they are cancelled,
/// or until the case releases them — and never on a clock. The time limit
/// is a hang bound.
@Suite("CLI diagnose foreground run", .timeLimit(.minutes(1)))
struct CLIDiagnoseForegroundRunTests {
    /// The first signal cancels the diagnosis and WAITS for it: the walk's
    /// cleanup — the throughput test's removal — runs, and its report is
    /// what the command prints and exits by.
    @Test func theFirstSignalCancelsTheRunAndWaitsForItsReport() async throws {
        let started = AsyncSignal()
        let cleanedUp = Mutex(false)
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = Task {
            await DiagnoseForegroundRun.drive(stops: stops) {
                started.signal()
                let outcome = await AsyncSignal().wait()
                cleanedUp.withLock { $0 = outcome == .cancelled }
                return Self.report(.cancelled(afterSteps: 1))
            }
        }
        #expect(await started.wait() == .signalled)
        signal.yield()
        let ending = await finishing(run)

        guard case .finished(let report) = ending else {
            Issue.record("the run did not wait for its report: \(ending)")
            return
        }
        #expect(report.completion == .cancelled(afterSteps: 1))
        #expect(cleanedUp.withLock { $0 }, "the diagnosis was not cancelled")
    }

    /// A second signal while the first one's cleanup is still running
    /// leaves at once — a removal stuck on a server that stopped answering
    /// cannot trap a person in their terminal. The diagnosis here ignores
    /// its cancellation and is released only after the run has returned.
    @Test func aSecondSignalLeavesWithoutWaiting() async throws {
        let started = AsyncSignal()
        let release = AsyncSignal()
        let (stops, signal) = AsyncStream.makeStream(of: Void.self)

        let run = Task {
            await DiagnoseForegroundRun.drive(stops: stops) {
                started.signal()
                // Awaited through a task of its own, which the run's
                // cancellation does not reach: a cleanup that does not
                // answer, until the case releases it.
                await Task { _ = await release.wait() }.value
                return Self.report(.complete)
            }
        }
        #expect(await started.wait() == .signalled)
        signal.yield()
        signal.yield()
        // Released on the case's own cancellation too, so a run that does
        // not leave — the red this case exists for — cannot outlive the
        // suite's time limit.
        let ending = await withTaskCancellationHandler {
            await finishing(run)
        } onCancel: {
            release.signal()
        }
        release.signal()

        guard case .abandoned = ending else {
            Issue.record("a second signal did not leave: \(ending)")
            return
        }
    }

    /// No signal: the run is the diagnosis, untouched.
    @Test func withoutASignalTheRunIsTheDiagnosis() async {
        let (stops, _) = AsyncStream.makeStream(of: Void.self)
        let ending = await DiagnoseForegroundRun.drive(stops: stops) { Self.report(.complete) }
        guard case .finished(let report) = ending else {
            Issue.record("\(ending)")
            return
        }
        #expect(report.completion == .complete)
    }

    // MARK: - What is said, and the exit

    /// A report whose throughput row says the file may remain earns a note
    /// on standard error naming it; so does a run abandoned before it could
    /// say anything. A run that removed its file earns none.
    @Test func aFileThatMayRemainIsNamedAndACleanRunIsNot() {
        let name = ThroughputProbe.fileName(for: UUID())
        let leftBehind = Self.report(
            .cancelled(afterSteps: 2),
            steps: [Self.step(.failed(DiagnosticReason.throughputFileLeftBehind))])
        let clean = Self.report(.cancelled(afterSteps: 1), steps: [Self.step(.ok)])

        let named = DiagnoseForegroundRun.leftoverNote(for: .finished(leftBehind), fileName: name)
        let abandoned = DiagnoseForegroundRun.leftoverNote(for: .abandoned, fileName: name)
        #expect(named?.contains(name) == true, "\(named ?? "nil")")
        #expect(abandoned?.contains(name) == true, "\(abandoned ?? "nil")")
        #expect(DiagnoseForegroundRun.leftoverNote(for: .finished(clean), fileName: name) == nil)
    }

    /// An interrupted run exits by what its report earns, as every run
    /// does; one abandoned with its file possibly on the server exits 16.
    @Test func theExitIsTheReportsAndAnAbandonedRunIsADiagnosis() {
        let clean = Self.report(.cancelled(afterSteps: 1), steps: [Self.step(.ok)])
        let leftBehind = Self.report(
            .cancelled(afterSteps: 1),
            steps: [Self.step(.failed(DiagnosticReason.throughputFileLeftBehind))])
        #expect(DiagnoseForegroundRun.exitCode(for: .finished(clean)) == .success)
        #expect(DiagnoseForegroundRun.exitCode(for: .finished(leftBehind)) == .diagnosis)
        #expect(DiagnoseForegroundRun.exitCode(for: .abandoned) == .diagnosis)
    }

    // MARK: - Support

    static func step(_ outcome: DiagnosticOutcome) -> DiagnosticStep {
        DiagnosticStepTimer(
            id: DiagnosticStepID.throughput,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.throughput)
        ).finish(outcome, "")
    }

    static func report(
        _ completion: DiagnosticReport.Completion, steps: [DiagnosticStep] = []
    ) -> DiagnosticReport {
        DiagnosticReport(
            endpoint: Endpoint(host: "127.0.0.1", port: 22), steps: steps, appVersion: "test",
            completion: completion, scope: .throughput)
    }
}
