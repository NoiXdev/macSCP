import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("CrossSessionTargets")
@MainActor
struct CrossSessionTargetsTests {
    /// Builds a tab with the same collaborators `ContentView` hands it — the
    /// same helper shape as `SessionTabTests.makeTab()`.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: none of these tests connects.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Attaches a live session to `tab`, the same shape `ContentView.
    /// startSession(in:with:)` builds, but using `LocalFileSystem` as the
    /// "remote" side — a real `RemoteFileSystem` conformer that needs no
    /// network and never has its I/O methods called by
    /// `CrossSessionTargets.targets`, which only reads `remote.currentPath`
    /// (set synchronously by `RemoteBrowserViewModel.init`).
    private func attachSession(to tab: SessionTab, remotePath: String) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: remotePath),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue))
    }

    /// A tab never offers itself as a transfer destination — "copy to
    /// here" through the cross-session path would enqueue a job whose
    /// source and destination are the same remote.
    @Test func aTabIsNotOfferedAsItsOwnTarget() {
        let mine = makeTab()
        attachSession(to: mine, remotePath: "/home/mine")
        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine])

        #expect(targets.isEmpty)
    }

    /// A tab that is not connected has no remote to receive anything, so it
    /// is skipped rather than offered as a target that silently does
    /// nothing when clicked.
    @Test func aTabWithoutASessionIsSkipped() {
        let mine = makeTab()
        let other = makeTab()
        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine, other])

        #expect(targets.isEmpty)
    }

    /// A connected OTHER tab IS offered, carrying its own id, display title,
    /// current remote path and connection kind through unchanged. This is
    /// the positive case the two empty-result tests above cannot prove: a
    /// `targets` that always returned `[]` would pass both of them too.
    @Test func aConnectedOtherTabIsOfferedAsATarget() {
        let mine = makeTab()
        let other = makeTab()
        other.titleName = "prod-web"
        other.connectionViewModel.kind = .s3
        attachSession(to: other, remotePath: "/var/www")

        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine, other])

        #expect(targets.count == 1)
        #expect(targets.first?.id == other.id)
        #expect(targets.first?.title == "prod-web")
        #expect(targets.first?.remotePath == "/var/www")
        #expect(targets.first?.kind == .s3)
    }
}
