import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginMergePlanner")
struct LoginMergePlannerTests {
    @Test func groupsByUsernameAndKeyPath() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = sshSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s3 = sshSession(name: "c", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k2")

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2, s3], ignoredGroups: [], secrets: InMemorySecretStore())

        #expect(candidates.count == 1)
        #expect(candidates.first?.displayLabel == "deploy")
        #expect(candidates.first?.values[SSHField.authKind] == "privateKey")
        #expect(candidates.first?.values[SSHField.keyPath] == "/k1")
        #expect(candidates.first?.sessionIDs == [s1.id, s2.id])
    }

    @Test func groupsByUsernameAndPasswordValue() throws {
        let s1 = sshSession(name: "a", host: "h", username: "root")
        let s2 = sshSession(name: "b", host: "h", username: "root")
        let s3 = sshSession(name: "c", host: "h", username: "root")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("a", for: s1.id)
        try secrets.savePassword("a", for: s2.id)
        try secrets.savePassword("b", for: s3.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2, s3], ignoredGroups: [], secrets: secrets)

        #expect(candidates.count == 1)
        #expect(candidates.first?.displayLabel == "root")
        #expect(candidates.first?.values[SSHField.authKind] == "password")
        #expect(candidates.first?.sessionIDs == [s1.id, s2.id])
    }

    @Test func sessionWithoutStoredPasswordExcluded() throws {
        let s1 = sshSession(name: "a", host: "h", username: "root")
        let s2 = sshSession(name: "b", host: "h", username: "root")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("a", for: s1.id)
        // s2 deliberately has no stored password.

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    @Test func sessionWithSetExcluded() throws {
        let s1 = sshSession(name: "a", host: "h", username: "root", loginSetID: UUID())
        let s2 = sshSession(name: "b", host: "h", username: "root")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("a", for: s1.id)
        try secrets.savePassword("a", for: s2.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    @Test func singletonGroupsSuppressed() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1], ignoredGroups: [], secrets: InMemorySecretStore())

        #expect(candidates.isEmpty)
    }

    @Test func ignoredGroupSuppressesSubset() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = sshSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s3 = sshSession(name: "c", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let secrets = InMemorySecretStore()

        let exact = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [Set([s1.id, s2.id])], secrets: secrets)
        #expect(exact.isEmpty)

        let superset = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [Set([s1.id, s2.id, s3.id])], secrets: secrets)
        #expect(superset.isEmpty)
    }

    // MARK: - Agent auth (M10d/T3)

    @Test func agentSessionsGroupByUsernameAlone() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .agent)
        let s2 = sshSession(name: "b", host: "h", username: "deploy", authKind: .agent)

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: InMemorySecretStore())

        #expect(candidates.count == 1)
        #expect(candidates.first?.displayLabel == "deploy")
        #expect(candidates.first?.values[SSHField.authKind] == "agent")
        // `keyPath` is not a `.agent`-visible field, so it never enters the
        // candidate's value bag at all; `FieldValues` reads a missing key back
        // as "", not nil (see `FieldValues.subscript`) -- the type-correct
        // spelling of the old `candidate.keyPath == nil`.
        #expect(candidates.first?.values[SSHField.keyPath] == "")
        #expect(candidates.first?.sessionIDs == [s1.id, s2.id])
    }

    @Test func agentAndPasswordSessionsNeverGroupTogether() throws {
        let s1 = sshSession(name: "a", host: "h", username: "root", authKind: .agent)
        let s2 = sshSession(name: "b", host: "h", username: "root")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("a", for: s2.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    /// `.agent` grouping must never read the keychain (spec §3 "kein
    /// Secret-Read") -- the double below fails the test if `password(for:)`
    /// is ever called.
    @Test func agentSessionsNeverReadKeychain() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .agent)
        let s2 = sshSession(name: "b", host: "h", username: "deploy", authKind: .agent)

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: NoReadAllowedSecretStore())

        #expect(candidates.count == 1)
    }

    @Test func newMemberReactivates() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = sshSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s3 = sshSession(name: "c", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let secrets = InMemorySecretStore()

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2, s3], ignoredGroups: [Set([s1.id, s2.id])], secrets: secrets)

        #expect(candidates.count == 1)
        #expect(candidates.first?.sessionIDs == [s1.id, s2.id, s3.id])
    }

    // MARK: - Protocol-correct grouping (M24/T2)

    /// SUCCESSOR to the M23 characterization test
    /// `nonSSHSessionsSharingASecretAreStillOfferedAsAMergeCandidate`, which
    /// pinned the bug this fixes: two S3 sessions sharing a secret used to
    /// collide on the SSH-shaped key `(username: "", authKind: .password,
    /// keyPath: nil, password: <secret>)` — a Keychain slot that for S3 holds
    /// the SECRET ACCESS KEY, not a password — and merging them (Task 3)
    /// would have created an unusable `.ssh` set and deleted both. As of M24
    /// the grouping key is derived from the backend's own `credentialSchema`
    /// (`kind` + the visible non-secret credential fields + the secret), so
    /// this now asserts the opposite of what it used to: two S3 sessions with
    /// the SAME access key ID and the SAME secret are correctly recognized as
    /// one S3 login, with the access key ID as the display label.
    @Test func twoS3SessionsSharingACredentialPairAreOneCandidate() throws {
        // `bucket` differs -- it lives in the CONNECTION schema, not the
        // credential one, so it plays no part in the grouping key.
        let a = s3Session(name: "bucket-a", config: StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "bucket-a", usePathStyle: false))
        let b = s3Session(name: "bucket-b", config: StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "bucket-b", usePathStyle: false))
        let secrets = InMemorySecretStore()
        try secrets.savePassword("shared-secret-access-key", for: a.id)
        try secrets.savePassword("shared-secret-access-key", for: b.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: secrets)

        #expect(candidates.count == 1)
        #expect(candidates.first?.kind == .s3)
        #expect(candidates.first?.sessionIDs == [a.id, b.id])
        #expect(candidates.first?.displayLabel == "AKIA")
        #expect(candidates.first?.values[S3Field.accessKeyID] == "AKIA")
    }

    @Test func twoS3SessionsWithDifferentSecretsAreNotACandidate() throws {
        // Both default to the same `accessKeyID` ("AKIA") via the fixture.
        let a = s3Session(name: "bucket-a")
        let b = s3Session(name: "bucket-b")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("secret-a", for: a.id)
        try secrets.savePassword("secret-b", for: b.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    @Test func twoS3SessionsWithDifferentAccessKeyIDsAreNotACandidate() throws {
        let a = s3Session(name: "bucket-a", config: StoredS3Config(
            accessKeyID: "AKIA1", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "bucket", usePathStyle: false))
        let b = s3Session(name: "bucket-b", config: StoredS3Config(
            accessKeyID: "AKIA2", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "bucket", usePathStyle: false))
        let secrets = InMemorySecretStore()
        try secrets.savePassword("shared-secret", for: a.id)
        try secrets.savePassword("shared-secret", for: b.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    /// The test the `isRequired`-derivation would NOT have passed: WebDAV's
    /// password is optional (M23, anonymous shares), so a rule that read
    /// secret-identity off `isRequired` would have left the password out of
    /// the key entirely, and two sessions with the same user name but
    /// DIFFERENT passwords would have collided as one login. `SecretRole`
    /// (M24/T1) is declared independently of `isRequired` precisely to avoid
    /// this.
    @Test func twoWebDAVSessionsWithDifferentPasswordsAreNotACandidate() throws {
        let a = webdavSession(name: "a", config: StoredWebDAVConfig(
            baseURL: "https://cloud.example.com/remote.php/dav",
            username: "tim", useNextcloudPath: false))
        let b = webdavSession(name: "b", config: StoredWebDAVConfig(
            baseURL: "https://cloud.example.com/remote.php/dav",
            username: "tim", useNextcloudPath: false))
        let secrets = InMemorySecretStore()
        try secrets.savePassword("password-a", for: a.id)
        try secrets.savePassword("password-b", for: b.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    @Test func twoWebDAVSessionsSharingAPasswordAreOneCandidate() throws {
        // `baseURL`/`useNextcloudPath` differ -- both live in the CONNECTION
        // schema, not the credential one.
        let a = webdavSession(name: "a", config: StoredWebDAVConfig(
            baseURL: "https://cloud.example.com/remote.php/dav",
            username: "tim", useNextcloudPath: false))
        let b = webdavSession(name: "b", config: StoredWebDAVConfig(
            baseURL: "https://other.example.com/remote.php/dav",
            username: "tim", useNextcloudPath: true))
        let secrets = InMemorySecretStore()
        try secrets.savePassword("shared-password", for: a.id)
        try secrets.savePassword("shared-password", for: b.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: secrets)

        #expect(candidates.count == 1)
        #expect(candidates.first?.kind == .webdav)
        #expect(candidates.first?.displayLabel == "tim")
    }

    /// The exact bug the M23 characterization test above pinned: `kind` is
    /// now part of the grouping key, so an S3 session and an SSH session
    /// sharing a Keychain slot value can never be mistaken for the same
    /// login, no matter what the raw secret bytes happen to be.
    @Test func anS3AndAnSSHSessionNeverShareACandidate() throws {
        let ssh = sshSession(name: "ssh", host: "h", username: "root")
        let s3 = s3Session(name: "bucket")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("shared-secret", for: ssh.id)
        try secrets.savePassword("shared-secret", for: s3.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [ssh, s3], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    /// `SecretRole.passphrase` (M24/T1): the passphrase unlocks `keyPath`,
    /// which is already part of the key, so it neither enters the key nor
    /// justifies a Keychain read. Double copied from
    /// `NoReadAllowedSecretStore` below, the same one
    /// `agentSessionsNeverReadKeychain` uses to pin the `.agent` case of this
    /// same rule.
    @Test func privateKeySessionsGroupWithoutReadingTheKeychain() {
        let s1 = sshSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = sshSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: NoReadAllowedSecretStore())

        #expect(candidates.count == 1)
    }

    /// WebDAV's user name is not `isRequired` (M23, anonymous shares), so two
    /// anonymous sessions both reach the secret check -- and with no
    /// Keychain entry at all, `.credential`'s guard excludes them exactly as
    /// it would a password-auth SSH session with no stored password.
    @Test func anonymousWebDAVSessionsAreNeverACandidate() {
        let a = webdavSession(name: "a", config: StoredWebDAVConfig(
            baseURL: "https://cloud.example.com/remote.php/dav",
            username: "", useNextcloudPath: false))
        let b = webdavSession(name: "b", config: StoredWebDAVConfig(
            baseURL: "https://cloud.example.com/remote.php/dav",
            username: "", useNextcloudPath: false))

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: InMemorySecretStore())

        #expect(candidates.isEmpty)
    }
}

/// Test double proving `.agent` grouping never reaches into the keychain
/// (M10d spec §3): `password(for:)` fails the test if called at all.
private final class NoReadAllowedSecretStore: SecretStore, @unchecked Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? {
        Issue.record("agent merge grouping must not read the keychain")
        return nil
    }
    func deletePassword(for sessionID: UUID) throws {}
}
