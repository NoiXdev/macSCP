# Snippet-Probelauf und Ausstieg pro Snippet — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vor dem Senden sichtbar machen, was tatsächlich auf die Leitung
geht — und die Ablehnung mit Evidenz umgehbar machen statt auf Zusicherung.

**Grundlage:** `docs/superpowers/specs/2026-08-30-snippet-probelauf-design.md`

**Architektur:** Die Anzeige ist ein reiner Wert in `macSCPCore`, aus
Snippet, Werten und Sendeplan gebildet. Beide Zugänge — Auslösen und
„Testen" — zeigen denselben Wert. Das Kennzeichen ist ein Feld an `Snippet`,
das der Export **nicht kennt**.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Der eingesetzte Wert darf in kein Protokoll, keinen Export und keine
  Fehlermeldung** — auch nicht in eine Testfehlermeldung. Das Audit-Log führt
  die Vorlage.
- **Keine Änderung an `SnippetCommandSurvey`** und keine an `SnippetSendPlan`s
  Ablehnung eines mehrzeiligen Einfügens.
- Nutzer-sichtbare Texte in **alle vier Kataloge** (`en`, `de`, `fr`, `pl`
  unter `Sources/MacSCPAppKit/Resources/<locale>.lproj/Localizable.strings`)
  über `L10n.string(_:_:)`; Core-seitig `CoreL10n.string(_:)`. **Kein String
  Catalog, kein `String(localized:)`, kein `Bundle.module`.** Das Deutsche
  **duzt**.
- **Nur zeigen, was möglich ist** — nichts wird ausgegraut.
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und
  jede Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot,
  sobald die Zahl eindeutiger Warnorte über 1 liegt.** Warnungen werden auf
  einem **frischen** Scratch-Pfad gemessen — inkrementell expandiert das
  `#expect`-Makro nicht neu, und das hat diese Woche zweimal null gemeldet,
  wo ein frischer Bau zwei fand.
- Ein Scratch-Pfad je Agent, nach Gebrauch gelöscht. Die App wird nicht
  gestartet, nichts gepusht.

---

### Task 1: Die Ausfuhr bekommt einen eigenen Typ

**Files:**
- Modify: `Sources/macSCPCore/Terminal/SnippetExportCodec.swift`,
  `Sources/macSCPCore/Terminal/SnippetImportPlanner.swift`
- Test: die bestehenden Export-/Import-Suiten, plus neue Fälle

**Warum zuerst:** das Kennzeichen aus Task 2 darf nicht eine Sekunde lang
existieren, ohne dass die Grenze steht. Umgekehrt wäre Task 2 ein Feld, das
durch Export und Import reist, und der Fehler, den dieser ganze Vorgang
vermeiden soll, wäre kurzzeitig eingebaut.

**Der gemessene Ist-Zustand:** `SnippetExportPayload` trägt `[Snippet]` —
denselben Typ, den der Store speichert. Bei Sitzungen ist das anders gelöst
(`ExportedGroup`, `ExportedSession`); **lies `SessionExportCodec` als
Vorbild**, einschließlich seiner Kommentare darüber, warum eine ausgeführte
Kennung dateilokal ist.

- [ ] **Step 1: Rot zuerst.** Ein Test, der belegt, dass ein Feld an
  `Snippet` heute durch einen Rundlauf reist. Nimm ein **vorhandenes** Feld
  dafür — das neue gibt es noch nicht.
- [ ] **Step 2: `ExportedSnippet` einführen.** Trägt die Felder, die geteilt
  gehören. Die Umschlüsselung von Kennungen folgt dem, was der
  Sitzungs-Planer tut; **schau nach, statt zu erfinden.**
- [ ] **Step 3: Die alte Form bleibt lesbar.** Eine Datei, die eine frühere
  Fassung geschrieben hat, importiert unverändert. Test dafür.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 5: Commit** — `refactor(snippets): give the export its own type`

---

### Task 2: Das Kennzeichen

**Files:**
- Modify: `Sources/macSCPCore/Terminal/Snippet.swift`,
  `Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift` (oder wo
  die Positionsprüfung gerufen wird — **nachsehen**), der Snippet-Editor
- Test: neue Fälle plus die bestehenden Substitutions-Suiten

- [ ] **Step 1: Rot zuerst.** Ein Snippet mit gesetztem Kennzeichen löst
  einen Platzhalter auf, den die Prüfung sonst ablehnt; ohne Kennzeichen wird
  weiterhin abgelehnt. Beide Richtungen.
