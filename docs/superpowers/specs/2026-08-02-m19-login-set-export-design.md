# M19 — Login-Set Import/Export + einheitliche Konfliktlösung (Design/Spec)

**Datum:** 2026-08-02
**Status:** freigegeben (Brainstorm), bereit für writing-plans
**Branch:** `develop`
**Vorgänger:** M9a (Session-Export/Import), M5b (Transfer-Konfliktdialog), M10b (Login-Sets), M17 (verwaltete SSH-Schlüssel), M18 (Login-Sets-Overlay mit Suche/Kontextmenü, SSH-Keys-Sheet).

## Ziel

Login-Sets exportieren und importieren — mit optionalen Geheimnissen und
optional eingebetteten verwalteten Schlüsseln. Gleichzeitig bekommen **alle**
Import-Wege (Login-Sets **und** Sessions) denselben Konfliktdialog, damit sich
Importe überall gleich verhalten.

## Ausgangslage (verifiziert)

- **`SessionExportCodec`** (`Sources/macSCPCore/Sessions/SessionExportCodec.swift`): Envelope mit `format`/`version`/`encrypted` (`formatName = "macscp-sessions"`, `currentVersion = 1`); unverschlüsselt = Klartext-JSON, verschlüsselt = PBKDF2 (600 000 Iterationen) + AES-GCM; `probe(_:)` erkennt Verschlüsselung ohne zu entschlüsseln; gehärtet gegen manipulierte Dateien (Iterationszahl wird auf `> 0 && <= 10_000_000` geklemmt, bevor sie CommonCrypto erreicht). **Der Envelope trägt `payload: SessionExportPayload?` konkret, der Formatname ist fest verdrahtet** — nicht wiederverwendbar ohne Umbau.
- **Secrets im Session-Export:** `SessionExportPayload.includesSecrets: Bool` als Opt-in; `password`/`jumpPassword`/`s3SecretAccessKey` sind optionale Felder; die App warnt zweistufig (`isConfirmingPlaintext`) beim unverschlüsselten Export mit Geheimnissen.
- **`SessionImportPlanner`**: reine Funktion `plan(existing:existingGroups:incoming:) -> SessionImportPlan` mit `groupsToCreate`/`sessionsToImport`/`skipped`; Duplikat-Schlüssel `(host, port, username)`; Duplikate werden **still übersprungen** und nur gezählt. Keychain-Schreiben passiert erst beim `applyImport` in der App.
- **Transfer-Konfliktmuster (M5b)**: `ConflictResolution { overwrite, skip, rename }` + Entscheider-Closure `(TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?`; `applyToAll` setzt eine Regel für den Rest der Queue (`queueRule`, beim Leerlaufen zurückgesetzt). Das ist die etablierte Vorlage.
- **`LoginSet`** trägt **keine** Geheimnisse (Doku im `LoginSetStore` sagt das explizit) — sie liegen im Keychain unter `set.id`. Felder: `id`, `name`, `username`, `authKind`, `keyPath`, `kind` (ssh/s3), `accessKeyID`.
- **Verwaltete Schlüssel (M17/M18):** `ManagedKeyStore` mit `keyDirectory` (0700), Dateien 0600 unter UUID-Namen, Passphrase im Keychain unter `key.id`; `key(forPath:)` löst einen Pfad auf einen verwalteten Schlüssel auf; `SSHKeyImporter.inspect` leitet Typ/Fingerprint/Public-Key ab.
- Der Session-Import importiert Login-Sets **nie** (`loginSetID` wird immer `nil`).

## Entscheidungen (Maintainer, 2026-08-02)

1. **Geheimnisse:** Opt-in wie beim Session-Export (Standard aus; verschlüsselt bevorzugt; zweistufige Klartext-Warnung).
2. **Schlüssel:** verwaltete Schlüssel werden **eingebettet**, damit ein Set auf einem anderen Rechner sofort funktioniert.
3. **Einbett-Grenze:** **nur verwaltete** Schlüssel; externe Pfade (z. B. `~/.ssh/id_ed25519`) werden **nie gelesen**. Eigener Schalter „Schlüsseldateien einbetten" mit eigener Warnung.
4. **Import-Konflikte:** Dialog je Konflikt (Überspringen / Ersetzen / Umbenennen) **mit „Für alle übernehmen"** — und dieser Dialog gilt **einheitlich auch für den Session-Import**.

## Architektur

### 1. Generischer Codec + eigenes Format

Der Envelope-/Krypto-Teil wird über den Payload-Typ generisch und bekommt den
Formatnamen als Parameter. `SessionExportCodec` bleibt als dünne Fassade mit
**unveränderter öffentlicher API** darüber; ein `LoginSetExportCodec` kommt
daneben. Damit existiert die gehärtete Krypto **einmal** — ein künftiger Fix
wirkt an beiden Stellen. Die bestehenden Session-Codec-Tests sind der
Regressionsschutz für den Umbau.

