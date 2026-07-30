# M11j — Tastatursteuerung im Dateibrowser: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Die Dateiliste per Tastatur bedienen (Finder-Stil), über dieselben Aktionen und dieselbe Gültigkeit wie das Kontextmenü.

**Architecture:** Eine reine, testbare Core-Funktion bildet `(Taste, Auswahl, Pane-Seite)` auf eine Aktion oder „nichts" ab und teilt die Gültigkeit mit `BrowserContextMenu.entries`. Eine `NSTableView`-Unterklasse fängt die Tasten ab und leitet zulässige Aktionen an genau die Closures, die Doppelklick und Kontextmenü schon nutzen.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11j-browser-keyboard-design.md`

## Global Constraints

- Code und Kommentare **nur Englisch**; Anzeigetexte über die Kataloge.
- Tastatur und Kontextmenü teilen die Gültigkeit (`BrowserContextMenu.entries`) —
  kein zweiter Gültigkeitsweg.
- Beide Panes identisch; Übertragen-Richtung aus `side`.
- **⌘-Tasten laufen durch `performKeyEquivalent`, modifierlose durch
  `keyDown`** — nicht verwechseln.
- Plain ⌫ bleibt unbelegt (kein versehentliches Löschen); nicht zulässige
  Tasten fallen an `super` (Type-Select bleibt).
- Selektion BY VALUE zum Tastendruck lesen (kein Stale-Index).
- Kollisions-Check gegen bestehende App-Menü-Kürzel; Kollision melden, nicht
  still umbelegen.
- `swift build` immer aus SAUBEREM Build-Verzeichnis prüfen.
- Tests: Swift Testing, TDD. Baseline: **786 Tests / 56 Suiten**.
- Kein Release, kein Merge auf `main`, kein Tag.

---

### Task 1: Reine Tasten-Auflösung (Core)

**Files:**
- Create: `Sources/macSCPCore/Presentation/BrowserKeyCommand.swift`
- Test: `Tests/macSCPCoreTests/BrowserKeyCommandTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem`, `BrowserPaneSide`, `BrowserContextMenu.entries(for:side:)`.
- Produces (T2 verlässt sich wörtlich darauf):
  - `public enum BrowserKey: Sendable { case returnKey, commandDown, commandO, commandUp, commandDelete, commandI, space, escape }`
  - `public enum BrowserKeyAction: Equatable, Sendable { case open(RemoteFileItem); case goUp; case rename(RemoteFileItem); case info(RemoteFileItem); case delete([RemoteFileItem]); case transfer([RemoteFileItem]); case clearSelection }`
  - `public enum BrowserKeyCommand { public static func resolve(key: BrowserKey, selection: [RemoteFileItem], side: BrowserPaneSide) -> BrowserKeyAction? }`

- [ ] **Step 1: Failing tests** (`BrowserKeyCommandTests`):
  - `.returnKey` + Einzelauswahl ⇒ `.rename(item)`; + Mehrfachauswahl ⇒ `nil`; + leere Auswahl ⇒ `nil`.
  - `.commandDown` und `.commandO` + Einzelauswahl ⇒ `.open(item)`; + Mehrfachauswahl ⇒ `nil`; + leer ⇒ `nil`.
  - `.commandUp` ⇒ `.goUp` (immer, auch bei leerer Auswahl).
  - `.commandDelete` + nicht-leerer Auswahl ⇒ `.delete(selection)`; + leer ⇒ `nil`.
  - `.commandI` + einzelner Datei ⇒ `.info(item)`; + einzelnem SYMLINK ⇒ `nil`; + Mehrfachauswahl ⇒ `nil`.
  - `.space` + übertragbarer Auswahl (mind. ein nicht-Symlink) ⇒ `.transfer(selection)`; + reiner Symlink-Auswahl ⇒ `nil` (Menü bietet Übertragen dort auch nicht); + leer ⇒ `nil`. `side` beeinflusst NUR die spätere Richtung, nicht die Auflösung hier — beide Seiten liefern `.transfer`.
  - `.escape` ⇒ `.clearSelection` (immer).

- [ ] **Step 2: Rot beweisen.** `swift test --filter BrowserKeyCommand` → FAIL.

- [ ] **Step 3: Implementierung.** `resolve` fragt für die
  auswahl-abhängigen Fälle `BrowserContextMenu.entries(for: selection,
  side: side)` und leitet nur ab, wenn der passende `BrowserMenuEntry`
  enthalten ist: `.rename` → `.rename`, `.infoAndPermissions` → `.info`,
  `.delete` → `.delete`, `.transferToOtherPane` → `.transfer`. `.open`
  gilt bei genau EINER Auswahl (der fokussierten Zeile); `.goUp` und
  `.clearSelection` sind immer gültig. Doc-Kommentar: warum die Gültigkeit
  über `entries` geteilt wird (Menü und Tastatur dürfen nie auseinander).

