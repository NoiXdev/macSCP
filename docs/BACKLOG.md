# macSCP — Backlog

**Stand:** 2026-08-29. Ein Index über die Einträge unter
`docs/superpowers/specs/`, damit sie nicht einzeln gesucht werden müssen.
Jeder Eintrag dort ist eine **gesicherte Idee oder ein gemessener Befund**,
kein Entwurf — die Entwürfe entstehen erst beim Angehen.

Diese Datei enthält keine Inhalte, nur Zeiger. Wer etwas ändert, ändert es
im Eintrag und zieht hier höchstens die Zeile nach.

---

## Fehler

| | Eintrag | Kern |
|---|---|---|
| **B-1** | [Fehlerliste](superpowers/specs/2026-08-20-bugs.md) | Verbinden zu einem toten Host blockiert die App. Ursache gemessen: Citadels Frist steht auf 30 s und wurde nie übergeben. **Teilweise behoben** — die Frist wird inzwischen übergeben und der Aufbau ist abbrechbar; offen bleibt, ob der Hauptthread tatsächlich blockiert. |
| **B-2** | [SSH-Schlüsselformate](superpowers/specs/2026-08-31-backlog-ssh-schluesselformate.md) | Aus einem Fehlerbericht zu v1.3.0, und es sind **zwei** Dinge. Die Meldung „SSH key format is not supported (currently: OpenSSH ed25519)" meint „unterstützt wird ed25519" und liest sich als „dein ed25519 wird nicht unterstützt" — billig zu beheben und beantwortet zugleich, welcher Fall beim nächsten Bericht vorliegt. Dahinter: der Lader kann **nur** ed25519, RSA und ecdsa lassen sich verwalten, aber nicht verbinden. |
| **B-3** | [S3 ohne Bucket verbinden](superpowers/specs/2026-08-31-backlog-s3-ohne-bucket.md) | Aus demselben Bericht: ohne Bucket und Region lässt macSCP nicht verbinden. Vorschlag des Maintainers: beide leer → Buckets laden und als Startpunkt zeigen. **`ListBuckets` gibt es im Baum nicht**, die Region kann nicht leer bleiben (SigV4 signiert mit ihr), und eine Bucket-Ebene ist eine **zweite Art Verzeichnis** — andere Spalten, andere mögliche Aktionen. Der billige Teil (Regions-Vorgabe + erklärende Meldung) ist davon abtrennbar. |

## Sicherheit und Prüfbarkeit

| Eintrag | Kern |
|---|---|
| [Fähigkeitsgrenze statt Wächter](superpowers/specs/2026-08-22-backlog-verbindungs-fähigkeit.md) | **Umgesetzt 2026-08-28.** Entscheider sind Typen, der Wählvorgang ist modulintern — beides von außen gepflanzt und die Compile-Fehler belegt. Offen und benannt: `import Citadel` kompiliert in der App-Schicht (SwiftPM-Suchpfad), diese Lücke liegt unterhalb der Typen und hält Scan plus Import-Allow-List am Leben. |
| [Tests, die an echte Ablagen kommen](superpowers/specs/2026-08-22-backlog-testisolation.md) | `ContentView` verdrahtete Keychain und Sitzungs-Store fest. Ein Test hat dadurch in den echten Keychain geschrieben. Naht ist inzwischen da; der Eintrag hält die Regel und die Restfälle. |
| [Wie weit lässt sich die Oberfläche prüfen?](superpowers/specs/2026-08-21-backlog-ui-testabdeckung.md) | **Entschieden 2026-08-28: XCUITest vorerst gestrichen** — ein zweites Bausystem einzuziehen, solange das erste nicht ausgeliefert hat, verschiebt das Problem. Die Abwägung (Wächter / ViewInspector / XCUITest) bleibt nachlesbar; zurück holt es ein Fehler dieser Klasse, der einen Nutzer erreicht. |
| [Abbau gegen eine eingefrorene Gegenseite](superpowers/specs/2026-08-25-backlog-abbau-bei-eingefrorenem-peer.md) | **Erledigt 2026-08-29.** `disconnect()` kam gegen einen schweigenden Peer nie zurück; genau `sftp.close()` hing. Drei der vier Abbau-Stufen sind jetzt begrenzt — die vierte (`cancelAll`) wurde gemessen und die Frist darum wieder zurückgenommen, weil sie nichts fing und den synchronen Sweep kostete. Mit offener Shell: ≥31 s ohne Rückkehr vorher, 10,3 s und `.lost` nachher. Der unbegrenzte Aufruf ist zusätzlich **strukturell ausgeschlossen** (`BoundedSFTPSession`). |
| [Unbegrenzte Dateischlüsse](superpowers/specs/2026-08-28-backlog-unbegrenzte-dateischluesse.md) | Nebenbefund zweier Abbau-Messungen: **8** `SFTPFile.close()`-Stellen, keine begrenzt, mehrere auf einem Abbau-Pfad. **Kein bestätigter Fehler** — dieselbe Form wie zwei Aufrufe, die nachweislich hingen, aber der eine Pfad dorthin ist gemessen und kommt zurück. Zuerst messen, erst dann begrenzen. |
| [Zwei offene Fragen aus der Abschlussdurchsicht](superpowers/specs/2026-08-26-backlog-offene-fragen-durchsicht.md) | **S3-Hälfte gemessen und entwarnt 2026-08-28:** `Authorization` reist über keine Weiterleitung mit (10 Fälle, 2 Origin-Formen, 5 Statuscodes). Offen bleibt **M3** — ein noch nicht gewählter Sitzungsursprung wird einem ad-hoc-Fehlschlag zugeschrieben; entworfen in [2026-08-28-zwei-offene-fragen-design.md](superpowers/specs/2026-08-28-zwei-offene-fragen-design.md). |
| [S3 fährt auf der geteilten URL-Session](superpowers/specs/2026-08-29-backlog-s3-teilt-die-url-session.md) | **Erledigt 2026-08-29.** S3 hat eine eigene `ephemeral`-Session und gibt sie in `disconnect()` frei; der `.shared`-Vorgabewert an `URLSessionHTTPTransport.init` ist weg, vier Aufrufstellen nennen ihre Session. Die offene Messung ist beantwortet, und zwar ungünstig: `sendStreaming` cacht **identisch** — eine `max-age`-Antwort wurde einem zweiten Prozess samt Körper von Platte ausgeliefert. |
| [S3 folgt Weiterleitungen ohne Kontrolle](superpowers/specs/2026-08-28-backlog-s3-weiterleitungen.md) | **Erledigt 2026-08-29** (`9e96025`), erst baubar geworden, seit S3 eine eigene Session hat. Gleiche Origin wird neu signiert und gefolgt — was zugleich den Funktionsfehler behebt, dass eine legitime Weiterleitung unsigniert ankam; eine fremde Origin (Schema, Host **und** Port) wird abgelehnt, und die Meldung nennt beide Origins ohne Pfad. Der falsche `Host` fällt durch das Neusignieren weg. |

