import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the property no source scan can: that a diagnosis actually STOPS
/// when the panel is dismissed and when the tab is torn down — not that the
/// two paths spell "cancel" somewhere, but that the running probe observes
/// its cancellation.
///
/// The defect this suite was written against (fix round 1): `run()` starts a
/// free `Task`, which no view teardown touches, and `cancel()` was reachable
/// only from the in-flight Cancel button. Closing the sheet, pressing Esc or
/// closing the tab left the walk going — the remaining steps under their
/// budgets, and the SSH dial holding Citadel's uncancellable 15 s `openSFTP`
/// timer — authenticating against the user's server after the user had
/// visibly withdrawn. CLAUDE.md, "The UI owns lifecycles explicitly … no
/// `deinit` cleanup".
///
/// ## The postcondition is read before anything heals
///
/// The fake runner parks in a cancellable sleep it never wakes from on its
/// own, and records its cancellation SYNCHRONOUSLY through
/// `withTaskCancellationHandler`. Every test here that reads that record does
/// so while the runner is still parked — before `runTask` is awaited, before
/// the model publishes anything — so none of them can pass on the strength of
/// a run that finished by itself. CLAUDE.md, "A check that reads after the
/// healing is not a check".
///
/// Deliberately no count: this paragraph said "both tests" while the suite
/// held six, which is what an enumeration in a header does the moment a test
/// is added.
///
/// The other half of the same rule is the `== false` pre-read each of them
/// carries before the act. A test that cannot have one is a test whose setup
/// has already satisfied it — see `aLivenessGiveUpOnTheDiagnosedTabKeepsTheRows`,
/// which was exactly that until fix round 3.
///
/// ## Isolation
///
/// A real `ContentView`, built through every seam its initializer offers —
/// temporary directories and an in-memory `SecretStore` — the same shape
/// `LivenessGiveUpOrderingTests` and `ConnectAttemptHandoffTests` use. See
/// that file's doc comment for the incident behind taking the whole seam
/// rather than the part today's path happens to need. `teardown(_:reason:)`
/// is driven for real, all the way down.
@Suite("Diagnostics lifecycle")
@MainActor
struct DiagnosticsLifecycleTests {
    // MARK: - Fixtures

    /// A runner that emits whatever rows it was given, then never finishes on
    /// its own, and notes the moment it is cancelled.
    ///
    /// `onCancel` runs synchronously on the thread that calls
    /// `Task.cancel()`, so `wasCancelled` is true by the time the call that
    /// cancelled it returns — which is what lets a test read it before the
    /// runner has had any chance to heal.
    ///
    /// One `ParkedRun` belongs to one run. The flag is never reset, so sharing
    /// an instance between two runs would let the first one's cancellation
    /// satisfy an assertion about the second — which is exactly how
    /// `aLivenessGiveUpOnTheDiagnosedTabKeepsTheRows` came to pass without
    /// testing anything (fix round 3, Important 1).
    private final class ParkedRun: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var started = false
        private let rows: [DiagnosticStep]

        init(emitting rows: [DiagnosticStep] = []) {
            self.rows = rows
        }

        var wasCancelled: Bool { lock.withLock { cancelled } }
        var hasStarted: Bool { lock.withLock { started } }

