# M11p — Language Switcher + FR/PL Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An app-own language switcher in Settings (via `AppleLanguages` override, applied at launch, a relaunch button to take effect) plus complete FR and PL translation for App + Core, with the catalog guard generalized to all languages.

**Architecture:** Core gets an `AppLanguage` enum + persisted `SettingsStore.selectedLanguage`. `MacSCPApp.init` reads it early and sets `AppleLanguages` (no intervention in `L10n`/`CoreL10n` — those honor the override on the next launch). Two new catalog pairs (fr, pl) per layer; the test guard checks parity+parseability across all languages. A language picker + relaunch button in `GeneralSettingsTab`.

**Tech Stack:** SwiftUI + AppKit, Swift 6 (`.swiftLanguageMode(.v5)`), Swift Testing, macOS 15, SPM resources (`.lproj`).

## Global Constraints

- Swift-tools 6.0, all targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/comments **English only**.
- UI strings via `.strings` catalogs, now EN/DE/FR/PL. **No ASCII `"`** in a value
  of a non-English catalog — a single one breaks the whole catalog (plist parse fails, language
  silently falls back to EN; `LocalizableStringsTests` guards that).
- Format placeholders (`%@`, `%lld`, `%1$@` …) in translations carried over
  **exactly** — count, order, type.
- Language selection persists in `SettingsStore` (Core); applied only early in
  `MacSCPApp.init` via `AppleLanguages`. **No** intervention in `L10n`/`CoreL10n`.
- FR/PL are **AI-generated**, marked via a header comment, to be reviewed by a
  native speaker before release.
- **M11n lesson / runtime smoke test:** new GUI paths must be checked via idle-CPU
  smoke test before shipping — here additionally launched in a non-EN language.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline: **900 tests / 62 suites** green.
- No release/tag without explicit maintainer instruction.

---

### Task 1: Core — AppLanguage + SettingsStore.selectedLanguage

**Files:**
- Create: `Sources/macSCPCore/Settings/AppLanguage.swift`
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`Keys`/`Defaults`/computed var)
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (append three cases)

**Interfaces:**
- Consumes (verified): `SettingsStore` enum pattern — `terminalTarget` (key in `enum Keys`, computed var with `guard case .string(let value)? = raw[Keys.x]` + `X(rawValue:) ?? fallback` + `persist()`); `TerminalTarget` enum file as the template.
- Produces (for Task 4): `AppLanguage` (public, `String`/`Codable`/`CaseIterable`/`Sendable`, cases `system,en,de,fr,pl`, `localeCode: String?`); `SettingsStore.selectedLanguage: AppLanguage` (default `.system`).

- [x] **Step 1: Failing test.** Append to `Tests/macSCPCoreTests/SettingsStoreTests.swift` (pattern as in `menuBarEnabledDefaultsTrue`/`…Roundtrips`):

```swift
    @Test func selectedLanguageDefaultsToSystem() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.selectedLanguage == .system)
        #expect(AppLanguage.system.localeCode == nil)
        #expect(AppLanguage.fr.localeCode == "fr")
    }

    @Test func selectedLanguageRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.selectedLanguage = .pl
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.selectedLanguage == .pl)
    }

    @Test func selectedLanguageFallsBackOnGarbage() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.selectedLanguage = .de
        // Corrupt the on-disk value, then a fresh load must fall back.
        let fileURL = dir.appendingPathComponent("settings.json")
        var raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as! [String: Any]
        raw["appLanguage"] = "klingon"
        try! JSONSerialization.data(withJSONObject: raw).write(to: fileURL)
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.selectedLanguage == .system)
    }
```

- [x] **Step 2: Red.** `swift test --filter SettingsStore`
  Expected: FAIL — `AppLanguage` and `selectedLanguage` do not exist.

- [x] **Step 3: Enum file.** New file `Sources/macSCPCore/Settings/AppLanguage.swift`:

```swift
/// The app's UI language, chosen in Settings independent of the system
/// language (M11p). `.system` follows the OS (no `AppleLanguages` override);
/// the rest map to a locale code applied at launch in `MacSCPApp.init`.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case en
    case de
    case fr
    case pl

    /// The `AppleLanguages` code to apply, or `nil` for `.system` (no
    /// override — the app follows the OS language).
    public var localeCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        }
    }
}
```

- [x] **Step 4: Setting.** In `Sources/macSCPCore/Settings/SettingsStore.swift`:
  - In `enum Keys` (after `menuBarEnabled`): `static let appLanguage = "appLanguage"`.
  - New computed var next to the others (pattern from `terminalTarget`):

```swift
    /// The UI language chosen in Settings (M11p). `.system` (default) means
    /// no `AppleLanguages` override — follow the OS. Applied at launch in
    /// `MacSCPApp.init`; a change needs an app relaunch to take effect.
    public var selectedLanguage: AppLanguage {
        get {
            guard case .string(let value)? = raw[Keys.appLanguage] else {
                return .system
            }
            return AppLanguage(rawValue: value) ?? .system
        }
        set {
            raw[Keys.appLanguage] = .string(newValue.rawValue)
            persist()
        }
    }
```

- [x] **Step 5: Green + suite.** `swift test --filter SettingsStore` → PASS; then `swift test`
  Expected: 900 + 3 = **903 tests** green.

- [x] **Step 6: Commit.**

```bash
git add Sources/macSCPCore/Settings/AppLanguage.swift Sources/macSCPCore/Settings/SettingsStore.swift Tests/macSCPCoreTests/SettingsStoreTests.swift
git commit -m "feat: add AppLanguage and the persisted selectedLanguage setting"
```

---

### Task 2: FR catalogs + Package.swift + generalize the test guard

**Files:**
- Create: `Sources/MacSCPApp/Resources/fr.lproj/Localizable.strings` (407 keys)
- Create: `Sources/macSCPCore/Resources/fr.lproj/Localizable.strings` (52 keys)
- Modify: `Package.swift` (Core resources)
- Modify: `Tests/macSCPCoreTests/LocalizableStringsTests.swift` (switch to a language list, include FR)

**Interfaces:**
- Consumes: the EN catalogs as the translation source (`…/en.lproj/Localizable.strings`, App 407 / Core 52 keys); the DE catalogs as the model for typographic quotation marks.
- Produces (for Task 3): the generalized test structure with a language list per layer, to which Task 3 only appends `"pl"`.

- [x] **Step 1: FR App catalog.** Produce `Sources/MacSCPApp/Resources/fr.lproj/Localizable.strings`: carry over EVERY key from `en.lproj/Localizable.strings` (identical key names, `;` structure), translate the value into **French**. Rules:
  - Leave format placeholders (`%@`, `%lld`, `%1$@`, `⌘⇧.` etc.) unchanged.
  - Quotation marks in the value: French guillemets « … » (never ASCII `"`; ASCII `"` only as the string delimiter). Where the EN/DE value contains no quotation, introduce none.
  - Keyboard-shortcut symbols (⌘⇧Y etc.) unchanged.
  - Header line as a comment: `/* AI-generated French translation (M11p) — review by a native speaker before release. */`

- [x] **Step 2: FR Core catalog.** Produce `Sources/macSCPCore/Resources/fr.lproj/Localizable.strings` analogously from the Core EN catalog (52 keys).

- [x] **Step 3: Package.swift.** Extend the `resources` list in the **Core** target:

```swift
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/fr.lproj"),
            ],
```

(App target unchanged — `.process("Resources")` picks up `fr.lproj` automatically.)

- [x] **Step 4: Generalize the test guard.** Restructure `Tests/macSCPCoreTests/LocalizableStringsTests.swift` so that, per layer, it checks the EN reference against a language list and parses all catalogs. Replace the four `@Test`/`assertIdenticalKeys` blocks (starting at `@Test(arguments:)`) with:

