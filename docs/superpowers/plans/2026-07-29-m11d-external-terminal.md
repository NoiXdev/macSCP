# M11d — Externes Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die SSH-Sitzung wahlweise im eingebauten Terminal oder in einer externen Terminal-App öffnen (Terminal.app, iTerm, frei wählbare App), ohne dass ein Passwort die App verlässt.

**Architecture:** Reiner `SSHCommandBuilder` (Argumentliste → POSIX-Quoting → Skript-Inhalt), damit alles Sicherheitsrelevante testbar ist; die App schreibt ein kurzlebiges `.command` (0700, eigener Temp-Unterordner mit Startup-Sweep nach M5e-Muster) und öffnet es mit der gewählten App — kein AppleScript, keine Automatisierungs-Berechtigung.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, AppKit (`NSWorkspace`), SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11d-external-terminal-design.md` — bindend. Branch: **develop**.
- **KEIN Passwort verlässt die App** — nicht als Argument, nicht in der Umgebung, nicht in der Zwischenablage, nicht im Skript. Bei Passwort-Verbindungen fragt `ssh` selbst.
- Quoting ist sicherheitsrelevant: jedes Argument EINZELN in Single-Quotes, enthaltene `'` nach POSIX-Muster (`'\''`). Ein Test muss beweisen, dass Sonderzeichen (Semikolon, Backtick, `$(...)`, Leerzeichen, Quote) nicht ausbrechen.
- Kein AppleScript, keine app-spezifische Automatisierung, keine neuen Entitlements.
- Skript: Rechte 0700, eigener Temp-Unterordner, Selbstlöschung vor `exec`, Startup-Sweep (Muster `EditSessionManager`).
- Fehler ehrlich und typisiert: fehlende/ungültige App und Schreibfehler sind eigene Fälle; KEIN stiller Rückfall auf eine andere App oder aufs eingebaute Terminal.
- Die Einstellung nimmt keine Fähigkeit weg: beide Wege bleiben über Menüeinträge erreichbar.
- KEIN Test startet einen Prozess oder öffnet eine App.
- Alle neuen UI-Texte EN/DE in BEIDEN App-Katalogen; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 670 Tests / 50 Suiten); gated Suiten in T3; Tests SYNCHRON im Vordergrund; TDD rot→grün für Core.
- KEIN Release, kein Merge nach main.

## Schedule

T1 (Core: Argumentbau + Quoting + Skript-Inhalt) → T2 (App: Settings, Start, Menüs, Hinweis, Fehler, Sweep) → T3 Abschluss (Koordinator).

---

### Task 1: SSHCommandBuilder (Core)

**Files:**
- Create: `Sources/macSCPCore/SSH/SSHCommandBuilder.swift`
- Test: `Tests/macSCPCoreTests/SSHCommandBuilderTests.swift` (neu)

**Interfaces:**
- Consumes: `SSHConnectionConfig` (inkl. `AuthMethod` mit `.password`/`.privateKey`/`.agent` und `Jump`).
- Produces (T2 verlässt sich exakt hierauf):
  - `SSHCommandBuilder.arguments(for config: SSHConnectionConfig) -> [String]`
  - `SSHCommandBuilder.shellCommand(for config: SSHConnectionConfig) -> String` (die gequotete `ssh …`-Zeile)
  - `SSHCommandBuilder.scriptContents(for config: SSHConnectionConfig) -> String` (vollständiger Skript-Text)

**Verhaltens-Anforderungen (Spec §1/§2, bindend):**
1. `arguments`: Reihenfolge `["-p","<port>"]` (NUR wenn `port != 22`), `["-l","<username>"]`, `["-i","<keyPath>"]` (NUR bei `.privateKey`), `["-J","<jumpUser>@<jumpHost>[:<jumpPort>]"]` (NUR wenn `config.jump != nil`; `:<port>` nur wenn `!= 22`), zuletzt `config.host`. `.agent` und `.password` erzeugen KEIN zusätzliches Argument.
2. Ein Passwort darf in KEINER Ausgabe vorkommen — auch nicht die Passphrase eines Keys (es wird nur der Pfad übergeben).
3. `shellCommand`: `ssh` gefolgt von den Argumenten, jedes EINZELN in Single-Quotes, enthaltene `'` als `'\''`. Ergebnis muss für eine POSIX-Shell exakt die Argumentliste aus (1) reproduzieren.
4. `scriptContents`: erste Zeile `#!/bin/sh`, dann eine Zeile, die das Skript selbst entfernt (`rm -f -- "$0"`), dann `exec ` + `shellCommand`. Genau EIN `exec ssh` im Text.
5. Reine Funktionen — kein Dateisystem, kein Prozess, keine Umgebung.

- [ ] **Step 1: Failing Tests**

```swift
    // SSHCommandBuilderTests:
    // passwordAuthOnlyUsesLoginAndHost: port 22, .password ->
    //   ["-l","tim","example.com"] (KEIN -p, kein -i).
    // nonDefaultPortAddsDashP: port 2222 -> beginnt mit ["-p","2222"].
    // privateKeyAddsIdentity: .privateKey(keyPath: "/k") -> enthält
    //   ["-i","/k"]; die Passphrase taucht NICHT auf (Config mit
    //   passphrase "geheim" -> shellCommand enthält "geheim" NICHT).
    // agentAuthAddsNothing: .agent -> gleiche Argumente wie .password.
    // jumpAddsDashJ: jump (host "b", user "j", port 22) -> enthält
    //   ["-J","j@b"]; mit port 2022 -> ["-J","j@b:2022"].
    // jumpAndKeyTogether: beides gesetzt -> beide Argumente vorhanden.
    // quotingIsSafe (parametrisiert): Key-Pfad "/pfad mit leer/id",
    //   Benutzername "ti'm", Host "a;rm -rf /", Host "$(whoami)",
    //   Host "`id`" -> shellCommand enthält KEINE unmaskierte Metazeichen-
    //   Wirkung: jedes Argument steht vollständig in Single-Quotes und
    //   jedes enthaltene ' ist als '\'' maskiert (Assertion über den
    //   erzeugten String, plus Gegenprobe: Zerlegen des Strings nach
    //   POSIX-Quoting-Regeln ergibt wieder exakt `arguments(for:)`).
    // scriptContentsShape: beginnt mit "#!/bin/sh", enthält
    //   'rm -f -- "$0"' VOR dem exec, genau ein "exec ssh",
    //   und kein Passwort/keine Passphrase.
```

