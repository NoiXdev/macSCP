# Zwei offene Fragen aus der Abschlussdurchsicht — Entwurf

**Stand:** 2026-08-28. Umsetzung von
`docs/superpowers/specs/2026-08-26-backlog-offene-fragen-durchsicht.md`.

Der Eintrag führt zwei Punkte, die nichts miteinander zu tun haben außer
ihrer Herkunft. Sie werden hier zusammen entworfen, weil sie zusammen
notiert wurden — aber sie teilen keinen Quelltext, und die eine Hälfte ist
heute noch **nicht entwerfbar**.

---

## Die Asymmetrie zuerst

**M3 ist eine Entwurfsfrage.** Der Mechanismus ist gelesen, der falsche
Zustand ist benannt, die Behebung ist eine Formfrage.

**Die S3-Redirect-Frage ist keine.** Ob es überhaupt etwas zu bauen gibt,
hängt an einer Messung, die niemand gemacht hat. Ein Entwurf davor wäre eine
Behebung für einen Fehler, dessen Existenz unbekannt ist — und dieses Projekt
hat heute dreimal erlebt, dass die Messung den Entwurf umgeworfen hat.

Deshalb: **M3 wird entworfen und umgesetzt. S3 wird gemessen, und der
Entwurf für S3 entsteht danach oder gar nicht.**

---

## M3 — Der Ursprung gehört dem Versuch, nicht dem Reiter

### Der gemessene Ausgangszustand

`connect(in:stored:)` setzt `tab.dialingStoredSessionID = stored.id`
**bevor** `await form.connect()` läuft. Der Kommentar an dieser Stelle
begründet die Reihenfolge sorgfältig — eine `fillForm`-Ablehnung soll keinen
Ursprung hinterlassen — und übersieht dabei den anderen Fall.

`ConnectionViewModel.connect()` beginnt mit:

```swift
guard state != .connecting else { return nil }
```

Ein abgelehnter zweiter Aufruf kehrt also zurück, **ohne den Zustand zu
ändern**. Der Mirror räumt den Ursprung aber ausschließlich bei einem
Zustandswechsel:

```swift
if newState != .connecting { tab.dialingStoredSessionID = nil }
```

Kein Wechsel, kein Räumen. Der Ursprung bleibt stehen und wird dem
**ad-hoc**-Versuch angeheftet, der gleich darauf scheitert. Die Fläche bietet
dann „Sitzung bearbeiten" für eine Sitzung an, die dieser Versuch nie
gewählt hat.

Erreichbar ist das, weil der Verbinden-Knopf des Formulars
`tab.isReconnecting` nicht nimmt und `sidebarConnectTarget` denselben Reiter
zurückgibt, solange er nicht verbunden ist.

**Einordnung, unverändert aus dem Eintrag:** rein kosmetisch. Kein
Sicherheitsproblem, keine Datenverwechslung über eine Fenstergrenze. Nur eine
falsch beschriftete Fläche in einem schmalen Zeitfenster.

### Die Entscheidung (Maintainer, 2026-08-28)

**Den Ursprung an den Versuch binden**, statt ihn nachträglich zu räumen.

Der Eintrag nannte zwei billigere Wege — beim Ablehnen miträumen, oder erst
nach einer Alleinstellungsprüfung setzen. Beide funktionieren. Beide fügen
eine **Aufräumregel** hinzu, und eine fehlende Aufräumregel ist genau das,
was diesen Fehler erzeugt hat. Eine zweite daneben zu stellen behebt den
Fall und lädt den nächsten ein.

`ConnectionViewModel` führt bereits `currentAttempt`, das am Kopf jedes
`connect()` neu vergeben und von `cancelConnecting()` bedingungslos bewegt
wird. Ein abgelehnter Aufruf kehrt **vor** dieser Vergabe zurück — er wird
nie ein Versuch. Wird der Ursprung dort vergeben, wo der Versuch entsteht,
kann ein abgelehnter Aufruf keinen beitragen. Der falsche Zustand ist danach
nicht aufgeräumt, sondern nicht darstellbar.

