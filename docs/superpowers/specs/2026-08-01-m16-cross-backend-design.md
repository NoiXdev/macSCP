# M16 — Cross-Backend-Transfer S3↔SSH (Design/Spec)

**Datum:** 2026-08-01
**Status:** freigegeben (Brainstorm), bereit für writing-plans
**Branch:** `develop`
**Vorgänger:** M8b (Cross-Session-Transfer), M12–M15 (S3-Backend + Login-Sets).

## Ziel

S3↔SSH-Transfers in beide Richtungen gated verifizieren und die UI so
erweitern, dass Cross-Backend-Transfers sichtbar werden (Ziel-Session +
Backend-Kennzeichnung, passive Warnung bei S3-Zielen ohne Resume). Die
Transfer-Engine bleibt unverändert — sie ist bereits backend-agnostisch.

## Ausgangslage (verifiziert)

Die Erkundung des Cross-Session-Pfads (M8b) ergab: `TransferEngine.copyFile`
(`Sources/macSCPCore/RemoteFS/TransferEngine.swift:93-189`) liest/schreibt
**rein über das `RemoteFileSystem`-Protokoll** — kein `if S3`, kein
`as? CitadelFileSystem`/`as? S3FileSystem`. Die gesamte M8b-Verkabelung
(`ContentView.transferToSession` ~2596, `TransferQueueViewModel` crossRemote-
Zweig ~825, `BandwidthLimiter`, `TabsViewModel`) ist reine Protokoll-
Delegation. Ordner-Rekursion (`expandTree` ~1044, S3-0-Byte-Marker in
`S3ListParser` versteckt), Resume-Guard (`effectiveResume` ~108, S3-Ziel →
Overwrite), stat/Konflikt (~944) und Größe/Fortschritt (~101) laufen alle
generisch. **S3↔SSH kopiert technisch bereits durch.**

Zwei echte Lücken:
1. **Test:** Kein gated S3↔SSH-Integrationstest (nur SSH↔SSH aus M8b,
   `CitadelFileSystemIntegrationTests.swift:1195`). Das Rig kann es —
   `docker/test-server/compose.yml` startet sshd:2222, sshd2:2223,
   minio:19000/19001 gemeinsam, gemeinsames Gate `MACSCP_ITEST=1`.
2. **UI-Transparenz:** `TransferQueueBar.row(_:)` zeigt nur Pfeil + Dateiname
   + Status — keine Ziel-/Backend-Kennzeichnung, keine Resume-Warnung. Der
   Queue-`Item` (`TransferQueueViewModel.swift:49`) trägt nur `destinationTabID`
   (opak), keinen Ziel-Namen/Backend.

## Entscheidungen (Maintainer, 2026-08-01)

- **Scope:** primär Verifikation + Härtung + UI-Transparenz; keine neue
  Engine-Mechanik. UI-Verbesserungen: alle drei (Ziel/Backend im Eintrag,
  Resume-Warnung, besseres Ziel-Submenü), aber **schlank** gebaut.
- **Resume-Warnung:** **passiver Hinweis** am Transfer-Eintrag (⚠-Symbol +
  Tooltip), kein Bestätigungsdialog.

## Architektur

### 1. Gated S3↔SSH-Test + Härtung (Tests)

Neuer gated Test (`Tests/macSCPCoreTests/`, Suite mit
`.enabled(if: ProcessInfo…["MACSCP_ITEST"] == "1")`, nutzt die bestehende
Compose-Datei, connectet S3 auf 19000 und Citadel auf 2222 gleichzeitig):

- **SSH→S3:** Datei auf sshd → `TransferEngine.copyFile(source: Citadel,
  destination: S3)` → Objekt in MinIO byte-identisch (Range-GET zurücklesen).
- **S3→SSH:** Objekt in MinIO → `copyFile(source: S3, destination: Citadel)`
  → Datei auf sshd byte-identisch.
