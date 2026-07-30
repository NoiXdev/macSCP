# M11h — Symlinks kennzeichnen (Design)

Datum: 2026-07-30 · Status: vom Maintainer freigegeben

## Ziel

Symlinks in der Dateiliste sind erkennbar, und ein Doppelklick auf einen
Symlink, der auf ein Verzeichnis zeigt, öffnet es.

**Maintainer-Entscheidungen (2026-07-30):**

1. **Nur Symlinks** bekommen ein Symbol — Ordner und Dateien bleiben
   unverändert. Das eingefrorene Listen-Layout aus M5g wird so minimal
   berührt, und das Symbol steht genau dort, wo bisher keine Information war.
2. **Der Doppelklick zieht nach**: er versucht hineinzugehen, wie es
   `navigate(to:)` seit M11g tut.

## Ausgangslage

- Die Dateiliste hat **überhaupt keine Icons**. Ordner erkennt man nur am
  angehängten `/` aus `FileListFormatter.displayName(for:)`
  (`item.isDirectory ? item.name + "/" : item.name`).
- Ein Symlink sieht damit **exakt wie eine gewöhnliche Datei** aus.
- Die Zellen entstehen in `RemoteFileTableView`s
  `tableView(_:viewFor:row:)`: pro Spalte ein `NSTableCellView` mit genau
  einem `NSTextField`, das über Auto-Layout mit 12 pt Einzug links und
  12 pt rechts an der Zelle hängt.
- `doubleClicked(_:)` ruft `onOpen` für Verzeichnisse, `onOpenFile` für
  Dateien — Symlinks und `.other` sind ausdrücklich ein No-op.
- `RemoteBrowserViewModel.navigate(to:)` (M11g) prüft genau den Fall, um
  den es hier geht: meldet `stat` einen Symlink, wird ein `list()` versucht;
  gelingt es, ist das Ziel begehbar.

## 1. Das Symbol (App)

In der Namensspalte erhält eine Zeile mit `kind == .symlink` ein
vorangestelltes `NSImageView` mit dem SF-Symbol **`arrow.up.forward`**
(derselbe Pfeil, den macOS selbst für Alias-Verweise verwendet), in
`inkTertiary`, auf der Textgröße der Zeile.

- Das Symbol sitzt **im Einzug**, den die Zeile schon hat: das Textfeld
  bleibt bei 12 pt, das Symbol steht links davor im vorhandenen
  Innenabstand. **Die Zeilenhöhe und die Textposition ändern sich nicht** —
  M5g hat beide gegen das Mockup abgeglichen, und eine Verschiebung wäre
  eine stille Design-Regression in einer Liste, die sonst unangetastet
  bleibt.
- Alle anderen Zeilen (`.file`, `.directory`, `.other`) sehen aus wie heute:
  kein Symbol, kein Platzhalter, keine Einrückung.
- Zellen werden wiederverwendet (`makeView(withIdentifier:)`): das Symbol
  muss bei jeder Wiederverwendung **explizit** ein- oder ausgeblendet
  werden, sonst wandert es auf eine falsche Zeile — der klassische
  Recycling-Fehler.
- Ein Tooltip auf der Zeile nennt den Sachverhalt („Symlink"), damit das
  Symbol auch ohne Vorwissen deutbar ist, und dient gleichzeitig als
  Accessibility-Beschreibung.

**Kein angehängtes `/` für Symlinks**, auch wenn sie auf ein Verzeichnis
zeigen: ohne `stat` pro Eintrag ist das nicht feststellbar (dieselbe
Zurückhaltung wie bei der Vervollständigung in M11g §5). Das Symbol sagt
„das ist ein Verweis", nicht „das ist ein Ordner" — und behauptet damit
nichts, was macSCP nicht weiß.

## 2. Der Doppelklick (App)

`doubleClicked(_:)` bekommt einen dritten Fall: bei `kind == .symlink`
wird der Pfad des Eintrags an denselben Weg gegeben, den die Pfadeingabe
nutzt (`navigate(to:)`). Das heißt konkret:

- Zeigt der Symlink auf ein begehbares Verzeichnis, wechselt das Pane
  hinein — mit dem **Symlink-Pfad** als neuem Ort, nicht mit dem
  aufgelösten Ziel. `navigate(to:)` verhält sich schon so, und ein
  aufgelöster Pfad würde `goUp()` an eine Stelle führen, von der der
  Benutzer nie gekommen ist.
- Zeigt er auf eine Datei oder ist er defekt, erscheint die Meldung aus
  `navigate(to:)` — dieselbe, die die Pfadeingabe zeigt. Kein stilles
  No-op mehr.
- `.other` bleibt ein No-op wie bisher.

Damit verschwindet die Unstimmigkeit, die der M11g-Review benannt hat:
Tippen folgte einem Symlink, Klicken nicht.

## 3. Was bewusst NICHT passiert

- Kein `stat` pro Listeneintrag, um Symlink-Ziele vorab aufzulösen: das
  wäre eine zusätzliche Abfrage pro Zeile über die Verbindung, für einen
  kosmetischen Gewinn.
- Kein Anzeigen des Ziels („aktuell → /var/www/releases/2026-07"): dafür
  bräuchte es ein `readlink`, das das FS-Protokoll heute nicht hat.
- Keine Icons für Ordner und Dateien (Maintainer-Entscheid).
- Die Vervollständigung bietet weiterhin keine Symlinks an (M11g §5 bleibt
  unverändert gültig) — sie bekommt kein `stat`-Budget.
- Kein Audit-Eintrag (Navigation ist keine Änderung).

## 4. Tests

- `FileListFormatter`: ein Symlink bekommt **kein** angehängtes `/`, auch
  wenn er „aktuell" heißt; Ordner und Dateien unverändert (Regression).
- Menü-/Verhaltensmodell: das bestehende `BrowserContextMenu`-Verhalten für
  Symlinks bleibt unangetastet (kein Übertragen, kein Editor, keine Rechte)
  — durch Test gepinnt, damit diese Runde es nicht versehentlich aufweicht.
- Der Doppelklick-Weg ist in der App-Schicht und hat kein Test-Target; die
  Kern-Logik dahinter (`navigate(to:)` inklusive Symlink-Zweig) ist aus
  M11g bereits abgedeckt, inklusive gated Rig-Test.
- Gated: ein Symlink auf ein Verzeichnis und einer auf eine Datei im Rig,
  über `navigate(to:)` — der erste gelingt, der zweite liefert die Meldung.

## 5. Aufteilung

T1 App (Symbol in der Namensspalte inkl. Recycling-Hygiene, Doppelklick,
Tooltip, EN/DE) + Core-Kleinigkeit (kein `/` für Symlinks, mit Test) →
T2 Abschluss. KEIN Release.
