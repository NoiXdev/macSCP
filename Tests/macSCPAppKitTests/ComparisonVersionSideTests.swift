import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// "Compare with Current Version": a `.filePair` comparison whose LEFT side is
/// a version of the object and whose right side is the object as it is now.
///
/// The properties held here, each beside the control that makes it mean
/// something:
///
/// 1. the version is fetched THROUGH THE VERSION CAPABILITY, and the left file
///    system (the tab's own, in production) is never asked for anything, so a
///    comparison cannot be handed the key's current content under an old
///    version's name;
/// 2. the version's transfer is one the queue cannot resume;
/// 3. a version that is not there, or is a delete marker, is refused with the
///    store's own kind of answer and nothing is fetched;
/// 4. the side is let go with the file systems;
/// 5. the request that asks for it names the sides and the version and leaves
///    the connection to the tab.
///
/// No test here asserts how long anything took.
@Suite("Comparison with a version", .timeLimit(.minutes(5)))
@MainActor
struct ComparisonVersionSideTests {
    private struct Rig {
        let comparison: Comparison
        let provider: FakeVersionProvider
        /// The file system standing where the tab's remote stands: it must
        /// never be read for the left side.
        let left: MemoryFS
        let right: MemoryFS
        let queue: TransferQueueViewModel
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonVersionSideTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func version(
        _ id: String, marker: Bool = false, latest: Bool = false, size: UInt64 = 4
    ) -> ObjectVersion {
        ObjectVersion(
            versionId: id, key: "docs/a.txt", isLatest: latest, isDeleteMarker: marker,
            size: marker ? nil : size, modifiedAt: nil, entityTag: nil)
    }

    private func makeRig(
        history: [ObjectVersion], contents: [String: Data], current: Data, root: URL
    ) -> Rig {
        let provider = FakeVersionProvider(versions: history, contents: contents)
        // Where the plain read of the key would land: the CURRENT content,
        // which a wrong route would hand over as the left side.
        let left = MemoryFS(files: ["/b/docs/a.txt": current])
        let right = MemoryFS(files: ["/b/docs/a.txt": current])
        let queue = TransferQueueViewModel()
        let comparison = Comparison(
            left: left, leftRoot: "/b/docs/a (v1).txt", right: right, rightRoot: "/b/docs/a.txt",
            algorithm: .sha256, transferQueue: queue, kind: .filePair,
            versionSide: .init(
                reference: .init(bucket: "b", key: "docs/a.txt", versionId: "v1"),
                source: provider),
            temporaryRoot: root)
        return Rig(comparison: comparison, provider: provider, left: left, right: right, queue: queue)
    }

    private func hunks(_ result: Result<[DiffHunk], DiffRefusal>) -> [DiffHunk]? {
        if case .success(let hunks) = result { return hunks }
        return nil
    }

    @Test func theVersionIsReadThroughTheVersionCapabilityAndNotThroughTheLeftFileSystem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeRig(
            history: [Self.version("v1"), Self.version("v2", latest: true)],
            contents: ["v1": Data("a\nb\n".utf8)], current: Data("a\nc\n".utf8), root: root)

        let result = try await rig.comparison.diffFilePair()

        // The positive: the diff is between the OLD content and the current
        // one, line for line.
        let shown = try #require(hunks(result))
        let lines = shown.flatMap(\.lines)
        #expect(lines.contains { $0.kind == .removed && $0.text == "b" })
        #expect(lines.contains { $0.kind == .added && $0.text == "c" })
        #expect(rig.provider.readVersionIds == ["v1"])
        #expect(rig.right.reads == ["/b/docs/a.txt"])
        // The negative, beside it: the left file system saw no request at all,
        // not a stat and not a read.
        #expect(rig.left.reads.isEmpty)
        #expect(rig.left.statCalls == 0)
        // Every byte went through the queue, as one version download that
        // cannot resume.
        let downloads = rig.queue.items.filter { $0.direction == .download }
        #expect(downloads.count == 2)
        // Exactly one of the two is the version's: the one the queue cannot
        // resume. The other, an ordinary download to a local disk, can be, so
        // the count tells the two apart (and is red if both look alike).
        #expect(downloads.filter { !$0.canResumeIfInterrupted }.count == 1)
        #expect(downloads.filter { $0.canResumeIfInterrupted }.count == 1)
    }

    /// A version the history does not hold, and a delete marker, are refused
    /// before a byte is fetched.
    @Test func aMissingVersionAndADeleteMarkerAreRefusedBeforeAnythingIsFetched() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = makeRig(
            history: [Self.version("v2", latest: true)], contents: ["v1": Data("x".utf8)],
            current: Data("y".utf8), root: root)
        await #expect(throws: RemoteFSError.self) { try await missing.comparison.diffFilePair() }
        #expect(missing.provider.readVersionIds.isEmpty)
        #expect(missing.left.statCalls == 0)

        let marker = makeRig(
            history: [Self.version("v1", marker: true), Self.version("v2", latest: true)],
            contents: ["v1": Data("x".utf8)], current: Data("y".utf8), root: root)
        await #expect(throws: RemoteFSError.self) { try await marker.comparison.diffFilePair() }
        #expect(marker.provider.readVersionIds.isEmpty)

