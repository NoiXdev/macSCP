# Backlog: Prüfsummen für Dateien

**Status:** offen
**Aufgenommen:** 2026-08-27, Maintainer

## Was gewünscht ist

Drei Punkte, die zusammengehören, aber sehr unterschiedlich schwer sind:

1. **In der Datei-Info** die Prüfsummen einer Datei anzeigen.
2. **Bei mehreren ausgewählten Dateien** ein Kontextmenü-Eintrag „Prüfsummen",
   der sie für die Auswahl zeigt.
3. **Eine neue Tabellenspalte** mit der Prüfsumme, samt Einstellung, **welche**
   (SHA-256, SHA-1, MD5, …).

## Der gemessene Ausgangszustand

| | |
|---|---|
| `RemoteFileItem` | trägt `name`, `path`, `kind`, `size`, `modifiedAt`, `permissions`, `owner`, `group` — **keinen** Hash und kein ETag |
| Befehlsausführung in Core | **gibt es nicht**. SSH hat eine Shell (`CitadelShell`), aber die bedient das Terminal, nicht einen Aufruf mit Rückgabewert |
| S3-ETag | wird intern für Mehrteil-Uploads benutzt (`S3MultipartXML`), aber **nicht** in die Auflistung durchgereicht |
| Vorhandene Prüfsummen-Nutzung | nur ausgehend: `Insecure.MD5` für den `Content-MD5`-Header, `SigV4Signer.hexSHA256` fürs Signieren |

## Die Falle, an der alles hängt

**Kein Protokoll dieser App liefert einen Datei-Hash im Vorbeigehen.** Was das
je Backend bedeutet, ist der eigentliche Inhalt dieses Eintrags:

| Backend | Woher käme ein Hash |
|---|---|
| **SFTP** | Gar nicht aus dem Protokoll. Entweder `sha256sum` über die Shell — setzt das Programm auf der Gegenseite voraus und ist kein SFTP mehr — oder **die ganze Datei herunterladen und lokal hashen**. |
| **S3** | Der ETag kommt in `ListObjectsV2` frei mit. **Aber er ist nur bei einteiligen Uploads das MD5 der Datei**; bei Mehrteil-Uploads ist er `md5-der-md5s-N` und damit *kein* Dateihash. Ihn als „MD5" zu zeigen wäre eine Lüge, die genau bei großen Dateien zuschlägt. |
| **WebDAV** | Kein Standardfeld. Manche Server (Nextcloud) liefern `OC-Checksum`, das ist aber eine Erweiterung und nichts, worauf sich ein Client verlassen kann. |
| **Lokal** | Unproblematisch — die Datei liegt da. |

**Punkt 3 ist deshalb der gefährlichste, nicht der kleinste.** Eine Spalte
verspricht einen Wert *pro Zeile*. Bei SFTP und WebDAV hieße das: beim Öffnen
eines Verzeichnisses jede Datei darin herunterladen. Ein Ordner mit 200 Dateien
zu je 50 MB wären 10 GB Verkehr für eine Spalte, die jemand versehentlich
eingeschaltet hat.

## Entscheidung des Maintainers (2026-08-27)

**Nur auf Anforderung. Und nicht durch Herunterladen** — die Datei zu holen,
um sie zu hashen, ist den Preis nicht wert.

Das beantwortet die Fragen 2 und 3 unten und schneidet zugleich die Reichweite
der Funktion zu. Die Gegenseite muss rechnen, und damit gilt:

| Backend | Was daraus folgt |
|---|---|
| **SFTP** | Nur über einen Befehl auf der Gegenseite (`sha256sum` und Verwandte). Setzt das Programm dort voraus und braucht in Core einen Weg, einen Befehl mit Rückgabewert auszuführen — **den es heute nicht gibt**. Das ist der eigentliche Bauanteil. |
| **S3** | Der ETag, mit der Mehrteil-Einschränkung oben. Kein Rechnen nötig, aber auch keine freie Wahl des Verfahrens: es ist, was es ist. |
| **WebDAV** | **Gar nicht**, außer der Server liefert `OC-Checksum` oder Ähnliches. Für einen Standard-WebDAV-Server gibt es die Funktion damit nicht. |
| **Lokal** | Unproblematisch, lokal gerechnet ist kein Herunterladen. |

**Die Konsequenz, die dabei benannt gehört:** die Funktion ist nicht überall
verfügbar. Ein Menüeintrag, der bei WebDAV fehlt oder ins Leere greift, muss
das *sagen* — „dieser Server liefert keine Prüfsummen" ist eine brauchbare
Antwort, ein ausgegrauter Eintrag ohne Begründung nicht.

Falls „nicht herunterladen" enger gemeint war, als es hier gelesen wird —
etwa „nicht von allein, auf ausdrückliche Anforderung aber schon" —, kehrt
SFTP ohne Fremdprogramm zurück und WebDAV wird überhaupt erst möglich. Diese
Lesart ist bewusst **nicht** gewählt; sie steht hier, damit die Wahl beim
Angehen sichtbar ist statt vergessen.

## Was vor dem Angehen zu entscheiden ist

1. **Wird gerechnet oder abgefragt?** Ein Hash, der bei S3 aus dem ETag kommt
   und bei SFTP aus einem Download, ist nicht dieselbe Zusage. Entweder das
   auseinanderhalten und **benennen** (woher der Wert stammt, und ob er den
   Dateiinhalt beschreibt), oder überall selbst rechnen und dafür überall
   denselben Preis zahlen.
2. **Wann wird gerechnet?** Nie von allein wäre die sichere Antwort: Prüfsumme
   auf Anforderung, pro Datei oder pro Auswahl, mit sichtbarem Fortschritt und
   Abbruch — so wie eine Übertragung, denn genau das ist es.
3. **Was zeigt die Spalte, solange nichts gerechnet wurde?** Leer, ein Knopf,
   oder eine Angabe, die aus der Auflistung kam? Ohne Antwort darauf wird die
   Spalte entweder nutzlos oder gefährlich.
4. **Welche Verfahren?** SHA-256 als Voreinstellung. MD5 und SHA-1 sind für
   Integritätsprüfung gegen eine fremde Angabe noch verbreitet, aber
   kryptografisch gebrochen — wenn sie angeboten werden, gehört das an der
   Einstellung gesagt, nicht als gleichwertige Wahl daneben gestellt.
5. **Kommt die Fähigkeit in `ProtocolCapabilities`?** Es gibt bereits
   `supportsPresignedURL` als Beispiel für „dieses Backend kann etwas, das
   andere nicht können". Eine Angabe wie „liefert Prüfsummen ohne Lesen" wäre
   dieselbe Form — und würde verhindern, dass die Oberfläche über
   `ConnectionKind` verzweigt.

## Zuschnitt-Vorschlag

Nicht als einen Vorgang bauen. Punkt 1 und 2 sind dieselbe Sache in zwei
Größen (eine Datei, mehrere Dateien) und **auf Anforderung** — das ist ein
überschaubarer, ehrlicher Vorgang. Punkt 3 ist ein eigener, und er sollte erst
angegangen werden, wenn Frage 3 oben beantwortet ist.