- [ ] **Step 2: Das Feld.** Optional beim Dekodieren mit Vorgabe „Prüfung
  an", damit jede bestehende Datei unverändert lesbar bleibt — `Codable`
  synthetisiert für einen **fehlenden** Schlüssel keinen Vorgabewert, es
  wirft. Prüf das mit echtem JSON ohne den Schlüssel, nicht mit einem Umlauf
  durch einen Wert im Speicher.
- [ ] **Step 3: Es schaltet die Positionsprüfung ab, sonst nichts.**
  `SnippetSendPlan`s Ablehnung eines mehrzeiligen Einfügens bleibt
  unberührt — eigener Test.
- [ ] **Step 4: Die Pflichtprobe.** Ein importiertes Snippet trägt das
  Kennzeichen **nie**. Belege es, indem du versuchst, es in eine
  Ausfuhrdatei zu schreiben: es darf sich nicht ausdrücken lassen. Kompiliert
  der Versuch, ist Task 1 unvollständig und das gehört gemeldet.
- [ ] **Step 5: Im Editor sichtbar**, mit einem Text, der benennt, **was**
  abgeschaltet wird. Alle vier Kataloge, das Deutsche duzt.
- [ ] **Step 6:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 7: Commit** — `feat(snippets): let one snippet opt out of the placement check`

---

### Task 3: Der Probelauf als Wert

**Files:**
- Create: `Sources/macSCPCore/Terminal/SnippetDryRun.swift`
- Test: `Tests/macSCPCoreTests/SnippetDryRunTests.swift`

**Interfaces:**
- Produces: einen Wert, der aus Snippet, Werten und Sendeplan beschreibt, was
  angezeigt wird. Task 4 ruft ihn von **beiden** Zugängen.

- [ ] **Step 1: Rot zuerst.** Was der Wert trägt, in Tests: der aufgelöste
  Befehl; welche Sendeform gewählt würde; ob abgelehnt wurde und warum; die
  Färbung über `SnippetHighlighter`.
- [ ] **Step 2: Umsetzen.** Der Wert **setzt zusammen**, die Ansicht nicht.
- [ ] **Step 3: Der Fall aus dem Eintrag.** `P=neu echo "$P"` als Fixture —
  der aufgelöste Text muss ihn zeigen, denn das ist der Fall, den der
  Probelauf sichtbar machen soll.
- [ ] **Step 4: Die Auflage prüfen.** Ein Test, der belegt, dass der
  eingesetzte Wert **in keiner** Audit-Zeile und **in keiner** Fehlermeldung
  erscheint. Das ist die Zusage dieses Vorgangs, also gehört sie in einen
  Test und nicht in einen Kommentar.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 6: Commit** — `feat(snippets): describe what a dry run shows`

---

### Task 4: Die zwei Zugänge

**Files:**
- Modify: der Auslöseweg (`ContentView`, wo `SnippetSendPlanner.plan` gerufen
  wird), der Snippet-Editor
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/`

**Interfaces:**
- Consumes: Task 3.

- [ ] **Step 1: Der Weg beim Auslösen.** Wird ein Snippet abgelehnt,
  erscheint der Probelauf mit Grund und **„trotzdem senden"**. Ohne Ablehnung
  ändert sich am Auslösen nichts — der Probelauf ist kein
  Bestätigungsschritt.
- [ ] **Step 2: Der „Testen"-Knopf im Editor.** Zeigt denselben Wert, sendet
  nichts. Benutzt **dieselbe** Wertabfrage wie das Auslösen; eine zweite
  Abfrageform wäre eine zweite Wahrheit darüber, was ein Wert ist.
- [ ] **Step 3: Nichts merken.** Was der Editor-Probelauf erfragt, darf den
  nächsten echten Lauf **nicht** vorbelegen. Eigener Test.
- [ ] **Step 4: Ein Wächter, der beide Zugänge auf denselben Wert
  festnagelt** — mit einer **positiven** Prüfung daneben, dass beide
  Aufrufstellen überhaupt existieren. Eine negative Prüfung allein veraltet
  still, und dieser Wächter scannt Quelltext: die **ganze Anweisung**, nicht
  eine Zeile, und er darf sich nicht auf einem Kommentar verankern.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 6: Commit** — `feat(snippets): show the dry run from both entrances`

---

## Was ausdrücklich nicht dazugehört

- **Kein globaler Schalter** in den Einstellungen.
- **Keine Änderung an der Erlaubnisliste** von `SnippetCommandSurvey`.
- **Kein Probelauf vor jeder Auslösung.**
- **Kein Merken von Werten aus dem Editor-Probelauf.**
