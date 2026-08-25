# Backlog: Keep-alive als zwei Einstellungen statt einer

**Angelegt:** 2026-08-25, aus einem Prüfbefund zu Task 9 des
Verbindungszustands. Klein, klar umrissen — und die Ursache war eine falsche
Vorgabe von mir, nicht ein Umsetzungsfehler.

## Was heute gilt

`SettingsStore.keepAliveIntervalSeconds` ist **ein** gespeicherter `Int`:
`0` heißt „aus", jeder andere Wert wird auf 15…600 geklemmt. Die Oberfläche
bildet das über einen Schalter plus Intervallfeld ab, mit einem
**ansichtslokalen, nicht gespeicherten** Merker für das zuletzt benutzte
Intervall.

## Der Preis, gemessen

Keep-alive ausschalten, App beenden, neu starten, wieder einschalten — das
selbst gewählte Intervall ist weg und steht wieder auf 60. Der Merker lebt
nur in der Ansicht, und der gespeicherte Wert wurde beim Ausschalten mit der
`0` überschrieben.

Das ist offengelegt (die Erläuterung im Einstellungsbereich sagt es), aber
es ist kein gutes Verhalten.

## Warum es so kam

**Die Auflage „ein gespeicherter Wert, keine zweite Einstellung" stammt aus
meinem Auftrag und war falsch.** Als Muster hatte ich ausdrücklich den
Auto-Refresh-Abschnitt derselben Datei genannt — und der besteht aus
**zwei** Einstellungen:

```
autoRefreshEnabled          Bool
autoRefreshIntervalSeconds  Int, geklemmt 2…300
```

Dort ist das Intervall immer gültig, es gibt keinen magischen Wert, und ein
Neustart verliert nichts. Ich habe gegen den Hausbrauch entschieden, den ich
selbst zitiert hatte.

## Was zu tun wäre

`keepAliveEnabled: Bool` einführen, `keepAliveIntervalSeconds` auf 15…600
klemmen ohne Sonderfall `0`, und den ansichtslokalen Merker ersatzlos
streichen.

**Nicht mehr in Task 9 gemacht, mit Begründung:** der `0`-Sonderfall ist
bereits in Core ausgeliefert und wird von der Sonde gelesen — beides
geprüft und abgeschlossen. Die Core-API am Ende eines langen Zweigs zu
ändern kauft eine kleine Verbesserung für ein echtes Regressionsrisiko in
Code, den gerade niemand mehr ansieht.

Beim Anfassen zu beachten: eine Migration ist nötig, aber trivial — ein
gespeichertes `0` wird zu `enabled: false` plus dem Vorgabeintervall. Und
die Klemmung gehört wie beim Nachbarn in **Getter und Setter**, damit eine
von Hand editierte Datei weder Spam noch einen toten Zeitgeber erzeugt.
