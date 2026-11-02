import Foundation
import Testing
@testable import macSCPCore

/// `S3FileSystem`'s `ObjectVersionProvider` conformance, first half
/// (`versions(ofKey:inBucket:)` and `deletedEntries(inBucket:prefix:)`),
/// against the canned transport: the request each call signs and how the
/// answers are put together. No network; the rig half is a later task's.
///
/// Every body here is CONSTRUCTED. The one measured value is `walkerMarker`,
/// the `NextKeyMarker` spec section 4.9 records RustFS returning, copied from
/// there character for character.
@Suite("S3FileSystem object versions")
struct S3ObjectVersionsTests {
    // MARK: - Fixtures

    /// MEASURED text (spec section 4.9), and the reason this suite has a test
    /// for a marker that repeats: the store returned it as an internal handle
    /// "identical across the pages of one listing".
    static let walkerMarker =
        "k1.txt[rustfs_cache:v2,id:58bdf6cd-abf7-46e6-be83-f09a449f2af3,src:walker,gen:live]"

    /// The same marker as it must reach the wire: every byte outside
    /// `A-Za-z0-9-._~` escaped once. Spelled out, not computed, so the
    /// assertion does not call the code it checks.
    static let walkerMarkerOnTheWire =
        "k1.txt%5Brustfs_cache%3Av2%2Cid%3A58bdf6cd-abf7-46e6-be83-f09a449f2af3%2Csrc%3Awalker%2Cgen%3Alive%5D"

    /// A version id marker with a `+`, a `/` and a `=`: the characters a
    /// base64 token carries and an encoder can get wrong.
    static let tokenVersionIdMarker = "dG9rZW4+/x=="
    static let tokenVersionIdMarkerOnTheWire = "dG9rZW4%2B%2Fx%3D%3D"

    static func version(_ key: String, _ id: String, latest: Bool) -> String {
        """
        <Version><Key>\(key)</Key><VersionId>\(id)</VersionId>
        <IsLatest>\(latest)</IsLatest><LastModified>2026-10-23T13:50:02.000Z</LastModified>
        <ETag>"5d41402abc4b2a76b9719d911017c592"</ETag><Size>12</Size></Version>
        """
    }

    static func marker(_ key: String, _ id: String, latest: Bool) -> String {
        """
        <DeleteMarker><Key>\(key)</Key><VersionId>\(id)</VersionId>
        <IsLatest>\(latest)</IsLatest><LastModified>2026-10-23T13:51:08.000Z</LastModified></DeleteMarker>
        """
    }

