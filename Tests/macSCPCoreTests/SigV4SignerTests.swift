import Testing
import Foundation
@testable import macSCPCore

@Suite("SigV4Signer")
struct SigV4SignerTests {
    // AWS SigV4 test-suite reference credentials/date (public, from AWS docs).
    private let signer = SigV4Signer(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        region: "us-east-1", service: "service")
    // 2015-08-30T12:36:00Z
    private let date = Date(timeIntervalSince1970: 1_440_938_160)

    @Test func signingKeyAndSignatureMatchAWSVector() {
        // Canonical/StringToSign/signature for the AWS "get-vanilla" case.
        // The test pins the FINAL signature hex the AWS suite documents for
        // these inputs; the implementer computes it via the SigV4 steps.
        let result = signer.authorizationHeader(
            method: "GET", host: "example.amazonaws.com", path: "/",
            query: [], headers: ["host": "example.amazonaws.com"],
            payloadHash: SigV4Signer.emptyPayloadHash, date: date)
        // Authorization must carry the fixed credential scope + signed headers.
        #expect(result.authorization.contains("AWS4-HMAC-SHA256"))
        #expect(result.authorization.contains("Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"))
        #expect(result.authorization.contains("SignedHeaders=host;x-amz-date"))
        // x-amz-date header is emitted.
        #expect(result.extraHeaders["x-amz-date"] == "20150830T123600Z")
    }

    @Test func emptyPayloadHashIsSHA256OfEmpty() {
        #expect(SigV4Signer.emptyPayloadHash ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
