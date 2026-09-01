# M11b — Update check implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macSCP learns about new versions — comparing the bundle version against the newest GitHub release, a menu entry for a manual check, silent automatic checking at most once daily, a notice with a link to the release page. No auto-download.

**Architecture:** A pure `AppVersion` SemVer type + `UpdateChecker` behind an injectable `ReleaseFetcher` (production `GitHubReleaseFetcher` on `URLSession`), plus a pure interval function; the App reads the bundle version and wires up the menu, dialog, settings toggle, and startup automation. No test touches the real network (mock fetcher + `URLProtocol` stub).

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, Foundation URLSession, SwiftUI/AppKit.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-m11b-update-check-design.md` — binding. Branch: **develop**.
- NO auto-download/installer/Sparkle; the app opens the release page in the browser at most.
- Automatic checking shows something ONLY on a find; no find and every error stay silent. A manually triggered check ALWAYS shows a result.
- The timestamp of the last check gets set after EVERY attempt (errors included).
- No token, no authenticated requests, no user data in the request (only the usual URL + `Accept` + `User-Agent`).
- Unparsable/missing local version ⇒ an honest "version unknown", NEVER an update claim.
- NO test may open a real network connection (mock fetcher or `URLProtocol` stub).
- `SettingsStore` extensions forward-compatible (an old `settings.json` reads defaults).
- Core stays bundle-free: the App layer reads the bundle version and passes it into the checker.
- All new UI text EN/DE in BOTH App catalogs; code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + full `swift test` green after every task (baseline 622 tests / 45 suites); gated suites in T3; tests SYNCHRONOUS in the foreground; TDD red→green for Core.
- NO release, no merge to main.

## Schedule

T1 (Core: AppVersion + UpdateChecker + Fetcher + interval) → T2 (App: settings, automation, menu, dialog, L10n) → T3 (README + closeout, coordinator).

---

### Task 1: AppVersion + UpdateChecker + GitHubReleaseFetcher (Core)

**Files:**
- Create: `Sources/macSCPCore/Updates/AppVersion.swift`, `Sources/macSCPCore/Updates/UpdateChecker.swift`, `Sources/macSCPCore/Updates/GitHubReleaseFetcher.swift`
- Test: `Tests/macSCPCoreTests/AppVersionTests.swift`, `Tests/macSCPCoreTests/UpdateCheckerTests.swift`, `Tests/macSCPCoreTests/GitHubReleaseFetcherTests.swift` (all new)

**Interfaces:**
- Produces (T2 relies on this exactly):
  - `AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible` with `init?(_ string: String)`
  - `ReleaseInfo: Equatable, Sendable` (`tag: String`, `url: URL`)
  - `protocol ReleaseFetcher: Sendable { func latestRelease() async throws -> ReleaseInfo }`
  - `GitHubReleaseFetcher: ReleaseFetcher` (`init(session: URLSession = .shared)`)
  - `UpdateCheckError: Error, Equatable, Sendable` (`offline`, `httpStatus(Int)`, `rateLimited`, `malformedResponse`)
  - `UpdateCheckResult: Equatable, Sendable` (`upToDate(current: AppVersion)`, `updateAvailable(latest: AppVersion, current: AppVersion, url: URL)`, `unknownLocalVersion`, `failed(UpdateCheckError)`)
  - `UpdateChecker` (`init(fetcher: any ReleaseFetcher, currentVersion: String?)`, `func check() async -> UpdateCheckResult`)
  - `UpdateSchedule.shouldCheck(now: Date, lastCheck: Date?, enabled: Bool) -> Bool` (pure function, 24 h rule)

**Behavioral requirements (spec §1/§2, binding):**
1. `AppVersion`: accepts `1.2.3` and `v1.2.3`; pre-release tag after `-`; build metadata after `+` is stripped and ignored; anything else (empty, `abc`, `1.2`, `1.2.x`) ⇒ nil. Comparison: major→minor→patch numeric; equal numbers ⇒ a version WITH a pre-release tag is less than one without; two pre-release tags compare field by field (fields split on `.`; purely numeric fields numeric, otherwise lexicographic; fewer fields ⇒ smaller). `description` returns the normalized form without `v`.
2. `UpdateChecker.check()`: `currentVersion` nil or unparsable ⇒ `.unknownLocalVersion` WITHOUT network access (the fetcher does not get called — prove this in the test via a counting mock). Otherwise call the fetcher; tag unparsable ⇒ `.failed(.malformedResponse)`; `latest > current` ⇒ `.updateAvailable`, otherwise `.upToDate`. Thrown `UpdateCheckError`s are passed through; every OTHER error ⇒ `.failed(.offline)` (URLSession throws a `URLError` for a missing connection; the mapping happens in the fetcher, the checker only catches the rest).
3. `GitHubReleaseFetcher`: GET on `https://api.github.com/repos/NoiXdev/macSCP/releases/latest`, header `Accept: application/vnd.github+json` and `User-Agent` starting with `macSCP/`; `timeoutInterval` 10 s. Response 200 ⇒ read JSON with `tag_name` and `html_url` (either missing ⇒ `malformedResponse`). 403 or 429 WITH header `x-ratelimit-remaining: 0` ⇒ `rateLimited`; other non-200 ⇒ `httpStatus(code)`. `URLError` ⇒ `offline`.
4. `UpdateSchedule.shouldCheck`: `enabled == false` ⇒ false; `lastCheck == nil` ⇒ true; otherwise `now.timeIntervalSince(lastCheck) >= 24*3600`.

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Prove red.** `swift test --filter AppVersion` etc. → FAIL.
- [x] **Step 3: Implementation** (AppVersion → UpdateSchedule → UpdateChecker → GitHubReleaseFetcher).
- [x] **Step 4: Green + full suite.** `swift test` → 622 + new ones, 0 failures. Additionally prove that no test touches the network (the stub registers as a `URLProtocol` and the test fails if an unexpected URL is requested — note this in the report).
- [x] **Step 5: Commit.** `feat: check GitHub for a newer release`

