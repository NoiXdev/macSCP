# macSCP M3c — TOFU-Host-Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trust-On-First-Use-Host-Key-Verifikation: beim ersten Verbinden Fingerprint bestätigen und speichern, bekannte Hosts still akzeptieren, bei Key-Änderung HARTER Stopp (kein Override in v1) — ersetzt das bisherige `.acceptAnything()`.

**Architecture:** `HostKeyFingerprint` (Core/SSH) berechnet OpenSSH-kompatible SHA256-Fingerprints (verifiziert gegen `ssh-keygen -lf`). `KnownHostsStore` (Core/Sessions, JSON `known_hosts.json` neben `sessions.json`) persistiert pro `host:port` den Public Key. `CitadelFileSystem.connect` bekommt zwei neue Pflicht-Parameter: `knownHosts: KnownHostsStore` und `onUnknownHostKey: @Sendable (HostKeyCandidate) async -> Bool`; ein eigener Citadel-Validator prüft: bekannt+gleich → akzeptieren, bekannt+ANDERS → `HostKeyError.mismatch` (hart), unbekannt → Decider fragen (UI-Prompt), bei Zustimmung speichern. `ConnectionViewModel` publiziert einen `hostKeyPrompt`-Zustand (Fingerprint-Karte im Formular-Flow, „Vertrauen & verbinden" / „Abbrechen"); Mismatch wird als unübersehbarer roter Fehler gerendert. Der CLI-Treiber vertraut automatisch und DRUCKT den Fingerprint (dokumentiert).

**Abhängigkeitsgraph:**

```
[ Task 0 (Opening-Fixes, UI) ∥ Task 1 (Fingerprint + KnownHostsStore, Core) ] ─→ Task 2 (Validator + Integration; RISK)
                                                                              ─→ Task 3 (UI-Prompt + VM) ─→ Task 4 (Abschluss)
```
(T0∥T1 dateidisjunkt — Worktree.)

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI-Texte Deutsch; Conventional Commits mit Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- **Sicherheits-Invarianten:** Mismatch ist ein HARTER Fehler ohne Override-UI (Spec); es gibt KEINEN Codepfad, der einen unbekannten Key ohne explizite Zustimmung akzeptiert; `.acceptAnything()` verschwindet vollständig aus dem Produktions-Code
- Kein Schlüsselmaterial im Repo (Laufzeit-Keys wie in M3b)
- OPS: Docker-Rig NIE aus einem Worktree heraus (neu) starten — Seed-Mount ist relativ zur compose-Datei
- Nach jedem Task: `swift test` grün

## Datei-Landkarte (Delta M3c)

```
Sources/macSCPCore/
  SSH/HostKeyFingerprint.swift        (neu, Task 1)
  Sessions/KnownHostsStore.swift      (neu, Task 1 — inkl. KnownHostKey)
  SSH/HostKeyValidation.swift         (neu, Task 2 — HostKeyCandidate, HostKeyError, Citadel-Validator)
  SSH/CitadelFileSystem.swift         (Task 2 — connect-Signatur + Validator statt acceptAnything)
  Presentation/ConnectionViewModel.swift (Task 3 — hostKeyPrompt-Zustand, Decider, Fehler-Mapping)
Sources/MacSCPCLI/MacSCPCLI.swift     (Task 2 — Auto-Trust + Fingerprint-Ausgabe)
Sources/MacSCPApp/
  ConnectionFormView.swift            (Task 0 — clearPassword bei Moduswechsel; Task 3 — Prompt-Karte)
  ContentView.swift                   (Task 0 — Form-Reset; Task 3 — Stores durchreichen)
Tests/macSCPCoreTests/
  HostKeyFingerprintTests.swift       (neu, Task 1 — 3 Tests, Cross-Check ssh-keygen)
  KnownHostsStoreTests.swift          (neu, Task 1 — 4 Tests)
  HostKeyValidationTests.swift        (neu, Task 2 — 3 Unit-Tests gegen Store)
  ConnectionViewModelTests.swift      (Task 3 — +3)
  CitadelFileSystemIntegrationTests.swift (Task 2 — +3 gated: TOFU/known/mismatch)
```

---

### Task 0: M3b-Opening-Fixes (UI-Hygiene)

