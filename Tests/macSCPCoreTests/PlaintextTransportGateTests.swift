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
}
