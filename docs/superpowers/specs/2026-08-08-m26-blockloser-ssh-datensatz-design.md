# M26 — Der blocklose SSH-Datensatz (Design)

**Stand:** 2026-08-08. Vorgänger: M25 (`2026-08-08-m25-abschluss.md`), dessen
Abschluss die Frage stellte, die dieser Meilenstein beantwortet.

## Ziel

`StoredSession.host`/`port`/`username`/`authKind` liefern für eine Sitzung ohne
SSH-Block die Rückfallwerte `""`/`22`/`""`/`.password`. M25 hat gezeigt, dass
**kein Leser mehr ungeschützt** ist — aber auch, dass Löschen erst bei **null
Nennungen** möglich ist, und es gibt fünfzehn in Produktionscode. Die Blockade
war nie technisch, sondern eine offene Frage:

> Was soll eine `.ssh`-Sitzung tun, deren Block in der Datei fehlt?

**Maintainer-Entscheidung 2026-08-08: beim Laden verwerfen.**

Danach gilt `.ssh` ⇒ `ssh != nil` in der Praxis, die fünfzehn Leser können auf
`guard let ssh` umstellen, und die vier Accessoren fallen.

## Wie der Zustand überhaupt entsteht

`StoredSession.init(from:)` liest den Block mit `decodeIfPresent`
(`StoredSession.swift:130`). Das ist Absicht und bleibt es: M23 hat festgelegt,
dass **ein kaputter Eintrag nicht die ganze Datei scheitern lassen darf**. Die
App selbst kann den Zustand nicht erzeugen — jeder Speicherpfad schreibt den
Block. Erreichbar ist er nur durch eine von Hand editierte oder beschädigte
`sessions-v2.json`.

## Die drei Änderungen

### 1. Verwurf beim Laden

`SessionStore.load()` fegt heute bereits eine Hygiene-Regel durch: eine
`groupID`, deren Gruppe es nicht mehr gibt, wird auf `nil` gesetzt
(`SessionStore.swift:70-76`). Dort kommt die zweite Regel daneben: ein
Datensatz mit `kind == .ssh` und `ssh == nil` wird **aus der geladenen Liste
entfernt**.

**Ohne die Datei beim Lesen neu zu schreiben.** Der nächste reguläre
Speichervorgang lässt den Eintrag ohnehin weg; ein Schreibzugriff auf dem
Lesepfad wäre eine neue Fehlerquelle für ein Problem, das niemand hat, und
würde die Datei ohne Zutun des Nutzers verändern. Bis dahin wird der Eintrag
bei jedem Start still übergangen — harmlos, und ehrlicher als eine Reparatur,
die den fehlenden Host raten müsste.

**Der Preis, ausgesprochen:** die Sitzung verschwindet aus der Seitenleiste,
ohne dass jemand sagt warum. Sie war allerdings vorher schon unbenutzbar — kein
Host, kein Benutzername, kein Verbinden. Ein sichtbarer Hinweis (Audit-Log)
wurde erwogen und verworfen: der Store kennt heute keinen Recorder, und ihm
einen zu geben ist ein größerer Eingriff als der Meilenstein wert ist.

**Nur `.ssh`, nicht alle drei Protokolle — und das ist eine bewusste
Asymmetrie.** Ein blockloser `.s3`- oder `.webdav`-Datensatz ist genauso
unbenutzbar, wird aber **nicht** verworfen. Zwei Gründe: erstens hat dieser
Meilenstein ein eng umrissenes Ziel, nämlich die vier SSH-Accessoren, und die
anderen beiden Protokolle haben gar keine — sie liefern für einen fehlenden
Block bereits den leeren Beutel, erfinden also nichts. Zweitens ist der
blocklose Nicht-SSH-Fall an mehreren Stellen bereits explizit abgefangen
(`hasStoredConfiguration`, `LoginMergePlanner`, `applyMerge`s Wache aus dem
M25-Nachgang), und ein Verwurf beim Laden würde diese Wachen unerreichbar
machen, ohne sie zu entfernen — Wachen, die dann nur noch behaupten, wovon
niemand mehr weiß, ob es stimmt.

Wer die Regel später auf alle Protokolle ausdehnt, muss diese Wachen mit
anfassen. Das ist ein eigener Durchgang, kein Nebensatz hier.

### 2. Die fünfzehn Leser bekommen `guard let ssh`

| Ort | Leser | Verhalten bei fehlendem Block |
|---|---|---|
| `LoginResolver.resolveJump` | 6 | wirft `.missingJumpSession` |
| `SessionListViewModel.delete` | 5 | überspringt die Restaurierung |
| `SSHFieldSchema.values(from:)` | 4 | liefert den **leeren** Beutel |

