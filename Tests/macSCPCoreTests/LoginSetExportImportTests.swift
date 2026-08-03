import Foundation
import Testing
@testable import macSCPCore

/// The view-model half of the login-set export/import feature (M19/T8):
/// building a `LoginSetExportPayload` out of the store + Keychain, and
/// applying a `LoginSetImportPlan` back into both (plus the managed key
/// store). The planner itself is covered by `LoginSetImportPlannerTests`;
/// what is proven here is everything that TOUCHES state.
@Suite("Login set export/import")
@MainActor
struct LoginSetExportImportTests {
    private func makeVM() -> (SessionListViewModel, InMemorySecretStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-loginio-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))
        return (vm, secrets, dir)
    }

    private func keyStore(in dir: URL) -> ManagedKeyStore {
        ManagedKeyStore(directory: dir.appendingPathComponent("keys-state", isDirectory: true))
    }

    /// A real ed25519 key registered as a managed key, exactly as M17/M18 do.
    @discardableResult
    private func addManagedKey(
        to store: ManagedKeyStore, secrets: any SecretStore, name: String,
        passphrase: String? = nil
    ) throws -> ManagedKey {
        let generated = try SSHKeyGenerator.generate(
            type: .ed25519, comment: name, passphrase: passphrase, into: store.keyDirectory)
        let key = ManagedKey(
            name: name, comment: name, type: .ed25519, fingerprint: generated.fingerprint,
            publicKeyOpenSSH: generated.publicKeyOpenSSH, createdAt: Date(),
            hasPassphrase: passphrase != nil, fileName: generated.privateKeyURL.lastPathComponent)
        try store.add(key)
        if let passphrase { try secrets.savePassword(passphrase, for: key.id) }
        return key
    }

    private func path(of key: ManagedKey, in store: ManagedKeyStore) -> String {
        store.keyDirectory.appendingPathComponent(key.fileName).path(percentEncoded: false)
    }

    // MARK: - Export

    @Test func exportWithoutSecretsCarriesNoCredentials() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = LoginSet(name: "prod", username: "deploy")
        vm.saveLoginSet(set, secret: "hunter2")

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: false, includeKeyFiles: false,
            keyStore: keyStore(in: dir))

        #expect(result.payload.includesSecrets == false)
        #expect(result.payload.includesKeyFiles == false)
        #expect(result.payload.sets.count == 1)
        #expect(result.payload.sets[0].secret == nil)
        #expect(result.payload.sets[0].name == "prod")
        #expect(result.missingSecretCount == 0)
    }

    /// The flags must describe the FILE, not the request: both planners gate
    /// on them, so a `true` that nothing backs makes the import promise
    /// material that is not there.
    @Test func flagsDescribeWhatIsActuallyInTheFile() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.saveLoginSet(LoginSet(name: "no-secret", username: "u"), secret: nil)

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: true,
            keyStore: keyStore(in: dir))

        #expect(result.payload.includesSecrets == false)
        #expect(result.payload.includesKeyFiles == false)
        // A password set with no stored password IS worth reporting.
        #expect(result.missingSecretCount == 1)
    }

    @Test func exportWithSecretsCarriesThem() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.saveLoginSet(LoginSet(name: "prod", username: "deploy"), secret: "hunter2")

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: false,
            keyStore: keyStore(in: dir))

        #expect(result.payload.includesSecrets)
        #expect(result.payload.sets[0].secret == "hunter2")
        #expect(result.missingSecretCount == 0)
    }

    /// An `~/.ssh` key is never opened, even when key files were requested —
    /// only its path travels, and the set is counted as external.
    @Test func externalKeyPathsAreNeverEmbedded() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let external = dir.appendingPathComponent("id_ed25519")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("EXTERNAL PRIVATE KEY".utf8).write(to: external)
        vm.saveLoginSet(
            LoginSet(name: "ext", username: "u", authKind: .privateKey,
                     keyPath: external.path(percentEncoded: false)),
            secret: nil)

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: true,
            keyStore: keyStore(in: dir))

        #expect(result.payload.includesKeyFiles == false)
        #expect(result.payload.sets[0].embeddedKey == nil)
        #expect(result.externalKeyCount == 1)
        #expect(result.keyErrors.isEmpty)
    }

    @Test func managedKeysTravelWithTheirOwnPassphrase() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = keyStore(in: dir)
        let key = try addManagedKey(to: keys, secrets: secrets, name: "prod", passphrase: "pp")
        vm.saveLoginSet(
            LoginSet(name: "prod", username: "deploy", authKind: .privateKey,
                     keyPath: path(of: key, in: keys)),
            secret: nil)

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: true, keyStore: keys)

        #expect(result.payload.includesKeyFiles)
        #expect(result.payload.includesSecrets)
        #expect(result.payload.sets[0].embeddedKey?.passphrase == "pp")
        #expect(result.keysWithoutPassphrase == 0)
    }

    /// M19 finding 3: a managed key that arrived from an earlier import WITHOUT
    /// its passphrase has no slot of its own, so the passphrase the user typed
    /// afterwards lives in the LOGIN SET's slot. `EmbeddedKeyPorter.embed` only
    /// ever looks at the key's own slot and would ship a locked key whose
    /// passphrase this machine had all along — the caller fills it in.
    @Test func aPassphraseHeldBytheSetIsNotLostOnReExport() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = keyStore(in: dir)
        // Encrypted key, NO Keychain slot of its own — exactly what
        // `EmbeddedKeyPorter.materialize` produces for a secret-free import.
        let key = try addManagedKey(to: keys, secrets: secrets, name: "imported", passphrase: "pp")
        try secrets.deletePassword(for: key.id)
        vm.saveLoginSet(
            LoginSet(name: "prod", username: "deploy", authKind: .privateKey,
                     keyPath: path(of: key, in: keys)),
            secret: "pp")

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: true, keyStore: keys)

        #expect(result.payload.sets[0].embeddedKey?.hasPassphrase == true)
        #expect(result.payload.sets[0].embeddedKey?.passphrase == "pp")
        #expect(result.keysWithoutPassphrase == 0)
    }

    /// …and when NOBODY holds the passphrase, that is reported rather than
    /// silently shipped as an unopenable key.
    @Test func aKeyWithNoReachablePassphraseIsReported() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = keyStore(in: dir)
        let key = try addManagedKey(to: keys, secrets: secrets, name: "imported", passphrase: "pp")
        try secrets.deletePassword(for: key.id)
        vm.saveLoginSet(
            LoginSet(name: "prod", username: "deploy", authKind: .privateKey,
                     keyPath: path(of: key, in: keys)),
            secret: nil)

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: true, keyStore: keys)

        #expect(result.payload.sets[0].embeddedKey?.passphrase == nil)
        #expect(result.keysWithoutPassphrase == 1)
        // The key file itself still travels — only the passphrase stayed home.
        #expect(result.payload.includesKeyFiles)
    }

    @Test func aBrokenManagedKeyIsNamedAndTheRestStillExports() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = keyStore(in: dir)
        let key = try addManagedKey(to: keys, secrets: secrets, name: "gone")
        vm.saveLoginSet(
            LoginSet(name: "broken", username: "u", authKind: .privateKey,
                     keyPath: path(of: key, in: keys)),
            secret: nil)
        vm.saveLoginSet(LoginSet(name: "fine", username: "u2"), secret: "pw")
        // The metadata entry stays, the file disappears — the "user deleted
        // something under keys/ by hand" case.
        try FileManager.default.removeItem(atPath: path(of: key, in: keys))

        let result = vm.loginSetExportPayload(
            for: vm.loginSets, includeSecrets: true, includeKeyFiles: true, keyStore: keys)

        #expect(result.keyErrors == ["broken"])
        #expect(result.payload.sets.count == 2)
        #expect(result.payload.sets.contains { $0.name == "fine" && $0.secret == "pw" })
    }

    // MARK: - Import

    @Test func applyImportWritesSetsAndSecrets() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = LoginSet(name: "prod", username: "deploy")
        let plan = LoginSetImportPlan(
            setsToImport: [
                PlannedLoginSet(set: fresh, secret: "pw", embeddedKey: nil, replacesExisting: false),
            ],
            skipped: ["dup"], renamed: ["other (2)"])

        let result = vm.applyLoginSetImport(plan, keyStore: keyStore(in: dir))

        #expect(result.imported == 1)
        #expect(result.skipped == 1)
        #expect(result.renamed == 1)
        #expect(result.secretsImported == 1)
        #expect(vm.loginSets.map(\.name) == ["prod"])
        #expect(try secrets.password(for: fresh.id) == "pw")
    }

    @Test func cancelledPlanWritesAndReportsNothing() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.saveLoginSet(LoginSet(name: "existing", username: "u"), secret: "keep")

        let result = vm.applyLoginSetImport(
            LoginSetImportPlan(cancelled: true), keyStore: keyStore(in: dir))

        #expect(result == SessionListViewModel.LoginSetImportResult())
        #expect(vm.loginSets.map(\.name) == ["existing"])
        #expect(try secrets.password(for: vm.loginSets[0].id) == "keep")
    }

    /// A replace that brings its own secret overwrites the old one…
    @Test func replaceWithASecretOverwritesTheStoredOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = LoginSet(name: "prod", username: "old")
        vm.saveLoginSet(existing, secret: "old-pw")

        let plan = LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(id: existing.id, name: "prod", username: "new"),
                secret: "new-pw", embeddedKey: nil, replacesExisting: true),
        ], replaced: ["prod"])
        let result = vm.applyLoginSetImport(plan, keyStore: keyStore(in: dir))

        #expect(result.replaced == 1)
        #expect(result.secretsImported == 1)
        #expect(result.secretsRemoved == 0)
        #expect(vm.loginSets.map(\.username) == ["new"])
        #expect(try secrets.password(for: existing.id) == "new-pw")
    }

    /// …and a replace from a secret-free file must not leave the OLD secret
    /// bound to the set the user just replaced (M19 finding 1). Silently
    /// keeping it means the "replaced" set connects with a credential that is
    /// neither in the file nor visible anywhere.
    @Test func replaceWithoutASecretRemovesTheStaleOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = LoginSet(name: "prod", username: "old")
        vm.saveLoginSet(existing, secret: "old-pw")

        let plan = LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(id: existing.id, name: "prod", username: "new"),
                secret: nil, embeddedKey: nil, replacesExisting: true),
        ], replaced: ["prod"])
        let result = vm.applyLoginSetImport(plan, keyStore: keyStore(in: dir))

        #expect(result.secretsRemoved == 1)
        #expect(try secrets.password(for: existing.id) == nil)
    }

    /// The login-set twin of `aReplaceRemovesTheStaleSecretEvenWhenTheKeychain
    /// CannotBeRead` (M19 review, important 1): an unreadable Keychain is not
    /// evidence that there is no secret, so the delete runs regardless.
    @Test func aReplaceRemovesTheStaleSecretEvenWhenTheKeychainCannotBeRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-loginio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsReads: true)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))
        let existing = LoginSet(name: "prod", username: "old")
        vm.saveLoginSet(existing, secret: "old-pw")
        #expect(secrets.peek(existing.id) == "old-pw")

        let result = vm.applyLoginSetImport(LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(id: existing.id, name: "prod", username: "new"),
                secret: nil, embeddedKey: nil, replacesExisting: true),
        ], replaced: ["prod"]), keyStore: keyStore(in: dir))

        #expect(secrets.peek(existing.id) == nil)
        #expect(result.secretsRemoved == 0)
    }

    @Test func aRemovalThatFailsIsReported() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-loginio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = UnreliableSecretStore(failsDeletes: true)
        let vm = SessionListViewModel(
            store: SessionStore(directory: dir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: dir))
        let existing = LoginSet(name: "prod", username: "old")
        vm.saveLoginSet(existing, secret: "old-pw")

        let result = vm.applyLoginSetImport(LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(id: existing.id, name: "prod", username: "new"),
                secret: nil, embeddedKey: nil, replacesExisting: true),
        ], replaced: ["prod"]), keyStore: keyStore(in: dir))

        #expect(result.secretRemovalFailures == 1)
        #expect(result.secretsRemoved == 0)
        #expect(secrets.peek(existing.id) == "old-pw")
    }

    /// A FRESH import that carries no secret must not delete anything — only a
    /// replace touches an existing slot.
    @Test func aFreshImportWithoutASecretRemovesNothing() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unrelated = LoginSet(name: "other", username: "u")
        vm.saveLoginSet(unrelated, secret: "keep")

        let plan = LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(name: "prod", username: "deploy"), secret: nil,
                embeddedKey: nil, replacesExisting: false),
        ])
        let result = vm.applyLoginSetImport(plan, keyStore: keyStore(in: dir))

        #expect(result.secretsRemoved == 0)
        #expect(try secrets.password(for: unrelated.id) == "keep")
    }

    @Test func embeddedKeysAreMaterializedAndRepointTheSet() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceKeys = keyStore(in: dir.appendingPathComponent("source"))
        let key = try addManagedKey(to: sourceKeys, secrets: secrets, name: "prod")
        let embedded = try #require(try EmbeddedKeyPorter.embed(
            keyPath: path(of: key, in: sourceKeys), includePassphrase: false,
            store: sourceKeys, secrets: secrets))

        let targetKeys = keyStore(in: dir.appendingPathComponent("target"))
        let plan = LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(name: "prod", username: "deploy", authKind: .privateKey,
                              keyPath: "/nowhere/id_ed25519"),
                secret: nil, embeddedKey: embedded, replacesExisting: false),
        ])

        let result = vm.applyLoginSetImport(plan, keyStore: targetKeys)

        #expect(result.keysImported == 1)
        #expect(result.keyFailures.isEmpty)
        #expect(result.missingKeyPaths.isEmpty)
        let imported = try #require(vm.loginSets.first)
        #expect(imported.keyPath?.hasPrefix(
            targetKeys.keyDirectory.path(percentEncoded: false)) == true)
        #expect(FileManager.default.fileExists(atPath: imported.keyPath ?? ""))
        #expect(try targetKeys.all().count == 1)
    }

    /// A set whose key file is nowhere on this machine imports anyway — and
    /// says so, instead of failing at the next connect.
    @Test func aSetWhoseKeyIsMissingLocallyIsReported() throws {
        let (vm, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = LoginSetImportPlan(setsToImport: [
            PlannedLoginSet(
                set: LoginSet(name: "prod", username: "deploy", authKind: .privateKey,
                              keyPath: "/nowhere/id_ed25519"),
                secret: nil, embeddedKey: nil, replacesExisting: false),
        ])

        let result = vm.applyLoginSetImport(plan, keyStore: keyStore(in: dir))

        #expect(result.imported == 1)
        #expect(result.missingKeyPaths == ["prod"])
        #expect(vm.loginSets.first?.keyFileIsMissing == true)
    }

    @Test func keyFileIsMissingOnlySpeaksAboutKeySets() throws {
        let (_, _, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LoginSet(name: "pw", username: "u").keyFileIsMissing == false)
        #expect(LoginSet(name: "agent", username: "u", authKind: .agent).keyFileIsMissing == false)
        #expect(LoginSet(name: "empty", username: "u", authKind: .privateKey, keyPath: "")
            .keyFileIsMissing == false)
        #expect(LoginSet(name: "gone", username: "u", authKind: .privateKey,
                         keyPath: "/nowhere/id_ed25519").keyFileIsMissing)
    }
}
