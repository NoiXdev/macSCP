import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The audit trail of the five S3 bucket-settings writes (S3 bucket settings,
/// Task 12): each write leaves exactly one line of its own kind, a refusal
/// does not read as done, the three Object Lock operations are told apart,
/// and a missing recorder costs the write nothing.
///
/// The five writes do not share a signature. They are
/// `CreateBucketModel.create(via:recorder:)`,
/// `BucketVersioningModel.apply(_:bucket:via:locks:recorder:)`,
/// `BucketCORSModel.save(bucket:via:recorder:)`,
/// `ObjectLockModel.run(key:bucket:via:recorder:)` (a file's retention and a
/// file's legal hold are the same method, told apart by the model's focus) and
/// `BucketObjectLockModel.save(bucket:via:recorder:)`, so the table below is
/// of an invoking closure per operation and not of one signature.
///
/// That the recorder is passed at all is the compiler's job, not a scan's:
/// every one of those parameters is required, with no default value, and
/// optional in its type.
@Suite("Bucket settings audit")
struct BucketSettingsAuditTests {
    /// What the store would say about a refusal. A named constant, and every
    /// check that it did not reach the trail computes its `Bool` first:
    /// `#expect` prints the source text of the expression it checks, so a
    /// value written into an expectation leaks through the failure message of
    /// the very test that forbids it.
    private static let storeWords = "store-words-canary-7f3a"

    private static var refusal: any Error { RemoteFSError.protocolError(reason: storeWords) }

    /// What an operation did, as far as the test can see without the trail:
    /// whether the store was asked to write, and whether the sheet's model
    /// shows a failure.
    struct Outcome: Sendable {
        let storeWasAskedToWrite: Bool
        let modelShowsAFailure: Bool
    }

    /// One of the five writes, driven through its own apply path. `refuse`
    /// makes the fake store refuse that write with `storeWords`.
    struct Operation: Sendable, CustomTestStringConvertible {
        let name: String
        let kind: AuditEvent.Kind
        let run: @MainActor @Sendable (_ recorder: AuditRecorder?, _ refuse: Bool) async -> Outcome
        var testDescription: String { name }
    }

    private static let corsDocument =
        "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"

    static let operations: [Operation] = [
        Operation(name: "create a bucket", kind: .bucketCreated) { recorder, refuse in
            let settings = FakeBucketSettings(createFailure: refuse ? .refused(Self.refusal) : nil)
            let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
            model.name = "macscp-third"
            await model.create(via: settings, recorder: recorder)
            let failed: Bool
            if case .failed = model.outcome { failed = true } else { failed = false }
            return Outcome(
                storeWasAskedToWrite: settings.creates.count == 1, modelShowsAFailure: failed)
        },
        Operation(name: "change versioning", kind: .versioningChanged) { recorder, refuse in
            let settings = FakeBucketSettings(
                versioning: .never, writeError: refuse ? Self.refusal : nil)
            let model = BucketVersioningModel(current: .never, bucketHasObjectLock: false)
            await model.apply(
                .enabled, bucket: "b1", via: settings,
                locks: ObjectLockStateCache(settings: settings), recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.writes.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
        Operation(name: "save CORS rules", kind: .corsChanged) { recorder, refuse in
            let settings = FakeBucketSettings(corsWriteError: refuse ? Self.refusal : nil)
            let model = BucketCORSModel(loaded: nil)
            model.text = Self.corsDocument
            await model.save(bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.corsWrites.count == 1,
                modelShowsAFailure: model.saveFailure != nil)
        },
        Operation(name: "set a file's retention", kind: .objectLockChanged) { recorder, refuse in
            let settings = FakeBucketSettings(lock: .init(writeError: refuse ? Self.refusal : nil))
            let model = ObjectLockModel(focus: .retention, bucketHasLock: true)
            await model.run(key: "reports/q3.pdf", bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.retentionWrites.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
        Operation(name: "place a file's legal hold", kind: .objectLockChanged) { recorder, refuse in
            let settings = FakeBucketSettings(lock: .init(writeError: refuse ? Self.refusal : nil))
            let model = ObjectLockModel(focus: .legalHold, bucketHasLock: true)
            model.legalHold = true
            await model.run(key: "reports/q3.pdf", bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.legalHoldWrites.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
        Operation(name: "set a bucket's Object Lock default", kind: .objectLockChanged) {
            recorder, refuse in
            let settings = FakeBucketSettings(lock: .init(writeError: refuse ? Self.refusal : nil))
            let model = BucketObjectLockModel(bucketHasLock: true, current: nil)
            await model.save(bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.defaultWrites.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
    ]

    /// A recorder over a store of its own, and the way to read what it
    /// recorded.
    private struct Trail {
        let recorder: AuditRecorder
        let directory: URL
        let store: AuditLogStore
        let sessionID = UUID()

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BucketSettingsAuditTests-\(UUID().uuidString)", isDirectory: true)
            store = AuditLogStore(directory: directory)
            recorder = AuditRecorder(sessionID: sessionID, store: store)
        }

        var events: [AuditEvent] { store.events(for: sessionID) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - The table is the thing it claims to be

    /// The positive control for every test below: a table that quietly lost a
    /// row, or whose rows all claim an old kind, would make them pass over
    /// fewer operations than the four new kinds stand for.
    @Test func theTableCoversEveryNewKind() {
        let covered = Set(Self.operations.map(\.kind))
        #expect(covered == [.bucketCreated, .versioningChanged, .corsChanged, .objectLockChanged])
        // Three of the rows share a kind on purpose: it is the one kind that
        // covers three operations.
        let lockRows = Self.operations.filter { $0.kind == .objectLockChanged }
        #expect(lockRows.count == 3)
    }

    // MARK: - One line, of the operation's own kind

    @MainActor @Test(arguments: operations)
    func eachOperationRecordsExactlyOneEventOfItsOwnKind(operation: Operation) async {
        let trail = Trail()
        defer { trail.remove() }
        let outcome = await operation.run(trail.recorder, false)
        #expect(outcome.storeWasAskedToWrite)
        #expect(outcome.modelShowsAFailure == false)
        let events = trail.events
        #expect(events.count == 1)
        #expect(events.first?.kind == operation.kind)
        #expect(events.first?.isError == false)
        #expect(events.first?.errorMessage == nil)
        // The detail names the bucket the write was about. Every operation in
        // the table uses one of these two, so a line that lost it fails here.
        let detail = events.first?.detail ?? ""
        let namesABucket = detail.contains("b1") || detail.contains("macscp-third")
        #expect(namesABucket)
    }

    // MARK: - A refusal

    @MainActor @Test(arguments: operations)
    func aRefusedOperationRecordsTheFailureAndNotASuccess(operation: Operation) async {
        let trail = Trail()
        defer { trail.remove() }
        let outcome = await operation.run(trail.recorder, true)
        #expect(outcome.storeWasAskedToWrite)
        #expect(outcome.modelShowsAFailure, "the sheet itself must show the refusal, or this tests nothing")
        let events = trail.events
        #expect(events.count == 1)
        #expect(events.first?.kind == operation.kind)
        #expect(events.first?.isError == true)
        let message = events.first?.errorMessage ?? ""
        #expect(message.isEmpty == false)
    }

    /// The store's own words never reach the trail: a `reason` can carry the
    /// endpoint the user typed, and that field takes
    /// `scheme://KEY:SECRET@host` as ordinary input. The positive control is
    /// the test above, whose refusal carries the same words and is recorded.
    @MainActor @Test(arguments: operations)
    func aRefusalsOwnWordsNeverReachTheTrail(operation: Operation) async {
        let trail = Trail()
        defer { trail.remove() }
        _ = await operation.run(trail.recorder, true)
        let events = trail.events
        #expect(events.count == 1, "nothing was recorded, so nothing was checked")
        let canary = Self.storeWords
        let leaked = events.contains { event in
            event.detail.contains(canary) || (event.errorMessage ?? "").contains(canary)
        }
        #expect(leaked == false)
    }

    // MARK: - Nothing sent, nothing recorded

    @MainActor @Test func aRunTheSheetRefusesBeforeAnyRequestRecordsNothing() async {
        let trail = Trail()
        defer { trail.remove() }

        // A name already in the bucket list: the sheet's own gate stops it.
        let settings = FakeBucketSettings()
        let taken = CreateBucketModel(existingNames: ["macscp-seed"], listingIsKnown: true)
        taken.name = "macscp-seed"
        await taken.create(via: settings, recorder: trail.recorder)

        // A COMPLIANCE retention whose tick was never given.
        let lock = FakeBucketSettings(lock: .init())
        let unticked = ObjectLockModel(focus: .retention, bucketHasLock: true)
        unticked.mode = .compliance
        await unticked.run(key: "k", bucket: "b1", via: lock, recorder: trail.recorder)

        #expect(settings.creates.isEmpty)
        #expect(lock.retentionWrites.isEmpty)
        #expect(trail.events.isEmpty)

        // The positive control: the same recorder records a write that goes
        // through.
        let ok = Self.operations[0]
        _ = await ok.run(trail.recorder, false)
        #expect(trail.events.count == 1)
    }

    // MARK: - The three Object Lock operations

    @MainActor @Test func anObjectLockLineNamesWhichOfTheThreeOperationsItWas() async {
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let until = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z
        let trail = Trail()
        defer { trail.remove() }

        // A COMPLIANCE retention: the only irreversible write macSCP makes.
        let compliance = ObjectLockModel(focus: .retention, bucketHasLock: true, now: { clock })
        compliance.mode = .compliance
        compliance.retainUntil = until
        compliance.acknowledged = true
        let store = FakeBucketSettings(lock: .init())
        await compliance.run(key: "reports/q3.pdf", bucket: "b1", via: store, recorder: trail.recorder)

        let hold = ObjectLockModel(focus: .legalHold, bucketHasLock: true, now: { clock })
        hold.legalHold = true
        await hold.run(key: "reports/q3.pdf", bucket: "b1", via: store, recorder: trail.recorder)

        let fallback = BucketObjectLockModel(bucketHasLock: true, current: nil, now: { clock })
        await fallback.save(bucket: "b1", via: store, recorder: trail.recorder)

        let events = trail.events
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.kind == .objectLockChanged })
        let details = events.map(\.detail)
        #expect(Set(details).count == 3, "three operations, three different lines")

        // The one assertion the 2026-10-19 decision rests on: the irreversible
        // write's line names the mode, the date, and the object.
        let retentionLine = details.first ?? ""
        #expect(retentionLine.contains("COMPLIANCE"))
        #expect(retentionLine.contains("2027-01-15T08:00:00Z"))
        #expect(retentionLine.contains("b1/reports/q3.pdf"))
        // And the reversible ones do not borrow its words.
        let others = details.dropFirst()
        let borrowed = others.contains { $0.contains("COMPLIANCE") }
        #expect(borrowed == false)
    }

    // MARK: - A missing recorder

    /// A KNOWN ABSENCE, measured. With no recorder the write goes through,
    /// shows no failure, and records nothing anywhere.
    ///
    /// When a tab has none: a tab whose stored session was deleted in the
    /// sidebar while it was open (`ContentView+Detail.swift`, the `onDelete`
    /// closure, sets `auditRecorder = nil` on purpose so the deleted
    /// session's log is not recreated as an orphan). It is NOT an ad-hoc
    /// connect: that gets a recorder under `AdHocAudit.sessionID`, pinned by
    /// `anAdHocConnectIsGivenARecorderUnderTheAdHocLogID`. The sheets take an
    /// optional recorder so that this case compiles and behaves; they take it
    /// with no default so that it is a decision at every call site.
    @MainActor @Test(arguments: operations)
    func withNoRecorderTheWriteStillGoesThroughAndNothingIsRecorded(operation: Operation) async {
        let bystander = Trail()
        defer { bystander.remove() }
        let outcome = await operation.run(nil, false)
        #expect(outcome.storeWasAskedToWrite)
        #expect(outcome.modelShowsAFailure == false)
        // A recorder that exists but was not handed to the operation records
        // nothing: the absence is of the recorder, not an accident of this
        // trail being empty for another reason (the table test above is the
        // positive control: the same operation DOES record when handed one).
        #expect(bystander.events.isEmpty)
    }

    /// The other half of the measurement above: an unsaved connection is given
    /// a recorder, under the fixed ad-hoc log id (M31), so its bucket-settings
    /// writes are audited like a stored session's. `ContentView.swift` says so
    /// in code: `startSession` attaches a recorder whatever the connection
    /// was saved or not, with `AdHocAudit.logSessionID`.
    @Test func anAdHocConnectIsGivenARecorderUnderTheAdHocLogID() throws {
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/ContentView.swift")
        let source = try SourceCorpus.code(of: url)
        let attach = try #require(source.range(of: "attachAuditRecorder("))
        let around = String(source[attach.lowerBound...].prefix(400))
        #expect(around.contains("AdHocAudit.logSessionID(storedID: storedSession?.id)"))
        // The positive control: the id is the stored one when there is one.
        let stored = UUID()
        #expect(AdHocAudit.logSessionID(storedID: stored) == stored)
        #expect(AdHocAudit.logSessionID(storedID: nil) == AdHocAudit.sessionID)
    }
}