- [ ] **Step 2: Rot beweisen.** `swift test --filter SSHCommandBuilder` → FAIL.
- [ ] **Step 3: Implementierung.**
- [ ] **Step 4: Grün + volle Suite.** `swift test` → 670 + neue.
- [ ] **Step 5: Commit.** `feat: build an ssh command line for external terminals`

---

### Task 2: Einstellung, Start, Menüs, Hinweis (App)

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (drei neue Werte), `Sources/MacSCPApp/ContentView.swift` (Toolbar-Knopf/⌘T-Verhalten + Start + Fehler-Alert + Hinweis), `Sources/MacSCPApp/MacSCPApp.swift` (Menüeinträge), die Settings-View mit dem Terminal-Tab (grep `terminalFontName`), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Create: `Sources/MacSCPApp/ExternalTerminalLauncher.swift`
- Test: Settings-Vorwärtskompatibilität + Roundtrip in der bestehenden Settings-Testdatei

**Interfaces:**
- Consumes (T1): `SSHCommandBuilder.scriptContents(for:)`; bestehend: `EditSessionManager`s Sweep-Muster (`macscp-edit`) als Vorbild für den eigenen Ordner, `SSHConnectionConfig` der laufenden Session (inkl. aufgelöstem Jump — dieselben Werte, die der Connect benutzt hat).
- Produces: `SettingsStore.terminalTarget: TerminalTarget` (`builtIn`/`terminalApp`/`iTerm`/`custom`, Default `builtIn`), `SettingsStore.customTerminalAppPath: String?`, `SettingsStore.externalTerminalPasswordHintShown: Bool`.

**Verhaltens-Anforderungen (Spec §3/§4, bindend):**
1. Settings vorwärtskompatibel (altes JSON ⇒ `builtIn`, nil, false); Roundtrip aller Fälle inkl. `custom` + Pfad.
2. `ExternalTerminalLauncher.open(config:target:customPath:)`: schreibt `scriptContents` nach `<temp>/macscp-terminal/<uuid>.command` mit Rechten **0700**, öffnet es mit der Ziel-App über `NSWorkspace` (`open(_:withApplicationAt:configuration:)`); wirft typisierte Fehler `applicationNotFound(String)` und `scriptWriteFailed(String)`.
3. App-Auflösung: `terminalApp` ⇒ Bundle-ID `com.apple.Terminal`, `iTerm` ⇒ `com.googlecode.iterm2`, `custom` ⇒ gespeicherter Pfad. Nicht auffindbar/ungültig ⇒ `applicationNotFound` mit Namen/Pfad in der Meldung; KEIN Rückfall.
4. Startup-Sweep für `<temp>/macscp-terminal` analog `EditSessionManager` (dort nachschauen und dasselbe Muster verwenden).
5. ⌘T und der Toolbar-Knopf folgen `terminalTarget`: `builtIn` ⇒ heutiges Umschalten; sonst ⇒ externes Öffnen. ZUSÄTZLICH zwei Menüeinträge, die immer beide Wege anbieten („Terminal ein-/ausblenden" und „Im externen Terminal öffnen"), beide nur bei verbundener Session aktiv.
6. Passwort-Hinweis: ist die Auth der Session `.password` und `externalTerminalPasswordHintShown == false`, VOR dem Öffnen ein Hinweis (EN „macSCP can't hand a saved password to an external terminal — ssh will ask you for it there." / DE „macSCP kann ein gespeichertes Passwort nicht an ein externes Terminal übergeben — ssh fragt dort danach.") mit „Nicht mehr anzeigen"/„Don't show again" (setzt das Flag) und „Öffnen"/„Open". Danach öffnen.
7. Fehler aus (2)/(3) erscheinen als Alert mit der konkreten Meldung.
8. Alle neuen Keys EN/DE in beiden App-Katalogen; Grep-Gegenprobe.

- [ ] **Step 1:** Settings-Werte + Tests (rot→grün). **Step 2:** Launcher + Sweep. **Step 3:** ⌘T/Toolbar + Menüeinträge. **Step 4:** Passwort-Hinweis + Fehler-Alerts. **Step 5:** Settings-UI (Auswahl + App-Picker). **Step 6:** L10n + Gegenprobe. **Step 7:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test`. **Step 8:** Commit `feat: open the session in an external terminal`.

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten am finalen Stand: Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips, keine Leichen; Rig `stop`.
- [ ] Visueller Smoke — an den Maintainer delegiert (Checkliste: Auswahl in den Einstellungen inkl. „Eigene App"; ⌘T folgt der Einstellung; beide Menüeinträge funktionieren; Öffnen mit Key-Verbindung verbindet ohne Nachfrage; Passwort-Verbindung zeigt den Hinweis und `ssh` fragt im Terminal; deinstallierte/ungültige App zeigt die konkrete Meldung; nach dem Start liegt kein Skript mehr in `<temp>/macscp-terminal`).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review (Package über `git merge-base origin/develop HEAD`), Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory, Zusammenfassung. KEIN Release.
