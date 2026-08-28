# Backlog: Abbau gegen eine eingefrorene Gegenseite

**Angelegt:** 2026-08-25, aus einer Selbstmeldung in Task 10 des
Verbindungszustands. Klein, aber die Lücke sitzt an einer unangenehmen
Stelle.

## Der Befund

Der Integrationstest friert die Gegenseite ein (`docker pause`): die Sockets
bestehen, sshd antwortet nie. Die Sonde erkennt das korrekt nach zwei
Sieben-Sekunden-Fristen, gemessen 14,1–14,9 s.

**Der Test taut vor dem Aufgabe-Lauf wieder auf — mit Absicht.** Denn
`disconnect()` ruft `try? await sftp.close()`, und ob dieser Aufruf gegen
eine nie antwortende Gegenseite **terminiert**, ist offen.

Gegen einen *getöteten* Container läuft der volle Abbau durch und ist in
Millisekunden fertig. Nur der eingefrorene Fall ist ungeprüft.

## Warum das zählt

Wenn `disconnect()` dort hängt, hängt `teardown` — und damit der Weg, über
den `handleLivenessGiveUp` den Zustand `.lost` überhaupt erst schreibt. Die
Erkennung wäre dann richtig und die Reaktion bliebe trotzdem aus.

Der eingefrorene Fall ist zudem der realistischere: ein Netz, das
verschwindet, tötet selten den Socket. Es hört einfach auf zu antworten.

## Was zu tun wäre

Den bestehenden Einfrier-Test um einen Abbau erweitern, **ohne** vorher
aufzutauen, und messen, ob er zurückkommt. Kommt er nicht zurück, braucht
`disconnect()` dieselbe Behandlung, die die Sonde schon hat: eine Frist, die
hält, auch wenn der darunterliegende Aufruf es nicht tut — das Muster steht
mit `LivenessProbeRace` bereits im Baum.

Zu beachten: der Test muss den Container in jedem Fall wieder auftauen und
entfernen, auch wenn er in eine Frist läuft. Task 10 löst das über `defer`
und ein `docker rm -f`, das auch einen pausierten Container entfernt.

---

## Gemessen und behoben (2026-08-28, `7ac7f7e`)

**Die offene Frage ist beantwortet, und zwar mit „nein".** `disconnect()`
terminiert gegen eine eingefrorene Gegenseite nicht.

Gemessen am realen Aufgabe-Pfad: betreten, nie verlassen — innerhalb zweier
unabhängiger Schranken von 120 s und 30 s. Nach `docker unpause` kam derselbe
aufgegebene Aufruf in 0,000491834 s zurück. Er war also nie langsam; er
wartete auf eine Antwort.

Die Zuordnung, an einem Wegwerf-Gerüst direkt an den Citadel-Objekten:

| Aufruf | kommt zurück, während der Peer eingefroren ist? | gemessen |
|---|---|---|
| `SFTPClient.close()` | **nein** | 20,01678975 s gegen 20 s Schranke |
| `SSHClient.close()` | **ja** | 0,051039125 s |

Damit hängt genau eine Zeile, und der Weg daran vorbei war offen. `try?`
verschluckt einen Fehler; es begrenzt keine Wartezeit.

**Die Behebung:** `BoundedClose` gibt diesem einen Aufruf eine Frist in der
Form von `LivenessProbeRace`, außerhalb des Hauptakteurs, und gibt ihn auf,
wenn die Frist gewinnt — wodurch `client.close()` und `jumpClient?.close()`
überhaupt erst laufen. Die Abbau-Reihenfolge bleibt unberührt.

**Fünf Sekunden**, von beiden Seiten belegt: der langsamste von zehn gesunden
`disconnect()`-Läufen gegen das Rig lag bei 0,001507583 s, und die Frist wird
zusätzlich zu einer Erkennung ausgegeben, die bereits 14,1–14,9 s kostet.

| | vorher | nachher |
|---|---|---|
| eingefrorener Peer | 127,946259083 s, **kein** Rückkehren, Tab bleibt `.degraded` | **5,050603459 s**, Tab wird `.lost`, Sitzung `nil` |
| getöteter Container | 0,006492291 s | 0,006294584 s |

Der gegatete Test leitet seine eigene Schranke aus der Produktionskonstante
ab, statt eine zweite Kopie der Zahl zu führen.

## Nachtrag vom selben Tag: die Behebung greift nur ohne Terminal

**Die Zahlen oben sind richtig und beschreiben trotzdem den Ausnahmefall.**
Der Test, der sie erzeugt hat, öffnet keine Shell — sein Platzhalter-Opener
wirft, was eine bewusste Entscheidung aus einem anderen Test ist und keine
Umgebungslücke.

Mit **offener Shell** gemessen, drei unabhängige Läufe:

