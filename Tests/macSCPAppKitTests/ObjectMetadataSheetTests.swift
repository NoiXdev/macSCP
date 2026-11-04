import Foundation
import MacSCPTestSupport
import Synchronization
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// An in-memory `ObjectMetadataProvider` that records what it is asked.
///
/// It answers the three calls the sheet makes. `acl` answers what `aclAnswer`
/// says (by default the store offers none, `nil`, which is what Core returns
/// for a store without object ACLs) and records every key it was asked about
/// in `aclReads`.
///
/// `observeAtWrite` runs at the moment `setMetadata` is called, before the
/// call is recorded: it is how a test sees what the store had been asked
/// BEFORE the write, which a count read afterwards cannot tell.
final class FakeObjectMetadataProvider: ObjectMetadataProvider, Sendable {
    /// What `acl(ofKey:inBucket:)` answers.
    enum ACLAnswer: Sendable {
        /// `nil` from Core: the store offers no object ACLs.
        case notOffered
        case policy(ObjectACL)
        case failure(any Error)
    }

    struct Write: Equatable, Sendable {
        let metadata: ObjectMetadata
        let key: String
        let bucket: String
    }

    private struct State {
        var stored: ObjectMetadata
        var readError: (any Error)?
        var writeError: (any Error)?
        var reads: [String] = []
        var aclReads: [String] = []
        var aclAnswer: ACLAnswer
        var writes: [Write] = []
        var observation: Int?
    }

    private let state: Mutex<State>
    private let observeAtWrite: (@Sendable () -> Int)?
    private let writeEntered: AsyncSignal?
    private let writeRelease: AsyncSignal?

    init(
        stored: ObjectMetadata, readError: (any Error)? = nil, writeError: (any Error)? = nil,
        aclAnswer: ACLAnswer = .notOffered,
        observeAtWrite: (@Sendable () -> Int)? = nil, writeEntered: AsyncSignal? = nil,
        writeRelease: AsyncSignal? = nil
    ) {
        state = Mutex(
            State(
                stored: stored, readError: readError, writeError: writeError,
                aclAnswer: aclAnswer))
        self.observeAtWrite = observeAtWrite
        self.writeEntered = writeEntered
        self.writeRelease = writeRelease
    }

    var reads: [String] { state.withLock { $0.reads } }
    var writes: [Write] { state.withLock { $0.writes } }
    /// The keys `acl(ofKey:inBucket:)` was asked about, in order.
    var aclReads: [String] { state.withLock { $0.aclReads } }
    /// What `observeAtWrite` answered at the first write, or `nil` if there was none.
    var observationAtFirstWrite: Int? { state.withLock { $0.observation } }

    func metadata(ofKey key: String, inBucket bucket: String) async throws -> ObjectMetadata {
        try state.withLock { state in
            state.reads.append(key)
            if let error = state.readError { throw error }
            return state.stored
        }
    }

    func setMetadata(_ metadata: ObjectMetadata, ofKey key: String, inBucket bucket: String) async throws {
        let seen = observeAtWrite?()
        state.withLock { state in
            if state.observation == nil { state.observation = seen }
            state.writes.append(Write(metadata: metadata, key: key, bucket: bucket))
        }
        writeEntered?.signal()
        if let release = writeRelease { _ = await release.wait() }
        try state.withLock { state in
            if let error = state.writeError { throw error }
            state.stored = metadata
        }
    }

    func acl(ofKey key: String, inBucket bucket: String) async throws -> ObjectACL? {
        let answer = state.withLock { state in
            state.aclReads.append(key)
            return state.aclAnswer
        }
        switch answer {
        case .notOffered: return nil
        case .policy(let policy): return policy
        case .failure(let error): throw error
        }
    }
}

