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
@Suite("Liveness give-up ordering")
@MainActor
struct LivenessGiveUpOrderingTests {
    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    /// The same minimal, `ContentView.init`-shaped fixture a window would
    /// hand it — no live window or rendering involved; `body` is never
    /// called, only the plain `handleLivenessGiveUp(_:)` method.
    private func makeContentView() -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let view = ContentView(
            settingsStore: SettingsStore(directory: settingsDir),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel())
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
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
}
