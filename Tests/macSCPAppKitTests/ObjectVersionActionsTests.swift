import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The five actions on a row of the version history, and the conditions under
/// which each is refused.
///
/// Every store is a fake that answers at once; no case waits on a clock and
/// none spins the main actor. What the store was asked is read off the
/// fake's own record (`FakeVersionProvider.writes`), never off the model, so a
/// model that said "done" without asking is red.
///
/// **Each refusal takes its positive beside it.** A refusal is a negative
/// check, and a negative check is the only kind that can go stale in silence:
/// a suite of refusals passes when the action enum is emptied. So every case
/// below names a row on which the same action IS offered, and
/// `everyActionIsOfferedOnAnOrdinaryEarlierRow` walks `VersionRowAction.allCases`
/// and checks it against a count, so an emptied enum is red there.
@Suite("Object version row actions", .timeLimit(.minutes(5)))
@MainActor
struct ObjectVersionActionsTests {
    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    private static func version(
        _ id: String, latest: Bool = false, marker: Bool = false, at seconds: TimeInterval = 0,
        etag: String? = nil
    ) -> ObjectVersion {
        ObjectVersion(
            versionId: id, key: "a.txt", isLatest: latest, isDeleteMarker: marker,
            size: marker ? nil : 10, modifiedAt: at(seconds), entityTag: marker ? nil : etag)
    }

    private static let target = ObjectVersionsTarget(
        bucket: "b", key: "a.txt", displayName: "a.txt", displayPath: "/b/a.txt")

    /// v3 is current; v2 and v1 are earlier content; m1 is a marker that is
    /// not the latest entry.
    private static var history: [ObjectVersion] {
        [
            version("v3", latest: true, at: 300, etag: "C"),
            version("m1", marker: true, at: 250),
            version("v2", at: 200, etag: "B"),
            version("v1", at: 100, etag: "A"),
        ]
    }

    /// What the window would be asked to do, and what the person was asked.
    @MainActor final class Calls {
        var opened: [String] = []
        var compared: [String] = []
        var downloaded: [String] = []
        var confirmations: [VersionConfirmation] = []
        /// How many writes had reached the store at the moment each question
        /// was asked.
        var writesWhenAsked: [Int] = []
    }

    struct Rig {
        let model: ObjectVersionsModel
        let provider: FakeVersionProvider
        let settings: FakeBucketSettings
        let calls: Calls
    }

    /// A loaded sheet over `history`. The bucket's versioning is `versioning`
    /// (a read that fails when `versioningReadFails`), its Object Lock is
    /// `lock` (none by default), every row's lock is read unless `readLocks`
    /// is off, and the person answers `answer` to any question.
    private static func rig(
        _ history: [ObjectVersion], versioning: BucketVersioning = .enabled,
        versioningReadFails: Bool = false,
        lock: FakeBucketSettings.ObjectLockFixture = .init(hasLock: false),
        readLocks: Bool = true, wired: Bool = true, answer: Bool = true,
        writes: FakeVersionProvider.WriteAnswer = .accepted, recorder: AuditRecorder? = nil
    ) async -> Rig {
        let settings = FakeBucketSettings(
            versioning: versioning,
            readError: versioningReadFails ? RemoteFSError.finding(.operationNotSupported) : nil,
            lock: lock)
        let provider = FakeVersionProvider(versions: history)
        provider.setWriteAnswer(writes)
        let calls = Calls()
        let handlers =
            wired
            ? VersionActionHandlers(
                open: { calls.opened.append($0.versionId) },
                compareWithCurrent: { calls.compared.append($0.versionId) },
                download: { calls.downloaded.append($0.versionId) })
            : VersionActionHandlers()
        let model = ObjectVersionsModel(
            target: target, provider: provider, recorder: recorder,
            locks: .init(settings: settings, cache: ObjectLockStateCache(settings: settings)),
            versioning: BucketVersioningCache(settings: settings), handlers: handlers,
            now: { epoch })
        model.confirm = { request in
            calls.confirmations.append(request)
            calls.writesWhenAsked.append(provider.writes.count)
            return answer
        }
        await model.load()
        if readLocks { await model.readLockStates(of: model.versions) }
        return Rig(model: model, provider: provider, settings: settings, calls: calls)
    }

    private static func row(_ id: String, in rig: Rig) -> ObjectVersion {
        rig.model.versions.first { $0.versionId == id }!
    }

    // MARK: - The enum is not empty

    @Test func everyActionIsOfferedOnAnOrdinaryEarlierRow() async {
        let rig = await Self.rig(Self.history)
        let v2 = Self.row("v2", in: rig)
        #expect(VersionRowAction.allCases.count == 5)
        for action in VersionRowAction.allCases {
            #expect(rig.model.isEnabled(action, on: v2), "\(action)")
            #expect(rig.model.refusal(of: action, on: v2) == nil, "\(action)")
        }
    }

