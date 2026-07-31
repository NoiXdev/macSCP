# M9b — Audit-Log pro Verbindung (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben (Blöcke 1+2 einzeln bestätigt)

## Ziel

Pro GESPEICHERTER Verbindung ein persistentes Protokoll dessen, was in ihren
Sessions passiert ist — Verbindungen, Transfers, Datei-Operationen, Fehler.
Es bleibt erhalten, bis die Verbindung gelöscht wird, und ist jederzeit über
das Sidebar-Kontextmenü einsehbar.

**Maintainer-Entscheidungen (2026-07-28):**

1. Ereignis-Umfang: alles Wesentliche — Verbunden/Getrennt, abgeschlossene
   Transfers (Richtung, Name, Ziel, Erfolg/Fehler/Abbruch), Datei-Operationen
   (Umbenennen, Löschen, Rechte, Neuer Ordner), Editor-Uploads,
   Cross-Session-Transfers (mit Ziel-Session), Fehler mit Meldungstext.
   KEINE Navigations-/Listing-Ereignisse.
2. Nur gespeicherte Sessions loggen (Ad-hoc-Verbindungen: nichts);
   Deckel rollierend die neuesten **1000** Einträge pro Session.
3. Anzeige: Sidebar-Kontextmenü „Audit-Log…" → großes Sheet mit Tabelle,
   Filter-Segmenten, Textsuche, „Log leeren…" (Rückfrage) und „Als Text
   exportieren…".
4. Architektur: Ansatz A — `AuditLogStore` (SessionStore-Muster) + optionale
   Sink-Hooks an den drei vorhandenen Engpässen; kein Event-Bus, kein OSLog.

## 1. Modell (Core)

`Sources/macSCPCore/Sessions/AuditEvent.swift`

- `public struct AuditEvent: Codable, Equatable, Sendable, Identifiable`:
  `id: UUID`, `timestamp: Date`, `kind: Kind`, `detail: String`,
  `isError: Bool`, `errorMessage: String?`.
- `public enum Kind: String, Codable, CaseIterable, Sendable`:
  `connected`, `disconnected`, `transferFinished`, `transferFailed`,
  `transferCancelled`, `rename`, `delete`, `permissions`, `newFolder`,
  `editUpload`, `crossSessionTransfer`.
- `detail` ist ein FERTIGER englischer Klartext (z. B.
  `upload report.pdf → /var/www`, `rename /etc/app.conf → app.conf.bak`,
  `to “db-prod”: dump.sql.gz → /srv/backups`). Die Anzeige lokalisiert nur
  die Kind-LABELS (EN/DE); Details (Pfade/Namen) sind Nutzdaten und bleiben
  unübersetzt. Kategorie-Zuordnung für den Filter: Transfers =
  transferFinished/Failed/Cancelled/editUpload/crossSessionTransfer;
  Datei-Ops = rename/delete/permissions/newFolder; Verbindung =
  connected/disconnected; Fehler = `isError == true` (Querschnitt).

## 2. AuditLogStore (Core)

`Sources/macSCPCore/Sessions/AuditLogStore.swift`

- Muster `SessionStore`: stateless struct, injizierbares Verzeichnis
  (Default `Application Support/macSCP/audit/`), eine Datei pro Session
  `<sessionID>.json`, atomare Writes, prettyPrinted/sortedKeys.
