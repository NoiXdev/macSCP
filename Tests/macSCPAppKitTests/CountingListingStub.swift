import Foundation
import Synchronization
import macSCPCore

/// The one stub that counts the requests a pane makes (S3 version history,
/// Task 10): plain listings, deleted-key listings and marker removals, in one
/// place, so that the tests that say "no request was made" and the tests that
/// say "this many were" read the SAME counters.
///
/// **A count of zero means something only beside a count that is not zero.**
/// A stub nobody reached reads zero exactly as a stub that was reached and
/// correctly not asked reads zero, so every suite that asserts a zero from
/// these counters also asserts, on the same stub, a listing it counted.
final class ListingCounters: Sendable {
    struct DeletedListing: Equatable, Sendable {
        let bucket: String
        let prefix: String
    }

    struct Lift: Equatable, Sendable {
        let key: String
        let bucket: String
        let markerVersionId: String
    }

    private struct State {
        var plain: [String] = []
        var deleted: [DeletedListing] = []
        var lifts: [Lift] = []
        var versionHistoryReads = 0
        var deletedByPrefix: [String: [DeletedEntry]] = [:]
        var deletedError: (any Error)?
        var liftError: (any Error)?
    }

    private let state = Mutex(State())

    /// The directories listed the ordinary way, in order.
    var plain: [String] { state.withLock { $0.plain } }
    /// The deleted-key listings asked for, in order.
    var deleted: [DeletedListing] { state.withLock { $0.deleted } }
    /// The marker removals asked for, in order, whatever each answered.
    var lifts: [Lift] { state.withLock { $0.lifts } }
    /// The per-key history reads (`versions(ofKey:inBucket:)`) asked for.
    var versionHistoryReads: Int { state.withLock { $0.versionHistoryReads } }

    /// The deleted entries a listing under `prefix` answers.
    func setDeleted(_ entries: [DeletedEntry], underPrefix prefix: String) {
        state.withLock { $0.deletedByPrefix[prefix] = entries }
    }

    func setDeletedError(_ error: (any Error)?) { state.withLock { $0.deletedError = error } }
    func setLiftError(_ error: (any Error)?) { state.withLock { $0.liftError = error } }

    func recordPlain(_ path: String) { state.withLock { $0.plain.append(path) } }

    func recordDeleted(bucket: String, prefix: String) throws -> [DeletedEntry] {
        try state.withLock { state in
            state.deleted.append(DeletedListing(bucket: bucket, prefix: prefix))
            if let error = state.deletedError { throw error }
            return state.deletedByPrefix[prefix] ?? []
        }
    }

    func recordLift(key: String, bucket: String, markerVersionId: String) throws {
        try state.withLock { state in
            state.lifts.append(Lift(key: key, bucket: bucket, markerVersionId: markerVersionId))
            if let error = state.liftError { throw error }
        }
    }

    func recordHistoryRead() { state.withLock { $0.versionHistoryReads += 1 } }
}

/// A file system that lists a fixed tree and counts every listing. It keeps no
/// history: it stands for a local pane's file system and for a backend that
/// does not version, the two panes the switch has nothing to do for.
final class PlainListingFS: RemoteFileSystem, Sendable {
    let counters: ListingCounters
    let tree: [String: [RemoteFileItem]]
    let rootIsContainerList: Bool

    init(counters: ListingCounters, tree: [String: [RemoteFileItem]], rootIsContainerList: Bool = false) {
        self.counters = counters
        self.tree = tree
        self.rootIsContainerList = rootIsContainerList
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        counters.recordPlain(path)
        return tree[path] ?? []
    }

    func stat(path: String) async throws -> RemoteFileItem {
        throw RemoteFSError.notFound(path: path)
    }

    func readStream(path: String, fromOffset offset: UInt64) async throws
        -> AsyncThrowingStream<Data, Error>
    { throw RemoteFSError.notFound(path: path) }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
    func delete(path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(path: String, permissions: UInt32) async throws {}
    func deleteTree(at path: String) async throws {}
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}

/// The same file system with a version history, standing where an S3 session's
/// remote stands. Its listings and its history requests go to the SAME
/// `ListingCounters` as `PlainListingFS`'s.
final class HistoryListingFS: RemoteFileSystem, ObjectVersionProvider, Sendable {
    let base: PlainListingFS
    var counters: ListingCounters { base.counters }
    var rootIsContainerList: Bool { base.rootIsContainerList }

    init(counters: ListingCounters, tree: [String: [RemoteFileItem]], rootIsContainerList: Bool = false) {
        base = PlainListingFS(counters: counters, tree: tree, rootIsContainerList: rootIsContainerList)
    }

    func list(path: String) async throws -> [RemoteFileItem] { try await base.list(path: path) }
    func stat(path: String) async throws -> RemoteFileItem { try await base.stat(path: path) }
    func readStream(path: String, fromOffset offset: UInt64) async throws
        -> AsyncThrowingStream<Data, Error>
    { try await base.readStream(path: path, fromOffset: offset) }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
    func delete(path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(path: String, permissions: UInt32) async throws {}
    func deleteTree(at path: String) async throws {}
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}

    func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion] {
        counters.recordHistoryRead()
        return []
    }

    func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry] {
        try counters.recordDeleted(bucket: bucket, prefix: prefix)
    }

    func readStream(
        ofKey key: String, inBucket bucket: String, versionId: String
    ) async throws -> AsyncThrowingStream<Data, Error> {
        throw RemoteFSError.finding(.operationNotSupported)
    }

    func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws {
        throw RemoteFSError.finding(.operationNotSupported)
    }

    func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws {
        throw RemoteFSError.finding(.operationNotSupported)
    }

    func liftDeleteMarker(
        ofKey key: String, inBucket bucket: String, markerVersionId: String
    ) async throws {
        try counters.recordLift(key: key, bucket: bucket, markerVersionId: markerVersionId)
    }
}
