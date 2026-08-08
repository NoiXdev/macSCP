# M24 — Protokollgerechte Anmeldungen (Design)

**Stand:** 2026-08-08. Vorgänger: M23 (`2026-08-07-m23-abschluss.md`), dessen
Abschlussbericht beide Bugs benannt und bewusst nicht behoben hat.

## Ziel

Zwei echte Fehler derselben Klasse beheben: eine SSH-geformte Schicht, die seit
M12 protokollfremde Sitzungen durchlässt.

1. **`LoginMergePlanner` kann das Secret einer S3- oder WebDAV-Sitzung
   löschen.** Ein Datenverlustpfad, nicht Kosmetik.
2. **`JumpSessionEligibility` filtert nicht nach Protokoll.** Ein Bucket ist als
   Bastion wählbar; der Resolver liest anschließend `host: ""`.

Beide sind heute durch Charakterisierungstests festgehalten, die erklären, was
falsch ist. Diese Tests kippen in diesem Meilenstein zu Zusagen.

**Nicht in diesem Meilenstein:** der intermittierende 0-%-CPU-Hänger der
Testsuite. Offene Ursache, eigene Untersuchung mit systematic-debugging.

## Bug 1 — der Merge-Vorschlag

### Ist-Zustand

`LoginMergePlanner.candidates` filtert ausschließlich auf `loginSetID == nil`.
Es gibt kein `kind`-Prädikat, und `SessionListViewModel.mergeCandidates()`
reicht jede Sitzung hinein. Für eine `.s3`-Sitzung liefert `session.authKind`
den Rückfallwert `.password` und `session.username` den Rückfallwert `""`; der
`.password`-Zweig liest dann den Keychain-Slot der Sitzung — der bei S3 den
**Secret Access Key** enthält.

Zwei S3-Sitzungen auf einem Zugangspaar (ein Account, zwei Buckets — der
Normalfall) erscheinen damit als Merge-Vorschlag. Wer ihn annimmt, bekommt über
`SessionListViewModel.applyMerge` ein `LoginSet`, dessen `kind` auf `.ssh`
vorbelegt ist und dessen `accessKeyID` `nil` bleibt; beide Sitzungen werden
darauf umgehängt und anschließend wird **jeder Sitzung ihr eigener
Keychain-Slot gelöscht**. WebDAV hat dieselbe Form.

Der Folgeschaden ist vollständig: das Set kann die Anmeldung nicht tragen
(falscher `kind`, kein `accessKeyID`), und `LoginResolver.resolve` lehnt die
Bindung beim Verbinden korrekt mit `kindMismatch` ab — nur ist das Secret dann
schon weg und muss neu eingetippt werden.

### Entscheidung (Maintainer, 2026-08-08)

**Merge protokollgerecht machen**, nicht auf SSH einschränken. S3-Login-Sets
existieren seit M15 und sind für genau diesen Fall gedacht; ein Filter würde
den Datenverlust beseitigen und den Nutzen gleich mit.

### Der Gruppierungsschlüssel

Heute hart SSH-geformt (`username` + `authKind` + `keyPath` + `password`).
Künftig aus dem Schema abgeleitet:

> `kind`
> + die Werte aller **sichtbaren** Felder des `credentialSchema`, die kein
>   Secret sind
> + das Secret, **falls** das sichtbare Secret-Feld die Anmeldung selbst ist
>   (siehe `SecretRole` unten)

`ConnectionFieldSchema.visibleFields(in:namespace:)` erledigt dabei die
Fallunterscheidung, die heute der `switch` macht. Das Ergebnis reproduziert das
SSH-Verhalten exakt, ohne SSH zu nennen:

**Alle Werte werden wörtlich verglichen** — auch die Nicht-Secret-Felder, auch
Groß-/Kleinschreibung, auch Leerraum. Das ist das heutige Verhalten (der
Planner liest `session.username` roh) und bewusst **nicht** das
`FieldIdentity`-Vokabular aus M23/P3: das beantwortet „ist das dieselbe
Verbindung" für die Import-Dublettenprüfung, tragen längst nicht alle
Credential-Felder (`SSHField.authKind` etwa nicht), und ein Feld ohne `identity`
fiele damit aus dem Schlüssel — genau das Feld, das SSHs drei Auth-Arten
auseinanderhält.

| Konfiguration | Sichtbare Nicht-Secret-Felder | Secret im Schlüssel |
|---|---|---|
| SSH `.password` | `username`, `authKind` | ja |
| SSH `.privateKey` | `username`, `authKind`, `keyPath` | nein |
| SSH `.agent` | `username`, `authKind` | kein Secret-Feld sichtbar |
| S3 | `accessKeyID` | ja |
| WebDAV | `username` | ja |

