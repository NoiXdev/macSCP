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

    /// The guard for `SchemaFormView.skipping` (M22/T9): every id the form is
    /// told to skip must still name a REAL declared field, and that field must
    /// be a `.group` — the one shape the generic renderer's vocabulary cannot
    /// express, which is why the App draws it by hand.
    ///
    /// Without this, a renamed field turns a skip into a silent no-op (two
    /// jump blocks on screen), and a field that STOPS being hand-drawn keeps
    /// being skipped — a row that vanishes from the form with nothing failing
    /// anywhere. The App has no test target, so this is the only place the
    /// question can be asked.
    @Test func everySkippedFieldIsADeclaredGroup() {
        var found: Set<String> = []
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            for schema in [descriptor.connectionSchema, descriptor.credentialSchema] {
                for field in schema.fields
                where BackendDescriptor.customRenderedFieldIDs.contains(field.id) {
                    found.insert(field.id)
                    guard case .group = field.kind else {
                        let message = "\(kind).\(field.id) is skipped by the form but is not a "
                            + "group — the renderer can draw it, so nothing should hide it"
                        Issue.record(Comment(rawValue: message))
                        continue
                    }
                }
            }
        }
        let orphans = BackendDescriptor.customRenderedFieldIDs.subtracting(found)
        #expect(orphans.isEmpty, "skipped ids that match no declared field, so they hide nothing")
    }

    /// The guard for `ConnectionField.identity` (M23/P3): every backend must
    /// name at least one field that makes a connection of its kind DISTINCT,
    /// and none of them may be a secret.
    ///
    /// Both halves are load-bearing, and neither is a compile error. A backend
    /// that declares nothing gets a key of just its kind — every session of
    /// that protocol collapses into one duplicate, which is exactly the defect
    /// the pre-M23 endpoint-triple key produced for S3 and WebDAV, only
    /// reintroduced by omission rather than by design. And a secret in an
    /// identity key would put a password into `SessionImportPlanner`'s
    /// in-memory key set, where nothing about the surrounding code expects
    /// one; an access key ID is an opaque credential but NOT a secret, which
    /// is why it may be identifying and `secretAccessKey` may not.
    @Test func everyBackendDeclaresANonSecretIdentity() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            #expect(
                !descriptor.identifyingFields.isEmpty,
                Comment(rawValue: "\(kind) names no identifying field, so every session of "
                    + "that kind would import as one and the same duplicate"))
            for field in descriptor.identifyingFields {
                #expect(
                    !field.isSecret,
                    Comment(rawValue: "\(kind).\(field.id) is a secret and must never enter "
                        + "a duplicate key"))
            }
        }
    }

    /// What each backend actually declares, pinned as a whole. The guard above
    /// says "at least one and no secret"; this says WHICH — so that adding a
    /// field to an identity, or dropping one from it, is a decision somebody
    /// made on purpose rather than a side effect of editing a schema. The
    /// import consequences are pinned in `SessionImportPlannerTests`.
    @Test func theDeclaredIdentitiesAreTheEndpointTripleAndItsTwoAnalogues() {
        func identifyingIDs(_ kind: ConnectionKind) -> [String] {
            BackendDescriptor.descriptor(for: kind).identifyingFields.map(\.id)
        }
        #expect(identifyingIDs(.ssh) == [
            SSHField.host.rawValue, SSHField.port.rawValue, SSHField.username.rawValue,
        ])
        #expect(identifyingIDs(.s3) == [
            S3Field.endpoint.rawValue, S3Field.bucket.rawValue, S3Field.accessKeyID.rawValue,
        ])
        #expect(identifyingIDs(.webdav) == [
            WebDAVField.baseURL.rawValue, WebDAVField.username.rawValue,
        ])
    }

    /// The host is the ONE case-folded field anywhere. DNS is case-insensitive,
    /// so `WEB-01` and `web-01` are one machine; a bucket name, a URL path and
    /// an access key ID are case-SENSITIVE, and folding them would merge
    /// connections that are genuinely different.
    @Test func onlyTheSSHHostIsCaseFolded() {
        var folded: [String] = []
        for kind in ConnectionKind.allCases {
            for field in BackendDescriptor.descriptor(for: kind).identifyingFields
            where field.identity == .caseInsensitive {
                folded.append("\(kind.rawValue).\(field.id)")
            }
        }
        #expect(folded == ["ssh.\(SSHField.host.rawValue)"])
    }

    /// A group is the ONLY thing any backend hand-draws — pinned so a new
    /// group added to a schema is a deliberate decision about whether the
    /// generic renderer can handle it, not a silent one.
    @Test func onlyTheSSHJumpIsHandDrawn() {
        #expect(BackendDescriptor.customRenderedFieldIDs == [SSHField.jump.rawValue])
    }
}
