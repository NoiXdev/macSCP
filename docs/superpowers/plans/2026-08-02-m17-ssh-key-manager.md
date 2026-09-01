# M17 — SSH Key Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A settings tab "SSH Keys" that generates ed25519/rsa/ecdsa keys, manages them (list/delete/copy+export public key), and makes ed25519 keys directly selectable in the form/login sets, with a central passphrase in the Keychain.

**Architecture:** on the Core side, `SSHKeyGenerator` (shells out to `ssh-keygen`) + `ManagedKeyStore` (secret-free JSON following the `KnownHostsStore` pattern; private files sit at 0600 in an app subdirectory). The reference stays the existing `keyPath` string — no model/loader rework; the passphrase is pulled automatically from the Keychain at connect time via a path lookup.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI+AppKit, macOS 15+, system `/usr/bin/ssh-keygen`, Keychain (`SecretStore`).

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **no new external dependency** (swift-crypto is already present; generation goes via the system `ssh-keygen`).
- Tests: Swift Testing, TDD red→green.
- **Never** log key bytes; passphrase **exclusively** in the Keychain under `key.id`; JSON store **secret-free**.
- Private files **0600**, directory **0700**, in the App Support folder — **no** writing to `~/.ssh`.
- `ssh-keygen` via **argument array** (no shell injection).
- `SSHPrivateKeyLoader` stays **unchanged** (still receives `keyPath` + `passphrase`); `ConnectionViewModel.connectSSH` unchanged.
- **Only ed25519** can be used to connect as a macSCP login; RSA/ECDSA can be generated + their public key exported, are **not** offered in the login picker, and are marked "not connectable" in the list.
- Code/comments/tests **in English**; UI strings EN/DE/FR/PL with **typographic characters** in non-English values, FR/PL AI-generated.
- Keychain tests gated via `MACSCP_KEYCHAIN=1`; ungated alternative via `InMemorySecretStore`.
- Conventional Commits (CI gate); footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Anchored facts (verified):** `SessionStore.defaultDirectory` = `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`. Stores are instantiated as `Store(directory: SessionStore.defaultDirectory)` (app wiring inline, e.g. `KnownHostsStore(directory: SessionStore.defaultDirectory)`). Real secret store: `KeychainSecretStore()` (`ContentView.swift:334`). Loader signature: `SSHPrivateKeyLoader.authentication(username: String, keyPath: String, passphrase: String?) throws -> SSHAuthenticationMethod`. `ssh-keygen` process template: `Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift:14`. Fingerprint helper: `HostKeyFingerprint.sha256(ofKeyBlobBase64:) -> String?`. `KnownHostsStore` store pattern: `Sources/macSCPCore/Sessions/KnownHostsStore.swift` (`init(directory:)`, `fileURL = directory.appendingPathComponent("known_hosts.json")`, `all()`/`persist()` atomic). `SecretStore`: `savePassword(_:for:)` / `password(for:)` / `deletePassword(for:)` (all `UUID`); test helper `InMemorySecretStore`.

---

## File Structure

- `Sources/macSCPCore/SSH/ManagedKey.swift` — **create**: `ManagedKey` + `KeyType`.
- `Sources/macSCPCore/SSH/SSHKeyGenerator.swift` — **create**: `ssh-keygen` wrapper.
- `Sources/macSCPCore/SSH/ManagedKeyStore.swift` — **create**: JSON store + `key(forPath:)` + `remove`.
- `Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift` — **create**: a pure resolution function (Task 3).
- `Sources/MacSCPApp/SSHKeysSettingsTab.swift` — **create**; `Sources/MacSCPApp/SettingsView.swift` — **modify** (sixth tab).
- `Sources/MacSCPApp/ContentView.swift` — **modify** (passphrase resolution at connect time).
- `Sources/MacSCPApp/ConnectionFormView.swift`, `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (key picker menu).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/SSHKeyGeneratorTests.swift`, `ManagedKeyStoreTests.swift`, `ManagedKeyPassphraseTests.swift` — **create**.

---

## Task 1: Core — `ManagedKey` + `KeyType` + `SSHKeyGenerator`

**Files:**
- Create: `Sources/macSCPCore/SSH/ManagedKey.swift`
- Create: `Sources/macSCPCore/SSH/SSHKeyGenerator.swift`
- Test: `Tests/macSCPCoreTests/SSHKeyGeneratorTests.swift`

