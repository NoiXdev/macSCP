# Backlog: Zwei offene Fragen aus der Abschlussdurchsicht

**Angelegt:** 2026-08-26, als Nachtrag zur Abschlussdurchsicht des Plans
*gescheiterter Aufbau* (`re-review-final.md`). Beide Punkte standen bis
dahin nur unter `.superpowers/`, das `.gitignore:10` ausschließt — sie
wären mit dem Arbeitsverzeichnis verschwunden. **Kein Entwurf.** Beide
Punkte sind ausdrücklich als **begründet, nicht gemessen** markiert; das
ist hier keine Nachlässigkeit, sondern das, was ein Netzversuch bzw. ein
Nebenläufigkeits-Fahrversuch für diesen Befund gekostet hätte, gegen die
Regel dieser Durchsicht, keinen echten Host zu wählen.

## M3 — Ein noch nicht gewählter gespeicherter Sitzungsursprung kann einem ad-hoc-Fehlschlag zugeschrieben werden

**Nur begründet, nicht ausgeführt.**

`connect(in:stored:)` setzt `tab.dialingStoredSessionID = stored.id`
**vor** `await form.connect()`. Läuft zu diesem Zeitpunkt bereits ein
ad-hoc-Wählvorgang des Formulars, weist `ConnectionViewModel.connect()`
den zweiten Aufruf ab (`secondConnectWhileConnectingIsRejected`) — ohne
den Zustand zu ändern, also ohne dass der Mirror den Ursprung verbraucht.
Scheitert dann der **ad-hoc**-Versuch, trägt `ConnectFailure` die
`stored.id`, und die Fläche bietet „Sitzung bearbeiten" für eine Sitzung
an, die dieser Versuch nie gewählt hat.

Erreichbar, weil der Formular-Verbinden-Knopf `tab.isReconnecting`
**nicht** nimmt (nur `connect(in:stored:)` tut das) und
`sidebarConnectTarget` denselben Tab zurückgibt, solange er nicht
verbunden ist.

**Einordnung:** rein kosmetisch — „Erneut versuchen" würde dann die
gespeicherte Sitzung wählen, was vermutlich das ist, was der Nutzer
gerade angeklickt hat. Kein Sicherheitsproblem, keine Datenverwechslung
über eine Fenstergrenze hinweg; nur eine falsch beschriftete Fläche für
einen schmalen Zeitfensterfall.

**Billige Behebung, wenn jemand das angeht:** den Mirror den Ursprung
beim Ablehnen des zweiten Aufrufs ebenfalls räumen lassen, oder
`dialingStoredSessionID` erst NACH einem bestätigten Alleinstellungs-Check
setzen statt davor.

## Die S3-Redirect-Frage

**Offene Frage ohne Beleg, ausdrücklich als solche notiert — kein
gemessener Befund.**

S3 setzt den `Authorization`-Header von Hand und fährt über
`URLSession.shared` **ohne** Delegate, also ohne Redirect-Kontrolle im
Code (im Unterschied zu WebDAV, das `WebDAVSessionDelegate` als einzige
Delegate-Klasse im Baum einsetzt). Ob Foundations `URLSession` diesen
handgesetzten `Authorization`-Header bei einer automatischen
Weiterleitung über eine **andere Origin** hinweg mitnimmt, lässt sich
ohne einen echten Netzversuch nicht entscheiden — und die Abschlussdurchsicht
hat bewusst keinen gemacht (Auflage: kein realer Host).

Der Header trägt nicht den Secret Key, wohl aber die Access-Key-ID und
die Signatur. Eine mitgenommene Signatur an eine fremde Origin ist kein
Klartext-Kreditiv-Leck, aber eine Anfrage-Fälschungs-Fläche, die von der
Antwort eines fremden, redirect-fähigen Endpunkts abhinge.

**Was das für ein Angehen bedeutet:** vor jeder Aussage über die
Sicherheit dieses Pfades braucht es entweder einen kontrollierten
Redirect-Test (ein lokaler Server, der 3xx auf eine zweite Origin
ausstellt, dagegen `S3FileSystem`s echte Anfrage gefahren) oder das
Nachlesen von Foundations dokumentiertem Verhalten für
`Authorization`-Header über Redirects (das sich je nach macOS-Version
und Statuscode unterscheiden kann). Bis dahin ist das eine offene Frage,
kein bestätigter Fehler — und sollte auch so zitiert werden.
