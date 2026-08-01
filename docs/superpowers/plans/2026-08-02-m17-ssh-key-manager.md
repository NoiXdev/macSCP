# M17 — SSH Key Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Settings-Tab „SSH-Schlüssel", der ed25519/rsa/ecdsa-Schlüssel erzeugt, verwaltet (Liste/löschen/Public-Key kopieren+exportieren) und ed25519-Keys direkt in Formular/Login-Sets wählbar macht, mit zentraler Passphrase im Keychain.

**Architecture:** Core-seitig `SSHKeyGenerator` (shellt `ssh-keygen`) + `ManagedKeyStore` (secret-freies JSON nach dem `KnownHostsStore`-Muster; private Dateien liegen 0600 in einem App-Unterordner). Die Referenz bleibt der bestehende `keyPath`-String — kein Modell-/Loader-Umbau; die Passphrase wird beim Connect über einen Pfad-Lookup automatisch aus dem Keychain gezogen.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI+AppKit, macOS 15+, System-`/usr/bin/ssh-keygen`, Keychain (`SecretStore`).

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **keine neue externe Dependency** (swift-crypto ist vorhanden; Erzeugung via System-`ssh-keygen`).
- Tests: Swift Testing, TDD rot→grün.
- Key-Bytes **nie** loggen; Passphrase **ausschließlich** Keychain unter `key.id`; JSON-Store **secret-frei**.
- Privatdateien **0600**, Verzeichnis **0700**, im App-Support-Ordner — **kein** Schreiben nach `~/.ssh`.
- `ssh-keygen` per **Argument-Array** (keine Shell-Injection).
- `SSHPrivateKeyLoader` bleibt **unverändert** (bekommt weiter `keyPath` + `passphrase`); `ConnectionViewModel.connectSSH` unverändert.
- **Nur ed25519** ist als macSCP-Login verbindbar; RSA/ECDSA sind erzeugbar + pub-exportierbar, im Login-Picker **nicht** angeboten und in der Liste als „nicht verbindbar" markiert.
- Code/Kommentare/Tests **Englisch**; UI-Strings EN/DE/FR/PL mit **typografischen Zeichen** in nicht-englischen Werten, FR/PL KI-generiert.
- gated Keychain-Tests via `MACSCP_KEYCHAIN=1`; ungated Alternative via `InMemorySecretStore`.
- Conventional Commits (CI-Gate); Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verankerte Fakten (verifiziert):** `SessionStore.defaultDirectory` = `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`. Stores werden als `Store(directory: SessionStore.defaultDirectory)` instanziiert (App-Wiring inline, z. B. `KnownHostsStore(directory: SessionStore.defaultDirectory)`). Realer Secret-Store: `KeychainSecretStore()` (`ContentView.swift:334`). Loader-Signatur: `SSHPrivateKeyLoader.authentication(username: String, keyPath: String, passphrase: String?) throws -> SSHAuthenticationMethod`. `ssh-keygen`-Process-Vorlage: `Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift:14`. Fingerprint-Helfer: `HostKeyFingerprint.sha256(ofKeyBlobBase64:) -> String?`. `KnownHostsStore`-Store-Muster: `Sources/macSCPCore/Sessions/KnownHostsStore.swift` (`init(directory:)`, `fileURL = directory.appendingPathComponent("known_hosts.json")`, `all()`/`persist()` atomar). `SecretStore`: `savePassword(_:for:)` / `password(for:)` / `deletePassword(for:)` (alle `UUID`); Test-Helfer `InMemorySecretStore`.

---

## File Structure

