import Foundation
import Testing

@testable import macSCPCore

/// `S3FileSystem`'s `ObjectMetadataProvider` conformance against the canned
/// transport: the request each call BUILDS (asserted on the `URLRequest`
/// the transport recorded), what it reads back afterwards, and that a write
/// the store's own answer does not confirm is not reported as done. No
/// network; the rig half is a later task's.
@Suite("S3FileSystem object metadata", .timeLimit(.minutes(5)))
struct S3ObjectMetadataTests {
    // MARK: - Fixtures

    static let bucket = "macscp-seed"

    /// A `HEAD` answer carrying `headers`, which `S3SettingsFake.httpResponse`
    /// cannot (it passes `nil` header fields).
    static func head(
        _ headers: [String: String], status: Int = 200
    ) -> (Data, HTTPURLResponse) {
        (
            Data(),
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:9000/other")!,
                statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        )
    }

    static let copied: (Data, HTTPURLResponse) = (
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <CopyObjectResult><ETag>"5d41402abc4b2a76b9719d911017c592"</ETag>\
            <LastModified>2026-11-03T14:00:00.000Z</LastModified></CopyObjectResult>
            """.utf8),
        S3SettingsFake.httpResponse(status: 200)
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

    static let wanted = ObjectMetadata(
        contentType: "text/markdown", cacheControl: "max-age=60",
        contentDisposition: "attachment; filename=\"a.md\"",
        custom: ["note": "set-by-test", "owner-team": "docs"], entityTag: nil)

    /// The `HEAD` headers a store would report for `wanted`.
    static let wantedHeaders: [String: String] = [
        "Content-Type": "text/markdown", "Cache-Control": "max-age=60",
        "Content-Disposition": "attachment; filename=\"a.md\"",
        "x-amz-meta-note": "set-by-test", "x-amz-meta-owner-team": "docs",
        "ETag": "\"5d41402abc4b2a76b9719d911017c592\"",
    ]

    /// The lower-cased names of the `x-amz-meta-*` headers a built request
    /// carries: what its custom pairs imply, read off the request itself.
    static func customHeaderNames(of request: URLRequest) -> Set<String> {
        Set(
            (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
                .filter { $0.hasPrefix("x-amz-meta-") })
    }

    // MARK: - Reading

    @Test func aHeadResponseBecomesMetadataWithTheEntityTagAsReceived() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.head(Self.wantedHeaders)])

        let metadata = try await fs.metadata(ofKey: "docs/a.md", inBucket: Self.bucket)

        #expect(metadata.contentType == "text/markdown")
        #expect(metadata.cacheControl == "max-age=60")
        #expect(metadata.contentDisposition == "attachment; filename=\"a.md\"")
        #expect(metadata.entityTag == "\"5d41402abc4b2a76b9719d911017c592\"")
        let request = try #require(await Self.sent(transport).first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.path == "/macscp-seed/docs/a.md")
        #expect(request.url?.query == nil)
    }

    /// The real counterpart of `ObjectMetadataProviderTests`'s
    /// `customMetadataKeysCarryNoTransportPrefix`, which checks its own
    /// literal input and cannot fail. This one reads the boundary.
    @Test func theTransportPrefixIsStrippedFromCustomKeysWhenAnAnswerIsRead() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.head(["x-amz-meta-note": "hello"])
        ])

        let metadata = try await fs.metadata(ofKey: "a.txt", inBucket: Self.bucket)

        #expect(metadata.custom["note"] == "hello")
        let carriesPrefix = metadata.custom.keys.contains { $0.hasPrefix("x-amz-meta-") }
        #expect(carriesPrefix == false)
        #expect(metadata.custom.count == 1)
    }

    @Test func aCustomKeyIsReadWhateverCaseTheStoreSpellsItsHeaderIn() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.head(["X-Amz-Meta-Note": "hello"])
        ])

        let metadata = try await fs.metadata(ofKey: "a.txt", inBucket: Self.bucket)

        #expect(metadata.custom == ["note": "hello"])
    }

    @Test func headersThatAreNotCustomMetadataAreNotReadAsIt() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.head([
                "x-amz-request-id": "abc", "x-amz-version-id": "v1", "Content-Length": "12",
                "x-amz-meta-": "no-name",
            ])
        ])

        let metadata = try await fs.metadata(ofKey: "a.txt", inBucket: Self.bucket)

        #expect(metadata.custom.isEmpty)
        #expect(metadata.contentType == nil)
        #expect(metadata.cacheControl == nil)
        #expect(metadata.contentDisposition == nil)
    }

    @Test func aMissingObjectIsNotFoundAtTheCallersPath() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [Self.head([:], status: 404)])

        await #expect(throws: RemoteFSError.notFound(path: "/macscp-seed/gone.txt")) {
            _ = try await fs.metadata(ofKey: "gone.txt", inBucket: Self.bucket)
        }
    }

    @Test func anEmptyKeyIsRefusedAndNothingIsSent() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [])

        await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.metadataKeyRequiredReason)) {
            _ = try await fs.metadata(ofKey: "", inBucket: Self.bucket)
        }
        await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.metadataKeyRequiredReason)) {
            try await fs.setMetadata(Self.wanted, ofKey: "", inBucket: Self.bucket)
        }
        await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.metadataKeyRequiredReason)) {
            _ = try await fs.acl(ofKey: "", inBucket: Self.bucket)
        }
        #expect(await Self.sent(transport).isEmpty)
    }

    // MARK: - Writing: the built request

    @Test func replacingMetadataSendsTheReplaceDirectiveAndTheFourFields() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(Self.wantedHeaders),
        ])

        try await fs.setMetadata(Self.wanted, ofKey: "docs/a b.md", inBucket: Self.bucket)

        let requests = await Self.sent(transport)
        let put = try #require(requests.first)
        #expect(put.httpMethod == "PUT")
        #expect(put.value(forHTTPHeaderField: "x-amz-metadata-directive") == "REPLACE")
        #expect(put.value(forHTTPHeaderField: "x-amz-copy-source") == "/macscp-seed/docs/a%20b.md")
        #expect(put.value(forHTTPHeaderField: "content-type") == "text/markdown")
        #expect(put.value(forHTTPHeaderField: "cache-control") == "max-age=60")
        #expect(
            put.value(forHTTPHeaderField: "content-disposition") == "attachment; filename=\"a.md\"")
        #expect(put.value(forHTTPHeaderField: "x-amz-meta-note") == "set-by-test")
        #expect(put.value(forHTTPHeaderField: "x-amz-meta-owner-team") == "docs")
        // The copy source names the SAME key the request is addressed to.
        #expect(put.url?.path == "/macscp-seed/docs/a b.md")
        // Signed, not merely set: an unsigned x-amz-* header is a signature
        // mismatch at a real store.
        let authorization = try #require(put.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("x-amz-metadata-directive"))
        #expect(authorization.contains("x-amz-copy-source"))
        #expect(authorization.contains("x-amz-meta-note"))
    }

    @Test func aFieldLeftNilIsNotSentSoTheReplaceDropsIt() async throws {
        let bare = ObjectMetadata(
            contentType: "text/plain", cacheControl: nil, contentDisposition: nil, custom: [:],
            entityTag: nil)
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(["Content-Type": "text/plain"]),
        ])

        try await fs.setMetadata(bare, ofKey: "a.txt", inBucket: Self.bucket)

        let put = try #require(await Self.sent(transport).first)
        #expect(put.value(forHTTPHeaderField: "cache-control") == nil)
        #expect(put.value(forHTTPHeaderField: "content-disposition") == nil)
        #expect(Self.customHeaderNames(of: put).isEmpty)
        #expect(put.value(forHTTPHeaderField: "x-amz-metadata-directive") == "REPLACE")
    }

    /// Exact, not "not doubled": the custom headers on the wire are the pairs
    /// given, prefixed once, lower-cased, and nothing more or less.
    @Test func theCustomHeadersOnTheWireAreExactlyThePairsGivenPrefixedOnce() async throws {
        let pairs = ObjectMetadata(
            contentType: nil, cacheControl: nil, contentDisposition: nil,
            custom: ["note": "x", "Owner-Team": "y", "k.v": "z"], entityTag: nil)
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(["x-amz-meta-note": "x", "x-amz-meta-owner-team": "y", "x-amz-meta-k.v": "z"]),
        ])

        try await fs.setMetadata(pairs, ofKey: "a.txt", inBucket: Self.bucket)

        let put = try #require(await Self.sent(transport).first)
        #expect(
            Self.customHeaderNames(of: put)
                == ["x-amz-meta-note", "x-amz-meta-owner-team", "x-amz-meta-k.v"])
        #expect(put.value(forHTTPHeaderField: "x-amz-meta-owner-team") == "y")
    }

    /// `ObjectMetadata.custom` says its keys carry no transport prefix. A key
    /// that does is refused before anything is sent, in any case, and the
    /// refusal does not carry the key.
    @Test func aCustomKeyThatAlreadyCarriesTheTransportPrefixIsRefusedAndNothingIsSent() async throws {
        let prefixedKeys = ["x-amz-meta-note", "X-Amz-Meta-note", "X-AMZ-META-"]
        for key in prefixedKeys {
            let metadata = ObjectMetadata(
                contentType: nil, cacheControl: nil, contentDisposition: nil,
                custom: [key: "v"], entityTag: nil)
            let (fs, transport) = try await S3SettingsFake.connect(responses: [])
            var thrown: RemoteFSError?
            do {
                try await fs.setMetadata(metadata, ofKey: "a.txt", inBucket: Self.bucket)
            } catch let error as RemoteFSError {
                thrown = error
            }
            #expect(thrown == RemoteFSError.protocolError(reason: S3FileSystem.metadataFieldRefusedReason))
            let reasonCarriesKey = S3FileSystem.metadataFieldRefusedReason.lowercased().contains(key.lowercased())
            #expect(reasonCarriesKey == false)
            #expect(await Self.sent(transport).isEmpty)
        }
    }

    @Test func aFieldThatCouldBreakTheHeaderBlockIsRefusedAndNothingIsSent() async throws {
        let hostile: [ObjectMetadata] = [
            ObjectMetadata(
                contentType: "text/plain\r\nx-injected: x", cacheControl: nil, contentDisposition: nil,
                custom: [:], entityTag: nil),
            ObjectMetadata(
                contentType: nil, cacheControl: nil, contentDisposition: nil,
                custom: ["bad name": "v"], entityTag: nil),
            ObjectMetadata(
                contentType: nil, cacheControl: nil, contentDisposition: nil,
                custom: ["": "v"], entityTag: nil),
            ObjectMetadata(
                contentType: nil, cacheControl: nil, contentDisposition: nil,
                custom: ["k": "a\nb"], entityTag: nil),
        ]
        for metadata in hostile {
            let (fs, transport) = try await S3SettingsFake.connect(responses: [])
            await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.metadataFieldRefusedReason)) {
                try await fs.setMetadata(metadata, ofKey: "a.txt", inBucket: Self.bucket)
            }
            #expect(await Self.sent(transport).isEmpty)
        }
    }

    // MARK: - Writing: read back, never assumed from a 200

    @Test func theWriteIsReadBackWithASecondHeadAfterTheCopy() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(Self.wantedHeaders),
        ])

        try await fs.setMetadata(Self.wanted, ofKey: "docs/a.md", inBucket: Self.bucket)

        let requests = await Self.sent(transport)
        #expect(requests.map(\.httpMethod) == ["PUT", "HEAD"])
        #expect(requests[1].url?.path == "/macscp-seed/docs/a.md")
    }

    /// The store answers `200` to the copy and the second `HEAD` disagrees.
    @Test func metadataThatCannotBeReadBackIsNotReportedAsWritten() async throws {
        var stale = Self.wantedHeaders
        stale["Content-Type"] = "application/octet-stream"
        let (fs, _) = try await S3SettingsFake.connect(responses: [Self.copied, Self.head(stale)])

        await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.setMetadataUnconfirmedReason)) {
            try await fs.setMetadata(Self.wanted, ofKey: "docs/a.md", inBucket: Self.bucket)
        }
    }

    @Test func eachFieldTheReadBackLacksOrAltersIsAnUnconfirmedWrite() async throws {
        var noCache = Self.wantedHeaders
        noCache["Cache-Control"] = nil
        var noCustom = Self.wantedHeaders
        noCustom["x-amz-meta-note"] = nil
        var extraCustom = Self.wantedHeaders
        extraCustom["x-amz-meta-extra"] = "kept-from-before"
        var otherDisposition = Self.wantedHeaders
        otherDisposition["Content-Disposition"] = "inline"
        var otherValue = Self.wantedHeaders
        otherValue["x-amz-meta-note"] = "something-else"

        for readBack in [noCache, noCustom, extraCustom, otherDisposition, otherValue] {
            let (fs, _) = try await S3SettingsFake.connect(responses: [Self.copied, Self.head(readBack)])
            await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.setMetadataUnconfirmedReason)) {
                try await fs.setMetadata(Self.wanted, ofKey: "docs/a.md", inBucket: Self.bucket)
            }
        }
    }

    /// The second way the read-back can leave the write unconfirmed: the
    /// `HEAD` **fails** instead of answering and disagreeing.
    ///
    /// The three cases above all feed a `HEAD` that answers. This one feeds
    /// one that does not, after a copy the store has already answered `200`
    /// with a `<CopyObjectResult>` — so the write HAPPENED, and on a
    /// versioned bucket a version now exists. Until 2026-11-04 the read's own
    /// error came out of `setMetadata` unchanged:
    /// `UnconfirmedMetadataWrite.describes` returns false for it, so the
    /// App's sheet showed "The change could not be saved." about a change the
    /// storage had taken. Both ways out of the read-back are the same news to
    /// a caller — accepted, not confirmed — and neither is a write that
    /// failed.
    @Test func aReadBackThatFailsAfterAnAcceptedCopyIsAnUnconfirmedWrite() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head([:], status: 500),
        ])

        var thrown: (any Error)?
        do {
            try await fs.setMetadata(Self.wanted, ofKey: "docs/a.md", inBucket: Self.bucket)
        } catch {
            thrown = error
        }
        // The error the App asks about by name. Anything else — including the
        // read's own `.finding(.unexpectedStatus(code: 500))`, which is what
        // this threw before — lands on the generic sentence.
        let reportedAsUnconfirmed = thrown.map { UnconfirmedMetadataWrite.describes($0) } ?? false
        #expect(reportedAsUnconfirmed)
        // The control: both requests really were sent, so there was an
        // accepted write for the read-back to fail after.
        let methods = await Self.sent(transport).map(\.httpMethod)
        #expect(methods == ["PUT", "HEAD"])
    }

    /// Spec section 4.5: the new version's ETag is IDENTICAL to the one it was
    /// copied from, the bytes being unchanged. A read-back that expected the
    /// tag to change would fail every real write.
    @Test func anUnchangedEntityTagDoesNotMakeTheWriteUnconfirmed() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(Self.wantedHeaders),
        ])

        try await fs.setMetadata(Self.wanted, ofKey: "docs/a.md", inBucket: Self.bucket)
    }

    @Test func aContentTypeLeftNilIsNotComparedBecauseAStoreMayAssignOne() async throws {
        let noType = ObjectMetadata(
            contentType: nil, cacheControl: nil, contentDisposition: nil, custom: [:], entityTag: nil)
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(["Content-Type": "application/octet-stream"]),
        ])

        try await fs.setMetadata(noType, ofKey: "a.txt", inBucket: Self.bucket)
    }

    @Test func aCopyThatAnswers200WithAnErrorBodyIsNotAWrite() async throws {
        let lying = (
            Data("<Error><Code>InternalError</Code></Error>".utf8),
            S3SettingsFake.httpResponse(status: 200)
        )
        let (fs, transport) = try await S3SettingsFake.connect(responses: [lying])

        do {
            try await fs.setMetadata(Self.wanted, ofKey: "docs/a.md", inBucket: Self.bucket)
            Issue.record("a 200 with an Error body was accepted as a write")
        } catch RemoteFSError.protocolError {
        } catch {
            Issue.record("expected .protocolError, got \(error)")
        }
        // No read-back is attempted after a copy that did not happen.
        #expect(await Self.sent(transport).count == 1)
    }

    // MARK: - Non-ASCII custom values: encoded on the wire, decoded on the way back

    /// A value with one non-ASCII scalar (u with diaeresis), spelled by escape
    /// so the file itself stays ASCII. Its UTF-8 bytes are 4D C3 BC 6C 6C 65 72.
    static let typedNonASCII = "M\u{00FC}ller"
    /// The same value as the store returns it after an encoded write.
    static let typedNonASCIIAsEncodedWord = "=?UTF-8?B?TcO8bGxlcg==?="

    private static func noteOnly(_ value: String) -> ObjectMetadata {
        ObjectMetadata(
            contentType: nil, cacheControl: nil, contentDisposition: nil,
            custom: ["note": value], entityTag: nil)
    }

    /// The point of the whole change: a raw non-ASCII byte in a signed header
    /// is what made the store answer `SignatureDoesNotMatch`. Every
    /// expectation here is a precomputed `Bool`, because the report of a
    /// failed expectation prints the value it evaluated, and the value under
    /// test carries the non-ASCII this test is about.
    @Test func aNonASCIICustomValueIsSentAsAnEncodedWord() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(["x-amz-meta-note": Self.typedNonASCIIAsEncodedWord]),
        ])

        try await fs.setMetadata(
            Self.noteOnly(Self.typedNonASCII), ofKey: "a.txt", inBucket: Self.bucket)

        let put = try #require(await Self.sent(transport).first)
        let sent = try #require(put.value(forHTTPHeaderField: "x-amz-meta-note"))
        let isASCII = sent.unicodeScalars.allSatisfy { $0.value < 0x80 }
        let isTheEncodedWord = sent == Self.typedNonASCIIAsEncodedWord
        #expect(isASCII)
        #expect(isTheEncodedWord)
        // Signed with that header, which is what makes the store agree.
        let authorization = try #require(put.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("x-amz-meta-note"))
    }

    @Test func anEncodedWordInTheHeadAnswerReachesTheCallerDecoded() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.head(["x-amz-meta-note": Self.typedNonASCIIAsEncodedWord])
        ])

        let metadata = try await fs.metadata(ofKey: "a.txt", inBucket: Self.bucket)

        let decodedToTheTypedText = metadata.custom["note"] == Self.typedNonASCII
        #expect(decodedToTheTypedText)
        #expect(metadata.custom.count == 1)
    }

    /// A store (or another tool) that kept raw bytes: what it answers is what
    /// the caller gets, untouched.
    @Test func aRawNonASCIIValueInTheHeadAnswerReachesTheCallerUnchanged() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.head(["x-amz-meta-note": Self.typedNonASCII])
        ])

        let metadata = try await fs.metadata(ofKey: "a.txt", inBucket: Self.bucket)

        let unchanged = metadata.custom["note"] == Self.typedNonASCII
        #expect(unchanged)
    }

    /// What the person sees: the write is confirmed. The store answers the
    /// read-back with the ENCODED word, which is what rustfs was measured
    /// returning, and the comparison finds it equal to what was typed.
    @Test func aNonASCIIValueWrittenAndReadBackIsConfirmed() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(["x-amz-meta-note": Self.typedNonASCIIAsEncodedWord]),
        ])

        try await fs.setMetadata(
            Self.noteOnly(Self.typedNonASCII), ofKey: "a.txt", inBucket: Self.bucket)

        let methods = await Self.sent(transport).map(\.httpMethod)
        #expect(methods == ["PUT", "HEAD"])
    }

    /// The control that keeps the confirmation honest: a read-back that holds
    /// some OTHER text is still an unconfirmed write, decoded or not.
    @Test func aReadBackHoldingOtherTextThanWasTypedIsStillUnconfirmed() async throws {
        let other = "=?UTF-8?B?TcO8bGxlcnM=?="
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            Self.copied, Self.head(["x-amz-meta-note": other]),
        ])

        await #expect(throws: RemoteFSError.protocolError(reason: S3FileSystem.setMetadataUnconfirmedReason)) {
            try await fs.setMetadata(
                Self.noteOnly(Self.typedNonASCII), ofKey: "a.txt", inBucket: Self.bucket)
        }
    }

    // MARK: - Writing: a refusal for size is the store's own

    /// Spec section 4.10 measured a single-part copy of 8 MiB and nothing
    /// above it. A store that refuses a larger one says so, and that refusal
    /// is what the caller gets: nothing retries it as a multipart copy.
    @Test func aCopyTheStoreRefusesForSizeSurfacesItsOwnRefusal() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            Self.error("EntityTooLarge", status: 400)
        ])

        await #expect(throws: RemoteFSError.finding(.unexpectedStatus(code: 400))) {
            try await fs.setMetadata(Self.wanted, ofKey: "big.bin", inBucket: Self.bucket)
        }

        let requests = await Self.sent(transport)
        #expect(requests.count == 1)
        #expect(requests.map(\.httpMethod) == ["PUT"])
        let multipart = requests.contains { request in
            let query = request.url?.query ?? ""
            return query.contains("uploads") || query.contains("partNumber")
        }
        #expect(multipart == false)
    }

    @Test func aRefusedCopyIsReportedAtTheCallersPath() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [Self.error("NoSuchKey", status: 404)])

        await #expect(throws: RemoteFSError.notFound(path: "/macscp-seed/gone.txt")) {
            try await fs.setMetadata(Self.wanted, ofKey: "gone.txt", inBucket: Self.bucket)
        }
    }

    // MARK: - The ACL read

    @Test func theAclIsReadWithAGetOnTheObjectAndParsed() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [
            (S3ACLXMLTests.ownerOnlyEmptyGrantee, S3SettingsFake.httpResponse(status: 200))
        ])

        let acl = try #require(try await fs.acl(ofKey: "docs/a.md", inBucket: Self.bucket))

        #expect(acl.grants.count == 1)
        #expect(acl.grants[0].holderIsUnnamed)
        let request = try #require(await Self.sent(transport).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/macscp-seed/docs/a.md")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.map(\.name) == ["acl"])
        #expect(request.httpBody == nil)
    }

    @Test func aStoreWithNoObjectAclsAnswersNilFromTheProviderToo() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [
            (S3ACLXMLTests.notImplementedBody, S3SettingsFake.httpResponse(status: 501))
        ])

        let acl = try await fs.acl(ofKey: "a.txt", inBucket: Self.bucket)

        #expect(acl == nil)
    }

    @Test func aMissingObjectsAclIsNotFoundAtTheCallersPath() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [Self.error("NoSuchKey", status: 404)])

        await #expect(throws: RemoteFSError.notFound(path: "/macscp-seed/gone.txt")) {
            _ = try await fs.acl(ofKey: "gone.txt", inBucket: Self.bucket)
        }
    }

    @Test func theProviderIsReachableThroughTheCapabilityCast() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        let backend: any RemoteFileSystem = fs
        #expect((backend as? any ObjectMetadataProvider) != nil)
    }
}