### `SecretRole` — warum `isRequired` nicht reicht

Der naheliegende Ableitungsweg „das Secret zählt mit, wenn sein Feld
`isRequired` ist" ergibt für SSH und S3 das Richtige und für **WebDAV das
Falsche**: dessen `password` ist seit M23 optional (anonyme Freigaben werden
unterstützt), fiele also aus dem Schlüssel. Zwei WebDAV-Sitzungen mit gleichem
Benutzernamen und **verschiedenen Passwörtern** wären wieder ein
Merge-Kandidat — derselbe Datenverlust in anderer Farbe.

Die Unterscheidung ist inhaltlich und nicht ableitbar, also wird sie
deklariert. SSHs `passphrase` **entsperrt** eine Anmeldung, die bereits im
Schlüssel steht (die Schlüsseldatei über `keyPath`): zwei Sitzungen auf
derselben Datei sind dieselbe Anmeldung, unabhängig davon, ob die Passphrase
hinterlegt ist. `password` und `secretAccessKey` **sind** die Anmeldung.

Neu in `FieldVocabulary.swift`, neben `FieldFormat` und `FieldIdentity`:

```swift
public enum SecretRole: Sendable {
    /// The secret IS the credential — two logins with different secrets are
    /// different logins.
    case credential
    /// The secret unlocks a credential named by another field (SSH's key
    /// path). Two logins to the same key file are the same login whether or
    /// not the passphrase happens to be stored.
    case passphrase
}
```

Getragen von `ConnectionField` (nur für `kind == .secret` bedeutungsvoll),
deklariert an vier Feldern: `SSHField.password` → `.credential`,
`SSHField.passphrase` → `.passphrase`, `S3Field.secretAccessKey` →
`.credential`, `WebDAVField.password` → `.credential`. Ein viertes Backend
deklariert es einmal mit.

### Teilnahmeregel

