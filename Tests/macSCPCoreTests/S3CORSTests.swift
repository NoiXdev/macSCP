import Foundation
import Testing
@testable import macSCPCore

/// A bucket's CORS rules: the XML pair, macSCP's own validation, and the
/// request `S3FileSystem` signs, against the canned transport. No network;
/// the rig half is `S3CORSGatedTests`.
@Suite("S3 bucket CORS")
struct S3CORSTests {
    private func rule(
        id: String? = nil, origins: [String] = ["*"], methods: [String] = ["GET"],
        allowedHeaders: [String] = [], exposeHeaders: [String] = [], maxAge: Int? = nil
    ) -> CORSRule {
        CORSRule(
            id: id, allowedOrigins: origins, allowedMethods: methods,
            allowedHeaders: allowedHeaders, exposeHeaders: exposeHeaders, maxAgeSeconds: maxAge)
    }

    // MARK: - The document

    @Test func theFullRuleSchemaRoundTrips() throws {
        let rule = CORSRule(
            id: "rule-one",
            allowedOrigins: ["https://a.example.com", "https://b.example.com"],
            allowedMethods: ["GET", "PUT"],
            allowedHeaders: ["x-amz-meta-foo"],
            exposeHeaders: ["ETag", "x-amz-version-id"],
            maxAgeSeconds: 3600)
        let body = try S3SettingsXML.corsBody([rule])
        #expect(try S3SettingsXML.parseCORS(body) == [rule])
    }

