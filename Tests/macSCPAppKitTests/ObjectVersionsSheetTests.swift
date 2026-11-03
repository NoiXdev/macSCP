import AppKit
import Foundation
import MacSCPTestSupport
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The version sheet's model: what a row is, in what order, and what a failed
/// or inapplicable lock read does to the listing.
///
/// Every store is a fake that answers at once; no case waits on a clock.
/// Counts of what the store was asked are read off the fakes' own records and
/// never off the model's internals, so a model that answered correctly while
/// asking the wrong thing is red.
@Suite("Object versions sheet")
@MainActor
struct ObjectVersionsSheetTests {
    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    private static func version(
        _ id: String, key: String = "a.txt", latest: Bool = false, marker: Bool = false,
        size: UInt64? = 10, at seconds: TimeInterval? = 0, etag: String? = nil
    ) -> ObjectVersion {
        ObjectVersion(
            versionId: id, key: key, isLatest: latest, isDeleteMarker: marker,
            size: marker ? nil : size, modifiedAt: seconds.map(at),
            entityTag: marker ? nil : etag)
    }

    /// The predicate of an empty search: matches every row.
    private static var everything: FileSearch.FileSearchPredicate {
        sheetSearchPredicate(text: "", isRegex: false).0
    }

    private static let target = ObjectVersionsTarget(
        bucket: "b", key: "a.txt", displayName: "a.txt", displayPath: "/b/a.txt")

    /// A bucket without Object Lock, as the store answers it: `false`.
    private static func noLock() -> FakeBucketSettings {
        FakeBucketSettings(lock: .init(hasLock: false))
    }

    /// A model over `versions`, with the lock half backed by `settings` (none
    /// for a backend without the capability). **`now` is fixed**, so a
    /// retention is in force or has run out by construction and never by the
    /// clock.
    private static func model(
        _ versions: [ObjectVersion], settings: FakeBucketSettings?,
        provider: FakeVersionProvider? = nil
    ) -> (model: ObjectVersionsModel, provider: FakeVersionProvider) {
        let provider = provider ?? FakeVersionProvider(versions: versions)
        let locks = settings.map {
            ObjectVersionsModel.LockBacking(settings: $0, cache: ObjectLockStateCache(settings: $0))
        }
        let model = ObjectVersionsModel(
            target: target, provider: provider, recorder: nil, locks: locks, versioning: nil,
            now: { epoch })
        return (model, provider)
    }

    /// A history of three content versions, newest first as a store sends it.
    private static var threeVersions: [ObjectVersion] {
        [
            version("v3", latest: true, at: 300, etag: "C"),
            version("v2", at: 200, etag: "B"),
            version("v1", at: 100, etag: "A"),
        ]
    }

    // MARK: - The five rows of the plan