- **Ordner-Baum cross-backend** (min. eine Richtung): rekursiver Transfer
  eines Verzeichnisses (Unterordner + Datei); prüft, dass S3-„Ordner"
  (0-Byte-Marker/CommonPrefix) als `.directory` erkannt und via
  `createDirectory` auf der Gegenseite angelegt werden.
- **Resume-Guard:** SSH→S3 mit gesetztem `resume` bekommt `.overwrite` (nie
  `.append`) — beweist den M13-Guard live über die Backend-Grenze.

Härtung: Deckt die kniffligen Fälle ab (S3-Marker-Ordner, Resume-Guard,
stat/Konflikt auf S3-Ziel). Deckt der Live-Test einen Bug auf (wie der
M13-Trailing-Slash-Fund, den nur echtes MinIO fand), wird er in M16 gefixt.

### 2. Cross-Backend-Metadaten im Queue-`Item` (Core)

Additiv zu `Item` (und `Job`, gleich gefädelt wie `destinationTabID`/
`crossRemote`/`isEditUpload`):

```swift
/// Whether the destination backend supports append-based resume (M16). Set
/// at enqueue from `destination.supportsAppendResume`; false for an S3
/// destination. Drives the passive resume warning in the transfer row.
public let destinationSupportsResume: Bool   // default true

/// Cross-backend target label (M16): the destination session's display name
/// + protocol kind, set only for cross-remote transfers (nil for
/// same-session). The queue holds only the opaque destinationTabID, so the
/// App supplies this at enqueue.
public let crossBackendTarget: CrossBackendTarget?   // default nil
```

Neuer Core-Wert:

```swift
public struct CrossBackendTarget: Equatable, Sendable {
    public var name: String
    public var kind: ConnectionKind
}
```

- `destinationSupportsResume`: **kein** neuer Aufrufer-Parameter — die Queue
  liest `destination.supportsAppendResume` beim `Item`-/`Job`-Bau selbst.
- `crossBackendTarget`: neuer optionaler `enqueue`/`enqueueTree`-Parameter
  (`crossBackendTarget: CrossBackendTarget? = nil`), gesetzt in
  `ContentView.transferToSession` (dort liegen Ziel-Session-Name und `kind`
  vor).
- Beide durch **jede** `Item`-Rekonstruktionsstelle gefädelt (retry,
  interrupt-retain) — exakt wie `isEditUpload`/`destinationDirectory` heute.

**Test (Core-Unit):**
- cross-remote enqueue auf S3-Ziel → `destinationSupportsResume == false`,
  `crossBackendTarget == CrossBackendTarget(name:…, kind: .s3)`.
- cross-remote enqueue auf SSH-Ziel → `destinationSupportsResume == true`,
  `crossBackendTarget?.kind == .ssh`.
- same-session lokal→S3-Upload → `destinationSupportsResume == false`,
  `crossBackendTarget == nil`.
- retry/interrupt-retain eines solchen Items behält beide Felder (kein
  Reset auf Default).

### 3. Transfer-Zeile — Ziel/Backend-Badge + passive Resume-Warnung (App)

`TransferQueueBar.row(_:)` (heute Pfeil + Dateiname + Status) bekommt zwei
additive, bedingte Elemente in derselben `HStack`:

- **Ziel-Badge (cross-backend):** wenn `item.crossBackendTarget != nil`, ein
  kleines Backend-Badge (`SSH`/`S3`, Small-Label-Typo wie die Sidebar-/Tab-
  Badges aus M12) + Ziel-Session-Name (z. B. `→ prod-bucket`). Same-Session-
  Transfers unverändert.
- **Passive Resume-Warnung:** wenn `item.destinationSupportsResume == false`
  **und** Status aktiv (queued/running), ein dezentes ⚠ mit Tooltip „Bei
  Abbruch startet der Upload neu". Kein Dialog, kein Klick. Verschwindet bei
  Abschluss. Gilt für jedes S3-Ziel.

