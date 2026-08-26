# Drei kleine Bedienpunkte — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drei unabhängige Ärgernisse aus dem Backlog beseitigen, jedes einzeln prüfbar und sofort spürbar.

**Grundlage:** `docs/superpowers/specs/2026-08-20-backlog-sitzungen-tabs-seitenleiste.md` (C1, D4) und `2026-08-20-backlog-verwaltungs-sheets.md` (Punkt 3).

**Reihenfolge:** von der kleinsten Wirkfläche zur größten. Die drei Aufgaben hängen nicht voneinander ab; jede kann für sich zurückgestellt werden.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**; Katalogwerte sind Übersetzungen, Deutsch duzt.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Alle vier Kataloge bei neuen Zeichenketten, gleiche Schlüsselmengen.
- Keine Zeilennummern, keine Ortsangaben in Kommentaren; jede Zahl im selben Durchgang gezählt.
- **Kein Test erreicht echten Keychain, Sitzungs-Store oder Konfiguration.** `ContentView` nimmt eingespeiste Ablagen.
- Wächter: **Mutationstests belegen die Empfindlichkeit, nie den Geltungsbereich.** Vor der Wahl eines Ankers fragen, *woher* die Eigenschaft verletzt werden könnte.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Einfachklick wählt aus, Doppelklick verbindet

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Test: `Tests/macSCPAppKitTests/`

**Der gemessene Ist-Zustand:** die Zeile hängt an `.onTapGesture { if !isRenaming { onSelect() } }`, und `onSelect` reicht über `ContentView+Detail.swift` an `connectFromSidebar(stored)` weiter — **ein Klick baut eine Verbindung auf.**

**Was den Weg rettet:** das Kontextmenü derselben Zeile trägt bereits einen Eintrag **„Verbinden"**. Der Verbindungsweg geht also nicht verloren, wenn der Tipp zur Auswahl wird.

- [x] **Step 1 (beantwortet 2026-08-26):** Die Seitenleiste kennt **keine**
  Auswahl. `selection` in `SessionSidebar.swift` gehört ausschließlich dem
  Tag-Filter (`HostTagFilterRow`); eine Sitzungszeile hat nur `onSelect`, und
  das führt direkt ins Verbinden.

  **Folge für den Zuschnitt:** Die Auswahl ist der eigentliche Anteil dieser
  Aufgabe, nicht die Geste. Nur den Einfachklick zu entschärfen, ohne etwas
  an seine Stelle zu setzen, macht ihn zur toten Geste — das wäre schlechter
  als heute. Diese Aufgabe umfasst deshalb:

  1. einen Auswahlzustand für die Zeile (welche Sitzung ist gemeint),
  2. seine sichtbare Hervorhebung,
  3. Doppelklick und Eingabetaste als Verbindungswege,
  4. das bestehende Kontextmenü bleibt der dritte Weg.

  Punkt 3 ist der Grund, warum Punkt 1 überhaupt trägt: eine Auswahl, auf die
  keine Taste wirkt, ist bloß eine Einfärbung.
- [ ] **Step 2:** Test zuerst: ein Einfachklick verbindet **nicht**, ein Doppelklick schon. Wo das nicht ohne Rendering-Umgebung geht, den entscheidbaren Teil in einen prüfbaren Wert ziehen und die Ansicht nur darauf zeigen lassen.
- [ ] **Step 3:** Rot. — [ ] **Step 4:** Umsetzen. — [ ] **Step 5:** Volle Suite grün.
- [ ] **Step 6: Commit** — `fix(sidebar): connect on double-click, select on single`

---

### Task 2: Seitenleistenbreite ziehen und merken

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift`, `Sources/macSCPCore/Settings/SettingsStore.swift`
- Test: `Tests/macSCPCoreTests/SettingsStoreTests.swift`

**Der gemessene Ist-Zustand:** `.frame(minWidth: 170, idealWidth: 190, maxWidth: 260)`. Die **Obergrenze 260** ist der Grund, warum sich die Leiste nicht nach rechts ziehen lässt; gespeichert wird nichts.

- [ ] **Step 1:** Test zuerst, nach dem Muster von `autoRefreshIntervalSeconds`: **Getter und Setter klemmen beide**, damit eine von Hand editierte `settings.json` keine unbrauchbare Breite erzeugt. Die Grenzen benennen und begründen.
- [ ] **Step 2:** Rot. — [ ] **Step 3:** Eigenschaft ergänzen, Klammer im View lösen, Breite lesen und schreiben.
- [ ] **Step 4:** Volle Suite grün.
- [ ] **Step 5: Commit** — `feat(sidebar): remember how wide you dragged it`

---

### Task 3: Spaltensortierung bei den bekannten Hosts

**Files:**
- Modify: `Sources/MacSCPAppKit/KnownHostsSheet.swift`
- Test: `Tests/macSCPAppKitTests/`

**Warum das der billigste Punkt ist:** das Sheet ist bereits eine `Table` mit sechs Spalten. SwiftUI liefert die Sortierung über eine `sortOrder`-Bindung und `KeyPathComparator` — kein Core-Anteil nötig.

- [ ] **Step 1:** Entscheiden und im Bericht begründen, ob die Sortierung über Sitzungen hinweg gemerkt wird. Wenn ja, kommt ein Feld im `SettingsStore` dazu und Task 2s Muster gilt hier genauso; wenn nein, sagen warum.
- [ ] **Step 2:** Test zuerst auf den **entscheidbaren** Anteil — welche Vergleichsregel zu welcher Spalte gehört —, nicht auf das Zeichnen. Besonders: ein Feld, das fehlen kann, darf beim Sortieren nicht an eine willkürliche Stelle rutschen.
- [ ] **Step 3:** Rot. — [ ] **Step 4:** Umsetzen. — [ ] **Step 5:** Volle Suite grün.
- [ ] **Step 6: Commit** — `feat(knownhosts): sort the table by its columns`

---

## Was ausdrücklich nicht dazugehört

- Kein Umbau von Logins oder SSH-Schlüsseln auf `Table` — vom Maintainer am 2026-08-20 **verworfen**.
- Kein Schnellfilter, kein Drei-Punkte-Menü, keine verschachtelten Ordner: eigene Einträge, eigene Entscheidungen.
- Keine Änderung an der Sortierung der Dateitabelle.
