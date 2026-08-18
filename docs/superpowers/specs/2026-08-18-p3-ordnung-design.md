# P3 — Ordnung: Host-Tags, Sidebar-Filter, Snippet-Austausch

Entschieden 2026-08-18. Hebt den Skizzen-Abschnitt „P3 — Ordnung" aus
`2026-08-10-snippets-runde-2-design.md` auf entschieden. Die dortigen drei
Festlegungen gelten unverändert weiter und werden hier nicht neu verhandelt:
Gruppen bleiben die Ablage und Tags die Sicht darauf; Host-Tags und
Snippet-Tags sind unabhängige Vokabulare; der Austausch bekommt keinen
Krypto-Pfad.

## Der gemessene Ausgangszustand

Nachgesehen, nicht angenommen:

- **Die Sidebar hat kein Suchfeld und keinen Filter.** `SessionSidebar`
  läuft ungefiltert durch `SessionListViewModel.sessions(inGroup:)`. Weder
  `searchText` noch eine Filterfunktion existiert. Ein Tag-Filter ist damit
  nicht „ein Filter mehr", sondern das erste Filterelement überhaupt.
- **Die Sidebar hat keinen Leer-Zustand.** Ist die Liste leer, rendert
  nichts. Die vorhandenen roten Fehlerzeilen decken nur Fehlerfälle ab.
- **Gruppen sind native `Section(isExpanded:)`-Blöcke**, eingeklappte
  Gruppen liegen in einem `Set<UUID>` im View-Zustand.
- **Der Bereich „IMPORTIERT"** (`~/.ssh/config`) ist eine eigene Section
  neben den Gruppen.
- **`StoredSession`** trägt heute `id`, `name`, `groupID`, `loginSetID`,
  `kind`, die drei Backend-Konfigurationen und `paneVisibility`. Die beiden
  Nicht-Verbindungsfelder `groupID` und `paneVisibility` werden beide über
  `decodeIfPresent` gelesen und im Export mitgeführt
  (`ExportedSession.paneVisibility`, `encodeIfPresent`).
- **Die Snippet-Tag-Regel** steht in `Snippet.init`: trimmen, Leere
  verwerfen, exakte Duplikate verwerfen (Groß/Klein bleibt erhalten),
  Reihenfolge des ersten Auftretens.
- **Die Envelope-Maschinerie** ist bereits generisch: `ExportEnvelopeCodec`
  mit `encode/probe/decode` über einen beliebigen `Codable`-Payload, und
  `password: String?` — bei `nil` entsteht ein Klartext-Payload mit
  `encrypted: false`. Zwei Formate nutzen sie: `macscp-sessions` und
  `macscp-logins`. Der Konflikt-Arbiter (`ImportConflict`,
  `ImportConflictArbiter`) wird von beiden Planern geteilt.
- **`SnippetStore`** schreibt `snippets.json` als **nacktes Array ohne
  Versionsfeld**. Ein Export- oder Importpfad für Snippets existiert nicht.

## Der Schnitt: zwei Teilphasen

P3 bündelt zwei Vorhaben, die außer dem Wort „Tag" nichts teilen. Sie werden
getrennt gebaut und getrennt abgeschlossen.

| Phase | Inhalt | Warum getrennt |
|---|---|---|
| **P3a** | Host-Tags am `StoredSession`, Formularfeld, Export/Import, Chip-Filter in der Sidebar, Leer-Zustand | eigener, in sich geschlossener Gegenstand |
| **P3b** | Austauschformat `macscp-snippets`, Codec, Planer, Export-/Import-Sheets | teilt mit P3a keine Datei außer der Tag-Regel |

Der Grund ist nicht Ordnungsliebe. Die Gesamt-Review am Phasenende hat in
den letzten Durchgängen genau deshalb Befunde geliefert, die keine
Task-Review sehen konnte, weil sie **eine** zusammenhängende Sache im Blick
hatte. Zwei unverbundene Subsysteme in einem Durchgang schwächen den
Prüfschritt, der hier am meisten liefert.

---