- API:
  - `append(_ event: AuditEvent, for sessionID: UUID)` — lädt, hängt an,
    kappt auf die NEUESTEN 1000 (Reihenfolge chronologisch in der Datei),
    schreibt. Wirft NIE (Fehler still geschluckt): ein kaputtes Log darf
    keinen Transfer/keine Aktion stören.
  - `events(for sessionID: UUID) -> [AuditEvent]` — kaputte/fehlende Datei
    ⇒ `[]` (fail-safe; die Sheet-Anzeige zeigt dann schlicht „leer").
  - `clear(for sessionID: UUID)` / `deleteLog(for sessionID: UUID)` —
    leeren bzw. Datei entfernen; Fehler still.
- Cap-Konstante `maxEntriesPerSession = 1000` (internal, testbar).

## 3. AuditRecorder + Sinks (Core)

`Sources/macSCPCore/Sessions/AuditRecorder.swift`

- `public struct AuditRecorder: Sendable`: `sessionID` + Store; Convenience:
  `recordConnected(host:username:)`, `recordDisconnected()`,
  `recordTransfer(...)` (mappt Queue-Item-Terminalzustand → Kind inkl.
  Editor-Upload- und Cross-Session-Variante; Cross-Session-Detail enthält
  den ZIEL-TITEL, den die App liefert), `recordAction(kind:detail:error:)`
  für die vier Browser-Aktionen.
- Sinks (beide optional, Default nil — nil ⇒ kein Logging, Ad-hoc still):
  - `TransferQueueViewModel.auditSink: ((Item) -> Void)?` — aufgerufen am
    EINZIGEN Terminal-Übergang (dem `wasTerminal`-Gate, wo
    `totalFailureCount` zählt), exakt einmal pro Item; nie bei
    Nicht-Terminal-Übergängen.
  - `RemoteBrowserViewModel.auditSink: ((AuditEvent) -> Void)?` — die vier
    Aktionen (rename/createFolder/applyPermissions/deleteItems) melden nach
    Abschluss Erfolg ODER Fehler (mit Meldung). Nur das Remote-Pane bekommt
    einen Sink.
- Verbindungs-Ereignisse loggt der App-Layer direkt über den Recorder
  (connect-Erfolg bzw. Teardown im Tab-Fluss).

## 4. App-Verkabelung

- `SessionTab.auditRecorder: AuditRecorder?` — gesetzt beim Connect einer
  GESPEICHERTEN Session (`connect(in:stored:)` bzw. `startSession`, wenn ein
  `activeStoredSessionID` entsteht), genullt im Teardown (nach dem
  `recordDisconnected`). Der Queue-Sink und der Remote-VM-Sink werden beim
  Setzen des Recorders verdrahtet und beim Nullen gelöst.
- Cross-Session-Detail: der App-Sink löst `item.destinationTabID` über
  `tabsModel` zum Ziel-Titel auf (Ziel-Tab schon zu ⇒ „unknown session").
- Löschung: `SessionListViewModel.delete` ruft zusätzlich
  `auditStore.deleteLog(for: session.id)`; Fehler blockieren das
  Session-Löschen nicht. Der Store wird dem VM injiziert (Init-Parameter
  mit Default — Tests reichen Temp-Verzeichnisse).

## 5. Audit-Sheet (App)

- Sidebar-Session-Kontextmenü: „Audit-Log…" (über „Löschen"; für JEDE
  gespeicherte Session, auch ohne aktive Verbindung).
- Sheet ~640×480, House-Stil: Titel = Session-Name; Filter-Segmente
  Alle / Transfers / Datei-Ops / Verbindung / Fehler; Suchfeld (Volltext
  über `detail` + `errorMessage`, case-insensitiv); Tabelle: Zeit
  (`dd.MM. HH:mm:ss`, lokal), Ereignis-Label (lokalisiert EN/DE), Detail
  (monospaced); Fehler-Zeilen rot getönt; NEUESTE OBEN.
- Fußzeile: Zähler („%lld Einträge" / gefiltert „%lld von %lld"),
  „Als Text exportieren…" (fileExporter, `.txt` — Zeilenformat
  `[ISO8601] KIND detail` + ` — error: <message>` bei Fehlern),
  „Log leeren…" (destruktiv, Rückfrage, ruft `clear(for:)`).
- Leerer Zustand: dezenter Hinweis („Noch keine Einträge.").
- Laden beim Öffnen; KEIN Live-Refresh (bewusst — Schließen/Öffnen genügt;
  Auto-Refresh ist M9c-Thema).
- Alle neuen UI-Texte EN/DE.

## 6. Tests

- Store: append/roundtrip; Rolling-Cap (Eintrag 1001 verdrängt den
  ältesten, Reihenfolge stabil); clear/deleteLog; kaputte Datei ⇒ `[]`;
  append gegen unbeschreibbares Verzeichnis (Datei statt Ordner, Muster
  M9a) wirft nicht und stört nicht.
- Recorder: Item→Event-Mapping (finished/failed/cancelled ×
  upload/download, Editor-Upload-Kind, Cross-Session-Kind mit Ziel-Titel
  im Detail); Aktions-Mapping der vier VM-Methoden (Erfolg + Fehlerfall).
- Queue-Sink: feuert exakt einmal pro Terminal-Übergang (Doppel-setStatus
  feuert nicht erneut — am wasTerminal-Gate getestet); nie bei
  Progress-Updates.
- VM-Sink: feuert nur bei gesetztem Sink; Erfolg UND Fehlerfall; nil-Sink
  = kein Effekt (Regression: Aktionen unverändert).
- App (Sheet, Menü, Verdrahtung): visueller Smoke (T4-Checkliste im Plan).

## 7. Bewusst NICHT in M9b

- Kein Logging für Ad-hoc-Verbindungen (auch nicht flüchtig).
- Keine Navigations-/Listing-Ereignisse.
- Kein Live-Refresh des offenen Sheets; kein eigenes Fenster.
- Kein strukturierter Export (CSV/JSON) — nur Text; Backlog-Kandidat.
- Keine Aufbewahrungs-Einstellungen (der 1000er-Deckel ist fix).