- Sichtbares Secret-Feld mit `.credential` und **kein** Secret im Keychain →
  die Sitzung nimmt nicht teil. Das ist exakt die heutige SSH-Regel („nichts
  zum Vergleichen"), jetzt auch für S3 und WebDAV. Anonyme WebDAV-Sitzungen
  werden damit nie vorgeschlagen.
- Sichtbares Secret-Feld mit `.passphrase`, oder gar kein sichtbares
  Secret-Feld (ssh-agent) → **der Keychain wird nicht angefasst.** Damit bleibt
  M10ds strukturelle Zusage erhalten, die `agentSetResolvesWithoutKeychainRead`
  mit einem lesefeindlichen Store festhält.

### `LoginMergeCandidate`

Verliert `username`, `authKind` und `keyPath`. Bekommt:

- `kind: ConnectionKind`
- `values: FieldValues` — die Credential-Werte des Kandidaten, **ohne Secret**
- `displayLabel: String` — der Wert des ersten sichtbaren Nicht-Secret-Feldes
  des Credential-Schemas. Bei SSH und WebDAV der Benutzername, bei S3 die
  Access Key ID.
- `sessionIDs: [UUID]` (unverändert)

Die Sortierung (heute `username`, dann `keyPath`, dann Gruppengröße) läuft
künftig über `displayLabel`, dann Gruppengröße. Die ignorierten Gruppen
(`ignoredMergeGroups`) sind Mengen von Sitzungs-IDs und bleiben unberührt.

### `applyMerge`

Baut das Set über den seit M22 vorhandenen
`BackendDescriptor.loginSet(id:name:from:)` — die Inverse, die jeden `kind`
kann. Der Secret-Transport (erste Gruppensitzung, die tatsächlich eines hat →
unter `set.id` speichern → erst danach die Sitzungs-Slots löschen, mit Rollback
bei Schreibfehler) bleibt unverändert; er war nie das Problem.

**Zusätzlich ein harter Riegel**, obwohl der umgebaute Planner ihn nie auslösen
sollte: ein Kandidat, dessen Sitzungen nicht alle den Kandidaten-`kind` tragen,
wird abgelehnt und nichts wird geschrieben. M23 hat zwölf Kommentare gefunden,
die etwas über den Code behaupteten, das niemand nachgezogen hatte — der Riegel
kostet wenige Zeilen und einen Test und macht aus der Behauptung eine Tatsache.

### App-Schicht

`LoginSetsSheet` liest `candidate.username` an drei Stellen (Banner,
Bestätigungsdialog, Vorschlagsname über `suggestedSetName(forUsername:)`).
Alle drei lesen künftig `candidate.displayLabel`. Der Bannertext („%lld
connections use the same login “%@”.") bleibt wörtlich gültig — er nennt keine
Protokoll-Begriffe. `suggestedSetName(forUsername:)` wird zu
`suggestedSetName(forLabel:)` umbenannt, damit der Parametername nicht lügt.

## Bug 2 — der Jump-Host

### Ist-Zustand

`JumpSessionEligibility.eligible(for:in:)` filtert auf die gerade bearbeitete
Sitzung und auf Ketten, sonst nichts. Eine `.s3`- oder `.webdav`-Sitzung wird
als Bastion angeboten, obwohl nur SSH tunnelt.
`LoginResolver.resolveJump(spec:sets:secrets:sessions:referencingSessionID:)`
weist sie ebenfalls nicht ab: es prüft Kette und Selbstbezug und liest dann
`referenced.host`/`referenced.port` — bei einer S3-Sitzung die internen
Rückfallwerte `""` und `22`.

### Drei Stellen, in aufsteigender Wichtigkeit

**1. Der Picker.** `JumpSessionEligibility.eligible` filtert zusätzlich auf
`kind == .ssh`. Ein Bucket verschwindet aus der Auswahl.

**2. Der harte Riegel im Resolver — die eigentliche Reparatur.** Ein
Picker-Filter schützt nur, was künftig angelegt wird. Wer heute schon eine
Sitzung hat, deren `jump.sessionID` auf einen Bucket zeigt (seit M12 anlegbar),
läuft weiterhin hinein. Also bekommt `resolveJump(…sessions:
referencingSessionID:)` neben den Prüfungen auf Kette und Selbstbezug eine
dritte: zeigt `sessionID` auf eine Nicht-SSH-Sitzung, wird geworfen, bevor Host
und Port gelesen werden.

Ein **eigener** Fehlerfall, nicht das vorhandene `kindMismatch` — das bedeutet
„Sitzung und ihr Login-Set sprechen verschiedene Protokolle" und würde hier eine
falsche Ursache nennen:

```swift
/// A jump's `sessionID` points at a session that is not an SSH connection.
/// Only SSH tunnels; an object-storage or WebDAV session has no host to dial
/// through. Distinct from `kindMismatch`, which is about a session and its
/// login set disagreeing.
case jumpSessionNotSSH
```

Kosten: drei vorhandene `catch`-Stellen (`ContentView` zweimal,
`ConnectionFormView` einmal) bekommen einen Arm, ein neuer L10n-Schlüssel in
allen vier App-Katalogen (en/de/fr/pl, identische Schlüsselmengen).

**3. `SessionListViewModel.delete`.** Wird eine Sitzung gelöscht, die anderen
als Bastion dient, kopiert `delete` deren Anmeldung in die referenzierenden
Sitzungen — inklusive `session.host` und `session.port`. Bei einer
Nicht-SSH-Sitzung sind das die Platzhalter.

Künftig: **ist die gelöschte Sitzung nicht SSH, wird nichts restauriert.** Die
Referenz bleibt hängen und ergibt beim nächsten Verbinden `.missingJumpSession`
(„die referenzierte Verbindung wurde gelöscht") — wahr und behebbar, während
`host: ""` wie eine konfigurierte Bastion aussieht, die niemand wählen kann.
`JumpRestoreResult.restored` fällt entsprechend niedriger aus.

### Bewusst nicht: eine Migration

Bestehende kaputte Jump-Referenzen werden **nicht** umgeschrieben. Sie
scheitern nach dem Riegel mit einer Meldung, die die Ursache nennt. Ein Sweep,
der gespeicherte `JumpSpec`-Blöcke des Nutzers anfasst, ist riskanter als der
Fehler, den er heilen soll.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Zwei S3-Sitzungen mit **gleichem** Zugangspaar ergeben einen `.s3`-Kandidaten, dessen Merge ein `.s3`-Set mit gesetztem `accessKeyID` erzeugt | Test über `applyMerge`, der das entstandene Set liest |
| 2 | Zwei S3- oder WebDAV-Sitzungen mit **verschiedenen** Secrets sind **kein** Kandidat | Test je Backend |
| 3 | Kein Merge löscht je ein Secret, das das Ziel-Set nicht trägt | Test: nach `applyMerge` liegt unter `set.id` genau das Secret der Gruppe |
| 4 | Das heutige SSH-Verhalten ist unverändert | siehe unten — die schmalste zulässige Anpassung der bestehenden `LoginMergePlannerTests` |
| 5 | `.passphrase` und ssh-agent lesen den Keychain nicht an | lesefeindlicher `SecretStore` wie in `agentSetResolvesWithoutKeychainRead` |
| 6 | Eine Nicht-SSH-Sitzung ist weder wählbar noch auflösbar als Bastion | Picker-Test **und** Resolver-Test; der Resolver-Test baut den `JumpSpec` direkt, ohne den Picker |
| 7 | `delete` schreibt nie einen Platzhalter-Host in einen fremden `JumpSpec` | Test mit S3-Bastion und referenzierender SSH-Sitzung |
| 8 | Beide Charakterisierungstests sind zu Zusagen umgeschrieben, nicht gelöscht | `nonSSHSessionsAreStillOfferedAsJumpHosts`, `nonSSHSessionsSharingASecretAreStillOfferedAsAMergeCandidate` |

### Kriterium 4 im Detail

Die bestehenden `LoginMergePlannerTests` lesen `candidate.username`,
`candidate.authKind` und `candidate.keyPath` — alle drei fallen mit der neuen
Kandidatenform weg. „Ohne Anpassung grün" ist deshalb nicht erreichbar; die
Klammer ist stattdessen, **welche** Anpassung zulässig ist.

Zulässig ist ausschließlich das Umlesen einer Behauptung auf ihren neuen
Sitzplatz — der behauptete Wert bleibt derselbe:

| vorher | nachher |
|---|---|
| `candidate.username == "deploy"` | `candidate.displayLabel == "deploy"` |
| `candidate.authKind == .privateKey` | `candidate.values[SSHField.authKind] == "privateKey"` |
| `candidate.keyPath == "/k1"` | `candidate.values[SSHField.keyPath] == "/k1"` |

**Unzulässig — und ein Befund für den Task-Bericht — ist jede Änderung an den
Eingaben eines Tests, an seinem `sessionIDs`-Ergebnis oder an der Zahl der
Kandidaten.** Wenn eine dieser Zeilen angefasst werden muss, hat der Umbau
SSH-Verhalten verschoben, und das gehört gemeldet statt weggeschrieben.

## Test-Hinweise

- Sitzungen werden über die M23-Fixtures gebaut (`sshSession`, `s3Session`,
  `webdavSession` in `Tests/macSCPCoreTests/SessionFixtures.swift`) — die eine
  Stelle, an der Tests einen `StoredSession` zusammensetzen.
- Secrets kommen aus `InMemorySecretStore`; echte Keychain-Zugriffe bleiben
  hinter `MACSCP_KEYCHAIN=1`.
- Kriterium 4 ist die Regressionsklammer: die bestehenden SSH-Tests dürfen
  **nicht** an die neue Kandidatenform angepasst werden müssen, außer dort, wo
  sie `candidate.username` lesen. Wo eine Anpassung nötig wird, gehört sie in
  den Task-Bericht.
- L10n-Parität wird vom vorhandenen `LocalizableStringsTests` erzwungen; der
  neue Schlüssel muss in allen vier App-Katalogen stehen.

## Für die Release-Notes

1. **Merge-Vorschläge gibt es jetzt auch für S3 und WebDAV** — und sie erzeugen
   ein Set des richtigen Protokolls. Vorher war der Vorschlag für diese
   Protokolle fehlerhaft und hat beim Annehmen die hinterlegten Zugangsdaten
   gelöscht.
2. **Objektspeicher- und WebDAV-Verbindungen sind nicht mehr als Jump-Host
   wählbar.** Eine bestehende Konfiguration, die auf eine solche zeigt,
   meldet beim Verbinden nun im Klartext, dass nur SSH-Verbindungen als
   Zwischenstation dienen können, statt eine nicht wählbare Bastion zu
   erzeugen.
3. **Wird eine Nicht-SSH-Verbindung gelöscht, auf die ein Jump-Host verweist,
   wird nichts mehr in die verweisende Verbindung zurückkopiert.** Sie meldet
   beim nächsten Verbinden, dass die referenzierte Verbindung fehlt.

## Offen, bewusst nicht Teil von M24

- Der 0-%-CPU-Hänger der Testsuite (eigene Untersuchung; als Sofortmaßnahme ein
  `timeout-minutes` im CI-Job).
- Verwaiste Jump-Keychain-Slots aus der M23-Migration.
- Die acht toten S3/WebDAV-Form-Shims auf `ConnectionViewModel`.
- Ob die vier `internal`-Accessoren `host`/`port`/`username`/`authKind` auf
  `StoredSession` nach diesem Meilenstein löschbar werden, wird beim Abschluss
  **geprüft**, nicht vorab zugesagt: nach M24 ist jeder verbliebene Leser
  entweder SSH-geschützt oder `SSHFieldSchema.values(from:)`, aber das ist ein
  Nebenergebnis und kein Ziel.
