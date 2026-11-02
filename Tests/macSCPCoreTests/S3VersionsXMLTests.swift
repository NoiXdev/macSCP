import Foundation
import Testing
@testable import macSCPCore

@Suite("S3VersionsXML")
struct S3VersionsXMLTests {
    // MARK: - Fixtures
    //
    // Every body here is CONSTRUCTED for this suite from a raw string; none is
    // a transcript of a response, and nothing is fetched. The spec records no
    // verbatim `ListVersionsResult` body (it describes the element names in
    // prose, section 4.1), so the keys, version ids, dates, tags and sizes in
    // these documents are scaffolding. What is measured text is named on the
    // fixtures that carry some: `walkerMarker` and `notImplementedBody` (and
    // `accessDeniedBody` for its code only).

    /// A delete marker on top of two content versions of one key.
    static let twoVersionsOneMarker = Data(
        #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>macscp-seed</Name><Prefix>doc.txt</Prefix><KeyMarker></KeyMarker>
          <VersionIdMarker></VersionIdMarker><MaxKeys>1000</MaxKeys>
          <IsTruncated>false</IsTruncated>
          <DeleteMarker>
            <Key>doc.txt</Key><VersionId>0b3a1f6e-5d6c-4a1e-9a55-0c7d2d1b9e01</VersionId>
            <IsLatest>true</IsLatest><LastModified>2026-10-23T13:51:08.000Z</LastModified>
          </DeleteMarker>
          <Version>
            <Key>doc.txt</Key><VersionId>7f2c9a0e-3b1d-4c55-8e0a-6a4f1d2b7c02</VersionId>
            <IsLatest>false</IsLatest><LastModified>2026-10-23T13:50:02.000Z</LastModified>
            <ETag>"5d41402abc4b2a76b9719d911017c592"</ETag><Size>12</Size>
            <StorageClass>STANDARD</StorageClass>
          </Version>
          <Version>
            <Key>doc.txt</Key><VersionId>c41e8d77-9f02-4b6a-a3d1-2e5b8f0a9c03</VersionId>
            <IsLatest>false</IsLatest><LastModified>2026-10-23T13:49:30.000Z</LastModified>
            <ETag>"7d793037a0760186574b0282f2f435e7"</ETag><Size>5</Size>
            <StorageClass>STANDARD</StorageClass>
          </Version>
        </ListVersionsResult>
        """#.utf8)

    /// `prefix=doc.txt` also matches `doc.txt.bak` at the store.
    static let keyAndSiblingKey = Data(
        #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Prefix>doc.txt</Prefix><IsTruncated>false</IsTruncated>
          <Version>
            <Key>doc.txt</Key><VersionId>11111111-1111-4111-8111-111111111111</VersionId>
            <IsLatest>true</IsLatest><LastModified>2026-10-23T13:50:02.000Z</LastModified>
            <ETag>"5d41402abc4b2a76b9719d911017c592"</ETag><Size>12</Size>
          </Version>
          <Version>
            <Key>doc.txt.bak</Key><VersionId>22222222-2222-4222-8222-222222222222</VersionId>
            <IsLatest>true</IsLatest><LastModified>2026-10-23T13:50:09.000Z</LastModified>
            <ETag>"7d793037a0760186574b0282f2f435e7"</ETag><Size>5</Size>
          </Version>
        </ListVersionsResult>
        """#.utf8)

    /// MEASURED text: the `NextKeyMarker` value spec section 4.9 records
    /// RustFS returning, copied from there character for character. The
    /// listing documents that carry it are constructed.
    static let walkerMarker =
        "k1.txt[rustfs_cache:v2,id:58bdf6cd-abf7-46e6-be83-f09a449f2af3,src:walker,gen:live]"

    /// A first page cut short at `max-keys=1`. The `KeyMarker` and
    /// `VersionIdMarker` are the REQUEST's echo; the `Next` pair is what
    /// continues the listing.
    static let truncatedFirstPage = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Prefix></Prefix><KeyMarker>echoed-request-key</KeyMarker>
          <VersionIdMarker>echoed-request-version</VersionIdMarker>
          <MaxKeys>1</MaxKeys><IsTruncated>true</IsTruncated>
          <NextKeyMarker>\(walkerMarker)</NextKeyMarker>
          <NextVersionIdMarker>33333333-3333-4333-8333-333333333333</NextVersionIdMarker>
          <Version>
            <Key>k1.txt</Key><VersionId>33333333-3333-4333-8333-333333333333</VersionId>
            <IsLatest>true</IsLatest><LastModified>2026-10-23T13:50:02.000Z</LastModified>
            <ETag>"5d41402abc4b2a76b9719d911017c592"</ETag><Size>12</Size>
          </Version>
        </ListVersionsResult>
        """.utf8)

    /// The last page of a continued listing: the request's echo is present,
    /// and nothing continues it.
    static let finalPageOfAContinuedListing = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Prefix></Prefix><KeyMarker>\(walkerMarker)</KeyMarker>
          <VersionIdMarker>33333333-3333-4333-8333-333333333333</VersionIdMarker>
          <MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated>
          <Version>
            <Key>k4.txt</Key><VersionId>44444444-4444-4444-8444-444444444444</VersionId>
            <IsLatest>true</IsLatest><LastModified>2026-10-23T13:50:02.000Z</LastModified>
            <ETag>"5d41402abc4b2a76b9719d911017c592"</ETag><Size>12</Size>
          </Version>
        </ListVersionsResult>
        """.utf8)