    // MARK: - The refusals, each beside its positive

    @Test func compareIsNotOfferedOnTheCurrentRowOrOnADeleteMarker() async {
        let rig = await Self.rig(Self.history)
        // The positive: an earlier content row is compared.
        #expect(rig.model.isEnabled(.compareWithCurrent, on: Self.row("v2", in: rig)))
        #expect(rig.model.isEnabled(.compareWithCurrent, on: Self.row("v1", in: rig)))

        let current = Self.row("v3", in: rig)
        let marker = Self.row("m1", in: rig)
        #expect(!rig.model.isEnabled(.compareWithCurrent, on: current))
        #expect(rig.model.refusal(of: .compareWithCurrent, on: current) == .isTheCurrentVersion)
        #expect(!rig.model.isEnabled(.compareWithCurrent, on: marker))
        #expect(rig.model.refusal(of: .compareWithCurrent, on: marker) == .deleteMarkerHasNoContent)
    }

    /// When the file is deleted at the moment (a marker is the latest entry) there is
    /// no current content, so no earlier row has anything to be compared with.
    @Test func compareHasNothingToCompareWithWhileTheFileIsDeleted() async {
        let deleted = [
            Self.version("m2", latest: true, marker: true, at: 300),
            Self.version("v2", at: 200, etag: "B"),
        ]
        let rig = await Self.rig(deleted)
        let v2 = Self.row("v2", in: rig)
        #expect(rig.model.refusal(of: .compareWithCurrent, on: v2) == .currentIsADeleteMarker)
        #expect(!rig.model.isEnabled(.compareWithCurrent, on: v2))
        // The positive: the same row is still downloadable and restorable.
        #expect(rig.model.isEnabled(.download, on: v2))
        #expect(rig.model.isEnabled(.restore, on: v2))
    }

    @Test func downloadIsNotOfferedOnADeleteMarker() async {
        let rig = await Self.rig(Self.history)
        #expect(rig.model.isEnabled(.download, on: Self.row("v2", in: rig)))
        let marker = Self.row("m1", in: rig)
        #expect(!rig.model.isEnabled(.download, on: marker))
        #expect(rig.model.refusal(of: .download, on: marker) == .deleteMarkerHasNoContent)
        // Nothing reaches the window for a refused row.
        let outcome = await rig.model.action(.download, on: marker)
        #expect(outcome == .declined(.deleteMarkerHasNoContent))
        #expect(rig.calls.downloaded.isEmpty)
    }

    /// Open is refused on a marker with a TYPED reason, not a bare `false`: the
    /// person asking deserves the reason, and the reason is a sentence of this
    /// project's own.
    @Test func openIsRefusedOnADeleteMarkerWithAReasonTheMenuCanSay() async {
        let rig = await Self.rig(Self.history)
        #expect(rig.model.isEnabled(.open, on: Self.row("v2", in: rig)))
        let marker = Self.row("m1", in: rig)
        let refusal = rig.model.refusal(of: .open, on: marker)
        #expect(refusal == .deleteMarkerHasNoContent)
        #expect(refusal?.line == ObjectVersionsLines.refusalNoContent)
        #expect(refusal?.line.text.isEmpty == false)
        let outcome = await rig.model.action(.open, on: marker)
        #expect(outcome == .declined(.deleteMarkerHasNoContent))
        #expect(rig.calls.opened.isEmpty)
    }

    @Test func restoreIsNotOfferedOnTheCurrentRow() async {
        let rig = await Self.rig(Self.history)
        #expect(rig.model.isEnabled(.restore, on: Self.row("v2", in: rig)))
        let current = Self.row("v3", in: rig)
        #expect(!rig.model.isEnabled(.restore, on: current))
        #expect(rig.model.refusal(of: .restore, on: current) == .isTheCurrentVersion)
        let marker = Self.row("m1", in: rig)
        #expect(rig.model.refusal(of: .restore, on: marker) == .deleteMarkerHasNoContent)
    }

