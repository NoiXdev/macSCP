import Foundation
import Testing
@testable import macSCPCore

@Suite("StoredSessionConnectionConfig")
struct StoredSessionConnectionConfigTests {
    // Named `make*` rather than `sshSession`/`s3Session` (like the SessionFixtures
    // helpers) so calling them from inside this file doesn't shadow the global
    // fixtures with a same-named, incompatible-signature member lookup.
    private func makeSSHSession(
        authKind: StoredSession.AuthKind = .password,
        keyPath: String? = nil,
        loginSetID: UUID? = nil,
        jump: StoredSession.JumpSpec? = nil
    ) -> StoredSession {
        sshSession(
            name: "prod", host: "example.com", port: 22, username: "deploy",
            authKind: authKind, keyPath: keyPath, loginSetID: loginSetID, jump: jump)
    }

    /// `withConfig: false` builds a session with `s3 == nil` — inconsistent
    /// stored data (`kind == .s3` but no config) rather than a session that
    /// simply omitted an optional field, so it's a distinct parameter rather
    /// than an optional `StoredS3Config?` default (which cannot tell "pass
    /// nil explicitly" apart from "use the default"). The `s3Session` fixture
    /// always supplies a config, so the `withConfig: false` branch stays a
    /// literal `StoredSession(...)` — no helper can express "no config" here.
    private func makeS3Session(withConfig: Bool = true, loginSetID: UUID? = nil) -> StoredSession {
        guard withConfig else {
            return StoredSession(
                name: "bucket", loginSetID: loginSetID, kind: .s3, s3: nil)
        }
        return s3Session(
            name: "bucket", loginSetID: loginSetID,
            config: StoredS3Config(
                accessKeyID: "AKID", region: "eu-central-1",
                endpoint: "https://s3.example.com", bucket: "my-bucket", usePathStyle: true))
    }

    @Test func passwordAuthBuildsAnSSHConfigWithTheResolvedSecret() throws {
        let config = try StoredSessionConnectionConfig.build(for: makeSSHSession(), secret: "hunter2")
        guard case .ssh(let ssh) = config else { Issue.record("expected .ssh"); return }
        #expect(ssh.host == "example.com")
        #expect(ssh.port == 22)
        #expect(ssh.username == "deploy")
        #expect(ssh.auth == .password("hunter2"))
    }

