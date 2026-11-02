import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The session's bucket-versioning cache: one read per bucket, kept, with a
/// failure never kept.
///
/// It mirrors `ObjectLockStateCache`'s cases in `ObjectLockSheetTests`, and the
/// shape of each is the same on purpose: how many times the STORE was asked is
/// read off the fake's own `reads`, never off the cache's internals, so a
/// cache that answered correctly while reading every time is red.
@Suite("Bucket versioning cache")
struct BucketVersioningCacheTests {
    /// Every state is an answer, `.never` included: "this bucket has no
    /// versioning" is what the store said, and asking again gives it again.
    /// Parameterised over `allCases` so a fourth state is covered when it
    /// arrives, and so the loop cannot be satisfied by an empty list.
    @MainActor @Test(arguments: BucketVersioning.allCases)
    func everyStateIsAnAnswerAndIsReadOnce(state: BucketVersioning) async throws {
        let probe = FakeBucketSettings(versioning: state)
        let cache = BucketVersioningCache(settings: probe)
        let first = try await cache.versioning("b")
        let second = try await cache.versioning("b")
        #expect(first == state)
        #expect(second == state)
        #expect(probe.reads == ["b"])
    }

    @Test func theStatesAreThreeAndNotTwo() {
        #expect(BucketVersioning.allCases.count == 3)
    }

    /// The cache is per bucket: a second bucket is a second read, and each
    /// keeps its own answer.
    @MainActor @Test func eachBucketIsReadOnceOnItsOwn() async throws {
        let probe = FakeBucketSettings(versioning: .enabled)
        let cache = BucketVersioningCache(settings: probe)
        _ = try await cache.versioning("b")
        _ = try await cache.versioning("b")
        #expect(probe.reads == ["b"])
        _ = try await cache.versioning("other")
        _ = try await cache.versioning("other")
        _ = try await cache.versioning("b")
        #expect(probe.reads == ["b", "other"])
    }

    /// A failure is not an answer. Asked twice, the store is asked twice, and
    /// the second ask throws as well: nothing the failed read left behind
    /// reads as a state, `.never` least of all.
    @MainActor @Test func aFailedReadIsNotRemembered() async {
        let failing = FakeBucketSettings(
            versioning: .enabled, readError: RemoteFSError.finding(.operationNotSupported))
        let cache = BucketVersioningCache(settings: failing)
        await #expect(throws: RemoteFSError.self) { _ = try await cache.versioning("b") }
        await #expect(throws: RemoteFSError.self) { _ = try await cache.versioning("b") }
        #expect(failing.reads == ["b", "b"])
    }

    /// The same, with the store healing between the two asks: the second ask
    /// reads again and returns what the store now says, so a cache that kept
    /// the failure as ANY value is red (not only one that rethrew it).
    @MainActor @Test func aFailureIsFollowedByARealReadWhenTheStoreRecovers() async throws {
        let probe = FakeBucketSettings(
            versioning: .suspended, readError: RemoteFSError.finding(.operationNotSupported))
        let cache = BucketVersioningCache(settings: probe)
        await #expect(throws: RemoteFSError.self) { _ = try await cache.versioning("b") }
        probe.setReadError(nil)
        let healed = try await cache.versioning("b")
        #expect(healed == .suspended)
        #expect(probe.reads == ["b", "b"])
        _ = try await cache.versioning("b")
        #expect(probe.reads == ["b", "b"], "the answer, once read, is kept")
    }

    /// Two surfaces asking about one bucket together share one read.
    @MainActor @Test func twoAsksAtOnceShareOneRead() async throws {
        let probe = FakeBucketSettings(versioning: .enabled)
        let cache = BucketVersioningCache(settings: probe)
        async let first = cache.versioning("b")
        async let second = cache.versioning("b")
        let answers = try await [first, second]
        #expect(answers == [.enabled, .enabled])
        #expect(probe.reads == ["b"])
    }

