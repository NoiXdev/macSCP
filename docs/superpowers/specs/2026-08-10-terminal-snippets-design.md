# Terminal-Snippets (Design)

**Stand:** 2026-08-10. Nie beauftragtes Backlog-Feature, erstes Design.

## Was es ist

Wiederverwendbare Kommandozeilen, die sich im SSH-Terminal-Panel einfügen
lassen. Global gepflegt, über ein Menü ausgelöst.

Der Anknüpfungspunkt ist schmal: `TerminalPanelViewModel.send(_ bytes:
[UInt8])` schickt Bytes an die Shell des jeweiligen Tabs. Ein Snippet ist
„Text → Bytes → send". Die Substanz des Meilensteins liegt nicht in der
Mechanik, sondern in zwei Entscheidungen über Risiko.

## Die zwei Risikoentscheidungen

### Einfügen ist der Normalfall, Ausführen ist markiert

Ein Snippet landet in der Eingabezeile; Enter drückt der Nutzer. Er sieht
vorher, was auf welchem Host liefe.

Jedes Snippet kann jedoch als **sofort ausführend** gekennzeichnet werden
(Maintainer-Entscheidung 2026-08-10). Der dagegen vorgebrachte Einwand war:
die Entscheidung fällt beim **Anlegen**, wirkt aber beim **Auslösen**, wo
niemand mehr weiß, welche Einträge scharf sind.

**Das Design löst den Einwand, statt ihn zu überstimmen:** ein eigenes
Menü **„Snippets"** in der Menüleiste, darin zwei Abschnitte — oben die
einfügenden, darunter die ausführenden unter eigener Überschrift. Eine
Gruppierung trägt diese Bedeutung zuverlässiger als ein Symbol am Eintrag,
und sie umgeht die Symbol-Regel aus M19a gleich mit.

### Snippets enthalten keine Zugangsdaten

Der Store ist JSON, und die Projektregel ist eindeutig: Secrets leben
ausschließlich im Schlüsselbund, JSON-Stores enthalten nie welche.

Beim Brainstorming standen drei Gegenvorschläge im Raum. Sie sind hier
festgehalten, weil sie plausibel klingen und **nicht halten**:

| Vorschlag | Warum er nicht trägt |
|---|---|
| Passwortloses SSH statt Passwörtern | Löst ein anderes Problem. macSCPs **eigene** Verbindung kann seit M10d Schlüssel und Agent. Das Snippet-Problem sitzt tiefer: Kommandos, die auf dem **Zielhost** ein Passwort brauchen (`mysql -p`, `sudo`, ein zweiter Hop). Für den zweiten Hop wäre **Agent-Forwarding** die Antwort — in M10d ausdrücklich ausgeschlossen und als eigener Meilenstein im Backlog. |
| History danach löschen | Schützt nicht und richtet Schaden an. Der Befehl steht während der Ausführung in `ps`, wo ihn jeder andere Nutzer der Maschine sieht — dagegen hilft nachträglich nichts. Dazu manipulierte macSCP fremde Shell-History, shell-spezifisch (bash/zsh/fish unterscheiden sich), und löschte dabei Einträge, die der Nutzer behalten wollte. |
| Eigene Shell statt Login-Shell | Umgeht die History-Datei, aber `ps` bleibt. Und das Panel wäre nicht mehr **seine** Shell: Prompt, Aliases, Environment fielen weg. Großer Preis, Teilnutzen, und eine Änderung am ganzen Terminal statt an Snippets. |

**Was trägt:** Zugangsdaten gehören nicht in die Kommandozeile — weder ins
Snippet noch von Hand getippt. Die Werkzeuge haben eigene Wege
(`mysql --defaults-file`, `sudo -S` über stdin, SSH mit Schlüssel).
Der Editor sagt das mit Begründung, statt Sicherheit vorzutäuschen.

Wer später echte Zugangsdaten im Terminal braucht, bekommt sie über
**Agent-Forwarding** als eigenes Feature — nicht über ein Passwortfeld an
Snippets.