**Files:**
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`

Kein Unit-Test (View-Hygiene); Verifikation: Build + Suite (98) grün. **Parallel-Hinweis:** disjunkt zu Task 1 — Worktree.

- [x] **Step 1:** In `ConnectionFormView`: an den `Picker("Authentifizierung", ...)` anhängen:

```swift
                .onChange(of: viewModel.authChoice) {
                    // Moduswechsel: Passwort/Passphrase nicht in den anderen
                    // Modus verschleppen (Review-Fund M3b).
                    viewModel.clearPassword()
                }
```

- [x] **Step 2:** In `ContentView.teardownSession()` nach `clearPassword()` ergänzen:

```swift
        connectionViewModel.authChoice = .password
        connectionViewModel.keyPath = ""
```

- [x] **Step 3:** `swift build && swift test` (98 grün). Commit: `fix: reset auth secret on mode switch and form on disconnect` (mit Footer).

---

### Task 1: HostKeyFingerprint + KnownHostsStore

**Files:**
- Create: `Sources/macSCPCore/SSH/HostKeyFingerprint.swift`
- Create: `Sources/macSCPCore/Sessions/KnownHostsStore.swift`
- Test: `Tests/macSCPCoreTests/HostKeyFingerprintTests.swift`
- Test: `Tests/macSCPCoreTests/KnownHostsStoreTests.swift`

**Interfaces:**
- Produces (für Task 2/3):

```swift
public enum HostKeyFingerprint {
    /// OpenSSH-kompatibler Fingerprint: "SHA256:" + Base64(SHA256(raw)) OHNE '='-Padding.
    /// keyBlobBase64 = das Base64-Feld einer OpenSSH-Public-Key-Zeile.
    public static func sha256(ofKeyBlobBase64 keyBlobBase64: String) -> String?
    // nil bei ungültigem Base64
}

public struct KnownHostKey: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String            // z.B. "ssh-ed25519"
    public let publicKeyBase64: String    // OpenSSH-Blob (Base64)
    public init(host: String, port: Int, keyType: String, publicKeyBase64: String)
    public var fingerprintSHA256: String  // berechnet via HostKeyFingerprint (computed)
}

public struct KnownHostsStore: Sendable {   // Muster wie SessionStore (JSON, atomar)
    public init(directory: URL)             // wirft nicht
    public func find(host: String, port: Int) throws -> KnownHostKey?
    public func upsert(_ key: KnownHostKey) throws   // ersetzt per host:port
}
```

**Parallel-Hinweis:** disjunkt zu Task 0 — Worktree möglich.

- [x] **Step 1: Fehlschlagende Tests**

`Tests/macSCPCoreTests/HostKeyFingerprintTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Der Fingerprint-Vertrag wird gegen das System-ssh-keygen verifiziert —
/// Laufzeit-Keys, kein Schlüsselmaterial im Repo.
@Suite("HostKeyFingerprint")
struct HostKeyFingerprintTests {
    /// Erzeugt einen ed25519-Key und liefert (Base64-Blob, ssh-keygen-Fingerprint).
    private func makeReference() throws -> (blob: String, expected: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("id_ed25519")

        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                            "-N", "", "-q", "-C", "fp-test"]
        try keygen.run(); keygen.waitUntilExit()
        #expect(keygen.terminationStatus == 0)

        let pubLine = try String(
            contentsOfFile: keyURL.path(percentEncoded: false) + ".pub", encoding: .utf8)
        let blob = pubLine.split(separator: " ")[1]

