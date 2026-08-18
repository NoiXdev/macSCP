# Snippets Runde 2 + Entkernung der App-Schicht (Design)

**Stand:** 2026-08-10. Anlass ist das Maintainer-Feedback nach dem ersten
Dev-Build der Terminal-Snippets (`1.2.0-dev`, Build 891).

## Der Befund

Der erste Wurf war benutzbar für jemanden, der den Code kennt, und
unauffindbar für alle anderen. Die Frage des Maintainers lautete wörtlich
„wo führe ich Snippets bei einem Host aus????" — und die Antwort war: nur
über die Menüleiste unter „Terminal", sonst nirgends. Das war meine
Empfehlung im ersten Brainstorming und sie war zu schmal.

Dazu kam ein Einwand gegen die Kennzeichnung „sofort ausführend": die
Entscheidung fällt beim **Anlegen**, wirkt aber beim **Auslösen**, wo der
Host feststeht und sichtbar ist. Der erste Entwurf hat das mit Gruppierung
im Menü abgefedert; das reicht nicht.

## Die Auflösung: Ausführen zieht um

Das Häkchen verschwindet aus dem Snippet. An seine Stelle treten **zwei
Aktionen an jeder Auslösefläche**: „Einfügen" und „Ausführen". Damit fällt
die scharfe Entscheidung dort, wo der Kontext sichtbar ist, und ein Snippet
ist wieder das, was es sein sollte: Text.

Das ist strenger als der Ist-Zustand, nicht lockerer. Heute kann ein
Snippet unbemerkt scharf sein; danach muss jede Ausführung angeklickt
werden.

## Der Schnitt

Das Feedback umfasst elf Punkte — drei am Datenmodell, vier am
Fensterlayout, der Rest an Auslöseflächen. Das ist kein Meilenstein,
sondern fünf Phasen, von denen zwei (P2, P3) hier nur skizziert sind:

| Phase | Inhalt | Warum diese Reihenfolge |
|---|---|---|
| **PV** | Vorversuch: Lassen sich SwiftUI-Views in diesem Paket überhaupt testen? | Das Ergebnis entscheidet, wie P0 aussieht — und die Frage wird beantwortet, nicht geraten |
| **P0** | Entkernung von `ContentView`: Unter-Views in eigene Dateien, reine Logik nach Core mit Tests | P1 fügt Kopfzeile, Popover und Kontextmenü hinzu — die landen sonst **in** dem Klotz und machen ihn größer |
| **P1** | Snippets erreichbar: Flag weg → zwei Aktionen, Tags, Kontextmenü am Host, Terminal-Kopfzeile mit Popover, Rechtsklick im Terminal | beantwortet den eigentlichen Befund |
| **P2** | Terminal-Fassung: Rand, eigener Terminal-Tab-Typ, Umschalter für die Dateipanes | Layout-Arbeit, ohne Bezug zu Snippets |
| **P3** | Ordnung: Host-Tags am `StoredSession` + Sidebar-Filter, Import/Export der Snippets | zuletzt, weil P1 erst zeigt, wie sich Tags anfühlen, bevor sie ein zweites Mal ans Session-Modell wandern |

Der **Massen-Runner** (Snippet auf n gefilterte Hosts, Ausgabe-Ansicht) ist
ausdrücklich **nicht** Teil davon. Er ist ein eigenes Werkzeug — n parallele
Verbindungen, Teilfehler, Abbruch, n Ausgabeströme lesbar halten — und
bekommt sein eigenes Brainstorming. P3s Host-Filter ist die Auswahlmechanik,
auf der er später aufsetzt.

---

## PV — Vorversuch: sind Views testbar?

**Die Frage.** Die App-Schicht ist heute ungetestet — das ist die Grenze,
die M29 offengelegt hat, und sie hat in Runde 1 drei Fehler durchgelassen.
Bevor eine weitere Phase diese Grenze als gegeben hinnimmt, wird sie
geprüft.

**Was zu klären ist**, in dieser Reihenfolge:

1. Lässt sich ein SwiftUI-View aus `MacSCPAppKit` in `macSCPAppKitTests`
   überhaupt instanziieren und auf seinen Inhalt hin untersuchen — sei es
   per Hierarchie-Inspektion oder per gerendertem Abbild?
2. Verträgt sich das mit **Swift Testing** (`@Test`/`#expect`)? Die
   verbreiteten Werkzeuge sind XCTest-orientiert; ob beides im selben
   Target koexistiert, ist offen.
3. Läuft es in **CI ohne GUI-Sitzung**? Ein Werkzeug, das nur lokal
   funktioniert, verschiebt das Problem, statt es zu lösen.
4. Was kostet es an Abhängigkeiten? Das Paket hat heute wenige, und eine
   Test-Abhängigkeit, die eine Toolchain-Version bindet, ist teuer.

**Zeitlich begrenzt.** Der Vorversuch ist ein Versuch, kein Meilenstein: er
endet mit einem Ja **samt lauffähigem Beispieltest an einem echten View
dieses Projekts** oder mit einem belegten Nein samt Grund. Ein „geht
wahrscheinlich" ist kein Ergebnis.

**Das Ergebnis ist eine Weiche, keine Vorgabe.** Fällt es positiv aus,
entscheidet der Maintainer, ob P0 die Views mit abdeckt. Fällt es negativ
aus, gilt für P0 die Alternative: so viel Entscheidungslogik wie möglich
nach Core, sodass in den Views nur noch Zeichnen übrig bleibt.

Diese Spec legt sich bewusst **nicht** darauf fest, dass View-Tests möglich
sind. Runde 1 hat vorgeführt, was eine ungeprüfte Annahme in einer Spec
kostet: dort stand `\n`, und richtig war `0x0D`.

---

## P0 — Entkernung der App-Schicht

### Der Ausgangszustand, gemessen

| Datei | Zeilen |
|---|---|
| `ContentView.swift` | 3464 (davon ~3330 in **einer** `View`-Struktur ab `struct ContentView`) |
| `SettingsView.swift` | 1306 |
| `RemoteFileTableView.swift` | 1050 |
| `LoginSetsSheet.swift` | 1048 |
| `ConnectionFormView.swift` | 1001 |
| **App-Schicht gesamt** | 15 909 |

Ein Fünftel der App-Schicht liegt in einer Datei. Nur `ContentView` ist
Gegenstand dieser Phase; die anderen vier bleiben, wo sie sind.

### Zwei Sorten Arbeit, bewusst in einer Phase

**Aufteilen** verschiebt Zeilen und macht sie lesbar. **Herausziehen** macht
sie prüfbar. Nur das zweite hat bleibenden Wert — es ist genau die Linie,
die M29-P2 mit dem Submit-Pfad gezogen hat, wo M28s Critical danach zum
ersten Mal durch einen Test gehalten war.

Kandidaten für den Umzug nach Core sind alles, was eine **Entscheidung**
trifft statt etwas zu zeichnen: welche Warnmeldung erscheint, wann ein
Kommando auf ein Backend ohne Shell trifft, welcher Weg zum externen
Terminal genommen wird, welcher Zustandsübergang auf ein Ereignis folgt.

**Die Liste der Extraktionen ist eine Hypothese, keine Vorgabe.** Der Plan
vermisst die Datei und benennt die tatsächlichen Schnitte; diese Spec legt
nur fest, wonach gesucht wird.

### Die Zusicherung

**Beim Aufteilen ändert sich kein Verhalten.** Beim Herausziehen ändert
sich Struktur *und* es entstehen Tests — ein Umzug nach Core ohne Test ist
kein Umzug, sondern eine Verschiebung.

### Die Gegenmaßnahme gegen die eigentliche Gefahr

Views sind in diesem Projekt nicht getestet (die Grenze aus M29), und die
gefährlichste Fehlerklasse ist das stille Schlucken: ein `@State`, das beim
Verschieben in die falsche Struktur wandert, bricht nichts sichtbar — es
hört nur auf zu aktualisieren, und **kein Test wird rot**.

