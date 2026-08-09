# M27 — Verwaiste Jump-Secrets aus der M23-Migration (Design)

**Stand:** 2026-08-09. Vorgänger: der Aufräum-Durchgang nach M26
(`2026-08-08-m26-abschluss.md`, Nachträge). Dieser Meilenstein löst den
letzten technischen Punkt, der aus M23 offen geblieben ist.

## Ziel

`LegacyStoredSession` sagt seit M23 im Doc-Kommentar, dass die Migration einer
Nicht-SSH-Sitzung deren `jump` verwirft und den zugehörigen
Schlüsselbund-Eintrag **stehen lässt** — und verweist die Aufräumarbeit an
„einen eigenen Durchgang, der einen `SecretStore` besitzt und seine Fehler
melden kann". Diesen Durchgang gibt es nicht. M27 baut ihn.

Der Eintrag ist heute durch **keinen** Löschpfad erreichbar: jeder Aufrufer
von `deletePassword` leitet seine ID aus einem Datensatz ab, den die Liste
noch enthält, und der verwaiste Datensatz ist genau der, den es nicht mehr
gibt.

## Warum das gefährlich ist, und was daraus folgt

Alle Secrets liegen unter **einem** Keychain-Service, das Konto ist jeweils
eine nackte UUID. Sitzungs-Secrets, Jump-Secrets, Login-Set-Secrets und
Managed-Key-Passphrasen stehen ununterscheidbar nebeneinander. Ein Sweep, der
„lösche, was keine Sitzung beansprucht" umsetzt, löscht Login-Set-Secrets und
Schlüssel-Passphrasen mit.

Die Bestandsaufnahme hat **sieben** konkrete Wege gefunden, auf denen die
Menge der beanspruchten IDs zu klein herauskommt. Vier davon haben dieselbe
Wurzel — zwischen Datei und Aufzählung sitzt ein Filter oder ein `try?`:

| Falle | Mechanismus |
|---|---|
| Login-Set mit unbekanntem `authKind` | `LoginSetStore.all()` verschweigt den Datensatz (Vorwärtskompatibilität, per Test festgenagelt); für einen neueren Build ist sein Secret lebendig |
| Store nicht lesbar | `reload()` setzt bei einem Wurf auf leere Listen und liest Login-Sets mit `try? … ?? []` |
| `managed_keys.json` nicht dekodierbar | `all()` **wirft**; ein Aufrufer mit `try?` macht daraus „es gibt keine Schlüssel" |
| Blockloser `.ssh`-Datensatz | `dropsOnLoad` blendet ihn aus `all()` aus, während er noch in der Datei steht |

Die übrigen drei: ein fehlschlagender Keychain-Read beweist nichts (Hausregel
seit M19); das Secret einer auf Login-Set-Modus umgestellten Sitzung ist
abgestanden, aber beansprucht; und die eigentlichen M23-Waisen sind nur aus
einer Datei erreichbar, die heute niemand liest.

**Daraus folgt die Bauform**, und sie ist der Kern dieses Entwurfs: nicht
„alles löschen, was niemand beansprucht", sondern **nur löschen, was positiv
als Waise identifiziert ist**.

## Die Bauform

### Kandidaten kommen aus der Legacy-Datei, nicht aus dem Schlüsselbund

`sessions.json` wird von M23 **nie gelöscht** — `migrateFromLegacy()` schreibt
nur die neue Datei, und der Doc-Kommentar am Store nennt die alte ausdrücklich
die Momentaufnahme, die für einen Downgrade liegen bleibt. Die verwaisten
`secretID`s stehen also noch dort, benennbar statt erschlossen.

**Das ist die entscheidende Eigenschaft dieses Entwurfs.** Ein Eintrag, den
ein *künftiger* macSCP-Build angelegt hat, kann per Konstruktion nie Kandidat
werden, weil er nicht in einer Datei von vor M23 stehen kann. Die
Vorwärtskompatibilitätsfalle ist damit nicht umgangen, sondern ausgeschlossen.

Eine Aufzählung des Schlüsselbunds ist nicht nötig. **Das `SecretStore`-
Protokoll bleibt unverändert** — und mit ihm die zwölf Konformitäten in acht
Dateien.

### Die Anspruchsmenge, und welcher Teil davon wirklich trägt

