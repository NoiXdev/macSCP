import Foundation
import Synchronization
import Testing
import macSCPCore

/// An in-memory `ObjectVersionProvider` for the sheets that read a history.
///
/// It answers `versions(ofKey:inBucket:)` and, unless told otherwise, nothing
/// else: the other requirements throw `RemoteFSError.finding(.operationNotSupported)`,
/// so a sheet that reached for a write it was not given fails loudly instead of
/// reading a made-up answer. **A write is recorded whatever it answers**
/// (`writes`), so a test can say that the store was not asked, and `writeAnswer`
/// opts a case in to a write that succeeds or one that throws something
/// specific. The listing is returned in the order it was given, so a test that
/// needs the model to sort can hand it a shuffled one.
///
/// No wait, no sleep: every method answers at once.
final class FakeVersionProvider: ObjectVersionProvider, Sendable {
    /// One `versions(ofKey:inBucket:)` call, as it arrived.
    struct Listing: Equatable, Sendable {
        let key: String
        let bucket: String
    }

    /// One restore, delete or marker removal, as it arrived.
    struct Write: Equatable, Sendable {
        enum Kind: Sendable { case restore, deleteVersion, liftDeleteMarker }
        let kind: Kind
        let key: String
        let bucket: String
        let versionId: String
    }

    /// What a write answers.
    enum WriteAnswer: Sendable {
        case unsupported
        case accepted
        case throwing(any Error)
    }

    private struct State {
        var versions: [ObjectVersion]
        var error: (any Error)?
        var listings: [Listing] = []
        var writes: [Write] = []
        var writeAnswer: WriteAnswer = .unsupported
        var contents: [String: Data] = [:]
        /// The listing (1-based) that waits at the store, and for what.
        var parked: (number: Int, entered: AsyncSignal, release: AsyncSignal)?
        var readVersionIds: [String] = []
    }

    private let state: Mutex<State>

    /// `contents` is what `readStream` answers, by version id; a version it
    /// does not hold is `.notFound`, and a provider with no contents at all
    /// reads nothing (`.operationNotSupported`).
    init(
        versions: [ObjectVersion] = [], error: (any Error)? = nil,
        contents: [String: Data] = [:]
    ) {
        state = Mutex(State(versions: versions, error: error, contents: contents))
    }

    /// The version ids `readStream` was asked for, in order.
    var readVersionIds: [String] { state.withLock { $0.readVersionIds } }

    /// The listings asked for, in order.
    var listings: [Listing] { state.withLock { $0.listings } }
    /// The writes asked for, in order, whatever each answered.
    var writes: [Write] { state.withLock { $0.writes } }

    /// What the writes answer from now on.
    func setWriteAnswer(_ answer: WriteAnswer) {
        state.withLock { $0.writeAnswer = answer }
    }

    private func record(_ write: Write) throws {
        let answer = state.withLock { state -> WriteAnswer in
            state.writes.append(write)
            return state.writeAnswer
        }
        switch answer {
        case .unsupported: throw Self.unsupported
        case .accepted: return
        case .throwing(let error): throw error
        }
    }

    private static var unsupported: RemoteFSError { .finding(.operationNotSupported) }

    /// Holds the `number`th listing (1-based, counted from the provider's
    /// creation) at the store until `release` is raised, after raising
    /// `entered`. For a test that has to look at the world while a listing is
    /// still on the wire.
    func parkListing(number: Int) -> (entered: AsyncSignal, release: AsyncSignal) {
        let gate = (entered: AsyncSignal(), release: AsyncSignal())
        state.withLock { $0.parked = (number, gate.entered, gate.release) }
        return gate
    }

    func versions(ofKey key: String, inBucket bucket: String) async throws -> [ObjectVersion] {
        let (answer, gate) = try state.withLock { state -> ([ObjectVersion], (entered: AsyncSignal, release: AsyncSignal)?) in
            state.listings.append(Listing(key: key, bucket: bucket))
            if let error = state.error { throw error }
            let parked = state.parked.flatMap { $0.number == state.listings.count ? ($0.entered, $0.release) : nil }
            return (state.versions, parked.map { (entered: $0.0, release: $0.1) })
        }
        if let gate {
            gate.entered.signal()
            await gate.release.arrives("a parked listing being released")
        }
        return answer
    }

    func deletedEntries(inBucket bucket: String, prefix: String) async throws -> [DeletedEntry] {
        throw Self.unsupported
    }

    func readStream(
        ofKey key: String, inBucket bucket: String, versionId: String
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let data = try state.withLock { state -> Data in
            state.readVersionIds.append(versionId)
            if state.contents.isEmpty { throw Self.unsupported }
            guard let data = state.contents[versionId] else {
                throw RemoteFSError.notFound(path: "/" + bucket + "/" + key)
            }
            return data
        }
        return AsyncThrowingStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
        }
    }

    func restore(key: String, inBucket bucket: String, toVersionId versionId: String) async throws {
        try record(Write(kind: .restore, key: key, bucket: bucket, versionId: versionId))
    }

    func deleteVersion(ofKey key: String, inBucket bucket: String, versionId: String) async throws {
        try record(Write(kind: .deleteVersion, key: key, bucket: bucket, versionId: versionId))
    }

    func liftDeleteMarker(ofKey key: String, inBucket bucket: String, markerVersionId: String) async throws {
        try record(Write(kind: .liftDeleteMarker, key: key, bucket: bucket, versionId: markerVersionId))
    }
}