        let lf = Process()
        let pipe = Pipe()
        lf.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        lf.arguments = ["-lf", keyURL.path(percentEncoded: false) + ".pub"]
        lf.standardOutput = pipe
        try lf.run(); lf.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        // Format: "256 SHA256:xxxx fp-test (ED25519)"
        let expected = out.split(separator: " ")
            .first { $0.hasPrefix("SHA256:") }.map(String.init) ?? ""
        return (String(blob), expected)
    }

    @Test func matchesSshKeygenFingerprint() throws {
        let (blob, expected) = try makeReference()
        #expect(!expected.isEmpty)
        #expect(HostKeyFingerprint.sha256(ofKeyBlobBase64: blob) == expected)
    }

    @Test func invalidBase64YieldsNil() {
        #expect(HostKeyFingerprint.sha256(ofKeyBlobBase64: "kein base64 !!!") == nil)
    }

    @Test func fingerprintHasNoPadding() throws {
        let (blob, _) = try makeReference()
        let fp = HostKeyFingerprint.sha256(ofKeyBlobBase64: blob)
        #expect(fp?.hasSuffix("=") == false)
        #expect(fp?.hasPrefix("SHA256:") == true)
    }
}
```

`Tests/macSCPCoreTests/KnownHostsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("KnownHostsStore")
struct KnownHostsStoreTests {
    private func makeStore() -> (KnownHostsStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-\(UUID().uuidString)")
        return (KnownHostsStore(directory: dir), dir)
    }

    private let key = KnownHostKey(
        host: "example.com", port: 22,
        keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")

    @Test func findOnEmptyStoreReturnsNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.find(host: "example.com", port: 22) == nil)
    }

    @Test func upsertPersistsAndFindsByHostAndPort() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(key)
        #expect(try store.find(host: "example.com", port: 22) == key)
        #expect(try store.find(host: "example.com", port: 2222) == nil)
    }

    @Test func upsertReplacesByHostPort() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(key)
        let rotated = KnownHostKey(
            host: "example.com", port: 22,
            keyType: "ssh-ed25519", publicKeyBase64: "TEVFUlpFSUxF")
        try store.upsert(rotated)
        #expect(try store.find(host: "example.com", port: 22)?.publicKeyBase64 == "TEVFUlpFSUxF")
    }

    @Test func fingerprintIsDerivedFromBlob() {
        // "QUJDREVG" == Base64("ABCDEF") — Fingerprint muss dem SHA256 davon entsprechen
        #expect(key.fingerprintSHA256 == HostKeyFingerprint.sha256(ofKeyBlobBase64: "QUJDREVG"))
    }
}
```

- [x] **Step 2: Rot** — Compile-Fehler (`HostKeyFingerprint`/`KnownHostsStore` unbekannt)

- [x] **Step 3: Implementieren**

`Sources/macSCPCore/SSH/HostKeyFingerprint.swift`:

```swift
import Crypto
import Foundation

/// OpenSSH-kompatible SHA256-Fingerprints ("SHA256:" + Base64 ohne Padding).
public enum HostKeyFingerprint {
    public static func sha256(ofKeyBlobBase64 keyBlobBase64: String) -> String? {
        guard let raw = Data(base64Encoded: keyBlobBase64) else { return nil }
        let digest = SHA256.hash(data: raw)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + b64
    }
}
```

`Sources/macSCPCore/Sessions/KnownHostsStore.swift`:

```swift
import Foundation

/// Gemerkter Host-Key (TOFU). Der Fingerprint ist aus dem Blob abgeleitet.
public struct KnownHostKey: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKeyBase64: String

    public init(host: String, port: Int, keyType: String, publicKeyBase64: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
    }

    public var fingerprintSHA256: String {
        HostKeyFingerprint.sha256(ofKeyBlobBase64: publicKeyBase64) ?? "SHA256:?"
    }
}

/// JSON-Persistenz der bekannten Host-Keys (Muster wie SessionStore:
/// zustandslos, atomare Writes, Single-App-Annahme).
public struct KnownHostsStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("known_hosts.json")
    }

    public func find(host: String, port: Int) throws -> KnownHostKey? {
        try all().first { $0.host == host && $0.port == port }
    }

    public func upsert(_ key: KnownHostKey) throws {
        var keys = try all()
        keys.removeAll { $0.host == key.host && $0.port == key.port }
        keys.append(key)
        try persist(keys)
    }

    private func all() throws -> [KnownHostKey] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([KnownHostKey].self, from: data)
    }

    private func persist(_ keys: [KnownHostKey]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
```

- [x] **Step 4: Grün** — beide Filter-Suiten (3 + 4), dann Gesamtsuite (auf eigenem Branch Basis + 7).
- [x] **Step 5: Commit** — `feat: add host key fingerprints and known hosts store` (mit Footer).

---

### Task 2: Host-Key-Validator + Citadel-Wiring + Integrationstests (RISK)

**Files:**
- Create: `Sources/macSCPCore/SSH/HostKeyValidation.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift`
- Modify: `Tests/macSCPCoreTests/SSHConnectionConfigTests.swift` (Aufrufstellen-Anpassung des Propagation-Tests)
- Create: `Tests/macSCPCoreTests/HostKeyValidationTests.swift`
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (+3 gated, alle Aufrufstellen anpassen)

**Interfaces:**
- Produces (für Task 3):

```swift
public struct HostKeyCandidate: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKeyBase64: String
    public var fingerprintSHA256: String
}

