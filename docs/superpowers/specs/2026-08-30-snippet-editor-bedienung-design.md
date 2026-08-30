# Snippet-Editor: Variablen falten, Platzhalter vorschlagen — Entwurf

**Stand:** 2026-08-30. Umsetzung von
`docs/superpowers/specs/2026-08-21-backlog-snippet-editor-bedienung.md`.

---

## Entscheidungen des Maintainers (2026-08-30)

1. **Kein gemerkter Faltzustand.** Jedes Öffnen beginnt gleich.
2. **Voller Umfang bei den Platzhaltern:** Einfügen über die Variablenzeile,
   Hinweis auf ein undeklariertes `{{NAME}}`, **und** Tipp-Vervollständigung
   bei `{{`.

## Der gemessene Ausgangszustand

`SnippetCommandEditor` ist bereits ein `NSTextView` — eine Vorschlagsliste
daran ist ein gelöstes Problem, an einem SwiftUI-`TextField` wäre es keins.

`SnippetVariableSubstitution.Problem` führt **sechs** Fälle, in diesem
Durchgang gezählt: `invalidName`, `unanalyzableContext`, `unusedPlaceholder`,
`placeholderInsideQuotes`, `placeholderNotInArgumentPosition`,
`placeholderIsReparsedByItsCommand`.

**Keiner davon ist „benutzt, aber nicht deklariert".** Ein `{{NAME}}` ohne
Deklaration geht wörtlich an die Shell. Als Text harmlos — aber der Befehl
tut etwas anderes, als der Nutzer glaubt, und nichts sagt es ihm. Der Eintrag
nennt das den eigentlichen Gewinn, und er hat recht: die anderen zwei Punkte
sind Bedienung, dieser behebt einen stillen Fehler.

## 1. Falten

### Kein gemerkter Zustand

Bestehende Variablen sind beim Öffnen **zu**, eine neu hinzugefügte **offen**
— sonst tippt niemand hinein.

Nichts wird gespeichert. Damit stellt sich die Frage nicht, wo der Zustand
lebt, ob er zum Snippet passt, was beim Löschen einer Variablen mit ihm
geschieht und ob er mit einem Export reist. Der Eintrag verlangt ohnehin, dass
er nie ins Modell darf; ihn gar nicht erst zu haben ist die kürzere Antwort.

### Was die zugeklappte Zeile zeigt

**Name, Art und Platzierung.** Genug, um die richtige wiederzufinden, ohne sie
zu öffnen — und Platzierung gehört dazu, weil sie darüber entscheidet, ob die
Variable überhaupt als `{{NAME}}` in den Befehl gehört.

### Eine Variable mit Fehler bleibt offen

Sie lässt sich nicht zuklappen, solange sie ein Problem hat.

Die Alternative — zuklappbar mit Fehlermarkierung — sagt einem, *dass* etwas
nicht stimmt, aber nicht *was*, und man klappt sie ohnehin auf. Und sie
verletzt den Zweck des Faltens an genau der Zeile, die Beachtung braucht.

**Daraus folgt eine nützliche Eigenschaft von selbst:** „alle zuklappen"
lässt die fehlerhaften offen und wird damit zu „zeig mir nur die Probleme".

### Massenaktionen

„Alle auf" und „alle zu", neben „Variable hinzufügen". **Nur zeigen, was
möglich ist**: sind alle bereits offen, erscheint „alle auf" nicht.

## 2. Platzhalter

### Der Hinweis auf Undeklariertes

Steht im Befehl ein `{{NAME}}`, das keine Deklaration hat, sagt der Editor
es. **Das ist kein neuer `Problem`-Fall**, sondern eine Anzeige im Editor:
`SnippetVariableSubstitution` entscheidet, ob gesendet werden darf, und
daran ändert sich nichts — ein undeklarierter Platzhalter war und bleibt
sendbar, er ist nur wörtlich.

Der Unterschied ist wichtig: eine Prüfung, die das Senden **verbietet**,
wäre eine Verhaltensänderung an acht Prüfrunden vorbei. Ein Hinweis im
Editor ist eine Anzeige.

### Einfügen über die Variablenzeile

Ein Weg, eine deklarierte Variable in den Befehl zu setzen, ohne ihren Namen
zu tippen. Deckt den Fall ab, dass man ihn nicht mehr weiß.

### Vervollständigung bei `{{`

Sobald `{{` getippt ist, werden die deklarierten Namen angeboten.

**Angeboten wird nur, was als `{{NAME}}` in den Befehl gehört.** Eine
Variable mit Platzierung „Umgebungsvariable" gehört das gerade nicht — sie
wird als Zuweisung vorangestellt. Sie mit anzubieten führte zum genauen
Gegenteil dessen, was ihre Platzierung sagt.

**Und sie wird auch nicht als `$NAME` angeboten.** Das ist die Fußangel aus
dem Eintrag, gemessen: bei einer **einzeiligen** Zuweisung als Präfix
expandiert die Shell `$NAME`, *bevor* die Zuweisung greift —
`P=neu echo "$P"` gibt den alten Wert aus. Eine Vervollständigung, die
`$NAME` einsetzt, wäre in einem einzeiligen Befehl still falsch, und
„manchmal anbieten, je nach Zeilenzahl" wäre eine Regel, die sich beim Tippen
ändert.

**Wer `$NAME` von Hand schreibt, sieht die Folge im Probelauf** — der zeigt
seit gestern den aufgelösten Text, und dieser Fall ist genau der, für den er
eine Fixture hat. Das ist die ehrliche Antwort: nicht verhindern, sondern
sichtbar machen.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: was die zugeklappte Zeile trägt, dass eine
fehlerhafte offen bleibt, welche Namen die Vervollständigung anbietet und
welche nicht, und wann der Hinweis auf ein undeklariertes `{{NAME}}`
erscheint.

**Nicht prüfbar** bleibt, ob sich die Vorschlagsliste am `NSTextView` beim
Tippen gut anfühlt, und ob das Formular nach dem Falten wirklich in das
Sheet passt. Beides Maintainer-Blick.

## Was ausdrücklich nicht dazugehört

- **Kein gespeicherter Faltzustand**, in keiner Form.
- **Kein neuer `Problem`-Fall** und keine Änderung an
  `SnippetVariableSubstitution` oder `SnippetCommandSurvey`. Der Hinweis ist
  eine Anzeige, kein Tor.
- **Kein `$NAME` in der Vervollständigung.**
- **Keine Änderung an der Sheet-Breite** (460 pt). Platz entsteht durch
  Falten, nicht durch ein größeres Fenster.