## P3a — Host-Tags und Sidebar-Filter

### Eine Regel, zwei Vokabulare

Die Normalisierung aus `Snippet.init` wandert als **eine** Funktion nach
Core. `Snippet` und `StoredSession` rufen dieselbe Funktion auf. Die
Vokabulare bleiben getrennt — ein Host-Tag versteckt kein Snippet, die
Bindung ist weiterhin ausdrücklich abgelehnt —, aber die *Regel* wird nicht
zweimal hingeschrieben.

Das ist keine Stilfrage. Zwei Kopien einer Regel, die auseinanderlaufen,
ohne dass ein Test es merkt, ist der Fehler, für den dieses Projekt zuletzt
mehrfach bezahlt hat: zuletzt in P2, wo eine wörtlich nachgebaute
Sichtbarkeitsregel ein leeres Fenster erzeugen konnte.

**Prüfbar:** ein Test, der beide Aufrufer gegen dieselben Eingaben laufen
lässt und gleiches Ergebnis verlangt. Er muss rot werden, wenn eine der
beiden Seiten die Regel selbst nachbaut.

### Das Feld

`tags: [String]` an `StoredSession`, oben neben `groupID` und
`paneVisibility` — **nicht** im Backend-Feldbeutel `FieldValues`, denn ein
Tag ist keine Verbindungseigenschaft, sondern eine Eigenschaft der
gespeicherten Sitzung.

- `decodeIfPresent` mit Standard `[]`. Eine vorhandene `sessions.json` ohne
  das Feld lädt unverändert und verhält sich exakt wie heute.
- Im Export mitgeführt, wie `paneVisibility` es vormacht.
- Eingabe im Verbindungsformular über dasselbe Token-Feld wie bei Snippets
  (`SnippetTagField`), sofern es sich ohne Verrenkung wiederverwenden lässt;
  andernfalls ein gleich aussehendes Feld, das dieselbe Regel benutzt. Das
  ist beim Bauen zu **messen**, nicht vorab zu behaupten.

### Der Filter

Eine Chip-Reihe über der Liste, gespeist aus den tatsächlich vergebenen
Tags. Genau ein Tag ist aktiv oder keiner.

- Ist ein Tag aktiv, **verschwinden Gruppen ohne Treffer vollständig**, und
  der Bereich „IMPORTIERT" verschwindet ebenfalls — er kann nie treffen.
  Die Liste zeigt dann genau die Hosts mit diesem Tag, sonst nichts.
- Der Filterzustand wird **nicht gespeichert**. Er ist eine Sicht, keine
  Einstellung, und startet bei jedem Programmstart leer.
- Verschwindet der letzte Host mit dem aktiven Tag (umbenannt, gelöscht,
  Tag entfernt), fällt der Filter auf „kein Tag" zurück, statt eine leere
  Liste stehen zu lassen.

### Der Leer-Zustand

Die Sidebar bekommt einen Leer-Zustand, den sie heute nicht hat. Ohne ihn
wäre ein Filter ohne Treffer ein wortlos leeres Fenster. Zwei
unterscheidbare Fälle, nicht ein gemeinsamer Text:

- **keine Sitzungen vorhanden** — der Zustand einer frischen Installation
- **Filter aktiv, kein Treffer** — mit einem Weg zurück (Filter aufheben)

Der zweite Fall ist der Grund für den ersten: er kommt ohnehin, sobald es
den Filter gibt, und ein gemeinsamer Text für beides würde bei einer
frischen Installation von einem Filter reden, den niemand gesetzt hat.

### Die Entscheidungslogik gehört nach Core

Welche Gruppen und welche Sitzungen bei aktivem Tag sichtbar sind, und
welcher der beiden Leer-Zustände gilt, ist eine reine Funktion aus
(Sitzungen, Gruppen, aktivem Tag) — und gehört als testbarer Typ nach Core,
nicht in den View-Body. P2 hat gezeigt, wie teuer die andere Variante ist:
eine Anzeigeentscheidung im View-Body war dort nur noch mit einem
Quelltext-Wächter zu sichern.

---

