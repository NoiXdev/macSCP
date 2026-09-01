# M9a — Session Import/Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export connections individually/per group/all into a versioned `.macscpsessions` file (optionally AES-GCM encrypted, optionally with passwords) and import them additively with duplicate detection.

**Architecture:** Two pure Core units (`SessionExportCodec` for the envelope format + crypto, `SessionImportPlanner` for duplicates/groups/ID reassignment) plus VM integration in `SessionListViewModel`; the app side consists of context-menu entries, an export sheet, a password sheet, and a result dialog via `fileExporter`/`fileImporter` with its own UTType.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, CryptoKit (AES-GCM), CommonCrypto (PBKDF2), SwiftUI `fileExporter`/`fileImporter`, UTType.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9a-session-import-export-design.md` — binding. Branch: **develop**.
- NO new SPM dependencies (CryptoKit + CommonCrypto are system frameworks; CommonCrypto via `import CommonCrypto`).
- Security: never export key FILES (only the `keyPath` string); passwords only when the toggle is on; the plaintext case (unencrypted + passwords) requires a red warning block + two-step confirmation; `sessions.json`/Keychain invariants untouched (import additive, never overwrite/modify).
- Crypto exactly per spec: PBKDF2-HMAC-SHA256, 600,000 iterations (the value is stored in the file and read from there on decode), 16-byte random salt, 256-bit key, AES-GCM SealedBox `combined`. A wrong password and a tampered file end in the SAME error `wrongPasswordOrCorrupted` (no oracle).
- Duplicates: triple (host lowercased, port, username case-sensitive) against the existing set AND within the file (keep-first); display name and IDs irrelevant; fresh UUIDs for everything imported.
- All new UI text EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); code + comments English ONLY.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (starting point 389 tests / 32 suites); gated suites only in T4.
- TDD for Core (codec, planner, VM); the app target is untestable → T3 delivers a build + behavior description; tests run SYNCHRONOUSLY in the foreground.

## Schedule

T1 (SessionExportCodec, Core) → T2 (SessionImportPlanner + VM, Core) → T3 (UI, App) → T4 close-out (coordinator).

---

### Task 1: SessionExportCodec (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionExportCodec.swift`
- Test: `Tests/macSCPCoreTests/SessionExportCodecTests.swift` (new)

**Interfaces:**
- Consumes: `StoredSession.AuthKind` (string raw value `password`/`privateKey`).
- Produces (T2/T3 rely on this exactly):
  - `public struct SessionExportPayload: Codable, Equatable, Sendable { public var includesSecrets: Bool; public var groups: [ExportedGroup]; public var sessions: [ExportedSession]; public init(...) }`
  - `public struct ExportedGroup: Codable, Equatable, Sendable { public let id: UUID; public var name: String; public init(...) }`
  - `public struct ExportedSession: Codable, Equatable, Sendable { public let id: UUID; public var name: String; public var host: String; public var port: Int; public var username: String; public var authKind: StoredSession.AuthKind; public var keyPath: String?; public var groupID: UUID?; public var password: String?; public init(...) }`
  - `public enum SessionExportError: Error, Equatable { case notAnExportFile, unsupportedVersion(Int), passwordRequired, wrongPasswordOrCorrupted }`
  - `public enum SessionExportCodec { public static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data; public static func decode(_ data: Data, password: String?) throws -> SessionExportPayload; public static func probe(_ data: Data) throws -> Bool }`
  - `probe` throws `notAnExportFile`/`unsupportedVersion`, otherwise returns `encrypted`.

