# M11b — Update-Prüfung (Design)

Datum: 2026-07-29 · Status: vom Maintainer freigegeben („passt")

## Ziel

macSCP erfährt von neuen Versionen: Abgleich der eigenen Bundle-Version
gegen das neueste GitHub-Release, Menüeintrag für die Prüfung von Hand und
eine zurückhaltende Automatik.

**Maintainer-Entscheidungen (2026-07-29):**

1. KEIN Auto-Download, kein Installer, kein Sparkle — nur Hinweis + Link
   zur Release-Seite.
2. Automatik AN (Default), höchstens EINE Prüfung pro Tag, in den
   Einstellungen abschaltbar.

## 1. Versionsvergleich (Core, pur)

- `AppVersion: Comparable, Equatable, Sendable` — parst `1.2.3`,
  `v1.2.3` und Vorab-Kennungen (`1.2.0-beta.1`).
  `init?(_ string: String)` liefert nil für Unparsbares.
- Vergleich nach SemVer: numerisch major→minor→patch; eine Vorab-Version
  ist KLEINER als dieselbe Version ohne Vorab-Kennung; Vorab-Kennungen
  untereinander werden feldweise verglichen (numerische Felder numerisch,
  sonst lexikografisch — die SemVer-Regel).
- Build-Metadaten (`+abc`) werden abgeschnitten und ignoriert.

## 2. Prüfung (Core, injizierbar)

- `protocol ReleaseFetcher: Sendable { func latestRelease() async throws -> ReleaseInfo }`;
  `ReleaseInfo` (`tag: String`, `url: URL`).
- Produktiv `GitHubReleaseFetcher(session: URLSession = .shared)`:
  GET `https://api.github.com/repos/NoiXdev/macSCP/releases/latest`,
  Header `Accept: application/vnd.github+json` und ein
  `User-Agent: macSCP/<version>`; Timeout 10 s; KEIN Token. GitHub liefert
  unter `/latest` ausschließlich echte Releases (keine Vorab-Versionen) —
  ein zusätzlicher Filter entfällt.
- `UpdateChecker(fetcher:currentVersion:)` mit
  `check() async -> UpdateCheckResult`:
  - `.upToDate(current: AppVersion)`
  - `.updateAvailable(latest: AppVersion, current: AppVersion, url: URL)`
  - `.unknownLocalVersion` (Bundle-Version fehlt/unparsbar — betrifft
    Dev-Builds; die App behauptet dann NICHTS)
  - `.failed(UpdateCheckError)` mit
    `offline`, `httpStatus(Int)`, `rateLimited`, `malformedResponse`
- Rate-Limit-Erkennung: HTTP 403/429 zusammen mit
  `x-ratelimit-remaining: 0` ⇒ `.rateLimited` (ohne Token gilt
  60 Anfragen/Stunde/IP — bei einer Prüfung pro Tag unerreichbar, die
  Meldung existiert der Ehrlichkeit halber).
- Die lokale Version kommt aus `CFBundleShortVersionString` des
  Main-Bundles; die App-Schicht liest sie und reicht sie hinein (Core
  bleibt Bundle-frei und testbar).

## 3. Automatik + Einstellungen

- `SettingsStore`: `updateCheckEnabled: Bool` (Default `true`) und
  `lastUpdateCheck: Date?` — beide vorwärtskompatibel (alte
  `settings.json` liest Default bzw. nil).
- Beim App-Start: prüfen, wenn `updateCheckEnabled` UND
  (`lastUpdateCheck == nil` ODER älter als 24 h). Der Zeitstempel wird
  nach JEDEM Versuch gesetzt — auch bei Fehlern —, damit ein toter
  Netzzugang nicht bei jedem Start erneut anklopft.
- Automatik zeigt NUR bei `.updateAvailable` etwas an. Kein Fund, kein
  Fehler, keine Unterbrechung — vollständig still.
- Die Prüfung läuft nebenläufig und blockiert den Start nie.

## 4. Bedienung

- Menüeintrag „Nach Updates suchen…" / „Check for Updates…" via
  `CommandGroup(after: .appInfo)` (direkt unter „Über macSCP").
- Von Hand ausgelöst zeigt er IMMER ein Ergebnis: Fund, „neueste Version",
  „Version unbekannt" oder die konkrete Fehlermeldung.
- Fund-Dialog: „Version %@ ist verfügbar (installiert: %@)" mit
  „Release-Seite öffnen" (`NSWorkspace.shared.open`) und „Später".
- Einstellungen, Tab Allgemein: Schalter „Automatisch nach Updates
  suchen" mit Fußtext „Fragt höchstens einmal täglich bei GitHub nach der
  neuesten Version. Es werden keine Daten über dich übertragen."
- Mehrfachklick-Schutz: läuft bereits eine Prüfung, ist der Menüeintrag
  deaktiviert.

## 5. README

Kurzer Abschnitt (Englisch), was wann angefragt wird
(`api.github.com`, höchstens täglich, nur Tag + Link werden gelesen),
dass keine Nutzerdaten übertragen werden und wo man es abschaltet.

## 6. Tests

- `AppVersion`: Parsen (mit/ohne `v`, Vorab, Build-Metadaten, Müll ⇒ nil),
  Vergleich (major/minor/patch, Vorab < Release, Vorab untereinander).
- `UpdateChecker` mit Mock-Fetcher: alle vier Ergebnisse; Fehlerfälle
  offline/HTTP/Rate-Limit/kaputte Antwort; unparsbare lokale Version.
- 24-Stunden-Logik als reine Funktion (`shouldCheck(now:lastCheck:enabled:)`)
  — Grenzwerte 23:59 / 24:01, deaktiviert, nie geprüft.
- `GitHubReleaseFetcher` über einen `URLProtocol`-Stub: korrekte URL und
  Header, Tag/URL-Parsing, 403+`x-ratelimit-remaining: 0` ⇒ `.rateLimited`,
  kaputtes JSON ⇒ `.malformedResponse`. KEIN Test geht ins echte Netz.
- Settings-Vorwärtskompatibilität (Raw-JSON ohne die neuen Felder).

## 7. Aufteilung

T1 Core (AppVersion + UpdateChecker + GitHubReleaseFetcher + Intervall-
Funktion) → T2 App (Settings-Schalter, Start-Automatik, Menü, Dialog,
EN/DE) → T3 README + Abschluss (Koordinator). KEIN Release.

## 8. Bewusst NICHT in M11b

Kein Auto-Download/Installer/Sparkle, keine Release-Notes-Anzeige, kein
Vorab-Versions-Kanal, kein Token/authentifizierte Anfragen, keine
Benachrichtigung außerhalb der App (kein Notification Center).