    /// CONSTRUCTED, around one measured fact. Measured (spec section 4.6): RustFS
    /// answers a call it does not implement with 501 and
    /// `<Code>NotImplemented</Code>`; the call measured there was
    /// `GetBucketOwnershipControls`, not a version listing. Scaffolding: the
    /// `Message` and `Resource` text, and the pairing with a version listing,
    /// which RustFS does implement (section 4.1). The pairing is the point of
    /// the fixture: some other store may not implement it, and its answer must
    /// not read as an authentication failure.
    static let notImplementedBody = Data(
        #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>NotImplemented</Code>
        <Message>ListObjectVersions is not implemented yet</Message>
        <Resource>/macscp-seed</Resource></Error>
        """#.utf8)

    /// The positive control for the 501 case: a refusal that really is one
    /// of credentials or permission. CONSTRUCTED: section 4.7 measured an
    /// `AccessDenied` code at 403 (on a version delete); this body's message
    /// and resource are scaffolding.
    static let accessDeniedBody = Data(
        #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>AccessDenied</Code><Message>Access Denied.</Message>
        <Resource>/macscp-seed</Resource></Error>
        """#.utf8)

    /// What `parsePage` threw, or `nil` when it returned.
    private static func thrownError(_ body: Data, status: Int) -> RemoteFSError? {
        do {
            _ = try S3VersionsXML.parsePage(body, status: status)
            return nil
        } catch let error as RemoteFSError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - Entries

    @Test func aVersionAndADeleteMarkerAreBothRead() throws {
        let page = try S3VersionsXML.parsePage(Self.twoVersionsOneMarker, status: 200)
        #expect(page.versions.count == 3)
        #expect(page.versions.filter(\.isDeleteMarker).count == 1)
        #expect(page.versions.first(where: \.isLatest)?.isDeleteMarker == true)
    }

    @Test func aDeleteMarkerHasNoSizeOrTagAndAVersionKeepsItsFields() throws {
        let page = try S3VersionsXML.parsePage(Self.twoVersionsOneMarker, status: 200)
        let marker = try #require(page.versions.first { $0.isDeleteMarker })
        #expect(marker.versionId == "0b3a1f6e-5d6c-4a1e-9a55-0c7d2d1b9e01")
        #expect(marker.size == nil)
        #expect(marker.entityTag == nil)
        #expect(marker.modifiedAt == Date(timeIntervalSince1970: 1_792_763_468))

        let version = try #require(page.versions.first { $0.versionId.hasPrefix("7f2c9a0e") })
        #expect(version.key == "doc.txt")
        #expect(version.isDeleteMarker == false)
        #expect(version.isLatest == false)
        #expect(version.size == 12)
        // The tag is kept as the store wrote it, quotes included.
        #expect(version.entityTag == "\"5d41402abc4b2a76b9719d911017c592\"")
    }

    @Test func theOrderTheStoreWroteIsTheOrderReturned() throws {
        let page = try S3VersionsXML.parsePage(Self.twoVersionsOneMarker, status: 200)
        #expect(page.versions.map { String($0.versionId.prefix(1)) } == ["0", "7", "c"])
    }

    @Test func aSiblingKeyTheRequestsPrefixAlsoMatchedIsStillParsed() throws {
        // `prefix=doc.txt` matches `doc.txt.bak` at the store; the parser reports
        // what arrived and the CALLER filters.
        let page = try S3VersionsXML.parsePage(Self.keyAndSiblingKey, status: 200)
        #expect(Set(page.versions.map(\.key)) == ["doc.txt", "doc.txt.bak"])
    }

    // MARK: - Markers

    @Test func aTruncatedPageCarriesBothMarkers() throws {
        let page = try S3VersionsXML.parsePage(Self.truncatedFirstPage, status: 200)
        #expect(page.isTruncated)
        #expect(page.nextVersionIdMarker != nil)
    }

    @Test func theNextMarkersAreTheStoresTokensUntouchedAndNotTheRequestsEcho() throws {
        let page = try S3VersionsXML.parsePage(Self.truncatedFirstPage, status: 200)
        #expect(page.nextKeyMarker == Self.walkerMarker)
        #expect(page.nextVersionIdMarker == "33333333-3333-4333-8333-333333333333")
    }

    @Test func aFinalPageHasNoMarkersAndIsNotTruncated() throws {
        // The positive control for the two tests above: a parser that
        // returned a marker for every page would pass both of them.
        let page = try S3VersionsXML.parsePage(Self.twoVersionsOneMarker, status: 200)
        #expect(page.nextKeyMarker == nil)
        #expect(page.nextVersionIdMarker == nil)
        #expect(page.isTruncated == false)
    }

    @Test func theRequestsEchoOfItsMarkersIsNotAContinuation() throws {
        // The echo names where THIS page started. Taking it for the next
        // marker would send the same request again, forever.
        let page = try S3VersionsXML.parsePage(Self.finalPageOfAContinuedListing, status: 200)
        #expect(page.versions.count == 1)
        #expect(page.nextKeyMarker == nil)
        #expect(page.nextVersionIdMarker == nil)
        #expect(page.isTruncated == false)
    }

    @Test func aMarkerCarryingAnInternalTokenIsEncodedNotParsed() {
        // The shape is measured (spec section 4.9: RustFS returned a walker
        // handle with brackets, commas and colons inside `NextKeyMarker`). This
        // literal is a SHORTENED, constructed variant of it, not the measured
        // string; `walkerMarker` is the measured one.
        let marker = "k1.txt[rustfs_cache:v2,id:58bdf6cd,src:walker,gen:live]"
        let encoded = S3VersionsXML.markerQueryValue(marker)
        let leaksABracket = encoded.contains("[") || encoded.contains("]")
        #expect(leaksABracket == false)
        #expect(encoded.contains("%5B"))
    }

    @Test func anEncodedMarkerDecodesBackToTheMarkerItCameFrom() {
        // The positive control for the test above: dropping every
        // character would also leave no bracket.
        let encoded = S3VersionsXML.markerQueryValue(Self.walkerMarker)
        #expect(encoded.removingPercentEncoding == Self.walkerMarker)
    }

    @Test func aMarkerWithNonASCIIAndQueryDelimitersRoundTrips() {
        let marker = "dir/ü ber&x=1+2/ключ#?.txt"
        let encoded = S3VersionsXML.markerQueryValue(marker)
        let leaksADelimiter = encoded.contains { "&=+#? /".contains($0) }
        #expect(leaksADelimiter == false)
        #expect(encoded.removingPercentEncoding == marker)
    }

    // MARK: - Refusals

    @Test func aStoreThatDoesNotImplementTheCallIsExplainedAsUnsupportedNotAsAnAuthFailure() {
        // `RemoteFSError.self` would match `.authenticationFailed`
        // as readily as anything else, so the VALUE is asserted.
        let thrown = Self.thrownError(Self.notImplementedBody, status: 501)
        let isAuthFailure = thrown == .authenticationFailed
        #expect(thrown == .finding(.operationNotSupported))
        #expect(isAuthFailure == false)
    }

    @Test func aRefusalOfCredentialsIsStillAnAuthFailure() {
        // The positive control for the test above: "not an auth failure" is
        // satisfied by a parser that can never report one.
        let thrown = Self.thrownError(Self.accessDeniedBody, status: 403)
        #expect(thrown == .authenticationFailed)
    }

    @Test func aNon2xxStatusNeverReadsTheBodyAsAListing() {
        // A listing body behind an error status must not be parsed as success.
        let thrown = Self.thrownError(Self.twoVersionsOneMarker, status: 500)
        #expect(thrown == .finding(.unexpectedStatus(code: 500)))
    }

    // MARK: - Malformed answers

    @Test func aDocumentWhoseRootIsNotAListingIsAProtocolError() {
        let body = Data("<html><body>Bad gateway</body></html>".utf8)
        let thrown = Self.thrownError(body, status: 200)
        guard case .protocolError? = thrown else {
            Issue.record("expected a protocolError, got \(String(describing: thrown))")
            return
        }
    }

    @Test func aDocumentThatIsNotWellFormedIsAProtocolError() {
        let body = Data("<ListVersionsResult><Version><Key>a".utf8)
        let thrown = Self.thrownError(body, status: 200)
        guard case .protocolError? = thrown else {
            Issue.record("expected a protocolError, got \(String(describing: thrown))")
            return
        }
    }

    @Test func aVersionWithoutAVersionIdIsAProtocolError() {
        // Reading it as an empty id would offer a restore of "nothing".
        let body = Data(
            "<ListVersionsResult><Version><Key>a</Key><IsLatest>true</IsLatest></Version></ListVersionsResult>"
                .utf8)
        let thrown = Self.thrownError(body, status: 200)
        guard case .protocolError? = thrown else {
            Issue.record("expected a protocolError, got \(String(describing: thrown))")
            return
        }
    }

    @Test func aSizeThatIsNotAnIntegerIsAProtocolError() {
        let body = Data(
            """
            <ListVersionsResult><Version><Key>a</Key><VersionId>v</VersionId>\
            <IsLatest>true</IsLatest><Size>twelve</Size></Version></ListVersionsResult>
            """.utf8)
        let thrown = Self.thrownError(body, status: 200)
        guard case .protocolError? = thrown else {
            Issue.record("expected a protocolError, got \(String(describing: thrown))")
            return
        }
    }

    @Test(arguments: [
        ("2026-10-23T13:50:02.000Z", 1_792_763_402.0),
        ("2026-10-23T13:50:02Z", 1_792_763_402.0),
    ])
    func aTimestampReadsWithOrWithoutFractionalSeconds(text: String, expected: Double) throws {
        let body = Data(
            """
            <ListVersionsResult><Version><Key>a</Key><VersionId>v</VersionId>\
            <IsLatest>true</IsLatest><LastModified>\(text)</LastModified></Version></ListVersionsResult>
            """.utf8)
        let page = try S3VersionsXML.parsePage(body, status: 200)
        #expect(page.versions.first?.modifiedAt == Date(timeIntervalSince1970: expected))
    }

    @Test func anEmptyListingIsAnEmptyPage() throws {
        let body = Data("<ListVersionsResult><IsTruncated>false</IsTruncated></ListVersionsResult>".utf8)
        let page = try S3VersionsXML.parsePage(body, status: 200)
        #expect(page.versions.isEmpty)
        #expect(page.isTruncated == false)
    }
}