- [x] **Step 1: Failing tests** — `Tests/macSCPCoreTests/SessionExportCodecTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionExportCodec")
struct SessionExportCodecTests {
    private func samplePayload(includesSecrets: Bool = false) -> SessionExportPayload {
        let groupID = UUID()
        return SessionExportPayload(
            includesSecrets: includesSecrets,
            groups: [ExportedGroup(id: groupID, name: "Prod")],
            sessions: [ExportedSession(
                id: UUID(), name: "wärter-01 🚀", host: "Web-01.example.COM",
                port: 2222, username: "deploy", authKind: .privateKey,
                keyPath: "/Users/x/.ssh/id_ed25519", groupID: groupID,
                password: includesSecrets ? "geh€im🔑" : nil)])
    }

    @Test func clearRoundtripPreservesPayload() throws {
        let payload = samplePayload()
        let data = try SessionExportCodec.encode(payload, password: nil)
        #expect(try SessionExportCodec.probe(data) == false)
        #expect(try SessionExportCodec.decode(data, password: nil) == payload)
    }

    @Test func encryptedRoundtripPreservesPayloadIncludingSecrets() throws {
        let payload = samplePayload(includesSecrets: true)
        let data = try SessionExportCodec.encode(payload, password: "päss wörd 🔒")
        #expect(try SessionExportCodec.probe(data) == true)
        let decoded = try SessionExportCodec.decode(data, password: "päss wörd 🔒")
        #expect(decoded == payload)
        // Plaintext must not leak into the encrypted file.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("deploy"))
        #expect(!text.contains("geh€im"))
    }

    @Test func wrongPasswordFailsWithoutOracle() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "right")
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try SessionExportCodec.decode(data, password: "wrong")
        }
    }

    @Test func tamperedCiphertextFailsWithSameError() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var ciphertext = Data(base64Encoded: envelope["ciphertext"] as! String)!
        ciphertext[ciphertext.count / 2] ^= 0xFF
        envelope["ciphertext"] = ciphertext.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try SessionExportCodec.decode(tampered, password: "pw")
        }
    }

    @Test func encryptedFileWithoutPasswordAsksForOne() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        #expect(throws: SessionExportError.passwordRequired) {
            _ = try SessionExportCodec.decode(data, password: nil)
        }
    }

    @Test func garbageAndForeignJSONAreRejected() throws {
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.probe(Data("not json at all".utf8))
        }
        let foreign = Data(#"{"something":"else"}"#.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(foreign, password: nil)
        }
    }

    @Test func newerVersionIsRejectedWithItsNumber() throws {
        let future = Data(#"{"format":"macscp-sessions","version":99,"encrypted":false,"payload":{}}"#.utf8)
        #expect(throws: SessionExportError.unsupportedVersion(99)) {
            _ = try SessionExportCodec.probe(future)
        }
    }
}
```

- [x] **Step 2: Prove red.** Run: `swift test --filter SessionExportCodecTests` → FAIL (types missing).

- [x] **Step 3: Implementation** — `Sources/macSCPCore/Sessions/SessionExportCodec.swift`:

```swift
import CommonCrypto
import CryptoKit
import Foundation

/// The on-disk payload of a `.macscpsessions` export (spec M9a §1). Key
/// FILES are never part of an export — `keyPath` is a plain path reference.
public struct SessionExportPayload: Codable, Equatable, Sendable {
    public var includesSecrets: Bool
    public var groups: [ExportedGroup]
    public var sessions: [ExportedSession]

    public init(includesSecrets: Bool, groups: [ExportedGroup], sessions: [ExportedSession]) {
        self.includesSecrets = includesSecrets
        self.groups = groups
        self.sessions = sessions
    }
}

public struct ExportedGroup: Codable, Equatable, Sendable {
    /// File-local reference target for `ExportedSession.groupID` — never
    /// imported as-is (the planner assigns fresh ids).
    public let id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ExportedSession: Codable, Equatable, Sendable {
    /// File-local id — only for group references inside the file.
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var groupID: UUID?
    /// Present only when the export included secrets AND the keychain had
    /// one for this session at export time.
    public var password: String?

    public init(
        id: UUID, name: String, host: String, port: Int, username: String,
        authKind: StoredSession.AuthKind, keyPath: String?, groupID: UUID?,
        password: String?
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.groupID = groupID
        self.password = password
    }
}

public enum SessionExportError: Error, Equatable {
    case notAnExportFile
    case unsupportedVersion(Int)
    case passwordRequired
    /// Deliberately indistinguishable (spec M9a §1): GCM authentication
    /// fails the same way for a wrong password and a tampered file — no
    /// oracle for attackers, one honest message for users.
    case wrongPasswordOrCorrupted
}

/// Versioned envelope codec for `.macscpsessions` files (spec M9a §1+§2.1).
/// Pure functions — no file system, no keychain — so every branch is unit
/// testable.
public enum SessionExportCodec {
    static let formatName = "macscp-sessions"
    static let currentVersion = 1
    /// OWASP-aligned for PBKDF2-HMAC-SHA256. Stored in the file, so future
    /// increases keep old files decodable.
    static let iterations = 600_000

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var encrypted: Bool
        var payload: SessionExportPayload?
        var salt: Data?
        var iterations: Int?
        var ciphertext: Data?
    }

    public static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let password else {
            return try encoder.encode(Envelope(
                format: formatName, version: currentVersion, encrypted: false,
                payload: payload))
        }
        var salt = Data(count: 16)
        let saltResult = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        precondition(saltResult == errSecSuccess, "SecRandomCopyBytes failed")
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return try encoder.encode(Envelope(
            format: formatName, version: currentVersion, encrypted: true,
            salt: salt, iterations: iterations, ciphertext: sealed.combined))
    }

    /// True = encrypted. Lets the UI decide whether to ask for a password
    /// without attempting decryption.
    public static func probe(_ data: Data) throws -> Bool {
        try envelope(from: data).encrypted
    }

    public static func decode(_ data: Data, password: String?) throws -> SessionExportPayload {
        let envelope = try envelope(from: data)
        if !envelope.encrypted {
            guard let payload = envelope.payload else { throw SessionExportError.notAnExportFile }
            return payload
        }
        guard let password else { throw SessionExportError.passwordRequired }
        guard let salt = envelope.salt, let iterations = envelope.iterations,
              let ciphertext = envelope.ciphertext else {
            throw SessionExportError.notAnExportFile
        }
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return try JSONDecoder().decode(SessionExportPayload.self, from: plaintext)
        } catch {
            throw SessionExportError.wrongPasswordOrCorrupted
        }
    }

    private static func envelope(from data: Data) throws -> Envelope {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == formatName else {
            throw SessionExportError.notAnExportFile
        }
        guard envelope.version <= currentVersion else {
            throw SessionExportError.unsupportedVersion(envelope.version)
        }
        return envelope
    }

    private static func derivedKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, passwordBytes.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &keyBytes, keyBytes.count)
        }
        guard status == kCCSuccess else { throw SessionExportError.wrongPasswordOrCorrupted }
        return SymmetricKey(data: Data(keyBytes))
    }
}
```

(Note: `import CommonCrypto` works directly in SPM on macOS; if the module
import should fail, the fallback route is a small system-library target —
NOT necessary on the current Xcode, try first. `Data` fields are encoded by
JSONEncoder as base64 — the spec format covers that.)

- [x] **Step 4: Green + full suite.** `swift test --filter SessionExportCodecTests` → PASS; `swift test` → 389 + 7 = 396 (record the number in the report); `swift build` clean.

- [x] **Step 5: Commit.**

```bash
git add Sources/macSCPCore/Sessions/SessionExportCodec.swift Tests/macSCPCoreTests/SessionExportCodecTests.swift
git commit -m "feat: add the versioned session export codec"
```

---

### Task 2: SessionImportPlanner + VM integration (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (new methods appended)
- Test: `Tests/macSCPCoreTests/SessionImportPlannerTests.swift` (new), `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (extend; `InMemorySecretStore` and `FailingSecretStore` already exist there as patterns)

**Interfaces:**
- Consumes: `SessionExportPayload`/`ExportedGroup`/`ExportedSession` (T1), `StoredSession`, `StoredGroup`, `SessionStore`, `SecretStore`, the existing `SessionListViewModel.password(for:)`.
- Produces (T3 relies on this exactly):
  - `public struct SessionImportPlan: Equatable, Sendable { public var groupsToCreate: [StoredGroup]; public var sessionsToImport: [PlannedSession]; public var skipped: [ExportedSession] }` with `public struct PlannedSession: Equatable, Sendable { public var session: StoredSession; public var password: String? }`
  - `public enum SessionImportPlanner { public static func plan(existing: [StoredSession], existingGroups: [StoredGroup], incoming: SessionExportPayload) -> SessionImportPlan }`
  - `SessionListViewModel`:
    - `public enum ExportScope { case single(StoredSession), group(StoredGroup), all }`
    - `public func exportPayload(for scope: ExportScope, includeGroups: Bool, includePasswords: Bool) -> (payload: SessionExportPayload, missingPasswordCount: Int)`
    - `public struct SessionImportResult: Equatable { public var imported: Int; public var skipped: Int; public var passwordsImported: Int; public var passwordFailures: Int }`
    - `public func applyImport(_ plan: SessionImportPlan) -> SessionImportResult`

**Rules (spec §2.2/§2.3, binding):** duplicate ⇔ (host.lowercased(), port, username) against the existing set AND in-file (keep-first); display name and IDs irrelevant; group match by exact name against the existing set, otherwise create fresh with a new UUID; every imported session gets a fresh UUID; passwords ride along on the plan entry; `applyImport` is additive, Keychain errors do not abort (the session stays, `passwordFailures` counts it); `exportPayload` leaves out missing Keychain passwords and counts them; groups only when `includeGroups` and only if referenced; when `includeGroups == false` every `groupID` in the payload is nil.

- [x] **Step 1: Failing planner tests** — `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionImportPlanner")
struct SessionImportPlannerTests {
    private func incoming(_ sessions: [ExportedSession], groups: [ExportedGroup] = []) -> SessionExportPayload {
        SessionExportPayload(includesSecrets: false, groups: groups, sessions: sessions)
    }

