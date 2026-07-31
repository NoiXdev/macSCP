# M10a — Known-Hosts-Verwaltung (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben (Mockup eingefroren:
`docs/design/assets/m10-mockups.html` Abschnitte 1+4 — wird mit diesem Spec
committet; Design-Block „ja weiter")

## Ziel

Alle per TOFU gemerkten Host-Keys einsehen und verwalten: Tabelle mit
Fingerprints, Suche, Kopieren, Entfernen mit Rückfrage — erreichbar über ein
neues „Sessions"-Menü, das Sidebar-Hintergrund-Menü und den TOFU-Prompt.

**Bindend aus dem Mockup:** KEIN Bearbeiten von Einträgen (Fingerprints
editierbar zu machen wäre ein Sicherheits-Fußschuss); Entfernen ist das
offizielle Werkzeug für rotierte Server-Keys.

## 1. Core: KnownHostKey + KnownHostsStore

- `KnownHostKey.addedAt: Date?` — NEU, optional und decode-kompatibel:
  Bestandseinträge ohne Feld lesen als `nil` (Anzeige „—"); der bestehende
  normalisierende Custom-Decoder bleibt der EINZIGE Decode-Pfad (M3d-Regel)
  und decodiert das Feld via `decodeIfPresent`. `upsert` stempelt beim
  Schreiben `Date()` (auch beim Ersetzen eines bestehenden Eintrags — der
  Zeitpunkt der letzten Vertrauensentscheidung).
- `KnownHostsStore.allKeys() throws -> [KnownHostKey]` — public, sortiert
  host (case-insensitiv, ist bereits lowercased) dann port.
- `KnownHostsStore.remove(host:port:)` throws — entfernt exakt den
  (host lowercased, port)-Match, persistiert atomar; No-op wenn nicht
  vorhanden.
- TOFU-INVARIANTEN UNANGETASTET: find/upsert/Validator-Fluss unverändert;
  Entfernen macht den Host wieder „unbekannt" (nächster Connect = normaler
  TOFU-Prompt); Mismatch bleibt harter Stopp.

## 2. App: KnownHostsSheet

Exakt Mockup Abschnitt 1 (~720 pt breit):

- Tabelle: Host, Port, Schlüsseltyp (Badge, RemoteBlue-Soft), Fingerprint
  (SHA256, monospaced, `inkSecondary`), Hinzugefügt (`dd.MM.yyyy`, „—" bei
  nil). Mehrfachauswahl. Suche über Host + Fingerprint (case-insensitiv).
- Fußzeile: Zähler („n Hosts" / gefiltert „n von m"), „Fingerprint
  kopieren" (nur bei Einzelauswahl aktiv; NSPasteboard), „Entfernen…"
  (destruktiv, nur bei Auswahl aktiv; Rückfrage-Text: „Beim nächsten
  Verbinden wird der Host wie ein unbekannter behandelt (neuer
  TOFU-Prompt)." — bei Mehrfachauswahl mit Anzahl), „Schließen".
- Laden beim Öffnen; Ladefehler ⇒ ehrliche Meldung im Sheet (kein stilles
  Leer). Nach Entfernen: Liste neu laden, Auswahl leeren.

## 3. Aufruf-Wege (Mockup Abschnitt 4, Known-Hosts-Teil)

- NEUES Menü „Sessions" in der Menüleiste: „Bekannte Hosts…" (⌘⇧K) + die
  dorthin GESPIEGELTEN Import/Export-Einträge („Alle Sessions exportieren…",
  „Sessions importieren…" — dieselben Handler wie im Sidebar-Menü, die
  Sidebar-Einträge bleiben). „Logins… ⌘⇧L" folgt in M10b.
- Sidebar-Hintergrund-Kontextmenü: „Bekannte Hosts…" (über den
  Export/Import-Einträgen, mit Separator).
- TOFU-Prompt: Fußnote/Link „Bekannte Hosts verwalten…" — öffnet das Sheet,
  der Prompt bleibt offen und unverändert gültig.
- Verdrahtung über die bestehende `TabCommands`-Brücke (Menü) bzw.
  Sheet-State in ContentView; Key-Window-Guards wie bei den Tab-Kommandos.

## 4. Tests

- Core: allKeys leer/sortiert; remove entfernt exakt den Tripel-Match,
  No-op sonst, persistiert; addedAt-Roundtrip; LEGACY-JSON ohne addedAt
  liest nil (Vorwärtskompatibilität, Raw-JSON-Test); upsert stempelt Datum
  (auch beim Ersetzen); Fingerprint-Ableitung unverändert (Regression).
- App (Sheet, Menü, Fußnote): visueller Smoke (T3), inkl. Beweis: Host
  entfernen → neu verbinden → TOFU-Prompt erscheint wieder.

## 5. Bewusst NICHT in M10a

- Kein Bearbeiten/Hinzufügen von Hand; kein known_hosts-Datei-Import
  (OpenSSH-Format) — Backlog-Kandidat.
- Kein „Logins"-Bereich (M10b), kein Jump-Host (M10c).
