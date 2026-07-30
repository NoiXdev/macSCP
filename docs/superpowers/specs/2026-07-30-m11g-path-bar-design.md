# M11g — Interaktive Pfadzeile (Design)

Datum: 2026-07-30 · Status: vom Maintainer freigegeben („ja los gehts")

## Ziel

Die Pfadzeile im Pane-Kopf wird bedienbar: Klick kopiert den Pfad,
Doppelklick öffnet eine manuelle Eingabe, Tab vervollständigt im Shell-Stil
(Maintainer-Entscheid 2026-07-30).

## Ausgangslage

- Die Pfadzeile ist heute ein reiner `Text(viewModel.currentPath)` im Kopf
  von `BrowserPane` (11,5 pt monospaced, `inkTertiary`, `.middle`-Truncation).
- `RemoteBrowserViewModel` kennt `open(_ item:)`, `goUp()`, `refresh()` —
  **kein** direktes Springen auf einen Pfad.
- Beide Panes hängen hinter demselben `RemoteFileSystem`-Protokoll
  (`LocalFileSystem` und `CitadelFileSystem`), das Verzeichnis-Listing ist
  also für Vervollständigung auf beiden Seiten dieselbe Operation.

## 1. Vervollständigung (Core, pur)

`PathCompletion.complete(input:entries:caseSensitive:) -> Result` ist eine
reine Funktion über dem getippten Text und einem Verzeichnis-Listing:

- `Result.completedInput: String` — der Text nach der Ergänzung bis zum
  eindeutigen gemeinsamen Präfix (unverändert, wenn nichts ergänzbar ist).
- `Result.candidates: [String]` — die passenden Ordnernamen, alphabetisch.
- Nur **Verzeichnisse** sind Kandidaten (auf eine Datei zu springen bringt
  nichts) und werden mit `/` ergänzt, damit sofort weitergetippt werden kann.
- Trailing `/` im Input heißt „dieses Verzeichnis listen"; sonst filtert die
  letzte Pfadkomponente per Präfix.
- `caseSensitive` ist ein Parameter, kein Default: die Gegenseite ist es in
  der Regel, ein lokales macOS-Dateisystem in der Standardkonfiguration
  nicht. Ein fester Wert würde in genau einem der beiden Panes falsch
  vervollständigen.

Kandidaten-Ermittlung braucht das Listing des **Elternverzeichnisses** des
getippten Pfades — die App holt es über das FS des Panes und übergibt es;
die Funktion selbst macht keine I/O.

## 2. Springen (Core, ViewModel)

`navigate(to path: String) async -> String?` (nil = Erfolg, sonst
lokalisierte Meldung), nach dem Muster der M7b-Aktionen:

- normalisiert mehrfache und abschließende Slashes (dieselbe Falle wie in
  M7a `deleteTree`: einmaliges Strippen genügt nicht),
- prüft per `stat`, dass das Ziel existiert und ein **Verzeichnis** ist —
  eine Datei bekommt eine eigene Meldung, nicht dieselbe wie „existiert
  nicht",
- **Symlinks (Korrektur 2026-07-30, T1-Review):** `LocalFileSystem.stat`
  meldet für einen Symlink bewusst `kind == .symlink`, auch wenn er auf ein
  Verzeichnis zeigt, während Citadels `stat` Links auflöst. Ein reiner
  `isDirectory`-Test hätte im lokalen Pane also `/tmp`, `/var` und `/etc`
  abgelehnt — Symlinks auf jedem Mac — und zwar mit der sachlich falschen
  Meldung „kein Verzeichnis". Bei `kind == .symlink` wird deshalb ein
  `list()` versucht: gelingt es, ist das Ziel begehbar. Core bleibt damit
  symlink-agnostisch (kein `lstat`, keine Auflösungslogik), und die
  Gegenseite ist unberührt, weil ihr `stat` bereits auflöst.
- fehlende Rechte bekommen die Meldung des Dateisystems,
- bei Erfolg wird geladen wie bei `open`, inklusive Auswahl-Reset.

## 3. Bedienung (App)

- **Einfacher Klick**: kopiert den vollen Pfad in die Zwischenablage. Der
  Zeiger wird zur Hand (sonst ist die Fähigkeit unauffindbar), und eine
  kurze Bestätigung blendet ein und wieder aus — ohne Rückmeldung wüsste
  niemand, ob es geklappt hat.
- **Doppelklick**: die Zeile wird ein Textfeld, vorbelegt mit dem aktuellen
  Pfad, Cursor am Ende. **Enter** springt, **Esc** bricht ab,
  **Fokusverlust** bricht ebenfalls ab — identisch zum Inline-Umbenennen in
  der Seitenleiste (M5f), damit es nur eine Regel zu merken gibt.
- **Tab**: ergänzt bis zum eindeutigen gemeinsamen Präfix. Ein zweites,
  unmittelbar folgendes Tab klappt die Kandidaten unter dem Feld auf; die
  Liste ist anklickbar. Jeder weitere Tastendruck schließt sie wieder.
- Während einer laufenden Vervollständigung bleibt das Feld bedienbar; ein
  langsames Listing darf die Eingabe nicht blockieren.

## 4. Fehler ehrlich

Ein Pfad, der nicht existiert, eine Datei ist oder dem die Rechte fehlen,
lässt das Feld **offen** mit der Meldung darunter — der getippte Text geht
nicht verloren. Kein stilles Verwerfen, kein Zurückfallen auf den alten
Pfad ohne Hinweis.

## 5. Bewusst NICHT in M11g

- Keine anklickbaren Pfad-Segmente (Breadcrumb): der Klick ist per
  Maintainer-Entscheid zum Kopieren belegt.
- Keine Verlaufs-Liste, kein Globbing, keine Lesezeichen.
- Keine `~`-Auflösung auf der Gegenseite: das bräuchte eine Extra-Abfrage
  beim Server, und ein halb funktionierendes `~` ist schlechter als keines.
- Kein Audit-Eintrag (Navigation ist keine Änderung).

## 6. Tests

- `PathCompletion`: absolutes Präfix, eindeutiger Treffer, mehrere
  Kandidaten (gemeinsames Präfix wird ergänzt, Rest bleibt), kein Treffer,
  Trailing-Slash listet alles, Dateien sind nie Kandidaten, Groß-/
  Kleinschreibung in beiden Modi, leeres Listing, Wurzelverzeichnis,
  Komponenten mit Leerzeichen.
- `navigate(to:)`: Erfolg lädt und setzt `currentPath`; Datei statt Ordner,
  nicht existierend und Rechte-Fehler liefern je eine unterschiedliche
  Meldung; Slash-Normalisierung inklusive Doppel-Slash und mehrfachem
  Trailing-Slash; Auswahl wird geleert.
- Gated Rig-Test: Sprung in ein tiefes Verzeichnis und zurück, plus
  Vervollständigung gegen ein echtes Listing.
- EN/DE-Kataloge: Key-Mengen identisch (der Parsing-Wächter aus M11d deckt
  das Format ab).

## 7. Aufteilung

T1 Core (`PathCompletion` + `navigate(to:)` + Rig-Test) → T2 App (Pfadzeile:
Kopieren, Eingabe, Tab, Kandidatenliste, Fehlerzeile, EN/DE) → T3 Abschluss.
KEIN Release.
