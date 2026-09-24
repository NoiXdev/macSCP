import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// No credential typed into an S3 endpoint or a WebDAV base URL reaches a
/// presigned URL, a request URL, the CLI's session list or any other
/// rendering of the typed text (the small-follow-ups re-review, O-1, O-2
/// and O-3).
///
/// Both fields take `scheme://KEY:SECRET@host` as ordinary input. The
/// renderings read it through ONE filter,
/// `URLText.withoutUserinfo(typedURL:atMayFollowHost:)`, and S3 drops the
/// userinfo at its one parse, `S3FieldSchema.endpointComponents`, so every
/// request, bucket and presigned URL is built without it. S3 also refuses
/// an `@` after the host, in the editor and at that parse (the review of
/// this fix, M-1), which leaves the known limit of the WebDAV door
/// (`aHostLikeTextAfterAnAtInTheSecretIsAKnownLimitOfTheWebDAVDoor`) to
/// WebDAV alone.
///
/// Every value that must not leak is a named constant, and every
/// expectation reads a `Bool` or an index list computed before it
/// (CLAUDE.md, "A value a test must not leak has two exits").
@Suite("No credential typed into an endpoint reaches a rendering", .timeLimit(.minutes(2)))
struct TypedEndpointSecrecyTests {
    // MARK: - The values that must not leak

    static let user = "sentinel-typed-user-4b7e"
    /// A `/`: the shape of a real S3 secret key, and the one that ended the
    /// old authority scan before the `@`.
    static let slashSecret = "sentinel-c2/typed-d3"
    /// A second `@` inside the userinfo.
    static let atSecret = "sentinel-e4@typed-f5"
    /// A `:` inside the password, beside the one that separates it.
    static let colonSecret = "sentinel-a6:typed-b7"
    /// A percent-encoded `/`, which is not a delimiter at all.
    static let percentSecret = "sentinel-c8%2Ftyped-d9"
    /// A space, which ends a URL in free text but not in a field.
    static let spaceSecret = "sentinel-e0 typed-f1"
    /// Every separator at once, `#` and `?` included.
    static let everySeparatorSecret =
        "sentinel-a2/typed-b3@typed-c4:typed-d5%2Ftyped-e6 typed-f7#typed-g8?typed-h9"

    static let secrets = [
        slashSecret, atSecret, colonSecret, percentSecret, spaceSecret, everySeparatorSecret,
    ]
    /// The secrets a `/`, `?` or `#` does not interrupt: the only ones for
    /// which a credential and an `@` in the path can both be read back
    /// exactly (see `aCredentialBesideAnAtInThePathIsCutAndThePathKept`).
    static let delimiterFreeSecrets = [atSecret, colonSecret, percentSecret, spaceSecret]

    /// Every piece of every secret between its separators, so a text that
    /// carries half of one — what a filter that stopped at the `/` leaves —
    /// is caught too. Every piece is at least eight characters, so none of
    /// them turns up by chance in a hex signature. The one exception is left
    /// out rather than shortened: `digitSecret`'s leading `12`, which
    /// Foundation reads as a PORT and which only ever appears right after
    /// the key ID (`user:12`), where `user` is the piece that catches it.
    static let fragments: [String] = ([user, parseableSecret] + secrets + atAfterHostSecrets).flatMap { secret in
        secret.replacingOccurrences(of: "%2F", with: "/")
            .split(whereSeparator: { "/@: #?".contains($0) }).map(String.init)
    }.filter { !$0.allSatisfy(\.isNumber) }

    static func leaks(_ text: String) -> Bool {
        fragments.contains { text.contains($0) }
    }

    /// Secrets that put an `@` AFTER the host, for the one door that cannot
    /// tell them from a path (re-review of the endpoint-leak fix, I-1 and
    /// M-1). The first holds an `@`, then a dotted name, then a `/`: the
    /// typed door reads `hl-host.example` as the server and keeps the tail.
    /// The second is a key ID followed by a secret whose text before its
    /// first `/` is a number, which Foundation reads as host and port.
    static let hostLikeSecret = "sentinel-hl@hl-host.example/sentinel-hl-more"
    static let digitSecret = "12/sentinel-dg-rest"
    static let atAfterHostSecrets = [hostLikeSecret, digitSecret]