    @Test func anAbsentConfigurationIsNilAndNotAnEmptyList() throws {
        // NoSuchCORSConfiguration is "none set", which is not the same as a
        // configuration holding zero rules.
        #expect(
            try S3SettingsXML.parseCORSResponse(
                status: 404,
                body: Data("<Error><Code>NoSuchCORSConfiguration</Code></Error>".utf8)) == nil)
        #expect(
            try S3SettingsXML.parseCORSResponse(
                status: 200, body: Data("<CORSConfiguration/>".utf8)) == [])
    }

    /// The rig answers with the elements of a rule sorted alphabetically,
    /// whatever order they were sent in (measured 2026-10-19). This is that
    /// answer, verbatim in its order.
    @Test func theFieldsOfARuleAreReadInAnyOrder() throws {
        let xml = """
            <CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><CORSRule>
            <AllowedHeader>x-amz-meta-foo</AllowedHeader>
            <AllowedMethod>GET</AllowedMethod><AllowedMethod>PUT</AllowedMethod>
            <AllowedOrigin>https://a.example.com</AllowedOrigin>
            <AllowedOrigin>https://b.example.com</AllowedOrigin>
            <ExposeHeader>ETag</ExposeHeader><ExposeHeader>x-amz-version-id</ExposeHeader>
            <ID>rule-one</ID><MaxAgeSeconds>3600</MaxAgeSeconds>
            </CORSRule></CORSConfiguration>
            """
        let parsed = try S3SettingsXML.parseCORS(Data(xml.utf8))
        #expect(
            parsed == [
                rule(
                    id: "rule-one", origins: ["https://a.example.com", "https://b.example.com"],
                    methods: ["GET", "PUT"], allowedHeaders: ["x-amz-meta-foo"],
                    exposeHeaders: ["ETag", "x-amz-version-id"], maxAge: 3600)
            ])
    }

    @Test func severalRulesKeepTheirOrder() throws {
        let rules = [rule(id: "first"), rule(id: "second", methods: ["PUT"]), rule(id: nil)]
        let body = try S3SettingsXML.corsBody(rules)
        #expect(try S3SettingsXML.parseCORS(body) == rules)
    }

    @Test func aValueWithMarkupInItRoundTripsEscaped() throws {
        let tricky = rule(id: "a&b<c>", origins: ["https://x.example.com/?a=1&b=2"])
        let body = try S3SettingsXML.corsBody([tricky])
        #expect(String(data: body, encoding: .utf8)?.contains("a&amp;b&lt;c&gt;") == true)
        #expect(try S3SettingsXML.parseCORS(body) == [tricky])
    }

    /// `S3XMLText.escaped` preserves whitespace, so the parse must not trim
    /// it: a value with a space at either end is another value. The number is
    /// the exception, because whitespace around a number is formatting.
    @Test func spacesAroundAValueSurviveTheRoundTrip() throws {
        let spaced = CORSRule(
            id: "  spaced  ", allowedOrigins: [" https://a.example.com "],
            allowedMethods: ["GET"], allowedHeaders: ["\tx-amz-meta-foo "],
            exposeHeaders: [" ETag"], maxAgeSeconds: 30)
        let body = try S3SettingsXML.corsBody([spaced])
        #expect(try S3SettingsXML.parseCORS(body) == [spaced])
    }

    @Test func whitespaceAroundTheNumberIsFormattingAndIsTrimmed() throws {
        let xml = """
            <CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>\
            <AllowedMethod>GET</AllowedMethod><MaxAgeSeconds>
              30
            </MaxAgeSeconds></CORSRule></CORSConfiguration>
            """
        #expect(try S3SettingsXML.parseCORS(Data(xml.utf8)) == [rule(maxAge: 30)])
    }

    @Test func aValueXMLCannotCarryIsRefusedWhileBuilding() {
        #expect(throws: RemoteFSError.finding(.requestBodyUnencodable)) {
            try S3SettingsXML.corsBody([rule(origins: ["bad\u{1}origin"])])
        }
    }

    @Test func aDocumentWithAForeignRootIsAProtocolErrorAndNotNoRules() {
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        do {
            _ = try S3SettingsXML.parseCORS(html)
            Issue.record("a foreign root was read as a configuration")
        } catch {
            guard case .protocolError(let reason) = (error as? RemoteFSError) else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
            // The reason is ours, not Foundation's description of our abort.
            #expect(reason == "Failed to parse S3 CORS response: no CORSConfiguration element")
        }
    }

    @Test func aDocumentThatIsNotWellFormedIsAProtocolError() {
        #expect(throws: RemoteFSError.self) {
            _ = try S3SettingsXML.parseCORS(Data("<CORSConfiguration><CORSRule>".utf8))
        }
        #expect(throws: RemoteFSError.self) {
            _ = try S3SettingsXML.parseCORS(Data())
        }
    }

    @Test func aMaxAgeThatIsNotAnIntegerIsAProtocolErrorAndNotAMissingOne() {
        let xml = """
            <CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>\
            <AllowedMethod>GET</AllowedMethod><MaxAgeSeconds>soon</MaxAgeSeconds>\
            </CORSRule></CORSConfiguration>
            """
        do {
            _ = try S3SettingsXML.parseCORS(Data(xml.utf8))
            Issue.record("a non-numeric MaxAgeSeconds was read")
        } catch {
            guard case .protocolError(let reason) = (error as? RemoteFSError) else {
                Issue.record("expected .protocolError, got \(error)")
                return
            }
            #expect(reason.contains("MaxAgeSeconds"))
        }
    }

    /// Only a field directly under a rule counts: an `ID` or an
    /// `AllowedMethod` nested one level deeper, or under the root, is not
    /// this rule's. The positive half is asserted in the same test, so the
    /// negative cannot go quiet by the parser reading nothing at all.
    @Test func onlyAFieldDirectlyUnderARuleCounts() throws {
        let xml = """
            <CORSConfiguration><AllowedMethod>DELETE</AllowedMethod><CORSRule>\
            <ID>real</ID><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod>\
            <Extension><ID>nested</ID><AllowedMethod>POST</AllowedMethod></Extension>\
            </CORSRule></CORSConfiguration>
            """
        let parsed = try S3SettingsXML.parseCORS(Data(xml.utf8))
        #expect(parsed == [rule(id: "real", origins: ["*"], methods: ["GET"])])
    }

    @Test func aNonSuccessAnswerThatIsNotTheAbsenceIsMappedNotSwallowed() {
        #expect(throws: RemoteFSError.authenticationFailed) {
            _ = try S3SettingsXML.parseCORSResponse(status: 403, body: Data())
        }
        // A 404 for a bucket that is not there is NOT "no CORS set".
        #expect(throws: RemoteFSError.notFound(path: "/gone")) {
            _ = try S3SettingsXML.parseCORSResponse(
                status: 404, body: Data("<Error><Code>NoSuchBucket</Code></Error>".utf8),
                path: "/gone")
        }
    }

    // MARK: - macSCP's own validation

    @Test func anInvalidMethodIsRefusedHereAndNotByTheStore() {
        let rule = CORSRule(
            id: nil, allowedOrigins: ["*"], allowedMethods: ["FETCH"],
            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
        #expect(rule.validate() == .methodNotAllowed("FETCH"))
    }

    @Test func aRuleNeedsAnOriginAndAMethod() {
        let noOrigin = CORSRule(
            id: nil, allowedOrigins: [], allowedMethods: ["GET"],
            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
        #expect(noOrigin.validate() == .noOrigin)
        let noMethod = CORSRule(
            id: nil, allowedOrigins: ["*"], allowedMethods: [],
            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
        #expect(noMethod.validate() == .noMethod)
    }

    @Test(arguments: ["GET", "PUT", "POST", "DELETE", "HEAD"])
    func everyMethodS3AcceptsIsAccepted(method: String) {
        #expect(rule(methods: [method]).validate() == .ok)
    }

    /// The vocabulary is exactly five names, upper case. `OPTIONS` and
    /// `PATCH` are real HTTP methods S3 does not take; `get` is S3's own
    /// refusal of a lower-case name.
    @Test(arguments: ["FETCH", "OPTIONS", "PATCH", "get", "", "GET "])
    func aMethodOutsideTheFiveIsRefused(method: String) {
        #expect(rule(methods: [method]).validate() == .methodNotAllowed(method))
    }

    @Test func theFirstRefusedMethodOfSeveralIsTheOneNamed() {
        #expect(rule(methods: ["GET", "FETCH", "TRACE"]).validate() == .methodNotAllowed("FETCH"))
    }

    /// A list with an entry that names nothing is not a rule that names an
    /// origin: the method side refuses `""` and `"GET "`, and the origin side
    /// holds to the same standard. The second half keeps a real origin
    /// accepted, so the check cannot pass by refusing everything.
    @Test(arguments: [[""], ["  "], ["https://a.example.com", ""], ["\t\n"]])
    func anOriginThatNamesNothingIsNoOrigin(origins: [String]) {
        #expect(rule(origins: origins).validate() == .noOrigin)
    }

    @Test func realOriginsAreStillAccepted() {
        #expect(rule(origins: ["*"]).validate() == .ok)
        #expect(rule(origins: ["https://a.example.com", "http://localhost:3000"]).validate() == .ok)
    }

    // MARK: - The Content-MD5 helper

    @Test func theDigestHelperIsTheBase64OfTheMD5() {
        // `printf abc | openssl md5 -binary | base64`
        #expect(S3FileSystem.contentMD5(of: Data("abc".utf8)) == "kAFQmDzST7DWlj99KOF/cg==")
    }

    // MARK: - The requests

    @Test func readingIsAGetOnTheCORSSubresourceOfTheNamedBucket() async throws {
        let answer = Data(
            "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>"
                .utf8)
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [(answer, S3SettingsFake.httpResponse(status: 200))])
        let configuration = try await fs.cors(ofBucket: "other")
        #expect(configuration?.rules == [rule()])
        #expect(configuration?.rawBody == answer)
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "cors=")
    }

    @Test func aBucketWithNoConfigurationReadsAsNil() async throws {
        let answer = Data(
            "<Error><Code>NoSuchCORSConfiguration</Code><Message>none</Message></Error>".utf8)
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(answer, S3SettingsFake.httpResponse(status: 404))])
        #expect(try await fs.cors(ofBucket: "other") == nil)
    }

    @Test func aForbiddenReadIsAuthenticationFailedThroughTheSharedMapping() async throws {
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(Data(), S3SettingsFake.httpResponse(status: 403))])
        do {
            _ = try await fs.cors(ofBucket: "other")
            Issue.record("a 403 returned rules")
        } catch {
            #expect((error as? RemoteFSError) == .authenticationFailed)
        }
    }

    @Test func writingIsAPutOfTheRulesWithTheBodysHashAndASignedContentMD5() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [(Data(), S3SettingsFake.httpResponse(status: 200))])
        try await fs.setCORS([rule()], ofBucket: "other")
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/other")
        #expect(sent.url?.query == "cors=")
        let body = try #require(sent.httpBody)
        #expect(
            String(data: body, encoding: .utf8)?.contains(
                "<CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod></CORSRule>")
                == true)
        #expect(
            sent.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4Signer.hexSHA256(body))
        // The expected digest is a literal: the base64 MD5 of this exact
        // body (`printf '%s' '<body>' | openssl md5 -binary | base64`), not
        // a call to the code that computes it.
        #expect(sent.value(forHTTPHeaderField: "Content-MD5") == "z5NRbjB3frWWZtwtWBl//w==")
        let authorization = try #require(sent.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.lowercased().contains("content-md5"))
    }

    /// The rig stores a `FETCH` rule and reads it back, so nothing the rig
    /// does can show that macSCP refuses it. This asserts the refusal where
    /// it lives: `setCORS` throws, and the transport was never asked.
    @Test func aFetchRuleIsRefusedBeforeAnyRequestReachesTheTransport() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [(Data(), S3SettingsFake.httpResponse(status: 200))])
        let before = await transport.requests.count
        do {
            try await fs.setCORS([rule(methods: ["FETCH"])], ofBucket: "other")
            Issue.record("a FETCH rule was sent")
        } catch {
            // A payload-free finding: the offending method is not in it.
            #expect((error as? RemoteFSError) == .finding(.corsRuleInvalid))
        }
        #expect(await transport.requests.count == before)
    }

    @Test func oneBadRuleAmongGoodOnesSendsNothing() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [(Data(), S3SettingsFake.httpResponse(status: 200))])
        let before = await transport.requests.count
        await #expect(throws: RemoteFSError.finding(.corsRuleInvalid)) {
            try await fs.setCORS(
                [rule(id: "good"), rule(origins: []), rule(id: "also-good")], ofBucket: "other")
        }
        #expect(await transport.requests.count == before)
    }

    /// No rules is not a configuration S3 can hold (a PUT of one is
    /// `400 MalformedXML`), so writing `[]` removes the configuration: one
    /// DELETE on the `cors` subresource, no body, and no PUT.
    @Test func writingNoRulesIsADeleteOfTheConfigurationAndNotAPut() async throws {
        let (fs, transport) = try await S3SettingsFake.connect(
            responses: [(Data(), S3SettingsFake.httpResponse(status: 204))])
        let before = await transport.requests.count
        try await fs.setCORS([], ofBucket: "other")
        let sent = await transport.requests
        #expect(sent.count == before + 1)
        let request = try #require(sent.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/other")
        #expect(request.url?.query == "cors=")
        #expect(request.httpBody == nil)
        #expect(sent.contains { $0.httpMethod == "PUT" } == false)
    }

    @Test func aRefusedRemovalIsMappedThroughTheSharedStatusMapping() async throws {
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(Data(), S3SettingsFake.httpResponse(status: 403))])
        do {
            try await fs.setCORS([], ofBucket: "other")
            Issue.record("a 403 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .authenticationFailed)
        }
    }

    /// The parse is lossy (an element a rule has no field for is skipped),
    /// so the document the rules came from is handed back untouched: it is
    /// the only place the skipped element is still visible.
    @Test func theRawDocumentKeepsWhatTheParsedRulesDropped() async throws {
        let answer = Data(
            ("<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
                + "<AllowedMethod>GET</AllowedMethod><FutureThing>x</FutureThing>"
                + "</CORSRule></CORSConfiguration>").utf8)
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(answer, S3SettingsFake.httpResponse(status: 200))])
        let configuration = try #require(try await fs.cors(ofBucket: "other"))
        #expect(configuration.rules == [rule()])
        #expect(String(data: configuration.rawBody, encoding: .utf8)?.contains("FutureThing") == true)
    }

    @Test func aNamedRefusalOfTheWriteBecomesItsFinding() async throws {
        let answer = Data("<Error><Code>NotImplemented</Code></Error>".utf8)
        let (fs, _) = try await S3SettingsFake.connect(
            responses: [(answer, S3SettingsFake.httpResponse(status: 501))])
        do {
            try await fs.setCORS([rule()], ofBucket: "other")
            Issue.record("a 501 was reported as success")
        } catch {
            #expect((error as? RemoteFSError) == .finding(.operationNotSupported))
        }
    }
}
