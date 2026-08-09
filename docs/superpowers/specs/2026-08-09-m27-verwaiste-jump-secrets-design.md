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

### Die Anspruchsmenge kommt aus den Rohdateien

Abgezogen wird die Vereinigung aller IDs, die heute irgendetwas beansprucht:
Sitzungs-IDs, Jump-`secretID`s, Login-Set-IDs, Managed-Key-IDs — jeweils aus
der **Datei**, nicht aus dem nachsichtigen Zugriff. `all()` und `reload()` sind
für diesen Zweck unbrauchbar, siehe Tabelle oben.

Der Abzug ist großzügiger als nötig (eine Legacy-Jump-`secretID` kann keine
heutige Managed-Key-ID sein), und das ist Absicht: er kostet nichts und macht
die Regel „gelöscht wird nur, was **nirgends** vorkommt" ohne Fallunterscheidung
wahr.

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

### Audit

Der Lauf wird auditiert — mit **Anzahl** entfernter Einträge und Anzahl
Fehler, **niemals mit IDs und niemals mit Werten**.

Das weicht bewusst vom Umfeld ab: das Löschen einer Sitzung, eines Login-Sets
und eines Managed Key ist heute nicht auditiert, das rekursive Remote-Löschen
schon. Begründung: hier werden Zugangsdaten entfernt, die der Nutzer nie zu
Gesicht bekommen hat und deren Verschwinden er auf keinem anderen Weg
bemerken kann.

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
| 3 | Ein blockloser `.ssh`-Datensatz schützt seine IDs trotzdem | Rohdatei enthält ihn, `all()` nicht; Sweep lässt seine IDs in Ruhe |
| 4 | Ein Login-Set mit unbekanntem `authKind` schützt seine ID | Fixture mit `"authKind": "future-x"`; Sweep lässt sie in Ruhe |
| 5 | Jede einzelne unlesbare Datei bricht den Lauf ab, ohne zu löschen | ein Test je Datei; `InMemorySecretStore` unverändert |
| 6 | Fehlende Legacy-Datei ist kein Fehler | Lauf meldet null entfernt, kein Wurf |
| 7 | Der Sweep liest nie ein Secret | Test-Double, dessen `password(for:)` den Test scheitern lässt |
| 8 | Ein Teilfehler stoppt den Lauf nicht | Double, das für eine ID wirft; die übrigen werden entfernt, der Bericht nennt den Fehler |
| 9 | Die Legacy-Datei ist nach dem Lauf byte-gleich | Bytes vorher/nachher |
| 10 | Der Audit-Eintrag enthält keine ID und keinen Wert | Test über den aufgezeichneten Eintrag |
| 11 | Alle vier Kataloge tragen die neuen Schlüssel | der vorhandene Wächtertest |

## Test-Hinweise

- Die Kernlogik gehört in Core und wird **ohne echten Schlüsselbund** getestet:
  temporäre Dateien plus `InMemorySecretStore`. Dessen `storedIDs` — im
  Aufräum-Durchgang eingeführt — ist genau das Werkzeug für Kriterium 1–4:
  es zeigt, dass **nirgends** etwas übrig blieb, nicht nur unter der einen ID,
  nach der man gefragt hat.
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
- Waisen aus fehlgeschlagenen Managed-Key-Rollbacks — nur über eine
  Schlüsselbund-Aufzählung erreichbar, die dieser Entwurf ablehnt.
- Der 0-%-CPU-Testsuite-Hänger.
- Der Release-Stau.
