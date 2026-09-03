import Foundation
import Testing

@testable import macSCPCore

/// What `BackendDescriptor.endpoint` reads out of a backend's own field
/// values — the one question the diagnostics runner asks a descriptor before
/// it resolves or dials anything.
///
/// Every case here goes through `BackendDescriptor.descriptor(for:)` rather
/// than through the schema helper behind it: the seam is what the runner
/// holds, and a helper that works while the descriptor forgets to name it is
/// exactly the wiring mistake these cases exist to catch.
@Suite("BackendDescriptor.endpoint")
struct BackendDescriptorEndpointTests {
    private func endpoint(_ kind: ConnectionKind, _ values: FieldValues) -> Endpoint? {
        BackendDescriptor.descriptor(for: kind).endpoint(values)
    }

    // MARK: - SSH

    @Test func sshReadsHostAndPort() {
        var values = FieldValues()
        values[SSHField.host] = "ssh.example.test"
        values[SSHField.port] = "2222"
        #expect(endpoint(.ssh, values) == Endpoint(host: "ssh.example.test", port: 2222))
    }

    /// The same fallback `SSHFieldSchema.makeConfig` applies, so the row the
    /// diagnosis probes is the port the connect would actually dial.
    @Test func sshFallsBackToTwentyTwoWithoutAPort() {
        var values = FieldValues()
        values[SSHField.host] = "ssh.example.test"
        #expect(endpoint(.ssh, values) == Endpoint(host: "ssh.example.test", port: 22))
    }

    @Test func sshTrimsWhitespaceAroundBothFields() {
        var values = FieldValues()
        values[SSHField.host] = "  ssh.example.test "
        values[SSHField.port] = "2222\n"
        #expect(endpoint(.ssh, values) == Endpoint(host: "ssh.example.test", port: 2222))
    }

    @Test func sshWithoutAHostHasNoEndpoint() {
        var values = FieldValues()
        values[SSHField.port] = "2222"
        #expect(endpoint(.ssh, values) == nil)
    }

    // MARK: - S3

    @Test func s3ReadsTheEndpointHostAndDefaultsToTLSPort() {
        var values = FieldValues()
        values[S3Field.endpoint] = "https://s3.example.test"
        #expect(endpoint(.s3, values) == Endpoint(host: "s3.example.test", port: 443))
    }

    @Test func s3DefaultsToEightyForPlainHTTP() {
        var values = FieldValues()
        values[S3Field.endpoint] = "http://s3.example.test"
        #expect(endpoint(.s3, values) == Endpoint(host: "s3.example.test", port: 80))
    }

    @Test func s3KeepsAnExplicitPort() {
        var values = FieldValues()
        values[S3Field.endpoint] = "http://127.0.0.1:19000"
        #expect(endpoint(.s3, values) == Endpoint(host: "127.0.0.1", port: 19000))
    }

    /// A schemeless endpoint is what a user types when they think of the
    /// field as a host name — and it is an endpoint this app CANNOT CONNECT
    /// TO: the connect path parses the same string with
    /// `URLComponents(string:)` (`S3FieldSchema.endpointComponents`, shared
    /// by both since this review round) and `S3RequestSigning.signedRequest`
    /// then throws "S3 endpoint has no host".
    ///
    /// So the reader refuses it too. An earlier version prepended `https://`
    /// here and nowhere else, which made the diagnosis report resolve ok /
    /// tcp accepted / dial ok for a session the app never dials that way —
    /// a healthy diagnosis about a connection that cannot exist.
    @Test func s3RefusesASchemelessEndpointBecauseTheConnectPathDoes() {
        var values = FieldValues()
        values[S3Field.endpoint] = "minio.example.test:19000"
        #expect(endpoint(.s3, values) == nil)
    }

    /// The Foundation fact the rule above rests on, measured rather than
    /// believed: this spelling parses as a SCHEME of `minio.example.test`
    /// with no host at all.
    @Test func aSchemelessEndpointParsesWithNoHost() {
        let components = S3FieldSchema.endpointComponents("minio.example.test:19000")
        #expect(components?.scheme == "minio.example.test")
        #expect(components?.host == nil)
    }

    @Test func s3WithoutAnEndpointHasNone() {
        #expect(endpoint(.s3, FieldValues()) == nil)
    }

    // MARK: - WebDAV

    @Test func webdavReadsTheBaseURLsHostAndPort() {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "https://dav.example.test/dav"
        #expect(endpoint(.webdav, values) == Endpoint(host: "dav.example.test", port: 443))
    }

    @Test func webdavKeepsAnExplicitPortOverPlainHTTP() {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "http://127.0.0.1:18080/dav"
        #expect(endpoint(.webdav, values) == Endpoint(host: "127.0.0.1", port: 18080))
    }

    @Test func webdavDefaultsToEightyForPlainHTTP() {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "http://nas.example.test/dav"
        #expect(endpoint(.webdav, values) == Endpoint(host: "nas.example.test", port: 80))
    }

    @Test func webdavWithoutABaseURLHasNoEndpoint() {
        #expect(endpoint(.webdav, FieldValues()) == nil)
    }

    /// The positive anchor for the four negative cases above: a bag that HAS
    /// its address field yields an endpoint for every backend, so "nil" above
    /// means "the field was missing" and not "this reader is broken".
    @Test(arguments: [ConnectionKind.ssh, .s3, .webdav])
    func everyBackendReadsAnEndpointFromAFilledBag(kind: ConnectionKind) {
        var values = FieldValues()
        values[SSHField.host] = "filled.example.test"
        values[S3Field.endpoint] = "https://filled.example.test"
        values[WebDAVField.baseURL] = "https://filled.example.test"
        #expect(endpoint(kind, values)?.host == "filled.example.test")
    }
}
