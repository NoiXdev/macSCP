# M9d — Terminal-Darstellung + Remote-Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Einstellbarer Terminal-Font/-Größe/-Cursor mit Live-Anwendung (Farben bleiben CI) + das Remote-Pane startet beim Connect im Remote-Home statt `/`.

**Architecture:** Vier vorwärtskompatible SettingsStore-Properties + `TerminalCursorStyle`-Enum (Core, getestet); `SSHTerminalView` liest sie in `makeNSView` und appliziert Änderungen in `updateNSView` nur bei echter Differenz; neuer Settings-Tab „Terminal" mit Monospace-Font-Popup und Vorschau; `RemoteFileSystem.homeDirectoryPath()` (Citadel `realpath "."`, Local `NSHomeDirectory()`, Mock konfigurierbar) — `startSession` löst das Home einmal auf.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftTerm (font/caret/cursorStyle-APIs), NSFontManager (Fixed-Pitch-Liste).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m9d-terminal-appearance-design.md` — bindend. Branch: **develop**.
- Farben/Theme UNVERÄNDERT (DesignTokens Tiefsee/Phosphor); nur Font, Größe (9…24 geklemmt beim Setzen UND Lesen), Cursor-Stil (block Default/bar/underline; unbekannter RawValue liest als block) + Blinken (Default true).
- Live-Anwendung in `updateNSView` NUR bei tatsächlicher Änderung (Vergleich) — reguläre Re-Renders dürfen das Terminal nicht anfassen; Font-Fallback: Name nicht auflösbar ⇒ System-Monospace, nie ein kaputtes Terminal.
- Remote-Home: EINMAL beim Connect via `homeDirectoryPath()`; Fehler ⇒ stiller Fallback `/`; kein erneutes Auflösen später.
- Alle neuen UI-Texte EN/DE; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 456 Tests / 36 Suiten); gated Suiten in T1 (Implementer, Rig nötig für den Citadel-Home-Test) und T3; Tests SYNCHRON im Vordergrund.
- TDD für Core; App-Target untestbar → T2 liefert Build + Verhaltensbeschreibung.

## Schedule

T1 (Core: Settings + Cursor-Enum + FS-Home, inkl. gated Test) → T2 (App: Terminal-Tab + SSHTerminalView + Home-Verdrahtung) → T3 Abschluss (Koordinator).

---

### Task 1: Settings-Properties, TerminalCursorStyle, homeDirectoryPath (Core)

**Files:**
- Create: `Sources/macSCPCore/Settings/TerminalCursorStyle.swift`
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift`, `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`, `Sources/macSCPCore/SSH/CitadelFileSystem.swift`, `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`, `Tests/macSCPCoreTests/MockRemoteFileSystem.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`, `Tests/macSCPCoreTests/TerminalCursorStyleTests.swift` (neu), `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (gated), `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` bzw. Mock-Tests (Mock-Home)

**Interfaces:**
- Produces (T2 verlässt sich exakt hierauf):
  - `public enum TerminalCursorStyle: String, Codable, CaseIterable, Sendable { case block, bar, underline }`
  - `SettingsStore.terminalFontName: String?` (Default nil), `terminalFontSize: Int` (13, geklemmt 9…24 Setter+Getter), `terminalCursorStyle: TerminalCursorStyle` (block; unbekannter Raw liest block), `terminalCursorBlink: Bool` (true)
  - `RemoteFileSystem.homeDirectoryPath() async throws -> String` (Protocol-Erweiterung; ALLE Konformen implementieren)
  - `MockRemoteFileSystem`: konfigurierbares Home (Default `/`) + optionaler Fehlermodus

- [ ] **Step 1: Failing Tests.** `TerminalCursorStyleTests.swift` (neu):

