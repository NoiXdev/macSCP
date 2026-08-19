# M30 — Der abgestandene Session-Slot beim Login-Set-Wechsel (Design)

Stand 2026-08-19. Ersetzt den am 2026-08-09 in `479d018` zurückgenommenen
Anlauf.

## Ausgangslage

Eine Sitzung, die an ein Login-Set gebunden wird, behält ihr eigenes
Passwort im Schlüsselbund. Schaltet der Nutzer später auf manuell zurück und
lässt das Feld leer, wird nichts geschrieben — und der nächste Connect nimmt
den alten Wert.

Vier Anläufe sind daran gescheitert. Jeder wollte den Slot **beim Binden**
löschen, jede Review-Runde schloss den zuvor benannten Verlustweg und
lieferte einen neuen. Die Revert-Nachricht zählt drei der vier Wege
namentlich auf; einer davon fragte `LoginSet.authKind == .agent`, obwohl der
Kommentar daneben wörtlich davor warnt, genau diese Ersetzung vorzunehmen. Die
Commit-Nachricht des Reverts fasst es zusammen: der Defekt ist real, aber
mild — ein unsichtbarer Slot, dessen Wert noch funktioniert —, und dagegen
stand jedes Mal ein Pfad, der die einzige Kopie eines Zugangsdatums
vernichtet.

## Was vorher gemessen wurde

Vier Messungen, die den Entwurf tragen. Ohne sie wäre dieselbe Falle noch
einmal aufgestellt worden:

1. **Das Formular lädt das Geheimnis nie aus dem Schlüsselbund.** Ein leeres
   Feld beim Speichern heißt projektweit „unverändert lassen" — eine
   bewusste, dokumentierte Regel.
2. **`visibleSecretField(for session:)` weiß von der Set-Bindung nichts.**
   Es liest nur die eigenen Werte der Sitzung; der Lösch-Zweig in
   `updateSession` (der für ssh-agent aufräumt) greift hier also nicht. Der
   Slot überlebt tatsächlich.
3. **Der Edit-Save-Validator läuft mit `requireSecrets: false`** — genau
   deshalb geht das leere Feld heute durch.
4. **`requireSecrets: true` verlangt nur sichtbare, als erforderlich
   deklarierte Geheimfelder.** Die SSH-Passphrase ist ausdrücklich optional,
   Agent-Logins zeigen gar kein Geheimfeld. Es gibt also keine
   Falschablehnung — die Annahme, an der dieser Ansatz sonst gescheitert
   wäre.

## Der Schnitt

Der Befund zerfällt in zwei Schäden:

- **Schaden 1:** Ein Geheimnis, das der Nutzer für abgelöst hält, liegt
  weiter im Schlüsselbund — unsichtbar, unbenutzt, ohne Verfallsdatum.
- **Schaden 2:** Beim Zurückschalten auf manuell wird es stillschweigend
  wieder aktiv.

**M30 behebt Schaden 2. Schaden 1 bleibt bewusst offen** (Maintainer-
Entscheidung 2026-08-19). Alle vier gescheiterten Anläufe zielten auf
Schaden 1 — per Löschen in dem Moment, in dem das Löschen am gefährlichsten
ist, weil das Set die einzige Kopie halten kann.

## Die Regel

Beim Verlassen des Set-Modus bedeutet ein leeres Geheimfeld **nicht**
„unverändert", sondern ist ein Validierungsfehler. Der bestehende Validator
sagt das mit der Meldung, die er für dieses Feld ohnehin deklariert.

In `ConnectionViewModel.validateForEditSave()` ist die Geheimnis-Pflicht
damit keine Konstante mehr, sondern folgt aus dem Übergang:

```swift
let leftLoginSet = editingOriginal.loginSetID != nil && loginMode == .manual
if let violation = descriptor.firstViolation(in: values, requireSecrets: leftLoginSet) { … }
```

Symmetrisch für den Jump, über `editingOriginal.jump?.loginSetID` und
`jumpLoginMode`; `validateJump(requireSecret:)` trägt den Parameter bereits.
Ein sitzungsreferenzierender Jump (`jumpSourceMode == .session`) kehrt dort
ohnehin früh zurück und besitzt kein eigenes Geheimnis, der Fall kann also
nicht greifen.