```swift
    /// Non-English languages per layer. Task 3 appends "pl".
    private static let appLangs = ["de", "fr"]
    private static let coreLangs = ["de", "fr"]

    private static func appPath(_ lang: String) -> String {
        "Sources/MacSCPApp/Resources/\(lang).lproj/Localizable.strings"
    }
    private static func corePath(_ lang: String) -> String {
        "Sources/macSCPCore/Resources/\(lang).lproj/Localizable.strings"
    }

    private static var allPaths: [String] {
        [appEnPath, coreEnPath]
            + appLangs.map(appPath) + coreLangs.map(corePath)
    }

    @Test(arguments: LocalizableStringsTests.allPaths)
    func catalogParsesAsAPropertyList(relativePath: String) {
        #expect(
            Self.parse(relativePath) != nil,
            "\(relativePath) failed to parse as a property list — check for an unescaped quote or other syntax error"
        )
    }

    @Test func appLayerLanguagesMatchEnglishKeys() {
        for lang in Self.appLangs {
            assertIdenticalKeys(enPath: Self.appEnPath, otherPath: Self.appPath(lang))
        }
    }

    @Test func coreLayerLanguagesMatchEnglishKeys() {
        for lang in Self.coreLangs {
            assertIdenticalKeys(enPath: Self.coreEnPath, otherPath: Self.corePath(lang))
        }
    }

    private func assertIdenticalKeys(enPath: String, otherPath: String) {
        guard let en = LocalizableStringsTests.parse(enPath) else {
            Issue.record("\(enPath) failed to parse as a property list"); return
        }
        guard let other = LocalizableStringsTests.parse(otherPath) else {
            Issue.record("\(otherPath) failed to parse as a property list"); return
        }
        let missing = Set(en.keys).subtracting(other.keys)
        let extra = Set(other.keys).subtracting(en.keys)
        #expect(missing.isEmpty, "Keys present in \(enPath) but missing from \(otherPath): \(missing.sorted())")
        #expect(extra.isEmpty, "Keys present in \(otherPath) but missing from \(enPath): \(extra.sorted())")
    }
```

(The four path constants `appEnPath`/`appDePath`/`coreEnPath`/`coreDePath` and `parse`/`repoRoot` stay; `appDePath`/`coreDePath` are no longer referenced directly — they may stay or be removed, depending on the compiler's "unused" warning. On a warning, remove them.)

- [x] **Step 5: plutil + suite.**

```bash
plutil -lint Sources/MacSCPApp/Resources/fr.lproj/Localizable.strings
plutil -lint Sources/macSCPCore/Resources/fr.lproj/Localizable.strings
swift test --filter Localizable
```
  Expected: plutil both OK; `Localizable` suite PASS (parity EN↔{DE,FR} + parse of all six files). On a parity failure, add the missing/extra keys; on a parse failure, find the (ASCII) quotation mark in the value and replace it.

- [x] **Step 6: Build + full suite.** `swift build` (clean) and `swift test` → **903** green.

- [x] **Step 7: Commit.**

```bash
git add Sources/MacSCPApp/Resources/fr.lproj Sources/macSCPCore/Resources/fr.lproj Package.swift Tests/macSCPCoreTests/LocalizableStringsTests.swift
git commit -m "feat: add French catalogs and generalize the localization guard"
```

---

### Task 3: PL catalogs + test on PL

**Files:**
- Create: `Sources/MacSCPApp/Resources/pl.lproj/Localizable.strings` (407 keys)
- Create: `Sources/macSCPCore/Resources/pl.lproj/Localizable.strings` (52 keys)
- Modify: `Package.swift` (Core resources)
- Modify: `Tests/macSCPCoreTests/LocalizableStringsTests.swift` (`"pl"` on both language lists)

**Interfaces:**
- Consumes: the EN catalogs as the source; the Task 2 test structure (`appLangs`/`coreLangs` lists).

- [x] **Step 1: PL App catalog.** Produce `Sources/MacSCPApp/Resources/pl.lproj/Localizable.strings` from the EN App catalog (407 keys) into **Polish**. Rules as in Task 2, but quotation marks in the Polish style „ … " (as with DE; never ASCII `"`). Header comment `/* AI-generated Polish translation (M11p) — review by a native speaker before release. */`

- [x] **Step 2: PL Core catalog.** `Sources/macSCPCore/Resources/pl.lproj/Localizable.strings` from the Core EN catalog (52 keys).

- [x] **Step 3: Package.swift.** In the **Core** target append `.process("Resources/pl.lproj")`:

```swift
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/pl.lproj"),
            ],
