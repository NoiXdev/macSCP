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

    /// A report the way Core hands one back. `completion` is a parameter
    /// rather than a default everywhere, because the cases below that cancel
    /// have to stand in for what `ConnectionDiagnostics` actually produces —
    /// a fake that always answers `.complete` would let the App launder a
    /// cancel's label away and stay green.
    nonisolated private static func report(
        _ steps: [DiagnosticStep], completion: DiagnosticReport.Completion = .complete
    ) -> DiagnosticReport {
        DiagnosticReport(
            endpoint: Endpoint(host: "example.test", port: 22), steps: steps,
            appVersion: "0.0.0-test", completion: completion)
    }

    /// A recording pasteboard: the seam the view model writes through, so a
    /// test can read what a copy entry actually put there. Production passes
    /// the `NSPasteboard.general` writer the rest of the app uses.
    nonisolated private final class Clipboard: @unchecked Sendable {
        private(set) var written: [String] = []
        func write(_ text: String) { written.append(text) }
    }

    /// A runner that measures nothing and reports it, for the tests that are
    /// about something other than the rows.
    nonisolated private static func finishing(
        with report: @autoclosure @escaping @Sendable () -> DiagnosticReport
    ) -> DiagnosticsViewModel.Runner {
        { _ in report() }
    }

    private static func model(
        runner: @escaping DiagnosticsViewModel.Runner, clipboard: Clipboard,
        endpoint: Endpoint? = Endpoint(host: "example.test", port: 22)
    ) -> DiagnosticsViewModel {
        DiagnosticsViewModel(
            name: "Test session", endpoint: endpoint, appVersion: "0.0.0-test", runner: runner,
            copy: { [clipboard] text in clipboard.write(text) })
    }

    // MARK: - Running

    /// The decision of 2026-09-02, at its source: a freshly built model has
    /// measured nothing. Whatever the panel does on appear, it cannot be
    /// showing a report it never ran.
    @Test func aFreshModelHasNotRunAnything() {
        let model = Self.model(runner: Self.finishing(with: Self.report([])), clipboard: Clipboard())
        #expect(model.report == nil)
        #expect(model.isRunning == false)
    }

    @Test func runPublishesTheRunnersReport() async {
        let expected = Self.report([Self.step(id: DiagnosticStepID.resolve)])
        let model = Self.model(runner: Self.finishing(with: expected), clipboard: Clipboard())
        model.run()
        await model.runTask?.value
        #expect(model.report == expected)
        #expect(model.isRunning == false)
    }

    @Test func isRunningIsSetBeforeTheRunnerAnswers() async {
        let gate = Gate()
        let model = Self.model(
            runner: { _ in await gate.wait(); return Self.report([]) }, clipboard: Clipboard())
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
        let partial = Self.report(
            [Self.step(id: DiagnosticStepID.resolve)], completion: .cancelled(afterSteps: 1))
        let model = Self.model(
            runner: { _ in
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
            runner: { _ in
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

    /// The cancellation the two lifecycle paths depend on: `cancel()` reaches
    /// the RUNNER, not just the model's own flags.
    ///
    /// Read while the runner is still parked, so nothing has healed: the fake
    /// records its cancellation synchronously through
    /// `withTaskCancellationHandler`, and a `true` here cannot have come from
    /// a run that simply finished. `DiagnosticsLifecycleTests` drives the same
    /// property through the sheet and the tab teardown.
    @Test func cancelReachesTheRunnerBeforeAnythingHeals() async {
        let observed = CancellationFlag()
        let started = Gate()
        let model = Self.model(
            runner: { [observed, started] _ in
                await withTaskCancellationHandler {
                    await started.open()
                    try? await Task.sleep(for: .seconds(600))
                    return Self.report([])
                } onCancel: {
                    observed.set()
                }
            },
            clipboard: Clipboard())
        model.run()
        await started.wait()
        #expect(observed.isSet == false, "nothing has asked it to stop yet")

        model.cancel()

        #expect(observed.isSet, """
            cancel() must reach the probe itself. The model's own flags say nothing about \
            whether an SSH dial is still authenticating against the user's server.
            """)
    }

    /// A run cancelled before its first step measured anything publishes
    /// nothing.
    ///
    /// `ConnectionDiagnostics.run()` answers a task cancelled before the
    /// resolve step with a report of ZERO steps. Publishing it swaps the
    /// panel's idle explanation for an empty rows area, offers "Run again",
    /// and enables the Copy menu over a report with no rows — three controls
    /// describing a measurement that never happened.
    @Test func aRunThatMeasuredNothingPublishesNothing() async {
        let model = Self.model(runner: Self.finishing(with: Self.report([])), clipboard: Clipboard())
        model.run()
        await model.runTask?.value
        #expect(model.report == nil, """
            an empty report is not a result; the panel keeps its idle text, which is the more \
            useful state
            """)
        #expect(model.isRunning == false, "the run is over either way")
    }

    /// The same rule must not throw away a report that DID measure something.
    @Test func aRunThatMeasuredOneStepPublishesIt() async {
        let partial = Self.report([Self.step(id: DiagnosticStepID.resolve)])
        let model = Self.model(runner: Self.finishing(with: partial), clipboard: Clipboard())
        model.run()
        await model.runTask?.value
        #expect(model.report == partial)
    }

    // MARK: - Rows as they arrive

    /// The rows appear while the walk is still walking.
    ///
    /// The defect (trace re-review, Important 1): the report was published
    /// once, at the end. A host whose last hops are firewalled finishes
    /// resolve, TCP, echo and dial in under a second and then spends the
    /// trace's whole 20 s budget walking silent hops — so the panel showed a
    /// spinner and nothing else for 21+ seconds, with four finished rows
    /// sitting in a local variable nobody could see.
    ///
    /// Read while the runner is still parked: the steps are visible BEFORE
    /// anything completes, which is the whole claim.
    @Test func rowsAppearAsEachStepFinishes() async {
        let emitted = [
            Self.step(id: DiagnosticStepID.resolve), Self.step(id: DiagnosticStepID.tcp),
        ]
        let parked = Gate()
        let model = Self.model(
            runner: { onStep in
                for step in emitted { await onStep(step) }
                await parked.wait()
                return Self.report(emitted)
            },
            clipboard: Clipboard())
        model.run()
        await Self.yieldUntil("both rows arrive") { model.steps.count == emitted.count }

        #expect(model.steps.map(\.id) == emitted.map(\.id), """
            both finished steps must be on screen while the run is still going — that is what \
            the 21-second spinner cost the reader
            """)
        #expect(model.isRunning, "and the run is genuinely still in flight")
        #expect(model.report == nil, "nothing has been published as a finished report yet")

        await parked.open()
        await model.runTask?.value
        #expect(model.steps.map(\.id) == emitted.map(\.id))
        #expect(model.report?.steps == emitted, """
            when the run ends, the report and the visible rows describe the same measurement
            """)
    }

    /// Cancelling keeps the rows that were already on screen — and keeps the
    /// label that says the walk was cut short.
    ///
    /// Before this, a cancel returned whatever `ConnectionDiagnostics` handed
    /// back — and a run cancelled mid-trace drops the step it is inside — so
    /// pressing Cancel after twenty seconds of spinner could cost the reader
    /// rows that had been ready the whole time.
    ///
    /// The completion is read HERE rather than only in the copy case below,
    /// because the run's own answer is what the copy renders: the model
    /// publishes the runner's report unchanged, and a model that re-decided
    /// "complete" on the way in would leave both copy shapes silent about the
    /// cancel with nothing else able to see it.
    @Test func cancellingKeepsTheRowsAlreadyMeasured() async {
        let emitted = [
            Self.step(id: DiagnosticStepID.resolve), Self.step(id: DiagnosticStepID.tcp),
        ]
        let model = Self.model(
            runner: { onStep in
                for step in emitted { await onStep(step) }
                try? await Task.sleep(for: .seconds(600))
                return Self.report(emitted, completion: .cancelled(afterSteps: emitted.count))
            },
            clipboard: Clipboard())
        model.run()
        await Self.yieldUntil("both rows arrive") { model.steps.count == emitted.count }

        model.cancel()
        await model.runTask?.value

        #expect(model.steps.map(\.id) == emitted.map(\.id), """
            the partial measurement IS the measurement — cancelling must not throw away the \
            rows the walk had already finished
            """)
        #expect(model.report?.completion == .cancelled(afterSteps: 2), """
            …and the report it publishes must still say the walk was cancelled, and after \
            how many steps: \(String(describing: model.report?.completion))
            """)
        #expect(model.isRunning == false)
    }

    /// Copying after a Cancel says the walk was cancelled.
    ///
    /// The scenario, measured as a real defect on 2026-09-03: a host answers
    /// the resolve and the TCP ping quickly and then hangs, the user decides
    /// two rows are enough evidence and presses Cancel, then copies. Every
    /// piece was already in place — the rows survive the cancel, the copy
    /// entry stays enabled — and the pasted text read exactly like a finished
    /// two-step diagnosis, because `ConnectionDiagnostics` built its
    /// cancellation returns through the same helper as its natural one.
    /// Whoever read the issue had no way to tell that the dial and the trace
    /// were never attempted from their having been attempted and found
    /// absent.
    ///
    /// `copyableReport`'s first branch returns the published report as it
    /// stands, so this is also the case that catches a model synthesising a
    /// `.running` snapshot over a run that is over.
    @Test func copyingAfterACancelSaysTheWalkWasCancelled() async {
        let emitted = [
            Self.step(id: DiagnosticStepID.resolve, detail: "A 127.0.0.1"),
            Self.step(id: DiagnosticStepID.tcp),
        ]
        let clipboard = Clipboard()
        let model = Self.model(
            runner: { onStep in
                for step in emitted { await onStep(step) }
                try? await Task.sleep(for: .seconds(600))
                return Self.report(emitted, completion: .cancelled(afterSteps: emitted.count))
            },
            clipboard: clipboard)
        model.run()
        await Self.yieldUntil("both rows arrive") { model.steps.count == emitted.count }

        model.cancel()
        await model.runTask?.value

        model.copyPlainText()
        model.copyMarkdown()
        #expect(clipboard.written.count == 2)
        for copied in clipboard.written {
            #expect(copied.contains("(cancelled after 2 steps)"), """
                a cancelled report pasted into an issue must say so: \(copied)
                """)
            #expect(copied.contains("run in progress") == false, """
                …and must not claim to be still running, which it is not: \(copied)
                """)
        }
    }

    /// A second run starts from an empty list rather than growing the first
    /// one's.
    @Test func runningAgainClearsTheRowsOfTheRunBefore() async {
        let first = Self.step(id: DiagnosticStepID.resolve)
        let second = Self.step(id: DiagnosticStepID.tcp)
        let calls = Calls()
        let model = Self.model(
            runner: { onStep in
                let step = await calls.next() == 1 ? first : second
                await onStep(step)
                return Self.report([step])
            },
            clipboard: Clipboard())
        model.run()
        await model.runTask?.value
        model.run()
        await model.runTask?.value
        #expect(model.steps.map(\.id) == [second.id])
    }

    /// A superseded run's late row must not land in the run that replaced it —
    /// the same attempt token the report has always been guarded by.
    @Test func aSupersededRunsLateRowIsDropped() async {
        let stale = Self.step(id: DiagnosticStepID.icmp)
        let current = Self.step(id: DiagnosticStepID.tcp)
        let calls = Calls()
        let released = Gate()
        let model = Self.model(
            runner: { onStep in
                if await calls.next() == 1 {
                    await released.wait()
                    await onStep(stale)
                    return Self.report([stale])
                }
                await onStep(current)
                return Self.report([current])
            },
            clipboard: Clipboard())
        model.run()
        let abandoned = model.runTask
        model.run()
        await model.runTask?.value
        await released.open()
        await abandoned?.value

        #expect(model.steps.map(\.id) == [current.id], """
            the abandoned run emits its row after the replacement has published; without the \
            attempt token it would append to the list the reader is looking at
            """)
    }

    // MARK: - Copying

    @Test func bothCopyEntriesReachThePasteboard() async {
        let expected = Self.report([Self.step(id: DiagnosticStepID.resolve, detail: "A 127.0.0.1")])
        let clipboard = Clipboard()
        let model = Self.model(runner: Self.finishing(with: expected), clipboard: clipboard)
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
        let model = Self.model(runner: Self.finishing(with: expected), clipboard: clipboard)
        model.run()
        await model.runTask?.value
        model.copyPlainText()
        model.copyMarkdown()
        #expect(clipboard.written.count == 2)
        #expect(clipboard.written[0] != clipboard.written[1])
    }

    /// The rows are on screen, so they can be copied.
    ///
    /// The case ruling A was written from: a firewalled host puts four rows up
    /// in the first second and then spends twenty more in the trace. Copy was
    /// disabled for all twenty, so the way to copy what you could already read
    /// was to press Cancel — pressing STOP in order to COPY.
    ///
    /// The reason given at the control was wrong in both halves, which is why
    /// it survived a round: the build line is the App's own
    /// (`CFBundleShortVersionString`), and the endpoint is
    /// `descriptor.endpoint(values)`, a `public let` the App computes one line
    /// from where it already builds the descriptor. Neither had to be
    /// invented; the endpoint simply was not carried across the seam.
    @Test func copyingMidRunWritesThePartialReportAndSaysItIsPartial() async {
        let emitted = [
            Self.step(id: DiagnosticStepID.resolve, detail: "A 127.0.0.1"),
            Self.step(id: DiagnosticStepID.tcp),
        ]
        let clipboard = Clipboard()
        let model = Self.model(
            runner: { onStep in
                for step in emitted { await onStep(step) }
                try? await Task.sleep(for: .seconds(600))
                return Self.report(emitted)
            },
            clipboard: clipboard)
        model.run()
        await Self.yieldUntil("the rows arrive") { model.steps.count == emitted.count }

        #expect(model.copyableReport != nil, "there is something to copy while it runs")
        model.copyPlainText()

        #expect(clipboard.written.count == 1, "one copy entry wrote once")
        let copied = clipboard.written.first ?? ""
        #expect(copied.contains("example.test:22"), """
            the endpoint is known before the walk starts and belongs in the header: \(copied)
            """)
        #expect(copied.contains(DiagnosticStepID.resolve))
        #expect(copied.contains("run in progress"), """
            a partial report pasted into an issue must say it is partial, or its missing rows \
            read as steps that were measured and found absent: \(copied)
            """)

        model.cancel()
        await model.runTask?.value
    }

    /// …and a finished report says nothing of the kind.
    @Test func copyingAFinishedRunCarriesNoPartialMarker() async {
        let clipboard = Clipboard()
        let expected = Self.report([Self.step(id: DiagnosticStepID.resolve)])
        let model = Self.model(runner: Self.finishing(with: expected), clipboard: clipboard)
        model.run()
        await model.runTask?.value
        model.copyPlainText()
        model.copyMarkdown()
        #expect(clipboard.written == [expected.plainText(), expected.markdown()], """
            a completed run copies the report Core produced, unchanged
            """)
        #expect(clipboard.written.allSatisfy { !$0.contains("run in progress") })
    }

    /// A run with no endpoint to name has nothing coherent to copy mid-run —
    /// the header would be a fabricated `:0`. The rows are still on screen.
    @Test func copyingMidRunIsRefusedWhenNoEndpointIsKnown() async {
        let emitted = [Self.step(id: DiagnosticStepID.resolve)]
        let clipboard = Clipboard()
        let model = Self.model(
            runner: { onStep in
                for step in emitted { await onStep(step) }
                try? await Task.sleep(for: .seconds(600))
                return Self.report(emitted)
            },
            clipboard: clipboard, endpoint: nil)
        model.run()
        await Self.yieldUntil("the row arrives") { model.steps.count == emitted.count }

        #expect(model.copyableReport == nil)
        model.copyPlainText()
        #expect(clipboard.written.isEmpty)

        model.cancel()
        await model.runTask?.value
    }

    /// The production model derives its endpoint from the target it was
    /// built for — the one path a fake runner can never exercise.
    ///
    /// Found by probing: replacing `descriptor.endpoint(target.values)` with
    /// `nil` in the convenience initializer left every test here green,
    /// because they all inject an endpoint directly. The mid-run copy would
    /// then be silently refused for every real session, which is the whole
    /// behaviour this round added.
    ///
    /// Constructing the model runs nothing — that is the decision of
    /// 2026-09-02 — so this touches no socket.
    @Test func theProductionModelKnowsItsEndpointBeforeAnythingRuns() {
        var values = BackendDescriptor.descriptor(for: .ssh).defaultValues
        values[SSHField.host] = "example.test"
        values[SSHField.port] = "2222"
        let model = DiagnosticsViewModel(
            target: DiagnosticsTarget(
                name: "Test session", kind: .ssh, values: values, sessionID: nil),
            secrets: nil)

        #expect(model.endpoint == Endpoint(host: "example.test", port: 2222), """
            the endpoint is `descriptor.endpoint(values)`, known before the first probe — \
            without it the panel names no host and a running walk cannot be copied
            """)
        #expect(model.steps.isEmpty, "and building one measures nothing")
        #expect(model.report == nil)
        #expect(model.isRunning == false)
    }

    @Test func copyingBeforeARunWritesNothing() {
        let clipboard = Clipboard()
        let model = Self.model(runner: Self.finishing(with: Self.report([])), clipboard: clipboard)
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

    /// The trace's budget marker is a fixed sentence with a number in it, and
    /// it rides in the step's DETAIL line rather than in its outcome. The
    /// panel renders the detail, so the marker has to be looked up there or
    /// it prints as the English Core composed.
    @Test func theTraceBudgetMarkerIsLocalizedInsideTheDetailLine() {
        let raw = DiagnosticReason.traceStoppedByBudget(afterHop: 6)
        let step = DiagnosticStep(
            id: DiagnosticStepID.trace,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.trace),
            started: Date(), duration: .milliseconds(90), outcome: .ok,
            detail: "1 10.0.0.1 1.2 ms; 2 * ; \(raw)")
        let rendered = DiagnosticsPresentation.detail(of: step)
        #expect(rendered != step.detail, "the marker must not print as Core composed it")
        #expect(!rendered.contains(raw))
        #expect(rendered.contains("6"), "the hop number survives the substitution: \(rendered)")
        #expect(rendered.hasPrefix("1 10.0.0.1 1.2 ms; 2 * ; "), """
            the measured hops are copied through untouched — they are the artifact people \
            paste into a bug report: \(rendered)
            """)
    }

    /// The hop-limit marker is the budget marker's twin — same shape, same
    /// place in the detail line, same reason for being localized: it says the
    /// trace stopped looking, which is the one thing in the line a reader has
    /// to understand rather than quote.
    @Test func theTraceHopLimitMarkerIsLocalizedInsideTheDetailLine() {
        let raw = DiagnosticReason.traceHopLimitReached(afterHop: 30)
        let step = DiagnosticStep(
            id: DiagnosticStepID.trace,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.trace),
            started: Date(), duration: .milliseconds(90), outcome: .ok,
            detail: "1 10.0.0.1 1.2 ms; \(raw)")
        let rendered = DiagnosticsPresentation.detail(of: step)
        #expect(rendered != step.detail, "the marker must not print as Core composed it")
        #expect(!rendered.contains(raw))
        #expect(rendered.contains("30"), "the hop number survives: \(rendered)")
        #expect(rendered.hasPrefix("1 10.0.0.1 1.2 ms; "))
    }

    /// A detail line with no marker in it is handed through unchanged.
    @Test func aDetailLineWithoutTheMarkerIsUntouched() {
        let step = Self.step(
            id: DiagnosticStepID.tcp, detail: "127.0.0.1:2222 accepted in 0.4 ms")
        #expect(DiagnosticsPresentation.detail(of: step) == step.detail)
    }

    @Test func aRowsDurationIsRenderedInTheReportsOwnFormat() {
        let step = Self.step(id: DiagnosticStepID.tcp)
        #expect(DiagnosticsPresentation.duration(of: step).contains("12"))
    }

    // MARK: - Support

    /// Yields until `condition` holds, or gives up with a message.
    ///
    /// Bounded, and that is the point: an unbounded `while … yield()` turns
    /// "the observer stopped being wired" into a HANG that reports as CI
    /// trouble rather than as the failing property it is. The count is a
    /// give-up, not a deadline — nothing here asserts on how many turns it
    /// took.
    private static func yieldUntil(
        _ what: String, turns: Int = 10_000, _ condition: () -> Bool
    ) async {
        for _ in 0..<turns {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("gave up after \(turns) turns waiting for: \(what)")
    }

    /// Records a cancellation the moment it happens, from whatever thread
    /// `Task.cancel()` runs the handler on. An `NSLock` rather than an actor
    /// because `withTaskCancellationHandler`'s `onCancel` is synchronous and
    /// cannot await anything.
    nonisolated private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    /// Counts the runner's invocations, so one fake can answer the first call
    /// and the second differently.
    private actor Calls {
        private var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    /// Opens once, and lets either side arrive first. An actor rather than a
    /// semaphore: nothing in this target may block the cooperative pool
    /// (CLAUDE.md, "Tests never block the cooperative pool").
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