- `Sources/macSCPCore/SSH/ManagedKey.swift` — **create**: `ManagedKey` + `KeyType`.
- `Sources/macSCPCore/SSH/SSHKeyGenerator.swift` — **create**: `ssh-keygen`-Wrapper.
- `Sources/macSCPCore/SSH/ManagedKeyStore.swift` — **create**: JSON-Store + `key(forPath:)` + `remove`.
- `Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift` — **create**: reine Auflöse-Funktion (Task 3).
- `Sources/MacSCPApp/SSHKeysSettingsTab.swift` — **create**; `Sources/MacSCPApp/SettingsView.swift` — **modify** (sechster Tab).
- `Sources/MacSCPApp/ContentView.swift` — **modify** (Passphrase-Auflösung am Connect).
- `Sources/MacSCPApp/ConnectionFormView.swift`, `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (Key-Picker-Menü).
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
  - `public enum SSHKeyGenerator { public static func generate(type: KeyType, comment: String, passphrase: String?, into dir: URL) throws -> GeneratedKey }` mit `public struct GeneratedKey { public let privateKeyURL: URL; public let publicKeyOpenSSH: String; public let fingerprint: String }` und `public enum SSHKeyGenError: Error, Equatable { case keygenFailed(status: Int32); case publicKeyUnreadable; case toolMissing }`

- [ ] **Step 1: `ManagedKey` + `KeyType` schreiben**

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

- [ ] **Step 2: Failing-Test für den Generator**

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

- [ ] **Step 3: Test rot**

Run: `swift test --filter SSHKeyGeneratorTests`
Expected: FAIL — „cannot find 'SSHKeyGenerator'".

- [ ] **Step 4: `SSHKeyGenerator` implementieren**

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

- [ ] **Step 5: Test grün**

Run: `swift test --filter SSHKeyGeneratorTests`
Expected: PASS — alle fünf Tests grün.

- [ ] **Step 6: Volle Suite + 0 Warnungen**

Run: `swift build && swift test`
Expected: Build 0 Warnungen; alle Tests grün.

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
- Consumes: `ManagedKey` (Task 1), `any SecretStore` (`deletePassword(for:)`), `InMemorySecretStore` (Test).
- Produces:
  - `public struct ManagedKeyStore: Sendable { public init(directory: URL); public var keyDirectory: URL; public func all() throws -> [ManagedKey]; public func add(_ key: ManagedKey) throws; public func remove(id: UUID, secrets: any SecretStore) throws; public func key(forPath path: String) throws -> ManagedKey? }`

- [ ] **Step 1: Failing-Test**

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

- [ ] **Step 2: Test rot**

Run: `swift test --filter ManagedKeyStoreTests`
Expected: FAIL — „cannot find 'ManagedKeyStore'".

- [ ] **Step 3: `ManagedKeyStore` implementieren**

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

Hinweis: den passenden `JSONDecoder().dateDecodingStrategy = .iso8601` in `all()` setzen (Symmetrie zum Encoder) — ergänze das im Decoder vor dem `decode`.

- [ ] **Step 4: Test grün**

Run: `swift test --filter ManagedKeyStoreTests`
Expected: PASS.

- [ ] **Step 5: Volle Suite + 0 Warnungen**

Run: `swift build && swift test`
Expected: Build 0 Warnungen; alle Tests grün.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/SSH/ManagedKeyStore.swift Tests/macSCPCoreTests/ManagedKeyStoreTests.swift
git commit -m "feat: persist managed SSH key metadata in a secret-free store

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Core+App — Passphrase-Auflösung beim Connect

**Files:**
- Create: `Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (Connect-Füll-Pfad, wo `form.password` gesetzt wird)
- Test: `Tests/macSCPCoreTests/ManagedKeyPassphraseTests.swift`

**Interfaces:**
- Consumes: `ManagedKeyStore.key(forPath:)` (Task 2), `any SecretStore`.
- Produces: `public enum ManagedKeyPassphrase { public static func resolve(keyPath: String, typed: String, store: ManagedKeyStore, secrets: any SecretStore) -> String }` — gibt die effektive Passphrase zurück: ist `typed` nicht-leer, gewinnt sie; sonst, wenn `keyPath` ein verwalteter Key mit `hasPassphrase` ist, die Keychain-Passphrase; sonst `typed` (leer).

- [ ] **Step 1: Failing-Test**

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

- [ ] **Step 2: Test rot**

Run: `swift test --filter ManagedKeyPassphraseTests`
Expected: FAIL — „cannot find 'ManagedKeyPassphrase'".

- [ ] **Step 3: `ManagedKeyPassphrase` implementieren**

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

- [ ] **Step 4: Test grün**

Run: `swift test --filter ManagedKeyPassphraseTests`
Expected: PASS.

- [ ] **Step 5: App-Verkabelung am Connect**

