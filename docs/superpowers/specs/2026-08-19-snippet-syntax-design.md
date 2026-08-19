# Snippet-Editor Teil 1 — Syntax-Darstellung (Design)

Stand 2026-08-19. Teil 1 von drei; die Zerlegung steht im Backlog
(Maintainer-Wunsch 2026-08-19). Rein additiv: keine Modelländerung, kein
Sicherheitsbezug.

## Ausgangslage

Das Befehlsfeld im Snippet-Editor ist heute ein einzeiliges `TextField` über
`@State private var command: String`. Die Liste zeigt den Befehl als
schlichten `Text`. Nichts davon ist eingefärbt.

**SwiftUI kann ein `TextField` beim Tippen nicht einfärben.** Farbe pro
Bereich gibt es nur über `AttributedString` in einem `Text` — also dort, wo
gelesen statt getippt wird — oder über einen `NSTextView` als
`NSViewRepresentable`. Maintainer-Entscheidung 2026-08-19: **auch im
Eingabefeld**, also `NSTextView`.

## Der Schnitt

**Ein getesteter Tokenizer in Core, eine ungetestete Darstellung in der
App-Schicht.** Das ist der einzige Schnitt, der überhaupt Testabdeckung
bringt: kein Test dieses Projekts zeichnet `NSViewRepresentable` (gemessen
in PV/P0 — Controls sind im Bitmap unsichtbar).

## Core: der Tokenizer

Eine reine Funktion. Befehlstext rein, benannte Bereiche raus — **kein
AppKit, keine Farben**. Welche Farbe eine Art bekommt, entscheidet die
App-Schicht über die vorhandenen Design-Tokens.

Erkannt wird, was in einem Snippet wirklich vorkommt:

| Art | Beispiel |
|---|---|
| Befehl (erstes Wort) | `docker` |
| Option | `-h`, `--follow` |
| Zeichenkette | `'…'`, `"…"` |
| Variable | `$HOME`, `${TAG}` |
| Kommentar | `# …` bis Zeilenende |
| Operator | `\|`, `&&`, `\|\|`, `;`, `>`, `<` |

Alles andere ist schlicht Text.

**Sprache als Parameter, nicht als gespeichertes Feld.** Die Funktion nimmt
die Sprache entgegen (`tokens(in:language:)`), heute mit dem einen Fall
`.shell`. Ein *gespeichertes* `type`-Feld am `Snippet` wird **nicht**
angelegt: es hätte genau einen möglichen Wert, und diese Bauart hat sich in
diesem Projekt schon den Vorwurf eingefangen, strukturell untestbar zu sein
(siehe `LoginMergeCandidate.kind`, dessen Doc-Kommentar das einräumt).
Kommt ein zweites Protokoll (Telnet o. Ä.), wird das Feld dann ergänzt und
altes JSON dekodiert als `.shell` — dasselbe Optional-Muster, das
`groupID` und `loginSetID` hier bereits benutzen. Durch das Warten geht
nichts verloren.

## App: `NSTextView` im `NSViewRepresentable`

Vier bekannte Fallen, ausdrücklich als Aufgaben geführt statt später
entdeckt:

1. **Cursor-Erhalt.** Neu-Einfärben setzt Attribute; ohne Vorkehrung
   springt die Einfügemarke ans Ende. Position vorher sichern, nachher
   zurücksetzen.
2. **Undo.** Attributänderungen dürfen nicht in den Undo-Stack, sonst macht
   ⌘Z Farben rückgängig statt Text.
3. **Bindungs-Schleife.** Textänderung → Binding → View-Update →
   Textänderung. Braucht eine Wächter-Bedingung, sonst rekursiert es.
4. **Aussehen.** Das Feld steht neben schlichten `TextField`s in einem
   Formular, an dem vier Runden Feinarbeit hängen (M5f/g/h/k). Rahmen,
   Innenabstand, Fokusring und Schrift müssen den Nachbarn entsprechen.

## Die Zeilenumbruch-Klemme

`Snippet.init?` lehnt **jeden** Zeilenumbruch ab (absichtlich, siehe P3e) —
und ein `NSTextView` nimmt Enter von Haus aus an. Das Feld muss Enter also
abweisen, solange Teil 2 (mehrzeilig) nicht da ist.

Diese Abweisung gehört in eine kleine, **getestete** Funktion und nicht in
einen Delegate-Zweig, den kein Test sieht. Sonst baut Teil 1 stillschweigend
Eingaben, die das Modell danach verwirft — und der Nutzer sieht nur, dass
Speichern nicht geht.

## Tests

**Tokenizer, vollständig.** Je ein Fall pro erkannter Art, plus die Fallen:

- eine Zeichenkette, die nichts schließt (`echo "abc`)
- ein `#` **innerhalb** einer Zeichenkette — kein Kommentar
- ein `$` am Ende ohne Namen
- ein Befehl ohne jedes Sonderzeichen — alles Text außer dem ersten Wort

**Konstant-Rückgabe-Probe:** ein Tokenizer, der pauschal „Text" liefert,
muss an mindestens einem dieser Tests scheitern. Der letzte Fall ist
zugleich die Gegenrichtung — er scheitert an einem Tokenizer, der alles als
Befehl markiert.

**Die Zeilenumbruch-Abweisung** bekommt ihren eigenen Test.

## Was ungeprüft bleibt

Die Darstellung selbst: Cursor-Verhalten, Undo, Fokusring und die
Ähnlichkeit zu den Nachbarfeldern sieht **nur eine Sichtprüfung beim
Maintainer**. Kein Test dieses Projekts zeichnet `NSViewRepresentable`. Das
ist der Preis der Entscheidung für ein einfärbendes Eingabefeld und gehört
so in den Abschlussbericht.