    private func exported(
        name: String = "s", host: String = "web-01", port: Int = 22,
        username: String = "root", groupID: UUID? = nil, password: String? = nil
    ) -> ExportedSession {
        ExportedSession(
            id: UUID(), name: name, host: host, port: port, username: username,
            authKind: .password, keyPath: nil, groupID: groupID, password: password)
    }

    @Test func duplicateTripleIsSkippedDespiteDifferentName() {
        let existing = [StoredSession(name: "anders", host: "WEB-01", username: "root")]
        let plan = SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([exported(name: "neu", host: "web-01")]))
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    @Test func hostCaseAndPortDistinguishCorrectly() {
        let existing = [StoredSession(name: "a", host: "web-01", username: "root")]
        let plan = SessionImportPlanner.plan(
            existing: existing, existingGroups: [],
            incoming: incoming([
                exported(host: "Web-01", port: 2222),     // other port -> import
                exported(host: "web-01", username: "deploy"), // other user -> import
            ]))
        #expect(plan.sessionsToImport.count == 2)
        #expect(plan.skipped.isEmpty)
    }

    @Test func inFileDuplicatesKeepFirst() {
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([
                exported(name: "erste", host: "Host-A"),
                exported(name: "zweite", host: "host-a"),
            ]))
        #expect(plan.sessionsToImport.map(\.session.name) == ["erste"])
        #expect(plan.skipped.map(\.name) == ["zweite"])
    }

    @Test func groupsMatchByNameOrGetCreatedFresh() {
        let existingGroup = StoredGroup(name: "Prod")
        let fileGroupProd = ExportedGroup(id: UUID(), name: "Prod")
        let fileGroupNew = ExportedGroup(id: UUID(), name: "Staging")
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [existingGroup],
            incoming: incoming(
                [exported(name: "p", host: "h1", groupID: fileGroupProd.id),
                 exported(name: "s", host: "h2", groupID: fileGroupNew.id)],
                groups: [fileGroupProd, fileGroupNew]))
        #expect(plan.groupsToCreate.map(\.name) == ["Staging"])
        let p = plan.sessionsToImport.first { $0.session.name == "p" }!
        let s = plan.sessionsToImport.first { $0.session.name == "s" }!
        #expect(p.session.groupID == existingGroup.id)          // matched by name
        #expect(s.session.groupID == plan.groupsToCreate[0].id) // fresh group
        #expect(plan.groupsToCreate[0].id != fileGroupNew.id)   // fresh id
    }

    @Test func importedSessionsGetFreshIDsAndCarryPasswords() {
        let file = exported(password: "geheim")
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [], incoming: incoming([file]))
        #expect(plan.sessionsToImport[0].session.id != file.id)
        #expect(plan.sessionsToImport[0].password == "geheim")
    }

    @Test func unknownGroupReferenceFallsBackToNil() {
        let plan = SessionImportPlanner.plan(
            existing: [], existingGroups: [],
            incoming: incoming([exported(groupID: UUID())])) // group not in file
        #expect(plan.sessionsToImport[0].session.groupID == nil)
    }
}
```

- [x] **Step 2: Prove red**, then implement the planner (a pure function; duplicate key `"\(host.lowercased())|\(port)|\(username)"`; first resolve groups — name match against `existingGroups`, otherwise create a fresh `StoredGroup(name:)` and keep a local file-ID→new-group mapping; then sessions in file order: check against the existing set + the set of tripes seen so far, on import build `StoredSession(id: UUID(), …)` with the resolved groupID). Prove green.

- [x] **Step 3: Failing VM tests** — in `SessionListViewModelTests.swift` (use the file's existing patterns/fixtures; `InMemorySecretStore` + `FailingSecretStore` already exist):

```swift
    @Test func exportPayloadScopesAndCountsMissingPasswords() {
        // Fixture: two sessions in group "Prod", one without a group; a
        // password exists in the InMemorySecretStore for only ONE of them.
        // scope .all, includeGroups: true, includePasswords: true
        //  -> 3 sessions, 1 group, exactly 1 password != nil, missing == 2? — NO:
        //     missing counts only sessions whose Keychain lookup returns nil;
        //     expectation here: 2 (the two without a stored password).
        // scope .group(prod) -> only the 2 group sessions, groups == [Prod]
        // scope .single(x), includeGroups: false -> 1 session, groups empty, groupID nil
        // includePasswords: false -> ALL password nil, includesSecrets false, missing == 0
    }

    @Test func applyImportCreatesEverythingAdditively() {
        // Apply a plan with 1 new group + 2 sessions (one with password) onto
        // an existing set with 1 unrelated session: afterwards 3 sessions in
        // the store, the group exists, the password is in the
        // InMemorySecretStore under the NEW session ID, Result == (imported: 2,
        // skipped: <from plan>, passwordsImported: 1, passwordFailures: 0);
        // existing set unchanged.
    }

    @Test func applyImportSurvivesKeychainFailure() {
        // FailingSecretStore: the session is still created,
        // passwordFailures == 1, passwordsImported == 0.
    }