### Die Form

`connect()` nimmt den Ursprung entgegen und schreibt ihn **nach** dem
Wächter, zusammen mit der Vergabe des Versuchs:

```swift
public func connect(origin: UUID? = nil) async -> (any RemoteFileSystem)? {
    guard state != .connecting else { return nil }
    …
    let myAttempt = UUID()
    currentAttempt = myAttempt
    attemptOrigin = origin
```

Die Fehlerfläche liest danach den Ursprung **des Versuchs, der gescheitert
ist**, statt einer Reiter-Eigenschaft, die überdauern kann.

**`tab.dialingStoredSessionID` entfällt damit ganz.** Das ist der eigentliche
Gewinn: die Eigenschaft, die einen veralteten Wert halten konnte, hört auf zu
existieren.

### Der Vorgabewert, und warum er hier anders liegt als in Task 1

`origin: UUID? = nil` trägt einen Vorgabewert, und dieselbe Woche hat drei
Vorgabewerte aus `SessionListViewModel.init` entfernt, weil ein Weglassen
still eine echte Nutzerdatei las.

**Der Unterschied ist, was das Weglassen bedeutet.** Dort zeigte der
Vorgabewert auf einen realen Ort und ein Test, der ihn wegließ, schrieb in
die Ablage des Maintainers. Hier bedeutet `nil` **ad-hoc** — der wahre und
einzige richtige Wert für einen Aufruf, der keine gespeicherte Sitzung wählt.
Es gibt nichts Reales, das ein Weglassen erreichen könnte.

Gezählt in diesem Durchgang: **zwei** Produktivaufrufe von `form.connect()`
(der Verbinden-Knopf in `ConnectionFormView` und der gespeicherte Weg in
`ContentView`) und **64** Aufrufe unter `Tests/`. Ein Pflichtargument würde
64 Teststellen ändern, um an zwei Produktivstellen etwas auszudrücken, das
an 64 Stellen ohnehin `nil` heißt.

**Die Gegenrede, damit sie nicht verschwiegen ist:** ein Vorgabewert macht es
möglich, den Ursprung an der gespeicherten Stelle zu **vergessen**, und dann
verhält sich ein gespeicherter Wählvorgang wie ein ad-hoc. Das ist eine
sichtbare Verschlechterung, keine stille — die Fläche böte dann kein
„Sitzung bearbeiten" an, wo sie es sollte —, und es ist die Richtung, in die
ein Fehler fallen soll.

### Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: dass ein abgelehnter zweiter Aufruf keinen
Ursprung hinterlässt, und dass ein gescheiterter Versuch den seinen trägt.
Der Zeitfensterfall selbst ist aus dem Test heraus herstellbar, weil beide
Wege auf dem Hauptakteur liegen.

**Nicht prüfbar** bleibt, dass die Fläche im laufenden Fenster die richtige
Beschriftung zeigt. Wie bisher.

---

## Die S3-Redirect-Frage — erst messen

### Was feststeht, ohne Messung

S3 setzt den `Authorization`-Header von Hand und fährt über
`URLSessionHTTPTransport()`, dessen Vorgabe `URLSession.shared` ist.
**`URLSession.shared` kann keinen Delegate haben** — es gibt im S3-Pfad also
keine Redirect-Kontrolle, nicht weil sie weggelassen wurde, sondern weil
diese Sitzung keine aufnehmen kann.

WebDAV macht es bereits anders: eigene `URLSession` aus
`URLSessionConfiguration.ephemeral` mit `WebDAVSessionDelegate`, übergeben an
`URLSessionHTTPTransport(session:)`.

**Die Naht für eine Behebung existiert also schon.** Das ist der Grund, warum
hier nichts entworfen werden muss, bevor gemessen wurde: fällt die Messung
schlecht aus, ist die Behebung das Muster, das nebenan bereits läuft.