```swift
import Testing
@testable import macSCPCore

@Suite("TerminalCursorStyle")
struct TerminalCursorStyleTests {
    @Test func rawValuesAreStable() {
        #expect(TerminalCursorStyle.block.rawValue == "block")
        #expect(TerminalCursorStyle.bar.rawValue == "bar")
        #expect(TerminalCursorStyle.underline.rawValue == "underline")
        #expect(TerminalCursorStyle.allCases.count == 3)
    }

    @Test func sixCursorCombinationsAreDistinct() {
        // The (style, blink) pair is the app-layer's mapping input to
        // SwiftTerm's six cursor modes — pin that all six pairs exist and
        // are distinguishable.
        var seen = Set<String>()
        for style in TerminalCursorStyle.allCases {
            for blink in [true, false] {
                seen.insert("\(style.rawValue)-\(blink)")
            }
        }
        #expect(seen.count == 6)
    }
}
```

`SettingsStoreTests`-Erweiterung (Datei-Muster): Defaults (nil/13/block/true), Größen-Klemmung Setter (8→9, 99→24) UND Getter (Raw-JSON 0→9, 1000→24), unbekannter Cursor-Raw (`"weird"` in Raw-JSON) liest als `.block`, Roundtrip aller vier, alte settings.json ⇒ Defaults. VM/Mock: Test, dass ein konfiguriertes Mock-Home von `homeDirectoryPath()` geliefert wird und der Fehlermodus wirft.

- [ ] **Step 2: Rot beweisen**, dann implementieren: Enum trivial; Settings nach `showHiddenFiles`/`autoRefreshIntervalSeconds`-Muster (String-Optional-Helfer für `terminalFontName` nachschlagen bzw. analog `stringValue/setString` ergänzen, falls nicht vorhanden — Muster `fileAssociations`/`defaultEditorPath` prüfen); `terminalCursorStyle` speichert RawValue-String, Getter `TerminalCursorStyle(rawValue:) ?? .block`.
- [ ] **Step 3: FS-API.** Protocol-Doku-Kommentar: „Resolves the connection's home directory (login landing point). Used once at session start; callers fall back to "/" on failure." Citadel: die SFTP-`realpath`-Fähigkeit existiert (Citadel `SFTPClient` — exakten Methodennamen nachschlagen, ~`getRealPath(atPath: ".")`); Fehler-Mapping wie die übrigen Citadel-Methoden. Local: `NSHomeDirectory()`. Mock: `var homePath: String = "/"` + Fehler-Flag, Konstruktions-kompatibel für alle Bestandstests (Defaults!).
- [ ] **Step 4: Gated Test** (in der Docker-Suite, deren Konventionen folgen; Rig aus dem HAUPT-Checkout starten, `docker compose -f docker/test-server/compose.yml start`, danach LAUFEN LASSEN):

```swift
    @Test func homeDirectoryPathResolvesAbsoluteAndListable() async throws {
        // connect helper of the suite (port 2222)
        // let home = try await fs.homeDirectoryPath()
        // #expect(home.hasPrefix("/"))
        // _ = try await fs.list(path: home)   // landing point must be listable
    }
```

- [ ] **Step 5: Grün + volle Suite (inkl. `MACSCP_ITEST=1 swift test`) + Commit.** `swift test` → 456 + ~10 (echte Zahl festhalten). Commit `feat: add terminal appearance settings and remote home resolution`

---

### Task 2: Terminal-Tab, SSHTerminalView-Live-Anwendung, Home-Start (App)

**Files:**
- Modify: `Sources/MacSCPApp/SSHTerminalView.swift`, `Sources/MacSCPApp/SettingsView.swift`, `Sources/MacSCPApp/ContentView.swift` (startSession: Home auflösen + Terminal-View-Aufrufstelle um settingsStore erweitern), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: keiner (App-Target; Smoke in T3)

**Interfaces:**
- Consumes: alles aus T1; `SSHTerminalView(viewModel:)`-Aufrufstelle in `ContentView.terminalPanel`; `startSession(in:with:storedName:)`.

