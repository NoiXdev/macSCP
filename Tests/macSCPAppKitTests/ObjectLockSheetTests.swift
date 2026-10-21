import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The per-file Object Lock sheet's decisions, and the cache that tells it
/// whether a bucket has Object Lock at all.
///
/// **This sheet carries the one operation on this branch that cannot be taken
/// back.** A COMPLIANCE retention is lifted by nobody until its date, not by
/// the account owner and not with a bypass (measured on the rig 2026-10-19:
/// `403` even with the bypass header). The maintainer asked for COMPLIANCE
/// with a clear warning, so what these tests hold the model to is that no path
/// to a COMPLIANCE write goes around the acknowledgement of the date being
/// written -- not that the sheet looks right, which no test here can see.
///
/// No test in this project draws a SwiftUI view. These are the decisions the
/// view reads, the catalogue entries it looks its text up in, and scans of
/// the view's own source.
@Suite("Object Lock sheet")
struct ObjectLockSheetTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    /// A fixed "now", so no test depends on the day it runs: 2026-09-21.
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// 2027-01-01 00:00 UTC: after `now`, as the brief's four cases use it.
    static let newYear = Date(timeIntervalSince1970: 1_798_761_600)
    /// 2027-01-01 12:00 UTC: January in every time zone there is, for the
    /// tests that look at the month's name.
    static let newYearNoon = Date(timeIntervalSince1970: 1_798_804_800)
    /// A day before `now`.
    static let yesterday = Date(timeIntervalSince1970: 1_789_913_600)

    // MARK: - The brief's four cases

    @MainActor @Test func complianceCannotBeRunUntilItIsAcknowledged() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        #expect(model.canRun == false)
        model.acknowledged = true
        #expect(model.canRun == true)
    }

    @MainActor @Test func governanceNeedsNoAcknowledgement() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .governance
        #expect(model.canRun == true)
    }

    @MainActor @Test func theAcknowledgementNamesTheDate() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        #expect(model.acknowledgementKey == "s3.objectLock.complianceAcknowledgement %@")
        #expect(model.acknowledgementDateText.isEmpty == false)
    }

    @MainActor @Test func aBucketWithoutObjectLockOffersNoLockAtAll() {
        // Review Focus 5: the rig would accept the enabling call, so the refusal
        // is macSCP's own.
        let model = ObjectLockModel(bucketHasLock: false, now: { Self.now })
        #expect(model.canRun == false)
        #expect(model.unavailableReasonKey == "s3.objectLock.notEnabledOnThisBucket")
    }

    // MARK: - The acknowledgement belongs to the date it was given for

    /// A tick is a statement about one date. Changing the date, or the mode and
    /// back, must not leave the statement standing for a date nobody read.
    @MainActor @Test func changingTheDateTakesTheAcknowledgementBack() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        model.acknowledged = true
        #expect(model.canRun)
        model.retainUntil = Self.newYear.addingTimeInterval(86_400)
        #expect(!model.acknowledged)
        #expect(!model.canRun)
    }

    @MainActor @Test func leavingComplianceAndComingBackTakesTheAcknowledgementBack() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        model.acknowledged = true
        model.mode = .governance
        model.mode = .compliance
        #expect(!model.acknowledged)
        #expect(!model.canRun)
    }

    /// A binding that writes back the value it already holds (a redraw does) is
    /// not a change and does not take the tick away.
    @MainActor @Test func writingBackTheSameValueKeepsTheAcknowledgement() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        model.acknowledged = true
        model.mode = .compliance
        model.retainUntil = Self.newYear
        #expect(model.acknowledged)
        #expect(model.canRun)
    }

    /// The positive beside the two above: a re-tick after a change works.
    @MainActor @Test func tickingAgainAfterAChangeRunsIt() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        model.acknowledged = true
        model.retainUntil = Self.newYear.addingTimeInterval(86_400)
        model.acknowledged = true
        #expect(model.canRun)
    }

    @MainActor @Test func aDateThatHasPassedCannotBeRunInEitherMode() {
        for mode in RetentionMode.allCases {
            let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
            model.mode = mode
            model.retainUntil = Self.yesterday
            model.acknowledged = true
            #expect(!model.canRun, "\(mode)")
            #expect(model.activeBlockers.contains(.dateNotInFuture), "\(mode)")
        }
    }

    /// The sentence names hours and minutes, and the picker edits hours and
    /// minutes: a start date with seconds would be a lock that ends later than
    /// the sentence says.
    @MainActor @Test func theStartingDateIsAWholeMinuteAWeekAhead() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        #expect(Calendar.current.component(.second, from: model.retainUntil) == 0)
        #expect(model.retainUntil > Self.now.addingTimeInterval(6 * 86_400))
        #expect(model.retainUntil < Self.now.addingTimeInterval(8 * 86_400))
        #expect(model.mode == .governance, "the sheet starts on the reversible choice")
        #expect(!model.acknowledged)
    }

    // MARK: - The warning is what the person is shown

    /// **The link between choosing COMPLIANCE and being shown the warning.**
    /// Every other test that names the warning reads the constant; this one
    /// reads what the form reads, `modeDetailLine`, by `key` and both ways: the
    /// GOVERNANCE arm is the positive beside the negative, so a line that
    /// answered the warning for every mode is red as well. Fix round 1,
    /// Important I-1: with COMPLIANCE's line replaced by the governance note,
    /// 79 tests ran green.
    @MainActor @Test func choosingComplianceShowsTheWarningAndGovernanceDoesNot() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        let shownForCompliance = model.modeDetailLine?.key
        model.mode = .governance
        let shownForGovernance = model.modeDetailLine?.key
        #expect(shownForCompliance == ObjectLockModel.complianceWarningLine.key)
        #expect(shownForGovernance == ObjectLockLines.governanceDetail.key)
        #expect(shownForCompliance != shownForGovernance)
    }

    /// The legal-hold sheet has no mode, and says nothing about one.
    @MainActor @Test func theLegalHoldSheetShowsNoModeLine() {
        let hold = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { Self.now })
        hold.mode = .compliance
        #expect(hold.modeDetailLine == nil)
        let retention = ObjectLockModel(focus: .retention, bucketHasLock: true, now: { Self.now })
        #expect(retention.modeDetailLine != nil)
    }

    /// And the form puts that line on screen: the retention form reads
    /// `model.modeDetailLine`, and the sheet shows that form for the retention
    /// focus. Deleting the `Text` that draws the warning left the model right
    /// and the screen without it (fix round 1, I-1, the second probe).
    @Test func theRetentionFormDrawsTheLineUnderTheModeChoice() throws {
        let source = try Self.code("MacSCPAppKit/ObjectLockSheet.swift")
        let form = try #require(source.range(of: "private var retentionForm: some View"))
        let rest = source[form.upperBound...]
        let end = try #require(rest.range(of: "private var legalHoldForm: some View"))
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("model.modeDetailLine"))
        #expect(body.contains(".text"))
        let present = try #require(source.range(of: "private var present: some View"))
        let presentBody = String(source[present.upperBound...].prefix(1500))
        #expect(presentBody.contains("retentionForm"))
        #expect(presentBody.contains("legalHoldForm"))
    }

    // MARK: - What the governance note promises

    /// A governance retention can be lifted by someone holding the bypass
    /// permission, and macSCP sends no bypass. The note says the first and not
    /// the second is available here: the fact stays (it is why GOVERNANCE needs
    /// no acknowledgement), the promise goes. Each language names the app in
    /// the limit, and the English no longer says "still".
    @MainActor @Test func theGovernanceNoteSaysItCannotBeLiftedFromHere() {
        for locale in Self.locales {
            let text = L10n.$localeOverride.withValue(locale) { ObjectLockLines.governanceDetail.text }
            let namesTheApp = text.contains("macSCP")
            #expect(namesTheApp, "\(locale)")
        }
        let english = L10n.$localeOverride.withValue("en") { ObjectLockLines.governanceDetail.text.lowercased() }
        let promises = english.contains("still")
        let limit = english.contains("not from macscp")
        let fact = english.contains("right permission")
        #expect(!promises)
        #expect(limit)
        #expect(fact)
    }

    /// **The refusal keeps the rule flat and hedges which cause applied.** The
    /// governance note states the rule ("not from macSCP"); the refusal that
    /// follows an attempt cannot know whether the retention or the key was the
    /// cause, so the uncertainty sits in the "either ... or" and not in the rule.
    /// Fix round 2: the round-1 wording put the hedge on the rule and so
    /// hedged, two sentences from where it was asserted, one fact. Each language
    /// names the app in the rule, as the governance note does.
    @MainActor @Test func theRefusalKeepsTheRuleFlatAndHedgesTheCause() {
        for locale in Self.locales {
            let text = L10n.$localeOverride.withValue(locale) { ObjectLockLines.retentionRefused.text }
            let namesTheApp = text.contains("macSCP")
            #expect(namesTheApp, "\(locale)")
        }
        let english = L10n.$localeOverride.withValue("en") { ObjectLockLines.retentionRefused.text.lowercased() }
        let eitherOr = english.contains("either") && english.contains(", or your access key")
        let flatRule = english.contains("cannot be shortened from macscp")
        let hedgedRule = english.contains("perhaps") || english.contains("may not be shortened")
        #expect(eitherOr)
        #expect(flatRule)
        #expect(!hedgedRule)
    }

    // MARK: - A COMPLIANCE retention in force cannot be weakened

    @MainActor private static func complianceHeld(until date: Date) -> ObjectLockModel {
        let model = ObjectLockModel(
            focus: .retention, bucketLock: .present,
            current: ObjectLockModel.Current(
                retention: ObjectRetention(mode: .compliance, retainUntil: date), legalHold: false),
            now: { Self.now })
        model.retainUntil = Self.newYear
        return model
    }

    /// The attempt is stopped, with a sentence, instead of being sent and
    /// explained afterwards by a refusal that names two other causes (fix
    /// round 2, NEW-2). GOVERNANCE over a COMPLIANCE retention still in force is
    /// the sheet's own starting state for such a file.
    @MainActor @Test func governanceOverAComplianceRetentionInForceIsStoppedAndSaysWhy() async {
        let model = Self.complianceHeld(until: Self.newYear)
        #expect(model.mode == .governance)
        #expect(model.activeBlockers == [.complianceInForce])
        #expect(!model.canRun)
        #expect(model.explanation?.key == ObjectLockModel.complianceInForceLine.key)
        let probe = FakeBucketSettings(lock: .init())
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.isEmpty)
    }

    /// The positives beside it: COMPLIANCE over COMPLIANCE is the ordinary
    /// acknowledged write; GOVERNANCE over a GOVERNANCE one is unaffected; and
    /// a COMPLIANCE retention whose date has passed is no longer in force.
    @MainActor @Test func onlyAComplianceRetentionStillInForceStopsGovernance() {
        let extend = Self.complianceHeld(until: Self.newYear)
        extend.mode = .compliance
        extend.acknowledged = true
        #expect(extend.canRun)

        let expired = Self.complianceHeld(until: Self.yesterday)
        #expect(expired.mode == .governance)
        #expect(!expired.activeBlockers.contains(.complianceInForce))
        #expect(expired.canRun)

        let governanceHeld = ObjectLockModel(
            focus: .retention, bucketLock: .present,
            current: ObjectLockModel.Current(
                retention: ObjectRetention(mode: .governance, retainUntil: Self.newYear), legalHold: false),
            now: { Self.now })
        #expect(governanceHeld.canRun)

        let hold = ObjectLockModel(
            focus: .legalHold, bucketLock: .present,
            current: ObjectLockModel.Current(
                retention: ObjectRetention(mode: .compliance, retainUntil: Self.newYear), legalHold: false),
            now: { Self.now })
        hold.legalHold = true
        #expect(hold.canRun, "a legal hold is not a retention and is not stopped by one")
    }

    // MARK: - Where the form starts

    /// A file already locked past the usual starting date is not offered a
    /// shortening as its default.
    @MainActor @Test func theFormStartsAtTheRetentionAlreadyInForceWhenThatIsLater() async {
        let later = Self.now.addingTimeInterval(400 * 86_400 + 17)
        let probe = FakeBucketSettings(
            lock: .init(retention: ObjectRetention(mode: .governance, retainUntil: later)))
        let model = ObjectLockModel(now: { Self.now })
        let usual = model.retainUntil
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.retainUntil >= later)
        #expect(model.retainUntil < later.addingTimeInterval(60))
        #expect(model.retainUntil > usual)
        #expect(Calendar.current.component(.second, from: model.retainUntil) == 0)
    }

    @MainActor @Test func aRetentionEarlierThanTheUsualStartLeavesTheUsualStart() async {
        let sooner = Self.now.addingTimeInterval(86_400)
        let probe = FakeBucketSettings(
            lock: .init(retention: ObjectRetention(mode: .governance, retainUntil: sooner)))
        let model = ObjectLockModel(now: { Self.now })
        let usual = model.retainUntil
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.retainUntil == usual)
    }

    /// Seeding the date is itself a change of the date, and a tick does not
    /// survive a change: whatever was ticked before the read landed is not
    /// ticked after it. (`ObjectLockModel.load` clears it on purpose, as the
    /// bucket default's does; fix round 1, Minor 1.)
    @MainActor @Test func aLoadTakesAnyAcknowledgementBack() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(now: { Self.now })
        model.mode = .compliance
        model.acknowledged = true
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(!model.acknowledged)
        #expect(model.mode == .compliance, "the person's choice of mode is not the read's to change")
        #expect(!model.canRun)
    }

    // MARK: - The date is a date for the reader

    /// "A date in a sentence is formatted for the locale, never interpolated
    /// raw." The month's name is the visible difference between four locales,
    /// and the raw forms must not appear. Noon UTC, so it is January wherever
    /// the test runs.
    @Test func theDateIsWrittenInTheReadersLanguage() {
        let expected = ["en": "January", "de": "Januar", "fr": "janvier", "pl": "stycznia"]
        for locale in Self.locales {
            let text = ObjectLockDates.text(Self.newYearNoon, localeCode: locale)
            let month = expected[locale] ?? ""
            let hasMonth = text.contains(month)
            #expect(hasMonth, "\(locale)")
            let raw = text.contains("1798804800") || text.contains("2027-01-01") || text.contains("T12:")
            #expect(!raw, "\(locale)")
        }
        #expect(expected.count == Self.locales.count)
    }

    @MainActor @Test func theAcknowledgementSentenceCarriesTheFormattedDate() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYearNoon
        for locale in Self.locales {
            let sentence = L10n.$localeOverride.withValue(locale) { model.acknowledgementSentence }
            let date = ObjectLockDates.text(Self.newYearNoon, localeCode: locale)
            let carries = sentence.contains(date)
            let unfilled = sentence.contains("%@")
            #expect(carries, "\(locale)")
            #expect(!unfilled, "\(locale)")
        }
    }

    // MARK: - The words about something permanent

    /// Plain words, naming what cannot be undone and until when. The negative
    /// half (no store mechanics) is beside the positive (it does say it).
    @MainActor @Test func theComplianceWordsSayWhatCannotBeUndoneInPlainEnglish() {
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYearNoon
        let texts = L10n.$localeOverride.withValue("en") {
            [model.acknowledgementSentence, ObjectLockModel.complianceWarningLine.text]
        }
        for text in texts {
            let lowered = text.lowercased()
            #expect(lowered.contains("nobody") || lowered.contains("not you"), "\(text)")
            for jargon in ["bypass", "header", "403", "s3", "x-amz", "version id", "delete marker"] {
                let leaked = lowered.contains(jargon)
                #expect(!leaked, "\(jargon)")
            }
        }
        let acknowledgement = texts[0].lowercased()
        #expect(acknowledgement.contains("undone"))
        #expect(acknowledgement.contains("before"))
    }

    // MARK: - The bucket's lock, read once per bucket

    @MainActor @Test func theLockStateIsReadOncePerBucket() async throws {
        let probe = FakeBucketSettings(lock: .init(hasLock: true))
        let cache = ObjectLockStateCache(settings: probe)
        _ = try await cache.hasObjectLock("b")
        _ = try await cache.hasObjectLock("b")
        #expect(probe.hasLockReads == ["b"])
        _ = try await cache.hasObjectLock("other")
        #expect(probe.hasLockReads == ["b", "other"])
    }

    /// The correction to Step 4, dated 2026-10-21: the cache asks the question
    /// Core answers for exactly this purpose, and never the one that cannot
    /// tell "no Object Lock" from "Object Lock with no default yet".
    @MainActor @Test func theCacheAsksWhetherThereIsALockAndNotWhetherThereIsADefault() async throws {
        let probe = FakeBucketSettings(lock: .init(hasLock: true, bucketDefault: nil))
        let cache = ObjectLockStateCache(settings: probe)
        let answer = try await cache.hasObjectLock("b")
        #expect(answer == true)
        #expect(probe.hasLockReads == ["b"])
        #expect(probe.defaultReads.isEmpty)
    }

    /// The main case the correction exists for: a lock-enabled bucket with no
    /// default, which is exactly where a first retention is set, is offered.
    @MainActor @Test func aLockedBucketWithNoDefaultIsOfferedTheLock() async {
        let probe = FakeBucketSettings(lock: .init(hasLock: true, bucketDefault: nil))
        let cache = ObjectLockStateCache(settings: probe)
        let model = ObjectLockModel(now: { Self.now })
        await model.load(key: "a.txt", bucket: "b", via: probe, cache: cache)
        #expect(model.bucketLock == .present)
        #expect(model.unavailableReasonKey == nil)
        #expect(model.canRun == true)
    }

    /// The store's "no lock" answer is an answer, kept: it is not retried like
    /// a failure.
    @MainActor @Test func aBucketWithNoLockIsRememberedAsSuch() async throws {
        let probe = FakeBucketSettings(lock: .init(hasLock: false))
        let cache = ObjectLockStateCache(settings: probe)
        let first = try await cache.hasObjectLock("b")
        let second = try await cache.hasObjectLock("b")
        #expect(first == false)
        #expect(second == false)
        #expect(probe.hasLockReads.count == 1)
    }

    /// A failure is not an answer. The next ask reads again, and the failed
    /// read left nothing behind that reads as "no lock".
    @MainActor @Test func aFailedReadIsNotRememberedAsAnAnswer() async throws {
        let failing = FakeBucketSettings(
            lock: .init(hasLock: true, hasLockError: RemoteFSError.finding(.operationNotSupported)))
        let cache = ObjectLockStateCache(settings: failing)
        await #expect(throws: RemoteFSError.self) { _ = try await cache.hasObjectLock("b") }
        await #expect(throws: RemoteFSError.self) { _ = try await cache.hasObjectLock("b") }
        #expect(failing.hasLockReads == ["b", "b"])
    }

    /// Two surfaces opening on one bucket together share one read.
    @MainActor @Test func twoAsksAtOnceShareOneRead() async throws {
        let probe = FakeBucketSettings(lock: .init(hasLock: true))
        let cache = ObjectLockStateCache(settings: probe)
        async let first = cache.hasObjectLock("b")
        async let second = cache.hasObjectLock("b")
        let answers = try await [first, second]
        #expect(answers == [true, true])
        #expect(probe.hasLockReads == ["b"])
    }

    // MARK: - Loading

    @MainActor @Test func aLoadReadsTheCurrentRetentionOfTheNamedKey() async {
        let held = ObjectRetention(mode: .governance, retainUntil: Self.newYear)
        let probe = FakeBucketSettings(lock: .init(retention: held))
        let model = ObjectLockModel(focus: .retention, now: { Self.now })
        await model.load(
            key: "photos/a.txt", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.current?.retention == held)
        #expect(probe.retentionReads == ["photos/a.txt"])
        #expect(probe.legalHoldReads.isEmpty)
    }

    @MainActor @Test func aLegalHoldLoadReadsTheHoldAndStartsTheToggleWhereTheStoreIs() async {
        let probe = FakeBucketSettings(lock: .init(legalHold: true))
        let model = ObjectLockModel(focus: .legalHold, now: { Self.now })
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.current?.legalHold == true)
        #expect(model.legalHold == true)
        #expect(probe.retentionReads.isEmpty)
        #expect(model.canRun == false)  // nothing to change yet
    }

    @MainActor @Test func aBucketWithNoLockIsNotAskedAboutTheFile() async {
        let probe = FakeBucketSettings(lock: .init(hasLock: false))
        let model = ObjectLockModel(now: { Self.now })
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.bucketLock == .absent)
        #expect(model.unavailableReasonKey == "s3.objectLock.notEnabledOnThisBucket")
        #expect(probe.retentionReads.isEmpty)
        #expect(model.canRun == false)
    }

    @MainActor @Test func aFailedLockReadSaysSoAndOffersNothing() async {
        let probe = FakeBucketSettings(
            lock: .init(hasLockError: RemoteFSError.finding(.operationNotSupported)))
        let model = ObjectLockModel(now: { Self.now })
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.bucketLock == .failed(RemoteFSFinding.operationNotSupported.message))
        #expect(model.unavailableReasonKey == nil)
        #expect(model.canRun == false)
    }

    @MainActor @Test func aFailedFileReadBlocksRunning() async {
        let probe = FakeBucketSettings(
            lock: .init(readError: RemoteFSError.finding(.operationNotSupported)))
        let model = ObjectLockModel(now: { Self.now })
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.bucketLock == .present)
        #expect(model.current == nil)
        #expect(model.currentFailure == RemoteFSFinding.operationNotSupported.message)
        #expect(model.canRun == false)
    }

    // MARK: - Running

    @MainActor @Test func aGovernanceRetentionIsWrittenOnceToTheNamedKeyAndShownAsTheStoreHasIt() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .governance
        model.retainUntil = Self.newYear
        await model.run(key: "photos/a.txt", bucket: "macscp-seed", via: probe)
        #expect(
            probe.retentionWrites == [
                FakeBucketSettings.RetentionWrite(
                    retention: ObjectRetention(mode: .governance, retainUntil: Self.newYear),
                    key: "photos/a.txt", bucket: "macscp-seed", versionId: nil)
            ])
        #expect(model.current?.retention == ObjectRetention(mode: .governance, retainUntil: Self.newYear))
        #expect(model.applyFailure == nil)
        #expect(model.isSaved)
        #expect(!model.isApplying)
        #expect(probe.legalHoldWrites.isEmpty)
    }

    /// The acknowledged date is the written date, and the tick is spent: a
    /// second COMPLIANCE write needs a second tick.
    @MainActor @Test func aComplianceRetentionIsWrittenOnlyForTheDateAcknowledgedAndSpendsTheTick() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.isEmpty, "sent without an acknowledgement")
        model.acknowledged = true
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.map(\.retention.retainUntil) == [Self.newYear])
        #expect(probe.retentionWrites.map(\.retention.mode) == [.compliance])
        #expect(!model.acknowledged)
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.count == 1, "a spent acknowledgement ran a second write")
    }

    @MainActor @Test func aRefusedWriteKeepsTheStateAndSaysWhyInAFixedSentence() async {
        let probe = FakeBucketSettings(
            lock: .init(writeError: RemoteFSError.permissionDenied(path: "/b/a")))
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.retainUntil = Self.newYear
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.count == 1)
        #expect(model.current?.retention == nil)
        #expect(model.applyFailure == ObjectLockLines.retentionRefused.text)
        #expect(!model.isSaved)
        #expect(!model.isApplying)
    }

    /// The same two exits as everywhere else: the code under test and the test.
    /// The planted value is a named constant and the `Bool` is computed before
    /// the expectation, so a failure cannot print it.
    @MainActor @Test func aFailureNeverQuotesTheReasonItWasGiven() async {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let probe = FakeBucketSettings(lock: .init(writeError: RemoteFSError.protocolError(reason: planted)))
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.retainUntil = Self.newYear
        await model.run(key: "a", bucket: "b", via: probe)
        let text = model.applyFailure ?? ""
        let quoted = text.contains("SECRETEXAMPLE") || text.contains("store.invalid")
        #expect(!text.isEmpty)
        #expect(!quoted)
    }

    @MainActor @Test func aLegalHoldIsPlacedAndLiftedOnTheNamedKey() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { Self.now })
        model.legalHold = true
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(
            probe.legalHoldWrites == [
                FakeBucketSettings.LegalHoldWrite(on: true, key: "a", bucket: "b", versionId: nil)
            ])
        #expect(model.current?.legalHold == true)
        // Placed; the toggle now equals the store, so there is nothing to run.
        #expect(!model.canRun)
        model.legalHold = false
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.legalHoldWrites.map(\.on) == [true, false])
    }

    /// A refused hold is not a refused retention: the sentence about a
    /// retention that may not be shortened would be false of it.
    @MainActor @Test func aRefusedHoldDoesNotTalkAboutRetentions() async {
        let probe = FakeBucketSettings(
            lock: .init(writeError: RemoteFSError.permissionDenied(path: "/b/a")))
        let model = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { Self.now })
        model.legalHold = true
        await model.run(key: "a", bucket: "b", via: probe)
        #expect(probe.legalHoldWrites.count == 1)
        #expect(model.applyFailure == ObjectLockLines.denied.text)
        #expect(model.applyFailure != ObjectLockLines.retentionRefused.text)
    }

    /// The sheet that opened for a legal hold has no way to place a retention,
    /// whatever its other fields hold. The positive half: the same model with
    /// the retention focus does write.
    @MainActor @Test func theLegalHoldSheetNeverWritesARetention() async {
        let probe = FakeBucketSettings(lock: .init())
        let holdSheet = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { Self.now })
        holdSheet.mode = .compliance
        holdSheet.retainUntil = Self.newYear
        holdSheet.acknowledged = true
        holdSheet.legalHold = true
        await holdSheet.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.isEmpty)
        #expect(probe.legalHoldWrites.count == 1)

        let retentionSheet = ObjectLockModel(focus: .retention, bucketHasLock: true, now: { Self.now })
        retentionSheet.legalHold = true
        await retentionSheet.run(key: "a", bucket: "b", via: probe)
        #expect(probe.retentionWrites.count == 1)
        #expect(probe.legalHoldWrites.count == 1, "the retention sheet placed a hold")
    }

    /// A write in flight blocks a second one. The fake holds the write until
    /// released, so the state is observed rather than raced.
    ///
    /// **A hang bound, and why this test needs one.** With the in-flight guard
    /// gone the second `run` reaches the fake, which holds it until `release`,
    /// and the test never gets to the line that raises it: measured on
    /// 2026-10-21 by planting out `guard canRun` in `run`, which left the run
    /// parked for ten minutes with no verdict. The limit turns that into a red;
    /// the `defer` lets go of anything still held when the test ends either way.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSecondRunWhileOneIsInFlightSendsNothing() async {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        defer { release.signal() }
        let probe = FakeBucketSettings(lock: .init(writeEntered: entered, writeRelease: release))
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        model.acknowledged = true
        let first = Task { @MainActor in await model.run(key: "a", bucket: "b", via: probe) }
        _ = await entered.wait()
        #expect(model.isApplying)
        #expect(model.activeBlockers.contains(.applying))
        #expect(!model.canRun)
        await model.run(key: "a", bucket: "b", via: probe)
        release.signal()
        await first.value
        #expect(probe.retentionWrites.count == 1)
    }

    // MARK: - Every state the sheet can be in

    /// What the model's decision inputs can be, as data. The cross product is
    /// every combination of them with the file's own current HOLD held empty
    /// (`model(for:)` always builds `legalHold: false`) and its current
    /// RETENTION either absent or a COMPLIANCE one still in force (`Held`); no
    /// combination is written out by hand, so a state nobody thought of is
    /// still run. A file that already carries a hold, or a GOVERNANCE retention,
    /// is covered by the loading tests (`aLoadReadsTheCurrentRetentionOfTheNamedKey`,
    /// `aLegalHoldLoadReadsTheHoldAndStartsTheToggleWhereTheStoreIs`,
    /// `aLegalHoldIsPlacedAndLiftedOnTheNamedKey`), not by this sweep.
    ///
    /// **Corrected 2026-10-21 (fix round 2).** The paragraph above read, in
    /// part, verbatim: "every combination of them with the file's own
    /// current values held empty (`model(for:)` always builds `Current(retention: nil, legalHold: false)`)".
    /// The retention is varied now, because a COMPLIANCE retention in force is
    /// the one input that makes a mode the sheet starts on unsaveable
    /// (`RunBlocker.complianceInForce`), and a blocker the sweep cannot reach is
    /// one `everyBlockerCanBeTheOnlyReasonRunIsOff` cannot hold.
    ///
    /// **Corrected 2026-10-21 (fix round 1, Minor 5).** This comment first read,
    /// verbatim: "What the model's facts can be, as data. The cross product is
    /// the sheet's state space; no combination is written out by hand, so a
    /// state nobody thought of is still run." It was not the sheet's state
    /// space: the current values were never varied. Widening the sweep was
    /// weighed and left, since the oracle's legal-hold arm would need a fourth
    /// input and the loading tests already hold the non-empty cases.
    enum LockFact: CaseIterable { case reading, failed, absent, present }
    enum Currency: CaseIterable { case unread, read }
    enum Day: CaseIterable { case past, future }
    enum Held: CaseIterable { case nothing, complianceInForce }

    struct Scenario: CustomStringConvertible {
        var focus: ObjectLockModel.Focus
        var lock: LockFact
        var current: Currency
        var mode: RetentionMode
        var acknowledged: Bool
        var day: Day
        var holdWanted: Bool
        var held: Held

        var description: String {
            "\(focus) lock=\(lock) current=\(current) \(mode) ack=\(acknowledged) day=\(day) hold=\(holdWanted) held=\(held)"
        }

        /// The rule, stated a second time and from the other end: what must be
        /// true for a write to be allowed at all. `ObjectLockModel` states it
        /// as a list of blockers; this is the conjunction.
        var mayWrite: Bool {
            guard lock == .present, current == .read else { return false }
            switch focus {
            case .retention:
                // A COMPLIANCE retention in force cannot be weakened, so GOVERNANCE
                // over it is not a change the sheet will send.
                let weakens = held == .complianceInForce && mode == .governance
                return day == .future && (mode == .governance || acknowledged) && !weakens
            case .legalHold:
                return holdWanted  // the store starts without a hold, so wanting one is the change
            }
        }
    }

    static var scenarios: [Scenario] {
        var all: [Scenario] = []
        for focus in ObjectLockModel.Focus.allCases {
            for lock in LockFact.allCases {
                for current in Currency.allCases {
                    for mode in RetentionMode.allCases {
                        for acknowledged in [false, true] {
                            for day in Day.allCases {
                                for holdWanted in [false, true] {
                                    for held in Held.allCases {
                                        all.append(
                                            Scenario(
                                                focus: focus, lock: lock, current: current, mode: mode,
                                                acknowledged: acknowledged, day: day,
                                                holdWanted: holdWanted, held: held))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    @MainActor static func model(for scenario: Scenario) -> ObjectLockModel {
        let lock: ObjectLockModel.BucketLock =
            switch scenario.lock {
            case .reading: .reading
            case .failed: .failed("x")
            case .absent: .absent
            case .present: .present
            }
        let held: ObjectRetention? =
            scenario.held == .complianceInForce
            ? ObjectRetention(mode: .compliance, retainUntil: Self.newYear) : nil
        let current: ObjectLockModel.Current? =
            scenario.current == .read ? ObjectLockModel.Current(retention: held, legalHold: false) : nil
        let model = ObjectLockModel(
            focus: scenario.focus, bucketLock: lock, current: current, now: { Self.now })
        model.mode = scenario.mode
        model.retainUntil = scenario.day == .future ? Self.newYear : Self.yesterday
        model.acknowledged = scenario.acknowledged
        model.legalHold = scenario.holdWanted
        return model
    }

    /// The rule holds in every one of the states, and `run` agrees with
    /// `canRun`: it writes exactly when the model said it could, and what it
    /// writes in COMPLIANCE is the date that was acknowledged, in a bucket that
    /// has the lock, for a date still ahead.
    @MainActor @Test func inNoStateDoesRunWriteWhatCanRunRefused() async {
        let scenarios = Self.scenarios
        let focuses: Int = ObjectLockModel.Focus.allCases.count
        let locks: Int = LockFact.allCases.count
        let currencies: Int = Currency.allCases.count
        let modes: Int = RetentionMode.allCases.count
        let days: Int = Day.allCases.count
        let tickAndHold: Int = 2 * 2
        let heldStates: Int = Held.allCases.count
        let expectedCount: Int = focuses * locks * currencies * modes * days * tickAndHold * heldStates
        #expect(scenarios.count == expectedCount)
        var wrote = 0
        var refused = 0
        for scenario in scenarios {
            let model = Self.model(for: scenario)
            let probe = FakeBucketSettings(lock: .init())
            let allowed = model.canRun
            #expect(allowed == scenario.mayWrite, "\(scenario)")
            await model.run(key: "k", bucket: "b", via: probe)
            let writes = probe.retentionWrites.count + probe.legalHoldWrites.count
            #expect(writes == (allowed ? 1 : 0), "\(scenario)")
            if allowed { wrote += 1 } else { refused += 1 }
            // The sheet of one kind cannot write the other kind.
            switch scenario.focus {
            case .retention: #expect(probe.legalHoldWrites.isEmpty, "\(scenario)")
            case .legalHold: #expect(probe.retentionWrites.isEmpty, "\(scenario)")
            }
            // A COMPLIANCE retention in force is never written over with GOVERNANCE.
            for write in probe.retentionWrites where write.retention.mode == .governance {
                #expect(scenario.held == .nothing, "\(scenario)")
            }
            // The irreversible path, from the written side.
            for write in probe.retentionWrites where write.retention.mode == .compliance {
                #expect(scenario.acknowledged, "\(scenario)")
                #expect(scenario.lock == .present, "\(scenario)")
                #expect(write.retention.retainUntil == Self.newYear, "\(scenario)")
                #expect(write.retention.retainUntil > Self.now, "\(scenario)")
            }
        }
        // Both outcomes occur: neither half of the equality above is vacuous.
        #expect(wrote > 0)
        #expect(refused > 0)
    }

    /// Every blocker is reachable alone: a blocker no state can show by itself
    /// is one nothing is holding the sheet to. And every blocker that the
    /// sheet explains has an explanation in every language.
    @MainActor @Test func everyBlockerCanBeTheOnlyReasonRunIsOff() {
        var aloneIn = Set<String>()
        for scenario in Self.scenarios {
            let model = Self.model(for: scenario)
            if model.activeBlockers.count == 1, let only = model.activeBlockers.first {
                aloneIn.insert("\(only)")
            }
        }
        // `applying` needs a write in flight; `aSecondRunWhileOneIsInFlightSendsNothing`
        // is where it is held.
        let expected = Set(ObjectLockModel.RunBlocker.allCases.filter { $0 != .applying }.map { "\($0)" })
        #expect(aloneIn == expected)
        #expect(!expected.isEmpty)
    }

    // MARK: - Where a file is

    private static func context(
        listRoot: Bool, path: String = "/", bucket: String = "macscp-seed"
    ) -> ConnectionActionContext {
        ConnectionActionContext(
            settings: FakeBucketSettings(), rootIsContainerList: listRoot, remotePath: path,
            configuredBucket: bucket)
    }

    @Test func inOneBucketTheKeyIsThePathAndTheBucketIsTheConfiguredOne() {
        let target = ObjectLockTarget.resolve(
            path: "/photos//2026/a b.jpg", in: Self.context(listRoot: false, bucket: " macscp-seed "))
        #expect(target == ObjectLockTarget(bucket: "macscp-seed", key: "photos/2026/a b.jpg"))
    }

    @Test func atTheBucketListTheFirstComponentIsTheBucket() {
        let context = Self.context(listRoot: true)
        #expect(
            ObjectLockTarget.resolve(path: "/macscp-second/photos/a.jpg", in: context)
                == ObjectLockTarget(bucket: "macscp-second", key: "photos/a.jpg"))
        // The bucket itself is not a file.
        #expect(ObjectLockTarget.resolve(path: "/macscp-second", in: context) == nil)
        #expect(ObjectLockTarget.resolve(path: "/", in: context) == nil)
    }

    @Test func aPathWithNoKeyOrNoBucketIsNoTarget() {
        #expect(ObjectLockTarget.resolve(path: "/", in: Self.context(listRoot: false)) == nil)
        #expect(ObjectLockTarget.resolve(path: "/a", in: Self.context(listRoot: false, bucket: "  ")) == nil)
    }

    @Test func theTitleNamesTheFileAndNotItsFolder() {
        let target = ObjectLockTarget(bucket: "b", key: "photos/2026/a.jpg")
        #expect(target.fileName == "a.jpg")
    }

    // MARK: - The two file actions

    @Test func eachFileActionIsAnIdTheS3DescriptorContributesAndMapsToItsOwnFocus() {
        let contributed = BackendDescriptor.descriptor(for: .s3).fileActions
        let ids = Set(contributed.map(\.id))
        #expect(ids.contains("s3.presignedURL"))
        #expect(!ObjectLockFileAction.allCases.isEmpty)
        for action in ObjectLockFileAction.allCases {
            #expect(ids.contains(action.rawValue), "\(action.rawValue)")
        }
        let focuses = ObjectLockFileAction.allCases.map(\.focus)
        #expect(Set(focuses.map { "\($0)" }).count == ObjectLockFileAction.allCases.count)
        #expect(Set(focuses.map { "\($0)" }).count == ObjectLockModel.Focus.allCases.count)
    }

    /// Each action opens the sheet for its own thing. The two enums name their
    /// cases alike, so the mapping is read rather than spelled: a swapped
    /// mapping would open the retention sheet from "Legal Hold…".
    @Test func eachActionOpensTheFocusThatSharesItsName() {
        for action in ObjectLockFileAction.allCases {
            #expect(String(describing: action.focus) == String(describing: action), "\(action)")
        }
        #expect(ObjectLockFileAction.allCases.count == ObjectLockModel.Focus.allCases.count)
    }

    /// The negative, with its positive in the same body: S3 does contribute
    /// them, and the loop measured as many pairs as there are other backends
    /// times actions, so an emptied list or a filtered-away kind is red and not
    /// a check that is satisfied (fix round 1, Minor 6).
    @Test func noOtherBackendContributesThem() {
        let s3 = Set(BackendDescriptor.descriptor(for: .s3).fileActions.map(\.id))
        for action in ObjectLockFileAction.allCases {
            #expect(s3.contains(action.rawValue), "\(action.rawValue)")
        }
        var checked = 0
        for kind in ConnectionKind.allCases where kind != .s3 {
            let ids = Set(BackendDescriptor.descriptor(for: kind).fileActions.map(\.id))
            for action in ObjectLockFileAction.allCases {
                #expect(!ids.contains(action.rawValue), "\(kind) \(action.rawValue)")
                checked += 1
            }
        }
        let others: Int = ConnectionKind.allCases.count - 1
        let actions: Int = ObjectLockFileAction.allCases.count
        #expect(checked == others * actions)
        #expect(checked > 0)
    }

    @Test func theTitlesOfTheTwoActionsResolveInEveryLanguage() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        let contributed = BackendDescriptor.descriptor(for: .s3).fileActions
        var checked = 0
        for action in ObjectLockFileAction.allCases {
            let contribution = contributed.first { $0.id == action.rawValue }
            let title = contribution?.titleKey ?? ""
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(title, sentinel) }
                #expect(resolved != sentinel, "\(action.rawValue) in \(locale)")
                checked += 1
            }
        }
        #expect(checked == ObjectLockFileAction.allCases.count * Self.locales.count)
    }

    // MARK: - The session's cache

    /// Only a connection with the bucket-settings capability gets a cache; the
    /// positive (it gets one) is beside the negative (a file system without the
    /// capability does not).
    @MainActor @Test func aConnectionWithTheCapabilityGetsACacheAndOneWithoutDoesNot() {
        #expect(BrowserSession.objectLockStates(for: FakeBucketSettings()) != nil)
        #expect(BrowserSession.objectLockStates(for: LocalFileSystem()) == nil)
    }

    // MARK: - Wiring (source scans)

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: SourceCorpus.url(of: .sources).appendingPathComponent(relativePath))
    }

    /// The file-action arm reaches the sheet through the id-keyed enum and the
    /// path resolver, and the window presents the item it assigns. Without the
    /// presentation the menu row would be live and inert, which is the failure
    /// the connection menu's guard exists for.
    @Test func theFileActionArmAssignsAnItemTheWindowPresents() throws {
        let dispatcher = try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        let sheets = try Self.code("MacSCPAppKit/ContentView+Sheets.swift")
        let router = try #require(dispatcher.range(of: "func handleBrowserMenuEntry("))
        let rest = dispatcher[router.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        #expect(body.contains(String(describing: ObjectLockFileAction.self) + "("))
        #expect(body.contains(String(describing: ObjectLockTarget.self) + ".resolve("))
        let assigned = try #require(
            body.firstMatch(of: #/(\w+)\s*=\s*ObjectLockSheetItem\(/#), "no ObjectLockSheetItem assignment")
        let state = String(assigned.output.1)
        let presentation = try #require(sheets.range(of: ".sheet(item: $\(state))"), "\(state) is never presented")
        let closure = sheets[presentation.upperBound...].prefix(400)
        #expect(closure.contains(String(describing: ObjectLockSheet.self) + "("))
    }

    /// `startSession` is where a session is built, and it is where the cache is
    /// put on it. A session without one makes the menu row and both file
    /// actions live and inert, and no other check here would see it.
    @Test func startSessionPutsTheCacheOnTheSessionItBuilds() throws {
        let source = try Self.code("MacSCPAppKit/ContentView.swift")
        let call = "BrowserSession.objectLockStates(for:"
        #expect(source.matches(of: Regex<Substring>(verbatim: call)).count == 1)
        let built = try #require(source.range(of: "tab.session = BrowserSession("))
        let placed = try #require(source.range(of: call))
        #expect(built.lowerBound < placed.lowerBound)
    }

    /// The arm hands the sheet the focus its action maps to and the path it was
    /// asked about, and the sheet writes to the bucket and key it was opened
    /// for. Each is a way to put a COMPLIANCE retention on the wrong thing, and
    /// none would turn another check here red.
    @Test func theSheetIsOpenedAndRunForTheFileThatWasChosen() throws {
        let dispatcher = try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        let arm = try #require(dispatcher.range(of: "ObjectLockTarget.resolve("))
        let around = String(dispatcher[arm.lowerBound...].prefix(900))
        #expect(around.contains("path: file.path"))
        #expect(around.contains("focus: lockAction.focus"))
        let sheet = try Self.code("MacSCPAppKit/ObjectLockSheet.swift")
        let runs = sheet.matches(of: #/model\.run\(([^)]*)\)/#).map { String($0.output.1) }
        #expect(runs == ["key: target.key, bucket: target.bucket, via: settings"])
        let loads = sheet.matches(of: #/model\.load\(([^)]*)\)/#).map { String($0.output.1) }
        #expect(loads.count == 1)
        let loadArguments = loads.first.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(loadArguments == "key: target.key, bucket: target.bucket, via: settings, cache: cache")
    }

    /// The acknowledgement is the wrapping checkbox, not a hand-written
    /// `Toggle`, so the long sentence wraps and the scan table that counts the
    /// component's sites sees it. The positive: the sheet source has both
    /// components' call.
    @Test func theAcknowledgementIsAWrappingCheckboxRow() throws {
        let source = try Self.code("MacSCPAppKit/ObjectLockSheet.swift")
        let calls = source.matches(of: #/CheckboxRow\(/#).count
        #expect(calls == 2, "the acknowledgement and the legal-hold toggle")
        let wraps = source.matches(of: #/wraps:\s*true/#).count
        #expect(wraps >= 1)
        #expect(!source.contains("Toggle("))
    }

    // MARK: - The catalogue

    /// Every line the sheet can show resolves in every shipped language: a key
    /// missing from one catalogue silently shows the English default there.
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

    /// The format specifiers of a line are the same in every language: a
    /// translation that dropped the date, or added a second argument, would
    /// crash or silently lose it.
    @MainActor @Test func everyTranslationKeepsTheSpecifiersOfTheEnglish() {
        let specifier = #/%(\d+\$)?(lld|@|d)/#
        var withSpecifiers = 0
        for line in Self.everyLine() {
            let english = line.english.matches(of: specifier).map { String($0.output.0) }.sorted()
            if !english.isEmpty { withSpecifiers += 1 }
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, "") }
                let found = resolved.matches(of: specifier).map { String($0.output.0) }.sorted()
                #expect(found == english, "\(line.key) in \(locale)")
            }
        }
        #expect(withSpecifiers > 0)
    }

    /// The acknowledgement and the warning above it are not one sentence said
    /// twice, and the German one is not the English one.
    @MainActor @Test func theWarningAndTheAcknowledgementAreDistinctInEveryLanguage() {
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) {
                (
                    ObjectLockModel.complianceWarningLine.text,
                    ObjectLockModel.complianceAcknowledgementLine.text
                )
            }
            #expect(texts.0 != texts.1, "\(locale)")
        }
        let german = L10n.$localeOverride.withValue("de") { ObjectLockModel.complianceWarningLine.text }
        let english = L10n.$localeOverride.withValue("en") { ObjectLockModel.complianceWarningLine.text }
        #expect(german != english)
    }

    /// The sheets' sources are read for the keys they use, so a key used in a
    /// view and absent from the lists above (and therefore from the checks
    /// above) is a red here. The comment-free view keeps the string literals.
    @MainActor @Test func everyKeyTheSheetUsesIsOneTheCatalogueChecksCover() throws {
        let covered = Set(Self.everyLine().map(\.key))
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/ObjectLockSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        // The bucket default's keys are `s3.objectLock.default.*` and belong to
        // `BucketObjectLockSheetTests`; the descriptor's titles are not lines of
        // a sheet. What is left is this sheet's and the shared lines.
        let used = Set(source.matches(of: #/"(s3\.objectLock\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let uncovered = used.subtracting(covered).sorted()
        #expect(uncovered.isEmpty, "\(uncovered)")
    }

    /// Every line the sheet can show, for every state it can be in.
    @MainActor static func everyLine() -> [CatalogueLine] {
        var lines = ObjectLockModel.fixedLines
        for scenario in scenarios {
            lines += model(for: scenario).lines
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0.key).inserted }
    }
}
