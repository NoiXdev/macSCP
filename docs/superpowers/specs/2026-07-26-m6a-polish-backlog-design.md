# macSCP M6a — Polish-Backlog (Design-Spec)

**Datum:** 2026-07-26
**Status:** vom Maintainer freigegeben (Block A + Block B)
**Kontext:** Erster Teil des Release-Meilensteins M6 (Aufteilung A: M6a Polish →
M6b Release). Arbeitet den kompletten offenen Ledger-Backlog ab. Nach M6a folgt
M6b (Icon, DMG, Signierung + Notarisierung, README).

## Ziel

Alle offenen Backlog-Punkte aus den M5-Reviews schließen: globales
Bandbreiten-Limit (geteilter Token-Bucket), Ordner-Abbruch im Konflikt-Dialog,
Edit-Integrations-Fixes, Formular-/Session-Aufräumarbeiten, a11y-Punkte der
neuen Formular-Optik und Code-Hygiene. Danach ist der Code release-fertig.

## Entscheidungen (Maintainer, 2026-07-26)

- Backlog-Scope: **kompletter** offener Ledger-Backlog (nicht kuratiert).
- Drossel: **geteilter Token-Bucket** pro Richtung, echte injizierbare Uhr.
- Konflikt-„Abbrechen" bei Ordner-Transfers: **bricht die ganze Gruppe ab**.
- Totes `paper`-Token: **löschen** (YAGNI), nicht als Fenstergrund einführen.
- Edit-Uploads: vom Resume-Banner **ausschließen** (kein Re-Download-Pfad).

## Block A — Verhaltensänderungen

### 1. Globaler Bandbreiten-Bucket (ersetzt die virtuelle Uhr)

- Neuer Core-Actor `BandwidthBucket`:
  - Konfiguration: `bytesPerSecond` (Rate) — Burst-Kapazität = 1 Sekunde
    Rate (Standard-Token-Bucket).
  - `consume(_ bytes: Int) async throws` — wartet (kooperativ cancelbar),
    bis genug Tokens vorhanden sind, dann Abzug. Refill kontinuierlich
    anhand der verstrichenen echten Zeit seit dem letzten Refill.
  - `setRate(bytesPerSecond: Int)` — Laufzeit-Update bei
    Settings-Änderung (vorhandenes onChange-Wiring der Queue).
  - Uhr und Schlafen injizierbar (Instant-Provider auf
    `ContinuousClock`-Basis + Sleep-Hook) → Tests deterministisch ohne
    echtes Schlafen; Default = echte Uhr/`Task.sleep`.
- `TransferEngine.copyFile`: Parameter `bytesPerSecondLimit: Int` +
  injizierter `sleep`-Hook entfallen; stattdessen `throttle:
  BandwidthBucket?` (nil = ungedrosselt). Vor jedem Chunk-Write:
  `try await throttle?.consume(chunk.count)`.
- `TransferQueueViewModel` besitzt **zwei** Buckets (Upload / Download,
  getrennte Settings wie bisher; Limit 0 ⇒ kein Bucket / nil) und reicht
  den richtungspassenden Bucket an jeden Transfer durch. Alle parallelen
  Transfers einer Richtung teilen sich damit exakt das Limit.
- Entfall ersatzlos: die virtuelle Drossel-Uhr inkl. Over-Throttling
  (real ≈ Limit/2 auf Links nahe dem Limit) und der dokumentierte
  M5d-Resume-Sonderfall („virtuelle Uhr startet bei 0") — der Bucket
  kennt nur Bytes, keine Transfer-Historie.
- Kooperative Cancellation bleibt: `consume` wirft bei Task-Cancellation;
  der bestehende Post-Write-Check bleibt das Gate.

### 2. Ordner-Abbruch im Konflikt-Dialog

- „Abbrechen" im Konflikt-Dialog eines **Gruppen-Items** (rekursiver
  Ordner-Transfer) bricht die ganze Gruppe ab:
  - Das konfliktbehaftete Item wird `.cancelled`.
  - Alle noch nicht gestarteten Items derselben Gruppe werden aus der
    Queue gefegt → `.cancelled`.
  - Bereits laufende Transfers derselben Gruppe werden kooperativ
    abgebrochen (`.cancelled`).
  - Bereits fertig kopierte Dateien bleiben liegen — es wird nichts
    gelöscht.
- Invarianten unverändert: Gruppen-`onCompleted` feuert exakt einmal,
  nachdem alle Items terminal sind; kein Item wird doppelt terminalisiert;
  exactly-once-Waiter bleiben.
- Einzeldatei-Konflikt: „Abbrechen" bricht wie bisher nur dieses Item ab.

## Block B — Fixes, a11y, Hygiene

### 3. Edit-Integration

