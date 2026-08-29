# Backlog: Verwaltungs-Sheets — Filter, Sortierung, Platz

**Angelegt:** 2026-08-20, aus Maintainer-Zuruf. Gesicherte Ideen, **kein Design**.
Fünf Punkte, davon vier klein und einer eine offene Grundsatzfrage.

## Ausgangslage, gemessen

| Sheet | Zeilen | Darstellung | Buttons |
|---|---|---|---|
| `KnownHostsSheet` | 238 | **`Table`**, 6 Spalten | 6 |
| `AuditLogSheet` | 287 | **`Table`**, 3 Spalten | — |
| `HiddenImportsSheet` | 191 | `List` | — |
| `LoginSetsSheet` | 1024 | `List` (+ 1 `Table`) | 23 |
| `SSHKeysSheet` | 878 | `List`, **kein `Table`** | 25 |

Vorhandene Bausteine: `SheetSearchField` (M18, Text + Regex-Umschalter,
Prädikat über `FileSearch.compile`) in vier Sheets; die parametrisierte
Sortierung aus M11l/M11m sitzt in der Dateitabelle, nicht in den Sheets.

## 1. Sitzung über das Kontextmenü duplizieren

In der Seitenleiste, neben Umbenennen/Löschen. Offen und vor dem Design zu
klären: Was passiert mit dem **Secret** — die duplizierte Sitzung zeigt auf
denselben Keychain-Eintrag, oder auf gar keinen? Und was mit einer
**Login-Set-Bindung** (M11a) und der Gruppenzugehörigkeit? Der Kopiername
braucht eine Regel, die mit `duplicateKey` aus dem Importpfad zusammenpasst,
statt einer zweiten Namensarithmetik daneben.

## 2. Schnellfilter unter der Suche

Ein Typ-Filter unterhalb von `SheetSearchField` in Known-Hosts, SSH-Keys und
Logins. Die Facetten sind je Sheet andere — Schlüsseltyp bei Keys,
Backend-Art bei Logins, Algorithmus bei Known-Hosts. Zu entscheiden: ein
gemeinsames Steuerelement mit übergebenen Facetten, oder drei eigene. Wenn
gemeinsam, gehört es neben `SheetSearchField` und teilt dessen Prädikat-Form,
damit Suche und Filter sich verketten statt zu konkurrieren.

### Gebaut am 2026-08-29 — der letzte offene Punkt des Eintrags

Entschieden und umgesetzt nach
`docs/superpowers/specs/2026-08-29-sheet-facetten-filter-design.md`: **ein
gemeinsames Steuerelement** (`SheetFacetPicker`), dem die Facetten übergeben
werden, über einem gemeinsamen Wert (`SheetFacetFilter` /
`SheetNarrowing` in Core). Die Verkettung von Suche und Facette ist eine
Funktion, die einmal geschrieben und aus den drei Sheets gerufen wird;
`SheetSearchField` selbst blieb unberührt.

Die Facettenwerte kommen aus den Zeilen, nicht aus einer Aufzählung — hat ein
Sheet nur einen Wert, erscheint gar keine Auswahl. Der Leerzustand
(`SheetListEmptyState`) nennt, **welche** Verengung die Liste geleert hat, und
räumt beide zusammen weg.

Mit erledigt: `KnownHostsSheet.isUnfiltered` las `searchText.isEmpty` und wäre
mit einer Facette falsch geworden. Dieselbe Form stand in `SSHKeysSheet`
(im `emptyStateText`) und in `LoginSetsSheet` (direkt im `body`); alle drei
fragen jetzt die Verkettung. `ServerCertificatesSheet` führt die Form
weiterhin — dort richtig, weil dieses Sheet keine Facette hat.

## 3. Spaltensortierung in der Known-Hosts-Tabelle