    /// One page of a listing. `next` is the continuation pair, or `nil` for a
    /// last page.
    static func page(_ entries: [String], next: (key: String, versionId: String?)? = nil) -> Data {
        var continuation = ""
        if let next {
            continuation = "<NextKeyMarker>\(next.key)</NextKeyMarker>"
            if let id = next.versionId {
                continuation += "<NextVersionIdMarker>\(id)</NextVersionIdMarker>"
            }
        }
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>\(next != nil)</IsTruncated>\(continuation)
            \(entries.joined(separator: "\n"))
            </ListVersionsResult>
            """.utf8)
    }

    static func ok(_ body: Data) -> (Data, HTTPURLResponse) {
        (body, S3SettingsFake.httpResponse(status: 200))
    }

    /// The listing requests the transport saw, after `connect`'s probe.
    static func listingRequests(_ transport: FakeS3Transport) async -> [URLRequest] {
        await Array(transport.requests.dropFirst())
    }

    // MARK: - One key's history

    @Test func theConnectionIsOfferedTheCapabilityThroughAnOptionalCast() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        let backend: any RemoteFileSystem = fs
        #expect((backend as? any ObjectVersionProvider) != nil)
    }

    @Test func oneKeysHistoryIsOneRequestWithThePrefix() async throws {
        let body = Self.page([
            Self.marker("doc.txt", "m1", latest: true),
            Self.version("doc.txt", "v2", latest: false),
            Self.version("doc.txt", "v1", latest: false),
        ])
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(body)])
        let versions = try await fs.versions(ofKey: "doc.txt", inBucket: "b")

        #expect(versions.map(\.versionId) == ["m1", "v2", "v1"])
        #expect(versions.map(\.isDeleteMarker) == [true, false, false])
        let sent = await Self.listingRequests(transport)
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/b")
        #expect(request.url?.query == "prefix=doc.txt&versions=")
        // Signed like every other request of this connection, not sent bare.
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256"))
    }

    @Test func aKeyWithNoHistoryIsAnEmptyHistory() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [Self.ok(Self.page([]))])
        let versions = try await fs.versions(ofKey: "doc.txt", inBucket: "b")
        #expect(versions.isEmpty)
    }

    @Test func aKeyIsSentRawAndEncodedOnceOnTheWire() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(Self.page([]))])
        _ = try await fs.versions(ofKey: "dir/a b+c.txt", inBucket: "b")
        let request = try #require(await Self.listingRequests(transport).first)
        let query = try #require(request.url?.query(percentEncoded: true))
        #expect(query.contains("prefix=dir%2Fa%20b%2Bc.txt"))
    }

    @Test func aSiblingKeyThePrefixMatchedIsNotInTheHistory() async throws {
        // The request sends prefix=doc.txt, the store answers with doc.txt and
        // doc.txt.bak, and the history holds doc.txt only.
        let body = Self.page([
            Self.version("doc.txt", "v1", latest: true),
            Self.version("doc.txt.bak", "b1", latest: true),
            Self.marker("doc.txt.old", "b2", latest: true),
        ])
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(body)])
        let versions = try await fs.versions(ofKey: "doc.txt", inBucket: "b")

        // Positive half: the filter keeps the key, it does not empty the list.
        #expect(versions.map(\.versionId) == ["v1"])
        #expect(Set(versions.map(\.key)) == ["doc.txt"])
        let request = try #require(await Self.listingRequests(transport).first)
        #expect(request.url?.query?.contains("prefix=doc.txt") == true)
    }

    // MARK: - Paging

    @Test func aTruncatedHistoryIsFollowedToTheEnd() async throws {
        let first = Self.page(
            [Self.version("k1.txt", "v2", latest: true)],
            next: (key: Self.walkerMarker, versionId: Self.tokenVersionIdMarker))
        let second = Self.page([Self.version("k1.txt", "v1", latest: false)])
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [Self.ok(first), Self.ok(second)])
        let versions = try await fs.versions(ofKey: "k1.txt", inBucket: "b")

        #expect(versions.map(\.versionId) == ["v2", "v1"])
        let sent = await Self.listingRequests(transport)
        #expect(sent.count == 2)

        // The first request carries no marker at all.
        let firstQuery = try #require(sent[0].url?.query(percentEncoded: true))
        #expect(firstQuery.contains("key-marker") == false)
        #expect(firstQuery.contains("version-id-marker") == false)

        // The second carries both, exactly as the store issued them, escaped
        // ONCE. `%25` anywhere would be a marker encoded twice.
        let secondQuery = try #require(sent[1].url?.query(percentEncoded: true))
        let pairs = Set(secondQuery.split(separator: "&").map(String.init))
        #expect(pairs.contains("key-marker=" + Self.walkerMarkerOnTheWire))
        #expect(pairs.contains("version-id-marker=" + Self.tokenVersionIdMarkerOnTheWire))
        let encodedTwice = secondQuery.contains("%25")
        #expect(encodedTwice == false)
        // What the store decodes is the marker it issued.
        let decodedKeyMarker = pairs.first { $0.hasPrefix("key-marker=") }?
            .dropFirst("key-marker=".count).removingPercentEncoding
        #expect(decodedKeyMarker == Self.walkerMarker)
    }

    @Test func aMarkerThatRepeatsAcrossPagesDoesNotEndTheListing() async throws {
        // Spec 4.9: this store returns the SAME key marker on every page of a
        // listing. A loop that stopped on "marker equals the last one" would
        // return after page two and drop page three.
        let same = (key: Self.walkerMarker, versionId: "id-a" as String?)
        let pages = [
            Self.page([Self.version("k1.txt", "v3", latest: true)], next: same),
            Self.page(
                [Self.version("k1.txt", "v2", latest: false)],
                next: (key: Self.walkerMarker, versionId: "id-b")),
            Self.page([Self.version("k1.txt", "v1", latest: false)]),
        ]
        let (fs, transport) = try await S3SettingsFake.connect(responses: pages.map(Self.ok))
        let versions = try await fs.versions(ofKey: "k1.txt", inBucket: "b")

        #expect(versions.map(\.versionId) == ["v3", "v2", "v1"])
        #expect(await Self.listingRequests(transport).count == 3)
    }

    @Test func aContinuationWithoutAVersionIdMarkerSendsTheKeyMarkerAlone() async throws {
        let first = Self.page(
            [Self.version("k1.txt", "v2", latest: true)], next: (key: "k1.txt", versionId: nil))
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [Self.ok(first), Self.ok(Self.page([]))])
        _ = try await fs.versions(ofKey: "k1.txt", inBucket: "b")
        let second = try #require(await Self.listingRequests(transport).last)
        let query = try #require(second.url?.query(percentEncoded: true))
        #expect(query.contains("key-marker=k1.txt"))
        #expect(query.contains("version-id-marker") == false)
    }

    @Test func aListingThatNeverEndsFailsInsteadOfReturningAPartialHistory() async throws {
        let endless = Self.page(
            [Self.version("k1.txt", "v", latest: true)], next: (key: "k1.txt", versionId: "x"))
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: Array(repeating: Self.ok(endless), count: 5))
        await #expect(throws: RemoteFSError.self) {
            _ = try await fs.versionEntries(
                inBucket: "b", prefix: "k1.txt", delimiter: nil, pageLimit: 3)
        }
        // Exactly the limit was asked for: the cap is on pages, not a guess.
        #expect(await Self.listingRequests(transport).count == 3)
    }

    @Test func aMarkerBesideIsTruncatedFalseIsStillFollowed() async throws {
        // The page type carries no flag, only the marker, so this layer
        // follows a marker wherever it appears; the extra request ends it.
        let first = Data(
            """
            <ListVersionsResult><IsTruncated>false</IsTruncated>
            <NextKeyMarker>k1.txt</NextKeyMarker><NextVersionIdMarker>x</NextVersionIdMarker>
            \(Self.version("k1.txt", "v2", latest: true))</ListVersionsResult>
            """.utf8)
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [Self.ok(first), Self.ok(Self.page([Self.version("k1.txt", "v1", latest: false)]))])
        let versions = try await fs.versions(ofKey: "k1.txt", inBucket: "b")
        #expect(versions.map(\.versionId) == ["v2", "v1"])
        #expect(await Self.listingRequests(transport).count == 2)
    }

    // MARK: - Deleted entries

    @Test func deletedEntriesAreTheLatestMarkersOnly() async throws {
        // gone.txt: its newest entry is a marker, so it IS deleted.
        // back.txt: a marker, but under a newer version (deleted, then
        //   written again), so it is NOT.
        // here.txt: never deleted.
        let body = Self.page([
            Self.marker("gone.txt", "gm", latest: true),
            Self.version("gone.txt", "gv", latest: false),
            Self.version("back.txt", "bv2", latest: true),
            Self.marker("back.txt", "bm", latest: false),
            Self.version("back.txt", "bv1", latest: false),
            Self.version("here.txt", "hv", latest: true),
        ])
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(body)])
        let deleted = try await fs.deletedEntries(inBucket: "b", prefix: "")

        // Positive half first: a method returning nothing would satisfy the
        // negative one.
        #expect(deleted.map(\.key) == ["gone.txt"])
        #expect(deleted.first?.markerVersionId == "gm")
        #expect(deleted.first?.modifiedAt != nil)
        #expect(deleted.contains { $0.key == "back.txt" } == false)
        #expect(deleted.contains { $0.key == "here.txt" } == false)

        let request = try #require(await Self.listingRequests(transport).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/b")
        #expect(request.url?.query == "delimiter=%2F&prefix=&versions=")
    }

    @Test func deletedEntriesAreOneLevelDeep() async throws {
        // The body carries BOTH shapes a store can answer with: the roll-up a
        // store that honours `delimiter=/` sends (`CommonPrefixes`), and the
        // nested marker as an ordinary top-level `DeleteMarker`, which is what
        // a store that ignores the parameter sends. The second is what makes
        // the absence assertion about OUR code: without the local exclusion
        // `d/sub/x.txt` would be reported. What a real store does with
        // `delimiter=/` on `?versions` is unmeasured (the rig task measures
        // it); the answer here no longer depends on that.
        let body = Data(
            """
            <ListVersionsResult><IsTruncated>false</IsTruncated>
            \(Self.marker("d/top.txt", "tm", latest: true))
            \(Self.marker("d/sub/x.txt", "nm", latest: true))
            <CommonPrefixes><Prefix>d/sub/</Prefix></CommonPrefixes>
            </ListVersionsResult>
            """.utf8)
        let (fs, transport) = try await S3SettingsFake.connect(responses: [Self.ok(body)])
        let deleted = try await fs.deletedEntries(inBucket: "b", prefix: "d/")

        #expect(deleted.map(\.key) == ["d/top.txt"])
        #expect(deleted.contains { $0.key.hasPrefix("d/sub/") } == false)
        let request = try #require(await Self.listingRequests(transport).first)
        #expect(request.url?.query(percentEncoded: true)?.contains("delimiter=%2F") == true)
    }

    /// The boundary cases of "one level below the prefix": the part of a key
    /// after the prefix must hold no `/`. A prefix need not end on a folder
    /// boundary, and a key the store sent that does not start with the prefix
    /// is not an answer to the question and is dropped.
    @Test(arguments: [
        // Root view: only keys with no `/` at all.
        (prefix: "", expected: ["top.txt", "elsewhere.txt"]),
        // `d/` under `d/` is the prefix itself, the folder and not a child of
        // it: dropped, as `S3ListParser` drops `key != prefix`. (Withdrawn
        // expectation, verbatim: `["d/top.txt", "d/"]`, which kept it.)
        (prefix: "d/", expected: ["d/top.txt"]),
        // Mid-name prefix: the rest after `d/to` is `p.txt` (kept), `/x` and
        // `p/x.txt` (below one level).
        (prefix: "d/to", expected: ["d/top.txt"]),
    ])
    func oneLevelIsMeasuredFromThePrefixNotFromAFolder(
        prefix: String, expected: [String]
    ) async throws {
        let keys = ["top.txt", "d/top.txt", "d/", "d/sub/x.txt", "d/to/x", "d/top/x.txt", "elsewhere.txt"]
        let body = Self.page(keys.map { Self.marker($0, "m-" + $0, latest: true) })
        let (fs, _) = try await S3SettingsFake.connect(responses: [Self.ok(body)])
        let deleted = try await fs.deletedEntries(inBucket: "b", prefix: prefix)
        // `elsewhere.txt` does not start with `d/` or `d/to`: dropped there.
        #expect(Set(deleted.map(\.key)) == Set(expected))
    }

    @Test func deletedEntriesUnderAPrefixAreFoundOnEveryPage() async throws {
        let first = Self.page(
            [Self.marker("d/a.txt", "am", latest: true)], next: (key: "d/a.txt", versionId: "am"))
        let second = Self.page([Self.marker("d/b.txt", "bm", latest: true)])
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [Self.ok(first), Self.ok(second)])
        let deleted = try await fs.deletedEntries(inBucket: "b", prefix: "d/")
        #expect(deleted.map(\.key) == ["d/a.txt", "d/b.txt"])
        let sent = await Self.listingRequests(transport)
        #expect(sent.count == 2)
        #expect(sent[0].url?.query?.contains("prefix=d%2F") == true)
        #expect(sent[1].url?.query?.contains("key-marker=d%2Fa.txt") == true)
    }

    // MARK: - Errors

    @Test func aMissingBucketNamesTheBucketAndNotAnEmptyPath() async throws {
        let body = Data("<Error><Code>NoSuchBucket</Code><Message>no</Message></Error>".utf8)
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(body, S3SettingsFake.httpResponse(status: 404))])
        do {
            _ = try await fs.versions(ofKey: "doc.txt", inBucket: "gone")
            Issue.record("a 404 returned a history")
        } catch {
            #expect((error as? RemoteFSError) == .notFound(path: "/gone"))
        }
    }

    @Test func aStoreWithoutTheCallKeepsItsNamedFinding() async throws {
        let body = Data("<Error><Code>NotImplemented</Code><Message>no</Message></Error>".utf8)
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(body, S3SettingsFake.httpResponse(status: 501))])
        do {
            _ = try await fs.deletedEntries(inBucket: "b", prefix: "")
            Issue.record("a 501 returned entries")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.operationNotSupported))
        }
    }

    // MARK: - Placeholders (canaries)

    // These four cases exist to be DELETED. `readStream` is implemented by
    // the version download (Task 5 of
    // `docs/superpowers/plans/2026-10-23-s3-version-history.md`); `restore`,
    // `deleteVersion` and `liftDeleteMarker` by the write half (its Task 4).
    // Until then each method refuses with `.finding(.operationNotSupported)`,
    // which is indistinguishable from a store that does not support the call.
    // A case going red means the method it names was implemented, and its case
    // must be removed in the same commit. One case per method, not one over
    // all four, so a single survivor is named.

    @Test func placeholderReadStreamStillRefuses() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        await #expect(throws: RemoteFSError.finding(.operationNotSupported)) {
            _ = try await fs.readStream(ofKey: "doc.txt", inBucket: "b", versionId: "v1")
        }
    }

    @Test func placeholderRestoreStillRefuses() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        await #expect(throws: RemoteFSError.finding(.operationNotSupported)) {
            try await fs.restore(key: "doc.txt", inBucket: "b", toVersionId: "v1")
        }
    }

    @Test func placeholderDeleteVersionStillRefuses() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        await #expect(throws: RemoteFSError.finding(.operationNotSupported)) {
            try await fs.deleteVersion(ofKey: "doc.txt", inBucket: "b", versionId: "v1")
        }
    }

    @Test func placeholderLiftDeleteMarkerStillRefuses() async throws {
        let (fs, _) = try await S3SettingsFake.connect(responses: [])
        await #expect(throws: RemoteFSError.finding(.operationNotSupported)) {
            try await fs.liftDeleteMarker(ofKey: "doc.txt", inBucket: "b", markerVersionId: "m1")
        }
    }
}