| | mit offener Shell | Kontrolle ohne Shell |
|---|---|---|
| Abbau kommt zurück? | **nein**, ≥30 s (nicht abbrechende Frist) | ja, 5,340685209 s |
| `disconnect()` betreten? | **nein** | ja |
| Tab | `.degraded`, Sitzung bleibt gesetzt | `.lost`, Sitzung `nil` |

Der einzige Unterschied ist das offene Terminal. Nach `docker unpause` kam
der aufgegebene Abbau in 0,0022 / 0,0017 / 0,0019 s zurück.

**Die Ursache ist die Reihenfolge.** `teardown` wartet auf vier Stufen:

```
cancelAll → editManager.stopAll() → terminal.shutdown() → disconnect()
```

Die Frist aus `7ac7f7e` sitzt in der **letzten**. `CitadelShell.close()` ist
`pump.cancel(); await pump.value` — ein unbegrenztes Warten auf eine
abgebrochene Aufgabe — und hängt in der dritten. Die Frist wird nie
erreicht.

Mindestens zwei weitere unbegrenzte Wartepunkte liegen davor: `cancelAll`
Schritt 3 wartet auf laufende Transfers, und `editManager.stopAll()` ist
nicht untersucht.

**Entscheidung des Maintainers (2026-08-28): jede Stufe einzeln begrenzen.**
Nicht der Abbau als Ganzes — seine Reihenfolge ist eine Invariante dieses
Projekts, und eine Frist darum würde sie mittendrin abbrechen und nicht
sagen, welche Stufe hing.

**Eine Lektion aus dem Messen selbst, die nichts mit SSH zu tun hat:** der
erste Lauf war **grün, während der Defekt vorlag**. Seine Nachbedingungen
lasen `enteredAt` und `liveness` erst **nach** dem Auftau-Block — also
nachdem der Peer wieder antwortete und der Abbau nachgeholt hatte. Eine
Prüfung, die nach der Heilung liest, ist keine Prüfung.

## Was offen bleibt — und eine Maintainer-Frage

**Ungegatet hält nichts die Verdrahtung.** Dass `BoundedClose` das Richtige
tut, ist ungegatet geprüft. Dass `disconnect()` es *benutzt*, hält allein der
gegatete Integrationstest. Ein Rückbau auf `try? await sftp.close()` bliebe
in einer CI ohne Docker grün.

Ein Quelltext-Wächter wurde **bewusst nicht** gebaut: er müsste zwei Namen
buchstabieren, die er nicht ableiten kann — genau die Sorte, vor der
`CLAUDE.md` unter „Guards that name what they watch" warnt. Die Frage war
damit nicht „welcher Wächter", sondern ob sich der ungebundene Aufruf
**strukturell** ausschließen lässt, wie beim Verbinden geschehen.

**Beantwortet und gebaut (2026-08-28, `c71a7c3`): ja.** `BoundedSFTPSession`
hält den rohen Client `private`, hat einen `private init` und eine
`closeBounded()` **ohne Argumente**; die Frist ist eine Eigenschaft des
Typs. Neun Weiterleitungen tragen die übrigen Operationen. **Null
Teständerungen**, weil `init` ohnehin schon `private` war und kein Test
`SFTPClient` nennt.

Sechs Verstöße gepflanzt, alle rot — darunter der, den ein Leser wirklich
schreiben würde, der „nur eben den rohen Client braucht":

```swift
extension BoundedSFTPSession { var unbounded: SFTPClient { raw } }
// error: 'raw' is inaccessible due to 'private' protection level
```

Dass das scheitert, hängt an `private` statt `fileprivate` — der Grund,
warum der Typ in seiner eigenen Datei liegen muss. Zur Kontrolle wurde die
Lücke am Stand davor bestätigt: dort kompiliert `try? await sftp.close()`.

**Was die Grenze nicht verhindert**, beides ausgeführt und im Typ
dokumentiert: den Schluss ganz zu **löschen** kompiliert, und
`try? await client.openSFTP().close()` kompiliert ebenfalls — frischer
Kanal, gespeicherte Sitzung unberührt (und weil `openSFTP()` selbst ein
Umlauf ist, brächte es denselben Hänger zurück). Sie erzwingt das **Wie**,
nie das **Ob**. Ein Quelltext-Wächter steht bewusst *nicht* daneben: einer
neben einer strukturellen Garantie lässt den nächsten Leser der Suite mehr
vertrauen, als sie verdient.

Weitere benannte Grenzen: die fünf Sekunden sind gegen Loopback bemessen;
`client.close()` ist nur in *dieser* Reihenfolge schnell gemessen, mit einem
aufgegebenen `sftp.close()` in der Luft; und `docker pause` ist ein Modell
eines verschwundenen Netzes, nicht das Netz selbst.
