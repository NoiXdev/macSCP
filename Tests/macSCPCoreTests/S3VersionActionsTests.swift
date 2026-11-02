import Foundation
import Testing

@testable import macSCPCore

/// `S3FileSystem`'s `ObjectVersionProvider` write half (`restore`,
/// `deleteVersion`, `liftDeleteMarker`) against the canned transport: the
/// request each call signs, what it reads back afterwards, and that a write
/// the history does not confirm is not reported as done. No network; the rig
/// half is a later task's.
///
/// Every body here is CONSTRUCTED. The history pages reuse the builders of
/// `S3ObjectVersionsTests` (`page`, `marker`, `ok`); an entry with a chosen
/// ETag is built here, because those builders fix theirs and the ETag is
/// exactly what a restore's read-back looks at.
@Suite("S3FileSystem version actions")
struct S3VersionActionsTests {
    // MARK: - Fixtures

    /// Two file MD5s, as an unquoted S3 ETag carries them.
    static let md5A = "5d41402abc4b2a76b9719d911017c592"
    static let md5B = "7d793037a0760186574b0282f2f435e7"
    /// Two composite (multipart) ETags with different part counts: what a
    /// large object's source version and its server-side copy can look like
    /// when the copy chose another chunking.
    static let compositeThreeParts = "9b2cf535f27731c974343645a3985328-3"
    static let compositeTwoParts = "0f6a1ca4d3c9d1b1b4c87e2c4b6c9a11-2"

    /// A stored version with the ETag a test chooses. Quoted, as S3 sends it.
    static func entry(
        _ id: String, latest: Bool, etag: String, key: String = "doc.txt"
    ) -> String {
        """
        <Version><Key>\(key)</Key><VersionId>\(id)</VersionId>
        <IsLatest>\(latest)</IsLatest><LastModified>2026-10-23T13:50:02.000Z</LastModified>
        <ETag>"\(etag)"</ETag><Size>12</Size></Version>
        """
    }

    static func history(_ entries: [String]) -> (Data, HTTPURLResponse) {
        S3ObjectVersionsTests.ok(S3ObjectVersionsTests.page(entries))
    }

