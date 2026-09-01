# macSCP M3c — TOFU host keys implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trust-on-first-use host key verification: confirm and store the fingerprint on first connect, silently accept known hosts, on key change a HARD stop (no override in v1) — replaces the current `.acceptAnything()`.

**Architecture:** `HostKeyFingerprint` (Core/SSH) computes OpenSSH-compatible SHA256 fingerprints (verified against `ssh-keygen -lf`). `KnownHostsStore` (Core/Sessions, JSON `known_hosts.json` next to `sessions.json`) persists the public key per `host:port`. `CitadelFileSystem.connect` gets two new required parameters: `knownHosts: KnownHostsStore` and `onUnknownHostKey: @Sendable (HostKeyCandidate) async -> Bool`; a dedicated Citadel validator checks: known+identical → accept, known+DIFFERENT → `HostKeyError.mismatch` (hard), unknown → ask the decider (UI prompt), on consent → store. `ConnectionViewModel` publishes a `hostKeyPrompt` state (fingerprint card in the form flow, "Trust & Connect" / "Cancel"); a mismatch is rendered as an unmissable red error. The CLI driver trusts automatically and PRINTS the fingerprint (documented).

**Dependency graph:**

```
[ Task 0 (opening fixes, UI) ∥ Task 1 (fingerprint + KnownHostsStore, Core) ] ─→ Task 2 (validator + integration; RISK)
                                                                              ─→ Task 3 (UI prompt + VM) ─→ Task 4 (wrap-up)
```
(T0∥T1 are file-disjoint — worktree.)

## Global Constraints

- swift-tools-version 6.0, language mode v5; macOS 14; UI texts German; Conventional Commits with footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- **Security invariants:** a mismatch is a HARD error with no override UI (spec); there is NO code path that accepts an unknown key without explicit consent; `.acceptAnything()` disappears entirely from production code
- No key material in the repo (runtime keys as in M3b)
- OPS: NEVER start the Docker rig from a worktree (new) — the seed mount is relative to the compose file
- After every task: `swift test` green

## File map (M3c delta)

```
Sources/macSCPCore/
  SSH/HostKeyFingerprint.swift        (new, Task 1)
  Sessions/KnownHostsStore.swift      (new, Task 1 — incl. KnownHostKey)
  SSH/HostKeyValidation.swift         (new, Task 2 — HostKeyCandidate, HostKeyError, Citadel validator)
  SSH/CitadelFileSystem.swift         (Task 2 — connect signature + validator instead of acceptAnything)
  Presentation/ConnectionViewModel.swift (Task 3 — hostKeyPrompt state, decider, error mapping)
Sources/MacSCPCLI/MacSCPCLI.swift     (Task 2 — auto-trust + fingerprint output)
Sources/MacSCPApp/
  ConnectionFormView.swift            (Task 0 — clearPassword on mode switch; Task 3 — prompt card)
  ContentView.swift                   (Task 0 — form reset; Task 3 — pass stores through)
Tests/macSCPCoreTests/
  HostKeyFingerprintTests.swift       (new, Task 1 — 3 tests, cross-check against ssh-keygen)
  KnownHostsStoreTests.swift          (new, Task 1 — 4 tests)
  HostKeyValidationTests.swift        (new, Task 2 — 3 unit tests against the store)
  ConnectionViewModelTests.swift      (Task 3 — +3)
  CitadelFileSystemIntegrationTests.swift (Task 2 — +3 gated: TOFU/known/mismatch)
```

---

### Task 0: M3b opening fixes (UI hygiene)

**Files:**
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`

No unit test (view hygiene); verification: build + suite (98) green. **Parallel note:** disjoint from Task 1 — worktree.

- [x] **Step 1:** In `ConnectionFormView`: append to the `Picker("Authentication", ...)`:

```swift
                .onChange(of: viewModel.authChoice) {
                    // Mode switch: don't carry a password/passphrase over
                    // into the other mode (review finding M3b).
                    viewModel.clearPassword()
                }
```

- [x] **Step 2:** In `ContentView.teardownSession()`, add after `clearPassword()`:

```swift
        connectionViewModel.authChoice = .password
        connectionViewModel.keyPath = ""