**Interfaces:**
- Consumes: `SSHPrivateKeyLoader.authentication(username:keyPath:passphrase:)`, `HostKeyFingerprint.sha256(ofKeyBlobBase64:)`, Foundation `Process`.
- Produces:
  - `public enum KeyType: Equatable, Sendable, Codable { case ed25519; case rsa(bits: Int); case ecdsa; public var isConnectable: Bool }`
  - `public struct ManagedKey: Identifiable, Equatable, Sendable, Codable { id, name, comment, type, fingerprint, publicKeyOpenSSH, createdAt, hasPassphrase, fileName }`
  - `public enum SSHKeyGenerator { public static func generate(type: KeyType, comment: String, passphrase: String?, into dir: URL) throws -> GeneratedKey }` with `public struct GeneratedKey { public let privateKeyURL: URL; public let publicKeyOpenSSH: String; public let fingerprint: String }` and `public enum SSHKeyGenError: Error, Equatable { case keygenFailed(status: Int32); case publicKeyUnreadable; case toolMissing }`

- [ ] **Step 1: Write `ManagedKey` + `KeyType`**

`Sources/macSCPCore/SSH/ManagedKey.swift`:

```swift
import Foundation

/// The kind of SSH key (M17). Only ed25519 keys can be used to CONNECT in
/// macSCP today (the loader is ed25519-only); rsa/ecdsa keys can be
/// generated and their public key exported, but are not offered as a login.
public enum KeyType: Equatable, Sendable, Codable {
    case ed25519
    case rsa(bits: Int)
    case ecdsa

    /// True only for ed25519 — the one type `SSHPrivateKeyLoader` can load.
    public var isConnectable: Bool {
        if case .ed25519 = self { return true }
        return false
    }
}

/// A macSCP-managed SSH key (M17). Metadata only — the private key lives as a
/// 0600 file in the key directory; its passphrase (if any) lives in the
/// Keychain under `id`. This struct is persisted to `managed_keys.json` and
/// therefore contains NO secret material.
public struct ManagedKey: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var comment: String
    public var type: KeyType
    public var fingerprint: String        // "SHA256:…"
    public var publicKeyOpenSSH: String   // "ssh-ed25519 AAAA… comment"
    public var createdAt: Date
    public var hasPassphrase: Bool
    public var fileName: String           // private key file, relative to the key dir

    public init(
        id: UUID = UUID(), name: String, comment: String, type: KeyType,
        fingerprint: String, publicKeyOpenSSH: String, createdAt: Date,
        hasPassphrase: Bool, fileName: String
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.type = type
        self.fingerprint = fingerprint
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
        self.hasPassphrase = hasPassphrase
        self.fileName = fileName
    }
}
```

- [ ] **Step 2: Failing test for the generator**

`Tests/macSCPCoreTests/SSHKeyGeneratorTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHKeyGenerator")
struct SSHKeyGeneratorTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-keygen-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func generatesEd25519FileWith0600AndOpenSSHPublicKey() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try SSHKeyGenerator.generate(
            type: .ed25519, comment: "macscp-test", passphrase: nil, into: dir)

        #expect(FileManager.default.fileExists(atPath: key.privateKeyURL.path))
        let perms = try FileManager.default.attributesOfItem(
            atPath: key.privateKeyURL.path)[.posixPermissions] as! NSNumber
        #expect(perms.int16Value == 0o600)
        #expect(key.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
    }

    @Test func generatedEd25519KeyLoadsThroughTheLoader() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try SSHKeyGenerator.generate(
            type: .ed25519, comment: "roundtrip", passphrase: nil, into: dir)
        // Roundtrip: the loader must accept our generated file.
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: key.privateKeyURL.path, passphrase: nil)
    }

    @Test func passphraseProtectedKeyRequiresThePassphrase() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try SSHKeyGenerator.generate(
            type: .ed25519, comment: "enc", passphrase: "s3cr3t", into: dir)
        // Wrong/empty passphrase must fail to load.
        #expect(throws: (any Error).self) {
            _ = try SSHPrivateKeyLoader.authentication(
                username: "tim", keyPath: key.privateKeyURL.path, passphrase: nil)
        }
        // Correct passphrase loads.
        _ = try SSHPrivateKeyLoader.authentication(
            username: "tim", keyPath: key.privateKeyURL.path, passphrase: "s3cr3t")
    }

    @Test func generatesRSAAndECDSA() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rsa = try SSHKeyGenerator.generate(
            type: .rsa(bits: 2048), comment: "r", passphrase: nil, into: dir)
        #expect(rsa.publicKeyOpenSSH.hasPrefix("ssh-rsa "))
        let ecdsa = try SSHKeyGenerator.generate(
            type: .ecdsa, comment: "e", passphrase: nil, into: dir)
        #expect(ecdsa.publicKeyOpenSSH.hasPrefix("ecdsa-"))
    }
}
```

