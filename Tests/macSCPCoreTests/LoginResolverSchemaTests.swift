import Foundation
import Testing
@testable import macSCPCore

/// The M22/T9 collapse: `resolve` and `resolveS3` became ONE function
/// returning the same `FieldValues` shape the connection form produces.
@Suite("LoginResolver schema")
struct LoginResolverSchemaTests {
    /// A WebDAV login set resolves into the same FieldValues shape the form
    /// produces — that is what makes WebDAV login sets work with no
    /// WebDAV-specific code anywhere.
    @Test func resolvesAWebDAVSetIntoFieldValues() throws {
        let secrets = InMemorySecretStore()
        let set = LoginSet(name: "cloud", username: "tim", kind: .webdav)
        try secrets.savePassword("app-password", for: set.id)

        let session = StoredSession(
            name: "s", host: "unused", port: 443, username: "unused",
            loginSetID: set.id, kind: .webdav)

        let values = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(values[WebDAVField.username] == "tim")
        #expect(values[WebDAVField.password] == "app-password")
    }

    @Test func resolvesAnS3SetIntoFieldValues() throws {
        let secrets = InMemorySecretStore()
        let set = LoginSet(name: "minio", username: "", kind: .s3, accessKeyID: "AKIA")
        try secrets.savePassword("topsecret", for: set.id)

        let session = StoredSession(
            name: "s", host: "unused", port: 443, username: "unused",
            loginSetID: set.id, kind: .s3)

        let values = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(values[S3Field.accessKeyID] == "AKIA")
        #expect(values[S3Field.secretAccessKey] == "topsecret")
    }

    /// SSH's two secret FIELDS, one Keychain slot: the resolver writes the
    /// stored secret into whichever of them the schema currently shows, so a
    /// key set's passphrase never lands in the password row (and vice versa).
    @Test func anSSHKeySetResolvesItsSecretIntoThePassphraseField() throws {
        let secrets = InMemorySecretStore()
        let set = LoginSet(
            name: "deploy", username: "deploy", authKind: .privateKey, keyPath: "/k")
        try secrets.savePassword("pp", for: set.id)
        let session = StoredSession(
            name: "s", host: "h", username: "unused", loginSetID: set.id)

        let values = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(values[SSHField.username] == "deploy")
        #expect(values[SSHField.keyPath] == "/k")
        #expect(values[SSHField.passphrase] == "pp")
        #expect(values[SSHField.password] == "")
    }

    @Test func anSSHPasswordSetResolvesItsSecretIntoThePasswordField() throws {
        let secrets = InMemorySecretStore()
        let set = LoginSet(name: "deploy", username: "deploy", authKind: .password)
        try secrets.savePassword("hunter2", for: set.id)
        let session = StoredSession(
            name: "s", host: "h", username: "unused", loginSetID: set.id)

        let values = try #require(
            try LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(values[SSHField.password] == "hunter2")
        #expect(values[SSHField.passphrase] == "")
    }

