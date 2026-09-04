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

    /// What each run asked the runner to measure, in the order the runs
    /// started. A LIST rather than a last-value, because "the scope is read
    /// when the button is pressed" is a claim about two runs of one model.
    nonisolated private final class ScopeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var scopes: [DiagnosticScope] = []
        var recorded: [DiagnosticScope] { lock.withLock { scopes } }
        func record(_ scope: DiagnosticScope) { lock.withLock { scopes.append(scope) } }
    }

    /// A runner that measures nothing and reports it, for the tests that are
    /// about something other than the rows.
    nonisolated private static func finishing(
        with report: @autoclosure @escaping @Sendable () -> DiagnosticReport
    ) -> DiagnosticsViewModel.Runner {
        { _, _ in report() }
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
            runner: { _, _ in await gate.wait(); return Self.report([]) }, clipboard: Clipboard())
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
            runner: { _, _ in
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
            runner: { _, _ in
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
            runner: { [observed, started] _, _ in
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

    // MARK: - Scope

    /// A panel nobody has touched runs the whole diagnosis — what every door
    /// promised before the menu beside Run existed.
    @Test func aModelNobodyHasTouchedRunsTheCompleteDiagnosis() async {
        let asked = ScopeLog()
        let model = Self.model(
            runner: { [asked] scope, _ in
                asked.record(scope)
                return Self.report([])
            },
            clipboard: Clipboard())

        #expect(model.scope == .complete, "the default is the whole walk")
        model.run()
        await model.runTask?.value
        #expect(asked.recorded == [.complete], """
            a run nobody scoped must reach the runner as the complete diagnosis — got \
            \(asked.recorded)
            """)
    }

    /// The menu decides what Run runs, and Run reads it when it is PRESSED.
    ///
    /// Two runs with two different scopes, over one model: a scope closed over
    /// at construction — the shape this seam had before the menu — passes the
    /// first test above and this one's first half, and sends the same walk
    /// both times here.
    @Test func runPassesTheScopeChosenAtTheMomentItIsPressed() async {
        let asked = ScopeLog()
        let model = Self.model(
            runner: { [asked] scope, _ in
                asked.record(scope)
                return Self.report([])
            },
            clipboard: Clipboard())

        model.scope = .trace
        model.run()
        await model.runTask?.value

        model.scope = .contributions
        model.run()
        await model.runTask?.value

        #expect(asked.recorded == [.trace, .contributions], """
            each run must carry the scope that was chosen when its button was pressed — got \
            \(asked.recorded)
            """)
    }

    /// The mid-run snapshot is a report about a SCOPED walk, and says so.
    ///
    /// The one construction of a `DiagnosticReport` outside Core
    /// (`copyableReport`): it took the initializer's `.complete` default, so a
    /// trace-only run copied while it walked pasted a header claiming the
    /// whole diagnosis and four rows that were never asked for. Read while the
    /// runner is parked, so nothing has healed.
    @Test func theMidRunSnapshotCarriesTheScopeThatIsWalking() async {
        let emitted = [Self.step(id: DiagnosticStepID.resolve)]
        let clipboard = Clipboard()
        let model = Self.model(
            runner: { _, observer in
                for step in emitted { await observer.onStep(step) }
                try? await Task.sleep(for: .seconds(600))
                return Self.report(emitted)
            },
            clipboard: clipboard)
        model.scope = .ping
        model.run()
        await Self.yieldUntil("the row arrives") { model.steps.count == emitted.count }

        #expect(model.copyableReport?.scope == .ping, """
            the snapshot must carry the scope its walk was started with, not the initializer's \
            default
            """)

        // The menu moves while the walk goes on — nothing has re-run, and the
        // rows on screen are still the ping's. A snapshot headed with what the
        // menu says NOW names a scope nothing in it was measured under.
        model.scope = .complete
        #expect(model.copyableReport?.scope == .ping, """
            touching the menu mid-run must not relabel the walk that is on screen
            """)

        model.copyPlainText()
        let copied = clipboard.written.first ?? ""
        #expect(copied.contains(DiagnosticScope.ping.rawValue), """
            and the paste must name it, or a scoped run reads as a complete one whose missing \
            rows went unmeasured: \(copied)
            """)

        model.cancel()
        await model.runTask?.value
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
            runner: { _, observer in
                for step in emitted { await observer.onStep(step) }
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
            runner: { _, observer in
                for step in emitted { await observer.onStep(step) }
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
            runner: { _, observer in
                for step in emitted { await observer.onStep(step) }
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
            runner: { _, observer in
                let step = await calls.next() == 1 ? first : second
                await observer.onStep(step)
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
            runner: { _, observer in
                if await calls.next() == 1 {
                    await released.wait()
                    await observer.onStep(stale)
                    return Self.report([stale])
                }
                await observer.onStep(current)
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

    // MARK: - The step in flight

    /// While a step is being measured, the model names it — the key Core
    /// announced, and nothing else.
    ///
    /// The maintainer's finding on the dev build (2026-09-04): the panel said
    /// "Measuring…" from the first probe to the last, so the twenty seconds a
    /// firewalled trace spends looked exactly like a resolve that had hung.
    /// Read while the runner is parked, so nothing has healed.
    @Test func theRunningStepIsNamedWhileItIsMeasured() async {
        let walking = Self.step(id: DiagnosticStepID.trace)
        let parked = Gate()
        let model = Self.model(
            runner: { _, observer in
                await observer.onStepStarted(walking.id, walking.titleKey)
                await parked.wait()
                return Self.report([walking])
            },
            clipboard: Clipboard())
        model.run()
        await Self.yieldUntil("the start arrives") { model.runningStepTitleKey != nil }

        #expect(model.runningStepTitleKey == walking.titleKey, """
            the model must carry the catalogue key the step announced, which is what lets the \
            panel name the step in flight — got \(String(describing: model.runningStepTitleKey))
            """)
        #expect(model.isRunning, "and the run is genuinely still in flight")

        await parked.open()
        await model.runTask?.value
        #expect(model.runningStepTitleKey == nil, """
            a run that has ended is measuring nothing, and a name left behind would be a step \
            the panel claims is still walking
            """)
    }

    /// The row IS the end of the step: the moment it lands, the line stops
    /// naming it. Read before the parked runner is released, so the run's own
    /// ending cannot be what cleared it.
    @Test func theFinishedRowClearsTheRunningStep() async {
        let measured = Self.step(id: DiagnosticStepID.resolve)
        let parked = Gate()
        let model = Self.model(
            runner: { _, observer in
                await observer.onStepStarted(measured.id, measured.titleKey)
                await observer.onStep(measured)
                await parked.wait()
                return Self.report([measured])
            },
            clipboard: Clipboard())
        model.run()
        await Self.yieldUntil("the row arrives") { model.steps.count == 1 }

        #expect(model.runningStepTitleKey == nil, """
            the step that produced a row is finished — naming it beside its own row is the \
            panel telling the reader two different things about one step
            """)
        #expect(model.isRunning, "while the walk itself is still going")

        await parked.open()
        await model.runTask?.value
    }

    /// A cancel clears the name too: nothing is measuring the step any more.
    @Test func cancellingClearsTheRunningStep() async {
        let walking = Self.step(id: DiagnosticStepID.dial)
        let model = Self.model(
            runner: { _, observer in
                await observer.onStepStarted(walking.id, walking.titleKey)
                // Returns the moment the task is cancelled; the duration is a
                // park, not a deadline anything here asserts on.
                try? await Task.sleep(for: .seconds(60))
                return Self.report([], completion: .cancelled(afterSteps: 0))
            },
            clipboard: Clipboard())
        model.run()
        await Self.yieldUntil("the start arrives") { model.runningStepTitleKey != nil }

        model.cancel()
        await model.runTask?.value
        #expect(model.runningStepTitleKey == nil, """
            a cancelled walk measures nothing, and the panel must not go on naming the step it \
            was stopped in the middle of
            """)
        #expect(model.isRunning == false)
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
            runner: { _, observer in
                for step in emitted { await observer.onStep(step) }
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
            runner: { _, observer in
                for step in emitted { await observer.onStep(step) }
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

    /// Five scopes, five names, none of them the raw case.
    @Test func everyScopeHasItsOwnNameInTheMenu() {
        let names = DiagnosticScope.allCases.map(DiagnosticsPresentation.scopeName)
        #expect(Set(names).count == DiagnosticScope.allCases.count, """
            each scope must read as its own entry — two entries with one name is a menu whose \
            user cannot tell what they picked: \(names)
            """)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(DiagnosticsPresentation.scopeName(.complete) != DiagnosticScope.complete.rawValue, """
            the entries come out of the catalog, not out of the enum's spelling
            """)
    }

    /// A column header is the catalogue entry for the key Core sent, and an
    /// unknown key degrades to its last component — what the report prints for
    /// the same column — rather than to the whole key.
    @Test func aColumnHeaderIsLookedUpAndDegradesToTheColumnsOwnName() {
        let hop = DiagnosticsPresentation.columnTitle(DiagnosticTraceColumn.hop)
        #expect(hop != DiagnosticTraceColumn.hop, "the header is not the key itself")
        #expect(!hop.isEmpty)
        #expect(DiagnosticsPresentation.columnTitle("diagnostics.trace.column.doesNotExistYet")
            == "doesNotExistYet")
    }

    /// Each of Core's four outcome words is looked up under ITS OWN key.
    ///
    /// The round trip — Core's constant, through the mapping, compared against
    /// the string that key resolves to — and it is what a key SWAP fails.
    /// Nothing else can see one: swapping two keys inside the mapping changes
    /// no key set, so the catalogue equality stays green, and while `en`
    /// rendered those words as the words Core composed it changed no string
    /// either. Every answered hop would have displayed "silent", in all four
    /// languages, with the suite green (review of 2026-09-03, Important 1).
    ///
    /// Which is why `en` now capitalizes them — `Answered`, `Silent`,
    /// `Destination`, `Unreachable (code %@)`, the same shape as the
    /// `diagnostics.outcome.*` badges beside them. That the rendered word
    /// DIFFERS from Core's is asserted here too: it is the property that makes
    /// the first assertion able to fail at all, and `en` sliding back to the
    /// lowercase word would take the round trip's teeth with it.
    ///
    /// The pasted report is untouched by any of this — it prints Core's own
    /// lowercase words, in English, by design (`DiagnosticReport`).
    @Test func everyTraceOutcomeWordIsLookedUpUnderItsOwnKey() {
        let outcome = DiagnosticTraceColumn.outcome
        let missing = "«no entry»"
        let words: [(word: String, key: String)] = [
            (DiagnosticTraceColumn.answered, "diagnostics.trace.outcome.answered"),
            (DiagnosticTraceColumn.silent, "diagnostics.trace.outcome.silent"),
            (DiagnosticTraceColumn.destination, "diagnostics.trace.outcome.destination"),
        ]
        for (word, key) in words {
            let rendered = DiagnosticsPresentation.cell(word, column: outcome)
            let underItsOwnKey = rendered == L10n.string(key, missing)
            let differsFromWhatCoreComposed = rendered != word
            #expect(underItsOwnKey, """
                `\(word)` must render as what \(key) resolves to — another key's entry reads as \
                a hop that did something else, and no other check in this suite can see it. \
                Got: \(rendered)
                """)
            #expect(differsFromWhatCoreComposed, """
                the entry for \(key) must not be the word Core composed, or the assertion above \
                is satisfied by a mapping that looks nothing up. Got: \(rendered)
                """)
        }

        // The fourth, which carries a number: same round trip, through the
        // format its own key resolves to.
        let code = 13
        let refusal = DiagnosticTraceColumn.unreachable(code: UInt8(code))
        let rendered = DiagnosticsPresentation.cell(refusal, column: outcome)
        let key = "diagnostics.trace.outcome.unreachable"
        let underItsOwnKey =
            rendered == String(format: L10n.string(key, missing), "\(code)")
        #expect(underItsOwnKey, """
            a refusal must render as \(key) with the measured code substituted — got \(rendered)
            """)
        #expect(rendered != refusal, """
            and it must not be the sentence Core composed, or the assertion above cannot fail
            """)
    }

    /// The outcome column is the one Core writes WORDS into, and it is the
    /// only one the panel looks up. Which key each word takes is the round
    /// trip above; what is pinned here is the branching around it.
    @Test func onlyTheOutcomeColumnIsLookedUpAndAnUnknownWordIsPassedThrough() {
        let address = "10.0.0.1"
        #expect(
            DiagnosticsPresentation.cell(address, column: DiagnosticTraceColumn.address) == address,
            """
            a measured cell is copied through byte for byte — it is what somebody pastes into \
            a bug report, and a translated address is one its reader cannot search for
            """)
        #expect(
            DiagnosticsPresentation.cell(
                DiagnosticTraceColumn.answered, column: DiagnosticTraceColumn.address)
                == DiagnosticTraceColumn.answered,
            "the outcome lookup is chosen by the COLUMN, not by the cell's text")

        let refusal = DiagnosticTraceColumn.unreachable(code: 13)
        let rendered = DiagnosticsPresentation.cell(refusal, column: DiagnosticTraceColumn.outcome)
        #expect(rendered.contains("13"), """
            the code the hop sent is the finding in that row and must survive the substitution: \
            \(rendered)
            """)

        let unknown = "something Core has not composed yet"
        #expect(
            DiagnosticsPresentation.cell(unknown, column: DiagnosticTraceColumn.outcome) == unknown,
            """
            a word this mapping does not know is shown as measured rather than mangled into a \
            format it does not fit
            """)
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