- **Startup-Sweep:** Beim App-Start wird das Wurzelverzeichnis
  `tmp/macscp-edit/` komplett geleert (zu diesem Zeitpunkt läuft kein
  Edit; Single-Instance-App). Verwaiste Verzeichnisse von Hard-Kills
  verschwinden zuverlässig.
- **Resume-Banner:** Unterbrochene **Edit-Uploads** erscheinen nicht mehr
  im Fortsetzen-Banner (ihre Temp-Quelle löscht `stopAll` beim Trennen —
  ein Resume schlüge sichtbar fehl). Sie enden als normaler Fehler; der
  nächste Editor-Save stößt ohnehin einen frischen Upload an.
- **Lokalisierte Fehlertexte:** Das Edit-Banner zeigt statt
  `String(describing:)` einen App-Layer-Mapper: `RemoteFSError`-Fälle und
  Abbruch erhalten katalogisierte EN/DE-Texte, unbekannte Fehler einen
  generischen Text.

### 4. Formular / Session

- „Neue Verbindung" nach dem Edit-Modus leert die Felder (Reset in
  `onNew`).
- `endEditing()` / `exitEditMode()` werden zu einer Methode konsolidiert.
- Der dichte Orphan-Cleanup-Ausdruck in `SessionStore.load()` wird lesbar
  umgeschrieben. Beides reine Refaktorierungen — bestehende Tests bleiben
  unverändert grün.

### 5. a11y (M5k-Minors)

- `FormRow`-Label: `.accessibilityHidden(true)` — VoiceOver nennt jede
  Zeile nur noch einmal (Controls behalten ihre a11y-Titel); die leere
  Toggle-Zeile emittiert kein leeres Static-Text-Element mehr.
- `FormRow`-Labels dimmen mit, wenn das Formular während des Verbindens
  disabled ist (`\.isEnabled`-Environment, Opacity 0.5 wie die Buttons).
- `PolishedButtonStyle`: sichtbarer Fokus-Ring für Full Keyboard Access
  (Ring in `remoteBlue`).

### 6. Kosmetik / Hygiene

- Totes `paper`-Token löschen; stale Kommentare in `DesignTokens`
  (staged-Hinweise) und am `errorHighlight` („4pt outside") korrigieren.
- L10n-Doppelaufrufe im Formular (Label + Control-Titel, 8×) einmal pro
  Zeile binden.
- Konfliktmeldung: Symlink/Sonstiges nicht mehr fälschlich als „existiert
  als Datei" melden.
- `applyToAll`-Recheck nach Gate-Acquire in der Konflikt-Maschinerie
  (verhindert einen überflüssigen Prompt, wenn die Regel gesetzt wurde,
  während das Item am FIFO-Gate wartete).

## Invarianten

- Sicherheits- und Architektur-Invarianten unangetastet: TOFU-Härte,
  Secrets nur im Keychain, UI-owned Lifecycles, FIFO-Startordnung,
  exactly-once-Waiter/onCompleted.
- Sprache: Code + Kommentare Englisch; neue UI-/Fehlertexte katalogisiert
  EN/DE.
- Keine neuen Settings; die bestehenden Up-/Down-Limits ändern nur ihre
  Wirkung (global statt pro Transfer) — Settings-UI unverändert.

## Tests

- `BandwidthBucket`: TDD mit injizierter Uhr — Rate eingehalten, Burst
  begrenzt, `setRate` wirkt, Cancellation wirft, mehrere Konsumenten
  teilen sich das Limit deterministisch.
- Engine/Queue: Drossel-Tests von virtueller Uhr auf Bucket-Stub
  migriert; Richtungs-Zuordnung (Upload-Bucket vs. Download-Bucket)
  getestet.
- Gruppen-Abbruch: neue Queue-Tests — Sweep erfasst genau die
  Gruppen-Items, `onCompleted` exactly-once, Einzeldatei-Fall unverändert,
  laufende Gruppen-Transfers kooperativ abgebrochen.
- Fehlertext-Mapper: Katalog-Lookup-Tests (locale-fest) für die
  `RemoteFSError`-Fälle + Abbruch + generisch.
- Startup-Sweep & Resume-Ausschluss: Unit-Tests auf Manager-/Queue-Ebene.
- Bestehende Suite (295) bleibt grün; gated Suiten (`MACSCP_ITEST`,
  `MACSCP_KEYCHAIN`) vor Abschluss.
- Visueller Smoke: Drossel live mit 2 parallelen Transfers gegen ein
  Limit (aggregiert ≈ Limit statt 2×), Ordner-Konflikt → Abbrechen stoppt
  die Gruppe, VoiceOver-Stichprobe Formular, Fokus-Ring per Tab,
  „Neue Verbindung" nach Edit leer.

## Bewusst NICHT in M6a

- Icon, DMG, Signierung, Notarisierung, README → M6b.
- Auto-Reconnect-Backoff (Backlog bleibt).
- Multi-Server/Multi-Fenster (v2).
- Settings-Fenster-Restyling (System-Chrome-Linie).