        func runner() -> DiagnosticsViewModel.Runner {
            { [self] _, observer in
                await withTaskCancellationHandler {
                    for row in rows { await observer.onStep(row) }
                    lock.withLock { started = true }
                    // Never returns of its own accord within any run of this
                    // suite; a working cancel returns it at once. The number
                    // is a park, not a deadline anything here asserts on.
                    try? await Task.sleep(for: .seconds(600))
                    return DiagnosticReport(
                        endpoint: Endpoint(host: "example.test", port: 22), steps: rows,
                        appVersion: "0.0.0-test")
                } onCancel: {
                    lock.withLock { cancelled = true }
                }
            }
        }
    }

    /// One finished row, for the fixtures that need the panel to have
    /// measured something.
    private static func step(id: String) -> DiagnosticStep {
        DiagnosticStep(
            id: id, titleKey: DiagnosticStepID.titleKey(for: id), started: Date(),
            duration: .milliseconds(7), outcome: .ok, detail: "")
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func makeContentView() -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("diag-settings")
        let auditDir = makeTempDirectory("diag-audit")
        let workDir = makeTempDirectory("diag-sessions")
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: workDir),
            secrets: InertSecretStore(),
            auditStore: AuditLogStore(directory: workDir.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: workDir),
            keys: ManagedKeyStore(directory: workDir))
        let view = ContentView(
            settingsStore: SettingsStore(directory: settingsDir),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel,
            secretStore: InertSecretStore(),
            managedKeyStore: ManagedKeyStore(directory: workDir))
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
            try? FileManager.default.removeItem(at: workDir)
        })
    }

    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Opens a panel on the window with a runner this suite controls, and
    /// starts it. Returns the parked run so the caller can read whether it
    /// was cancelled, and the model so the caller can stop it afterwards.
    ///
    /// Goes through the presenter rather than `showDiagnostics(for:)` on
    /// purpose: that entry builds the REAL `ConnectionDiagnostics`, which
    /// would resolve a name and open sockets. What is under test here is the
    /// lifecycle, not the probes.
    private func presentRunningPanel(
        on view: ContentView, for tab: SessionTab? = nil, emitting rows: [DiagnosticStep] = []
    ) async -> (parked: ParkedRun, model: DiagnosticsViewModel) {
        let parked = ParkedRun(emitting: rows)
        let model = DiagnosticsViewModel(name: "Test session", runner: parked.runner())
        view.diagnostics.present(model, for: tab?.id)
        model.run()
        await Self.yieldUntil("the runner reached its park") { parked.hasStarted }
        await Self.yieldUntil("every emitted row reached the model") {
            model.steps.count == rows.count
        }
        return (parked, model)
    }

    /// Yields until `condition` holds, or gives up with a message.
    ///
    /// Bounded, and that is the whole point: an unbounded `while … yield()`
    /// turns "the observer stopped being wired" into a HANG — the run sits at
    /// CI's timeout and reports as infrastructure trouble rather than as the
    /// failing property it is. The count is a give-up, not a deadline: nothing
    /// here asserts on how many turns it took, and a machine that needs more
    /// than this many main-actor turns to run a lock write has a different
    /// problem.
    private static func yieldUntil(
        _ what: String, turns: Int = 10_000, _ condition: () -> Bool
    ) async {
        for _ in 0..<turns {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("gave up after \(turns) turns waiting for: \(what)")
    }

    /// Ends a run this test started and WAITS for it, after every assertion
    /// has been made.
    ///
    /// The order is the rule, not a preference: a `ParkedRun` sleeps for ten
    /// minutes, so stopping it before the postconditions are read would let
    /// the thing under test heal into the values the test wanted (CLAUDE.md,
    /// "Tests that watch a defect heal"). Every call below is therefore the
    /// last statement of its test.
    ///
    /// Awaited rather than merely cancelled: a `Task` that is cancelled and
    /// never joined is still a scheduler entry, and on a three-core runner
    /// sharing its pool with three thousand tests those entries are exactly
    /// the kind of thing that makes a starved run slower.
    private func stopAndAwait(_ models: DiagnosticsViewModel?...) async {
        for model in models { model?.cancel() }
        for model in models { await model?.runTask?.value }
    }

    // MARK: - The two paths

    /// Closing the sheet stops the diagnosis.
    @Test func dismissingThePanelCancelsTheRunningDiagnosis() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let (parked, _) = await presentRunningPanel(on: view)
        #expect(parked.wasCancelled == false, "nothing has asked it to stop yet")

        view.endDiagnostics()

        // Read while the runner is still parked: it cannot have finished on
        // its own, so a true here is the cancellation and nothing else.
        #expect(parked.wasCancelled, """
            dismissing the panel must stop the diagnosis. A run that outlives its sheet keeps \
            dialling — and the SSH dial authenticates while doing it — after the user has \
            closed the window on it.
            """)
        #expect(view.diagnostics.open == nil)
    }

    /// Tearing down the tab the panel was opened FOR stops the run — and
    /// keeps what it measured on screen.
    ///
    /// Two halves, and the second is the one fix round 1 got wrong. Stopping
    /// is right: the walk is dialling a connection the window has finished
    /// with, and closing a tab does not dismiss the sheet by itself, so
    /// nothing else would stop it. DISMISSING is not: `teardown` runs for six
    /// callers, and `handleLivenessGiveUp` is not a user action at all — the
    /// session dropping is precisely WHY the panel is open, and throwing the
    /// rows away at that moment discards the only thing that could say whether
    /// the host stopped resolving, the port stopped accepting or the auth
    /// started failing. The sheet stays until the person closes it.
    @Test func tearingDownTheDiagnosedTabStopsTheRunAndKeepsTheRows() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        let (parked, _) = await presentRunningPanel(on: view, for: tab)
        #expect(parked.wasCancelled == false)

        await view.teardown(tab, reason: .userRequested)

        #expect(parked.wasCancelled, """
            leaving a connection must stop the diagnosis of it — the walk would otherwise \
            keep dialling a server the window is done with.
            """)
        #expect(view.diagnostics.open != nil, """
            …and must NOT take the panel with it: a finished or partial report is what the \
            user opened it for, and there is no way back to it except re-dialling.
            """)
    }

    /// The path that is not a user action at all: the liveness probe giving
    /// up. The rows survive it.
    @Test func aLivenessGiveUpOnTheDiagnosedTabKeepsTheRows() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        let (parked, model) = await presentRunningPanel(on: view, for: tab)
        // The pre-read every sibling carries, and the one this test could not
        // have while it started a SECOND run of its own: `run()` begins by
        // cancelling whatever is in flight, `ParkedRun` records that
        // synchronously, and one instance was shared by both runs — so
        // `wasCancelled` was already true here, and the assertion below was
        // satisfied by the setup. Deleting `stopDiagnostics(of:)` from
        // `teardown` left this test green (fix round 3, Important 1).
        #expect(parked.wasCancelled == false, "nothing has asked it to stop yet")

        await view.handleLivenessGiveUp(tab)

        #expect(parked.wasCancelled, """
            the give-up path must stop the walk: it runs `teardown`, and the connection it \
            was dialling is gone.
            """)
        #expect(view.diagnostics.open === model, """
            the connection dropping is the reason the panel is open. Closing it here is the \
            one moment the measurement was worth most.
            """)

        await stopAndAwait(model)
    }

    /// The composition the name of the test above only claims: teardown stops
    /// the run AND the rows it had measured are still there.
    ///
    /// `tearingDownTheDiagnosedTabStopsTheRunAndKeepsTheRows` asserts that the
    /// PANEL survives, and its fake emits nothing, so `steps` is empty
    /// throughout and a `stopRun` that "tidied up" by clearing the rows would
    /// pass it on its name. The rows-survive-a-cancel property is proved at
    /// the model (`cancellingKeepsTheRowsAlreadyMeasured`); this is the only
    /// place the two are composed.
    @Test func tearingDownTheDiagnosedTabLeavesTheMeasuredRowsOnScreen() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        let emitted = [Self.step(id: DiagnosticStepID.resolve), Self.step(id: DiagnosticStepID.tcp)]
        let (parked, model) = await presentRunningPanel(on: view, for: tab, emitting: emitted)
        #expect(model.steps.count == emitted.count, "the rows are on screen before the act")
        #expect(parked.wasCancelled == false)

        await view.teardown(tab, reason: .userRequested)

        // Read while the runner is still parked, so nothing has healed: the
        // walk cannot have finished and re-published these rows.
        #expect(model.steps.map(\.id) == emitted.map(\.id), """
            the measurement survives the teardown that stopped it — it is what the panel was \
            opened for, and there is no way back to it except re-dialling.
            """)
        #expect(parked.wasCancelled)
        #expect(view.diagnostics.open === model)

        await stopAndAwait(model)
    }

    /// A different tab's teardown touches neither the run nor the panel.
    @Test func tearingDownAnUnrelatedTabLeavesTheDiagnosisAlone() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let diagnosed = makeTab()
        let unrelated = makeTab()
        let (parked, model) = await presentRunningPanel(on: view, for: diagnosed)

        await view.teardown(unrelated, reason: .userRequested)

        #expect(parked.wasCancelled == false, """
            closing one connection must not stop the diagnosis of another — before this, \
            `performCloseOthers` and the reconnect-in-place branch both did.
            """)
        #expect(view.diagnostics.open != nil)

        await stopAndAwait(model)
    }

    /// A panel opened from the sidebar belongs to no tab, so no teardown may
    /// claim it.
    @Test func aPanelOpenedFromNoTabSurvivesEveryTeardown() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let (parked, model) = await presentRunningPanel(on: view)

        await view.teardown(makeTab(), reason: .userRequested)

        #expect(parked.wasCancelled == false)
        #expect(view.diagnostics.open != nil)

        await stopAndAwait(model)
    }

    /// The presenter never leaves an older run walking behind a newer panel:
    /// asking a second time stops the first.
    @Test func openingASecondPanelCancelsTheFirstRun() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let (first, firstModel) = await presentRunningPanel(on: view)

        let second = ParkedRun()
        view.diagnostics.present(
            DiagnosticsViewModel(name: "Another session", runner: second.runner()), for: nil)

        #expect(first.wasCancelled, """
            a panel replaced without being dismissed leaves its run with nothing on screen to \
            stop it — the presenter has to.
            """)
        #expect(second.wasCancelled == false, "the new panel's own run is untouched")

        // Only the first has a task: the replacement panel's run is never
        // started, which is what `second.wasCancelled == false` above rests
        // on. `stopAndAwait` joins the one the presenter cancelled.
        await stopAndAwait(firstModel)
    }
}

/// A `SecretStore` that stores nothing and answers nothing — the window under
/// test must never reach the real Keychain.
private struct InertSecretStore: SecretStore {
    func savePassword(_ password: String, for id: UUID) throws {}
    func password(for id: UUID) throws -> String? { nil }
    func deletePassword(for id: UUID) throws {}
}
