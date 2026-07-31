# M9a — Import/Export von Verbindungen (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben (Blöcke 1+2 einzeln bestätigt)

## Ziel

Verbindungen (einzeln, pro Gruppe oder alle) über das Sidebar-Kontextmenü in
eine versionierte `.macscpsessions`-Datei exportieren und additiv wieder
importieren — wahlweise verschlüsselt, mit optionalen Passwörtern und
Dubletten-Erkennung.

**Maintainer-Entscheidungen (2026-07-28):**

1. Passwörter: optional AUCH im unverschlüsselten Export (Checkbox, Default
   AUS, roter Warnhinweis + Extra-Bestätigung beim Klartext-Fall).
   Key-DATEIEN werden nie exportiert, nur der Pfad-Verweis.
2. Dubletten: Tripel Host+Port+Username (Anzeigename egal, interne IDs egal);
   Dubletten werden übersprungen, Ergebnis-Dialog berichtet die Zahlen.
3. UI: Kontextmenü-Einträge (Session „Exportieren…", Gruppe „Gruppe
   exportieren…", Hintergrund „Alle exportieren…" + „Importieren…");
   Gruppenzuordnung als Toggle im Export-Sheet.
4. Technik: Ansatz A — eigenes JSON-Envelope-Format, CryptoKit AES-GCM +
   PBKDF2 (CommonCrypto), KEINE neuen Dependencies.

## 1. Dateiformat `.macscpsessions`

JSON-Umschlag, versioniert (Muster sessions.json):

```json
{
  "format": "macscp-sessions",
  "version": 1,
  "encrypted": false,
  "payload": { … }                     // Klartext-Fall
}
```

Verschlüsselter Fall statt `payload`:

```json
{
  "format": "macscp-sessions",
  "version": 1,
  "encrypted": true,
  "salt": "<Base64, 16 zufällige Bytes>",
  "iterations": 600000,
  "ciphertext": "<Base64, AES-GCM SealedBox combined über das serialisierte Payload-JSON>"
}
```

- Schlüsselableitung: PBKDF2-HMAC-SHA256 (CommonCrypto), 600 000 Iterationen
  (Wert steht in der Datei — spätere Erhöhung bricht alte Dateien nicht),
  256-Bit-Schlüssel.
- AES-GCM (CryptoKit) authentifiziert: falsches Passwort und manipulierte
  Datei sind vom Codec nicht unterscheidbar und enden im selben definierten
  Fehler (bewusst, keine Orakel-Unterscheidung).
- `version` > 1 beim Import ⇒ klarer Abbruch („Datei stammt aus einer
  neueren macSCP-Version").

Payload:

```json
{
  "includesSecrets": true,
  "groups":   [ { "id": "<UUID>", "name": "Prod" } ],
  "sessions": [ {
      "id": "<UUID>",                  // nur zur Gruppen-Referenz innerhalb der Datei
      "name": "web-01", "host": "…", "port": 22, "username": "…",
      "authKind": "password" | "privateKey",
      "keyPath": "<Pfad oder null>",
      "groupID": "<UUID oder null>",
      "password": "<String oder fehlend>"   // nur wenn includesSecrets
  } ]
}
```

- `groups` enthält nur Gruppen, auf die exportierte Sessions verweisen, und
  nur, wenn der Gruppen-Toggle an war (sonst leer + `groupID: null` überall).
- Passwörter, die im Keychain fehlen, werden ausgelassen; der Export-Bericht
  zählt sie („ohne Passwort exportiert: n").

## 2. Core-Einheiten (rein, unit-testbar)

### 2.1 SessionExportCodec

`Sources/macSCPCore/Sessions/SessionExportCodec.swift`

- `encode(_ payload: SessionExportPayload, password: String?) throws -> Data`
  — `password == nil` ⇒ Klartext-Umschlag, sonst verschlüsselt.
- `decode(_ data: Data, password: String?) throws -> SessionExportPayload`
  — typisierte Fehler: `notAnExportFile`, `unsupportedVersion(Int)`,
  `passwordRequired`, `wrongPasswordOrCorrupted`.
- `probe(_ data: Data) throws -> Bool` (ist verschlüsselt?) — damit die UI
  weiß, ob ein Passwort-Sheet nötig ist, ohne zu entschlüsseln.

### 2.2 SessionImportPlanner

`Sources/macSCPCore/Sessions/SessionImportPlanner.swift`

- `plan(existing: [StoredSession], existingGroups: [StoredGroup], incoming: SessionExportPayload) -> SessionImportPlan`
- Regeln:
  - Dublette ⇔ gleiches Tripel (host, port, username) gegen BESTAND —
    case-sensitiv beim Username, Host normalisiert wie der KnownHostsStore
    (lowercase); Dubletten landen in `skipped`.
  - Auch INNERHALB der Datei werden Tripel-Dubletten dedupliziert
    (keep-first, wie der ssh-config-Import).
  - Gruppen: Match gegen bestehende per NAME (exakt); fehlende Gruppen
    werden als anzulegende geführt; Sessions referenzieren das Ergebnis.
  - Jede zu importierende Session bekommt eine FRISCHE UUID; das Passwort
    (falls im Payload) hängt am Plan-Eintrag und wird unter der neuen ID
    gespeichert.
- `SessionImportPlan`: `groupsToCreate`, `sessionsToImport`
  (inkl. optionalem Passwort je Eintrag), `skipped` (fürs Reporting).

### 2.3 VM-Integration

`SessionListViewModel` erhält:

- `exportPayload(for scope: ExportScope, includeGroups: Bool, includePasswords: Bool) -> (payload: SessionExportPayload, missingPasswordCount: Int)`
  — `ExportScope`: `.single(StoredSession)`, `.group(StoredGroup)`, `.all`.
  Passwörter via bestehendem `password(for:)` (Keychain).
- `applyImport(_ plan: SessionImportPlan) -> SessionImportResult` — legt
  Gruppen + Sessions an (Store), speichert Passwörter (SecretStore);
  Keychain-Fehler brechen NICHT ab: Session wird trotzdem angelegt,
  `passwordFailures` zählt. `SessionImportResult`: importiert / übersprungen /
  Passwörter übernommen / Passwort-Fehler.
- Import ist ADDITIV: bestehende Sessions/Gruppen werden nie verändert oder
  überschrieben.

## 3. UI (App-Layer)

### 3.1 Export

- Kontextmenü-Einträge (Keys EN/DE): Session „Export…", Gruppe „Export
  Group…", Hintergrund „Export All…" (gedimmt bei 0 Sessions) —
  alle öffnen DASSELBE Export-Sheet mit vorbelegtem Scope.
- Export-Sheet: Zusammenfassung („n Verbindungen"), Toggle „Gruppenzuordnung
  mitnehmen" (Default AN, ausgeblendet/irrelevant bei Scope ohne Gruppen),
  Toggle „Passwörter einschließen" (Default AUS), Auswahl
  „Verschlüsselt/Unverschlüsselt":
  - Verschlüsselt: zwei SecureFields (Passwort + Wiederholung); Export-Button
    erst aktiv bei Übereinstimmung und ≥ 1 Zeichen; Hinweis, ein langes
    Passwort zu wählen.
  - Unverschlüsselt UND Passwörter an: roter Warnblock („Passwörter liegen
    dann im Klartext in der Datei") + der Button verlangt eine zusätzliche
    Bestätigung (zweistufig: „Trotzdem exportieren…").
- Danach nativer Speichern-Dialog (`fileExporter`), eigener UTType
  `dev.noix.macscp.sessions` (Endung `.macscpsessions`, in Info.plist
  deklariert). Nach Erfolg kurzer Ergebnis-Hinweis inkl.
  `missingPasswordCount`, falls > 0.

### 3.2 Import

- Hintergrund-Menü „Import…" → `fileImporter` → `probe`:
  - verschlüsselt ⇒ Passwort-Sheet; falsches Passwort zeigt die Meldung im
    Sheet, beliebig viele Versuche, Abbrechen möglich.
- Planner → `applyImport` → Ergebnis-Dialog: „X importiert, Y als Dublette
  übersprungen, Z Passwörter übernommen" + ggf. Passwort-Fehler-Zeile + ggf.
  Hinweis „Die Datei enthielt unverschlüsselte Passwörter."
- Sidebar refresht; KEIN Auto-Connect.

### 3.3 Fehlerfälle

- `notAnExportFile`/`unsupportedVersion`: Alert mit klarer Meldung.
- `wrongPasswordOrCorrupted`: im Passwort-Sheet inline.
- Leerer Scope: Menüpunkt gedimmt.
- Schreibfehler beim Export (Disk): Alert mit lokalisierter Fehlermeldung.

## 4. Tests

- Codec: Roundtrip klar + verschlüsselt (inkl. Umlaute/Emoji im Passwort und
  im Payload), falsches Passwort ⇒ `wrongPasswordOrCorrupted`, EIN geflipptes
  Ciphertext-Byte ⇒ derselbe Fehler, `probe` beide Fälle, Versions-Gate,
  `passwordRequired` (encrypted ohne Passwort dekodiert), `includesSecrets`-
  Flag konsistent.
- Planner: Tripel-Dublette trotz anderem Namen; Host-Case-Normalisierung;
  In-Datei-Dubletten keep-first; Gruppen-Match per Name vs. Neuanlage;
  frische UUIDs (≠ Datei-IDs, ≠ Bestand); Passwort-Durchreichung.
- VM: `applyImport` mit Mock-SecretStore (inkl. injiziertem Keychain-Fehler
  ⇒ Session trotzdem da, Zähler stimmt); `exportPayload`-Scopes + Zähler.
- UI: visueller Smoke (T4-Checkliste im Plan).

## 5. Bewusst NICHT in M9a

- Kein Merge/Überschreiben bestehender Sessions beim Import (nur additiv).
- Kein Export der Key-Dateien; keine Passphrase-Extraktion aus dem ssh-agent.
- Kein Fremdformat-Import (PuTTY/WinSCP/Termius) — Backlog-Kandidat.
- Keine iCloud-/Sync-Mechanik.