```

- [x] **Step 3:** `swift build && swift test` (98 green). Commit: `fix: reset auth secret on mode switch and form on disconnect` (with footer).

---

### Task 1: HostKeyFingerprint + KnownHostsStore

**Files:**
- Create: `Sources/macSCPCore/SSH/HostKeyFingerprint.swift`
- Create: `Sources/macSCPCore/Sessions/KnownHostsStore.swift`
- Test: `Tests/macSCPCoreTests/HostKeyFingerprintTests.swift`
- Test: `Tests/macSCPCoreTests/KnownHostsStoreTests.swift`

**Interfaces:**
- Produces (for Task 2/3):

```swift
public enum HostKeyFingerprint {
    /// OpenSSH-compatible fingerprint: "SHA256:" + Base64(SHA256(raw)) WITHOUT '=' padding.
    /// keyBlobBase64 = the Base64 field of an OpenSSH public key line.
    public static func sha256(ofKeyBlobBase64 keyBlobBase64: String) -> String?
    // nil for invalid Base64
}

public struct KnownHostKey: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String            // e.g. "ssh-ed25519"
    public let publicKeyBase64: String    // OpenSSH blob (Base64)
    public init(host: String, port: Int, keyType: String, publicKeyBase64: String)
    public var fingerprintSHA256: String  // computed via HostKeyFingerprint (computed)
}

public struct KnownHostsStore: Sendable {   // pattern like SessionStore (JSON, atomic)
    public init(directory: URL)             // does not throw
    public func find(host: String, port: Int) throws -> KnownHostKey?
    public func upsert(_ key: KnownHostKey) throws   // replaces by host:port
}
```

**Parallel note:** disjoint from Task 0 — worktree possible.

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Red** — compile error (`HostKeyFingerprint`/`KnownHostsStore` unknown)

- [x] **Step 3: Implement**

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

- [x] **Step 4: Green** — both filtered suites (3 + 4), then the full suite (base on its own branch + 7).
- [x] **Step 5: Commit** — `feat: add host key fingerprints and known hosts store` (with footer).

---

### Task 2: Host key validator + Citadel wiring + integration tests (RISK)

**Files:**
- Create: `Sources/macSCPCore/SSH/HostKeyValidation.swift`
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`
- Modify: `Sources/MacSCPCLI/MacSCPCLI.swift`
- Modify: `Tests/macSCPCoreTests/SSHConnectionConfigTests.swift` (call-site adjustment of the propagation test)
- Create: `Tests/macSCPCoreTests/HostKeyValidationTests.swift`
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (+3 gated, adjust all call sites)

**Interfaces:**
- Produces (for Task 3):

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

Behavior: known+identical → connect silently; known+different → `HostKeyError.mismatch` (NEVER the decider); unknown → the decider; `true` → connect AND `knownHosts.upsert`; `false` → `HostKeyError.rejectedByUser`. Afterward `.acceptAnything()` exists nowhere anymore in production code (`grep` proves it).

**API DRIFT HANDLING (core risk of this task):** Before implementing, clarify against `.build/checkouts/Citadel/Sources/Citadel/`: what the host key validator type is called (`SSHHostKeyValidator`?), which factories exist (`acceptAnything`, `trustedKeys`, a `custom` hook with closure/delegate?), and how to get at the presented key bytes (NIOSSHPublicKey → OpenSSH blob: is there a `write(to:)`/Base64 representation? If needed, via `NIOSSHPublicKey` serialization into a ByteBuffer). **Two-phase strategy:** (1) If an async-capable custom hook exists → do TOFU directly in the hook. (2) If the hook is synchronous or only `trustedKeys` exists → fallback: a short probe connect BEFORE the actual connect to grab the host key is NOT acceptable (TOCTOU); instead, the synchronous variant: getting the decider's result BEFORE the connect does not work (the key is only known at the handshake) — so instead: the hook rejects unknown keys, throws a marked error identifying the candidate outward, `connect` catches it, asks the decider, on `true` → upsert + ONE retry with the now-known key. Both variants satisfy the tests; justify the chosen one in the report. If BOTH are impossible: report BLOCKED, soften nothing.

- [x] **Step 1: Unit tests (red)** — `Tests/macSCPCoreTests/HostKeyValidationTests.swift`: 3 tests against the pure decision logic (which must exist as a testable function, e.g. `HostKeyValidation.evaluate(candidate:known:) -> Outcome` with `Outcome: accept/askUser/mismatch`):

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

(`Outcome` as `enum Outcome: Equatable { case accept, askUser, mismatch(expected: String) }` — part of `HostKeyValidation.swift`.)

- [x] **Step 2: Gated tests (red resp. green after wiring)** — add to the integration suite (raise the EXISTING call sites of `connect(config:)` to the new signature; for the EXISTING tests: a fresh temp `KnownHostsStore` + `onUnknownHostKey: { _ in true }`):

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

(`CallCounterBox` = a small NSLock class double in the test file, `@unchecked Sendable`.)