    /// A real `CopyObjectResult`, which is what a successful copy answers.
    static let copied: (Data, HTTPURLResponse) = S3ObjectVersionsTests.ok(
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <CopyObjectResult><ETag>"\(md5A)"</ETag>\
            <LastModified>2026-10-23T14:00:00.000Z</LastModified></CopyObjectResult>
            """.utf8))

    static let noContent: (Data, HTTPURLResponse) = (
        Data(), S3SettingsFake.httpResponse(status: 204)
    )

    static func error(_ code: String, status: Int) -> (Data, HTTPURLResponse) {
        (
            Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code></Error>".utf8),
            S3SettingsFake.httpResponse(status: status)
        )
    }

    /// What the transport saw after `connect`'s own probe.
    static func sent(_ transport: FakeS3Transport) async -> [URLRequest] {
        await Array(transport.requests.dropFirst())
    }

    static func restoreUnconfirmed() -> RemoteFSError {
        .protocolError(reason: S3FileSystem.restoreUnconfirmedReason)
    }

    // MARK: - restore: the request

    @Test func restoringAnOldVersionIsReadBackAsTheNewCurrent() async throws {
        // Before: v2 is current, v1 is the one to bring back. After: a new
        // version v3 is current and carries v1's content (same MD5).
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
            Self.copied,
            Self.history([
                Self.entry("v3", latest: true, etag: Self.md5A),
                Self.entry("v2", latest: false, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
        ])
        try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")

        let sent = await Self.sent(transport)
        // The history is read, the copy is made, the history is read again.
        #expect(sent.map { $0.httpMethod ?? "" } == ["GET", "PUT", "GET"])
        let copy = try #require(sent.dropFirst().first)
        #expect(copy.url?.path == "/b/doc.txt")
        // The version id names the SOURCE only: the destination is a plain
        // key, so the store writes a new version of it.
        #expect(copy.url?.query == nil)
        #expect(copy.value(forHTTPHeaderField: "x-amz-copy-source") == "/b/doc.txt?versionId=v1")
        // The copy source travels as a SIGNED header: an unsigned one is a
        // signature mismatch at the store.
        let authorization = try #require(copy.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("x-amz-copy-source"))
    }

    /// The copy source is the key encoded as a path, then `?versionId=` and
    /// the id encoded as a query value: each exactly once, and the suffix
    /// added AFTER the key is encoded. Spelled out rather than computed, so
    /// the assertion does not call the code it checks. Encoding the whole
    /// string as one path would turn the `?` and `=` into `%3F` and `%3D`,
    /// and the store would read them as part of the key's name.
    @Test(arguments: [
        ("doc.txt", "v1", "/b/doc.txt?versionId=v1"),
        ("dir/a b+c.txt", S3ObjectVersionsTests.tokenVersionIdMarker,
         "/b/dir/a%20b%2Bc.txt?versionId=dG9rZW4%2B%2Fx%3D%3D"),
        ("what?.txt", "v1", "/b/what%3F.txt?versionId=v1"),
    ])
    func theCopySourceEncodesTheKeyAndTheVersionIdEachOnceAndKeepsTheirSeparator(
        key: String, versionId: String, expected: String
    ) async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v9", latest: true, etag: Self.md5B, key: key),
                Self.entry(versionId, latest: false, etag: Self.md5A, key: key),
            ]),
            Self.copied,
            Self.history([
                Self.entry("v10", latest: true, etag: Self.md5A, key: key),
                Self.entry("v9", latest: false, etag: Self.md5B, key: key),
                Self.entry(versionId, latest: false, etag: Self.md5A, key: key),
            ]),
        ])
        try await fs.restore(key: key, inBucket: "b", toVersionId: versionId)
        let copy = try #require(await Self.sent(transport).dropFirst().first)
        #expect(copy.httpMethod == "PUT")
        let header = copy.value(forHTTPHeaderField: "x-amz-copy-source")
        #expect(header == expected)
        // The separator is a real `?`: it survived the key's encoding.
        let separatorSurvived = header?.contains("?versionId=") == true
        #expect(separatorSurvived)
    }

    // MARK: - restore: what counts as confirmed

    @Test func aRestoreThatProducedNoNewCurrentVersionIsNotReportedAsDone() async throws {
        // The copy answered like a success, and the history afterwards is the
        // history from before: v2 is still the current one. v2 carries the
        // SAME content as v1 here on purpose, so the content comparison alone
        // would be satisfied and only the requirement of a NEW current
        // version can refuse it.
        let before = [
            Self.entry("v2", latest: true, etag: Self.md5A),
            Self.entry("v1", latest: false, etag: Self.md5A),
        ]
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history(before), Self.copied, Self.history(before),
        ])
        await #expect(throws: Self.restoreUnconfirmed()) {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
        }
        // The read-back really happened: the failure is a verdict on what it
        // saw, not a short-circuit.
        #expect(await Self.sent(transport).count == 3)
    }

    @Test func aRestoreWhoseNewCurrentVersionHasOtherContentIsNotReportedAsDone() async throws {
        // The source is a plain file (a file MD5), so a correct copy must
        // carry the same MD5. A new current version with another one is not
        // the restored content.
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
            Self.copied,
            Self.history([
                Self.entry("v3", latest: true, etag: Self.md5B),
                Self.entry("v2", latest: false, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
        ])
        await #expect(throws: Self.restoreUnconfirmed()) {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
        }
    }

    @Test func aRestoreWhoseNewCurrentEntryIsADeleteMarkerIsNotReportedAsDone() async throws {
        // A restore writes a VERSION. A marker on top is somebody else's
        // delete that raced the copy: new, and current, and not the content.
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
            Self.copied,
            Self.history([
                S3ObjectVersionsTests.marker("doc.txt", "m1", latest: true),
                Self.entry("v2", latest: false, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
        ])
        await #expect(throws: Self.restoreUnconfirmed()) {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
        }
    }

    /// **Why the evidence differs by the source's ETag.** A single-part
    /// object's ETag IS the MD5 of its bytes, so a copy of it must reproduce
    /// the ETag and the content is checkable against the source. A multipart
    /// object's ETag is an MD5 over the PARTS' MD5s with `-N` appended, so it
    /// depends on the chunking, and a server-side copy is free to chunk
    /// differently: a correct copy of a large file need not match its source.
    /// Requiring equality there would report a correct restore as unconfirmed
    /// and the user would retry it, making a second copy. For a source that
    /// is not a file MD5 the confirmation is therefore the weaker pair: a new
    /// current version that is not a delete marker and is not the version
    /// restored from. The two paths rest on different evidence on purpose.
    @Test func aMultipartSourceIsConfirmedByANewCurrentVersionEvenWhenTheCompositeDiffers() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.compositeThreeParts),
            ]),
            Self.copied,
            Self.history([
                Self.entry("v3", latest: true, etag: Self.compositeTwoParts),
                Self.entry("v2", latest: false, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.compositeThreeParts),
            ]),
        ])
        // No throw: a correct restore of a large file is reported as done.
        try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
    }

    @Test func aMultipartSourceWithNoNewCurrentVersionIsStillNotReportedAsDone() async throws {
        // The positive control for the test above: relaxing the content
        // comparison did not relax the requirement of a NEW current version.
        let before = [
            Self.entry("v2", latest: true, etag: Self.md5B),
            Self.entry("v1", latest: false, etag: Self.compositeThreeParts),
        ]
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.history(before), Self.copied, Self.history(before),
        ])
        await #expect(throws: Self.restoreUnconfirmed()) {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
        }
    }

    @Test func aSourceWhoseETagIsNotAChecksumIsConfirmedByANewCurrentVersion() async throws {
        // Some stores put opaque text where the ETag goes. There is nothing to
        // compare, so the weaker pair applies -- and still needs a new current.
        let opaque = "not-a-digest"
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: opaque),
            ]),
            Self.copied,
            Self.history([
                Self.entry("v3", latest: true, etag: "another-opaque-value"),
                Self.entry("v2", latest: false, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: opaque),
            ]),
        ])
        try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
    }

    @Test func aCopyThatAnswers200WithAnErrorBodyIsNotASuccessfulRestore() async throws {
        // S3 can answer a server-side copy with `200 OK` and an `<Error>` in
        // the body when the copy fails partway through. Reporting that as a
        // restore would tell the user their old version is back when it is
        // not.
        let failedMidway = S3ObjectVersionsTests.ok(
            Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>
                """.utf8))
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
            failedMidway,
        ])
        var failure: RemoteFSError?
        do {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
        } catch let error as RemoteFSError {
            failure = error
        }
        guard case .protocolError(let reason)? = failure else {
            Issue.record("expected a .protocolError from the failed copy, got \(String(describing: failure))")
            return
        }
        #expect(reason.hasPrefix("S3 copy failed"))
        // It is the COPY's failure that surfaced, not the read-back's: no
        // history was read after it (the canned set holds no third answer, so
        // a read-back would have failed differently).
        #expect(await Self.sent(transport).map { $0.httpMethod ?? "" } == ["GET", "PUT"])
    }

    // MARK: - restore: what it refuses before it writes

    @Test func restoringAVersionTheHistoryDoesNotHoldWritesNothing() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([Self.entry("v2", latest: true, etag: Self.md5B)])
        ])
        await #expect(throws: RemoteFSError.notFound(path: "/doc.txt")) {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v-missing")
        }
        // Positive half: the history WAS read, and nothing but that read left.
        #expect(await Self.sent(transport).map { $0.httpMethod ?? "" } == ["GET"])
    }

    @Test func aDeleteMarkerCannotBeRestoredFrom() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([
                S3ObjectVersionsTests.marker("doc.txt", "m1", latest: true),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ])
        ])
        var failure: RemoteFSError?
        do {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "m1")
        } catch let error as RemoteFSError {
            failure = error
        }
        guard case .protocolError? = failure else {
            Issue.record("expected a .protocolError, got \(String(describing: failure))")
            return
        }
        #expect(await Self.sent(transport).map { $0.httpMethod ?? "" } == ["GET"])
    }

    // MARK: - deleteVersion

    /// The header that lets a GOVERNANCE retention be shortened or deleted
    /// through. macSCP never sends it (spec section 6.2), so a version under
    /// retention stays refused.
    static let bypassHeader = "x-amz-bypass-governance-retention"

    @Test func deletingAVersionUnderRetentionIsRefusedWithoutABypassHeader() async throws {
        let farFuture = S3ObjectVersionsTests.ok(
            Data(
                """
                <Retention><Mode>GOVERNANCE</Mode>\
                <RetainUntilDate>2999-01-01T00:00:00.000Z</RetainUntilDate></Retention>
                """.utf8))
        let noHold = S3ObjectVersionsTests.ok(
            Data("<LegalHold><Status>OFF</Status></LegalHold>".utf8))
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.error("AccessDenied", status: 403), noHold, farFuture,
        ])
        await #expect(throws: RemoteFSError.finding(.objectUnderRetention(path: "/doc.txt"))) {
            try await fs.deleteVersion(ofKey: "doc.txt", inBucket: "b", versionId: "v1")
        }

        // The assertion is on the requests this built, not on a store's
        // answer. `#require` first, so an empty set fails loudly instead of
        // running an absence check over nothing.
        let sent = await Self.sent(transport)
        let delete = try #require(sent.first)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path == "/b/doc.txt")
        #expect(delete.url?.query == "versionId=v1")

        // Accessor: `URLRequest.value(forHTTPHeaderField:)`, which matches a
        // header NAME case-insensitively. Subscripting `allHTTPHeaderFields`
        // does not, so an absence read through it would pass for a header
        // spelled in another case. Chosen on purpose, and used for the
        // presence checks and the absence check alike.
        //
        // Positive controls, through the SAME accessor, before its `nil` is
        // believed: a header that must be present is found, and the bypass
        // name itself resolves when a request carries it, in another case.
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != nil })
        var control = URLRequest(url: try #require(URL(string: "http://127.0.0.1:9000/control")))
        control.setValue("true", forHTTPHeaderField: Self.bypassHeader)
        let accessorResolvesTheName =
            control.value(forHTTPHeaderField: Self.bypassHeader.uppercased()) == "true"
        #expect(accessorResolvesTheName)

        let carriers = sent.filter { $0.value(forHTTPHeaderField: Self.bypassHeader) != nil }
        #expect(carriers.isEmpty)
    }

    @Test func aVersionThatLeftTheHistoryIsDeleted() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.noContent,
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B)
            ]),
        ])
        try await fs.deleteVersion(ofKey: "doc.txt", inBucket: "b", versionId: "v1")
        let sent = await Self.sent(transport)
        #expect(sent.map { $0.httpMethod ?? "" } == ["DELETE", "GET"])
        let delete = try #require(sent.first)
        #expect(delete.url?.path == "/b/doc.txt")
        #expect(delete.url?.query == "versionId=v1")
        let authorization = try #require(delete.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256"))
    }

    @Test func aVersionIdIsEncodedOnceOnTheDeleteRequest() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.noContent, Self.history([]),
        ])
        try await fs.deleteVersion(
            ofKey: "dir/a b.txt", inBucket: "b", versionId: S3ObjectVersionsTests.tokenVersionIdMarker)
        let delete = try #require(await Self.sent(transport).first)
        let query = try #require(delete.url?.query(percentEncoded: true))
        #expect(query == "versionId=" + S3ObjectVersionsTests.tokenVersionIdMarkerOnTheWire)
        #expect(delete.url?.path(percentEncoded: true) == "/b/dir/a%20b.txt")
    }

    @Test func aDeleteThatLeavesTheVersionInTheHistoryIsNotReportedAsDone() async throws {
        // The store answered 204, and the history still lists v1.
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.noContent,
            Self.history([
                Self.entry("v2", latest: true, etag: Self.md5B),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
        ])
        await #expect(
            throws: RemoteFSError.protocolError(reason: S3FileSystem.deleteVersionUnconfirmedReason)
        ) {
            try await fs.deleteVersion(ofKey: "doc.txt", inBucket: "b", versionId: "v1")
        }
        #expect(await Self.sent(transport).count == 2)
    }

    // MARK: - liftDeleteMarker

    @Test func liftingAMarkerIsOneDeleteOfThatMarkersVersionId() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([
                S3ObjectVersionsTests.marker("doc.txt", "m1", latest: true),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ]),
            Self.noContent,
            Self.history([Self.entry("v1", latest: true, etag: Self.md5A)]),
        ])
        try await fs.liftDeleteMarker(ofKey: "doc.txt", inBucket: "b", markerVersionId: "m1")

        let sent = await Self.sent(transport)
        // ONE delete among the reads around it, and it names the marker.
        #expect(sent.map { $0.httpMethod ?? "" } == ["GET", "DELETE", "GET"])
        let deletes = sent.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 1)
        let delete = try #require(deletes.first)
        #expect(delete.url?.path == "/b/doc.txt")
        #expect(delete.url?.query == "versionId=m1")
    }

    @Test func aVersionIsNotLiftedLikeAMarker() async throws {
        // `v1` holds content. Lifting it as if it were a marker would delete
        // data permanently, so nothing is deleted.
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([
                S3ObjectVersionsTests.marker("doc.txt", "m1", latest: true),
                Self.entry("v1", latest: false, etag: Self.md5A),
            ])
        ])
        var failure: RemoteFSError?
        do {
            try await fs.liftDeleteMarker(ofKey: "doc.txt", inBucket: "b", markerVersionId: "v1")
        } catch let error as RemoteFSError {
            failure = error
        }
        guard case .protocolError? = failure else {
            Issue.record("expected a .protocolError, got \(String(describing: failure))")
            return
        }
        #expect(await Self.sent(transport).map { $0.httpMethod ?? "" } == ["GET"])
    }

    @Test func aMarkerTheHistoryDoesNotHoldIsNotLifted() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history([Self.entry("v1", latest: true, etag: Self.md5A)])
        ])
        await #expect(throws: RemoteFSError.notFound(path: "/doc.txt")) {
            try await fs.liftDeleteMarker(ofKey: "doc.txt", inBucket: "b", markerVersionId: "m-missing")
        }
        #expect(await Self.sent(transport).map { $0.httpMethod ?? "" } == ["GET"])
    }

    @Test func aMarkerThatIsStillListedAfterTheDeleteIsNotReportedAsLifted() async throws {
        let stillThere = [
            S3ObjectVersionsTests.marker("doc.txt", "m1", latest: true),
            Self.entry("v1", latest: false, etag: Self.md5A),
        ]
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.history(stillThere), Self.noContent, Self.history(stillThere),
        ])
        await #expect(
            throws: RemoteFSError.protocolError(reason: S3FileSystem.liftDeleteMarkerUnconfirmedReason)
        ) {
            try await fs.liftDeleteMarker(ofKey: "doc.txt", inBucket: "b", markerVersionId: "m1")
        }
        #expect(await Self.sent(transport).count == 3)
    }

    // MARK: - An empty key

    /// An empty key addresses the bucket itself, and a `DELETE` of the bucket
    /// root is not a version delete. Refused before any request is built.
    @Test func noWriteIsSentForAnEmptyKey() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [])
        for write in [
            { try await fs.restore(key: "", inBucket: "b", toVersionId: "v1") },
            { try await fs.deleteVersion(ofKey: "", inBucket: "b", versionId: "v1") },
            { try await fs.liftDeleteMarker(ofKey: "", inBucket: "b", markerVersionId: "m1") },
        ] as [@Sendable () async throws -> Void] {
            var failure: RemoteFSError?
            do { try await write() } catch let error as RemoteFSError { failure = error }
            guard case .protocolError? = failure else {
                Issue.record("expected a .protocolError, got \(String(describing: failure))")
                continue
            }
        }
        // Positive half: the connection's own probe is the only request.
        #expect(await transport.requests.count == 1)
    }
}