- [ ] **Step 3: Red test**

Run: `swift test --filter SSHKeyGeneratorTests`
Expected: FAIL — "cannot find 'SSHKeyGenerator'".

- [ ] **Step 4: Implement `SSHKeyGenerator`**

`Sources/macSCPCore/SSH/SSHKeyGenerator.swift`:

```swift
import Foundation

/// Generates SSH keypairs by shelling out to the system `ssh-keygen` (M17).
/// Files are written into an app-owned directory (never `~/.ssh`); the
/// private key is chmod'd 0600. The passphrase is passed via `-N` in the
/// argument array (never a shell string) — it is briefly visible in the
/// process's argv to the same user via `ps`, an accepted minor since
/// `ssh-keygen` offers no stdin passphrase path for generation.
public enum SSHKeyGenerator {
    public struct GeneratedKey: Equatable, Sendable {
        public let privateKeyURL: URL
        public let publicKeyOpenSSH: String
        public let fingerprint: String
    }

    public enum SSHKeyGenError: Error, Equatable {
        case keygenFailed(status: Int32)
        case publicKeyUnreadable
        case toolMissing
    }

    public static func generate(
        type: KeyType, comment: String, passphrase: String?, into dir: URL
    ) throws -> GeneratedKey {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let fileURL = dir.appendingPathComponent(UUID().uuidString)
        let tool = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw SSHKeyGenError.toolMissing
        }

        var args = ["-t", typeFlag(type)]
        if case .rsa(let bits) = type { args += ["-b", String(bits)] }
        args += [
            "-f", fileURL.path(percentEncoded: false),
            "-N", passphrase ?? "",
            "-C", comment,
            "-q",
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        // Never inherit an interactive prompt; keep output quiet.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHKeyGenError.keygenFailed(status: process.terminationStatus)
        }

        // Harden perms (ssh-keygen already writes 0600, but be explicit).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))

        let pubURL = dir.appendingPathComponent(fileURL.lastPathComponent + ".pub")
        guard let pubContents = try? String(contentsOf: pubURL, encoding: .utf8) else {
            throw SSHKeyGenError.publicKeyUnreadable
        }
        let publicKeyOpenSSH = pubContents.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = fingerprint(fromOpenSSHPublicKey: publicKeyOpenSSH)
            ?? SSHKeyGenerator.fingerprintViaTool(pubURL: pubURL)
            ?? ""

        return GeneratedKey(
            privateKeyURL: fileURL, publicKeyOpenSSH: publicKeyOpenSSH, fingerprint: fingerprint)
    }

    private static func typeFlag(_ type: KeyType) -> String {
        switch type {
        case .ed25519: return "ed25519"
        case .rsa: return "rsa"
        case .ecdsa: return "ecdsa"
        }
    }

    /// "ssh-ed25519 <base64> comment" → SHA256 fingerprint of the base64 blob.
    private static func fingerprint(fromOpenSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return HostKeyFingerprint.sha256(ofKeyBlobBase64: String(parts[1]))
    }

    /// Fallback: `ssh-keygen -lf <pub>` prints "<bits> SHA256:… comment (TYPE)".
    private static func fingerprintViaTool(pubURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-lf", pubURL.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return out.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init)
    }
}
```

- [ ] **Step 5: Green test**

Run: `swift test --filter SSHKeyGeneratorTests`
Expected: PASS — all five tests green.

- [ ] **Step 6: Full suite + 0 warnings**

Run: `swift build && swift test`
Expected: build 0 warnings; all tests green.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/SSH/ManagedKey.swift Sources/macSCPCore/SSH/SSHKeyGenerator.swift Tests/macSCPCoreTests/SSHKeyGeneratorTests.swift
git commit -m "feat: generate SSH keys via ssh-keygen into an app directory

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Core — `ManagedKeyStore`

**Files:**
- Create: `Sources/macSCPCore/SSH/ManagedKeyStore.swift`
- Test: `Tests/macSCPCoreTests/ManagedKeyStoreTests.swift`

