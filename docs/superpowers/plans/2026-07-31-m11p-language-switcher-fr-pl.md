# M11p — Sprachumschalter + FR/PL-Übersetzung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein app-eigener Sprachumschalter in den Einstellungen (via `AppleLanguages`-Override, angewandt beim Start, Relaunch-Knopf zum Übernehmen) plus vollständige FR- und PL-Übersetzung für App + Core, mit auf alle Sprachen verallgemeinertem Katalog-Wächter.

**Architecture:** Core bekommt ein `AppLanguage`-Enum + persistiertes `SettingsStore.selectedLanguage`. `MacSCPApp.init` liest es früh und setzt `AppleLanguages` (kein Eingriff in `L10n`/`CoreL10n` — die respektieren den Override beim nächsten Start). Zwei neue Katalogpaare (fr, pl) je Schicht; der Test-Wächter prüft Parität+Parsebarkeit über alle Sprachen. Ein Sprach-Picker + Relaunch-Knopf im `GeneralSettingsTab`.

**Tech Stack:** SwiftUI + AppKit, Swift 6 (`.swiftLanguageMode(.v5)`), Swift Testing, macOS 15, SPM-Ressourcen (`.lproj`).

## Global Constraints

- Swift-tools 6.0, alle Targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/Kommentare **English only**.
- UI-Strings über `.strings`-Kataloge, jetzt EN/DE/FR/PL. **Kein ASCII-`"` im Wert** eines nicht-englischen Katalogs — ein einziges zerbricht den ganzen Katalog (Plist-Parse schlägt fehl, Sprache fällt still auf EN zurück; `LocalizableStringsTests` bewacht das).
- Format-Platzhalter (`%@`, `%lld`, `%1$@` …) in Übersetzungen **exakt** übernehmen — Anzahl, Reihenfolge, Typ.
- Sprachauswahl persistiert in `SettingsStore` (Core); Anwendung nur früh in `MacSCPApp.init` über `AppleLanguages`. **Kein** Eingriff in `L10n`/`CoreL10n`.
- FR/PL sind **KI-generiert**, per Kopfkommentar gekennzeichnet, vor Release muttersprachlich zu prüfen.
- **M11n-Lektion / Runtime-Rauchtest:** neue GUI-Wege vor Auslieferung per Idle-CPU-Rauchtest prüfen — hier zusätzlich in einer Nicht-EN-Sprache starten.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Baseline: **900 Tests / 62 Suiten** grün.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.

---

### Task 1: Core — AppLanguage + SettingsStore.selectedLanguage