Deshalb: **kleine, einzeln committete Schritte**, je Extraktion Build plus
volle Suite. Ein `git bisect` findet dann den Schuldigen, statt dass ein
3000-Zeilen-Diff am Stück beurteilt werden muss. Ein Dev-Build am Ende der
Phase ist Pflicht, und der Abschlussbericht sagt ausdrücklich, dass die
Sichtprüfung beim Maintainer liegt.

---

## P1 — Snippets erreichbar

### Modell

```swift
public struct Snippet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var tags: [String]
}
```

`runsImmediately` entfällt.

### Migration bestehender Stores

Beim Dekodieren einer `snippets.json` aus dem ersten Wurf:

- `runsImmediately` wird **ignoriert**. Ein bisher als ausführend
  markiertes Snippet wird zu einem gewöhnlichen. Information geht verloren,
  und zwar bewusst — die Markierung war das, was entfallen sollte.
  Ausführen bleibt möglich, nur pro Auslösung.
- `tags` fehlt und wird zur leeren Liste.

Die vorhandene Ablehnung eingebetteter Zeilenumbrüche (`\n`, `\r`) im
Kommando bleibt unverändert und bleibt eine **Modellregel**, die auch für
eine von Hand bearbeitete Datei gilt.

### Tag-Regel (Maintainer-Entscheidung 2026-08-10)

- **Nur trimmen.** Leerraum außen fällt weg; Groß-/Kleinschreibung bleibt
  erhalten, wie getippt.
- Ein Tag, der nach dem Trimmen leer ist, wird abgelehnt.
- **Exakte** Dubletten am selben Snippet fallen weg. `Docker` und `docker`
  sind zwei verschiedene Tags und bleiben beide erhalten — das ist die
  Folge der Entscheidung und wird nicht heimlich abgeschwächt.
- Die Regel hängt am Modell, nicht am Formular, und gilt damit auch für
  eine von Hand bearbeitete Datei.
- **Die Reihenfolge bleibt, wie eingegeben.** `tags` ist eine Liste, keine
  Menge; sortiert wird erst bei der Anzeige.

**Gedämpft wird die Dublettengefahr an der Eingabe, nicht am Speicher:** die
Vorschlagsliste sucht **ohne Rücksicht auf Groß-/Kleinschreibung**. Wer
`doc` tippt, bekommt ein vorhandenes `Docker` angeboten und greift es,
statt ein zweites anzulegen. Gespeichert wird trotzdem exakt das Getippte.

### Das Tag-Eingabefeld

Token-Feld statt Freitext: jeder gesetzte Tag ist ein Chip mit
Entfernen-Knopf. Beim Tippen öffnet sich eine Vorschlagsliste mit den
vorhandenen Tags samt Anzahl; der **letzte Eintrag ist immer**
„*x* als neuen Tag anlegen". Ein neuer Tag entsteht so nie versehentlich —
genau dort entstehen sonst die Dubletten.

Dasselbe Feld wird in P3 für Host-Tags wiederverwendet.

### Filter im Verwaltungs-Sheet

Eine Chip-Zeile unter dem vorhandenen Suchfeld: „Alle" plus je ein Chip pro
Tag mit Anzahl, dazu ein Chip „ohne Tag" — sonst werden genau die Snippets
unauffindbar, die noch nicht einsortiert sind.

**Einwertig, nicht mehrwertig.** Ein Chip zur Zeit. Mehrfachauswahl bräuchte
eine Und/Oder-Semantik, die niemand verlangt hat; wenn der Massen-Runner
sie später braucht, ist das seine Entscheidung.

### Die Bytes

`SnippetKeystrokes.bytes(for:execute:)` — das Flag wandert vom Snippet an
den Aufruf. Das in Runde 1 **gemessene** `0x0D` (CR, was die Eingabetaste
über SwiftTerms `insertNewline` → `EscapeSequences.cmdRet` tatsächlich
schickt) bleibt unverändert und bleibt gepinnt.

