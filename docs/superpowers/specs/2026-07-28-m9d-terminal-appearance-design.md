# M9d — Terminal-Darstellung + Remote-Home-Start (Design)

Datum: 2026-07-28 · Status: vom Maintainer freigegeben (Design in einem Block bestätigt, „direkt los")

## Ziel

Einstellbare Terminal-Darstellung (Monospace-Font, Schriftgröße, Cursor-Stil)
mit Live-Anwendung auf offene Terminals; Farben bleiben festes CI (Tiefsee/
Phosphor). Eingefalteter Mini-Fix: das Remote-Pane öffnet beim Connect das
Remote-HOME (SFTP `realpath "."`) statt `/`.

**Maintainer-Entscheidungen (2026-07-28):** Umfang = Font + Größe +
Cursor-Stil; Farben/Theme fest (CI). Remote-Home-Fix in diesem Meilenstein.

## 1. Settings (Core)

`SettingsStore`, vorwärtskompatibel wie gehabt:

- `terminalFontName: String?` — nil (Default) = System-Monospace (SF Mono).
- `terminalFontSize: Int` — Default 13, geklemmt 9…24 beim Setzen UND Lesen.
- `terminalCursorStyle: TerminalCursorStyle` — Enum (String-RawValue) mit
  `block` (Default), `bar`, `underline`; unbekannte gespeicherte Werte lesen
  als Default.
- `terminalCursorBlink: Bool` — Default `true`.
- `TerminalCursorStyle` liegt in Core (testbar) und liefert zusammen mit dem
  Blink-Flag das Mapping auf SwiftTerms sechs Cursor-Modi (blink/steady ×
  block/underline/bar) — als reine Funktion `swiftTermStyleName`-artig bzw.
  direkt im App-Layer gemappt; das MAPPING (6 Kombinationen) ist Core-seitig
  als Enum+Flag-Paar getestet.

## 2. Anwendung (App, SSHTerminalView)

- `makeNSView` liest Font/Größe/Cursor aus dem SettingsStore (injiziert als
  Parameter, kein Singleton) statt der harten 13-pt-Zeile.
- `updateNSView` (heute leer) appliziert Änderungen LIVE: Font-Objekt neu
  auflösen und setzen (SwiftTerm reflowt; Resize→SSH window-change läuft über
  den bestehenden Delegate), Cursor-Stil setzen. Nur bei tatsächlicher
  Änderung anfassen (Vergleich), damit reguläre SwiftUI-Re-Renders das
  Terminal nicht stören.
- Font-Auflösung: gespeicherter Name → `NSFont(name:size:)`; nicht (mehr)
  vorhanden → System-Monospace-Fallback. Nie ein leeres/kaputtes Terminal.
- Farben/Theme: UNVERÄNDERT (DesignTokens Tiefsee/Phosphor).

## 3. Settings-UI

- Neuer Tab „Terminal" (nach „Öffnen mit"): Font-Popup (nur Fixed-Pitch-
  Fonts des Systems, oberster Eintrag „System (SF Mono)" = nil), Größe-
  Stepper 9–24, Cursor-Picker (Block/Balken/Unterstrich) + Toggle „Blinken",
  darunter eine kleine Live-Vorschau-Zeile im Tiefsee-Look (statisch
  gerenderter Beispieltext mit gewähltem Font/Größe).
- Keys EN/DE.

## 4. Remote-Home beim Connect

- `RemoteFileSystem`-Protocol: `homeDirectoryPath() async throws -> String`.
  - `CitadelFileSystem`: SFTP `realpath "."` (Citadel `getRealPath`).
  - `LocalFileSystem`: `NSHomeDirectory()`.
  - `MockRemoteFileSystem`: konfigurierbar (Default `/`).
- `startSession` löst das Home EINMAL beim Connect auf und erzeugt das
  Remote-VM mit diesem `startPath`; Fehler ⇒ stiller Fallback `/` (Verhalten
  wie bisher). Kein erneutes Auflösen bei Refresh/Navigation.

## 5. Tests

- Store: Defaults, Klemmung 9–24 (Setzen/Lesen, Raw-JSON), unbekannter
  Cursor-RawValue liest als `block`, Roundtrip, alte settings.json ohne
  Keys ⇒ Defaults.
- Cursor-Mapping: 6 Kombinationen (3 Stile × Blink an/aus) eindeutig.
- FS: Mock-`homeDirectoryPath` (konfiguriert + Fehlerfall); gated
  Citadel-Test: `homeDirectoryPath()` liefert absoluten Pfad (beginnt mit
  `/`) und `list` darauf funktioniert.
- App (Popup, Live-Anwendung, Vorschau): visueller Smoke (T3).

## 6. Bewusst NICHT in M9d

- Keine Farb-/Theme-Auswahl (CI bleibt fest); keine ANSI-Palette-Settings.
- Kein Zeilenabstand/Padding-Setting.
- Keine Pro-Session-Terminal-Settings (global genügt).