/// The metadata sheet's decisions: what it says, what it sends, and the
/// acknowledgement a COMPLIANCE-default bucket requires before it writes.
///
/// ## How sensitive these are: ten plants, committed with their commands
///
/// The commit that introduced this file has a compile failure as its red (the
/// sheet was drafted before its tests and moved out of `Sources/` for one
/// build), so the behavioural weight of "these tests would notice" is carried
/// by plants. Each ran through `scripts/mutation-probe` from the repository
/// root on a clean tree, which refuses a dirty one and reverts index-safely;
/// each printed, verbatim, the control line (the unplanted tree's run) and the
/// verdict below it. P1 to P7 and P10 plant into the sheet's model and are
/// read by this suite (P1 and P5 to P7 were the implementer's, and the review
/// re-ran P1; P2 to P4 were the review's); P8 and P9 plant into the wiring
/// and are read by the audit-wiring guard in `BucketSettingsAuditTests`; P10
/// makes a refused write report `.written`. Run 2026-11-03 on the tree of the round-1 fix commit,
/// `fix(app): metadata sheet review round 1, a save says whether it wrote, and
/// the audit guard sees the sheet`.
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P1 a stale acknowledgement no longer refuses' \
///   --apply "perl -0pi -e 's/            if acknowledgementIsStale \{\n                refusedSaves \+= 1\n                return \.refused\(\.acknowledgementStale\)\n            \}\n//' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aTickGivenForOneDayDoesNotStandForAnother()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P2 an ungiven acknowledgement no longer refuses' \
///   --apply "perl -0pi -e 's/            if !acknowledged \{\n                refusedSaves \+= 1\n                return \.refused\(\.complianceNotAcknowledged\)\n            \}\n//' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aComplianceDefaultBucketRefusesToSaveWithoutAnAcknowledgement()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aDefaultThatBecameComplianceWhileTheSheetWasOpenIsNotWrittenUnder()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aRefusedSaveIsSomethingTheSheetCanSee()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aSaveTheSheetRefusedRecordsNothing()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aTickIsNotCarriedOverToADifferentDefault()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aTickedComplianceDefaultBucketIsWrittenOnceAndTheTickIsSpent()
///   macSCPAppKitTests.ObjectMetadataSheetTests/inNoStateDoesSaveWriteWhatCanSaveRefused()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P3 the pre-write read asks for a default on a bucket with no lock' \
///   --apply "perl -0pi -e 's/            present \? try await Self\.lockDefault\(of: target\.bucket, via: settings\) : nil/            try await Self.lockDefault(of: target.bucket, via: settings)/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aBucketWithoutObjectLockReadsNoDefaultAtAll()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P4 the audit line carries the typed Cache-Control value' \
///   --apply "perl -0pi -e 's/key: target\.key, bucket: target\.bucket, standardFieldCount: standardFieldCount,\n                customPairCount: written\.custom\.count, complianceDefaultDays: complianceDays,\n                failure: nil\)/key: target.key + \" \" + (written.cacheControl ?? \"\"), bucket: target.bucket, standardFieldCount: standardFieldCount,\n                customPairCount: written.custom.count, complianceDefaultDays: complianceDays,\n                failure: nil)/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aWriteLeavesOneLineOfItsOwnKind()
///   macSCPAppKitTests.ObjectMetadataSheetTests/theAuditLineForAMetadataChangeCarriesNoCredential()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P5 no lock re-read before the write' \
///   --apply "perl -0pi -e 's/            try await readLockBeforeTheWrite\(\)\n/            _ = 0\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aDefaultThatBecameComplianceWhileTheSheetWasOpenIsNotWrittenUnder()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aLockReadThatFailsBeforeTheWriteWritesNothingAndSaysSo()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aTickIsNotCarriedOverToADifferentDefault()
///   macSCPAppKitTests.ObjectMetadataSheetTests/theDefaultIsReadAgainImmediatelyBeforeEveryWrite()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P6 a draft equal to the store is no longer refused' \
///   --apply "perl -0pi -e 's/        guard hasChanges else \{ return \.refused\(\.nothingChanged\) \}\n//' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aSaveRightAfterOpeningWritesNothing()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aSaveTheSheetRefusedRecordsNothing()
///   macSCPAppKitTests.ObjectMetadataSheetTests/afterASaveTheSavedValuesAreWhatTheSheetCompares()
///   macSCPAppKitTests.ObjectMetadataSheetTests/changingAFieldBackBeforeSavingWritesNothing()
///   macSCPAppKitTests.ObjectMetadataSheetTests/inNoStateDoesSaveWriteWhatCanSaveRefused()
///   macSCPAppKitTests.ObjectMetadataSheetTests/spacesAroundAValueAreNotAChange()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P7 the content type is dropped from what is sent' \
///   --apply "perl -0pi -e 's/        let written = draftMetadata\n/        var written = draftMetadata\n        written.contentType = nil\n/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aFieldClearedByThePersonIsSentAsNone()
///   macSCPAppKitTests.ObjectMetadataSheetTests/aWriteLeavesOneLineOfItsOwnKind()
///   macSCPAppKitTests.ObjectMetadataSheetTests/afterASaveTheSavedValuesAreWhatTheSheetCompares()
///   macSCPAppKitTests.ObjectMetadataSheetTests/savingSendsEveryFieldThatWasLoadedAndNotOnlyTheOneThatChanged()
/// ```
///
/// ```
/// scripts/mutation-probe --filter BucketSettingsAuditTests \
///   --label 'P8 the menu arm builds the metadata item with recorder: nil' \
///   --apply "perl -0pi -e 's/ObjectMetadataSheetItem\(\n                        recorder: tab\.auditRecorder,/ObjectMetadataSheetItem(\n                        recorder: nil,/' Sources/MacSCPAppKit/ContentView+MenuActions.swift"
/// ── control: 16 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 16 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.BucketSettingsAuditTests/everySheetItemIsBuiltWithTheTabsRecorder()
/// ```
///
/// ```
/// scripts/mutation-probe --filter BucketSettingsAuditTests \
///   --label 'P9 the model is built without the item recorder' \
///   --apply "perl -0pi -e 's/target: item\.target, recorder: item\.recorder, provider: item\.provider,/target: item.target, recorder: nil, provider: item.provider,/' Sources/MacSCPAppKit/ContentView+Sheets.swift"
/// ── control: 16 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 16 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.BucketSettingsAuditTests/everySheetIsBuiltWithItsItemsRecorder()
/// ```
///
/// ```
/// scripts/mutation-probe --filter ObjectMetadataSheetTests \
///   --label 'P10 a refused write is reported as written' \
///   --apply "perl -0pi -e 's/                failure: applyFailure\)\n            return \.failed/                failure: applyFailure)\n            return .written/' Sources/MacSCPAppKit/ObjectMetadataSheet.swift"
/// ── control: 39 test(s) ran, 0 pre-existing failures
/// RESULT: RED — 39 test(s) ran, and the plant was caught by:
///   macSCPAppKitTests.ObjectMetadataSheetTests/aRefusedWriteIsRecordedAsAFailureWithAFixedSentence()
/// ```
///
/// **P10's anchor no longer exists, 2026-11-04.** The recipe above is kept as
/// the record of the run it reports, not as one to re-run: the line it
/// matches moved when the catch arm stopped carrying two kinds of news in
/// `applyFailure`. Re-run as written, the `perl` matches nothing, the tree is
/// unchanged, and the probe reports a GREEN that is a false all-clear.
///
///     /usr/bin/grep -c -F 'failure: applyFailure)' Sources/MacSCPAppKit/ObjectMetadataSheet.swift
///
/// prints 0 and exits 1, with the positive control
///
///     /usr/bin/grep -c -F 'failure: applyNotice?.text)' Sources/MacSCPAppKit/ObjectMetadataSheet.swift
///
/// printing 1 and exiting 0 — so the zero above is a moved line and not an
/// unopened file. Substituting `applyNotice?.text` for `applyFailure` in the
/// recipe makes it plant again; the figures beside it would then be a claim
/// about a run nobody made.
///
@Suite("Object metadata sheet")
struct ObjectMetadataSheetTests {
    private static let locales = ["en", "de", "fr", "pl"]
    private static let now = ObjectLockSheetTests.now
    private static let target = ObjectLockTarget(bucket: "macscp-seed", key: "docs/report.txt")

    /// A value that must never reach the trail or a failure message. A named
    /// constant, and every check that it did not leak computes its `Bool`
    /// first: `#expect` prints the source text of the expression it checks, so
    /// a value written into an expectation would leak through the failure of
    /// the very test that forbids it.
    private static let secretLookingValue = "metadata-value-canary-3c9e"
    private static let storeWords = "store-words-canary-5b1d"

