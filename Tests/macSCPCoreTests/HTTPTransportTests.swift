import Foundation
import Testing
@testable import macSCPCore

@Suite("HTTPTransport")
struct HTTPTransportTests {
    /// The transport must use the session it was handed, not `.shared` —
    /// WebDAV depends on this to get its delegate (auth + server trust) into
    /// the request path at all.
    @Test func usesTheInjectedSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTransportStubURLProtocol.self]
        let transport = URLSessionHTTPTransport(session: URLSession(configuration: configuration))

        let (data, response) = try await transport.send(
            URLRequest(url: URL(string: "https://example.invalid/probe")!))

        #expect(response.statusCode == 218)
        #expect(String(data: data, encoding: .utf8) == "stubbed")
    }
}

/// Answers every request with 218 and a fixed body. Registered only on the
/// ephemeral configuration above, so it cannot leak into other suites.
final class HTTPTransportStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 218, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("stubbed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
