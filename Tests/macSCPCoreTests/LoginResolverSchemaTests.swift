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
            name: "s", loginSetID: set.id, kind: .webdav)

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
            name: "s", loginSetID: set.id, kind: .s3)

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
        let session = sshSession(
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
        let session = sshSession(
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
        let session = sshSession(
            name: "s", host: "h", username: "unused", loginSetID: set.id)

        let values = try #require(try LoginResolver.resolve(
            session: session, sets: [set], secrets: NoReadAllowedStore()))
        #expect(values[SSHField.username] == "deploy")
        #expect(values[SSHField.authKind] == StoredSession.AuthKind.agent.rawValue)
        #expect(values[SSHField.password] == "")
        #expect(values[SSHField.passphrase] == "")
    }

    @Test func aSessionWithoutASetResolvesToNil() throws {
        let session = sshSession(name: "s", host: "h", port: 22, username: "u")
        #expect(try LoginResolver.resolve(
            session: session, sets: [], secrets: InMemorySecretStore()) == nil)
    }

    @Test func aMissingSetIsAnError() {
        let session = sshSession(
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
            name: "s", loginSetID: set.id, kind: .webdav)
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

    /// SSH and S3 mark the field that IDENTIFIES their login as required —
    /// which is what the login-set editor gates Save on since the `switch` over
    /// `ConnectionKind` (that returned "always disabled" for `.webdav`) is
    /// gone.
    ///
    /// `.webdav` is excluded deliberately (maintainer decision, M23/T5 fix
    /// round 1): anonymous WebDAV is supported, so neither of its credential
    /// fields is required and an empty WebDAV credential form is legitimately
    /// complete — pinned by `anEmptyWebDAVCredentialFormIsComplete` below.
    @Test(arguments: ConnectionKind.allCases.filter { $0 != .webdav })
    func anEmptyCredentialFormIsIncompleteForEveryBackend(kind: ConnectionKind) {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        #expect(!descriptor.credentialSchema.missingRequiredFields(
            in: descriptor.defaultValues, namespace: descriptor.fieldNamespace).isEmpty,
            "\(kind) marks no credential field required, so its editor could save a nameless login")
    }

    /// Anonymous WebDAV (maintainer decision, M23/T5 fix round 1): a public
    /// read-only share, or a LAN box with no auth, is a real deployment. Since
    /// M23 `connect()` honours `isRequired`, so marking these required would
    /// refuse such a server before the connect was even attempted.
    @Test func anEmptyWebDAVCredentialFormIsComplete() {
        let descriptor = BackendDescriptor.descriptor(for: .webdav)
        var values = descriptor.defaultValues
        values[WebDAVField.username] = ""
        values[WebDAVField.password] = ""
        #expect(descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace).isEmpty)
    }

    /// Repointed from WebDAV to S3 (M23/T5 fix round 1): WebDAV no longer has a
    /// required credential field, so it can no longer carry this assertion.
    /// The mechanic under test is unchanged — a form with every required
    /// credential filled reports nothing missing.
    @Test func aFilledCredentialFormIsComplete() {
        let descriptor = BackendDescriptor.descriptor(for: .s3)
        var values = descriptor.defaultValues
        values[S3Field.accessKeyID] = "AKIAEXAMPLE"
        values[S3Field.secretAccessKey] = "shh-secret"
        #expect(descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace).isEmpty)
    }

    /// Whitespace is not a value (M15's trimming rule, now in the schema).
    ///
    /// Repointed from WebDAV to SSH (M23/T5 fix round 1) for the same reason as
    /// the test above; SSH's `username` is the required credential field now
    /// standing in as the subject. `password` is filled here so the assertion
    /// below isolates the whitespace-username case rather than also catching
    /// SSH's own password requirement, which is visible under the default
    /// password auth kind.
    @Test func aBlankRequiredFieldStillCountsAsMissing() {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        var values = descriptor.defaultValues
        values[SSHField.username] = "   "
        values[SSHField.password] = "hunter2"
        #expect(descriptor.credentialSchema.missingRequiredFields(
            in: values, namespace: descriptor.fieldNamespace).map(\.id)
            == [SSHField.username.rawValue])
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