**Interfaces:**
- Consumes: `ManagedKey` (Task 1), `any SecretStore` (`deletePassword(for:)`), `InMemorySecretStore` (test).
- Produces:
  - `public struct ManagedKeyStore: Sendable { public init(directory: URL); public var keyDirectory: URL; public func all() throws -> [ManagedKey]; public func add(_ key: ManagedKey) throws; public func remove(id: UUID, secrets: any SecretStore) throws; public func key(forPath path: String) throws -> ManagedKey? }`

- [ ] **Step 1: Failing test**

`Tests/macSCPCoreTests/ManagedKeyStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ManagedKeyStore")
struct ManagedKeyStoreTests {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-keystore-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleKey(fileName: String = "k1") -> ManagedKey {
        ManagedKey(
            name: "laptop", comment: "c", type: .ed25519, fingerprint: "SHA256:abc",
            publicKeyOpenSSH: "ssh-ed25519 AAAA c", createdAt: Date(timeIntervalSince1970: 0),
            hasPassphrase: true, fileName: fileName)
    }

    @Test func addAllRoundtripsAndJSONHasNoSecret() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        let key = sampleKey()
        try store.add(key)
        #expect(try store.all() == [key])

        let json = try String(
            contentsOf: dir.appendingPathComponent("managed_keys.json"), encoding: .utf8)
        #expect(!json.lowercased().contains("passphrase"))
        #expect(!json.contains("BEGIN OPENSSH PRIVATE KEY"))
    }

    @Test func keyForPathMatchesByFileNameInKeyDir() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        let key = sampleKey(fileName: "abc123")
        try store.add(key)

        let managedPath = store.keyDirectory.appendingPathComponent("abc123").path
        #expect(try store.key(forPath: managedPath) == key)
        #expect(try store.key(forPath: "/Users/tim/.ssh/id_ed25519") == nil)
    }

    @Test func removeDeletesFilesAndKeychainSlot() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManagedKeyStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.keyDirectory, withIntermediateDirectories: true)
        let priv = store.keyDirectory.appendingPathComponent("abc123")
        let pub = store.keyDirectory.appendingPathComponent("abc123.pub")
        try Data("priv".utf8).write(to: priv)
        try Data("pub".utf8).write(to: pub)

        let key = sampleKey(fileName: "abc123")
        try store.add(key)
        let secrets = InMemorySecretStore()
        try secrets.savePassword("s3cr3t", for: key.id)

        try store.remove(id: key.id, secrets: secrets)

        #expect(try store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: priv.path))
        #expect(!FileManager.default.fileExists(atPath: pub.path))
        #expect(try secrets.password(for: key.id) == nil)
    }
}
```

- [ ] **Step 2: Red test**

Run: `swift test --filter ManagedKeyStoreTests`
Expected: FAIL — "cannot find 'ManagedKeyStore'".

- [ ] **Step 3: Implement `ManagedKeyStore`**

`Sources/macSCPCore/SSH/ManagedKeyStore.swift`:

```swift
import Foundation

/// JSON persistence for managed SSH keys (`managed_keys.json`), following the
/// `KnownHostsStore` pattern (stateless, atomic writes). Secret-free: the
/// private key file lives under `keyDirectory` (0600), the passphrase in the
/// Keychain under `ManagedKey.id` — never here.
public struct ManagedKeyStore: Sendable {
    private let directory: URL
    private let fileURL: URL
    /// Where the private/public key files live (0700 subdirectory).
    public let keyDirectory: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("managed_keys.json")
        self.keyDirectory = directory.appendingPathComponent("keys", isDirectory: true)
    }

    public func all() throws -> [ManagedKey] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ManagedKey].self, from: data)
    }

    public func add(_ key: ManagedKey) throws {
        var keys = try all()
        keys.removeAll { $0.id == key.id }
        keys.append(key)
        try persist(keys)
    }

    /// Removes metadata AND the private/public key files AND the Keychain
    /// passphrase slot under `id`. Missing files/slot are ignored (idempotent).
    public func remove(id: UUID, secrets: any SecretStore) throws {
        let keys = try all()
        if let key = keys.first(where: { $0.id == id }) {
            let priv = keyDirectory.appendingPathComponent(key.fileName)
            try? FileManager.default.removeItem(at: priv)
            try? FileManager.default.removeItem(
                at: keyDirectory.appendingPathComponent(key.fileName + ".pub"))
        }
        try? secrets.deletePassword(for: id)
        try persist(keys.filter { $0.id != id })
    }

    /// The managed key whose private file is at `path`, or nil. Matches by the
    /// resolved absolute path of `keyDirectory/fileName` (tilde-expanded).
    public func key(forPath path: String) throws -> ManagedKey? {
        let target = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.path
        return try all().first {
            keyDirectory.appendingPathComponent($0.fileName).standardizedFileURL.path == target
        }
    }

    private func persist(_ keys: [ManagedKey]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
```

