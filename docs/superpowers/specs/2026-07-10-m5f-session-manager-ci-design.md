# macSCP M5f — Session-Manager & CI-Angleich (Design-Spec)

**Datum:** 2026-07-10
**Status:** vom Maintainer freigegeben (Brainstorming-Session, Design-Review der laufenden App)
**Referenzen:** `docs/design/ci.md` („Zwei Welten, ein Fenster"), interaktiver Entwurf
„macSCP — Design & CI" (Artifact, Session 2026-07-09), `docs/superpowers/specs/2026-07-09-macscp-design.md`

## Ziel

Zwei Baustellen aus dem Design-Review des Maintainers:

1. **Session-Manager ausbauen:** Kontextmenü mit Umbenennen / Bearbeiten /
   Löschen für gespeicherte Sessions plus flache Gruppen (Anlegen, Umbenennen,
   Auflösen, Sessions zuordnen).
2. **UI an die CI-Entwürfe angleichen:** Sidebar-Optik, Verbindungsansicht,
   Titelleiste/Toolbar und durchgängige Akzentfarben entsprechen noch nicht
   dem freigegebenen Entwurf.

## Entscheidungen (Maintainer, 2026-07-10)

| Frage | Entscheidung |
|---|---|
| Design-Scope | Alle vier Punkte: Sidebar-Look, Verbindungsansicht, Titelleiste/Toolbar, durchgängige Akzentfarben |
| Bearbeiten-Flow | Bestehendes Verbindungsformular wiederverwenden (Edit-Modus) |
| Gruppenstruktur | Flache Gruppen (eine Ebene), keine verschachtelten Ordner |
| Gruppen-Datenmodell | Eigene Gruppen-Objekte (`groups`-Array + `groupID` an der Session) |
| Design-Umsetzung | Gezielte View-Anpassungen mit bestehenden `DesignTokens`, kein Theming-System |

## Teil A — Session-Manager

### Datenmodell & Store

- Neu: `public struct StoredGroup: Codable, Equatable, Identifiable, Sendable`
  mit `id: UUID` und `name: String`.
- `StoredSession` erhält `public var groupID: UUID?` (nil = ungruppiert).
- `SessionStore` persistiert Gruppen zusätzlich zu den Sessions in
  `sessions.json`. **Vorwärts-/Rückwärtskompatibilität:** bestehende Dateien
  ohne `groups`/`groupID` laden unverändert (keine Migration); das bestehende
  Lade-/Speicher-Muster des Stores bleibt erhalten.
- Reihenfolge: Gruppen in Anlage-Reihenfolge (Array-Reihenfolge im Store);
  Sessions innerhalb einer Gruppe wie bisher in Speicher-Reihenfolge.
- **Gruppe löschen = auflösen:** die zugeordneten Sessions bekommen
  `groupID = nil`, werden also ungruppiert — niemals mitgelöscht.
- Verwaiste `groupID`s (Gruppe fehlt in `groups`) werden beim Laden wie
  `nil` behandelt (defensiv, kein Fehler).
- Secrets: unverändert ausschließlich Keychain (`SecretStore`), adressiert
  über die Session-ID; `sessions.json` enthält weiterhin keine Geheimnisse.

### SessionListViewModel — neue Operationen

- `renameSession(id:to:)` — Name trimmen, leer nicht zulässig.
- `updateSession(_:)` — vollständige Bearbeitung (Name, Host, Port, User,
  AuthKind, KeyPath, groupID); Secret-Update siehe Edit-Flow.
- `createGroup(name:) -> StoredGroup` — leere Gruppen sind erlaubt.
- `renameGroup(id:to:)`
- `dissolveGroup(id:)` — Sessions → ungruppiert.
- `moveSession(id:toGroup:)` — `nil` = „Keine Gruppe".
- Delete bleibt wie gehabt (Session + Keychain-Secret), bekommt aber in der
  UI eine Rückfrage.

### Sidebar-Verhalten

- Aufbau: „SESSIONS"-Label → ungruppierte Sessions → je Gruppe ein
  einklappbarer Abschnitt (DisclosureGroup-Verhalten; Einklapp-Zustand ist
  reiner UI-State pro Fenster, nicht persistiert) → Sektion „IMPORTIERT"
  (unverändert, wird nicht gruppiert).
- Kontextmenü **Session-Zeile**: Verbinden · Bearbeiten… · Umbenennen ·
  Verschieben nach → (Untermenü: alle Gruppen, „Keine Gruppe",
  „Neue Gruppe…") · Löschen (destructive, mit Bestätigungsdialog — das
  Keychain-Secret wird mitgelöscht).
- Umbenennen ist **inline**: die Zeile wird zum Textfeld, Enter bestätigt,
  Escape bricht ab (Fokus-Verlust = abbrechen, kein stiller Commit).
- Kontextmenü **Gruppen-Header**: Umbenennen · Auflösen.
- Kontextmenü **Sidebar-Hintergrund**: Neue Verbindung · Neue Gruppe…
- **Drag & Drop:** Session-Zeile auf einen Gruppen-Header ziehen verschiebt
  die Session in die Gruppe; auf den „SESSIONS"-Bereich ziehen entgruppiert.
  (Kontextmenü „Verschieben nach" ist der funktionale Hauptweg; D&D ist
  Komfort.)
- „Neue Gruppe…" öffnet einen Namens-Prompt als Alert mit Textfeld
  (Bestätigen legt an, leerer Name legt nichts an).
- Sidebar-Interaktionen bleiben während Transfers/Verbindungsaufbau
  deaktiviert wie bisher (`interactionsDisabled`).

### Bearbeiten-Flow (Formular im Edit-Modus)

- Einstieg über Kontextmenü „Bearbeiten…"; die Detailfläche zeigt das
  bestehende Verbindungsformular vorbefüllt (Name, Host, Port, Benutzer,
  Auth-Art, Key-Pfad) plus **Gruppen-Auswahl** (Picker: Keine Gruppe /
  vorhandene Gruppen). Derselbe Picker erscheint auch beim Neu-Anlegen,
  sobald „Als Session speichern" aktiv ist.
- Titel „Session bearbeiten"; Buttons: **Speichern**,
  **Speichern & verbinden**, Zurück (verwirft Änderungen und zeigt den
  vorherigen Zustand).
- **Passwort/Passphrase im Edit-Modus:** Feld ist leer, Platzhalter
  „unverändert". Leer lassen = vorhandenes Secret bleibt; Eingabe =
  Keychain-Eintrag wird überschrieben. Gespeicherte Secrets werden **nie**
  aus der Keychain ins Formular geladen (bestehende Sicherheits-Invariante).
- Wechsel der Auth-Art beim Bearbeiten folgt derselben Semantik wie beim
  Anlegen (Passwort ↔ Key inkl. Passphrase-Feld).
- „Speichern" verbindet **nicht**; „Speichern & verbinden" speichert und
  startet danach den normalen Verbindungsweg (inkl. TOFU unverändert).

## Teil B — CI-Angleich

Grundsatz: gezielte Anpassungen mit den bestehenden `DesignTokens`
(`localAmber`, `remoteBlue`, `statusPhosphor`, Terminal-Farben). Die
CI-Regeln aus `docs/design/ci.md` gelten bindend: Bernstein/Ozeanblau nur
semantisch (lokal/remote), Phosphor nur für Status, Fehler in System-Rot,
Systemfarben haben sonst Vorrang.

### Sidebar-Optik (wie Entwurfs-Mockup)

- Aktive Session: Soft-Hintergrund in Ozeanblau (abgeleitet aus
  `remoteBlue`, ~12 % Opazität), Schrift semibold in `remoteBlue`,
  Phosphor-Punkt.
- Inaktive Zeilen: dezenter Hover-Hintergrund; Punkt in Sekundärfarbe.
- Abschnitts-Labels („SESSIONS", Gruppennamen, „IMPORTIERT"): klein,
  versal, mit Laufweite — wie im Mockup (`.caption2`, semibold, tracking).

### Verbindungsansicht

- Kompakter Formularblock (~420 pt), Abstände/Proportionen am
  Dialog-Mockup orientiert.
- Primärbutton („Verbinden" / „Speichern & verbinden") in Ozeanblau
  (`borderedProminent` + Tint) statt System-Akzent.

### Titelleiste / Toolbar

- Verbunden: Fenstertitel **„macSCP — ‹Sessionname›"** (ungespeicherte
  Verbindungen: `user@host`); Aktionen **Hochladen · Herunterladen ·
  Terminal · Trennen** als echte macOS-Toolbar (SF Symbols) statt der
  bisherigen eingebauten Kopfzeile.