        // The positive: the same shape with a real version reads it.
        let real = makeRig(
            history: [Self.version("v1"), Self.version("v2", latest: true)],
            contents: ["v1": Data("x".utf8)], current: Data("y".utf8), root: root)
        _ = try await real.comparison.diffFilePair()
        #expect(real.provider.readVersionIds == ["v1"])
    }

    @Test func theVersionSideIsLetGoWithTheFileSystems() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = makeRig(
            history: [Self.version("v1")], contents: [:], current: Data(), root: root)
        #expect(rig.comparison.versionSide?.reference.versionId == "v1")
        #expect(rig.comparison.fileSystems != nil)
        rig.comparison.releaseFileSystems()
        #expect(rig.comparison.versionSide == nil)
        #expect(rig.comparison.fileSystems == nil)
    }

    // MARK: - The tab resolves the version against its own session

    /// A file system that also keeps a version history, standing where a
    /// session's remote stands.
    private struct VersionedFS: RemoteFileSystem, ObjectVersionProvider {
        let files: MemoryFS
        let history: FakeVersionProvider

        func list(path: String) async throws -> [RemoteFileItem] { try await files.list(path: path) }
        func stat(path: String) async throws -> RemoteFileItem { try await files.stat(path: path) }
        func readStream(path: String, fromOffset offset: UInt64) async throws
            -> AsyncThrowingStream<Data, Error>
        { try await files.readStream(path: path, fromOffset: offset) }
        func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
        func delete(path: String) async throws {}
        func createDirectory(at path: String) async throws {}
        func rename(from: String, to: String) async throws {}
        func setPermissions(path: String, permissions: UInt32) async throws {}
        func deleteTree(at path: String) async throws {}
        func homeDirectoryPath() async throws -> String { "/" }
        func disconnect() async {}

        func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion] {
            try await history.versions(ofKey: key, inBucket: bucket)
        }
        func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry] {
            try await history.deletedEntries(inBucket: bucket, prefix: prefix)
        }
        func readStream(
            ofKey key: String, inBucket bucket: String, versionId: String
        ) async throws -> AsyncThrowingStream<Data, Error> {
            try await history.readStream(ofKey: key, inBucket: bucket, versionId: versionId)
        }
        func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws {}
        func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws {}
        func liftDeleteMarker(
            ofKey key: String, inBucket bucket: String, markerVersionId: String
        ) async throws {}
    }

    private func connectedTab(remote: any RemoteFileSystem) -> SessionTab {
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in throw CancellationError() }),
            certificateBridge: CertificatePromptBridge(), limiter: BandwidthLimiter(),
            maxConcurrent: 2)
        let sessionID = UUID()
        tab.session = BrowserSession(
            id: sessionID, localFS: LocalFileSystem(), remoteFS: remote,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remote, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in throw CancellationError() }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        return tab
    }

    /// The request carries ids; the tab turns them into a side over ITS
    /// session. A remote that keeps no history starts nothing, and an ordinary
    /// comparison on the same tab starts as it always did.
    @Test func theTabResolvesTheVersionAgainstItsOwnSessionOrStartsNothing() {
        let reference = Comparison.VersionRef(bucket: "b", key: "docs/a.txt", versionId: "v1")
        let capable = connectedTab(
            remote: VersionedFS(
                files: MemoryFS(files: [:]), history: FakeVersionProvider()))
        let started = capable.startComparison(
            left: .remote, leftRoot: "/b/docs/a (v1).txt", right: .remote,
            rightRoot: "/b/docs/a.txt", algorithm: .sha256, kind: .filePair,
            leftVersion: reference)
        #expect(started?.versionSide?.reference == reference)
        #expect(capable.comparisons.count == 1)

        let plain = connectedTab(remote: MemoryFS(files: [:]))
        let refused = plain.startComparison(
            left: .remote, leftRoot: "/x", right: .remote, rightRoot: "/y",
            algorithm: .sha256, kind: .filePair, leftVersion: reference)
        #expect(refused == nil)
        #expect(plain.comparisons.isEmpty)
        // The positive beside the refusal: the same tab compares ordinarily.
        let ordinary = plain.startComparison(
            left: .remote, leftRoot: "/x", right: .remote, rightRoot: "/y",
            algorithm: .sha256, kind: .filePair)
        #expect(ordinary != nil)
        #expect(ordinary?.versionSide == nil)

        for tab in [capable, plain] { tab.endComparisons() }
    }

    // MARK: - The request

    @Test func theRequestNamesTheVersionAndTheCurrentPathAndCarriesNoConnection() {
        let request = ComparisonRequest.forVersion(
            bucket: "b", key: "docs/a.txt", versionId: "null", currentPath: "/b/docs/a.txt")
        #expect(request.kind == .filePair)
        #expect(request.leftVersion == .init(bucket: "b", key: "docs/a.txt", versionId: "null"))
        #expect(request.right == .remote)
        #expect(request.rightRoot == "/b/docs/a.txt")
        // The left label is the object's own place with the version folded
        // into the file name, so two versions read differently.
        #expect(request.leftRoot == "/b/docs/" + VersionLocalName.forDownload(fileName: "a.txt", versionId: "null"))
        let other = ComparisonRequest.forVersion(
            bucket: "b", key: "docs/a.txt", versionId: "v7", currentPath: "/b/docs/a.txt")
        #expect(other.leftRoot != request.leftRoot)
        // The positive beside the factories that predate it: they carry no
        // version.
        let pair = ComparisonRequest.forTwoSelected(
            [
                RemoteFileItem(name: "x", path: "/x", kind: .file),
                RemoteFileItem(name: "y", path: "/y", kind: .file),
            ], on: .local)
        #expect(pair?.leftVersion == nil)
    }
}
