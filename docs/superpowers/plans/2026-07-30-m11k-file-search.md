# M11k — Suche in der Dateiliste: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** In der aktuellen Verzeichnis-Liste filtern oder zur Fundstelle springen (umschaltbar), optional per Regex; Feld auf ⌘F, Esc schließt.

**Architecture:** Ein reiner, testbarer Core-Matcher (Teiltext/Regex, mit eigenem Ungültig-Fall) und eine reine Ableitung (Liste + Query + Modus ⇒ sichtbare Items / Match-Indizes / Fehler); der `RemoteBrowserViewModel` hält den Suchzustand und ruft die Ableitung. Die App zeigt ein Suchfeld pro Pane, ⌘F über den fokus-gescopten M11j-Weg.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11k-file-search-design.md`

## Global Constraints

- Code und Kommentare **nur Englisch**; Anzeigetexte über die Kataloge
  (EN Default + DE, typografische Anführungszeichen im Deutschen).
- Suche wirkt NUR auf die aktuell geladene Liste — keine rekursive/Server-
  Suche.
- Ungültiger Regex ⇒ EIGENER Fehlerfall, Liste bleibt stehen (nicht „0
  Treffer" vortäuschen).
- `load()` auf ein neues Verzeichnis SETZT die Suche zurück;
  `refreshQuietly()` behält sie.
- Nur der Dateiname wird durchsucht.
- `swift build` immer aus SAUBEREM Build-Verzeichnis prüfen.
- Tests: Swift Testing, TDD. Baseline: **806 Tests / 57 Suiten**.
- Kein Release, kein Merge auf `main`, kein Tag.

---

### Task 1: Matcher + Ableitung + VM-Suchzustand (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/FileSearch.swift`
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Modify: `Sources/macSCPCore/Resources/{en,de}.lproj/Localizable.strings` (nur falls eine Core-Fehlermeldung dort lebt; sonst App-Schicht)
- Test: `Tests/macSCPCoreTests/FileSearchTests.swift`, `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (erweitern)

**Interfaces:**
- Consumes: `RemoteFileItem` (`name`, `path`), `RemoteBrowserViewModel.items`/`displayItems`.
- Produces (T2 verlässt sich wörtlich darauf):
  - `public enum FileSearchMode: Sendable { case filter, jump }`
  - `public enum FileSearchError: Error, Equatable, Sendable { case invalidRegex }`
  - `public enum FileSearch`
    - `public static func compile(query: String, isRegex: Bool) -> Result<FileSearchPredicate, FileSearchError>` (leerer Query ⇒ „alles passt")
    - `public struct FileSearchPredicate: Sendable { public func matches(_ name: String) -> Bool; public var isEmpty: Bool }`
    - `public struct Derivation: Equatable, Sendable { public let visible: [RemoteFileItem]; public let matchPaths: [String]; public let matchCount: Int; public let totalCount: Int }`
    - `public static func derive(all: [RemoteFileItem], query: String, isRegex: Bool, mode: FileSearchMode) -> Result<Derivation, FileSearchError>`
  - Auf `RemoteBrowserViewModel`: `searchQuery`, `searchIsRegex`, `searchMode`, `searchError: FileSearchError?`, `searchMatchCount`, `searchTotalCount`, sowie Sprung-Navigation `focusNextMatch()`/`focusPreviousMatch()` (setzen `selectedItems` auf den nächsten/vorherigen Treffer, Umbruch) und `clearSearch()`.

- [ ] **Step 1: Failing tests für `FileSearch`** (`FileSearchTests`):
  - `compile("", isRegex: false)` ⇒ Predicate mit `isEmpty == true`, `matches` liefert für alles `true`.
  - Teiltext case-insensitiv: `compile("log", false)` matcht `Access.LOG`, nicht `readme`.
  - Regex gültig: `compile("\\.log$", true)` matcht `a.log`, nicht `a.log.1`; Anker `^var` etc.
  - Regex UNGÜLTIG: `compile("[", true)` ⇒ `.failure(.invalidRegex)`.
  - `derive` Filter-Modus: `visible` = nur Treffer, `matchCount`/`totalCount` stimmen; leere Query ⇒ alles sichtbar.
  - `derive` Sprung-Modus: `visible` == `all` (voll), `matchPaths` = Pfade der Treffer in Listenreihenfolge.
  - `derive` mit ungültigem Regex ⇒ `.failure(.invalidRegex)` (der Aufrufer lässt dann `items` stehen).
  - Unicode/Umlaut: `compile("müller", false)` matcht `Müller.txt` (case-insensitiv, diakritik wie NSString-Vergleich — dokumentieren, was gilt).

- [ ] **Step 2: Rot beweisen.** `swift test --filter FileSearch` → FAIL.

- [ ] **Step 3: `FileSearch` implementieren** (rein). Regex einmal
  kompilieren (`NSRegularExpression`, `.caseInsensitive`), Teiltext über
  `localizedCaseInsensitiveContains`. `derive` baut aus dem kompilierten
  Prädikat die vier Felder je Modus.

- [ ] **Step 4: Grün.** `swift test --filter FileSearch` → PASS.

- [ ] **Step 5: Failing tests für den VM-Suchzustand**
  (`RemoteBrowserViewModelTests`, Mock-FS):
  - Filter-Modus: `searchQuery` setzen reduziert `items`, `searchMatchCount`/
    `searchTotalCount` stimmen; leeren ⇒ wieder alles.
  - Sprung-Modus: `items` bleibt voll; `focusNextMatch()` setzt
    `selectedItems` auf den ersten/nächsten Treffer, Umbruch am Ende;
    `focusPreviousMatch()` rückwärts.
  - Ungültiger Regex: `searchError == .invalidRegex`, `items` UNVERÄNDERT
    (nicht geleert).
  - `load()` auf neues Verzeichnis: `searchQuery` leer, `searchError` nil,
    `items` voll.
  - `refreshQuietly()` mit aktivem Filter: wendet ihn auf die frische Liste
    an (Treffer bleiben gefiltert), Auswahl-Semantik unverändert.

- [ ] **Step 6: Rot beweisen, dann implementieren.** `displayedAll` als
  gespeicherte Basis einführen (von `load`/`refreshQuietly` gesetzt);
  `items` aus `FileSearch.derive` ableiten; die Suche-Setter lösen die
  Neuableitung aus. `load()` ruft `clearSearch()` VOR dem Ableiten. Die
  bestehenden `items`-Konsumenten (M7b-Aktionen, Auswahl) bleiben korrekt,
  weil `items` weiterhin die angezeigte Liste ist.

- [ ] **Step 7: Grün + volle Suite.** `swift test` → 806 + neue.

- [ ] **Step 8: Commit.** `feat: search the current directory listing`

---

### Task 2: Suchfeld, Modus/Regex, ⌘F, Esc (App)

**Files:**
- Create: `Sources/MacSCPApp/FileSearchBar.swift`
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (Suchfeld über der Tabelle, Zustand ans ViewModel), `Sources/MacSCPApp/RemoteFileTableView.swift` (⌘F über `performKeyEquivalent`), `Sources/MacSCPApp/Resources/{en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: die VM-Suche aus T1; der fokus-gescopte `performKeyEquivalent`
  aus M11j.

- [ ] **Step 1: `FileSearchBar`** — ein Suchfeld (SwiftUI), das an die
  VM-Suchfelder bindet: Textfeld, Modus-Umschalter (Filtern/Springen),
  Regex-Schalter, rechts die Trefferzahl („%1$lld von %2$lld" bzw.
  „Treffer k/N" im Sprung-Modus) ODER bei `searchError == .invalidRegex`
  eine rote, konkrete Meldung. Optik dezent, an den bestehenden Panehead-
  Maßen orientiert (M5g nicht verschieben).

- [ ] **Step 2: Einblenden in `BrowserPane`.** Das Suchfeld erscheint über
  der Dateiliste, wenn die Suche für dieses Pane aktiv ist (ein
  `@State`/gebundener Bool). Ist es aus, ändert sich am Ruhezustand des
  Panes nichts.

- [ ] **Step 3: ⌘F.** Im `performKeyEquivalent` der
  `KeyboardDrivenTableView` (fokus-gescopt aus M11j) ⌘+"f" abfangen: die
  Suche dieses Panes einblenden und den Fokus ins Feld setzen. Nur die
  fokussierte Tabelle reagiert (der Guard ist schon da). Kollisions-Check:
  ⌘F ist unbelegt.

- [ ] **Step 4: Enter/⇧Enter im Sprung-Modus.** Im Feld: Enter ⇒
  `focusNextMatch()`, ⇧Enter ⇒ `focusPreviousMatch()`; die Tabelle scrollt
  den Treffer in den sichtbaren Bereich (die Auswahl setzt die VM, das
  Table-View folgt der `selectedItems`-Reconciliation — prüfen, dass der
  Treffer sichtbar wird, ggf. `scrollRowToVisible`).

- [ ] **Step 5: Esc.** Schließt das Feld, ruft `clearSearch()` (alles wird
  wieder gezeigt), Fokus zurück auf die Tabelle.

- [ ] **Step 6: EN/DE.** Neue Keys in BEIDE Kataloge (Trefferzahl-Formate,
  Modus-/Regex-Beschriftungen, die Regex-Fehlermeldung), Englisch zuerst.
  `plutil -lint` OK, `LocalizableStringsTests` grün.

- [ ] **Step 7: Verifikation.** `swift build` aus sauberem Verzeichnis
  (keine neuen Warnungen), volle `swift test`.

- [ ] **Step 8: Commit.** `feat: add the file-list search bar`

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips.
- [ ] Visueller Smoke — Maintainer (Checkliste: ⌘F öffnet das Feld im
  fokussierten Pane; Filtern reduziert live mit „N von M"; Springen lässt
  die Liste voll und Enter/⇧Enter wandert durch die Treffer mit Umbruch;
  Regex-Schalter an, `\.log$` filtert; ungültiger Ausdruck zeigt die rote
  Meldung statt „0 Treffer", die Liste bleibt stehen; Esc schließt und zeigt
  alles; Verzeichniswechsel setzt die Suche zurück; beide Panes unabhängig;
  Type-Select der Tabelle unberührt).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review, Fix-Runden bis „Yes",
  Push develop, `gh run watch`, Memory. KEIN Release.
