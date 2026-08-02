# M19 — Login-Set Import/Export + einheitliche Konfliktlösung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Login-Sets lassen sich exportieren und importieren — optional mit Geheimnissen und eingebetteten verwalteten Schlüsseln — und **alle** Import-Wege benutzen denselben Konfliktdialog.

**Architecture:** Der gehärtete Envelope-/Krypto-Kern des Session-Exports wird über den Payload-Typ generisch; `SessionExportCodec` bleibt als dünne Fassade mit unveränderter öffentlicher API darüber, ein `LoginSetExportCodec` kommt daneben. Eine geteilte Konflikt-Maschinerie (Resolution/Conflict/Decider nach dem Vorbild der Transfer-Queue) wird von beiden Import-Planern benutzt; die App zeigt für beide dasselbe Sheet.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, CryptoKit/CommonCrypto (vorhanden), SwiftUI + AppKit, macOS 15+.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **keine neue externe Dependency**.
- **Geheimnisse und Schlüsselmaterial nur bei ausdrücklichem Opt-in**; unverschlüsselter Export davon nur nach **zweistufiger** Bestätigung.
- **Externe Schlüsseldateien werden nie gelesen** — nur Pfade, die `ManagedKeyStore.key(forPath:)` als verwalteten Schlüssel auflöst. `~/.ssh` bleibt tabu.
- Importierte Schlüssel: Datei **0600**, Verzeichnis explizit auf **0700** härten (`createDirectory` härtet ein *bestehendes* Verzeichnis NICHT — die Foundation-Falle aus M17/M18), Passphrase ausschließlich im Keychain unter der **neuen** Key-ID, Aufräumen von Datei **und** Keychain-Slot bei jedem Fehlschlag nach dem Schreiben.
- **`replace` überschreibt bewusst auch das Keychain-Geheimnis**, der Eintrag behält seine `id`. Der Dialog benennt das.
- **Kein Schlüsselmaterial und keine Geheimnisse in Logs oder Fehlertexten.**
- Die bestehenden Session-Codec-Tests laufen **unverändert** weiter — sie sind der Regressionsschutz des generischen Umbaus.
- Code, Kommentare, Testnamen: **Englisch**. UI-Strings EN/DE/FR/PL, typografische Zeichen in nicht-englischen Werten (kein ASCII `"`).
- Conventional Commits; Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verankerte Fakten (verifiziert am Code):** `SessionExportCodec` (`Sources/macSCPCore/Sessions/SessionExportCodec.swift`) ist ein `public enum` mit `static let formatName = "macscp-sessions"` (:128), `static let currentVersion = 1` (:129), `private struct Envelope: Codable` (:134), `public static func encode(_:password:)` (:144), `probe(_:)` (:167), `decode(_:password:)` (:171), `private struct EnvelopeHeader: Decodable` (:205), `private static func envelope(from:)` (:210) und `derivedKey(password:salt:iterations:)` (:224). Fehler: `public enum SessionExportError: Error, Equatable` (:110). `SessionImportPlanner.plan(existing:existingGroups:incoming:) -> SessionImportPlan` (`SessionImportPlanner.swift:39`) ist **synchron und rein**; `SessionImportPlan` hat `groupsToCreate`/`sessionsToImport`/`skipped`. `LoginSet` **und** `LoginSetStore` liegen beide in `Sources/macSCPCore/Sessions/LoginSetStore.swift` (Store: `all()`, `upsert(_:)`, `delete(id:)`). `ManagedKeyStore` (`Sources/macSCPCore/SSH/ManagedKeyStore.swift`): `keyDirectory`, `all()`, `add(_:)`, `remove(id:secrets:)`, `key(forPath:)`. `UTType.macscpSessions` wird in `Sources/MacSCPApp/SessionExportImportSheets.swift:16-18` per `exportedAs: "dev.noix.macscp.sessions"` deklariert; das gepackte `.app` deklariert denselben Identifier zusätzlich in `Info.plist` (`UTExportedTypeDeclarations`, erzeugt von `scripts/package-app`).

**Kein App-Testtarget:** `Package.swift` hat nur `macSCPCoreTests`. App-Tasks sind build-verifiziert; alle testbare Logik gehört nach Core.

---

## Task 1: Generischer Envelope-/Krypto-Kern (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/ExportEnvelopeCodec.swift`
- Modify: `Sources/macSCPCore/Sessions/SessionExportCodec.swift`
- Test: `Tests/macSCPCoreTests/ExportEnvelopeCodecTests.swift` (neu)

**Interfaces:**
- Produces:
  ```swift
  public enum ExportEnvelopeCodec {
      public static func encode<P: Codable>(_ payload: P, format: String, version: Int, password: String?) throws -> Data
      public static func probe(_ data: Data, format: String) throws -> Bool
      public static func decode<P: Codable>(_ data: Data, as: P.Type, format: String, currentVersion: Int, password: String?) throws -> P
  }
  ```
  Fehler bleiben `SessionExportError` (der Typ wird von beiden Formaten geteilt; **nicht** umbenennen — das wäre eine API-Änderung ohne Nutzen).
- `SessionExportCodec`s öffentliche API bleibt **byte-identisch**: `encode(_:password:)`, `probe(_:)`, `decode(_:password:)`, `formatName`, `currentVersion`.

- [ ] **Step 1: Failing-Test schreiben**

