# Backlog: S3 folgt Weiterleitungen ohne Kontrolle

**Angelegt:** 2026-08-28, aus der Messung, welche die S3-Frage der
Abschlussdurchsicht beantwortet hat. **Die Sicherheitsfrage ist beantwortet
und entwarnt** — was hier steht, sind die Befunde daneben.

**Entscheidung des Maintainers (2026-08-28): angehen, als eigener
Vorgang.** Nicht wegen der Signatur.

## Was gemessen wurde, und was dabei herauskam

Gemessen mit `S3FileSystem.connect` ohne eingespeisten Transport — also der
echten signierten Anfrage über `URLSessionHTTPTransport()` und damit
`URLSession.shared`. Zwei Origin-Formen, fünf Statuscodes, zehn Fälle.
macOS 26.6.2 (25G83), Swift 6.3.3, CFNetwork 3860.700.1.

**`Authorization` wird nicht mitgenommen. In keinem der zehn Fälle.**

Damit ist die ursprüngliche Sorge — eine Signatur an einer fremden Origin —
widerlegt. Der Test steht im Baum und stellt dieselbe Frage auf jeder
Plattform neu, auf der die Suite läuft; das ist Absicht, weil das Verhalten
Foundations undokumentiert und versionsabhängig ist.

## Die drei Befunde, die bleiben

### 1. Die Weiterleitung wird gefolgt, nicht verweigert

Die fremde Origin erfährt den Bucket-Pfad, die Listenabfrage, `x-amz-date`,
`x-amz-content-sha256` — und über den mitgereisten `Host` den konfigurierten
Endpunkt. Keine Signatur, keine Access-Key-ID. Aber auch nicht nichts.

**Das ist der Grund für den Vorgang.** Er behebt nichts Hypothetisches: die
Preisgabe ist gemessen, nur kleiner als befürchtet.

### 2. Der handgesetzte `Host` reist mit und ist danach falsch

S3 setzt `Host` ausdrücklich, weil er Teil der SigV4-Signatur ist. Nach
einem Sprung auf eine andere Origin trägt die Anfrage weiterhin den alten
Wert — gemessen: eine Anfrage an `localhost:<p2>` mit
`Host: 127.0.0.1:<p1>`.

Kein Kreditiv-Problem, aber bei virtual-hosted Adressierung eine falsch
adressierte Anfrage. Und es ist der Weg, über den Befund 1 den Endpunkt
preisgibt.

### 3. Foundation streift den Header bei **jeder** Weiterleitung ab

Auch bei gleicher Origin und nur anderem Pfad — im Kontrollarm gemessen.

Das ist keine Sicherheits-, sondern eine **Funktionsfrage**: eine legitime
Weiterleitung eines Anbieters käme unsigniert an und würde abgelehnt.
Niemand hat einen solchen Fall gesehen; er gehört hierher, damit die
Behebung ihn nicht übersieht.

## Was ein Vorgang zu klären hätte

Die Naht existiert bereits und wird benutzt, wie sie ist:
`URLSessionHTTPTransport(session:)`. WebDAV fährt genau so, mit
`URLSessionConfiguration.ephemeral` und `WebDAVSessionDelegate` als
einziger Delegate-Klasse im Baum. **`URLSession.shared` kann keinen
Delegate tragen** — das ist der ganze Grund, warum im S3-Pfad keine
Kontrolle sitzt.

Offen und beim Entwerfen zu entscheiden:

- **Ablehnen oder umsigniert folgen?** Eine Weiterleitung über eine fremde
  Origin abzulehnen ist die strengere und einfachere Antwort. Ihr neu zu
  folgen und dabei für das neue Ziel zu signieren behebt zusätzlich Befund 3
  — und ist deutlich mehr Arbeit, weil die Signatur den `Host` bindet.
- **Was „fremd" heißt.** Schema, Host und Port, oder nur der Host? Die
  Messung zeigt, dass Foundation hier gar nicht unterscheidet; das Projekt
  müsste es selbst festlegen.
- **Gilt dasselbe für `sendStreaming`?** Der Download-Pfad geht über
  `URLSession.bytes(for:)` — dieselbe Sitzung, ein anderer
  Foundation-Einstieg. **Nicht gemessen.** Vor dem Entwerfen messen.

## Was das nicht ist

- **Keine Behebung eines Lecks.** Es gibt keins; die Messung sagt das
  ausdrücklich.
- **Keine Änderung an WebDAVs Delegate** und keine gemeinsame
  Weiterleitungs-Politik über beide Backends, bevor jemand das entworfen
  hat.
- Keine Aussage über echte S3-Anbieter. Gemessen wurde Foundation gegen
  einen kontrollierten Stub auf Loopback — das genügt für die gestellte
  Frage und für nichts darüber hinaus.
