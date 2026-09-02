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
    /// startSession(in:with:)` builds, defaulting to `LocalFileSystem` as the
    /// "remote" side — a real `RemoteFileSystem` conformer that needs no
    /// network and never has its I/O methods called by
    /// `CrossSessionTargets.targets`, which reads `remote.currentPath` (set
    /// synchronously by `RemoteBrowserViewModel.init`) and
    /// `remoteFS.rootIsContainerList` (a stored answer, no I/O).
    ///
    /// `remoteFS` is a parameter since fix round 1 of the bucket-list task:
    /// the third rule needs a remote whose root IS a container list, and
    /// `LocalFileSystem` takes the protocol default and can never say so.
    private func attachSession(
        to tab: SessionTab, remotePath: String, remoteFS: any RemoteFileSystem = LocalFileSystem()
    ) {
        let sessionID = UUID()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: remotePath),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: remotePath)
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

    /// A tab whose remote pane sits at a BUCKET LIST is not offered either
    /// (review C-1): nothing can be written there, so a cross-session
    /// transfer aimed at it would be enqueued and then refused by Core
    /// (`bucketLevelRefused`) — the "offered and then refused" shape this
    /// task closed at every other door.
    ///
    /// The destination question is the same function every other door asks,
    /// `BrowserScope.acceptsIncomingFiles`; this is simply the one place
    /// each target's OWN destination is known.
    @Test func aTabSittingAtItsBucketListIsNotOfferedAsATarget() {
        let mine = makeTab()
        let other = makeTab()
        attachSession(to: other, remotePath: "/", remoteFS: BucketListFileSystem())

        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine, other])

        #expect(targets.isEmpty)
    }

    /// The positive check beside it, and the one that proves the filter is
    /// about the DIRECTORY and not about the backend: the very same
    /// bucket-list connection, one level inside a bucket, IS offered.
    @Test func theSameBucketListTabIsOfferedOnceItIsInsideABucket() {
        let mine = makeTab()
        let other = makeTab()
        attachSession(to: other, remotePath: "/macscp-seed", remoteFS: BucketListFileSystem())

        let targets = CrossSessionTargets.targets(excluding: mine.id, in: [mine, other])

        #expect(targets.count == 1)
        #expect(targets.first?.remotePath == "/macscp-seed")
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

/// A remote whose ROOT lists containers — what `S3FileSystem` is with
/// "Start at the bucket list" on. Only `rootIsContainerList` is answered;
/// `CrossSessionTargets.targets` calls nothing else, and a `fatalError`
/// everywhere else is what says so.
private struct BucketListFileSystem: RemoteFileSystem {
    var rootIsContainerList: Bool { true }

    func list(path: String) async throws -> [RemoteFileItem] {
        fatalError("not exercised by this test")
    }
    func stat(path: String) async throws -> RemoteFileItem {
        fatalError("not exercised by this test")
    }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("not exercised by this test")
    }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        fatalError("not exercised by this test")
    }
    func delete(path: String) async throws { fatalError("not exercised by this test") }
    func createDirectory(at path: String) async throws { fatalError("not exercised by this test") }
    func rename(from: String, to: String) async throws { fatalError("not exercised by this test") }
    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }
    func deleteTree(at path: String) async throws { fatalError("not exercised by this test") }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}
