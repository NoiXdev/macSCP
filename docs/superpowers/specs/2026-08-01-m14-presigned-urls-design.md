# M14 — Presigned Share-URLs (S3) Design

**Status:** freigegeben (Brainstorming 2026-08-01)
**Meilenstein:** M14
**Sprache:** Design-Doc DE; Code/Kommentare EN; UI lokalisiert EN/DE/FR/PL.

## Ziel

Eine **zeitbegrenzte, signierte Share-URL** für ein S3-Objekt erzeugen — der in
M12 vom Maintainer gewünschte Kontextmenü-Eintrag „temporäre Share-URL". Zwei
Richtungen, beim Erstellen wählbar:
- **GET** — jemand lädt das Objekt über die URL **herunter** (der klassische
  „schick jemandem diese Datei"-Fall).
- **PUT** — jemand lädt über die URL eine Datei **hoch** (auf einen im Sheet
  editierbaren Ziel-Key).

Die URL trägt die Signatur in der Query (kein Header nötig) und läuft nach einer
wählbaren Frist ab (SigV4-Maximum **7 Tage**). Rein rechnerisch, **kein
Netzwerk** beim Erzeugen.

Dies ist die **erste echte Nutzung des M12-Contribution-Seams**: ein Backend
steuert einen protokoll-eigenen Kontextmenü-Eintrag bei, den die generische
Schicht liest, ohne den konkreten Typ zu kennen.

**Nicht in M14:** Cross-Backend-Transfer S3↔SSH (= M15); „Öffnen mit"
S3-CLI-Tool (späterer Meilenstein). **Kein Release.**

## Ausgangslage (Ist)

- `SigV4Signer` (M12/M13) kann nur **Header**-Signing (`authorizationHeader`).
  Presigned braucht **Query**-Signing — neue Methode.
- `ProtocolCapabilities.supportsPresignedURL` existiert (s3 = true, ssh = false),
  wird aber **nirgends gelesen**.
- `BackendContributions.FileActionContribution` (M12-Seam) existiert, ist aber
  in beiden Descriptors **leer** und **nicht ans Kontextmenü verdrahtet** (der
  Doc-Kommentar sagt ausdrücklich „S3 presigned URL lands in M14").
- `BrowserContextMenu.entries(…)` (Core) baut feste `BrowserMenuEntry`-Fälle;
  das App-`RemoteFileTableView` rendert sie als `NSMenu`. Kein Descriptor-
  Beitrag wird gelesen.
- `RemoteShellProvider` ist das etablierte Muster für eine **optionale**
  Backend-Fähigkeit (`as?`-Abfrage) — Vorbild für presigned.

## Architektur / Komponenten

### 1. SigV4 presigned Query-Signing (`SigV4Signer`)

Neue Methode neben `authorizationHeader`:
```swift
public func presignedQuery(
    method: String, host: String, path: String,
    expiresInSeconds: Int, date: Date
) -> [(name: String, value: String)]
```
Erzeugt die SigV4-Query-Parameter für eine presigned URL:
`X-Amz-Algorithm=AWS4-HMAC-SHA256`, `X-Amz-Credential={accessKeyID}/{scope}`,
`X-Amz-Date={amzDate}`, `X-Amz-Expires={seconds}`,
`X-Amz-SignedHeaders=host`, (bei STS zusätzlich
`X-Amz-Security-Token={sessionToken}`), zuletzt `X-Amz-Signature={sig}`.
Der Payload-Hash im Canonical Request ist `UNSIGNED-PAYLOAD`, der einzige
signierte Header ist `host`; die Canonical Query enthält alle X-Amz-*-Parameter
**außer** `X-Amz-Signature` (sortiert, RFC-3986 wie gehabt über
`canonicalQueryString`). Die HMAC-Kette / `canonicalURI` / `hexSHA256` werden
wiederverwendet (single source). Gegen den **AWS-presigned-Testvektor** gepinnt.

### 2. Optionaler Fähigkeits-Seam (`PresignedURLProvider`)

Neu `Sources/macSCPCore/RemoteFS/PresignedURLProvider.swift` (Muster wie
`RemoteShellProvider`):
```swift
public enum PresignedMethod: String, Sendable { case get = "GET", put = "PUT" }

public protocol PresignedURLProvider: Sendable {
    /// A time-limited signed URL for `key`. `.get` downloads it, `.put` uploads
    /// to it. `expiresIn` is clamped to [1s, 7 days] (SigV4 max). Pure — no I/O.
    func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL
}
```
Die App fragt `fs as? PresignedURLProvider` (kein `if kind ==`). Backends ohne
presigned konformieren nicht.

### 3. `S3FileSystem: PresignedURLProvider`

`presignedURL(method:key:expiresIn:)` baut die Objekt-URL (path- vs.
virtual-host wie in M13, über `keyRequestURL`/`canonicalKeyPath`), ruft
`signer.presignedQuery(...)` mit `expiresIn` (nach `max(1, min(604800, …))`
geklemmt) und hängt die Query an. Reines Signieren, kein `transport`-Aufruf.

### 4. Contribution-Seam ins Kontextmenü (Core)

- `BrowserMenuEntry` bekommt `case backendFileAction(FileActionContribution)`.
- `BrowserContextMenu.entries(…)` bekommt einen Parameter
  `fileActions: [FileActionContribution] = []` und hängt sie **nur bei
  einfacher Datei-Auswahl** (`selection.count == 1`, `!isDirectory`) an — z.B.
  direkt vor `copyPath`/`delete`. `BrowserKeyCommand` bleibt unberührt (kein
  Tastenkürzel).
- `s3Descriptor.fileActions` (in `BackendDescriptor.swift`) bekommt
  `FileActionContribution(id: "s3.presignedURL", titleKey:
  "browser.action.presignedURL", titleDefault: "Share Link…")`.
  `sshDescriptor.fileActions` bleibt leer.

### 5. App — Kontextmenü + Sheet (`RemoteFileTableView` / neues Sheet)

- `RemoteFileTableView`s Coordinator liest die `fileActions` des aktiven
  Remote-Backends (`BackendDescriptor.descriptor(for: activeKind).fileActions`,
  via die schon vorhandene Backend-/Descriptor-Referenz des Panes) und rendert
  `backendFileAction`-Einträge als `NSMenuItem`; Klick meldet die
  `FileActionContribution.id` + die Auswahl an einen Handler.
- Neues **Sheet** `PresignedURLSheet` (SwiftUI):
  - Segmented `PresignedMethod`: **GET (Download)** / **PUT (Upload)**.
  - Ablauf-`Picker`: 15 Min / 1 Std / 24 Std / 7 Tage — vorbelegt aus
    `settingsStore.presignedDefaultExpiry`.
  - Bei **PUT**: ein **editierbares Ziel-Key-Feld**, vorbelegt mit dem Key des
    angeklickten Objekts; Warnhinweis „überschreibt einen bestehenden Key".
  - Button „URL erzeugen" → ruft `fs.presignedURL(...)` → zeigt die URL in einem
    read-only, textauswählbaren Feld + Button **„Kopieren"** (in die
    Zwischenablage). Fehler (kein Provider / Signaturfehler) als Inline-Meldung.
- Nur sichtbar/erzeugbar, wenn das aktive Remote-Backend `PresignedURLProvider`
  ist — die Menü-Beisteuerung (via `supportsPresignedURL`-getriebenem Descriptor)
  garantiert das bereits.

### 6. Settings (`SettingsStore` + Settings-UI)

- `SettingsStore.presignedDefaultExpiry: PresignedExpiry` (Enum mit den vier
  Stufen; Codable-persistiert im bestehenden JSON-Muster, Default `.oneHour`).
- Ein Control im **Transfers**-Settings-Tab („Standard-Ablauf für Share-Links").

## Fehlerbehandlung / Sicherheit

- **Die URL IST das Geheimnis**: wer sie hat, kann in der Frist zugreifen. Sie
  wird **nur** in die Zwischenablage geschrieben — **nie geloggt, nie
  persistiert, nie in eine Fehlermeldung interpoliert**. Der Access-Key steht
  (unvermeidbar) in der URL-Query; das Secret **nie** (es fließt nur in die
  HMAC-Signatur, wie überall).
- **PUT überschreibt** den Ziel-Key ohne Rückfrage (S3-Semantik) — das Sheet
  warnt sichtbar.
- Ablauf hart auf **[1 s, 604800 s]** geklemmt (SigV4-Limit 7 Tage).
- `presignedURL` ist rein rechnerisch; ein fehlender Provider oder ein
  ungültiger Key wirft `RemoteFSError.protocolError` bzw. wird von der
  Menü-Gating verhindert.

## Tests

- **SigV4 presigned Unit** (`SigV4SignerTests`): `presignedQuery` gegen den
  dokumentierten AWS-presigned-Vektor (GET, feste Creds/Region/Datum/Expires) —
  `X-Amz-Signature` bit-gleich; die Reihenfolge/Kodierung der X-Amz-*-Parameter
  stimmt.
- **`presignedURL`-Unit** (`S3FileSystemTests`, Fake nicht nötig — rein
  rechnerisch): GET- und PUT-URL enthalten die erwarteten Query-Parameter,
  korrekten Key/Host (path- + virtual-host), `X-Amz-Expires` geklemmt (>7 Tage →
  604800), Signatur present. Kein Secret in der URL.
- **`BrowserContextMenu`-Unit**: eine einfache **Datei**-Auswahl mit
  `fileActions: [presigned]` enthält den `backendFileAction`-Eintrag; eine
  **Ordner**-/Mehrfach-Auswahl **nicht**; SSH (leere fileActions) nie.
- **GATED MinIO** (die entscheidende Prüfung, wie in M13 gelernt — Fake-Tests
  validieren die Signatur NICHT): presign **GET** eines Seed-Objekts → per
  `URLSession` GET abrufen → Bytes bit-gleich (HTTP 200). presign **PUT** auf
  einen neuen Key → per `URLSession` PUT hochladen → das Objekt erscheint in
  `list`/`stat` mit der richtigen Größe. Aufräumen. Läuft aus dem
  Haupt-Checkout.
- **Runtime-Idle-CPU-Smoke** (feste Gewohnheit seit M11n): Dev-Build starten,
  das neue Sheet öffnen (S3-Datei → „Share Link…"), Idle ~0 % CPU, GET/PUT
  umschalten ohne Spin.

## Dateien

- Ändern: `Sources/macSCPCore/S3/SigV4Signer.swift` (`presignedQuery`).
- Neu: `Sources/macSCPCore/RemoteFS/PresignedURLProvider.swift`.
- Ändern: `Sources/macSCPCore/S3/S3FileSystem.swift` (`PresignedURLProvider`-
  Konformität + `presignedURL`).
- Ändern: `Sources/macSCPCore/Presentation/BrowserContextMenu.swift`
  (`backendFileAction`-Fall + `fileActions`-Parameter).
- Ändern: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
  (`s3Descriptor.fileActions`).
- Ändern: `Sources/macSCPCore/Settings/SettingsStore.swift`
  (`presignedDefaultExpiry` + `PresignedExpiry`).
- Neu: `Sources/MacSCPApp/PresignedURLSheet.swift`.
- Ändern: `Sources/MacSCPApp/RemoteFileTableView.swift` (Menü liest
  `fileActions`, Handler öffnet das Sheet), `Sources/MacSCPApp/SettingsView.swift`
  (Ablauf-Control), `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/
  Localizable.strings`.
- Tests: `SigV4SignerTests.swift`, `S3FileSystemTests.swift`,
  `BrowserContextMenuTests.swift` (falls vorhanden, sonst neu),
  `S3FileSystemIntegrationTests.swift` (gated GET+PUT).

## Global Constraints

- Swift 6, alle Targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/Kommentare **Englisch**; UI-Strings über die vier `.strings`-Kataloge
  EN/DE/FR/PL, typografische Anführungszeichen, **kein ASCII-`"`** in
  Nicht-EN-Werten; FR/PL KI-generiert (Native-Review vor Release).
- **Keine neue Dependency** (Foundation `URLSession` nur im gated Test;
  swift-crypto via `SigV4Signer`).
- **Secret nur im Signer**, nie in Logs/JSON/URL; die erzeugte presigned URL nur
  in die Zwischenablage, nie geloggt/persistiert.
- Generischer Layer liest nur Capabilities/Contributions — **kein `if kind ==`**
  im Browser/Menü; presigned als `as? PresignedURLProvider`.
- TDD red→green; neue Logik mit Tests; **jede signier-berührende Änderung gated
  gegen echtes MinIO** (M13-Lektion). Runtime-Smoke fürs neue Sheet.
- **Kein Release.** Cross-Backend = M15; „Öffnen mit" S3-CLI = späterer
  Meilenstein.
