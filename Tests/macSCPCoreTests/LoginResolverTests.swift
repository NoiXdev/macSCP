import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginResolver")
struct LoginResolverTests {
    @Test func manualSessionResolvesNil() throws {
        let session = sshSession(name: "web", host: "example.com", username: "tim")
        let resolved = try LoginResolver.resolve(session: session, sets: [], secrets: InMemorySecretStore())
        #expect(resolved == nil)
    }

    @Test func setSessionResolvesFromSet() throws {
        let set = LoginSet(name: "Deploy", username: "deploy", authKind: .privateKey, keyPath: "/k")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("pp", for: set.id)
        let session = sshSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)

        // M22/T9: `resolve` returns the backend's own credential values now,
        // so the same four assertions are made field by field. `passphrase`,
        // not `password`: a private-key set's secret goes into the field the
        // schema shows for private-key auth.
        let resolved = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(resolved[SSHField.username] == "deploy")
        #expect(resolved[SSHField.authKind] == StoredSession.AuthKind.privateKey.rawValue)
        #expect(resolved[SSHField.keyPath] == "/k")
        #expect(resolved[SSHField.passphrase] == "pp")
    }

    @Test func missingSecretResolvesNilSecret() throws {
        let set = LoginSet(name: "Deploy", username: "deploy", authKind: .password)
        let secrets = InMemorySecretStore()
        let session = sshSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)

        let resolved = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(resolved[SSHField.username] == "deploy")
        #expect(resolved[SSHField.authKind] == StoredSession.AuthKind.password.rawValue)
        #expect(resolved[SSHField.keyPath] == "")
        #expect(resolved[SSHField.password] == "")
    }

    @Test func missingSetThrows() throws {
        let session = sshSession(name: "web", host: "example.com", username: "unused", loginSetID: UUID())
        #expect(throws: LoginResolveError.missingSet) {
            try LoginResolver.resolve(session: session, sets: [], secrets: InMemorySecretStore())
        }
    }

    /// M12: a session must not bind to a login set of a different protocol
    /// (an SSH session referencing an S3 set here) -- the connect must fail
    /// honestly rather than resolve credentials shaped for the wrong kind.
    @Test func kindMismatchBetweenSessionAndSetThrows() throws {
        let set = LoginSet(name: "S3 Prod", username: "unused", kind: .s3, accessKeyID: "AKIAEXAMPLE")
        let session = sshSession(
            name: "web", host: "example.com", username: "unused", loginSetID: set.id)
        #expect(throws: LoginResolveError.kindMismatch) {
            try LoginResolver.resolve(session: session, sets: [set], secrets: InMemorySecretStore())
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

    // MARK: - A jump bound to a set of another protocol (M28/T7)

    /// A WebDAV set carries `authKind: .password` and its own username, and
    /// its Keychain slot holds the share's password -- so without a `kind`
    /// guard `resolveJump` would build a `ResolvedLogin` out of them and the
    /// caller would hand exactly that to the SSH bastion. The refusal must
    /// therefore come BEFORE the read, which `readIDs` pins.
    ///
    /// The failure message names the leaked IDENTITY (whose username, which
    /// auth kind, whether a secret came along) and never the secret's value.
    @Test func resolveJumpRefusesAWebDAVSet() throws {
        let set = LoginSet(name: "Share", username: "dav", kind: .webdav)
        let spec = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let secrets = RecordingSecretStore([set.id: "the-share-password"])

        do {
            let resolved = try LoginResolver.resolveJump(spec: spec, sets: [set], secrets: secrets)
            Issue.record("""
                the jump was not refused: it resolved to the WebDAV set's own login, which the \
                caller would then hand to the SSH bastion -- username equals the set's: \
                \(resolved.username == set.username), auth kind: \(resolved.authKind.rawValue), \
                a secret was attached: \(resolved.secret != nil)
                """)
        } catch LoginResolveError.jumpSetNotSSH {
            // The refusal this test is about. Any OTHER error propagates out
            // of the `throws` test and fails it by itself.
        }
        #expect(secrets.readIDs.isEmpty)
    }

    /// The same refusal for an object-storage set. `username` is deliberately
    /// non-empty: `LoginSetImportPlanner.makeSet` passes an imported set's
    /// `username` through unexamined, so an `.s3` set can carry one, and with
    /// one the jump would reach `SSHConnectionConfig`'s own
    /// `emptyJumpUsername` check and pass it -- the wrong cause, reported
    /// late, instead of a refusal here.
    @Test func resolveJumpRefusesAnS3Set() throws {
        let set = LoginSet(
            name: "Bucket", username: "imported", kind: .s3, accessKeyID: "AKIAEXAMPLE")
        let spec = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let secrets = RecordingSecretStore([set.id: "the-secret-access-key"])

        do {
            let resolved = try LoginResolver.resolveJump(spec: spec, sets: [set], secrets: secrets)
            Issue.record("""
                the jump was not refused: it resolved to the S3 set's own login, which the \
                caller would then hand to the SSH bastion -- username equals the set's: \
                \(resolved.username == set.username), auth kind: \(resolved.authKind.rawValue), \
                a secret was attached: \(resolved.secret != nil)
                """)
        } catch LoginResolveError.jumpSetNotSSH {
            // The refusal this test is about.
        }
        #expect(secrets.readIDs.isEmpty)
    }

    /// Regression clamp for `resolveJumpSetResolvesFromSet` above: an `.ssh`
    /// set is what the new guard lets through, secret read included, so the
    /// refusal cannot have been written as "refuse every set".
    @Test func resolveJumpStillAcceptsAnSSHSet() throws {
        let set = LoginSet(name: "Bastion", username: "deploy", authKind: .password)
        let spec = StoredSession.JumpSpec(
            host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let secrets = RecordingSecretStore([set.id: "bp"])

        let resolved = try LoginResolver.resolveJump(spec: spec, sets: [set], secrets: secrets)
        #expect(resolved == ResolvedLogin(
            username: "deploy", authKind: .password, keyPath: nil, secret: "bp"))
        #expect(secrets.readIDs == [set.id])
    }

    /// The session-mode path is untouched: a jump referencing an SSH session
    /// whose OWN login set is WebDAV still reports `.kindMismatch` -- that
    /// disagreement is between a session and its set, which is what
    /// `sshLogin(session:sets:secrets:)`'s guard is about, and reporting the
    /// new jump case there would name the wrong cause.
    @Test func resolveJumpFromSessionKeepsReportingKindMismatch() throws {
        let set = LoginSet(name: "Share", username: "dav", kind: .webdav)
        let bastion = sshSession(
            name: "Bastion", host: "b", port: 2022, username: "unused", loginSetID: set.id)
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bastion.id)

        #expect(throws: LoginResolveError.kindMismatch) {
            _ = try LoginResolver.resolveJump(
                spec: spec, sets: [set], secrets: InMemorySecretStore(),
                sessions: [bastion], referencingSessionID: nil)
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
        let session = sshSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)

        let resolved = try #require(try LoginResolver.resolve(
            session: session, sets: [set], secrets: NoReadAllowedSecretStore()))
        #expect(resolved[SSHField.username] == "deploy")
        #expect(resolved[SSHField.authKind] == StoredSession.AuthKind.agent.rawValue)
        #expect(resolved[SSHField.keyPath] == "")
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

    // MARK: - Jump from a saved session (M11a)

    @Test func resolveJumpFromSessionUsesItsHostAndLogin() throws {
        let secrets = InMemorySecretStore()
        let bastion = sshSession(
            name: "Bastion", host: "b", port: 2022, username: "deploy", authKind: .password)
        try secrets.savePassword("s", for: bastion.id)
        let spec = StoredSession.JumpSpec(
            host: "unused", username: "unused", sessionID: bastion.id)

        let resolved = try LoginResolver.resolveJump(
            spec: spec, sets: [], secrets: secrets, sessions: [bastion], referencingSessionID: nil)
        #expect(resolved == ResolvedJump(
            host: "b", port: 2022,
            login: ResolvedLogin(username: "deploy", authKind: .password, keyPath: nil, secret: "s")))
    }

    @Test func resolveJumpFromSessionWithLoginSet() throws {
        let set = LoginSet(name: "Deploy", username: "setuser", authKind: .privateKey, keyPath: "/k")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("pp", for: set.id)
        let bastion = sshSession(
            name: "Bastion", host: "b", port: 2022, username: "unused", loginSetID: set.id)
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bastion.id)

        let resolved = try LoginResolver.resolveJump(
            spec: spec, sets: [set], secrets: secrets, sessions: [bastion], referencingSessionID: nil)
        #expect(resolved == ResolvedJump(
            host: "b", port: 2022,
            login: ResolvedLogin(username: "setuser", authKind: .privateKey, keyPath: "/k", secret: "pp")))
    }

    @Test func resolveJumpFromAgentSessionReadsNoKeychain() throws {
        let bastion = sshSession(
            name: "Bastion", host: "b", port: 2022, username: "deploy", authKind: .agent)
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bastion.id)

        let resolved = try LoginResolver.resolveJump(
            spec: spec, sets: [], secrets: NoReadAllowedSecretStore(),
            sessions: [bastion], referencingSessionID: nil)
        #expect(resolved == ResolvedJump(
            host: "b", port: 2022,
            login: ResolvedLogin(username: "deploy", authKind: .agent, keyPath: nil, secret: nil)))
    }

    @Test func resolveJumpMissingSessionThrows() throws {
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: UUID())
        #expect(throws: LoginResolveError.missingJumpSession) {
            _ = try LoginResolver.resolveJump(
                spec: spec, sets: [], secrets: InMemorySecretStore(), sessions: [], referencingSessionID: nil)
        }
    }

    /// Regression clamp for the positive case `resolveJumpFromSessionUsesItsHostAndLogin`
    /// already covers: a jump referencing an SSH session still resolves, unaffected
    /// by the M24/T4 `.jumpSessionNotSSH` guard.
    @Test func resolveJumpAcceptsAnSSHReferencedSession() throws {
        let secrets = InMemorySecretStore()
        let bastion = sshSession(
            name: "Bastion", host: "b", port: 2022, username: "deploy", authKind: .password)
        try secrets.savePassword("s", for: bastion.id)
        let spec = StoredSession.JumpSpec(
            host: "unused", username: "unused", sessionID: bastion.id)

        let resolved = try LoginResolver.resolveJump(
            spec: spec, sets: [], secrets: secrets, sessions: [bastion], referencingSessionID: nil)
        #expect(resolved == ResolvedJump(
            host: "b", port: 2022,
            login: ResolvedLogin(username: "deploy", authKind: .password, keyPath: nil, secret: "s")))
    }

    /// A jump's `sessionID` referencing a non-SSH session (an object-storage
    /// or WebDAV session, creatable since M12) must be refused: it has no
    /// host to dial, and reading its host/port would silently yield
    /// `StoredSession`'s SSH fallbacks (`""` and `22`).
    @Test func resolveJumpRefusesANonSSHReferencedSession() throws {
        let bucket = s3Session(name: "Bucket")
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bucket.id)

        #expect(throws: LoginResolveError.jumpSessionNotSSH) {
            _ = try LoginResolver.resolveJump(
                spec: spec, sets: [], secrets: InMemorySecretStore(),
                sessions: [bucket], referencingSessionID: nil)
        }
    }

    /// Pins the guard order in `resolveJump`: a `sessionID` that is not in
    /// `sessions` at all must still report `.missingJumpSession`, not the
    /// newer `.jumpSessionNotSSH` — the kind check runs only after the
    /// referenced session has been found.
    @Test func resolveJumpStillRefusesAMissingSessionFirst() throws {
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: UUID())
        #expect(throws: LoginResolveError.missingJumpSession) {
            _ = try LoginResolver.resolveJump(
                spec: spec, sets: [], secrets: InMemorySecretStore(), sessions: [], referencingSessionID: nil)
        }
    }

    @Test func resolveJumpChainThrows() throws {
        let innerJump = StoredSession.JumpSpec(host: "inner", username: "inner")
        let bastion = sshSession(
            name: "Bastion", host: "b", port: 2022, username: "deploy", jump: innerJump)
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: bastion.id)

        #expect(throws: LoginResolveError.jumpChainNotSupported) {
            _ = try LoginResolver.resolveJump(
                spec: spec, sets: [], secrets: InMemorySecretStore(),
                sessions: [bastion], referencingSessionID: nil)
        }
    }

    @Test func resolveJumpSelfReferenceThrows() throws {
        let referencingID = UUID()
        let bastion = sshSession(
            id: referencingID, name: "Self", host: "b", port: 2022, username: "deploy")
        let spec = StoredSession.JumpSpec(host: "unused", username: "unused", sessionID: referencingID)

        #expect(throws: LoginResolveError.jumpChainNotSupported) {
            _ = try LoginResolver.resolveJump(
                spec: spec, sets: [], secrets: InMemorySecretStore(),
                sessions: [bastion], referencingSessionID: referencingID)
        }
    }

    @Test func resolveJumpManualUnchanged() throws {
        let secrets = InMemorySecretStore()
        let manualSpec = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        try secrets.savePassword("jp", for: manualSpec.secretID)
        let manualResolved = try LoginResolver.resolveJump(
            spec: manualSpec, sets: [], secrets: secrets, sessions: [], referencingSessionID: nil)
        #expect(manualResolved == ResolvedJump(
            host: "bastion.example.com", port: 22,
            login: ResolvedLogin(username: "jumper", authKind: .password, keyPath: nil, secret: "jp")))

        let set = LoginSet(name: "Bastion", username: "deploy", authKind: .privateKey, keyPath: "/k")
        try secrets.savePassword("pp", for: set.id)
        let setSpec = StoredSession.JumpSpec(host: "bastion.example.com", username: "unused", loginSetID: set.id)
        let setResolved = try LoginResolver.resolveJump(
            spec: setSpec, sets: [set], secrets: secrets, sessions: [], referencingSessionID: nil)
        #expect(setResolved == ResolvedJump(
            host: "bastion.example.com", port: 22,
            login: ResolvedLogin(username: "deploy", authKind: .privateKey, keyPath: "/k", secret: "pp")))

        let agentSpec = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", authKind: .agent)
        let agentResolved = try LoginResolver.resolveJump(
            spec: agentSpec, sets: [], secrets: NoReadAllowedSecretStore(), sessions: [], referencingSessionID: nil)
        #expect(agentResolved == ResolvedJump(
            host: "bastion.example.com", port: 22,
            login: ResolvedLogin(username: "jumper", authKind: .agent, keyPath: nil, secret: nil)))
    }

    @Test func jumpSpecRoundtripKeepsSecretID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-jump-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper")
        let session = sshSession(name: "web", host: "example.com", username: "tim", jump: jump)

        try SessionStore(directory: dir).upsert(session)
        // A brand-new SessionStore instance (no shared in-memory state) proves
        // the JumpSpec, including its secretID, actually round-trips through
        // disk rather than surviving only in the writer's own state.
        let reloaded = try SessionStore(directory: dir).all()
        #expect(reloaded.first?.jump == jump)
    }

    @Test func jumpSpecRoundtripKeepsSessionID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-jump-session-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bastionID = UUID()
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "jumper", sessionID: bastionID)
        let session = sshSession(name: "web", host: "example.com", username: "tim", jump: jump)

        try SessionStore(directory: dir).upsert(session)
        let reloaded = try SessionStore(directory: dir).all()
        #expect(reloaded.first?.jump?.sessionID == bastionID)
        #expect(reloaded.first?.jump == jump)
    }

    // MARK: - S3 through the collapsed resolver (M15, collapsed in M22/T9)

    @Test func resolveS3ManualSessionResolvesNil() throws {
        let session = s3Session(name: "bucket")
        let resolved = try LoginResolver.resolve(
            session: session, sets: [], secrets: InMemorySecretStore())
        #expect(resolved == nil)
    }

    @Test func resolveS3SetSessionResolvesAccessKeyAndSecret() throws {
        let set = LoginSet(name: "S3 Prod", username: "unused", kind: .s3, accessKeyID: "AKIAEXAMPLE")
        let secrets = InMemorySecretStore()
        try secrets.savePassword("s3cr3t", for: set.id)
        let session = s3Session(name: "bucket", loginSetID: set.id)

        let resolved = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(resolved[S3Field.accessKeyID] == "AKIAEXAMPLE")
        #expect(resolved[S3Field.secretAccessKey] == "s3cr3t")
    }

    @Test func resolveS3MissingSecretResolvesNilSecret() throws {
        let set = LoginSet(name: "S3 Prod", username: "unused", kind: .s3, accessKeyID: "AKIAEXAMPLE")
        let session = s3Session(name: "bucket", loginSetID: set.id)

        let resolved = try #require(try LoginResolver.resolve(
            session: session, sets: [set], secrets: InMemorySecretStore()))
        #expect(resolved[S3Field.accessKeyID] == "AKIAEXAMPLE")
        #expect(resolved[S3Field.secretAccessKey] == "")
    }

    @Test func resolveS3KindMismatchBetweenS3SessionAndSSHSetThrows() throws {
        let set = LoginSet(name: "SSH", username: "deploy", authKind: .password)
        let session = s3Session(name: "bucket", loginSetID: set.id)
        #expect(throws: LoginResolveError.kindMismatch) {
            try LoginResolver.resolve(session: session, sets: [set], secrets: InMemorySecretStore())
        }
    }

    @Test func resolveS3MissingSetThrows() throws {
        let session = s3Session(name: "bucket", loginSetID: UUID())
        #expect(throws: LoginResolveError.missingSet) {
            try LoginResolver.resolve(session: session, sets: [], secrets: InMemorySecretStore())
        }
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

/// Test double for the jump refusal tests (M28/T7). Unlike
/// `NoReadAllowedSecretStore` it does not judge a read — it RECORDS which ids
/// were read and hands back what it was seeded with, so one store serves both
/// a test that requires no read at all and one that requires exactly one.
/// Seeding matters for the mutation check: with the guard removed, the
/// resolver produces a `ResolvedLogin` that visibly carries a secret.
private final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private let stored: [UUID: String]
    private(set) var readIDs: [UUID] = []

    init(_ stored: [UUID: String]) { self.stored = stored }

    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? {
        readIDs.append(sessionID)
        return stored[sessionID]
    }
    func deletePassword(for sessionID: UUID) throws {}
}
