# Backlog: FTP und SMB/AFP als weitere Protokolle

**Angelegt:** 2026-08-25, aus Maintainer-Zuruf. Gesicherte Idee, **kein
Entwurf** — und ein Eintrag, bei dem der Preis stärker auseinandergeht als
der Wunsch vermuten lässt.

## Ausgangslage, gemessen

`ConnectionKind` hat heute **drei** Fälle: `ssh`, `s3`, `webdav`. Dazu
gehören drei `BackendDescriptor`-Instanzen mit je **13 Pflichtfeldern** —
Fähigkeiten, Verbindungs- und Zugangsschema, `makeConfig`, `connect`,
Abzeichen, Geheimnis-Umgebungsvariable, Dateiaktionen und weitere.

**Das ist der Erweiterungspunkt, und er ist gut gebaut:** ein Kommentar am
Verbindungspfad hält fest, dass genau diese Bauform „den letzten
`ConnectionKind`-switch auf dem Verbindungspfad auflöste". Ein viertes
Backend heißt also: einen Descriptor schreiben, nicht zwanzig Stellen
anfassen. `ConnectionKind` kommt zwar in 22 Dateien vor, aber überwiegend als
Wert, nicht als Verzweigung — vor dem Anfangen ist zu zählen, wie viele
davon **echte Fallunterscheidungen** sind.

## Die zwei Hälften sind sehr verschieden

### FTP

Ein eigenes Protokoll, das macSCP selbst sprechen müsste. Zu klären, bevor
etwas entworfen wird:

- **Womit?** Apples URL-Ladesystem hat seine FTP-Unterstützung aufgegeben;
  es bräuchte also eine Bibliothek oder eine eigene Implementierung über
  NIO. Das ist die Entscheidung, an der alles Weitere hängt.
- **Welche Spielart?** Nacktes FTP überträgt Zugangsdaten im Klartext. Für
  ein Programm, das gerade drei Geheimnis-Lecks geschlossen hat, ist das
  keine Nebensache: FTPS und SFTP-über-SSH (letzteres kann macSCP schon)
  sind die sicheren Verwandten. Ob nacktes FTP überhaupt angeboten werden
  soll — und wenn ja, mit welcher Warnung — gehört entschieden, nicht
  nebenbei implementiert.
- Aktiv oder passiv, Wiederaufnahme, Verzeichnislisten in ihren zahlreichen
  Server-Dialekten: FTP ist alt und uneinheitlich.

### SMB und AFP

**Grundsätzlich anders gelagert:** macOS spricht beides bereits selbst.
Realistisch geht es hier nicht darum, ein Protokoll zu implementieren,
sondern eine **Einbindung** anzusprechen — mounten und dann über das
Dateisystem arbeiten.

Damit verschiebt sich alles:

- Der `connect`-Anteil wäre ein Mount, kein Verbindungsaufbau.
- Der Geheimnis-Weg liefe womöglich über die System-Anmeldung statt über
  macSCPs eigenen `SecretStore` — was die Frage aufwirft, wer dann was
  besitzt.
- **TOFU und die Host-Schlüssel-Prüfung haben hier keine Entsprechung.**
  Die Sicherheitszusagen dieses Projekts sind auf SSH zugeschnitten; für
  eine Einbindung gelten die des Betriebssystems. Das ist kein Hindernis,
  aber es gehört benannt, bevor jemand annimmt, die gewohnten Garantien
  gälten weiter.
- AFP ist von Apple abgekündigt. Ob es sich noch lohnt, ist eine eigene
  Frage.

## Empfehlung zur Reihenfolge

Die beiden Hälften **nicht zusammen angehen**. Sie teilen nur das Wort
„Protokoll" — technisch, sicherheitlich und im Aufwand haben sie fast nichts
gemeinsam. Wer sie in einen Plan packt, entwirft für den Durchschnitt zweier
sehr verschiedener Dinge.

Wenn eines zuerst: **SMB**, weil die Einbindung existiert und der Descriptor
das meiste bereits vorgibt. FTP braucht zuerst die Entscheidung über
Bibliothek und Spielart, und die ist keine Umsetzungsfrage.