**Der billigste Punkt der Liste.** Das Sheet ist bereits eine `Table` mit
sechs Spalten; SwiftUI liefert die Sortierung über eine `sortOrder`-Bindung
und `KeyPathComparator`. Kein Core-Anteil nötig — außer man will die
Sortierung über Sitzungen hinweg merken, dann kommt ein Feld im
`SettingsStore` dazu. `AuditLogSheet` ist ebenfalls schon `Table` und würde
denselben Griff erben.

## 4. Tabellen-Umstellung — verworfen (Maintainer, 2026-08-20)

Erwogen und **abgelehnt**: Logins und SSH-Keys von `List` auf `Table`
umzubauen. Known-Hosts und Audit-Log bleiben `Table`, die beiden anderen
bleiben `List`. Die Frage ist damit zu, nicht vertagt.

**Was der Bau gezeigt hatte**, bevor entschieden wurde: Die Login-Set-Zeile
wäre glatt durchgegangen — Badge, Name, Untertitel, Warnung, Nutzungszahl,
fünf Felder in fester Ordnung, keine Aktionen in der Zeile. Die
SSH-Key-Zeile hätte zwei Umbauten gebraucht: eine nur manchmal vorhandene
dritte Textzeile, und fünf dauerhaft sichtbare Icon-Buttons, die das
Kontextmenü derselben Zeile ohnehin wiederholt.

**Was die Entscheidung kostet, und zwar dauerhaft:** Der Untertitel ist ein
zusammengesetzter String — bei Keys `SHA256:… · <n> bit`, bei Login-Sets
Benutzer und Pfad. Fingerabdruck, Schlüssellänge und Pfad sind darin
verbacken und stehen als Felder nicht zur Verfügung. **Nach ihnen lässt sich
deshalb weder sortieren noch filtern**, solange die Zeile eine `List`-Zeile
ist. Wer das später doch will, kommt an dieser Entscheidung wieder vorbei —
dann aber als eigener Vorgang, nicht als Nebenwirkung von Punkt 2.

## 5. Import/Export unter ein Drei-Punkte-Menü — entschieden

**Gemessen, bevor entschieden wurde** (Fußzeilen-Knöpfe je Sheet):

| Sheet | Knöpfe | Inhalt |
|---|---|---|
| Login-Sets | **6** | Neu, Bearbeiten, Löschen, Exportieren, Importieren, Schließen |
| SSH-Schlüssel | 3 | Importieren, Erzeugen, Schließen |
| Known Hosts | 2 | Entfernen, Schließen |
| Hidden Imports | 1 | Schließen |

Das Platzproblem ist damit **Login-Sets**, nicht „die Sheets". Bei den
Schlüsseln nimmt dieselbe Behandlung einen Knopf weg und fügt einen Klick
hinzu.

### Die Regel, die es trotzdem für beide entscheidet

In der Login-Sets-Leiste stehen zwei Arten von Aktionen nebeneinander: Neu /
Bearbeiten / Löschen wirken auf die **Auswahl in der Liste**, Exportieren /
Importieren auf eine **Datei auf der Platte**.

> **Auswahl-Aktionen bleiben sichtbar. Datei-Aktionen wandern unter das
> Drei-Punkte-Menü.**

Daraus folgt auch, was *nicht* hineingehört: „Löschen…" spart zwar Platz,
ist aber zerstörend — eine zerstörende Aktion zu verstecken ist die falsche
Ersparnis. Und die Regel beantwortet den nächsten Fall im Voraus, statt ihn
wieder zur Einzelfrage zu machen.

### Festgelegt

- **Beide Sheets** bekommen das Menü — die Schlüssel nicht wegen Platzmangel,
  sondern damit die Regel an einer Stelle gilt statt an einer von zweien.
  Wenn der private Export später aus der Zeile in die Fußzeile wandert, ist
  der Platz schon da.
- **Position:** unmittelbar links von „Schließen".
- **Beschriftung:** nur das Symbol, kein Wort. Braucht damit zwingend einen
  `help`-Text und ein `accessibilityLabel`.
- Inhalt zunächst: Exportieren…, Importieren…

Zu bauen ist es gegen `List`, nicht gegen `Table` — siehe Punkt 4.

