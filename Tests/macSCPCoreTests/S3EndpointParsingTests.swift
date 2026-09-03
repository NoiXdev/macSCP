import Foundation
import Testing
@testable import macSCPCore

/// What the ONE S3 endpoint parse (`S3FieldSchema.endpointComponents`) makes
/// of every spelling a user types into the endpoint field.
///
/// Written as a measurement first (2026-09-03, maintainer report: an S3
/// connection fails when the host field carries a port). What the table
/// recorded BEFORE the fix, straight out of `URLComponents(string:)`:
///
///     minio.example.test               scheme=nil    host=nil  port=nil
///     minio.example.test:9000          scheme=minio.example.test host=nil port=nil
///     http://minio.example.test:9000   scheme=http   host=minio.example.test port=9000
///     https://minio.example.test       scheme=https  host=minio.example.test port=nil
///     https://minio.example.test:8443/ scheme=https  host=minio.example.test port=8443
///     [::1]:9000                       scheme=nil    host=nil  port=nil
///     s3.amazonaws.com                 scheme=nil    host=nil  port=nil
///     192.0.2.10:9000                  (no components at all — nil)
///
/// FOUR of the eight parsed with no host and a fifth (`192.0.2.10:9000`) did
/// not parse at all — two outcomes with two different refusals, which an
/// earlier version of this comment ran together (review 2026-09-04, I-1).
/// A string that does not parse is refused by `S3FileSystem`'s URL builders
/// ("Invalid S3 endpoint"); a string that parses with no host gets past them
/// under path-style addressing and is refused by
/// `S3RequestSigning.signedRequest` ("S3 endpoint has no host"), while
/// virtual-hosted addressing refuses it one step earlier ("Invalid S3
/// endpoint host"). `host:9000` was the worst of them: Foundation reads
/// `minio.example.test` as the SCHEME and the port as the path.
///
/// The rule since this task: **a schemeless endpoint means `https`, and its
/// port is honoured.** One place implements it — the parse below — so the
/// connect path, the diagnosis reader and the form all read the same string
/// the same way.
@Suite("S3 endpoint parsing")
struct S3EndpointParsingTests {
    /// One row of the table: the typed spelling and what the parse must make
    /// of it. `path` is the parsed path, which the connect path OVERWRITES
    /// (it writes `/bucket/key`), so it is recorded rather than relied on.
    struct Row: Sendable, CustomStringConvertible {
        let typed: String
        let scheme: String
        /// `URLComponents.host`, which keeps an IPv6 literal's BRACKETS —
        /// unlike `URL.host()`, which strips them. `dialedHost` below is the
        /// stripped one, and the difference is not cosmetic: `getaddrinfo`
        /// rejects a bracketed literal, so the diagnosis has to read the
        /// bare one (`BackendDescriptorEndpointTests`).
        let host: String
        let port: Int?
        let path: String
        /// What the form says it understood — scheme, host and port, with an
        /// IPv6 literal bracketed exactly once.
        let canonical: String
        /// What a diagnosis would dial: `Endpoint`'s host, and its port or
        /// the scheme's default.
        let dialedHost: String
        let dialedPort: Int

        var description: String { typed }
    }

