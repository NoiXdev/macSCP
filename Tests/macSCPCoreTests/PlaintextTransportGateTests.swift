import Foundation
import Testing
@testable import macSCPCore

@Suite("PlaintextTransportGate")
struct PlaintextTransportGateTests {
    private func webdav(_ url: String) -> ConnectionConfig {
        .webdav(WebDAVConnectionConfig(
            baseURL: url, username: "u", useNextcloudPath: false, password: "p"))
    }

    @Test func basicOverPlaintextRequiresConfirmation() {
        #expect(PlaintextTransportGate.requiresConfirmation(for: webdav("http://nas.local/dav")))
    }

    @Test func tlsDoesNotRequireConfirmation() {
        #expect(!PlaintextTransportGate.requiresConfirmation(for: webdav("https://nas.local/dav")))
    }

    /// SSH is always encrypted — the gate must read the capability, not the
    /// kind, or it becomes another `if kind ==` branch.
    @Test func alwaysEncryptedBackendsAreNeverGated() throws {
        let ssh = ConnectionConfig.ssh(try SSHConnectionConfig(
            host: "h", port: 22, username: "u", auth: .password("p")))
        #expect(!PlaintextTransportGate.requiresConfirmation(for: ssh))
        #expect(BackendDescriptor.descriptor(for: .ssh).capabilities.transport == .alwaysEncrypted)
    }

    /// S3 is .optionalTLS too, so the gate must apply there as well — it is a
    /// transport rule, not a WebDAV rule.
    @Test func plaintextS3IsGatedByTheSameRule() {
        let s3 = ConnectionConfig.s3(S3ConnectionConfig(
            accessKeyID: "a", secretAccessKey: "s", region: "r",
            endpoint: "http://minio.local:9000", bucket: "b",
            usePathStyle: true, sessionToken: nil))
        #expect(PlaintextTransportGate.requiresConfirmation(for: s3))
    }

    private func s3(_ endpoint: String) -> ConnectionConfig {
        .s3(S3ConnectionConfig(
            accessKeyID: "a", secretAccessKey: "s", region: "r",
            endpoint: endpoint, bucket: "b", usePathStyle: true, sessionToken: nil))
    }

    /// The gate reads the ONE endpoint parse rather than testing the string
    /// for an `http://` prefix of its own (review 2026-09-04). A pasted
    /// endpoint carrying a leading space is the difference: the prefix test
    /// answered "encrypted" for a session that dials in the clear.
    @Test func aPastedPlaintextEndpointIsStillGated() {
        #expect(PlaintextTransportGate.requiresConfirmation(for: s3(" http://minio.local:9000 ")))
    }

    /// And a schemeless endpoint is https by the same parse, so it is not
    /// gated — the gate and the dial cannot disagree about the scheme.
    @Test func aSchemelessEndpointIsReadAsTLSByTheSameParse() {
        #expect(!PlaintextTransportGate.requiresConfirmation(for: s3("minio.local:9000")))
    }
}

/// Which sentence the confirmation shows is decided from the same config the
/// gate reads, in one place: `kind(for:)`. The App picks its body from the
/// kind, so a plain FTP session cannot be told to use a scheme FTP does not
/// have.
extension PlaintextTransportGateTests {
    private func ftp(_ security: FTPSecurityMode) -> ConnectionConfig {
        .ftp(FTPConnectionConfig(
            host: "files.example.com", port: security.defaultPort, username: "tim",
            security: security, password: ""))
    }

    private func plaintextS3() -> ConnectionConfig {
        .s3(S3ConnectionConfig(
            accessKeyID: "a", secretAccessKey: "s", region: "r",
            endpoint: "http://minio.local:9000", bucket: "b",
            usePathStyle: true, sessionToken: nil))
    }

    private func plaintextWebDAV() -> ConnectionConfig {
        .webdav(WebDAVConnectionConfig(
            baseURL: "http://nas.local/dav", username: "u", useNextcloudPath: false, password: "p"))
    }

    @Test func plainFTPIsOfTheFTPKind() {
        #expect(PlaintextTransportGate.kind(for: ftp(.plain)) == .plainFTP)
    }

    @Test func neitherFTPSFormIsOfAnyKind() {
        #expect(PlaintextTransportGate.kind(for: ftp(.explicitTLS)) == nil)
        #expect(PlaintextTransportGate.kind(for: ftp(.implicitTLS)) == nil)
    }

    @Test func anHTTPEndpointOfEitherHTTPBackendIsOfTheHTTPKind() {
        #expect(PlaintextTransportGate.kind(for: plaintextS3()) == .http)
        #expect(PlaintextTransportGate.kind(for: plaintextWebDAV()) == .http)
    }

    @Test func anEncryptedConfigIsOfNoKind() throws {
        let ssh = ConnectionConfig.ssh(try SSHConnectionConfig(
            host: "h", port: 22, username: "u", auth: .password("p")))
        #expect(PlaintextTransportGate.kind(for: ssh) == nil)
        #expect(PlaintextTransportGate.kind(for: webdav("https://nas.local/dav")) == nil)
    }

    /// The question and its sentence cannot disagree: asking is defined as
    /// having a kind. Every config above, both ways.
    @Test func theQuestionIsAskedExactlyWhenThereIsAKind() throws {
        let ssh = ConnectionConfig.ssh(try SSHConnectionConfig(
            host: "h", port: 22, username: "u", auth: .password("p")))
        let configs: [ConnectionConfig] = [
            ftp(.plain), ftp(.explicitTLS), ftp(.implicitTLS),
            plaintextS3(), plaintextWebDAV(), webdav("https://nas.local/dav"), ssh,
        ]
        for config in configs {
            let asks = PlaintextTransportGate.requiresConfirmation(for: config)
            let hasKind = PlaintextTransportGate.kind(for: config) != nil
            #expect(asks == hasKind)
        }
        // Positive control: the loop above covered both answers.
        let answers = configs.map { PlaintextTransportGate.requiresConfirmation(for: $0) }
        #expect(answers.contains(true))
        #expect(answers.contains(false))
    }
}
