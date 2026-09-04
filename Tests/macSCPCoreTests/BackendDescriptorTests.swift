import Foundation
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
        #expect(c.supportsRemoteChecksum)
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
        // TRUE since the checksum work of 2026-08-31: S3 computes nothing on
        // request, but it can answer the question from the ETag the listing
        // already carries — and whether that ETag describes the object's
        // content is carried by the result's provenance, not by this flag.
        #expect(c.supportsRemoteChecksum)
        #expect(c.transport == .optionalTLS)
    }

    /// Pins `ProtocolCapabilities.authenticatesHostKey` against an
    /// INDEPENDENT derivation of the same fact, so the axis cannot silently
    /// drift from the code it describes: which backend's `connect` closure
    /// (`BackendDescriptor.swift:428-526`) actually forwards the
    /// `HostKeyDecider` argument to a host-key-consuming API, rather than
    /// dropping it on the floor as `_`. SSH's closure passes it on as
    /// `onUnknownHostKey:` to `CitadelFileSystem.connect`; S3's ignores it
    /// entirely; WebDAV's ignores it too and authenticates the server
    /// through its own, separate certificate decider instead — a TLS
    /// certificate is not a host key.
    ///
    /// The switch below is exhaustive over `ConnectionKind` (this replaces
    /// `CLIMatrix.hasHostKeys`'s former exhaustive switch, moved here so the
    /// capability axis is checked against the same reasoning that used to
    /// gate the CLI matrix directly), so a fourth backend does not compile
    /// here until someone says which side of this it is on.
    @Test func authenticatesHostKeyMatchesWhichBackendsConnectClosureUsesTheDecider() {
        for kind in ConnectionKind.allCases {
            let derivedFromConnectClosure: Bool
            switch kind {
            case .ssh: derivedFromConnectClosure = true
            case .s3, .webdav: derivedFromConnectClosure = false
            }
            #expect(
                BackendDescriptor.descriptor(for: kind).capabilities.authenticatesHostKey
                    == derivedFromConnectClosure,
                Comment(rawValue: "\(kind).capabilities.authenticatesHostKey disagrees with "
                    + "which backend's connect closure forwards the HostKeyDecider"))
        }
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

    /// The guard for `ConnectionField.secretRole` (M24): every secret field in
    /// either schema must declare what its value means for a login's
    /// identity, because a missing role is read as `.credential` — the field
    /// then enters the identity key by default, which is the safe direction
    /// but not always the right one (an SSH passphrase must NOT enter it).
    @Test func everySecretFieldDeclaresItsRole() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            for schema in [descriptor.connectionSchema, descriptor.credentialSchema] {
                for field in schema.fields where field.isSecret {
                    #expect(
                        field.secretRole != nil,
                        Comment(rawValue: "\(kind).\(field.id) is a secret and declares no "
                            + "secretRole, so a missing value would be read as .credential"))
                }
            }
        }
    }

    /// The reverse guard: no field that is never read as a secret may declare
    /// a role — `secretRole` is meaningless outside `.secret`, and a role on
    /// the wrong field would be a role nothing ever consults.
    @Test func noNonSecretFieldDeclaresASecretRole() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            for schema in [descriptor.connectionSchema, descriptor.credentialSchema] {
                for field in schema.fields where !field.isSecret {
                    #expect(
                        field.secretRole == nil,
                        Comment(rawValue: "\(kind).\(field.id) is not a secret but declares a "
                            + "secretRole, which nothing ever reads"))
                }
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

    // MARK: - visibleSecretField(for:) (M25/T2)

    /// ssh-agent is the one case that shows no secret field at all: the key
    /// material lives with the agent, so there is nothing on screen to ask
    /// for.
    @Test func sshAgentSessionShowsNoSecretField() {
        let session = sshSession(name: "agent-box", authKind: .agent)
        #expect(BackendDescriptor.descriptor(for: .ssh).visibleSecretField(for: session) == nil)
    }

    @Test func sshPasswordSessionShowsItsPasswordField() {
        let session = sshSession(name: "password-box", authKind: .password)
        let field = BackendDescriptor.descriptor(for: .ssh).visibleSecretField(for: session)
        #expect(field?.id == SSHField.password.rawValue)
    }

    @Test func sshPrivateKeySessionShowsItsPassphraseField() {
        let session = sshSession(name: "key-box", authKind: .privateKey, keyPath: "/k")
        let field = BackendDescriptor.descriptor(for: .ssh).visibleSecretField(for: session)
        #expect(field?.id == SSHField.passphrase.rawValue)
    }

    @Test func s3SessionAlwaysShowsItsSecretField() {
        let session = s3Session(name: "bucket")
        let field = BackendDescriptor.descriptor(for: .s3).visibleSecretField(for: session)
        #expect(field?.id == S3Field.secretAccessKey.rawValue)
    }

    @Test func webdavSessionAlwaysShowsItsPasswordField() {
        let session = webdavSession(name: "cloud")
        let field = BackendDescriptor.descriptor(for: .webdav).visibleSecretField(for: session)
        #expect(field?.id == WebDAVField.password.rawValue)
    }

    /// No fixture can build a `.ssh` session with a `nil` SSH block — every
    /// SSH fixture fills one — so this constructs `StoredSession` directly,
    /// the one sanctioned exception to the fixture rule (see
    /// `SessionFixtures.swift`'s header comment).
    ///
    /// Through M25 this pinned the OPPOSITE answer: a missing SSH block read
    /// through `StoredSession`'s inventing accessors (`authKind` defaulting
    /// to `.password`) into a POPULATED bag, exactly like a normal password
    /// session. M26 deletes those accessors and gives `SSHFieldSchema
    /// .values(from:)` a guard of its own, so `.ssh` now yields the empty bag
    /// on a missing block, same as `.s3`/`.webdav` always have — there is no
    /// more asymmetry for this case to pin.
    @Test func anSSHSessionWithoutItsBlockYieldsTheEmptyBag() {
        let session = StoredSession(
            id: UUID(), name: "blockless", groupID: nil, loginSetID: nil, kind: .ssh)
        let descriptor = BackendDescriptor.descriptor(for: .ssh)
        #expect(descriptor.visibleSecretField(for: session) == nil)
        #expect(descriptor.sessionValues(session).raw.isEmpty)
    }

    /// Guards `SessionListViewModel.updateSession`'s leftover-slot
    /// deletion: it deletes the session's Keychain entry precisely when
    /// `visibleSecretField(for:)` returns nil. Today that never happens for
    /// `.s3`/`.webdav` only because neither backend's secret field declares a
    /// `visibleWhen` — `FieldVisibility.evaluate`'s `guard let condition else
    /// { return true }` makes an unconditioned field visible even against the
    /// EMPTY bag a blockless session yields.
    /// Since M26 all three backends' `sessionValues(_:)` return that same
    /// empty bag for a blockless session — `.ssh` no longer differs from
    /// `.s3`/`.webdav` here — so the property this test pins rests solely on
    /// the absent `visibleWhen`, not on any per-backend fallback. If a
    /// `visibleWhen` is ever added to
    /// `S3Field.secretAccessKey` — nothing here needs one today, but
    /// `WebDAVField.password` already supports the shape via the "anonymous"
    /// toggle documented on `WebDAVFieldSchema`, so the pattern is a plausible
    /// future edit — a blockless `.s3` session run through `updateSession`
    /// (reachable from the UI via rename or drag-to-group) would take the
    /// `== nil` branch and silently delete a LIVE Keychain entry. This test is
    /// the only thing that would catch that: it fails the moment
    /// `visibleSecretField(for:)` stops being non-nil for a blockless `.s3`
    /// session.
    ///
    /// No fixture can build a `.s3` session with a `nil` S3 block — `s3Session`
    /// in `SessionFixtures.swift` always fills one — so this constructs
    /// `StoredSession` directly, the same sanctioned exception the SSH twin
    /// above uses.
    @Test func anS3SessionWithoutItsBlockStillShowsItsSecretField() {
        let session = StoredSession(
            id: UUID(), name: "blockless", groupID: nil, loginSetID: nil, kind: .s3)
        let field = BackendDescriptor.descriptor(for: .s3).visibleSecretField(for: session)
        #expect(field?.id == S3Field.secretAccessKey.rawValue)
    }

    /// WebDAV twin of the S3 case above, and the more pointed of the two:
    /// `WebDAVFieldSchema` already documents an "anonymous" configuration that
    /// would need `WebDAVField.password` to carry a `visibleWhen` — the one
    /// concrete change that would flip this property. Same guard, same
    /// consequence (`updateSession` deleting a live Keychain entry on a
    /// rename), same reasoning as the S3 test's doc comment.
    ///
    /// No fixture can build a `.webdav` session with a `nil` WebDAV block —
    /// `webdavSession` in `SessionFixtures.swift` always fills one — so this
    /// constructs `StoredSession` directly, the same sanctioned exception the
    /// SSH twin above uses.
    @Test func aWebDAVSessionWithoutItsBlockStillShowsItsPasswordField() {
        let session = StoredSession(
            id: UUID(), name: "blockless", groupID: nil, loginSetID: nil, kind: .webdav)
        let field = BackendDescriptor.descriptor(for: .webdav).visibleSecretField(for: session)
        #expect(field?.id == WebDAVField.password.rawValue)
    }

    // MARK: - visibleSecretField(for set:) (M28/T1)

    /// The LoginSet twin of the StoredSession question. Both ask
    /// `visibleSecretField` over the same schema; only the value source differs.
    @Test func aPasswordLoginSetShowsItsPasswordField() throws {
        let set = LoginSet(name: "deploy", username: "deploy", authKind: .password)
        let field = BackendDescriptor.descriptor(for: .ssh).visibleSecretField(for: set)
        #expect(field?.id == SSHField.password.rawValue)
    }

    @Test func anAgentLoginSetShowsNoSecretField() throws {
        let set = LoginSet(name: "agent", username: "deploy", authKind: .agent)
        #expect(BackendDescriptor.descriptor(for: .ssh).visibleSecretField(for: set) == nil)
    }

    /// The passphrase row IS on screen for a key set, so this is not the
    /// agent's nil case — it is the second way a set can need no secret, and
    /// the assertion on `isRequired` is what distinguishes them. It is also
    /// what lets `SessionListViewModel.setCoversItsLogin` answer for a key set
    /// without a `ManagedKeyStore` of its own.
    @Test func aPrivateKeyLoginSetShowsAnOptionalPassphraseField() throws {
        let set = LoginSet(
            name: "key", username: "deploy", authKind: .privateKey, keyPath: "/k")
        let field = BackendDescriptor.descriptor(for: .ssh).visibleSecretField(for: set)
        #expect(field?.id == SSHField.passphrase.rawValue)
        #expect(field?.isRequired == false)
    }
}
