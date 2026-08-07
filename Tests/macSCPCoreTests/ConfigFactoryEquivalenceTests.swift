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

        // ABSOLUTE, not just relative: every assertion above only says the
        // two paths agree with EACH OTHER, which a future change that made
        // both untrimmed would still satisfy. This says which answer is the
        // correct one — the padding must actually be gone.
        guard case .s3(let s3) = viaBuild else { Issue.record("expected .s3"); return }
        #expect(s3.accessKeyID == "AKIAEXAMPLE")
        #expect(s3.region == "eu-central-1")
        #expect(s3.endpoint == "https://s3.example.com")
        #expect(s3.bucket == "archive")
    }

    /// Same shape as the S3 case above, for SSH under password auth: a
    /// session migrated from an older file whose `host`/`username` carry
    /// whitespace must not produce two different configs depending on which
    /// path reads it. The deleted `buildSSH` passed `session.host` and
    /// `session.username` straight into `SSHConnectionConfig.init` untrimmed
    /// — this fixture is what would have caught that, had it existed before
    /// the reviewer had to reinstate `buildSSH` to find it.
    @Test func buildAgreesWithTheFactoryOnAPaddedSSHSession() throws {
        let session = sshSession(
            name: "prod", host: "  prod.example.com  ", port: 2222, username: "  deploy  ")
        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: "hunter2")
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), "hunter2")
        #expect(viaBuild == viaFactory)

        guard case .ssh(let ssh) = viaBuild else { Issue.record("expected .ssh"); return }
        #expect(ssh.host == "prod.example.com")
        #expect(ssh.username == "deploy")
    }

    /// Same shape, for WebDAV: a migrated session's `baseURL`/`username`
    /// carrying whitespace must not produce two different configs depending
    /// on which path reads it. The deleted `buildWebDAV` was equally
    /// untrimmed, and no fixture here ever exercised it.
    @Test func buildAgreesWithTheFactoryOnAPaddedWebDAVSession() throws {
        let session = webdavSession(
            name: "cloud",
            config: StoredWebDAVConfig(
                baseURL: "  https://cloud.example.com/remote.php/dav  ",
                username: "  tim  ", useNextcloudPath: false))
        let viaBuild = try StoredSessionConnectionConfig.build(for: session, secret: nil)
        let descriptor = BackendDescriptor.descriptor(for: .webdav)
        let viaFactory = try descriptor.makeConfig(descriptor.sessionValues(session), "")
        #expect(viaBuild == viaFactory)

        guard case .webdav(let webdav) = viaBuild else { Issue.record("expected .webdav"); return }
        #expect(webdav.baseURL == "https://cloud.example.com/remote.php/dav")
        #expect(webdav.username == "tim")
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