In `Sources/MacSCPApp/ContentView.swift`, im gespeicherte-Session-Connect-Pfad (SSH-Zweig, direkt **nachdem** `form.password` aus `resolved.secret`/`password(for: stored)` gefüllt wurde, und ebenso im Formular-Connect-Handler, direkt **vor** `form.connect()`), die effektive Passphrase für den privateKey-Fall nachziehen:

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

Die reale Quelle des `SecretStore` prüfen: `sessionListViewModel.secrets` bzw. `KeychainSecretStore()` (wie an `ContentView.swift:334` verdrahtet) — den vorhandenen Store verwenden, keinen neuen anlegen, falls schon einer im Scope ist. Beide Connect-Einstiege (gespeicherte Session + Formular) müssen die Zeile bekommen, analog dazu, wie beide heute `form.password` setzen.

- [ ] **Step 6: Build + Behaviour-Check**

Run: `swift build`
Expected: 0 Warnungen. Verhalten per Codelesen: ein verwalteter Key mit gespeicherter Passphrase verbindet ohne erneute Eingabe; ein externer keyPath oder eine getippte Passphrase verhält sich unverändert.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/SSH/ManagedKeyPassphrase.swift Tests/macSCPCoreTests/ManagedKeyPassphraseTests.swift Sources/MacSCPApp/ContentView.swift
git commit -m "feat: auto-resolve a managed key's passphrase at connect

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: App — Settings-Tab „SSH-Schlüssel"