Note: set the matching `JSONDecoder().dateDecodingStrategy = .iso8601` in `all()` (symmetry with the encoder) — add that to the decoder before the `decode`.

- [ ] **Step 4: Green test**

Run: `swift test --filter ManagedKeyStoreTests`
Expected: PASS.

- [ ] **Step 5: Full suite + 0 warnings**

Run: `swift build && swift test`
Expected: build 0 warnings; all tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/SSH/ManagedKeyStore.swift Tests/macSCPCoreTests/ManagedKeyStoreTests.swift
git commit -m "feat: persist managed SSH key metadata in a secret-free store

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Core+App — Passphrase Resolution at Connect Time

**Files:**
- Create: `Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (the connect fill path, where `form.password` is set)
- Test: `Tests/macSCPCoreTests/ManagedKeyPassphraseTests.swift`

**Interfaces:**
- Consumes: `ManagedKeyStore.key(forPath:)` (Task 2), `any SecretStore`.
- Produces: `public enum ManagedKeyPassphrase { public static func resolve(keyPath: String, typed: String, store: ManagedKeyStore, secrets: any SecretStore) -> String }` — returns the effective passphrase: if `typed` is non-empty it wins; otherwise, if `keyPath` is a managed key with `hasPassphrase`, the Keychain passphrase; otherwise `typed` (empty).

- [ ] **Step 1: Failing test**

`Tests/macSCPCoreTests/ManagedKeyPassphraseTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ManagedKeyPassphrase")
struct ManagedKeyPassphraseTests {
    private func tempStore() -> ManagedKeyStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-pp-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ManagedKeyStore(directory: dir)
    }

    @Test func managedKeyWithStoredPassphraseIsResolved() throws {
        let store = tempStore()
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "kf")
        try store.add(key)
        let secrets = InMemorySecretStore()
        try secrets.savePassword("stored-pp", for: key.id)
        let path = store.keyDirectory.appendingPathComponent("kf").path

        let effective = ManagedKeyPassphrase.resolve(
            keyPath: path, typed: "", store: store, secrets: secrets)
        #expect(effective == "stored-pp")
    }

    @Test func typedPassphraseWins() throws {
        let store = tempStore()
        let key = ManagedKey(
            name: "k", comment: "", type: .ed25519, fingerprint: "SHA256:x",
            publicKeyOpenSSH: "ssh-ed25519 AAAA", createdAt: Date(),
            hasPassphrase: true, fileName: "kf")
        try store.add(key)
        let secrets = InMemorySecretStore()
        try secrets.savePassword("stored-pp", for: key.id)
        let path = store.keyDirectory.appendingPathComponent("kf").path

        #expect(ManagedKeyPassphrase.resolve(
            keyPath: path, typed: "typed", store: store, secrets: secrets) == "typed")
    }

    @Test func foreignPathFallsBackToTyped() throws {
        let store = tempStore()
        let secrets = InMemorySecretStore()
        #expect(ManagedKeyPassphrase.resolve(
            keyPath: "/Users/tim/.ssh/id_ed25519", typed: "", store: store, secrets: secrets) == "")
    }
}
```

- [ ] **Step 2: Red test**

Run: `swift test --filter ManagedKeyPassphraseTests`
Expected: FAIL — "cannot find 'ManagedKeyPassphrase'".

- [ ] **Step 3: Implement `ManagedKeyPassphrase`**

`Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift`:

```swift
import Foundation