*Verworfen:* eigener Codec als Kopie (Krypto doppelt gepflegt — bei einem Fund
wird eine Stelle vergessen); das Session-Format erweitern (vermischt zwei Dinge,
die getrennt exportiert werden).

**Format:** `format: "macscp-logins"`, `version: 1`, eigener UTType
(`macscp-logins`), damit der Öffnen-Dialog nur passende Dateien anbietet und
eine versehentlich gewählte Session-Datei klar abgewiesen wird.

**Payload:**

```swift
public struct LoginSetExportPayload: Codable, Equatable, Sendable {
    public var includesSecrets: Bool
    public var includesKeyFiles: Bool
    public var sets: [ExportedLoginSet]
}

public struct ExportedLoginSet: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ConnectionKind          // ssh | s3
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var accessKeyID: String?
    /// Only when `includesSecrets` — the set's Keychain secret at export time.
    public var secret: String?
    /// Only when `includesKeyFiles` AND the keyPath resolves to a managed key.
    public var embeddedKey: EmbeddedKey?
}

public struct EmbeddedKey: Codable, Equatable, Sendable {
    public var fileContents: Data            // the private key file
    public var name: String
    public var comment: String
    public var type: KeyType
    public var fingerprint: String
    public var hasPassphrase: Bool
    /// Only when `includesSecrets` — the managed key's Keychain passphrase.
    public var passphrase: String?
}
```

### 2. Geteilte Konfliktlösung (Core + App)

Neuer, von **beiden** Import-Wegen genutzter Baustein, nach dem Vorbild der
Transfer-Queue:

```swift
public enum ImportConflictResolution: Equatable, Sendable { case skip, replace, rename }

public struct ImportConflict: Equatable, Sendable {
    public var itemName: String          // e.g. the login set / session name
    public var kindLabel: String         // what collides, for the dialog text
}

public typealias ImportConflictDecider =
    @Sendable (ImportConflict) async -> (resolution: ImportConflictResolution, applyToAll: Bool)?
```

- `applyToAll == true` setzt die Antwort als Regel für alle weiteren Konflikte **dieses** Imports; `nil` bricht den Import ab (nichts wird angewandt).
- **Login-Set-Import:** Kollisionsschlüssel ist der **Name** (case-insensitiv, getrimmt).
- **Session-Import:** der bestehende Schlüssel `(host, port, username)` bleibt; nur die Behandlung wechselt von „still überspringen" zu „fragen". `SessionImportPlan.skipped` bleibt für die Zusammenfassung erhalten.
- **`replace`-Semantik (sicherheitsrelevant):** der vorhandene Eintrag wird überschrieben, **inklusive seines Keychain-Geheimnisses**; der Eintrag behält seine `id`, damit Sessions, die ein Login-Set referenzieren, weiter zeigen. Der Dialog benennt das ausdrücklich.
- **`rename`:** der importierte Eintrag bekommt einen eindeutigen Namen (Suffix), der vorhandene bleibt unangetastet; der importierte bekommt eine **frische `id`**.
- **`skip`:** der importierte Eintrag wird verworfen.

**Verhaltensänderung (bewusst):** Der Session-Import fragt künftig statt still zu überspringen. „Überspringen + Für alle" reproduziert das alte Verhalten mit einem Klick.

**App:** ein gemeinsames Konflikt-Sheet (Name, was kollidiert, drei Aktionen + „Für alle weiteren übernehmen"), optisch am Transfer-Konflikt-Sheet orientiert, von beiden Import-Flüssen verwendet.

### 3. Eingebettete Schlüssel

**Export:** Für Sets mit `authKind == .privateKey` prüft
`ManagedKeyStore.key(forPath:)`, ob der Pfad ein verwalteter Schlüssel ist. Nur
dann — und nur bei aktivem Schalter „Schlüsseldateien einbetten" — wird
`embeddedKey` gefüllt (Dateiinhalt + Metadaten; `passphrase` nur zusätzlich bei
aktivem Geheimnis-Schalter). **Externe Pfade werden nie gelesen.**

**Import:** Ein `embeddedKey` wird wie ein Key-Import behandelt: frische
`UUID`, Datei in `ManagedKeyStore.keyDirectory` schreiben, **0600** setzen,
Verzeichnis explizit auf **0700** härten (die Foundation-Falle aus M17/M18:
`createDirectory` härtet ein bestehendes Verzeichnis nicht nach), Metadaten in
den Store, Passphrase (falls vorhanden) in den Keychain unter der neuen Key-ID.
Der `keyPath` des importierten Sets zeigt danach auf den **neuen lokalen Pfad**.
Schlägt ein Schritt fehl, werden Datei und Keychain-Slot wieder entfernt (kein
verwaistes Artefakt) — wie beim manuellen Import.

**Ohne eingebetteten Schlüssel:** Das Set wird angelegt; existiert die Datei am
Zielrechner nicht, wird es in der Liste als **„Schlüssel fehlt"** markiert.

### 4. App-UI

**Export:** Knopf „Exportieren…" im Login-Sets-Overlay (alle Sets; bei
getroffener Auswahl nur die markierten) und „Exportieren…" im
Zeilen-Kontextmenü (einzelnes Set). Export-Sheet nach Session-Vorbild:
Schalter **„Passwörter einschließen"** + **„Schlüsseldateien einbetten"**,
Auswahl verschlüsselt/unverschlüsselt, Passwort + Wiederholung, zweistufige
Klartext-Bestätigung, sobald Geheimnisse **oder** Schlüssel unverschlüsselt
hinausgingen.

