import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHFieldSchema")
struct SSHFieldSchemaTests {
    private func passwordValues() -> FieldValues {
        var values = FieldValues()
        values[SSHField.host] = "server.example.com"
        values[SSHField.port] = "22"
        values[SSHField.username] = "tim"
        values[SSHField.authKind] = "password"
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .ssh), fields: SSHField.self).isEmpty)
    }

    /// Both enums declare their own namespace, so the jump host's `host`
    /// cannot overwrite the target's.
    @Test func theTwoFieldEnumsDoNotShareStorage() {
        #expect(SSHField.namespace == "SSHField")
        #expect(SSHJumpField.namespace == "SSHJumpField")

        var values = passwordValues()
        values[SSHField.jump, SSHJumpField.host] = "bastion.example.com"
        #expect(values[SSHField.host] == "server.example.com")
        #expect(values[SSHField.jump, SSHJumpField.host] == "bastion.example.com")
    }

    @Test func makeConfigBuildsPasswordAuth() throws {
        let config = try SSHFieldSchema.makeConfig(passwordValues(), "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh, got \(config)")
            return
        }
        #expect(ssh.host == "server.example.com")
        #expect(ssh.port == 22)
        #expect(ssh.username == "tim")
        #expect(ssh.auth == .password("hunter2"))
    }

    @Test func makeConfigBuildsPrivateKeyAuth() throws {
        var values = passwordValues()
        values[SSHField.authKind] = "privateKey"
        values[SSHField.keyPath] = "/Users/tim/.ssh/id_ed25519"
        let config = try SSHFieldSchema.makeConfig(values, "passphrase")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.auth == .privateKey(
            keyPath: "/Users/tim/.ssh/id_ed25519", passphrase: "passphrase"))
    }

    /// An unencrypted key carries no passphrase: an empty secret must stay
    /// nil rather than become an empty passphrase.
    @Test func makeConfigLeavesAnEmptyPassphraseNil() throws {
        var values = passwordValues()
        values[SSHField.authKind] = "privateKey"
        values[SSHField.keyPath] = "/Users/tim/.ssh/id_ed25519"
        let config = try SSHFieldSchema.makeConfig(values, "")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.auth == .privateKey(
            keyPath: "/Users/tim/.ssh/id_ed25519", passphrase: nil))
    }

    /// Agent auth needs no secret at all — an empty one must not turn into an
    /// empty password.
    @Test func makeConfigBuildsAgentAuthWithoutASecret() throws {
        var values = passwordValues()
        values[SSHField.authKind] = "agent"
        let config = try SSHFieldSchema.makeConfig(values, "")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.auth == .agent)
    }

    @Test func makeConfigRejectsPrivateKeyAuthWithoutAPath() {
        var values = passwordValues()
        values[SSHField.authKind] = "privateKey"
        values[SSHField.keyPath] = "   "
        #expect(throws: SSHConnectionConfig.ConfigError.emptyKeyPath) {
            _ = try SSHFieldSchema.makeConfig(values, "p")
        }
    }

    /// The key path is only shown for private-key auth. That rule lives in the
    /// schema, so the form does not have to know it.
    @Test func theKeyPathFieldIsConditionalOnTheAuthKind() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        let keyPath = try #require(schema.fields.first { $0.id == SSHField.keyPath.rawValue })
        let condition = try #require(keyPath.visibleWhen)
        #expect(condition.field == SSHField.authKind.rawValue)
        #expect(condition.equals == "privateKey")

        var values = passwordValues()
        #expect(!FieldVisibility.isVisible(keyPath, in: values, namespace: "SSHField"))
        values[SSHField.authKind] = "privateKey"
        #expect(FieldVisibility.isVisible(keyPath, in: values, namespace: "SSHField"))
    }

    /// The managed-key picker's options come from a store the Core cannot
    /// reach, so the schema names the source and the App resolves it.
    @Test func theManagedKeyFieldIsAPickerOverManagedKeys() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        let field = try #require(schema.fields.first { $0.id == SSHField.managedKeyID.rawValue })
        guard case .picker(let source) = field.kind else {
            Issue.record("expected a picker, got \(field.kind)")
            return
        }
        #expect(source == .managedKeys)
    }

    /// The jump host is one group, exactly one level deep.
    @Test func theJumpFieldIsAGroupOfLeafFields() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        let field = try #require(schema.fields.first { $0.id == SSHField.jump.rawValue })
        guard case .group(let leaves) = field.kind else {
            Issue.record("expected a group, got \(field.kind)")
            return
        }
        #expect(Set(leaves.map(\.id)) == Set(SSHJumpField.allCases.map(\.rawValue)))
    }

    /// The secret belongs to the credential schema — the same split S3 and
    /// WebDAV got. The jump's own password leaf is not covered by this: a
    /// nested login has no second credential schema to live in.
    @Test func theSecretLivesInTheCredentialSchemaOnly() {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        #expect(descriptor.credentialSchema.fields.contains {
            $0.id == SSHField.password.rawValue && $0.isSecret
        })
        #expect(!descriptor.connectionSchema.fields.contains {
            $0.id == SSHField.password.rawValue
        })
    }

    @Test func valuesRoundTripThroughTheStoredSession() {
        var session = StoredSession(
            name: "prod", host: "server.example.com", port: 22, username: "tim")
        SSHFieldSchema.apply(passwordValues(), to: &session)
        let back = SSHFieldSchema.values(from: session)
        #expect(back[SSHField.host] == "server.example.com")
        #expect(back[SSHField.port] == "22")
        #expect(back[SSHField.username] == "tim")
        #expect(back[SSHField.authKind] == "password")
    }

    /// `StoredSession` carries far more than the connection fields. Rebuilding
    /// it would silently drop a user's group, login-set binding or jump host,
    /// so the adapter writes ONLY what `SSHField` covers.
    @Test func applyTouchesNoPropertyOutsideTheSchema() {
        let groupID = UUID()
        let loginSetID = UUID()
        let jump = StoredSession.JumpSpec(host: "bastion.example.com", username: "ops")
        var session = StoredSession(
            id: UUID(), name: "prod", host: "old.example.com", port: 2200,
            username: "old", authKind: .agent, keyPath: nil, groupID: groupID,
            loginSetID: loginSetID, jump: jump)
        let id = session.id

        SSHFieldSchema.apply(passwordValues(), to: &session)

        #expect(session.host == "server.example.com")
        #expect(session.port == 22)
        #expect(session.username == "tim")
        #expect(session.authKind == .password)
        // Everything the schema does not cover survives untouched.
        #expect(session.id == id)
        #expect(session.name == "prod")
        #expect(session.groupID == groupID)
        #expect(session.loginSetID == loginSetID)
        #expect(session.jump == jump)
        #expect(session.kind == .ssh)
    }

    /// A key path belongs to private-key auth only: switching to a password
    /// must clear it rather than leave a stale path on disk.
    @Test func applyClearsTheKeyPathWhenAuthIsNotAPrivateKey() {
        var session = StoredSession(
            name: "prod", host: "server.example.com", username: "tim",
            authKind: .privateKey, keyPath: "/Users/tim/.ssh/id_ed25519")
        SSHFieldSchema.apply(passwordValues(), to: &session)
        #expect(session.keyPath == nil)
    }

    @Test func displaySummaryIsUserAtHost() {
        #expect(SSHFieldSchema.displaySummary(passwordValues()) == "tim@server.example.com")
    }

    /// The descriptor points at this schema — before M22 it threw
    /// "not migrated yet" for every call.
    @Test func theDescriptorIsWiredToTheSchema() throws {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        #expect(descriptor.connectionSchema == SSHFieldSchema.connection)
        #expect(descriptor.credentialSchema == SSHFieldSchema.credential)
        #expect(descriptor.displaySummary(passwordValues()) == "tim@server.example.com")
        #expect(descriptor.requiresSecret)
        #expect(descriptor.secretEnvironmentVariable == "MACSCP_PASSWORD")

        let config = try descriptor.makeConfig(passwordValues(), "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh, got \(config)")
            return
        }
        #expect(ssh.host == "server.example.com")
    }
}
