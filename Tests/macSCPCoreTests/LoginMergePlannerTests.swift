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
        #expect(candidates.first?.username == "deploy")
        #expect(candidates.first?.authKind == .privateKey)
        #expect(candidates.first?.keyPath == "/k1")
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
        #expect(candidates.first?.username == "root")
        #expect(candidates.first?.authKind == .password)
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
        #expect(candidates.first?.username == "deploy")
        #expect(candidates.first?.authKind == .agent)
        #expect(candidates.first?.keyPath == nil)
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

    /// CHARACTERIZATION, not an endorsement (M23/T8 fix round 1).
    ///
    /// `candidates` filters only on `loginSetID == nil` — there is no `kind`
    /// predicate — and `SessionListViewModel.mergeCandidates()` hands it every
    /// session regardless of protocol. So two S3 sessions that happen to share
    /// a secret are offered as a merge candidate whose username is empty,
    /// suggesting the user fold two object-storage connections into one SSH
    /// login set.
    ///
    /// Pre-existing and unchanged in severity by M23: before the milestone the
    /// key was `("unused", .password, nil, <secret>)`, now it is
    /// `("", .password, nil, <secret>)`. Two S3 sessions sharing a secret
    /// collided then and collide now — the shape change neither introduces nor
    /// repairs it. Note the secret compared here is an S3 SECRET ACCESS KEY,
    /// stored under the session id in the same slot an SSH password uses,
    /// which is why it lines up at all.
    ///
    /// Pinned for the same reason as
    /// `JumpSessionEligibilityTests.nonSSHSessionsAreStillOfferedAsJumpHosts`:
    /// so that adding the missing `kind` filter breaks a test that explains
    /// itself rather than one that reads like a regression.
    @Test func nonSSHSessionsSharingASecretAreStillOfferedAsAMergeCandidate() throws {
        let a = s3Session(name: "bucket-a")
        let b = s3Session(name: "bucket-b")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("shared-secret-access-key", for: a.id)
        try secrets.savePassword("shared-secret-access-key", for: b.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [a, b], ignoredGroups: [], secrets: secrets)

        #expect(candidates.count == 1)
        #expect(candidates.first?.sessionIDs == [a.id, b.id])
        // The tell that this is wrong rather than merely surprising: the
        // candidate has no username to merge ON, because an S3 session has no
        // SSH block to take one from.
        #expect(candidates.first?.username == "")
        #expect(a.ssh == nil)
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
