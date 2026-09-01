# M11b — Update Check (Design)

Date: 2026-07-29 · Status: approved by the maintainer ("works for me")

## Goal

macSCP learns about new versions: comparing its own bundle version
against the latest GitHub release, a menu item for checking by hand, and
a restrained automatic check.

**Maintainer decisions (2026-07-29):**

1. NO auto-download, no installer, no Sparkle — just a notice + a link
   to the release page.
2. Automatic check ON (default), at most ONE check per day, can be
   disabled in settings.

## 1. Version comparison (Core, pure)

- `AppVersion: Comparable, Equatable, Sendable` — parses `1.2.3`,
  `v1.2.3` and pre-release identifiers (`1.2.0-beta.1`).
  `init?(_ string: String)` returns nil for anything unparsable.
- Comparison per SemVer: numeric major→minor→patch; a pre-release
  version is LESS than the same version without a pre-release identifier;
  pre-release identifiers are compared field by field among themselves
  (numeric fields numerically, otherwise lexicographically — the SemVer
  rule).
- Build metadata (`+abc`) is stripped and ignored.

## 2. Checking (Core, injectable)

- `protocol ReleaseFetcher: Sendable { func latestRelease() async throws -> ReleaseInfo }`;
  `ReleaseInfo` (`tag: String`, `url: URL`).
- Production `GitHubReleaseFetcher(session: URLSession = .shared)`:
  GET `https://api.github.com/repos/NoiXdev/macSCP/releases/latest`,
  header `Accept: application/vnd.github+json` and a
  `User-Agent: macSCP/<version>`; timeout 10s; NO token. GitHub returns
  under `/latest` only actual releases (no pre-release versions) —
  an extra filter is unnecessary.
- `UpdateChecker(fetcher:currentVersion:)` with
  `check() async -> UpdateCheckResult`:
  - `.upToDate(current: AppVersion)`
  - `.updateAvailable(latest: AppVersion, current: AppVersion, url: URL)`
  - `.unknownLocalVersion` (bundle version missing/unparsable — affects
    dev builds; the App then claims NOTHING)
  - `.failed(UpdateCheckError)` with
    `offline`, `httpStatus(Int)`, `rateLimited`, `malformedResponse`
- Rate-limit detection: HTTP 403/429 together with
  `x-ratelimit-remaining: 0` ⇒ `.rateLimited` (without a token,
  60 requests/hour/IP applies — unreachable with one check per day, the
  message exists purely for honesty's sake).
- The local version comes from `CFBundleShortVersionString` of
  the main bundle; the App layer reads it and passes it in (Core
  stays bundle-free and testable).

## 3. Automatic check + settings

- `SettingsStore`: `updateCheckEnabled: Bool` (default `true`) and
  `lastUpdateCheck: Date?` — both forward compatible (old
  `settings.json` reads the default or nil respectively).
- On App start: check if `updateCheckEnabled` AND
  (`lastUpdateCheck == nil` OR older than 24h). The timestamp is
  set after EVERY attempt — even on errors — so a dead
  network connection doesn't knock again on every launch.
- The automatic check shows something ONLY on `.updateAvailable`. No hit, no
  error, no interruption — entirely silent.
- The check runs concurrently and never blocks startup.

## 4. Operation

- Menu item „Nach Updates suchen…" / „Check for Updates…" via
  `CommandGroup(after: .appInfo)` (directly under "About macSCP").
- When triggered by hand it ALWAYS shows a result: a hit, "latest version",
  "version unknown" or the concrete error message.
- Hit dialog: „Version %@ ist verfügbar (installiert: %@)" with
  „Release-Seite öffnen" (`NSWorkspace.shared.open`) and „Später".
- Settings, General tab: toggle „Automatisch nach Updates
  suchen" with footer text „Fragt höchstens einmal täglich bei GitHub nach der
  neuesten Version. Es werden keine Daten über dich übertragen."
- Multi-click protection: if a check is already running, the menu item is
  disabled.

## 5. README

A short section (English) on what is requested when
(`api.github.com`, at most daily, only tag + link are read),
that no user data is transmitted, and where to disable it.

## 6. Tests

- `AppVersion`: parsing (with/without `v`, pre-release, build metadata,
  garbage ⇒ nil), comparison (major/minor/patch, pre-release < release,
  pre-release among themselves).
- `UpdateChecker` with a mock fetcher: all four results; error cases
  offline/HTTP/rate-limit/broken response; unparsable local version.
- The 24-hour logic as a pure function (`shouldCheck(now:lastCheck:enabled:)`)
  — boundary values 23:59 / 24:01, disabled, never checked.
- `GitHubReleaseFetcher` via a `URLProtocol` stub: correct URL and
  headers, tag/URL parsing, 403+`x-ratelimit-remaining: 0` ⇒ `.rateLimited`,
  broken JSON ⇒ `.malformedResponse`. NO test hits the real network.
- Settings forward compatibility (raw JSON without the new fields).

## 7. Breakdown

T1 Core (AppVersion + UpdateChecker + GitHubReleaseFetcher + interval
function) → T2 App (settings toggle, startup automatic check, menu, dialog,
EN/DE) → T3 README + wrap-up (coordinator). NO release.

## 8. Deliberately NOT in M11b

No auto-download/installer/Sparkle, no release-notes display, no
pre-release channel, no token/authenticated requests, no
notification outside the App (no Notification Center).
