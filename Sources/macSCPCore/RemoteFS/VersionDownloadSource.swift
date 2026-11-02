import Foundation

/// One version of one object, presented to `TransferEngine` as a file system
/// of exactly one file, so a version download runs through the transfer queue
/// like any other: its progress row, its bandwidth pacing, its cancel and its
/// failure classification are the queue's own and not a second copy of them.
///
/// **A version download cannot resume, and this type is where that is
/// decided.** The capability read, `ObjectVersionProvider.readStream(ofKey:
/// inBucket:versionId:)`, has no offset, and the offset a resume needs has
/// nowhere to come from. The queue would otherwise offer one: a connection
/// lost mid-download to a disk that can append is retained as `.interrupted`,
/// and `retryInterrupted` hands the retained job the tab's OWN file systems.
/// For a version that would put the tab's remote in this type's place with a
/// path naming the key, so the resumed read would fetch the key's CURRENT
/// content and append its tail to the partial file of an old version: a file
/// of the right length and the wrong bytes, which nothing downstream can
/// notice. Two things close it:
/// - `TransferQueueViewModel` classifies a lost connection on a version
///   download as `.failed(.interrupted)` and retains no job, so
///   `retryInterrupted` never meets one (the version download's `Job` flag,
///   `isVersionDownload`);
/// - this type refuses any offset above zero (`resumeRefusedReason`), so a
///   path that reached it with one anyway would stop here, with the partial
///   file as it was, rather than restart from zero under a resume label.
///
/// No validator is read or sent (`entityTag` stays the protocol's `nil`): a
/// version id names immutable content, so there is no "the object changed
/// since" to check.
///
/// Everything a transfer's source does not do refuses, so a caller that used
/// this as anything but a source would find out at once. It is never a
/// destination, so it inherits `supportsAppendResume`'s default without
/// answering for it, as `ThroughputPayload` does
/// (`RemoteFileSystemAppendResumeGuardTests` lists both).
struct VersionDownloadSource: RemoteFileSystem {
    /// Why a read from anywhere but the start was refused.
    static let resumeRefusedReason =
        "a version download cannot be resumed: start it again from the beginning"
    /// Why a delete marker was refused as a download: it holds no content.
    static let markerReason = "this version is a delete marker and has no content to download"
    private static let refusalReason = "a version download source reads one version and nothing else"

    let source: any ObjectVersionProvider
    let bucket: String
    let key: String
    let versionId: String

    init(source: any ObjectVersionProvider, bucket: String, key: String, versionId: String) {
        self.source = source
        self.bucket = bucket
        self.key = key
        self.versionId = versionId
    }

    /// What the queue shows for the source side of the row.
    var displayPath: String { "/" + bucket + "/" + key }

    /// The version's entry in the key's history: its size for the progress
    /// bar, and the check that the id names content before anything is read.
    /// An id the history does not hold is `.notFound`, as for the write half
    /// (`/bucket/key`); a delete marker is refused, since reading its id is a
    /// request no store answers with bytes.
    func stat(path: String) async throws -> RemoteFileItem {
        let history = try await source.versions(ofKey: key, inBucket: bucket)
        guard let entry = history.first(where: { $0.versionId == versionId }) else {
            throw RemoteFSError.notFound(path: displayPath)
        }
        guard !entry.isDeleteMarker else {
            throw RemoteFSError.protocolError(reason: Self.markerReason)
        }
        let name = key.split(separator: "/").last.map(String.init) ?? key
        return RemoteFileItem(
            name: name, path: displayPath, kind: .file, size: entry.size,
            modifiedAt: entry.modifiedAt)
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard offset == 0 else {
            throw RemoteFSError.protocolError(reason: Self.resumeRefusedReason)
        }
        return try await source.readStream(ofKey: key, inBucket: bucket, versionId: versionId)
    }

    func list(path: String) async throws -> [RemoteFileItem] { throw Self.refusal }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws { throw Self.refusal }
    func delete(path: String) async throws { throw Self.refusal }
    func createDirectory(at path: String) async throws { throw Self.refusal }
    func rename(from: String, to: String) async throws { throw Self.refusal }
    func setPermissions(path: String, permissions: UInt32) async throws { throw Self.refusal }
    func deleteTree(at path: String) async throws { throw Self.refusal }
    func homeDirectoryPath() async throws -> String { "/" }
    /// The provider belongs to the tab's connection, which owns its
    /// lifecycle; a download's source must not close it.
    func disconnect() async {}

    private static let refusal = RemoteFSError.protocolError(reason: refusalReason)
}
