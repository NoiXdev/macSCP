# Backlog: S3 fährt auf der geteilten URL-Session

**Angelegt:** 2026-08-29, als Produktionsbefund aus der Diagnose eines
flatternden Tests. **Gemessen**, nicht vermutet — aber die Folgen im
laufenden Betrieb sind **nicht** gemessen, und der Unterschied steht unten.

## Der gezählte Befund

`URLSessionHTTPTransport.init` trägt den Vorgabewert `session: URLSession =
.shared`, und `S3FileSystem.connect` nimmt diesen Vorgabewert. **S3 ist der
einzige Pfad im Baum auf der geteilten Session** — in diesem Durchgang
nachgezählt:

| Pfad | Session |
|---|---|
| S3 | `URLSession.shared` |
| WebDAV | eigene, aus `URLSessionConfiguration.ephemeral` |
| Update-Prüfung | eigene, aus `.ephemeral` |

`URLSession.shared` benutzt `URLCache.shared`: einen **persistenten
Platten-Cache**, den alle Prozesse des Rechners teilen und der in
`~/Library/Caches` liegt.

## Wie er gefunden wurde

Nicht durch Lesen. Ein Test, der die S3-Redirect-Frage beantwortet, fiel
gelegentlich; die naheliegende Erklärung (knappe Wartezeiten unter Last) war
falsch. 80 Läufe zeigten: **ohne Last fiel er häufiger**, und mit geleertem
`URLCache.shared` gar nicht mehr. Belegt über zwei Prozesse — ein zweiter
`swift test`-Prozess ohne eigenen Listener fand `cachedEntry=true
status=308` und folgte einem Location, den ein früherer Prozess hinterlassen
hatte.

Die ganze Kette steht in
`2026-08-08-testsuite-haenger-untersuchung.md`.

## Warum das mehr ist als eine Testeigenheit

**Gemessen** wurde, dass die 301- und 308-Antworten eines Endpunkts auf
Platte landen und **prozessübergreifend** wieder ausgeliefert werden.

**Daraus folgt, ungemessen im laufenden Betrieb:**

1. **S3-Antworten liegen in `~/Library/Caches`** — Bucket-Listings, und je
   nach Kopfzeilen auch Objekt-Antworten. Unverschlüsselt, außerhalb jedes
   Ablaufs, den macSCP kontrolliert. Der Rest dieses Projekts legt Geheimes
   ausschließlich in den Keychain und schreibt es nie in eine JSON-Datei; ein
   Bucket-Inhalt ist kein Geheimnis derselben Klasse, aber er ist auch nicht
   nichts.
2. **Eine einmal gelieferte dauerhafte Weiterleitung (301/308) wirkt über
   Neustarts hinweg.** Antwortet ein Endpunkt einmal mit 301 auf eine fremde
   Origin, folgt macSCP dieser Weiterleitung danach womöglich aus dem Cache —
   ohne den echten Endpunkt zu fragen. Das ist dieselbe Klasse Frage wie die,
   die `2026-08-29-backlog-s3-weiterleitungen.md` stellt, nur haltbarer.
3. **Die Session ist geteilt.** Cookies, Kreditiv-Cache und
   Verbindungs-Wiederverwendung von `URLSession.shared` gelten für alles, was
   sie benutzt.

## Was zu tun wäre

**Die Naht existiert und wird von WebDAV bereits benutzt:**
`URLSessionHTTPTransport(session:)`. S3 bekäme eine eigene Session aus
`URLSessionConfiguration.ephemeral`, wie WebDAV eine hat.

Vor dem Umsetzen zu entscheiden:

- **Reicht `ephemeral`, oder soll der Vorgabewert von
  `URLSessionHTTPTransport` ganz verschwinden?** Ein Vorgabewert, der auf
  einen prozessweiten geteilten Zustand zeigt, ist genau die Sorte, die
  dieses Projekt bei `SessionListViewModel.init` bereits entfernt hat —
  weglassen kompilierte dort, und wer weglässt, bekam den echten Ort. Hier
  ist es dasselbe Muster.
- **Was das für den Download-Pfad heißt.** `sendStreaming` geht über
  `URLSession.bytes(for:)`; ob dort dieselbe Cache-Frage gilt, ist
  **ungemessen** und gehört vor den Entwurf.
- **Ob eine eigene Session etwas kostet**, das heute stillschweigend von der
  geteilten kommt — Verbindungs-Wiederverwendung über mehrere Anfragen
  hinweg ist der Kandidat.

## Was das nicht ist

- **Kein bestätigtes Leck.** Dass Antworten gecacht werden, ist gemessen;
  dass ein Nutzer dadurch zu Schaden kommt, ist es nicht.
- **Keine Änderung an WebDAV**, das es bereits richtig macht.
- Kein Umbau von `HTTPTransport` als Naht — sie genügt und wird benutzt, wie
  sie ist.
