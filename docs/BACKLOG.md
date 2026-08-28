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
| [Wie weit lässt sich die Oberfläche prüfen?](superpowers/specs/2026-08-21-backlog-ui-testabdeckung.md) | Vier belegte Fälle, die kein Test dieses Projekts sehen kann. Abwägung zwischen Wächtern, ViewInspector und XCUITest — mit der Empfehlung, XCUITest als eigenes Vorhaben zu terminieren. |
| [Abbau gegen eine eingefrorene Gegenseite](superpowers/specs/2026-08-25-backlog-abbau-bei-eingefrorenem-peer.md) | Ob `disconnect()` gegen einen nie antwortenden Peer zurückkommt, ist ungeprüft. Kommt es nicht zurück, wird der Zustand „verloren" nie geschrieben. |
| [Zwei offene Fragen aus der Abschlussdurchsicht](superpowers/specs/2026-08-26-backlog-offene-fragen-durchsicht.md) | Beide nur begründet, nicht gemessen: ein noch nicht gewählter gespeicherter Sitzungsursprung kann einem ad-hoc-Fehlschlag zugeschrieben werden (kosmetisch); ob S3s handgesetzter `Authorization`-Header eine Redirect-Origin-Grenze übersteht, ist ohne Netzversuch offen. |

## Oberfläche

| Eintrag | Kern |
|---|---|
| [Sitzungen, Tabs, Seitenleiste](superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md) | **Sechs von elf Punkten erledigt** (A1, A2, B1, B2, B3, C1, D4). Offen: „Sitzung ist schon offen“ (C2), verschachtelte Ordner **und** freie Sortierung als *ein* Vorgang (D1+D2), Suche im Baum (D3), Tags abschaltbar und als Filter (E1, E2). |
| [Verwaltungs-Sheets](superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md) | Spaltensortierung bei Known Hosts (fast geschenkt, ist schon eine `Table`), Schnellfilter, Drei-Punkte-Menü für Import/Export. Enthält zwei getroffene Entscheidungen: **keine** Tabellen-Umstellung für Logins und Keys, und die Regel „Auswahl-Aktionen bleiben sichtbar, Datei-Aktionen wandern ins Menü". |
| [Feinschliff an den Reitern](superpowers/specs/2026-08-27-backlog-reiter-feinschliff.md) | Aus der Maintainer-Prüfung: **sichtbare Einfügemarke beim Ziehen** (billig, wenn sie den Zielreiter hervorhebt — ein Einfügestrich zwischen Reitern holt die gerade entfernte Positionsrechnung zurück) und **Umschalten Terminal ↔ Dateien** aus dem Reiter-Menü. Der zweite Punkt landet auf der Naht, die `PaneVisibility` ausdrücklich offengelassen hat: zwei Wahrheiten über „ist das Terminal sichtbar". |
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