**Verhaltens-Anforderungen:**
1. `SSHTerminalView` bekommt `let settingsStore: SettingsStore`. `makeNSView`: Font via privater Helfer `resolvedFont()` (`terminalFontName` → `NSFont(name:size:)`, sonst `NSFont.monospacedSystemFont(ofSize:weight:.regular)`; Größe = `terminalFontSize`), Cursor via Mapping (style, blink) → SwiftTerm-Cursor-API (die konkrete SwiftTerm-API nachschlagen: `TerminalView`/`Terminal` bietet Cursor-Stil-Setter — z. B. `setCursorStyle` auf dem `Terminal`; im Report dokumentieren). Farben/Replay/FirstResponder-Zeilen UNVERÄNDERT.
2. `updateNSView`: aktuellen Soll-Font + Soll-Cursor berechnen; NUR wenn `terminal.font` (Name+Größe) bzw. der gemerkte Cursor-Zustand (im Coordinator gespeichert) abweicht, neu setzen. Kommentar: reguläre Re-Renders dürfen das Terminal nicht anfassen.
3. Settings-Tab „Terminal" (nach „Öffnen mit"): Font-Popup — Einträge: „System (SF Mono)" (nil) + alle Fixed-Pitch-Familien (`NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask)` auf Familien reduziert, alphabetisch); Größe-Stepper 9…24; Cursor-Picker (3 Stile, lokalisierte Labels) + Toggle „Blinken"; darunter Vorschau: `Text("deploy@web-01:~ $ ls -la")` im gewählten Font/Größe auf `DesignTokens.terminalBackground` mit Phosphor-Textfarbe, r6-Ecken.
4. Home-Start in `startSession`: VOR der `BrowserSession`-Erzeugung `let home = (try? await fs.homeDirectoryPath()) ?? "/"` und `RemoteBrowserViewModel(fs: fs, startPath: home)`. (`startSession` ist bereits async-fähig? Prüfen — sie wird aus async-Kontexten gerufen; falls sync, den Home-Lookup in den connect-Fluss davor ziehen. Lösung im Report dokumentieren.)
5. Keys EN/DE (Vorschlag): `settings.tab.terminal` „Terminal"/„Terminal", `settings.terminal.font` „Font"/„Schrift", `settings.terminal.systemFont` „System (SF Mono)"/„System (SF Mono)", `settings.terminal.size %lld` „Size: %lld pt"/„Größe: %lld pt", `settings.terminal.cursor` „Cursor"/„Cursor", `settings.terminal.cursor.block/bar/underline` „Block"/„Balken"/„Unterstrich" (EN Block/Bar/Underline), `settings.terminal.cursorBlink` „Blinking"/„Blinken", `settings.terminal.preview` (Vorschau-Zeile bleibt unlokalisierter Beispieltext — KEIN Key nötig, im Report vermerken). Grep-Gegenprobe beide Kataloge.

- [ ] **Step 1:** SSHTerminalView. **Step 2:** Settings-Tab + Keys. **Step 3:** Home-Start. **Step 4:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test` (Stand T1). **Step 5:** Commit `feat: make the terminal appearance configurable and start in the remote home`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün, zero skips.
- [ ] Visueller Smoke (Dev-Wrapper; Maintainer testet ggf. selbst): Verbinden → Remote-Pane startet im HOME (Rig: testuser-Home) statt `/`; Terminal öffnen → Settings: Font wechseln (z. B. Menlo), Größe ändern, Cursor Balken/blinkend → offenes Terminal übernimmt LIVE ohne Inhalt-Verlust; ungültige Größe klemmt; Vorschau folgt; Neustart behält Werte; Regressionen: ⌘T-Replay, Resize→window-change, CI-Farben unverändert.
- [ ] Plan-Checkboxen, Ledger, Opus-Whole-Branch-Final-Review (Base = Commit vor T1), Fixes, Push develop, CI, Rig `stop`, Memory-Update, Milestone-Zusammenfassung (+ M10-Reihenfolge Known Hosts → Login-Sets → Jump-Host als Nächstes; M9e ssh-agent ggf. in M10b-Design einbeziehen — Login-Set-Auth-Art „Agent"; Release-Bündelung weiter offen).