/// Resolves the effective key passphrase at connect time (M17). A typed
/// passphrase always wins. Otherwise, if `keyPath` points at a managed key
/// that has a stored passphrase, it is read from the Keychain under the key's
/// id. Otherwise the (empty) typed value is returned. Keeps
/// `SSHPrivateKeyLoader` and the connect view model unchanged — the caller
/// just supplies a better `passphrase` than the empty form field.
public enum ManagedKeyPassphrase {
    public static func resolve(
        keyPath: String, typed: String, store: ManagedKeyStore, secrets: any SecretStore
    ) -> String {
        if !typed.isEmpty { return typed }
        guard let key = try? store.key(forPath: keyPath), key.hasPassphrase else { return typed }
        return (try? secrets.password(for: key.id)) ?? typed
    }
}
```

- [ ] **Step 4: Green test**

Run: `swift test --filter ManagedKeyPassphraseTests`
Expected: PASS.

- [ ] **Step 5: App wiring at connect time**

In `Sources/MacSCPApp/ContentView.swift`, in the saved-session connect path (SSH branch, directly **after** `form.password` is filled from `resolved.secret`/`password(for: stored)`, and likewise in the form connect handler, directly **before** `form.connect()`), pull in the effective passphrase for the privateKey case:

```swift
// M17: if this key is a managed key with a stored passphrase and none was
// typed, resolve it from the Keychain so the user need not re-enter it.
if form.authChoice == .privateKey {
    form.password = ManagedKeyPassphrase.resolve(
        keyPath: form.keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
        typed: form.password,
        store: ManagedKeyStore(directory: SessionStore.defaultDirectory),
        secrets: sessionListViewModel.secrets)
}
```

Check the real source of the `SecretStore`: `sessionListViewModel.secrets` or `KeychainSecretStore()` (as wired at `ContentView.swift:334`) — use the existing store, don't create a new one if one is already in scope. Both connect entry points (saved session + form) must get the line, the same way both already set `form.password` today.

- [ ] **Step 6: Build + behavior check**

Run: `swift build`
Expected: 0 warnings. Behavior by code reading: a managed key with a stored passphrase connects without re-entry; an external keyPath or a typed passphrase behaves unchanged.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift Tests/macSCPCoreTests/ManagedKeyPassphraseTests.swift Sources/MacSCPApp/ContentView.swift
git commit -m "feat: auto-resolve a managed key's passphrase at connect

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: App — Settings Tab "SSH Keys"

**Files:**
- Create: `Sources/MacSCPApp/SSHKeysSettingsTab.swift`
- Modify: `Sources/MacSCPApp/SettingsView.swift` (sixth `.tabItem`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `ManagedKeyStore` (Task 2), `SSHKeyGenerator` (Task 1), `ManagedKey`/`KeyType`, `KeychainSecretStore`, `SessionStore.defaultDirectory`, `L10n`, `DesignTokens`.
- Produces: `struct SSHKeysSettingsTab: View`.

A pure SwiftUI view — build-verified (no unit test; the core logic is tested in Task 1/2).

- [ ] **Step 1: `SSHKeysSettingsTab` with list + actions**

A new `SSHKeysSettingsTab` following the pattern of `OpenWithSettingsTab` (`SettingsView.swift:382`). A `@State private var keys: [ManagedKey] = []`, loaded via `ManagedKeyStore(directory: SessionStore.defaultDirectory).all()` in `.onAppear` and reloaded after every mutation. Elements:
- **List** (`List`/`ScrollView`): one row per key with `name`, a type badge (`ED25519`/`RSA`/`ECDSA` — label derived from `KeyType`), `fingerprint` (shortened), `comment`, `createdAt` (formatted), a lock `Image(systemName: "lock")` when `hasPassphrase`. If `!key.type.isConnectable`, a subdued `Text(L10n.string("keys.notConnectable", "Not usable as a macSCP login"))`.
- A **Generate…** button → opens a sheet (`GenerateKeySheet`, its own small `struct` in the same file): fields `name`, `comment`, a type `Picker` (`.ed25519`/`.rsa`/`.ecdsa`), for RSA a key-size `Picker` (2048/3072/4096, default 3072), `passphrase` (`SecureField`) + a confirmation `SecureField` (must match). "Generate" calls `SSHKeyGenerator.generate(...)` into `keyDirectory`; for a non-empty passphrase, `KeychainSecretStore().savePassword(pp, for: newID)`; builds a `ManagedKey` (with `fileName = generated.privateKeyURL.lastPathComponent`, `id = newID`, `hasPassphrase`, `fingerprint`, `publicKeyOpenSSH`, `createdAt: Date()`) and `store.add(key)`.
- **Context menu per row** + buttons: **Copy public key** (`NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.publicKeyOpenSSH, forType: .string)`), **Export public key…** (`fileExporter`/`NSSavePanel` writes `key.publicKeyOpenSSH`), **Delete** (confirmation dialog → `store.remove(id: key.id, secrets: KeychainSecretStore())` → reload the list).

**Usage warning on delete:** before deleting, a best-effort count of the sessions/login sets whose `keyPath` points at this key's file (analogous to the `usageCount` display on login sets). If the count is > 0, mention it in the confirmation dialog. Check the count source (SessionStore/LoginSetStore access) in the app scope; if it isn't conveniently reachable here, show the generic warning text without a number (not a blocker).

Skeleton:

```swift
import SwiftUI
import macSCPCore

