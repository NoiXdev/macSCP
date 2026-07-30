# M11l — Sortieren per Spaltenklick: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Dateiliste nach Name/Größe/Datum sortieren — Spaltenklick wählt den Schlüssel, erneuter Klick dreht die Richtung; Ordner bleiben oben.

**Architecture:** Die bestehende Sortier-Autorität `sortedForDisplay` wird um Schlüssel + Richtung parametrisiert (Ordner-zuerst bleibt); der `RemoteBrowserViewModel` hält den Sortierzustand und reicht ihn in `displayItems` durch, sodass `load`/`refreshQuietly`/M11k-Suche konsistent sortieren. Die Tabelle meldet Header-Klicks, das ViewModel bleibt die einzige Sortier-Autorität.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-30-m11l-column-sort-design.md`

## Global Constraints

- Code und Kommentare **nur Englisch**; Anzeigetexte über die Kataloge.
- **Ordner bleiben immer oben** (Gruppierung, unabhängig vom Schlüssel und
  von der Richtung).
- Sortierung ist STABIL (Name-Tiebreaker bei gleicher Größe/gleichem Datum);
  fehlende Größe/fehlendes Datum deterministisch.
- Die Sortier-Autorität bleibt an EINER Stelle (Core `sortedForDisplay`) —
  AppKit sortiert die NSTableView-Zeilen NICHT selbst; die Reihenfolge kommt
  aus `items`.
- Sortierzustand überlebt `refreshQuietly` und Verzeichniswechsel (Anzeige-
  Präferenz des Panes); die M11k-Suche wird beim Wechsel zurückgesetzt, die
  Sortierung NICHT.
- Der parameterlose `sortedForDisplay`-Aufruf bleibt als Default `.name`
  aufsteigend erhalten (nichts anderes bricht).
- `swift build` immer aus SAUBEREM Build-Verzeichnis prüfen.
- Tests: Swift Testing, TDD. Baseline: **826 Tests / 58 Suiten**.
- Kein Release, kein Merge auf `main`, kein Tag.

---

### Task 1: Parametrisierte Sortierung + VM-Zustand (Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/RemoteBrowserViewModel.swift`
- Create: `Sources/macSCPCore/Presentation/FileSortKey.swift` (oder im VM-File, falls klein)
- Test: `Tests/macSCPCoreTests/RemoteBrowserViewModelTests.swift` (erweitern), ggf. `Tests/macSCPCoreTests/FileSortTests.swift`

**Interfaces:**
- Consumes: `RemoteFileItem` (`name`, `isDirectory`, Größe, Änderungsdatum — die genauen Property-Namen im Typ nachsehen).
- Produces (T2 verlässt sich wörtlich darauf):
  - `public enum FileSortKey: Sendable, Equatable { case name, size, modified }`
  - `RemoteBrowserViewModel.sortedForDisplay(_:key:ascending:)` (static, key/ascending mit Defaults `.name`/`true`)
  - Auf dem VM: `var sortKey: FileSortKey`, `var sortAscending: Bool` (@Observable, didSet → Neuableitung).

- [ ] **Step 1: Failing tests** (rein, Core) für `sortedForDisplay(key:ascending:)`:
  - Ordner-zuerst bei `.name`/`.size`/`.modified`, auf UND ab (auch
    absteigend stehen Ordner oben).
  - `.name` aufsteigend == heutiges Verhalten; absteigend kehrt innerhalb der
    Gruppen um.
  - `.size` NUMERISCH: Items mit Größen 9, 10, 100 ⇒ Reihenfolge 9,10,100
    aufsteigend (nicht lexikografisch 10,100,9).
  - `.modified` nach Zeitstempel auf/ab.
  - Name-Tiebreaker: zwei Dateien gleicher Größe ⇒ nach Name sortiert
    (stabil, deterministisch).
  - fehlende Größe/fehlendes Datum: deterministische Position (dokumentieren,
    welche).

- [ ] **Step 2: Rot beweisen.** `swift test --filter <Sort>` → FAIL.

