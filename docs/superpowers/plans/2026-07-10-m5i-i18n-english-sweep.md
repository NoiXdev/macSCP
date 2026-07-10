# macSCP M5i — i18n & English-Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der komplette Bestand erfüllt die Sprach-Policy aus CLAUDE.md: Quellcode-Kommentare nur Englisch; ALLE nutzer-sichtbaren Strings laufen über Lokalisierung mit Englisch als Default und funktionierender deutscher Übersetzung (App startet auf Deutsch → deutsche UI).

**Architektur:** Klassische `.lproj`-Lokalisierung statt `.xcstrings` (SwiftPM verarbeitet `en.lproj/Localizable.strings` + `de.lproj/Localizable.strings` nativ — der M5c-Fund: xcstrings werden verbatim kopiert, nie kompiliert). Zwei Ressourcen-Bundles: App-Target (UI-Strings) und Core-Target (Fehler-/Statusmeldungen, die in Core entstehen: `message(for:)`, ConnectionViewModel-Validierung, Host-Key-Warntexte). Beide nutzen einen Bundle-Helfer nach dem Muster von `SettingsResources` (SwiftPMs generierter `Bundle.module`-Accessor fatalErrort ohne danebenliegendes Bundle — Muster liegt in `SettingsView.swift`).

**Tech Stack:** Nur Foundation-Lokalisierung; keine neuen Dependencies.

## Global Constraints