    final class Clock: @unchecked Sendable { var date = ObjectMetadataSheetTests.now }

    /// Several fields set, so that a save which sent only the changed one would
    /// drop the others.
    private static var stored: ObjectMetadata {
        ObjectMetadata(
            contentType: "text/plain", cacheControl: "max-age=60",
            contentDisposition: "inline", custom: ["author": "Ada", "team": "docs"],
            entityTag: "\"0123456789abcdef\"")
    }

    /// Everything a test needs, built the way the menu action builds it.
    @MainActor struct Rig {
        let provider: FakeObjectMetadataProvider
        let settings: FakeBucketSettings
        let model: ObjectMetadataModel
        let trail: Trail?
        let clock: Clock

        init(
            stored: ObjectMetadata = ObjectMetadataSheetTests.stored,
            versioning: BucketVersioning = .enabled,
            lock: FakeBucketSettings.ObjectLockFixture? = .init(hasLock: false),
            readError: (any Error)? = nil, writeError: (any Error)? = nil,
            aclAnswer: FakeObjectMetadataProvider.ACLAnswer = .notOffered,
            recording: Bool = false, writeEntered: AsyncSignal? = nil,
            writeRelease: AsyncSignal? = nil
        ) {
            let settings = FakeBucketSettings(versioning: versioning, lock: lock)
            let atWrite: @Sendable () -> Int = { settings.defaultReads.count }
            let provider = FakeObjectMetadataProvider(
                stored: stored, readError: readError, writeError: writeError,
                aclAnswer: aclAnswer, observeAtWrite: atWrite, writeEntered: writeEntered, writeRelease: writeRelease)
            let trail = recording ? Trail() : nil
            let clock = Clock()
            self.provider = provider
            self.settings = settings
            self.trail = trail
            self.clock = clock
            model = ObjectMetadataModel(
                target: ObjectMetadataSheetTests.target, recorder: trail?.recorder,
                provider: provider, settings: settings,
                locks: ObjectLockStateCache(settings: settings),
                versioning: BucketVersioningCache(settings: settings), now: { clock.date })
        }
    }

    /// A recorder over a store of its own, and the way to read what it
    /// recorded.
    final class Trail {
        let recorder: AuditRecorder
        let directory: URL
        let store: AuditLogStore
        let sessionID = UUID()

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectMetadataSheetTests-\(UUID().uuidString)", isDirectory: true)
            store = AuditLogStore(directory: directory)
            recorder = AuditRecorder(sessionID: sessionID, store: store)
        }

        var events: [AuditEvent] { store.events(for: sessionID) }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private static func complianceLock(days: Int = 30) -> FakeBucketSettings.ObjectLockFixture {
        .init(hasLock: true, bucketDefault: .init(days: days, mode: .compliance))
    }

    private static func governanceLock(days: Int = 30) -> FakeBucketSettings.ObjectLockFixture {
        .init(hasLock: true, bucketDefault: .init(days: days, mode: .governance))
    }

    // MARK: - What it says

    @MainActor @Test func theSheetSaysAVersionWillBeAddedOnAVersionedBucket() async {
        let versioned = Rig(versioning: .enabled)
        await versioned.model.load()
        #expect(versioned.model.versionNote?.key == ObjectMetadataLines.versionAdded.key)
        let english = L10n.$localeOverride.withValue("en") {
            ObjectMetadataLines.versionAdded.text.lowercased()
        }
        let namesAVersion = english.contains("adds a new version")
        #expect(namesAVersion)

        // The positive control: the sentence is not said where it would be false.
        for state in [BucketVersioning.never, .suspended] {
            let other = Rig(versioning: state)
            await other.model.load()
            #expect(other.model.versionNote == nil, "\(state)")
        }
    }

    @MainActor @Test func aVersioningStateThatCouldNotBeReadIsSaidToBeUnconfirmedAndNotGuessed() async {
        let settings = FakeBucketSettings(
            versioning: .enabled, readError: RemoteFSError.protocolError(reason: Self.storeWords),
            lock: .init(hasLock: false))
        let model = ObjectMetadataModel(
            target: Self.target, recorder: nil,
            provider: FakeObjectMetadataProvider(stored: Self.stored),
            settings: settings, locks: ObjectLockStateCache(settings: settings),
            versioning: BucketVersioningCache(settings: settings))
        await model.load()
        #expect(model.versionNote?.key == ObjectMetadataLines.versionUnknown.key)
        #expect(model.phase == .ready, "the metadata was read, and stays editable")
    }

    @MainActor @Test func theFormStartsOnEverythingThatWasRead() async {
        let rig = Rig()
        await rig.model.load()
        #expect(rig.model.phase == .ready)
        #expect(rig.model.contentType == "text/plain")
        #expect(rig.model.cacheControl == "max-age=60")
        #expect(rig.model.contentDisposition == "inline")
        #expect(rig.model.custom.map(\.name) == ["author", "team"])
        #expect(rig.model.custom.map(\.value) == ["Ada", "docs"])
        #expect(rig.provider.reads == [Self.target.key])
    }

    @MainActor @Test func aMetadataReadThatFailedIsSaidInAFixedSentenceAndOffersNoSave() async {
        let rig = Rig(readError: RemoteFSError.protocolError(reason: Self.storeWords))
        await rig.model.load()
        guard case .failed(let sentence) = rig.model.phase else {
            Issue.record("the phase after a failed read was \(rig.model.phase)")
            return
        }
        #expect(sentence == ObjectMetadataLines.readFailed.text)
        let leaked = sentence.contains(Self.storeWords)
        #expect(leaked == false)
        #expect(rig.model.canSave == false)
        #expect(await rig.model.save() == .blocked)
        #expect(rig.provider.writes.isEmpty)
    }

    // MARK: - COMPLIANCE

    /// Review Focus 3.
    @MainActor @Test func aComplianceDefaultBucketRefusesToSaveWithoutAnAcknowledgement() async {
        let rig = Rig(lock: Self.complianceLock())
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        #expect(rig.model.canSave == false)
        #expect(rig.model.explanation?.key == BucketObjectLockModel.notAcknowledgedLine.key)
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        #expect(rig.provider.writes.isEmpty, "a COMPLIANCE-default bucket was written without the tick")
    }

