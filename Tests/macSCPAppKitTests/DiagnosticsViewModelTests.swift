import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The panel's view model, over a FAKE runner: what `run()`, `cancel()` and
/// the two copy entries do, and what the panel renders each row as.
///
/// Nothing here opens a socket. The real runner is an actor in Core with its
/// own suite (`ConnectionDiagnosticsTests`); what this one is about is the
/// half that sits between it and the window — that a run starts only when
/// asked, that a cancelled run keeps the steps it did measure, and that both
/// copy shapes reach the pasteboard the app writes to.
@MainActor
@Suite("Diagnostics view model")
struct DiagnosticsViewModelTests {
    // MARK: - Fixtures

    nonisolated private static func step(
        id: String, outcome: DiagnosticOutcome = .ok, detail: String = ""
    ) -> DiagnosticStep {
        DiagnosticStep(
            id: id, titleKey: DiagnosticStepID.titleKey(for: id), started: Date(),
            duration: .milliseconds(12), outcome: outcome, detail: detail)
    }

    nonisolated private static func report(_ steps: [DiagnosticStep]) -> DiagnosticReport {
        DiagnosticReport(
            endpoint: Endpoint(host: "example.test", port: 22), steps: steps,
            appVersion: "0.0.0-test")
    }

    /// A recording pasteboard: the seam the view model writes through, so a
    /// test can read what a copy entry actually put there. Production passes
    /// the `NSPasteboard.general` writer the rest of the app uses.
    nonisolated private final class Clipboard: @unchecked Sendable {
        private(set) var written: [String] = []
        func write(_ text: String) { written.append(text) }
    }

    private static func model(
        runner: @escaping DiagnosticsViewModel.Runner, clipboard: Clipboard
    ) -> DiagnosticsViewModel {
        DiagnosticsViewModel(
            name: "Test session", runner: runner,
            copy: { [clipboard] text in clipboard.write(text) })
    }

    // MARK: - Running

    /// The decision of 2026-09-02, at its source: a freshly built model has
    /// measured nothing. Whatever the panel does on appear, it cannot be
    /// showing a report it never ran.
    @Test func aFreshModelHasNotRunAnything() {
        let model = Self.model(runner: { Self.report([]) }, clipboard: Clipboard())
        #expect(model.report == nil)
        #expect(model.isRunning == false)
    }

    @Test func runPublishesTheRunnersReport() async {
        let expected = Self.report([Self.step(id: DiagnosticStepID.resolve)])
        let model = Self.model(runner: { expected }, clipboard: Clipboard())
        model.run()
        await model.runTask?.value
        #expect(model.report == expected)
        #expect(model.isRunning == false)
    }

    @Test func isRunningIsSetBeforeTheRunnerAnswers() async {
        let gate = Gate()
        let model = Self.model(
            runner: { await gate.wait(); return Self.report([]) }, clipboard: Clipboard())
        model.run()
        #expect(model.isRunning, "the panel must be able to show progress while the run is in flight")
        await gate.open()
        await model.runTask?.value
        #expect(model.isRunning == false)
    }

    /// A cancelled run keeps what it measured. The runner in Core returns the
    /// steps that finished before the cancellation, and the model must publish
    /// them rather than throw the partial answer away — a half-finished
    /// diagnosis is exactly the artefact a hanging connection produces.
    @Test func cancelKeepsTheStepsTheRunHadAlreadyMeasured() async {
        let partial = Self.report([Self.step(id: DiagnosticStepID.resolve)])
        let model = Self.model(
            runner: {
                // Returns the moment the task is cancelled; the duration is a
                // park that a working cancel never waits out, not a deadline
                // anything here asserts on.
                try? await Task.sleep(for: .seconds(60))
                return partial
            },
            clipboard: Clipboard())
        model.run()
        model.cancel()
        await model.runTask?.value
        #expect(model.report == partial)
        #expect(model.isRunning == false)
    }

