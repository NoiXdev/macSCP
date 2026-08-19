# P3e — Abschluss

**Ziel:** Wer ein Snippet im Terminal ausführt, findet es später im
Sitzungsprotokoll wieder.
**Stand:** fertig. Suite 2118 Tests in 185 Suiten, grün.

## Was die Machbarkeitsmessung entschieden hat

Nicht gebaut wird die Protokollierung freier Tastatureingabe. SSH handelt
Echo nicht aus, SwiftTerms SRM-Modus ist ein Stub, und `sudo` schaltet das
Echo serverseitig per `termios` ab — auf der Leitung unsichtbar. Es gibt
also keinen ehrlichen Weg, getippte Eingaben zu protokollieren, ohne
irgendwann ein Passwort mitzuschreiben. Protokolliert wird nur, was macSCP
selbst absendet und dessen Text es kennt.

## Was die Messung an der Phasengröße geändert hat

Zwei Funde machten sie klein: die Audit-Maschinerie aus M9b steht komplett,
und alle vier Snippet-Oberflächen (Menüleiste, Terminal-Rechtsklick,
Header-Popover samt Doppelklick-Fenster und Zeilen-Kontextmenü,
Sidebar-Submenü) laufen durch **einen** Trichter,
`ContentView.triggerSnippet(_:execute:)`. Es blieb: eine Ereignisart, ein
Core-Formatierer, eine Aufzeichnungszeile, eine Filterkategorie „Terminal",
vier Kataloge.

**Nur Ausführungen.** Ein eingefügtes Snippet steht im Prompt und kann vor
dem Absenden geändert werden; es als „ausgeführt" zu protokollieren wäre
ein falscher Eintrag. Die ⌃⌘-Kürzel belegen ausschließlich Einfügen und
schreiben deshalb nichts.

## Was die Gesamtprüfung fand

**Ein echter, vorbestehender Fehler in `Snippet` — nicht von dieser Phase
verursacht, aber von ihr aufgedeckt.** Der Guard prüfte
`command.contains("\n")` und `contains("\r")`. Swift behandelt `"\r\n"` als
**einen** Grapheme-Cluster, und `String.contains(_:)` sucht graphembasiert:

    let cmd = "cd /srv\r\nls -la"
    cmd.contains("\n")              // false
    cmd.contains("\r")              // false
    Array(cmd.utf8)                 // enthält 13 UND 10

Ein Snippet mit Windows-Zeilenenden kam also durch — und ging mit einem
rohen `0x0D` in der Mitte an die Shell. Das führt die erste Zeile **sofort
aus**, auch beim *Einfügen*, wo der Code ausdrücklich zusagt, nie einen
Zeilenabschluss anzuhängen. Erreichbar über den Snippet-Import (eine unter
Windows erzeugte oder handgeschriebene Datei), weil `init(from:)` durch
denselben Guard läuft. Ebenso passierten U+000B, U+000C, U+0085, U+2028 und
U+2029.

Der Guard heißt jetzt `!command.contains(where: \.isNewline)`, mit roten
Tests für CRLF und den vertikalen Tabulator vorweg.

Außerdem: die Prüfung hat drei unwahre bzw. veraltete Textstellen gefunden
(die Zusage „the log says what actually went out", die veraltete
Guard-Beschreibung im Snippet-Sheet und dessen L10n-Rückfalltext) und einen
schwachen Test, der jetzt über `AuditEvent.Kind.allCases` läuft und damit
jeden künftigen Fall ohne Katalogeintrag fängt.

## Bekannte Grenzen (bewusst so)

- **Der Eintrag entsteht nach dem `send`-Aufruf, nicht nach der
  Zustellung.** `TerminalPanelViewModel.send` ist fire-and-forget: Bytes,
  die vor dem Öffnen der Shell anfallen, werden gepuffert, und scheitert das
  Öffnen, verwirft der Fehlerzweig sie — der Eintrag steht dann trotzdem.
  Realistisch bei einem Konto mit `ForceCommand`. Der Kommentar an der
  Stelle sagt das inzwischen. Eine echte Zustellrückmeldung wäre eine eigene
  Änderung an `send`.
- **Ad-hoc-Verbindungen protokollieren nichts.** Der Recorder hängt an einer
  gespeicherten Session; ohne sie gibt es auch kein Sheet zum Öffnen. Das
  gilt für das ganze Audit-Feature, ist aber hier zuerst spürbar, weil
  Terminal und Snippets auf einer Ad-hoc-Verbindung normal funktionieren.
- **Die Regel „Snippets tragen keine Zugangsdaten" ist zugesagt, nicht
  erzwungen.** Neu ist, dass ein ausgeführter Befehl jetzt auch im
  Sitzungsprotokoll steht — es überlebt das Snippet, landet im Textexport
  des Protokolls und wiederholt sich pro Sitzung. Der Hinweistext im Editor
  sagt das jetzt in allen vier Sprachen.

## Backlog (aus der Prüfung, vorbestehend)

`AuditLogStore.loadIfNeeded` schluckt Decode-Fehler und schreibt beim
nächsten `append` neu. Eine ältere App-Version, die ein Protokoll mit einer
ihr unbekannten Ereignisart liest, sieht es als leer und **überschreibt die
Historie dieser Sitzung**. Gilt für jede je hinzugefügte Art. Ein
nachsichtiger Decoder (unbekannte Werte auf `.unknown` abbilden) wäre der
Fix — vor der nächsten neuen Ereignisart zu erledigen.
