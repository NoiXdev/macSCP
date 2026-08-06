import Testing
@testable import macSCPCore

@Suite("BackendDescriptor")
struct BackendDescriptorTests {
    @Test func sshCapabilities() {
        let c = BackendDescriptor.descriptor(for: .ssh).capabilities
        #expect(c.supportsShell)
        #expect(c.permissionModel == .posixMode)
        #expect(c.supportsSymlinks)
        #expect(c.atomicRename)
        #expect(c.directoriesAreReal)
        #expect(c.resumeMode == .append)
        #expect(!c.supportsPresignedURL)
        #expect(c.transport == .alwaysEncrypted)
    }

    @Test func s3Capabilities() {
        let c = BackendDescriptor.descriptor(for: .s3).capabilities
        #expect(!c.supportsShell)
        #expect(c.permissionModel == .none)
        #expect(!c.supportsSymlinks)
        #expect(!c.atomicRename)
        #expect(!c.directoriesAreReal)
        #expect(c.resumeMode == .rangeGet)
        #expect(c.supportsPresignedURL)          // capability is TRUE; M14 wires the action
        #expect(c.transport == .optionalTLS)
    }

    /// The secret access key lives in `credentialSchema`, not
    /// `connectionSchema` (M22): a secret belongs to the login, not the
    /// server, and that split is what lets one generic editor serve every
    /// backend's login sets instead of each protocol growing its own.
    @Test func s3ConnectionSchemaHasProviderPresetsAndTheSecretLivesInTheCredentialSchema() {
        let descriptor = BackendDescriptor.descriptor(for: .s3)
        let schema = descriptor.connectionSchema
        #expect(schema.presets.contains { $0.id == "aws" })
        #expect(schema.presets.contains { $0.id == "hetzner" })
        #expect(schema.presets.contains { $0.id == "custom" })
        #expect(descriptor.credentialSchema.fields.contains { $0.isSecret })
        #expect(!schema.fields.contains { $0.isSecret })
    }

    /// The guard `CLISecretSources` carries today, now expressed as a
    /// descriptor property. An agent-auth SSH session needs no secret; asking
    /// for one would make the CLI refuse a connection ssh-agent could serve.
    @Test func sshNeedsNoSecretForAgentAuth() {
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        var values = FieldValues()
        values[SSHField.authKind] = "agent"
        #expect(!ssh.requiresSecret(values))
        values[SSHField.authKind] = "password"
        #expect(ssh.requiresSecret(values))
        values[SSHField.authKind] = "privateKey"
        #expect(ssh.requiresSecret(values))
    }

    /// S3 and WebDAV always need one, whatever the values say.
    @Test func theOtherBackendsAlwaysNeedASecret() {
        for kind in [ConnectionKind.s3, .webdav] {
            #expect(BackendDescriptor.descriptor(for: kind).requiresSecret(FieldValues()))
        }
    }
}
