# M11f — Ausgeblendete Importe (Design)

Datum: 2026-07-29 · Status: vom Maintainer freigegeben („ja los gehts")

## Ziel

Importierte Verbindungen aus `~/.ssh/config` sollen aus der Seitenleiste
verschwinden können, ohne dass macSCP die config-Datei anfasst. Der Rückweg
führt über ein eigenes Verwaltungs-Sheet (Maintainer-Entscheid 2026-07-29,
Variante „Eigenes Verwaltungs-Sheet" — konsistent mit Known Hosts und
Login-Sets).

## Ausgangslage

- `SSHConfigImporter.load(path:)` liest `~/.ssh/config` bei jedem Öffnen
  eines Fensters neu (`ContentView.task`), dedupliziert nach Alias
  (first-wins, ssh-Semantik) und sortiert alphabetisch.
- `SSHConfigHost` trägt `alias`, `hostName`, `user`, `port`,
  `identityFile` — keine Geheimnisse, keine ID außer dem Alias.
- Die Sidebar-Sektion IMPORTIERT zeigt sie rein lesend; ein Klick füllt das
  Formular, ohne zu verbinden. Es gibt heute kein Kontextmenü.
- `~/.ssh/config` ist strikt read-only — seit M3d eine bewusste Zusage.

## 1. Persistenz (Core)

`HiddenImportStore` nach dem Muster von `LoginSetStore`: eigene JSON-Datei
`hidden-imports.json` im selben Verzeichnis wie `sessions.json`, stateless,
atomare Writes, vorwärtskompatibles Containerformat (unbekannte Felder
überleben Schreibvorgänge nicht — aber eine ältere Datei ohne die Felder
lädt anstandslos).

Gespeichert wird ausschließlich der **Alias** — er ist die Identität, unter
der der Eintrag sowohl in der config als auch in der Seitenleiste steht.
Kein Host, kein Benutzer, kein Pfad: die Liste soll nicht zu einer zweiten,
veraltenden Kopie der config werden.

API: `allHidden() -> [String]`, `hide(_ alias: String)`,
`unhide(_ alias: String)`, `isHidden(_ alias: String) -> Bool`.
`hide`/`unhide` sind idempotent. Der Vergleich ist exakt (nicht
case-insensitiv): ssh behandelt `Host`-Aliase als exakte Zeichenketten, und
eine großzügigere Regel würde Einträge ausblenden, die der Nutzer nie
gemeint hat.

## 2. Filter + Waisen (Core, pur)

Eine reine Funktion trennt die geladenen Hosts in das, was die Seitenleiste
zeigt, und das, was das Sheet zeigt:

- **sichtbar**: alle Hosts, deren Alias nicht in der Ausblend-Liste steht.
- **ausgeblendet**: Aliase aus der Liste, die es in der config noch gibt.
- **verwaist**: Aliase aus der Liste, zu denen es in der config KEINEN Host
  mehr gibt (umbenannt oder gelöscht).

Die Trennung ist pur und ohne Dateizugriff testbar; das Laden bleibt in
`SSHConfigImporter`.

## 3. Bedienung (App)

- **Ausblenden**: Kontextmenü auf einer importierten Zeile → „Ausblenden".
  Der Eintrag verschwindet sofort; kein Bestätigungsdialog (der Vorgang ist
  verlustfrei und mit einem Klick umkehrbar).
- **Zurückholen**: Menü **Sitzungen ▸ Ausgeblendete Importe… (⌘⇧I)**.
  ⌘⇧I ist frei (belegt sind ⌘N, ⌘W, ⌘1–9, ⌘⇧., ⌘⇧K, ⌘⇧L, ⌘T, ⌘,).
  Der Menütitel trägt die Anzahl, solange etwas ausgeblendet ist — ohne
  diesen Hinweis wäre der Rückweg unauffindbar, sobald die Sektion
  IMPORTIERT komplett leer ist.
- **Sheet**: eine Zeile je ausgeblendetem Alias mit „Wieder einblenden".
  Verwaiste Einträge sind als solche gekennzeichnet („nicht mehr in
  ~/.ssh/config") und lassen sich ganz aus der Liste entfernen, damit dort
  nichts verrottet, das niemand mehr zuordnen kann. Leerzustand mit einem
  Satz, der erklärt, wie Einträge hierher kommen.
- Nach jeder Änderung aktualisiert sich die Seitenleiste sofort (der
  gelesene config-Bestand bleibt im Fenster-State, neu gefiltert wird ohne
  erneutes Lesen der Datei).

## 4. Was bewusst NICHT passiert

- Kein Schreiben in `~/.ssh/config` — in keiner Variante.
- Die Ausblend-Liste reist **nicht** im Sessions-Export (M9a) mit: sie
  gehört zu einer lokalen Datei auf genau diesem Rechner, nicht zu den
  Verbindungen. Auf einem anderen Rechner sähe dieselbe Liste willkürlich
  aus.
- Kein Ausblenden per Muster/Wildcard, keine Gruppen, kein Bearbeiten
  importierter Einträge (letzteres bliebe ein Widerspruch zur read-only-
  Zusage).
- Kein Audit-Eintrag: Ausblenden ist reine Anzeige-Einstellung ohne
  Sicherheitsrelevanz.

## 5. Tests

- Store: Roundtrip hide/unhide, Idempotenz beider Richtungen, leere Datei,
  fehlende Datei, unbekannte Felder in der Datei (Vorwärtskompatibilität),
  exakter (nicht case-insensitiver) Vergleich.
- Filter: sichtbar/ausgeblendet/verwaist über eine Tabelle von Fällen,
  inklusive „Alias umbenannt ⇒ alter Eintrag verwaist, neuer sichtbar".
- Reihenfolge der sichtbaren Hosts bleibt die der Importer-Sortierung.
- EN/DE-Kataloge: Key-Mengen identisch (der Parsing-Wächter aus M11d deckt
  das Format ab).

## 6. Aufteilung

T1 Core (Store + reine Trennfunktion) → T2 App (Kontextmenü, Sheet,
Menüeintrag mit Zähler, Verdrahtung, EN/DE) → T3 Abschluss.
KEIN Release.