public enum HostKeyError: Error, Equatable, Sendable {
    /// Bekannter Host präsentiert einen ANDEREN Key — harter Stopp, kein Override.
    case mismatch(host: String, expected: String, presented: String)  // Fingerprints
    case rejectedByUser
}

// CitadelFileSystem.connect — NEUE Pflicht-Signatur:
public static func connect(
    config: SSHConnectionConfig,
    knownHosts: KnownHostsStore,
    onUnknownHostKey: @escaping @Sendable (HostKeyCandidate) async -> Bool
) async throws -> CitadelFileSystem
```

Verhalten: bekannt+identisch → still verbinden; bekannt+anders → `HostKeyError.mismatch` (NIE der Decider); unbekannt → Decider; `true` → verbinden UND `knownHosts.upsert`; `false` → `HostKeyError.rejectedByUser`. `.acceptAnything()` existiert danach nirgends mehr im Produktions-Code (`grep` beweist es).

**API-DRIFT-BEHANDLUNG (Kern-Risiko dieses Tasks):** Vor dem Implementieren in `.build/checkouts/Citadel/Sources/Citadel/` klären: Wie heißt der Host-Key-Validator-Typ (`SSHHostKeyValidator`?), welche Fabriken existieren (`acceptAnything`, `trustedKeys`, ein `custom`-Hook mit Closure/Delegate?), und wie kommt man an die präsentierten Key-Bytes (NIOSSHPublicKey → OpenSSH-Blob: gibt es `write(to:)`/Base64-Repräsentation? Notfalls über `NIOSSHPublicKey`-Serialisierung in einen ByteBuffer). **Zwei-Phasen-Strategie:** (1) Wenn ein async-fähiger custom-Hook existiert → direkt TOFU im Hook. (2) Wenn der Hook synchron ist oder nur `trustedKeys` existiert → Fallback: VOR dem eigentlichen Connect einen kurzen Probe-Connect zum Abgreifen des Host-Keys ist NICHT akzeptabel (TOCTOU); stattdessen synchrone Variante: Decider-Ergebnis VOR dem Connect einholen geht nicht (Key erst beim Handshake bekannt) — dann: Hook lehnt unbekannte Keys ab, wirft eine markierte Fehlerkennung mit dem Kandidaten nach außen, `connect` fängt sie, fragt den Decider, bei `true` → upsert + EIN Retry mit jetzt bekanntem Key. Beide Varianten erfüllen die Tests; die gewählte im Report begründen. Wenn BEIDES unmöglich ist: BLOCKED melden, nichts aufweichen.

- [x] **Step 1: Unit-Tests (Rot)** — `Tests/macSCPCoreTests/HostKeyValidationTests.swift`: 3 Tests gegen die pure Entscheidungslogik (die als testbare Funktion existieren muss, z.B. `HostKeyValidation.evaluate(candidate:known:) -> Outcome` mit `Outcome: accept/askUser/mismatch`):

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("HostKeyValidation")
struct HostKeyValidationTests {
    private let candidate = HostKeyCandidate(
        host: "example.com", port: 22,
        keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")

    @Test func unknownHostAsksUser() {
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: nil) == .askUser)
    }

    @Test func knownIdenticalKeyAccepts() {
        let known = KnownHostKey(host: "example.com", port: 22,
                                 keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: known) == .accept)
    }

    @Test func knownDifferentKeyIsMismatch() {
        let known = KnownHostKey(host: "example.com", port: 22,
                                 keyType: "ssh-ed25519", publicKeyBase64: "TEVFUlpFSUxF")
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: known)
            == .mismatch(expected: known.fingerprintSHA256))
    }
}
```