## P3b — Snippets exportieren und importieren

### Das Format

`macscp-snippets` über `ExportEnvelopeCodec`, mit **`password: nil`,
immer**. Die Signatur nimmt ein Passwort entgegen; dieser Codec übergibt
nie eines, und das wird gepinnt statt kommentiert.

Snippets enthalten keine Zugangsdaten — der Store ist JSON, Secrets leben
ausschließlich im Schlüsselbund. Eine Verschlüsselung würde eine Sicherheit
vortäuschen, die es nicht gibt. Das ist dieselbe Begründung wie in Runde 1
und sie hat sich nicht geändert.

Eigener UTType nach dem vorhandenen Muster
(`dev.noix.macscp.snippets`, konform zu `.json`).

### Der Planer

Eigener Planer auf dem **geteilten** `ImportConflictArbiter` — nicht ein
zweiter Arbiter daneben. **Duplikat am Namen**, wie bei Login-Sets: ein
importiertes „Docker aufräumen" trifft auf ein vorhandenes gleichen Namens,
und der Nutzer entscheidet überschreiben, behalten oder beide.

Der Vergleich folgt derselben Trimm-Regel wie die Tags, damit
„Docker aufräumen " und „Docker aufräumen" nicht als zwei Einträge landen.

### Die Oberfläche

Export- und Import-Sheets nach dem Muster der Sitzungs-Sheets, inklusive
Auswahl beim Export. Das geteilte Konflikt-Sheet aus M19 wird
wiederverwendet.

---

## Was ausdrücklich nicht dazugehört

- **Der Massen-Runner** (ein Snippet auf n gefilterte Hosts, Ausgabe-Ansicht)
  bleibt außen vor. Er ist ein eigenes Werkzeug — n parallele Verbindungen,
  Teilfehler, Abbruch, n lesbare Ausgabeströme — und bekommt sein eigenes
  Brainstorming. P3as Filter ist die Auswahlmechanik, auf der er aufsetzt.
- **Ein Versionsfeld für `snippets.json`.** Der Store bleibt das nackte
  Array. Die Austauschdatei bekommt ihre Version über die Envelope. Eine
  Migration des Stores ist eine eigene Aufgabe.
- **Jede Bindung zwischen Host-Tags und Snippet-Tags.**
- **Mehrfachauswahl im Filter** (zwei Tags gleichzeitig). Ein Tag genügt für
  den Zweck; die Mechanik lässt sich später erweitern, ohne dass jetzt
  jemand die Und/Oder-Frage beantworten muss.

## Erfolgskriterien

1. Eine `sessions.json` ohne `tags` lädt unverändert und zeigt keine Tags.
2. Ein Host mit Tag `docker` erscheint bei aktivem Filter `docker`; ein Host
   ohne diesen Tag nicht; „IMPORTIERT" verschwindet.
3. Tags überleben Export und Import.
4. Beide Leer-Zustände sind unterscheidbar und im Filterfall wieder
   verlassbar.
5. Snippets lassen sich exportieren und wieder einlesen; ein gleichnamiges
   Snippet erzeugt einen Konflikt, kein stilles Überschreiben.
6. Die exportierte Snippet-Datei ist Klartext und enthält kein Feld, das
   Verschlüsselung behauptet.

## Prüfbarkeit, ehrlich

Was Tests halten können: die Tag-Regel und ihre gemeinsame Nutzung, die
Sichtbarkeitsberechnung samt Leer-Zustand als Core-Typ, Migration gegen eine
wörtliche Alt-Datei, der Export-Roundtrip, die Duplikat-Regel des Planers,
und dass der Snippet-Codec nie ein Passwort übergibt.

Was Tests hier **nicht** halten: dass die Chip-Reihe im Fenster gut
aussieht, dass das Token-Feld sich im Verbindungsformular richtig anfühlt,
und dass die Sidebar bei aktivem Filter tatsächlich so aussetzt wie
beschrieben. Das App-Target hat kein View-Instanziierungswerkzeug; in P2
blieb dafür nur ein Quelltext-Wächter, dessen Grenzen dokumentiert sind.
Diese Punkte gehören in die Sichtprüfung des Maintainers am Phasenende und
werden dort namentlich aufgeführt, nicht stillschweigend übergangen.

