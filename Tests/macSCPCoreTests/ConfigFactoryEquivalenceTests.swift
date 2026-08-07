import Foundation
import Testing
@testable import macSCPCore

/// Success criterion 4: `StoredSessionConnectionConfig.build` and
/// `descriptor.makeConfig` must produce the SAME config for the same input.
///
/// Two ways to build one thing is the defect this phase removes, and the two
/// had already drifted — S3's factory trims every field while the stored-config
/// initializer trims none, so a session migrated from an older file got a
/// different config depending on which path reached it. Nothing failed loudly;
/// the two simply ran in different contexts.
///
/// This suite is that guarantee's only enforcement. If it is ever deleted or
/// weakened, the two paths are free to drift apart again in silence.
@Suite struct ConfigFactoryEquivalenceTests {
    private func s3Stored(padded: Bool) -> StoredS3Config {
        let pad = padded ? "  " : ""
        return StoredS3Config(
            accessKeyID: "\(pad)AKIAEXAMPLE\(pad)",
            region: "\(pad)eu-central-1\(pad)",
            endpoint: "\(pad)https://s3.example.com\(pad)",
            bucket: "\(pad)archive\(pad)",
            usePathStyle: true)
    }

    /// The clean case: whatever `build` returns, the factory returns too.
    @Test(arguments: ConnectionKind.allCases)
    func buildAgreesWithTheFactory(kind: ConnectionKind) throws {
        let secret = "s3cr3t"
        let session: StoredSession
        switch kind {
        case .ssh:
            session = sshSession(
                name: "prod", host: "prod.example.com", port: 2222, username: "deploy")
        case .s3:
            session = s3Session(name: "archive", config: s3Stored(padded: false))
        case .webdav:
            session = webdavSession(name: "cloud")
        }

        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: secret)
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), secret)
        #expect(viaBuild == viaFactory)
    }

    /// The case that was already broken. A session whose stored fields carry
    /// whitespace — an older file, migrated — must not produce two different
    /// configs depending on which path reads it.
    @Test func buildAgreesWithTheFactoryOnAPaddedS3Session() throws {
        let session = s3Session(name: "archive", config: s3Stored(padded: true))
        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: "s3cr3t")
        let descriptor = BackendDescriptor.descriptor(for: .s3)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), "s3cr3t")
        #expect(viaBuild == viaFactory)
    }

    /// SSH under private-key auth: the passphrase convention (empty means an
    /// unencrypted key, not an empty passphrase) must be the same on both.
    @Test func buildAgreesWithTheFactoryForAnUnencryptedKey() throws {
        let session = sshSession(
            name: "prod", host: "prod.example.com", username: "deploy",
            authKind: .privateKey, keyPath: "/keys/id_ed25519")
        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: nil)
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), "")
        #expect(viaBuild == viaFactory)
    }
}
