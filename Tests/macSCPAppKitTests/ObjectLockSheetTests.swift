import Foundation
import MacSCPTestSupport
import Observation
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

    /// The sentence for a date that is not ahead says that it has passed, and
    /// what to do, in every language (fix round 3, NEW-6): a person who clicked
    /// a live button is told why it did nothing, not only what to choose.
    @MainActor @Test func theDateSentenceSaysTheDateHasPassed() {
        let passed = ["en": "have passed", "de": "ist vorbei", "fr": "est passée", "pl": "minęła"]
        #expect(passed.count == Self.locales.count)
        for locale in Self.locales {
            let text = L10n.$localeOverride.withValue(locale) { ObjectLockModel.datePastLine.text }
            let says = text.contains(passed[locale] ?? "\u{0}")
            #expect(says, "\(locale)")
        }
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
        let views = try Self.views("MacSCPAppKit/ObjectLockSheet.swift")
        // `retentionForm`'s own block, ending at the brace that closes it
        // (`SourceSpans.Views.block(openedBy:)`), read in the view where
        // string literals are blanked.
        //
        // **It ended at the NAME of the next declaration,
        // `private var legalHoldForm: some View`, until this closeout**, so
        // anything DECLARED between the two forms was inside the span. Round 5
        // left the read alone and argued it was safe; that argument is
        // withdrawn. It read, verbatim: "It is not in the family item 3 names:
        // both of its failure directions are loud, because a missing or moved
        // anchor makes the `#require` fail rather than widen the span." The
        // `#require` is indeed loud about an anchor that MOVES. It says nothing
        // about text that JOINS the span from outside the form, and that is the
        // silent direction: plant X1 deletes the
        // `if let detail = model.modeDetailLine` block from `retentionForm` --
        // no COMPLIANCE warning under the mode choice at all -- and parks an
        // unused `@ViewBuilder private var parkedLine: some View` spelling it
        // between the two forms. X1 was GREEN before this fix and is RED after,
        // 3150 tests both times; X1c, 25 comment lines at the top of
        // `retentionForm` with no code touched, is GREEN, so the narrower read
        // is not a stricter guard. Both commands and both verdicts are in
        // `SidebarNewBucketTests.swift`'s header.
        //
        // What the old boundary left open, from the repository root:
        //
        //     python3 -I -c 'import itertools
        //     s=open("Sources/MacSCPAppKit/ObjectLockSheet.swift").read()
        //     a="private var retentionForm: some View"
        //     up=s.index(a)+len(a)
        //     i=s.index("{",up)
        //     d=list(itertools.accumulate((c=="{")-(c=="}") for c in s[i:]))
        //     end=i+d.index(0)-up
        //     name=s.index("private var legalHoldForm: some View",up)-up
        //     print("block ends at",end,"| the name read ends at",name,"| it over-reads by",name-end)'
        //
        // prints `block ends at 1061 | the name read ends at 1081 | it
        // over-reads by 20`. Twenty characters is not the measurement that
        // matters here, and this is where the `present` window below differs:
        // that one over-reads a FIXED 144 characters, so what falls inside it
        // is whatever the file happens to hold; this one over-read whatever was
        // declared in the gap, which is nothing today and the whole of
        // `parkedLine` under X1. The command counts braces in the RAW text
        // where the guard counts them in the blanked view; the two agree here
        // because the region holds no brace inside a literal or a comment.
        let form = try #require(
            views.block(openedBy: "private var retentionForm: some View"),
            "`private var retentionForm: some View` is not there, or its braces do not balance")
        #expect(form.code.contains("model.modeDetailLine"))
        #expect(form.code.contains(".text"))
        // `present`'s own block, ending at the brace that closes it
        // (`SourceSpans.Views.block(openedBy:)`), and both names read in the
        // view where string literals are blanked.
        //
        // **It was 1500 characters from "private var present: some View" until
        // fix round 5 of the new-bucket task, and that window was already
        // satisfied by neighbouring code with nothing planted.** The block ends
        // 1356 characters after the anchor, so the window over-read it by 144,
        // and the `private var retentionForm: some View` declaration below sits
        // 1388 characters after the anchor -- 32 characters inside the
        // over-read. So `case .retention: EmptyView()` in `present`, a sheet
        // that shows no retention form at all, was satisfied by the DECLARATION
        // of the form it no longer shows (plant V1 of that round, GREEN then,
        // RED now). The figure, from the repository root:
        //
        //     python3 -I -c 'import itertools
        //     s=open("Sources/MacSCPAppKit/ObjectLockSheet.swift").read()
        //     up=s.index("private var present: some View")+len("private var present: some View")
        //     i=s.index("{",up)
        //     d=list(itertools.accumulate((c=="{")-(c=="}") for c in s[i:]))
        //     end=i+d.index(0)-up
        //     print("present block ends at",end,"| window 1500 over-reads by",1500-end,"| second retentionForm at",s.index("retentionForm",s.index("retentionForm",up)+1)-up)'
        //
        // prints `present block ends at 1356 | window 1500 over-reads by 144 |
        // second retentionForm at 1388`. It counts braces in the RAW text where
        // the guard counts them in the blanked view; the two agree here because
        // the region holds no brace inside a literal or a comment.
        //
        // The other direction cost 1039 characters of slack: 25 comment lines
        // at the top of `present`, no code changed, pushed both forms out of the
        // window and turned this red (plant V2, RED then, GREEN now).
        let presentBlock = try #require(
            views.block(openedBy: "private var present: some View"),
            "`private var present: some View` is not there, or its braces do not balance")
        #expect(presentBlock.code.contains("retentionForm"))
        #expect(presentBlock.code.contains("legalHoldForm"))
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
    ///
    /// **In every language, not in English alone (fix round 3, NEW-5).** The
    /// first version of this test held the either-or and the flat rule for the
    /// English only; a de, fr or pl string reverted to hedging the rule would
    /// have passed. Each language now has its connective and the hedge words
    /// that language would use for the rule, asserted present and absent, and
    /// the table is counted against the locales.
    @MainActor @Test func theRefusalKeepsTheRuleFlatAndHedgesTheCause() {
        let connective = ["en": "either", "de": "entweder", "fr": "soit", "pl": "albo"]
        let ruleHedges = [
            "en": ["perhaps", "may not be shortened"], "de": ["möglicherweise", "womöglich", "vielleicht"],
            "fr": ["peut-être"], "pl": ["być może", "możliwe, że"],
        ]
        #expect(connective.count == Self.locales.count)
        #expect(ruleHedges.count == Self.locales.count)
        for locale in Self.locales {
            let text = L10n.$localeOverride.withValue(locale) { ObjectLockLines.retentionRefused.text }
            let namesTheApp = text.contains("macSCP")
            let lowered = text.lowercased()
            let hasConnective = lowered.contains(connective[locale] ?? "\u{0}")
            let hedgesTheRule = (ruleHedges[locale] ?? []).contains { lowered.contains($0) }
            #expect(namesTheApp, "\(locale)")
            #expect(hasConnective, "\(locale)")
            #expect(!hedgesTheRule, "\(locale)")
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
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
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

    /// **The starting mode is not seeded from the file's (ruled twice).** A
    /// COMPLIANCE file opens on GOVERNANCE, which `complianceInForce` then stops
    /// with its own sentence; seeding the mode would start the sheet on the
    /// irreversible one. Until now this rested on nobody having written the line
    /// (fix round 3).
    @MainActor @Test func aLoadOverAComplianceFileLeavesTheModeWhereItWas() async {
        let probe = FakeBucketSettings(
            lock: .init(retention: ObjectRetention(mode: .compliance, retainUntil: Self.newYear)))
        let model = ObjectLockModel(now: { Self.now })
        await model.load(key: "a", bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.current?.retention?.mode == .compliance, "the read landed")
        #expect(model.mode == .governance)
        #expect(model.activeBlockers == [.complianceInForce])
    }

    // MARK: - A date that passes while the sheet is open

    private final class Clock: @unchecked Sendable { var date = ObjectLockSheetTests.now }

    private final class RedrawFlag: @unchecked Sendable {
        private(set) var raised = false
        func raise() { raised = true }
    }

    /// **The per-file sheet's twin of the bucket default's stale tick (fix round
    /// 3, NEW-6).** The date chosen was ahead when the sheet was drawn; it
    /// passes while the sheet is open. The clock is not observable, so the click
    /// used to write nothing and change nothing the sheet watches: a live button
    /// that did nothing. A refused run is counted, the date blocker reads the
    /// count, and the sentence says the date has passed. The positive is beside
    /// it: before the date passes the same click writes.
    @MainActor @Test func aDateThatPassesWhileTheSheetIsOpenIsSaidSoOnTheClick() async {
        let clock = Clock()
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(bucketHasLock: true, now: { clock.date })
        model.retainUntil = Self.now.addingTimeInterval(3_600)
        #expect(model.canRun, "the date is ahead")
        #expect(model.explanation == nil)
        let redraw = RedrawFlag()
        withObservationTracking({ _ = model.canRun }, onChange: { redraw.raise() })
        clock.date = Self.now.addingTimeInterval(7_200)
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.retentionWrites.isEmpty, "a retention was written for a date that had passed")
        #expect(redraw.raised, "a click on a passed date changed nothing the sheet was watching")
        #expect(model.explanation?.key == ObjectLockModel.datePastLine.key)
        model.retainUntil = Self.now.addingTimeInterval(3 * 86_400)
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.retentionWrites.count == 1)
    }

    /// The count is of refused runs and nothing else: a run that is allowed
    /// does not count.
    @MainActor @Test func onlyARefusedRunIsCounted() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(model.refusedRuns == 0)
        model.retainUntil = Self.yesterday
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(model.refusedRuns == 1)
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
        await model.run(key: "photos/a.txt", bucket: "macscp-seed", via: probe, recorder: nil)
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
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.retentionWrites.isEmpty, "sent without an acknowledgement")
        model.acknowledged = true
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.retentionWrites.map(\.retention.retainUntil) == [Self.newYear])
        #expect(probe.retentionWrites.map(\.retention.mode) == [.compliance])
        #expect(!model.acknowledged)
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.retentionWrites.count == 1, "a spent acknowledgement ran a second write")
    }

    @MainActor @Test func aRefusedWriteKeepsTheStateAndSaysWhyInAFixedSentence() async {
        let probe = FakeBucketSettings(
            lock: .init(writeError: RemoteFSError.permissionDenied(path: "/b/a")))
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.retainUntil = Self.newYear
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
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
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        let text = model.applyFailure ?? ""
        let quoted = text.contains("SECRETEXAMPLE") || text.contains("store.invalid")
        #expect(!text.isEmpty)
        #expect(!quoted)
    }

    @MainActor @Test func aLegalHoldIsPlacedAndLiftedOnTheNamedKey() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { Self.now })
        model.legalHold = true
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(
            probe.legalHoldWrites == [
                FakeBucketSettings.LegalHoldWrite(on: true, key: "a", bucket: "b", versionId: nil)
            ])
        #expect(model.current?.legalHold == true)
        // Placed; the toggle now equals the store, so there is nothing to run.
        #expect(!model.canRun)
        model.legalHold = false
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.legalHoldWrites.map(\.on) == [true, false])
    }

    /// A refused hold is not a refused retention: the sentence about a
    /// retention that may not be shortened would be false of it.
    @MainActor @Test func aRefusedHoldDoesNotTalkAboutRetentions() async {
        let probe = FakeBucketSettings(
            lock: .init(writeError: RemoteFSError.permissionDenied(path: "/b/a")))
        let model = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { Self.now })
        model.legalHold = true
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
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
        await holdSheet.run(key: "a", bucket: "b", via: probe, recorder: nil)
        #expect(probe.retentionWrites.isEmpty)
        #expect(probe.legalHoldWrites.count == 1)

        let retentionSheet = ObjectLockModel(focus: .retention, bucketHasLock: true, now: { Self.now })
        retentionSheet.legalHold = true
        await retentionSheet.run(key: "a", bucket: "b", via: probe, recorder: nil)
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
    @MainActor @Test(.timeLimit(.minutes(5))) func aSecondRunWhileOneIsInFlightSendsNothing() async {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        defer { release.signal() }
        let probe = FakeBucketSettings(lock: .init(writeEntered: entered, writeRelease: release))
        let model = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        model.mode = .compliance
        model.retainUntil = Self.newYear
        model.acknowledged = true
        let first = Task { @MainActor in await model.run(key: "a", bucket: "b", via: probe, recorder: nil) }
        _ = await entered.wait()
        #expect(model.isApplying)
        #expect(model.activeBlockers.contains(.applying))
        #expect(!model.canRun)
        await model.run(key: "a", bucket: "b", via: probe, recorder: nil)
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
            await model.run(key: "k", bucket: "b", via: probe, recorder: nil)
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

    private struct ViewsNotInLockstep: Error { let file: String }

    /// One file's two blanked views, in lockstep, so a span here can end at the
    /// brace that closes the thing it is named for instead of at a character
    /// count (`SourceSpans.Views`): `content` keeps string literals and is what
    /// an anchor is matched in, `code` blanks them too and is where the braces
    /// are counted. Throws rather than hand back a view pair of two different
    /// lengths, which would be a read of one view by the other's offsets.
    private static func views(_ relativePath: String) throws -> SourceSpans.Views {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent(relativePath)
        guard
            let views = SourceSpans.Views(
                content: try SourceCorpus.commentFree(of: url),
                code: try SourceCorpus.code(of: url))
        else { throw ViewsNotInLockstep(file: relativePath) }
        return views
    }

    /// The file-action arm reaches the sheet through the id-keyed enum and the
    /// path resolver, and the window presents the item it assigns. Without the
    /// presentation the menu row would be live and inert, which is the failure
    /// the connection menu's guard exists for.
    @Test func theFileActionArmAssignsAnItemTheWindowPresents() throws {
        let dispatcher = try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        // The body up to its own closing brace (`SourceSpans.functionBody`). It
        // was read up to "the next `\n    func `" until fix round 4 of the
        // new-bucket task, which is a boundary a `private func` does not carry:
        // with the `ObjectLockFileAction(action:)` conversion parked in one
        // between this function and `restoreDeletedFiles`, the first check
        // below passed (plant S2 of that round, GREEN then, RED now). Parking
        // the WHOLE arm there instead is caught by
        // `theSheetIsOpenedAndRunForTheFileThatWasChosen` below, which reads the
        // Object Lock ARM inside this same function body since the Task 6
        // closeout. This clause read, verbatim: "which reads the same function
        // body since fix round 5" -- true of round 5's tree, where the sibling
        // read the whole body; the closeout narrowed it to the arm, and S1 stays
        // red by it either way, because parking the arm empties the arm. This
        // comment read, verbatim:
        // "which reads from the first `ObjectLockTarget.resolve(` in the file,
        // so that plant (S1) measures nothing about this span" -- true of
        // `e26a116e`, where that sibling was still a 900-character window; at
        // `b85de102` the span guard here was red on S1 too, and since fix round
        // 5 so is the sibling. A span bounded by a brace cannot be satisfied by
        // text that is not in the function it names.
        let body = try #require(
            SourceSpans.functionBody(named: "handleBrowserMenuEntry", in: dispatcher),
            "func handleBrowserMenuEntry not found")
        #expect(body.contains(String(describing: ObjectLockFileAction.self) + "("))
        #expect(body.contains(String(describing: ObjectLockTarget.self) + ".resolve("))
        let assigned = try #require(
            body.firstMatch(of: #/(\w+)\s*=\s*ObjectLockSheetItem\(/#), "no ObjectLockSheetItem assignment")
        let state = String(assigned.output.1)
        // The presentation's own closure, ending at the brace that closes it.
        // It was 400 characters from `.sheet(item: $<state>)` until fix round 5
        // of the new-bucket task: the closure ends 190 characters after that
        // anchor and the sheet call sits 23 characters into it, so the window
        // over-read the closure by 210 and left 377 characters of slack. Unlike
        // `present` above, nothing in that over-read satisfies the check today
        // (the next two sheets build `ObjectVersionsSheet(` and
        // `ObjectMetadataSheet(`), so the decoy had to be planted: an
        // `EmptyView()` in the sheet with the real sheet built in an `.overlay`
        // 127 characters further on passed (plant W1 of that round, GREEN then,
        // RED now), and 9 comment lines above the call, no code changed, turned
        // it red (plant W2, RED then, GREEN now). The figure, from the
        // repository root:
        //
        //     python3 -I -c 'import itertools
        //     t=open("Sources/MacSCPAppKit/ContentView+Sheets.swift").read()
        //     up=t.index(".sheet(item: $objectLockSheetItem)")+len(".sheet(item: $objectLockSheetItem)")
        //     i=t.index("{",up)
        //     d=list(itertools.accumulate((c=="{")-(c=="}") for c in t[i:]))
        //     end=i+d.index(0)-up
        //     print("closure ends at",end,"| window 400 over-reads by",400-end,"| the sheet call sits at",t.index("ObjectLockSheet(",up)-up)'
        //
        // prints `closure ends at 190 | window 400 over-reads by 210 | the sheet
        // call sits at 23`.
        let closure = try #require(
            Self.views("MacSCPAppKit/ContentView+Sheets.swift")
                .block(openedBy: ".sheet(item: $\(state))"),
            "\(state) is never presented")
        #expect(closure.code.contains(String(describing: ObjectLockSheet.self) + "("))
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
        // The router's own body, ending at the brace that closes it
        // (`SourceSpans.functionBody`, as the sibling above uses). It was 900
        // characters from the FIRST `ObjectLockTarget.resolve(` in the file
        // until fix round 5 of the new-bucket task -- a window a decoy can be
        // put in FRONT of rather than behind: with the real arm handing the
        // sheet `focus: .retention` and a private function ABOVE
        // `handleBrowserMenuEntry` spelling the correct call, the first
        // `resolve(` in the file was the decoy's and both checks below passed
        // (plant U1 of that round, GREEN then, RED now). U1c, the same
        // violation with no decoy, was RED either way, which is what makes
        // U1's GREEN a blind guard and not a harmless plant.
        //
        // The `resolve(` check is the positive control that took the place of
        // the `#require` on that range: without it a body that resolves no
        // path at all would be read by two `contains` that name neither.
        //
        // **Fix round 5 replaced that window with the WHOLE body of
        // `handleBrowserMenuEntry`, and that traded one direction away while
        // fixing the two it was aimed at.** The body spans the Object Lock arm
        // AND the `.metadata` arm, and both spell `path: file.path`, so both
        // `contains` below could be satisfied by the other arm: plant U2 -- the
        // real arm handing the sheet `focus: .retention`, with
        // `let lockAction = (focus: 0, other: 0)` and
        // `_ = (path: file.path, focus: lockAction.focus)` parked in the
        // `.metadata` arm -- was GREEN on the function body. The 900-character
        // window round 5 replaced could not reach that arm, so the SAME plant
        // was RED before round 5. Both of those are runs and not arithmetic:
        // GREEN at `0bbeff1b`, RED at round 4's final guard (this tree with
        // `ObjectLockSheetTests.swift` restored to `b85de102`; the only other
        // file differing between the two trees is `SidebarNewBucketTests.swift`,
        // whose round-5 change is a check that reads `ContentView+Detail.swift`
        // and cannot see this plant). Round 5's own report named this closer and
        // recorded that its brief had specified the function body; the closeout
        // takes the closer. Narrowing it drops nothing the body read caught --
        // U1, U1c and S1 are still RED, U1b still GREEN -- and the figures, from
        // the repository root:
        //
        //     python3 -I -c 'import itertools
        //     s=open("Sources/MacSCPAppKit/ContentView+MenuActions.swift").read()
        //     d=s.index("func handleBrowserMenuEntry(")
        //     i=s.index("{",d)
        //     acc=list(itertools.accumulate((c=="{")-(c=="}") for c in s[i:]))
        //     body=s[d:i+acc.index(0)+1]
        //     a=body.index("case .retention, .legalHold:")
        //     arm=body[a:body.index("case .versions:",a)]
        //     print("body",len(body),"| arm",len(arm),"| the read drops",len(body)-len(arm),"| path: file.path in body",body.count("path: file.path"),"in arm",arm.count("path: file.path"))'
        //
        // prints `body 8423 | arm 1273 | the read drops 7150 | path: file.path
        // in body 2 in arm 1`, and
        //
        //     python3 -I -c 's=open("Sources/MacSCPAppKit/ContentView+MenuActions.swift").read()
        //     a=s.index("ObjectLockTarget.resolve(")
        //     print("the .metadata arm starts",s.index("case .metadata:",a)-a,"characters after the first ObjectLockTarget.resolve(")'
        //
        // prints `the .metadata arm starts 1971 characters after the first
        // ObjectLockTarget.resolve(`. Raw text in both, where the guard reads
        // the blanked view; they agree here because neither region holds a brace
        // or one of these phrases inside a literal.
        //
        // The arm is read INSIDE the body rather than from the file, so a
        // second `switch` that grows the same label elsewhere cannot answer for
        // this one, and the `#require` is loud if the label moves.
        let body = try #require(
            SourceSpans.functionBody(named: "handleBrowserMenuEntry", in: dispatcher),
            "func handleBrowserMenuEntry not found")
        let arm = try #require(
            SourceSpans.switchArm("case .retention, .legalHold:", in: body),
            "the Object Lock arm is not in handleBrowserMenuEntry's body")
        #expect(arm.contains(String(describing: ObjectLockTarget.self) + ".resolve("))
        #expect(arm.contains("path: file.path"))
        #expect(arm.contains("focus: lockAction.focus"))
        let sheet = try Self.code("MacSCPAppKit/ObjectLockSheet.swift")
        let runs = sheet.matches(of: #/model\.run\(([^)]*)\)/#).map {
            String($0.output.1).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        #expect(runs == ["key: target.key, bucket: target.bucket, via: settings, recorder: recorder"])
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

    /// **No line of the sheet names how the store works (fix round 3).** The
    /// bucket default scanned every line; this sheet scanned two. Every line, in
    /// the language the source text is written in, with the lines counted so an
    /// empty list cannot pass.
    @MainActor @Test func noLineOfTheSheetNamesStoreMechanics() {
        let english = L10n.$localeOverride.withValue("en") {
            Self.everyLine().map { $0.text.lowercased() }
        }
        #expect(english.count > 20)
        for text in english {
            for jargon in ["bypass", "header", "403", "x-amz", "version id", "delete marker", "xml"] {
                let leaked = text.contains(jargon)
                #expect(!leaked, "\(jargon)")
            }
        }
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
