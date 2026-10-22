import Foundation
import Synchronization
import macSCPCore

/// An in-memory `S3BucketSettings` for the sheets that talk to the capability.
///
/// It answers only what the sheets ask (`versioning(ofBucket:)`,
/// `setVersioning(_:ofBucket:)`, `cors(ofBucket:)`, `setCORS(_:ofBucket:)`, and
/// the six Object Lock calls once it is given an `ObjectLockFixture`); every
/// other method throws `RemoteFSError.finding(.operationNotSupported)`, so a
/// sheet that reached for a call it was not given fails loudly instead of
/// reading a made-up answer. An Object Lock call made on a fake that was not
/// given a fixture fails the same way.
///
/// **The Object Lock half mirrors what Core refuses.** `setObjectLockDefault`
/// on a bucket with no Object Lock throws `.objectLockNotConfigured` and
/// records no write, and fewer than one day is `.protocolError`, as
/// `S3BucketSettings.setObjectLockDefault` documents. `hasObjectLock` answers a
/// fixed `Bool` and never `nil`: Core's `false` is the store's 404 and nothing
/// else, so a fake that could answer "unknown" would model a state the real
/// call does not have.
///
/// **A write changes what the next read returns**, the way a store does, so a
/// sheet that re-reads after writing is exercised against the store's own
/// answer and not against the value it just sent. `createBucket` is a write
/// like the others in this respect, and `CreateEffect` is how a create that
/// the store ACCEPTED but did not fully carry out is written down.
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

    /// One `createBucket` call, as it arrived.
    struct CreateCall: Equatable, Sendable {
        let bucket: String
        let protection: BucketProtection
    }

    /// How `createBucket` fails, when it does: the two places Core's own call
    /// can fail. A call that makes two requests (the create, then the
    /// versioning) can fail at the first, leaving nothing behind, or at the
    /// second, leaving the bucket created and unversioned
    /// (`S3BucketSettings.createBucket`).
    enum CreateFailure: Sendable {
        /// The create itself is refused; no bucket exists afterwards.
        case refused(any Error)
        /// The create succeeded and the versioning request after it failed;
        /// the bucket exists. The call records that it was made.
        case afterTheBucketExists(any Error)
    }

    /// What the store actually DOES with a create it accepts, as opposed to
    /// what the create asked for.
    ///
    /// It exists because the two can differ, which is the whole of F1: a
    /// store can answer a create with success and not carry out part of it,
    /// and only a read-back can tell. Without this the fake could express a
    /// create that THREW (`CreateFailure`) and a create that did everything,
    /// and nothing in between -- so the case the rig measured could not be
    /// written down.
    enum CreateEffect: Sendable, Equatable {
        /// The protection reaches the bucket: versioning enabled, and Object
        /// Lock too where the create carried its header.
        case asAsked
        /// The create succeeds, the versioning request after it is taken, and
        /// the Object Lock header does NOTHING. What the Docker rig answers
        /// to a re-create of a bucket the key already owns (measured
        /// 2026-10-19, `S3CreateBucketGatedTests`
        /// `.recreatingABucketTheKeyOwnsDoesNotEnableObjectLockButDoesEnableVersioning`,
        /// which asserts `after?.hasLock == false` and
        /// `after?.versioning == .enabled` for exactly this).
        case ignoresTheObjectLockHeader
        /// The create succeeds and the versioning does not take. The mirror
        /// of the case above, for the half of the read-back that watches
        /// versioning rather than the lock.
        case ignoresTheVersioningRequest
    }

    /// What the fake answers for the Object Lock calls. Its absence keeps the
    /// six calls unsupported.
    struct ObjectLockFixture: Sendable {
        var hasLock: Bool
        var bucketDefault: ObjectLockDefault?
        var retention: ObjectRetention?
        var legalHold: Bool
        var hasLockError: (any Error)?
        var readError: (any Error)?
        var writeError: (any Error)?
        /// Raised when a write has reached the store and is waiting. With
        /// `writeRelease` set, the write then waits for it, so a test observes
        /// a write in flight instead of racing one.
        var writeEntered: AsyncSignal?
        var writeRelease: AsyncSignal?
        /// The same pair for `hasObjectLock`: raised when the read has reached
        /// the store, and, with `hasLockRelease` set, held there until it is
        /// raised, so a test observes the lock read still pending while the
        /// versioning read has already returned.
        var hasLockEntered: AsyncSignal?
        var hasLockRelease: AsyncSignal?

        init(
            hasLock: Bool = true, bucketDefault: ObjectLockDefault? = nil,
            retention: ObjectRetention? = nil, legalHold: Bool = false,
            hasLockError: (any Error)? = nil, readError: (any Error)? = nil,
            writeError: (any Error)? = nil, writeEntered: AsyncSignal? = nil,
            writeRelease: AsyncSignal? = nil, hasLockEntered: AsyncSignal? = nil,
            hasLockRelease: AsyncSignal? = nil
        ) {
            self.hasLockEntered = hasLockEntered
            self.hasLockRelease = hasLockRelease
            self.writeEntered = writeEntered
            self.writeRelease = writeRelease
            self.hasLock = hasLock
            self.bucketDefault = bucketDefault
            self.retention = retention
            self.legalHold = legalHold
            self.hasLockError = hasLockError
            self.readError = readError
            self.writeError = writeError
        }
    }

    /// A bucket default as `objectLockDefault(ofBucket:)` returns it.
    struct ObjectLockDefault: Equatable, Sendable {
        let days: Int
        let mode: RetentionMode
    }

    /// One `setObjectLockDefault` call that reached the store, as it arrived.
    struct DefaultWrite: Equatable, Sendable {
        let days: Int
        let mode: RetentionMode
        let bucket: String
    }

    /// One `setRetention` call, as it arrived.
    struct RetentionWrite: Equatable, Sendable {
        let retention: ObjectRetention
        let key: String
        let bucket: String
        let versionId: String?
    }

    /// One `setLegalHold` call, as it arrived.
    struct LegalHoldWrite: Equatable, Sendable {
        let on: Bool
        let key: String
        let bucket: String
        let versionId: String?
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
        var lock: ObjectLockFixture?
        var createFailure: CreateFailure?
        var createEffect: CreateEffect = .asAsked
        var creates: [CreateCall] = []
        var hasLockReads: [String] = []
        var defaultReads: [String] = []
        var defaultWrites: [DefaultWrite] = []
        var retentionReads: [String] = []
        var retentionWrites: [RetentionWrite] = []
        var legalHoldReads: [String] = []
        var legalHoldWrites: [LegalHoldWrite] = []
    }

    private let state: Mutex<State>

    init(
        versioning: BucketVersioning = .never, readError: (any Error)? = nil,
        writeError: (any Error)? = nil, cors: BucketCORS? = nil,
        corsReadError: (any Error)? = nil, corsWriteError: (any Error)? = nil,
        lock: ObjectLockFixture? = nil, createFailure: CreateFailure? = nil,
        createEffect: CreateEffect = .asAsked
    ) {
        state = Mutex(
            State(
                versioning: versioning, readError: readError, writeError: writeError, cors: cors,
                corsReadError: corsReadError, corsWriteError: corsWriteError, lock: lock,
                createFailure: createFailure, createEffect: createEffect))
    }

    /// The `createBucket` calls, in order, whether or not they then failed.
    var creates: [CreateCall] { state.withLock { $0.creates } }

    /// The buckets `versioning(ofBucket:)` was asked about, in order.
    var reads: [String] { state.withLock { $0.reads } }
    /// The `setVersioning` calls, in order.
    var writes: [Write] { state.withLock { $0.writes } }
    /// The buckets `cors(ofBucket:)` was asked about, in order.
    var corsReads: [String] { state.withLock { $0.corsReads } }
    /// The `setCORS` calls, in order.
    var corsWrites: [CORSWrite] { state.withLock { $0.corsWrites } }

    /// The buckets `hasObjectLock(ofBucket:)` was asked about, in order.
    var hasLockReads: [String] { state.withLock { $0.hasLockReads } }
    /// The buckets `objectLockDefault(ofBucket:)` was asked about, in order.
    var defaultReads: [String] { state.withLock { $0.defaultReads } }
    /// The `setObjectLockDefault` calls that reached the store, in order,
    /// whether or not the store then refused them (a `writeError` still records
    /// the call). Only the two refusals made before the store is asked record
    /// nothing: fewer than one day, and a bucket with no Object Lock.
    ///
    /// **Corrected 2026-10-21 (fix round 1, Minor 4).** This comment read,
    /// verbatim: "The `setObjectLockDefault` calls that were not refused, in
    /// order." `BucketObjectLockSheetTests.aRefusedWriteKeepsTheStateAndSaysWhyInAFixedSentence`
    /// asserts `defaultWrites.count == 1` with a `writeError` set, so a call the
    /// store refused is recorded.
    var defaultWrites: [DefaultWrite] { state.withLock { $0.defaultWrites } }
    /// The keys `retention(ofKey:...)` was asked about, in order.
    var retentionReads: [String] { state.withLock { $0.retentionReads } }
    /// The `setRetention` calls, in order.
    var retentionWrites: [RetentionWrite] { state.withLock { $0.retentionWrites } }
    /// The keys `legalHold(ofKey:...)` was asked about, in order.
    var legalHoldReads: [String] { state.withLock { $0.legalHoldReads } }
    /// The `setLegalHold` calls, in order.
    var legalHoldWrites: [LegalHoldWrite] { state.withLock { $0.legalHoldWrites } }

    func versioning(ofBucket bucket: String) async throws -> BucketVersioning {
        try state.withLock { state in
            state.reads.append(bucket)
            if let error = state.readError { throw error }
            // A create the store refused left nothing to read, as a real one
            // answers `NoSuchBucket`; one that failed AFTER the bucket was made
            // (`CreateFailure.afterTheBucketExists`) left a bucket that reads.
            if case .refused = state.createFailure,
                state.creates.contains(where: { $0.bucket == bucket })
            {
                throw RemoteFSError.notFound(path: "/" + bucket)
            }
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
        try state.withLock { state in
            state.creates.append(CreateCall(bucket: bucket, protection: protection))
            switch state.createFailure {
            case .refused(let error): throw error
            case .afterTheBucketExists(let error): throw error
            case nil: break
            }
            // **A create the store ACCEPTED changes what the next read
            // returns**, the way the writes above already do, so a caller
            // that reads back after creating is exercised against the store's
            // own answer and not against the value it sent. Before the F1 fix
            // nothing read back, so the fake left its state untouched here
            // and a create was invisible to every read.
            //
            // `state.createEffect` is where the two come apart. The lock
            // fixture is ESTABLISHED for every create that asks for any
            // protection, because that is every create whose read-back asks
            // `hasObjectLock` -- and the answer for such a bucket must be a
            // `Bool`, not `.operationNotSupported`, which is the fake saying
            // it was never given a fixture: a DIFFERENT outcome (the
            // read-back FAILING) that would hide the one under test.
            //
            // **A create never REMOVES a lock.** The header can be honoured
            // or ignored; neither takes a lock off a bucket that already had
            // one. So an existing fixture keeps its `hasLock` unless the
            // header is both sent and honoured, and a fake with no fixture
            // starts at `false`, the way a bucket made without the header
            // has none. That is what lets a test say "the create asked for
            // versioning only and landed on a bucket that already has Object
            // Lock" -- the mirror case, and the one the F1 fix round missed.
            //
            // **Corrected 2026-10-22 (F1, fix round 2).** This paragraph read,
            // verbatim: "The lock fixture is ESTABLISHED when the create
            // carried the lock header, whichever way the effect goes", and
            // the code was `if protection == .lockedAndVersioned { ...
            // lock.hasLock = state.createEffect != .ignoresTheObjectLockHeader }`,
            // which also switched an existing lock OFF for an ignored header.
            // **Corrected again 2026-10-22 (F1, fix round 3).** The guard was
            // `if protection != .none`, which left a PLAIN create with no
            // fixture -- and the read-back now runs for a plain create too,
            // so `hasObjectLock` would have answered `.operationNotSupported`
            // where a store answers a `Bool`. Every accepted create
            // establishes it; which protection was asked for decides only
            // whether the lock is switched ON.
            var lock = state.lock ?? ObjectLockFixture(hasLock: false)
            if protection == .lockedAndVersioned,
                state.createEffect != .ignoresTheObjectLockHeader
            {
                lock.hasLock = true
            }
            state.lock = lock
            if protection != .none, state.createEffect != .ignoresTheVersioningRequest {
                state.versioning = .enabled
            }
        }
    }
    /// Changes what `hasObjectLock` throws from now on (`nil` to answer again),
    /// for a test in which the same store fails once and then does not. A
    /// no-op on a fake that was given no Object Lock fixture.
    func setHasLockError(_ error: (any Error)?) {
        state.withLock { $0.lock?.hasLockError = error }
    }

    func hasObjectLock(ofBucket bucket: String) async throws -> Bool {
        let gate = try state.withLock { state -> (AsyncSignal?, AsyncSignal?) in
            state.hasLockReads.append(bucket)
            guard let lock = state.lock else { throw Self.unsupported }
            return (lock.hasLockEntered, lock.hasLockRelease)
        }
        gate.0?.signal()
        if let release = gate.1 { _ = await release.wait() }
        return try state.withLock { state in
            guard let lock = state.lock else { throw Self.unsupported }
            if let error = lock.hasLockError { throw error }
            return lock.hasLock
        }
    }
    func objectLockDefault(ofBucket bucket: String) async throws -> (days: Int, mode: RetentionMode)? {
        try state.withLock { state in
            state.defaultReads.append(bucket)
            guard let lock = state.lock else { throw Self.unsupported }
            if let error = lock.readError { throw error }
            return lock.bucketDefault.map { (days: $0.days, mode: $0.mode) }
        }
    }
    func setObjectLockDefault(days: Int, mode: RetentionMode, ofBucket bucket: String) async throws {
        let gate = try state.withLock { state -> (AsyncSignal?, AsyncSignal?) in
            guard let lock = state.lock else { throw Self.unsupported }
            guard days >= 1 else { throw RemoteFSError.protocolError(reason: "days below one") }
            guard lock.hasLock else { throw RemoteFSError.finding(.objectLockNotConfigured) }
            state.defaultWrites.append(DefaultWrite(days: days, mode: mode, bucket: bucket))
            return (lock.writeEntered, lock.writeRelease)
        }
        gate.0?.signal()
        if let release = gate.1 { _ = await release.wait() }
        try state.withLock { state in
            guard var lock = state.lock else { throw Self.unsupported }
            if let error = lock.writeError { throw error }
            lock.bucketDefault = ObjectLockDefault(days: days, mode: mode)
            state.lock = lock
        }
    }
    func retention(ofKey key: String, inBucket bucket: String, versionId: String?) async throws
        -> ObjectRetention?
    {
        try state.withLock { state in
            state.retentionReads.append(key)
            guard let lock = state.lock else { throw Self.unsupported }
            if let error = lock.readError { throw error }
            return lock.retention
        }
    }
    func setRetention(
        _ retention: ObjectRetention, ofKey key: String, inBucket bucket: String, versionId: String?
    ) async throws {
        let gate = try state.withLock { state -> (AsyncSignal?, AsyncSignal?) in
            guard let lock = state.lock else { throw Self.unsupported }
            state.retentionWrites.append(
                RetentionWrite(retention: retention, key: key, bucket: bucket, versionId: versionId))
            return (lock.writeEntered, lock.writeRelease)
        }
        gate.0?.signal()
        if let release = gate.1 { _ = await release.wait() }
        try state.withLock { state in
            guard var lock = state.lock else { throw Self.unsupported }
            if let error = lock.writeError { throw error }
            lock.retention = retention
            state.lock = lock
        }
    }
    func legalHold(ofKey key: String, inBucket bucket: String, versionId: String?) async throws -> Bool {
        try state.withLock { state in
            state.legalHoldReads.append(key)
            guard let lock = state.lock else { throw Self.unsupported }
            if let error = lock.readError { throw error }
            return lock.legalHold
        }
    }
    func setLegalHold(_ on: Bool, ofKey key: String, inBucket bucket: String, versionId: String?) async throws {
        let gate = try state.withLock { state -> (AsyncSignal?, AsyncSignal?) in
            guard let lock = state.lock else { throw Self.unsupported }
            state.legalHoldWrites.append(
                LegalHoldWrite(on: on, key: key, bucket: bucket, versionId: versionId))
            return (lock.writeEntered, lock.writeRelease)
        }
        gate.0?.signal()
        if let release = gate.1 { _ = await release.wait() }
        try state.withLock { state in
            guard var lock = state.lock else { throw Self.unsupported }
            if let error = lock.writeError { throw error }
            lock.legalHold = on
            state.lock = lock
        }
    }
}