struct SSHKeysSettingsTab: View {
    @State private var keys: [ManagedKey] = []
    @State private var showGenerate = false
    private let store = ManagedKeyStore(directory: SessionStore.defaultDirectory)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // header + List(keys) { row($0) } + toolbar buttons …
        }
        .padding(20)
        .onAppear { reload() }
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet(store: store) { reload() }
        }
    }

    private func reload() { keys = (try? store.all()) ?? [] }
    // row(_:), copyPublicKey(_:), exportPublicKey(_:), delete(_:) …
}
```

- [ ] **Step 2: Hook the sixth tab into `SettingsView`**

In `Sources/MacSCPApp/SettingsView.swift`, in the `TabView` after the `ShortcutsSettingsTab` block:

```swift
            SSHKeysSettingsTab()
                .tabItem { Label(L10n.string("settings.tab.sshKeys", "SSH Keys"), systemImage: "key") }
```

Check whether the fixed `.frame(width: 460, height: 460)` is enough for the list + actions; otherwise put the list in a fixed-height `ScrollView` (do NOT change the window size without good reason — the other tabs share it).

- [ ] **Step 3: L10n (EN/DE/FR/PL)**

New keys across all four catalogs (tab label, column titles/labels, "not connectable", generate-dialog fields, type/key-size options, copy/export/delete actions, delete/usage warning). Example core keys (EN shown; DE/FR/PL analogous, typographic characters, no ASCII quote in non-English values):

```
"settings.tab.sshKeys" = "SSH Keys";
"keys.generate" = "Generate…";
"keys.generate.name" = "Name";
"keys.generate.comment" = "Comment";
"keys.generate.type" = "Type";
"keys.generate.bits" = "Key size";
"keys.generate.passphrase" = "Passphrase (optional)";
"keys.generate.passphrase.confirm" = "Confirm passphrase";
"keys.notConnectable" = "Not usable as a macSCP login (public key export only)";
"keys.copyPublic" = "Copy public key";
"keys.exportPublic" = "Export public key…";
"keys.delete" = "Delete";
"keys.delete.confirm %d" = "Delete this key? %d saved connection(s) reference it.";
"keys.empty" = "No keys yet. Generate one to get started.";
```

- [ ] **Step 4: Build + behavior check**

Run: `swift build`
Expected: 0 warnings. Check catalog parity (`swift test --filter Localizable`). Behavior by code reading: generate → the list shows the new key; copy puts the OpenSSH line on the clipboard; delete removes the key + file + Keychain entry.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/SSHKeysSettingsTab.swift Sources/MacSCPApp/SettingsView.swift Sources/MacSCPApp/Resources
git commit -m "feat: add an SSH Keys settings tab to generate and manage keys

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: App — Key Picker in the Form + Login Set Editor

**Files:**
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (keyPath block ~505–521; jump-keyPath analogous, optional)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (keyPath block ~401–412)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `ManagedKeyStore.all()` filtered to `type.isConnectable`, `ManagedKey.name`/`fingerprint`/`fileName`, `ManagedKeyStore.keyDirectory`, `SessionStore.defaultDirectory`.
- Produces: nothing new (fills `viewModel.keyPath` / the editor's `keyPath` state).

Pure SwiftUI/App — build-verified.

- [ ] **Step 1: "Managed key" menu in the form**

In the keyPath `FormRow` of `ConnectionFormView.swift` (next to the `TextField` + "…" `Button`), additively insert a `Menu` that lists the connectable keys and fills `viewModel.keyPath` with the app file path:

```swift
let connectableKeys = (try? ManagedKeyStore(
    directory: SessionStore.defaultDirectory).all())?.filter { $0.type.isConnectable } ?? []