    // MARK: - The sanitizer

    /// Every spelling of a credential in front of a host, in each place a
    /// host can be written, with the exact text that must come out.
    static func credentialRows() -> [(input: String, expected: String)] {
        secrets.flatMap { secret -> [(String, String)] in
            [
                ("https://\(user):\(secret)@s3.example.test", "https://s3.example.test"),
                ("https://\(user):\(secret)@s3.example.test:9000/seed",
                 "https://s3.example.test:9000/seed"),
                // Schemeless: the userinfo starts at the first character.
                ("\(user):\(secret)@minio.lan:9000", "minio.lan:9000"),
                ("https://\(user):\(secret)@[2001:db8::1]:9000/dav", "https://[2001:db8::1]:9000/dav"),
                ("https://\(user):\(secret)@[::1]", "https://[::1]"),
                ("HTTP://\(user):\(secret)@192.0.2.10:9000", "HTTP://192.0.2.10:9000"),
                ("  https://\(user):\(secret)@s3.example.test  ", "https://s3.example.test"),
                ("https://:\(secret)@s3.example.test", "https://s3.example.test"),
            ]
        } + [("https://\(user)@s3.example.test/dav", "https://s3.example.test/dav")]
    }

    /// No credential, so nothing may change — above all not a path or a
    /// query that carries an `@` of its own. The Nextcloud rows are the
    /// ones a WebDAV user really types: the files collection is named after
    /// the account, and an account is often an e-mail address.
    static let untouchedRows = [
        "https://s3.example.test",
        "minio.lan:9000",
        "192.0.2.10:9000",
        "https://[::1]:9000",
        "",
        "https://cloud.example.com/remote.php/dav/files/alice@example.com/",
        "https://cloud.example.com:8443/remote.php/dav/files/alice@example.com/",
        "https://[2001:db8::1]/dav/alice@example.com/",
        "http://192.0.2.10:8080/dav/alice@example.com/",
        "http://localhost:8080/dav/alice@example.com",
        "https://dav.example.com/dav?owner=alice@example.com",
        "https://dav.example.com/dav#alice@example.com",
        "dav.example.com/files/alice@example.com",
    ]

    @Test func everyFragmentIsLongEnoughToMeanSomething() {
        let short = Self.fragments.filter { $0.count < 8 }
        #expect(Self.fragments.count > Self.secrets.count, "the secrets no longer split into pieces")
        #expect(short.isEmpty, "\(short.count) fragments shorter than eight characters")
    }

    @Test func everyCredentialSpellingIsCutAndTheServerKept() {
        let rows = Self.credentialRows()
        let outputs = rows.map { URLText.withoutUserinfo(typedURL: $0.input, atMayFollowHost: true) }
        let leaking = outputs.indices.filter { Self.leaks(outputs[$0]) }
        let wrong = outputs.indices.filter { outputs[$0] != rows[$0].expected }
        #expect(rows.count == Self.secrets.count * 8 + 1, "the table lost rows")
        #expect(leaking.isEmpty, "rows still carrying a credential, by index: \(leaking)")
        #expect(wrong.isEmpty, "rows that did not come out as the bare server, by index: \(wrong)")
    }

    @Test func aURLWithoutACredentialIsLeftAlone() {
        let changed = Self.untouchedRows.indices.filter {
            URLText.withoutUserinfo(typedURL: Self.untouchedRows[$0], atMayFollowHost: true)
                != Self.untouchedRows[$0]
        }
        #expect(changed.isEmpty, "rows the filter changed, by index: \(changed)")
    }

    /// A credential AND an `@` in the path: the authority is cut at its own
    /// last `@`, because what follows it is a server address, and the path
    /// is kept.
    @Test func aCredentialBesideAnAtInThePathIsCutAndThePathKept() {
        let path = "/remote.php/dav/files/alice@example.com/"
        let outputs = Self.delimiterFreeSecrets.map {
            URLText.withoutUserinfo(
                typedURL: "https://\(Self.user):\($0)@cloud.example.com\(path)", atMayFollowHost: true)
        }
        let leaking = outputs.indices.filter { Self.leaks(outputs[$0]) }
        let wrong = outputs.indices.filter { outputs[$0] != "https://cloud.example.com\(path)" }
        #expect(leaking.isEmpty, "rows still carrying a credential, by index: \(leaking)")
        #expect(wrong.isEmpty, "rows whose path was not kept, by index: \(wrong)")
    }

