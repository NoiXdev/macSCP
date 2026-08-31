# Prüfsummen für Dateien — Entwurf

**Stand:** 2026-08-31. Umsetzung der Punkte **1 und 2** aus
`docs/superpowers/specs/2026-08-27-backlog-datei-hashes.md`. Punkt 3 (die
Tabellenspalte) bleibt ausdrücklich draußen — der Eintrag schneidet das
selbst so zu, und Frage 3 dort ist unbeantwortet.

---

## Entscheidungen des Maintainers

- **2026-08-27:** nur auf Anforderung, **nicht durch Herunterladen**.
- **2026-08-31:** der Vorgang baut den **SFTP-Befehlsweg** mit.
- **2026-08-31:** **SHA-256, MD5 und SHA-1**, mit Hinweis an der Einstellung.

## Der gemessene Ausgangszustand

| | |
|---|---|
| Befehl mit Rückgabewert in Core | **gibt es nicht** — `CitadelShell` bedient das Terminal |
| `ProtocolCapabilities` | acht Felder, u. a. `supportsPresignedURL` als Vorbild für „dieses Backend kann etwas" |
| `RemoteFileItem` | trägt keinen Hash und kein ETag |
| Quoting | `PosixQuoting` liegt in Core und ist geprüft |

## Die Fähigkeit ist eng, nicht allgemein

**Core bekommt keinen `exec(String)`.** Es bekommt „berechne die Prüfsumme
dieser Datei mit diesem Verfahren".

Das ist die Entscheidung, an der dieser Entwurf hängt. Ein allgemeiner
Ausführungsweg wäre eine neue Fläche, die jeder künftige Wächter beobachten
müsste, und die Erfahrung dieses Projekts mit Quelltext-Wächtern ist
eindeutig. Eine enge Fähigkeit hat **einen** interpolierten Teil — den Pfad —
und der geht durch `PosixQuoting`, das es schon gibt.

Der Aufrufer kann damit keinen Befehl formulieren. Nicht weil ein Test es
verbietet, sondern weil es keinen Parameter dafür gibt.

## Die Gegenseite ist nicht überall dieselbe

`sha256sum` ist GNU; unter macOS und BSD heißt es `shasum -a 256`. Dasselbe
gilt für die anderen beiden Verfahren.

**Einmal je Verbindung wird gefragt**, welche Form vorhanden ist, und die
Antwort gilt für diese Verbindung. Kein zusammengesetzter Befehl mit `&&`
und `||`, der beide Fälle in einer Zeile abdeckt — das wäre genau die
Konstruktion, die dieses Projekt an anderer Stelle acht Prüfrunden lang
abgelehnt hat, und sie brächte nichts außer einem gesparten Umlauf.

**Findet sich keine Form, gibt es die Funktion auf dieser Verbindung nicht**,
und das wird gesagt.

## Die Ausgabe wird nicht geglaubt, sondern gelesen

Ein `sha256sum` antwortet mit `<hex>  <pfad>`. Gelesen wird **nur das erste
Feld**, und nur, wenn es aus Hex-Ziffern in der Länge besteht, die das
Verfahren vorschreibt.

Der zurückgegebene Pfad wird **nicht** verglichen und nicht angezeigt: er
kommt von der Gegenseite, und ein Wert von dort ist Eingabe. Die Zuordnung
„welche Datei" macht der Aufrufer, der gefragt hat.

Das ist eine reine Funktion und damit prüfbar, ohne dass eine Verbindung
existiert.

## Woher der Wert stammt, steht dabei

| Backend | Quelle | Beschreibt es den Inhalt? |
|---|---|---|
| SFTP | auf der Gegenseite gerechnet | ja |
| Lokal | lokal gerechnet | ja |
| S3 | ETag aus der Auflistung | **nur bei einteiligem Upload** |
| WebDAV | nichts | — |

**Der S3-Fall ist der, an dem eine Anzeige lügen könnte.** Ein ETag der Form
`md5-der-md5s-N` ist kein Dateihash, und genau bei großen Dateien tritt er
auf. Ein Ergebnis trägt deshalb **immer** mit, woher es kommt und ob es den
Inhalt beschreibt — nicht als Fußnote, sondern als Teil des Werts. Eine
Anzeige, die das weglassen kann, wird es irgendwann weglassen.

WebDAV liefert nichts. **Das wird gesagt, nicht ausgegraut:** „dieser Server
liefert keine Prüfsummen" ist eine Antwort, ein toter Menüeintrag nicht.

## Rechnen ist eine Übertragung

Der Eintrag sagt es: auf Anforderung, mit sichtbarem Fortschritt und
Abbruch — „denn genau das ist es".

Bei einer Auswahl wird **eine Datei nach der anderen** gerechnet, das
Ergebnis erscheint, sobald es da ist, und Abbrechen lässt das Gerechnete
stehen. Eine Prüfsumme über 40 GB dauert auf der Gegenseite Minuten; ein
Fenster ohne Ausweg wäre dasselbe Problem, das der Abbau-Vorgang dieser Woche
gerade behoben hat.

**Und der Aufruf bekommt eine Frist.** Diese Woche hat zweimal gemessen, dass
ein `await` gegen eine schweigende Gegenseite nicht zurückkommt; ein neuer
Wartepunkt ohne Decke wäre der dritte.

## Die Verfahren

**SHA-256 als Voreinstellung.** MD5 und SHA-1 werden angeboten, weil der
häufigste reale Anlass der Abgleich gegen eine fremde Angabe ist — und die
ist oft MD5.

**An der Einstellung steht, dass beide gebrochen sind**, und zwar so, dass
der Unterschied klar ist: zum Abgleich gegen eine Angabe taugen sie, als
Nachweis, dass zwei Dateien gleich sind, nicht. Sie stehen nicht
gleichwertig neben SHA-256.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: das Lesen der Ausgabe, das Quoten des
Pfads, die Wahl der Befehlsform, die Herkunft im Ergebnis, dass ein
Mehrteil-ETag nicht als Dateihash gilt, und dass ein fehlender Befehl eine
Aussage erzeugt statt eines toten Eintrags.

**Nicht prüfbar** bleibt, was ein echter Server tut — gemessen wird gegen das
Docker-Rig und lokale Dateien.

## Was ausdrücklich nicht dazugehört

- **Keine Tabellenspalte** (Punkt 3).
- **Kein allgemeiner Befehlsweg** in Core.
- **Kein Herunterladen**, um zu rechnen — auch nicht als Ausweichweg, wenn
  kein Befehl gefunden wurde.
- **Kein `OC-Checksum`** für WebDAV in diesem Vorgang; es ist eine Erweiterung
  und ein eigener Fall.
