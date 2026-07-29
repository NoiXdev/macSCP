# M11b — Update-Prüfung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macSCP erfährt von neuen Versionen — Abgleich der Bundle-Version gegen das neueste GitHub-Release, Menüeintrag für die Prüfung von Hand, stille Automatik höchstens einmal täglich, Hinweis mit Link zur Release-Seite. Kein Auto-Download.

**Architecture:** Reiner `AppVersion`-SemVer-Typ + `UpdateChecker` hinter einem injizierbaren `ReleaseFetcher` (produktiv `GitHubReleaseFetcher` auf `URLSession`), plus eine reine Intervall-Funktion; die App liest die Bundle-Version, verdrahtet Menü, Dialog, Settings-Schalter und die Start-Automatik. Kein Test geht ins echte Netz (Mock-Fetcher + `URLProtocol`-Stub).

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, Foundation URLSession, SwiftUI/AppKit.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11b-update-check-design.md` — bindend. Branch: **develop**.
- KEIN Auto-Download/Installer/Sparkle; die App öffnet höchstens die Release-Seite im Browser.
- Automatik zeigt NUR bei einem Fund etwas; kein Fund und jeder Fehler bleiben still. Von Hand ausgelöst wird IMMER ein Ergebnis gezeigt.
- Der Zeitstempel der letzten Prüfung wird nach JEDEM Versuch gesetzt (auch bei Fehlern).
- Kein Token, keine authentifizierten Anfragen, keine Nutzerdaten im Request (nur die übliche URL + `Accept` + `User-Agent`).
- Unparsbare/fehlende lokale Version ⇒ ehrliches „Version unbekannt", NIE eine Update-Behauptung.
- KEIN Test darf eine echte Netzwerkverbindung aufbauen (Mock-Fetcher bzw. `URLProtocol`-Stub).
- `SettingsStore`-Erweiterungen vorwärtskompatibel (alte `settings.json` liest Defaults).
- Core bleibt bundle-frei: die Bundle-Version liest die App-Schicht und reicht sie in den Checker.
- Alle neuen UI-Texte EN/DE in BEIDEN App-Katalogen; Code + Kommentare NUR Englisch; keine neuen Dependencies.
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + volle `swift test` nach jedem Task grün (Ausgangslage 622 Tests / 45 Suiten); gated Suiten in T3; Tests SYNCHRON im Vordergrund; TDD rot→grün für Core.
- KEIN Release, kein Merge nach main.

## Schedule

T1 (Core: AppVersion + UpdateChecker + Fetcher + Intervall) → T2 (App: Settings, Automatik, Menü, Dialog, L10n) → T3 (README + Abschluss, Koordinator).

---

### Task 1: AppVersion + UpdateChecker + GitHubReleaseFetcher (Core)

**Files:**
- Create: `Sources/macSCPCore/Updates/AppVersion.swift`, `Sources/macSCPCore/Updates/UpdateChecker.swift`, `Sources/macSCPCore/Updates/GitHubReleaseFetcher.swift`
- Test: `Tests/macSCPCoreTests/AppVersionTests.swift`, `Tests/macSCPCoreTests/UpdateCheckerTests.swift`, `Tests/macSCPCoreTests/GitHubReleaseFetcherTests.swift` (alle neu)

**Interfaces:**
- Produces (T2 verlässt sich exakt hierauf):
  - `AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible` mit `init?(_ string: String)`
  - `ReleaseInfo: Equatable, Sendable` (`tag: String`, `url: URL`)
  - `protocol ReleaseFetcher: Sendable { func latestRelease() async throws -> ReleaseInfo }`
  - `GitHubReleaseFetcher: ReleaseFetcher` (`init(session: URLSession = .shared)`)
  - `UpdateCheckError: Error, Equatable, Sendable` (`offline`, `httpStatus(Int)`, `rateLimited`, `malformedResponse`)
  - `UpdateCheckResult: Equatable, Sendable` (`upToDate(current: AppVersion)`, `updateAvailable(latest: AppVersion, current: AppVersion, url: URL)`, `unknownLocalVersion`, `failed(UpdateCheckError)`)
  - `UpdateChecker` (`init(fetcher: any ReleaseFetcher, currentVersion: String?)`, `func check() async -> UpdateCheckResult`)
  - `UpdateSchedule.shouldCheck(now: Date, lastCheck: Date?, enabled: Bool) -> Bool` (reine Funktion, 24-h-Regel)

**Verhaltens-Anforderungen (Spec §1/§2, bindend):**
1. `AppVersion`: akzeptiert `1.2.3` und `v1.2.3`; Vorab-Kennung nach `-`; Build-Metadaten nach `+` werden abgeschnitten und ignoriert; alles andere (leer, `abc`, `1.2`, `1.2.x`) ⇒ nil. Vergleich: major→minor→patch numerisch; gleiche Zahlen ⇒ Version MIT Vorab-Kennung ist kleiner als ohne; zwei Vorab-Kennungen feldweise (Felder an `.` getrennt; rein numerische Felder numerisch, sonst lexikografisch; weniger Felder ⇒ kleiner). `description` gibt die normalisierte Form ohne `v` zurück.
2. `UpdateChecker.check()`: `currentVersion` nil oder unparsbar ⇒ `.unknownLocalVersion` OHNE Netzzugriff (der Fetcher wird nicht gerufen — im Test über einen zählenden Mock beweisen). Sonst Fetcher rufen; Tag unparsbar ⇒ `.failed(.malformedResponse)`; `latest > current` ⇒ `.updateAvailable`, sonst `.upToDate`. Geworfene `UpdateCheckError` werden durchgereicht; jeder ANDERE Fehler ⇒ `.failed(.offline)` (URLSession wirft für fehlende Verbindung `URLError`; die Zuordnung passiert im Fetcher, der Checker fängt nur den Rest ab).
3. `GitHubReleaseFetcher`: GET auf `https://api.github.com/repos/NoiXdev/macSCP/releases/latest`, Header `Accept: application/vnd.github+json` und `User-Agent` beginnend mit `macSCP/`; `timeoutInterval` 10 s. Antwort 200 ⇒ JSON mit `tag_name` und `html_url` lesen (fehlt eins ⇒ `malformedResponse`). 403 oder 429 MIT Header `x-ratelimit-remaining: 0` ⇒ `rateLimited`; sonstige Nicht-200 ⇒ `httpStatus(code)`. `URLError` ⇒ `offline`.
4. `UpdateSchedule.shouldCheck`: `enabled == false` ⇒ false; `lastCheck == nil` ⇒ true; sonst `now.timeIntervalSince(lastCheck) >= 24*3600`.