- [ ] **Step 4: Grün.** `swift test --filter BrowserKeyCommand` → PASS, dann volle `swift test`.

- [ ] **Step 5: Commit.** `feat: resolve browser keyboard commands against the menu model`

---

### Task 2: NSTableView-Unterklasse + Dispatch (App)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (Unterklasse + Coordinator-Dispatch + Verdrahtung), ggf. `Sources/MacSCPApp/BrowserPane.swift` / `Sources/MacSCPApp/ContentView.swift` (goUp-/Transfer-Closure, falls nicht vorhanden)

**Interfaces:**
- Consumes: `BrowserKey`/`BrowserKeyAction`/`BrowserKeyCommand.resolve` (T1); die bestehenden Closures `onOpen`, `onOpenFile`, `onOpenSymlink` (M11h), `onMenuAction`, `onSelect`; `viewModel.goUp()`.

- [ ] **Step 1: `NSTableView`-Unterklasse** (privat in
  `RemoteFileTableView.swift`) mit schwacher Referenz auf den Coordinator.
  `makeNSView` instanziiert diese Unterklasse statt `NSTableView()`.

- [ ] **Step 2: `performKeyEquivalent(_:)`** für die ⌘-Tasten
  (⌘↓/⌘O/⌘↑/⌘⌫/⌘I). Modifier und `charactersIgnoringModifiers` /
  `keyCode` (Pfeile ⌘↓/⌘↑ über `keyCode` 125/126) auf `BrowserKey`
  abbilden, `BrowserKeyCommand.resolve` mit der aktuellen Auswahl (BY VALUE)
  rufen, bei Aktion dispatchen und `true` zurück; sonst `super`/`false`.

- [ ] **Step 3: `keyDown(_:)`** für Return / Leertaste / Esc. Gleiche
  Auflösung; nicht-verarbeitete Tasten an `super` (Type-Select bleibt).

- [ ] **Step 4: Dispatch.** Eine Coordinator-Methode
  `perform(_ action: BrowserKeyAction)`:
  - `.open(item)` → **exakt derselbe Weg wie `doubleClicked`** (Ordner →
    `onOpen`, Datei → `onOpenFile`, Symlink → `onOpenSymlink`, `.other`
    No-op) — nicht duplizieren, die vorhandene Verzweigung
    wiederverwenden/teilen.
  - `.goUp` → `viewModel.goUp()` (oder die dafür vorhandene Closure).
  - `.rename(item)` → `onMenuAction(.rename, [item])`.
  - `.info(item)` → `onMenuAction(.infoAndPermissions, [item])`.
  - `.delete(sel)` → `onMenuAction(.delete, sel)`.
  - `.transfer(sel)` → `onMenuAction(.transferToOtherPane, sel)` (die
    Richtung ergibt sich dort bereits aus dem Pane).
  - `.clearSelection` → `onSelect([])` und die Tabellen-Auswahl leeren.

- [ ] **Step 5: Kollisions-Check.** Prüfen, dass ⌘↓/⌘↑/⌘O/⌘I/⌘⌫ mit keinem
  App-Menü-Kürzel kollidieren (⌘N/W/1–9, ⌘⇧., ⌘⇧K/L/I, ⌘T, ⌘,). Im Report
  festhalten. (⌘A/Select-All und Pfeile bleiben nativ.)

- [ ] **Step 6: Verifikation.** `swift build` aus sauberem Verzeichnis
  (keine neuen Warnungen; vier vorbestehende erwartet), volle `swift test`.

- [ ] **Step 7: Commit.** `feat: drive the file browser from the keyboard`

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips.
- [ ] Visueller Smoke — Maintainer (Checkliste: Return benennt um; ⌘↓/⌘O
  öffnet Ordner/Datei/folgt Symlink; ⌘↑ hoch; ⌘⌫ löscht mit Rückfrage;
  ⌘I Info, nicht bei Symlink; Leertaste überträgt in die richtige Richtung
  je Pane; ⌘A alles, Esc leert; plain ⌫ tut nichts; nicht zulässige Tasten
  bei falscher Auswahl tun nichts; Type-Select durch Tippen bleibt; beide
  Panes).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review, Fix-Runden bis „Yes",
  Push develop, `gh run watch`, Memory. KEIN Release.