**Einfügen hängt niemals ein Zeilenende an**, unabhängig vom Aufrufer. Das
ist eine Zusicherung mit Test, kein Aufrufer-Detail.

### `SnippetMenuModel` (Core)

Ein Typ, vier Flächen. Eingabe: die Snippets, ein optionaler Tag-Filter,
der Verbindungszustand. Ausgabe: die fertige Struktur — Gruppen je Tag
(Snippets ohne Tag zuletzt), pro Eintrag Titel und die zwei Aktionen, und
im deaktivierten Fall der Grund.

Der Grund für einen Typ statt vier Ableitungen: die App-Schicht ist
praktisch nicht testbar, Core vollständig — und das Projekt hat die Lektion
schon bezahlt, dass **zwei Codestellen, die dieselbe Frage beantworten,
auseinanderdriften**. Bei vier wäre es schlimmer.

`SnippetsLoad` bleibt unverändert erhalten: ein **unlesbarer** Store darf
nie wie ein **leerer** aussehen.

### Die vier Auslöseflächen

| Fläche | Inhalt |
|---|---|
| Menüleiste „Terminal" | Untermenü je Tag statt flacher Liste. ⌃⌘1–3 **fügen** die ersten drei Snippets in Speicherreihenfolge ein |
| Kontextmenü am Host (Sidebar) | Eintrag „Snippet" mit denselben Gruppen |
| Terminal-Kopfzeile | Host links, Snippet-Knopf rechts, Popover mit Suchfeld und Gruppen |
| Rechtsklick im Terminal | dieselben Einträge |

**Ausführen bekommt kein Tastenkürzel.** Ein Tastendruck, der sofort auf
einem Host läuft, hat keinen guten Fehlerfall.

Deaktiviert wird überall mit der Bedingung, die die beiden vorhandenen
Terminal-Einträge schon benutzen
(`!isActiveTabConnected || !activeTabSupportsShell`); am Host-Kontextmenü
entsprechend über `BackendDescriptor…capabilities.supportsShell`, sodass
S3- und WebDAV-Sitzungen den Eintrag grau zeigen statt ins Leere zu laufen.

Der **Shortcuts-Katalog aus M11q wird mitgepflegt** — er ist von Hand
gewartet und sein eigener Doc-Kommentar nennt das als Pflicht.

### Was gemessen werden muss, statt angenommen zu werden

1. **Belegt SwiftTerm den Rechtsklick bereits?** Üblicherweise mit
   „Einfügen". Wenn ja, wird sich an das vorhandene Menü angehängt, nicht
   überschrieben. Der Implementierer stellt das fest und hält das Ergebnis
   fest.
2. **Wie viel Rand hat das Terminal-Panel heute tatsächlich?** Die Zahl
   wird gemessen, nicht geschätzt — und erst in P2 geändert.

Diese Spec legt sich bei beidem bewusst nicht fest. Runde 1 hat gezeigt,
was das kostet: dort stand `\n` in der Spec, und richtig war `0x0D`.

---

## P2 — Terminal-Fassung (entschieden 2026-08-12)

