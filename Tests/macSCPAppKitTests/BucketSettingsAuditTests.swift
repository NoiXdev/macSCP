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
        /// What the line of a write that went through starts with. The values
        /// that reach the recorder are the sheet's, and only a test through
        /// the sheet's own apply path can see them: the Core tests hand the
        /// recorder whatever they like.
        let detailPrefix: String
        let run: @MainActor @Sendable (_ recorder: AuditRecorder?, _ refuse: Bool) async -> Outcome
        var testDescription: String { name }
    }

    private static let corsDocument =
        "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"

    static let operations: [Operation] = [
        Operation(
            name: "create a bucket", kind: .bucketCreated,
            detailPrefix: "created bucket macscp-third") { recorder, refuse in
            let settings = FakeBucketSettings(createFailure: refuse ? .refused(Self.refusal) : nil)
            let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
            model.name = "macscp-third"
            await model.create(via: settings, recorder: recorder)
            let failed: Bool
            if case .failed = model.outcome { failed = true } else { failed = false }
            return Outcome(
                storeWasAskedToWrite: settings.creates.count == 1, modelShowsAFailure: failed)
        },
        Operation(
            name: "change versioning", kind: .versioningChanged,
            detailPrefix: "versioning of bucket b1 set to enabled") { recorder, refuse in
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
        Operation(
            name: "save CORS rules", kind: .corsChanged,
            detailPrefix: "CORS rules of bucket b1 set to 1 rule") { recorder, refuse in
            let settings = FakeBucketSettings(corsWriteError: refuse ? Self.refusal : nil)
            let model = BucketCORSModel(loaded: nil)
            model.text = Self.corsDocument
            await model.save(bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.corsWrites.count == 1,
                modelShowsAFailure: model.saveFailure != nil)
        },
        Operation(
            name: "set a file's retention", kind: .objectLockChanged,
            detailPrefix: "retention of b1/reports/q3.pdf set to GOVERNANCE until ") { recorder, refuse in
            let settings = FakeBucketSettings(lock: .init(writeError: refuse ? Self.refusal : nil))
            let model = ObjectLockModel(focus: .retention, bucketHasLock: true)
            await model.run(key: "reports/q3.pdf", bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.retentionWrites.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
        Operation(
            // The other value of the enum the row above leaves at its default.
            // A sheet starts on GOVERNANCE, so a refused retention whose
            // recorded mode is forced to GOVERNANCE equals the attempt of the
            // row above and nothing could notice; it differs from this one.
            // The clock is injected, so the line is exact.
            name: "set a file's COMPLIANCE retention", kind: .objectLockChanged,
            detailPrefix: "retention of b1/reports/q3.pdf set to COMPLIANCE until 2027-01-15T08:00:00Z"
        ) { recorder, refuse in
            let clock = Date(timeIntervalSince1970: 1_700_000_000)
            let until = Date(timeIntervalSince1970: 1_800_000_000)
            let settings = FakeBucketSettings(lock: .init(writeError: refuse ? Self.refusal : nil))
            let model = ObjectLockModel(focus: .retention, bucketHasLock: true, now: { clock })
            // Each of these takes the acknowledgement back, so the tick is last.
            model.mode = .compliance
            model.retainUntil = until
            model.acknowledged = true
            await model.run(key: "reports/q3.pdf", bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.retentionWrites.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
        Operation(
            name: "place a file's legal hold", kind: .objectLockChanged,
            detailPrefix: "legal hold on b1/reports/q3.pdf placed") { recorder, refuse in
            let settings = FakeBucketSettings(lock: .init(writeError: refuse ? Self.refusal : nil))
            let model = ObjectLockModel(focus: .legalHold, bucketHasLock: true)
            model.legalHold = true
            await model.run(key: "reports/q3.pdf", bucket: "b1", via: settings, recorder: recorder)
            return Outcome(
                storeWasAskedToWrite: settings.legalHoldWrites.count == 1,
                modelShowsAFailure: model.applyFailure != nil)
        },
        Operation(
            name: "set a bucket's Object Lock default", kind: .objectLockChanged,
            detailPrefix: "default retention of bucket b1 set to GOVERNANCE for 30 days"
        ) { recorder, refuse in
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
        // Four of the rows share a kind on purpose: it is the one kind that
        // covers three operations, and the retention is in it twice, once per
        // mode. (Corrected: this comment read "Three of the rows share a kind
        // on purpose: it is the one kind that covers three operations", and the
        // check beneath it was `lockRows.count == 3`.)
        let lockRows = Self.operations.filter { $0.kind == .objectLockChanged }
        #expect(lockRows.count == 4)
        // Seven rows for the five apply methods (`ObjectLockModel.run` serves
        // the retention and the legal hold, and the retention has one row per
        // mode). Pinned because a duplicated row would pass the two checks
        // above while the parameterised tests ran a bogus case as an eighth
        // operation. (Corrected: this comment read "Six rows for the five apply
        // methods (`ObjectLockModel.run` serves the retention and the legal
        // hold). Pinned because a duplicated row would pass the two checks
        // above while the parameterised tests ran a bogus case as a seventh
        // operation", and the check was `Self.operations.count == 6`.)
        #expect(Self.operations.count == 7)
        // The positive control for the refused-write check below: both modes
        // are in the table, so a recorded mode forced to either one differs
        // from the attempt of the other row.
        let modes = ["GOVERNANCE", "COMPLIANCE"].filter { mode in
            Self.operations.contains { $0.detailPrefix.contains("set to \(mode) until") }
        }
        #expect(modes == ["GOVERNANCE", "COMPLIANCE"])
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
        // The detail carries the values the sheet wrote: the bucket, the key,
        // the state or mode, the count. A wrong value, not only a missing line,
        // fails here.
        let detail = events.first?.detail ?? ""
        let startsAsExpected = detail.hasPrefix(operation.detailPrefix)
        #expect(startsAsExpected, "\(operation.name)")
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
        // The line of a refused write says what was ATTEMPTED, with the same
        // values a success would have carried (Core pins the shape). Without
        // this, a refused COMPLIANCE retention could be recorded as an attempt
        // at GOVERNANCE, or a refused hold as its opposite, and nothing would
        // notice (probes N3 and N4 of the Task 12 review ended GREEN).
        //
        // **Corrected (Task 12, fix round 2).** That sentence was true of the
        // legal hold and false of the retention: the table's only retention row
        // left the mode at the sheet's default, GOVERNANCE, so a recorded mode
        // forced to GOVERNANCE was the attempt itself and N3 stayed GREEN. The
        // table now has a retention row per mode.
        let detail = events.first?.detail ?? ""
        let describesTheAttempt = detail.hasPrefix(operation.detailPrefix)
        #expect(describesTheAttempt, "\(operation.name)")
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

    // MARK: - What the create's line claims (F1)

    /// **The audit line records what was READ BACK, not what was requested.**
    /// The store answers the create with success and does not apply the
    /// Object Lock header, so a line saying the bucket has Object Lock is a
    /// record someone would later rely on for a protection that is not there
    /// -- which is worse than a sheet saying it, because the sheet is read
    /// once and the trail is read afterwards.
    ///
    /// The positive control is the second half: the same create against a
    /// store that does apply it DOES say Object Lock, so this is not a test
    /// that passes because the words never appear.
    @MainActor @Test func aCreateWhoseObjectLockDidNotTakeIsNotRecordedAsHavingIt() async {
        let didNotTake = Trail()
        defer { didNotTake.remove() }
        let ignoring = FakeBucketSettings(createEffect: .ignoresTheObjectLockHeader)
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: ignoring, recorder: didNotTake.recorder)

        let events = didNotTake.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .bucketCreated)
        let detail = events.first?.detail ?? ""
        // What was read back: versioning took, the lock did not.
        #expect(detail == "created bucket macscp-third with versioning")
        #expect(detail.contains("Object Lock") == false)
        // And it is not recorded as a clean write: a line with no failure
        // beside it reads as done.
        #expect(events.first?.isError == true)
        #expect((events.first?.errorMessage ?? "").isEmpty == false)

        let took = Trail()
        defer { took.remove() }
        let applying = FakeBucketSettings()
        let confirmed = CreateBucketModel(existingNames: [], listingIsKnown: true)
        confirmed.name = "macscp-third"
        confirmed.objectLock = true
        await confirmed.create(via: applying, recorder: took.recorder)
        let confirmedDetail = took.events.first?.detail ?? ""
        #expect(confirmedDetail == "created bucket macscp-third with versioning and Object Lock")
        #expect(took.events.first?.isError == false)
    }

    /// **The mirror, and what the line must say about it.** The create asked
    /// for versioning only and landed on a bucket that already has Object
    /// Lock. "created bucket X with versioning" would be a record of what was
    /// asked for, beside a bucket that enforces something nobody chose and
    /// nobody can remove. The line names what was READ BACK, so it says
    /// Object Lock -- and carries the failure sentence, so it does not read
    /// as a clean write either.
    ///
    /// Together with the test above, this is the property stated both ways:
    /// no line claims a protection that is not there, and no line omits one
    /// that is.
    @MainActor @Test func aCreateOntoAnAlreadyLockedBucketRecordsTheLockItFound() async {
        let trail = Trail()
        defer { trail.remove() }
        let locked = FakeBucketSettings(lock: .init(hasLock: true))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.versioning = true
        await model.create(via: locked, recorder: trail.recorder)

        let events = trail.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .bucketCreated)
        let detail = events.first?.detail ?? ""
        #expect(detail == "created bucket macscp-third with versioning and Object Lock")
        #expect(events.first?.isError == true)
        #expect((events.first?.errorMessage ?? "").isEmpty == false)
    }

    /// The same, for a create that chose NOTHING. The person asked for a
    /// plain bucket; the line names the versioning and the Object Lock the
    /// read-back found, because they are what the bucket has and what a
    /// reader of the trail will be deciding from -- and under a COMPLIANCE
    /// default the objects written into it afterwards cannot be deleted by
    /// anyone until their dates pass.
    @MainActor @Test func aPlainCreateOntoAnAlreadyProtectedBucketRecordsWhatItFound() async {
        let trail = Trail()
        defer { trail.remove() }
        let protected = FakeBucketSettings(versioning: .enabled, lock: .init(hasLock: true))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        await model.create(via: protected, recorder: trail.recorder)

        let events = trail.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .bucketCreated)
        let detail = events.first?.detail ?? ""
        #expect(detail == "created bucket macscp-third with versioning and Object Lock")
        #expect(detail != "created bucket macscp-third")
        #expect(events.first?.isError == true)
        #expect((events.first?.errorMessage ?? "").isEmpty == false)
    }

    /// **The default retention reaches the trail with its mode and its day
    /// count.** Those two are what a reader of the trail decides from -- how
    /// long the files they added are held, and whether anyone can lift it --
    /// and the sheet's sentence carries neither, by design. Neither is a
    /// secret: no store text, no endpoint, no key.
    @MainActor @Test func aBucketDefaultFoundOnACreateIsRecordedWithItsModeAndDays() async {
        let trail = Trail()
        defer { trail.remove() }
        let withDefault = FakeBucketSettings(
            versioning: .enabled,
            lock: .init(hasLock: true, bucketDefault: .init(days: 30, mode: .compliance)))
        let model = CreateBucketModel(existingNames: [], listingIsKnown: true)
        model.name = "macscp-third"
        model.objectLock = true
        await model.create(via: withDefault, recorder: trail.recorder)

        let events = trail.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .bucketCreated)
        let detail = events.first?.detail ?? ""
        #expect(
            detail == "created bucket macscp-third with versioning and Object Lock; "
                + "the bucket already had a COMPLIANCE default retention of 30 days")
        #expect(events.first?.isError == true)
        #expect((events.first?.errorMessage ?? "").isEmpty == false)

        // The positive control: the same create on a bucket with no default
        // records the line without the clause, and as a clean write.
        let plain = Trail()
        defer { plain.remove() }
        let noDefault = CreateBucketModel(existingNames: [], listingIsKnown: true)
        noDefault.name = "macscp-third"
        noDefault.objectLock = true
        await noDefault.create(via: FakeBucketSettings(), recorder: plain.recorder)
        let plainDetail = plain.events.first?.detail ?? ""
        #expect(plainDetail == "created bucket macscp-third with versioning and Object Lock")
        #expect(plainDetail.contains("default retention") == false)
        #expect(plain.events.first?.isError == false)
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

    // MARK: - The recorder reaches the sheet

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(
            of: SourceCorpus.url(of: .sources).appendingPathComponent(relativePath))
    }

    /// The first place `name` is called, as a whole identifier: `ObjectLockSheet(`
    /// is also the tail of `BucketObjectLockSheet(`, and a plain substring search
    /// for the one finds the other's call site first (measured by probe P9, which
    /// planted `recorder: nil` in the one this scan then never looked at).
    private static func firstUse(of name: String, in source: String) -> Range<String.Index>? {
        var from = source.startIndex
        while let found = source.range(of: "\(name)(", range: from..<source.endIndex) {
            let before = found.lowerBound > source.startIndex
                ? source[source.index(before: found.lowerBound)] : " "
            if !(before.isLetter || before.isNumber || before == "_") { return found }
            from = found.upperBound
        }
        return nil
    }

    /// The compiler makes every call site DECIDE about a recorder; it cannot
    /// say the decision was the tab's. A `recorder: nil` in the dispatcher
    /// compiles, passes every model test above, and silently drops the trail
    /// of the one write that cannot be undone. The type names are read from
    /// the types, not spelled.
    @Test func everySheetItemIsBuiltWithTheTabsRecorder() throws {
        let dispatchers =
            try Self.code("MacSCPAppKit/ContentView+MenuActions.swift")
        let items = [
            String(describing: ContentView.BucketVersioningSheetItem.self),
            String(describing: ContentView.BucketCORSSheetItem.self),
            String(describing: ContentView.BucketObjectLockSheetItem.self),
            String(describing: ContentView.CreateBucketSheetItem.self),
            String(describing: ContentView.ObjectLockSheetItem.self),
        ]
        for item in items {
            let at = try #require(Self.firstUse(of: item, in: dispatchers), "\(item) is built nowhere")
            let around = String(dispatchers[at.upperBound...].prefix(120))
            let passesTheTabs = around.contains("recorder: tab.auditRecorder")
            #expect(passesTheTabs, "\(item)")
        }
    }

    /// The second hop: the item's recorder reaches the sheet that applies.
    @Test func everySheetIsBuiltWithItsItemsRecorder() throws {
        let sheets = try Self.code("MacSCPAppKit/ContentView+Sheets.swift")
        let names = [
            String(describing: BucketVersioningSheet.self),
            String(describing: BucketCORSSheet.self),
            String(describing: BucketObjectLockSheet.self),
            String(describing: CreateBucketSheet.self),
            String(describing: ObjectLockSheet.self),
        ]
        for name in names {
            let at = try #require(Self.firstUse(of: name, in: sheets), "\(name) is built nowhere")
            let around = String(sheets[at.upperBound...].prefix(120))
            let passesItems = around.contains("recorder: item.recorder")
            #expect(passesItems, "\(name)")
        }
    }

    // MARK: - Create's records, one per arm

    /// `create` makes exactly one recording call per arm it can take: the
    /// store accepted the request and the read-back confirmed the settings;
    /// it accepted and the bucket turned out to have LESS protection than was
    /// asked for; it accepted and the bucket turned out to have MORE; it
    /// accepted and the bucket turned out to carry a DEFAULT RETENTION this
    /// call cannot have set; it accepted and the read-back did not answer; it
    /// refused. Six. That is what is pinned, and it is the half that notices
    /// a record somebody deleted.
    ///
    /// **Corrected 2026-10-23 (F1, fix round 4).** The sentence above read,
    /// verbatim: "it accepted and the bucket turned out to have MORE; it
    /// accepted and the read-back did not answer; it refused. Five.", and the
    /// check was `recordingCalls == 5` with the message "confirmed, less than
    /// asked, more than asked, unconfirmed, refused". A sixth arm landed: the
    /// bucket has a DEFAULT RETENTION, which this call cannot have set.
    ///
    /// **Corrected 2026-10-22 (F1, fix round 3).** The sentence above read,
    /// verbatim: "it accepted and the read-back found something else; it
    /// accepted and the read-back did not answer; it refused. Four.", and the
    /// check was `recordingCalls == 4` with the message "confirmed, not as
    /// asked, unconfirmed, refused". "Something else" split in two, because
    /// the two directions of a mismatch are two different things to tell a
    /// person and two different lines to write.
    ///
    /// **Corrected 2026-10-22 (F1 of the final whole-branch review).** This
    /// test was named `createMakesExactlyTwoRecordingCalls`, asserted
    /// `recordingCalls == 2` with the message "the success line and the
    /// refusal line", and its first paragraph read, verbatim: "`create` makes
    /// exactly two recording calls: one when the store accepted the request,
    /// one when it refused it." The success side is now three arms, because a
    /// create the store accepted is read back before it is called done, and
    /// each arm records a different protection or a different sentence.
    ///
    /// What is NOT pinned, and cannot be by a text scan: that the refusal's
    /// record is unconditional, the shape the fix for Ruling 20 gave it (it
    /// is made straight from the catch, like each of the other four apply
    /// methods, and the type that carries the refusal can only be a refusal).
    /// (Corrected: that clause read "like the other four recording sites".
    /// Four is the number of apply methods; the recording calls outside
    /// `create` are more numerous, because several of those methods record on
    /// more than one arm.) An
    /// earlier version of this test tried, by forbidding control-flow
    /// keywords between the catch and the call. It was withdrawn after two
    /// ways round it were measured, neither of which contains a keyword: the
    /// call placed inside a helper that decides, and the call placed inside a
    /// closure handed to an optional's map. Short-circuit operators branch
    /// without a keyword too. The ways to branch are an open set, so any list
    /// of them is a chase, and the next reader finds the next spelling.
    ///
    /// Reinstating a gate changes no behaviour: a refusal is recorded either
    /// way, because the refusal type has no arm that is not a refusal. That is
    /// why no behavioural test can see the difference, and why the shape is a
    /// readability property of the code, not an invariant of the program.
    @Test func createMakesOneRecordingCallPerArmItCanTake() throws {
        let source = try Self.code("MacSCPAppKit/CreateBucketSheet.swift")
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains("func create(via") })
        let end = try #require(lines[(start + 1)...].firstIndex { $0.hasPrefix("    }") })
        let recordingCalls = lines[start...end].filter { $0.contains("recordBucketCreated(") }.count
        #expect(
            recordingCalls == 6,
            "confirmed, less, more, a default nobody set here, unconfirmed, refused")
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