- swift-tools 6.0; ALLE Targets `.swiftLanguageMode(.v5)`; macOS 15; Swift Testing.
- KEINE Verhaltensänderung außer der Sprach-/Lookup-Schicht: Alle 219 Tests bleiben grün (angepasste Assertions prüfen über denselben Lookup, nie über hartkodierte Sprachliteral-Duplikate).
- Kommentar-Sweep ist REIN mechanisch: Bedeutung 1:1 übersetzen, Fachbegriffe/Invarianten-Formulierungen präzise erhalten (z. B. „exactly-once", „Hard-Stop"), KEINE Umformulierung von Logik, keine Code-Änderungen im selben Hunk außer dem Kommentar.
- Sicherheitskritische Texte (Host-Key-Mismatch-Warnung!) müssen in BEIDEN Sprachen die volle Schärfe behalten („Möglicher Man-in-the-Middle" / "Possible man-in-the-middle attack").
- Gated Tests: `MACSCP_ITEST=1` (Rig aus Haupt-Checkout), `MACSCP_KEYCHAIN=1`.
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Implementierer pushen nicht.

**Abhängigkeitsgraph:** `[ T1 (App-Layer) ∥ T2 (Core-Layer + Tests) ] → T3 (Abschluss)` — dateidisjunkt bis auf `Package.swift` (T1 ändert nur den MacSCPApp-Block [xcstrings→lproj im selben Resources-Ordner: KEINE Manifest-Änderung nötig], T2 ergänzt `resources` NUR am macSCPCore-Target — Merge konfliktfrei bzw. trivial).

---

### Task 1: App-Layer — UI-Strings in `.lproj` (EN/DE) + Kommentare Englisch

**Files:**
- Create: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings`, `Sources/MacSCPApp/Resources/de.lproj/Localizable.strings`
- Delete: `Sources/MacSCPApp/Resources/Localizable.xcstrings`
- Modify: ALLE Dateien unter `Sources/MacSCPApp/` (Strings + Kommentare): `ContentView.swift`, `ConnectionFormView.swift`, `SessionSidebar.swift`, `TransferQueueBar.swift`, `SettingsView.swift`, `SSHTerminalView.swift`, `RemoteFileTableView.swift`, `RemoteFilePromise.swift`, `BrowserPane.swift`, `TransferRateFormatting.swift`(nur Kommentare), `DesignTokens.swift`, `MacSCPApp.swift`, `FileListFormatter`-Konsumenten falls App-seitig.

**Bindend:**
1. **Inventar zuerst** (im Report dokumentieren): `grep -n` über alle App-Dateien nach String-Literalen in `Text(`, `Label(`, `Button(`, `.help(`, `placeholder`, `Toggle(`, `TabItem`, Alert/Sheet-Texten, Fenstertiteln. Jeder nutzer-sichtbare String bekommt einen Key.
2. Key-Konvention: flach, prefix-gruppiert, Englisch als Key-Sprache NICHT verwenden — Keys sind stabile Bezeichner (`connection.title`, `connection.field.host`, `transfers.pending %lld`, `conflict.title`, `conflict.overwrite`, `terminal.ended`, `sidebar.imported`, `settings.tab.transfers`, …). EN-`.strings` = Default-Texte (die bisherigen deutschen Texte sinnvoll ins Englische übersetzt), DE-`.strings` = die bisherigen deutschen Texte.
3. Lookup: einen kleinen App-weiten Helfer `L10n.string(_ key:)`/`L10n.text(_ key:)` (Umbenennung/Verallgemeinerung von `SettingsResources` — EINE Quelle, `SettingsView` zieht mit um). SwiftUI-Views nutzen `Text(L10n…)`/`String(localized:bundle:)`-Formen; Format-Strings (z. B. „%lld ausstehend") über `String(format: L10n.string(…), n)` bzw. `String(localized:)`-Interpolation.
4. Die 5 Settings-Strings aus dem xcstrings-Katalog wandern 1:1 in die `.strings`-Dateien; xcstrings wird gelöscht. `Package.swift` bleibt unverändert (Resources-Ordner ist schon deklariert; `.process` verarbeitet lproj korrekt).
5. **Kommentar-Sweep App-Layer:** jeder deutsche Kommentar (auch MARK-Zeilen) → präzises Englisch.
6. **DE-Render-Beweis (bindend, headless):** kleiner ausführbarer Check — z. B. `swift test` mit einem NEUEN Unit-Test im App-… App hat kein Testtarget → stattdessen: Mini-Verifikation via `swift run`?? Nicht nötig kompliziert: BINDEND ist ein Bundle-Lookup-Test im CORE-Testtarget geht nicht (App-Bundle). Stattdessen: Verifikations-Skript im Report — `defaults`-freier Direkt-Check: das gebaute `.build/debug/macSCP_MacSCPApp.bundle` MUSS `de.lproj/Localizable.strings` und `en.lproj/Localizable.strings` enthalten (ls im Report) UND ein 10-Zeilen-Swift-Schnipsel (swiftc, temporär, nicht committen) lädt das Bundle und assertet `localizedString(forKey: "connection.title", …, table: nil)` in beiden lprojs unterschiedlich/korrekt. Visueller App-auf-Deutsch-Beweis folgt in T3.
7. Kein String bleibt hartkodiert (Suche im Report: `grep -rn '"' Sources/MacSCPApp --include='*.swift'` gefiltert auf verbliebene sichtbare Literale — begründete Ausnahmen: reine Symbole, SF-Symbol-Namen, Format-Konstanten, Bundle-IDs).

- [x] Inventar → `.strings` EN+DE anlegen → Views umstellen → Kommentare EN → Bundle-Beweis → `swift build && swift test` (219 grün, keine neuen Tests nötig) → Headless-Launch-Check → Commit `refactor: localize app ui strings and translate comments to english` (mit Footer).

---

### Task 2: Core-Layer — Meldungen lokalisieren + Kommentare Englisch + Tests locale-fest

**Files:**
- Create: `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`, `Sources/macSCPCore/Resources/de.lproj/Localizable.strings`, `Sources/macSCPCore/Resources/CoreL10n.swift`(Bundle-Helfer)
- Modify: `Package.swift` (NUR macSCPCore-Target: `resources: [.process("Resources")]`)
- Modify: ALLE Dateien unter `Sources/macSCPCore/` und `Sources/MacSCPCLI/` (Kommentare; Meldungs-Erzeuger auf Lookup), alle `Tests/macSCPCoreTests/*` (Kommentare + Assertions).

**Bindend:**
1. **Meldungs-Inventar** (Report): alle nutzer-sichtbaren Strings, die in Core entstehen — `TransferQueueViewModel.message(for:)` (4 Fälle + Fallback), Konflikt-/Rename-Fehler („Kein freier Name…"), `ConnectionViewModel`-Validierungen („Port muss eine Zahl sein." usw.) + Host-Key-Texte (Erst-Verbindung/Mismatch-Warnung — VOLLE Schärfe in beiden Sprachen), Terminal-Meldungen („Shell beendet…", „…unterstützt kein Terminal."), `RemoteFSError`-reasons die durchscheinen? — reasons sind laut Policy ENGLISCH (Log-Charakter): reasons werden NICHT lokalisiert, sondern auf Englisch normalisiert; die UI-Meldung drumherum ist lokalisiert.
2. Gleiches Key-Schema (`core.transfer.notFound %@`, `core.connect.portNumeric`, `core.hostkey.mismatch %@ %@ %@`, …); EN = Default-Text, DE = bisheriger deutscher Text. Lookup via `CoreL10n` (Bundle-Probing-Muster wie `SettingsResources`, aber für das Core-Bundle `macSCP_macSCPCore.bundle`; in Tests funktioniert `Bundle.module` regulär — Helfer probiert `Bundle.module`-Pfade defensiv OHNE fatalError).
3. **Test-Anpassung (kritisch, bindend):** Tests, die exakte deutsche Meldungen asserten, prüfen künftig gegen DENSELBEN Lookup (`CoreL10n`-Aufruf im Test) — nie gegen neu hartkodierte Literale. Damit sind die Tests locale-unabhängig und pinnen die Key-Verdrahtung. UI-Statuslabels („übersprungen"/„abgebrochen"/„wartet") sind APP-Strings (T1) — Core-Status bleibt Enum.
4. **Kommentar-Sweep Core+Tests+CLI:** priorisiert die drei Misch-Dateien (`TransferEngine`, `TransferQueueViewModel`, `CitadelFileSystem`), dann alle übrigen (RemoteFS/, SSH/, Sessions/, Presentation/, Settings/, CLI, alle Tests). MARK-Zeilen inklusive. Deutsche IDENTIFIER (falls vorhanden — grep nach Umlauten/`ae|oe|ue`-Verdacht) mitziehen, sofern nicht public-API-brechend; public API ist bereits englisch.
5. Die zwei Doc-Notes aus dem M5c-Final-Review einarbeiten (englisch): Post-Write-Check-Kommentar um den benignen cancel-nach-letztem-Chunk-Fall ergänzen; das ist Kommentararbeit, hier miterledigt.
6. `RemoteFSError`-reason-Strings, die heute deutsch sind (z. B. „Pfad existiert als Datei: …", „known_hosts nicht lesbar: …", „Shell konnte nicht geöffnet werden…", „Diese Verbindung unterstützt kein Terminal.") → ENGLISCH normalisieren (Policy: reasons = englische Log-Strings); wo eine UI sie heute 1:1 zeigt, entsteht die deutsche Fassung über die lokalisierte Hüll-Meldung (`message(for:)`-Pfad). Tests, die reasons prüfen, ziehen auf die englischen reasons um.

- [x] Inventar → Resources+Helfer → Meldungs-Erzeuger umstellen → reasons EN → Tests auf Lookup/EN-reasons → Kommentar-Sweep → `swift build && swift test` (219 grün) → gated NICHT nötig (T3) → Commit `refactor: localize core messages and translate comments to english` (mit Footer).

---

### Task 3: Abschluss-Verifikation

- [x] `swift test` gesamt (219 erwartet) + Rig hoch, `MACSCP_ITEST=1` voll (219-Äquivalent gated), `MACSCP_KEYCHAIN=1` 2/2 — die gated Suiten beweisen, dass die reason-Normalisierung keine Integrationspfade bricht.
- [x] **Rest-Grep-Nachweis:** `grep -rn` über `Sources/ Tests/` nach verbliebenen deutschen Kommentaren/Strings (Umlaut-Suche `[äöüÄÖÜß]` + Stichproben häufiger Wörter) — Ergebnis LEER bis auf `de.lproj`-Dateien und begründete Ausnahmen (im Commit dokumentiert).
- [x] **Visueller Sprach-Beweis** (Bildschirm frei): App normal starten → UI ENGLISCH (Default, da System… System ist deutsch → App folgt System: DEUTSCH! Also: normal starten → DEUTSCH sichtbar (Formular „Neue Verbindung" etc. aus de.lproj — jetzt ECHT aus dem Katalog); dann mit erzwungenem Englisch starten (`defaults write dev.noidee.macscp.dev AppleLanguages '("en")'` bzw. Launch-Argument `-AppleLanguages "(en)"` via `open --args`) → UI ENGLISCH. Beide Screenshots im Ledger vermerken; danach das defaults-Override wieder ENTFERNEN.
- [x] Kurzer Funktions-Smoke (verbinden, ein Transfer, ein Konflikt-Sheet in der aktiven Sprache).
- [x] Checkboxen, Commit `docs: mark M5i plan tasks as completed` (mit Footer).

## Ausblick

Danach M5d (Resume + Reconnect + Teil-Datei-Aufräumen), M5e (Editor-Integration), M6 (Release; dort: DMG-Packaging muss beide lproj mitnehmen, applyToAll-Recheck-Einzeiler, globaler Drossel-Bucket, Sheet-Default-Action-Review).
