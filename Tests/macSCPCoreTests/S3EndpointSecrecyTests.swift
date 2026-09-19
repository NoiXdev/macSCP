import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// No S3 error text carries the endpoint the user typed (final review of the
/// 2026-09-19 small follow-ups, I-2).
///
/// The endpoint field takes `https://KEY:SECRET@host` as ordinary input, and
/// the S3 throw sites that refuse an endpoint which cannot become a request
/// used to interpolate it into `connectionFailed(reason:)`. They fire for
/// exactly such an endpoint: a `/` in the secret — AWS secret keys routinely
/// carry one — makes the whole string unparseable, and the same `/` ended
/// `URLText.withoutUserinfo`'s authority scan before the `@` (until the
/// re-review's O-1 fix), so no filter further down could clean the text.
/// Their reasons are fixed sentences now (`S3EndpointReason`), which name
/// the part that failed and never its value.
///
/// Every value that must not leak is a named constant, and every expectation
/// reads a `Bool` computed before it (CLAUDE.md, "A value a test must not
/// leak has two exits").
@Suite("No S3 error text carries the typed endpoint", .timeLimit(.minutes(2)))
struct S3EndpointSecrecyTests {
    // MARK: - The values that must not leak

    static let user = "sentinel-endpoint-key-3a9f"
    /// A `/`, which makes the endpoint unparseable (and stopped
    /// `URLText.withoutUserinfo` short until the re-review's O-1 fix), and
    /// an `@`, which puts a second separator inside the userinfo.
    static let secret = "sentinel-a1c7/endpoint-b2d8@secret-c3e9"
    static let unparseableEndpoint = "https://\(user):\(secret)@s3.example.test"

    /// A secret with an `@` and no `/`: the endpoint parses, so it reaches
    /// the builders' later refusals.
    static let parseableSecret = "sentinel-d4f0@secret-e5a1"
    /// An IPv6 literal under virtual-hosted addressing: the bucket cannot be
    /// put in front of a bracketed host, so no request URL can be built.
    static let unbuildableEndpoint = "https://\(user):\(parseableSecret)@[::1]:9000"

    /// Every piece of either secret between its separators, so a text that
    /// carries half of one — what a filter that stopped at the `/` leaves —
    /// is caught too.
    static let secretParts = (secret + "/" + parseableSecret)
        .split(whereSeparator: { "/@".contains($0) }).map(String.init)

    static func leaks(_ text: String) -> Bool {
        text.contains(user) || secretParts.contains { text.contains($0) }
    }

    static func config(
        endpoint: String, usePathStyle: Bool, startsAtBucketList: Bool = false
    ) -> S3ConnectionConfig {
        S3ConnectionConfig(
            accessKeyID: user, secretAccessKey: "SK", region: "us-east-1",
            endpoint: endpoint, bucket: "macscp-seed", usePathStyle: usePathStyle,
            sessionToken: nil, startsAtBucketList: startsAtBucketList)
    }

    /// The reason of the `connectionFailed` a signed request for `shape`
    /// throws, with whether the error's own description carries a secret.
    static func refusal(
        _ shape: S3RequestShape, config: S3ConnectionConfig
    ) -> (reason: String?, describedLeaks: Bool) {
        do {
            _ = try S3FileSystem.signedRequest(shape, method: "GET", config: config)
            return (nil, false)
        } catch {
            let describedLeaks = leaks(String(describing: error))
            guard case RemoteFSError.connectionFailed(let reason) = error else {
                return (nil, describedLeaks)
            }
            return (reason, describedLeaks)
        }
    }

    static let shapes: [S3RequestShape] = [
        .account, .bucketRoot(bucket: "macscp-seed"), .objectKey(bucket: "macscp-seed", key: "a.txt"),
    ]

    // MARK: - Each throw site