    /// "Is this the current version" is `isLatest` and NOT
    /// `rowState(of:) == .current`: the state puts a lock ahead of `.current`,
    /// so a locked newest version reads `.locked`, and a gate written against
    /// `.current` would offer a restore of the row that already is current.
    @Test func aLockedCurrentRowIsStillTheCurrentRow() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = [
            "v3": ObjectRetention(mode: .compliance, retainUntil: Self.at(600))
        ]
        let rig = await Self.rig(Self.history, lock: fixture)
        let current = Self.row("v3", in: rig)
        // The premise: the row is locked, so its state is not `.current`.
        #expect(rig.model.rowState(of: current) != .current)
        #expect(current.isLatest)
        #expect(rig.model.refusal(of: .restore, on: current) == .isTheCurrentVersion)
        #expect(rig.model.refusal(of: .compareWithCurrent, on: current) == .isTheCurrentVersion)
        // And the positive beside: an earlier unlocked row of the same history.
        #expect(rig.model.isEnabled(.restore, on: Self.row("v2", in: rig)))
    }

    /// The one mistake here that loses data. The sheet opens on `.suspended`
    /// (a suspended bucket still has a history), but a write to a suspended
    /// bucket REPLACES the `null` version instead of adding one, so a restore
    /// there destroys the current content. The two questions have different
    /// answers and this holds them apart.
    @Test(arguments: BucketVersioning.allCases)
    func restoreIsGatedOnVersioningBeingEnabledAndNotOnTheSheetsOwnAvailability(
        state: BucketVersioning
    ) async {
        let rig = await Self.rig(Self.history, versioning: state)
        let v2 = Self.row("v2", in: rig)
        #expect(rig.model.bucketVersioning == state)
        if state == .enabled {
            #expect(rig.model.isEnabled(.restore, on: v2))
        } else {
            #expect(!rig.model.isEnabled(.restore, on: v2))
            #expect(rig.model.refusal(of: .restore, on: v2) == .versioningIsNotEnabled)
        }
        // The sheet's own question, which says yes to `.suspended` as well.
        let sheetOpens = VersionsRowAvailability(versioning: state).isAvailable
        #expect(sheetOpens == (state != .never))
        // Everything that only reads stays offered on a suspended bucket.
        #expect(rig.model.isEnabled(.download, on: v2) == true)
        #expect(rig.model.isEnabled(.open, on: v2) == true)
    }

    @Test func aSuspendedBucketIsAskedNothingAndWrittenNothing() async {
        let rig = await Self.rig(Self.history, versioning: .suspended)
        let outcome = await rig.model.action(.restore, on: Self.row("v2", in: rig))
        #expect(outcome == .declined(.versioningIsNotEnabled))
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.calls.confirmations.isEmpty)
        // The positive: the same call on an enabled bucket does write.
        let enabled = await Self.rig(Self.history, versioning: .enabled)
        let done = await enabled.model.action(.restore, on: Self.row("v2", in: enabled))
        #expect(done == .restored)
        #expect(enabled.provider.writes.count == 1)
    }

    /// A state that could not be read is not `.enabled`.
    @Test func aVersioningStateThatCouldNotBeReadDoesNotOfferRestore() async {
        let rig = await Self.rig(Self.history, versioningReadFails: true)
        #expect(rig.model.bucketVersioning == nil)
        let v2 = Self.row("v2", in: rig)
        #expect(rig.model.refusal(of: .restore, on: v2) == .versioningIsNotEnabled)
        // The history itself still listed, and reading actions still offered.
        #expect(rig.model.phase == .loaded)
        #expect(rig.model.isEnabled(.download, on: v2))
    }

    @Test func deleteIsNotOfferedOnALockedRowOrOneWhoseLockIsUnknown() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = [
            "v2": ObjectRetention(mode: .governance, retainUntil: Self.at(600)),
            // Run out at `now`: no longer in force.
            "v0": ObjectRetention(mode: .governance, retainUntil: Self.at(-600)),
        ]
        fixture.legalHoldByVersion = ["v1": true]
        fixture.failingVersions = ["v4"]
        let history =
            Self.history + [
                Self.version("v0", at: 50, etag: "Z"), Self.version("v4", at: 40, etag: "Y"),
                Self.version("v5", at: 30, etag: "X"),
            ]
        // Every row's lock is read except v5's: it stays unknown.
        let rig = await Self.rig(history, lock: fixture, readLocks: false)
        await rig.model.readLockStates(of: rig.model.versions.filter { $0.versionId != "v5" })

        // The positive: a row whose retention has run out is deletable.
        let expired = Self.row("v0", in: rig)
        #expect(rig.model.rowState(of: expired) != .locked(until: Self.at(-600), mode: .governance))
        #expect(rig.model.isEnabled(.deleteVersion, on: expired))

        // A retention in force, a legal hold, an unreadable lock, an unknown one.
        let locked = Self.row("v2", in: rig)
        #expect(!rig.model.isEnabled(.deleteVersion, on: locked))
        #expect(rig.model.refusal(of: .deleteVersion, on: locked) == .lockedOrHeld)
        let held = Self.row("v1", in: rig)
        #expect(rig.model.refusal(of: .deleteVersion, on: held) == .lockedOrHeld)
        let unreadable = Self.row("v4", in: rig)
        #expect(rig.model.rowState(of: unreadable) == .lockUnreadable)
        #expect(rig.model.refusal(of: .deleteVersion, on: unreadable) == .lockNotConfirmed)
        let unknown = Self.row("v5", in: rig)
        #expect(rig.model.rowState(of: unknown) == .lockUnknown)
        #expect(!rig.model.isEnabled(.deleteVersion, on: unknown))
        #expect(rig.model.refusal(of: .deleteVersion, on: unknown) == .lockNotConfirmed)

        // Nothing is asked and nothing is sent for any refused row.
        for refused in [locked, held, unreadable, unknown] {
            let outcome = await rig.model.action(.deleteVersion, on: refused)
            if case .declined = outcome {} else { Issue.record("not declined: \(outcome)") }
        }
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.calls.confirmations.isEmpty)
    }

    /// A locked NEWEST row reads `.locked` (not `.current`), and the delete is
    /// refused on the lock; an unlocked newest row is deletable.
    @Test func aLockedCurrentRowCannotBeDeletedAndAnUnlockedOneCan() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = [
            "v3": ObjectRetention(mode: .compliance, retainUntil: Self.at(600))
        ]
        let locked = await Self.rig(Self.history, lock: fixture)
        #expect(locked.model.refusal(of: .deleteVersion, on: Self.row("v3", in: locked)) == .lockedOrHeld)

        let open = await Self.rig(Self.history, lock: .init(hasLock: true))
        let current = Self.row("v3", in: open)
        #expect(open.model.rowState(of: current) == .current)
        #expect(open.model.isEnabled(.deleteVersion, on: current))
    }

    /// The delete here is `deleteVersion`, which Core refuses for a marker
    /// (it would undelete the key). The refusal is made before anything is
    /// sent.
    @Test func aDeleteMarkerIsNotDeletedAsAVersion() async {
        let rig = await Self.rig(Self.history)
        #expect(rig.model.isEnabled(.deleteVersion, on: Self.row("v2", in: rig)))
        let marker = Self.row("m1", in: rig)
        #expect(rig.model.refusal(of: .deleteVersion, on: marker) == .aMarkerIsNotDeletedHere)
        let outcome = await rig.model.action(.deleteVersion, on: marker)
        #expect(outcome == .declined(.aMarkerIsNotDeletedHere))
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.calls.confirmations.isEmpty)
    }

    // MARK: - Say it before it runs

    @Test func restoreStatesThatItWritesANewVersionBeforeItRuns() async {
        let rig = await Self.rig(Self.history)
        let v2 = Self.row("v2", in: rig)
        let outcome = await rig.model.action(.restore, on: v2)

        // One question, asked while the store had been sent nothing.
        #expect(rig.calls.confirmations.count == 1)
        #expect(rig.calls.writesWhenAsked == [0])
        guard let request = rig.calls.confirmations.first else {
            Issue.record("no question was asked")
            return
        }
        #expect(request.action == .restore)
        #expect(request.message == ObjectVersionsLines.restoreMessage)
        #expect(request.title == ObjectVersionsLines.restoreTitle)
        #expect(!request.isDestructive)
        // It names the file and the version's date, and says "a new version".
        #expect(request.messageText.contains("a.txt"))
        #expect(request.messageText.contains(ObjectVersionsFormat.date(v2.modifiedAt)))
        let sayingNewVersion = ObjectVersionsLines.restoreMessage.english.contains("new version")
        #expect(sayingNewVersion)

        // The positive: after the yes, the store was asked exactly once, for
        // this version, and the outcome is the confirmed one.
        #expect(
            rig.provider.writes == [
                .init(kind: .restore, key: "a.txt", bucket: "b", versionId: "v2")
            ])
        #expect(outcome == .restored)
        #expect(rig.model.lastOutcome == .restored)
        // The history was read again, so the new version is on the sheet.
        #expect(rig.provider.listings.count == 2)
        #expect(!rig.model.writeInProgress)
    }

    @Test func deletingAVersionAsksForConfirmationFirst() async {
        let rig = await Self.rig(Self.history)
        let v2 = Self.row("v2", in: rig)
        let outcome = await rig.model.action(.deleteVersion, on: v2)

        #expect(rig.calls.confirmations.count == 1)
        #expect(rig.calls.writesWhenAsked == [0])
        guard let request = rig.calls.confirmations.first else {
            Issue.record("no question was asked")
            return
        }
        #expect(request.action == .deleteVersion)
        #expect(request.message == ObjectVersionsLines.deleteMessage)
        #expect(request.title == ObjectVersionsLines.deleteTitle)
        #expect(request.isDestructive)
        // It names the file and the version id it is about to remove for good.
        #expect(request.messageText.contains("a.txt"))
        #expect(request.messageText.contains("v2"))
        // An ordinary confirmation: it asks one question, and carries no
        // acknowledgement to type or tick.
        #expect(request.confirm == ObjectVersionsLines.deleteButton)

        #expect(
            rig.provider.writes == [
                .init(kind: .deleteVersion, key: "a.txt", bucket: "b", versionId: "v2")
            ])
        #expect(outcome == .deleted)
        #expect(rig.provider.listings.count == 2)
    }

    /// A "no" writes nothing, and so does a window that never set the
    /// question: the default fails closed. Each beside the "yes" above.
    @Test func aNoWritesNothingAndSoDoesAWindowThatNeverAsked() async {
        for action in [VersionRowAction.restore, .deleteVersion] {
            let declined = await Self.rig(Self.history, answer: false)
            let outcome = await declined.model.action(action, on: Self.row("v2", in: declined))
            #expect(outcome == .cancelled, "\(action)")
            #expect(declined.calls.confirmations.count == 1, "\(action)")
            #expect(declined.provider.writes.isEmpty, "\(action)")
            #expect(!declined.model.writeInProgress)
            // No history re-read for a "no".
            #expect(declined.provider.listings.count == 1)

            let unwired = await Self.rig(Self.history)
            unwired.model.confirm = { _ in false }
            _ = await unwired.model.action(action, on: Self.row("v2", in: unwired))
            #expect(unwired.provider.writes.isEmpty, "\(action)")
        }
    }

    /// The model's own default for `confirm` (never set by a window) asks
    /// nothing and sends nothing.
    @Test func aModelNobodyGaveAQuestionToNeverWrites() async {
        let settings = FakeBucketSettings(versioning: .enabled, lock: .init(hasLock: false))
        let provider = FakeVersionProvider(versions: Self.history)
        provider.setWriteAnswer(.accepted)
        let model = ObjectVersionsModel(
            target: Self.target, provider: provider, recorder: nil,
            locks: .init(settings: settings, cache: ObjectLockStateCache(settings: settings)),
            versioning: BucketVersioningCache(settings: settings), now: { Self.epoch })
        await model.load()
        let v2 = model.versions.first { $0.versionId == "v2" }!
        #expect(model.isEnabled(.restore, on: v2))
        let outcome = await model.action(.restore, on: v2)
        #expect(outcome == .cancelled)
        #expect(provider.writes.isEmpty)
    }

    /// The history was re-read while the question stood (the person sat on it),
    /// so the lock the answer was based on is unknown again: the delete is
    /// refused after the "yes" rather than sent on stale ground.
    @Test func aDeleteIsCheckedAgainAfterTheAnswer() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = [
            "v1": ObjectRetention(mode: .governance, retainUntil: Self.at(600))
        ]
        let rig = await Self.rig(Self.history, lock: fixture)
        let v2 = Self.row("v2", in: rig)
        #expect(rig.model.isEnabled(.deleteVersion, on: v2))
        rig.model.confirm = { [model = rig.model] _ in
            await model.load()
            return true
        }
        let outcome = await rig.model.action(.deleteVersion, on: v2)
        #expect(outcome == .declined(.lockNotConfirmed))
        #expect(rig.provider.writes.isEmpty)
    }

    // MARK: - A second write is not started

    @Test func aSecondWriteIsRefusedWhileOneIsWaitingForItsAnswer() async {
        let rig = await Self.rig(Self.history)
        let v2 = Self.row("v2", in: rig)
        let v1 = Self.row("v1", in: rig)
        var duringTheQuestion: [VersionActionRefusal?] = []
        var secondOutcome: VersionActionOutcome?
        rig.model.confirm = { [model = rig.model] _ in
            duringTheQuestion.append(model.refusal(of: .restore, on: v1))
            duringTheQuestion.append(model.refusal(of: .deleteVersion, on: v1))
            secondOutcome = await model.action(.restore, on: v1)
            return true
        }
        _ = await rig.model.action(.restore, on: v2)
        #expect(duringTheQuestion == [.anotherWriteIsRunning, .anotherWriteIsRunning])
        #expect(secondOutcome == .declined(.anotherWriteIsRunning))
        // One write, the first; and after it the menu is live again.
        #expect(rig.provider.writes.map(\.versionId) == ["v2"])
        #expect(rig.model.isEnabled(.restore, on: v1))
    }

    // MARK: - A version id of `null`

    /// `null` is a real, displayable id. Every action takes it as a target and
    /// hands it on exactly as listed.
    @Test func aVersionIdOfNullIsATargetForEveryAction() async {
        let history = [
            Self.version("v9", latest: true, at: 300, etag: "C"),
            Self.version("null", at: 100, etag: "A"),
        ]
        let rig = await Self.rig(history)
        let null = Self.row("null", in: rig)
        #expect(null.versionId == "null")
        for action in VersionRowAction.allCases {
            #expect(rig.model.isEnabled(action, on: null), "\(action)")
        }
        _ = await rig.model.action(.open, on: null)
        _ = await rig.model.action(.compareWithCurrent, on: null)
        _ = await rig.model.action(.download, on: null)
        #expect(rig.calls.opened == ["null"])
        #expect(rig.calls.compared == ["null"])
        #expect(rig.calls.downloaded == ["null"])

        _ = await rig.model.action(.restore, on: null)
        _ = await rig.model.action(.deleteVersion, on: null)
        #expect(
            rig.provider.writes.map(\.versionId) == ["null", "null"],
            "the id goes to the store as the four characters it is")
        #expect(rig.provider.writes.map(\.kind) == [.restore, .deleteVersion])
    }

    // MARK: - What each action hands to the window

    @Test func openCompareAndDownloadAreHandedToTheWindowWithTheRow() async {
        let rig = await Self.rig(Self.history)
        let v2 = Self.row("v2", in: rig)
        #expect(await rig.model.action(.open, on: v2) == .handedOff(.open))
        #expect(await rig.model.action(.compareWithCurrent, on: v2) == .handedOff(.compareWithCurrent))
        #expect(await rig.model.action(.download, on: v2) == .handedOff(.download))
        #expect(rig.calls.opened == ["v2"])
        #expect(rig.calls.compared == ["v2"])
        #expect(rig.calls.downloaded == ["v2"])
        // None of the three writes anything or asks anything.
        #expect(rig.provider.writes.isEmpty)
        #expect(rig.calls.confirmations.isEmpty)
    }

    /// A row whose window gave no way to do it is not offered: an enabled row
    /// that does nothing is worse than a disabled one.
    @Test func anActionNobodyIsWiredToDoIsNotOffered() async {
        let unwired = await Self.rig(Self.history, wired: false)
        let v2 = Self.row("v2", in: unwired)
        for action in [VersionRowAction.open, .compareWithCurrent, .download] {
            #expect(unwired.model.refusal(of: action, on: v2) == .notAvailableHere, "\(action)")
        }
        // The positive: the same history, wired, offers all three; and the
        // writes, which need no window, are offered either way.
        let wired = await Self.rig(Self.history)
        for action in [VersionRowAction.open, .compareWithCurrent, .download] {
            #expect(wired.model.isEnabled(action, on: Self.row("v2", in: wired)), "\(action)")
        }
        #expect(unwired.model.isEnabled(.restore, on: v2))
    }

    // MARK: - An unconfirmed write is not a failed one

    /// Core confirms by reading the history back, and a result it cannot
    /// confirm comes back as a `.protocolError`. The store took the request;
    /// whether the history shows it is the open question, so the sentence says
    /// the outcome could not be confirmed and never that it failed. The same
    /// is true of a connection lost before the answer.
    @Test func anUnconfirmedWriteIsNotWordedAsAFailure() async {
        let unconfirmed: [any Error] = [
            RemoteFSError.protocolError(reason: "S3 restore could not be confirmed"),
            RemoteFSError.connectionFailed(reason: "lost"),
        ]
        for error in unconfirmed {
            for action in [VersionRowAction.restore, .deleteVersion] {
                let rig = await Self.rig(Self.history, writes: .throwing(error))
                let outcome = await rig.model.action(action, on: Self.row("v2", in: rig))
                #expect(outcome == .notConfirmed(action), "\(action)")
                let english = outcome.line?.english ?? ""
                #expect(english.contains("could not be confirmed"), "\(action)")
                let saysFailed = english.lowercased().contains("fail")
                #expect(!saysFailed, "\(action)")
                // The store was asked, and the history was read again so the
                // person can see what it holds.
                #expect(rig.provider.writes.count == 1)
                #expect(rig.provider.listings.count == 2)
                #expect(rig.model.lastOutcome == outcome)
            }
        }
    }

    /// The positive beside it: a refusal that is certain says so, and says
    /// that nothing was changed.
    @Test func aRefusalTheStoreMakesForCertainSaysNothingWasChanged() async {
        let refusals: [(any Error, CatalogueLine)] = [
            (RemoteFSError.finding(.objectUnderRetention(path: "/b/a.txt")), ObjectVersionsLines.outcomeLocked),
            (RemoteFSError.finding(.objectUnderLegalHold(path: "/b/a.txt")), ObjectVersionsLines.outcomeLocked),
            (RemoteFSError.notFound(path: "/b/a.txt"), ObjectVersionsLines.outcomeGone),
            (RemoteFSError.permissionDenied(path: "/b/a.txt"), ObjectVersionsLines.outcomeDenied),
            (RemoteFSError.finding(.operationNotSupported), ObjectVersionsLines.outcomeUnsupported),
        ]
        for (error, line) in refusals {
            let rig = await Self.rig(Self.history, writes: .throwing(error))
            let outcome = await rig.model.action(.deleteVersion, on: Self.row("v2", in: rig))
            #expect(outcome == .refused(.deleteVersion, why: line))
            #expect(line.english.contains("Nothing was changed") || line.english.contains("locked"))
        }
    }

    /// A refused write that is stale (the version is gone) re-reads the
    /// history; one that is final (locked, denied) does not need to.
    @Test func aStaleRefusalReadsTheHistoryAgain() async {
        let gone = await Self.rig(
            Self.history, writes: .throwing(RemoteFSError.notFound(path: "/b/a.txt")))
        _ = await gone.model.action(.deleteVersion, on: Self.row("v2", in: gone))
        #expect(gone.provider.listings.count == 2)

        let locked = await Self.rig(
            Self.history,
            writes: .throwing(RemoteFSError.finding(.objectUnderRetention(path: "/b/a.txt"))))
        _ = await locked.model.action(.deleteVersion, on: Self.row("v2", in: locked))
        #expect(locked.provider.listings.count == 1)
    }

    @Test func theStatusLineOfAnActionClearsWhenTheNextOneStarts() async {
        let rig = await Self.rig(Self.history)
        _ = await rig.model.action(.restore, on: Self.row("v2", in: rig))
        #expect(rig.model.lastOutcome == .restored)
        rig.model.confirm = { _ in false }
        _ = await rig.model.action(.deleteVersion, on: Self.row("v1", in: rig))
        #expect(rig.model.lastOutcome == .cancelled)
    }

    // MARK: - The question on screen

    private static var sampleQuestion: VersionConfirmation {
        VersionConfirmation(
            action: .deleteVersion, title: ObjectVersionsLines.deleteTitle,
            message: ObjectVersionsLines.deleteMessage, messageText: "sample",
            confirm: ObjectVersionsLines.deleteButton, isDestructive: true)
    }

    /// The bridge answers once, with what the person chose, and clears the
    /// question. The wait is on the signal the bridge raises when it has put
    /// the question up, not on a poll.
    @Test func theQuestionIsAnsweredOnceAndThenGone() async {
        let bridge = VersionConfirmationBridge()
        let posted = AsyncSignal()
        bridge.asked = { posted.signal() }
        let asking = Task { @MainActor in await bridge.ask(Self.sampleQuestion) }
        _ = await posted.wait()
        #expect(bridge.request == Self.sampleQuestion)
        bridge.answer(true)
        #expect(await asking.value == true)
        #expect(bridge.request == nil)
        // A second answer to a question that is gone changes nothing.
        bridge.answer(false)
        #expect(bridge.request == nil)
    }

    /// Every way the question can go away is a "no": a cancelled task, and a
    /// second question arriving over the first. The first test is the "yes"
    /// beside them.
    @Test func aQuestionThatGoesAwayIsANo() async {
        let bridge = VersionConfirmationBridge()
        let first = AsyncSignal()
        bridge.asked = { first.signal() }
        let cancelled = Task { @MainActor in await bridge.ask(Self.sampleQuestion) }
        _ = await first.wait()
        cancelled.cancel()
        #expect(await cancelled.value == false)
        #expect(bridge.request == nil)

        let second = AsyncSignal()
        bridge.asked = { second.signal() }
        let replaced = Task { @MainActor in await bridge.ask(Self.sampleQuestion) }
        _ = await second.wait()
        let third = AsyncSignal()
        bridge.asked = { third.signal() }
        let replacing = Task { @MainActor in await bridge.ask(Self.sampleQuestion) }
        // The second question is answered "no" by the third arriving.
        #expect(await replaced.value == false)
        _ = await third.wait()
        bridge.answer(true)
        #expect(await replacing.value == true)
    }

    // MARK: - The trail

    /// A recorder over a store of its own, and the way to read what it
    /// recorded.
    private struct Trail {
        let recorder: AuditRecorder
        let directory: URL
        let store: AuditLogStore
        let sessionID = UUID()

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectVersionActionsTests-\(UUID().uuidString)", isDirectory: true)
            store = AuditLogStore(directory: directory)
            recorder = AuditRecorder(sessionID: sessionID, store: store)
        }

        var events: [AuditEvent] { store.events(for: sessionID) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// What the store would say about a refusal or a loss. A named constant,
    /// and the check that it did not reach the trail computes its `Bool`
    /// first: `#expect` prints the source text of the expression it checks.
    private static let storeWords = "store-words-canary-5c1e"

    @Test func aConfirmedRestoreAndDeleteEachLeaveOneLineOfTheirOwnKind() async {
        let trail = Trail()
        defer { trail.remove() }
        let rig = await Self.rig(Self.history, recorder: trail.recorder)
        _ = await rig.model.action(.restore, on: Self.row("v2", in: rig))
        _ = await rig.model.action(.deleteVersion, on: Self.row("v1", in: rig))
        let events = trail.events
        #expect(events.map(\.kind) == [.versionRestored, .versionDeleted])
        #expect(events.allSatisfy { !$0.isError && $0.errorMessage == nil })
        #expect(events[0].detail == "restored version v2 of b/a.txt as its current version")
        #expect(events[1].detail == "permanently deleted version v1 of b/a.txt")
    }

    /// A write that could not be confirmed is recorded as an attempt that
    /// could not be confirmed (the request went out; the history does not
    /// say), a refusal as a refusal, and neither carries the store's words.
    @Test func anUnconfirmedAndARefusedWriteAreRecordedAsSuchWithoutTheStoresWords() async {
        let errors: [(any Error, Bool)] = [
            (RemoteFSError.protocolError(reason: Self.storeWords), true),
            (RemoteFSError.finding(.objectUnderRetention(path: "/b/a.txt")), false),
        ]
        for (error, unconfirmed) in errors {
            let trail = Trail()
            defer { trail.remove() }
            let rig = await Self.rig(Self.history, writes: .throwing(error), recorder: trail.recorder)
            _ = await rig.model.action(.deleteVersion, on: Self.row("v2", in: rig))
            let events = trail.events
            #expect(events.count == 1)
            #expect(events.first?.kind == .versionDeleted)
            #expect(events.first?.isError == true)
            // The line says what was attempted, as a success would have.
            let attempted = events.first?.detail.hasPrefix("permanently deleted version v2") ?? false
            #expect(attempted)
            let message = events.first?.errorMessage ?? ""
            #expect(!message.isEmpty)
            let saysUnconfirmed = message.contains("could not be confirmed")
            #expect(saysUnconfirmed == unconfirmed)
            let saysFailed = message.lowercased().contains("fail")
            #expect(!saysFailed)
            let canary = Self.storeWords
            let leaked = events.contains {
                $0.detail.contains(canary) || ($0.errorMessage ?? "").contains(canary)
            }
            #expect(!leaked)
        }
    }

    /// Nothing sent, nothing recorded: a "no", a refused row and a bucket the
    /// restore is not offered on leave the trail empty. The positive is the
    /// test above.
    @Test func anActionThatSentNothingRecordsNothing() async {
        let trail = Trail()
        defer { trail.remove() }
        let said = await Self.rig(Self.history, answer: false, recorder: trail.recorder)
        _ = await said.model.action(.restore, on: Self.row("v2", in: said))
        _ = await said.model.action(.deleteVersion, on: Self.row("v2", in: said))
        let suspended = await Self.rig(
            Self.history, versioning: .suspended, recorder: trail.recorder)
        _ = await suspended.model.action(.restore, on: Self.row("v2", in: suspended))
        _ = await suspended.model.action(.deleteVersion, on: Self.row("m1", in: suspended))
        #expect(trail.events.isEmpty)
    }

    /// A tab without a recorder (its stored session was deleted) costs the
    /// write nothing.
    @Test func aMissingRecorderCostsTheWriteNothing() async {
        let rig = await Self.rig(Self.history, recorder: nil)
        let outcome = await rig.model.action(.restore, on: Self.row("v2", in: rig))
        #expect(outcome == .restored)
        #expect(rig.provider.writes.count == 1)
    }

    // MARK: - The catalogue

    @Test(arguments: ["de", "fr", "pl"])
    func theActionSentencesAreTranslatedAndKeepTheirSpecifiers(locale: String) {
        let specifier = #/%(\d+\$)?(lld|@|d)/#
        let lines: [CatalogueLine] = [
            ObjectVersionsLines.actionOpen,
            ObjectVersionsLines.actionCompare,
            ObjectVersionsLines.actionDownload,
            ObjectVersionsLines.actionRestore,
            ObjectVersionsLines.actionDelete,
            ObjectVersionsLines.refusalNoContent,
            ObjectVersionsLines.refusalIsCurrent,
            ObjectVersionsLines.refusalCurrentIsMarker,
            ObjectVersionsLines.refusalVersioningNotEnabled,
            ObjectVersionsLines.refusalLocked,
            ObjectVersionsLines.refusalLockNotConfirmed,
            ObjectVersionsLines.refusalMarker,
            ObjectVersionsLines.refusalBusy,
            ObjectVersionsLines.refusalUnavailable,
            ObjectVersionsLines.restoreTitle,
            ObjectVersionsLines.restoreMessage,
            ObjectVersionsLines.restoreButton,
            ObjectVersionsLines.deleteTitle,
            ObjectVersionsLines.deleteMessage,
            ObjectVersionsLines.deleteButton,
            ObjectVersionsLines.outcomeRestored,
            ObjectVersionsLines.outcomeDeleted,
            ObjectVersionsLines.outcomeRestoreNotConfirmed,
            ObjectVersionsLines.outcomeDeleteNotConfirmed,
            ObjectVersionsLines.outcomeLocked,
            ObjectVersionsLines.outcomeGone,
            ObjectVersionsLines.outcomeDenied,
            ObjectVersionsLines.outcomeUnsupported,
        ]
        #expect(lines.count == 28)
        for line in lines {
            #expect(ObjectVersionsLines.all.contains(line), "\(line.key)")
            let resolved = L10n.$localeOverride.withValue(locale) {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(resolved != "ZZ-UNRESOLVED-ZZ", "\(line.key) in \(locale)")
            #expect(resolved != line.key, "\(line.key) in \(locale)")
            #expect(resolved != line.english, "\(line.key) in \(locale)")
            let expected = line.english.matches(of: specifier).map { String($0.output.0) }.sorted()
            let found = resolved.matches(of: specifier).map { String($0.output.0) }.sorted()
            #expect(found == expected, "\(line.key) in \(locale)")
        }
    }
}