    static let table: [Row] = [
        Row(typed: "minio.example.test", scheme: "https", host: "minio.example.test",
            port: nil, path: "", canonical: "https://minio.example.test",
            dialedHost: "minio.example.test", dialedPort: 443),
        Row(typed: "minio.example.test:9000", scheme: "https", host: "minio.example.test",
            port: 9000, path: "", canonical: "https://minio.example.test:9000",
            dialedHost: "minio.example.test", dialedPort: 9000),
        Row(typed: "http://minio.example.test:9000", scheme: "http", host: "minio.example.test",
            port: 9000, path: "", canonical: "http://minio.example.test:9000",
            dialedHost: "minio.example.test", dialedPort: 9000),
        Row(typed: "https://minio.example.test", scheme: "https", host: "minio.example.test",
            port: nil, path: "", canonical: "https://minio.example.test",
            dialedHost: "minio.example.test", dialedPort: 443),
        Row(typed: "https://minio.example.test:8443/", scheme: "https", host: "minio.example.test",
            port: 8443, path: "/", canonical: "https://minio.example.test:8443",
            dialedHost: "minio.example.test", dialedPort: 8443),
        Row(typed: "[::1]:9000", scheme: "https", host: "[::1]",
            port: 9000, path: "", canonical: "https://[::1]:9000",
            dialedHost: "::1", dialedPort: 9000),
        Row(typed: "s3.amazonaws.com", scheme: "https", host: "s3.amazonaws.com",
            port: nil, path: "", canonical: "https://s3.amazonaws.com",
            dialedHost: "s3.amazonaws.com", dialedPort: 443),
        Row(typed: "192.0.2.10:9000", scheme: "https", host: "192.0.2.10",
            port: 9000, path: "", canonical: "https://192.0.2.10:9000",
            dialedHost: "192.0.2.10", dialedPort: 9000),
    ]