    /// The first refusal in every URL builder: the endpoint does not parse.
    /// Every shape, in both addressing styles.
    @Test(arguments: shapes, [true, false])
    func anUnparseableEndpointIsRefusedWithAFixedSentence(
        _ shape: S3RequestShape, usePathStyle: Bool
    ) {
        let (reason, describedLeaks) = Self.refusal(
            shape, config: Self.config(endpoint: Self.unparseableEndpoint, usePathStyle: usePathStyle))
        let reasonLeaks = Self.leaks(reason ?? "")
        let isTheFixedSentence = reason == S3EndpointReason.unparseable
        #expect(reason != nil, "no connectionFailed was thrown")
        #expect(reasonLeaks == false, "the reason carries the endpoint's credential")
        #expect(describedLeaks == false, "the error's description carries the endpoint's credential")
        #expect(isTheFixedSentence)
    }

    /// The builders' refusal of a URL they cannot rebuild with the bucket in
    /// it: an IPv6 host under virtual-hosted addressing.
    @Test(arguments: [
        S3RequestShape.bucketRoot(bucket: "macscp-seed"), .objectKey(bucket: "macscp-seed", key: "a.txt"),
    ])
    func anEndpointNoRequestURLCanBeBuiltFromIsRefusedWithAFixedSentence(_ shape: S3RequestShape) {
        let (reason, describedLeaks) = Self.refusal(
            shape, config: Self.config(endpoint: Self.unbuildableEndpoint, usePathStyle: false))
        let reasonLeaks = Self.leaks(reason ?? "")
        let isTheFixedSentence = reason == S3EndpointReason.requestURLUnbuildable
        #expect(reason != nil, "no connectionFailed was thrown")
        #expect(reasonLeaks == false, "the reason carries the endpoint's credential")
        #expect(describedLeaks == false, "the error's description carries the endpoint's credential")
        #expect(isTheFixedSentence)
    }

    /// The signer's refusal of a URL with no host. It interpolated the
    /// configured endpoint, not the URL it was handed, so the configured
    /// endpoint is the one that holds the credential here.
    @Test func theSignerRefusesAHostlessURLWithAFixedSentence() throws {
        let hostless = try #require(URL(string: "https:///macscp-seed"))
        var reason: String?
        var describedLeaks = false
        do {
            _ = try S3RequestSigning.signedRequest(
                url: hostless, method: "GET", canonicalPath: "/macscp-seed", query: [],
                extraHeaders: [:], body: nil, payloadHash: SigV4Signer.emptyPayloadHash,
                config: Self.config(endpoint: Self.unparseableEndpoint, usePathStyle: true))
        } catch {
            describedLeaks = Self.leaks(String(describing: error))
            if case RemoteFSError.connectionFailed(let text) = error { reason = text }
        }
        let reasonLeaks = Self.leaks(reason ?? "")
        let isTheFixedSentence = reason == S3EndpointReason.noHost
        #expect(reason != nil, "no connectionFailed was thrown")
        #expect(reasonLeaks == false, "the reason carries the endpoint's credential")
        #expect(describedLeaks == false, "the error's description carries the endpoint's credential")
        #expect(isTheFixedSentence)
    }

    // MARK: - Every surface a dial's failure reaches

