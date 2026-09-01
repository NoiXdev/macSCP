# M11p — Language Switcher + FR/PL Translation Design

**Status:** approved (brainstorming 2026-07-31)
**Milestone:** M11p
**Language:** design doc DE; code/comments EN; UI localized EN/DE/FR/PL

## Goal

An app-own language switcher in Settings (independent of the system
language) plus a complete French (fr) and Polish (pl) translation. The
guard test is extended to FR/PL so that a wrong quotation mark there does
not silently fall back to English (as the M11d blocker did for DE).

Maintainer decisions from the brainstorming:
- **Mechanism:** language switching via an `AppleLanguages` override,
  applied at launch; after switching, a **relaunch button** („macSCP neu
  starten") + a hint text. No live switching (the bundle tables cache).
- **Translation source:** FR/PL are **AI-generated** (technical UI
  context), clearly marked as such; a native speaker should review them
  before a real release. Lands only on `develop`, **no release**.

## Context / current state

- **Catalogs today:** only en + de, per layer.
  - App: `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`
    (**407 keys** per language).
  - Core: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings`
    (**52 keys** per language).
- **Lookups:** `L10n.string` (App, `Sources/MacSCPApp/L10n.swift`) and
  `CoreL10n.string` (Core, `Sources/macSCPCore/L10n/CoreL10n.swift`) resolve
  their bundle manually and delegate the language choice **entirely to
  Foundation** (the `AppleLanguages` key). **No changes to these two files
  are needed** — an override set early takes effect automatically on the
  next launch. Live switching is not possible (bundle tables cache after
  the first lookup) → a restart is inherent.
- **Package.swift:** `defaultLocalization: "en"`. The Core target lists
  lproj **explicitly** (`.process("Resources/en.lproj")`, `…de.lproj`); the
  App target uses `.process("Resources")` (picks up new lproj
  automatically).
- **package-app:** builds the `.app` by hand; a **marker trick**
  (`mkdir … Contents/Resources/{en,de}.lproj`) — macOS only offers a
  language if an (empty) marker lproj exists in the main bundle; only then
  do the real catalogs in the SPM resource bundles become reachable. A
  verification line checks the markers. Info.plist is generated via
  heredoc, **without** `CFBundleLocalizations`.
- **`LocalizableStringsTests`** (`Tests/macSCPCoreTests/`): Swift Testing;
  hardcoded EN/DE paths; checks (a) plist parseability per file (catches a
  wrong quotation mark — `NSDictionary(contentsOfFile:)` returns `nil`) and
  (b) key parity EN↔DE per layer.
- **Settings pattern:** `SettingsStore` (Core, JSON) — the enum-setting
  template `terminalTarget`/`terminalCursorStyle` (its own `enum` file,
  `Keys`, `Defaults`, a computed var with a rawValue fallback). Picker
  template in `TerminalSettingsTab` (`SettingsView.swift`),
  `GeneralSettingsTab` is the place for the language picker.
- **`MacSCPApp.init()`** builds the `SettingsStore` synchronously (reads
  `settings.json`) **before** the first localized lookup (menus/views only
  build in `body`). That is the earliest and correct place for the
  override. There is **no** relaunch helper in the code yet — that is new.

## Architecture

### Core — language enum + setting

- New `Sources/macSCPCore/Settings/AppLanguage.swift`:
  ```swift
  public enum AppLanguage: String, Codable, CaseIterable, Sendable {
      case system, en, de, fr, pl
      /// The AppleLanguages code, or nil for `.system` (no override).
      public var localeCode: String? {
          switch self {
          case .system: return nil
          case .en: return "en"; case .de: return "de"
          case .fr: return "fr"; case .pl: return "pl"
          }
      }
  }
  ```
- `SettingsStore.selectedLanguage: AppLanguage` (default `.system`),
  following the `terminalTarget` pattern (key, default, computed var with
  `AppLanguage(rawValue:) ?? .system`, `persist()`).

### App — application, UI, relaunch

- **`MacSCPApp.init()`**: apply the language immediately after
  `settingsStore` is built and **before** anything else:
  - `let launch = settingsStore.selectedLanguage`
  - if `let code = launch.localeCode`: `UserDefaults.standard.set([code],
    forKey: "AppleLanguages")`
  - otherwise (`.system`): `UserDefaults.standard.removeObject(forKey:
    "AppleLanguages")`.
  - keep `launch` in a `let launchLanguage: AppLanguage` and pass it
    through to `ContentView`/the `Settings` scene (for relaunch
    visibility).
- **`GeneralSettingsTab`**: a new `Section` "Language" with
  `Picker($store.selectedLanguage)` — tags System/en/de/fr/pl. If
  `store.selectedLanguage` diverges from `launchLanguage`, a hint text
  („Wird nach Neustart angewandt") **and** a button „macSCP neu starten"
  appear beneath it.
- **Relaunch helper** (new, App layer): launches, detached,
  `/bin/sh -c "sleep 1; open <Bundle.main.bundlePath>"` and then calls
  `NSApp.terminate(nil)`. A deliberate user action; no `deinit` cleanup
  needed (like a normal quit).

### FR/PL catalogs

- New: `Sources/MacSCPApp/Resources/{fr,pl}.lproj/Localizable.strings`
  (407 keys each, keys exactly as EN, format placeholders unchanged) and
  `Sources/macSCPCore/Resources/{fr,pl}.lproj/Localizable.strings`
  (52 keys each).
- **Quotation marks:** FR « … » (guillemets), PL „ … " (like DE); only
  ASCII `"` as delimiter, never inside a value. A header comment marks the
  catalogs as AI-generated / to be reviewed by a native speaker.
- **Package.swift:** add `.process("Resources/fr.lproj")` +
  `.process("Resources/pl.lproj")` to the Core target. App target
  unchanged.
- **package-app:** extend the marker `mkdir` and the verification
  `test -d` to cover `fr.lproj`/`pl.lproj`; add
  `CFBundleLocalizations = (en, de, fr, pl)` to the Info.plist heredoc.

### Test guard

- Generalize `LocalizableStringsTests`: per layer (App/Core) one EN
  reference and the list of non-EN languages (de, fr, pl); check each
  against EN for key parity, and check **all** catalogs (including en) for
  plist parseability. This way FR/PL does not silently fall back to
  English.

## New UI strings (all 4 languages)

- `settings.general.language.header` = „Language" / „Sprache" / „Langue" /
  „Język"
- `settings.general.language.system` = „System" (or localized)
- `settings.general.language.footer` = a hint that the switch requires a
  restart.
- `settings.general.language.relaunch` = „Relaunch macSCP" (or localized)
- Language names in the picker are shown as **endonyms** (English,
  Deutsch, Français, Polski) — fixed labels, not translated.

## Edge cases

- **`.system` selected while a non-system language was running:** the
  override is removed on the next launch → the app follows the system
  again; the relaunch button is offered.
- **Unknown/broken setting value:** rawValue fallback → `.system`.
- **Catalog broken (wrong quotation mark):** the test fails red → caught
  before merge; at runtime the language would silently fall back to EN
  (exactly what the test prevents).
- **Relaunch during active transfers:** a deliberate user action; treated
  like a normal quit (no special dialog in v1).

## Tests

- **Core (new, red→green):** `SettingsStore.selectedLanguage` — default
  `.system`, roundtrip, rawValue fallback to `.system`.
- **`LocalizableStringsTests` extended:** parity EN↔{DE,FR,PL} per layer +
  parseability of all eight catalog files. (Fails red if FR/PL keys are
  missing or a quotation mark breaks the catalog.)
- **No App test target** for picker/relaunch/`AppleLanguages` —
  verification by build/trace.
- **Runtime smoke test (mandatory):** start a dev build with
  `AppleLanguages` set (e.g. `fr`) → the app starts without a crash, idle
  CPU ~0%. Catches both a language startup failure and a SwiftUI layout
  storm.
- Translation *quality* is not covered by any test → AI labeling + native
  speaker review before release.

## Task breakdown (for the plan)

1. **Core:** `AppLanguage` + `SettingsStore.selectedLanguage` (+ tests).
2. **FR catalogs** App+Core (full translation) + Package.swift + test for
   FR.
3. **PL catalogs** App+Core (full translation) + test for PL.
4. **App switcher:** picker + applying `AppleLanguages` in `init` +
   `launchLanguage` pass-through + relaunch helper/button + new UI strings
   in all 4 languages + package-app marker/Info.plist.
5. **Final verification** (gated, review, runtime smoke test in a non-EN
   language, push, deploy).

FR and PL are kept separate so each translation stays focused and its
review stays manageable.

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD
  where logic is created.
- Code/comments EN; UI strings via the `.strings` catalogs, now
  EN/DE/FR/PL. **No ASCII `"` inside a value** of any non-English catalog
  (breaks the catalog).
- Language selection persists in `SettingsStore` (Core); applied only
  early in `MacSCPApp.init` via `AppleLanguages`, no changes to
  `L10n`/`CoreL10n`.
- **M11n lesson:** check new GUI paths with a runtime idle-CPU smoke test
  before shipping — here, additionally launching in a non-EN language.
- FR/PL are AI-generated and must be reviewed by a native speaker before a
  release.
- No release/tag without explicit maintainer instruction.