---

## Nachtrag 2026-08-18: Terminal aus dem Host-Kontextmenü (P3c)

Maintainer-Feedback nach dem Dev-Build von P3a. **Nicht** Teil von P3b; eine
eigene kleine Phase.

Das Kontextmenü einer gespeicherten Sitzung bekommt unter „Verbinden" zwei
Einträge:

- **„Terminal öffnen"** — verbindet in macSCP und kommt **ohne Dateibrowser**
  hoch, also nur das Terminal. Die Mechanik dafür steht seit P2: eine
  Sitzung kann ihre sichtbaren Hälften selbst bestimmen.
- **„In externem Terminal öffnen"** — übergibt an das eingestellte
  Terminalprogramm; macSCP baut dabei **keine** eigene Verbindung auf.

**Beide sind eigene Einträge**, nicht ein Eintrag, der der Einstellung
„Terminal-Ziel" folgt (Maintainer-Entscheidung): die Entscheidung fällt pro
Klick, nicht vorab in den Einstellungen. Die Einstellung bleibt, wofür sie
da ist — was der Terminal-Knopf in der Symbolleiste tut.

**Beide erscheinen nur, wenn die Sitzung eine Shell hat.** Für S3 und WebDAV
sagt `BackendDescriptor.capabilities.supportsShell` nein, und dann gibt es
die Einträge nicht — nicht ausgegraut, sondern gar nicht, weil ein
dauerhaft toter Eintrag an einem S3-Bucket nichts erklärt.

Offen bis zur Planung: ob „Terminal öffnen" einen neuen Tab aufmacht oder
den aktiven benutzt, und was passiert, wenn die Sitzung bereits verbunden
ist. Beides beim Planen am Code messen, nicht raten.

## Nachtrag 2026-08-18: Die Snippet-Auswahl im Terminal (P3d)

Maintainer-Feedback nach dem Dev-Build. **Nicht** Teil von P3b oder P3c.

Die Auswahl im Terminal soll aufhören, eine Liste zu sein, die beim Klick
sofort etwas tut. Stattdessen:

- **Doppelklick auf eine Zeile** öffnet ein Fenster mit den Aktionen
  **Einfügen**, **Ausführen** und **Abbrechen** — die Entscheidung fällt
  also nach dem Sehen, nicht davor.
- **Beim Überfahren** zeigt die Zeile den Befehl, der laufen würde.
- **Kontextmenü auf jeder Zeile** mit Ausführen, Einfügen, Vorschau.

Der Grund dahinter ist derselbe wie bei „sofort ausführen" in Runde 2: ein
Klick, der einen Befehl auf einem entfernten Rechner startet, darf keine
Nebenwirkung eines Auswahlvorgangs sein.

### Nachtrag: Tastaturbedienung im Aktionsfenster

Das Kontextmenü der Zeile trägt **dieselben drei Möglichkeiten** wie das
Fenster. Und das Fenster bekommt Tastenkürzel auf allen drei Aktionen, damit
schnelles Arbeiten möglich bleibt — **Esc bricht ab**.

**Der Konflikt, der dabei zu entscheiden ist:** in einem macOS-Dialog löst
Return den Standardknopf aus. Läge Return auf „Ausführen", startete
Doppelklick + Return einen Befehl auf einem entfernten Rechner mit zwei
Anschlägen — und genau die Beiläufigkeit soll dieser Umbau ja beseitigen.
Ein Kürzel für „Ausführen" ist damit nicht ausgeschlossen, aber es sollte
eines sein, das man nicht versehentlich trifft. Beim Brainstorming
entscheiden, nicht im Vorbeigehen.

