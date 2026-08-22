import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the property no source-text scan can: that
/// `ContentView.handleLivenessGiveUp(_:)` — the real function
/// `LivenessProbeRunner`'s `.giveUp` case calls, not a reimplementation of
/// it — actually leaves a tab `.lost` after tearing its session down, not
/// merely that its source SPELLS "teardown" and "`.lost`" somewhere inside
/// it. A prior round's guard checked exactly that spelling; a reviewer
/// swapped the function's two statements and it still passed, because a
/// scan cannot see which one ran first. This drives the REAL
/// `ContentView.teardown(_:)` end to end (bridge dismiss, queue
/// `cancelAll`, edit-manager `stopAll`, terminal `shutdown`, remote
/// `disconnect`, all the way down) through the actual give-up entry point,
/// the same shape a prior round's reviewer used to catch the original
/// ordering bug.
///
/// Isolation (connection-liveness plan, Task 6 fix round 2, review item 3):
/// `makeContentView()` below constructs a real `ContentView`, the same
/// shape `ConnectAttemptHandoffTests` uses — see that file's own top-level
/// doc comment for the incident that made this suite's own isolation worth
/// checking rather than assumed. Reading `teardown(_:)`'s full body (the
/// only thing `handleLivenessGiveUp(_:)` calls beyond a plain property
/// write) shows it never touches `sessionListViewModel` or any
/// `SecretStore` — this suite's own path genuinely does not reach the real
/// Keychain or the real session store today. It is still built with the
/// SAME temp-directory/in-memory-secrets seam `ConnectAttemptHandoffTests`
/// uses (`ContentView.init`'s `sessionListViewModel:` parameter), and
/// `theRealSessionsFileIsNeverTouched` below proves it empirically rather
/// than resting on "the code doesn't call it today" — the property that
/// matters is that a FUTURE change to `teardown(_:)` cannot silently start
/// writing to a developer's real data through this suite without the proof
/// below catching it, not that today's code happens not to.
@Suite("Liveness give-up ordering")
@MainActor
struct LivenessGiveUpOrderingTests {
    private static var realSessionsFileURL: URL {
        SessionStore.defaultDirectory.appendingPathComponent("sessions-v2.json")
    }

    /// Read as raw bytes, not parsed — see `ConnectAttemptHandoffTests
    /// .snapshotRealSessionsFile()` for why a byte-for-byte comparison
    /// (including "the file does not exist, in both snapshots") is the
    /// right shape here.
    private func snapshotRealSessionsFile() -> Data? {
        try? Data(contentsOf: Self.realSessionsFileURL)
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    /// The same minimal, `ContentView.init`-shaped fixture a window would
    /// hand it — no live window or rendering involved; `body` is never
    /// called, only the plain `handleLivenessGiveUp(_:)` method. Isolated
    /// via `ContentView.init`'s `sessionListViewModel:` seam even though
    /// this suite's own call path does not reach it — see this file's own
    /// top-level doc comment.
    private func makeContentView() -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let workDir = makeTempDirectory("sessions")
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: workDir),
            secrets: NoOpSecretStore(),
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
            sessionListViewModel: sessionListViewModel)
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
            try? FileManager.default.removeItem(at: workDir)
        })
    }

    /// Same shape as `SessionTabTests.makeTab()`.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Same shape as `SessionTabTests.attachSession(to:)`.
    private func attachSession(to tab: SessionTab) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        tab.liveness = .degraded
    }

    @Test func givingUpLeavesTheTabLostWithNoSession() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)

        await view.handleLivenessGiveUp(tab)

        #expect(tab.session == nil)
        #expect(tab.liveness == .lost)
    }

    /// Demonstrated, not just asserted by construction — same reasoning as
    /// `ConnectAttemptHandoffTests.theRealSessionsFileIsNeverTouched`, whose
    /// own doc comment explains why a snapshot comparison is the standard
    /// this branch now holds any test that builds a real `ContentView` to.
    @Test func theRealSessionsFileIsNeverTouched() async {
        let before = snapshotRealSessionsFile()
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)

        await view.handleLivenessGiveUp(tab)

        let after = snapshotRealSessionsFile()
        #expect(before == after, """
            the real on-disk session store changed while this suite ran. \
            `before` had \(before?.count.description ?? "no file"), \
            `after` had \(after?.count.description ?? "no file").
            """)
    }
}

/// Test double for `SecretStore`, local to this file for the same reason
/// `ConnectAttemptHandoffTests`' own `RecordingSecretStore` is (`macSCPAppKitTests`
/// does not depend on `macSCPCoreTests`, so `Tests/macSCPCoreTests
/// /InMemorySecretStore.swift` is not importable here). No recording
/// needed here — this suite's own path never calls it (see this file's
/// top-level doc comment) — so a bare no-op is enough; its only job is to
/// not be `KeychainSecretStore`.
private struct NoOpSecretStore: SecretStore {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? { nil }
    func deletePassword(for sessionID: UUID) throws {}
}
