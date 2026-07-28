import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginResolver")
struct LoginResolverTests {
    @Test func manualSessionResolvesNil() throws {
        let session = StoredSession(name: "web", host: "example.com", username: "tim")
        let resolved = try LoginResolver.resolve(session: session, sets: [], secrets: InMemorySecretStore())
        #expect(resolved == nil)
    }

    @Test func setSessionResolvesFromSet() throws {
        let set = LoginSet(name: "Deploy", username: "deploy", authKind: .privateKey, keyPath: "/k")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("pp", for: set.id)
        let session = StoredSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)

        let resolved = try LoginResolver.resolve(session: session, sets: [set], secrets: secrets)
        #expect(resolved == ResolvedLogin(username: "deploy", authKind: .privateKey, keyPath: "/k", secret: "pp"))
    }

    @Test func missingSecretResolvesNilSecret() throws {
        let set = LoginSet(name: "Deploy", username: "deploy", authKind: .password)
        let secrets = InMemorySecretStore()
        let session = StoredSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)

        let resolved = try LoginResolver.resolve(session: session, sets: [set], secrets: secrets)
        #expect(resolved == ResolvedLogin(username: "deploy", authKind: .password, keyPath: nil, secret: nil))
    }

    @Test func missingSetThrows() throws {
        let session = StoredSession(name: "web", host: "example.com", username: "unused", loginSetID: UUID())
        #expect(throws: LoginResolveError.missingSet) {
            try LoginResolver.resolve(session: session, sets: [], secrets: InMemorySecretStore())
        }
    }

    @Test func legacySessionJSONDecodesNilLoginSetID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-legacy-loginset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Fixture written straight to disk: legacy sessions.json without a
        // loginSetID field at all (simulating a pre-M10b installation).
        try Data("""
        [{"id":"\(UUID().uuidString)","name":"web","host":"example.com","port":22,\
        "username":"tim","authKind":"password"}]
        """.utf8).write(to: dir.appendingPathComponent("sessions.json"))

        let store = SessionStore(directory: dir)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.loginSetID == nil)
    }
}