---

### Task 2: Settings, startup automation, menu, dialog (App)

**Files:**
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (two new values), `Sources/MacSCPApp/MacSCPApp.swift` (menu entry + startup automation), `Sources/MacSCPApp/SettingsView.swift` (or the file with the General tab — find it via grep for `showHiddenFiles`), `Sources/MacSCPApp/ContentView.swift` (dialog state, if that is the natural home — the implementer decides and justifies it), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: settings forward compatibility + clamping/default behavior in the existing settings test file (find via grep for `autoRefreshIntervalSeconds`)

**Interfaces:**
- Consumes (T1): `AppVersion`, `UpdateChecker`, `GitHubReleaseFetcher`, `UpdateCheckResult`, `UpdateCheckError`, `UpdateSchedule.shouldCheck`.
- Produces: `SettingsStore.updateCheckEnabled: Bool` (default true), `SettingsStore.lastUpdateCheck: Date?`.

**Behavioral requirements (spec §3/§4, binding):**
1. Settings: both values forward-compatible (raw JSON without them ⇒ default true or nil respectively); writing persists atomically like the other values.
2. Startup automation: ONCE on app start, concurrently (never blocks startup); only if `UpdateSchedule.shouldCheck(now:lastCheck:enabled:)` is true. Set the timestamp after EVERY attempt (errors included). Display ONLY on `.updateAvailable` — all other results stay silent in the automatic check.
3. Menu entry "Check for Updates…"/German equivalent via `CommandGroup(after: .appInfo)`; a manually triggered check ALWAYS shows a result (find, up to date, version unknown, error message per error kind). If a check is already running, the entry is disabled.
4. Find dialog: title/text "Version %@ is available (installed: %@)"/DE equivalent; buttons "Open Release Page" (`NSWorkspace.shared.open(url)`) and "Later". On "version unknown": its own message, no link. Error messages per `UpdateCheckError` (offline / HTTP status / rate limit / malformed response).
5. Settings (General tab): toggle "Automatically check for updates"/DE with footer text "Checks GitHub for the latest version at most once daily. No data about you is transmitted."/DE equivalent.
6. The local version comes from `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String` — if missing (dev build), that leads via the Core path to `.unknownLocalVersion` (no special handling in the App).
7. All new keys EN/DE in both App catalogs; grep cross-check for key-set equality.

- [x] **Step 1:** settings values + tests (red→green). **Step 2:** menu entry + dialog state + result display. **Step 3:** startup automation. **Step 4:** settings UI toggle. **Step 5:** L10n + cross-check. **Step 6:** `swift build` (0 errors, no new warnings) + full `swift test`. **Step 7:** Commit `feat: offer a manual and a daily update check`.

---

### Task 3: README + closeout (coordinator)

- [x] README section (English, short): what gets requested when (`api.github.com`, at most daily, only the tag + link get read), that no user data is transmitted, where to turn it off. Placement: its own short section after "Known limitations" or as a subsection there — pick the smaller solution.
- [x] Gated suites at the final state: rig `start`, `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all green, zero skips, no leftovers; rig `stop`.
- [ ] Visual smoke test — delegated to the maintainer (checklist: menu entry shows "you're up to date" at the current version; toggle in settings; find dialog against an artificially low bundle version; offline behavior).
- [x] Plan checkboxes, ledger, Opus final review (package via `git merge-base origin/develop HEAD`), fix rounds until "Yes", push develop, `gh run watch`, memory, summary. NO release.
