# M18 — UI-Nachbesserungen (Suche, SSH-Keys-Sheet, Kontextmenü, Settings-Sidebar) — Design/Spec

**Datum:** 2026-08-02
**Status:** freigegeben (Brainstorm), bereit für writing-plans
**Branch:** `develop`
**Vorgänger:** M11k (FileSearch), M9a (Session-Export-Muster), M10a/M10b (Known-Hosts-/Login-Sets-Sheets), M11f (Hidden-Imports-Sheet), M17 (SSH-Key-Manager).

## Ziel

Vier zusammenhängende UI-Verbesserungen: (1) eine geteilte Suchleiste in allen Listen-Sheets, (2) die SSH-Schlüssel-Verwaltung aus den Einstellungen in ein eigenes Sheet (mit Import/Export), (3) ein Zeilen-Kontextmenü im Login-Sets-Sheet, (4) das Settings-Fenster als Sidebar-Navigation mit protokoll-spezifischen Bereichen.

## Ausgangslage (verifiziert)

- **Sheets:** `LoginSetsSheet` (List, Footer-Buttons New/Edit/Delete, **keine** Suche, **kein** Kontextmenü), `KnownHostsSheet` (Table, **eigene** Ad-hoc-Contains-Suche), `HiddenImportsSheet` (List, keine Suche), `AuditLogSheet` (List, keine Suche). Alle im 720×460-Rhythmus, präsentiert via `TabCommands`-Brücke (`showKnownHosts`/`showLogins`/`showHiddenImports`) + „Sessions"-Menüpunkte + `@State` + `.sheet(isPresented:)` in `ContentView`.
- **Suche:** `FileSearch.compile(query:isRegex:) -> Result<FileSearchPredicate, FileSearchError>` + `FileSearchPredicate.matches(_ name: String) -> Bool` (Core, M11k, getestet). `FileSearchBar` ist die vorhandene, aber datei-listen-spezifische App-UI.
- **SSH-Keys:** heute ein Settings-Tab (`SSHKeysSettingsTab`, M17) mit Liste + `GenerateKeySheet` + kopieren/exportieren/löschen; erreicht die Kern-APIs `ManagedKeyStore`/`SSHKeyGenerator`/`KeychainSecretStore`. Der „Schlüssel verwalten…"-Knopf (Formular/Login-Set-Editor) nutzt heute `SettingsLink`.
- **Settings:** `SettingsView` = `TabView` mit 6 Tabs (General/Transfers/Open-with/Terminal/Shortcuts/SSH-Keys), feste `.frame(width: 460, height: 460)`. Tab-`struct`s sauber injiziert. `GeneralSettingsTab` überladen (Sprache/Hidden/Menübar/Spalten/Auto-Refresh/Updates). Kein `.searchable`-Muster im Projekt; kein SwiftUI-Fertigbaustein für Settings-Sidebar.
- **Login-Set-Kontextmenü-Vorlage:** `SessionSidebar` hat bereits ein Zeilen-`.contextMenu` (Connect/Edit/Export/Rename/Delete).
- **Sicherheit:** SSH-Key-Privatdateien liegen 0600 im App-Ordner; Passphrase im Keychain unter `key.id`; kein `~/.ssh`-Schreiben (M17-Invarianten bleiben).

## Entscheidungen (Maintainer, 2026-08-02)

1. **Scope:** M18 = Suche + SSH-Keys-Sheet + Login-Set-Kontextmenü + Settings-Sidebar. **Login-Set-Import/Export bleibt eigener Meilenstein M19** (verschlüsseltes Codec-Subsystem).
2. **Suche:** volle `FileSearch.compile`-Mechanik (Enthält + optionaler Regex + Fehleranzeige), geteilte Komponente, angewandt auf **Login-Sets, Known-Hosts, Hidden-Imports, Audit-Log, SSH-Keys**.
3. **SSH-Keys:** raus aus den Einstellungen, eigenes Sheet wie Logins/Known-Hosts; **mit Import** (vorgezogen aus M17-v2) und **privatem-Schlüssel-Export mit Warnung**; Zeilen-Kontextmenü inkl. **Umbenennen**.
4. **Settings:** **Sidebar-Navigation** (macOS-15-Stil); „General" wird in **Allgemein** + **Ansicht** aufgeteilt; **Protokoll-Bereiche SSH/S3** mit protokoll-spezifischen Settings (presigned-Ablauf → S3, externes-Terminal-Ziel → SSH).

## Architektur

### 1. Geteilte Such-Komponente (App)

