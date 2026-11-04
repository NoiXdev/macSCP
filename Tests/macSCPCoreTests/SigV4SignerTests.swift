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

    /// SigV4's canonical header value is the value TRIMMED **and** with
    /// sequential spaces inside it collapsed to one. A signer that only trims
    /// signs a canonical request no verifier that applies the documented
    /// collapse can reproduce, and the answer is 403 `SignatureDoesNotMatch`,
    /// which `S3FileSystem.mapErrorStatus` turns into `.authenticationFailed`
    /// — "check your access key", for a value with two spaces in it.
    ///
    /// Reachable with ordinary input only since the object-metadata sheet:
    /// `Cache-Control: max-age=60,  must-revalidate` and
    /// `Content-Disposition: attachment;  filename="report.pdf"` are values a
    /// person types, and every other `extraHeaders` value in Core is a fixed
    /// literal, a digest, or percent-encoded.
    ///
    /// **Six `Bool` readings, not one**, and they are named one by one below
    /// so the number is an enumeration rather than a claim. The first two are
    /// the property; the four after them are what stops a green here from
    /// being an artefact. (A seventh expectation, inline at the end, reads the
    /// signed-header list.)
    ///
    /// - `twoSpacesSignAsOne` and `threeSpacesSignAsOne` are the collapse.
    /// - `oneSpaceIsNotNoSpace` says the collapsed form is a single space and
    ///   not none: a "fix" that stripped every space would make the first two
    ///   true and this one false.
    /// - `leadingAndTrailingSpacesAreTrimmed` is the trim, which this signer
    ///   has always done.
    /// - `theTabAndItsNeighbourSpaceBothSurvive` is the character class, and
    ///   it is the reading added on 2026-11-04. The helper's comment states
    ///   "Spaces, not white space in general … so nothing here touches one"
    ///   as a DECISION, and nothing held it: widening the collapse to
    ///   `Character.isWhitespace` — three lines, the kind of edit a tidying
    ///   pass makes — reddened nothing across 549 `SigV4|S3` tests
    ///   (`scripts/mutation-probe`, foreground, plant R3a). Both values here
    ///   carry a doubled space, so both enter the loop whatever the guard is
    ///   widened to; they differ only in the space that FOLLOWS a tab, which
    ///   a whitespace collapse eats and a space collapse does not.
    /// - `theHeaderReachesTheSignature` is the control for all of them: two
    ///   values that differ in a letter sign differently, so an equality above
    ///   is the canonicalization and not a header the signature never saw.
    ///
    /// **Corrected 2026-11-04**: the paragraph above read, verbatim, "**Four
    /// readings, not one.** The first is the property; the other three are
    /// what stops a green here from being an artefact" — a count of the four
    /// bullets over a body that made five `Bool` readings, before this round
    /// made it six.
    ///
    /// **No signature and no key is written into an expectation.** `#expect`
    /// reports the source text of the expression it checks, so every reading
    /// is a `Bool` computed before the expectation and the signatures stay in
    /// local constants (`CLAUDE.md`, "A value a test must not leak has two
    /// exits, not one"). The credentials are the suite's, which are AWS's own
    /// published example values.
    ///
    /// **Not measured here:** whether any store enforces the collapse. AWS
    /// documents it; this pins the signer against the specification, not
    /// against a store's answer.
    @Test func sequentialSpacesInsideACanonicalHeaderValueCollapseToOne() {
        let field = "content-disposition"
        func signature(of value: String) -> String {
            signer.authorizationHeader(
                method: "PUT", host: "example.amazonaws.com", path: "/bucket/doc.txt",
                query: [], headers: ["host": "example.amazonaws.com", field: value],
                payloadHash: SigV4Signer.emptyPayloadHash, date: date
            ).authorization
        }
        let oneSpace = signature(of: #"attachment; filename="a b.pdf""#)
        let twoSpaces = signature(of: #"attachment; filename="a  b.pdf""#)
        let threeSpaces = signature(of: #"attachment; filename="a   b.pdf""#)
        let noSpace = signature(of: #"attachment; filename="ab.pdf""#)
        let padded = signature(of: #"  attachment; filename="a b.pdf"  "#)
        let otherValue = signature(of: #"attachment; filename="z b.pdf""#)
        // Both of these carry the doubled space after the semicolon, so the
        // helper's `contains("  ")` guard lets both into the loop however it
        // is spelled; the only difference between them is the space that
        // FOLLOWS the tab. A collapse of spaces leaves that pair alone and
        // the two sign differently; a collapse of white space eats the space
        // after the tab in the first and they sign the same.
        let tabThenSpace = signature(of: "attachment;  filename=\"a\t b.pdf\"")
        let tabAlone = signature(of: "attachment;  filename=\"a\tb.pdf\"")

        let twoSpacesSignAsOne = twoSpaces == oneSpace
        let threeSpacesSignAsOne = threeSpaces == oneSpace
        let oneSpaceIsNotNoSpace = oneSpace != noSpace
        let leadingAndTrailingSpacesAreTrimmed = padded == oneSpace
        let theTabAndItsNeighbourSpaceBothSurvive = tabThenSpace != tabAlone
        let theHeaderReachesTheSignature = otherValue != oneSpace

        #expect(twoSpacesSignAsOne, "two spaces inside the value signed differently from one")
        #expect(threeSpacesSignAsOne, "three spaces inside the value signed differently from one")
        #expect(oneSpaceIsNotNoSpace, "the space was removed rather than collapsed")
        #expect(leadingAndTrailingSpacesAreTrimmed, "the value is no longer trimmed")
        #expect(
            theTabAndItsNeighbourSpaceBothSurvive,
            "the collapse reached a tab, or the space beside one")
        #expect(theHeaderReachesTheSignature, "the header is not in the signature at all")
        // And it is in the signed-header list, which is the other half of that
        // control and carries no value.
        #expect(signer.authorizationHeader(
            method: "PUT", host: "example.amazonaws.com", path: "/bucket/doc.txt",
            query: [], headers: ["host": "example.amazonaws.com", field: "x  y"],
            payloadHash: SigV4Signer.emptyPayloadHash, date: date
        ).authorization.contains("SignedHeaders=\(field);host;x-amz-date"))
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
