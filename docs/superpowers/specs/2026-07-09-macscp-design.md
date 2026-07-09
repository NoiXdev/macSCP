# macSCP — Design-Spec

**Datum:** 2026-07-09
**Status:** Entwurf, vom Maintainer freigegeben (Brainstorming-Session)
**Lizenz des Projekts:** MIT

## Ziel

Ein nativer Open-Source-Client für macOS im Geist von WinSCP. Ein echter Port ist
unmöglich (WinSCP ist C++ Builder/VCL, rein Windows-gebunden) — macSCP ist eine
Neuentwicklung, die das WinSCP-Bedienkonzept auf den Mac bringt:

- Zwei-Fenster-Dateibrowser (lokal ↔ remote) über SFTP
- Integriertes SSH-Terminal pro Verbindung
- Session-Manager mit macOS-Keychain-Anbindung
- Transfer-Queue mit Resume und Editor-Integration

**Zielgruppe:** Mac-Nutzer, die von Windows/WinSCP kommen oder einen nativen,
freien SFTP-Client vermissen. Alleinstellungsmerkmal gegenüber Cyberduck (Java),
FileZilla (wxWidgets) und Electron-Clients: fühlt sich wie eine echte Mac-App an.

## Rahmenentscheidungen

| Entscheidung | Wahl | Begründung |
|---|---|---|
| Sprache/UI | Swift + SwiftUI, AppKit wo nötig | Natives Feeling ist das Alleinstellungsmerkmal; eine Sprache/Codebasis statt Rust+TS (Tauri wurde verworfen) |
| SSH/SFTP | [Citadel](https://github.com/orlandos-nl/Citadel) (auf SwiftNIO SSH) | Aktiv gepflegt (Stand 04/2026), High-Level-SFTP-API; hinter Abstraktionsschicht austauschbar |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Ausgereift, AppKit-Frontend, produktiv in Secure ShellFish, La Terminal, CodeEdit |
| Fallback SSH | libssh2 via C-Interop | Nur falls Citadel Lücken zeigt; ermöglicht durch Protokoll-Abstraktion |
| Mindest-macOS | 14 (Sonoma) | @Observable, moderne SwiftUI-APIs |
| Lizenz | MIT | Niedrigste Contributor-Hürde, üblich im Swift-Ökosystem |
| Tests | Swift Testing | Unit gegen Mock-FS, Integration gegen Docker-SSH-Server |
| Distribution | GitHub Releases (DMG) + später Homebrew Cask | Üblicher Weg für Open-Source-Mac-Tools; kein App Store in v1 |

## Architektur

Vier Kern-Module (Swift Package `macSCPCore`, UI-unabhängig, headless testbar)
plus die App:

### 1. `Core/RemoteFS` — Protokoll-Abstraktion

Ein Swift-Protocol `RemoteFileSystem` definiert alle Dateioperationen:

- `list(path)`, `stat(path)`
- `readStream(path)` / `writeStream(path)` (Streams, kein Voll-Puffern)
- `rename`, `delete`, `mkdir`, `chmod`

v1-Implementierung: `CitadelFileSystem`. Die UI und die Transfer-Queue arbeiten
ausschließlich gegen das Protocol. Damit sind libssh2-Fallback sowie spätere
Backends (FTP, S3, WebDAV) reine Zusatzimplementierungen.

### 2. `Core/SSH` — Verbindungs-Schicht

`SSHConnection` = eine authentifizierte SSH-Verbindung pro Server. SFTP-Channel
und Shell-Channel (Terminal) laufen gemultiplext über dieselbe Verbindung — ein
Login, beides verfügbar (wie WinSCP mit integrierter Konsole).

Verantwortlich für:

- Host-Key-Verifikation (TOFU: beim ersten Verbinden bestätigen, Fingerprint
  speichern, bei Änderung deutlich warnen)
- Auth: Passwort, Public Key (inkl. Passphrase), ssh-agent
- Reconnect mit exponentiellem Backoff bei Verbindungsabbruch
- Kapselung der NIO-Welt: nach außen ausschließlich async/await

### 3. `Core/Sessions` — Session-Verwaltung

- Gespeicherte Verbindungen (Name, Host, Port, User, Auth-Methode,
  Start-Verzeichnisse) als lokale Konfigurationsdatei (JSON) in
  `~/Library/Application Support/macSCP/`
- Geheimnisse (Passwörter, Key-Passphrasen) **ausschließlich** in der
  macOS-Keychain, nie in der Konfigurationsdatei
- Lesender Import aus `~/.ssh/config` (Host, HostName, User, Port,
  IdentityFile) — bestehende Hosts erscheinen ohne Neuanlage

### 4. `Core/Transfer` — Transfer-Queue

- Warteschlange mit konfigurierbarer Parallelität (Default: 3 gleichzeitig)
- Fortschritt pro Datei und gesamt (Bytes, Rate, ETA)
- Resume abgebrochener Transfers (SFTP-Offset-Fortsetzung)
- Konfliktregeln: überschreiben / überspringen / umbenennen — pro Fall fragen
  oder als Regel für die Queue setzen
- Rekursive Verzeichnis-Transfers

**Editor-Integration** (setzt auf der Queue auf): Remote-Datei → Download in
Temp-Verzeichnis → Öffnen mit Standard-App → Datei-Watcher (DispatchSource)
erkennt Speichern → automatischer Upload. Aufräumen der Temp-Dateien beim
Schließen der Session.

### 5. App/UI (SwiftUI + gezielt AppKit)

Hauptfenster-Layout:

```
┌───────────┬──────────────────────┬──────────────────────┐
│ Sessions  │  Lokal (Pfad, Liste) │ Remote (Pfad, Liste) │
│ Sidebar   │                      │                      │
│           ├──────────────────────┴──────────────────────┤
│           │  Terminal-Panel (einblendbar, SwiftTerm)    │
│           ├─────────────────────────────────────────────┤
│           │  Transfer-Leiste (Queue, Fortschritt)       │
└───────────┴─────────────────────────────────────────────┘
```

- Dateilisten: AppKit-`NSTableView` via `NSViewRepresentable` — reine
  SwiftUI-Listen brechen bei Verzeichnissen mit tausenden Einträgen ein
- Drag & Drop: Finder → Remote-Liste (Upload), Remote-Liste → Finder (Download)
- Terminal: SwiftTerms AppKit-View eingebettet, pro Session ein Terminal
- ViewModels mit `@Observable`, Core-Aufrufe via async/await

## Fehlerbehandlung

- Jede Core-Schicht wirft typisierte Fehler (`RemoteFSError`, `SSHError`,
  `TransferError`)
- UI übersetzt in verständliche Meldungen mit Handlungsoption
  („Verbindung verloren — erneut verbinden?")
- Transfers überleben Reconnects (Queue pausiert, setzt nach Reconnect fort)
- Host-Key-Änderung ist ein harter Stopp mit deutlicher Warnung, kein Dialog
  zum Wegklicken

## Testing

- **Unit:** Core-Logik (Queue, Konfliktregeln, ssh-config-Parser,
  Session-Store) gegen ein `MockRemoteFileSystem`
- **Integration:** komplette SFTP-Schicht gegen einen lokalen
  OpenSSH-Docker-Container (z.B. `linuxserver/openssh-server`)
- **CI:** GitHub Actions auf macOS-Runnern: Build + Unit-Tests bei jedem PR;
  Integrationstests, soweit Docker auf dem Runner verfügbar
- UI: manuelle Smoke-Tests je Meilenstein; UI-Automation nicht in v1

## Meilensteine

1. **M1 — Kern-Beweis:** Verbinden, Auth, Remote-Verzeichnis auflisten
   (Core-Package + minimaler CLI-Treiber, noch keine App)
2. **M2 — Browser:** App-Fenster mit Zwei-Fenster-Browser, Download/Upload
   einzelner Dateien, Drag & Drop
3. **M3 — Sessions:** Session-Manager, Keychain, ssh-config-Import
4. **M4 — Terminal:** SwiftTerm-Panel je Verbindung
5. **M5 — Queue:** Transfer-Queue mit Resume + Editor-Integration
6. **M6 — Release:** App-Icon, Onboarding, README/Docs, notarisierte DMG,
   GitHub-Release

## Bewusst NICHT in v1

- SCP-Protokoll-Fallback, FTP/FTPS, S3, WebDAV
- Verzeichnis-Synchronisation („Sync Browsing" / Ordnervergleich)
- Mehrfach-Fenster / Tabs für mehrere gleichzeitige Server — v1 verwaltet
  genau **eine aktive Verbindung pro Fenster**; Session-Wechsel trennt die
  vorherige Verbindung (nach Rückfrage bei laufenden Transfers)
- App Store / Sandbox
- Skripting/CLI-Automatisierung

## Vorgemerkt für v2

- **Mehrere gleichzeitige Server über Tabs/Fenster** — vom Maintainer bestätigt
  (2026-07-09). Architektur-Hinweis für v1: nichts bauen, was eine einzige
  globale Verbindung annimmt — Verbindung/Session gehört an das Fenster- bzw.
  Tab-Objekt, nicht in einen App-weiten Singleton.

## Offene Punkte

- **Notarisierung:** braucht Apple-Developer-Account (99 €/Jahr). Bis M6
  unsignierte Dev-Builds; Entscheidung beim Release-Meilenstein.
- **Konkurrenz-Check:** Web-Recherche, ob ein vergleichbares natives
  Open-Source-Projekt existiert, steht noch aus (Such-Dienst war während der
  Session nicht verfügbar; Stand Januar 2026: nichts Nennenswertes in der
  Nische).
- **README-Konvention:** Projektbeschreibung/Tagline nutzenorientiert ohne
  Stack-Details; technische Details ab dem Contributing-Teil (Auslegung der
  globalen Konvention des Maintainers).