Neue App-View **`SheetSearchField`** (kompakter als `FileSearchBar`, ohne Filter/Jump-Picker — Sheets filtern immer):
- Bindet `@Binding var text: String` + `@Binding var isRegex: Bool`; zeigt Suchfeld + Regex-Toggle + Fehlertext.
- Liefert den kompilierten `FileSearchPredicate` an die Host-View (z. B. über eine `onChange`-abgeleitete `@State`, oder die Host-View ruft `FileSearch.compile` selbst mit `text`/`isRegex`). Leeres/whitespace-Query → matcht alles; ungültiges Regex → `FileSearchError` → Fehlertext, **keine** stille 0-Treffer-Liste.
- Jedes Sheet filtert seine eigene Liste: `items.filter { predicate.matches(searchString(for: $0)) }` mit einem sheet-spezifischen `searchString`:
  - Login-Sets: `"\(name) \(username) \(accessKeyID ?? "")"`
  - Known-Hosts: `"\(host) \(fingerprint)"` (ersetzt die bestehende Contains-Suche)
  - Hidden-Imports: `alias`/Host
  - Audit-Log: Event-Zusammenfassung (Aktion + Host/Ziel)
  - SSH-Keys: `"\(name) \(comment) \(fingerprint)"`

**Kein neuer Core-Code** — nur die App-View + fünf Einbindungen. Reine SwiftUI, build-verifiziert.

### 2. SSH-Keys-Verwaltung als eigenes Sheet (App)

