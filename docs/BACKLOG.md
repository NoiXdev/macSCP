# macSCP — Backlog

**Stand:** 2026-08-28. Ein Index über die Einträge unter
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

## Sicherheit und Prüfbarkeit

| Eintrag | Kern |
|---|---|
| [Fähigkeitsgrenze statt Wächter](superpowers/specs/2026-08-22-backlog-verbindungs-fähigkeit.md) | **Umgesetzt 2026-08-28.** Entscheider sind Typen, der Wählvorgang ist modulintern — beides von außen gepflanzt und die Compile-Fehler belegt. Offen und benannt: `import Citadel` kompiliert in der App-Schicht (SwiftPM-Suchpfad), diese Lücke liegt unterhalb der Typen und hält Scan plus Import-Allow-List am Leben. |
| [Tests, die an echte Ablagen kommen](superpowers/specs/2026-08-22-backlog-testisolation.md) | `ContentView` verdrahtete Keychain und Sitzungs-Store fest. Ein Test hat dadurch in den echten Keychain geschrieben. Naht ist inzwischen da; der Eintrag hält die Regel und die Restfälle. |
| [Wie weit lässt sich die Oberfläche prüfen?](superpowers/specs/2026-08-21-backlog-ui-testabdeckung.md) | **Entschieden 2026-08-28: XCUITest vorerst gestrichen** — ein zweites Bausystem einzuziehen, solange das erste nicht ausgeliefert hat, verschiebt das Problem. Die Abwägung (Wächter / ViewInspector / XCUITest) bleibt nachlesbar; zurück holt es ein Fehler dieser Klasse, der einen Nutzer erreicht. |
| [Abbau gegen eine eingefrorene Gegenseite](superpowers/specs/2026-08-25-backlog-abbau-bei-eingefrorenem-peer.md) | **Gemessen 2026-08-28, Behebung in Arbeit.** `disconnect()` kam nicht zurück — betreten und nie verlassen innerhalb 120 s und 30 s; genau `sftp.close()` hing, `SSHClient.close()` nicht. Mit Frist: 5,05 s und der Tab wird `.lost` — **aber nur ohne offenes Terminal**. Mit Shell hängt `terminal.shutdown()` eine Stufe davor, `disconnect()` wird nie betreten (≥30 s, dreimal gemessen). Behoben: drei der vier Stufen begrenzt (`cancelAll` gemessen unnötig und zurückgenommen), Abbau mit Shell 10,3 s statt Hänger. Der unbegrenzte Aufruf ist zusätzlich **strukturell ausgeschlossen** (`BoundedSFTPSession`, sechs Verstöße gepflanzt, alle Compile-Fehler). |
| [Unbegrenzte Dateischlüsse](superpowers/specs/2026-08-28-backlog-unbegrenzte-dateischluesse.md) | Nebenbefund zweier Abbau-Messungen: **8** `SFTPFile.close()`-Stellen, keine begrenzt, mehrere auf einem Abbau-Pfad. **Kein bestätigter Fehler** — dieselbe Form wie zwei Aufrufe, die nachweislich hingen, aber der eine Pfad dorthin ist gemessen und kommt zurück. Zuerst messen, erst dann begrenzen. |
| [Zwei offene Fragen aus der Abschlussdurchsicht](superpowers/specs/2026-08-26-backlog-offene-fragen-durchsicht.md) | **S3-Hälfte gemessen und entwarnt 2026-08-28:** `Authorization` reist über keine Weiterleitung mit (10 Fälle, 2 Origin-Formen, 5 Statuscodes). Offen bleibt **M3** — ein noch nicht gewählter Sitzungsursprung wird einem ad-hoc-Fehlschlag zugeschrieben; entworfen in [2026-08-28-zwei-offene-fragen-design.md](superpowers/specs/2026-08-28-zwei-offene-fragen-design.md). |
| [S3 folgt Weiterleitungen ohne Kontrolle](superpowers/specs/2026-08-28-backlog-s3-weiterleitungen.md) | Was die Messung **nicht** entwarnt: die Weiterleitung wird gefolgt statt verweigert (die fremde Origin erfährt Bucket-Pfad und Endpunkt), der handgesetzte `Host` reist mit und ist danach falsch, und Foundation streift den Header auch bei gleicher Origin ab — eine legitime Anbieter-Weiterleitung käme unsigniert an. `URLSession.shared` kann keinen Delegate tragen; die Naht dafür existiert. **Entschieden: eigener Vorgang.** |

## Oberfläche

| Eintrag | Kern |
|---|---|
| [Sitzungen, Tabs, Seitenleiste](superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md) | **Sieben von elf Punkten erledigt** (A1, A2, B1, B2, B3, C1, C2, D4). Offen: verschachtelte Ordner **und** freie Sortierung als *ein* Vorgang (D1+D2), Suche im Baum (D3), Tags abschaltbar und als Filter (E1, E2). |
| [Verwaltungs-Sheets](superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md) | **Zwei von drei erledigt**, nachgeprüft am 2026-08-29: Spaltensortierung bei Known Hosts (`KnownHostsSorting`, `Table(sortOrder:)`) und Schnellfilter in allen vier Sheets. **Offen: das Drei-Punkte-Menü für Import/Export** — im Baum gibt es dafür heute nichts. Die zwei getroffenen Entscheidungen gelten weiter: **keine** Tabellen-Umstellung für Logins und Keys, und „Auswahl-Aktionen bleiben sichtbar, Datei-Aktionen wandern ins Menü". |
| [Feinschliff an den Reitern](superpowers/specs/2026-08-27-backlog-reiter-feinschliff.md) | **Erledigt 2026-08-27/28**, nachgeprüft am 2026-08-29: die Einfügemarke hebt den Zielreiter hervor (`TabStripView.dropTarget`), und das Umschalten Terminal ↔ Dateien hängt als `TabMenuEntry.pane(_:_:)` im Reiter-Menü, mit `PaneToggleState` als der einen Wahrheit. Zeiger bleibt, weil die Begründungen darin gelten. |
| [Snippet-Editor: Bedienung](superpowers/specs/2026-08-21-backlog-snippet-editor-bedienung.md) | Variablen ein- und ausklappbar samt Massenaktionen; Platzhalter beim Tippen vorschlagen. Der Baustein dafür (`NSTextView`) ist schon da. |
| [Prüfsummen für Dateien](superpowers/specs/2026-08-27-backlog-datei-hashes.md) | Hashes in der Datei-Info, für eine Auswahl, und als Tabellenspalte. Der Befund: **kein Protokoll dieser App liefert einen Datei-Hash im Vorbeigehen** — bei SFTP und WebDAV hieße eine Spalte, jede Datei des Verzeichnisses herunterzuladen, und S3s ETag ist bei Mehrteil-Uploads *kein* Dateihash. |
| [Snippet-Probelauf](superpowers/specs/2026-08-20-backlog-snippet-probelauf.md) | Zeigen, was tatsächlich gesendet würde — und damit zugleich der ehrliche Ausstieg aus der Sicherheitsprüfung, pro Snippet statt global. Enthält die gemessene Falle, dass eine einzeilige Präfix-Zuweisung `$VAR` zu früh expandiert. |

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
