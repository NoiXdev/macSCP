# Snippet-Editor Teil 2 — mehrzeilige Snippets (Design)

**Stand:** 2026-08-19, freigegeben. Setzt auf Teil 1 auf
(`2026-08-19-snippet-syntax-design.md`, abgeschlossen und sichtgeprüft).

## Ausgangslage

Ein Snippet ist heute **eine** Befehlszeile. `Snippet.init?` scheitert, sobald
der Befehl ein Zeichen enthält, für das `Character.isNewline` gilt — das ist
der einzige Grund, aus dem dieser Initializer überhaupt scheitern kann. Teil 1
hat diese Klemme sichtbar gemacht und ausdrücklich stehen lassen: das
Eingabefeld wandelt eingefügte Umbrüche in Leerzeichen, „solange Teil 2 nicht
da ist".

Der Bedarf sind kleine, wiederkehrende Abläufe: ein Datenbank-Export, ein Log
einsammeln und unter einem Namen ablegen. Drei Zeilen, kein Skript.

## Die entscheidende Frage war nicht der Editor

Sie war, **was auf der Gegenseite passiert**. Der Editor ist der leichte Teil.

Gemessen, nicht angenommen: `Terminal.bracketedPasteMode` in SwiftTerm ist
`public private(set) var`, und SwiftTerms eigener ⌘V-Pfad auf macOS wertet ihn
aus (`MacTerminalView`: `if isPaste, terminal.bracketedPasteMode { … }`).
**Bracketed Paste ist ein Modus, den die entfernte Shell einschaltet und den
der lokale Emulator mitschreibt** — die App kann ihn also lesen, ohne die
Gegenseite zu befragen. `getTerminal()` ist öffentlich; der Zustand ist von der
App-Schicht aus erreichbar, wo `TerminalView` lebt.

**Maintainer-Entscheidung:** geklammert, wenn der Modus an ist, sonst
zeilenweise. Damit übernimmt macSCP die Regel, die SwiftTerm für ⌘V ohnehin
anwendet, statt eine eigene zu erfinden.

Verworfen wurden:

- **Immer zeilenweise.** Überall gleich, aber eine fehlschlagende Zeile stoppt
  die folgenden nicht, und startet eine Zeile ein Programm, das `stdin` liest
  (`python`, `mysql`, `ssh`), landet der Rest in diesem Programm.
- **Immer als Heredoc.** Ein logischer Befehl unabhängig vom Modus — aber er
  läuft in einer Subshell, also wirken `cd`, `export`, `source` nicht mehr auf
  die Sitzung, und ausgeführt wird nicht mehr wörtlich das, was dasteht.

## Kein Modus am Snippet

Ein Snippet **enthält** Umbrüche oder nicht; der Inhalt trägt die Information
bereits. Ein zusätzliches `multiline`-Flag wäre ein Zustand, der dem Inhalt
widersprechen kann — Flag aus, Inhalt zweizeilig, wer gewinnt? Es entfällt,
und mit ihm die Store-Migration und die Anpassung an Export/Import.

Preis, bewusst getragen: die Eingabetaste muss im Befehlsfeld einen Umbruch
schreiben. Damit ist die in Teil 1 offen gebliebene Return-Frage nicht
beobachtet, sondern **umdefiniert** — sie stellt sich nicht mehr.

## Modell

`Snippet.init?` verliert die Umbruch-Abweisung. Kein neues Feld. Das
Store-Format bleibt unverändert: ein JSON-String trägt Umbrüche, alte Dateien
lesen sich ohne Migration.

`SnippetCommandInput.sanitized` fällt **ersatzlos** weg — seine einzige
Aufgabe war das Ersetzen von Umbrüchen durch Leerzeichen. Der Aufruf im
`shouldChangeTextIn:`-Zweig des Editors verschwindet mit ihm; ein eingefügter
mehrzeiliger Befehl ist ab jetzt gültige Eingabe.