**Files:**
- Create: `Sources/macSCPCore/Settings/AppLanguage.swift`
- Modify: `Sources/macSCPCore/Settings/SettingsStore.swift` (`Keys`/`Defaults`/computed var)
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift` (drei Fälle anhängen)

**Interfaces:**
- Consumes (verifiziert): `SettingsStore` Enum-Muster — `terminalTarget` (Key in `enum Keys`, computed var mit `guard case .string(let value)? = raw[Keys.x]` + `X(rawValue:) ?? fallback` + `persist()`); `TerminalTarget`-Enum-File als Vorlage.
- Produces (für Task 4): `AppLanguage` (public, `String`/`Codable`/`CaseIterable`/`Sendable`, cases `system,en,de,fr,pl`, `localeCode: String?`); `SettingsStore.selectedLanguage: AppLanguage` (default `.system`).

- [ ] **Step 1: Failing test.** In `Tests/macSCPCoreTests/SettingsStoreTests.swift` anhängen (Muster wie `menuBarEnabledDefaultsTrue`/`…Roundtrips`):

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

- [ ] **Step 2: Rot.** `swift test --filter SettingsStore`
  Expected: FAIL — `AppLanguage` und `selectedLanguage` existieren nicht.

- [ ] **Step 3: Enum-File.** Neue Datei `Sources/macSCPCore/Settings/AppLanguage.swift`:

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

- [ ] **Step 4: Setting.** In `Sources/macSCPCore/Settings/SettingsStore.swift`:
  - In `enum Keys` (nach `menuBarEnabled`): `static let appLanguage = "appLanguage"`.
  - Neue computed var bei den anderen (Muster `terminalTarget`):

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

- [ ] **Step 5: Grün + Suite.** `swift test --filter SettingsStore` → PASS; dann `swift test`
  Expected: 900 + 3 = **903 Tests** grün.

- [ ] **Step 6: Commit.**

```bash
git add Sources/macSCPCore/Settings/AppLanguage.swift Sources/macSCPCore/Settings/SettingsStore.swift Tests/macSCPCoreTests/SettingsStoreTests.swift
git commit -m "feat: add AppLanguage and the persisted selectedLanguage setting"
```

---

### Task 2: FR-Kataloge + Package.swift + Test-Wächter verallgemeinern

**Files:**
- Create: `Sources/MacSCPApp/Resources/fr.lproj/Localizable.strings` (407 Keys)
- Create: `Sources/macSCPCore/Resources/fr.lproj/Localizable.strings` (52 Keys)
- Modify: `Package.swift` (Core-Ressourcen)
- Modify: `Tests/macSCPCoreTests/LocalizableStringsTests.swift` (auf Sprachliste umstellen, FR aufnehmen)

**Interfaces:**
- Consumes: die EN-Kataloge als Übersetzungsquelle (`…/en.lproj/Localizable.strings`, App 407 / Core 52 Keys); die DE-Kataloge als Vorbild für typografische Anführungszeichen.
- Produces (für Task 3): die verallgemeinerte Test-Struktur mit einer Sprachliste je Schicht, an die Task 3 nur `"pl"` anhängt.

- [ ] **Step 1: FR App-Katalog.** `Sources/MacSCPApp/Resources/fr.lproj/Localizable.strings` erzeugen: JEDEN Key aus `en.lproj/Localizable.strings` übernehmen (identische Key-Namen, `;`-Struktur), den Wert nach **Französisch** übersetzen. Regeln:
  - Format-Platzhalter (`%@`, `%lld`, `%1$@`, `⌘⇧.` u.ä.) unverändert lassen.
  - Anführungszeichen im Wert: französische Guillemets « … » (nie ASCII-`"`; ASCII-`"` nur als String-Delimiter). Wo der EN/DE-Wert kein Zitat enthält, keins einführen.
  - Tastenkürzel-Symbole (⌘⇧Y etc.) unverändert.
  - Kopfzeile als Kommentar: `/* AI-generated French translation (M11p) — review by a native speaker before release. */`

- [ ] **Step 2: FR Core-Katalog.** `Sources/macSCPCore/Resources/fr.lproj/Localizable.strings` analog aus dem Core-EN-Katalog (52 Keys) erzeugen.

- [ ] **Step 3: Package.swift.** Im **Core**-Target die `resources`-Liste erweitern:

```swift
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/fr.lproj"),
            ],
```

(App-Target unverändert — `.process("Resources")` zieht `fr.lproj` automatisch.)

- [ ] **Step 4: Test-Wächter verallgemeinern.** `Tests/macSCPCoreTests/LocalizableStringsTests.swift` so umbauen, dass es je Schicht die EN-Referenz gegen eine Sprachliste prüft und alle Kataloge parst. Ersetze die vier `@Test`/`assertIdenticalKeys`-Blöcke (ab `@Test(arguments:)`) durch:

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

(Die vier Pfad-Konstanten `appEnPath`/`appDePath`/`coreEnPath`/`coreDePath` und `parse`/`repoRoot` bleiben; `appDePath`/`coreDePath` werden nicht mehr direkt referenziert — sie dürfen bleiben oder entfernt werden, je nach Compiler-Warnung „unused". Bei Warnung entfernen.)

- [ ] **Step 5: plutil + Suite.**

```bash
plutil -lint Sources/MacSCPApp/Resources/fr.lproj/Localizable.strings
plutil -lint Sources/macSCPCore/Resources/fr.lproj/Localizable.strings
swift test --filter Localizable
```
  Expected: plutil beide OK; `Localizable`-Suite PASS (Parität EN↔{DE,FR} + Parse aller sechs Dateien). Bei einem Paritäts-Fehler fehlende/überzählige Keys nachziehen, bei Parse-Fehler das (ASCII-)Anführungszeichen im Wert finden und ersetzen.

- [ ] **Step 6: Build + volle Suite.** `swift build` (sauber) und `swift test` → **903** grün.

- [ ] **Step 7: Commit.**

```bash
git add Sources/MacSCPApp/Resources/fr.lproj Sources/macSCPCore/Resources/fr.lproj Package.swift Tests/macSCPCoreTests/LocalizableStringsTests.swift
git commit -m "feat: add French catalogs and generalize the localization guard"
```

---

### Task 3: PL-Kataloge + Test auf PL

**Files:**
- Create: `Sources/MacSCPApp/Resources/pl.lproj/Localizable.strings` (407 Keys)
- Create: `Sources/macSCPCore/Resources/pl.lproj/Localizable.strings` (52 Keys)
- Modify: `Package.swift` (Core-Ressourcen)
- Modify: `Tests/macSCPCoreTests/LocalizableStringsTests.swift` (`"pl"` an beide Sprachlisten)

**Interfaces:**
- Consumes: die EN-Kataloge als Quelle; die Task-2-Test-Struktur (`appLangs`/`coreLangs`-Listen).

- [ ] **Step 1: PL App-Katalog.** `Sources/MacSCPApp/Resources/pl.lproj/Localizable.strings` aus dem EN-App-Katalog (407 Keys) nach **Polnisch** erzeugen. Regeln wie Task 2, aber Anführungszeichen im polnischen Stil „ … " (wie DE; nie ASCII-`"`). Kopfkommentar `/* AI-generated Polish translation (M11p) — review by a native speaker before release. */`

