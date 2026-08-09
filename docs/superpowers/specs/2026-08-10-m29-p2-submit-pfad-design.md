# M29-P2 — Der Submit-Pfad nach Core (Design)

**Stand:** 2026-08-10. Vorgänger: `2026-08-09-m29-p1-abschluss.md`.

## Warum es diese Phase gibt

M28s Whole-Branch-Review fand einen **Critical**: ein WebDAV- oder S3-Passwort
konnte einen SSH-Bastion-Host erreichen. Der Wächter, der ihn schloss, sitzt
in `ContentView.resolveSelectedJumpLoginSet` — einer `private func` auf einer
SwiftUI-View. **Kein Test hält ihn.** In M29-P1 wurde er probeweise ganz
entfernt; die volle Suite blieb grün.

P1 hat das Fundament gebaut (Library-Split, zweites Testtarget, Lokalisierung
unter `swift test`). **P2 holt die Entscheidung aus der View heraus**, dorthin,
wo die bestehende Suite sie erreicht.

## Was der Submit-Pfad heute tut

`ConnectionFormView` ruft an drei Knöpfen `resolveLoginSetForSubmit()`. Die
Implementierung in `ContentView` ruft drei Funktionen und verundet ihre
Ergebnisse:

```swift
let targetResolved = resolveSelectedLoginSet(in: tab)
let jumpResolved = resolveSelectedJumpLoginSet(in: tab)
let jumpSessionResolved = resolveSelectedJumpSession(in: tab)
return targetResolved && jumpResolved && jumpSessionResolved
```

**Dass alle drei laufen, ist Absicht** — jede Ablehnung soll ihre eigene
Meldung zeigen, nicht nur die erste. Gesichert ist das heute allein dadurch,
dass drei `let`-Zeilen vor dem `&&` stehen.

Jede der drei mischt drei Aufgaben: Modus-Wächter, Prüfung, und das Befüllen
des Formulars samt lokalisierter Meldung.

### Die Sicherheitseigenschaft steckt in der Zeilenreihenfolge

`resolveSelectedJumpLoginSet` prüft `JumpLoginSetEligibility.isEligible`
**bevor** `fillJumpForm` läuft — und `fillJumpForm` liest den Keychain-Slot
des Sets. Vertauscht man die beiden Zeilen, ist M28s Critical zurück: das
Secret des artfremden Sets steht im Formular, ein späterer Moduswechsel
schreibt es in den eigenen Jump-Slot der Sitzung, und der Connect trägt es
zum Bastion.

**Diese Reihenfolge ist die eigentliche Zusicherung des Meilensteins, und sie
ist bis heute von nichts festgehalten.**

### Asymmetrie zwischen Ziel und Jump

Der **Ziel**-Füllpfad ist bereits ein Einzeiler nach Core
(`form.applyResolvedCredentials(sessionListViewModel.credentials(of: set))`);
in der View steckt nur die Entscheidung. Der **Jump**-Füllpfad liegt
vollständig App-seitig und liest den Keychain selbst über eine synthetische
`StoredSession`. Genau dort saß der Critical.

## Der Entwurf

Core bekommt **einen** neuen Typ in `Sources/macSCPCore/Presentation/`. Er
beantwortet eine Frage: *darf dieser Submit laufen, und mit welchen Werten?*
Er liefert **Fälle, keinen Text** — dieselbe Aufteilung wie
`LoginResolveError`, und die, die die Projektregel für Core-Meldungen
verlangt.

### Drei Auflösungen plus ein Koordinator

| Funktion | Aufgabe |
|---|---|
| `resolveTargetLoginSet` | Ziel-Set auflösen; **neu: `kind`-Wächter** |
| `resolveJumpLoginSet` | Jump-Set auflösen; **Wächter vor dem Füllen** |
| `resolveJumpSession` | referenzierte Sitzung auflösen (vier Fehlerfälle) |
| `prepareForSubmit` | ruft alle drei, **kürzt nie ab**, sammelt **jede** Ablehnung |

