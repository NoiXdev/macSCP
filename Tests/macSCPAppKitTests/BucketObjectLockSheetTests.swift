import Foundation
import MacSCPTestSupport
import Observation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The bucket-default Object Lock sheet's decisions.
///
/// A default applies to objects written AFTER it is set (measured on the rig
/// 2026-10-19: an object already in the bucket stays unlocked), so a
/// COMPLIANCE default is the most far-reaching irreversible choice on this
/// branch: it is not one file but every file added from then on. The
/// acknowledgement here is therefore held to the same standard as the
/// per-file one, in `ObjectLockSheetTests`.
@Suite("Bucket Object Lock sheet")
struct BucketObjectLockSheetTests {
    private static let locales = ["en", "de", "fr", "pl"]
    private static let now = ObjectLockSheetTests.now

    // MARK: - What it shows

    @MainActor @Test func aBucketWithNoLockOffersNothingToSetAndSaysWhy() {
        let model = BucketObjectLockModel(bucketHasLock: false, current: nil, now: { Self.now })
        #expect(model.canSave == false)
        #expect(model.unavailableReasonKey == "s3.objectLock.notEnabledOnThisBucket")
    }

    @MainActor @Test func aLockedBucketWithNoDefaultCanBeGivenOne() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        #expect(model.unavailableReasonKey == nil)
        #expect(model.canSave == true)
        #expect(model.currentLine.key == "s3.objectLock.default.current.none")
    }

    // MARK: - COMPLIANCE

    @MainActor @Test func aComplianceDefaultCannotBeSavedUntilItIsAcknowledged() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        model.days = 30
        #expect(model.canSave == false)
        model.acknowledged = true
        #expect(model.canSave == true)
    }

    // MARK: - The warning is what the person is shown

    /// The default's counterpart of
    /// `ObjectLockSheetTests.choosingComplianceShowsTheWarningAndGovernanceDoesNot`:
    /// the line the form reads, by `key`, in both modes (fix round 1, I-1).
    @MainActor @Test func choosingComplianceShowsTheWarningAndGovernanceDoesNot() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        let shownForCompliance = model.modeDetailLine.key
        model.mode = .governance
        let shownForGovernance = model.modeDetailLine.key
        #expect(shownForCompliance == BucketObjectLockModel.complianceWarningLine.key)
        #expect(shownForGovernance == ObjectLockLines.governanceDetail.key)
        #expect(shownForCompliance != shownForGovernance)
    }

    @Test func theFormDrawsTheLineUnderTheModeChoice() throws {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/BucketObjectLockSheet.swift")
        let source = try SourceCorpus.code(of: url)
        let form = try #require(source.range(of: "private var form: some View"))
        let body = String(source[form.upperBound...])
        #expect(body.contains("model.modeDetailLine"))
        #expect(body.contains(".text"))
        let present = try #require(source.range(of: "private var present: some View"))
        let presentBody = String(source[present.upperBound...].prefix(1500))
        #expect(presentBody.contains("\n            form\n"))
    }

    @MainActor @Test func aGovernanceDefaultNeedsNoAcknowledgement() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .governance
        #expect(model.canSave == true)
    }

    /// The day in the acknowledgement is the one a file saved NOW would be
    /// locked until, so it follows the days. A DAY, not an instant: a file added
    /// a minute from now is locked until a minute later than that, and a sentence
    /// that named the minute would be wrong the moment it was read.
    @MainActor @Test func theAcknowledgementNamesTheDayAFileAddedNowIsLockedUntil() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        model.days = 30
        let thirtyDays = Calendar.current.date(byAdding: .day, value: 30, to: Self.now) ?? Self.now
        let expected = Calendar.current.startOfDay(for: thirtyDays)
        #expect(model.acknowledgementKey == "s3.objectLock.default.complianceAcknowledgement %@")
        #expect(model.acknowledgementDate == expected)
        #expect(model.acknowledgementDateText == ObjectLockDates.dayText(expected, localeCode: nil))
    }

    /// A day is written for the reader and carries no time.
    @Test func aDayIsWrittenInTheReadersLanguageAndWithoutATime() {
        let expected = ["en": "January", "de": "Januar", "fr": "janvier", "pl": "stycznia"]
        for locale in Self.locales {
            let text = ObjectLockDates.dayText(ObjectLockSheetTests.newYearNoon, localeCode: locale)
            let month = expected[locale] ?? ""
            let hasMonth = text.contains(month)
            let hasTime = text.contains(":")
            #expect(hasMonth, "\(locale)")
            #expect(!hasTime, "\(locale)")
        }
        #expect(expected.count == Self.locales.count)
    }

    private final class Clock: @unchecked Sendable { var date = BucketObjectLockSheetTests.now }

    /// **The tick is for the day it named.** The clock moves while the sheet
    /// is open; a tick given for one day does not stand for another (fix round
    /// 1, Minor 2: the date was recomputed from `now()` on every read while the
    /// tick stood). The same day later is the same day, so the positive is
    /// beside the negative.
    ///
    /// **And it says so (fix round 2, NEW-1).** A stale tick has its own blocker
    /// and its own sentence, not "Tick the box to confirm" beside a box that is
    /// ticked. The round-1 `save()` cleared a stale tick on the click, which
    /// left that generic sentence as the only explanation; the tick now stands,
    /// the reason is the stale one in either ordering (a redraw before the
    /// click, or none), and re-ticking is what clears it.
    @MainActor @Test func aTickGivenForOneDayDoesNotStandForAnother() async {
        let clock = Clock()
        let probe = FakeBucketSettings(lock: .init())
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { clock.date })
        model.mode = .compliance
        model.days = 30
        model.acknowledged = true
        let named = model.acknowledgementDate
        clock.date = Self.now.addingTimeInterval(1)
        #expect(model.acknowledgementDate == named)
        #expect(model.canSave, "the same day, a moment later")
        #expect(model.explanation == nil)
        clock.date = Self.now.addingTimeInterval(2 * 86_400)
        #expect(model.acknowledgementDate != named)
        #expect(model.activeBlockers == [.acknowledgementStale])
        #expect(model.explanation?.key == BucketObjectLockModel.staleLine.key)
        await model.save(bucket: "b", via: probe, recorder: nil)
        #expect(probe.defaultWrites.isEmpty, "a tick for another day sent a COMPLIANCE default")
        #expect(model.acknowledged, "the tick stands: it is not taken away unexplained")
        #expect(model.explanation?.key == BucketObjectLockModel.staleLine.key)
        model.acknowledged = false
        #expect(model.explanation?.key == BucketObjectLockModel.notAcknowledgedLine.key)
        model.acknowledged = true
        #expect(model.canSave)
        await model.save(bucket: "b", via: probe, recorder: nil)
        #expect(probe.defaultWrites.count == 1)
    }

    /// A click on a stale tick changes something the sheet watches, so the
    /// sentence appears even when nothing redrew since midnight: the model
    /// counts the refusal, and the stale blocker reads the count (fix round 2).
    @MainActor @Test func aClickOnAStaleTickIsSomethingTheSheetCanSee() async {
        let clock = Clock()
        let probe = FakeBucketSettings(lock: .init())
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { clock.date })
        model.mode = .compliance
        model.acknowledged = true
        clock.date = Self.now.addingTimeInterval(2 * 86_400)
        let before = model.refusedSaves
        // What the view does: reads `canSave` while drawing. The click must
        // invalidate what that read depended on.
        let redraw = RedrawFlag()
        withObservationTracking({ _ = model.canSave }, onChange: { redraw.raise() })
        await model.save(bucket: "b", via: probe, recorder: nil)
        #expect(model.refusedSaves == before + 1)
        #expect(redraw.raised, "a click on a stale tick changed nothing the sheet was watching")
    }

    private final class RedrawFlag: @unchecked Sendable {
        private(set) var raised = false
        func raise() { raised = true }
    }

    /// **A second write of the same value is not a new tick.** `acknowledged`
    /// stamps the day it was given for; without the guard that `mode` and `days`
    /// have, a binding writing `true` back after midnight would turn a stale tick
    /// fresh (fix round 2, NEW-3).
    @MainActor @Test func tickingAnAlreadyTickedBoxDoesNotRefreshTheDay() {
        let clock = Clock()
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { clock.date })
        model.mode = .compliance
        model.acknowledged = true
        clock.date = Self.now.addingTimeInterval(2 * 86_400)
        model.acknowledged = true
        #expect(!model.canSave, "a repeated write of true made a stale tick fresh")
        #expect(model.activeBlockers == [.acknowledgementStale])
        model.acknowledged = false
        model.acknowledged = true
        #expect(model.canSave, "a real re-tick is a new decision")
    }

    /// **A read starts the decision over, on both models, failed or not (fix
    /// round 2).** The bucket default used to clear the tick only at the end of
    /// a read that succeeded, so a failed read left a tick standing from before.
    /// Nothing could be written on it (the read's own blockers hold), but the
    /// two models said different things; now both clear at the start.
    @MainActor @Test func aFailedReadTakesAnyAcknowledgementBack() async {
        let failing = FakeBucketSettings(
            lock: .init(hasLockError: RemoteFSError.finding(.operationNotSupported)))
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        model.acknowledged = true
        await model.load(bucket: "b", via: failing, cache: ObjectLockStateCache(settings: failing))
        #expect(!model.acknowledged)
        #expect(!model.canSave)

        let perFile = ObjectLockModel(bucketHasLock: true, now: { Self.now })
        perFile.mode = .compliance
        perFile.acknowledged = true
        await perFile.load(key: "a", bucket: "b", via: failing, cache: ObjectLockStateCache(settings: failing))
        #expect(!perFile.acknowledged)
    }

    @MainActor @Test func changingTheDaysOrTheModeTakesTheAcknowledgementBack() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        model.days = 30
        model.acknowledged = true
        model.days = 31
        #expect(!model.acknowledged)
        model.acknowledged = true
        model.mode = .governance
        model.mode = .compliance
        #expect(!model.acknowledged)
        #expect(!model.canSave)
        // Writing back what is already there is no change.
        model.acknowledged = true
        model.days = 31
        model.mode = .compliance
        #expect(model.acknowledged)
        #expect(model.canSave)
    }

    // MARK: - Days

    @MainActor @Test func aPeriodOutsideTheRangeCannotBeSavedInEitherMode() {
        for mode in RetentionMode.allCases {
            for days in [0, -3, BucketObjectLockModel.dayRange.upperBound + 1] {
                let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
                model.mode = mode
                model.days = days
                model.acknowledged = true
                #expect(!model.canSave, "\(mode) \(days)")
                #expect(model.activeBlockers.contains(.daysOutOfRange), "\(mode) \(days)")
            }
        }
    }

    /// The two ends of the range are themselves allowed, and the sentence for
    /// a period outside it carries the ceiling.
    @MainActor @Test func theEndsOfTheRangeAreInAndTheSentenceNamesTheCeiling() {
        let ends = [BucketObjectLockModel.dayRange.lowerBound, BucketObjectLockModel.dayRange.upperBound]
        for days in ends {
            let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
            model.days = days
            #expect(model.canSave, "\(days)")
        }
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.days = 0
        let sentence = L10n.$localeOverride.withValue("en") { model.explanationSentence ?? "" }
        let ceiling = String(BucketObjectLockModel.dayRange.upperBound)
        let namesIt = sentence.contains(ceiling)
        let unfilled = sentence.contains("%")
        #expect(namesIt)
        #expect(!unfilled)
    }

    /// The acknowledgement's date is counted from the clock by the days, and
    /// a period past the ceiling does not move it.
    @MainActor @Test func theAcknowledgementDateDoesNotRunPastTheCeiling() {
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.days = BucketObjectLockModel.dayRange.upperBound
        let atTheCeiling = model.acknowledgementDate
        model.days = Int.max / 2
        #expect(model.acknowledgementDate == atTheCeiling)
        #expect(atTheCeiling > Self.now)
    }

    @MainActor @Test func savingTheDefaultThatIsAlreadyThereIsNothingToSave() {
        let model = BucketObjectLockModel(
            bucketHasLock: true, current: (days: 14, mode: .governance), now: { Self.now })
        #expect(model.days == 14)
        #expect(model.mode == .governance)
        #expect(!model.canSave)
        model.days = 15
        #expect(model.canSave)
    }

    // MARK: - Loading

    @MainActor @Test func aLoadReadsTheLockAndTheDefaultOfTheNamedBucket() async {
        let probe = FakeBucketSettings(
            lock: .init(bucketDefault: .init(days: 7, mode: .compliance)))
        let model = BucketObjectLockModel(now: { Self.now })
        await model.load(bucket: "macscp-seed", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(probe.hasLockReads == ["macscp-seed"])
        #expect(probe.defaultReads == ["macscp-seed"])
        #expect(model.days == 7)
        #expect(model.mode == .compliance)
        #expect(!model.acknowledged)
    }

    @MainActor @Test func aBucketWithNoLockIsNotAskedForItsDefault() async {
        let probe = FakeBucketSettings(lock: .init(hasLock: false))
        let model = BucketObjectLockModel(now: { Self.now })
        await model.load(bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.bucketLock == .absent)
        #expect(probe.defaultReads.isEmpty)
        #expect(!model.canSave)
    }

    /// A default Core cannot read (it is set in years) is shown as unreadable
    /// and blocks saving, because saving would overwrite a default nobody saw.
    @MainActor @Test func aDefaultThatCannotBeReadBlocksSavingOverIt() async {
        let probe = FakeBucketSettings(
            lock: .init(readError: RemoteFSError.protocolError(reason: "years")))
        let model = BucketObjectLockModel(now: { Self.now })
        await model.load(bucket: "b", via: probe, cache: ObjectLockStateCache(settings: probe))
        #expect(model.currentFailure == BucketObjectLockModel.readFailedLine.text)
        #expect(!model.canSave)
    }

    // MARK: - Saving

    @MainActor @Test func aGovernanceDefaultIsWrittenOnceToTheNamedBucketAndReadBack() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.days = 45
        await model.save(bucket: "macscp-second", via: probe, recorder: nil)
        #expect(
            probe.defaultWrites == [
                FakeBucketSettings.DefaultWrite(days: 45, mode: .governance, bucket: "macscp-second")
            ])
        #expect(probe.defaultReads == ["macscp-second"])
        #expect(model.current?.days == 45)
        #expect(model.isSaved)
        #expect(!model.canSave)
    }

    @MainActor @Test func aComplianceDefaultIsWrittenOnlyAfterTheTickAndSpendsIt() async {
        let probe = FakeBucketSettings(lock: .init())
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        model.days = 10
        await model.save(bucket: "b", via: probe, recorder: nil)
        #expect(probe.defaultWrites.isEmpty, "sent without an acknowledgement")
        model.acknowledged = true
        await model.save(bucket: "b", via: probe, recorder: nil)
        #expect(probe.defaultWrites.map(\.mode) == [.compliance])
        #expect(probe.defaultWrites.map(\.days) == [10])
        #expect(!model.acknowledged)
    }

    @MainActor @Test func aRefusedWriteKeepsTheStateAndSaysWhyInAFixedSentence() async {
        let planted = "https://AKIDEXAMPLE:SECRETEXAMPLE@store.invalid"
        let probe = FakeBucketSettings(lock: .init(writeError: RemoteFSError.protocolError(reason: planted)))
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        await model.save(bucket: "b", via: probe, recorder: nil)
        let text = model.applyFailure ?? ""
        let quoted = text.contains("SECRETEXAMPLE") || text.contains("store.invalid")
        #expect(probe.defaultWrites.count == 1)
        #expect(text == BucketObjectLockModel.applyFailedLine.text)
        #expect(!quoted)
        #expect(model.current == nil)
        #expect(!model.isSaved)
    }

    /// With a hang bound, for the reason given on the per-file sheet's twin of
    /// this test (`ObjectLockSheetTests.aSecondRunWhileOneIsInFlightSendsNothing`).
    @MainActor @Test(.timeLimit(.minutes(5))) func aSecondSaveWhileOneIsInFlightSendsNothing() async {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        defer { release.signal() }
        let probe = FakeBucketSettings(lock: .init(writeEntered: entered, writeRelease: release))
        let model = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { Self.now })
        model.mode = .compliance
        model.acknowledged = true
        let first = Task { @MainActor in await model.save(bucket: "b", via: probe, recorder: nil) }
        _ = await entered.wait()
        #expect(model.isApplying)
        #expect(model.activeBlockers.contains(.applying))
        await model.save(bucket: "b", via: probe, recorder: nil)
        release.signal()
        await first.value
        #expect(probe.defaultWrites.count == 1)
    }

    // MARK: - Every state the sheet can be in

    enum LockFact: CaseIterable { case reading, failed, absent, present }
    enum Days: CaseIterable { case none, one, many }
    enum Same: CaseIterable { case noDefault, sameAsDefault, differs }

    struct Scenario: CustomStringConvertible {
        var lock: LockFact
        var currentRead: Bool
        var mode: RetentionMode
        var acknowledged: Bool
        var days: Days
        var same: Same

        var description: String {
            "lock=\(lock) read=\(currentRead) \(mode) ack=\(acknowledged) days=\(days) same=\(same)"
        }

        static let existing = (days: 14, mode: RetentionMode.governance)

        var dayCount: Int {
            switch days {
            case .none: 0
            case .one: 1
            case .many: 90
            }
        }

        /// The rule from the other end: a save is allowed only on a bucket
        /// with the lock, with its default read, with at least a day, with the
        /// tick if it is COMPLIANCE, and with something to change.
        var maySave: Bool {
            guard lock == .present, currentRead, dayCount >= 1 else { return false }
            guard mode == .governance || acknowledged else { return false }
            // `sameAsDefault` is built below as exactly the existing default.
            return same != .sameAsDefault
        }
    }

    static var scenarios: [Scenario] {
        var all: [Scenario] = []
        for lock in LockFact.allCases {
            for currentRead in [false, true] {
                for mode in RetentionMode.allCases {
                    for acknowledged in [false, true] {
                        for days in Days.allCases {
                            for same in Same.allCases {
                                all.append(
                                    Scenario(
                                        lock: lock, currentRead: currentRead, mode: mode,
                                        acknowledged: acknowledged, days: days, same: same))
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    /// `sameAsDefault` is meaningful only when there is a default and it is
    /// the one the fields hold; the other combinations of it are collapsed
    /// to what they would be anyway, so the state space stays honest.
    @MainActor static func model(for scenario: Scenario) -> (BucketObjectLockModel, Scenario) {
        var scenario = scenario
        let lock: BucketObjectLockModel.BucketLock =
            switch scenario.lock {
            case .reading: .reading
            case .failed: .failed("x")
            case .absent: .absent
            case .present: .present
            }
        let existing: (days: Int, mode: RetentionMode)? =
            scenario.same == .noDefault ? nil : Scenario.existing
        let model = BucketObjectLockModel(
            bucketLock: lock, currentRead: scenario.currentRead, current: existing, now: { Self.now })
        if scenario.same == .sameAsDefault {
            // The fields hold exactly the default; the other fields of the
            // scenario do not apply to this state.
            scenario.mode = Scenario.existing.mode
            scenario.days = .many
            model.mode = Scenario.existing.mode
            model.days = Scenario.existing.days
            scenario.acknowledged = false
            model.acknowledged = false
        } else {
            model.mode = scenario.mode
            model.days = scenario.dayCount
            model.acknowledged = scenario.acknowledged
        }
        return (model, scenario)
    }

    @MainActor @Test func inNoStateDoesSaveWriteWhatCanSaveRefused() async {
        var wrote = 0
        var refused = 0
        let locks: Int = LockFact.allCases.count
        let modes: Int = RetentionMode.allCases.count
        let daysChoices: Int = Days.allCases.count
        let sames: Int = Same.allCases.count
        let readAndTick: Int = 2 * 2
        let expectedCount: Int = locks * readAndTick * modes * daysChoices * sames
        #expect(Self.scenarios.count == expectedCount)
        for raw in Self.scenarios {
            let (model, scenario) = Self.model(for: raw)
            let probe = FakeBucketSettings(lock: .init())
            let allowed = model.canSave
            // `sameAsDefault` leaves the model with a mode of its own; the
            // oracle is asked about the state the model is actually in.
            let expected = scenario.maySave
            #expect(allowed == expected, "\(scenario)")
            await model.save(bucket: "b", via: probe, recorder: nil)
            #expect(probe.defaultWrites.count == (allowed ? 1 : 0), "\(scenario)")
            if allowed { wrote += 1 } else { refused += 1 }
            for write in probe.defaultWrites where write.mode == .compliance {
                #expect(scenario.acknowledged, "\(scenario)")
                #expect(scenario.lock == .present, "\(scenario)")
                #expect(write.days >= 1, "\(scenario)")
            }
        }
        #expect(wrote > 0)
        #expect(refused > 0)
    }

    @MainActor @Test func everyBlockerCanBeTheOnlyReasonSavingIsOff() {
        var aloneIn = Set<String>()
        for raw in Self.scenarios {
            let (model, _) = Self.model(for: raw)
            if model.activeBlockers.count == 1, let only = model.activeBlockers.first {
                aloneIn.insert("\(only)")
            }
        }
        // `applying` needs a write in flight and `acknowledgementStale` a clock that
        // moves; `aSecondSaveWhileOneIsInFlightSendsNothing` and
        // `aTickGivenForOneDayDoesNotStandForAnother` are where each is held.
        let expected = Set(
            BucketObjectLockModel.SaveBlocker.allCases
                .filter { $0 != .applying && $0 != .acknowledgementStale }.map { "\($0)" })
        #expect(aloneIn == expected)
        #expect(!expected.isEmpty)
    }

    // MARK: - The catalogue

    @MainActor @Test func everyLineResolvesInAllFourLocales() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        let lines = Self.everyLine()
        for line in lines {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, sentinel) }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
            }
        }
        #expect(lines.count > 0)
    }

    @MainActor @Test func theEnglishCatalogueSaysTheDefault() {
        let lines = Self.everyLine()
        for line in lines {
            let english = L10n.$localeOverride.withValue("en") { L10n.string(line.key, "ZZ-UNRESOLVED-ZZ") }
            #expect(english == line.english, "\(line.key)")
        }
        #expect(lines.count > 0)
    }

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

    /// The default's warning is not the per-file one: it is about every file
    /// added from now on, and says so. Distinct in every language.
    @MainActor @Test func theDefaultsWarningIsItsOwnSentence() {
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) {
                (
                    BucketObjectLockModel.complianceWarningLine.text,
                    ObjectLockModel.complianceWarningLine.text,
                    BucketObjectLockModel.complianceAcknowledgementLine.text,
                    ObjectLockModel.complianceAcknowledgementLine.text
                )
            }
            #expect(texts.0 != texts.1, "\(locale)")
            #expect(texts.2 != texts.3, "\(locale)")
            #expect(texts.0 != texts.2, "\(locale)")
        }
        let english = L10n.$localeOverride.withValue("en") {
            BucketObjectLockModel.complianceWarningLine.text.lowercased()
        }
        #expect(english.contains("every file"))
        #expect(english.contains("undone"))
    }

    /// Plain words: nothing of how the store works.
    @MainActor @Test func theDefaultsWordsNameNoStoreMechanics() {
        let english = L10n.$localeOverride.withValue("en") {
            Self.everyLine().map { $0.text.lowercased() }
        }
        for text in english {
            for jargon in ["bypass", "header", "403", "x-amz", "version id", "delete marker", "xml"] {
                let leaked = text.contains(jargon)
                #expect(!leaked, "\(jargon)")
            }
        }
        #expect(!english.isEmpty)
    }

    @MainActor @Test func everyKeyTheSheetUsesIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/BucketObjectLockSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(source.matches(of: #/"(s3\.objectLock\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let covered = Set(Self.everyLine().map(\.key))
        let uncovered = used.subtracting(covered).sorted()
        #expect(uncovered.isEmpty, "\(uncovered)")
    }

    /// The sheet saves to, and reads from, the bucket it was opened for.
    @Test func theSheetSavesAndLoadsTheBucketItWasOpenedFor() throws {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/BucketObjectLockSheet.swift")
        let source = try SourceCorpus.code(of: url)
        let saves = source.matches(of: #/model\.save\(([^)]*)\)/#).map { String($0.output.1) }
        #expect(saves == ["bucket: bucket, via: settings, recorder: recorder"])
        let loads = source.matches(of: #/model\.load\(([^)]*)\)/#).map { String($0.output.1) }
        #expect(loads == ["bucket: bucket, via: settings, cache: cache"])
    }

    /// The acknowledgement is the wrapping checkbox, not a hand-written Toggle.
    @Test func theAcknowledgementIsAWrappingCheckboxRow() throws {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/BucketObjectLockSheet.swift")
        let source = try SourceCorpus.code(of: url)
        #expect(source.matches(of: #/CheckboxRow\(/#).count == 1)
        #expect(source.matches(of: #/wraps:\s*true/#).count == 1)
        #expect(!source.contains("Toggle("))
    }

    @MainActor static func everyLine() -> [CatalogueLine] {
        var lines = BucketObjectLockModel.fixedLines
        for scenario in scenarios {
            lines += model(for: scenario).0.lines
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0.key).inserted }
    }
}