**Die Änderung enthält keinen `delete`-Aufruf.** Der getippte Wert
überschreibt den alten Slot über den vorhandenen Schreibpfad. Die vier
Verlustwege sind damit nicht bewacht, sondern baulich ausgeschlossen — das
ist der eigentliche Unterschied zum zurückgenommenen Anlauf.

## Warum die Regel im Validator sitzt

Validierung gehört in den Validator. `validateForEditSave` ist die eine
Funktion, die ein Edit-Speichern seine Sitzung zusammenbauen lässt; die
Aufrufstellen im Formular gehen beide durch sie hindurch. Ein künftiger
Aufrufer kann die Regel deshalb nicht vergessen — dieselbe Begründung wie
beim Jump-Guard in `updateSession`.

`editingOriginal` ist dort nachweislich nicht-nil, nicht bloß „bisher immer":
`mode` ist `private(set)`, `beginEditing` ist die einzige Stelle, die
`.edit` setzt, und sie setzt `editingOriginal` davor. Der bestehende
Doc-Kommentar führt das bereits aus.

Die Alternative — die Regel in `SessionListViewModel.updateSession`, das den
vorherigen Zustand ebenfalls kennt — wurde verworfen: dort müsste ein neuer
Ablehnungspfad durch die Persistenzschicht wachsen, für eine Frage, die die
Validierung schon beantworten kann.

## Randfälle

| Fall | Verhalten |
|---|---|
| Set → manuell, Passwort-Auth, Feld leer | abgelehnt, Passwortfeld benannt |
| Set → manuell, Passwort getippt | gespeichert, alter Wert überschrieben |
| Set → manuell, Schlüssel-Auth ohne Passphrase | gespeichert (Passphrase ist optional) |
| Set → manuell, Agent-Auth | gespeichert (kein Geheimfeld sichtbar) |
| Set A → Set B | unverändert, kein manueller Modus im Spiel |
| Manuelle Sitzung, kein Modus-Wechsel, Feld leer | gespeichert — „leer = unverändert" bleibt intakt |

### Die andere Tür: das Set wird gelöscht

Eine Sitzung verlässt den Set-Modus auch, wenn ihr Login-Set gelöscht wird.
Dieser Pfad ist **bereits richtig** und wird nicht angefasst: er schreibt das
Geheimnis des Sets in den Slot der Sitzung, bevor er `loginSetID` nullt. Der
alte Wert wird also überschrieben, nicht abgestanden zurückgelassen — hier
entsteht der Befund gar nicht. Nachgemessen 2026-08-19; ohne diese Messung
wäre es die naheliegendste Lücke im Umfang von M30.

## Der Preis

Wer das Set verlässt und sein altes Passwort behalten wollte, muss es einmal
neu tippen. Das ist die Gegenleistung dafür, dass „leer" an dieser Stelle
nicht mehr zwei Dinge bedeuten kann. Bewusst so entschieden, nicht übersehen.

## Tests

Sechs Fälle, einer je Zeile der Randfall-Tabelle, plus die beiden
Jump-Formen von Zeile 1 und 2.

Die **Konstant-Rückgabe-Probe** ist erfüllt: Zeile 1 wird rot, wenn
`requireSecrets` hart auf `false` steht, Zeile 6 wird rot, wenn es hart auf
`true` steht. Die Regel ist damit in beide Richtungen festgenagelt, nicht
nur in der, die der Fix herstellt.

Zeile 3 und 4 sind die Falschablehnungs-Wächter: sie halten Messung 4 fest,
damit ein künftiger Umbau der Feldschemata — etwa eine Passphrase, die
erforderlich wird — hier auffällt statt beim Nutzer.

## Was offen bleibt

Schaden 1: der eigene Slot einer Sitzung, die gebunden **ist**, wird nicht
angefasst. Ebenso unberührt bleiben die im Revert genannten Nachbarn
`applyMerge` und die Jump-Bindung, die mit `try?` lesen und trotzdem
löschen — sie gehören zu Schaden 1 und zu keinem Pfad, den M30 anfasst.