    @MainActor @Test func theAcknowledgementNamesTheDateTheVersionBecomesUndeletable() async {
        let rig = Rig(lock: Self.complianceLock(days: 30))
        await rig.model.load()
        let thirtyDays = Calendar.current.date(byAdding: .day, value: 30, to: Self.now) ?? Self.now
        let expected = Calendar.current.startOfDay(for: thirtyDays)
        #expect(rig.model.acknowledgementDate == expected)
        let dayText = ObjectLockDates.dayText(expected, localeCode: nil)
        #expect(rig.model.acknowledgementDateText == dayText)
        let sentence = rig.model.acknowledgementSentence
        let namesTheDay = sentence.contains(dayText)
        #expect(namesTheDay)
        #expect(ObjectMetadataLines.complianceAcknowledgement.key == "s3.metadata.complianceAcknowledgement %@")
        // The date follows the default's days.
        let longer = Rig(lock: Self.complianceLock(days: 365))
        await longer.model.load()
        #expect(longer.model.acknowledgementDate != rig.model.acknowledgementDate)
    }

    @MainActor @Test func aTickedComplianceDefaultBucketIsWrittenOnceAndTheTickIsSpent() async {
        let rig = Rig(lock: Self.complianceLock())
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        rig.model.acknowledged = true
        #expect(rig.model.canSave)
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
        #expect(rig.model.isSaved)
        #expect(rig.model.acknowledged == false, "the tick was spent by the write")
        // A second change needs a new tick.
        rig.model.cacheControl = "max-age=5"
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        #expect(rig.provider.writes.count == 1)
    }

    /// Review Focus: the case the brief names no test for. A tick is valid for
    /// the day it named; the clock moves while the sheet is open.
    @MainActor @Test func aTickGivenForOneDayDoesNotStandForAnother() async {
        let rig = Rig(lock: Self.complianceLock())
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        rig.model.acknowledged = true
        let named = rig.model.acknowledgementDate

        rig.clock.date = Self.now.addingTimeInterval(1)
        #expect(rig.model.acknowledgementDate == named)
        #expect(rig.model.canSave, "the same day, a moment later")

        rig.clock.date = Self.now.addingTimeInterval(2 * 86_400)
        #expect(rig.model.acknowledgementDate != named)
        #expect(rig.model.activeBlockers == [.acknowledgementStale])
        #expect(rig.model.explanation?.key == BucketObjectLockModel.staleLine.key)
        #expect(await rig.model.save() == .refused(.acknowledgementStale))
        #expect(rig.provider.writes.isEmpty, "a tick for another day wrote a COMPLIANCE-default bucket")
        #expect(rig.model.acknowledged, "the tick stands: it is not taken away unexplained")

        // Re-ticking is what clears it.
        rig.model.acknowledged = false
        #expect(rig.model.explanation?.key == BucketObjectLockModel.notAcknowledgedLine.key)
        rig.model.acknowledged = true
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
    }

    @MainActor @Test func aRefusedSaveIsSomethingTheSheetCanSee() async {
        let rig = Rig(lock: Self.complianceLock())
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        let before = rig.model.refusedSaves
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        #expect(rig.model.refusedSaves == before + 1)
    }

    @MainActor @Test func aGovernanceDefaultBucketNeedsNoAcknowledgement() async {
        let rig = Rig(lock: Self.governanceLock())
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        #expect(rig.model.defaultIsCompliance == false)
        #expect(rig.model.canSave)
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
    }

    @MainActor @Test func aLockedBucketWithNoDefaultNeedsNoAcknowledgement() async {
        let rig = Rig(lock: .init(hasLock: true, bucketDefault: nil))
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
    }

    /// Zero requests for the default on a counting stub, the first half's D1
    /// lesson: a bucket without Object Lock has no default to read, and the
    /// answer to "does it have a lock" is not a request for one.
    @MainActor @Test func aBucketWithoutObjectLockReadsNoDefaultAtAll() async {
        let rig = Rig(lock: .init(hasLock: false))
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
        #expect(rig.settings.defaultReads.isEmpty, "a default was read for a bucket with no Object Lock")
        // The positive control: the question that IS asked was asked.
        #expect(rig.settings.hasLockReads.isEmpty == false)
        // And the counter counts: a bucket with a lock is read.
        let locked = Rig(lock: Self.governanceLock())
        await locked.model.load()
        #expect(locked.settings.defaultReads.isEmpty == false)
    }

    // MARK: - The default is read before the write

    /// Not only when the sheet opened: the default can change while it is
    /// open, and an acknowledgement is for the default it was given for.
    @MainActor @Test func theDefaultIsReadAgainImmediatelyBeforeEveryWrite() async {
        for lock in [Self.governanceLock(), Self.complianceLock(), .init(hasLock: true, bucketDefault: nil)] {
            let rig = Rig(lock: lock)
            await rig.model.load()
            let readsAfterLoad = rig.settings.defaultReads.count
            #expect(readsAfterLoad == 1)
            rig.model.cacheControl = "no-cache"
            rig.model.acknowledged = rig.model.defaultIsCompliance
            #expect(await rig.model.save() == .written)
            #expect(rig.provider.writes.count == 1)
            #expect(rig.provider.observationAtFirstWrite == readsAfterLoad + 1)
        }
    }

