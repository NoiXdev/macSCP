import Foundation
import Testing
@testable import macSCPCore

/// The view model on `FieldValues` (M22/T8): one map instead of a typed
/// property per protocol, and one factory instead of a `switch` per call site.
@Suite("ConnectionViewModel schema")
@MainActor
struct ConnectionViewModelSchemaTests {
    /// `ConnectionViewModel` has no zero-arg initializer (its `connector` is
    /// required) — these tests never reach `connect()`, so it is never called.
    private func makeModel() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
    }

    @Test func buildsAnSSHConfigFromValues() throws {
        let model = makeModel()
        model.kind = .ssh
        model.values[SSHField.host] = "server.example.com"
        model.values[SSHField.port] = "22"
        model.values[SSHField.username] = "tim"
        model.values[SSHField.authKind] = "password"

        let config = try BackendDescriptor.descriptor(for: model.kind).makeConfig(model.values, "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.host == "server.example.com")
        #expect(ssh.auth == .password("hunter2"))
    }

    /// The factory takes ONE secret, and a jump host's lives in its own
    /// Keychain slot — so `makeConfig` must not build a jump, and the caller
    /// that can resolve the second secret attaches it. A config that silently
    /// dropped the jump would dial the target directly, bypassing a bastion
    /// the network policy may require.
    @Test func makeConfigLeavesTheJumpToTheCaller() throws {
        let model = makeModel()
        model.kind = .ssh
        model.values[SSHField.host] = "server.example.com"
        model.values[SSHField.username] = "tim"
        model.jumpEnabled = true
        model.jumpHost = "bastion.example.com"
        model.jumpUsername = "ops"

        let config = try BackendDescriptor.descriptor(for: model.kind).makeConfig(model.values, "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.jump == nil)
    }

    /// …and `connect()` is the caller that attaches it. This is the guard on
    /// the whole point of `makeConfig`'s omission: the config that actually
    /// reaches the connector carries the bastion.
    @Test func connectAttachesTheJumpTheFactoryOmits() async {
        let model = ConnectionViewModel(connector: { config, _ in
            guard case .ssh(let ssh) = config else {
                Issue.record("expected .ssh")
                throw RemoteFSError.protocolError(reason: "expected .ssh")
            }
            #expect(ssh.jump?.host == "bastion.example.com")
            #expect(ssh.jump?.username == "ops")
            #expect(ssh.jump?.auth == .password("bastion-pass"))
            return MockRemoteFileSystem(tree: ["/": []])
        })
        model.host = "server.example.com"
        model.username = "tim"
        model.password = "hunter2"
        model.jumpEnabled = true
        model.jumpHost = "bastion.example.com"
        model.jumpUsername = "ops"
        model.jumpPassword = "bastion-pass"

        #expect(await model.connect() != nil)
    }

    @Test func buildsAWebDAVConfigFromValues() throws {
        let model = makeModel()
        model.kind = .webdav
        model.values[WebDAVField.baseURL] = "https://cloud.example.com"
        model.values[WebDAVField.username] = "tim"

        let config = try BackendDescriptor.descriptor(for: model.kind).makeConfig(model.values, "app-password")
        guard case .webdav(let dav) = config else {
            Issue.record("expected .webdav")
            return
        }
        #expect(dav.baseURL == "https://cloud.example.com")
        #expect(dav.password == "app-password")
    }

    /// Switching protocol must not carry the previous one's values across —
    /// they are namespaced, so an S3 endpoint cannot leak into a WebDAV form,
    /// but the user should also not see a stale form.
    @Test func switchingKindClearsTheForm() {
        let model = makeModel()
        model.kind = .s3
        model.values[S3Field.bucket] = "backups"
        model.kind = .webdav
        #expect(model.values[S3Field.bucket] == "")
    }

    /// Assigning the SAME kind is not a switch. `exitEditMode()` sets `.ssh`
    /// unconditionally and is documented to keep the field values for its
    /// callers (teardown, connect-stored, import), which overwrite them right
    /// after — an unguarded reset would blank the form under them.
    @Test func reassigningTheSameKindKeepsTheForm() {
        let model = makeModel()
        model.host = "server.example.com"
        model.kind = .ssh
        #expect(model.host == "server.example.com")
    }

    /// A brand-new form is not empty: the port and the auth kind come from the
    /// backend's declared defaults, which is what keeps the picker from
    /// rendering blank and the user from having to type 22.
    @Test func aFreshFormCarriesTheBackendsDefaults() {
        let model = makeModel()
        #expect(model.port == "22")
        #expect(model.authChoice == .password)
        #expect(model.jumpPort == "22")

        model.kind = .s3
        #expect(model.values.raw[S3Field.namespace + ".usePathStyle"] == "false")
    }

    @Test func missingRequiredFieldSurfacesAsAFailure() {
        let model = makeModel()
        model.kind = .webdav
        #expect(throws: (any Error).self) {
            _ = try BackendDescriptor.descriptor(for: model.kind).makeConfig(model.values, "p")
        }
    }

    /// The typed properties are views onto `values`, not a second copy — the
    /// drift that no compiler catches is what M22 exists to remove.
    @Test func theTypedPropertiesAndTheValueMapAreTheSameStorage() {
        let model = makeModel()
        model.host = "server.example.com"
        #expect(model.values[SSHField.host] == "server.example.com")

        model.values[SSHField.username] = "tim"
        #expect(model.username == "tim")

        model.kind = .s3
        model.s3Bucket = "backups"
        #expect(model.values[S3Field.bucket] == "backups")
    }

    /// The jump's fields live under the schema's `jump` GROUP, so the jump's
    /// own host can never overwrite the target's.
    @Test func theJumpFieldsLiveInTheGroupNotBesideTheTargets() {
        let model = makeModel()
        model.host = "server.example.com"
        model.jumpHost = "bastion.example.com"

        #expect(model.values[SSHField.host] == "server.example.com")
        #expect(model.values[SSHField.jump, SSHJumpField.host] == "bastion.example.com")
        #expect(model.values.raw["SSHField.jump.host"] == "bastion.example.com")
    }

    /// SSH splits its secret across two fields (password, passphrase) and only
    /// one is ever on screen. Reading follows the auth kind; WRITING fills
    /// both, so a programmatic fill — a login set's secret, a Keychain
    /// passphrase — survives a later auth-kind switch.
    @Test func theSecretSlotFollowsTheAuthKindOnReadAndFillsBothOnWrite() {
        let model = makeModel()
        model.password = "hunter2"
        #expect(model.values[SSHField.password] == "hunter2")
        #expect(model.values[SSHField.passphrase] == "hunter2")

        model.authChoice = .privateKey
        #expect(model.password == "hunter2")

        // What the form itself writes goes to exactly one of the two.
        model.values[SSHField.passphrase] = "key-phrase"
        #expect(model.password == "key-phrase")
        model.authChoice = .password
        #expect(model.password == "hunter2")
    }

    /// Disconnecting must not leave a secret behind in a slot the current auth
    /// kind no longer reads.
    @Test func clearingThePasswordEmptiesEverySecretSlot() {
        let model = makeModel()
        model.values[SSHField.password] = "hunter2"
        model.values[SSHField.passphrase] = "key-phrase"
        model.values[WebDAVField.password] = "app-password"

        model.clearPassword()

        #expect(model.values[SSHField.password].isEmpty)
        #expect(model.values[SSHField.passphrase].isEmpty)
        #expect(model.values[WebDAVField.password].isEmpty)
    }
}