(`Outcome` als `enum Outcome: Equatable { case accept, askUser, mismatch(expected: String) }` — Teil von `HostKeyValidation.swift`.)

- [x] **Step 2: Gated-Tests (Rot bzw. nach Wiring grün)** — in der Integrations-Suite ergänzen (bestehende Aufrufstellen von `connect(config:)` auf die neue Signatur heben; für die BESTEHENDEN Tests: frischer Temp-KnownHostsStore + `onUnknownHostKey: { _ in true }`):

```swift
    @Test func tofuStoresKeyOnFirstAcceptAndConnectsSilentlyAfterwards() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        let asked = CallCounterBox()
        let fs1 = try await CitadelFileSystem.connect(
            config: config, knownHosts: store,
            onUnknownHostKey: { _ in asked.increment(); return true })
        await fs1.disconnect()
        #expect(asked.value == 1)
        #expect(try store.find(host: "127.0.0.1", port: 2222) != nil)

        let fs2 = try await CitadelFileSystem.connect(
            config: config, knownHosts: store,
            onUnknownHostKey: { _ in asked.increment(); return true })
        await fs2.disconnect()
        #expect(asked.value == 1)   // kein zweiter Prompt
    }

    @Test func rejectedHostKeyFailsWithoutStoring() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        await #expect(throws: HostKeyError.rejectedByUser) {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store, onUnknownHostKey: { _ in false })
        }
        #expect(try store.find(host: "127.0.0.1", port: 2222) == nil)
    }

    @Test func tamperedKnownKeyFailsHardWithMismatch() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-tofu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownHostsStore(directory: dir)
        try store.upsert(KnownHostKey(
            host: "127.0.0.1", port: 2222,
            keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG"))   // absichtlich falsch
        let config = try SSHConnectionConfig(
            host: "127.0.0.1", port: 2222, username: "testuser",
            auth: .password("testpass"))

        do {
            _ = try await CitadelFileSystem.connect(
                config: config, knownHosts: store,
                onUnknownHostKey: { _ in
                    Issue.record("Mismatch darf NIE den Decider fragen")
                    return true
                })
            Issue.record("mismatch erwartet")
        } catch let error as HostKeyError {
            guard case .mismatch = error else {
                Issue.record("mismatch erwartet, war: \(error)")
                return
            }
        }
    }
```

(`CallCounterBox` = kleines NSLock-Klassen-Double im Testfile, `@unchecked Sendable`.)

- [x] **Step 3: Implementieren** — `HostKeyValidation.swift` (Candidate/Error/Outcome/evaluate + Citadel-Hook gemäß Drift-Ergebnis), `CitadelFileSystem.connect` neue Signatur (Decider/Store), `MacSCPCLI` anpassen: eigener `KnownHostsStore` (defaultDirectory-Nachbar) + Auto-Trust-Decider, der den Fingerprint auf stderr druckt: `FileHandle.standardError.write(Data("Host-Key \(candidate.fingerprintSHA256) automatisch vertraut (CLI-Treiber)\n".utf8))`.

**Build-Brücke für die App (Task 3 ersetzt sie):** `ContentView`s Produktions-Connector kompiliert nach der Signatur-Änderung nicht mehr. In diesem Task NUR minimal patchen:

```swift
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(
            config: config,
            knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
            // ÜBERGANG (Task 3 ersetzt dies durch den Fingerprint-Prompt):
            // unbekannte Hosts werden bis dahin automatisch vertraut.
            onUnknownHostKey: { _ in true }
        )
    })
```

Task 4 verifiziert per `grep -rn "onUnknownHostKey: { _ in true }" Sources/MacSCPApp/`, dass diese Brücke entfernt wurde.

- [x] **Step 4: Grün** — Unit (Basis + 3), gated (Rig aus HAUPT-Checkout!): 10/10.
- [x] **Step 5: Commit** — `feat: enforce trust-on-first-use host key verification` (mit Footer).

---

