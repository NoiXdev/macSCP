# M11k — Suche in der Dateiliste (Design)

Datum: 2026-07-30 · Status: vom Maintainer freigegeben (beides umschaltbar,
Regex, ⌘F)

## Ziel

In der aktuellen Verzeichnis-Liste suchen: entweder **filtern** (nur Treffer
zeigen) oder **zur Fundstelle springen** (Liste bleibt voll, Auswahl wandert),
umschaltbar; optional als regulärer Ausdruck. Feld auf ⌘F, Esc schließt.

## Grenze (wichtig)

Die Suche wirkt **nur auf die aktuell geladene Liste** eines Panes — kein
rekursiver Gang durch den Baum, keine zusätzlichen Server-Abfragen. Die
Trefferzahl („12 von 431") bezieht sich auf die Einträge des aktuellen
Verzeichnisses (nach dem Versteckt-Filter). Rekursive Suche wäre ein eigener,
viel größerer Meilenstein.

## Ausgangslage

- `RemoteBrowserViewModel.load()`/`refreshQuietly()` bauen `items` über
  `displayItems(from:)` = Versteckt-Filter + Sortierung. `items` IST die
  angezeigte Liste; es gibt heute keine getrennte „volle" Liste.
- Die Dateiliste ist das `NSTableView` aus M11j; Auswahl läuft über
  `onSelect`/`viewModel.selectedItems`.
- ⌘F ist bisher unbelegt. M11j hat einen **fokus-gescopten**
  `performKeyEquivalent` in `KeyboardDrivenTableView` — der ideale Ort, ⌘F
  ans FOKUSSIERTE Pane zu leiten.

## 1. Reiner Matcher (Core)

`FileSearchMatcher` (pur, testbar):

- `compile(query:isRegex:) -> Result<Predicate, FileSearchError>`:
  - leerer/blanker Query ⇒ „alles passt" (kein Filter).
  - `isRegex == false`: case-insensitiver **Teiltext** auf dem Dateinamen.
  - `isRegex == true`: `NSRegularExpression` (case-insensitiv), Teiltreffer
    im Namen zählt. Ein **ungültiger** Ausdruck ⇒ `.failure(.invalidRegex)`
    — ein eigener Fall, NICHT „keine Treffer".
- `matches(name:) -> Bool` auf dem kompilierten Prädikat.

Warum kompiliert-dann-anwenden: der reguläre Ausdruck wird EINMAL geprüft/
gebaut, nicht pro Zeile; und der Ungültig-Fall ist sauber vom Leer-Treffer-
Fall getrennt (der Maintainer hat ausdrücklich eine eigene, ehrliche
Fehleranzeige verlangt).

## 2. Suchzustand im ViewModel

Additiv, ohne die bestehende `items`-Bedeutung zu brechen:

- Neue gespeicherte Basis `displayedAll: [RemoteFileItem]` = das Ergebnis von
  `displayItems(from:)` VOR der Suche (Versteckt-gefiltert, sortiert).
  `load()`/`refreshQuietly()` setzen sie; die Suche leitet daraus ab.
- `searchQuery: String`, `searchIsRegex: Bool`,
  `searchMode: SearchMode` (`.filter` / `.jump`).
- Abgeleitet:
  - **Filter-Modus:** `items` = `displayedAll` ∩ Matcher; zusätzlich
    `searchMatchCount` und `searchTotalCount` für „N von M".
  - **Sprung-Modus:** `items` = `displayedAll` (voll); ein
    `searchMatchPaths`/`currentMatchIndex`, das die Auswahl auf den nächsten
    Treffer setzt (Enter/„weiter" iteriert, Umbruch am Ende).
  - **Ungültiger Regex:** `items` bleibt unverändert stehen (nicht leeren!)
    und ein `searchError` wird gesetzt — die UI zeigt ihn, statt „0 Treffer"
    vorzutäuschen.
- Bei jeder Änderung von Query/Modus/Regex-Schalter neu ableiten. `load()`
  auf ein neues Verzeichnis **setzt die Suche zurück** (leerer Query) —
  ein Filter aus dem alten Ordner soll nicht stumm den neuen verstecken.
- `refreshQuietly()` behält den aktiven Suchzustand bei (der Ordner ist
  derselbe), wendet ihn auf die frische Liste an.

Die Ableitung (Query+Modus+Liste ⇒ sichtbare Items / Match-Indizes /
Fehler) ist eine **reine, testbare** Funktion; die VM ruft sie nur.

## 3. Bedienung (App)

- **⌘F** öffnet über der Dateiliste des FOKUSSIERTEN Panes ein Suchfeld —
  geleitet über den fokus-gescopten `performKeyEquivalent` aus M11j (nur die
  fokussierte Tabelle reagiert). Fokus wandert ins Feld.
- Das Feld enthält: das Textfeld, einen **Modus-Umschalter** (Filtern /
  Springen), einen **Regex-Schalter** (`.*`), rechts die Trefferzahl
  („12 von 431"). Bei ungültigem Regex statt der Zahl eine rote,
  konkrete Meldung.
- **Springen-Modus:** Enter setzt die Auswahl auf den nächsten Treffer,
  ⇧Enter auf den vorherigen, Umbruch. Die Trefferzahl zeigt „Treffer k/N".
- **Esc** schließt das Feld, leert die Suche und zeigt wieder alles; der
  Fokus geht zurück auf die Tabelle.
- Das Feld ist **pro Pane** (jedes Pane sucht in seiner eigenen Liste); der
  Zustand hängt am jeweiligen ViewModel/Tab, überlebt also einen
  Tab-Wechsel nicht als globaler Zustand.
- Type-Select der Tabelle (M11j) bleibt unberührt — das Suchfeld ist ein
  eigener Fokus.

## 4. Fehler ehrlich

- Ungültiger regulärer Ausdruck: eigene rote Meldung im Suchfeld, die Liste
  bleibt stehen (kein vorgetäuschtes „keine Treffer").
- Kein Treffer bei GÜLTIGER Suche: „0 von M" bzw. „keine Treffer" — das ist
  ein legitimes Ergebnis, keine Fehlermeldung.

## 5. Bewusst NICHT in M11k

- Keine rekursive/Server-seitige Suche über das aktuelle Verzeichnis hinaus.
- Kein Suchverlauf, keine gespeicherten Suchen.
- Kein Ersetzen/Bulk-Umbenennen über Treffer.
- Keine Suche über Größe/Datum/Rechte — nur über den Namen.
- Kein Audit-Eintrag (Suche ist reine Anzeige).

## 6. Tests

- **Matcher (Core):** leerer Query ⇒ alles; Teiltext case-insensitiv;
  Regex gültig (Teiltreffer, Anker `^`/`$`, `\.log$`); Regex UNGÜLTIG ⇒
  `.invalidRegex` (nicht „kein Treffer"); Unicode/Umlaut im Namen.
- **Ableitung (Core/VM-nah):** Filter-Modus reduziert `items` und liefert
  N/M; Sprung-Modus lässt `items` voll und liefert Match-Indizes + Umbruch
  vorwärts/rückwärts; ungültiger Regex lässt `items` stehen und setzt den
  Fehler; `load()` auf neues Verzeichnis setzt die Suche zurück;
  `refreshQuietly()` behält sie und wendet sie auf die frische Liste an;
  Auswahl im Sprung-Modus zeigt auf den erwarteten Pfad.
- EN/DE-Kataloge: Key-Mengen identisch.
- Die AppKit-/SwiftUI-Feld-Anbindung hat kein Test-Target → Smoke.

## 7. Aufteilung

T1 Core (`FileSearchMatcher` + reine Ableitung + VM-Suchzustand, mit Tests)
→ T2 App (Suchfeld, Modus-/Regex-Schalter, Trefferzahl/Fehler, ⌘F über den
M11j-Fokusweg, Esc, EN/DE) → T3 Abschluss. KEIN Release.
