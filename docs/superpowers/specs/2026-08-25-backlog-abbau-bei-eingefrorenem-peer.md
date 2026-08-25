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