Zu `.missingJumpSession`: das ist nicht der nächstbeste Fehler, sondern der
wörtlich richtige. Ein verworfener Datensatz ist aus Sicht des Verweises nicht
mehr da — und die Suche `sessions.first(where:)` scheitert ohnehin schon vor
dem Guard, weil die Liste ihn nicht mehr enthält. Der Guard ist Gürtel und
Hosenträger, und er sagt dasselbe wie der Pfad davor.

Zu `delete`: dieselbe Regel, die M24 für Nicht-SSH-Bastionen eingeführt hat —
nichts restaurieren, die Referenz hängen lassen, beim nächsten Verbinden
ehrlich scheitern.

Zu `values(from:)`: der leere Beutel ist der Punkt, an dem SSH sich endlich
**genauso verhält wie S3 und WebDAV** (`BackendDescriptor.sessionValues`
liefert für die beiden schon heute `FieldValues()`, wenn der Block fehlt). Die
dokumentierte Asymmetrie verschwindet.

### 3. Die vier Accessoren fallen

`host`, `port`, `username`, `authKind` werden gelöscht.

**`keyPath` und `jump` bleiben.** Sie liefern Optionals, erfinden nichts, und
ihre achtzehn Leser sind legitim (so schon im M23-Abschluss festgehalten).

## Zwei Tests aus M25 kehren sich um

`anSSHSessionWithoutItsBlockStillShowsAPasswordField` und sein Zwilling nageln
heute fest, dass ein blockloser `.ssh`-Datensatz einen **gefüllten** Beutel
liefert — mit `authKind == "password"` aus dem Rückfall. Nach M26 liefert er
einen leeren.

**Das ist kein Bruch der Zusage, sondern ihr Zweck.** Die Tests waren die
Klammer für die Übergangszeit, in der die Accessoren noch standen. Sie werden
**umgeschrieben, nicht gelöscht**, mit einem Doc-Kommentar, der M26 als die
Stelle nennt, an der sich die Antwort geändert hat — dasselbe Verfahren wie
bei den Charakterisierungstests in M24.

Der `.s3`/`.webdav`-Zwilling aus der M25-Fix-Welle (`visibleSecretField` ist
für einen blocklosen Datensatz **nicht** nil) bleibt unverändert gültig: er
pinnt eine Eigenschaft des Schemas, nicht der Accessoren.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Ein `.ssh`-Datensatz ohne Block erscheint nicht in `sessions` | Test, der eine solche Datei schreibt und über den echten `SessionStore` lädt |
| 2 | Die Datei wird beim Laden **nicht** verändert | derselbe Test: Datei-Inhalt vor und nach dem Laden byte-gleich |
| 3 | Andere Datensätze derselben Datei überleben | derselbe Test: ein gesunder Nachbar ist da |
| 4 | Die vier Accessoren existieren nicht mehr | `grep`, und der Compiler |
| 5 | `keyPath` und `jump` existieren unverändert weiter | grep |
| 6 | `values(from:)` liefert für einen blocklosen `.ssh`-Datensatz den leeren Beutel | der umgeschriebene M25-Test |
| 7 | Kein Verhalten ändert sich für gesunde Daten | die volle Suite bleibt grün; jede nötige Anpassung außer den beiden umgeschriebenen Tests ist ein **Befund** |
| 8 | Testzahl ≥ 1604 | volle Suite, gegatete Suiten, Kataloge `plutil`-clean |

## Test-Hinweise

- Kriterium 1–3 brauchen einen **echten `SessionStore`** über eine Datei im
  temporären Verzeichnis, nicht einen Mock: geprüft wird der Lesepfad selbst.
  Muster dafür steht in den vorhandenen `SessionStore`-Tests und in den
  eingefrorenen Legacy-Fixtures aus M22/M23.
- Die Fixture-Datei wird **von Hand geschrieben** (ein `.ssh`-Datensatz ohne
  `ssh`-Schlüssel plus ein gesunder Nachbar), weil kein Schreibpfad der App sie
  erzeugen kann. Das ist derselbe begründete Sonderfall wie bei den
  blocklosen Sitzungen in `BackendDescriptorTests`.
- Sitzungen sonst über die Fixtures aus `SessionFixtures.swift`.

## Für die Release-Notes

**Ein Satz.** Eine Verbindung, deren gespeicherte Daten unvollständig sind —
nur durch Handeditieren der Datei oder Dateischaden erreichbar — wird beim
Start übergangen statt als nicht verbindbare Zeile angezeigt.

## Offen, bewusst nicht Teil von M26

- Den Zustand **unrepräsentierbar** machen (ein Payload je `kind` statt drei
  optionaler Blöcke). Das wäre die eigentliche Wurzel, ist aber ein
  Modell- und Persistenzumbau mit Formatfrage — eigener Meilenstein, falls je.
- Ein sichtbarer Hinweis auf den Verwurf (Audit-Log).
- Der 0-%-CPU-Testsuite-Hänger (eigene Akte).
- Der Release-Stau: 313+ Commits vor `main`.
