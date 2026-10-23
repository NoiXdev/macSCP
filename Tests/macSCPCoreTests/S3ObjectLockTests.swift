import Foundation
import Testing

@testable import macSCPCore

/// Object Lock on `S3FileSystem`'s `S3BucketSettings` conformance: the bucket
/// default, a retention and a legal hold on one object, and the delete path
/// that tells a lock from a missing permission. Against the canned transport;
/// the rig half is `S3ObjectLockGatedTests`.
///
/// What the rig will NOT show, and so what is pinned here: that macSCP sends
/// a signed `Content-MD5` on `PUT ?object-lock` (every request in
/// `S3ObjectLockGatedTests` sends it, so a green gated run is silent on
/// whether the rig requires it), and that there is no way to switch Object
/// Lock on for an existing bucket (the rig allows it).
///
/// **The rig does not require the header. MEASURED 2026-10-23, and only of
/// RustFS 1.0.0.** On a throwaway bucket created with
/// `x-amz-bucket-object-lock-enabled`, one `PUT ?object-lock` carrying a
/// GOVERNANCE default of one day and NO `Content-MD5` was answered
/// `HTTP 200` with an empty body; the CONTROL, a `GET ?object-lock`
/// afterwards, read back `<Mode>GOVERNANCE</Mode><Days>1</Days>`, so the
/// configuration took and the 200 is not the "accepted and ignored" answer a
/// status alone would also fit. The bucket was deleted (204) and its absence
/// confirmed (404). Sent with curl's own SigV4, the instrument the design's
/// §4 table was measured with -- **not** through `S3FileSystem`, so what is
/// measured is that this store accepts a validly signed request without the
/// header, not that macSCP's own code path was exercised without it.
///
/// **The AWS half is still a reading, not a measurement.** That AWS answers
/// `400` without the header comes from a search summary of its published
/// reference for `PutObjectLockConfiguration` (see the comment in
/// `S3FileSystem.setObjectLockDefault`), and this rig cannot speak for AWS in
/// either direction. macSCP sends the header, signed, on both. The two halves
/// stay separate: measured of RustFS 1.0.0, read of AWS.
///
/// **Corrected 2026-10-23.** The parenthesis above read, verbatim: "and no
/// run of the request without it is on record; the header of that file names
/// the observation that would settle it", and the paragraph that followed it
/// read, verbatim: "**Corrected 2026-10-22 (Task 13).** The parenthesis
/// after "`Content-MD5` on `PUT ?object-lock`" read, verbatim: "(the rig does
/// not require it)". That was stated as a fact and was not measured." Both
/// described a question nobody had put to a store. The run above is that
/// observation, made on the outcome the gated file had decided for in
/// advance.
@Suite("S3 Object Lock")
struct S3ObjectLockTests {
    // MARK: - Fixtures

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    private static let namespace = "http://s3.amazonaws.com/doc/2006-03-01/"

    private static func lockDocument(_ inner: String) -> Data {
        Data("<ObjectLockConfiguration>\(inner)</ObjectLockConfiguration>".utf8)
    }

    private static func error(_ code: String) -> Data {
        Data("<Error><Code>\(code)</Code><Message>text the store wrote</Message></Error>".utf8)
    }

    private static let accessDenied = error("AccessDenied")

    private static func retentionDocument(mode: String, until: String) -> Data {
        Data(
            "<Retention><Mode>\(mode)</Mode><RetainUntilDate>\(until)</RetainUntilDate></Retention>"
                .utf8)
    }

    private static func holdDocument(_ status: String) -> Data {
        Data("<LegalHold><Status>\(status)</Status></LegalHold>".utf8)
    }

    /// The reason of the `.protocolError` a call throws, or a description of
    /// what it did instead; `nil` when it did not throw.
    private func protocolReason(_ work: () throws -> some Any) -> String? {
        do {
            _ = try work()
            return nil
        } catch RemoteFSError.protocolError(let reason) {
            return reason
        } catch {
            return "threw something else: \(error)"
        }
    }

    private func answer(_ body: Data, status: Int = 200) -> (Data, HTTPURLResponse) {
        (body, S3SettingsFake.httpResponse(status: status))
    }

    // MARK: - The bucket default, XML