    /// "Run again" replaces the previous run rather than racing it.
    ///
    /// The abandoned run does not simply vanish: `ConnectionDiagnostics`
    /// answers a cancelled task with the steps it had, so the first runner
    /// RETURNS, after the second one has already published. Without an
    /// attempt token that late answer overwrites the run that replaced it, and
    /// the panel ends up showing the older, shorter report — the exact defect
    /// `ConnectionViewModel.currentAttempt` exists for on the connect path.
    ///
    /// Both tasks are awaited before the postcondition is read, so the
    /// assertion is not a race that happens to land the right way.
    @Test func runAgainSupersedesAnInFlightRun() async {
        let abandoned = Self.report([Self.step(id: DiagnosticStepID.resolve)])
        let current = Self.report([Self.step(id: DiagnosticStepID.tcp)])
        let calls = Calls()
        let model = Self.model(
            runner: {
                if await calls.next() == 1 {
                    // Returns the moment `run()`'s second call cancels it; the
                    // duration is a park a working cancel never waits out.
                    try? await Task.sleep(for: .seconds(60))
                    return abandoned
                }
                return current
            },
            clipboard: Clipboard())
        model.run()
        let first = model.runTask
        model.run()
        await first?.value
        await model.runTask?.value
        #expect(model.report == current, """
            the superseded run's late answer must not land — got \
            \(String(describing: model.report?.steps.map(\.id)))
            """)
        #expect(model.isRunning == false)
    }

    // MARK: - Copying

    @Test func bothCopyEntriesReachThePasteboard() async {
        let expected = Self.report([Self.step(id: DiagnosticStepID.resolve, detail: "A 127.0.0.1")])
        let clipboard = Clipboard()
        let model = Self.model(runner: { expected }, clipboard: clipboard)
        model.run()
        await model.runTask?.value

        model.copyPlainText()
        model.copyMarkdown()
        #expect(clipboard.written == [expected.plainText(), expected.markdown()], """
            the two entries copy the report's own two renderings, unchanged — the report is \
            a bug-report artefact and stays English (DiagnosticReport's own doc comment)
            """)
    }

    /// The two renderings are not the same text, so a test that only counted
    /// two writes could not tell the entries apart.
    @Test func theTwoCopyShapesDiffer() async {
        let expected = Self.report([Self.step(id: DiagnosticStepID.tcp)])
        let clipboard = Clipboard()
        let model = Self.model(runner: { expected }, clipboard: clipboard)
        model.run()
        await model.runTask?.value
        model.copyPlainText()
        model.copyMarkdown()
        #expect(clipboard.written.count == 2)
        #expect(clipboard.written[0] != clipboard.written[1])
    }

    @Test func copyingBeforeARunWritesNothing() {
        let clipboard = Clipboard()
        let model = Self.model(runner: { Self.report([]) }, clipboard: clipboard)
        model.copyPlainText()
        model.copyMarkdown()
        #expect(clipboard.written.isEmpty, """
            with no report there is nothing to copy, and writing an empty report onto the \
            user's pasteboard would silently replace whatever was on it
            """)
    }

    // MARK: - What a row says

    @Test func aRowTitleComesFromTheStepsOwnCatalogueKey() {
        let resolved = DiagnosticsPresentation.title(of: Self.step(id: DiagnosticStepID.resolve))
        #expect(resolved != DiagnosticStepID.resolve, """
            the row title must come out of the catalog, not fall back to the step id — a \
            missing key would render the raw id in the panel
            """)
        #expect(!resolved.isEmpty)
    }

    /// A key Core does not have a catalog entry for renders as the step id
    /// rather than as an empty row.
    @Test func anUnknownTitleKeyDegradesToTheStepId() {
        let step = DiagnosticStep(
            id: "s3.accessLevel", titleKey: "diagnostics.step.doesNotExistYet",
            started: Date(), duration: .milliseconds(1), outcome: .ok, detail: "")
        #expect(DiagnosticsPresentation.title(of: step) == "s3.accessLevel")
    }

    @Test func everyOutcomeHasItsOwnBadge() {
        let badges = [
            DiagnosticOutcome.ok, .failed("refused"), .timedOut,
            .unavailable("no IPv6 route"), .skipped("nothing resolved to probe"),
        ].map(DiagnosticsPresentation.badge(for:))
        #expect(Set(badges).count == 5, """
            the five outcomes must read as five different badges — "not available in this \
            build" must never read as "your server is broken" (DiagnosticOutcome's own doc \
            comment) — got \(badges)
            """)
        #expect(badges.allSatisfy { !$0.isEmpty })
    }

    /// A reason Core composed itself is localized through the key Core names
    /// for it; one it did not compose is shown exactly as measured.
    @Test func aFixedReasonIsLocalizedAndAMeasuredOneIsNot() {
        let fixed = DiagnosticReason.nothingToProbe
        #expect(DiagnosticReason.key(for: fixed) != nil, """
            the runner's own sentences must carry a catalogue key — see DiagnosticReason
            """)
        #expect(!DiagnosticsPresentation.reason(of: .skipped(fixed)).isEmpty)

        let measured = "Connection refused"
        #expect(DiagnosticsPresentation.reason(of: .failed(measured)) == measured, """
            a strerror or a server's own message has no key and is shown as it was measured
            """)
    }

    @Test func anOkOutcomeCarriesNoReason() {
        #expect(DiagnosticsPresentation.reason(of: .ok).isEmpty)
        #expect(DiagnosticsPresentation.reason(of: .timedOut).isEmpty)
    }

    @Test func aRowsDurationIsRenderedInTheReportsOwnFormat() {
        let step = Self.step(id: DiagnosticStepID.tcp)
        #expect(DiagnosticsPresentation.duration(of: step).contains("12"))
    }

    // MARK: - Support

    /// Opens once, for the "is running" observation. An actor rather than a
    /// semaphore: nothing in this target may block the cooperative pool
    /// (CLAUDE.md, "Tests never block the cooperative pool").
    /// Counts the runner's invocations, so one fake can answer the first call
    /// and the second differently.
    private actor Calls {
        private var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }
}