    /// The tie the rule breaks toward the secret: a `/` in the secret AND an
    /// `@` in the path read the same as a host followed by a path, and the
    /// text before the first `/` (`user:secret-start`) is no server
    /// address. Everything up to the LAST `@` goes; the path's own `@` is
    /// the price, and the rendering shows `example.com/`. A mangled path in
    /// a rendering costs a confused reader; a kept secret costs the secret.
    @Test func aSlashInTheSecretBesideAnAtInThePathFailsTowardTheSecret() {
        let outputs = [Self.slashSecret, Self.everySeparatorSecret].map {
            URLText.withoutUserinfo(
                typedURL: "https://\(Self.user):\($0)@cloud.example.com/files/alice@example.com/",
                atMayFollowHost: true)
        }
        let leaking = outputs.indices.filter { Self.leaks(outputs[$0]) }
        let keepsAServer = outputs.allSatisfy { $0 == "https://example.com/" }
        #expect(leaking.isEmpty, "rows still carrying a credential, by index: \(leaking)")
        #expect(keepsAServer, "the over-strip no longer ends at the last @")
    }

    /// The free-text door shares the rule: a `/` in the secret no longer
    /// ends the authority before the `@` (the hole the helper's doc used to
    /// state), and a URL inside a sentence still ends at the next space.
    @Test func freeTextLosesASlashBearingCredentialToo() {
        let sentence =
            "connect failed: https://\(Self.user):\(Self.slashSecret)@s3.example.test:9000/seed; mail admin@example.com"
        let stripped = URLText.withoutUserinfo(sentence)
        let leaks = Self.leaks(stripped)
        let keepsTheRest =
            stripped == "connect failed: https://s3.example.test:9000/seed; mail admin@example.com"
        #expect(leaks == false)
        #expect(keepsTheRest)
    }

    // MARK: - O-2: S3 builds no URL with the userinfo in it

    /// A secret the endpoint still parses with (an `@` and a `%2F`, no raw
    /// `/`): the one shape that used to reach a presigned URL.
    static let parseableSecret = "sentinel-p1@typed-p2%2Ftyped-p3"
    static let parseableEndpoint = "https://\(user):\(parseableSecret)@s3.example.test:9000"

    static let emptyListingXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """

    static let bucketListXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Buckets><Bucket><Name>macscp-seed</Name>
            <CreationDate>2024-01-02T03:04:05.000Z</CreationDate></Bucket></Buckets>
        </ListAllMyBucketsResult>
        """