Neue Datei `Tests/macSCPCoreTests/ExportEnvelopeCodecTests.swift`. Der Test beweist, dass der Kern **formatunabhängig** funktioniert und Formate sich gegenseitig abweisen:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ExportEnvelopeCodec")
struct ExportEnvelopeCodecTests {
    private struct Probe: Codable, Equatable {
        var name: String
        var count: Int
    }

    @Test func roundTripsAnyPayloadUnencrypted() throws {
        let payload = Probe(name: "x", count: 3)
        let data = try ExportEnvelopeCodec.encode(payload, format: "macscp-probe", version: 1, password: nil)
        #expect(try ExportEnvelopeCodec.probe(data, format: "macscp-probe") == false)
        let back = try ExportEnvelopeCodec.decode(
            data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: nil)
        #expect(back == payload)
    }

    @Test func roundTripsAnyPayloadEncrypted() throws {
        let payload = Probe(name: "x", count: 3)
        let data = try ExportEnvelopeCodec.encode(payload, format: "macscp-probe", version: 1, password: "pw")
        #expect(try ExportEnvelopeCodec.probe(data, format: "macscp-probe") == true)
        let back = try ExportEnvelopeCodec.decode(
            data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: "pw")
        #expect(back == payload)
    }

    @Test func rejectsAForeignFormat() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 1, password: nil)
        #expect(throws: SessionExportError.self) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-other", currentVersion: 1, password: nil)
        }
    }

    @Test func rejectsAFutureVersion() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 2, password: nil)
        #expect(throws: SessionExportError.self) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: nil)
        }
    }
}
```

Den genauen Fehlerfall (`notAnExportFile` / `unsupportedVersion`) aus `SessionExportError` ablesen und die beiden Abweis-Tests auf den **konkreten** Fall verschärfen, statt nur auf den Typ zu prüfen.

- [ ] **Step 2: Test rot**

Run: `swift test --filter ExportEnvelopeCodec`
Expected: FAIL — `ExportEnvelopeCodec` existiert nicht.

- [ ] **Step 3: Kern extrahieren**

`ExportEnvelopeCodec.swift` bekommt den **unveränderten** Envelope-/Krypto-Code aus `SessionExportCodec`: `Envelope` (Payload jetzt generisch bzw. als `Data` transportiert), `EnvelopeHeader`, `envelope(from:)`, `derivedKey(password:salt:iterations:)`, PBKDF2 mit 600 000 Iterationen, AES-GCM, und **die Iterationsklemme `> 0 && <= 10_000_000` vor dem CommonCrypto-Aufruf** — diese Härtung ist sicherheitsrelevant und muss wortgleich mitwandern.

Der bestehende `Envelope` trägt `payload: SessionExportPayload?` konkret. Beim Generischmachen entscheidet der Implementierer zwischen zwei Wegen und **begründet die Wahl im Bericht**:
- `Envelope<P: Codable>` generisch über den Payload, oder
- der Payload wird als bereits kodiertes `Data`/Base64 im Envelope geführt und in einer zweiten Runde de-/kodiert.

Maßgeblich ist: **die erzeugten Bytes eines Session-Exports müssen bitgleich zu vorher bleiben**, sonst brechen bestehende Dateien. Prüfe das ausdrücklich (bestehende Session-Tests plus, falls nötig, ein eigener Vergleich gegen einen vor dem Umbau erzeugten Blob).

`SessionExportCodec` wird zur Fassade:

```swift
public enum SessionExportCodec {
    static let formatName = "macscp-sessions"
    static let currentVersion = 1

    public static func encode(_ payload: SessionExportPayload, password: String?) throws -> Data {
        try ExportEnvelopeCodec.encode(payload, format: formatName, version: currentVersion, password: password)
    }

    public static func probe(_ data: Data) throws -> Bool {
        try ExportEnvelopeCodec.probe(data, format: formatName)
    }

    public static func decode(_ data: Data, password: String?) throws -> SessionExportPayload {
        try ExportEnvelopeCodec.decode(data, as: SessionExportPayload.self,
                                       format: formatName, currentVersion: currentVersion, password: password)
    }
}
```

**Die bestehenden Session-Codec-Tests werden NICHT angefasst.** Bleiben sie grün, ist der Umbau bewiesen. Muss doch einer angepasst werden, ist das ein Signal, dass die Fassade nicht äquivalent ist — dann melden statt den Test umschreiben.

- [ ] **Step 4: Grün + volle Suite**

Run: `swift test --filter "ExportEnvelopeCodec|SessionExportCodec"` → PASS, dann `swift build && swift test` → 0 Warnungen, alle grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions Tests/macSCPCoreTests/ExportEnvelopeCodecTests.swift
git commit -m "refactor: make the export envelope and crypto generic over the payload

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Login-Set-Format (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/LoginSetExportCodec.swift`
- Test: `Tests/macSCPCoreTests/LoginSetExportCodecTests.swift` (neu)

**Interfaces:**
- Consumes: `ExportEnvelopeCodec` (Task 1).
- Produces: `LoginSetExportPayload`, `ExportedLoginSet`, `EmbeddedKey`, `LoginSetExportCodec` mit `formatName = "macscp-logins"`, `currentVersion = 1`, `encode/probe/decode` analog zur Session-Fassade.

- [ ] **Step 1: Failing-Test**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginSetExportCodec")
struct LoginSetExportCodecTests {
    private func sample(secret: String? = nil, key: EmbeddedKey? = nil) -> LoginSetExportPayload {
        LoginSetExportPayload(
            includesSecrets: secret != nil,
            includesKeyFiles: key != nil,
            sets: [ExportedLoginSet(
                id: UUID(), name: "Prod", kind: .ssh, username: "deploy",
                authKind: .password, keyPath: nil, accessKeyID: nil,
                secret: secret, embeddedKey: key)])
    }

