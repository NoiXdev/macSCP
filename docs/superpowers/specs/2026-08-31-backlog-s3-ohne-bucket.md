# Backlog: S3 ohne Bucket verbinden

**Angelegt:** 2026-08-31, aus einem Fehlerbericht von außen (v1.3.0), mit
einem Vorschlag des Maintainers.

## Der Bericht

> „I tried to connect without providing bucket and region and it doesn't
> allows me. When I fill using slash then the connection has been failed."

Anbieter war Servinga (S3-kompatibel).

## Der gemessene Ausgangszustand

- `S3ConnectionConfig` trägt `region` und `bucket` als nicht-optionale
  `String`, und das Feldschema führt beide als Pflicht.
- **`ListBuckets` gibt es im Baum nicht** — nachgesehen, kein Vorkommen. S3
  listet heute ausschließlich *innerhalb* eines Buckets.
- Ein Bucket namens `/` ist kein Bucket; dass das Verbinden damit scheitert,
  ist richtig und nicht der Fehler.

## Der Vorschlag des Maintainers

> Sind beide leer, soll macSCP die Buckets laden und sie als Startpunkt im
> Dateibrowser zeigen — oder ein Schalter „Buckets als Startpunkt holen", der
> die beiden Felder dann entfernt.

Das ist die richtige Richtung: der Bucket ist für den Nutzer kein
Verbindungsparameter, sondern das erste Verzeichnis.

## Was vor einem Entwurf zu klären ist

1. **Die Region kann nicht einfach leer bleiben.** SigV4 **signiert mit ihr** —
   sie geht in den Credential-Scope ein. „Leer" heißt also nicht „weglassen",
   sondern „einen Vorgabewert wählen" (`us-east-1` ist der übliche, den viele
   S3-kompatible Anbieter akzeptieren, weil sie die Region nicht prüfen). Das
   ist eine Annahme über fremde Server und gehört benannt, nicht versteckt.
2. **Nicht jeder Anbieter kann `ListBuckets`.** Es ist ein Konto-weiter
   Aufruf und verlangt eine eigene Berechtigung (`s3:ListAllMyBuckets`). Ein
   Zugangsschlüssel, der auf einen Bucket beschränkt ist — der übliche Fall
   bei geteilten Zugängen — darf das nicht. **Dann muss das Feld zurück**, und
   zwar mit einer Meldung, die sagt warum, statt einer leeren Liste.
3. **Zwei leere Felder als Schalter oder ein echter Schalter?** Der Vorschlag
   nennt beides. Ein Zustand, der aus *zwei* leeren Feldern erschlossen wird,
   ist schwerer zu erklären als ein Ankreuzfeld, das die Felder ausblendet —
   und dieses Projekt hat diese Woche mehrfach die sichtbare Form der
   erschlossenen vorgezogen.
4. **Was zeigt der Browser auf der Bucket-Ebene?** Buckets sind keine Ordner:
   sie haben kein Änderungsdatum im Listing, keine Größe, keine Rechte. Die
   Tabelle müsste damit umgehen, und `RemoteFileItem` trägt heute Felder, die
   dort alle leer wären.
5. **Was tun Übertragungen und Prüfsummen auf dieser Ebene?** Ein Bucket
   lässt sich nicht herunterladen. „Nur zeigen, was möglich ist" heißt hier,
   dass die halbe Werkzeugleiste auf dieser Ebene nichts zu tun hat.

## Warum das kein kleiner Vorgang ist

Die Punkte 4 und 5 machen daraus mehr als ein Feld weniger: es ist eine
**zweite Art von Verzeichnis** im Dateibrowser, mit anderen Spalten und
anderen möglichen Aktionen. Das ist machbar und sinnvoll — aber es ist zu
entwerfen, nicht nebenbei zu bauen.

**Der billige Teil davon, falls jemand nur den Bericht schließen will:** eine
Vorgabe für die Region und eine Fehlermeldung, die sagt, dass der Bucket
gebraucht wird und warum. Das behebt „es lässt mich nicht", ohne die zweite
Verzeichnisart.

## Was das nicht ist

- **Keine Änderung an der Signatur.** Die Region bleibt Teil des Scopes.
- **Kein Erraten der Region** aus dem Endpunkt.
