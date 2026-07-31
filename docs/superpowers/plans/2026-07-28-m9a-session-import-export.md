# M9a — Session-Import/Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verbindungen einzeln/pro Gruppe/alle in eine versionierte `.macscpsessions`-Datei exportieren (wahlweise AES-GCM-verschlüsselt, optional mit Passwörtern) und additiv mit Dubletten-Erkennung importieren.

**Architecture:** Zwei reine Core-Einheiten (`SessionExportCodec` für das Envelope-Format + Krypto, `SessionImportPlanner` für Dubletten/Gruppen/ID-Neuvergabe) plus VM-Integration in `SessionListViewModel`; die App-Seite sind Kontextmenü-Einträge, ein Export-Sheet, ein Passwort-Sheet und ein Ergebnis-Dialog über `fileExporter`/`fileImporter` mit eigenem UTType.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, CryptoKit (AES-GCM), CommonCrypto (PBKDF2), SwiftUI `fileExporter`/`fileImporter`, UTType.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9a-session-import-export-design.md` — bindend. Branch: **develop**.
- KEINE neuen SPM-Dependencies (CryptoKit + CommonCrypto sind System-Frameworks; CommonCrypto via `import CommonCrypto`).
- Sicherheit: Key-DATEIEN nie exportieren (nur `keyPath`-String); Passwörter nur, wenn der Toggle an ist; Klartext-Fall (unverschlüsselt + Passwörter) verlangt roten Warnblock + zweistufige Bestätigung; `sessions.json`/Keychain-Invarianten unangetastet (Import additiv, nie überschreiben/verändern).
- Krypto exakt laut Spec: PBKDF2-HMAC-SHA256, 600 000 Iterationen (Wert steht in der Datei und wird beim Decode von dort gelesen), 16-Byte-Zufalls-Salt, 256-Bit-Schlüssel, AES-GCM SealedBox `combined`. Falsches Passwort und manipulierte Datei enden im SELBEN Fehler `wrongPasswordOrCorrupted` (kein Orakel).
- Dubletten: Tripel (host lowercased, port, username case-sensitiv) gegen Bestand UND in-Datei (keep-first); Anzeigename und IDs egal; frische UUIDs für alles Importierte.
- Alle neuen UI-Texte EN/DE (`Sources/MacSCPApp/Resources/*/Localizable.strings`); Code + Kommentare NUR Englisch.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 389 Tests / 32 Suiten); gated Suiten nur in T4.
- TDD für Core (Codec, Planner, VM); App-Target untestbar → T3 liefert Build + Verhaltensbeschreibung; Tests SYNCHRON im Vordergrund.

## Schedule

T1 (SessionExportCodec, Core) → T2 (SessionImportPlanner + VM, Core) → T3 (UI, App) → T4 Abschluss (Koordinator).

---

### Task 1: SessionExportCodec (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionExportCodec.swift`
- Test: `Tests/macSCPCoreTests/SessionExportCodecTests.swift` (neu)

**Interfaces:**
- Consumes: `StoredSession.AuthKind` (String-RawValue `password`/`privateKey`).
- Produces (T2/T3 verlassen sich exakt hierauf):
  - `public struct SessionExportPayload: Codable, Equatable, Sendable { public var includesSecrets: Bool; public var groups: [ExportedGroup]; public var sessions: [ExportedSession]; public init(...) }`
  - `public struct ExportedGroup: Codable, Equatable, Sendable { public let id: UUID; public var name: String; public init(...) }`
  - `public struct ExportedSession: Codable, Equatable, Sendable { public let id: UUID; public var name: String; public var host: String; public var port: Int; public var username: String; public var authKind: StoredSession.AuthKind; public var keyPath: String?; public var groupID: UUID?; public var password: String?; public init(...) }`
  - `public enum SessionExportError: Error, Equatable { case notAnExportFile, unsupportedVersion(Int), passwordRequired, wrongPasswordOrCorrupted }`
  - `public enum SessionExportCodec { public static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data; public static func decode(_ data: Data, password: String?) throws -> SessionExportPayload; public static func probe(_ data: Data) throws -> Bool }`
  - `probe` wirft `notAnExportFile`/`unsupportedVersion`, liefert sonst `encrypted`.

- [x] **Step 1: Failing Tests** — `Tests/macSCPCoreTests/SessionExportCodecTests.swift`:

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

- [x] **Step 2: Rot beweisen.** Run: `swift test --filter SessionExportCodecTests` → FAIL (Typen fehlen).

- [x] **Step 3: Implementierung** — `Sources/macSCPCore/Sessions/SessionExportCodec.swift`:

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

(Hinweis: `import CommonCrypto` funktioniert in SPM auf macOS direkt; sollte der Modul-Import fehlschlagen, ist die Fallback-Route ein kleines System-Library-Target — NICHT nötig auf aktuellem Xcode, erst probieren. `Data`-Felder werden von JSONEncoder als Base64 kodiert — deckt das Spec-Format ab.)

- [x] **Step 4: Grün + volle Suite.** `swift test --filter SessionExportCodecTests` → PASS; `swift test` → 389 + 7 = 396 (Zahl im Report festhalten); `swift build` sauber.

- [x] **Step 5: Commit.**

```bash
git add Sources/macSCPCore/Sessions/SessionExportCodec.swift Tests/macSCPCoreTests/SessionExportCodecTests.swift
git commit -m "feat: add the versioned session export codec"
```

---

### Task 2: SessionImportPlanner + VM-Integration (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (neue Methoden ans Ende)
- Test: `Tests/macSCPCoreTests/SessionImportPlannerTests.swift` (neu), `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (erweitern; dort existieren `InMemorySecretStore` und `FailingSecretStore` als Muster)

**Interfaces:**
- Consumes: `SessionExportPayload`/`ExportedGroup`/`ExportedSession` (T1), `StoredSession`, `StoredGroup`, `SessionStore`, `SecretStore`, bestehendes `SessionListViewModel.password(for:)`.
- Produces (T3 verlässt sich exakt hierauf):
  - `public struct SessionImportPlan: Equatable, Sendable { public var groupsToCreate: [StoredGroup]; public var sessionsToImport: [PlannedSession]; public var skipped: [ExportedSession] }` mit `public struct PlannedSession: Equatable, Sendable { public var session: StoredSession; public var password: String? }`
  - `public enum SessionImportPlanner { public static func plan(existing: [StoredSession], existingGroups: [StoredGroup], incoming: SessionExportPayload) -> SessionImportPlan }`
  - `SessionListViewModel`:
    - `public enum ExportScope { case single(StoredSession), group(StoredGroup), all }`
    - `public func exportPayload(for scope: ExportScope, includeGroups: Bool, includePasswords: Bool) -> (payload: SessionExportPayload, missingPasswordCount: Int)`
    - `public struct SessionImportResult: Equatable { public var imported: Int; public var skipped: Int; public var passwordsImported: Int; public var passwordFailures: Int }`
    - `public func applyImport(_ plan: SessionImportPlan) -> SessionImportResult`

**Regeln (Spec §2.2/§2.3, bindend):** Dublette ⇔ (host.lowercased(), port, username) gegen Bestand; in-Datei-Dubletten keep-first; Gruppen-Match per exaktem Namen gegen Bestand, sonst Neuanlage mit frischer UUID; jede importierte Session frische UUID; Passwörter hängen am Plan-Eintrag; `applyImport` additiv, Keychain-Fehler brechen nicht ab (Session bleibt, `passwordFailures` zählt); `exportPayload` lässt fehlende Keychain-Passwörter aus und zählt sie; Gruppen nur bei `includeGroups` und nur referenzierte; bei `includeGroups == false` sind alle `groupID`s im Payload nil.

- [x] **Step 1: Failing Planner-Tests** — `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`:

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

- [x] **Step 2: Rot beweisen**, dann Planner implementieren (reine Funktion; Dubletten-Schlüssel `"\(host.lowercased())|\(port)|\(username)"`; erst Gruppen auflösen — Name-Match gegen `existingGroups`, sonst `StoredGroup(name:)` frisch anlegen und im lokalen Mapping Datei-ID→neue Gruppe führen; dann Sessions in Dateireihenfolge: gegen Bestands-Set + gesehene-Tripel-Set prüfen, bei Import `StoredSession(id: UUID(), …)` mit aufgelöster groupID bauen). Grün beweisen.

- [x] **Step 3: Failing VM-Tests** — in `SessionListViewModelTests.swift` (bestehende Muster/Fixtures der Datei nutzen; `InMemorySecretStore` + `FailingSecretStore` existieren):

```swift
    @Test func exportPayloadScopesAndCountsMissingPasswords() {
        // Fixture: zwei Sessions in Gruppe "Prod", eine ohne Gruppe; nur für
        // EINE liegt ein Passwort im InMemorySecretStore.
        // scope .all, includeGroups: true, includePasswords: true
        //  -> 3 Sessions, 1 Gruppe, genau 1 password != nil, missing == 2? — NEIN:
        //     missing zählt nur Sessions, deren Keychain-Lookup nil liefert;
        //     Erwartung hier: 2 (die beiden ohne gespeichertes Passwort).
        // scope .group(prod) -> nur die 2 Gruppen-Sessions, groups == [Prod]
        // scope .single(x), includeGroups: false -> 1 Session, groups leer, groupID nil
        // includePasswords: false -> ALLE password nil, includesSecrets false, missing == 0
    }

    @Test func applyImportCreatesEverythingAdditively() {
        // Plan mit 1 neuer Gruppe + 2 Sessions (eine mit Passwort) auf einen
        // Bestand mit 1 fremden Session anwenden: danach 3 Sessions im Store,
        // Gruppe existiert, Passwort im InMemorySecretStore unter der NEUEN
        // Session-ID, Result == (imported: 2, skipped: <aus Plan>, passwordsImported: 1,
        // passwordFailures: 0); Bestand unverändert.
    }

    @Test func applyImportSurvivesKeychainFailure() {
        // FailingSecretStore: Session wird trotzdem angelegt,
        // passwordFailures == 1, passwordsImported == 0.
    }
```

(Kommentar-Skizzen in echte Assertions ausformulieren — die Erwartungswerte stehen drin; Fixture-Konstruktion an die vorhandenen Tests der Datei angleichen.)

- [x] **Step 4: Rot**, dann VM-Methoden implementieren: `exportPayload` mappt Scope → Sessions (Gruppen-Scope über `sessions(inGroup:)`), sammelt referenzierte Gruppen nur bei `includeGroups`, holt Passwörter via `password(for:)` nur bei `includePasswords` (nil ⇒ `missingPasswordCount += 1`), `includesSecrets = includePasswords`. `applyImport` schreibt Gruppen (`store.upsertGroup`), dann Sessions (`store.upsert`), Passwörter via `secrets.savePassword` in do/catch (Fehler ⇒ `passwordFailures += 1`), am Ende `reload()`; `skipped = plan.skipped.count`. Grün.

- [x] **Step 5: Volle Suite + Commit.** `swift test` (396 + 9 ≈ 405; echte Zahl festhalten).

```bash
git add -A
git commit -m "feat: plan and apply session imports with duplicate detection"
```

---

### Task 3: UI — Menüs, Export-Sheet, Import-Fluss (App)

**Files:**
- Create: `Sources/MacSCPApp/SessionExportImportSheets.swift`
- Modify: `Sources/MacSCPApp/SessionSidebar.swift` (Kontextmenü-Einträge + Callbacks), `Sources/MacSCPApp/ContentView.swift` (Sheet-/fileExporter-/fileImporter-State + Verkabelung), `Sources/MacSCPApp/Info-Template o. Ä.` — UTType-Deklaration: prüfen, wo die App ihre Info.plist-Quellen hält (`scripts/package-app` generiert sie; dort `UTExportedTypeDeclarations` für `dev.noix.macscp.sessions` mit Endung `macscpsessions` ergänzen; für den Dev-`swift run`-Betrieb funktionieren fileExporter/fileImporter auch über die Endung — im Report dokumentieren), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T4)

**Interfaces:**
- Consumes: `SessionExportCodec` (encode/probe/decode + Fehler), `SessionListViewModel.exportPayload/applyImport`, `SessionImportPlanner.plan`, `ExportScope`, Sidebar-Callbacks-Muster (`onSelect`/`onEdit`/…), `PolishedButtonStyle`, `FormRow`-Ästhetik der bestehenden Sheets (NameEntrySheet als Vorlage).
- Produces: die komplette Export-/Import-UX laut Spec §3.

**Verhaltens-Anforderungen (Spec §3, bindend):**
1. Sidebar-Kontextmenüs: Session „Export…" / Gruppe „Export Group…" / Hintergrund „Export All…" (gedimmt bei 0 Sessions) + „Import…" — neue Callbacks nach dem Muster der bestehenden (`onExport(ExportScope)`, `onImport`), Verkabelung in `ContentView`.
2. Export-Sheet (ein View für alle Scopes): Zusammenfassungszeile („%lld Verbindungen"-Key), Toggle „Include group assignment" (Default AN; ausgeblendet bei `.single` ohne Gruppe), Toggle „Include passwords" (Default AUS), Picker/Segmente „Encrypted"/„Unencrypted" (Default Encrypted): Verschlüsselt ⇒ zwei SecureFields (Passwort + Wiederholung; Export-Button nur bei Übereinstimmung && count ≥ 1; Hinweis-Text langes Passwort); Unverschlüsselt && Passwörter AN ⇒ roter Warnblock (`export.plaintextWarning`) und der Primär-Button wird zweistufig: erster Klick wandelt ihn in „Export anyway…" (destruktive Färbung), zweiter Klick exportiert (State im Sheet).
3. Export-Ausführung: `exportPayload` → `SessionExportCodec.encode` → `fileExporter` (FileDocument-Wrapper oder `fileExporter(isPresented:document:contentType:defaultFilename:)` mit einem kleinen `FileDocument`, Endung `.macscpsessions`, Default-Name „macSCP Sessions"). Danach, falls `missingPasswordCount > 0` und Passwörter AN: Kurz-Alert „Exported without password: %lld".
4. Import: `fileImporter` (contentType eigener UTType + `.json`-Fallback zulassen — `allowedContentTypes` mit dem eigenen Typ; Datei lesen mit security-scoped access wie der Key-Import es vormacht) → `probe` → bei encrypted Passwort-Sheet (SecureField + Fehlerzeile bei `wrongPasswordOrCorrupted`, beliebige Versuche, Abbrechen) → `decode` → `SessionImportPlanner.plan(existing: viewModel.sessions, existingGroups: viewModel.groups, incoming:)` → `applyImport` → Ergebnis-Alert: „%lld imported, %lld skipped as duplicates, %lld passwords imported" + Zeile bei `passwordFailures > 0` + Zusatzzeile, wenn `payload.includesSecrets && !encrypted` („The file contained unencrypted passwords.").
5. Fehler-Alerts: `notAnExportFile` („Not a macSCP sessions file."), `unsupportedVersion` („This file was created by a newer version of macSCP."), Schreib-/Lesefehler generisch lokalisiert. Kein Auto-Connect nach Import.
6. Alle Keys EN/DE (Vorschlag: `export.menu.single/group/all`, `import.menu`, `export.sheet.title`, `export.summary %lld`, `export.includeGroups`, `export.includePasswords`, `export.encrypted`, `export.unencrypted`, `export.password`, `export.passwordRepeat`, `export.passwordHint`, `export.plaintextWarning`, `export.confirmAnyway`, `export.action`, `export.missingPasswords %lld`, `import.password.title`, `import.password.wrong`, `import.result.title`, `import.result.body`-Bausteine, `import.error.notExport`, `import.error.newerVersion`) — exakte Wortlaute EN zuerst, DE-Übersetzung; Grep-Gegenprobe beide Kataloge.

- [x] **Step 1:** Sheets-Datei (Export-Sheet, Passwort-Sheet; NameEntrySheet-Stil: Titel, Felder, isWorking, `.polished`-Buttons). **Step 2:** Sidebar-Einträge + Callbacks. **Step 3:** ContentView-Verkabelung (State, fileExporter/fileImporter, Fehler-/Ergebnis-Alerts). **Step 4:** UTType in `scripts/package-app`-Plist + ggf. Doku-Zeile. **Step 5:** Katalog-Keys + Gegenprobe. **Step 6:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T2). **Step 7:** Commit `feat: export and import stored sessions from the sidebar`.

---

### Task 4: Abschluss-Verifikation (Koordinator)

- [x] Gated Suiten (Rig-Start aus dem Haupt-Checkout): `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün, zero skips (406 vor / 412 nach den Final-Review-Fixes).
- [ ] Visueller Smoke — **an den Maintainer delegiert** (Wrapper läuft; Checkliste in der Milestone-Zusammenfassung): Export einzeln/Gruppe/alle (Datei-Inhalt prüfen: Klartext lesbar, verschlüsselt opak); Passwörter-Toggle + Klartext-Warnweg (zweistufiger Button); verschlüsselter Roundtrip inkl. falschem Passwort (Meldung im Sheet); Import mit Dubletten (Bericht zählt korrekt); Gruppen-Match vs. Neuanlage; frische Session verbindet mit importiertem Passwort (Keychain-Prompt-Verhalten beachten); leerer Bestand dimmt Export-Menüs; Regressionen Sidebar (Gruppen-CRUD, Rename, D&D-Menüwege).
- [x] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1; Krypto explizit — „No" mit einem Critical → Fix-Commit 648d7d0 → Re-Review „Ready to merge: Yes"), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ Hinweis: Release-Bündelung M9 offen; M9b Audit-Log als Nächstes).
