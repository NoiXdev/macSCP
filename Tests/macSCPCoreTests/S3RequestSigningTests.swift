import Foundation
import Testing

@testable import macSCPCore

/// Re-signing a redirect, asked of the signing path directly.
///
/// `S3RedirectControlTests` proves a same-origin hop arrives signed, but a
/// same-origin hop cannot move the `Host` — so it cannot show that the
/// header FOLLOWS the target rather than being copied from the first
/// request. That is the stale-`Host` finding of 2026-08-28, and it is what
/// these tests pin: the signer is handed a target the policy would never
/// allow, precisely because the policy is not what is under test here.
@Suite("S3 request signing")
struct S3RequestSigningTests {

    private static let config = S3ConnectionConfig(
        accessKeyID: "AKIARESIGN", secretAccessKey: "resign-secret-key",
        region: "us-east-1", endpoint: "https://s3.example.com",
        bucket: "bucket", usePathStyle: true, sessionToken: nil)

    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// The finding this closes: after a hop the request used to carry the
    /// `Host` of the origin it started at. Rebuilt through the signing path,
    /// the header is set FOR the new target — there is no old value to
    /// carry, which is why the fix is a construction and not a correction.
    @Test func reSigningSetsTheHostOfTheNewTarget() throws {
        let request = try S3RequestSigning.reSigned(
            target: try url("https://elsewhere.example:8443/bucket/key"), method: "GET",
            body: nil, signedHeaders: [:], unsignedHeaders: [:], config: Self.config)

        #expect(request.value(forHTTPHeaderField: "Host") == "elsewhere.example:8443")
        #expect(request.value(forHTTPHeaderField: "Host") != "s3.example.com",
                "the Host of the configured endpoint survived the rebuild")
        // And the signature covers it: SigV4 always signs `host`, so a
        // request whose signed-header list names it cannot have been signed
        // for a different one.
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("SignedHeaders=host;"))
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIARESIGN/"))
    }

    /// The wire URL is rebuilt with the signer's own encoding rules rather
    /// than passed through, so the query that is sent and the query that was
    /// signed are the same string. Canonical order is sorted by name, which
    /// is the observable half of that.
    @Test func reSigningRebuildsTheQueryCanonically() throws {
        let request = try S3RequestSigning.reSigned(
            target: try url("https://s3.example.com/bucket?b=2&a=1"), method: "GET",
            body: nil, signedHeaders: [:], unsignedHeaders: [:], config: Self.config)
        #expect(request.url?.query == "a=1&b=2")
    }

    /// A body travels, and its hash is recomputed for the new signature —
    /// which is only possible because every S3 request body is a `Data` in
    /// memory. `x-amz-content-sha256` carries that hash, so a stale one
    /// would be a signature over bytes that are not being sent.
    @Test func reSigningRecomputesThePayloadHash() throws {
        let body = Data("<Delete><Object><Key>a</Key></Object></Delete>".utf8)
        let request = try S3RequestSigning.reSigned(
            target: try url("https://s3.example.com/bucket?delete"), method: "POST",
            body: body, signedHeaders: ["content-md5": "abc=="], unsignedHeaders: [:],
            config: Self.config)

        #expect(request.httpBody == body)
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256")
            == SigV4Signer.hexSHA256(body))
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("content-md5"), "a carried header was not signed")
    }

    /// An empty body and no body are the same thing to the signature, and
    /// both are the well-known empty-payload hash.
    @Test func reSigningSignsTheEmptyPayloadWithoutABody() throws {
        let request = try S3RequestSigning.reSigned(
            target: try url("https://s3.example.com/bucket/key"), method: "GET",
            body: nil, signedHeaders: [:], unsignedHeaders: [:], config: Self.config)
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256")
            == SigV4Signer.emptyPayloadHash)
    }

    /// `Range` is set on a download AFTER signing, on purpose. Carried the
    /// same way here, it reaches the new target without joining the signed
    /// header set.
    @Test func reSigningCarriesRangeOutsideTheSignature() throws {
        let request = try S3RequestSigning.reSigned(
            target: try url("https://s3.example.com/bucket/key"), method: "GET",
            body: nil, signedHeaders: [:], unsignedHeaders: ["Range": "bytes=100-"],
            config: Self.config)

        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=100-")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("range") == false,
                "Range joined the signed header set")
    }
}
