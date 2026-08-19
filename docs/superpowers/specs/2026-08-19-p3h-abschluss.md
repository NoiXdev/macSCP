# P3h — Abschluss

**Ziel:** „Exportieren" in der Fußzeile bedeutet in beiden Sheets dasselbe
und sagt vorher, wie viele Einträge geschrieben werden.
**Stand:** fertig. Suite 2139 Tests in 188 Suiten, grün.

## Was gebaut wurde

`ListExportScope.resolve(selectedID:from:)` im Core: die Auswahl, falls sie
zu den sichtbaren Zeilen gehört, sonst alle sichtbaren. Beide Fußzeilen
rufen sie — bisher stand die Regel als private Methode nur in einem der
beiden Sheets, das andere hatte gar keine. Der Snippet-Export bekam dazu
eine Bestätigung mit der Anzahl: ohne sie wäre die Verengung auf eine
Auswahl unsichtbar, also genau das, wovor die Spec warnt.

Das **Zeilen**-Kontextmenü blieb unangetastet: es exportiert weiterhin genau
seine Zeile, unbestätigt. Der Klick ist die Aussage über den Umfang.

Nachgeprüft in der Gesamtprüfung: das Verhalten der Login-Sets ist Fall für
Fall unverändert, auch für eine Auswahl, die der Filter vom Schirm genommen
hat, und für eine veraltete Kennung.

## Was die Gesamtprüfung fand

**Zwei Kommentare, die der Commit unmittelbar davor gerade repariert
hatte, waren wieder falsch** — dieselbe Stelle, dieselbe Ursache: die Phase
verschob, wer `performExport` ruft, ohne den Kommentar nachzuziehen, der die
Aufrufer beschreibt.

**Ein Doc-Kommentar behauptete eine Historie, die es nie gab:** „a second
copy is how Export came to mean two different things". Es gab nie eine
zweite Kopie — die Regel stand nur in einem Sheet, das andere hatte keine.
Die wahre Fassung ist zugleich das stärkere Argument für die Auslagerung.

**Eine Namenskollision aus meinem Plan:** der neue Typ hieß `ExportScope`,
genau wie das vorhandene `SessionListViewModel.ExportScope`
(`.single`/`.group`/`.all`). Es kompilierte, weil die Aufrufstellen
qualifizieren — lesbar war es nicht. Jetzt `ListExportScope`, und in
`Presentation/` statt `Sessions/`.

**Der Bestätigungsknopf teilte sich den Schlüssel mit dem Auslöser.** Das
widerspricht dem Muster derselben Datei (`snippets.delete` /
`snippets.delete.confirm`), setzt eine Ellipse auf einen Bestätigungsknopf
und war der einzige Grund, warum ein vorhandener Zähl-Wächter von 2 auf 3
gelockert werden musste. Jetzt `snippets.export.confirm`, und der Wächter
steht wieder auf 2.

## Offen

**Eine Sichtprüfung, die kein Test ersetzen kann.** Der Bestätigungsknopf
bewaffnet den Speichern-Dialog aus der Aktion eines sich schließenden
Alerts heraus — auf macOS also ein Sheet auf einem Fenster, das gerade ein
anderes abbaut. Das Vorbild im Haus (`LoginSetsSheet`) tut dasselbe, aber
aus einem `.sheet`, nicht aus einem `.alert`, und läuft. Wahrscheinlich
unproblematisch, aber ungetestet: **Snippets öffnen → „Exportieren…" →
bestätigen → erscheint der Speichern-Dialog?** Falls nicht, ist die
Reparatur ein `DispatchQueue.main.async` um den Aufruf in der Alert-Aktion.

**Singular-Grammatik**, geerbt von `logins.export.summary`: „1 snippets will
be written…". Bei Login-Sets war die Eins der Ausnahmefall, bei Snippets ist
sie nach dieser Phase der Regelfall (Zeile auswählen → Exportieren). Der
ehrliche Fix ist ein `.stringsdict`, kein zweigeteilter String — die
polnischen Pluralregeln machen eine Zwei-Wege-Verzweigung ohnehin falsch.
Eigene, kleine Aufgabe für beide Schlüssel gemeinsam.