    /// The session owns one only when the connection has the capability, as
    /// the lock cache does: the positive beside the negative.
    @MainActor @Test func aConnectionWithTheCapabilityGetsACacheAndOneWithoutDoesNot() {
        #expect(BrowserSession.bucketVersioning(for: FakeBucketSettings()) != nil)
        #expect(BrowserSession.bucketVersioning(for: LocalFileSystem()) == nil)
    }

    // MARK: - What the menu can ask without waiting

    /// `knownVersioning` answers from what was already read and `nil` for
    /// "not asked", which is none of the three states: a bucket never asked
    /// about is not a bucket that was never versioned.
    @MainActor @Test func theSynchronousAccessorAnswersOnlyFromWhatWasRead() async throws {
        let probe = FakeBucketSettings(versioning: .never)
        let cache = BucketVersioningCache(settings: probe)
        #expect(cache.knownVersioning("b") == nil)
        #expect(probe.reads.isEmpty, "asking synchronously reads nothing")
        _ = try await cache.versioning("b")
        #expect(cache.knownVersioning("b") == .never)
        #expect(cache.knownVersioning("other") == nil)
        // A failed read leaves nothing to know.
        let failing = FakeBucketSettings(
            versioning: .enabled, readError: RemoteFSError.finding(.operationNotSupported))
        let failed = BucketVersioningCache(settings: failing)
        await #expect(throws: RemoteFSError.self) { _ = try await failed.versioning("b") }
        #expect(failed.knownVersioning("b") == nil)
    }

    // MARK: - A write

    /// The four clicks that gave a wrong answer: the row is evaluated on a
    /// `.never` bucket, the user enables versioning, and the cache must not go
    /// on saying `.never`.
    @MainActor @Test func aWriteThenAnAskReadsAgain() async throws {
        let probe = FakeBucketSettings(versioning: .never)
        let cache = BucketVersioningCache(settings: probe)
        #expect(try await cache.versioning("b") == .never)
        try await probe.setVersioning(.enabled, ofBucket: "b")
        // Before the writer tells it, the cache still says what it read: the
        // gap `invalidate` exists to close.
        #expect(cache.knownVersioning("b") == .never)
        cache.invalidate("b")
        #expect(cache.knownVersioning("b") == nil)
        #expect(try await cache.versioning("b") == .enabled)
        #expect(probe.reads == ["b", "b"])
        #expect(cache.knownVersioning("b") == .enabled)
    }

    /// The positive control for the case above: a write to one bucket does not
    /// drop the answer for another, which is not read again.
    @MainActor @Test func aWriteToOneBucketDoesNotInvalidateAnother() async throws {
        let probe = FakeBucketSettings(versioning: .suspended)
        let cache = BucketVersioningCache(settings: probe)
        _ = try await cache.versioning("b")
        _ = try await cache.versioning("other")
        #expect(probe.reads == ["b", "other"])
        cache.invalidate("b")
        #expect(cache.knownVersioning("other") == .suspended)
        #expect(cache.knownVersioning("b") == nil)
        _ = try await cache.versioning("other")
        #expect(probe.reads == ["b", "other"], "the other bucket was not read again")
        _ = try await cache.versioning("b")
        #expect(probe.reads == ["b", "other", "b"])
    }

    /// A read that was already on the wire when the write landed returns the
    /// state from before it. It must not put that back into the cache.
    @MainActor @Test func aReadInFlightWhenAWriteLandsDoesNotRecordTheOldState() async throws {
        let probe = FakeBucketSettings(versioning: .never)
        let gate = probe.holdVersioningReads()
        let cache = BucketVersioningCache(settings: probe)
        let stale = Task { @MainActor in try await cache.versioning("b") }
        _ = await gate.entered.wait()
        try await probe.setVersioning(.enabled, ofBucket: "b")
        cache.invalidate("b")
        gate.release.signal()
        // The caller that was waiting gets what its read saw.
        #expect(try await stale.value == .never)
        // The cache does not keep it.
        #expect(cache.knownVersioning("b") == nil)
        #expect(try await cache.versioning("b") == .enabled)
        #expect(cache.knownVersioning("b") == .enabled)
    }
}