- [ ] **Step 2: PL Core-Katalog.** `Sources/macSCPCore/Resources/pl.lproj/Localizable.strings` aus dem Core-EN-Katalog (52 Keys).

- [ ] **Step 3: Package.swift.** Im **Core**-Target `.process("Resources/pl.lproj")` anhängen:

```swift
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/pl.lproj"),
            ],
```

- [ ] **Step 4: Test-Listen.** In `Tests/macSCPCoreTests/LocalizableStringsTests.swift` beide Listen erweitern:

```swift
    private static let appLangs = ["de", "fr", "pl"]
    private static let coreLangs = ["de", "fr", "pl"]
```

- [ ] **Step 5: plutil + Suite.**

```bash
plutil -lint Sources/MacSCPApp/Resources/pl.lproj/Localizable.strings
plutil -lint Sources/macSCPCore/Resources/pl.lproj/Localizable.strings
swift test --filter Localizable
```
  Expected: plutil OK; `Localizable`-Suite PASS (Parität EN↔{DE,FR,PL} + Parse aller acht Dateien).

- [ ] **Step 6: Build + volle Suite.** `swift build` sauber; `swift test` → **903** grün.

- [ ] **Step 7: Commit.**

```bash
git add Sources/MacSCPApp/Resources/pl.lproj Sources/macSCPCore/Resources/pl.lproj Package.swift Tests/macSCPCoreTests/LocalizableStringsTests.swift
git commit -m "feat: add Polish catalogs and extend the localization guard"
```

---

### Task 4: App-Switcher — Picker, AppleLanguages, Relaunch, package-app

