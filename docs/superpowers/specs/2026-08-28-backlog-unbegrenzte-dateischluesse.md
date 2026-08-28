# Backlog: Unbegrenzte Dateischlüsse

**Angelegt:** 2026-08-28, als Nebenbefund zweier Messungen am Abbau gegen
eine eingefrorene Gegenseite. **Kein Entwurf, und ausdrücklich kein
gemessener Fehler** — eine gelesene Beobachtung mit einem bekannten
Vorbild daneben.

## Woher das kommt

Zwei Aufrufe sind an diesem Tag gemessen worden, und beide hingen gegen
einen schweigenden Peer:

- `SFTPClient.close()` in `disconnect()` — behoben mit einer Frist
  (`7ac7f7e`)
- `CitadelShell.close()` in `terminal.shutdown()` — behoben mit einer
  Stufenfrist (`eed1c8a`)

Beide hatten dieselbe Form: ein `await` auf eine Antwort der Gegenseite,
ohne Decke. Beim Nachzählen des zweiten Falls fiel eine dritte Familie
derselben Form auf.

## Der gezählte Befund

**8 wörtliche `SFTPFile.close()`-Aufrufstellen**, alle in
`Sources/macSCPCore/SSH/CitadelFileSystem.swift`, sonst nirgends unter
`Sources/`. Keine davon ist begrenzt.

Die Zahl ist mehrdeutig und deshalb aufgeschlüsselt, weil ein Vorbericht
sie ohne Aufschlüsselung nannte: **5** haben `SFTPFile` als direkten
Empfänger, die anderen **3** gehen über die Box `SFTPReadHandle` und
laufen alle in derselben Stelle zusammen.

**Gelesen, nicht gemessen:** vier davon sitzen in Abbruch- und
Fehlerzweigen und eine in einem Weg, der über `cancelAll` Schritt 3
erreichbar ist — also auf einem Abbau-Pfad, und zwar vor
`terminal.shutdown()`. Eine weitere sitzt in einem `deinit` und läuft
abgekoppelt: sie hält niemanden auf, kann aber eine Task lecken.

**Fünf weitere unbegrenzte Schlüsse in derselben Datei gehören
ausdrücklich NICHT dazu**, in diesem Durchgang mitgezählt, damit der
nächste Leser sie nicht für einen Fund hält: die Schlüsse auf
`jumpAgent`/`targetAgent`. Das sind `AgentAuthContext`-Verbindungen zum
lokalen SSH-Agenten über einen Unix-Socket — sie sprechen nicht mit der
Gegenseite und können an einem schweigenden Peer nicht hängen. Sie liegen
zudem auf dem Verbindungs-, nicht auf dem Abbau-Pfad.

## Warum das kein „behebt sich mit demselben Handgriff" ist

`cancelAll` ist inzwischen **gemessen** worden und kommt zurück —
0,0045 s mit laufendem 8-MB-Download gegen den eingefrorenen Peer,
dreimal von drei. Der eine Abbau-Pfad, der über diese Aufrufe führt, hängt
also heute nicht.

Das ist der Grund, warum hier ein Eintrag steht und keine Aufgabe: die
Form ist verdächtig, der Fall ist es nicht. Eine Frist um acht Aufrufe zu
legen, von denen keiner nachweislich hängt, wäre genau das, was diese
Woche schon einmal zurückgenommen wurde — die Frist um `cancelAll` fing
nichts und kostete eine sichtbare Verhaltensänderung.

## Was zu tun wäre, wenn jemand das angeht

**Zuerst messen, nicht begrenzen.** Ein Transfer, der mitten im Schreiben
oder Lesen steht, während die Gegenseite verstummt — kommt der
Dateischluss zurück? Das Rig kann das (`docker pause`), und die Technik
steht in `.superpowers/sdd/frozen-peer-measurement.md` und
`.superpowers/sdd/shell-close-measurement.md`.

Kommt er zurück, gehört das Ergebnis hierher und der Eintrag wird
geschlossen. Kommt er nicht zurück, ist die Behebung bereits gebaut:
`BoundedClose` trägt die Form, und `TeardownStage` zeigt, wie eine
aufgegebene Stufe sichtbar wird.

**Die Falle beim Messen**, teuer gelernt am selben Tag: jede
Nachbedingung wird **vor** dem Auftauen abgelesen. Ein Lauf dieser Serie
war grün, während der Defekt vorlag, weil er den Zustand erst danach
abfragte. Steht seit dem 2026-08-28 als Regel in `CLAUDE.md`.

## Was das nicht ist

- **Kein bestätigter Fehler.** Niemand hat einen hängenden Dateischluss
  gesehen; es ist eine Formähnlichkeit zu zwei Fällen, die hingen.
- **Kein Grund, `deinit` anzufassen.** Der abgekoppelte Schluss dort ist
  eine eigene Frage (eine geleckte Task, kein Hänger) und gehört nicht in
  denselben Vorgang.
- Keine Verallgemeinerung auf andere Backends. S3 und WebDAV fahren über
  `URLSession`, die eigene Fristen führt.
