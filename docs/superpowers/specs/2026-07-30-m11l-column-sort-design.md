# M11l — Sortieren per Spaltenklick (Design)

Datum: 2026-07-30 · Status: vom Maintainer freigegeben („passt so")

## Ziel

Die Dateiliste nach Name, Größe oder Änderungsdatum sortieren — Klick auf die
Spaltenüberschrift wählt den Schlüssel, erneuter Klick dreht die Richtung.

## Ausgangslage

- `RemoteBrowserViewModel.sortedForDisplay(_:)` ist heute die EINZIGE
  Sortier-Autorität: Ordner zuerst, dann Name case-insensitiv. Kein Backend
  sortiert. Aufgerufen in `displayItems(from:)` (nach dem Versteckt-Filter,
  vor der M11k-Suche).
- Die Tabelle (`RemoteFileTableView`) hat drei Spalten `name`/`size`/
  `modified` mit `PolishedHeaderCell`; heute reagieren die Überschriften
  nicht auf Klicks (keine `sortDescriptors`).

## 1. Sortier-Autorität parametrisieren (Core)

- Neuer Typ `FileSortKey: Sendable` (`.name` / `.size` / `.modified`).
- `sortedForDisplay(_:key:ascending:)`:
  - **Ordner bleiben immer zuerst** (Gruppierung, unabhängig vom Schlüssel):
    Ordner tragen keine Größe und die Gruppierung ist das heutige Verhalten;
    sie über die Datei-Sortierung zu mischen wäre eine stille
    Verhaltensänderung und bei Größe sinnlos. Innerhalb jeder Gruppe (Ordner,
    Nicht-Ordner) wird nach dem Schlüssel sortiert.
  - `.name`: `localizedCaseInsensitiveCompare` (wie heute).
  - `.size`: numerisch nach Bytegröße; fehlende Größe (z. B. Ordner-Gruppe
    intern) deterministisch ans Ende der Sekundärordnung, dann Name als
    Tiebreaker.
  - `.modified`: nach Zeitstempel; fehlender Zeitstempel deterministisch,
    Name als Tiebreaker.
  - `ascending == false` kehrt die Ordnung INNERHALB der Gruppen um — die
    Ordner-zuerst-Gruppierung bleibt (auch absteigend stehen Ordner oben).
  - Der Name-Tiebreaker macht die Sortierung **stabil/deterministisch**
    (gleiche Größe/gleiches Datum ⇒ immer dieselbe Reihenfolge).
- Der bestehende Aufruf ohne Parameter bleibt als Standard `.name`
  aufsteigend erhalten (Default-Argumente), damit nichts anderes bricht.

## 2. Sortierzustand im ViewModel

- `sortKey: FileSortKey = .name`, `sortAscending: Bool = true`
  (`@Observable`, `didSet` → `displayItems` neu ableiten wie bei der Suche).
- `displayItems(from:)` reicht `sortKey`/`sortAscending` an
  `sortedForDisplay` durch. Damit sortieren `load`, `refreshQuietly` UND die
  M11k-Suche (die `displayedAll` daraus baut) konsistent nach demselben
  Zustand.
- Der Sortierzustand überlebt `refreshQuietly` und Verzeichniswechsel
  (er ist eine Anzeige-Präferenz des Panes, kein Verzeichnis-Attribut) —
  im Gegensatz zur Suche, die beim Wechsel zurückgesetzt wird.

## 3. Bedienung (App)

- Die drei Spalten bekommen `sortDescriptorPrototype`s
  (`name`/`size`/`modified`); die Tabelle meldet Klicks über
  `tableView(_:sortDescriptorsDidChange:)` an den Coordinator.
- Ein Klick auf eine Überschrift: ist es eine ANDERE Spalte, wird sie zum
  Sortierschlüssel (Standardrichtung: Name/Datum aufsteigend, Größe
  absteigend — größte zuerst ist das Erwartbare); ist es die AKTIVE Spalte,
  kippt nur die Richtung.
- Die aktive Spalte zeigt das native Sortier-Dreieck (▲/▼) — AppKit macht
  das über den gesetzten `sortDescriptor`; der `PolishedHeaderCell` muss den
  Indikator durchzeichnen (prüfen, dass die M5g-Kopf-Optik erhalten bleibt
  und das Dreieck sichtbar ist).
- Die tatsächliche Sortierung macht NICHT AppKit auf den NSTableView-Zeilen,
  sondern das ViewModel (die Reihenfolge kommt aus `items`) — der
  `sortDescriptorsDidChange` setzt nur `viewModel.sortKey`/`sortAscending`,
  und die neue `items`-Reihenfolge fließt über die bestehende
  Reload-/Reconcile-Mechanik zurück. So bleibt die Sortier-Autorität an
  EINER Stelle (Core), und Suche/Filter/Sortierung greifen widerspruchsfrei.
- Beide Panes unabhängig (Zustand am jeweiligen ViewModel).

## 4. Bewusst NICHT in M11l

- Keine „Ordner mischen"-Option (Ordner bleiben oben; ggf. später als
  Einstellung).
- Kein Sortieren nach Rechten/Besitzer (die Spalten gibt es noch nicht —
  das ist der nächste Wunsch; wenn sie kommen, bekommen sie ihren
  `FileSortKey`-Fall).
- Kein Persistieren des Sortierzustands über App-Neustarts (Anzeige-
  Präferenz pro Sitzung; ein späteres Settings-Thema).
- Kein Audit-Eintrag.

## 5. Tests

- `sortedForDisplay(key:ascending:)` (rein, Core): Ordner-zuerst bei jedem
  Schlüssel und in beiden Richtungen; `.name` auf/ab; `.size` numerisch
  (nicht lexikografisch — „9" vor „10" nur bei numerischem Vergleich);
  `.modified` auf/ab; Name-Tiebreaker bei gleicher Größe/gleichem Datum
  (Stabilität); fehlende Größe/fehlendes Datum deterministisch.
- VM: `sortKey`/`sortAscending` setzen ordnet `items` neu; überlebt
  `refreshQuietly` und `load` auf ein neues Verzeichnis; wirkt zusammen mit
  einem aktiven M11k-Filter (gefilterte Liste ist sortiert).
- Die AppKit-Kopf-Anbindung hat kein Test-Target → Smoke.

## 6. Aufteilung

T1 Core (parametrisierte `sortedForDisplay` + VM-Sortierzustand, mit Tests)
→ T2 App (Spalten-`sortDescriptor`s, Klick-Handler, Dreieck-Indikator,
beide Panes) → T3 Abschluss. KEIN Release.