    @Test func theLatestVersionIsTheCurrentRow() async {
        // Handed over shuffled: the order is the model's to define, not the
        // store's to supply.
        let shuffled = [Self.threeVersions[2], Self.threeVersions[0], Self.threeVersions[1]]
        let (model, provider) = Self.model(shuffled, settings: Self.noLock())
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.versions.map(\.versionId) == ["v3", "v2", "v1"])
        #expect(model.rowState(of: model.versions[0]) == .current)
        #expect(model.rowState(of: model.versions[1]) == .plain)
        #expect(model.rowState(of: model.versions[2]) == .plain)
        // The positive beside the negatives: the store was asked for this
        // key in this bucket and for nothing else.
        #expect(provider.listings == [.init(key: "a.txt", bucket: "b")])
    }

    @Test func aDeleteMarkerRowIsNotAContentRow() async {
        let history = [
            Self.version("m1", latest: true, marker: true, at: 300),
            Self.version("v1", at: 100, etag: "A"),
        ]
        let settings = FakeBucketSettings(lock: .init(hasLock: true))
        let (model, _) = Self.model(history, settings: settings)
        await model.load()
        let marker = model.versions[0]
        #expect(marker.isDeleteMarker)
        // A marker is a marker even though the store flags it as the latest
        // entry, and it is not "locked" or "unknown" either.
        #expect(model.rowState(of: marker) == .deleteMarker)
        #expect(model.stateText(of: marker) == ObjectVersionsLines.deleteMarker.text)

        await model.readLockStates(of: model.versions)
        // No lock read was sent for it, and one was for the version beneath.
        #expect(settings.versionReads.contains { $0.versionId == "v1" })
        #expect(!settings.versionReads.contains { $0.versionId == "m1" })

        // The filters tell the two apart.
        let all = Self.everything
        #expect(model.rows(filter: .deleteMarkers, matching: all).map(\.id) == ["m1"])
        #expect(model.rows(filter: .versions, matching: all).map(\.id) == ["v1"])
        #expect(model.rows(filter: .all, matching: all).map(\.id) == ["m1", "v1"])
    }

    /// Spec section 4.5 measured the ETag staying identical across a REPLACE
    /// copy, which is the one signal that a version is a metadata change.
    @Test func aVersionWithTheSameETagAsItsPredecessorIsMetadataOnly() async {
        let history = [
            Self.version("v4", latest: true, at: 400, etag: "C"),
            Self.version("v3", at: 300, etag: "B"),
            Self.version("v2", at: 200, etag: "B"),
            Self.version("v1", at: 100, etag: "A"),
        ]
        let (model, _) = Self.model(history, settings: Self.noLock())
        await model.load()
        let byId = Dictionary(uniqueKeysWithValues: model.versions.map { ($0.versionId, $0) })
        // v3 repeats v2's tag: marked. v2 repeats nothing (v1 differs), v1 has
        // no predecessor, v4 differs from v3.
        #expect(model.rowState(of: byId["v3"]!) == .metadataOnly)
        #expect(model.rowState(of: byId["v2"]!) == .plain)
        #expect(model.rowState(of: byId["v1"]!) == .plain)
        #expect(model.isMetadataOnly(byId["v3"]!))
        #expect(!model.isMetadataOnly(byId["v2"]!))
        #expect(!model.isMetadataOnly(byId["v1"]!))
        #expect(!model.isMetadataOnly(byId["v4"]!))
    }

    @Test func theCurrentRowThatRepeatsItsPredecessorIsStillCurrentAndSaysSo() async {
        let history = [
            Self.version("v2", latest: true, at: 200, etag: "A"),
            Self.version("v1", at: 100, etag: "A"),
        ]
        let (model, _) = Self.model(history, settings: Self.noLock())
        await model.load()
        let latest = model.versions[0]
        // Restore and Compare key off "current"; the note rides in the text.
        #expect(model.rowState(of: latest) == .current)
        #expect(model.isMetadataOnly(latest))
        let text = model.stateText(of: latest)
        #expect(text.contains(ObjectVersionsLines.current.text))
        #expect(text.contains(ObjectVersionsLines.metadataOnly.text))
    }

    @Test func aMarkerBetweenTwoEqualTagsBreaksThePair() async {
        let history = [
            Self.version("v2", latest: true, at: 300, etag: "A"),
            Self.version("m1", marker: true, at: 200),
            Self.version("v1", at: 100, etag: "A"),
        ]
        let (model, _) = Self.model(history, settings: Self.noLock())
        await model.load()
        #expect(!model.isMetadataOnly(model.versions[0]))
        // And two entries with NO tag are not "the same tag".
        let untagged = [
            Self.version("u2", latest: true, at: 200, etag: nil),
            Self.version("u1", at: 100, etag: nil),
        ]
        let (second, _) = Self.model(untagged, settings: Self.noLock())
        await second.load()
        #expect(!second.isMetadataOnly(second.versions[0]))
    }

    /// The first half's D1 lesson. A bucket without Object Lock: the rows
    /// show, the state is `.plain`/`.current`, and nothing reports failure.
    @Test func aListingThatSucceededIsNotEmptiedByALockReadThatCouldNotApply() async {
        // A store that does not implement the call at all (the fake with no
        // lock fixture answers exactly that), a bucket that reports none, and
        // a backend without the capability.
        let cases: [(String, FakeBucketSettings?)] = [
            ("a store without the Object Lock call", FakeBucketSettings()),
            ("a bucket without Object Lock", Self.noLock()),
            ("a backend without bucket settings", nil),
        ]
        for (name, settings) in cases {
            let (model, _) = Self.model(Self.threeVersions, settings: settings)
            await model.load()
            #expect(model.phase == .loaded, "\(name)")
            #expect(model.versions.count == 3, "\(name)")
            #expect(model.bucketLock == .notApplicable, "\(name)")
            #expect(model.rowState(of: model.versions[0]) == .current, "\(name)")
            #expect(model.rowState(of: model.versions[1]) == .plain, "\(name)")
            // Nothing was read per version for a bucket with nothing to read.
            await model.readLockStates(of: model.versions)
            let perVersionReads = settings?.versionReads.count ?? 0
            #expect(perVersionReads == 0, "\(name)")
        }
    }

    @Test func aLockQuestionThatCouldNotBeAnsweredLeavesTheRowsAndSaysSoWithoutSayingFailed() async {
        let settings = FakeBucketSettings(
            lock: .init(hasLockError: RemoteFSError.protocolError(reason: "planted")))
        let (model, _) = Self.model(Self.threeVersions, settings: settings)
        await model.load()
        // The listing is not emptied and not reported as failed.
        #expect(model.phase == .loaded)
        #expect(model.versions.count == 3)
        #expect(model.bucketLock == .undetermined)
        for version in model.versions {
            #expect(model.rowState(of: version) == .lockUnreadable)
        }
        // The wording is "could not be confirmed", in every language, and the
        // word for failure is in none of them.
        let confirmWords = ["en": "confirmed", "de": "bestätigt", "fr": "confirmé", "pl": "potwierdzić"]
        let failWords = ["en": "fail", "de": "fehlgeschlagen", "fr": "échec", "pl": "niepowodzeni"]
        for (locale, word) in confirmWords {
            let text = L10n.$localeOverride.withValue(locale) {
                ObjectVersionsLines.lockUnreadable.text.lowercased()
            }
            #expect(text.contains(word), "\(locale)")
            #expect(!text.contains(failWords[locale] ?? "\u{0}"), "\(locale)")
        }
    }

    @Test func anEmptyHistorySaysSoRatherThanLookingLikeAFailure() async {
        let (model, provider) = Self.model([], settings: Self.noLock())
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.versions.isEmpty)
        // The sentence is "nothing found", and "no matches" is another fact:
        // the filter and the search emptied a history that has entries.
        #expect(model.emptyLine(visibleRows: 0) == ObjectVersionsLines.empty)
        #expect(model.emptyLine(visibleRows: 1) == nil)
        #expect(provider.listings.count == 1)

        let (full, _) = Self.model(Self.threeVersions, settings: Self.noLock())
        await full.load()
        #expect(full.emptyLine(visibleRows: 0) == ObjectVersionsLines.noMatches)
        #expect(ObjectVersionsLines.empty != ObjectVersionsLines.noMatches)
    }

    // MARK: - A failed listing

    @Test func aListingThatFailsSaysSoInAFixedSentenceAndNeverQuotesTheError() async {
        let secretBearing = "https://AKIAEXAMPLE:SECRETEXAMPLE@store.example"
        let provider = FakeVersionProvider(error: RemoteFSError.protocolError(reason: secretBearing))
        let (model, _) = Self.model([], settings: Self.noLock(), provider: provider)
        await model.load()
        guard case .failed(let sentence) = model.phase else {
            Issue.record("the phase is not .failed")
            return
        }
        #expect(sentence == ObjectVersionsLines.readFailed.text)
        let leaked = sentence.contains("SECRETEXAMPLE") || sentence.contains("store.example")
        #expect(!leaked)
        #expect(model.versions.isEmpty)

        let denied = FakeVersionProvider(error: RemoteFSError.permissionDenied(path: "/b/a.txt"))
        let (second, _) = Self.model([], settings: nil, provider: denied)
        await second.load()
        #expect(second.phase == .failed(ObjectVersionsLines.denied.text))
    }

    // MARK: - Lock states

    @Test func aBucketWithALockHasEachRowsLockReadAndUnreadRowsAreUnknownNotUnlocked() async {
        let future = Self.at(10_000)
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = ["v2": ObjectRetention(mode: .compliance, retainUntil: future)]
        fixture.legalHoldByVersion = ["v1": true]
        let settings = FakeBucketSettings(lock: fixture)
        let (model, _) = Self.model(Self.threeVersions, settings: settings)
        await model.load()
        #expect(model.bucketLock == .applies)
        // Before any per-version read: not yet known, which is neither locked
        // nor free.
        for version in model.versions {
            #expect(model.rowState(of: version) == .lockUnknown)
        }
        await model.readLockStates(of: model.versions)
        let byId = Dictionary(uniqueKeysWithValues: model.versions.map { ($0.versionId, $0) })
        #expect(model.rowState(of: byId["v3"]!) == .current)
        #expect(model.rowState(of: byId["v2"]!) == .locked(until: future, mode: .compliance))
        #expect(model.rowState(of: byId["v1"]!) == .legalHold)
        // A lock on the newest entry is what the row IS, and "Current" still
        // leads the text.
        let latestLocked = Self.version("v9", latest: true, at: 900, etag: "Z")
        var second = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        second.legalHoldByVersion = ["v9": true]
        let (other, _) = Self.model([latestLocked], settings: FakeBucketSettings(lock: second))
        await other.load()
        await other.readLockStates(of: other.versions)
        #expect(other.rowState(of: latestLocked) == .legalHold)
        #expect(other.stateText(of: latestLocked).hasPrefix(ObjectVersionsLines.current.text))
    }

    /// What the ROW TELLS THE USER, not what the enum is. A version under a
    /// retention and a legal hold stays undeletable past the retention's date,
    /// so a text that said only "Locked until <date>" would promise a date it
    /// will not be deletable on. `rowState` keeps the retention (a later task
    /// gates on it); the text says both.
    @Test func aRowUnderBothARetentionAndAHoldTellsTheUserBoth() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = ["v2": ObjectRetention(mode: .compliance, retainUntil: Self.at(600))]
        fixture.legalHoldByVersion = ["v2": true]
        let (model, _) = Self.model(Self.threeVersions, settings: FakeBucketSettings(lock: fixture))
        await model.load()
        await model.readLockStates(of: model.versions)
        let v2 = model.versions[1]
        #expect(v2.versionId == "v2")
        // The enum is unchanged.
        #expect(model.rowState(of: v2) == .locked(until: Self.at(600), mode: .compliance))
        let text = model.stateText(of: v2)
        let retention = String(
            format: ObjectVersionsLines.locked.text, ObjectLockLines.modeName(.compliance).text,
            ObjectLockDates.text(Self.at(600)))
        #expect(text.contains(retention))
        #expect(text.contains(ObjectVersionsLines.legalHold.text))
        // And in that order: the date first, the hold as a further part.
        #expect(text == "\(retention) · \(ObjectVersionsLines.legalHold.text)")
    }

    /// The positive control for the case above: a retention alone says only
    /// the retention, and a hold alone says only the hold.
    @Test func aRowUnderOnlyARetentionOrOnlyAHoldTellsOnlyThat() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = ["v2": ObjectRetention(mode: .governance, retainUntil: Self.at(600))]
        fixture.legalHoldByVersion = ["v1": true]
        let (model, _) = Self.model(Self.threeVersions, settings: FakeBucketSettings(lock: fixture))
        await model.load()
        await model.readLockStates(of: model.versions)
        let retentionOnly = model.stateText(of: model.versions[1])
        #expect(retentionOnly.contains(ObjectLockDates.text(Self.at(600))))
        #expect(!retentionOnly.contains(ObjectVersionsLines.legalHold.text))
        #expect(!retentionOnly.contains("·"))
        let holdOnly = model.stateText(of: model.versions[2])
        #expect(holdOnly == ObjectVersionsLines.legalHold.text)
    }

    @Test func aRetentionThatHasRunOutIsNotALockAndOneInForceWinsOverAHold() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = [
            "v2": ObjectRetention(mode: .governance, retainUntil: Self.at(-1)),
            "v1": ObjectRetention(mode: .governance, retainUntil: Self.at(60)),
        ]
        fixture.legalHoldByVersion = ["v1": true]
        let (model, _) = Self.model(Self.threeVersions, settings: FakeBucketSettings(lock: fixture))
        await model.load()
        await model.readLockStates(of: model.versions)
        let byId = Dictionary(uniqueKeysWithValues: model.versions.map { ($0.versionId, $0) })
        #expect(model.rowState(of: byId["v2"]!) == .plain)
        #expect(model.rowState(of: byId["v1"]!) == .locked(until: Self.at(60), mode: .governance))
    }

    @Test func aLockReadThatFailsMarksOnlyItsRowAndKeepsEveryRow() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.failingVersions = ["v2"]
        let (model, _) = Self.model(Self.threeVersions, settings: FakeBucketSettings(lock: fixture))
        await model.load()
        await model.readLockStates(of: model.versions)
        let byId = Dictionary(uniqueKeysWithValues: model.versions.map { ($0.versionId, $0) })
        #expect(model.phase == .loaded)
        #expect(model.versions.count == 3)
        #expect(model.rowState(of: byId["v2"]!) == .lockUnreadable)
        #expect(model.rowState(of: byId["v3"]!) == .current)
        #expect(model.rowState(of: byId["v1"]!) == .plain)
    }

    @Test func aReadThatIsCancelledRecordsNothingAndTheRowStaysUnknown() async {
        let settings = FakeBucketSettings(lock: .init(hasLock: true))
        let (model, _) = Self.model(Self.threeVersions, settings: settings)
        await model.load()
        let row = model.versions[1]
        let read = Task { @MainActor in await model.readLockState(of: row) }
        read.cancel()
        await read.value
        #expect(model.rowState(of: row) == .lockUnknown)
        #expect(settings.versionReads.isEmpty)
        // The positive: uncancelled, the same call records its answer.
        await model.readLockState(of: row)
        #expect(model.rowState(of: row) == .plain)
        #expect(!settings.versionReads.isEmpty)
    }

    // MARK: - The version id "null"

    /// S3 reports the id as the four characters `null` for an object written
    /// before versioning was on and for a write while it is suspended. It is
    /// a real id: a row, sent to the store as itself, matched by search.
    @Test func aVersionIdThatIsTheWordNullIsARealRow() async throws {
        let history = [
            Self.version("v2", latest: true, at: 200, etag: "B"),
            Self.version("null", at: 100, etag: "A"),
        ]
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.legalHoldByVersion = ["null": true]
        let settings = FakeBucketSettings(lock: fixture)
        let (model, _) = Self.model(history, settings: settings)
        await model.load()
        await model.readLockStates(of: model.versions)

        let rows = model.rows(filter: .all, matching: Self.everything)
        #expect(rows.map(\.id) == ["v2", "null"])
        // A `#require`: with the row missing, indexing it would trap the runner.
        let nullRow = try #require(rows.first { $0.id == "null" }, "no row for the null version")
        #expect(nullRow.version.versionId == "null")
        #expect(nullRow.state == .legalHold)
        // The id reached the store as the id, and not as "no version".
        let reads = settings.versionReads.filter { $0.versionId == "null" }.map(\.kind)
        #expect(reads.contains(.retention) && reads.contains(.legalHold))
        // And it is searchable like any other.
        let (predicate, _) = sheetSearchPredicate(text: "null", isRegex: false)
        #expect(model.rows(filter: .all, matching: predicate).map(\.id) == ["null"])
        // As a table identity it is unique alongside the other ids.
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    // MARK: - Bounded reads

    @Test func lockReadsAreBoundedToTheLimitNoMatterHowLongTheHistory() async {
        let many = (0..<14).map {
            Self.version("v\($0)", latest: $0 == 13, at: TimeInterval($0), etag: "E\($0)")
        }
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.yieldsPerVersionRead = 40
        let settings = FakeBucketSettings(lock: fixture)
        let (model, _) = Self.model(many, settings: settings)
        await model.load()
        await model.readLockStates(of: model.versions)
        #expect(model.readings.count == 14, "every row was read")
        #expect(settings.versionReads.count == 28, "retention and hold, once per row")
        // A floor of 2, not the limit: how many of the four slots the scheduler
        // fills at once is its business, so the exact peak would be flaky here.
        // The exact peak is pinned deterministically by the next case; this one
        // keeps the ceiling and proves at least some parallelism (a model that
        // read one row at a time peaks at 1).
        #expect(settings.maxVersionReadsInFlight >= 2)
        #expect(settings.maxVersionReadsInFlight <= ObjectVersionsModel.lockReadLimit)
    }

    /// A read cancelled while the store is being asked records nothing either:
    /// the fake does not honour cancellation, so the read comes back with an
    /// answer after the cancel, and it must be dropped, not recorded.
    @Test(.timeLimit(.minutes(5)))
    func aReadCancelledWhileTheStoreIsBeingAskedRecordsNothing() async {
        let hold = FakeBucketSettings.VersionReadHold(
            threshold: 1, reached: AsyncSignal(), release: AsyncSignal())
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.versionReadHold = hold
        fixture.legalHoldByVersion = ["v2": true]
        let settings = FakeBucketSettings(lock: fixture)
        let (model, _) = Self.model(Self.threeVersions, settings: settings)
        await model.load()
        let row = model.versions[1]
        let read = Task { @MainActor in await model.readLockState(of: row) }
        guard await hold.reached.arrives("the held lock read reaching the store") else {
            read.cancel()
            hold.release.signal()
            await read.value
            return
        }
        read.cancel()
        hold.release.signal()
        await read.value
        // The store answered (the positive: there was a read to drop) and the
        // row is as unknown as before.
        #expect(!settings.versionReads.isEmpty)
        #expect(model.readings[row.versionId] == nil)
        #expect(model.rowState(of: row) == .lockUnknown)
    }

    /// The peak as a fact. The fake holds every version read at the store until
    /// the test lets go, and says when `lockReadLimit` are in flight at once: a
    /// model that reads fewer never raises it (the wait for it ends at the hang
    /// bound with a named failure; it used to wait on the case's own
    /// `.timeLimit`, which does not end a park), one that reads more has more
    /// than the limit in flight when the test checks before releasing.
    @Test(.timeLimit(.minutes(5)))
    func theLimitIsReachedAndNotExceeded() async {
        let many = (0..<14).map {
            Self.version("v\($0)", latest: $0 == 13, at: TimeInterval($0), etag: "E\($0)")
        }
        let hold = FakeBucketSettings.VersionReadHold(
            threshold: ObjectVersionsModel.lockReadLimit, reached: AsyncSignal(),
            release: AsyncSignal())
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.versionReadHold = hold
        let settings = FakeBucketSettings(lock: fixture)
        let (model, _) = Self.model(many, settings: settings)
        await model.load()
        let all = model.versions
        let reading = Task { @MainActor in await model.readLockStates(of: all) }
        guard await hold.reached.arrives("lockReadLimit lock reads being in flight together") else {
            reading.cancel()
            hold.release.signal()
            await reading.value
            return
        }
        // Give every other row the chance to get to the store, if the gate lets
        // it: the rest of the rows' tasks are runnable now.
        for _ in 0..<50 { await Task.yield() }
        #expect(settings.maxVersionReadsInFlight == ObjectVersionsModel.lockReadLimit)
        #expect(settings.versionReads.count == ObjectVersionsModel.lockReadLimit)
        hold.release.signal()
        await reading.value
        #expect(model.readings.count == 14)
        #expect(settings.maxVersionReadsInFlight == ObjectVersionsModel.lockReadLimit)
    }

    @Test func theGateRunsAtMostItsLimitAtOnceAndAllOfThem() async {
        @MainActor final class Probe {
            var running = 0
            var peak = 0
            var finished = 0
        }
        let gate = ConcurrencyGate(limit: 2)
        let probe = Probe()
        let tasks = (0..<7).map { _ in
            Task { @MainActor in
                _ = await gate.run {
                    probe.running += 1
                    probe.peak = max(probe.peak, probe.running)
                    // Give up the main actor several times so every other
                    // caller gets a chance to enter, if the gate lets it.
                    for _ in 0..<8 { await Task.yield() }
                    probe.running -= 1
                    probe.finished += 1
                }
            }
        }
        for task in tasks { await task.value }
        #expect(probe.finished == 7)
        #expect(probe.peak == 2)
    }

    // MARK: - Order, filter, search

    @Test func theOrderIsExplicitNewestFirstWithAnUndatedEntryLast() {
        let ordered = ObjectVersionsModel.ordered([
            Self.version("old", at: 100),
            Self.version("undated", at: nil),
            Self.version("new", at: 300),
            Self.version("flagged", latest: true, at: 50),
            Self.version("mid", at: 200),
        ])
        #expect(ordered.map(\.versionId) == ["flagged", "new", "mid", "old", "undated"])
        // Equal dates keep the order they arrived in.
        let ties = ObjectVersionsModel.ordered([
            Self.version("a", at: 100), Self.version("b", at: 100), Self.version("c", at: 100),
        ])
        #expect(ties.map(\.versionId) == ["a", "b", "c"])
    }

    @Test func theLockedFilterListsLockedAndHeldRowsOnly() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = ["v2": ObjectRetention(mode: .governance, retainUntil: Self.at(60))]
        fixture.legalHoldByVersion = ["v1": true]
        let (model, _) = Self.model(Self.threeVersions, settings: FakeBucketSettings(lock: fixture))
        await model.load()
        await model.readLockStates(of: model.versions)
        #expect(
            Set(model.rows(filter: .locked, matching: Self.everything).map(\.id)) == ["v2", "v1"])
        #expect(Self.threeVersions.count == model.rows(filter: .all, matching: Self.everything).count)
        // The filters are exactly the four, so one added later is placed here.
        #expect(ObjectVersionsModel.Filter.allCases.count == 4)
    }

    @Test func theSearchMatchesWhatTheRowShows() async {
        let (model, _) = Self.model(Self.threeVersions, settings: Self.noLock())
        await model.load()
        let (byId, _) = sheetSearchPredicate(text: "v2", isRegex: false)
        #expect(model.rows(filter: .all, matching: byId).map(\.id) == ["v2"])
        let (byState, _) = sheetSearchPredicate(
            text: ObjectVersionsLines.earlier.text, isRegex: false)
        #expect(Set(model.rows(filter: .all, matching: byState).map(\.id)) == ["v2", "v1"])
        let (nothing, _) = sheetSearchPredicate(text: "no such version", isRegex: false)
        #expect(model.rows(filter: .all, matching: nothing).isEmpty)
    }

    /// `stateText(of:localeCode:)` speaks ONE language: the words and the date
    /// are both in `localeCode`, whatever the ambient override says. It used to
    /// resolve only the date through the parameter.
    @Test func theStateTextIsInOneLanguageWhateverTheAmbientOverrideIs() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = ["v2": ObjectRetention(mode: .compliance, retainUntil: Self.at(600))]
        let (model, _) = Self.model(Self.threeVersions, settings: FakeBucketSettings(lock: fixture))
        await model.load()
        await model.readLockStates(of: model.versions)
        let v2 = model.versions[1]
        let german = L10n.$localeOverride.withValue("en") {
            model.stateText(of: v2, localeCode: "de")
        }
        let expected = L10n.$localeOverride.withValue("de") {
            String(
                format: ObjectVersionsLines.locked.text, ObjectLockLines.modeName(.compliance).text,
                ObjectLockDates.text(Self.at(600), localeCode: "de"))
        }
        #expect(german == expected)
        // The control: the same call under an English override and an English
        // code is English, so the two outputs above differ by language.
        let english = L10n.$localeOverride.withValue("en") {
            model.stateText(of: v2, localeCode: "en")
        }
        #expect(english != german)
        #expect(english.hasPrefix("Locked until"))
        // The rows go through the same parameter.
        let rows = L10n.$localeOverride.withValue("en") {
            model.rows(filter: .all, matching: Self.everything, localeCode: "de")
        }
        #expect(rows.first { $0.id == "v2" }?.stateText == expected)
    }

    // MARK: - The target

    @Test func theSheetNamesTheObjectAsTheRowNamedIt() {
        let file = RemoteFileItem(name: "a.txt", path: "/photos/2026/a.txt", kind: .file)
        let list = ConnectionActionContext(
            settings: nil, rootIsContainerList: true, remotePath: "/photos/2026",
            configuredBucket: "")
        let atTheList = ObjectVersionsTarget.resolve(file: file, in: list)
        #expect(atTheList?.bucket == "photos")
        #expect(atTheList?.key == "2026/a.txt")
        // The names are the row's, untouched; they are not rebuilt from the
        // two halves above.
        #expect(atTheList?.displayName == "a.txt")
        #expect(atTheList?.displayPath == "/photos/2026/a.txt")

        let inOneBucket = ConnectionActionContext(
            settings: nil, rootIsContainerList: false, remotePath: "/2026",
            configuredBucket: "photos")
        let single = ObjectVersionsTarget.resolve(
            file: RemoteFileItem(name: "a.txt", path: "/2026/a.txt", kind: .file),
            in: inOneBucket)
        #expect(single?.bucket == "photos")
        #expect(single?.key == "2026/a.txt")
        #expect(single?.displayPath == "/2026/a.txt", "not /photos/2026/a.txt")

        // The bucket list itself is not a file in a bucket.
        let bucketRow = RemoteFileItem(name: "photos", path: "/photos", kind: .directory)
        #expect(ObjectVersionsTarget.resolve(file: bucketRow, in: list) == nil)
    }

    // MARK: - The cost of building the table

    /// A history long enough that a per-row search shows: `count` versions, the
    /// first the current one, and every second one carrying the entity tag of
    /// the one beneath it (a metadata-only pair), plus a delete marker.
    private static func longHistory(_ count: Int) -> [ObjectVersion] {
        (0..<count).map { index in
            if index == 3 {
                return version("m\(index)", marker: true, at: TimeInterval(1000 - index))
            }
            return version(
                "v\(index)", latest: index == 0, at: TimeInterval(1000 - index),
                etag: "E\(index / 2)")
        }
    }

    /// Building the table's rows works out each row's state ONCE and finds no
    /// row by searching for it. Counted, not timed: before this was pinned,
    /// `rows(...)` worked each state out twice (the row's own, and again inside
    /// the state text) and searched `versions` for the row's id up to three
    /// times per row, which is quadratic in a history that nothing caps.
    @Test func buildingTheRowsWorksEachStateOutOnceAndSearchesForNoRow() async {
        let history = Self.longHistory(40)
        let (model, _) = Self.model(history, settings: Self.noLock())
        await model.load()
        let rowCount = model.versions.count
        #expect(rowCount == 40)

        let evaluationsBefore = model.rowStateEvaluations
        let lookupsBefore = model.positionLookups
        let rows = model.rows(filter: .all, matching: Self.everything)
        let evaluations = model.rowStateEvaluations - evaluationsBefore
        let lookups = model.positionLookups - lookupsBefore

        // The positive: the rows were built (all of them), so the counts below
        // are about a real build and not about an empty one.
        #expect(rows.count == rowCount)
        #expect(evaluations == rowCount)
        #expect(lookups == 0)
    }

    /// The same rows, row for row, as asking each one on its own: the cheaper
    /// build changes the cost and nothing the person sees.
    @Test func theBuiltRowsAreWhatAskingEachRowOnItsOwnAnswers() async {
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.retentionByVersion = [
            "v5": ObjectRetention(mode: .governance, retainUntil: Self.at(600))
        ]
        fixture.legalHoldByVersion = ["v6": true]
        let settings = FakeBucketSettings(lock: fixture)
        let (model, _) = Self.model(Self.longHistory(12), settings: settings)
        await model.load()
        await model.readLockStates(of: model.versions.filter { $0.versionId != "v8" })
        let rows = model.rows(filter: .all, matching: Self.everything)
        #expect(rows.count == 12)
        // The premises: the history really holds each kind of row.
        let states = Set(rows.map { String(describing: $0.state) })
        #expect(rows.contains { $0.state == .deleteMarker })
        #expect(rows.contains { $0.state == .metadataOnly })
        #expect(rows.contains { $0.state == .legalHold })
        #expect(rows.contains { $0.state == .lockUnknown })
        #expect(states.count >= 5)
        for row in rows {
            #expect(row.state == model.rowState(of: row.version), "\(row.id)")
            #expect(row.stateText == model.stateText(of: row.version), "\(row.id)")
        }
    }

    // MARK: - Catalogue

    private static let locales = ["en", "de", "fr", "pl"]

    /// How many lines the family has, written down. **An independent figure**:
    /// `german.count == all.count` can never fail (one is a map of the other),
    /// and `> 20` was true of a family of 25 and of one of 54. The command
    /// that produces it, from the repository root, counting the keys the App's
    /// English catalogue holds under this family:
    /// `grep -o '"s3\.versions\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings | wc -l`.
    /// Adding a line means changing this figure, which is the point.
    static let lineCount = 54

    /// The one place a language's word IS the English one: "Versions" is also
    /// the French word. Named by language and key, so a copy anywhere else is
    /// still red, and checked to be the English word (above) rather than
    /// skipped.
    private static let sameWordInThatLanguage: Set<String> = ["fr s3.versions.filter.versions"]

    @Test(arguments: ["en", "de", "fr", "pl"])
    func everyLineResolvesInEveryLanguageAndTheEnglishIsTheSourceText(locale: String) {
        for line in ObjectVersionsLines.all {
            let resolved = L10n.$localeOverride.withValue(locale) {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(resolved != "ZZ-UNRESOLVED-ZZ", "\(line.key) in \(locale)")
            if locale == "en" {
                #expect(resolved == line.english, "\(line.key)")
            } else if Self.sameWordInThatLanguage.contains("\(locale) \(line.key)") {
                #expect(resolved == line.english, "\(line.key) in \(locale)")
            } else {
                // A translation is not a copy of the English.
                #expect(resolved != line.english, "\(line.key) in \(locale)")
            }
        }
        #expect(ObjectVersionsLines.all.count == Self.lineCount)
    }

    @Test func everyTranslationKeepsTheFormatSpecifiersOfTheEnglish() {
        let specifier = #/%(\d+\$)?(lld|@|d)/#
        var withSpecifiers = 0
        for line in ObjectVersionsLines.all {
            let english = line.english.matches(of: specifier).map { String($0.output.0) }.sorted()
            if !english.isEmpty { withSpecifiers += 1 }
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(line.key, "") }
                let found = resolved.matches(of: specifier).map { String($0.output.0) }.sorted()
                #expect(found == english, "\(line.key) in \(locale)")
            }
        }
        // Six: the sheet's title, the lock line, the two counts, and the two
        // confirmation sentences of the row actions (Task 9). (Withdrawn
        // wording, verbatim: `#expect(withSpecifiers == 4)` -- true until the
        // restore and delete confirmations, which name the file, the date and
        // for the delete the version id, joined the family.)
        #expect(withSpecifiers == 6)
    }

    /// Every German line, not one: the name and the plural make a claim about
    /// all of them. The negative (no polite form anywhere) has its positive
    /// beside it: the lines were really scanned (more than twenty; the
    /// comment used to say "25 of them", true before the row actions' lines
    /// joined the family), and the one that
    /// carries an address form carries the informal one.
    @Test func theGermanSentencesAddressTheReaderAsDu() {
        let german = L10n.$localeOverride.withValue("de") {
            ObjectVersionsLines.all.map(\.text)
        }
        #expect(german.count == ObjectVersionsLines.all.count)
        #expect(german.count == Self.lineCount)
        #expect(german.contains { $0.contains("Dein ") })
        let polite = german.filter {
            $0.contains(" Ihr") || $0.hasPrefix("Ihr") || $0.contains("Ihnen")
                || $0.contains("Sie ") || $0.contains(" Sie")
        }
        #expect(polite.isEmpty, "\(polite)")
    }

    /// The sheet's source is read for the keys it spells, so a key used in a
    /// view and missing from the list the checks above walk is red here.
    @Test func everyKeyTheSheetSourceSpellsIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectVersionsSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(source.matches(of: #/"(s3\.versions\.[^"]+)"/#).map { String($0.output.1) })
        let covered = Set(ObjectVersionsLines.all.map(\.key))
        #expect(used.count == covered.count, "\(used.count) keys spelled, \(covered.count) covered")
        #expect(used.subtracting(covered).isEmpty, "\(used.subtracting(covered).sorted())")
        #expect(covered.subtracting(used).isEmpty, "\(covered.subtracting(used).sorted())")
    }

    /// The columns, side by side at their minimums, and the sheet's inset on
    /// both sides fit the width the sheet is bounded to. The footer (a count and
    /// the close button) is measured by `BoundedViewLayoutGuardTests` through the
    /// registry; the table is not, so its minimum is held here.
    @Test func theColumnsFitTheSheetsOwnWidth() {
        let needed = ObjectVersionsSheet.columnMinimums + 2 * ObjectVersionsSheet.padding
        #expect(needed > 2 * ObjectVersionsSheet.padding, "the columns have a width")
        #expect(needed <= ObjectVersionsSheet.bound.grantedWidth, "\(needed) of \(ObjectVersionsSheet.bound.grantedWidth)")
    }

    /// The row set is built once per render and handed to the table and to the
    /// footer's count: each build filters, formats and sorts every row. The
    /// negative (no second read of `rows`) has its positive beside it: the one
    /// `let` is found.
    @Test func theRowSetIsBuiltOncePerRender() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectVersionsSheet.swift")
        let source = try SourceCorpus.code(of: url)
        #expect(source.contains("let shown = rows"))
        let reads = source.matches(of: #/(?:^|[^.\w])rows(?!\w)/#).count
        // The model's `func rows(`, the view's `private var rows`, and the one
        // read (`model.rows(` is preceded by a dot and not counted).
        #expect(reads == 3, "`rows` is spelled \(reads) times")
        #expect(!source.contains("rows.count"))
    }

    /// The sheet is the audit log's shape: a table, a filter menu, the shared
    /// search field with its predicate, and a footer that counts.
    @Test func theSheetIsTheAuditLogsShape() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/ObjectVersionsSheet.swift")
        let source = try SourceCorpus.code(of: url)
        for needle in ["Table(", "Picker(", "SheetSearchField(", "sheetSearchPredicate(", ".sheetBound(Self.bound)"] {
            #expect(source.contains(needle), "\(needle)")
        }
        #expect(!source.contains("\u{0}absent"))
    }
}

