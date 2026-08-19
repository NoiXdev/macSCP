# Snippet-Editor Teil 2 — mehrzeilige Snippets: Abschluss

**Stand:** fertig, mergefähig nach einer Fix-Welle. Suite **2217 Tests in 199
Suiten**, grün. Ausgangswert vor dem Zweig: 2197 in 196.

## Was umgesetzt wurde

Ein Snippet darf mehrere Zeilen haben. Was beim Auslösen auf die Gegenseite
geht, entscheidet der Bracketed-Paste-Modus, den die entfernte Shell
einschaltet und der lokale Emulator mitschreibt.

| Befehl | Klammerung | Aktion | Ergebnis |
|---|---|---|---|
| einzeilig | egal | beides | wie bisher, byteweise unverändert |
| mehrzeilig | an | einfügen | `ESC[200~` + Rumpf + `ESC[201~` |
| mehrzeilig | an | ausführen | dito + CR |
| mehrzeilig | aus | ausführen | zeilenweise, CR nach jeder Zeile |
| mehrzeilig | aus | einfügen | **abgelehnt**, mit Angebot auszuführen |

Zwischen den Klammern stehen die rohen UTF-8-Bytes des Rumpfs. Das ist nicht
geraten, sondern an SwiftTerms eigenem ⌘V-Pfad abgelesen: `paste(_:)` reicht
den Zwischenablage-String unverändert an `send(txt:)`, das daraus
`[UInt8](txt.utf8)` macht — keine Zeilenenden-Übersetzung auf dem ganzen Weg.

Kein Feld am Modell, keine Store-Migration: ein Snippet **enthält** Umbrüche
oder nicht, der Inhalt trägt die Information. `Snippet.init` verlor damit
seinen einzigen Fehlschlag-Grund und ist nicht mehr fehlbar; **95**
Aufrufstellen wurden nachgezogen, der Umbruch-Sanitizer gelöscht.

Im Editor schreibt Return jetzt einen Umbruch, Speichern ist ⌘Return (eine von
**drei** `.defaultAction`-Stellen der Datei, die anderen zwei blieben), und das
Feld wächst bis zu einer Obergrenze mit.

## Kompatibilität — in eine Richtung

Alte `snippets.json` laden unverändert; das Format hat sich nicht geändert, der
Decoder ist nur nachsichtiger geworden.

**Umgekehrt gilt es nicht.** Eine mit diesem Build geschriebene mehrzeilige
Datei macht die **ganze** Datei für die ausgelieferte 1.2.0 unlesbar, deren
Decoder auf den Umbruch wirft. Das gehört in die Release-Notes; ein Fix ist es
nicht, weil ein Downgrade kein unterstützter Weg ist.

## Das Schluss-Review fand einen Critical, den kein Task-Review sehen konnte

`isVerticallyResizable = false` nagelte den Rahmen der Textansicht fest. Eine
`NSScrollView` scrollt genau so weit, wie der Rahmen ihres Dokuments reicht —
`hasVerticalScroller = true` allein bewirkt nichts. Jenseits der
Acht-Zeilen-Grenze war der Text gesetzt, aber unerreichbar, und die
Einfügemarke verließ beim Tippen das Sichtfeld.

Der Prüfer hat das nicht vermutet, sondern **mit einer AppKit-Probe gemessen**:
bei 5, 12, 30 und 60 Zeilen blieb der Rahmen bei 150 pt, während der Text 88,
200, 488 und 968 brauchte.

**Der Fehler stand so im Plan.** Er schrieb „`isVerticallyResizable` bleibt
`false`" *und* „danach senkrechter Scroller" — ein Widerspruch, den der
Umsetzer getreu beidem umgesetzt hat. Es ist der vierte Plan-Defekt dieses
Zweigs und der teuerste.

Weiter behoben: `SnippetKeystrokes.bytes(for:execute:)` war verwaiste
öffentliche API geworden, die genau die Gefahr wieder aufmachte, gegen die der
Zweig gebaut ist (sie liefert für einen mehrzeiligen Befehl die rohen Umbrüche
als Tastenanschläge) — jetzt `internal`. Die ganze App→Core-Verdrahtung war
ungetestet; der Prüfer bewies es durch Mutation, nicht durch Behauptung: `??
false` zu `?? true` gedreht, 318 Tests blieben grün. Und der Ablehnungs-Alert
konnte verschluckt werden, weil der Auslöser feuerte, bevor Sheet und Popover
geschlossen waren — die Fix-Welle fand dafür **zwei** Auslöser-Formen mit vier
Closures, nicht die eine aus dem Befund.

## Was ungeprüft bleibt — Sichtprüfung beim Maintainer

Kein Test dieses Projekts zeichnet einen `NSViewRepresentable` oder spricht mit
einer echten Shell. Ausdrücklich offen:

- **Das Mitwachsen des Feldes** samt Obergrenze, und dass jenseits davon
  senkrecht gescrollt werden kann. Der Critical oben war genau hier.
- **⌘Return speichert**, Return schreibt einen Umbruch.
- **Die drei Anzeigestellen** mit einem mehrzeiligen Befehl: Zeile im Sheet,
  Vorschauzeile am Terminal-Panel (beide „+N weitere"), und das Aktions-Sheet,
  das den Befehl absichtlich ganz zeigt.
- **Der Ablehnungs-Alert aus allen vier Auslösern** — er ist das einzige neue
  Modal des Zweigs, und die Präsentationsreihenfolge war ein Befund.
- **Ein geklammertes Einfügen gegen eine echte Shell** mit eingeschaltetem
  Modus 2004.

## Die Lektion dieses Zweigs

Vier der fünf Fehler, die Reviews fanden, standen **im Plan**, nicht in der
Umsetzung: eine Zahl, die ein Grep falsch zählte; ein Wächtertest, der nie
hätte bestehen können; ein Kommentar, der eine Ausnahme verschwieg; und der
Widerspruch oben. Die Umsetzer haben jedes Mal getan, was dastand.

Das ist die dritte Wiederholung desselben Befunds in diesem Projekt.
Plan-Prosa klingt beim Schreiben vollständig und wird beim Umsetzen geglaubt.
Was hilft, ist nicht mehr Sorgfalt beim Schreiben, sondern dass die
Umsetzer den Auftrag haben, Widersprüche zu **melden statt aufzulösen** — beide
Male, wo das geschah, kam ein echter Fund heraus.