- [ ] **Step 1: Failing Tests**

```swift
    // AppVersionTests:
    // parsesPlainAndPrefixed: "1.2.3" und "v1.2.3" -> gleich; description == "1.2.3".
    // parsesPreReleaseAndDropsBuildMetadata: "1.2.0-beta.1+abc" ->
    //   Vorab "beta.1"; "1.2.0+abc" == "1.2.0".
    // rejectsGarbage: "", "abc", "1.2", "1.2.x", "v" -> nil (parametrisiert).
    // ordersByNumericFields: 1.2.3 < 1.10.0 < 2.0.0 (NICHT lexikografisch).
    // preReleaseIsOlderThanRelease: "1.2.0-beta.1" < "1.2.0".
    // preReleaseFieldsCompare: "1.2.0-alpha" < "1.2.0-beta";
    //   "1.2.0-beta.2" < "1.2.0-beta.10" (numerisch!);
    //   "1.2.0-beta" < "1.2.0-beta.1" (weniger Felder ist kleiner).
    //
    // UpdateCheckerTests (CountingMockFetcher: zählt Aufrufe, liefert
    // gestelltes Ergebnis oder wirft):
    // unknownLocalVersionSkipsNetwork: currentVersion nil bzw. "dev" ->
    //   .unknownLocalVersion UND fetcher.callCount == 0.
    // detectsNewerRelease: current "1.0.0", Tag "v1.1.0" ->
    //   .updateAvailable(latest 1.1.0, current 1.0.0, url).
    // sameOrOlderIsUpToDate: Tag "v1.0.0" und Tag "v0.9.0" -> .upToDate.
    // malformedTagFails: Tag "release-xyz" -> .failed(.malformedResponse).
    // fetcherErrorsPropagate: Fetcher wirft .rateLimited/.httpStatus(500)
    //   -> genau dieser Fehler in .failed; ein fremder Fehler -> .failed(.offline).
    //
    // GitHubReleaseFetcherTests (URLProtocol-Stub, KEIN echtes Netz):
    // buildsCorrectRequest: URL, Accept-Header, User-Agent-Präfix "macSCP/".
    // parsesTagAndURL: 200 + JSON -> ReleaseInfo.
    // missingFieldsThrowMalformed: JSON ohne tag_name -> malformedResponse.
    // rateLimitDetected: 403 + x-ratelimit-remaining: 0 -> rateLimited;
    //   403 OHNE den Header -> httpStatus(403).
    // otherStatusThrowsHTTPStatus: 500 -> httpStatus(500).
    //
    // UpdateScheduleTests:
    // respectsDisabledAndInterval: enabled false -> false; lastCheck nil ->
    //   true; 23h59m -> false; 24h01m -> true.
```

- [ ] **Step 2: Rot beweisen.** `swift test --filter AppVersion` etc. → FAIL.
- [ ] **Step 3: Implementierung** (AppVersion → UpdateSchedule → UpdateChecker → GitHubReleaseFetcher).
- [ ] **Step 4: Grün + volle Suite.** `swift test` → 622 + neue, 0 Failures. Zusätzlich beweisen, dass kein Test ins Netz geht (der Stub registriert sich als `URLProtocol` und der Test schlägt fehl, wenn eine unerwartete URL angefragt wird — im Report festhalten).
- [ ] **Step 5: Commit.** `feat: check GitHub for a newer release`

