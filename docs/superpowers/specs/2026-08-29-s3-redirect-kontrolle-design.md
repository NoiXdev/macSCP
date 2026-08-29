# S3-Weiterleitungen kontrollieren — Entwurf

**Stand:** 2026-08-29. Umsetzung von
`docs/superpowers/specs/2026-08-28-backlog-s3-weiterleitungen.md`.

**Dieser Vorgang war bis heute nicht baubar.** S3 fuhr auf
`URLSession.shared`, und die geteilte Session kann keinen Delegate tragen.
Seit `36a68fe` hat S3 eine eigene Session — die Kontrolle ist damit
überhaupt erst erreichbar geworden.

---

## Der gemessene Ausgangszustand

Aus der Messung vom 2026-08-28, zehn Fälle über zwei Origin-Formen und fünf
Statuscodes:

| | |
|---|---|
| `Authorization` über eine Weiterleitung | **wird nicht mitgenommen**, in keinem Fall |
| andere handgesetzte Kopfzeilen (`x-amz-date`, `x-amz-content-sha256`, `Host`) | reisen mit |
| Weiterleitung selbst | wird **gefolgt**, nicht verweigert |
| gleiche Origin, nur anderer Pfad | Header wird **ebenfalls** abgestreift |

Daraus die drei Befunde, die der Backlog-Eintrag festhält: die fremde Origin
erfährt Bucket-Pfad, Listenabfrage, Zeitstempel und — über den mitgereisten
`Host` — den konfigurierten Endpunkt; der `Host` ist danach falsch; und eine
**legitime** Weiterleitung käme unsigniert an und scheiterte.

Der letzte Punkt ist eine Funktions-, keine Sicherheitsfrage — und er ist
der Grund, warum „alles ablehnen" die falsche Antwort wäre.

## Entscheidungen des Maintainers (2026-08-29)

### 1. Gleiche Origin: neu signieren und folgen. Fremde Origin: ablehnen.

Bei gleicher Origin wird die Anfrage **für das neue Ziel neu signiert** und
gefolgt. Das behebt zugleich den Funktionsfehler: die Weiterleitung kommt
signiert an statt nackt.

Eine fremde Origin wird **abgelehnt**, mit einer Meldung, die nennt, wohin
der Endpunkt schicken wollte. Ihr Bucket-Pfad und Endpunkt preiszugeben ist
genau die Anfrage-Fälschungs-Fläche, die der Eintrag benennt — und der
Nutzer erfährt lieber, dass sein Endpunkt ihn woandershin schicken wollte,
als dass es stillschweigend geschieht.

### 2. „Fremd" heißt Schema, Host und Port

Die Origin-Definition aus RFC 6454, ohne Ermessen. `https` → `http` ist
damit fremd, ein Portwechsel auch.

Das Herabstufen auf Klartext ist ausdrücklich der Fall, den das mit abdeckt:
eine Weiterleitung, die die Verschlüsselung wegnimmt, ist die, der man am
wenigsten folgen will.

## Der Entwurf

### Ein eigener Delegate, kein geteilter

`WebDAVSessionDelegate` ist bereits ein `URLSessionTaskDelegate`, beantwortet
aber eine andere Frage (Zertifikate). Die beiden zusammenzulegen hieße, zwei
Politiken in einen Typ zu ziehen, die nichts teilen außer der Protokollform.

S3 bekommt einen eigenen, kleinen Delegate, der genau eine Frage beantwortet.

### Die Entscheidung ist ein reiner Wert

Ob eine Weiterleitung gefolgt, neu signiert oder abgelehnt wird, hängt nur
an zwei URLs. Das gehört als prüfbarer Wert nach Core — nach dem Vorbild von
`SessionNameCollision` und `SidebarOrdering` —, nicht in eine
Delegate-Methode, in der es nur über eine echte Session erreichbar wäre.

Der Delegate ruft den Wert und führt aus, was er sagt.

### Neu signieren heißt: dieselbe Anfrage, neues Ziel

Die neue Anfrage wird **gebaut wie die erste**, mit dem Ziel der
Weiterleitung: Methode, Körper und Kopfzeilen aus dem bestehenden
Signierweg, nicht aus der von Foundation vorgeschlagenen Anfrage. Der
falsche `Host` fällt damit von selbst weg — er wird für das neue Ziel neu
gesetzt und mitsigniert.

**Gemessen und deshalb hier festgehalten:** der S3-Pfad kennt **keinen**
Strom-Körper — jeder Anfragekörper liegt im Speicher oder fehlt. Eine
Anfrage lässt sich deshalb originalgetreu wiederholen. Käme später ein
Strom-Upload dazu, ist diese Annahme die erste, die nachzusehen wäre: ein
Strom lässt sich nicht zweimal lesen.

### Ablehnen ist ein Fehler mit Inhalt

Eine abgelehnte Weiterleitung endet in einem Fehler, der sagt **wohin**
geschickt werden sollte. „Verbindung fehlgeschlagen" wäre hier die falsche
Ersparnis: der Nutzer kann daraus nicht schließen, dass sein Endpunkt ihn
umzuleiten versucht, und genau das ist die Information, die zählt.

Der Text geht durch alle vier Kataloge; das Deutsche duzt.

### Was mit der Statuscode-Vielfalt geschieht

Alle Weiterleitungscodes durchlaufen dieselbe Entscheidung. 301/302/303
schreiben die Methode auf GET um, 307/308 erhalten sie — das ist Foundations
Verhalten und bleibt es. Für das Neusignieren zählt die Methode der Anfrage,
die tatsächlich gestellt wird.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: die Origin-Regel, dass gleiche Origin
signiert ankommt, dass eine fremde abgelehnt wird und das Ziel in der
Meldung steht, und dass der `Host` nach dem Neusignieren zum neuen Ziel
passt. Der Loopback-Aufbau dafür steht bereits
(`S3RedirectAuthorizationMeasurementTests`, `LoopbackHTTPStub`).

**Nicht prüfbar** bleibt, was ein echter S3-Anbieter tut. Gemessen wird
Foundation gegen einen kontrollierten Stub — das genügt für diese Fragen und
für nichts darüber hinaus.

## Was ausdrücklich nicht dazugehört

- **Keine Änderung an `WebDAVSessionDelegate`** und keine gemeinsame
  Weiterleitungs-Politik über beide Backends.
- **Keine Einstellung**, mit der sich das Ablehnen abschalten lässt. Wer
  einem umgeleiteten Endpunkt trauen will, trägt ihn als Endpunkt ein.
- **Keine Änderung am Signierweg selbst**, nur ein zweiter Aufruf davon.
- Keine Behandlung von `x-amz-bucket-region`-Regionswechseln als eigener
  Fall — ein Anbieter, der so umleitet, tut es innerhalb seiner eigenen
  Origin oder wird abgelehnt wie jeder andere.