Rein additiv, keine Layout-Umbauten/neuen Zeilenhöhen. Reine SwiftUI-View
(build-verifiziert + Idle-CPU-Rauchtest); die Datenlogik ist in Abschnitt 2
getestet.

**L10n:** Tooltip-String + ggf. „→"-Ziel-Präfix-Format in EN/DE/FR/PL
(typografische Zeichen, FR/PL KI-generiert). Backend-Badge-Labels „SSH"/„S3"
existieren aus M12.

### 4. Ziel-Session-Submenü verbessern (App)

Das M8b-„An Session übertragen"-Submenü (`crossSessionTargets(for:)`
~ContentView:2579 + Rendering) ergänzt:

- **Backend-Badge pro Ziel:** `CrossSessionTarget` bekommt ein `kind`-Feld
  (aus der Ziel-Session); jeder Menüeintrag zeigt `SSH`/`S3` neben dem Namen.
- **Klarere Ziel-Pfad-Anzeige:** der vorhandene `CrossSessionTarget.remotePath`
  wird im Eintrag mit angezeigt. Trägt das Menü-Widget keinen zweizeiligen
  Eintrag sauber, wird der Pfad kompakt in den Titel gefaltet
  (`prod-bucket — /uploads`).

Rein additiv, keine Verhaltensänderung am Transfer.

**L10n:** ggf. ein Format-String fürs Titel/Pfad-Zusammensetzen (EN/DE/FR/PL);
Badge-Labels aus M12.

## Sicherheit / Invarianten

- Keine Änderung an Signer/Transport/Engine-Kopierlogik — nur additive
  Metadaten + View.
- Kein `if kind == .s3`-Sonderpfad in der Kopierlogik; die Backend-Kennung im
  `Item` ist reine Anzeige-Metadaten.
- Keine neue externe Dependency.
- Resume-Guard (M13) bleibt unangetastet — der Test verifiziert ihn nur über
  die Backend-Grenze.

## Tests

- **Core-Unit:** Queue-Item-Metadaten (Abschnitt 2, vier Fälle inkl. retry).
- **Gated MinIO+sshd (`MACSCP_ITEST=1`, aus dem Haupt-Checkout):** SSH→S3,
  S3→SSH, Ordner-Baum cross-backend, Resume-Guard über die Grenze
  (Abschnitt 1).
- **Runtime-Smoke (Maintainer + Koordinator-Idle-CPU):** Transfer-Leiste mit
  Cross-Backend-Badge + Resume-⚠, Ziel-Submenü mit Backend-Badge.

## Nicht in M16

- Neue Engine-/Kopiermechanik (nicht nötig).
- Aktiver Resume-Bestätigungsdialog (bewusst verworfen — passiv gewählt).
- „Öffnen mit" S3-CLI, Verbindungs-Diagnose, SSH-Key-Manager, SSH-Terminal-
  Snippets, MCP-Server, macSCP-CLI (eigene spätere Meilensteine).

## Betroffene Dateien

- `Tests/macSCPCoreTests/…` — neuer gated S3↔SSH-Test (ggf. eigene Datei
  `CrossBackendTransferIntegrationTests.swift`); Core-Unit-Test für die
  Item-Metadaten.
- `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` — `Item`/
  `Job` um `destinationSupportsResume` + `crossBackendTarget`; `enqueue`/
  `enqueueTree` um den optionalen Parameter; alle Rekonstruktionsstellen.
- `Sources/macSCPCore/…` — neuer `CrossBackendTarget`-Typ (eigene kleine
  Datei oder bei `TransferQueueViewModel`).
- `Sources/MacSCPApp/TransferQueueBar.swift` — Ziel-Badge + Resume-⚠ in
  `row(_:)`.
- `Sources/MacSCPApp/ContentView.swift` — `transferToSession` gibt
  `crossBackendTarget` mit; `crossSessionTargets(for:)` + Submenü-Rendering
  um `kind`/Pfad.
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` —
  Tooltip + Menü-Format-Strings.