- Getrennt: Titel „macSCP", keine Toolbar-Items.
- Bestehende Lifecycle-/Resize-Logik (kompaktes Fenster, aktives
  Wachsen/Schrumpfen, M5c/T0) bleibt unverändert.

### Akzentfarben durchgängig

- Globaler Tint in Ozeanblau auf dem Fenster-Content: Default-Buttons,
  Toggles, Picker-Auswahl, Progress-Indikatoren erben die CI-Primärfarbe.
- Semantik unangetastet: Upload-/Lokal-Elemente bleiben Bernstein
  (TransferQueueBar, Pane-Badges), Download/Remote Blau, Verbunden-Status
  Phosphor, Fehler System-Rot.

## Fehlerbehandlung

- Leerer Name beim Umbenennen/Anlegen (Session oder Gruppe): Eingabe wird
  nicht übernommen (inline: Abbruch; Formular: Feld-Validierung wie beim
  Anlegen).
- Gruppen-Namen dürfen doppelt sein (keine Eindeutigkeits-Pflicht — die ID
  identifiziert); der Plan darf optional beim Anlegen einen Hinweis zeigen,
  MUSS aber nicht.
- Store-Fehler (I/O) laufen über den bestehenden `errorMessage`-Weg der
  Sidebar.
- Löschen-Rückfrage nennt den Session-Namen und dass gespeicherte
  Zugangsdaten mit entfernt werden.

## Tests

- **Store:** Roundtrip mit Gruppen + `groupID`; Laden einer Alt-Datei ohne
  Gruppen-Felder; verwaiste `groupID` → wie nil behandelt.
- **ViewModel:** rename/update/move/createGroup/renameGroup/dissolveGroup
  (Auflösen erhält Sessions und entgruppiert sie); Delete entfernt Secret
  (Mock-SecretStore); Update-Semantik: leeres Secret-Feld = Secret bleibt,
  gesetztes = überschrieben.
- **ConnectionViewModel (Edit-Modus):** Vorbefüllung, Speichern ohne
  Connect, Speichern & verbinden nutzt den normalen Connect-Weg.
- **Optik:** visueller Smoke-Test je Abschluss-Task (Sidebar-Zustände,
  Toolbar verbunden/getrennt, Edit-Roundtrip inkl. Passwort-unverändert).

## Bewusst NICHT im Scope

- Verschachtelte Ordner / Hierarchie.
- Manuelle Sortierung (D&D-Reihenfolge) innerhalb von Gruppen.
- Gruppierung der importierten ssh-config-Hosts (bleiben eigene Sektion).
- Theming-System / konfigurierbare Farben.