**Vor der Planung zu klären** (nicht raten, am Code und mit dem Maintainer):
was ein einfacher Klick dann noch tut; ob „Vorschau" dasselbe Fenster ohne
Aktionen ist oder etwas Eigenes; ob der Befehl beim Überfahren als Tooltip
oder als feste Zeile im Popover steht. Der Maintainer hat außerdem einen
Screenshot der heutigen Auswahl geschickt (Suchfeld, „Regex"-Kästchen,
Aufklappmenü) — der Ist-Zustand ist beim Planen **am Code zu messen**, nicht
aus dem Bild abzuleiten.

## Nachtrag 2026-08-18: Terminal-Protokoll (P3e)

Maintainer-Feedback nach dem Dev-Build. Eigene Phase, **nach** P3b.

Das Protokoll aus M9b (`AuditEvent`, `AuditLogStore`, Sheet) bekommt
Terminal-Ereignisse. Gemessen: `AuditEvent.Kind` kennt heute **keinen**
Shell-Fall — es wird erweitert, nicht neu gebaut.

**Maintainer-Entscheidung:** protokolliert werden Snippet-Ausführungen
**und** selbst getippte Befehle, letztere **über eine Einstellung
zuschaltbar**.

**Der Schutz gegen mitgeschriebene Passwörter kommt nicht aus einem
Textfilter**, sondern aus dem Zustand des Terminals: fordert die Gegenseite
eine verdeckte Eingabe an (Echo aus, wie bei `sudo`), schreibt das Protokoll
nur einen Vermerk („verdeckte Eingabe") und **den Inhalt gar nicht**.

Das ist die bessere Konstruktion, weil sie ein Signal benutzt statt zu
raten. Ein Muster-Filter, der 95 % erwischt, erzeugt Vertrauen, das die
restlichen 5 % nicht rechtfertigen — und die 5 % sind genau die Fälle, in
denen ein Passwort in einer Datei landet.

### Vor der Planung: Machbarkeit prüfen, nicht annehmen

**Offen und ausdrücklich ungeklärt:** ob die Client-Seite zuverlässig
erkennt, dass die Gegenseite das Echo abgeschaltet hat. Bei SSH schaltet
das entfernte PTY das Echo ab; der Client bekommt die Zeichen dann schlicht
nicht zurück. Ob SwiftTerm daraus einen belastbaren Zustand ableitet — über
die Terminal-Modi oder anders —, ist **am Code und an der Bibliothek zu
messen**, bevor irgendetwas geplant wird.

Fällt die Prüfung negativ aus, ist die Entscheidung neu zu treffen, statt
ersatzweise doch einen Musterfilter einzubauen. Die Rückfallmöglichkeiten
wären dann: nur Snippets protokollieren, oder getippte Befehle nur mit
einer ausdrücklichen Warnung im Einstellungstext.

Ebenfalls beim Planen zu klären: ob eine Zeile beim Absenden oder beim
Abschluss protokolliert wird, was mit einer Zeile passiert, die nie mit
Return endet, und ob das Protokoll pro Sitzung oder global gelesen wird.

## Nachtrag 2026-08-18: Export aus dem Kontextmenü, überall (P3f)

Maintainer-Feedback. Eigene Phase.

Exportieren soll nicht nur über Knöpfe in Sheets gehen, sondern **überall
über das Kontextmenü** — an der Zeile, an der man ohnehin steht.

**Vor der Planung am Code zu messen**, welche Listen heute exportierbare
Dinge zeigen und was ihr Kontextmenü bereits kann: Sitzungen und Gruppen in
der Sidebar, Login-Sets, Snippets, ggf. SSH-Schlüssel. Für jede Stelle ist
zu klären, ob „Exportieren" dort dasselbe meint wie der vorhandene Knopf
(Auswahl, Filter, Umfang) oder etwas Engeres — ein Kontextmenü an *einer*
Zeile legt „nur dieses eine" nahe, der Knopf im Sheet exportiert heute die
sichtbare Menge.

Diese Uneinheitlichkeit ist der eigentliche Entwurfspunkt der Phase und
gehört ins Brainstorming, nicht in einen Schnellschuss: „Exportieren" darf
an zwei Stellen nicht zwei verschiedene Umfänge bedeuten, ohne dass man es
sieht.
