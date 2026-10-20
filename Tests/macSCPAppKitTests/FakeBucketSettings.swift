import Foundation
import Synchronization
import macSCPCore

/// An in-memory `S3BucketSettings` for the sheets that talk to the capability.
///
/// It answers only what the versioning and CORS sheets ask
/// (`versioning(ofBucket:)`, `setVersioning(_:ofBucket:)`, `cors(ofBucket:)`,
/// `setCORS(_:ofBucket:)`); every other method throws
/// `RemoteFSError.finding(.operationNotSupported)`, so a sheet that reached for
/// a call it was not given fails loudly instead of reading a made-up answer.
///
/// **A write changes what the next read returns**, the way a store does, so a
/// sheet that re-reads after writing is exercised against the store's own
/// answer and not against the value it just sent.
///
/// **`setCORS` keeps the asymmetry of the real store.** Rules written read back
/// as a configuration whose `rawBody` is the document `S3SettingsXML.corsBody`
/// builds for them, and `setCORS([])` clears the configuration, so the next read
/// is `nil` and never an empty list (`S3BucketSettings.setCORS`).
///
/// No wait, no sleep: every method answers at once.
final class FakeBucketSettings: S3BucketSettings, Sendable {
    /// One `setVersioning` call, as it arrived.
    struct Write: Equatable, Sendable {
        let state: BucketVersioning
        let bucket: String
    }

    /// One `setCORS` call, as it arrived.
    struct CORSWrite: Equatable, Sendable {
        let rules: [CORSRule]
        let bucket: String
    }

    private struct State {
        var versioning: BucketVersioning
        var readError: (any Error)?
        var writeError: (any Error)?
        var reads: [String] = []
        var writes: [Write] = []
        var cors: BucketCORS?
        var corsReadError: (any Error)?
        var corsWriteError: (any Error)?
        var corsReads: [String] = []
        var corsWrites: [CORSWrite] = []
    }

    private let state: Mutex<State>

    init(
        versioning: BucketVersioning = .never, readError: (any Error)? = nil,
        writeError: (any Error)? = nil, cors: BucketCORS? = nil,
        corsReadError: (any Error)? = nil, corsWriteError: (any Error)? = nil
    ) {
        state = Mutex(
            State(
                versioning: versioning, readError: readError, writeError: writeError, cors: cors,
                corsReadError: corsReadError, corsWriteError: corsWriteError))
    }

    /// The buckets `versioning(ofBucket:)` was asked about, in order.
    var reads: [String] { state.withLock { $0.reads } }
    /// The `setVersioning` calls, in order.
    var writes: [Write] { state.withLock { $0.writes } }
    /// The buckets `cors(ofBucket:)` was asked about, in order.
    var corsReads: [String] { state.withLock { $0.corsReads } }
    /// The `setCORS` calls, in order.
    var corsWrites: [CORSWrite] { state.withLock { $0.corsWrites } }

    func versioning(ofBucket bucket: String) async throws -> BucketVersioning {
        try state.withLock { state in
            state.reads.append(bucket)
            if let error = state.readError { throw error }
            return state.versioning
        }
    }

    func setVersioning(_ target: BucketVersioning, ofBucket bucket: String) async throws {
        try state.withLock { state in
            state.writes.append(Write(state: target, bucket: bucket))
            if let error = state.writeError { throw error }
            state.versioning = target
        }
    }

    private static var unsupported: RemoteFSError { .finding(.operationNotSupported) }

    func cors(ofBucket bucket: String) async throws -> BucketCORS? {
        try state.withLock { state in
            state.corsReads.append(bucket)
            if let error = state.corsReadError { throw error }
            return state.cors
        }
    }

    func setCORS(_ rules: [CORSRule], ofBucket bucket: String) async throws {
        try state.withLock { state in
            state.corsWrites.append(CORSWrite(rules: rules, bucket: bucket))
            if let error = state.corsWriteError { throw error }
            state.cors =
                rules.isEmpty
                ? nil
                : BucketCORS(rules: rules, rawBody: try S3SettingsXML.corsBody(rules))
        }
    }

    func createBucket(_ bucket: String, protection: BucketProtection) async throws {
        throw Self.unsupported
    }
    func hasObjectLock(ofBucket bucket: String) async throws -> Bool { throw Self.unsupported }
    func objectLockDefault(ofBucket bucket: String) async throws -> (days: Int, mode: RetentionMode)? {
        throw Self.unsupported
    }
    func setObjectLockDefault(days: Int, mode: RetentionMode, ofBucket bucket: String) async throws {
        throw Self.unsupported
    }
    func retention(ofKey key: String, inBucket bucket: String, versionId: String?) async throws
        -> ObjectRetention?
    {
        throw Self.unsupported
    }
    func setRetention(
        _ retention: ObjectRetention, ofKey key: String, inBucket bucket: String, versionId: String?
    ) async throws {
        throw Self.unsupported
    }
    func legalHold(ofKey key: String, inBucket bucket: String, versionId: String?) async throws -> Bool {
        throw Self.unsupported
    }
    func setLegalHold(_ on: Bool, ofKey key: String, inBucket bucket: String, versionId: String?) async throws {
        throw Self.unsupported
    }
}