```

(Turn the comment sketches into real assertions — the expected values are
already in them; align fixture construction with the file's existing tests.)

- [x] **Step 4: Red**, then implement the VM methods: `exportPayload` maps scope → sessions (group scope via `sessions(inGroup:)`), collects referenced groups only when `includeGroups`, fetches passwords via `password(for:)` only when `includePasswords` (nil ⇒ `missingPasswordCount += 1`), `includesSecrets = includePasswords`. `applyImport` writes groups (`store.upsertGroup`), then sessions (`store.upsert`), passwords via `secrets.savePassword` in a do/catch (error ⇒ `passwordFailures += 1`), and at the end `reload()`; `skipped = plan.skipped.count`. Green.

- [x] **Step 5: Full suite + commit.** `swift test` (396 + 9 ≈ 405; record the real number).

```bash
git add -A
git commit -m "feat: plan and apply session imports with duplicate detection"
```

---

### Task 3: UI — menus, export sheet, import flow (App)

**Files:**
- Create: `Sources/MacSCPApp/SessionExportImportSheets.swift`
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (context-menu entries + callbacks), `Sources/MacSCPApp/ContentView.swift` (sheet/fileExporter/fileImporter state + wiring), `Sources/MacSCPApp/Info-Template or similar` — UTType declaration: check where the app keeps its Info.plist sources (`scripts/package-app` generates them; add `UTExportedTypeDeclarations` there for `dev.noix.macscp.sessions` with extension `macscpsessions`; for dev `swift run` operation, fileExporter/fileImporter also work via the extension — document this in the report), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (app target; smoke test in T4)

**Interfaces:**
- Consumes: `SessionExportCodec` (encode/probe/decode + errors), `SessionListViewModel.exportPayload/applyImport`, `SessionImportPlanner.plan`, `ExportScope`, sidebar callback patterns (`onSelect`/`onEdit`/…), `PolishedButtonStyle`, the `FormRow` aesthetic of the existing sheets (NameEntrySheet as template).
- Produces: the complete export/import UX per spec §3.

**Behavior requirements (spec §3, binding):**
1. Sidebar context menus: session "Export…" / group "Export Group…" / background "Export All…" (dimmed at 0 sessions) + "Import…" — new callbacks following the existing pattern (`onExport(ExportScope)`, `onImport`), wired up in `ContentView`.
2. Export sheet (one view for all scopes): summary line ("%lld connections" key), toggle "Include group assignment" (default ON; hidden for `.single` without a group), toggle "Include passwords" (default OFF), picker/segments "Encrypted"/"Unencrypted" (default Encrypted): Encrypted ⇒ two SecureFields (password + repeat; the export button only enabled when they match && count ≥ 1; hint text for a long password); Unencrypted && passwords ON ⇒ a red warning block (`export.plaintextWarning`) and the primary button becomes two-step: the first click turns it into "Export anyway…" (destructive coloring), the second click exports (state held in the sheet).
3. Export execution: `exportPayload` → `SessionExportCodec.encode` → `fileExporter` (FileDocument wrapper or `fileExporter(isPresented:document:contentType:defaultFilename:)` with a small `FileDocument`, extension `.macscpsessions`, default name "macSCP Sessions"). Afterward, if `missingPasswordCount > 0` and passwords ON: a short alert "Exported without password: %lld".
4. Import: `fileImporter` (content type: own UTType + allow a `.json` fallback — `allowedContentTypes` with the own type; read the file with security-scoped access the way the key import already does it) → `probe` → if encrypted, a password sheet (SecureField + error line on `wrongPasswordOrCorrupted`, unlimited attempts, cancel) → `decode` → `SessionImportPlanner.plan(existing: viewModel.sessions, existingGroups: viewModel.groups, incoming:)` → `applyImport` → result alert: "%lld imported, %lld skipped as duplicates, %lld passwords imported" + a line when `passwordFailures > 0` + an extra line when `payload.includesSecrets && !encrypted` ("The file contained unencrypted passwords.").
5. Error alerts: `notAnExportFile` ("Not a macSCP sessions file."), `unsupportedVersion` ("This file was created by a newer version of macSCP."), write/read errors generically localized. No auto-connect after import.
6. All keys EN/DE (suggestion: `export.menu.single/group/all`, `import.menu`, `export.sheet.title`, `export.summary %lld`, `export.includeGroups`, `export.includePasswords`, `export.encrypted`, `export.unencrypted`, `export.password`, `export.passwordRepeat`, `export.passwordHint`, `export.plaintextWarning`, `export.confirmAnyway`, `export.action`, `export.missingPasswords %lld`, `import.password.title`, `import.password.wrong`, `import.result.title`, `import.result.body` building blocks, `import.error.notExport`, `import.error.newerVersion`) — exact wording EN first, then the DE translation; grep counter-check across both catalogs.

- [x] **Step 1:** sheets file (export sheet, password sheet; NameEntrySheet style: title, fields, isWorking, `.polished` buttons). **Step 2:** sidebar entries + callbacks. **Step 3:** ContentView wiring (state, fileExporter/fileImporter, error/result alerts). **Step 4:** UTType in `scripts/package-app` plist + doc line if needed. **Step 5:** catalog keys + counter-check. **Step 6:** `swift build` (0 errors, no new warnings) + full `swift test` (T2 state). **Step 7:** commit `feat: export and import stored sessions from the sidebar`.

---

### Task 4: Close-out verification (coordinator)

- [x] Gated suites (start the rig from the main checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ fully green, zero skips (406 before / 412 after the final-review fixes).
- [ ] Visual smoke — **delegated to the maintainer** (wrapper is running; checklist in the milestone summary): export single/group/all (check file contents: plaintext readable, encrypted opaque); passwords toggle + plaintext warning path (two-step button); encrypted roundtrip including a wrong password (message in the sheet); import with duplicates (report counts correctly); group match vs. fresh creation; a fresh session connects with the imported password (note the Keychain prompt behavior); an empty session set dims the export menus; sidebar regressions (group CRUD, rename, drag-and-drop menu paths).
- [x] Plan checkboxes, ledger, Opus whole-branch final review (base = commit before T1; crypto called out explicitly — "No" with one Critical → fix commit 648d7d0 → re-review "Ready to merge: Yes"), fixes, push develop, CI, stop the rig, memory update, milestone summary (+ note: M9 release bundling still open; M9b audit log up next).
