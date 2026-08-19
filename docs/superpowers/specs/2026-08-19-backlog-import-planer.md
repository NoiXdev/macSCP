# Backlog: Import-Planer — halb gefüllte Feldtaschen

**Angelegt:** 2026-08-19, beim Aufräumen der Wegwerf-Berichte unter
`.superpowers/`. Der Punkt stammt aus dem Import-Planer-Durchgang und wurde
dort ausdrücklich als „bewusst nicht behoben" geführt. Vor dem Übertragen am
Quelltext nachgemessen: gilt weiterhin.

## Der offene Fall

`SessionImportPlanner` lässt eine Feldtasche passieren, sobald sie *nicht
leer* ist — nicht erst, wenn sie brauchbar ist. Eine Tasche, die
beispielsweise nur `SSHField.keyPath` enthält, kommt durch; `SSHFieldSchema.apply`
schreibt dann die Vorgaben `host: ""`, `port: 22`, `username: ""`.

Ergebnis: ein sichtbarer, aber nicht wählbarer Datensatz. Er überlebt
`dropsOnLoad`, weil ein `ssh`-Block existiert.

**Nicht betroffen:** die Orphan-Fälle, die derselbe Durchgang behoben hat.
Der Eintrag ist sichtbar und löschbar, und Löschen räumt den Keychain-Slot
mit — also kein Datenleck, sondern ein Ärgernis beim Import kaputter Dateien.

## Verwandter Fall, der bereits im Code steht

Der Zwilling — ein Eintrag mit `jumpHost` und `jumpUsername`, aber ohne
SSH-Block, der über die Jump-Anheftung einen leeren `ssh`-Block bekommt und
dadurch ebenfalls den Drop überlebt — ist im Planer selbst als bekannter,
außerhalb des damaligen Auftrags liegender Rest kommentiert. Wer (a)
angeht, sollte beide in einem Zug erledigen: es ist dieselbe Ursache.

## Warum nicht sofort

Beide Formen entstehen nur aus einer von Hand veränderten oder von einer
fremden Quelle erzeugten Exportdatei. Ein sinnvoller Fix prüft die Tasche
gegen das Pflichtfeld-Schema des Backends statt gegen `isEmpty` — das ist
mehr als eine Zeile und gehört in einen eigenen Durchgang mit Tests für
beide Formen.