Der Header trägt nicht den Secret Key, wohl aber die Access-Key-ID und die
Signatur. Eine mitgenommene Signatur an eine fremde Origin ist kein
Klartext-Kreditiv-Leck, aber eine Anfrage-Fälschungs-Fläche.

### Der Messaufbau

Loopback, kein echter Host — die Auflage der Abschlussdurchsicht gilt weiter.
`Tests/macSCPCoreTests/LoopbackHTTPStub.swift` liefert das Gerüst samt
`seenRequests` und `waitForRequests(atLeast:within:)`.

Zwei Origins entstehen auf Loopback auf zwei Arten, und **beide gehören
gemessen**, weil sie verschieden ausgehen können:

| Fall | erste Origin | zweite Origin | unterscheidet sich in |
|---|---|---|---|
| A | `127.0.0.1:<p1>` | `127.0.0.1:<p2>` | Port |
| B | `127.0.0.1:<p1>` | `localhost:<p2>` | Hostname **und** Port |

Eine Implementierung, die nur beim Hostwechsel abstreift, besteht Fall A und
fällt in Fall B. Nur einen zu messen hieße, eine Aussage über beide zu
treffen.

Gefahren wird die **echte** Anfrage von `S3FileSystem` über den
Vorgabe-Transport — das ist der Gegenstand der Frage. Beobachtet wird, ob die
Anfrage an der zweiten Origin einen `Authorization`-Header trägt.

**Die Positivprüfung daneben ist Pflicht, nicht Kür.** „Kein
`Authorization` an der zweiten Origin" ist eine negative Aussage, und eine
negative Aussage über eine Anfrage, die gar nicht ankam, ist stumm wahr. Die
Messung muss deshalb zuerst belegen, dass die Weiterleitung überhaupt
stattfand und die zweite Origin eine Anfrage gesehen hat — sonst misst sie
einen kaputten Stub und meldet Sicherheit. Genau diese Falle hat in dieser
Woche schon einmal eine Sicherheitszusicherung stumm bestehen lassen.

### Was die Messung entscheidet

- **Header wird nicht mitgenommen:** die Frage wird geschlossen, mit der
  gemessenen macOS-Version dabei. `„auf 26.x nicht mitgenommen"` ist nicht
  dasselbe wie `„wird nicht mitgenommen"` — Foundations Verhalten hängt an
  Version und Statuscode, und der Eintrag sagt das selbst. Ob daraus trotzdem
  ein Delegate folgt, ist dann eine Entscheidung mit Daten statt ohne.
- **Header wird mitgenommen:** S3 bekommt eine eigene Sitzung mit Delegate,
  nach dem Vorbild von WebDAV. Der Entwurf dafür entsteht dann — mit der
  Messung als Beleg und der Frage, ob die Weiterleitung über eine fremde
  Origin abgelehnt oder nur der Header abgestreift wird.

### Was kein Test dieses Projekts sehen kann

Was ein **echter** S3-Anbieter bei einer Weiterleitung tut. Gemessen wird
Foundations Verhalten gegen einen kontrollierten Stub, nicht das Verhalten von
AWS, MinIO oder Ceph. Das genügt für die gestellte Frage — sie handelt von
`URLSession`, nicht vom Gegenüber — und es genügt für nichts darüber hinaus.

---

## Was ausdrücklich nicht dazugehört

- **Keine Änderung an `ConnectionViewModel`s Ablehnung des zweiten
  Aufrufs.** `guard state != .connecting` bleibt, samt seinem Test.
- **Keine Änderung an WebDAVs Delegate** und keine Verallgemeinerung von
  Redirect-Regeln über beide Backends hinweg, bevor gemessen ist.
- **Kein Umbau des HTTP-Transports.** Die Naht
  `URLSessionHTTPTransport(session:)` genügt und wird benutzt, wie sie ist.
- Kein Blockieren, keine neue Einstellung, keine sichtbare Änderung für den
  Nutzer aus M3 heraus — außer der richtigen Beschriftung.