    @MainActor @Test func aDefaultThatBecameComplianceWhileTheSheetWasOpenIsNotWrittenUnder() async throws {
        let rig = Rig(lock: Self.governanceLock())
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        #expect(rig.model.canSave, "the sheet believes the default is GOVERNANCE")
        try await rig.settings.setObjectLockDefault(days: 90, mode: .compliance, ofBucket: Self.target.bucket)
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.model.defaultIsCompliance, "the sheet now shows the acknowledgement")
        #expect(rig.model.bucketDefault == .init(days: 90, mode: .compliance))
    }

    @MainActor @Test func aTickIsNotCarriedOverToADifferentDefault() async throws {
        let rig = Rig(lock: Self.complianceLock(days: 30))
        await rig.model.load()
        rig.model.cacheControl = "no-cache"
        rig.model.acknowledged = true
        try await rig.settings.setObjectLockDefault(days: 365, mode: .compliance, ofBucket: Self.target.bucket)
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        #expect(rig.provider.writes.isEmpty, "a tick for 30 days stood for 365")
        #expect(rig.model.acknowledged == false)
    }

    @MainActor @Test func aLockReadThatFailsBeforeTheWriteWritesNothingAndSaysSo() async {
        var fixture = Self.governanceLock()
        fixture.readError = RemoteFSError.protocolError(reason: Self.storeWords)
        let rig = Rig(lock: fixture)
        await rig.model.load()
        guard case .failed = rig.model.bucketLock else {
            Issue.record("the lock state after a failed default read was \(rig.model.bucketLock)")
            return
        }
        #expect(rig.model.activeBlockers.contains(.lockReadFailed))
        rig.model.cacheControl = "no-cache"
        #expect(rig.model.canSave == false)
        // Straight to save(), past the button: it reads again, fails again, writes nothing.
        #expect(await rig.model.save() == .failed)
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.model.applyNotice == .failed(ObjectLockLines.readFailed.text))
        let leaked = (rig.model.applyNotice?.text ?? "").contains(Self.storeWords)
        #expect(leaked == false)
    }

    // MARK: - Nothing changed

    @MainActor @Test func changingAFieldBackBeforeSavingWritesNothing() async {
        let rig = Rig(lock: Self.complianceLock())
        await rig.model.load()
        rig.model.acknowledged = true
        rig.model.cacheControl = "no-cache"
        #expect(rig.model.hasChanges)
        rig.model.cacheControl = "max-age=60"
        #expect(rig.model.hasChanges == false)
        let defaultReads = rig.settings.defaultReads.count
        #expect(await rig.model.save() == .refused(.nothingChanged))
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.settings.defaultReads.count == defaultReads, "a save that writes nothing asked the store something")
        #expect(rig.model.explanation?.key == ObjectMetadataLines.unchangedLine.key)
    }

    @MainActor @Test func aSaveRightAfterOpeningWritesNothing() async {
        let rig = Rig()
        await rig.model.load()
        #expect(rig.model.canSave == false)
        #expect(await rig.model.save() == .refused(.nothingChanged))
        #expect(rig.provider.writes.isEmpty)
    }

    @MainActor @Test func spacesAroundAValueAreNotAChange() async {
        let rig = Rig()
        await rig.model.load()
        rig.model.contentType = "  text/plain "
        #expect(rig.model.hasChanges == false)
        #expect(await rig.model.save() == .refused(.nothingChanged))
    }

    // MARK: - What is sent

    /// A `REPLACE` copy replaces everything: a field not sent is dropped. So
    /// editing one field must send the rest as they were read.
    @MainActor @Test func savingSendsEveryFieldThatWasLoadedAndNotOnlyTheOneThatChanged() async {
        let rig = Rig()
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        #expect(await rig.model.save() == .written)
        let sent = rig.provider.writes.first
        #expect(rig.provider.writes.count == 1)
        #expect(sent?.key == Self.target.key)
        #expect(sent?.bucket == Self.target.bucket)
        #expect(
            sent?.metadata
                == ObjectMetadata(
                    contentType: "text/plain", cacheControl: "no-store",
                    contentDisposition: "inline", custom: ["author": "Ada", "team": "docs"],
                    entityTag: Self.stored.entityTag))
    }

    @MainActor @Test func aFieldClearedByThePersonIsSentAsNone() async {
        let rig = Rig()
        await rig.model.load()
        rig.model.contentDisposition = ""
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.first?.metadata.contentDisposition == nil)
        #expect(rig.provider.writes.first?.metadata.contentType == "text/plain")
    }

    @MainActor @Test func customPairsCanBeAddedEditedAndRemoved() async {
        let rig = Rig()
        await rig.model.load()
        rig.model.addCustomRow()
        let added = rig.model.custom.last
        #expect(rig.model.hasChanges == false, "a blank row is not a pair")
        rig.model.custom[rig.model.custom.count - 1].name = "Reviewed"
        rig.model.custom[rig.model.custom.count - 1].value = "yes"
        if let team = rig.model.custom.first(where: { $0.name == "team" }) {
            rig.model.removeCustomRow(team.id)
        }
        #expect(await rig.model.save() == .written)
        #expect(added != nil)
        // The name is sent in the lower case the store keeps it in.
        #expect(rig.provider.writes.first?.metadata.custom == ["author": "Ada", "reviewed": "yes"])
    }

    @MainActor @Test func afterASaveTheSavedValuesAreWhatTheSheetCompares() async {
        let rig = Rig()
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        #expect(await rig.model.save() == .written)
        #expect(rig.model.hasChanges == false)
        #expect(await rig.model.save() == .refused(.nothingChanged))
        #expect(rig.provider.writes.count == 1)
    }

    // MARK: - A pair that cannot be sent

    @MainActor @Test func aPairWithoutANameDuplicateOrUnsendableNameKeepsSaveOffAndSaysWhich() async {
        let cases: [(name: String, value: String, expected: ObjectMetadataModel.DraftProblem)] = [
            ("", "value", .customNameMissing),
            ("author", "other", .customNameDuplicated),
            ("AUTHOR", "other", .customNameDuplicated),
            ("has space", "v", .customNameInvalid),
            ("caf\u{E9}", "v", .customNameInvalid),
            ("x-amz-meta-note", "v", .customNamePrefixed),
            ("X-Amz-Meta-Note", "v", .customNamePrefixed),
        ]
        for item in cases {
            let rig = Rig()
            await rig.model.load()
            rig.model.addCustomRow()
            rig.model.custom[rig.model.custom.count - 1].name = item.name
            rig.model.custom[rig.model.custom.count - 1].value = item.value
            #expect(rig.model.draftProblem == item.expected, "\(item.expected)")
            #expect(rig.model.canSave == false, "\(item.expected)")
            let line = rig.model.explanation
            let expectedLine: CatalogueLine =
                switch item.expected {
                case .customNameMissing: ObjectMetadataLines.customNameMissingLine
                case .customNameInvalid: ObjectMetadataLines.customNameInvalidLine
                case .customNamePrefixed: ObjectMetadataLines.customNamePrefixedLine
                case .customNameDuplicated: ObjectMetadataLines.customNameDuplicatedLine
                }
            #expect(line == expectedLine, "\(item.expected)")
            #expect(await rig.model.save() == .blocked)
            #expect(rig.provider.writes.isEmpty, "\(item.expected) was sent")
        }
        #expect(cases.count == 7)
    }

    // MARK: - The trail

    @MainActor @Test func aWriteLeavesOneLineOfItsOwnKind() async {
        let rig = Rig(lock: Self.complianceLock(days: 30), recording: true)
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        rig.model.acknowledged = true
        #expect(await rig.model.save() == .written)
        let events = rig.trail?.events ?? []
        #expect(events.count == 1)
        #expect(events.first?.kind == .metadataChanged)
        #expect(events.first?.isError == false)
        #expect(
            events.first?.detail
                == "metadata of macscp-seed/docs/report.txt replaced, sending 3 standard fields and 2 custom pairs; the bucket's COMPLIANCE default retention of 30 days applies to the new version"
        )
    }

    @MainActor @Test func aRefusedWriteIsRecordedAsAFailureWithAFixedSentence() async {
        let rig = Rig(
            writeError: RemoteFSError.protocolError(reason: Self.storeWords), recording: true)
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        #expect(await rig.model.save() == .failed)
        #expect(rig.provider.writes.count == 1)
        #expect(rig.model.applyNotice == .failed(ObjectLockLines.applyFailed.text))
        #expect(rig.model.isSaved == false)
        let events = rig.trail?.events ?? []
        #expect(events.count == 1)
        #expect(events.first?.isError == true)
        #expect(events.first?.errorMessage == ObjectLockLines.applyFailed.text)
        let leaked = events.contains {
            $0.detail.contains(Self.storeWords) || ($0.errorMessage ?? "").contains(Self.storeWords)
        }
        #expect(leaked == false)
        // The draft stays, so the person can try again.
        #expect(rig.model.cacheControl == "no-store")
        #expect(rig.model.hasChanges)
    }

    /// A write the storage TOOK, whose read-back did not confirm it, is said
    /// to be unconfirmed and never as a failure — the rule
    /// `ObjectMetadataLines.versionUnknown` states for a read holds for this
    /// write, because the change was sent and accepted. Core throws
    /// `setMetadataUnconfirmedReason` only after `copyObject` has returned,
    /// which means a 2xx with a `<CopyObjectResult>`: the object has changed,
    /// and on a versioned bucket there is a new version.
    ///
    /// **Both ways out of Core's read-back arrive as this one error** — the
    /// read answered and disagreed, and the read itself failed — so this case
    /// covers both by feeding the error rather than a store's answer; the
    /// Core side of the second is
    /// `S3ObjectMetadataTests.aReadBackThatFailsAfterAnAcceptedCopyIsAnUnconfirmedWrite`.
    ///
    /// **And the acknowledgement is spent.** The arm used to leave the tick
    /// standing, so on a bucket whose default retention is COMPLIANCE one
    /// more click was a second version nobody can erase, with no second
    /// ceremony. The tick goes back to the person for the same reason the
    /// `.written` arm takes it: a request left for the storage.
    @MainActor @Test func aWriteTheStorageTookWhoseReadBackFailedIsSaidToBeUnconfirmed() async {
        let rig = Rig(
            lock: Self.complianceLock(),
            writeError: UnconfirmedMetadataWrite.error,
            recording: true)
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        rig.model.acknowledged = true
        #expect(await rig.model.save() == .failed)
        // The control: the write really was sent, so there was something the
        // storage could have taken.
        #expect(rig.provider.writes.count == 1)
        #expect(rig.model.isSaved == false)
        #expect(rig.model.applyNotice == .unconfirmed(ObjectMetadataLines.saveUnconfirmed.text))
        // And not the sentence this arm used to say, which is false of a
        // change the storage took: "The change could not be saved."
        #expect(rig.model.applyNotice?.text != ObjectLockLines.applyFailed.text)
        // **And not in the failure's slot either.** The sentence is careful,
        // and the sheet drew it in `.red` directly above the missing
        // "Saved." until 2026-11-04 — so the answer to an accepted change
        // was read as a failure before a word of it. `isFailure` is the one
        // thing that becomes a colour (`ObjectMetadataModel.SaveNotice`), and
        // this is where it is held to being false for this error.
        #expect(rig.model.applyNotice?.isFailure == false)
        #expect(rig.model.acknowledged == false, "the tick was spent by the write")
        #expect(rig.model.activeBlockers.contains(.complianceNotAcknowledged))
        // So a second click asks for the ceremony again instead of writing.
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        #expect(rig.provider.writes.count == 1)
    }

    /// The other exit of the same arm: a write the storage REFUSED keeps the
    /// generic sentence, and spends the acknowledgement too.
    ///
    /// Spending it there is deliberate and is the conservative half of the
    /// rule: the request left, and for a failure that is not the unconfirmed
    /// one macSCP does not know whether the storage wrote anything (a
    /// connection lost after the request went out is this arm as much as a
    /// refusal is). One ceremony per request that leaves, not per request
    /// that is known to have landed. A refusal the sheet makes BEFORE the
    /// write leaves the tick standing — `aTickGivenForOneDayDoesNotStandForAnother`
    /// holds that — because nothing was sent.
    @MainActor @Test func aWriteTheStorageRefusedKeepsTheGenericSentenceAndSpendsTheTick() async {
        let rig = Rig(
            lock: Self.complianceLock(),
            writeError: RemoteFSError.protocolError(reason: Self.storeWords), recording: true)
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        rig.model.acknowledged = true
        #expect(await rig.model.save() == .failed)
        #expect(rig.provider.writes.count == 1)
        // The failure slot, drawn in red: the positive control for the
        // reading above it, which says the unconfirmed one is NOT drawn that
        // way. A `SaveNotice` that answered `isFailure` the same for both
        // would fail one of the two.
        #expect(rig.model.applyNotice == .failed(ObjectLockLines.applyFailed.text))
        #expect(rig.model.applyNotice?.isFailure == true)
        #expect(rig.model.acknowledged == false)
        let leaked = (rig.model.applyNotice?.text ?? "").contains(Self.storeWords)
        #expect(leaked == false)
    }

    @MainActor @Test func theAuditLineForAMetadataChangeCarriesNoCredential() async {
        var secretStored = Self.stored
        secretStored.custom["api-token"] = Self.secretLookingValue
        let rig = Rig(stored: secretStored, lock: Self.complianceLock(), recording: true)
        await rig.model.load()
        rig.model.cacheControl = Self.secretLookingValue
        rig.model.acknowledged = true
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
        let events = rig.trail?.events ?? []
        #expect(events.count == 1, "nothing was recorded, so nothing was checked")
        let value = Self.secretLookingValue
        let lineLeaks = events.contains {
            $0.detail.contains(value) || ($0.errorMessage ?? "").contains(value)
        }
        #expect(lineLeaks == false)
        // The positive control: the predicate finds the value where it is.
        let controlDetected = "sending \(value)".contains(value)
        #expect(controlDetected)
        // And the value really was in the request, so there was something to leak.
        let sent = rig.provider.writes.first?.metadata
        let wasSent = sent?.cacheControl == value && sent?.custom["api-token"] == value
        #expect(wasSent)
        // Not the name of a custom pair either: names are the person's own words.
        let nameLeaks = events.contains { $0.detail.contains("api-token") }
        #expect(nameLeaks == false)
    }

    @MainActor @Test func aSaveTheSheetRefusedRecordsNothing() async {
        let rig = Rig(lock: Self.complianceLock(), recording: true)
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        #expect(await rig.model.save() == .refused(.complianceNotAcknowledged))
        rig.model.cacheControl = "max-age=60"
        #expect(await rig.model.save() == .refused(.nothingChanged))
        #expect(rig.trail?.events.isEmpty == true)
        // The positive control: the same recorder records a write that goes through.
        rig.model.cacheControl = "no-store"
        rig.model.acknowledged = true
        #expect(await rig.model.save() == .written)
        #expect(rig.trail?.events.count == 1)
    }

    @MainActor @Test func withNoRecorderTheWriteStillGoesThrough() async {
        let rig = Rig()
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        #expect(await rig.model.save() == .written)
        #expect(rig.provider.writes.count == 1)
        #expect(rig.model.isSaved)
    }

    // MARK: - One at a time

    @MainActor @Test(.timeLimit(.minutes(5))) func aSecondSaveWhileOneIsInFlightSendsNothing() async {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let rig = Rig(writeEntered: entered, writeRelease: release)
        await rig.model.load()
        rig.model.cacheControl = "no-store"
        let first = Task { @MainActor in await rig.model.save() }
        _ = await entered.wait()
        #expect(rig.model.isApplying)
        #expect(rig.model.canSave == false)
        #expect(await rig.model.save() == .blocked)
        #expect(rig.provider.writes.count == 1, "a second save was sent while the first was in flight")
        release.signal()
        #expect(await first.value == .written)
        #expect(rig.provider.writes.count == 1)
        #expect(rig.model.isSaved)
    }

    // MARK: - A matrix: no state writes what canSave refused

    @MainActor @Test func inNoStateDoesSaveWriteWhatCanSaveRefused() async {
        enum Lock: CaseIterable { case none, governance, compliance }
        var wrote = 0
        var refused = 0
        for lock in Lock.allCases {
            for changed in [false, true] {
                for ticked in [false, true] {
                    let fixture: FakeBucketSettings.ObjectLockFixture =
                        switch lock {
                        case .none: .init(hasLock: false)
                        case .governance: Self.governanceLock()
                        case .compliance: Self.complianceLock()
                        }
                    let rig = Rig(lock: fixture)
                    await rig.model.load()
                    if changed { rig.model.cacheControl = "no-store" }
                    rig.model.acknowledged = ticked && lock == .compliance
                    let allowed = rig.model.canSave
                    let expected = changed && (lock != .compliance || ticked)
                    #expect(allowed == expected, "\(lock) changed:\(changed) ticked:\(ticked)")
                    // The outcome is the oracle's too: what canSave refused is
                    // refused for the reason the state has, and what it allowed
                    // is written.
                    let outcome: ObjectMetadataModel.SaveOutcome =
                        !changed
                        ? .refused(.nothingChanged)
                        : (lock == .compliance && !ticked
                            ? .refused(.complianceNotAcknowledged) : .written)
                    #expect(
                        await rig.model.save() == outcome,
                        "\(lock) changed:\(changed) ticked:\(ticked)")
                    #expect(
                        rig.provider.writes.count == (allowed ? 1 : 0),
                        "\(lock) changed:\(changed) ticked:\(ticked)")
                    if allowed { wrote += 1 } else { refused += 1 }
                }
            }
        }
        #expect(wrote > 0)
        #expect(refused > 0)
    }

    // MARK: - The catalogue

    @MainActor @Test func everyLineResolvesInEveryLanguageAndTheEnglishIsTheSourceText() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        // Words that are the same in a language as in English: the three
        // header names, which are not translated anywhere, and German "Name".
        // Named by language and key, so a copy anywhere else is still red,
        // and checked to be the English word rather than skipped.
        let sameInEveryLanguage: Set<String> = [
            ObjectMetadataLines.contentTypeLabel.key, ObjectMetadataLines.cacheControlLabel.key,
            ObjectMetadataLines.contentDispositionLabel.key,
        ]
        let sameInThatLanguage: Set<String> = ["de \(ObjectMetadataLines.customNameLabel.key)"]
        for line in ObjectMetadataLines.all + ObjectMetadataLines.borrowed {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, sentinel) }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
                if locale == "en" {
                    #expect(resolved == line.english, "\(line.key)")
                } else if sameInEveryLanguage.contains(line.key)
                    || sameInThatLanguage.contains("\(locale) \(line.key)")
                {
                    #expect(resolved == line.english, "\(line.key) in \(locale)")
                } else {
                    #expect(resolved != line.english, "\(line.key) in \(locale)")
                }
            }
        }
    }

    /// How many keys the family has, written down. **An independent figure**
    /// (`all.count` is a map of the thing it checks and can never disagree
    /// with it). The command that produces it, from the repository root:
    /// `grep -o '"s3\.metadata\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings | wc -l`.
    /// Adding a line means changing this figure, which is the point. It was
    /// 23 until `ObjectMetadataLines.saveUnconfirmed` arrived; the command
    /// above printed 24 on 2026-11-04, for `en` and for each of the three
    /// other catalogues with its path substituted.
    static let lineCount = 24

    @Test func theFamilyHasTheLinesItIsWrittenDownToHave() throws {
        #expect(ObjectMetadataLines.all.count == Self.lineCount)
        #expect(Set(ObjectMetadataLines.all.map(\.key)).count == Self.lineCount, "a key is used twice")
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/Resources/en.lproj/Localizable.strings")
        let catalogue = try String(contentsOf: url, encoding: .utf8)
        let keys = catalogue.matches(of: #/"(s3\.metadata\.[^"]+)" *=/#).map { String($0.output.1) }
        #expect(Set(keys) == Set(ObjectMetadataLines.all.map(\.key)))
        #expect(keys.count == Self.lineCount)
    }

    /// The figure and the order `ObjectMetadataLines.borrowed`'s doc comment
    /// states, held to the array.
    ///
    /// It existed because the two disagreed from the commit that wrote the
    /// file until 2026-11-04: the comment counted "Three lines", enumerated
    /// five, and the array held six. Nothing was red, because nothing read
    /// the comment — and the line the enumeration omitted,
    /// `ObjectLockLines.readFailed`, is one the sheet really draws, so the
    /// sentence nobody checked was in all four catalogues was the one the
    /// count hid. Each key is read off the type that owns it, so a rename
    /// moves this with it rather than leaving a literal behind.
    @MainActor @Test func theBorrowedLinesAreTheSixTheCommentNames() {
        let borrowed = ObjectMetadataLines.borrowed
        #expect(borrowed.count == 6)
        #expect(
            borrowed.map(\.key) == [
                ObjectLockLines.denied.key, ObjectLockLines.applyFailed.key,
                ObjectLockLines.readFailed.key, ObjectLockLines.saved.key,
                BucketObjectLockModel.notAcknowledgedLine.key,
                BucketObjectLockModel.staleLine.key,
            ])
    }

    @Test func everyTranslationKeepsTheSpecifiersOfTheEnglish() {
        let specifier = #/%(\d+\$)?(lld|@|d)/#
        var withSpecifiers = 0
        for line in ObjectMetadataLines.all {
            let english = line.english.matches(of: specifier).map { String($0.output.0) }.sorted()
            if !english.isEmpty { withSpecifiers += 1 }
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, "") }
                let found = resolved.matches(of: specifier).map { String($0.output.0) }.sorted()
                #expect(found == english, "\(line.key) in \(locale)")
            }
        }
        // The title and the acknowledgement.
        #expect(withSpecifiers == 2)
    }

    @MainActor @Test func theTwoComplianceSentencesAreTheSheetsOwnAndNameTheNewVersion() {
        for locale in Self.locales {
            let texts = L10n.$localeOverride.withValue(locale) {
                (
                    ObjectMetadataLines.complianceWarning.text,
                    BucketObjectLockModel.complianceWarningLine.text,
                    ObjectMetadataLines.complianceAcknowledgement.text,
                    BucketObjectLockModel.complianceAcknowledgementLine.text
                )
            }
            #expect(texts.0 != texts.1, "\(locale)")
            #expect(texts.2 != texts.3, "\(locale)")
        }
        let english = L10n.$localeOverride.withValue("en") {
            ObjectMetadataLines.complianceAcknowledgement.text.lowercased()
        }
        #expect(english.contains("new version"))
        #expect(english.contains("undone"))
    }

    /// The labels are the store's header names and the prefix sentence quotes
    /// the prefix; no other sentence names how the store works.
    @Test func theWordsNameNoStoreMechanicsExceptWhereThePersonTypesThem() {
        let exempt: Set<String> = [
            ObjectMetadataLines.contentTypeLabel.key, ObjectMetadataLines.cacheControlLabel.key,
            ObjectMetadataLines.contentDispositionLabel.key,
            ObjectMetadataLines.customNamePrefixedLine.key,
            ObjectMetadataLines.customNameInvalidLine.key,
        ]
        let lines = ObjectMetadataLines.all.filter { !exempt.contains($0.key) }
        for line in lines {
            let text = L10n.$localeOverride.withValue("en") { line.text.lowercased() }
            for jargon in ["bypass", "header", "403", "x-amz", "version id", "delete marker", "xml", "copy"] {
                let leaked = text.contains(jargon)
                #expect(!leaked, "\(jargon) in \(line.key)")
            }
        }
        #expect(lines.count > 10)
    }

    // MARK: - The sheet is wired to the model, and the descriptor to the route

    @Test func theSheetLoadsAndSavesThroughTheModel() throws {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/ObjectMetadataSheet.swift")
        let source = try SourceCorpus.code(of: url)
        let saves = source.matches(of: #/model\.save\(([^)]*)\)/#).map { String($0.output.1) }
        #expect(saves == [""])
        let loads = source.matches(of: #/model\.load\(([^)]*)\)/#).map { String($0.output.1) }
        #expect(loads == [""])
        #expect(source.matches(of: #/CheckboxRow\(/#).count == 1)
        #expect(source.matches(of: #/wraps:\s*true/#).count == 1)
        #expect(!source.contains("Toggle("))
    }

    @Test func theDescriptorOffersTheRowAndTheWindowRoutesIt() {
        let action = BackendDescriptor.descriptor(for: .s3).fileActions.first { $0.id == "s3.metadata" }
        #expect(action?.titleKey == "browser.action.metadata")
        #expect(action?.titleDefault == "Metadata…")
        if let action {
            #expect(BackendFileActionRoute(action: action) == .metadata)
            #expect(BackendFileActionRoute.verdict(for: action, bucketVersioning: nil).isAvailable)
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) {
                    L10n.string(action.titleKey, "ZZ-UNRESOLVED-ZZ")
                }
                #expect(resolved != "ZZ-UNRESOLVED-ZZ", "\(locale)")
            }
        }
    }

    @MainActor @Test func theRowIsOnlyOfferedWhereTheBackendHasTheCapability() {
        for kind in ConnectionKind.allCases where kind != .s3 {
            let ids = BackendDescriptor.descriptor(for: kind).fileActions.map(\.id)
            #expect(!ids.contains("s3.metadata"), "\(kind)")
        }
    }
}