/// The sheet hosted in a window, so the table realises its cells: the lock of
/// a row is requested by the row's own state cell, and that is the one thing
/// the model tests above cannot reach.
@Suite("Object versions sheet, hosted", .serialized)
@MainActor
struct ObjectVersionsSheetHostedTests {
    /// Spike, 2026-11-02: hosting the sheet and laying it out is enough for
    /// every realised cell's `.task` to start (a first retention read per
    /// row, up to the limit, was recorded before any await), so the
    /// assertion that something was asked needs no waiting. The wait for the
    /// rest is for the reads to finish, and `AsyncSignal.arrives` is its hang
    /// bound. (Withdrawn wording, verbatim: "the case's own `.timeLimit` is its
    /// hang bound" -- it does not end a park.)
    @Test(.timeLimit(.minutes(5)))
    func theTableAsksForTheLockOfEveryRowItShowsAndOfNoMarker() async throws {
        let history = [
            ObjectVersion(
                versionId: "v3", key: "a.txt", isLatest: true, isDeleteMarker: false, size: 3,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_300), entityTag: "C"),
            ObjectVersion(
                versionId: "m1", key: "a.txt", isLatest: false, isDeleteMarker: true, size: nil,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_200), entityTag: nil),
            ObjectVersion(
                versionId: "null", key: "a.txt", isLatest: false, isDeleteMarker: false, size: 1,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_100), entityTag: "A"),
        ]
        var fixture = FakeBucketSettings.ObjectLockFixture(hasLock: true)
        fixture.legalHoldByVersion = ["null": true]
        let settings = FakeBucketSettings(lock: fixture)
        let model = ObjectVersionsModel(
            target: ObjectVersionsTarget(
                bucket: "b", key: "a.txt", displayName: "a.txt", displayPath: "/b/a.txt"),
            provider: FakeVersionProvider(versions: history), recorder: nil,
            locks: .init(settings: settings, cache: ObjectLockStateCache(settings: settings)),
            versioning: nil)
        await model.load()
        #expect(model.bucketLock == .applies)
        #expect(settings.versionReads.isEmpty, "nothing is read until a row is on screen")

        let host = NSHostingView(rootView: ObjectVersionsSheet(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // A `#require`, not an `#expect`: with no read requested the wait below
        // would wait for reads that were never sent.
        try #require(
            !settings.versionReads.isEmpty, "laying the table out asked for no row's lock")
        // Wait for the reads of the rows the model lists, counted off the model
        // and not spelled: a listing that lost a row (the `null` one) would
        // otherwise wait for a read that is never sent. The wait is an `await`
        // on a signal the model raises as each reading is recorded, so the main
        // actor is free while it waits, and the wait carries the hang bound
        // (`AsyncSignal.arrives`) so that a reading that never lands is a named
        // failure. (Withdrawn wording, verbatim: "so the main actor is free while
        // it waits and the case's own `.timeLimit` can fire if a reading never
        // lands" -- the time limit does not end a park.) (It was a `Task.yield()` loop with an
        // iteration bound; it made progress, but it burned the one main-actor
        // executor for as long as the reads took, which is the starvation
        // CLAUDE.md measures on the three-core runner.)
        let expected = model.versions.filter { !$0.isDeleteMarker }.count
        let allRecorded = AsyncSignal()
        model.lockReadRecorded = { [unowned model] in
            if model.readings.count >= expected { allRecorded.signal() }
        }
        if model.readings.count >= expected { allRecorded.signal() }
        guard await allRecorded.arrives("every lock reading being recorded") else { return }
        #expect(model.readings.count == expected, "the reads did not all come back")
        #expect(model.readings.keys.sorted() == ["null", "v3"])
        let nullVersion = try #require(
            model.versions.first { $0.versionId == "null" }, "the listing has no null version")
        #expect(model.rowState(of: nullVersion) == .legalHold)
        #expect(!settings.versionReads.contains { $0.versionId == "m1" })
    }
}