## Oberfläche

| Eintrag | Kern |
|---|---|
| [Sitzungen, Tabs, Seitenleiste](superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md) | **Vollständig erledigt** (elf von elf, abgeschlossen 2026-08-29). Zeiger bleibt, weil die Begründungen und die gemessenen Ausgangszustände darin gelten. |
| [Verwaltungs-Sheets](superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md) | **Vollständig erledigt** (2026-08-29): Punkte 1, 2, 3 und 5 umgesetzt, Punkt 4 verworfen. Der Facetten-Filter ist ein Steuerelement für drei Sheets, verkettet mit der Suche über einen prüfbaren Wert; die Werte kommen aus den Zeilen, und unter zwei Werten erscheint keine Auswahl. Nebenbei gefunden: **alle drei** Sheets trugen dieselbe stille Lüge — „ungefiltert" hieß „Suchfeld leer". Zeiger bleibt wegen der Begründungen, besonders Punkt 4. |
| [Feinschliff an den Reitern](superpowers/specs/2026-08-27-backlog-reiter-feinschliff.md) | **Erledigt 2026-08-27/28**, nachgeprüft am 2026-08-29: die Einfügemarke hebt den Zielreiter hervor (`TabStripView.dropTarget`), und das Umschalten Terminal ↔ Dateien hängt als `TabMenuEntry.pane(_:_:)` im Reiter-Menü, mit `PaneToggleState` als der einen Wahrheit. Zeiger bleibt, weil die Begründungen darin gelten. |
| [Snippet-Editor: Bedienung](superpowers/specs/2026-08-21-backlog-snippet-editor-bedienung.md) | **Erledigt 2026-08-30.** Variablen falten ohne gemerkten Zustand; eine fehlerhafte lässt sich nicht zuklappen, womit „alle zu" zu „zeig mir nur die Probleme" wird. Einfügen, Vervollständigung bei `{{`, und der Hinweis auf ein undeklariertes `{{NAME}}` — als **Anzeige**, nicht als Sendeverbot. **Offen geblieben:** ein `{{DB}}` für eine Umgebungsvariable ist genauso stumm und wird nicht gemeldet — ein Klick vom behobenen Fall entfernt, braucht einen eigenen Satz. |
| [Prüfsummen für Dateien](superpowers/specs/2026-08-27-backlog-datei-hashes.md) | **Punkte 1 und 2 erledigt 2026-08-31** (vier Aufgaben). Core bekam **keinen** `exec(String)`, sondern „berechne die Prüfsumme dieser Datei": `ChecksumCommandLine` hat einen `fileprivate init` und zwei Konstruktionsstellen im ganzen Paket. Ein Ergebnis ohne **Herkunft** ist nicht konstruierbar — belegt, indem die schwächere Bauart gepflanzt wurde und mit grüner Suite durchging. Ein Mehrteil-ETag sagt ausdrücklich, dass er **nicht** die Prüfsumme der Datei ist. **Offen: Punkt 3** (Tabellenspalte), dessen Frage 3 unbeantwortet ist, sowie kein Fortschritt innerhalb einer Datei und kein eigener Fall für „dieses Verfahren gibt es hier nicht". |
| [Snippet-Probelauf](superpowers/specs/2026-08-20-backlog-snippet-probelauf.md) | **Erledigt 2026-08-30** (vier Aufgaben). Der Probelauf zeigt den aufgelösten Befehl, die Sendeform, den Ablehnungsgrund und die Färbung — aus **einem** Wert, den beide Zugänge rufen (Ablehnung beim Auslösen, „Testen" im Editor). Das Kennzeichen pro Snippet gibt es zusätzlich; es kann **nicht** exportiert werden, weil die Ausfuhr einen eigenen Typ bekam, bevor das Feld existierte. Der eingesetzte Wert erreicht kein Protokoll, keinen Export und keine Fehlermeldung — auch keine Testfehlermeldung. |

## Neue Funktionen

| Eintrag | Kern |
|---|---|
| [FTP und SMB/AFP](superpowers/specs/2026-08-25-backlog-weitere-protokolle.md) | Zwei sehr verschiedene Hälften unter einem Wort. SMB/AFP spricht macOS bereits — es ginge um eine Einbindung, und die gewohnten TOFU-Zusagen haben dort keine Entsprechung. FTP bräuchte zuerst eine Entscheidung über Bibliothek und Spielart, denn nacktes FTP überträgt Zugangsdaten im Klartext. **Nicht zusammen angehen.** |
| [Werkzeuge zum Untersuchen einer Verbindung](superpowers/specs/2026-08-25-backlog-verbindungswerkzeuge.md) | Ping und Trace pro Verbindung, auch ohne gespeicherten Host. Die offene Frage ist, was beides hier heißen soll — ein Protokoll von macSCPs eigenem Aufbau ist vermutlich nützlicher als ein Traceroute und braucht keine erhöhten Rechte. |

## Werkzeug und Wartung

| Eintrag | Kern |
|---|---|
| [CLI: Vervollständigung, Hilfe, Host-Liste](superpowers/specs/2026-08-20-backlog-cli-completion-hosts.md) | Die Host-Auflistung fehlt ganz und ist zugleich die Datenquelle für die Vervollständigung — deshalb zuerst. Auflage: die Liste fasst den Keychain nicht an. |
| [Abhängigkeiten](superpowers/specs/2026-08-20-backlog-abhaengigkeiten.md) | swift-nio-ssh kommt als **Fremd-Fork** über Citadel herein — der eigentliche Befund. Dazu: SwiftTerm hängt an einer nackten Revision, swift-crypto ist zwei Hauptversionen zurück. |
| [Keep-alive als zwei Einstellungen](superpowers/specs/2026-08-25-backlog-keepalive-zwei-einstellungen.md) | Ein gespeicherter Wert trägt „aus" und „Intervall" zugleich; das Intervall überlebt keinen Neustart. Ursache war eine falsche Vorgabe im Auftrag, nicht die Umsetzung. |
| [Import-Planer](superpowers/specs/2026-08-19-backlog-import-planer.md) | Halb gefüllte Feldtaschen beim Import. Vor dem Angehen prüfen, wie viel davon der Snippet-Zweig bereits erledigt hat. |

---

## Erledigt (Zeiger bleiben, damit die Begründungen auffindbar sind)

| Eintrag | |
|---|---|
| [Swift-6-Warnungen](superpowers/specs/2026-08-19-backlog-swift6-warnungen.md) | erledigt 2026-08-26: alle sechs Targets auf `.v6`, warnungsfrei, CI-Schranke bewiesen rot und grün |
| [Snippet-Editor Teil 3: deklarierte Variablen](superpowers/specs/2026-08-19-backlog-snippet-teil-3.md) | umgesetzt, zehn Prüfrunden |
| [M6a Polish-Backlog](superpowers/specs/2026-07-26-m6a-polish-backlog-design.md) | Meilenstein abgeschlossen |
| [M11e Backlog-Sweep](superpowers/specs/2026-07-29-m11e-backlog-sweep-design.md) | Meilenstein abgeschlossen |

---

## Wenn du nicht weißt, womit anfangen

Drei Kandidaten, aus unterschiedlichen Gründen:

1. **Einfachklick verbindet nicht mehr** — eine Zeile, spürbar bei jeder Benutzung, und das Kontextmenü hat den Weg schon.
2. **Known-Hosts-Spaltensortierung** — fast geschenkt, weil das Sheet bereits eine `Table` ist.
3. **Die Fähigkeitsgrenze** — der einzige Eintrag, der eine wiederkehrende Fehlerklasse beendet statt ihren nächsten Fall zu behandeln.