    @Test func roundTripsUnencrypted() throws {
        let payload = sample()
        let data = try LoginSetExportCodec.encode(payload, password: nil)
        #expect(try LoginSetExportCodec.probe(data) == false)
        #expect(try LoginSetExportCodec.decode(data, password: nil) == payload)
    }

    @Test func roundTripsEncrypted() throws {
        let payload = sample(secret: "s3cret")
        let data = try LoginSetExportCodec.encode(payload, password: "pw")
        #expect(try LoginSetExportCodec.probe(data) == true)
        #expect(try LoginSetExportCodec.decode(data, password: "pw") == payload)
    }

    @Test func rejectsTheWrongPassword() throws {
        let data = try LoginSetExportCodec.encode(sample(secret: "s3cret"), password: "pw")
        #expect(throws: SessionExportError.self) {
            _ = try LoginSetExportCodec.decode(data, password: "nope")
        }
    }

    // A sessions file must not import as logins — the two formats are distinct.
    @Test func rejectsASessionsFile() throws {
        let sessions = try SessionExportCodec.encode(
            SessionExportPayload(includesSecrets: false, groups: [], sessions: []), password: nil)
        #expect(throws: SessionExportError.self) {
            _ = try LoginSetExportCodec.decode(sessions, password: nil)
        }
    }

    // Secret hygiene: without the opt-in, nothing sensitive reaches the file.
    @Test func aPlainExportWithoutOptInCarriesNoSecrets() throws {
        let data = try LoginSetExportCodec.encode(sample(), password: nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("s3cret"))
        #expect(!text.lowercased().contains("private key"))
    }
}
```

Die konkreten Fehlerfälle (falsches Passwort, fremdes Format) aus `SessionExportError` ablesen und die Erwartungen darauf verschärfen. `KeyType`/`StoredSession.AuthKind`/`ConnectionKind` sind vorhanden — reale Fälle verwenden.

- [ ] **Step 2: Test rot**

Run: `swift test --filter LoginSetExportCodec`
Expected: FAIL — `LoginSetExportPayload` existiert nicht.

- [ ] **Step 3: Implementieren**

Payload-Typen exakt wie in der Spec (`docs/superpowers/specs/2026-08-02-m19-login-set-export-design.md`, Abschnitt „Payload"): `LoginSetExportPayload { includesSecrets, includesKeyFiles, sets }`, `ExportedLoginSet { id, name, kind, username, authKind, keyPath, accessKeyID, secret, embeddedKey }`, `EmbeddedKey { fileContents: Data, name, comment, type: KeyType, fingerprint, hasPassphrase, passphrase }`. Alle `Codable, Equatable, Sendable`, mit `public init`. Doc-Kommentare an `secret`/`passphrase`/`embeddedKey` halten fest, **wann** sie überhaupt gefüllt sein dürfen.

`LoginSetExportCodec` ist die zweite dünne Fassade über `ExportEnvelopeCodec` — dieselbe Form wie `SessionExportCodec`, nur mit `formatName = "macscp-logins"`.

- [ ] **Step 4: Grün + volle Suite**

Run: `swift test --filter LoginSetExportCodec` → PASS; `swift build && swift test` → grün, 0 Warnungen.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/LoginSetExportCodec.swift Tests/macSCPCoreTests/LoginSetExportCodecTests.swift
git commit -m "feat: add the macscp-logins export format

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Geteilte Konflikt-Maschinerie (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/ImportConflict.swift`

**Interfaces:**
- Produces: `ImportConflictResolution`, `ImportConflict`, `ImportConflictDecider`, `ImportConflictArbiter`.

Reine Typen plus ein kleiner Zustandshalter für „Für alle übernehmen" — ohne den müsste jeder Planer die Regel selbst mitschleppen, und genau dort schleicht sich die Abweichung ein.

- [ ] **Step 1: Failing-Test**

In `Tests/macSCPCoreTests/ImportConflictTests.swift` (neu):

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ImportConflictArbiter")
struct ImportConflictTests {
    @Test func asksOncePerConflictWithoutApplyToAll() async {
        let asked = Counter()
        let arbiter = ImportConflictArbiter { _ in
            await asked.bump()
            return (.skip, false)
        }
        _ = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        _ = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(await asked.value == 2)
    }

    @Test func applyToAllAnswersEveryFurtherConflictWithoutAsking() async {
        let asked = Counter()
        let arbiter = ImportConflictArbiter { _ in
            await asked.bump()
            return (.replace, true)
        }
        let first = await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set"))
        let second = await arbiter.resolve(ImportConflict(itemName: "b", kindLabel: "login set"))
        #expect(first == .replace)
        #expect(second == .replace)
        #expect(await asked.value == 1)
    }