**Import:** Knopf „Importieren…" im Overlay + Menüpunkt „Logins importieren…"
im Sessions-Menü. Ablauf: Datei wählen → `probe` → ggf. Passwort-Sheet →
Planung → Konfliktdialog je Kollision → Anwenden → Zusammenfassung
(„X importiert, Y ersetzt, Z übersprungen"; plus Hinweis auf Sets mit fehlendem
Schlüssel).

## Tests

- **Codec (Core):** Roundtrip unverschlüsselt + verschlüsselt; falsches Passwort → typisierter Fehler; `macscp-sessions`-Datei als Login-Import → klare Abweisung; unbekannte Version → `unsupportedVersion`; manipulierte Iterationszahl wird abgewiesen. Die bestehenden Session-Codec-Tests laufen **unverändert** weiter (Regressionsschutz des generischen Umbaus).
- **Konfliktlösung (Core):** `skip`/`replace`/`rename` je einzeln; `applyToAll` wirkt auf alle folgenden Konflikte; `nil` bricht ab (nichts angewandt) — für **beide** Planer.
- **Secret-Hygiene:** ein Export ohne Opt-in enthält weder Geheimnisse noch Schlüsselmaterial (Prüfung an der erzeugten Datei).
- **Schlüssel-Einbettung:** Roundtrip mit verwaltetem Schlüssel — nach dem Import existiert die Datei mit 0600, ist im Store registriert, der `keyPath` zeigt darauf; ein **externer** Pfad wird nicht eingelesen.
- **App:** build-verifiziert, Katalog-Parität, Idle-CPU-Smoke.

## Sicherheit / Invarianten

- Geheimnisse und Schlüsselmaterial nur bei ausdrücklichem Opt-in im Export; unverschlüsselter Export davon nur nach zweistufiger Bestätigung.
- Externe Schlüsseldateien werden nie gelesen; `~/.ssh` bleibt schreib- und lesetabu außer bei ausdrücklicher Nutzerwahl.
- Importierte Schlüssel: 0600 / Verzeichnis 0700, Passphrase nur Keychain unter der neuen Key-ID, Aufräumen bei Fehlschlag.
- `replace` überschreibt bewusst auch das Keychain-Geheimnis — im Dialog benannt.
- Kein Schlüsselmaterial und keine Geheimnisse in Logs oder Fehlertexten.
- Keine neue externe Dependency.

## Nicht in M19

- Sammel-Übersicht statt Einzeldialogen (bewusst verworfen — bräche die Einheitlichkeit mit dem Transfer-Dialog).
- Einbetten **externer** Schlüsseldateien.
- Known-Hosts-/SSH-Key-Export als eigene Formate (SSH-Keys haben ihren eigenen Weg aus M18).

## Betroffene Dateien

- `Sources/macSCPCore/Sessions/SessionExportCodec.swift` — **modify** (generischer Envelope/Krypto-Kern, Fassade unverändert).
- `Sources/macSCPCore/Sessions/LoginSetExportCodec.swift` — **create** (Payload + Codec).
- `Sources/macSCPCore/Sessions/ImportConflict.swift` — **create** (Resolution/Conflict/Decider).
- `Sources/macSCPCore/Sessions/LoginSetImportPlanner.swift` — **create**.
- `Sources/macSCPCore/Sessions/SessionImportPlanner.swift` — **modify** (Decider statt stillem Überspringen).
- `Sources/MacSCPApp/ImportConflictSheet.swift` — **create** (geteiltes Sheet).
- `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (Export/Import-Knöpfe + Kontextmenü-Eintrag, „Schlüssel fehlt"-Markierung).
- `Sources/MacSCPApp/SessionExportImportSheets.swift` — **modify/erweitern** (Login-Set-Export-Sheet nach demselben Muster).
- `Sources/MacSCPApp/ContentView.swift`, `MacSCPApp.swift` — **modify** (fileExporter/Importer, Menüpunkt, Konflikt-Sheet-Verdrahtung für beide Importe).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
- `Tests/macSCPCoreTests/…` — Codec-, Konflikt- und Einbettungs-Tests.