### Task 3: UI-Prompt + ViewModel

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (+3; Connector-Typalias erweitert sich)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`

**Interfaces:**
- `ConnectionViewModel.Connector` wird zu `@Sendable (SSHConnectionConfig, @escaping @Sendable (HostKeyCandidate) async -> Bool) async throws -> any RemoteFileSystem` (Produktions-Connector reicht den Decider an `CitadelFileSystem.connect` durch; `knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory)` entsteht in ContentView).
- Neuer VM-Zustand:

```swift
    public struct HostKeyPrompt: Equatable {
        public let candidate: HostKeyCandidate
    }
    public private(set) var hostKeyPrompt: HostKeyPrompt?
    public func resolveHostKeyPrompt(trust: Bool)   // setzt Continuation fort
```

- `connect()` installiert als Decider eine Closure, die `hostKeyPrompt` publiziert und auf eine `CheckedContinuation<Bool, Never>` wartet, die `resolveHostKeyPrompt` erfüllt (Continuation privat halten; doppelte Resolve-Aufrufe ignorieren; beim Verlassen von `connect()` (Fehler/Ende) `hostKeyPrompt = nil`).
- Fehler-Mapping in `failedState`:

```swift
        case HostKeyError.mismatch(let host, let expected, let presented):
            return .failed(message: "ACHTUNG: Der Host-Key von \(host) hat sich geändert! "
                + "Erwartet \(expected), präsentiert \(presented). "
                + "Möglicher Man-in-the-Middle — Verbindung abgebrochen.", field: nil)
        case HostKeyError.rejectedByUser:
            return .failed(message: "Verbindung abgebrochen — Host-Key nicht bestätigt.", field: nil)
```

- Formular: unter dem Fehler-Text eine Prompt-Karte, wenn `hostKeyPrompt != nil`:

```swift
            if let prompt = viewModel.hostKeyPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Erster Verbindungsaufbau zu \(prompt.candidate.host)")
                        .font(.headline)
                    Text("Fingerprint (\(prompt.candidate.keyType)):")
                        .font(.callout)
                    Text(prompt.candidate.fingerprintSHA256)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Abbrechen") { viewModel.resolveHostKeyPrompt(trust: false) }
                        Button("Vertrauen & verbinden") {
                            viewModel.resolveHostKeyPrompt(trust: true)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
```

- 3 VM-Tests: `unknownHostPublishesPromptAndTrustConnects` (Fake-Connector ruft Decider mit Kandidat; prüft prompt-Publikation, resolve(true) → fs non-nil, prompt nil danach), `rejectMapsToGermanMessage` (resolve(false) → Connector wirft rejectedByUser → Meldung), `mismatchMapsToScaryMessage` (Connector wirft mismatch direkt).

- [x] Steps: Tests (Rot) → VM implementieren → Formular/ContentView verdrahten → `swift build && swift test` (Basis + 3) → Headless-Launch → Commit `feat: prompt for unknown host keys with hard mismatch stop` (mit Footer).

---

### Task 4: Abschluss-Verifikation

- [x] **Step 1:** `swift test` — Zielzahl laut Zählung (98 + 7 T1 + 3 T2-Unit + 3 T3 = 111; gated zählen mit: +3 → gesamt gemeldet 114? Koordinator verifiziert exakt)
- [x] **Step 2:** Rig hoch (HAUPT-Checkout!), gated 10/10, MACSCP_KEYCHAIN 2/2
- [x] **Step 3: Visueller Smoke-Test** (Koordinator): Frischer known_hosts-Zustand → Verbinden → Fingerprint-Karte erscheint (Fingerprint mit `ssh-keygen -lf` auf dem Container-Hostkey gegenprüfen!) → „Vertrauen & verbinden" → verbunden; Trennen + Reconnect → KEIN Prompt; known_hosts.json manipulieren → Reconnect → harter roter Mismatch-Stopp, kein Verbindungsaufbau; „Abbrechen" beim Prompt → saubere Abbruch-Meldung
- [x] **Step 4:** Checkboxen, Commit `docs: mark M3c plan tasks as completed` (mit Footer)

## Ausblick

**M3d** ssh-config-Import (purer Parser: Host/HostName/User/Port/IdentityFile; Merge in die Sidebar als „importiert"-Einträge) — danach ist **M3 komplett**. Dann M4 Terminal (+ großes Design-Element), M5 Queue, M6 Release inkl. Design-Polish-Pass + App-Icon.