    static func config(usePathStyle: Bool, startsAtBucketList: Bool = false) -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: "AKIAPRESIGNTEST", secretAccessKey: "SK", region: "us-east-1",
            endpoint: parseableEndpoint, bucket: "macscp-seed", usePathStyle: usePathStyle,
            sessionToken: nil, startsAtBucketList: startsAtBucketList)
    }

    static func ok() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://s3.example.test:9000/")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    /// The link `PresignedURLSheet` shows so the user can hand it on, and
    /// the request the dial sent, in both addressing styles.
    @Test(arguments: [true, false])
    func aPresignedURLCarriesNoCredentialTypedIntoTheEndpoint(usePathStyle: Bool) async throws {
        let transport = FakeS3Transport(responses: [(Data(Self.emptyListingXML.utf8), Self.ok())])
        let fs = try await S3FileSystem.connect(Self.config(usePathStyle: usePathStyle), transport: transport)
        let presigned = try fs.presignedURL(method: .get, key: "a.txt", expiresIn: 600)
        let sent = await transport.requests.compactMap(\.url)

        let presignedLeaks = Self.leaks(presigned.absoluteString)
        let presignedHasUserinfo = presigned.user != nil || presigned.password != nil
        let sentLeaks = sent.contains { Self.leaks($0.absoluteString) }
        let presignedNamesTheServer = presigned.host?.hasSuffix("s3.example.test") == true
        #expect(sent.isEmpty == false, "the dial sent no request")
        #expect(presignedLeaks == false, "the presigned URL carries the endpoint's credential")
        #expect(presignedHasUserinfo == false)
        #expect(sentLeaks == false, "a request URL carries the endpoint's credential")
        #expect(presignedNamesTheServer)
    }

    /// The account-level `ListBuckets` URL has its own builder.
    @Test func theBucketListURLCarriesNoCredentialTypedIntoTheEndpoint() async throws {
        let transport = FakeS3Transport(responses: [(Data(Self.bucketListXML.utf8), Self.ok())])
        _ = try await S3FileSystem.connect(
            Self.config(usePathStyle: true, startsAtBucketList: true), transport: transport)
        let sent = await transport.requests.compactMap(\.url)
        let sentLeaks = sent.contains { Self.leaks($0.absoluteString) }
        #expect(sent.isEmpty == false, "the dial sent no request")
        #expect(sentLeaks == false, "the bucket-list URL carries the endpoint's credential")
    }

    /// Dropped at the one parse, so every consumer of it is clean — the
    /// form's "Connects to" origin and the diagnosis's endpoint included.
    @Test func theParseDropsTheUserinfo() throws {
        let components = try #require(S3FieldSchema.endpointComponents(Self.parseableEndpoint))
        let hasUserinfo = components.user != nil || components.password != nil
        let keepsTheServer = components.host == "s3.example.test" && components.port == 9000
        #expect(hasUserinfo == false)
        #expect(keepsTheServer)
    }

    // MARK: - O-3: the CLI's session list

    @Test func theCLISessionListCarriesNoCredential() {
        let sessions = Self.secrets.enumerated().flatMap { index, secret in
            [
                s3Session(
                    name: "s3-\(index)",
                    config: StoredS3Config(
                        accessKeyID: "AKIA", region: "eu-central-1",
                        endpoint: "https://\(Self.user):\(secret)@s3.example.test",
                        bucket: "bucket", usePathStyle: false)),
                webdavSession(
                    name: "dav-\(index)",
                    config: StoredWebDAVConfig(
                        baseURL: "https://\(Self.user):\(secret)@dav.example.test/dav",
                        username: "tim", useNextcloudPath: false)),
            ]
        }
        let rows = SessionCatalog(sessions: sessions, groups: []).rows(matching: .init())
        let leaking = rows.filter { Self.leaks($0.target) }.map(\.name)
        let namesTheServers = rows.allSatisfy {
            $0.target == "bucket @ https://s3.example.test" || $0.target == "https://dav.example.test/dav"
        }
        #expect(rows.count == sessions.count)
        #expect(leaking.isEmpty, "rows carrying a credential: \(leaking)")
        #expect(namesTheServers, "a target no longer names its server")
    }

    // MARK: - The other renderings

    /// The summary in the sidebar and every audit entry: an endpoint that
    /// does not parse used to fall back to the raw text.
    @Test func theSessionSummaryCarriesNoCredential() {
        let summaries = Self.secrets.flatMap { secret -> [String] in
            var s3 = FieldValues()
            s3[S3Field.endpoint] = "https://\(Self.user):\(secret)@s3.example.test"
            s3[S3Field.bucket] = "bucket"
            var dav = FieldValues()
            dav[WebDAVField.baseURL] = "https://\(Self.user):\(secret)@dav.example.test/dav"
            dav[WebDAVField.username] = "tim"
            return [S3FieldSchema.displaySummary(s3), WebDAVFieldSchema.displaySummary(dav)]
        }
        let leaking = summaries.indices.filter { Self.leaks(summaries[$0]) }
        let namesTheServers = summaries.allSatisfy { $0.contains("example.test") }
        #expect(leaking.isEmpty, "summaries carrying a credential, by index: \(leaking)")
        #expect(namesTheServers)
    }

    /// The session overview, with the secrets the old filter could not cut.
    @Test func theSessionOverviewCarriesNoCredential() {
        let texts = Self.secrets.flatMap { secret -> [String] in
            let s3 = s3Session(
                name: "s3",
                config: StoredS3Config(
                    accessKeyID: "AKIA", region: "eu-central-1",
                    endpoint: "https://\(Self.user):\(secret)@s3.example.test",
                    bucket: "bucket", usePathStyle: false))
            let dav = webdavSession(
                name: "dav",
                config: StoredWebDAVConfig(
                    baseURL: "https://\(Self.user):\(secret)@dav.example.test/dav",
                    username: "tim", useNextcloudPath: false))
            return [s3, dav].flatMap { session in
                SessionOverviewModel(
                    session: session, descriptor: .descriptor(for: session.kind), knownKey: nil,
                    secrets: NoSecrets(), events: [], snippets: []
                ).facts.map(\.text)
            }
        }
        let leaking = texts.indices.filter { Self.leaks(texts[$0]) }
        let namesTheServers =
            texts.contains("https://s3.example.test") && texts.contains("https://dav.example.test/dav")
        #expect(leaking.isEmpty, "facts carrying a credential, by index: \(leaking)")
        #expect(namesTheServers)
    }

    // MARK: - The known limit of the WebDAV door (re-review I-1)

    /// Where the typed door with `atMayFollowHost: true` cannot tell a
    /// secret from a path: the password holds an `@`, then text that reads
    /// as a server address, then a `/`, `?` or `#`. It has the structure of
    /// the Nextcloud row this door exists to keep
    /// (`u:p@cloud.example.com/files/alice@example.com/`), so the door keeps
    /// the tail. This pins TODAY's output, the known leak, so a change to
    /// the rule is a decision someone makes on purpose rather than a
    /// side effect. S3 does not go through this door
    /// (`anS3EndpointWithAnAtAfterTheHostIsRefusedEverywhere`).
    static let knownLimitInput = "https://\(user):\(hostLikeSecret)@dav.example.test/dav"
    static let knownLimitOutput = "https://hl-host.example/sentinel-hl-more@dav.example.test/dav"

    @Test func aHostLikeTextAfterAnAtInTheSecretIsAKnownLimitOfTheWebDAVDoor() {
        let output = URLText.withoutUserinfo(typedURL: Self.knownLimitInput, atMayFollowHost: true)
        let isTodaysOutput = output == Self.knownLimitOutput
        let cutsTheFront = output.contains(Self.user) == false && output.contains("sentinel-hl@") == false
        #expect(isTodaysOutput, "the known limit changed — update the doc of URLText.hostStart(in:) and the BACKLOG row")
        #expect(cutsTheFront)
    }

    // MARK: - S3 refuses an @ after the host (re-review M-1)

    static let atAfterHostEndpoints = [
        "https://\(user):\(digitSecret)@s3.example.test",
        "https://\(user):\(hostLikeSecret)@s3.example.test/dav",
        "\(user):\(hostLikeSecret)@s3.example.test:9000",
        "https://s3.example.test/path?owner=someone@example.test",
    ]

    /// Endpoints that must keep working: a port, a path, a schemeless one,
    /// an IP literal, and a credential in FRONT of the host (dropped by the
    /// parse, and no `@` after the host).
    static let acceptedEndpoints = [
        "https://s3.example.test:9000/some/path",
        "https://s3.example.test",
        "minio.lan:9000",
        "http://[::1]:9000/",
        "https://\(user):\(colonSecret)@s3.example.test:9000/seed",
    ]

    static func s3Values(endpoint: String) -> FieldValues {
        var values = BackendDescriptor.descriptor(for: .s3).defaultValues
        values[S3Field.endpoint] = endpoint
        values[S3Field.region] = "eu-central-1"
        values[S3Field.bucket] = "bucket"
        values[S3Field.accessKeyID] = "AKIA"
        values[S3Field.secretAccessKey] = "SK"
        return values
    }

    /// The session editor: the same field-validation shape as a blank
    /// field, with the endpoint's own message.
    @Test func anS3EndpointWithAnAtAfterTheHostIsAValidationError() {
        let violations = Self.atAfterHostEndpoints.map {
            BackendDescriptor.descriptor(for: .s3).firstViolation(in: Self.s3Values(endpoint: $0), requireSecrets: true)
        }
        let wrong = violations.indices.filter {
            violations[$0]?.messageKey != "core.connect.s3EndpointInvalid"
                || violations[$0]?.fieldKey != "S3Field.endpoint"
        }
        #expect(wrong.isEmpty, "endpoints not refused with the endpoint's message, by index: \(wrong)")
    }

    @Test func aNormalS3EndpointStillPassesAndParses() {
        let refused = Self.acceptedEndpoints.indices.filter {
            BackendDescriptor.descriptor(for: .s3)
                .firstViolation(in: Self.s3Values(endpoint: Self.acceptedEndpoints[$0]), requireSecrets: true) != nil
        }
        let unparsed = Self.acceptedEndpoints.indices.filter {
            S3FieldSchema.endpointComponents(Self.acceptedEndpoints[$0])?.host?.isEmpty != false
        }
        #expect(refused.isEmpty, "accepted endpoints refused, by index: \(refused)")
        #expect(unparsed.isEmpty, "accepted endpoints the parse no longer reads, by index: \(unparsed)")
    }

    /// The one parse refuses it too, so a stored session that already holds
    /// such an endpoint — saved before this rule, or written by the CLI or
    /// an import — reaches no request, and every rendering that reads the
    /// parse (the sidebar's summary, the audit entries, "Connects to", the
    /// diagnosis endpoint) falls back to nothing or to the S3 door.
    @Test func theS3ParseRefusesAnAtAfterTheHost() {
        let parsed = Self.atAfterHostEndpoints.indices.filter {
            S3FieldSchema.endpointComponents(Self.atAfterHostEndpoints[$0]) != nil
        }
        #expect(parsed.isEmpty, "endpoints the parse still reads, by index: \(parsed)")
    }

    /// Every S3 rendering, for every endpoint with an `@` after the host.
    @Test func noS3RenderingOfAnAtAfterTheHostEndpointCarriesTheCredential() {
        var texts: [String] = []
        for endpoint in Self.atAfterHostEndpoints {
            let values = Self.s3Values(endpoint: endpoint)
            texts.append(S3FieldSchema.displaySummary(values))
            texts.append(S3FieldSchema.canonicalEndpoint(endpoint) ?? "")
            texts.append(S3FieldSchema.requestOrigin(values) ?? "")
            texts.append(S3FieldSchema.endpoint(values)?.text ?? "")
            let session = s3Session(
                name: "s3",
                config: StoredS3Config(
                    accessKeyID: "AKIA", region: "eu-central-1", endpoint: endpoint,
                    bucket: "bucket", usePathStyle: false))
            texts += SessionCatalog(sessions: [session], groups: []).rows(matching: .init()).map(\.target)
            texts += SessionOverviewModel(
                session: session, descriptor: .descriptor(for: .s3), knownKey: nil,
                secrets: NoSecrets(), events: [], snippets: []
            ).facts.map(\.text)
        }
        let leaking = texts.indices.filter { Self.leaks(texts[$0]) }
        let namesTheServer = texts.contains { $0.contains("s3.example.test") }
        #expect(leaking.isEmpty, "renderings carrying a credential, by index: \(leaking)")
        #expect(namesTheServer)
    }

    /// A stored session holding such an endpoint: the CLI's builder refuses
    /// it with the field's LABEL (never its value), and a dial that got past
    /// it anyway meets the parse's fixed sentence. Nothing traps.
    @Test func aStoredSessionWithAnAtAfterTheHostFailsWithAFixedSentence() async {
        var outcomes: [String] = []
        for endpoint in Self.atAfterHostEndpoints {
            let session = s3Session(
                name: "s3",
                config: StoredS3Config(
                    accessKeyID: "AKIA", region: "eu-central-1", endpoint: endpoint,
                    bucket: "bucket", usePathStyle: true))
            do {
                _ = try StoredSessionConnectionConfig.build(for: session, secret: "SK", checkedSources: [])
                outcomes.append("built")
            } catch StoredSessionConnectionError.incompleteConfiguration(let field) {
                outcomes.append("incomplete:\(field)")
            } catch {
                outcomes.append("other")
            }
            let config = S3ConnectionConfig(
                accessKeyID: "AKIA", secretAccessKey: "SK", region: "eu-central-1",
                endpoint: endpoint, bucket: "bucket", usePathStyle: true, sessionToken: nil,
                startsAtBucketList: false)
            do {
                _ = try await S3FileSystem.connect(config, transport: FakeS3Transport(responses: []))
                outcomes.append("connected")
            } catch RemoteFSError.connectionFailed(let reason) {
                outcomes.append(reason == S3EndpointReason.unparseable ? "unparseable" : "reason-leak:\(Self.leaks(reason))")
            } catch {
                outcomes.append("other")
            }
        }
        let label = BackendDescriptor.descriptor(for: .s3).fieldLabel(forKey: "S3Field.endpoint")
        let expected = Array(repeating: ["incomplete:\(label)", "unparseable"], count: Self.atAfterHostEndpoints.count)
            .flatMap { $0 }
        let asExpected = outcomes == expected
        #expect(asExpected, "outcomes: \(outcomes.map { $0.hasPrefix("incomplete:") ? "incomplete" : $0 })")
    }

    /// The editor shows the violation on the endpoint field, in the
    /// catalogue's words, when the form is resolved for a save or a dial.
    @MainActor
    @Test func theEditorShowsTheEndpointsOwnMessage() {
        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.kind = .s3
        vm.values = Self.s3Values(endpoint: Self.atAfterHostEndpoints[0])
        let resolution = vm.resolveConfigWithoutDialing()
        var shown: String?
        if case .failed(.failed(let message, _)) = resolution { shown = message }
        let isTheEndpointMessage = shown == CoreL10n.string("core.connect.s3EndpointInvalid")
        let leaks = Self.leaks(shown ?? "")
        #expect(isTheEndpointMessage)
        #expect(leaks == false)
    }

    private struct NoSecrets: SecretPresence {
        func hasSecret(for slot: UUID) -> Bool { false }
    }

    // MARK: - The guard: no rendering bypasses the filter

    /// Every Swift file under `Sources/`, read with comments blanked and
    /// strings kept (an interpolation sits inside a string literal).
    ///
    /// A READ is one of the typed values: the stored or runtime config's
    /// `endpoint`/`baseURL` property (named by reading the types, not by
    /// spelling them) on a receiver, or the field bag's
    /// `[S3Field.endpoint]`/`[WebDAVField.baseURL]`. A RENDERING of a read
    /// is one of six shapes: inside an interpolation, beside a `+`, on a
    /// line that calls `String(format:`, after `return`, after `??`, or as a
    /// `text:` argument. A read inside `URLText.withoutUserinfo(typedURL:`
    /// is not one.
    ///
    /// The negative stands beside positives: the scan found files, it found
    /// reads (so its read pattern still matches the tree), and the filter is
    /// called by name in each file that renders the typed text today.
    @Test func noRenderingOfATypedEndpointBypassesTheFilter() throws {
        let files = try SourceCorpus.files(under: SourceCorpus.url(of: .sources))
            .filter { $0.pathExtension == "swift" }
        let sources = try SourceCorpus.commentFree(ofAll: files)
        var reads = 0
        var found: [String] = []
        for (file, source) in zip(files, sources) {
            for line in source.split(separator: "\n") {
                reads += Self.reads(in: String(line)).count
                if Self.rendersARead(String(line)) {
                    found.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        let byName = Dictionary(zip(files.map(\.lastPathComponent), sources), uniquingKeysWith: { a, _ in a })
        let filterMissing = Self.renderingFiles.filter { byName[$0]?.contains(Self.filterCall) != true }
        #expect(files.count > 100, "the scan found too few sources — moved?")
        #expect(reads >= 20, "the read pattern matches almost nothing any more — renamed?")
        #expect(filterMissing.isEmpty, "files that no longer call the filter: \(filterMissing)")
        #expect(found.isEmpty, "\(found)")
    }

    /// The guard is not blind to any shape it forbids, nor to a read it
    /// must allow.
    @Test func theGuardSeesEveryRenderingShape() {
        let planted = [
            #"return "\(s3.bucket) @ \(s3.endpoint)""#,
            #"let a = "host=" + webdav.baseURL"#,
            #"let b = String(format: "%@", config.endpoint)"#,
            "return webdav.baseURL",
            "let host = hostText ?? values[S3Field.endpoint]",
            "Fact(id: \"x\", text: stored.baseURL)",
            #"let c = "\(values[WebDAVField.baseURL])""#,
        ]
        let allowed = [
            #"return "\(s3.bucket) @ \(URLText.withoutUserinfo(typedURL: s3.endpoint, atMayFollowHost: false))""#,
            "guard var components = S3FieldSchema.endpointComponents(config.endpoint) else {",
            "text: URLText.withoutUserinfo(typedURL: webdav.baseURL, atMayFollowHost: true), isMonospaced: true))",
            "values[S3Field.endpoint] = stored.endpoint",
            "return (URLText.withoutUserinfo(typedURL: s3.endpoint, atMayFollowHost: false), \"-\", \"s3\")",
            "if let endpoint = model.endpoint {",
        ]
        let missed = planted.indices.filter { Self.rendersARead(planted[$0]) == false }
        let overreached = allowed.indices.filter { Self.rendersARead(allowed[$0]) }
        #expect(missed.isEmpty, "planted renderings the guard missed, by index: \(missed)")
        #expect(overreached.isEmpty, "allowed lines the guard flagged, by index: \(overreached)")
    }

    static let filterCall = "URLText.withoutUserinfo(typedURL:"

    /// Where the typed text is rendered today — each must call the filter.
    static let renderingFiles = [
        "SessionCatalog.swift", "SessionOverviewModel.swift", "ConnectionViewModel.swift",
        "S3FieldSchema.swift", "WebDAVFieldSchema.swift", "ImportPreviewPlanner.swift",
    ]

    /// The property names the typed text lives under, read off the types.
    static let propertyNames: Set<String> = {
        let s3 = StoredS3Config(
            accessKeyID: "", region: "", endpoint: "\u{1}", bucket: "", usePathStyle: false)
        let dav = StoredWebDAVConfig(baseURL: "\u{1}", username: "", useNextcloudPath: false)
        let labels = [Mirror(reflecting: s3), Mirror(reflecting: dav)].flatMap { mirror in
            mirror.children.compactMap { child in (child.value as? String) == "\u{1}" ? child.label : nil }
        }
        return Set(labels)
    }()

    /// The field-bag keys, derived from the field enums.
    static let bagKeys: [String] = [
        "[\(String(describing: S3Field.self)).\(S3Field.endpoint.rawValue)]",
        "[\(String(describing: WebDAVField.self)).\(WebDAVField.baseURL.rawValue)]",
    ]

    /// The ranges of every read in `line`: a bag key, or a property read on
    /// a lower-case receiver (a value, never a type such as `S3Field`)
    /// that is not immediately called or assigned to.
    static func reads(in line: String) -> [Range<String.Index>] {
        // A bag read's range starts at its receiver (`values[…]`), so the
        // text in front of it is what the rendering shapes look at.
        let patterns =
            bagKeys.map { #"\b[a-z][A-Za-z0-9_]*"# + NSRegularExpression.escapedPattern(for: $0) }
            + propertyNames.map { #"\b[a-z][A-Za-z0-9_]*[?!]?\."# + $0 + #"\b(?!\s*\()(?!\s*=[^=])"# }
        var ranges: [Range<String.Index>] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let whole = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: whole) {
                if let range = Range(match.range, in: line) { ranges.append(range) }
            }
        }
        return ranges
    }

    /// Whether `line` renders a read that does not sit inside the filter.
    static func rendersARead(_ line: String) -> Bool {
        let bare = line.replacingOccurrences(
            of: #"URLText\.withoutUserinfo\(typedURL:[^()]*(\([^()]*\))*[^()]*\)"#, with: "FILTERED",
            options: .regularExpression)
        let reads = reads(in: bare)
        guard !reads.isEmpty else { return false }
        if bare.contains("String(format:") { return true }
        for read in reads {
            let before = bare[..<read.lowerBound]
            let after = bare[read.upperBound...]
            let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
            let afterTrimmed = after.trimmingCharacters(in: .whitespaces)
            if Self.isInsideInterpolation(bare, at: read.lowerBound) { return true }
            if beforeTrimmed.hasSuffix("+") || afterTrimmed.hasPrefix("+") { return true }
            if beforeTrimmed.hasSuffix("return") || beforeTrimmed.hasSuffix("??")
                || beforeTrimmed.hasSuffix("text:")
            {
                return true
            }
        }
        return false
    }

    /// Whether `index` sits inside an open `\(` … `)` of `line`.
    static func isInsideInterpolation(_ line: String, at index: String.Index) -> Bool {
        var rest = line[..<index]
        while let open = rest.range(of: #"\("#, options: .backwards) {
            var depth = 1
            for character in line[open.upperBound..<index] {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0 { break }
            }
            if depth > 0 { return true }
            rest = rest[..<open.lowerBound]
        }
        return false
    }
}