    @Test func anAbsentLockConfigurationIsNilAndNotAZeroDayDefault() throws {
        #expect(
            try S3SettingsXML.parseObjectLockResponse(
                status: 404,
                body: Data(
                    "<Error><Code>ObjectLockConfigurationNotFoundError</Code></Error>".utf8)) == nil)
    }

    @Test func aBucketDefaultRoundTrips() throws {
        let body = try S3SettingsXML.objectLockBody(days: 1, mode: .governance)
        let parsed = try #require(try S3SettingsXML.parseObjectLockResponse(status: 200, body: body))
        #expect(parsed.days == 1)
        #expect(parsed.mode == .governance)
    }

    @Test(arguments: RetentionMode.allCases, [1, 30, 3650])
    func everyModeAndSeveralDayCountsRoundTrip(mode: RetentionMode, days: Int) throws {
        let body = try S3SettingsXML.objectLockBody(days: days, mode: mode)
        let parsed = try #require(try S3SettingsXML.parseObjectLockResponse(status: 200, body: body))
        #expect(parsed.days == days)
        #expect(parsed.mode == mode)
    }

    @Test func theBodyIsTheDocumentS3Documents() throws {
        let body = try S3SettingsXML.objectLockBody(days: 30, mode: .compliance)
        #expect(
            String(data: body, encoding: .utf8)
                == Self.header + "<ObjectLockConfiguration xmlns=\"\(Self.namespace)\">"
                + "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                + "<Mode>COMPLIANCE</Mode><Days>30</Days></DefaultRetention></Rule>"
                + "</ObjectLockConfiguration>")
    }

    /// A lock with no default and a bucket with no lock are different states
    /// that read the same through the public signature, so the internal read
    /// keeps them apart; `setObjectLockDefault` depends on it.
    @Test func noObjectLockAndObjectLockWithoutADefaultAreDifferentStates() throws {
        let absent = try S3SettingsXML.parseObjectLockState(
            status: 404, body: Self.error("ObjectLockConfigurationNotFoundError"))
        let noDefault = try S3SettingsXML.parseObjectLockState(
            status: 200,
            body: Self.lockDocument("<ObjectLockEnabled>Enabled</ObjectLockEnabled>"))
        #expect(absent == .notConfigured)
        #expect(noDefault == .enabled(defaultRetention: nil))
        // Both are `nil` through the public read, and neither is a default.
        #expect(
            try S3SettingsXML.parseObjectLockResponse(
                status: 200,
                body: Self.lockDocument("<ObjectLockEnabled>Enabled</ObjectLockEnabled>")) == nil)
    }

    /// The 404 of a missing BUCKET is not the 404 of a missing lock
    /// configuration: the code decides.
    @Test func aDifferentNotFoundIsNotAnAbsentLockConfiguration() {
        #expect(throws: RemoteFSError.notFound(path: "/b")) {
            try S3SettingsXML.parseObjectLockResponse(
                status: 404, body: Self.error("NoSuchBucket"), path: "/b")
        }
    }

    /// The rig writes `Days` before `Mode`, which is the order S3 documents
    /// the other way round (measured 2026-10-19).
    @Test func theFieldsDoNotDependOnTheirOrder() throws {
        let rigOrder = Self.lockDocument(
            "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                + "<Days>7</Days><Mode>COMPLIANCE</Mode></DefaultRetention></Rule>")
        let reversed = Self.lockDocument(
            "<Rule><DefaultRetention><Mode>COMPLIANCE</Mode><Days>7</Days></DefaultRetention></Rule>"
                + "<ObjectLockEnabled>Enabled</ObjectLockEnabled>")
        for document in [rigOrder, reversed] {
            let parsed = try #require(try S3SettingsXML.parseObjectLockResponse(status: 200, body: document))
            #expect(parsed.days == 7)
            #expect(parsed.mode == .compliance)
        }
    }

    @Test func aDefaultInYearsIsRefusedAndNotConvertedToDays() throws {
        let years = Self.lockDocument(
            "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                + "<Mode>GOVERNANCE</Mode><Years>1</Years></DefaultRetention></Rule>")
        let reason = protocolReason { try S3SettingsXML.parseObjectLockResponse(status: 200, body: years) }
        #expect(reason?.contains("years") == true)
        #expect(reason?.hasPrefix("Failed to parse S3 object lock response") == true)
    }

    @Test(arguments: [
        ("<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Days>1</Days></DefaultRetention></Rule>", "no known Mode"),
        ("<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>LOOSE</Mode><Days>1</Days></DefaultRetention></Rule>", "no known Mode"),
        ("<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode></DefaultRetention></Rule>", "neither Days nor Years"),
        ("<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days><Years>1</Years></DefaultRetention></Rule>", "both Days and Years"),
        ("<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>soon</Days></DefaultRetention></Rule>", "not a positive integer"),
        ("<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>0</Days></DefaultRetention></Rule>", "not a positive integer"),
        ("<Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days></DefaultRetention></Rule>", "no ObjectLockEnabled"),
        ("<ObjectLockEnabled>Disabled</ObjectLockEnabled>", "unknown ObjectLockEnabled"),
    ])
    func aDocumentThatCannotBeReadAsADefaultIsRefused(inner: String, reasonFragment: String) {
        let reason = protocolReason {
            try S3SettingsXML.parseObjectLockResponse(status: 200, body: Self.lockDocument(inner))
        }
        #expect(reason?.contains(reasonFragment) == true, "got: \(reason ?? "no error")")
    }

    /// Only an element at its place in the schema counts. A `Days` and a
    /// `Mode` anywhere else are not the default's: this document has a
    /// default retention with neither of its own, and so is refused, where a
    /// parser that took the first `Days` it saw would have read 9.
    @Test func onlyAnElementAtItsPlaceInTheSchemaCounts() throws {
        let misplaced = Self.lockDocument(
            "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Days>9</Days><Mode>COMPLIANCE</Mode>"
                + "<Rule><Days>9</Days><DefaultRetention><Mode>GOVERNANCE</Mode></DefaultRetention></Rule>")
        let reason = protocolReason {
            try S3SettingsXML.parseObjectLockResponse(status: 200, body: misplaced)
        }
        #expect(reason?.contains("neither Days nor Years") == true, "got: \(reason ?? "no error")")
        // The positive beside it: the same elements, in their place, are read.
        let placed = Self.lockDocument(
            "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                + "<Mode>GOVERNANCE</Mode><Days>9</Days></DefaultRetention></Rule>")
        let parsed = try #require(try S3SettingsXML.parseObjectLockResponse(status: 200, body: placed))
        #expect(parsed.days == 9)
    }

    @Test func aDocumentWithAnotherRootIsRefusedWithTheParsersOwnReason() {
        let reason = protocolReason {
            try S3SettingsXML.parseObjectLockResponse(
                status: 200, body: Data("<html><body>proxy</body></html>".utf8))
        }
        #expect(reason == "Failed to parse S3 object lock response: no ObjectLockConfiguration element")
    }

    @Test func aDocumentThatIsNotWellFormedIsRefused() {
        let reason = protocolReason {
            try S3SettingsXML.parseObjectLockResponse(
                status: 200, body: Data("<ObjectLockConfiguration><ObjectLockEnabled>".utf8))
        }
        #expect(reason?.hasPrefix("Failed to parse S3 object lock response") == true)
    }

    @Test(arguments: [0, -1, Int.min])
    func fewerThanOneDayIsRefusedWhenTheBodyIsBuilt(days: Int) {
        let reason = protocolReason { try S3SettingsXML.objectLockBody(days: days, mode: .governance) }
        #expect(reason?.contains("at least one day") == true)
    }

    // MARK: - Retention, XML

    @Test(arguments: [
        RetentionMode.governance, RetentionMode.compliance,
    ])
    func aRetentionRoundTrips(mode: RetentionMode) throws {
        let retention = ObjectRetention(
            mode: mode, retainUntil: Date(timeIntervalSince1970: 1_800_000_000))
        let parsed = try S3SettingsXML.parseRetention(S3SettingsXML.retentionBody(retention))
        #expect(parsed == retention)
    }

    @Test func theRetentionBodyIsExactlyWhatTheStoreReadsBack() {
        let body = S3SettingsXML.retentionBody(
            ObjectRetention(mode: .governance, retainUntil: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(
            String(data: body, encoding: .utf8)
                == Self.header + "<Retention xmlns=\"\(Self.namespace)\"><Mode>GOVERNANCE</Mode>"
                + "<RetainUntilDate>2027-01-15T08:00:00.000Z</RetainUntilDate></Retention>")
    }

    @Test(arguments: ["2027-01-15T08:00:00.000Z", "2027-01-15T08:00:00Z"])
    func aTimestampIsReadWithOrWithoutFractionalSeconds(text: String) throws {
        let parsed = try S3SettingsXML.parseRetention(Self.retentionDocument(mode: "COMPLIANCE", until: text))
        #expect(parsed == ObjectRetention(mode: .compliance, retainUntil: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func anObjectWithNoRetentionReadsNilWhicheverWayTheStoreSaysIt() throws {
        // The rig: an empty element (measured 2026-10-19).
        #expect(try S3SettingsXML.parseRetentionResponse(status: 200, body: Data("<Retention></Retention>".utf8)) == nil)
        // AWS: an error naming the missing configuration.
        #expect(try S3SettingsXML.parseRetentionResponse(status: 404, body: Self.error("NoSuchObjectLockConfiguration")) == nil)
    }

    /// `nil` is "no retention", and a bucket with no Object Lock is another
    /// answer: the rig says `400 InvalidRequest` to both lock reads there.
    @Test func otherRefusalsAreNotNoRetention() {
        #expect(throws: RemoteFSError.notFound(path: "/b/k")) {
            try S3SettingsXML.parseRetentionResponse(status: 404, body: Self.error("NoSuchKey"), path: "/b/k")
        }
        #expect(throws: RemoteFSError.finding(.unexpectedStatus(code: 400))) {
            try S3SettingsXML.parseRetentionResponse(status: 400, body: Self.error("InvalidRequest"), path: "/b/k")
        }
    }

    @Test(arguments: [
        ("<Retention><Mode>GOVERNANCE</Mode></Retention>", "not both present"),
        ("<Retention><RetainUntilDate>2027-01-15T08:00:00.000Z</RetainUntilDate></Retention>", "not both present"),
        ("<Retention><Mode>LOOSE</Mode><RetainUntilDate>2027-01-15T08:00:00.000Z</RetainUntilDate></Retention>", "unknown Mode"),
        ("<Retention><Mode>GOVERNANCE</Mode><RetainUntilDate>next week</RetainUntilDate></Retention>", "not a timestamp"),
        ("<LegalHold><Status>ON</Status></LegalHold>", "no Retention element"),
    ])
    func aRetentionDocumentThatCannotBeReadIsRefused(document: String, reasonFragment: String) {
        let reason = protocolReason { try S3SettingsXML.parseRetention(Data(document.utf8)) }
        #expect(reason?.contains(reasonFragment) == true, "got: \(reason ?? "no error")")
    }

    // MARK: - Legal hold, XML

    @Test func aHoldReadsOnOrOff() throws {
        #expect(try S3SettingsXML.parseLegalHold(Self.holdDocument("ON")) == true)
        #expect(try S3SettingsXML.parseLegalHold(Self.holdDocument("OFF")) == false)
    }

    @Test func anObjectNeverHeldReadsFalseWhichEverWayTheStoreSaysIt() throws {
        #expect(try S3SettingsXML.parseLegalHoldResponse(status: 200, body: Self.holdDocument("OFF")) == false)
        #expect(try S3SettingsXML.parseLegalHoldResponse(status: 404, body: Self.error("NoSuchObjectLockConfiguration")) == false)
    }

    @Test func aHoldDocumentThatSaysNeitherOnNorOffIsRefusedAndNotReadAsOff() {
        for document in ["<LegalHold></LegalHold>", "<LegalHold><Status>MAYBE</Status></LegalHold>", "<Retention/>"] {
            let reason = protocolReason { try S3SettingsXML.parseLegalHold(Data(document.utf8)) }
            #expect(reason?.hasPrefix("Failed to parse S3 legal hold response") == true, "\(document): \(reason ?? "no error")")
        }
    }

    @Test func aMissingKeyIsNotAnUnheldObject() {
        #expect(throws: RemoteFSError.notFound(path: "/b/k")) {
            try S3SettingsXML.parseLegalHoldResponse(status: 404, body: Self.error("NoSuchKey"), path: "/b/k")
        }
    }

    @Test(arguments: [(true, "ON"), (false, "OFF")])
    func theHoldBodyNamesItsStatus(on: Bool, status: String) {
        #expect(
            String(data: S3SettingsXML.legalHoldBody(on), encoding: .utf8)
                == Self.header + "<LegalHold xmlns=\"\(Self.namespace)\"><Status>\(status)</Status></LegalHold>")
    }

    // MARK: - The bucket default, requests

    @Test func theDefaultIsReadFromTheBucketsObjectLockSubresource() async throws {
        let body = Self.lockDocument(
            "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                + "<Days>1</Days><Mode>GOVERNANCE</Mode></DefaultRetention></Rule>")
        let (fs, transport) = try await S3SettingsFake.connect(responses: [answer(body)])
        let current = try #require(try await fs.objectLockDefault(ofBucket: "other"))
        #expect(current.days == 1)
        #expect(current.mode == .governance)
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "object-lock=")
    }

    // MARK: - Whether a bucket has Object Lock at all

    /// The three states, each through the same call: a lock with a default,
    /// a lock with NO default (the one `objectLockDefault` cannot tell from
    /// "no lock"), and no lock.
    @Test(arguments: [
        ("a default retention", 0, true),
        ("a lock with no default yet", 1, true),
        ("no lock at all", 2, false),
    ])
    func hasObjectLockTellsALockWithoutADefaultFromNoLock(
        label: String, scenario: Int, expected: Bool
    ) async throws {
        let response: (Data, HTTPURLResponse)
        switch scenario {
        case 0:
            response = answer(
                Self.lockDocument(
                    "<ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                        + "<Mode>GOVERNANCE</Mode><Days>1</Days></DefaultRetention></Rule>"))
        case 1:
            response = answer(Self.lockEnabledNoDefault)
        default:
            response = answer(Self.error("ObjectLockConfigurationNotFoundError"), status: 404)
        }
        let (fs, transport) = try await S3SettingsFake.connect(responses: [response])
        #expect(try await fs.hasObjectLock(ofBucket: "other") == expected, "\(label)")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "object-lock=")
    }

    /// `false` is the store saying the bucket has no lock, and nothing else
    /// is: a refusal, a missing bucket and an unreadable answer all throw.
    @Test func aFailureIsNeverReadAsNoObjectLock() async throws {
        let cases: [((Data, HTTPURLResponse), RemoteFSError?)] = [
            (answer(Data(), status: 403), .authenticationFailed),
            (answer(Self.error("NoSuchBucket"), status: 404), .notFound(path: "/other")),
            (answer(Data("<html>proxy</html>".utf8)), nil),
        ]
        for (response, expected) in cases {
            let (fs, _) = try await S3SettingsFake.connect(responses: [response])
            do {
                let has = try await fs.hasObjectLock(ofBucket: "other")
                Issue.record("a failure was read as \(has)")
            } catch {
                if let expected {
                    #expect((error as? RemoteFSError) == expected)
                } else {
                    #expect(error is RemoteFSError)
                }
            }
        }
    }

    @Test func aBucketWithoutObjectLockReadsNilAndNotAnError() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            answer(Self.error("ObjectLockConfigurationNotFoundError"), status: 404)
        ])
        #expect(try await fs.objectLockDefault(ofBucket: "other") == nil)
    }

    private static let lockEnabledNoDefault = lockDocument("<ObjectLockEnabled>Enabled</ObjectLockEnabled>")

    /// Ruling A. The rig does NOT check the header -- measured 2026-10-23, of
    /// RustFS 1.0.0 only: a `PUT ?object-lock` without `Content-MD5` was
    /// answered 200 and the configuration read back, see this file's header
    /// for the method and the control. This test pins what macSCP SENDS,
    /// which is what no store's tolerance can settle: the header is required
    /// by a READING of AWS's reference, and no AWS endpoint has ever been
    /// reached from this project.
    ///
    /// **Corrected 2026-10-23.** This paragraph read, verbatim: "Ruling A.
    /// Whether the rig checks the header is not known (see the header of
    /// `S3ObjectLockGatedTests`); this test pins what macSCP SENDS.
    /// (Withdrawn, verbatim: "and the rig does not check it", stated as a fact
    /// and never measured.)" The question has now been put to the rig. What
    /// the correction it quotes was right about stands: a shape-only test is
    /// what pins macSCP's own request, and a tolerant store is a reason to
    /// send the header rather than a reason not to.
    ///
    /// The request carries a
    /// `Content-MD5` of its body, and the header is SIGNED. The digest is a
    /// literal, the base64 MD5 of the exact body, not a call to the code that
    /// computes it. The first request is the read that precedes every write.
    @Test(arguments: [
        (RetentionMode.governance, 1, "ioUu5NbE86A7mZxhCptGfg=="),
        (RetentionMode.compliance, 30, "/NeDzuXdkxnc5qBFURUUyg=="),
    ])
    func settingTheDefaultIsAPutWithASignedContentMD5OfItsBody(
        mode: RetentionMode, days: Int, expectedMD5: String
    ) async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            answer(Self.lockEnabledNoDefault), answer(Data()),
        ])
        try await fs.setObjectLockDefault(days: days, mode: mode, ofBucket: "other")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "object-lock=")
        #expect(sent.value(forHTTPHeaderField: "Content-MD5") == expectedMD5)
        let authorization = try #require(sent.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("content-md5"))
        let body = try #require(sent.httpBody)
        #expect(body == (try S3SettingsXML.objectLockBody(days: days, mode: mode)))
        #expect(sent.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4Signer.hexSHA256(body))
    }

    /// Ruling C, in behaviour: the rig would accept this write on a bucket
    /// created without Object Lock, so it is the call, not the store, that
    /// refuses. Exactly one request goes out (the read), and it is not a PUT.
    @Test func aBucketWithoutObjectLockIsRefusedAfterOneReadAndNothingIsWritten() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            answer(Self.error("ObjectLockConfigurationNotFoundError"), status: 404)
        ])
        let before = await transport.requests.count
        do {
            try await fs.setObjectLockDefault(days: 1, mode: .governance, ofBucket: "other")
            Issue.record("a default was set on a bucket with no Object Lock")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.objectLockNotConfigured))
        }
        let sent = await transport.requests.dropFirst(before)
        #expect(sent.count == 1)
        #expect(sent.first?.httpMethod == "GET")
        #expect(sent.contains { $0.httpMethod == "PUT" } == false)
    }

    @Test func aRefusedReadStopsTheWriteToo() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [answer(Data(), status: 403)])
        let before = await transport.requests.count
        do {
            try await fs.setObjectLockDefault(days: 1, mode: .governance, ofBucket: "other")
            Issue.record("a refused read went on to write")
        } catch {
            #expect((error as? RemoteFSError) == .authenticationFailed)
        }
        #expect(await transport.requests.count == before + 1)
    }

    @Test func fewerThanOneDaySendsNothing() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [])
        let before = await transport.requests.count
        await #expect(throws: RemoteFSError.self) {
            try await fs.setObjectLockDefault(days: 0, mode: .governance, ofBucket: "other")
        }
        #expect(await transport.requests.count == before)
    }

    // MARK: - Per object, requests

    @Test func aRetentionIsReadFromTheKeysRetentionSubresource() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            answer(Self.retentionDocument(mode: "GOVERNANCE", until: "2027-01-15T08:00:00.000Z"))
        ])
        let held = try await fs.retention(ofKey: "dir/a b.txt", inBucket: "other", versionId: nil)
        #expect(held == ObjectRetention(mode: .governance, retainUntil: Date(timeIntervalSince1970: 1_800_000_000)))
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/other/dir/a b.txt")
        #expect(sent.url?.query == "retention=")
    }

    @Test func aVersionIsNamedInTheQueryWhenOneIsGiven() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            answer(Self.holdDocument("ON")), answer(Self.holdDocument("ON")),
        ])
        _ = try await fs.legalHold(ofKey: "k", inBucket: "other", versionId: nil)
        let current = try #require(await transport.requests.last)
        _ = try await fs.legalHold(ofKey: "k", inBucket: "other", versionId: "v-1")
        let versioned = try #require(await transport.requests.last)
        #expect(current.url?.query == "legal-hold=")
        #expect(versioned.url?.query == "legal-hold=&versionId=v-1")
        #expect(versioned.url?.path == "/other/k")
    }

    @Test func aMissingObjectIsNotFoundAtTheCallersOwnPath() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            answer(Self.error("NoSuchKey"), status: 404)
        ])
        do {
            _ = try await fs.retention(ofKey: "dir/gone", inBucket: "other", versionId: nil)
            Issue.record("a missing key returned a retention")
        } catch {
            #expect((error as? RemoteFSError) == .notFound(path: "/other/dir/gone"))
        }
    }

    @Test func settingARetentionIsAPutOfItsBodyWithASignedContentMD5() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [answer(Data())])
        try await fs.setRetention(
            ObjectRetention(mode: .governance, retainUntil: Date(timeIntervalSince1970: 1_800_000_000)),
            ofKey: "dir/a", inBucket: "other", versionId: "v-9")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/other/dir/a")
        #expect(sent.url?.query == "retention=&versionId=v-9")
        #expect(sent.value(forHTTPHeaderField: "Content-MD5") == "oyL+n7oAUYIBUPwYkgyGMA==")
        let authorization = try #require(sent.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("content-md5"))
        let body = try #require(sent.httpBody)
        #expect(String(data: body, encoding: .utf8)?.contains("<Mode>GOVERNANCE</Mode>") == true)
        #expect(sent.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4Signer.hexSHA256(body))
    }

    /// Nothing on this path sends the governance bypass, so a shortening the
    /// store refuses stays refused; pinned so the header cannot arrive by
    /// accident.
    @Test func noWriteSendsTheGovernanceBypass() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [answer(Data()), answer(Data())])
        try await fs.setRetention(
            ObjectRetention(mode: .governance, retainUntil: Date(timeIntervalSince1970: 1_800_000_000)),
            ofKey: "k", inBucket: "other", versionId: nil)
        try await fs.setLegalHold(false, ofKey: "k", inBucket: "other", versionId: nil)
        for sent in await transport.requests.suffix(2) {
            #expect(sent.value(forHTTPHeaderField: "x-amz-bypass-governance-retention") == nil)
        }
    }

    @Test(arguments: [(true, "PabGSMHFuZL/pMW6ZUAWbQ=="), (false, "dUbasAU9gptvOryKx8wHGQ==")])
    func settingAHoldIsAPutWithASignedContentMD5(on: Bool, expectedMD5: String) async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [answer(Data())])
        try await fs.setLegalHold(on, ofKey: "k", inBucket: "other", versionId: nil)
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/other/k")
        #expect(sent.url?.query == "legal-hold=")
        #expect(sent.value(forHTTPHeaderField: "Content-MD5") == expectedMD5)
        let authorization = try #require(sent.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("content-md5"))
    }

    @Test func aRefusedWriteIsMappedThroughTheSharedStatusMapping() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [answer(Self.accessDenied, status: 403)])
        do {
            try await fs.setLegalHold(true, ofKey: "k", inBucket: "other", versionId: nil)
            Issue.record("a 403 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .authenticationFailed)
        }
    }

    // MARK: - A refused delete: a lock, or a missing permission

    private static let farFuture = retentionDocument(mode: "GOVERNANCE", until: "2999-01-01T00:00:00.000Z")
    private static let longPast = retentionDocument(mode: "GOVERNANCE", until: "2001-01-01T00:00:00.000Z")
    private static let noRetention = Data("<Retention></Retention>".utf8)

    /// The connection is in `.bucket` mode, so the path a finding carries is
    /// `/` + the key whichever bucket was asked about.
    private func refusal(
        probes: [(Data, HTTPURLResponse)], code: String = "AccessDenied"
    ) async throws -> (error: RemoteFSError, requests: Int) {
        let (fs, transport) = try await S3SettingsFake.connect(responses: probes)
        let before = await transport.requests.count
        let error = await fs.refusalOfDelete(
            status: 403, body: Self.error(code), bucket: "other", key: "k")
        return (error, await transport.requests.count - before)
    }

    @Test func aLegalHoldIsNamedAsOne() async throws {
        let (error, requests) = try await refusal(probes: [answer(Self.holdDocument("ON"))])
        #expect(error == .finding(.objectUnderLegalHold(path: "/k")))
        // The hold settles it: the retention is not read.
        #expect(requests == 1)
    }

    @Test func aRetentionInForceIsNamedAsOne() async throws {
        let (error, _) = try await refusal(probes: [answer(Self.holdDocument("OFF")), answer(Self.farFuture)])
        #expect(error == .finding(.objectUnderRetention(path: "/k")))
    }

    /// A key that lacks the permission gets the same `AccessDenied`, and
    /// telling it that its file is under a retention would be wrong the other
    /// way round. Each of these establishes no lock, so the answer is the
    /// ordinary one.
    @Test(arguments: [
        ("no hold, no retention", 0),
        ("no hold, a retention that has passed", 1),
        ("a bucket without Object Lock", 2),
    ])
    func noLockInForceMeansTheOrdinaryRefusal(label: String, scenario: Int) async throws {
        let probes: [(Data, HTTPURLResponse)]
        switch scenario {
        case 0:
            probes = [answer(Self.holdDocument("OFF")), answer(Self.noRetention)]
        case 1:
            probes = [answer(Self.holdDocument("OFF")), answer(Self.longPast)]
        default:
            probes = [
                answer(Self.error("InvalidRequest"), status: 400),
                answer(Self.error("InvalidRequest"), status: 400),
            ]
        }
        let (error, _) = try await refusal(probes: probes)
        #expect(error == .authenticationFailed, "\(label)")
    }

    @Test func aRefusalThatIsNotAccessDeniedAsksNothing() async throws {
        let (error, requests) = try await refusal(probes: [], code: "SignatureDoesNotMatch")
        #expect(error == .authenticationFailed)
        #expect(requests == 0)
    }

    @Test func aDeleteOfASingleFileSaysItIsUnderALegalHold() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            answer(Data()),  // HEAD: an object
            answer(Data(S3SettingsFake.emptyListingXML.utf8)),  // no children
            answer(Self.accessDenied, status: 403),  // DELETE refused
            answer(Self.holdDocument("ON")),
        ])
        do {
            try await fs.delete(path: "/k")
            Issue.record("a refused delete returned")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.objectUnderLegalHold(path: "/k")))
        }
    }

    // MARK: - A refusal inside a DeleteObjects answer

    private func listing(_ keys: [String]) -> Data {
        let contents = keys.map { "<Contents><Key>\($0)</Key><Size>0</Size></Contents>" }.joined()
        return Data(
            ("<ListBucketResult xmlns=\"\(Self.namespace)\"><IsTruncated>false</IsTruncated>"
                + contents + "</ListBucketResult>").utf8)
    }

    private let directoryListing = Data(
        ("<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
            + "<IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>d/</Prefix></CommonPrefixes>"
            + "</ListBucketResult>").utf8)

    /// One `deleteTree` over `keys`, whose `DeleteObjects` answer is a 200
    /// listing `echoed` as `AccessDenied`, followed by `probes`.
    ///
    /// **`echoed` is a LIST** (F2 of the final whole-branch review): every
    /// case here used a batch with exactly one refused key, which is why none
    /// of them could see that the lock probe ran per key. The volume is the
    /// property, so the fixture has to be able to express it.
    private func deleteTree(
        sending keys: [String], refused echoed: [String], probes: [(Data, HTTPURLResponse)]
    ) async throws -> (error: RemoteFSError?, probeRequests: Int) {
        let entries = echoed.map {
            "<Error><Key>\($0)</Key><Code>AccessDenied</Code>"
                + "<Message>text the store wrote</Message></Error>"
        }.joined()
        let result = Data("<DeleteResult>\(entries)</DeleteResult>".utf8)
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            answer(Data(), status: 404), answer(directoryListing), answer(listing(keys)),
            answer(result),
        ] + probes)
        let before = await transport.requests.count
        do {
            try await fs.deleteTree(at: "/d")
            return (nil, 0)
        } catch {
            return (error as? RemoteFSError, await transport.requests.count - before - 4)
        }
    }

    /// The probe list begins with the BUCKET's lock state (F2): `deleteTree`
    /// asks `GET ?object-lock` once per call before it asks about any key, so
    /// a case that wants a key probed has to let the bucket answer first.
    @Test func aKeyRefusedUnderALockIsNamedAtTheCallersOwnKey() async throws {
        let outcome = try await deleteTree(
            sending: ["d/", "d/a"], refused: ["d/a"],
            probes: [
                answer(Self.lockDocument("<ObjectLockEnabled>Enabled</ObjectLockEnabled>")),
                answer(Self.holdDocument("ON")),
            ])
        #expect(outcome.error == .finding(.objectUnderLegalHold(path: "/d/a")))
    }

    /// Ruling B. The store echoes a key this batch never held, and a finding
    /// must not carry a value the store chose: the entry is skipped, and with
    /// nothing named the failure is the generic one. No lock is looked up for
    /// it either — and since F2 that `probeRequests == 0` says something more:
    /// a skipped entry does not even make the call ask the bucket's lock
    /// state, because the skip happens before the `AccessDenied` arm.
    @Test func aKeyTheBatchNeverHeldIsNeverShownAsAPath() async throws {
        let outcome = try await deleteTree(
            sending: ["d/", "d/a"], refused: ["somewhere/else"],
            probes: [answer(Self.holdDocument("ON"))])
        guard case .protocolError? = outcome.error else {
            Issue.record("expected the generic failure, got \(String(describing: outcome.error))")
            return
        }
        #expect(outcome.probeRequests == 0)
    }

    /// The echoed key is matched the way Swift compares strings, which is by
    /// canonical equivalence, and the path is the caller's spelling of it:
    /// here the caller sent the precomposed form and the store echoed the
    /// decomposed one.
    @Test func theCallersSpellingIsUsedWhenTheStoreEchoesAnEquivalentOne() async throws {
        let precomposed = "d/caf\u{E9}"
        let decomposed = "d/cafe\u{301}"
        let outcome = try await deleteTree(
            sending: ["d/", precomposed], refused: [decomposed],
            probes: [
                answer(Self.lockDocument("<ObjectLockEnabled>Enabled</ObjectLockEnabled>")),
                answer(Self.holdDocument("ON")),
            ])
        guard case .finding(.objectUnderLegalHold(let path))? = outcome.error else {
            Issue.record("expected a legal hold finding, got \(String(describing: outcome.error))")
            return
        }
        #expect(Array(path.unicodeScalars) == Array("/\(precomposed)".unicodeScalars))
    }

    /// **F2.** Four refused keys in ONE batch, on a bucket with no Object
    /// Lock. The lock state is a property of the bucket, not of the key, so
    /// it is asked at most once per `deleteTree` call: one probe request for
    /// the whole batch, not two per refused key.
    ///
    /// What the eight requests this replaces would have bought: nothing. A
    /// bucket without Object Lock has no key under a hold or a retention, and
    /// the rig answers `400 InvalidRequest` to both reads
    /// (`noLockInForceMeansTheOrdinaryRefusal`'s third argument measures that).
    /// `AccessDenied` is what EVERY key gets from an access key that lacks
    /// `s3:DeleteObject`, so the batch that pays most is the ordinary one.
    @Test func aBatchOfRefusedKeysAsksTheBucketsLockStateOnlyOnce() async throws {
        let keys = ["d/", "d/a", "d/b", "d/c"]
        let outcome = try await deleteTree(
            sending: keys, refused: keys,
            probes: [answer(Self.error("ObjectLockConfigurationNotFoundError"), status: 404)]
                + Array(repeating: answer(Self.error("InvalidRequest"), status: 400), count: 12))
        // The answer is the ordinary refusal: nothing established a lock.
        guard case .protocolError? = outcome.error else {
            Issue.record("expected the generic failure, got \(String(describing: outcome.error))")
            return
        }
        #expect(outcome.probeRequests == 1)
        // The positive control for the count: the batch really did carry four
        // refusals, so a one-key batch is not what was measured.
        #expect(keys.count == 4)
    }

    /// **The bucket's own lock state could not be read, and that does not buy
    /// an unbounded walk.** A read that failed establishes nothing, so a
    /// refused key is still worth asking about — but only the FIRST one. With
    /// the bucket's configuration unreadable and the first object's lock state
    /// uninformative, nothing distinguishes the five-hundredth key from the
    /// first, and the alternative is paying for 999 more answers that cannot
    /// improve the one message the user sees.
    ///
    /// One bucket read that fails, then one key probed (its hold and its
    /// retention, both uninformative): 3 requests for a batch of four
    /// refusals, not 9. And the reason says the lock state could not be read,
    /// so the record does not look like a bucket that simply has no lock.
    @Test func anUnreadableBucketLockStateProbesOnlyTheFirstRefusedKey() async throws {
        let keys = ["d/", "d/a", "d/b", "d/c"]
        let outcome = try await deleteTree(
            sending: keys, refused: keys,
            probes: [answer(Self.accessDenied, status: 403)]
                + Array(repeating: answer(Self.error("InvalidRequest"), status: 400), count: 12))
        guard case .protocolError(let reason)? = outcome.error else {
            Issue.record("expected the generic failure, got \(String(describing: outcome.error))")
            return
        }
        #expect(reason == S3FileSystem.deleteTreeRefusedWithUnreadableLockStateReason)
        #expect(reason != S3FileSystem.deleteTreeRefusedReason)
        #expect(outcome.probeRequests == 3)
        #expect(keys.count == 4)
    }

    /// The reason of a refused batch on a bucket the call COULD read: the
    /// plain one. The positive control for the test above, so that neither
    /// reason is the answer to every refusal.
    @Test func aBucketWhoseLockStateReadsGivesThePlainReason() async throws {
        let keys = ["d/", "d/a"]
        let outcome = try await deleteTree(
            sending: keys, refused: keys,
            probes: [answer(Self.error("ObjectLockConfigurationNotFoundError"), status: 404)])
        guard case .protocolError(let reason)? = outcome.error else {
            Issue.record("expected the generic failure, got \(String(describing: outcome.error))")
            return
        }
        #expect(reason == S3FileSystem.deleteTreeRefusedReason)
        #expect(outcome.probeRequests == 1)
    }

    /// The other half of the hoist: a bucket that DOES have Object Lock still
    /// gets its keys probed, and the first key under a hold settles the
    /// answer. One bucket read plus one `?legal-hold` — three requests fewer
    /// than the per-key shape spent reaching the same finding, and the
    /// finding is the same one.
    @Test func aBucketWithObjectLockStillNamesTheKeyUnderAHold() async throws {
        let outcome = try await deleteTree(
            sending: ["d/", "d/a", "d/b"], refused: ["d/a", "d/b"],
            probes: [
                answer(Self.lockDocument("<ObjectLockEnabled>Enabled</ObjectLockEnabled>")),
                answer(Self.holdDocument("ON")),
            ])
        #expect(outcome.error == .finding(.objectUnderLegalHold(path: "/d/a")))
        #expect(outcome.probeRequests == 2)
    }

    // MARK: - No way to switch Object Lock on

    /// Enabling Object Lock on an existing bucket is out of scope here (the
    /// maintainer asked for the lock at bucket creation; a retrofit was not
    /// asked for and cannot be undone), and the rig would let it through,
    /// accepting `PUT ?object-lock` on a bucket created without a lock. So
    /// the absence is a fact about macSCP's own surface that no test against
    /// the rig can show. The surface is read from the protocol's declaration;
    /// the positive checks beside the negative one are what keep the scan
    /// from going stale in silence.
    @Test func theProtocolOffersNoWayToEnableLockOnAnExistingBucket() throws {
        let surface = try S3BucketSettingsSurface.methodNames
        // Positive: the scan is reading the declaration. The seven real lock
        // methods are on it, and so are the other settings.
        for expected in [
            "hasObjectLock(ofBucket:)",
            "objectLockDefault(ofBucket:)",
            "setObjectLockDefault(days:mode:ofBucket:)",
            "retention(ofKey:inBucket:versionId:)",
            "setRetention(_:ofKey:inBucket:versionId:)",
            "legalHold(ofKey:inBucket:versionId:)",
            "setLegalHold(_:ofKey:inBucket:versionId:)",
            "versioning(ofBucket:)", "setCORS(_:ofBucket:)",
            "createBucket(_:protection:)",
        ] {
            #expect(surface.contains(expected), "\(expected) is not on the scanned surface")
        }
        // Negative: nothing on it enables a lock.
        let enabling = surface.filter {
            let name = $0.lowercased()
            return name.contains("enable") && name.contains("lock")
        }
        #expect(enabling.isEmpty, "\(enabling)")
    }

    /// The scan has to be seen to find a violation, or its silence means
    /// nothing: a planted declaration, and the shapes the real one uses.
    @Test func theSurfaceScanFindsAPlantedEnableMethodAndReadsLabels() {
        let planted = """
            public protocol S3BucketSettings: Sendable {
                func a(x: Int) async throws
                func enableObjectLock(ofBucket bucket: String) async throws
                func b<T>(_ value: T, with handler: (Int) -> [String: Int]) -> Int
            }
            public protocol Unrelated { func notOnTheSurface() }
            extension S3BucketSettings {
                func fromAnExtension(_ s: String, c d: [String: Int]) {
                    func localHelper() {}
                }
            }
            """
        #expect(
            S3BucketSettingsSurface.methodNames(inCode: planted) == [
                "a(x:)", "enableObjectLock(ofBucket:)", "b(_:with:)", "fromAnExtension(_:c:)",
            ])
    }
}
