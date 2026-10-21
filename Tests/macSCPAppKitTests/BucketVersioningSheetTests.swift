import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The versioning sheet's decisions: which state a bucket can move to, what the
/// sheet says before it moves, and what it shows when the store refuses.
///
/// No test in this project draws a SwiftUI view; these are the decisions the
/// view reads, the catalogue entries it looks its text up in, and one scan of
/// the view's own source for the keys it uses.
@Suite("Bucket versioning sheet")
struct BucketVersioningSheetTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    // MARK: - What can be offered

    @MainActor @Test func aNeverVersionedBucketOffersOnlyEnabling() {
        // Review Focus 4: "suspend" means nothing on a bucket that never kept
        // versions, and offering it would ask for a call that cannot be made.
        let model = BucketVersioningModel(current: .never, bucketHasObjectLock: false)
        #expect(model.offeredStates == [.enabled])
    }

    /// **Changed 2026-10-21 (Task 11b).** This test used to build its model as
    /// `BucketVersioningModel(current: .enabled)`, verbatim, and to read as
    /// though any enabled bucket could be suspended. Withdrawn: the offer now
    /// depends on the lock, so the bucket here is named as one without
    /// (`aLockBearingBucketIsNotOfferedSuspension` holds the other side).
    @MainActor @Test func anEnabledBucketCanBeSuspendedAndNotUnset() {
        let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
        #expect(model.offeredStates == [.suspended])
    }

    @MainActor @Test func aSuspendedBucketCanBeTurnedBackOn() {
        let model = BucketVersioningModel(current: .suspended, bucketHasObjectLock: false)
        #expect(model.offeredStates == [.enabled])
    }

    // MARK: - What Object Lock forbids (Task 11b)

    @MainActor @Test func aLockBearingBucketIsNotOfferedSuspension() {
        let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: true)
        #expect(model.offeredStates == [])
        #expect(model.blockedReasonKey == "s3.versioning.objectLockKeepsItOn")
    }

    @MainActor @Test func aBucketWithoutALockIsStillOfferedSuspension() {
        // The positive control. Without it the test above passes on a model that
        // offers nothing to anybody.
        let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
        #expect(model.offeredStates == [.suspended])
        #expect(model.blockedReasonKey == nil)
    }

    @MainActor @Test func anUnreadLockStateOffersNothingAndSaysNothingAboutLocks() {
        // The third state is the one that bites: the cache has not answered yet.
        // Offering suspension here would be the old behaviour under a new name,
        // and naming Object Lock here would assert a fact nobody has read.
        let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: nil)
        #expect(model.offeredStates == [])
        #expect(model.blockedReasonKey == nil)
    }

    @MainActor @Test func enablingIsNeverBlockedByALock() {
        // A never-versioned bucket cannot carry a lock, but a suspended one that
        // somehow reads as locked must still be offered the way back ON.
        for lock in [true, false] {
            let suspended = BucketVersioningModel(current: .suspended, bucketHasObjectLock: lock)
            #expect(suspended.offeredStates == [.enabled])
        }
    }

    /// `.never` is a state the store reports and cannot be asked for; no state
    /// offers it. Paired with a total, so an empty offer cannot satisfy it.
    @MainActor @Test func noStateEverOffersNever() {
        var offered = 0
        for state in BucketVersioning.allCases {
            let states = BucketVersioningModel(current: state, bucketHasObjectLock: false).offeredStates
            offered += states.count
            #expect(!states.contains(.never))
        }
        #expect(offered == BucketVersioning.allCases.count)
    }

    /// Until the read has answered, or after it failed, there is no state to
    /// move from and so nothing to offer.
    @MainActor @Test func nothingIsOfferedWithoutAKnownState() {
        #expect(BucketVersioningModel().offeredStates.isEmpty)
        #expect(BucketVersioningModel(loadFailure: "x").offeredStates.isEmpty)
        #expect(BucketVersioningModel().warningKey == nil)
    }

    // MARK: - What it says first

    @MainActor @Test func suspendingSaysWhatItDoesNotDo() {
        let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
        #expect(model.warningKey == "s3.versioning.suspendKeepsVersions")
    }

    /// Every offered action says something about cost before the click, and
    /// each says its own thing. Turning versioning on for the first time is
    /// the one-way door (it can be suspended, never returned to
    /// never-versioned); resuming a suspended bucket is NOT, because that door
    /// is already shut, so it must not say so. The three answers differ from
    /// one another, so a model that returned one key for every state would not
    /// pass.
    ///
    /// **Changed 2026-10-20 (review Minor 5).** This test used to end
    /// `#expect(suspended == nil)` under the sentence "A resumed bucket has
    /// nothing further to warn about." Withdrawn: resuming was the one offered
    /// action that said nothing about cost.
    @MainActor @Test func eachStateSaysItsOwnThingBeforeTheClick() {
        let never = BucketVersioningModel(current: .never, bucketHasObjectLock: false).warningKey
        let enabled = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false).warningKey
        let suspended = BucketVersioningModel(current: .suspended, bucketHasObjectLock: false).warningKey
        #expect(never != nil)
        #expect(enabled != nil)
        #expect(suspended != nil)
        #expect(never != enabled)
        #expect(never != suspended)
        #expect(enabled != suspended)
    }

    /// The resume line is about cost and does not repeat the one-way claim,
    /// which would be false of a bucket that has already been switched on once.
    /// Both halves in English: the positive (it names cost) beside the negative
    /// (it does not say versioning cannot be removed).
    @MainActor @Test func resumingSaysWhatItStartsAgainAndNotTheOneWayThing() {
        let english = L10n.$localeOverride.withValue("en") {
            BucketVersioningModel(current: .suspended, bucketHasObjectLock: false).warning?.text.lowercased() ?? ""
        }
        let namesCost = english.contains("cost")
        let claimsOneWay = english.contains("not removed") || english.contains("cannot")
        #expect(namesCost)
        #expect(!claimsOneWay)
    }

    /// The warning about money says what suspending does AND what it does not
    /// do, in plain words, and names nothing about how the store works. The
    /// words below are the ones this sentence must not lean on; the positive
    /// halves are that the sentence is there and that it mentions cost.
    @MainActor @Test func theSuspendWarningIsPlainAndNamesNoMechanics() {
        let english = L10n.$localeOverride.withValue("en") {
            BucketVersioningModel(current: .enabled, bucketHasObjectLock: false).warning?.text ?? ""
        }
        #expect(!english.isEmpty)
        let lowered = english.lowercased()
        for jargon in ["delete marker", "s3", "bucket policy", "lifecycle"] {
            let leaked = lowered.contains(jargon)
            #expect(!leaked)
        }
        let namesCost = lowered.contains("cost")
        #expect(namesCost)
    }

    // MARK: - Reading and writing

    @MainActor @Test func aReadFillsTheStateFromTheBucketItWasAskedAbout() async {
        let settings = FakeBucketSettings(versioning: .suspended, lock: .init(hasLock: false))
        let model = BucketVersioningModel()
        await model.read(
            bucket: "macscp-seed", from: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(model.current == .suspended)
        #expect(settings.reads == ["macscp-seed"])
        #expect(settings.hasLockReads == ["macscp-seed"])
        #expect(model.bucketHasObjectLock == false)
        #expect(model.offeredStates == [.enabled])
    }

    /// The read is what carries the lock answer into the model: a bucket under
    /// Object Lock, read through the cache, is offered nothing and says why,
    /// and the unlocked bucket beside it is the positive control. Without that
    /// control, a read that never offered anything would pass.
    @MainActor @Test func aReadOfALockBearingBucketOffersNothingAndSaysWhy() async {
        let locked = FakeBucketSettings(versioning: .enabled, lock: .init(hasLock: true))
        let model = BucketVersioningModel()
        await model.read(bucket: "b", from: locked, locks: ObjectLockStateCache(settings: locked))
        #expect(model.bucketHasObjectLock == true)
        #expect(model.offeredStates == [])
        #expect(model.blockedReasonKey == "s3.versioning.objectLockKeepsItOn")
        // A warning about a click that is not on offer would be noise.
        #expect(model.warning == nil)

        let open = FakeBucketSettings(versioning: .enabled, lock: .init(hasLock: false))
        let control = BucketVersioningModel()
        await control.read(bucket: "b", from: open, locks: ObjectLockStateCache(settings: open))
        #expect(control.offeredStates == [.suspended])
        #expect(control.blockedReasonKey == nil)
        #expect(control.warningKey == "s3.versioning.suspendKeepsVersions")
    }

    /// The offer is also the gate on the write: a suspension that was not
    /// offered is never sent, so a stale button cannot reach the store.
    @MainActor @Test func aSuspensionOnALockBearingBucketIsNeverSent() async {
        let settings = FakeBucketSettings(versioning: .enabled)
        let locked = BucketVersioningModel(current: .enabled, bucketHasObjectLock: true)
        await locked.apply(.suspended, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes.isEmpty)
        let unread = BucketVersioningModel(current: .enabled, bucketHasObjectLock: nil)
        await unread.apply(.suspended, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes.isEmpty)
        // The positive control: the same bucket, known to have no lock.
        let open = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
        await open.apply(.suspended, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes.count == 1)
    }

    /// **Fix round 1, I1.** A lock that cannot be read changes nothing the sheet
    /// offers or says for a bucket that is not enabled, so it must not cost the
    /// sheet its reach there: a never-versioned or suspended bucket still
    /// settles and still offers enabling. The enabled bucket beside them is the
    /// positive control -- the same failure there IS a failed load, because the
    /// lock is the whole decision.
    @MainActor @Test func aLockThatCannotBeReadDoesNotCostABucketThatIsNotEnabled() async {
        for state in [BucketVersioning.never, .suspended] {
            let settings = FakeBucketSettings(
                versioning: state, lock: .init(hasLockError: RemoteFSError.finding(.operationNotSupported)))
            let model = BucketVersioningModel()
            await model.read(
                bucket: "b", from: settings, locks: ObjectLockStateCache(settings: settings))
            #expect(model.load == .known(state), "\(state)")
            #expect(model.offeredStates == [.enabled], "\(state)")
            #expect(model.bucketHasObjectLock == nil)
            #expect(model.lockReadFailed)
            // Nothing is said about a lock the sheet has no use for.
            #expect(model.blockedReasonKey == nil)
        }
        let enabled = FakeBucketSettings(
            versioning: .enabled, lock: .init(hasLockError: RemoteFSError.finding(.operationNotSupported)))
        let model = BucketVersioningModel()
        await model.read(bucket: "b", from: enabled, locks: ObjectLockStateCache(settings: enabled))
        #expect(model.load == .failed(BucketVersioningModel.lockReadFailedLine.text))
    }

    /// **Fix round 1, I1, the half that stops the sheet going silent.** A
    /// bucket that settled without its lock and is then enabled asks again, and
    /// the cache keeps no failure, so the second ask is a real one: when the
    /// store answers, the suspend button is there (or the lock sentence, for a
    /// bucket that has one); when it fails again, the sheet SAYS so instead of
    /// standing with a state line and nothing else.
    @MainActor @Test func enablingAfterAFailedLockReadAsksAgainAndNeverGoesSilent() async {
        let broken = RemoteFSError.finding(.operationNotSupported)

        // The second ask answers: no lock, so the way back OFF is offered.
        let healed = FakeBucketSettings(versioning: .never, lock: .init(hasLock: false, hasLockError: broken))
        let cache = ObjectLockStateCache(settings: healed)
        let model = BucketVersioningModel()
        await model.read(bucket: "b", from: healed, locks: cache)
        #expect(model.lockReadFailed)
        healed.setHasLockError(nil)
        await model.apply(.enabled, bucket: "b", via: healed, locks: cache)
        #expect(healed.hasLockReads == ["b", "b"])
        #expect(model.current == .enabled)
        #expect(model.bucketHasObjectLock == false)
        #expect(!model.lockReadFailed)
        #expect(model.offeredStates == [.suspended])
        #expect(model.blockedReasonKey == nil)

        // The second ask answers with a lock: nothing offered, and it says why.
        let locked = FakeBucketSettings(versioning: .never, lock: .init(hasLock: true, hasLockError: broken))
        let lockedCache = ObjectLockStateCache(settings: locked)
        let lockedModel = BucketVersioningModel()
        await lockedModel.read(bucket: "b", from: locked, locks: lockedCache)
        locked.setHasLockError(nil)
        await lockedModel.apply(.enabled, bucket: "b", via: locked, locks: lockedCache)
        #expect(lockedModel.offeredStates == [])
        #expect(lockedModel.blockedReasonKey == "s3.versioning.objectLockKeepsItOn")

        // The second ask fails too: nothing offered, and the sheet says the
        // lock could not be read -- not silence.
        let stuck = FakeBucketSettings(versioning: .never, lock: .init(hasLock: false, hasLockError: broken))
        let stuckCache = ObjectLockStateCache(settings: stuck)
        let stuckModel = BucketVersioningModel()
        await stuckModel.read(bucket: "b", from: stuck, locks: stuckCache)
        await stuckModel.apply(.enabled, bucket: "b", via: stuck, locks: stuckCache)
        #expect(stuck.hasLockReads == ["b", "b"])
        #expect(stuckModel.current == .enabled)
        #expect(stuckModel.offeredStates == [])
        #expect(stuckModel.lockReadFailed)
        #expect(stuckModel.blockedReasonKey == "s3.versioning.error.lockRead")
        #expect(stuckModel.lines.contains(BucketVersioningModel.lockReadFailedLine))
        // "Not asked yet" is a different thing and still says nothing.
        let unread = BucketVersioningModel(current: .enabled, bucketHasObjectLock: nil)
        #expect(!unread.lockReadFailed)
        #expect(unread.blockedReasonKey == nil)
    }

    /// **The two answers land together.** The lock read is held at the store
    /// while the versioning read has already returned; in that window the sheet
    /// must still be `.reading`, not a settled sheet with no button. Only when
    /// the lock answer is in does the load settle, with both.
    @MainActor @Test(.timeLimit(.minutes(1)))
    func theVersioningAnswerDoesNotSettleBeforeTheLockAnswer() async {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let settings = FakeBucketSettings(
            versioning: .enabled,
            lock: .init(hasLock: false, hasLockEntered: entered, hasLockRelease: release))
        let model = BucketVersioningModel()
        let cache = ObjectLockStateCache(settings: settings)
        let reading = Task { @MainActor in
            await model.read(bucket: "b", from: settings, locks: cache)
        }
        _ = await entered.wait()
        // Versioning has been read; the lock has been asked and not answered.
        #expect(settings.reads == ["b"])
        #expect(model.load == .reading)
        #expect(model.offeredStates == [])
        release.signal()
        await reading.value
        #expect(model.load == .known(.enabled))
        #expect(model.bucketHasObjectLock == false)
        #expect(model.offeredStates == [.suspended])
    }

    /// A lock read that fails is a failed load with a sentence of its own, not
    /// a known state beside an unread lock: that would be a sheet with no
    /// button and nothing to say. It does not claim a lock either, and it does
    /// not quote what failed (the reason can carry the endpoint the user typed;
    /// the value is a constant and the `Bool` computed first, as in
    /// `aFailureNeverQuotesTheReasonItWasGiven`).
    @MainActor @Test func aLockThatCouldNotBeReadLeavesASentenceAndNoOffer() async {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let settings = FakeBucketSettings(
            versioning: .enabled,
            lock: .init(hasLockError: RemoteFSError.protocolError(reason: planted)))
        let model = BucketVersioningModel()
        await model.read(bucket: "b", from: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(model.load == .failed(BucketVersioningModel.lockReadFailedLine.text))
        #expect(model.current == nil)
        #expect(model.bucketHasObjectLock == nil)
        #expect(model.offeredStates == [])
        #expect(model.blockedReasonKey == nil)
        let text = BucketVersioningModel.lockReadFailedLine.text
        let quoted = text.contains("SECRETEXAMPLE") || text.contains("store.invalid")
        #expect(!text.isEmpty)
        #expect(!quoted)
    }

    /// Two sheets on one bucket share one lock read, because the model asks the
    /// session's cache and not the store.
    @MainActor @Test func twoReadsOfOneBucketAskTheStoreOnceAboutTheLock() async {
        let settings = FakeBucketSettings(versioning: .enabled, lock: .init(hasLock: false))
        let cache = ObjectLockStateCache(settings: settings)
        let first = BucketVersioningModel()
        let second = BucketVersioningModel()
        await first.read(bucket: "b", from: settings, locks: cache)
        await second.read(bucket: "b", from: settings, locks: cache)
        #expect(settings.reads == ["b", "b"])
        #expect(settings.hasLockReads == ["b"])
        #expect(second.bucketHasObjectLock == false)
    }

    @MainActor @Test func aRefusedReadSaysSoAndOffersNothing() async {
        let settings = FakeBucketSettings(
            readError: RemoteFSError.finding(.operationNotSupported), lock: .init(hasLock: false))
        let model = BucketVersioningModel()
        await model.read(bucket: "b", from: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(model.current == nil)
        #expect(model.offeredStates.isEmpty)
        #expect(model.load == .failed(RemoteFSFinding.operationNotSupported.message))
    }

    @MainActor @Test func enablingWritesOnceToTheNamedBucketAndShowsTheStoresAnswer() async {
        let settings = FakeBucketSettings(versioning: .never)
        let model = BucketVersioningModel(current: .never, bucketHasObjectLock: false)
        await model.apply(.enabled, bucket: "macscp-second", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes == [FakeBucketSettings.Write(state: .enabled, bucket: "macscp-second")])
        #expect(model.current == .enabled)
        #expect(model.offeredStates == [.suspended])
        #expect(model.applyFailure == nil)
        #expect(!model.isApplying)
    }

    @MainActor @Test func suspendingWritesSuspended() async {
        let settings = FakeBucketSettings(versioning: .enabled)
        let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
        await model.apply(.suspended, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes == [FakeBucketSettings.Write(state: .suspended, bucket: "b")])
        #expect(model.current == .suspended)
    }

    /// The model refuses a target it did not offer, before any request:
    /// `.never` cannot be written, and "suspend" on a never-versioned bucket is
    /// not on offer. The positive control is the offered write above.
    @MainActor @Test func aStateThatWasNotOfferedIsNeverSent() async {
        let settings = FakeBucketSettings(versioning: .never)
        let model = BucketVersioningModel(current: .never, bucketHasObjectLock: false)
        await model.apply(.never, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        await model.apply(.suspended, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes.isEmpty)
        #expect(model.current == .never)
    }

    @MainActor @Test func aRefusedWriteKeepsTheStateAndSaysWhy() async {
        let settings = FakeBucketSettings(
            versioning: .never, writeError: RemoteFSError.finding(.operationNotSupported))
        let model = BucketVersioningModel(current: .never, bucketHasObjectLock: false)
        await model.apply(.enabled, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        #expect(settings.writes.count == 1)
        #expect(model.current == .never)
        #expect(model.applyFailure == RemoteFSFinding.operationNotSupported.message)
        #expect(!model.isApplying)
    }

    /// A raw `reason` can carry the endpoint the user typed, and that field
    /// takes `scheme://KEY:SECRET@host` as ordinary input. The message is a
    /// fixed sentence, so nothing of the error reaches the screen.
    ///
    /// The value is a named constant and the `Bool` is computed before the
    /// expectation, so a failure cannot print it (CLAUDE.md, "A value a test
    /// must not leak has two exits, not one").
    @MainActor @Test func aFailureNeverQuotesTheReasonItWasGiven() async {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let settings = FakeBucketSettings(
            versioning: .never, writeError: RemoteFSError.protocolError(reason: planted))
        let model = BucketVersioningModel(current: .never, bucketHasObjectLock: false)
        await model.apply(.enabled, bucket: "b", via: settings, locks: ObjectLockStateCache(settings: settings))
        let text = model.applyFailure ?? ""
        let quoted = text.contains("SECRETEXAMPLE") || text.contains("store.invalid")
        #expect(!text.isEmpty)
        #expect(!quoted)
    }

    @MainActor @Test func aMissingPermissionHasItsOwnSentence() {
        let denied = BucketVersioningModel.message(
            for: RemoteFSError.permissionDenied(path: "/b"), applying: true)
        let generic = BucketVersioningModel.message(
            for: CocoaError(.fileReadUnknown), applying: true)
        #expect(!denied.isEmpty)
        #expect(!generic.isEmpty)
        #expect(denied != generic)
    }

    // MARK: - The catalogue

    /// Every line the sheet can show resolves in every shipped language: a key
    /// missing from one catalogue silently shows the English default there.
    /// The sentinel is absurd on purpose, so a hit can only be a real entry.
    @MainActor @Test func everyLineResolvesInAllFourLocales() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        let lines = Self.everyLine()
        for line in lines {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) {
                    L10n.string(line.key, sentinel)
                }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
            }
        }
        #expect(lines.count > 0)
    }

    /// The English default a line carries must be what the `en` catalogue
    /// says: a second copy of a string that disagrees with the first is how the
    /// English UI drifts from its default.
    @MainActor @Test func theEnglishCatalogueSaysTheDefault() {
        let lines = Self.everyLine()
        for line in lines {
            let english = L10n.$localeOverride.withValue("en") {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(english == line.english, "\(line.key)")
        }
        #expect(lines.count > 0)
    }

    /// The two warnings are the sheet's reason for existing, so they are held
    /// to more than "present": in every language they are not the same
    /// sentence, and the German one is not the English one.
    @MainActor @Test func theTwoWarningsAreDistinctInEveryLanguage() throws {
        let enable = try #require(BucketVersioningModel(current: .never, bucketHasObjectLock: false).warning)
        let suspend = try #require(BucketVersioningModel(current: .enabled, bucketHasObjectLock: false).warning)
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) { (enable.text, suspend.text) }
            #expect(texts.0 != texts.1, "\(locale)")
        }
        let inGerman = L10n.$localeOverride.withValue("de") { suspend.text }
        let inEnglish = L10n.$localeOverride.withValue("en") { suspend.text }
        #expect(inGerman != inEnglish)
    }

    /// The sheet's source is read for the keys it uses, so a key used in the
    /// view and absent from `everyLine()` (and therefore from the checks above)
    /// is a red here. The comment-free view keeps the string literals; the
    /// positive half is that the scan found some.
    @MainActor @Test func everyKeyTheSheetUsesIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/BucketVersioningSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(
            source.matches(of: #/"(s3\.versioning\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let uncovered = used.subtracting(Set(Self.everyLine().map(\.key))).sorted()
        #expect(uncovered.isEmpty, "\(uncovered)")
    }

    /// The lock sentence says what is true and no more: this bucket uses
    /// Object Lock, so its versioning cannot be switched off. It does not say
    /// the store refuses anything, because that fact is AWS's documentation
    /// (spec section 4) and nobody here observed a refusal. The positive
    /// halves are that it names Object Lock and says "cannot"; the negatives
    /// are the words of a claimed refusal. In every language the sentence is
    /// its own, not the English one.
    @MainActor @Test func theLockSentenceClaimsNoRefusalAndIsSaidInEveryLanguage() {
        let line = BucketVersioningModel.objectLockKeepsItOnLine
        let english = L10n.$localeOverride.withValue("en") { line.text.lowercased() }
        let namesTheLock = english.contains("object lock")
        let saysCannot = english.contains("cannot")
        #expect(namesTheLock)
        #expect(saysCannot)
        for claim in ["refus", "reject", "denied", "error", "fail", "store"] {
            let claimed = english.contains(claim)
            #expect(!claimed, "\(claim)")
        }
        for locale in ["de", "fr", "pl"] {
            let said = L10n.$localeOverride.withValue(locale) { line.text }
            #expect(said != line.english, "\(locale)")
            #expect(!said.isEmpty)
        }
    }

    // MARK: - Wiring (source scans)

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent(relativePath))
    }

    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What the compiler cannot see: that the sheet's read is handed the
    /// sheet's own cache (the parameter is required, so it cannot be left out,
    /// but nothing stops a call that passes some other one), that the opener
    /// puts the SESSION's cache in the item, and that the window builds the
    /// sheet from the item's cache and not from a fresh one. The first scan
    /// ends on a count, so a sheet that stopped reading cannot satisfy it.
    @Test func theCacheTravelsFromTheSessionToTheRead() throws {
        let sheet = try Self.code("MacSCPAppKit/BucketVersioningSheet.swift")
        let reads = sheet.matches(of: #/model\.read\(([^)]*)\)/#).map { Self.flattened(String($0.output.1)) }
        #expect(reads == ["bucket: bucket, from: settings, locks: locks"])

        let dispatcher = try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        let item = try #require(dispatcher.range(of: "BucketVersioningSheetItem("))
        let around = Self.flattened(String(dispatcher[item.lowerBound...].prefix(400)))
        #expect(around.contains("bucket: bucket"))
        #expect(around.contains("states: session.objectLockStates"))

        let sheets = try Self.code("MacSCPAppKit/ContentView+Sheets.swift")
        let presented = try #require(sheets.range(of: ".sheet(item: $versioningSheetItem)"))
        let closure = Self.flattened(String(sheets[presented.upperBound...].prefix(300)))
        #expect(closure.contains("BucketVersioningSheet("))
        #expect(closure.contains("locks: item.states"))
    }

    /// **Fix round 1, I2: the sheet's body draws the blocked sentence.** The
    /// model can be right and the sentence still absent from the screen, which
    /// is the one user-visible half of Task 11b; deleting the `Text` that draws
    /// it left the whole suite green (probe P8, measured GREEN on 31c39ec1).
    /// The `.known` branch of `content` reads `model.blockedReason` and shows
    /// its text, beside the `model.warning` draw it sits after, which is the
    /// positive control that the slice is the branch that draws the model's
    /// lines at all.
    @Test func theKnownStateDrawsTheReasonNothingIsOffered() throws {
        let source = try Self.code("MacSCPAppKit/BucketVersioningSheet.swift")
        let content = try #require(source.range(of: "@ViewBuilder private var content: some View"))
        let body = Self.flattened(String(source[content.upperBound...]))
        let known = try #require(body.range(of: "case .known:"))
        let branch = String(body[known.upperBound...])
        let warning = try #require(branch.range(of: "if let warning = model.warning { Text(warning.text)"))
        let blocked = try #require(
            branch.range(of: "if let blocked = model.blockedReason { Text(blocked.text)"))
        #expect(warning.lowerBound < blocked.lowerBound)
    }

    /// Every line the sheet can show, for every state it can be in.
    @MainActor private static func everyLine() -> [CatalogueLine] {
        var lines = BucketVersioningModel.fixedLines
        for state in BucketVersioning.allCases {
            lines += BucketVersioningModel(current: state, bucketHasObjectLock: false).lines
        }
        lines += BucketVersioningModel(current: .enabled, bucketHasObjectLock: true).lines
        return lines
    }
}