    @Test func passwordAuthWithoutASecretThrows() {
        #expect(throws: StoredSessionConnectionError.secretRequired) {
            try StoredSessionConnectionConfig.build(for: makeSSHSession(), secret: nil)
        }
    }

    @Test func passwordAuthWithAnEmptySecretThrows() {
        #expect(throws: StoredSessionConnectionError.secretRequired) {
            try StoredSessionConnectionConfig.build(for: makeSSHSession(), secret: "")
        }
    }

    @Test func privateKeyAuthBuildsAnSSHConfigWithTheKeyPathAndPassphrase() throws {
        let session = makeSSHSession(authKind: .privateKey, keyPath: "/keys/id_ed25519")
        let config = try StoredSessionConnectionConfig.build(for: session, secret: "passphrase")
        guard case .ssh(let ssh) = config else { Issue.record("expected .ssh"); return }
        #expect(ssh.auth == .privateKey(keyPath: "/keys/id_ed25519", passphrase: "passphrase"))
    }

    /// An unencrypted key has no passphrase — an absent or empty secret must
    /// build a config, not fail, and must pass `nil` (not empty string)
    /// onward, mirroring `ConnectionViewModel.connectSSH()`'s own rule.
    @Test func privateKeyAuthWithNoSecretMeansAnUnencryptedKey() throws {
        let session = makeSSHSession(authKind: .privateKey, keyPath: "/keys/id_ed25519")
        let config = try StoredSessionConnectionConfig.build(for: session, secret: nil)
        guard case .ssh(let ssh) = config else { Issue.record("expected .ssh"); return }
        #expect(ssh.auth == .privateKey(keyPath: "/keys/id_ed25519", passphrase: nil))
    }

    @Test func privateKeyAuthWithoutAKeyPathThrows() {
        let session = makeSSHSession(authKind: .privateKey, keyPath: nil)
        #expect(throws: StoredSessionConnectionError.incompleteConfiguration(field: "Key path")) {
            try StoredSessionConnectionConfig.build(for: session, secret: "passphrase")
        }
    }

    @Test func privateKeyAuthWithAnEmptyKeyPathThrows() {
        let session = makeSSHSession(authKind: .privateKey, keyPath: "   ")
        #expect(throws: StoredSessionConnectionError.incompleteConfiguration(field: "Key path")) {
            try StoredSessionConnectionConfig.build(for: session, secret: "passphrase")
        }
    }

    /// Agent auth needs no secret at all — building must succeed even
    /// without one, and must succeed the same way whether a secret happens
    /// to be passed in or not (the call site is expected to skip resolution
    /// entirely, but this function must not depend on that).
    @Test func agentAuthNeedsNoSecret() throws {
        let session = makeSSHSession(authKind: .agent)
        let config = try StoredSessionConnectionConfig.build(for: session, secret: nil)
        guard case .ssh(let ssh) = config else { Issue.record("expected .ssh"); return }
        #expect(ssh.auth == .agent)
    }

    @Test func s3BuildsAConfigFromTheStoredFieldsAndTheResolvedSecret() throws {
        let config = try StoredSessionConnectionConfig.build(for: makeS3Session(), secret: "secretkey")
        guard case .s3(let s3) = config else { Issue.record("expected .s3"); return }
        #expect(s3.accessKeyID == "AKID")
        #expect(s3.secretAccessKey == "secretkey")
        #expect(s3.region == "eu-central-1")
        #expect(s3.endpoint == "https://s3.example.com")
        #expect(s3.bucket == "my-bucket")
        #expect(s3.usePathStyle == true)
    }

    @Test func s3WithoutASecretThrows() {
        #expect(throws: StoredSessionConnectionError.secretRequired) {
            try StoredSessionConnectionConfig.build(for: makeS3Session(), secret: nil)
        }
    }

    @Test func s3WithoutStoredConfigurationThrows() {
        #expect(throws: StoredSessionConnectionError.missingBackendConfiguration(kind: .s3)) {
            try StoredSessionConnectionConfig.build(for: makeS3Session(withConfig: false), secret: "secretkey")
        }
    }

    @Test func aLoginSetBoundSessionThrowsRegardlessOfKind() {
        let setID = UUID()
        #expect(throws: StoredSessionConnectionError.loginSetSessionsNotSupported) {
            try StoredSessionConnectionConfig.build(for: makeSSHSession(loginSetID: setID), secret: "hunter2")
        }
        #expect(throws: StoredSessionConnectionError.loginSetSessionsNotSupported) {
            try StoredSessionConnectionConfig.build(for: makeS3Session(loginSetID: setID), secret: "secretkey")
        }
    }

    /// PINS A WIDENING, not a pre-existing rule (M23/P2). The deleted
    /// `buildS3` validated nothing — it copied the stored fields straight into
    /// the config — so a blank region used to build and connect. Routing
    /// through the factory means `firstViolation` now walks S3's connection
    /// schema, where `region` is `isRequired`, and refuses first.
    ///
    /// CLOSED by the maintainer: `region` stays required. The evidence:
    /// `SigV4Signer` does not fail on an empty region — it silently emits a
    /// credential scope with an empty segment
    /// (`…/19700101//s3/aws4_request`). A probe against the rig's MinIO shows
    /// it accepts that blank scope, but it also accepts a NONSENSE region —
    /// MinIO simply never checks the segment, so its tolerance is evidence
    /// only that MinIO isn't the one enforcing the field, not that the field
    /// is unneeded. Real AWS rejects the empty segment outright, with the
    /// opaque `AuthorizationHeaderMalformed` or `SignatureDoesNotMatch` (see
    /// `S3FieldSchema.makeConfig`'s comment on `region`, which records the
    /// same finding — and, unlike here, now says NOT optional). The GUI
    /// cannot produce a blank region in the first place; only
    /// `SessionImportPlanner` (which presence-checks `s3Region` without
    /// checking emptiness) or a hand-edited `sessions-v2.json` can.
    ///
    /// This test exists so the behaviour is pinned rather than incidental.
    @Test func s3WithABlankRegionIsRefusedByTheSchema() {
        let session = s3Session(
            name: "bucket",
            config: StoredS3Config(
                accessKeyID: "AKID", region: "", endpoint: "https://minio.example.com",
                bucket: "my-bucket", usePathStyle: true))
        #expect(throws: StoredSessionConnectionError.incompleteConfiguration(field: "Region")) {
            try StoredSessionConnectionConfig.build(for: session, secret: "secretkey")
        }
    }

    /// A `.ssh` session with no stored block is representable on disk — the
    /// decoder accepts it deliberately, so one bad record cannot fail the whole
    /// file. Before M23/P2 only S3 and WebDAV reported that honestly; SSH fell
    /// through to a blank host and surfaced `ConfigError.emptyHost` instead.
    @Test func anSSHSessionWithoutItsStoredBlockThrowsMissingConfiguration() {
        var session = sshSession(name: "broken")
        session.ssh = nil
        #expect(throws: StoredSessionConnectionError.missingBackendConfiguration(kind: .ssh)) {
            try StoredSessionConnectionConfig.build(for: session, secret: "pw")
        }
    }

    @Test func aSessionWithAJumpThrows() {
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jump")
        #expect(throws: StoredSessionConnectionError.jumpSessionsNotSupported) {
            try StoredSessionConnectionConfig.build(for: makeSSHSession(jump: jump), secret: "hunter2")
        }
    }
}
