# Backlog: Snippet-Editor Teil 3 — deklarierte Variablen

**Angelegt:** 2026-08-19. **Kein Design, sondern eine gesicherte Idee.**

Diese Schärfung stammt aus dem Gespräch beim Zuschnitt von Teil 1 und war
danach in keiner Datei — sie lebte nur im Verlauf. Beim Aufräumen der
Wegwerf-Artefakte fiel das auf. Hier steht sie, damit sie einen Brainstorming-
Durchgang überlebt, nicht damit sie ihn ersetzt.

## Die Idee des Maintainers

Ein Snippet bekommt ein Kennzeichen — im Gespräch „erweitertes Snippet" —,
und erst damit erscheint ein Bereich, in dem **Variablen deklariert** werden:
Name, Typ (freie Eingabe, Auswahl aus einer Liste), vermutlich ein
Vorgabewert. Beim Auslösen fragt macSCP die Werte ab und übergibt sie an den
Befehl.

Der Kern des Arguments, und er ist gut: **so muss niemand die Variablen im
Text suchen.** Die Alternative — den Befehlstext nach `{{name}}` oder `$1`
absuchen und daraus ein Formular bauen — macht den Befehl zur Quelle der
Wahrheit über etwas, das der Nutzer nirgends zusammenhängend sieht. Eine
Deklaration ist sichtbar, sortierbar, kommentierbar.

Beispiele aus dem Gespräch: ein Datenbank-Export, ein Log einsammeln und unter
einem Namen ablegen — also wiederkehrende Abläufe, bei denen sich zwischen
zwei Aufrufen genau ein oder zwei Werte ändern.

Zusätzlich erwogen: ein **Typ-Marker am Snippet** (`shell`, perspektivisch
`telnet` o. Ä.), falls macSCP je andere Sitzungsarten bekommt. Der Tokenizer
aus Teil 1 nimmt die Sprache bereits als Parameter entgegen und speichert sie
ausdrücklich **nicht** — dieser Marker wäre der Ort, an dem sie herkäme.

## Was vor einem Design zu klären ist

- **Wie die Werte in den Befehl kommen.** Textersetzung im Befehl, oder als
  `NAME=wert` vorangestellte Umgebungszuweisungen? Das erste ist offensichtlich
  und anfällig für Quoting-Fehler; das zweite ist robust, funktioniert aber nur
  für Werte, die tatsächlich als Umgebung taugen.
- **Quoting.** Ein Wert mit Leerzeichen, Anführungszeichen oder `$` darf den
  Befehl nicht umbauen können. Das ist der sicherheitsnahe Kern des ganzen
  Vorhabens und gehört an eine getestete Stelle in Core, nicht in die View.
- **Braucht es das Kennzeichen überhaupt?** Dieselbe Frage wie bei Teil 2, wo
  sie den Schalter gekostet hat: eine leere Deklarationsliste ist bereits die
  Aussage „keine Variablen". Ein Flag daneben kann ihr widersprechen. Der
  Unterschied zu Teil 2: hier wäre das Flag zugleich der Schalter, der den
  Bereich in der Oberfläche überhaupt einblendet — das kann seinen Preis wert
  sein. Offen, nicht entschieden.
- **Store-Format.** Anders als Teil 2 kommt dieser Teil ohne Migration nicht
  aus. Das Snippet-JSON bekommt eine Struktur, und Export/Import
  (`macscp`-Umschlag) müssen mit.
- **Niemals Zugangsdaten.** Der Snippet-Store ist reines JSON. Ein
  Variablentyp „Passwort", der den Wert speichert, ist ausgeschlossen; ein
  Typ, der bei jedem Aufruf fragt und den Wert nicht behält, wäre denkbar —
  und müsste dann auch aus dem Protokoll herausgehalten werden, das heute den
  ausgeführten Befehl mitschreibt.

## Reihenfolge

Nach Teil 2. Teil 2 macht mehrzeilige Rümpfe möglich, und erst damit lohnen
Variablen richtig — ein einzeiliger Befehl mit drei Abfragen ist selten.