`Snippet.command` bleibt `let`. Der Grund dafür war nie allein die
Umbruch-Regel, sondern auch die Tag-Normalisierung — siehe den Doc-Kommentar
des Typs.

## Senden: eine reine Funktion mit einem Ergebnistyp

Neu in Core, neben `SnippetKeystrokes`. Sie liefert **nicht** nur Bytes,
sondern einen Typ, der auch „abgelehnt" sagen kann — sonst müsste ein
Menüpunkt Bytes senden, die etwas anderes tun, als er verspricht:

```swift
public enum SnippetSendPlan: Equatable {
    case send([UInt8])
    /// Einfügen ist ohne Klammerung nicht ohne Ausführen möglich.
    case refusedMultilineInsert
}
```

Eingaben: der Snippet-Befehl, `execute: Bool`, `bracketedPaste: Bool`.

| Befehl | Klammerung | Aktion | Ergebnis |
|---|---|---|---|
| einzeilig | egal | einfügen | Bytes des Befehls |
| einzeilig | egal | ausführen | Bytes + CR |
| mehrzeilig | an | einfügen | `ESC[200~` + Rumpf + `ESC[201~` |
| mehrzeilig | an | ausführen | dito + CR |
| mehrzeilig | aus | ausführen | zeilenweise, CR nach **jeder** Zeile |
| mehrzeilig | aus | einfügen | `refusedMultilineInsert` |

**Ein einzeiliger Befehl wird nie geklammert**, auch wenn der Modus an ist.
Das hält das heutige Verhalten byteweise identisch und ist ein eigener Test
wert: der häufigste Fall darf sich durch diese Änderung nicht verschieben.

Die App liest `bracketedPasteMode` und reicht das `Bool` hinein. Core sieht
SwiftTerm nicht und bleibt ohne Terminal testbar.

**`SnippetKeystrokes` bleibt und behält seine Aufgabe:** die Bytes einer
einzelnen Zeile samt Terminator, mitsamt der dort niedergeschriebenen
Belegkette für das CR. Die neue Funktion **ruft sie auf** — für den
einzeiligen Fall unverändert, für den zeilenweisen Rückfall je Zeile. So ist
die Gleichheit im häufigsten Fall keine Behauptung eines Tests gegen ein
Literal, sondern strukturell: es ist derselbe Aufruf. Der Test hält das nur
fest.

### Was zu messen ist, bevor es geschrieben wird

**Welche Zeilenenden zwischen den Klammern stehen.** Das ist dieselbe Sorte
Frage wie das CR in Teil 1, das dort vermessen statt geraten wurde. Der Plan
misst am Paste-Pfad von SwiftTerm nach, welche Bytes ein mehrzeiliger
Zwischenablage-Inhalt zwischen `ESC[200~` und `ESC[201~` tatsächlich erzeugt,
und legt die Belegkette als Doc-Kommentar an die Naht — so wie
`SnippetKeystrokes.terminator` sie heute für das CR trägt.

Bis diese Messung vorliegt, steht in dieser Spec **keine** Byte-Behauptung
über den Rumpf.

## Ablehnung an der Oberfläche

`refusedMultilineInsert` wird nicht verschluckt. Die auslösende Stelle zeigt
einen Hinweis: dass die Gegenseite mehrzeiliges Einfügen ohne Ausführen nicht
anbietet, mit dem Angebot, stattdessen auszuführen. Text lokalisiert in allen
vier Katalogen (`en`, `de`, `fr`, `pl`) — der Wächtertest hält die
Schlüsselmengen gleich.

## Editor

Alles, was Teil 1 gebaut und der Maintainer geprüft hat, bleibt: kein Umbruch,
waagerechtes Scrollen, Einfärbung, abgeschaltete automatische Ersetzungen,
Tab wandert weiter.

Was sich ändert:

- **Return schreibt einen Umbruch.** Der `insertNewline(_:)`-Anspruch im
  `doCommandBy:` entfällt; der zugehörige Wächtertest wird umgedreht, statt
  gelöscht zu werden — er hält dann fest, dass Return **nicht** beansprucht
  wird.
