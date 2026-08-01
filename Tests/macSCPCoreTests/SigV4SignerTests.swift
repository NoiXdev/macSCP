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
        #expect(result.authorization.contains("Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"))
        // x-amz-date header is emitted.
        #expect(result.extraHeaders["x-amz-date"] == "20150830T123600Z")
    }

    @Test func emptyPayloadHashIsSHA256OfEmpty() {
        #expect(SigV4Signer.emptyPayloadHash ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func presignedQueryMatchesAWSVector() {
        // AWS docs "Example: GET Object (query parameters)". Secret is the docs'
        // query-params example secret (note the '/' — distinct from get-vanilla).
        let signer = SigV4Signer(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1", service: "s3")
        let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
        let params = signer.presignedQuery(
            method: "GET", host: "examplebucket.s3.amazonaws.com",
            path: "/test.txt", expiresInSeconds: 86400, date: date)
        let dict = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value) })
        #expect(dict["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
        #expect(dict["X-Amz-Credential"] == "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
        #expect(dict["X-Amz-Date"] == "20130524T000000Z")
        #expect(dict["X-Amz-Expires"] == "86400")
        #expect(dict["X-Amz-SignedHeaders"] == "host")
        #expect(dict["X-Amz-Signature"] == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }
}
