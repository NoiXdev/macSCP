# M11p — Sprachumschalter + FR/PL-Übersetzung Design

**Status:** freigegeben (Brainstorming 2026-07-31)
**Meilenstein:** M11p
**Sprache:** Design-Doc DE; Code/Kommentare EN; UI lokalisiert EN/DE/FR/PL

## Ziel

Ein app-eigener Sprachumschalter in den Einstellungen (unabhängig von der
Systemsprache) plus vollständige französische (fr) und polnische (pl)
Übersetzung. Der Wächter-Test wird auf FR/PL erweitert, damit ein falsches
Anführungszeichen dort nicht still auf Englisch zurückfällt (wie der
M11d-Blocker es für DE tat).

Maintainer-Entscheidungen aus dem Brainstorming:
- **Mechanismus:** Sprachwechsel via `AppleLanguages`-Override, angewandt beim
  Start; nach dem Umschalten ein **Relaunch-Knopf** („macSCP neu starten") +
  Hinweistext. Kein Live-Wechsel (die Bundle-Tabellen cachen).
- **Übersetzungsquelle:** FR/PL werden **KI-generiert** (technischer
  UI-Kontext), klar als solche gekennzeichnet; vor einem echten Release soll
  ein Muttersprachler drüberschauen. Kommt nur auf `develop`, **kein Release**.

## Kontext / Ist-Zustand

- **Kataloge heute:** nur en + de, je Schicht.
  - App: `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`
    (**407 Keys** je Sprache).
  - Core: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings`
    (**52 Keys** je Sprache).
- **Lookups:** `L10n.string` (App, `Sources/MacSCPApp/L10n.swift`) und
  `CoreL10n.string` (Core, `Sources/macSCPCore/L10n/CoreL10n.swift`) lösen ihr
  Bundle manuell auf und delegieren die Sprachwahl **komplett an Foundation**
  (den `AppleLanguages`-Key). **Kein Eingriff in diese zwei Dateien nötig** —
  ein früh gesetzter Override greift beim nächsten Start automatisch. Live-
  Wechsel ist nicht möglich (Bundle-Tabellen cachen nach dem ersten Lookup) →
  Neustart ist inhärent.
- **Package.swift:** `defaultLocalization: "en"`. Core-Target listet lproj
  **explizit** (`.process("Resources/en.lproj")`, `…de.lproj`); App-Target
  nutzt `.process("Resources")` (zieht neue lproj automatisch).
- **package-app:** baut das `.app` von Hand; **Marker-Trick** (`mkdir …
  Contents/Resources/{en,de}.lproj`) — macOS bietet eine Sprache nur an, wenn
  im Haupt-Bundle ein (leeres) Marker-lproj existiert; erst dann werden die
  echten Kataloge in den SPM-Resource-Bundles erreichbar. Verifikations-Zeile
  prüft die Marker. Info.plist wird per Heredoc erzeugt, **ohne**
  `CFBundleLocalizations`.
- **`LocalizableStringsTests`** (`Tests/macSCPCoreTests/`): Swift-Testing;
  hartkodierte EN/DE-Pfade; prüft (a) Plist-Parsebarkeit je Datei (fängt ein
  falsches Anführungszeichen — `NSDictionary(contentsOfFile:)` liefert `nil`)
  und (b) Schlüssel-Parität EN↔DE je Schicht.
- **Settings-Muster:** `SettingsStore` (Core, JSON) — Enum-Setting-Vorlage
  `terminalTarget`/`terminalCursorStyle` (eigenes `enum`-File, `Keys`,
  `Defaults`, computed var mit rawValue-Fallback). Picker-Vorlage im
  `TerminalSettingsTab` (`SettingsView.swift`), `GeneralSettingsTab` ist der
  Ort für den Sprach-Picker.
- **`MacSCPApp.init()`** baut den `SettingsStore` synchron (liest
  `settings.json`) **vor** dem ersten lokalisierten Lookup (Menüs/Views bauen
  erst in `body`). Das ist die früheste und richtige Stelle für den Override.
  Es gibt **keinen** Relaunch-Helfer im Code — der ist neu.

## Architektur

### Core — Sprach-Enum + Setting

- Neu `Sources/macSCPCore/Settings/AppLanguage.swift`:
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
- `SettingsStore.selectedLanguage: AppLanguage` (Default `.system`), nach dem
  `terminalTarget`-Muster (Key, Default, computed var mit
  `AppLanguage(rawValue:) ?? .system`, `persist()`).

### App — Anwendung + UI + Relaunch

- **`MacSCPApp.init()`**: unmittelbar nachdem `settingsStore` gebaut ist und
  **vor** allem Weiteren die Sprache anwenden:
  - `let launch = settingsStore.selectedLanguage`
  - wenn `let code = launch.localeCode`: `UserDefaults.standard.set([code],
    forKey: "AppleLanguages")`
  - sonst (`.system`): `UserDefaults.standard.removeObject(forKey:
    "AppleLanguages")`.
  - `launch` in einem `let launchLanguage: AppLanguage` merken und an
    `ContentView`/die `Settings`-Szene durchreichen (für die
    Relaunch-Sichtbarkeit).
- **`GeneralSettingsTab`**: neuer `Section` „Language" mit
  `Picker($store.selectedLanguage)` — Tags System/en/de/fr/pl. Weicht
  `store.selectedLanguage` von `launchLanguage` ab, erscheinen darunter ein
  Hinweistext („Wird nach Neustart angewandt") **und** ein Button „macSCP neu
  starten".
- **Relaunch-Helfer** (neu, App-Schicht): startet losgelöst
  `/bin/sh -c "sleep 1; open <Bundle.main.bundlePath>"` und ruft dann
  `NSApp.terminate(nil)`. Bewusste Nutzeraktion; kein `deinit`-Cleanup nötig
  (wie normales Beenden).

### FR/PL-Kataloge

- Neu: `Sources/MacSCPApp/Resources/{fr,pl}.lproj/Localizable.strings`
  (je 407 Keys, Schlüssel exakt wie EN, Format-Platzhalter unverändert) und
  `Sources/macSCPCore/Resources/{fr,pl}.lproj/Localizable.strings`
  (je 52 Keys).
- **Anführungszeichen:** FR « … » (Guillemets), PL „ … " (wie DE); nur
  ASCII-`"` als Delimiter, nie im Wert. Kopfkommentar kennzeichnet die
  Kataloge als KI-generiert / muttersprachlich zu prüfen.
- **Package.swift:** dem Core-Target `.process("Resources/fr.lproj")` +
  `.process("Resources/pl.lproj")` hinzufügen. App-Target unverändert.
- **package-app:** Marker-`mkdir` und Verifikations-`test -d` um
  `fr.lproj`/`pl.lproj` erweitern; `CFBundleLocalizations = (en, de, fr, pl)`
  in die Info.plist-Heredoc aufnehmen.

### Test-Wächter

- `LocalizableStringsTests` verallgemeinern: je Schicht (App/Core) eine EN-
  Referenz und die Liste der Nicht-EN-Sprachen (de, fr, pl); jede gegen EN auf
  Schlüssel-Parität prüfen, und **alle** Kataloge (inkl. en) auf
  Plist-Parsebarkeit. So fällt FR/PL nicht still auf Englisch zurück.

## Neue UI-Strings (alle 4 Sprachen)

- `settings.general.language.header` = „Language" / „Sprache" / „Langue" /
  „Język"
- `settings.general.language.system` = „System" (bzw. lokalisiert)
- `settings.general.language.footer` = Hinweis, dass der Wechsel einen Neustart
  braucht.
- `settings.general.language.relaunch` = „Relaunch macSCP" (bzw. lokalisiert)
- Sprachnamen im Picker werden **endonym** angezeigt (English, Deutsch,
  Français, Polski) — feste Labels, nicht übersetzt.

## Randfälle

- **`.system` gewählt, während eine Nicht-System-Sprache lief:** Override wird
  beim nächsten Start entfernt → App folgt wieder dem System; Relaunch-Knopf
  wird angeboten.
- **Unbekannter/kaputter Setting-Wert:** rawValue-Fallback → `.system`.
- **Kataloge fehlerhaft (falsches Anführungszeichen):** Test schlägt rot →
  wird vor Merge gefangen; zur Laufzeit fiele die Sprache still auf EN zurück
  (genau das verhindert der Test).
- **Relaunch bei aktiven Übertragungen:** bewusste Nutzeraktion; behandelt wie
  normales Beenden (kein Sonderdialog in v1).

## Tests

- **Core (neu, red→green):** `SettingsStore.selectedLanguage` — Default
  `.system`, Roundtrip, rawValue-Fallback auf `.system`.
- **`LocalizableStringsTests` erweitert:** Parität EN↔{DE,FR,PL} je Schicht +
  Parsebarkeit aller acht Katalogdateien. (Fällt rot, wenn FR/PL Keys fehlen
  oder ein Anführungszeichen den Katalog zerbricht.)
- **Kein App-Test-Target** für Picker/Relaunch/`AppleLanguages` — Verifikation
  per Build/Trace.
- **Runtime-Rauchtest (Pflicht):** Dev-Build mit gesetztem `AppleLanguages`
  (z.B. `fr`) starten → App startet ohne Crash, Idle-CPU ~0%. Fängt sowohl
  einen Sprach-Startfehler als auch einen SwiftUI-Layout-Sturm.
- Übersetzungs-*Qualität* deckt kein Test ab → KI-Kennzeichnung +
  Muttersprachler-Review vor Release.

## Aufgaben-Schnitt (für den Plan)

1. **Core:** `AppLanguage` + `SettingsStore.selectedLanguage` (+ Tests).
2. **FR-Kataloge** App+Core (Vollübersetzung) + Package.swift + Test auf FR.
3. **PL-Kataloge** App+Core (Vollübersetzung) + Test auf PL.
4. **App-Switcher:** Picker + `AppleLanguages`-Anwendung in `init` +
   `launchLanguage`-Durchreichung + Relaunch-Helfer/-Knopf + neue UI-Strings in
   allen 4 Sprachen + package-app-Marker/Info.plist.
5. **Abschluss-Verifikation** (gated, Review, Runtime-Rauchtest in Nicht-EN,
   Push, Deploy).

FR und PL getrennt, damit jede Übersetzung fokussiert bleibt und ihr Review
überschaubar ist.

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD wo
  Logik entsteht.
- Code/Kommentare EN; UI-Strings über die `.strings`-Kataloge, jetzt
  EN/DE/FR/PL. **Kein ASCII-`"` im Wert** irgendeines nicht-englischen
  Katalogs (bricht den Katalog).
- Sprachauswahl persistiert in `SettingsStore` (Core); Anwendung nur früh in
  `MacSCPApp.init` über `AppleLanguages`, kein Eingriff in `L10n`/`CoreL10n`.
- **M11n-Lektion:** neue GUI-Wege vor Auslieferung per Runtime-Idle-CPU-
  Rauchtest prüfen — hier zusätzlich in einer Nicht-EN-Sprache starten.
- FR/PL sind KI-generiert und vor einem Release muttersprachlich zu prüfen.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.