- **Speichern wird ⌘Return**, und zwar nur im Snippet-Editor. Die übrigen
  `.defaultAction`-Stellen der Datei bleiben unangetastet; welche das sind,
  zählt der Plan im selben Moment nach, in dem er sie anfasst.
- **Das Feld wächst mit** — eine Zeile hoch bei einzeiligem Befehl, dann pro
  Zeile mehr bis zu einer Obergrenze, danach senkrechter Scroller. Die
  Obergrenze ist ein Schätzwert und gehört in die Sichtprüfung.
- Die Bedienhilfen-Beschriftung bleibt, wie sie ist (M6a-Invariante).

## Liste

Die Snippet-Liste zeigt den Befehl als Text. Bei mehreren Zeilen zeigt sie die
**erste Zeile**; dass weitere folgen, muss erkennbar sein. Die genaue Form
(Marker, Zeilenzahl) entscheidet die Umsetzung am Bestand — sie soll dem
Rhythmus der Liste folgen, nicht ihn brechen.

## Protokoll: nichts zu tun, aber jetzt belastet

`SnippetAuditDetail` faltet Weißraum schon heute zu einfachen Leerzeichen
zusammen, und in Swift ist **jedes** Zeichen mit `isNewline` auch
`isWhitespace` — ein mehrzeiliger Befehl geht also von selbst einzeilig ins
Protokoll. Das ist keine Änderung.

Es ist aber ab jetzt eine **belastete** Regel: geschrieben wurde sie, als es
mehrzeilige Befehle nicht geben konnte. Sie bekommt deshalb ihren eigenen
Test.

## Tests

**Die Sendefunktion, vollständig** — jede Zeile der Tabelle oben, plus die
Ablehnung.

**Konstant-Rückgabe-Probe:** eine Implementierung, die immer dieselben Bytes
liefert, muss an mindestens zwei dieser Fälle scheitern. Eine, die immer
klammert, scheitert am einzeiligen Fall.

**Der einzeilige Fall ist byteweise unverändert** — gegen das heutige
`SnippetKeystrokes.bytes(for:execute:)` geprüft, nicht gegen ein neu
hingeschriebenes Literal.

**Das Modell nimmt Umbrüche an:** `Snippet(name:command:)` mit `"a\nb"` ist
nicht mehr `nil`, und ein `"\r\n"` im Befehl überlebt den Roundtrip durch den
Store. Der CRLF-Fall verdient seinen eigenen Test aus demselben Grund, aus dem
ihn Teil 1 hatte: `"\r\n"` ist **ein** Grapheme-Cluster.

**Das Protokoll bleibt einzeilig** bei mehrzeiligem Befehl.

**Wächter in der App-Schicht**, dem Muster von `SnippetCommandEditorGuardTests`
folgend: Return wird nicht mehr beansprucht, Tab weiterhin schon, und das
Speichern-Kürzel ist ⌘Return.

## Was ungeprüft bleibt

Die Darstellung: das Mitwachsen des Feldes, ⌘Return, und wie sich ein
geklammertes Einfügen im laufenden Terminal anfühlt. Kein Test dieses Projekts
zeichnet `NSViewRepresentable`, und keiner spricht mit einer echten Shell im
Bracketed-Paste-Modus. **Sichtprüfung beim Maintainer**, und das gehört so in
den Abschlussbericht.

Teil 1 hat für diese Klasse den Beleg geliefert: das Schluss-Review fand den
Umbruch-Fehler korrekt, und der Fix ersetzte ihn durch zwei neue, die
ebenfalls plausibel aussahen und erst der Blick auf die laufende App fand.

## Nicht in diesem Teil

- **Heredoc.** Die Klammerung löst den Fall besser — ohne den Befehl
  umzuschreiben und ohne Subshell.
- **Variablen mit Abfrage** und ein `shell`/`telnet`-Marker: Teil 3, siehe
  `2026-08-19-backlog-snippet-teil-3.md`.