    @Test(arguments: table)
    func theParseReadsEverySpelling(_ row: Row) throws {
        let components = try #require(
            S3FieldSchema.endpointComponents(row.typed),
            "\(row.typed) did not parse at all")
        #expect(components.scheme == row.scheme)
        #expect(components.host == row.host)
        #expect(components.port == row.port)
        #expect(components.path == row.path)
    }

    /// The same table read as the diagnosis reads it — host and port, with
    /// the scheme's default port where none was typed. This is where the
    /// IPv6 literal loses its brackets: `[::1]:9000` is dialed as `::1`
    /// port 9000.
    @Test(arguments: table)
    func everySpellingNamesTheHostAndPortADiagnosisWouldDial(_ row: Row) {
        var values = FieldValues()
        values[S3Field.endpoint] = row.typed
        #expect(S3FieldSchema.endpoint(values)
            == Endpoint(host: row.dialedHost, port: row.dialedPort))
    }

    @Test(arguments: table)
    func theCanonicalSpellingIsSchemeHostAndPort(_ row: Row) {
        #expect(S3FieldSchema.canonicalEndpoint(row.typed) == row.canonical)
    }

    /// The canonical spelling is a FIXED POINT: feeding it back through the
    /// parse yields the same host and port. Without that, the string the form
    /// shows and the string the connect path dials could drift apart.
    @Test(arguments: table)
    func theCanonicalSpellingParsesBackToItself(_ row: Row) {
        #expect(S3FieldSchema.canonicalEndpoint(row.canonical) == row.canonical)
    }

    /// Surrounding whitespace is a paste artifact, not part of a host name —
    /// and the trim has to happen BEFORE the scheme test, or a leading space
    /// would make ` https://host` look schemeless and get a second prefix.
    @Test func aWhitespacePaddedSpellingParsesLikeTheTrimmedOne() {
        #expect(S3FieldSchema.canonicalEndpoint("  https://minio.example.test:8443  ")
            == "https://minio.example.test:8443")
        #expect(S3FieldSchema.canonicalEndpoint("\tminio.example.test:9000\n")
            == "https://minio.example.test:9000")
    }

    /// An endpoint the parse cannot use at all still has no host, and the
    /// canonical spelling is nil rather than an invented one. The blank case
    /// is the form's "Enter the endpoint" violation, not this function's.
    @Test(arguments: ["", "   ", "https://", "http://:9000"])
    func anUnusableSpellingHasNoCanonicalForm(_ typed: String) {
        #expect(S3FieldSchema.canonicalEndpoint(typed) == nil)
    }

    /// The Foundation fact the `https://` prefix exists for, measured rather
    /// than believed — and the reason the fix could not be "let the user type
    /// a host": `URLComponents` reads `host:9000` as a SCHEME of `host`, and
    /// refuses `192.0.2.10:9000` outright (a scheme may not start with a
    /// digit).
    @Test func foundationReadsASchemelessSpellingAsASchemeAndNotAsAHost() {
        let raw = URLComponents(string: "minio.example.test:9000")
        #expect(raw?.scheme == "minio.example.test")
        #expect(raw?.host == nil)
        #expect(URLComponents(string: "192.0.2.10:9000") == nil)
    }

    /// The spelling the Cyberduck importer writes for a custom endpoint with
    /// a port, composed in Core so the importer cannot invent a second one.
    /// An IPv6 literal is bracketed here, because that is what makes it
    /// parse back.
    @Test func theComposedSpellingIsWhatTheParseAccepts() throws {
        #expect(S3FieldSchema.endpointSpelling(host: "minio.example.test", port: 9000)
            == "https://minio.example.test:9000")
        #expect(S3FieldSchema.endpointSpelling(host: "minio.example.test", port: nil)
            == "https://minio.example.test")
        #expect(S3FieldSchema.endpointSpelling(host: "::1", port: 9000) == "https://[::1]:9000")
        let ipv6 = try #require(S3FieldSchema.endpointComponents(
            S3FieldSchema.endpointSpelling(host: "::1", port: 9000)))
        // Bracketed, because that is `URLComponents.host`'s spelling of a
        // literal; the bare `::1` a resolver needs comes off the URL (see
        // `everySpellingNamesTheHostAndPortADiagnosisWouldDial`).
        #expect(ipv6.host == "[::1]")
        #expect(ipv6.port == 9000)
        #expect(ipv6.url?.host() == "::1")
    }

    /// The whole point of the change, end to end: a session configured with a
    /// schemeless `host:port` endpoint reaches the transport as an `https`
    /// request to that host and that port, with the `Host` header the signer
    /// signed carrying the port too. Before the fix this threw
    /// `connectionFailed(reason: "Invalid S3 endpoint: …")` from
    /// `S3FileSystem`'s URL builders and no request was ever sent.
    @Test func aSchemelessEndpointWithAPortDialsThatHostAndPort() async throws {
        let config = S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "minio.example.test:9000", bucket: "backups",
            usePathStyle: true, sessionToken: nil)
        let emptyListing = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <IsTruncated>false</IsTruncated>
            </ListBucketResult>
            """
        let response = HTTPURLResponse(
            url: URL(string: "https://minio.example.test:9000/backups")!,
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let transport = FakeS3Transport(responses: [(Data(emptyListing.utf8), response)])

        _ = try await S3FileSystem.connect(config, transport: transport)

        let requests = await transport.requests
        let probe = try #require(requests.first)
        let url = try #require(probe.url)
        #expect(url.scheme == "https")
        #expect(url.host == "minio.example.test")
        #expect(url.port == 9000)
        #expect(probe.value(forHTTPHeaderField: "Host") == "minio.example.test:9000")
    }

    // MARK: - The origin a request actually reaches

    /// The endpoint field names a SERVER; the request goes to whatever the
    /// addressing style makes of it. With virtual-hosted addressing — the
    /// default, `usePathStyle` off — that is `<bucket>.<host>`, which is a
    /// different name to resolve and the reason a footnote that printed the
    /// endpoint's own origin would have been wrong about where the
    /// connection goes (review 2026-09-04, I-3).
    @Test func theOriginNamesTheBucketUnderVirtualHostAddressing() {
        var values = FieldValues()
        values[S3Field.endpoint] = "minio.example.test:9000"
        values[S3Field.bucket] = "backups"
        values[bool: S3Field.usePathStyle] = false
        #expect(S3FieldSchema.requestOrigin(values) == "https://backups.minio.example.test:9000")
    }

    @Test func pathStyleAddressingLeavesTheOriginAtTheEndpointHost() {
        var values = FieldValues()
        values[S3Field.endpoint] = "minio.example.test:9000"
        values[S3Field.bucket] = "backups"
        values[bool: S3Field.usePathStyle] = true
        #expect(S3FieldSchema.requestOrigin(values) == "https://minio.example.test:9000")
    }

    /// A bucket-list session has no bucket to put in front of the host, in
    /// either style — the same reason `S3FileSystem.bucketListURL` does not
    /// go through `requestURL`.
    @Test func aBucketListSessionHasNoBucketToPutInFrontOfTheHost() {
        var values = FieldValues()
        values[S3Field.endpoint] = "minio.example.test:9000"
        values[S3Field.bucket] = "backups"
        values[bool: S3Field.usePathStyle] = false
        values[bool: S3Field.startsAtBucketList] = true
        #expect(S3FieldSchema.requestOrigin(values) == "https://minio.example.test:9000")
    }

    /// The maintainer's own spelling, and the case that made the rule
    /// necessary: `192.0.2.10:9000` with the default addressing would send
    /// the request to `backups.192.0.2.10`, a name no resolver answers. An IP
    /// literal is addressed path-style, so the origin is the host itself.
    @Test func anIPLiteralEndpointIsAddressedPathStyleSoItsOriginIsTheHost() {
        var values = FieldValues()
        values[S3Field.endpoint] = "192.0.2.10:9000"
        values[S3Field.bucket] = "backups"
        values[bool: S3Field.usePathStyle] = false
        #expect(S3FieldSchema.pathStyleIsForced(values))
        #expect(S3FieldSchema.usesPathStyle(values))
        #expect(S3FieldSchema.requestOrigin(values) == "https://192.0.2.10:9000")
    }

    @Test func anIPv6LiteralEndpointIsAddressedPathStyleToo() {
        var values = FieldValues()
        values[S3Field.endpoint] = "[::1]:9000"
        values[S3Field.bucket] = "backups"
        values[bool: S3Field.usePathStyle] = false
        #expect(S3FieldSchema.pathStyleIsForced(values))
        #expect(S3FieldSchema.requestOrigin(values) == "https://[::1]:9000")
    }

    /// A named host is left to the user's own choice of addressing.
    @Test func aNamedHostDoesNotForceAnAddressingStyle() {
        var values = FieldValues()
        values[S3Field.endpoint] = "minio.example.test:9000"
        #expect(S3FieldSchema.pathStyleIsForced(values) == false)
    }

    /// The endpoint field is ordinary input, and a credential can be typed
    /// into it (`https://KEY:SECRET@host` — a spelling `S3AccessProbe`
    /// already reckons with). Everything this file composes is scheme, host
    /// and port, so no userinfo can reach a screen through it.
    ///
    /// The secret lives in a named constant and every answer is reduced to a
    /// `Bool` BEFORE the expectation: `#expect` reports the SOURCE TEXT of
    /// what it checks, so a secret written into an expectation leaks through
    /// the failure message — the one exit a test opens by itself.
    @Test func noCredentialInTheEndpointReachesTheOriginOrTheCanonicalSpelling() {
        let key = "AKIAEXAMPLE"
        let secret = "s3cr3t-do-not-print"
        var values = FieldValues()
        values[S3Field.endpoint] = "https://\(key):\(secret)@minio.example.test:9000"
        values[S3Field.bucket] = "backups"
        values[bool: S3Field.usePathStyle] = true

        let origin = S3FieldSchema.requestOrigin(values) ?? ""
        let canonical = S3FieldSchema.canonicalEndpoint(values[S3Field.endpoint]) ?? ""
        let summary = S3FieldSchema.displaySummary(values)
        let originIsClean = !origin.contains(secret) && !origin.contains(key)
        let canonicalIsClean = !canonical.contains(secret) && !canonical.contains(key)
        let summaryIsClean = !summary.contains(secret) && !summary.contains(key)

        #expect(originIsClean)
        #expect(canonicalIsClean)
        #expect(summaryIsClean)
        #expect(origin == "https://minio.example.test:9000")
    }
}