Der ursprüngliche Entwurf sah einen **eigenen Terminal-Tab-Typ** vor
(„Nur Terminal öffnen" baut nur eine Shell auf, kein SFTP). **Verworfen.**
Zwei Gründe, der zweite ist der bessere:

1. Meine Beschreibung war zu optimistisch. Der Verbindungsaufbau liefert
   ein `RemoteFileSystem` — **das Dateisystem ist die Verbindung**;
   `BrowserSession` wird in einem Zug daraus gebaut und das Terminal hängt
   als Kindkanal daran. Eine Sitzung ohne SFTP wäre eine Änderung daran,
   was „verbunden" heißt, nicht ein Flag.
2. Der Maintainer-Vorschlag ist einfacher **und** deckt mehr ab: die
   Sichtbarkeit beider Hälften wird in der Toolbar geschaltet, wo der
   Terminal-Schalter (⌘T) und der Übertragungen-Schalter schon sitzen.
   Ein reines Terminal ist dann kein Tab-**Typ**, sondern ein **Zustand**,
   den jeder Tab annehmen und wieder verlassen kann.

### Was gebaut wird

- **Rand ums Terminal: 14 horizontal / 8 vertikal.** Gemessen: das Terminal
  sitzt heute **bündig ohne jeden Rand**, während die Panes und der
  `.ended`-Textblock im selben Panel bereits 14/8 benutzen. Der Wert ist
  also der vorhandene Rhythmus, nicht ein erfundener. Die in P1 gebaute
  Kopfzeile benutzt 12/6 und wird mit angeglichen, damit Kopfzeile und
  Terminalfläche nicht um zwei Punkt auseinanderliegen.
- **Ein zweiter Toolbar-Schalter „Dateien"** neben dem vorhandenen
  „Terminal". Beide schalten die Sichtbarkeit ihrer Hälfte.
- **Der letzte aktive Schalter ist gesperrt** — beide aus ergäbe ein leeres
  Fenster. Er wird sichtbar deaktiviert, nicht stillschweigend wirkungslos.
- **Ohne Shell gibt es keinen Terminal-Schalter** (S3, WebDAV): er bleibt
  grau, „Dateien" ist damit der einzige und folglich gesperrt.

### Der Zustand überlebt — pro gespeicherter Sitzung

**Maintainer-Entscheidung 2026-08-12.** `prod-web` öffnet sich künftig so,
wie es zuletzt stand. Das ist die nützlichste der drei Varianten (die
anderen waren: gar nicht merken, oder ein globaler Standard) — aber es hat
eine Konsequenz, die hier stehen muss statt später zu überraschen:

**Es wandert ins `StoredSession`-Format und damit in Export/Import.** Seit
M23-P3 ist das Format ein Feldbeutel, der Zusatzfelder ohne Migration
verträgt, und der Import-Arbiter behandelt unbekannte Felder bereits. Es
ist also kein Formatbruch — aber es ist auch **kein reiner View-Umbau
mehr**, und die Export-Roundtrip-Tests müssen es mittragen.

Ein eigenes Fenster bleibt ausgeschlossen: Mehrfenster ist laut
Projektregel erst v2.

## P3 — Ordnung (Skizze)

- **Host-Tags** am `StoredSession`: Feld im Formular, in Export/Import
  mitgeführt, Filter in der Sidebar. Gruppen aus M5f bleiben die Ablage,
  Tags werden die Sicht darauf — sie ersetzen einander nicht.
- **Kein Zusammenhang zu Snippet-Tags.** Ein Host-Tag versteckt kein
  Snippet; die beiden Vokabulare sind unabhängig. Die Bindung („Snippet mit
  Tag `docker` erscheint nur an Hosts mit `docker`") ist ausdrücklich
  abgelehnt.
- **Import/Export der Snippets** über die Envelope-Maschinerie aus M19.
  Snippets enthalten keine Secrets; das Format braucht deshalb keinen
  Krypto-Pfad, wohl aber denselben Konflikt-Arbiter.

---

## Snippets enthalten weiterhin keine Zugangsdaten

Unverändert gegenüber Runde 1, und der Grund bleibt derselbe: der Store ist
JSON, und Secrets leben ausschließlich im Schlüsselbund. Die drei beim
ersten Brainstorming vorgebrachten Gegenvorschläge (passwortloses SSH,
History nachträglich löschen, eigene Shell statt Login-Shell) sind mit
Begründung in
`docs/superpowers/specs/2026-08-10-terminal-snippets-design.md` abgelehnt.

Wer echte Zugangsdaten im Terminal braucht, bekommt sie über
**Agent-Forwarding** — eigener Meilenstein, im Backlog seit M10d.

Der Import/Export in P3 ändert daran nichts: ein Format ohne Secrets
braucht keine Verschlüsselung, und es wird keine hineinerfunden, die
Sicherheit nur vortäuscht.

---

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Eine `snippets.json` aus Runde 1 lädt; `runsImmediately` verschwindet, `tags` ist leer | Test gegen eine wörtliche Alt-Datei |
| 2 | Einfügen hängt **nie** ein Zeilenende an, Ausführen genau eines (`0x0D`) | Test über die erzeugten Bytes, beide Aufrufarten |
| 3 | Ein Tag wird getrimmt, leer abgelehnt, exakte Dubletten fallen weg, Groß/Klein bleibt | Test, auch für einen von Hand geschriebenen Store |
| 4 | Die Vorschlagsliste findet `Docker` bei Eingabe `doc` | Test am Vorschlags-Matcher |
| 5 | `SnippetMenuModel` gruppiert nach Tags, Untagged zuletzt, und liefert den Deaktiviert-Grund | Test |
| 6 | Ein unlesbarer Store sieht nicht wie ein leerer aus | vorhandener Test bleibt grün |
| 7 | Alle vier Auslöseflächen zeigen dieselben Einträge | Review — sie lesen aus **einem** Modell, das ist der Nachweis im Code |
| 8 | Ohne verbundene Sitzung bzw. ohne Shell sind die Einträge deaktiviert | Review; App-seitig |
| 9 | P0 ändert kein Verhalten | volle Suite je Schritt + Dev-Build; **Sichtprüfung liegt beim Maintainer** |
| 10 | Alle vier Kataloge tragen die neuen Schlüssel | vorhandener Wächtertest, `plutil -lint` |
| 11 | Der Shortcuts-Katalog nennt die Kürzel korrekt | Review gegen den Katalog |
| 12 | PV endet mit einem lauffähigen Beispieltest an einem echten View **oder** einem belegten Nein | der Test läuft, oder der Bericht nennt den Grund — „wahrscheinlich" zählt nicht |

## Prüfbarkeit, ehrlich

Modell, Migration, Tag-Regel, Vorschlags-Matcher, `SnippetMenuModel` und
die Byte-Erzeugung liegen in Core und werden vollständig gepinnt.

**Die vier Auslöseflächen selbst bleiben ungepinnt — vorbehaltlich PV.**
Fällt der Vorversuch positiv aus und entscheidet der Maintainer, das
Werkzeug einzuführen, ändert sich dieser Absatz; bis dahin gilt er.

Es ist dieselbe Grenze wie zuletzt — und sie hat in Runde 1 drei Fehler
durchgelassen, die erst die Gesamt-Review fand: das falsche Abschluss-Byte,
verworfene Bytes vor dem Öffnen der Shell und ein `try?`, das einen
unlesbaren Store von einem leeren ununterscheidbar machte. Keiner davon
hätte einen Test rot gemacht.

Der Abschlussbericht sagt das wieder ausdrücklich, statt Sichtprüfungen als
Nachweis auszugeben. Kriterien 7, 8 und 9 sind Review-Punkte, keine Tests.

## Was ausdrücklich **nicht** dazugehört

- **Der Massen-Runner** über gefilterte Hosts samt Ausgabe-Ansicht —
  eigenes Brainstorming, eigener Meilenstein.
- **Mehrzeilige Kommandos und Syntax-Hervorhebung.** Beides ergibt erst mit
  dem Runner einen ehrlichen Ort: solange „einfügen" der Normalfall ist,
  liefe bei einem mehrzeiligen Snippet alles bis auf die letzte Zeile
  sofort los, ohne dass jemand die Eingabetaste gedrückt hätte.
- **Platzhalter** (`{{pfad}}`, aktuelles Verzeichnis).
- **Bindung von Snippets an Hosts, Gruppen oder Protokolle.**
- **Agent-Forwarding.**
- **Mehrfenster** (v2).
- `SettingsView`, `RemoteFileTableView`, `LoginSetsSheet` und
  `ConnectionFormView` — P0 fasst nur `ContentView` an.

## Für die Release-Notes

**Ein Satz.** Snippets lassen sich mit Tags ordnen und direkt am Host oder
im Terminal einfügen oder ausführen.