## Modell und Ablage

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var runsImmediately: Bool
}
```

`SnippetStore` schreibt `snippets.json` in dasselbe Verzeichnis wie
`known_hosts.json` und `managed_keys.json` — gleiche Bauart wie
`KnownHostsStore`: zustandslos, atomare Schreibvorgänge, keine Secrets.

**Global, nicht pro Host.** Wie Login-Sets und verwaltete Schlüssel. Eine
Bindung an einzelne Sitzungen hat niemand verlangt und zöge Export, Import
und Gruppen mit sich.

## Ein Snippet ist genau eine Kommandozeile

**Eingebettete Zeilenumbrüche werden beim Speichern abgelehnt.** Sonst wäre
„einfügen" gelogen: alle Zeilen bis auf die letzte liefen sofort, ohne dass
jemand Enter gedrückt hätte. Mehrzeilige Skripte sind ein anderes Feature.

Die Ablehnung ist eine Store-/Modellregel, kein Formular-Detail — sie muss
auch für einen von Hand bearbeiteten `snippets.json` gelten.

## Das Auslösen

`send(Array(command.utf8))`, bei `runsImmediately` gefolgt vom
Zeilenabschluss-Byte. Mehr ist es nicht; die Gegenseite ist ein echtes PTY
und zeigt den eingefügten Text in ihrer Eingabezeile.

> **Welches Byte, ist zu prüfen und nicht zu raten.** Die Eingabetaste
> schickt an einem Terminal üblicherweise **CR** (`0x0D`), nicht LF
> (`0x0A`) — ein `\n` kann in einer PTY-Zeilendisziplin wirkungslos sein,
> und dann führt ein als „sofort ausführend" markiertes Snippet nichts aus.
> Der Implementierer stellt fest, was SwiftTerm und die Gegenseite für die
> Eingabetaste tatsächlich senden, und pinnt das Ergebnis in einem Test.
> **Diese Spec legt sich bewusst nicht fest**; sie legt nur fest, dass die
> Antwort gemessen wird.

**Ohne verbundene Sitzung im aktiven Tab sind die Menüeinträge deaktiviert**
— es gibt kein `send`-Ziel, und ein Eintrag, der ins Leere läuft, ist
schlechter als einer, der grau ist.

## Verwaltung

Ein Sheet wie die Login-Sets und die SSH-Schlüssel: Liste, Suchfeld (das
`SheetSearchField` aus M18 existiert bereits), Anlegen, Bearbeiten,
Löschen. Dort steht der Hinweis zu Zugangsdaten.

Der **Shortcuts-Katalog aus M11q wird mitgepflegt**: er ist von Hand
gewartet, und sein eigener Doc-Kommentar nennt das als Pflicht bei jeder
Kürzel-Änderung.

## Was ausdrücklich **nicht** dazugehört

- **Platzhalter** (`{{pfad}}`, aktuelles Verzeichnis).
- **Export/Import.** Die Envelope-Maschinerie aus M19 ist dafür da, aber
  niemand hat es verlangt; Snippets enthalten keine Secrets, ein späterer
  Nachbau ist billig.
- **Bindung an Hosts, Gruppen oder Protokolle.**
- **Mehrzeilige Skripte.**
- **Agent-Forwarding** — eigener Meilenstein, siehe oben.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Ein eingefügtes Snippet endet **ohne** Zeilenabschluss | Test über die erzeugten Bytes |
| 2 | Ein ausführendes Snippet endet mit **genau einem** Zeilenabschluss, und zwar dem, den die Eingabetaste sendet | Test über die erzeugten Bytes; das Byte ist gemessen, nicht angenommen (siehe oben) |
| 3 | Ein Kommando mit Zeilenumbruch wird abgelehnt | Test, auch für einen von Hand geschriebenen Store-Inhalt |
| 4 | Der Store überlebt Schreiben und Lesen unverändert | Roundtrip-Test |
| 5 | Ein fehlender Store liefert eine leere Liste, keinen Fehler | Test — dieselbe Zusicherung wie bei `KnownHostsStore` |
| 6 | Ausführende Snippets stehen im Menü in einem eigenen Abschnitt | Review; App-seitig, kein Test möglich |
| 7 | Ohne verbundene Sitzung sind die Einträge deaktiviert | Review; App-seitig |
| 8 | Der Store enthält nie ein Secret | Review; die Regel steht als Doc-Zusage am Typ |
| 9 | Alle vier Kataloge tragen die neuen Schlüssel | vorhandener Wächtertest, `plutil -lint` |
| 10 | Der Shortcuts-Katalog nennt die neuen Kürzel | Review gegen den Katalog |

## Prüfbarkeit, ehrlich

Store, Modell, die Newline-Ablehnung und die Byte-Kodierung liegen in Core
und sind vollständig testbar. **Die Menü-Verdrahtung ist App-seitig und
bleibt ungepinnt** — dieselbe Grenze, die M29 offengelegt hat: es gibt kein
View-Testwerkzeug im Projekt, und das ist eine bewusste Entscheidung.

Kriterien 6 und 7 sind deshalb Review-Punkte, keine Tests, und der
Abschlussbericht muss das so sagen.

## Für die Release-Notes

**Ein Satz.** Häufig gebrauchte Befehle lassen sich als Snippets ablegen und
im Terminal einfügen.

## Offen, bewusst nicht Teil davon

- Agent-Forwarding (eigener Meilenstein, Backlog seit M10d).
- Platzhalter, Export/Import, mehrzeilige Skripte.
- M29-P3: die Entkernung des Rests von `ContentView`.
- Der Release-Stau: 410 Commits vor `origin/main`.
