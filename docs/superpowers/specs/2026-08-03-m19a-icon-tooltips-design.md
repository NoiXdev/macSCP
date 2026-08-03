# M19a — Tooltips an Icon-Aktionen + Wächter (Design/Spec)

**Datum:** 2026-08-03
**Status:** freigegeben (Maintainer), bereit für writing-plans
**Branch:** `develop`
**Anlass:** Maintainer-Frage: „Icons für Aktionen sollten beim Überfahren einen Titel bekommen, damit man erkennt, was sie tun — oder?"

## Ziel

Jede anklickbare Fläche, die nur ein Symbol zeigt, sagt beim Überfahren, was
sie tut — und ein Test sorgt dafür, dass das bei künftigen Symbolen nicht
wieder dem Zufall überlassen bleibt.

## Ausgangslage (im Code verifiziert)

Die Vermutung stimmt als Regel, aber die Abdeckung ist bereits gut — das
Beispiel des Maintainers ist sogar vollständig versorgt:

- **SSH-Schlüssel-Sheet: 6 von 6 Symbolen haben `.help`** (`SSHKeysSheet.swift`
  :237/:243/:249/:255/:261 für Kopieren, Public exportieren, Privat
  exportieren, Umbenennen, Löschen; :202 für das Schloss).
- **Toolbar vollständig:** Terminal (`ContentView.swift:940`), Transfer-Leiste
  (:951), Hochladen (:2689), Herunterladen (:2706).
- **Tab-Leiste teilweise:** das `+` hat einen Hinweis mit Kürzel
  (`TabStripView.swift:34`, „New tab (⌘N)"), das `×` nicht.

**Die zwei echten Lücken**, beide anklickbar:

1. `TabStripView.swift:107-108` — `xmark`, schließt den Tab, erscheint beim
   Überfahren der Zeile.
2. `SettingsView.swift:511` — `minus.circle`, entfernt eine Dateizuordnung im
   Bereich „Öffnen mit".

**Bewusst dekorativ** (Symbole, die keine Fläche zum Klicken sind):
`TransferQueueBar.swift:77` (Richtungspfeil) und :128 (Häkchen bei
„fertig"). Das ⚠ dort (:97) hat schon einen Hinweistext (:100), ebenso der
Fehlerfall (:135).

## Umfang

### 1. Die zwei fehlenden Hinweistexte

`×` am Tab: „Tab schließen (⌘W)" — mit Kürzel, weil das `+` daneben es
genauso hält. `−` in „Öffnen mit": „Zuordnung entfernen".

Zwei neue Schlüssel in **allen vier** Katalogen (`{en,de,fr,pl}.lproj`),
typografische Zeichen in den nicht-englischen Werten.

### 2. Der Wächter

Es gibt **kein UI-Testtarget** (`Package.swift` hat nur `macSCPCoreTests`),
also muss der Test den Quelltext lesen — dasselbe Mittel wie der
`#filePath`-Lint aus M19 (`EmbeddedKeyPorterTests`), der dort einen Read vor
dem Eigentums-Guard verhindert.

Der Test durchsucht `Sources/MacSCPApp/*.swift` nach jedem `Image(systemName:`
und `systemImage:` und verlangt für jedes Vorkommen genau **eine** von zwei
Antworten:

- in der Nähe steht ein `.help(` — erledigt; **oder**
- das Vorkommen steht auf einer ausdrücklichen Liste dekorativer Symbole,
  jeder Eintrag mit Datei, Symbolname und **einer Zeile Begründung**.

Ein neues Symbol, das in keiner der beiden Schubladen liegt, macht den Test
rot.

**Was der Wächter leistet und was nicht** — das gehört so in den
Doc-Kommentar, nicht schöner:

- Er beweist **nicht**, dass ein Hinweistext gut oder überhaupt am richtigen
  Element hängt. Ein `.help` am falschen Knopf in der Nähe geht durch.
- Die Nähe-Heuristik ist grob; ungewöhnliche Formatierung kann sie täuschen.
- Die Liste will gepflegt werden; sie ist bewusst eine Bremse, keine
  Bequemlichkeit.

Er erzwingt genau eine Sache: dass **jemand entschieden hat**. Das ist der
Anspruch, und mehr kann eine Quelltextprüfung ohne UI-Test nicht leisten. In
M19 hat ein solcher Lint zweimal echte Lücken gefangen — aber erst, nachdem
ein Reviewer ihn selbst mit einem Zeilenumbruch ausgehebelt hatte. Die
Schwäche ist belegt, nicht theoretisch; deshalb wird sie benannt statt
weggeschrieben.

## Tests

- **Wächter (Core-Testtarget, liest App-Quellen):** grün gegen den
  aufgeräumten Stand; rot, sobald ein Symbol ohne `.help` und ohne
  Listeneintrag auftaucht. Der Nachweis erfolgt per Mutation — ein Symbol
  ohne beides einfügen, Test muss rot werden, danach zurücknehmen.
- **Katalog-Parität:** beide neuen Schlüssel in allen vier Katalogen, per
  Grep geprüft (der Paritätstest diffed nur gegen `en.lproj` und sieht einen
  überall fehlenden Schlüssel nicht — genau diese Lücke hat in M18 einen
  Fehler ausgeliefert).
- App-Änderungen sind build-verifiziert; für Tooltips gibt es keinen
  Laufzeittest.

## Invarianten

- Keine neue externe Dependency.
- Code, Kommentare, Testnamen englisch; UI-Strings EN/DE/FR/PL, typografisch,
  kein ASCII-`"` in nicht-englischen Werten.
- Der Wächter darf nichts anderes prüfen als die Entscheidung pro Symbol —
  kein schleichender Stil-Linter.

## Nicht in M19a

- Dekorative Symbole mit Hinweistexten nachrüsten (Richtungspfeil, Häkchen,
  Typ-Badges) — sie stehen auf der Liste und bleiben dort.
- Ein UI-Testtarget einführen.
- Hinweistexte an Flächen, die bereits sichtbaren Text tragen.

## Betroffene Dateien

- `Sources/MacSCPApp/TabStripView.swift` — **modify** (Tooltip am `×`).
- `Sources/MacSCPApp/SettingsView.swift` — **modify** (Tooltip am `−`).
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` —
  **modify** (zwei neue Schlüssel).
- `Tests/macSCPCoreTests/IconTooltipLintTests.swift` — **create** (Wächter +
  Liste dekorativer Symbole).