Der Koordinator ist kein Beiwerk. Ein kurzschließender Koordinator verbirgt
die zweite und dritte Meldung — ein Verhalten, das heute niemand prüft und
das sich als Test schreiben lässt. Die Ablehnungen kommen in **fester
Reihenfolge** zurück (Ziel, Jump-Set, Jump-Sitzung), damit die App sie
deterministisch anzeigen kann und der Test sie als Liste vergleichen kann.

**Wer füllt.** Das Befüllen bleibt in Core, nicht in der App: `Connection
ViewModel` ist ein Core-Typ, und die Reihenfolge Wächter-vor-Füllen ist nur
dann festgenagelt, wenn beide Schritte im selben prüfbaren Aufruf liegen.
Der Submit-Pfad der App liest und schreibt danach **kein** Zugangsdatenfeld
mehr.

### Die Ablehnungsfälle

Jeder Fall trägt sein hervorzuhebendes Feld selbst. `ConnectionViewModel.
Field` ist bereits `public` in Core, die Zuordnung gehört also dorthin — und
wird damit prüfbar, statt wie heute über vier Fangzweige verstreut zu liegen.

| Fall | Feld | Meldungsschlüssel (App) |
|---|---|---|
| `targetSetMissing` | – | `loginSets.missingSet` |
| **`targetSetKindMismatch`** (neu) | – | **`form.loginSet.kindMismatch`** (neu) |
| `jumpSetMissing` | `.jumpHost` | `loginSets.missingSet` |
| `jumpSetNotSSH` | `.jumpHost` | `form.jump.set.notSSH` |
| `jumpSessionMissing` | `.jumpSession` | `form.jump.session.missing` |
| `jumpChainNotSupported` | `.jumpSession` | `form.jump.session.chainNotSupported` |
| `jumpSessionNotSSH` | `.jumpSession` | `form.jump.session.notSSH` |
| `jumpSessionLoginUnresolvable` | `.jumpSession` | `loginSets.missingSet` |