---

### Task 2: Settings, Start-Automatik, Menü, Dialog (App)

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (zwei neue Werte), `Sources/MacSCPApp/MacSCPApp.swift` (Menüeintrag + Start-Automatik), `Sources/MacSCPApp/SettingsView.swift` (bzw. die Datei mit dem Allgemein-Tab — per grep `showHiddenFiles`), `Sources/MacSCPApp/ContentView.swift` (Dialog-State, falls dort das natürliche Zuhause ist — der Implementer entscheidet und begründet), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: Settings-Vorwärtskompatibilität + Klemm-/Default-Verhalten in der bestehenden Settings-Testdatei (per grep `autoRefreshIntervalSeconds`)

**Interfaces:**
- Consumes (T1): `AppVersion`, `UpdateChecker`, `GitHubReleaseFetcher`, `UpdateCheckResult`, `UpdateCheckError`, `UpdateSchedule.shouldCheck`.
- Produces: `SettingsStore.updateCheckEnabled: Bool` (Default true), `SettingsStore.lastUpdateCheck: Date?`.

**Verhaltens-Anforderungen (Spec §3/§4, bindend):**
1. Settings: beide Werte vorwärtskompatibel (Raw-JSON ohne sie ⇒ Default true bzw. nil); Schreiben persistiert atomar wie die übrigen Werte.
2. Start-Automatik: beim App-Start EINMAL, nebenläufig (blockiert den Start nie); nur wenn `UpdateSchedule.shouldCheck(now:lastCheck:enabled:)` true ist. Zeitstempel nach JEDEM Versuch setzen (auch bei Fehlern). Anzeige NUR bei `.updateAvailable` — alle anderen Ergebnisse bleiben in der Automatik still.
3. Menüeintrag „Nach Updates suchen…"/„Check for Updates…" via `CommandGroup(after: .appInfo)`; von Hand ausgelöst wird IMMER ein Ergebnis gezeigt (Fund, aktuell, Version unbekannt, Fehlermeldung je Fehlerart). Läuft bereits eine Prüfung, ist der Eintrag deaktiviert.
4. Fund-Dialog: Titel/Text „Version %@ ist verfügbar (installiert: %@)"/EN-Pendant; Buttons „Release-Seite öffnen" (`NSWorkspace.shared.open(url)`) und „Später". Bei „Version unbekannt": eigene Meldung, kein Link. Fehlermeldungen je `UpdateCheckError` (offline / HTTP-Status / Rate-Limit / kaputte Antwort).
5. Einstellungen (Allgemein-Tab): Schalter „Automatisch nach Updates suchen"/EN mit Fußtext „Fragt höchstens einmal täglich bei GitHub nach der neuesten Version. Es werden keine Daten über dich übertragen."/EN-Pendant.
6. Die lokale Version kommt aus `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String` — fehlt sie (Dev-Build), führt das über den Core-Pfad zu `.unknownLocalVersion` (keine Sonderbehandlung in der App).
7. Alle neuen Keys EN/DE in beiden App-Katalogen; Grep-Gegenprobe Key-Set-Gleichheit.

- [ ] **Step 1:** Settings-Werte + Tests (rot→grün). **Step 2:** Menüeintrag + Dialog-State + Ergebnis-Darstellung. **Step 3:** Start-Automatik. **Step 4:** Settings-UI-Schalter. **Step 5:** L10n + Gegenprobe. **Step 6:** `swift build` (0 Fehler, keine neuen Warnungen) + volle `swift test`. **Step 7:** Commit `feat: offer a manual and a daily update check`.

---

### Task 3: README + Abschluss (Koordinator)

- [ ] README-Abschnitt (Englisch, kurz): was wann angefragt wird (`api.github.com`, höchstens täglich, nur Tag + Link werden gelesen), dass keine Nutzerdaten übertragen werden, wo man es abschaltet. Platz: eigener kurzer Abschnitt nach „Known limitations" oder als Unterpunkt dort — die kleinere Lösung wählen.
- [ ] Gated Suiten am finalen Stand: Rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → alle grün, zero skips, keine Leichen; Rig `stop`.
- [ ] Visueller Smoke — an den Maintainer delegiert (Checkliste: Menüeintrag zeigt bei aktueller Version „du bist aktuell"; Schalter in den Einstellungen; Fund-Dialog gegen eine künstlich kleine Bundle-Version; Offline-Verhalten).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review (Package über `git merge-base origin/develop HEAD`), Fix-Runden bis „Yes", Push develop, `gh run watch`, Memory, Zusammenfassung. KEIN Release.