- [ ] **Step 3: Implementierung.** `sortedForDisplay` bekommt `key`/
  `ascending`; erst nach `isDirectory` gruppieren, dann innerhalb per Schlüssel
  mit Name-Tiebreaker; `ascending == false` kehrt die Innen-Ordnung um, die
  Gruppierung bleibt. Doc-Kommentar: Ordner-zuerst ist bewusste Gruppierung.

- [ ] **Step 4: Failing tests für den VM-Zustand**
  (`RemoteBrowserViewModelTests`, Mock-FS):
  - `sortKey`/`sortAscending` setzen ordnet `items` neu.
  - Überlebt `refreshQuietly` (frische Liste, gleiche Sortierung).
  - Überlebt `load` auf ein neues Verzeichnis (Sortierung bleibt, anders als
    die Suche).
  - Zusammen mit aktivem M11k-Filter: die gefilterte Liste ist sortiert.

- [ ] **Step 5: Rot beweisen, dann implementieren.** `sortKey`/
  `sortAscending` aufs VM, `displayItems(from:)` reicht sie durch,
  didSet-Neuableitung wie bei der Suche.

- [ ] **Step 6: Grün + volle Suite.** `swift test` → 826 + neue.

- [ ] **Step 7: Commit.** `feat: sort the file listing by name, size or date`

---

### Task 2: Spalten-Sortierung in der Tabelle (App)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift` (sortDescriptorPrototypes, `sortDescriptorsDidChange`, Coordinator-Dispatch, Indikator im `PolishedHeaderCell` prüfen)

**Interfaces:**
- Consumes: `FileSortKey` und der VM-Sortierzustand aus T1.

- [ ] **Step 1: `sortDescriptorPrototype`s** auf die drei Spalten
  (`name`/`size`/`modified`), key passend zum `FileSortKey`. Anfangszustand
  der Tabelle spiegelt den VM-Default (`.name` aufsteigend), sodass das
  Dreieck initial an der Namensspalte steht (oder bewusst unsichtbar, falls
  das der M5g-Optik entspricht — im Report festhalten).

- [ ] **Step 2: `tableView(_:sortDescriptorsDidChange:)`** im Coordinator:
  aus dem neuen aktiven `NSSortDescriptor` (key + `ascending`) den
  `FileSortKey` ableiten und `viewModel.sortKey`/`sortAscending` setzen.
  Standardrichtung beim Wechsel auf eine ANDERE Spalte: Name/Datum
  aufsteigend, Größe absteigend (größte zuerst). Die NEUE `items`-Reihenfolge
  fließt über die bestehende Reload-/Reconcile-Mechanik zurück — NICHT AppKit
  die Zeilen selbst sortieren lassen.

- [ ] **Step 3: Indikator.** Prüfen, dass das native Sortier-Dreieck (▲/▼)
  auf der aktiven Spalte sichtbar ist und `PolishedHeaderCell` es
  durchzeichnet, ohne die M5g-Kopf-Optik (Versal, Kern, Hairline, 22 pt) zu
  verschieben. Falls der Custom-HeaderCell den Indikator schluckt, minimal
  nachbessern (nur das Dreieck, nicht die Typo).

- [ ] **Step 4: Verifikation.** `swift build` aus sauberem Verzeichnis (keine
  neuen Warnungen), volle `swift test`. Beide Panes unabhängig prüfen (der
  Zustand hängt am jeweiligen ViewModel).

- [ ] **Step 5: Commit.** `feat: sort the file list by clicking column headers`

---

### Task 3: Abschluss-Verifikation (Koordinator)

- [ ] Gated Suiten: `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → grün, zero skips.
- [ ] Visueller Smoke — Maintainer (Checkliste: Klick auf Name/Größe/Datum
  sortiert; erneuter Klick dreht die Richtung; Ordner bleiben in beiden
  Richtungen oben; Größe numerisch, nicht lexikografisch; das Dreieck steht
  auf der aktiven Spalte; Sortierung überlebt Verzeichniswechsel und
  Auto-Refresh; wirkt zusammen mit ⌘F-Filter; beide Panes unabhängig; M5g-
  Kopf-Optik unverschoben).
- [ ] Plan-Checkboxen, Ledger, Opus-Final-Review, Fix-Runden bis „Yes",
  Push develop, `gh run watch`, Memory. KEIN Release.
