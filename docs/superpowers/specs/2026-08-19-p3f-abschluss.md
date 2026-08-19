# P3f — Abschluss

**Ziel:** Exportieren überall über das Zeilen-Kontextmenü.
**Stand:** fertig. Suite 2128 Tests in 186 Suiten, grün.

## Was die Messung ergab

Der Auftrag lautete, vor dem Planen zu messen, welche Listen exportierbare
Dinge zeigen und was ihr Kontextmenü schon kann. Ergebnis: **vier von fünf
waren bereits fertig.**

| Liste | Export in der Zeile |
|---|---|
| Sitzung (Sidebar) | vorhanden, `export.menu.single` |
| Gruppe (Sidebar) | vorhanden, `export.menu.group` |
| Login-Sets | vorhanden, `logins.export.action` |
| SSH-Schlüssel | vorhanden, öffentlich und privat |
| Snippets (Sheet) | **fehlte** — jetzt ergänzt |

Damit war die Phase ein Eintrag, kein Umbau.

## Die offene Frage der Spec war schon beantwortet — im Code

Die Spec fragte, ob „Exportieren" an der Zeile dasselbe meint wie im Sheet.
`LoginSetsSheet` beantwortet das seit M19 mit Kommentar: *„the footer button
covers 'all' (or whatever is selected); this one always means THIS row."*
Der Zeileneintrag setzt vorher die Auswahl, damit sichtbare Auswahl und
wirksamer Umfang nie auseinanderlaufen. Der neue Snippet-Eintrag überträgt
genau dieses Muster — keine zweite Regel.

## Was die Gesamtprüfung fand

**Die Messung war unvollständig.** Es gibt ein **sechstes** Zeilen-
Kontextmenü auf einer Liste mit exportierbaren Dingen: den Terminal-
Snippet-Picker aus P3d (`ContentView+Detail.swift`, `SnippetRowContextMenu`)
mit Ausführen / Einfügen / Vorschau. Er wurde weder gezählt noch bewusst
ausgeschlossen. Zwei kleinere Nachbarn ebenso: das Audit-Protokoll (Export
nur in der Fußzeile, gar kein Zeilenmenü) und die importierten Hosts
(Zeilenmenü mit nur „Ausblenden").

Kein Code geändert — aber „überall" ist damit belegt-für-fünf und
offen-für-den-Picker. **Das ist eine Maintainer-Entscheidung**, kein
stiller Ausschluss: ein Speichern-Dialog mitten in einer laufenden
Terminal-Sitzung ist plausibel unerwünscht, aber das entscheidet nicht die
Phase.

Außerdem: zwei Kommentare, die nicht mehr stimmten (der Suite-Kommentar des
neuen Wächters versprach eine Reihenfolge-Zusicherung, die eine Korrektur
zuvor entfernt hatte; `performExport`s Kommentar kannte nur einen Aufrufer,
seit dieser Phase gibt es zwei), und ein Wächtertest, der über die ganze
Datei suchte und die richtigen Vorkommen nur durch Reihenfolgen-Glück traf.
Er isoliert jetzt den Zeilen-Menüblock, scheitert bei fehlendem Anker statt
still durchzugehen, und zählt `"snippets.export"` auf genau zwei Vorkommen —
das fängt die Drift, die ein bloßes `contains` nicht sehen konnte.

## Offen, bewusst nicht entschieden

**Der Bestätigungsschritt fehlt bei Snippets — an beiden Auslösern.**
`LoginSetsSheet` öffnet sowohl aus der Fußzeile als auch aus der Zeile sein
Export-Sheet mit Optionen und Anzahl; der Snippet-Export geht direkt in den
Speichern-Dialog. Sachlich begründet: `SnippetExportCodec` hat weder
Optionen noch Passwort, ein Optionen-Sheet hätte nichts zu zeigen.

**Die Fußzeilen meinen Verschiedenes.** Login-Sets exportieren die Auswahl,
falls eine sichtbar ist, sonst alle sichtbaren — und nennen die Anzahl,
bevor geschrieben wird. Snippets exportieren immer die sichtbare Menge und
ignorieren die Auswahl. Beides vorbestehend, von dieser Phase nicht
angefasst. Eine Vereinheitlichung wäre eine Verhaltensänderung an
ausgeliefertem Code und gehört dem Maintainer vorgelegt, nicht nebenbei
erledigt — zumal ohne Bestätigungsschritt eine Auswahl-Verengung bei
Snippets **unsichtbar** wäre, also genau das, wovor die Spec warnt.