### Gebaut am 2026-08-29 — mit einer Korrektur an der Tabelle oben

Nachgezählt vor dem Bau, Fußzeile für Fußzeile: Login-Sets **6** und
SSH-Schlüssel **3** stimmen. **Known Hosts sind 3, nicht 2** — „Fingerabdruck
kopieren", „Entfernen…", „Schließen"; die Zeile oben hat den Kopier-Knopf
übersehen. Hidden Imports **1** stimmt (der „Wieder anzeigen"-Knopf sitzt in
der Zeile, nicht in der Fußzeile).

Danach: Login-Sets vier Knöpfe (Neu, Bearbeiten, Löschen, Schließen) plus das
Menü, SSH-Schlüssel zwei (Erzeugen, Schließen) plus das Menü. „Löschen…"
blieb sichtbar, wie festgelegt. Die Regel selbst trägt jetzt ein Typ:
`SheetOverflowAction` kennt nur Export und Import, `SheetOverflowMenu`
zeichnet nichts anderes — eine zerstörende Aktion hat dort keine Darstellung.
Bei den Schlüsseln wird gar kein Export angeboten (die Schlüssel-Exporte
sitzen in der Zeile), und bei den Logins fällt der Export-Eintrag weg, statt
grau zu werden, wenn die Suche nichts übrig lässt.

### Nachgezogen am 2026-08-29 — das dritte Sheet, und was die Zählung fand

`SnippetsSheet` hatte dieselbe Form und zeichnete weiter eigene
Exportieren…/Importieren…-Knöpfe. Nachgezählt vor dem Umbau: **6** Knöpfe
(Neu, Bearbeiten, Löschen, Exportieren, Importieren, Schließen) — dieselbe
Zahl wie Login-Sets, aus demselben Grund. Danach: **4** (Neu, Bearbeiten,
Löschen, Schließen) plus das Menü. „Löschen…" blieb sichtbar. Der
Einzel-Export in der Zeile blieb, wo er ist: er meint immer die
rechtsgeklickte Zeile und fragt nicht nach.

Die Wächter zählten die Sheets bis dahin **von Hand** auf — genau das Loch,
das dieses Sheet drei Milestones lang offen gehalten hat. Die Liste ist
ersetzt: `SheetOverflowMenuWiringGuardTests` findet die Sheets jetzt selbst,
und ein zweiter Scan geht über *jede* Fußzeile im App-Layer, nicht nur über
die mit Menü — sonst bleibt ein viertes abweichendes Sheet wieder unsichtbar,
weil es in der geprüften Menge gar nicht vorkommt.

Dieser Scan fand sofort einen Fall: **`AuditLogSheet` zeichnet „Als Text
exportieren…" in der Fußzeile.** Nicht mit umgebaut, sondern als
festgeschriebene Ausnahme eingetragen — die Aktion schreibt ein Protokoll zum
Mitlesen, kein wieder einlesbares Dokument, hat kein Importieren neben sich
und trägt nicht die Wortwahl des Menüs. Ob sie unter die Regel fällt, ist
eine Entscheidung über *dieses* Sheet und keine mechanische Wiederholung.
Der Eintrag ist angenagelt: verschwindet der Knopf, ohne dass die Ausnahme
gelöscht wird, schlägt der Test fehl.

## Reihenfolge

Mit der Absage an 4 sind alle verbliebenen Punkte voneinander unabhängig.

3 zuerst — er ist fast geschenkt, weil das Sheet bereits eine `Table` ist,
und macht die Known-Hosts-Ansicht sofort besser. Dann 5, weil das
Drei-Punkte-Menü die Zeilen entlastet, bevor 2 eine weitere Zeile
darüberlegt. 1 ist von allen dreien unabhängig und kann dazwischen.

**2 baut jetzt gegen `List`**, nicht gegen `Table` — der Filter arbeitet auf
denselben abgeleiteten Strings wie die Suche und braucht kein Spaltenmodell.
