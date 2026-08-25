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

    /// Fix round 1: the property no test previously pinned. The Core suite's
    /// `cancelAllDueToConnectionLossFailsRunningAndKeepsQueuedListed` proves
    /// what `TransferQueueViewModel.cancelAll(reason:)` DOES for each
    /// reason; nothing proved that `handleLivenessGiveUp(_:)` actually
    /// PASSES `.connectionLost` rather than `.userRequested` at its one
    /// real call site — a reviewer flipping that single literal left the
    /// full suite green before this test existed. This drives the real
    /// give-up path with an item still in the queue and asserts the
    /// reason it reads afterward, so that flip cannot pass silently again.
    ///
    /// The item is enqueued synchronously, immediately before the
    /// (suspending) call to `handleLivenessGiveUp`, with NO `await` in
    /// between: `enqueue`'s own `kickWorker()` moves the job into
    /// `resolvingJobIDs` synchronously (a freshly created `Task`'s body
    /// cannot run until the CURRENTLY executing MainActor code reaches its
    /// own first suspension point), so the item is still non-terminal —
    /// and the bogus paths below are never actually read, since
    /// `cancelAll`'s synchronous "resolving" sweep marks the item terminal
    /// before `process` ever gets to open them — at the exact moment
    /// `teardown(_:reason:)` sweeps the queue. No real disk access happens
    /// either way, and no network is dialled.
    @Test func givingUpMarksQueuedTransfersConnectionLost() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)
        let session = tab.session!

        let itemID = tab.transferQueue.enqueue(
            fileName: "never-touched.txt", direction: .upload,
            source: session.localFS, sourcePath: "/does/not/exist.txt",
            destination: session.remoteFS, destinationDirectory: "/does/not/exist",
            onCompleted: nil)

        await view.handleLivenessGiveUp(tab)

        let item = tab.transferQueue.items.first { $0.id == itemID }
        let expectedReason = CoreL10n.string("core.transfer.connectionLost")
        #expect(item?.status == .failed(expectedReason), """
            expected the queued item to read .failed("\(expectedReason)") after a liveness \
            give-up, found \(String(describing: item?.status)) instead — \
            handleLivenessGiveUp(_:) must pass .connectionLost to teardown(_:reason:), not \
            .userRequested.
            """)
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