    /// A dial with the unparseable endpoint, in both root modes, read back
    /// through every place its error is shown: the CLI's stderr line, the
    /// connect form, the queue, the browser banner and the diagnostics
    /// sentence. The connect form is the one that printed the reason
    /// unfiltered (`ConnectionViewModel.failedState`), the CLI the other.
    @Test(arguments: [false, true])
    @MainActor func aDialWithTheEndpointPutsItOnNoSurface(startsAtBucketList: Bool) async {
        let config = Self.config(
            endpoint: Self.unparseableEndpoint, usePathStyle: true,
            startsAtBucketList: startsAtBucketList)
        var thrown: (any Error)?
        do {
            _ = try await S3FileSystem.connect(config, transport: FakeS3Transport(responses: []))
        } catch {
            thrown = error
        }
        guard let error = thrown else {
            Issue.record("the dial did not fail")
            return
        }
        var form = ""
        if case .failed(let message, _) = ConnectionViewModel.failedState(for: error) { form = message }
        let cli = CLIErrorMapping.message(for: error)
        let surfaces = [
            String(describing: error), cli, form,
            TransferQueueViewModel.message(for: error),
            RemoteBrowserViewModel.message(for: error, path: "/"),
            DialSupport.reason(for: error),
        ]
        let leaking = surfaces.indices.filter { Self.leaks(surfaces[$0]) }
        let exitsAsAConnectionFailure = CLIErrorMapping.exitCode(for: error) == .connection
        let cliNamesTheRefusal = cli.contains(S3EndpointReason.unparseable)
        let formNamesTheRefusal = form.contains(S3EndpointReason.unparseable)
        #expect(leaking.isEmpty, "surfaces carrying the credential, by index: \(leaking)")
        #expect(exitsAsAConnectionFailure)
        #expect(cliNamesTheRefusal, "the CLI no longer says what was refused")
        #expect(formNamesTheRefusal, "the connect form no longer says what was refused")
    }

    // MARK: - The guard: no S3 source interpolates an endpoint into text

    /// Read with comments blanked and strings kept (`SourceCorpus
    /// .commentFree`): an interpolation sits inside a string literal, which
    /// the code-only view blanks. Covers every Swift file of the S3 backend,
    /// so a new throw site in a new file is read too.
    ///
    /// The negative stands beside positives: the backend's files are found,
    /// the builders still read the configured endpoint (so the scan is over
    /// the code that holds the value), and the fixed sentences are what the
    /// refusals now use.
    @Test func noS3SourceInterpolatesAnEndpointIntoText() throws {
        let directory = SourceCorpus.url(of: .sources)
            .appendingPathComponent("macSCPCore/S3", isDirectory: true)
        let files = try SourceCorpus.files(under: directory).filter { $0.pathExtension == "swift" }
        let sources = try SourceCorpus.commentFree(ofAll: files)
        let joined = sources.joined(separator: "\n")
        let readsTheEndpoint = joined.contains(Self.endpointRead)
        let usesTheFixedSentences = joined.contains("\(String(describing: S3EndpointReason.self)).")
        #expect(files.isEmpty == false, "no S3 source was found — moved?")
        #expect(readsTheEndpoint, "no S3 source reads the configured endpoint any more — renamed?")
        #expect(usesTheFixedSentences, "the refusals no longer use S3EndpointReason")
        var found: [String] = []
        for (file, source) in zip(files, sources) {
            found += Self.endpointInterpolations(in: source).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(found.isEmpty, "\(found)")
    }

    /// The guard is not blind to what it forbids.
    @Test func theGuardSeesAnEndpointInterpolation() {
        let planted = """
            throw RemoteFSError.connectionFailed(reason: "Invalid S3 endpoint: \\(config.endpoint)")
            let b = "at \\(URLText.withoutUserinfo(config.endpoint))"
            let c = "\\(S3FieldSchema.assumedEndpointScheme)://\\(trimmed)"
            """
        #expect(Self.endpointInterpolations(in: planted).count == 2)
    }

    static let endpointRead = "endpointComponents(config.endpoint)"

    /// Every line of `source` with a string interpolation whose expression —
    /// up to its own closing parenthesis — names an `endpoint`.
    /// Case-sensitive, so the scheme constant `assumedEndpointScheme` is not
    /// one.
    static func endpointInterpolations(in source: String) -> [String] {
        source.split(separator: "\n").filter { line in
            var rest = line[...]
            while let open = rest.range(of: "\\(") {
                let after = rest[open.upperBound...]
                var depth = 1
                let expression = after.prefix { character in
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                    return depth > 0
                }
                if expression.contains("endpoint") { return true }
                rest = after
            }
            return false
        }.map(String.init)
    }
}