```

- [x] **Step 4: Test lists.** In `Tests/macSCPCoreTests/LocalizableStringsTests.swift` extend both lists:

```swift
    private static let appLangs = ["de", "fr", "pl"]
    private static let coreLangs = ["de", "fr", "pl"]
```

- [x] **Step 5: plutil + suite.**

```bash
plutil -lint Sources/MacSCPApp/Resources/pl.lproj/Localizable.strings
plutil -lint Sources/macSCPCore/Resources/pl.lproj/Localizable.strings
swift test --filter Localizable
```
  Expected: plutil OK; `Localizable` suite PASS (parity EN↔{DE,FR,PL} + parse of all eight files).

- [x] **Step 6: Build + full suite.** `swift build` clean; `swift test` → **903** green.

- [x] **Step 7: Commit.**

```bash
git add Sources/MacSCPApp/Resources/pl.lproj Sources/macSCPCore/Resources/pl.lproj Package.swift Tests/macSCPCoreTests/LocalizableStringsTests.swift
git commit -m "feat: add Polish catalogs and extend the localization guard"
```

---

### Task 4: App switcher — picker, AppleLanguages, relaunch, package-app

**Files:**
- Create: `Sources/MacSCPApp/AppRelauncher.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (apply `AppleLanguages` in `init`, pass `launchLanguage` through)
- Modify: `Sources/MacSCPApp/SettingsView.swift` (`SettingsView` + `GeneralSettingsTab` get `launchLanguage`; language `Section`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (new UI keys in ALL four)
- Modify: `scripts/package-app` (marker + `CFBundleLocalizations`)

**Interfaces:**
- Consumes (Task 1): `AppLanguage` (`localeCode`), `SettingsStore.selectedLanguage`. Existing: `MacSCPApp.init` (builds `settingsStore` around line 106); `SettingsView(store:updateModel:)` in the `Settings` scene; `GeneralSettingsTab` (`@Bindable var store`, `Form`); `L10n.string`; enum picker pattern (`Picker(..., selection: $store.x) { Text(...).tag(EnumCase) }`).

- [x] **Step 1: Relaunch helper.** New file `Sources/MacSCPApp/AppRelauncher.swift`:

```swift
import AppKit

/// Relaunches the running app (M11p): used after a language change, which
/// only takes effect on a fresh launch (the bundle's localized tables cache
/// after first use). Spawns a detached shell that waits for this process to
/// exit, then reopens the .app, and terminates immediately. A deliberate
/// user action — no `deinit` cleanup needed, same as a normal quit.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
```

- [x] **Step 2: Apply AppleLanguages + launchLanguage.** In `Sources/MacSCPApp/MacSCPApp.swift`:
  - Add a property: `let launchLanguage: AppLanguage`.
  - In `init()`, directly AFTER `let store = SettingsStore(directory: SettingsStore.defaultDirectory)` (line 106) and BEFORE `menuBarController = …`:

```swift
        // Apply the chosen UI language before any localized lookup (M11p).
        // `L10n`/`CoreL10n` defer to Foundation's AppleLanguages resolution,
        // so setting this here (before `body` builds any menu/view) is early
        // enough for a fresh launch; a change made while running needs a
        // relaunch (the bundle tables cache). `.system` clears the override.
        let language = store.selectedLanguage
        if let code = language.localeCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        launchLanguage = language
```

  - Extend the `Settings` scene by the parameter:

```swift
        Settings {
            SettingsView(store: settingsStore, updateModel: updateModel,
                         launchLanguage: launchLanguage)
                .tint(DesignTokens.remoteBlue)
        }
```

- [x] **Step 3: Pass through SettingsView + GeneralSettingsTab.** In `Sources/MacSCPApp/SettingsView.swift`:
  - `SettingsView` gets `let launchLanguage: AppLanguage` and passes it through to `GeneralSettingsTab(store:updateModel:launchLanguage:)` (the tab is built in `SettingsView.body`'s `TabView`).
  - `GeneralSettingsTab` gets `let launchLanguage: AppLanguage`.

- [x] **Step 4: Language section.** Insert into `GeneralSettingsTab.body` (inside the `Form`, e.g. as the first `Section`):

```swift
            Section {
                Picker(
                    L10n.string("settings.general.language.header", "Language"),
                    selection: $store.selectedLanguage
                ) {
                    Text(L10n.string("settings.general.language.system", "System"))
                        .tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.en)
                    Text("Deutsch").tag(AppLanguage.de)
                    Text("Français").tag(AppLanguage.fr)
                    Text("Polski").tag(AppLanguage.pl)
                }
                if store.selectedLanguage != launchLanguage {
                    Button(L10n.string("settings.general.language.relaunch", "Relaunch macSCP")) {
                        AppRelauncher.relaunch()
                    }
                }
            } footer: {
                Text(L10n.string(
                    "settings.general.language.footer",
                    "Takes effect after a relaunch."))
                    .foregroundStyle(.secondary)
            }
```

- [x] **Step 5: UI strings in EN + DE.** Append four keys each in `en.lproj` and `de.lproj`. EN:

```
"settings.general.language.header" = "Language";
"settings.general.language.system" = "System";
"settings.general.language.footer" = "Takes effect after a relaunch.";
"settings.general.language.relaunch" = "Relaunch macSCP";
```

DE (typographic, no ASCII `"` in the value):

```
"settings.general.language.header" = "Sprache";
"settings.general.language.system" = "System";
"settings.general.language.footer" = "Wird nach einem Neustart angewandt.";
"settings.general.language.relaunch" = "macSCP neu starten";
```

- [x] **Step 6: UI strings in FR + PL.** The same four keys in `fr.lproj` and `pl.lproj` (FR guillemets/no ASCII `"`; PL „ "):

FR:

```
"settings.general.language.header" = "Langue";
"settings.general.language.system" = "Système";
"settings.general.language.footer" = "Prend effet après un redémarrage.";
"settings.general.language.relaunch" = "Relancer macSCP";
```

PL:

```
"settings.general.language.header" = "Język";
"settings.general.language.system" = "System";
"settings.general.language.footer" = "Zacznie obowiązywać po ponownym uruchomieniu.";
"settings.general.language.relaunch" = "Uruchom ponownie macSCP";
```

- [x] **Step 7: package-app.** In `scripts/package-app`:
  - Extend the marker line (currently `mkdir "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/de.lproj"`) by `fr.lproj`/`pl.lproj`:

```bash
mkdir "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/de.lproj" \
      "$APP/Contents/Resources/fr.lproj" "$APP/Contents/Resources/pl.lproj"
```

  - Insert into the Info.plist heredoc after `CFBundleDevelopmentRegion`:

```
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>fr</string>
        <string>pl</string>
    </array>
```

  - Extend the verification line:

```bash
test -d "$APP/Contents/Resources/en.lproj" -a -d "$APP/Contents/Resources/de.lproj" \
     -a -d "$APP/Contents/Resources/fr.lproj" -a -d "$APP/Contents/Resources/pl.lproj"
```

- [x] **Step 8: Catalog lint + parity.**

```bash
for l in en de fr pl; do plutil -lint "Sources/MacSCPApp/Resources/$l.lproj/Localizable.strings"; done
swift test --filter Localizable
```
  Expected: all OK; suite PASS (the four new keys are in all four App catalogs → parity holds).

- [x] **Step 9: Build + full suite + idle-CPU smoke test (non-EN).**

```bash
swift build
swift test
MACSCP_VERSION=1.2.0-dev MACSCP_BUILD=m11p scripts/package-app
codesign --force --deep --sign - dist/macSCP.app; xattr -cr dist/macSCP.app
# Force a non-EN launch via the REAL path: the app's own `appLanguage`
# setting. (`defaults write … AppLanguages` would NOT work — init's
# `.system` branch calls removeObject and clobbers it.) Back up + restore.
SETTINGS="$HOME/Library/Application Support/macSCP/settings.json"
cp "$SETTINGS" /tmp/macscp-settings.bak 2>/dev/null || printf '{}' > /tmp/macscp-settings.bak
python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home()/"Library/Application Support/macSCP/settings.json"
d = json.loads(p.read_text()) if p.exists() else {}
d["appLanguage"] = "fr"
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(d))
PY
open dist/macSCP.app; sleep 7
ps -o pid,%cpu,state -p "$(pgrep -f 'dist/macSCP.app/Contents/MacOS/macSCP' | head -1)"
pkill -f 'dist/macSCP.app/Contents/MacOS/macSCP'
cp /tmp/macscp-settings.bak "$SETTINGS" 2>/dev/null || true
```
  Expected: `Build complete` (no new warnings); `swift test` **903** green; app launches in FR without crashing, `%CPU` near 0, state `S`. On a spin (>50%) or crash: STOP, report BLOCKED. (Restore your own settings.json at the end.)

- [x] **Step 10: Trace verification.** Confirm: the `AppleLanguages` application sits in `init` BEFORE any lookup; `.system` removes the override; the relaunch button appears only when `selectedLanguage != launchLanguage`; `AppRelauncher.relaunch` launches detached + `NSApp.terminate`; the picker tags cover every `AppLanguage` case.

- [x] **Step 11: Commit.**

```bash
git add Sources/MacSCPApp/AppRelauncher.swift Sources/MacSCPApp/MacSCPApp.swift Sources/MacSCPApp/SettingsView.swift Sources/MacSCPApp/Resources scripts/package-app
git commit -m "feat: add an in-app language switcher with a relaunch button"
```

---

### Task 5: Final verification (coordinator)

- [x] Gated suites: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → green, zero skips (Docker rig from the main checkout).
- [x] `swift build` clean; `plutil -lint` all eight catalogs OK; `LocalizableStringsTests` green (parity EN↔{DE,FR,PL} + parse).
- [x] Runtime idle-CPU smoke test in a non-EN language passed (Task 4 Step 9).
- [x] Whole-milestone Opus review via `review-package <base> HEAD`: focus on (a) `AppleLanguages` timing (before the first lookup, `.system` removes the override); (b) relaunch visibility + helper correct; (c) FR/PL parity + NO ASCII `"` in the value (spot-checked, the test covers the rest) + format placeholders preserved; (d) Package.swift/package-app/CFBundleLocalizations complete for fr+pl; (e) test guard really covers all four languages. Fix rounds until "Ready to merge: Yes".
- [ ] Visual smoke — maintainer (picker System/EN/DE/FR/PL; switching shows the relaunch button; restart applies the language; app UI + menus appear translated; `.system` follows the system again; light/dark).
- [x] Plan checkboxes, ledger, push develop, `gh run watch`, deploy dev build, memory. **NO release** (have FR/PL reviewed by a native speaker before release).
