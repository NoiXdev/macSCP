import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginMergePlanner")
struct LoginMergePlannerTests {
    @Test func groupsByUsernameAndKeyPath() {
        let s1 = StoredSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = StoredSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s3 = StoredSession(name: "c", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k2")

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2, s3], ignoredGroups: [], secrets: InMemorySecretStore())

        #expect(candidates.count == 1)
        #expect(candidates.first?.username == "deploy")
        #expect(candidates.first?.authKind == .privateKey)
        #expect(candidates.first?.keyPath == "/k1")
        #expect(candidates.first?.sessionIDs == [s1.id, s2.id])
    }

    @Test func groupsByUsernameAndPasswordValue() throws {
        let s1 = StoredSession(name: "a", host: "h", username: "root")
        let s2 = StoredSession(name: "b", host: "h", username: "root")
        let s3 = StoredSession(name: "c", host: "h", username: "root")
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
        let s1 = StoredSession(name: "a", host: "h", username: "root")
        let s2 = StoredSession(name: "b", host: "h", username: "root")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("a", for: s1.id)
        // s2 deliberately has no stored password.

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    @Test func sessionWithSetExcluded() throws {
        let s1 = StoredSession(name: "a", host: "h", username: "root", loginSetID: UUID())
        let s2 = StoredSession(name: "b", host: "h", username: "root")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("a", for: s1.id)
        try secrets.savePassword("a", for: s2.id)

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [], secrets: secrets)

        #expect(candidates.isEmpty)
    }

    @Test func singletonGroupsSuppressed() {
        let s1 = StoredSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1], ignoredGroups: [], secrets: InMemorySecretStore())

        #expect(candidates.isEmpty)
    }

    @Test func ignoredGroupSuppressesSubset() {
        let s1 = StoredSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = StoredSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s3 = StoredSession(name: "c", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let secrets = InMemorySecretStore()

        let exact = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [Set([s1.id, s2.id])], secrets: secrets)
        #expect(exact.isEmpty)

        let superset = LoginMergePlanner.candidates(
            sessions: [s1, s2], ignoredGroups: [Set([s1.id, s2.id, s3.id])], secrets: secrets)
        #expect(superset.isEmpty)
    }

    @Test func newMemberReactivates() {
        let s1 = StoredSession(name: "a", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s2 = StoredSession(name: "b", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let s3 = StoredSession(name: "c", host: "h", username: "deploy", authKind: .privateKey, keyPath: "/k1")
        let secrets = InMemorySecretStore()

        let candidates = LoginMergePlanner.candidates(
            sessions: [s1, s2, s3], ignoredGroups: [Set([s1.id, s2.id])], secrets: secrets)

        #expect(candidates.count == 1)
        #expect(candidates.first?.sessionIDs == [s1.id, s2.id, s3.id])
    }
}