    @Test func nilCancelsAndStaysCancelled() async {
        let arbiter = ImportConflictArbiter { _ in nil }
        #expect(await arbiter.resolve(ImportConflict(itemName: "a", kindLabel: "login set")) == nil)
        #expect(await arbiter.isCancelled)
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
```

- [ ] **Step 2: Test rot**

Run: `swift test --filter ImportConflictArbiter`
Expected: FAIL — die Typen existieren nicht.

- [ ] **Step 3: Implementieren**

```swift
public enum ImportConflictResolution: Equatable, Sendable { case skip, replace, rename }

public struct ImportConflict: Equatable, Sendable {
    public var itemName: String
    public var kindLabel: String
    public init(itemName: String, kindLabel: String) { … }
}

public typealias ImportConflictDecider =
    @Sendable (ImportConflict) async -> (resolution: ImportConflictResolution, applyToAll: Bool)?

/// Holds the "apply to all" rule for ONE import run, mirroring the transfer
/// queue's `queueRule` (M5b). Both import planners go through this so the two
/// flows cannot drift apart.
public actor ImportConflictArbiter {
    public init(decider: @escaping ImportConflictDecider) { … }
    public private(set) var isCancelled = false
    /// Returns nil once the user cancelled — the caller must then apply nothing.
    public func resolve(_ conflict: ImportConflict) async -> ImportConflictResolution? { … }
}
```

`resolve` fragt den Decider nur, solange keine Regel gesetzt und nicht abgebrochen wurde; `applyToAll == true` merkt die Antwort; `nil` setzt `isCancelled` und liefert ab dann ohne Rückfrage `nil`.

- [ ] **Step 4: Grün + Suite**

Run: `swift test --filter ImportConflictArbiter` → PASS; `swift build && swift test` → grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/ImportConflict.swift Tests/macSCPCoreTests/ImportConflictTests.swift
git commit -m "feat: add the shared import conflict machinery

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Schlüssel-Einbettung und -Materialisierung (Core, sicherheitskritisch)

**Files:**
- Create: `Sources/macSCPCore/Sessions/EmbeddedKeyPorter.swift`
- Test: `Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift` (neu)

**Interfaces:**
- Consumes: `EmbeddedKey` (Task 2), `ManagedKeyStore`, `ManagedKey`, `SecretStore`.
- Produces:
  ```swift
  public enum EmbeddedKeyPorter {
      /// Returns an `EmbeddedKey` only when `keyPath` resolves to a MANAGED key.
      /// External paths are never read — a nil result means "not ours, skip".
      public static func embed(keyPath: String?, includePassphrase: Bool,
                               store: ManagedKeyStore, secrets: any SecretStore) throws -> EmbeddedKey?

      /// Writes the key into the managed store under a FRESH id and returns the
      /// new local path for the imported set's `keyPath`.
      public static func materialize(_ key: EmbeddedKey,
                                     store: ManagedKeyStore, secrets: any SecretStore) throws -> String
  }
  ```

- [ ] **Step 1: Failing-Tests**

Muster: wie die M17/M18-Key-Tests echte Schlüssel per `ssh-keygen` erzeugen (siehe `Tests/macSCPCoreTests/SSHKeyGeneratorTests.swift` und `SSHKeyImporterTests.swift` — Aufbau von dort übernehmen, inklusive Temp-Verzeichnis und Aufräumen).

```swift
    @Test func embedsOnlyManagedKeys() throws {
        // A generated key inside the managed store round-trips …
        // … and a path OUTSIDE the store returns nil WITHOUT reading the file.
    }

    @Test func embedCarriesThePassphraseOnlyWhenAsked() throws { … }

    @Test func materializeWritesThePrivateKeyWith0600() throws {
        let path = try EmbeddedKeyPorter.materialize(embedded, store: store, secrets: secrets)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
        #expect(try store.key(forPath: path) != nil)
    }

    @Test func materializeHardensAPreexistingKeyDirectoryTo0700() throws { … }

    @Test func materializeUsesAFreshIDAndStoresThePassphraseUnderIt() throws { … }

    @Test func materializeCleansUpTheFileAndKeychainSlotWhenAStepFails() throws { … }
```

Für den Aufräum-Test einen `SecretStore`-Double verwenden, dessen `savePassword` wirft (die bestehenden Tests haben ein solches Muster — nachsehen und wiederverwenden, nicht neu erfinden).

- [ ] **Step 2: Tests rot**

Run: `swift test --filter EmbeddedKeyPorter`
Expected: FAIL — Typ existiert nicht.

- [ ] **Step 3: Implementieren**

`embed`: `guard let keyPath`, dann `store.key(forPath: keyPath)`. Ist das `nil` → **`nil` zurückgeben, ohne die Datei anzufassen** (das ist die Invariante „externe Pfade werden nie gelesen"; im Doc-Kommentar festhalten). Sonst Dateiinhalt von `keyDirectory/fileName` lesen und `EmbeddedKey` aus den `ManagedKey`-Metadaten bauen; `passphrase` nur bei `includePassphrase && key.hasPassphrase` aus dem Keychain unter `key.id`.

`materialize`: frische `UUID`, Verzeichnis anlegen **und** explizit auf `0700` setzen (`setAttributes`, nicht `createDirectory(attributes:)` — die Falle aus M17/M18), Datei unter der neuen ID schreiben und explizit auf `0600` setzen, `ManagedKey` mit der neuen ID in den Store, Passphrase (falls vorhanden) unter der neuen ID in den Keychain, neuen Pfad zurückgeben. **Jeder** Fehlschlag nach dem Schreiben räumt Datei und Keychain-Slot wieder ab (`do/catch` mit Cleanup, wie der manuelle Import in `SSHKeysSheet`). Schlüsselbytes niemals loggen oder in Fehlertexte aufnehmen.

- [ ] **Step 4: Grün + Suite**

Run: `swift test --filter EmbeddedKeyPorter` → PASS; `swift build && swift test` → grün, 0 Warnungen.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/EmbeddedKeyPorter.swift Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift
git commit -m "feat: embed and materialize managed keys for login set transport

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Login-Set-Import-Planer (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/LoginSetImportPlanner.swift`
- Test: `Tests/macSCPCoreTests/LoginSetImportPlannerTests.swift` (neu)

**Interfaces:**
- Consumes: `LoginSetExportPayload` (T2), `ImportConflictArbiter` (T3).
- Produces:
  ```swift
  public struct PlannedLoginSet: Equatable, Sendable {
      public var set: LoginSet
      public var secret: String?
      public var embeddedKey: EmbeddedKey?
      /// True when this replaces an existing set — the applier must also
      /// overwrite that set's Keychain secret.
      public var replacesExisting: Bool
  }

  public struct LoginSetImportPlan: Equatable, Sendable {
      public var setsToImport: [PlannedLoginSet]
      public var skipped: [String]      // names
      public var replaced: [String]     // names
      public var renamed: [String]      // new names
      public var cancelled: Bool
  }

  public enum LoginSetImportPlanner {
      public static func plan(existing: [LoginSet], incoming: LoginSetExportPayload,
                              arbiter: ImportConflictArbiter) async -> LoginSetImportPlan
  }
  ```

Planer ist **rein** (kein Store-, Keychain- oder Dateizugriff) — das Anwenden macht die App.

- [ ] **Step 1: Failing-Tests**

```swift
    @Test func importsNonCollidingSetsUnchanged() async { … }

    // Collision key is the NAME, case-insensitive and trimmed.
    @Test func detectsCollisionsByTrimmedCaseInsensitiveName() async { … }

    @Test func skipDropsTheIncomingSet() async { … }

    @Test func replaceKeepsTheExistingIDSoReferencingSessionsStillPoint() async {
        // The planned set must carry the EXISTING id, not the file's id.
        #expect(plan.setsToImport[0].set.id == existing[0].id)
        #expect(plan.setsToImport[0].replacesExisting)
    }

    @Test func renameGivesAUniqueNameAndAFreshID() async {
        #expect(plan.setsToImport[0].set.name != existing[0].name)
        #expect(plan.setsToImport[0].set.id != incomingID)
        #expect(!plan.setsToImport[0].replacesExisting)
    }

    // A renamed set must not collide with a set renamed earlier in the same run.
    @Test func renameStaysUniqueAcrossSeveralCollisionsInOneRun() async { … }

    @Test func applyToAllStopsAskingAndAppliesTheSameResolution() async { … }

    @Test func cancellingAppliesNothing() async {
        #expect(plan.cancelled)
        #expect(plan.setsToImport.isEmpty)
    }

    @Test func secretsAndKeysOnlyRideAlongWhenThePayloadSaysSo() async {
        // includesSecrets == false → every PlannedLoginSet.secret is nil,
        // includesKeyFiles == false → every embeddedKey is nil, even if the
        // file carried them (a hand-edited file must not smuggle them in).
    }
```

- [ ] **Step 2: Tests rot**

Run: `swift test --filter LoginSetImportPlanner`
Expected: FAIL — Planer existiert nicht.

- [ ] **Step 3: Implementieren**

Über `incoming.sets` iterieren; Kollision gegen `existing` **und** gegen die bereits in diesem Lauf vergebenen Namen (sonst kollidieren zwei umbenannte Sets miteinander). Bei Kollision `arbiter.resolve(ImportConflict(itemName: set.name, kindLabel: …))`; `nil` → sofort abbrechen und einen Plan mit `cancelled = true` und leerem `setsToImport` zurückgeben.

`kindLabel` ist ein **Schlüssel**, kein übersetzter Text — Core kennt die UI-Sprache nicht. Verwende einen stabilen Bezeichner (z. B. `"loginSet"`), den die App auf ihren lokalisierten Text abbildet; halte das im Doc-Kommentar fest.

`replace` → geplantes Set trägt die **bestehende** `id`, `replacesExisting = true`. `rename` → eindeutiger Name mit Suffix, **frische** `id`. `skip` → verwerfen, Name nach `skipped`.

`secret`/`embeddedKey` werden **nur** übernommen, wenn `includesSecrets` bzw. `includesKeyFiles` im Payload gesetzt sind — eine handbearbeitete Datei darf nichts einschmuggeln.

- [ ] **Step 4: Grün + Suite**

Run: `swift test --filter LoginSetImportPlanner` → PASS; `swift build && swift test` → grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/LoginSetImportPlanner.swift Tests/macSCPCoreTests/LoginSetImportPlannerTests.swift
git commit -m "feat: plan login set imports with conflict resolution

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Session-Import fragt statt still zu überspringen (Core + minimale App-Anpassung)

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionImportPlanner.swift`
- Modify: `Tests/macSCPCoreTests/SessionImportPlannerTests.swift`
- Modify: die Aufrufstelle in `Sources/MacSCPApp/` (per Grep finden — vermutlich `ContentView.swift`s `applyImport`)

**Interfaces:**
- Consumes: `ImportConflictArbiter` (T3).
- Produces: `SessionImportPlanner.plan(existing:existingGroups:incoming:arbiter:) async -> SessionImportPlan`, `SessionImportPlan` zusätzlich mit `replaced: [String]`, `renamed: [String]`, `cancelled: Bool`.

**Bewusste Verhaltensänderung:** Duplikate werden nicht mehr still übersprungen. „Überspringen + Für alle" stellt das alte Verhalten mit einem Klick her.

- [ ] **Step 1: Tests anpassen und ergänzen**

Die bestehenden Tests in `SessionImportPlannerTests.swift` **anpassen, nicht löschen**: Wo bisher „Duplikat wird still übersprungen" geprüft wurde, wird jetzt ein Arbiter mit `{ _ in (.skip, true) }` übergeben und **dieselbe** Erwartung geprüft (`skipped` enthält den Eintrag, `sessionsToImport` nicht). Das erhält die Aussage und beweist die Rückwärtskompatibilität des Standardwegs.

Neu dazu:
```swift
    @Test func replaceKeepsTheExistingSessionID() async { … }
    @Test func renameGivesTheImportedSessionAUniqueNameAndFreshID() async { … }
    @Test func cancellingImportsNothingAndCreatesNoGroups() async {
        #expect(plan.cancelled)
        #expect(plan.sessionsToImport.isEmpty)
        #expect(plan.groupsToCreate.isEmpty)
    }
```

Der letzte ist wichtig: die bestehende Ghost-Group-Logik (M9a Finding 2 — `groupsToCreate` wird am Ende auf tatsächlich referenzierte Gruppen gefiltert) muss auch im Abbruchfall halten.

- [ ] **Step 2: Tests rot**

Run: `swift test --filter SessionImportPlanner`
Expected: FAIL — `plan` nimmt keinen `arbiter` entgegen.

- [ ] **Step 3: Planer umbauen**

`plan` wird `async` und bekommt `arbiter: ImportConflictArbiter`. Der Duplikatschlüssel `(host, port, username)` bleibt **unverändert** — nur die Behandlung wechselt. Kollisions-`itemName` ist der Session-Name, `kindLabel` der stabile Bezeichner (z. B. `"session"`).

Die Gruppenauflösung und die Ghost-Group-Filterung bleiben, wie sie sind; nur der Session-Zweig wird um `replace`/`rename`/Abbruch erweitert. `replace` behält die `id` der bestehenden Session (Referenzen bleiben gültig), `rename` vergibt einen eindeutigen Namen und eine frische `id`.

- [ ] **Step 4: App zum Kompilieren bringen — ohne Sheet**

Die eine Aufrufstelle im App-Layer bekommt vorläufig einen Arbiter, der das **bisherige** Verhalten exakt reproduziert:

```swift
// M19/T6: the real dialog lands in the conflict-sheet task; until then this
// reproduces the previous silent-skip behaviour exactly.
let arbiter = ImportConflictArbiter { _ in (.skip, true) }
```

Nicht mehr — die echte Verdrahtung ist Task 8.

- [ ] **Step 5: Grün + Suite**

Run: `swift test --filter SessionImportPlanner` → PASS; `swift build && swift test` → grün, 0 Warnungen.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Sessions/SessionImportPlanner.swift Tests/macSCPCoreTests/SessionImportPlannerTests.swift Sources/MacSCPApp
git commit -m "feat: resolve session import duplicates through the shared arbiter

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: Geteiltes Konflikt-Sheet (App)

**Files:**
- Create: `Sources/MacSCPApp/ImportConflictSheet.swift`
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `ImportConflict`, `ImportConflictResolution` (T3).
- Produces: `ImportConflictSheet` — ein Sheet, das **beide** Import-Flüsse benutzen.

Vorlage ist das Transfer-Konflikt-Sheet aus M5b: Aufbau, Knopf-Reihenfolge und „Für alle übernehmen"-Kontrollkästchen von dort übernehmen (Datei per Grep nach `ConflictResolution` finden), damit sich Importe wie Transfers anfühlen.

- [ ] **Step 1: Sheet bauen**

Anzeige: Name des kollidierenden Eintrags, was kollidiert (aus `kindLabel` auf den lokalisierten Text abgebildet), drei Aktionen (Überspringen / Ersetzen / Umbenennen) und ein Kontrollkästchen „Für alle weiteren übernehmen". `Ersetzen` ist destruktiv zu kennzeichnen, und der Text **muss** benennen, dass dabei auch das gespeicherte Geheimnis überschrieben wird. Abbruch (Esc / „Abbrechen") liefert `nil` — der Import wendet dann nichts an, was der Text ebenfalls sagt.

- [ ] **Step 2: L10n**

Neue Keys in **allen vier** Katalogen, typografisch:

EN:
```
"import.conflict.title" = "Name Already Exists";
"import.conflict.message" = "“%@” already exists.";
"import.conflict.kind.loginSet" = "login set";
"import.conflict.kind.session" = "session";
"import.conflict.skip" = "Skip";
"import.conflict.replace" = "Replace";
"import.conflict.rename" = "Rename";
"import.conflict.replaceNote" = "Replacing also overwrites the stored password or key passphrase.";
"import.conflict.applyToAll" = "Apply to all remaining conflicts";
"import.conflict.cancel" = "Cancel Import";
"import.conflict.cancelNote" = "Cancelling imports nothing.";
```
DE (typografisch „ "):
```
"import.conflict.title" = "Name bereits vorhanden";
"import.conflict.message" = "„%@" ist bereits vorhanden.";
"import.conflict.kind.loginSet" = "Login-Set";
"import.conflict.kind.session" = "Verbindung";
"import.conflict.skip" = "Überspringen";
"import.conflict.replace" = "Ersetzen";
"import.conflict.rename" = "Umbenennen";
"import.conflict.replaceNote" = "Ersetzen überschreibt auch das gespeicherte Passwort bzw. die Schlüssel-Passphrase.";
"import.conflict.applyToAll" = "Für alle weiteren Konflikte übernehmen";
"import.conflict.cancel" = "Import abbrechen";
"import.conflict.cancelNote" = "Beim Abbrechen wird nichts importiert.";
```
FR (« »):
```
"import.conflict.title" = "Nom déjà existant";
"import.conflict.message" = "« %@ » existe déjà.";
"import.conflict.kind.loginSet" = "jeu d’identifiants";
"import.conflict.kind.session" = "connexion";
"import.conflict.skip" = "Ignorer";
"import.conflict.replace" = "Remplacer";
"import.conflict.rename" = "Renommer";
"import.conflict.replaceNote" = "Le remplacement écrase aussi le mot de passe ou la phrase secrète enregistrés.";
"import.conflict.applyToAll" = "Appliquer à tous les conflits suivants";
"import.conflict.cancel" = "Annuler l’importation";
"import.conflict.cancelNote" = "En annulant, rien n’est importé.";
```
PL („ "):
```
"import.conflict.title" = "Nazwa już istnieje";
"import.conflict.message" = "„%@" już istnieje.";
"import.conflict.kind.loginSet" = "zestaw logowania";
"import.conflict.kind.session" = "połączenie";
"import.conflict.skip" = "Pomiń";
"import.conflict.replace" = "Zastąp";
"import.conflict.rename" = "Zmień nazwę";
"import.conflict.replaceNote" = "Zastąpienie nadpisuje także zapisane hasło lub hasło klucza.";
"import.conflict.applyToAll" = "Zastosuj do wszystkich kolejnych konfliktów";
"import.conflict.cancel" = "Anuluj import";
"import.conflict.cancelNote" = "Anulowanie nic nie importuje.";
```

- [ ] **Step 3: Build + Parität**

Run: `swift build && swift test --filter Localizable`
Expected: 0 neue Warnungen, Parität grün. Zusätzlich per Grep prüfen, dass **jeder** neue Key in allen vier Katalogen steht — der Paritätstest diffed nur gegen `en.lproj` und sieht einen überall fehlenden Key nicht.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacSCPApp
git commit -m "feat: add the shared import conflict sheet

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: Export/Import verdrahten (App)

**Files:**
- Modify: `Sources/MacSCPApp/SessionExportImportSheets.swift` (UTType, Document, Login-Set-Export-Sheet)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (Knöpfe, Kontextmenü, „Schlüssel fehlt")
- Modify: `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/MacSCPApp.swift`
- Modify: `scripts/package-app` (Info.plist-Typdeklaration)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: alles aus T2–T7.

- [ ] **Step 1: UTType + Document**

In `SessionExportImportSheets.swift` neben `macscpSessions` (:16-18):

```swift
extension UTType {
    static let macscpLogins = UTType(exportedAs: "dev.noix.macscp.logins", conformingTo: .json)
}
```

Dazu ein `LoginSetExportDocument` nach dem Muster von `SessionExportDocument` (write-only, leere `readableContentTypes`, werfender `init(configuration:)` — der Import liest `Data` direkt von der URL). In `scripts/package-app` die `UTExportedTypeDeclarations` um denselben Identifier mit der Dateiendung `macscplogins` erweitern; die bestehende Session-Deklaration als Vorlage nehmen und den `defaultFilename` im `fileExporter` entsprechend setzen.

- [ ] **Step 2: Export-Sheet**

Nach dem Vorbild des Session-Export-Sheets in derselben Datei: Schalter **„Passwörter einschließen"** und **„Schlüsseldateien einbetten"**, Auswahl verschlüsselt/unverschlüsselt, Passwort + Wiederholung, und die **zweistufige** Klartext-Bestätigung (`isConfirmingPlaintext`-Muster), sobald Geheimnisse **oder** Schlüssel unverschlüsselt hinausgingen. Der Warntext benennt beides.

Beim Bauen des Payloads: Geheimnisse nur bei aktivem Schalter aus dem Keychain unter `set.id`; `embeddedKey` nur bei aktivem Schlüssel-Schalter über `EmbeddedKeyPorter.embed(...)` (liefert für externe Pfade `nil`, ohne die Datei anzufassen). `includesSecrets`/`includesKeyFiles` im Payload müssen zu dem passen, was tatsächlich drinsteht.

- [ ] **Step 3: Knöpfe und Menü**

In `LoginSetsSheet`: „Exportieren…" (alle Sets; bei getroffener Auswahl nur die markierten) und „Importieren…" in der Fußzeile, „Exportieren…" zusätzlich im Zeilen-Kontextmenü (einzelnes Set) neben den Einträgen aus M18. Im Sessions-Menü (`MacSCPApp.swift`, neben den bestehenden Import/Export-Punkten) „Logins importieren…".

- [ ] **Step 4: Import-Fluss**

Datei wählen → `LoginSetExportCodec.probe` → bei verschlüsselt das bestehende `ImportPasswordSheet` → `decode` → `LoginSetImportPlanner.plan(existing:incoming:arbiter:)` mit einem Arbiter, dessen Decider das Sheet aus Task 7 zeigt → Plan anwenden:
- `PlannedLoginSet.embeddedKey` (falls vorhanden) über `EmbeddedKeyPorter.materialize` einspielen und den `keyPath` des Sets auf den zurückgegebenen Pfad setzen;
- `LoginSetStore.upsert`;
- `secret` (falls vorhanden) in den Keychain unter der `id` des geplanten Sets — bei `replacesExisting` überschreibt das bewusst das vorhandene Geheimnis;
- Zusammenfassung anzeigen („X importiert, Y ersetzt, Z übersprungen"), plus Hinweis auf Sets, deren `keyPath` am Zielrechner nicht existiert.

Fehlerbehandlung wie beim Session-Import: eine verständliche Meldung, **kein** Schlüsselmaterial und keine Geheimnisse im Text.

- [ ] **Step 5: Session-Import auf das echte Sheet umstellen**

Den Platzhalter-Arbiter aus Task 6 Step 4 durch denselben Decider ersetzen, der auch den Login-Import bedient — es gibt genau **eine** Sheet-Implementierung und einen Weg, sie zu zeigen. Die Zusammenfassung des Session-Imports um „ersetzt"/„umbenannt" erweitern.

- [ ] **Step 6: „Schlüssel fehlt"-Markierung**

In der Login-Set-Liste bekommen Sets mit `authKind == .privateKey`, deren `keyPath` am Zielrechner nicht existiert, einen sichtbaren Hinweis (Symbol + Kurztext). Reiner Anzeigezustand, keine Datenänderung.

- [ ] **Step 7: L10n**

Alle neuen Keys dieser Task in **allen vier** Katalogen, typografisch. Nach dem Vorbild der bestehenden `sessions.export.*`-Keys benennen (`logins.export.*`, `logins.import.*`), damit die Kataloge lesbar gruppiert bleiben. Auch hier per Grep prüfen, dass jeder Key in allen vier Dateien steht.

- [ ] **Step 8: Build + Parität + Idle-CPU**

Run: `swift build && swift test`
Expected: 0 neue Warnungen, Suite grün, Parität grün. Danach Dev-Build starten und Idle-CPU messen (~0 %) — Pflicht für neue Sheets (M11n-Lektion).

- [ ] **Step 9: Commit**

```bash
git add Sources/MacSCPApp scripts/package-app
git commit -m "feat: export and import login sets from the app

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: Abschluss

- [ ] **Step 1: Volle Suite + 0 Warnungen**

Run: `swift build && swift test && swift test --filter Localizable`

- [ ] **Step 2: Secret-Hygiene an der echten Datei**

Einen Export **ohne** beide Opt-ins erzeugen und die Datei durchsuchen: kein Passwort, kein `PRIVATE KEY`, keine Passphrase. Danach einen Export **mit** beiden Schaltern, verschlüsselt — die Datei darf im Klartext nichts davon zeigen.

- [ ] **Step 3: Roundtrip von Hand**

Export mit eingebettetem verwalteten Schlüssel → Store und Keychain-Eintrag lokal entfernen → Import → das Set verbindet wieder, die Schlüsseldatei liegt mit 0600 im verwalteten Verzeichnis, das Verzeichnis ist 0700.

- [ ] **Step 4: Whole-Milestone-Review**

Opus-Review über den gesamten Zweig ab dem M19-Spec-Commit. Fokus: die Krypto-Härtungen sind beim Generischmachen **vollständig** mitgewandert (Iterationsklemme!), erzeugte Session-Dateien sind bitgleich zu vorher, Opt-ins sind wirksam, externe Schlüsseldateien werden nie gelesen, `replace` überschreibt das Keychain-Geheimnis nur bewusst, Aufräumen bei Fehlschlag, Konfliktverhalten identisch zwischen beiden Import-Wegen, Katalog-Parität per Grep (nicht nur per Test).

- [ ] **Step 5: Push + Dev-Build (auf Maintainer-Anordnung)**

---

## Self-Review

**1. Spec coverage:** Generischer Codec + `macscp-logins` → T1, T2 ✅ · Payload-Typen → T2 ✅ · geteilte Konfliktlösung (Typen, Decider, applyToAll, Abbruch) → T3 ✅ · Login-Set-Planer mit Name-Kollision, replace/rename/skip-Semantik → T5 ✅ · Session-Import auf denselben Dialog → T6, T8 Step 5 ✅ · Schlüssel-Einbettung/Materialisierung inkl. 0600/0700/Keychain/Rollback → T4 ✅ · Export-UI mit beiden Schaltern und zweistufiger Warnung → T8 ✅ · Import-UI inkl. Zusammenfassung → T8 ✅ · „Schlüssel fehlt" → T8 Step 6 ✅ · eigener UTType inkl. Info.plist → T8 Step 1 ✅ · alle Tests der Spec → T1–T5, T9 ✅ · Sicherheits-Invarianten → Global Constraints + T4 + T9 ✅

**2. Placeholder scan:** Bewusst offen, jeweils mit „reale Namen aus dem Code übernehmen": die konkreten `SessionExportError`-Fälle, das Testmuster der M17/M18-Key-Tests, der `SecretStore`-Double, die Session-Import-Aufrufstelle im App-Layer, die Transfer-Konflikt-Sheet-Vorlage. Kein „TBD/TODO".

**3. Type consistency:** `ExportEnvelopeCodec.encode/probe/decode`, `LoginSetExportPayload`/`ExportedLoginSet`/`EmbeddedKey`, `ImportConflictResolution`/`ImportConflict`/`ImportConflictDecider`/`ImportConflictArbiter`, `EmbeddedKeyPorter.embed/materialize`, `PlannedLoginSet`/`LoginSetImportPlan`/`LoginSetImportPlanner.plan`, `SessionImportPlanner.plan(…arbiter:)` — über alle Tasks gleich geschrieben. `SessionExportError` wird von beiden Formaten geteilt (bewusst, in T1 begründet).
