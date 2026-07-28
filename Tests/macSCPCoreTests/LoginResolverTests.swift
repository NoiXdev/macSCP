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

    // MARK: - Jump host (M10c)

    @Test func resolveJumpManualUsesSecretIDSlot() throws {
        let secrets = InMemorySecretStore()
        let spec = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        try secrets.savePassword("jp", for: spec.secretID)

        let resolved = try LoginResolver.resolveJump(spec: spec, sets: [], secrets: secrets)
        #expect(resolved == ResolvedLogin(username: "jumper", authKind: .password, keyPath: nil, secret: "jp"))
    }

    @Test func resolveJumpSetResolvesFromSet() throws {
        let set = LoginSet(name: "Bastion", username: "deploy", authKind: .privateKey, keyPath: "/k")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("pp", for: set.id)
        let spec = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)

        let resolved = try LoginResolver.resolveJump(spec: spec, sets: [set], secrets: secrets)
        #expect(resolved == ResolvedLogin(username: "deploy", authKind: .privateKey, keyPath: "/k", secret: "pp"))
    }

    @Test func resolveJumpMissingSetThrows() throws {
        let spec = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: UUID())
        #expect(throws: LoginResolveError.missingSet) {
            _ = try LoginResolver.resolveJump(spec: spec, sets: [], secrets: InMemorySecretStore())
        }
    }

    @Test func legacySessionJSONDecodesNilJump() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-legacy-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Fixture written straight to disk: legacy sessions.json without a
        // jump field at all (simulating a pre-M10c installation).
        try Data("""
        [{"id":"\(UUID().uuidString)","name":"web","host":"example.com","port":22,\
        "username":"tim","authKind":"password"}]
        """.utf8).write(to: dir.appendingPathComponent("sessions.json"))

        let store = SessionStore(directory: dir)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.jump == nil)
    }

    // MARK: - Agent auth (M10d/T3)

    /// `.agent` resolution must never touch the keychain (spec §3): the
    /// double below fails the test if `password(for:)` is ever called.
    @Test func agentSetResolvesWithoutKeychainRead() throws {
        let set = LoginSet(name: "Agent", username: "deploy", authKind: .agent)
        let session = StoredSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)

        let resolved = try LoginResolver.resolve(session: session, sets: [set], secrets: NoReadAllowedSecretStore())
        #expect(resolved == ResolvedLogin(username: "deploy", authKind: .agent, keyPath: nil, secret: nil))
    }

    @Test func resolveJumpManualAgentDoesNotReadKeychain() throws {
        let spec = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", authKind: .agent)

        let resolved = try LoginResolver.resolveJump(spec: spec, sets: [], secrets: NoReadAllowedSecretStore())
        #expect(resolved == ResolvedLogin(username: "jumper", authKind: .agent, keyPath: nil, secret: nil))
    }

    @Test func resolveJumpSetAgentDoesNotReadKeychain() throws {
        let set = LoginSet(name: "Bastion", username: "deploy", authKind: .agent)
        let spec = StoredSession.JumpSpec(host: "bastion.example.com", username: "unused", loginSetID: set.id)

        let resolved = try LoginResolver.resolveJump(spec: spec, sets: [set], secrets: NoReadAllowedSecretStore())
        #expect(resolved == ResolvedLogin(username: "deploy", authKind: .agent, keyPath: nil, secret: nil))
    }

    @Test func jumpSpecRoundtripKeepsSecretID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-jump-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let session = StoredSession(name: "web", host: "example.com", username: "tim", jump: jump)

        try SessionStore(directory: dir).upsert(session)
        // A brand-new SessionStore instance (no shared in-memory state) proves
        // the JumpSpec, including its secretID, actually round-trips through
        // disk rather than surviving only in the writer's own state.
        let reloaded = try SessionStore(directory: dir).all()
        #expect(reloaded.first?.jump == jump)
    }
}

/// Test double proving `.agent` resolution never reaches into the keychain
/// (M10d spec §3): `password(for:)` fails the test if called at all.
/// `savePassword`/`deletePassword` are unused by these tests but must exist
/// to satisfy the protocol.
private final class NoReadAllowedSecretStore: SecretStore, @unchecked Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? {
        Issue.record("agent resolution must not read the keychain")
        return nil
    }
    func deletePassword(for sessionID: UUID) throws {}
}