Der letzte Fall ist heute ein `catch`-all („dangling login set auf der
referenzierten Sitzung, oder sonst etwas"). Er behält seine Meldung, bekommt
aber einen Namen — ein unbenannter Sammelfall ist nicht prüfbar.

### Was in der App bleibt

Ein Dreizeiler: Fälle in Text übersetzen, `showFailure(message:field:)`
aufrufen, `refusals.isEmpty` zurückgeben. Kein Wächter, keine Reihenfolge,
keine Keychain-Lesung.

### Der neue Ziel-Wächter

`resolveSelectedLoginSet` fragt heute **nicht**, ob das gewählte Set zum
Protokoll der Sitzung passt. Folgenlos ist das nur durch einen
Namensraum-Zufall: `applyResolvedCredentials` legt die Werte unter dem
Präfix des jeweiligen Backends ab, und ein `.ssh`-Formular liest
`webdav.password` nie. **Sicher aus Versehen, nicht aus Konstruktion** —
und der Zufall trägt nur, solange kein Backend die Feld-Namen eines anderen
benutzt.

Der Wächter stellt dieselbe Frage wie die Jump-Seite, nur für das Ziel:
`set.kind == session kind`. Das ist die **einzige gewollte
Verhaltensänderung** dieser Phase.

## Was P2 erstmals prüfbar macht

Der Test, den es heute nicht geben kann:

> Ein Jump ist an ein WebDAV-Set gebunden. `prepareForSubmit` lehnt mit
> `jumpSetNotSSH` ab — **und** `form.jumpPassword` ist unverändert. Das
> Secret wurde nie ins Formular gelesen.

Die zweite Zusicherung ist die eigentliche: sie hält die Reihenfolge
Wächter-vor-Füllen fest. Wer die beiden Zeilen vertauscht, macht diesen Test
rot — mit dem Credential sichtbar an der falschen Stelle, nicht bloß mit
einem abweichenden Flag.

Dazu: dass der Koordinator nicht kurzschließt (zwei gleichzeitige Fehler
liefern zwei Ablehnungen), und die Fall-zu-Feld-Zuordnung.

## Was ausdrücklich **nicht** dazugehört

- **Die Entkernung des Rests von `ContentView`** (3540 Zeilen, 65 Funktionen)
  und die **Aufteilung in Unter-Views** — das ist P3.
- **UI-Testing.** Weder XCUITest noch ViewInspector kommen ins Projekt. Dass
  der Knopf die Core-Funktion tatsächlich aufruft, bleibt ungeprüft; der
  Restrisiko-Anteil schrumpft dadurch, dass die App-Seite auf einen
  Dreizeiler zusammenfällt.
- **Der veraltete Slot** einer set-gebundenen Sitzung. Eigener Durchgang.
- **Die Editor-Reibung** beim Bearbeiten eines Login-Sets.

## Risiken

- **Verhaltensgleichheit.** Sieben der acht Fälle müssen Meldung **und** Feld
  exakt wie heute liefern. Eine vertauschte Zuordnung wäre eine stille
  Verschlechterung: der Nutzer bekäme das falsche Feld hervorgehoben.
- **Der Jump-Fill zieht mit nach Core.** Er liest den Keychain über eine
  synthetische `StoredSession` mit der ID des Sets. Diese Konstruktion muss
  mitwandern, ohne dass eine zweite Lesart entsteht.
- **Der neue Ziel-Wächter kann bestehende Konfigurationen ablehnen**, die
  heute stillschweigend funktionieren — nämlich eine Sitzung, die an ein
  artfremdes Set gebunden ist. Das ist gewollt: sie funktioniert nur
  scheinbar, weil die Werte ins Leere geschrieben werden. Der Nutzer bekommt
  jetzt eine Erklärung statt eines unerklärlichen Anmeldefehlers.
- **Ein achter Fall, der heute keiner ist.** Der `catch`-all bekommt einen
  Namen; wenn dort mehr als der bekannte Fall hineinläuft, verdeckt der neue
  Name das nicht mehr — er benennt es.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Der Jump-Wächter läuft **vor** jeder Keychain-Lesung | Test: artfremdes Set gebunden ⇒ Ablehnung **und** `jumpPassword` unverändert |
| 2 | Mutation macht Kriterium 1 rot | Wächter hinter den Fill verschoben ⇒ Rot-Ausgabe wörtlich im Bericht, mit dem Credential an der falschen Stelle |
| 3 | Der Koordinator kürzt nie ab | Test mit zwei gleichzeitigen Fehlern ⇒ zwei Ablehnungen |
| 4 | Jeder der acht Fälle ist einzeln erreichbar | ein Test je Zeile der Fall-Tabelle |
| 5 | Fall-zu-Feld-Zuordnung stimmt | Test über alle acht Fälle |
| 6 | Sieben Fälle liefern Meldung und Feld **wie heute** | Vergleich gegen den heutigen Code, im Bericht Fall für Fall |
| 7 | Der neue Ziel-`kind`-Wächter greift | Test je Protokoll-Paarung |
| 8 | Die App-Seite ist ein Dreizeiler ohne Wächter | Review; kein `isEligible`, kein `kind`, keine Keychain-Lesung mehr in `ContentView`s Submit-Pfad |
| 9 | Kein Secret-Wert in Meldung, Log oder Testfehlertext | Review |
| 10 | Der neue Schlüssel steht in allen vier App-Katalogen | vorhandener Wächtertest, `plutil -lint` |
| 11 | Suite bleibt grün, Zahl steigt um die neuen Tests | Testausgabe |

## Für die Release-Notes

**Ein Satz.** Wird für eine Verbindung ein gespeichertes Login gewählt, das
zu einem anderen Protokoll gehört, sagt macSCP das jetzt, statt die Angaben
stillschweigend zu verwerfen.

## Offen, bewusst nicht Teil von P2

- P3: Entkernung und View-Aufteilung.
- Dass der Submit-Knopf die Core-Funktion aufruft, ist nicht pinnbar (siehe
  oben).
- Kein Test deckt den Pfad ab, über den die ausgelieferte App ihr
  Ressourcen-Bundle findet (Befund aus P1).
- Der veraltete Slot, die Editor-Reibung, der app-weite Audit-Bereich.
- Der Release-Stau: 399 Commits vor `origin/main`.