Abgezogen wird die Vereinigung aller IDs, die heute irgendetwas beansprucht:
Sitzungs-IDs, Jump-`secretID`s, Login-Set-IDs, Managed-Key-IDs.

**Hier ist eine Einschränkung fällig, die dieser Entwurf sich beim Nachrechnen
selbst auferlegt hat.** Der erste Entwurf verlangte, all das aus den
**Rohdateien** zu lesen statt aus `all()`, und begründete das mit den vier
Filterfallen der Tabelle oben. Nachgerechnet trägt dieses Argument hier
**nicht**:

- `dropsOnLoad` verbirgt nur blocklose `.ssh`-Datensätze — und ein solcher hat
  keinen `ssh`-Block, also auch keine Jump-`secretID`, die zu schützen wäre.
- `LoginSetStore.all()` verbirgt Login-Sets mit unbekanntem `authKind` — deren
  IDs werden eigens vergeben und können keine Jump-`secretID` von vor M23 sein.

Weil Kandidaten **ausschließlich** Jump-`secretID`s aus der Legacy-Datei sind,
kann keine der beiden verborgenen Sorten je Kandidat werden. Der Rohdatei-Weg
ist damit **Gürtel und Hosenträger, nicht die tragende Wand** — und die Spec
sagt das, statt eine Sicherheit zu behaupten, die woanders herkommt.

**Tragend ist etwas anderes, und das ist ernst:** wird die Sitzungsdatei nicht
gelesen, sondern schweigend als leer behandelt, ist **keine** Jump-`secretID`
mehr beansprucht — und der Sweep löscht die Secrets sämtlicher noch
existierender Jump-Verbindungen. Genau diesen Weg macht `reload()` auf, das
bei einem Wurf auf leere Listen setzt.

Daraus die Regel: **der Sweep benutzt niemals den Zustand des ViewModels**,
sondern die Stores selbst, und lässt sie werfen. Der großzügige Abzug über
alle vier Sorten bleibt trotzdem — er kostet nichts und macht „gelöscht wird
nur, was nirgends vorkommt" ohne Fallunterscheidung wahr.

### Jeder Lesefehler bricht ab

Kein `try? … ?? []` auf irgendeinem Pfad dieses Meilensteins. Lässt sich eine
der Dateien nicht lesen, **läuft der Sweep nicht** und sagt das. „Ich konnte
nicht lesen" darf nie zu „es gibt nichts" werden — das ist der Fehler, aus dem
drei der sieben Fallen bestehen.

Das gilt auch für die Legacy-Datei selbst: ist sie da und nicht lesbar, ist
das ein Abbruch. Ist sie **nicht** da, gibt es nichts zu tun — kein Fehler.

### Es wird nichts gelesen, nur gelöscht

Der Sweep ruft `password(for:)` nie auf. Damit gibt es keine
Zugriffsdialoge, und keine Entscheidung hängt an einem fehlschlagenden Read.
Ein Löschen ohne vorhandenen Eintrag ist ein No-op — im Repo bereits durch
`deleteRemovesAndIsIdempotent` festgehalten.

### Die Legacy-Datei bleibt liegen

Sie wird gelesen und nicht angefasst. Die Downgrade-Zusage aus M23 bleibt
gültig. Der Sweep braucht dafür einen **schmalen, ausschließlich lesenden**
Zugang zu einer Datei, die heute `private` ist.

## Bedienung

Ein Knopf in **Einstellungen › Daten verwalten** — der Bereich existiert und
enthält bisher nur Verknüpfungen, keine eigene Aktion.

- **Bestätigung nach Hausmuster:** `.confirmationDialog` mit destruktivem
  Knopf, wie beim Löschen von Sitzungen, Login-Sets und Known Hosts.
- **Kein Vorschau-Zähler, sondern ein Bericht danach**, gebildet aus den
  tatsächlichen Löschergebnissen: „N Einträge entfernt", bei Fehlern zusätzlich
  deren Anzahl. Ein zweiter Lauf meldet schlicht null. Damit braucht es **keine
  Erledigt-Markierung** — und der Meilenstein muss keine Migrations-Flag-
  Maschinerie erfinden, die es im Projekt nicht gibt.