Neuer **`SSHKeysSheet`** (Struktur wie `LoginSetsSheet`): Titel, `SheetSearchField`, Liste (Name, Typ-Badge, Fingerprint-Kurz, Kommentar, Datum, Schloss; RSA/ECDSA „nicht verbindbar"-Hinweis), Footer-Buttons, feste 720×460. Der M17-`SSHKeysSettingsTab`-Inhalt + `GenerateKeySheet` ziehen um; `ManagedKeyStore`/`SSHKeyGenerator`/Keychain-Kern unverändert.

**Aktionen (Footer + Zeilen-`.contextMenu`):**
- **Generieren…** (M17, unverändert)
- **Importieren…** — `fileImporter` wählt eine OpenSSH-Privatschlüssel-Datei; in den App-Key-Ordner kopieren (0600); Typ + Fingerprint via `ssh-keygen -l -f`, Public-Key via `ssh-keygen -y -f` (bei passphrase-geschütztem Key mit Passphrase-Eingabe) ableiten; Name/Kommentar abfragen; optionale Passphrase in den Keychain unter neuer `key.id`; `ManagedKey` mit `add`. Fehlschlag räumt kopierte Datei + Keychain-Slot auf (kein verwaistes Artefakt).
- **Public-Key kopieren** / **Public-Key exportieren…** (M17, unverändert)
- **Privaten Schlüssel exportieren…** — kopiert die private Key-Datei an einen `NSSavePanel`-Ort, **hinter einer Bestätigung mit Warnhinweis** („Der private Schlüssel verlässt den geschützten Speicher"); Passphrase-Verschlüsselung der Datei bleibt erhalten.
- **Umbenennen…** — Name/Kommentar eines Keys ändern (`ManagedKey` upsert unter derselben `id`; Datei/Keychain unberührt).
- **Löschen…** (M17, `store.remove(id:secrets:)`).

**Erreichbarkeit (gleiche Brücke wie Logins/Known-Hosts):** neuer `TabCommands.showSSHKeys` + „Sessions"-Menüpunkt **„SSH-Schlüssel…"** + `@State showSSHKeysSheet` + `.sheet(isPresented:)` in `ContentView`. Der M17-„Schlüssel verwalten…"-Knopf (Formular/Login-Set-Editor) ruft jetzt **direkt** dieses Sheet (ersetzt `SettingsLink`). Der Settings-Tab „SSH Keys" wird aus `SettingsView` entfernt.

**Sicherheit:** M17-Invarianten bleiben — Privatdateien 0600, Passphrase nur Keychain unter `key.id`, kein `~/.ssh`-Schreiben, `ssh-keygen` per Argument-Array; der private-Key-Export ist der einzige bewusste Weg aus dem Schutzraum, hinter Bestätigung.

### 3. Login-Set-Zeilen-Kontextmenü (App)

An `LoginSetsSheet.row` ein `.contextMenu { Bearbeiten…; Löschen… }`, das dieselben Closures wie die Footer-Buttons aufruft (`editorTarget` bzw. Lösch-`confirmationDialog`). Rechtsklick selektiert die Zeile zuerst. Footer-Buttons bleiben (additiv). Keine neuen L10n-Keys (Edit/Delete existieren).

### 4. Settings-Fenster → Sidebar-Navigation (App)

`SettingsView` von `TabView` auf **`NavigationSplitView`** umstellen: links `List` der Bereiche (mit SF-Symbolen), rechts Detail = Inhalt des gewählten Bereichs. Bestehende Bereichs-`struct`s als Detail wiederverwendet; `GeneralSettingsTab` in zwei aufgeteilt.

**Bereiche:**
- **Allgemein** — Sprache/Relaunch, Menübar-Icon, Updates
- **Ansicht** — versteckte Dateien, Datei-Spalten, Auto-Refresh
- **Übertragung** — Parallelität, Bandbreite *(protokoll-neutral)*
- **Öffnen mit** — Editor/Endungs-Regeln
- **Terminal** — Font/Größe/Cursor des eingebauten Terminals
- **Kurzbefehle** — Tastenkürzel-Übersicht
- **Protokolle** (Gruppe):
  - **SSH** — externes-Terminal-Ziel (aus „Terminal" hierher); Knopf „SSH-Schlüssel verwalten…" öffnet das Sheet (Abschnitt 2)
  - **S3** — presigned-URL-Standard-Ablauf (aus „Übertragung" hierher); Heimat für künftige S3-Settings

Der SSH-Keys-Bereich entfällt (jetzt Sheet). Fenstergröße ans Split-Layout angepasst (breiter). **Idle-CPU-Rauchtest** vor Auslieferung (M11n-Lektion: SwiftUI-Layout-Container auf macOS 26 können in eine Endlosschleife laufen).

**L10n:** neue Bereichstitel („Allgemein"/„Ansicht"/„Protokolle"/„SSH"/„S3"), Such-Placeholder/Regex/Fehler, Import/privat-Export/Umbenennen/Warnung-Strings, Menüpunkt „SSH-Schlüssel…" — EN/DE/FR/PL, typografische Zeichen, FR/PL KI-generiert.

## Tests

- **Core:** kein neuer Core-Code außer ggf. einem kleinen `searchString`-Helfer pro Modell (falls in Core); die Such-Mechanik (`FileSearch`) ist bereits getestet. Falls der SSH-Key-**Import** eine Core-Funktion bekommt (Datei kopieren + `ssh-keygen`-Ableitung), ein Unit-/Integrationstest gegen echtes `ssh-keygen` (wie M17): ein per `ssh-keygen` erzeugter Key wird importiert → Fingerprint/Typ/Public-Key stimmen, lädt via `SSHPrivateKeyLoader`.
- **App:** build-verifiziert + **Runtime-Idle-CPU-Smoke** (v. a. die neue Settings-Sidebar + die fünf Such-Sheets).
- **L10n:** Katalog-Parität (bestehender Test-Wächter).

## Sicherheit / Invarianten

- SSH-Key-Invarianten aus M17 unverändert (0600/0700, Passphrase nur Keychain unter `key.id`, kein `~/.ssh`-Schreiben, `ssh-keygen` Argument-Array).
- Privater-Schlüssel-Export nur hinter Bestätigung + Warnhinweis; Import räumt bei Fehlschlag auf (kein verwaistes Artefakt).
- Keine neue externe Dependency.

## Nicht in M18 (→ später)

- **Login-Set-Import/Export** (verschlüsseltes Codec-Subsystem) — eigener Meilenstein **M19**.
- `authorized_keys`-Ausrollen (M17-v2).
- WebDAV/weitere Protokoll-Settings-Bereiche (kommen mit dem jeweiligen Protokoll-Meilenstein).

## Betroffene Dateien

- `Sources/MacSCPApp/SheetSearchField.swift` — **create** (geteilte Suchleiste).
- `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** (Suche + Zeilen-Kontextmenü).
- `Sources/MacSCPApp/KnownHostsSheet.swift` — **modify** (Suche auf `SheetSearchField` vereinheitlichen).
- `Sources/MacSCPApp/HiddenImportsSheet.swift`, `Sources/MacSCPApp/AuditLogSheet.swift` — **modify** (Suche).
- `Sources/MacSCPApp/SSHKeysSheet.swift` — **create** (aus `SSHKeysSettingsTab` extrahiert + Import/privat-Export/Umbenennen + Suche).
- `Sources/MacSCPApp/SettingsView.swift` — **modify** (Sidebar-Navigation, General-Split, Protokoll-Bereiche, SSH-Keys-Tab entfernt).
- `Sources/MacSCPApp/ContentView.swift`, `Sources/MacSCPApp/MacSCPApp.swift` — **modify** (`showSSHKeys`-Brücke + „SSH-Schlüssel…"-Menüpunkt + `.sheet`).
- `Sources/MacSCPApp/ConnectionFormView.swift`, `Sources/MacSCPApp/LoginSetsSheet.swift` — **modify** („Schlüssel verwalten…" → Sheet statt `SettingsLink`).
- `Sources/macSCPCore/SSH/…` — **modify/create** ggf. SSH-Key-Import-Helfer + Test.
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**.