**Files:**
- Create: `Sources/MacSCPApp/AppRelauncher.swift`
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (`AppleLanguages`-Anwendung in `init`, `launchLanguage` durchreichen)
- Modify: `Sources/MacSCPApp/SettingsView.swift` (`SettingsView` + `GeneralSettingsTab` bekommen `launchLanguage`; Sprach-`Section`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (neue UI-Keys in ALLEN vier)
- Modify: `scripts/package-app` (Marker + `CFBundleLocalizations`)

**Interfaces:**
- Consumes (Task 1): `AppLanguage` (`localeCode`), `SettingsStore.selectedLanguage`. Bestehend: `MacSCPApp.init` (baut `settingsStore` um Zeile 106); `SettingsView(store:updateModel:)` in der `Settings`-Szene; `GeneralSettingsTab` (`@Bindable var store`, `Form`); `L10n.string`; Enum-Picker-Muster (`Picker(..., selection: $store.x) { Text(...).tag(EnumCase) }`).

- [ ] **Step 1: Relaunch-Helfer.** Neue Datei `Sources/MacSCPApp/AppRelauncher.swift`:

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

- [ ] **Step 2: AppleLanguages anwenden + launchLanguage.** In `Sources/MacSCPApp/MacSCPApp.swift`:
  - Property hinzufügen: `let launchLanguage: AppLanguage`.
  - In `init()`, direkt NACH `let store = SettingsStore(directory: SettingsStore.defaultDirectory)` (Zeile 106) und VOR `menuBarController = …`:

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

  - Die `Settings`-Szene um den Parameter erweitern:

```swift
        Settings {
            SettingsView(store: settingsStore, updateModel: updateModel,
                         launchLanguage: launchLanguage)
                .tint(DesignTokens.remoteBlue)
        }
```

- [ ] **Step 3: SettingsView + GeneralSettingsTab durchreichen.** In `Sources/MacSCPApp/SettingsView.swift`:
  - `SettingsView` bekommt `let launchLanguage: AppLanguage` und reicht es an `GeneralSettingsTab(store:updateModel:launchLanguage:)` durch (der Tab wird in `SettingsView.body`s `TabView` gebaut).
  - `GeneralSettingsTab` bekommt `let launchLanguage: AppLanguage`.

- [ ] **Step 4: Sprach-Section.** In `GeneralSettingsTab.body` (im `Form`, z.B. als erste `Section`) einfügen:

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

- [ ] **Step 5: UI-Strings in EN + DE.** In `en.lproj` und `de.lproj` je vier Keys anfügen. EN:

```
"settings.general.language.header" = "Language";
"settings.general.language.system" = "System";
"settings.general.language.footer" = "Takes effect after a relaunch.";
"settings.general.language.relaunch" = "Relaunch macSCP";
```

DE (typografisch, kein ASCII-`"` im Wert):

```
"settings.general.language.header" = "Sprache";
"settings.general.language.system" = "System";
"settings.general.language.footer" = "Wird nach einem Neustart angewandt.";
"settings.general.language.relaunch" = "macSCP neu starten";
```

- [ ] **Step 6: UI-Strings in FR + PL.** Dieselben vier Keys in `fr.lproj` und `pl.lproj` (FR Guillemets/kein ASCII-`"`; PL „ "):

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

- [ ] **Step 7: package-app.** In `scripts/package-app`:
  - Marker-Zeile (aktuell `mkdir "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/de.lproj"`) um `fr.lproj`/`pl.lproj` erweitern:

```bash
mkdir "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/de.lproj" \
      "$APP/Contents/Resources/fr.lproj" "$APP/Contents/Resources/pl.lproj"
```

  - Im Info.plist-Heredoc nach `CFBundleDevelopmentRegion` einfügen:

```
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>fr</string>
        <string>pl</string>
    </array>
```

  - Die Verifikations-Zeile erweitern:

```bash
test -d "$APP/Contents/Resources/en.lproj" -a -d "$APP/Contents/Resources/de.lproj" \
     -a -d "$APP/Contents/Resources/fr.lproj" -a -d "$APP/Contents/Resources/pl.lproj"
```

- [ ] **Step 8: Katalog-Lint + Parität.**

```bash
for l in en de fr pl; do plutil -lint "Sources/MacSCPApp/Resources/$l.lproj/Localizable.strings"; done
swift test --filter Localizable
```
  Expected: alle OK; Suite PASS (die vier neuen Keys sind in allen vier App-Katalogen → Parität bleibt).

- [ ] **Step 9: Build + volle Suite + Idle-CPU-Rauchtest (Nicht-EN).**

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
  Expected: `Build complete` (keine neuen Warnungen); `swift test` **903** grün; App startet in FR ohne Crash, `%CPU` nahe 0, state `S`. Falls Spin (>50%) oder Crash: STOP, BLOCKED melden. (Die eigene settings.json am Ende wiederherstellen.)

- [ ] **Step 10: Trace-Verifikation.** Bestätigen: `AppleLanguages`-Anwendung steht in `init` VOR jedem Lookup; `.system` entfernt den Override; Relaunch-Knopf nur bei `selectedLanguage != launchLanguage`; `AppRelauncher.relaunch` startet losgelöst + `NSApp.terminate`; Picker-Tags decken alle `AppLanguage`-Fälle.

- [ ] **Step 11: Commit.**

```bash
git add Sources/MacSCPApp/AppRelauncher.swift Sources/MacSCPApp/MacSCPApp.swift Sources/MacSCPApp/SettingsView.swift Sources/MacSCPApp/Resources scripts/package-app
git commit -m "feat: add an in-app language switcher with a relaunch button"
```

---

### Task 5: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips (Docker-Rig aus dem Haupt-Checkout).
- [ ] `swift build` sauber; `plutil -lint` alle acht Kataloge OK; `LocalizableStringsTests` grün (Parität EN↔{DE,FR,PL} + Parse).
- [ ] Runtime-Idle-CPU-Rauchtest in einer Nicht-EN-Sprache bestanden (Task 4 Step 9).
- [ ] Whole-Milestone Opus-Review über `review-package <base> HEAD`: Fokus auf (a) `AppleLanguages`-Timing (vor erstem Lookup, `.system` entfernt Override); (b) Relaunch-Sichtbarkeit + Helfer korrekt; (c) FR/PL Parität + KEIN ASCII-`"` im Wert (stichprobenartig, der Test deckt den Rest) + Format-Platzhalter erhalten; (d) Package.swift/package-app/CFBundleLocalizations vollständig für fr+pl; (e) Test-Wächter erfasst wirklich alle vier Sprachen. Fix-Runden bis „Ready to merge: Yes".
- [ ] Visueller Smoke — Maintainer (Picker System/EN/DE/FR/PL; Umschalten zeigt Relaunch-Knopf; Neustart wendet die Sprache an; App-UI + Menüs erscheinen übersetzt; `.system` folgt wieder dem System; hell/dunkel).
- [ ] Plan-Checkboxen, Ledger, Push develop, `gh run watch`, Dev-Build deployen, Memory. **KEIN Release** (FR/PL vor Release muttersprachlich prüfen lassen).