- **Der Knopf ist immer aktiv.** Ein Ausgegraut-Zustand bräuchte einen
  Dateizugriff beim Zeichnen der Einstellungen, für eine Aktion, die ohnehin
  idempotent ist.
- **Ein Teilfehler stoppt nicht.** Wie beim Entfernen mehrerer Known Hosts
  läuft die Schleife weiter und der Bericht nennt die Fehlerzahl.

### Kein Audit-Eintrag — und warum die erste Entscheidung zurückgenommen wurde

Ursprünglich sollte der Lauf auditiert werden: hier verschwinden Zugangsdaten,
die der Nutzer nie gesehen hat. Beim Schreiben des Plans stellte sich heraus,
dass das im heutigen Modell nicht einlösbar ist.

**Das Audit-Log ist strikt sitzungsgebunden.** `AuditRecorder` wird mit einer
`sessionID` erzeugt, `AuditLogStore` legt eine Datei je Sitzung an, und ein
Recorder entsteht nur, wenn ein Verbindungsfenster einen anhängt. Die
Einstellungen haben keine Sitzung. Zudem gibt es **bewusst keine globale
Audit-Ansicht** — ein erzeugter Eintrag wäre aus der App heraus nicht lesbar.

„Auditiert" hieße also: eine Datei auf der Platte, die niemand öffnen kann.
Das ist kein Protokoll, sondern die Behauptung eines Protokolls.

**Entscheidung (Maintainer, 2026-08-09): kein Audit-Eintrag.** Stattdessen der
Bericht unmittelbar nach dem Lauf — der Nutzer hat die Aktion selbst ausgelöst
und steht davor. Damit liegt M27 auf einer Linie mit dem Löschen von
Sitzungen, Login-Sets und Managed Keys, die alle nicht auditiert sind.

Ein app-weiter Audit-Bereich wurde erwogen und verworfen: er löste das Problem
richtig, hat aber eigene Designfragen (Aufbewahrung, Ansicht, Menge) und wäre
größer als dieser Meilenstein. **Gehört aufs Backlog, nicht in M27.**

## Was ausdrücklich nicht dazugehört

- **Waisen aus fehlgeschlagenen Managed-Key-Rollbacks.** Drei Rollback-Pfade
  löschen mit `try?`; schlägt das fehl, bleibt ein Eintrag unter einer ID
  zurück, die nie in `managed_keys.json` gelangt ist. Diese IDs stehen
  **nirgends** — mit dem Verfahren dieses Meilensteins sind sie nicht
  auffindbar. Sie zu finden hieße, den Schlüsselbund aufzuzählen, und genau
  das schließt dieser Entwurf aus.
- **Das abgestandene Secret einer auf Login-Set-Modus umgestellten Sitzung.**
  `save()` überspringt den Secret-Block, wenn ein Login-Set gesetzt ist, und
  `updateSession`s Aufräumen fragt das Schema, das `loginSetID` nicht kennt —
  also bleibt der alte Eintrag liegen. Die ID ist beansprucht, der Eintrag ist
  **keine Waise**, und der Sweep fasst ihn nicht an. Andere Fehlerklasse:
  keine Altlast, sondern eine Lücke im laufenden Speicherpfad. **Eigener
  Befund, eigener Fix, eigener Test** — Maintainer-Entscheidung 2026-08-09.
- **Ein Unterscheidungsmerkmal im Schlüsselbund** (Label, Präfix, eigener
  Service je Sorte). Erwogen und verworfen: Keychain-ACLs hängen am einzelnen
  Eintrag, ein umgeschriebenes Konto ist ein neuer Eintrag, und damit wären
  alle „Immer erlauben"-Zustimmungen weg, die die CLI für unbeaufsichtigte
  Läufe braucht. Ein älterer Build sähe außerdem null Secrets, ohne den
  Datei-Umweg, den M23 sich offengehalten hat.
- **Ein automatischer Lauf beim Start.** Der Code hält ausdrücklich fest, dass
  ein Lesepfad keine Keychain-Schreibwirkung haben darf; ein stiller Lauf
  bräuchte einen eigenen Aufhänger nach dem Start und nähme dem Nutzer die
  Entscheidung ab.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Eine Legacy-Jump-`secretID`, die kein heutiger Datensatz beansprucht, wird gelöscht | Test über temporäre Dateien + `InMemorySecretStore`: ID vorher da, nachher weg |
