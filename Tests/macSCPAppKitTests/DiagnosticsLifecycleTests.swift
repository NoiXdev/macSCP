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
/// `withTaskCancellationHandler`. Both tests read that record while the
/// runner is still parked — before `runTask` is awaited, before the model
/// publishes anything — so neither can pass on the strength of a run that
/// finished by itself. CLAUDE.md, "A check that reads after the healing is
/// not a check".
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

    /// A runner that never finishes on its own and notes the moment it is
    /// cancelled.
    ///
    /// `onCancel` runs synchronously on the thread that calls
    /// `Task.cancel()`, so `wasCancelled` is true by the time the call that
    /// cancelled it returns — which is what lets both tests read it before
    /// the runner has had any chance to heal.
    private final class ParkedRun: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var started = false

        var wasCancelled: Bool { lock.withLock { cancelled } }
        var hasStarted: Bool { lock.withLock { started } }

        func runner() -> DiagnosticsViewModel.Runner {
            { [self] in
                await withTaskCancellationHandler {
                    lock.withLock { started = true }
                    // Never returns of its own accord within any run of this
                    // suite; a working cancel returns it at once. The number
                    // is a park, not a deadline anything here asserts on.
                    try? await Task.sleep(for: .seconds(600))
                    return DiagnosticReport(
                        endpoint: Endpoint(host: "example.test", port: 22), steps: [],
                        appVersion: "0.0.0-test")
                } onCancel: {
                    lock.withLock { cancelled = true }
                }
            }
        }
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
    /// was cancelled.
    ///
    /// Goes through the presenter rather than `showDiagnostics(for:)` on
    /// purpose: that entry builds the REAL `ConnectionDiagnostics`, which
    /// would resolve a name and open sockets. What is under test here is the
    /// lifecycle, not the probes.
    private func presentRunningPanel(on view: ContentView) async -> ParkedRun {
        let parked = ParkedRun()
        let model = DiagnosticsViewModel(name: "Test session", runner: parked.runner())
        view.diagnostics.present(model)
        model.run()
        while !parked.hasStarted { await Task.yield() }
        return parked
    }

    // MARK: - The two paths

    /// Closing the sheet stops the diagnosis.
    @Test func dismissingThePanelCancelsTheRunningDiagnosis() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let parked = await presentRunningPanel(on: view)
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

    /// Tearing the tab down stops it too, and does not wait for the sheet's
    /// own disappearance to do it.
    ///
    /// Explicitly, rather than through the view lifecycle: clearing the
    /// presented panel dismisses the sheet, and SwiftUI decides when — and
    /// whether — `.onDisappear` runs. Leaning on that would be exactly the
    /// `deinit`-shaped cleanup CLAUDE.md's invariant forbids.
    @Test func tearingTheTabDownCancelsTheRunningDiagnosis() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        let parked = await presentRunningPanel(on: view)
        #expect(parked.wasCancelled == false)

        await view.teardown(tab, reason: .userRequested)

        #expect(parked.wasCancelled, """
            leaving a connection must stop the diagnosis of it. Closing the tab does not even \
            dismiss the sheet by itself, so without this the walk continues against a server \
            the window no longer has anything to do with.
            """)
        #expect(view.diagnostics.open == nil)
    }

    /// The presenter never leaves an older run walking behind a newer panel:
    /// asking a second time stops the first.
    @Test func openingASecondPanelCancelsTheFirstRun() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let first = await presentRunningPanel(on: view)

        let second = ParkedRun()
        view.diagnostics.present(
            DiagnosticsViewModel(name: "Another session", runner: second.runner()))

        #expect(first.wasCancelled, """
            a panel replaced without being dismissed leaves its run with nothing on screen to \
            stop it — the presenter has to.
            """)
        #expect(second.wasCancelled == false, "the new panel's own run is untouched")
    }
}

/// A `SecretStore` that stores nothing and answers nothing — the window under
/// test must never reach the real Keychain.
private struct InertSecretStore: SecretStore {
    func savePassword(_ password: String, for id: UUID) throws {}
    func password(for id: UUID) throws -> String? { nil }
    func deletePassword(for id: UUID) throws {}
}