    /// M10d: an agent set has no secret field at all, so the Keychain is
    /// never reached — structurally, not by an `if`. The store fails the test
    /// on any read.
    @Test func anAgentSetResolvesWithoutReadingTheKeychain() throws {
        let set = LoginSet(name: "agent", username: "deploy", authKind: .agent)
        let session = StoredSession(
            name: "s", host: "h", username: "unused", loginSetID: set.id)

        let values = try #require(try LoginResolver.resolve(
            session: session, sets: [set], secrets: NoReadAllowedStore()))
        #expect(values[SSHField.username] == "deploy")
        #expect(values[SSHField.authKind] == StoredSession.AuthKind.agent.rawValue)
        #expect(values[SSHField.password] == "")
        #expect(values[SSHField.passphrase] == "")
    }

    @Test func aSessionWithoutASetResolvesToNil() throws {
        let session = StoredSession(name: "s", host: "h", port: 22, username: "u")
        #expect(try LoginResolver.resolve(
            session: session, sets: [], secrets: InMemorySecretStore()) == nil)
    }

    @Test func aMissingSetIsAnError() {
        let session = StoredSession(
            name: "s", host: "h", port: 22, username: "u", loginSetID: UUID())
        #expect(throws: LoginResolveError.missingSet) {
            _ = try LoginResolver.resolve(
                session: session, sets: [], secrets: InMemorySecretStore())
        }
    }

    /// The invariant that survives the collapse: binding a session to a set of
    /// a different protocol is a hard stop, never a fallback to credentials
    /// shaped for the wrong backend.
    @Test func aSetOfTheWrongKindIsAHardStop() {
        let set = LoginSet(name: "ssh", username: "tim")
        let session = StoredSession(
            name: "s", host: "unused", port: 443, username: "unused",
            loginSetID: set.id, kind: .webdav)
        #expect(throws: LoginResolveError.kindMismatch) {
            _ = try LoginResolver.resolve(
                session: session, sets: [set], secrets: InMemorySecretStore())
        }
    }

    /// The jump path is untouched: a jump host is an SSH concept, so
    /// `resolveJump` keeps returning `ResolvedLogin` and is not made generic.
    @Test func theJumpResolverStillReturnsAnSSHLogin() throws {
        let spec = StoredSession.JumpSpec(host: "bastion", username: "tim")
        let resolved = try LoginResolver.resolveJump(
            spec: spec, sets: [], secrets: InMemorySecretStore())
        #expect(resolved.username == "tim")
    }

    // MARK: - The editor's half of the same vocabulary

    /// Round-trip through the descriptor's adapters: what the editor renders
    /// is what the resolver reads back, for every backend. A kind that only
    /// half-implements this would fail here rather than in a form nobody
    /// tests.
    @Test(arguments: ConnectionKind.allCases)
    func aSetSurvivesTheRoundTripThroughItsCredentialSchema(kind: ConnectionKind) throws {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        var edited = descriptor.defaultValues
        // Fill every visible non-secret field with a recognizable value.
        for field in descriptor.credentialSchema.visibleFields(
            in: edited, namespace: descriptor.fieldNamespace) where !field.isSecret {
            if case .text = field.kind {
                edited.setRaw("\(descriptor.fieldNamespace).\(field.id)", to: "value-\(field.id)")
            }
        }
        let id = UUID()
        let set = descriptor.loginSet(id: id, name: "n", from: edited)
        #expect(set.id == id)
        #expect(set.kind == kind)

        let readBack = descriptor.loginSetValues(set)
        for field in descriptor.credentialSchema.visibleFields(
            in: edited, namespace: descriptor.fieldNamespace) where !field.isSecret {
            if case .text = field.kind {
                #expect(
                    readBack.raw["\(descriptor.fieldNamespace).\(field.id)"]
                        == "value-\(field.id)",
                    "\(kind) lost \(field.id) on the way through LoginSet")
            }
        }
    }

    /// Every backend marks exactly the field that IDENTIFIES its login as
    /// required — which is what the login-set editor gates Save on since the
    /// `switch` over `ConnectionKind` (that returned "always disabled" for
    /// `.webdav`) is gone.
    @Test(arguments: ConnectionKind.allCases)
    func anEmptyCredentialFormIsIncompleteForEveryBackend(kind: ConnectionKind) {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        #expect(!descriptor.credentialSchema.missingRequiredFields(
            in: descriptor.defaultValues, namespace: descriptor.fieldNamespace).isEmpty,
            "\(kind) marks no credential field required, so its editor could save a nameless login")
    }

    @Test func aFilledWebDAVCredentialFormIsComplete() {
        let descriptor = BackendDescriptor.descriptor(for: .webdav)
        var values = descriptor.defaultValues
        values[WebDAVField.username] = "tim"
        #expect(descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace).isEmpty)
    }

    /// Whitespace is not a value (M15's trimming rule, now in the schema).
    @Test func aBlankRequiredFieldStillCountsAsMissing() {
        let descriptor = BackendDescriptor.descriptor(for: .webdav)
        var values = descriptor.defaultValues
        values[WebDAVField.username] = "   "
        #expect(descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace).map(\.id)
            == [WebDAVField.username.rawValue])
    }
}

/// Test double proving `.agent` resolution never reaches into the Keychain
/// (M10d spec §3): `password(for:)` fails the test if called at all.
private final class NoReadAllowedStore: SecretStore, @unchecked Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? {
        Issue.record("agent resolution must not read the keychain")
        return nil
    }
    func deletePassword(for sessionID: UUID) throws {}
}