- [x] **Step 3: Implement** — `HostKeyValidation.swift` (Candidate/Error/Outcome/evaluate + Citadel hook per the drift outcome), `CitadelFileSystem.connect` new signature (decider/store), adjust `MacSCPCLI`: its own `KnownHostsStore` (neighboring the defaultDirectory) + an auto-trust decider that prints the fingerprint to stderr: `FileHandle.standardError.write(Data("Host-Key \(candidate.fingerprintSHA256) automatisch vertraut (CLI-Treiber)\n".utf8))`.

**Build bridge for the App (Task 3 replaces it):** `ContentView`'s production connector no longer compiles after the signature change. In this task, patch it MINIMALLY only:

```swift
    @State private var connectionViewModel = ConnectionViewModel(connector: { config in
        try await CitadelFileSystem.connect(
            config: config,
            knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
            // TRANSITIONAL (Task 3 replaces this with the fingerprint prompt):
            // unknown hosts are trusted automatically until then.
            onUnknownHostKey: { _ in true }
        )
    })
```

Task 4 verifies via `grep -rn "onUnknownHostKey: { _ in true }" Sources/MacSCPApp/` that this bridge has been removed.

- [x] **Step 4: Green** — unit (base + 3), gated (rig from the MAIN checkout!): 10/10.
- [x] **Step 5: Commit** — `feat: enforce trust-on-first-use host key verification` (with footer).

---

### Task 3: UI prompt + view model

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (+3; the connector type alias expands)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`

**Interfaces:**
- `ConnectionViewModel.Connector` becomes `@Sendable (SSHConnectionConfig, @escaping @Sendable (HostKeyCandidate) async -> Bool) async throws -> any RemoteFileSystem` (the production connector threads the decider through to `CitadelFileSystem.connect`; `knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory)` is created in ContentView).
- New VM state:

```swift
    public struct HostKeyPrompt: Equatable {
        public let candidate: HostKeyCandidate
    }
    public private(set) var hostKeyPrompt: HostKeyPrompt?
    public func resolveHostKeyPrompt(trust: Bool)   // resumes the continuation
```

- `connect()` installs as the decider a closure that publishes `hostKeyPrompt` and waits on a `CheckedContinuation<Bool, Never>` that `resolveHostKeyPrompt` fulfills (keep the continuation private; ignore duplicate resolve calls; on leaving `connect()` (error/end) set `hostKeyPrompt = nil`).
- Error mapping in `failedState`:

```swift
        case HostKeyError.mismatch(let host, let expected, let presented):
            return .failed(message: "ACHTUNG: Der Host-Key von \(host) hat sich geändert! "
                + "Erwartet \(expected), präsentiert \(presented). "
                + "Möglicher Man-in-the-Middle — Verbindung abgebrochen.", field: nil)
        case HostKeyError.rejectedByUser:
            return .failed(message: "Verbindung abgebrochen — Host-Key nicht bestätigt.", field: nil)
```

- Form: below the error text, a prompt card when `hostKeyPrompt != nil`:

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

- 3 VM tests: `unknownHostPublishesPromptAndTrustConnects` (fake connector calls the decider with a candidate; checks prompt publication, resolve(true) → fs non-nil, prompt nil afterward), `rejectMapsToGermanMessage` (resolve(false) → connector throws rejectedByUser → message), `mismatchMapsToScaryMessage` (connector throws mismatch directly).

- [x] Steps: tests (red) → implement the VM → wire up the form/ContentView → `swift build && swift test` (base + 3) → headless launch → commit `feat: prompt for unknown host keys with hard mismatch stop` (with footer).

---

### Task 4: Wrap-up verification

- [x] **Step 1:** `swift test` — target count per the count (98 + 7 T1 + 3 T2 unit + 3 T3 = 111; gated ones count too: +3 → total reported 114? the coordinator verifies exactly)
- [x] **Step 2:** rig up (MAIN checkout!), gated 10/10, MACSCP_KEYCHAIN 2/2
- [x] **Step 3: Visual smoke test** (coordinator): fresh known_hosts state → connect → the fingerprint card appears (cross-check the fingerprint against `ssh-keygen -lf` on the container's host key!) → "Trust & Connect" → connected; disconnect + reconnect → NO prompt; tamper with known_hosts.json → reconnect → hard red mismatch stop, no connection established; "Cancel" on the prompt → clean cancel message
- [x] **Step 4:** check off checkboxes, commit `docs: mark M3c plan tasks as completed` (with footer)

## Outlook

**M3d** ssh-config import (a pure parser: Host/HostName/User/Port/IdentityFile; merge into the sidebar as "imported" entries) — after that **M3 is complete**. Then M4 terminal (+ a big design element), M5 queue, M6 release incl. design polish pass + app icon.