**Files:**
- Create: `Sources/MacSCPApp/SSHKeysSettingsTab.swift`
- Modify: `Sources/MacSCPApp/SettingsView.swift` (sechster `.tabItem`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `ManagedKeyStore` (Task 2), `SSHKeyGenerator` (Task 1), `ManagedKey`/`KeyType`, `KeychainSecretStore`, `SessionStore.defaultDirectory`, `L10n`, `DesignTokens`.
- Produces: `struct SSHKeysSettingsTab: View`.

Reine SwiftUI-View — build-verifiziert (kein Unit-Test; die Kernlogik ist in Task 1/2 getestet).

- [ ] **Step 1: `SSHKeysSettingsTab` mit Liste + Aktionen**

Neuer `SSHKeysSettingsTab` nach dem Muster von `OpenWithSettingsTab` (`SettingsView.swift:382`). Ein `@State private var keys: [ManagedKey] = []`, geladen via `ManagedKeyStore(directory: SessionStore.defaultDirectory).all()` in `.onAppear` und nach jeder Mutation neu geladen. Elemente:
- **Liste** (`List`/`ScrollView`): pro Key eine Zeile mit `name`, Typ-Badge (`ED25519`/`RSA`/`ECDSA` — Label aus `KeyType`), `fingerprint` (gekürzt), `comment`, `createdAt` (formatiert), Schloss-`Image(systemName: "lock")` bei `hasPassphrase`. Ist `!key.type.isConnectable`, ein dezenter `Text(L10n.string("keys.notConnectable", "Not usable as a macSCP login"))`.
- **Erzeugen…**-Button → öffnet ein Sheet (`GenerateKeySheet`, eigener kleiner `struct` in derselben Datei): Felder `name`, `comment`, Typ-`Picker` (`.ed25519`/`.rsa`/`.ecdsa`), bei RSA ein Bitlängen-`Picker` (2048/3072/4096, Default 3072), `passphrase` (`SecureField`) + Bestätigungs-`SecureField` (müssen übereinstimmen). „Erzeugen" ruft `SSHKeyGenerator.generate(...)` in den `keyDirectory`; bei nicht-leerer Passphrase `KeychainSecretStore().savePassword(pp, for: newID)`; baut `ManagedKey` (mit `fileName = generated.privateKeyURL.lastPathComponent`, `id = newID`, `hasPassphrase`, `fingerprint`, `publicKeyOpenSSH`, `createdAt: Date()`) und `store.add(key)`.
- **Kontextmenü pro Zeile** + Buttons: **Public-Key kopieren** (`NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.publicKeyOpenSSH, forType: .string)`), **Public-Key exportieren…** (`fileExporter`/`NSSavePanel` schreibt `key.publicKeyOpenSSH`), **Löschen** (Bestätigungsdialog → `store.remove(id: key.id, secrets: KeychainSecretStore())` → Liste neu laden).

**Nutzungs-Warnung beim Löschen:** vor dem Löschen eine Best-effort-Zählung der Sessions/Login-Sets, deren `keyPath` auf die Datei dieses Keys zeigt (analog zur `usageCount`-Anzeige bei Login-Sets). Ist die Zahl > 0, im Bestätigungsdialog erwähnen. Die Zählquelle (SessionStore/LoginSetStore-Zugriff) im App-Scope prüfen; ist sie hier nicht bequem erreichbar, den generischen Warntext ohne Zahl zeigen (kein Blocker).

Grundgerüst:

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

- [ ] **Step 2: Sechsten Tab in `SettingsView` einhängen**

In `Sources/MacSCPApp/SettingsView.swift`, im `TabView` nach dem `ShortcutsSettingsTab`-Block:

```swift
            SSHKeysSettingsTab()
                .tabItem { Label(L10n.string("settings.tab.sshKeys", "SSH Keys"), systemImage: "key") }
```

Prüfen, ob die feste `.frame(width: 460, height: 460)` für Liste + Aktionen reicht; sonst die Liste in einen `ScrollView` fester Höhe setzen (Fenstergröße NICHT ohne Not ändern — die anderen Tabs teilen sie).

- [ ] **Step 3: L10n (EN/DE/FR/PL)**

Neue Keys in alle vier Kataloge (Tab-Label, Spaltentitel/Labels, „nicht verbindbar", Generieren-Dialog-Felder, Typ-/Bitlängen-Optionen, Aktionen kopieren/exportieren/löschen, Lösch-/Nutzungs-Warnung). Beispiel-Kernkeys (EN gezeigt; DE/FR/PL analog, typografische Zeichen, kein ASCII-Quote in nicht-englischen Werten):

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

- [ ] **Step 4: Build + Behaviour-Check**

Run: `swift build`
Expected: 0 Warnungen. Katalog-Parität prüfen (`swift test --filter Localizable`). Verhalten per Codelesen: erzeugen → Liste zeigt neuen Key; kopieren legt die OpenSSH-Zeile in die Zwischenablage; löschen entfernt Key + Datei + Keychain.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/SSHKeysSettingsTab.swift Sources/MacSCPApp/SettingsView.swift Sources/MacSCPApp/Resources
git commit -m "feat: add an SSH Keys settings tab to generate and manage keys

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: App — Key-Picker im Formular + Login-Set-Editor

**Files:**
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (keyPath-Block ~505–521; jump-keyPath analog optional)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (keyPath-Block ~401–412)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `ManagedKeyStore.all()` gefiltert auf `type.isConnectable`, `ManagedKey.name`/`fingerprint`/`fileName`, `ManagedKeyStore.keyDirectory`, `SessionStore.defaultDirectory`.
- Produces: nichts Neues (füllt `viewModel.keyPath` / den Editor-`keyPath`-State).

Reine SwiftUI/App — build-verifiziert.

- [ ] **Step 1: „Verwalteter Schlüssel"-Menü im Formular**

Im keyPath-`FormRow` von `ConnectionFormView.swift` (neben `TextField` + „…"-`Button`) additiv ein `Menu` einfügen, das die verbindbaren Keys listet und `viewModel.keyPath` mit dem App-Datei-Pfad füllt:

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

Plus ein „Schlüssel verwalten…"-Knopf, der das Settings-Fenster/den Tab öffnet (analog zum bestehenden „Logins verwalten…"-Muster — die reale Öffnen-Mechanik im Code übernehmen). `shortFingerprint` = die ersten ~12 Zeichen nach `SHA256:` (kleiner privater Helfer).

- [ ] **Step 2: Dasselbe Menü im Login-Set-Editor**

In `LoginSetsSheet.swift` im keyPath-Block (privateKey-Zweig, ~401–412) dasselbe Menü additiv einfügen, das den Editor-`keyPath`-State füllt.

- [ ] **Step 3: L10n**

```
"keys.picker.managed" = "Managed key";
"keys.picker.manage" = "Manage keys…";
```
in alle vier Kataloge (DE/FR/PL typografisch).

- [ ] **Step 4: Build + Behaviour-Check**

Run: `swift build`
Expected: 0 Warnungen. Verhalten: nur ed25519-Keys erscheinen im Menü; Auswahl füllt `keyPath`; Freitext + „…" bleiben nutzbar. Sind keine verbindbaren Keys vorhanden, erscheint das Menü nicht (kein leeres Menü).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/ConnectionFormView.swift Sources/MacSCPApp/LoginSetsSheet.swift Sources/MacSCPApp/Resources
git commit -m "feat: pick a managed SSH key in the connection form and login sets

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Abschluss — Suite, Review, Push/Deploy

**Files:** keine (Verifikation + Closeout).

- [ ] **Step 1: Volle Suite (inkl. Keychain-Pfade)**

Run: `MACSCP_KEYCHAIN=1 swift test`
Expected: gesamte Suite grün, inkl. der neuen `SSHKeyGeneratorTests`/`ManagedKeyStoreTests`/`ManagedKeyPassphraseTests`.

- [ ] **Step 2: Ungated Suite + 0 Warnungen**

Run: `swift build && swift test`
Expected: Build 0 Warnungen; ungated Suite grün.

- [ ] **Step 3: Runtime-Idle-CPU-Smoke**

Dev-Build starten, den neuen Settings-Tab öffnen, Idle-CPU prüfen (Lektion M11n) — statische Liste, kein Dauer-CPU/Layout-Sturm.

- [ ] **Step 4: Whole-Milestone-Review**

Opus-Whole-Branch-Review über den gesamten M17-Diff (`git merge-base develop HEAD`..HEAD, Basis = M16-HEAD `8bae812`), Fokus auf die Global Constraints (Passphrase nur Keychain, JSON secret-frei, 0600/0700, kein `~/.ssh`-Schreiben, `ssh-keygen` Argument-Array, `SSHPrivateKeyLoader` unverändert, nur ed25519 verbindbar).

- [ ] **Step 5: Push + CI + Dev-Build (auf Maintainer-Anordnung)**

Nach grünem Review — auf Maintainer-Anordnung: Push nach `develop`, `gh run watch`, Dev-Build v1.7.0-dev nach `~/Desktop/macSCP-dev.app`. Kein Release/Tag.

---

## Self-Review

**1. Spec coverage:**
- Spec §Core `ManagedKey`/`KeyType` + `SSHKeyGenerator` → Task 1. ✅
- Spec §Core `ManagedKeyStore` (all/add/remove-mit-Cleanup/key(forPath:)) → Task 2. ✅
- Spec §Core Passphrase-Auflösung + `SSHPrivateKeyLoader` unverändert → Task 3. ✅
- Spec §App Settings-Tab (Liste/Erzeugen/kopieren/exportieren/löschen/Kontextmenü/Nutzungs-Warnung) → Task 4. ✅
- Spec §App Formular/Login-Set-Picker (nur ed25519, füllt keyPath, „verwalten"-Knopf) → Task 5. ✅
- Spec §Tests (Store-CRUD, Generator gegen echtes ssh-keygen inkl. Roundtrip, Passphrase-Auflösung) → Task 1/2/3. ✅
- Spec §Tests App build + Idle-CPU → Task 4/6. ✅
- Spec §Sicherheit/Invarianten → Global Constraints + Task-6-Review. ✅
- Spec §L10n → Task 4/5. ✅

**2. Placeholder scan:** Offene Stellen mit klarer „realen Wert übernehmen"-Anweisung: die exakte `SecretStore`-Quelle + der zweite Connect-Einstieg in Task 3, die Nutzungs-Zählquelle + Settings-Öffnen-Mechanik in Task 4/5. Kein „TBD/TODO".

**3. Type consistency:** `SSHKeyGenerator.generate(type:comment:passphrase:into:) -> GeneratedKey{privateKeyURL,publicKeyOpenSSH,fingerprint}`; `ManagedKey(id,name,comment,type,fingerprint,publicKeyOpenSSH,createdAt,hasPassphrase,fileName)`; `KeyType.isConnectable`; `ManagedKeyStore(directory:)` / `.keyDirectory` / `all()` / `add(_:)` / `remove(id:secrets:)` / `key(forPath:)`; `ManagedKeyPassphrase.resolve(keyPath:typed:store:secrets:)` — über alle Tasks konsistent. `SessionStore.defaultDirectory` als Store-Verzeichnis einheitlich.