if !connectableKeys.isEmpty {
    Menu(L10n.string("keys.picker.managed", "Managed key")) {
        ForEach(connectableKeys) { key in
            Button("\(key.name) — \(shortFingerprint(key.fingerprint))") {
                viewModel.keyPath = ManagedKeyStore(directory: SessionStore.defaultDirectory)
                    .keyDirectory.appendingPathComponent(key.fileName).path(percentEncoded: false)
            }
        }
    }
    .fixedSize()
}
```

Plus a "Manage keys…" button that opens the settings window/tab (analogous to the existing "Manage logins…" pattern — take over the real opening mechanism from the code). `shortFingerprint` = the first ~12 characters after `SHA256:` (a small private helper).

- [ ] **Step 2: Same menu in the login set editor**

In `LoginSetsSheet.swift`, in the keyPath block (privateKey branch, ~401–412), additively insert the same menu, which fills the editor's `keyPath` state.

- [ ] **Step 3: L10n**

```
"keys.picker.managed" = "Managed key";
"keys.picker.manage" = "Manage keys…";
```
into all four catalogs (DE/FR/PL typographic).

- [ ] **Step 4: Build + behavior check**

Run: `swift build`
Expected: 0 warnings. Behavior: only ed25519 keys appear in the menu; selecting one fills `keyPath`; free text + "…" stay usable. If no connectable keys exist, the menu does not appear (no empty menu).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/ConnectionFormView.swift Sources/MacSCPApp/LoginSetsSheet.swift Sources/MacSCPApp/Resources
git commit -m "feat: pick a managed SSH key in the connection form and login sets

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Closeout — Suite, Review, Push/Deploy

**Files:** none (verification + closeout).

- [ ] **Step 1: Full suite (incl. Keychain paths)**

Run: `MACSCP_KEYCHAIN=1 swift test`
Expected: the entire suite green, including the new `SSHKeyGeneratorTests`/`ManagedKeyStoreTests`/`ManagedKeyPassphraseTests`.

- [ ] **Step 2: Ungated suite + 0 warnings**

Run: `swift build && swift test`
Expected: build 0 warnings; ungated suite green.

- [ ] **Step 3: Runtime idle-CPU smoke test**

Start the dev build, open the new settings tab, check idle CPU (lesson M11n) — a static list, no sustained CPU/layout storm.

- [ ] **Step 4: Whole-milestone review**

An Opus whole-branch review over the entire M17 diff (`git merge-base develop HEAD`..HEAD, base = M16 HEAD `8bae812`), focused on the Global Constraints (passphrase Keychain-only, JSON secret-free, 0600/0700, no `~/.ssh` writes, `ssh-keygen` argument array, `SSHPrivateKeyLoader` unchanged, only ed25519 connectable).

- [ ] **Step 5: Push + CI + dev build (on maintainer instruction)**

After a green review — on maintainer instruction: push to `develop`, `gh run watch`, dev build v1.7.0-dev to `~/Desktop/macSCP-dev.app`. No release/tag.

---

## Self-Review

**1. Spec coverage:**
- Spec §Core `ManagedKey`/`KeyType` + `SSHKeyGenerator` → Task 1. ✅
- Spec §Core `ManagedKeyStore` (all/add/remove-with-cleanup/key(forPath:)) → Task 2. ✅
- Spec §Core passphrase resolution + `SSHPrivateKeyLoader` unchanged → Task 3. ✅
- Spec §App settings tab (list/generate/copy/export/delete/context menu/usage warning) → Task 4. ✅
- Spec §App form/login-set picker (ed25519 only, fills keyPath, "manage" button) → Task 5. ✅
- Spec §Tests (store CRUD, generator against real ssh-keygen incl. roundtrip, passphrase resolution) → Task 1/2/3. ✅
- Spec §Tests app build + idle CPU → Task 4/6. ✅
- Spec §Security/invariants → Global Constraints + Task 6 review. ✅
- Spec §L10n → Task 4/5. ✅

**2. Placeholder scan:** Open spots with a clear "adopt the real value" instruction: the exact `SecretStore` source + the second connect entry point in Task 3, the usage-count source + the settings-opening mechanism in Task 4/5. No "TBD/TODO".

**3. Type consistency:** `SSHKeyGenerator.generate(type:comment:passphrase:into:) -> GeneratedKey{privateKeyURL,publicKeyOpenSSH,fingerprint}`; `ManagedKey(id,name,comment,type,fingerprint,publicKeyOpenSSH,createdAt,hasPassphrase,fileName)`; `KeyType.isConnectable`; `ManagedKeyStore(directory:)` / `.keyDirectory` / `all()` / `add(_:)` / `remove(id:secrets:)` / `key(forPath:)`; `ManagedKeyPassphrase.resolve(keyPath:typed:store:secrets:)` — consistent across all tasks. `SessionStore.defaultDirectory` used uniformly as the store directory.
