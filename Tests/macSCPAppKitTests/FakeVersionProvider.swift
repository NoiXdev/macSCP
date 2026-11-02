import Foundation
import Synchronization
import macSCPCore

/// An in-memory `ObjectVersionProvider` for the sheets that read a history.
///
/// It answers `versions(ofKey:inBucket:)` and nothing else: the five other
/// requirements throw `RemoteFSError.finding(.operationNotSupported)`, so a
/// sheet that reached for a write it was not given fails loudly instead of
/// reading a made-up answer. The listing is returned in the order it was
/// given, so a test that needs the model to sort can hand it a shuffled one.
///
/// No wait, no sleep: every method answers at once.
final class FakeVersionProvider: ObjectVersionProvider, Sendable {
    /// One `versions(ofKey:inBucket:)` call, as it arrived.
    struct Listing: Equatable, Sendable {
        let key: String
        let bucket: String
    }

    private struct State {
        var versions: [ObjectVersion]
        var error: (any Error)?
        var listings: [Listing] = []
    }

    private let state: Mutex<State>

    init(versions: [ObjectVersion] = [], error: (any Error)? = nil) {
        state = Mutex(State(versions: versions, error: error))
    }

    /// The listings asked for, in order.
    var listings: [Listing] { state.withLock { $0.listings } }

    private static var unsupported: RemoteFSError { .finding(.operationNotSupported) }

    func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion] {
        try state.withLock { state in
            state.listings.append(Listing(key: key, bucket: bucket))
            if let error = state.error { throw error }
            return state.versions
        }
    }

    func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry] {
        throw Self.unsupported
    }

    func readStream(
        ofKey key: String, inBucket bucket: String, versionId: String
    ) async throws -> AsyncThrowingStream<Data, Error> {
        throw Self.unsupported
    }

    func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws {
        throw Self.unsupported
    }

    func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws {
        throw Self.unsupported
    }

    func liftDeleteMarker(ofKey key: String, inBucket bucket: String, markerVersionId: String) async throws {
        throw Self.unsupported
    }
}
