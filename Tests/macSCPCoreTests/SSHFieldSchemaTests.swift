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

    /// The jump host's `host` cannot overwrite the target's — because of the
    /// `jump.` path segment, not because of `SSHJumpField.namespace`, which
    /// storage never uses (the OWNER's namespace prefixes a group member).
    @Test func theJumpPathSegmentKeepsTheTwoLoginsApart() {
        #expect(SSHField.namespace == "SSHField")
        #expect(SSHJumpField.namespace == "SSHJumpField")

        var values = passwordValues()
        values[SSHField.jump, SSHJumpField.host] = "bastion.example.com"
        #expect(values[SSHField.host] == "server.example.com")
        #expect(values[SSHField.jump, SSHJumpField.host] == "bastion.example.com")
        // The stored key is owner-namespaced and carries the group segment.
        #expect(values.raw["SSHField.jump.host"] == "bastion.example.com")
        #expect(values.raw["SSHJumpField.host"] == nil)
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
    ///
    /// Relocated in M22/T8 from the connection schema to the credential one.
    /// A key path is part of the LOGIN — a login set carries it — and the form
    /// renders both schemas now, so a field named by both would draw two rows
    /// and would keep being asked for in login-set mode, where the chosen set
    /// already supplies it. The visibility rule itself is unchanged.
    @Test func theKeyPathFieldIsConditionalOnTheAuthKind() throws {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        #expect(!descriptor.connectionSchema.fields.contains {
            $0.id == SSHField.keyPath.rawValue
        })
        let schema = descriptor.credentialSchema
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
    ///
    /// Relocated in M22/T8 for the same reason as the key path above: picking
    /// a key IS picking a login, and a login set supplies it.
    @Test func theManagedKeyFieldIsAPickerOverManagedKeys() throws {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        #expect(!descriptor.connectionSchema.fields.contains {
            $0.id == SSHField.managedKeyID.rawValue
        })
        let schema = descriptor.credentialSchema
        let field = try #require(schema.fields.first { $0.id == SSHField.managedKeyID.rawValue })
        guard case .picker(let source) = field.kind else {
            Issue.record("expected a picker, got \(field.kind)")
            return
        }
        #expect(source == .managedKeys)
    }

    /// The factory cannot resolve a jump host's secret — it takes exactly one
    /// secret and a jump has its own Keychain entry — so it must not build a
    /// jump at all. Silently dropping it here would let a bastion-only
    /// session dial its target directly: a timeout at best, a connection that
    /// bypasses a required bastion at worst. The caller attaches it.
    @Test func makeConfigLeavesTheJumpToTheCaller() throws {
        var values = passwordValues()
        values[SSHField.jump, SSHJumpField.host] = "bastion.example.com"
        values[SSHField.jump, SSHJumpField.port] = "2222"
        values[SSHField.jump, SSHJumpField.username] = "ops"
        values[SSHField.jump, SSHJumpField.authKind] = "password"
        let config = try SSHFieldSchema.makeConfig(values, "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.jump == nil)
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

    /// Both secrets belong to the credential schema — the same split S3 and
    /// WebDAV got. The jump's own password leaf is not covered by this: a
    /// nested login has no second credential schema to live in.
    @Test func theSecretsLiveInTheCredentialSchemaOnly() {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        for secret in [SSHField.password, SSHField.passphrase] {
            #expect(descriptor.credentialSchema.fields.contains {
                $0.id == secret.rawValue && $0.isSecret
            })
            #expect(!descriptor.connectionSchema.fields.contains {
                $0.id == secret.rawValue
            })
        }
    }

    /// The jump's `password` leaf is the ONLY `.secret` in any connection
    /// schema in the codebase, and it is there because a nested login has no
    /// credential schema of its own. `ConnectionField.isSecret` cannot see
    /// leaves (`LeafField` has none), so nothing else would catch a second
    /// one — and a save path persisting connection-schema values would write
    /// it into the session JSON in plaintext. This pins both halves: no
    /// top-level secret at all, and exactly one deliberate leaf exception.
    @Test func theOnlySecretInTheConnectionSchemaIsTheJumpsOwnPassword() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        #expect(!schema.fields.contains { $0.isSecret })

        let jump = try #require(schema.fields.first { $0.id == SSHField.jump.rawValue })
        guard case .group(let leaves) = jump.kind else {
            Issue.record("expected a group, got \(jump.kind)")
            return
        }
        #expect(leaves.filter { $0.kind == .secret }.map(\.id)
            == [SSHJumpField.password.rawValue])
    }

    /// The secret is two DIFFERENT fields, not one slot with two meanings —
    /// which is what the login-set editor has rendered since M10d: a password
    /// row, a passphrase row, and under `.agent` no secret row at all
    /// (spec §5.2). Exercised through the real visibility filter.
    @Test(arguments: [
        (StoredSession.AuthKind.password, [SSHField.password]),
        (.privateKey, [SSHField.passphrase]),
        (.agent, []),
    ])
    func theCredentialSchemaShowsTheRightSecretPerAuthKind(
        kind: StoredSession.AuthKind, expected: [SSHField]
    ) {
        var values = FieldValues()
        values[SSHField.authKind] = kind.rawValue
        let visible = SSHFieldSchema.credential
            .visibleFields(in: values, namespace: SSHField.namespace)
        let secrets = visible.filter(\.isSecret).map(\.id)
        #expect(secrets == expected.map(\.rawValue))
        // The auth kind itself is always askable, whatever it is.
        #expect(visible.contains { $0.id == SSHField.authKind.rawValue })
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

    /// Fix round 1 (M22/T11 review): two sessions to the same host on
    /// different ports — a bastion with a forwarded port, e.g.
    /// `admin@homelab:22` vs `admin@homelab:2222` — used to render an
    /// identical sidebar tooltip once the port was dropped. The port must
    /// come back for a non-default value.
    @Test func displaySummaryAppendsANonDefaultPort() {
        var values = passwordValues()
        values[SSHField.port] = "2222"
        #expect(SSHFieldSchema.displaySummary(values) == "tim@server.example.com:2222")
    }

    /// The default port stays suppressed — this is what keeps `:22` out of
    /// every ordinary tab title.
    @Test func displaySummarySuppressesTheDefaultPort() {
        var values = passwordValues()
        values[SSHField.port] = "22"
        #expect(SSHFieldSchema.displaySummary(values) == "tim@server.example.com")
    }

    /// An empty/unparsable port field (a hand-built `FieldValues` a test
    /// might construct — `sessionValues` always writes `String(session.port)`,
    /// so production values are never empty here) must fall back to the
    /// default rather than leaving a dangling trailing `:`.
    @Test func displaySummaryTreatsAnEmptyPortAsTheDefault() {
        var values = passwordValues()
        values[SSHField.port] = ""
        let summary = SSHFieldSchema.displaySummary(values)
        #expect(summary == "tim@server.example.com")
        #expect(!summary.hasSuffix(":"))
    }

    /// The descriptor points at this schema — before M22 it threw
    /// "not migrated yet" for every call.
    @Test func theDescriptorIsWiredToTheSchema() throws {
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        #expect(descriptor.connectionSchema == SSHFieldSchema.connection)
        #expect(descriptor.credentialSchema == SSHFieldSchema.credential)
        #expect(descriptor.displaySummary(passwordValues()) == "tim@server.example.com")
        #expect(descriptor.requiresSecret(passwordValues()))
        #expect(descriptor.secretEnvironmentVariable == "MACSCP_PASSWORD")

        let config = try descriptor.makeConfig(passwordValues(), "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh, got \(config)")
            return
        }
        #expect(ssh.host == "server.example.com")
    }
}
