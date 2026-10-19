import Foundation
import Testing

@testable import macSCPCore

/// The store's `<Code>` is what tells one refusal from another when the
/// status alone cannot: every 403 used to become "authentication failed",
/// including a delete refused under a legal hold. `S3ErrorCode` reads the
/// code and names the few refusals a user of the bucket settings can
/// provoke; everything else keeps the status-only mapping.
@Suite struct S3ErrorCodeTests {
    @Test func anErrorBodyYieldsItsCode() {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code>\
        <Message>Object has a legal hold and cannot be deleted.</Message></Error>
        """.utf8)
        #expect(S3ErrorCode.parse(body) == "AccessDenied")
    }

    @Test func aBodyWithNoCodeYieldsNil() {
        #expect(S3ErrorCode.parse(Data("not xml".utf8)) == nil)
    }

    @Test func anUnnamedCodeKeepsTodaysMapping() {
        let mapped = S3ErrorCode.finding(forCode: "SignatureDoesNotMatch", status: 403, path: "/b/k")
        #expect(mapped == nil)  // nil means: fall through to mapErrorStatus
    }

    /// `AccessDenied` is the code both a legal hold and a retention period
    /// answer with, so the code alone cannot tell them apart; the caller
    /// that read `?legal-hold` can, and until then the code falls through.
    @Test func accessDeniedFallsThroughBecauseTheCodeAloneCannotSplitHoldFromRetention() {
        let mapped = S3ErrorCode.finding(forCode: "AccessDenied", status: 403, path: "/b/k")
        #expect(mapped == nil)
    }

    @Test(arguments: [
        ("ObjectLockConfigurationNotFoundError", 404, RemoteFSFinding.Name.objectLockNotConfigured),
        ("BucketNotEmpty", 409, RemoteFSFinding.Name.bucketNotEmpty),
        ("NotImplemented", 501, RemoteFSFinding.Name.operationNotSupported),
    ])
    func aNamedCodeBecomesItsFinding(
        code: String, status: Int, expected: RemoteFSFinding.Name
    ) throws {
        let mapped = try #require(S3ErrorCode.finding(forCode: code, status: status, path: "/b/k"))
        guard case .finding(let finding) = mapped else {
            Issue.record("not a finding")
            return
        }
        #expect(finding.name == expected)
    }

    @Test func noNewFindingCarriesTheServersSentence() {
        // The store's message is the thing that must NOT travel. Compute the Bool
        // before the expectation so neither the sentence nor its spelling can
        // reach a failure message.
        let serverSentence = "Object has a legal hold and cannot be deleted."
        let finding = RemoteFSFinding.objectUnderLegalHold(path: "/b/k")
        let leaks = finding.logSentence.contains(serverSentence)
        #expect(leaks == false)
    }

    /// The route end to end, without a network: a refused request's body is
    /// handed to the mapper along with its status, and a named code becomes
    /// its finding where the status-only mapping would have said something
    /// else.
    @Test func theStatusMapperReadsTheBodyForANamedCode() {
        let body = Data("<Error><Code>BucketNotEmpty</Code></Error>".utf8)
        let mapped = S3FileSystem.mapErrorStatus(409, body: body, path: "/b")
        #expect(mapped == .finding(.bucketNotEmpty))
    }

    @Test func theStatusMapperKeepsTodaysMappingForUnnamedCodes() {
        let denied = Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8)
        #expect(S3FileSystem.mapErrorStatus(403, body: denied, path: "/b/k") == .authenticationFailed)
        #expect(S3FileSystem.mapErrorStatus(403, body: Data(), path: "/b/k") == .authenticationFailed)
        #expect(S3FileSystem.mapErrorStatus(404, body: Data(), path: "/b/k") == .notFound(path: "/b/k"))
        #expect(
            S3FileSystem.mapErrorStatus(500, body: Data(), path: "/b/k")
                == .finding(.unexpectedStatus(code: 500)))
    }
}