| 2 | Eine Legacy-`secretID`, die ein heutiger Datensatz weiterhin beansprucht, wird **nicht** gelöscht | derselbe Test, zweite ID, bleibt liegen |
| 3 | **Eine nicht lesbare Sitzungsdatei löscht nichts** — der schwerste Fall: schweigend leer hieße, sämtliche lebenden Jump-Secrets zu löschen | Test mit unlesbarer Datei; `InMemorySecretStore` danach **unverändert**, Lauf meldet den Fehler |
| 4 | Der Sweep liest den ViewModel-Zustand nicht | Sweep bekommt die Stores, nicht das ViewModel; als Signatur festgelegt und im Review geprüft |
| 5 | Jede einzelne unlesbare Datei bricht den Lauf ab, ohne zu löschen | ein Test je Datei; `InMemorySecretStore` unverändert |
| 6 | Fehlende Legacy-Datei ist kein Fehler | Lauf meldet null entfernt, kein Wurf |
| 7 | Der Sweep liest nie ein Secret | Test-Double, dessen `password(for:)` den Test scheitern lässt |
| 8 | Ein Teilfehler stoppt den Lauf nicht | Double, das für eine ID wirft; die übrigen werden entfernt, der Bericht nennt den Fehler |
| 9 | Die Legacy-Datei ist nach dem Lauf byte-gleich | Bytes vorher/nachher |
| 10 | Der Bericht nennt Zahlen, nie eine ID und nie einen Wert | Test über den erzeugten Text |
| 11 | Alle vier Kataloge tragen die neuen Schlüssel | der vorhandene Wächtertest |

## Test-Hinweise

- Die Kernlogik gehört in Core und wird **ohne echten Schlüsselbund** getestet:
  temporäre Dateien plus `InMemorySecretStore`. Dessen `storedIDs` — im
  Aufräum-Durchgang eingeführt — ist genau das Werkzeug für die Kriterien 1–3:
  es zeigt, dass **nirgends** etwas übrig blieb bzw. dass **nichts** angefasst
  wurde, nicht nur unter der einen ID, nach der man gefragt hat.
- **Zwei Tests, die keine sind, und trotzdem hineingehören.** Die Fixtures für
  den blocklosen `.ssh`-Datensatz und für das Login-Set mit unbekanntem
  `authKind` werden mitgeführt — aber mit einem Doc-Kommentar, der sagt, dass
  sie unter der heutigen Kandidatenregel **nicht scheitern können** und als
  Wächter für eine spätere Ausweitung dastehen. Wer die Kandidatenmenge je auf
  „alles im Schlüsselbund" erweitert, macht sie damit scharf. Ohne diesen
  Kommentar wären es zwei Tests, die Sicherheit vortäuschen.
- Für Kriterium 7 braucht es ein Double, dessen `password(for:)` den Test
  scheitern lässt. Das Muster existiert im Repo mehrfach.
- Die gegatete `MACSCP_KEYCHAIN`-Suite bleibt **unberührt**. Sie deckt den
  echten Schlüsselbund ab, dieser Meilenstein fügt dem nichts hinzu.
- Fixtures für den blocklosen Datensatz und für den unbekannten `authKind`
  existieren bereits und werden wiederverwendet statt neu erfunden.

## Für die Release-Notes

**Ein Satz.** Einstellungen › Daten verwalten kann Zugangsdaten entfernen, die
beim Aufstieg von Version 1.0 im Schlüsselbund zurückgeblieben sind und seither
von nichts mehr benutzt werden.

## Offen, bewusst nicht Teil von M27

- Das abgestandene Secret im Login-Set-Modus (siehe oben) — **auf dem Backlog**.
- **Ein app-weiter Audit-Bereich** ohne Sitzungsbezug, samt Ansicht — die
  Voraussetzung dafür, eine Aktion aus den Einstellungen überhaupt
  protokollieren zu können. **Auf dem Backlog.**
- Waisen aus fehlgeschlagenen Managed-Key-Rollbacks — nur über eine
  Schlüsselbund-Aufzählung erreichbar, die dieser Entwurf ablehnt.
- Der 0-%-CPU-Testsuite-Hänger.
- Der Release-Stau.
