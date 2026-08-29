# Verschachtelte Ordner und freie Sortierung — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ordner lassen sich ineinander legen und alles lässt sich frei
sortieren — ohne dass ein Rückschritt auf eine ältere Fassung mehr verliert
als die Ordnung selbst.

**Grundlage:** `docs/superpowers/specs/2026-08-29-ordner-und-sortierung-design.md`

**Architektur:** Die Regeln sind reine Werte in `macSCPCore` — Baumaufbau,
Zyklenprüfung, Ordnungsberechnung, Reparatur beschädigter Einfuhr. Der Store
schreibt, die Seitenleiste zeigt. **Keine Ansicht rechnet eine Position aus.**

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Migrationen additiv, nie zerstörend.** Neue Felder sind optional; eine
  Datei ohne sie bleibt lesbar und verliert nichts.
- **Kein neuer Dateiname**, keine zweite Datei, kein Versionsschlüssel.
  `sessions-v2.json` bleibt.
- **Keine Änderung an `SessionListViewModel.save`** und seinem Upsert über
  den Namen.
- **Kein Löschen von Sitzungen.** Auflösen hebt hoch, es entfernt nie.
- **Kein Test erreicht echten Keychain, Sitzungs-Store oder Konfiguration.**
  Jeder Store zeigt auf ein temporäres Verzeichnis — `SessionListViewModel
  .init` hat seit `ab97f2a` keine Vorgabewerte mehr, das ist Absicht.
- **Nutzer-sichtbare Texte gehen durch alle vier Kataloge** (`en`, `de`,
  `fr`, `pl` unter `Sources/MacSCPAppKit/Resources/<locale>.lproj/
  Localizable.strings`), erreicht über `L10n.string(_:_:)` / `L10n.text(_:_:)`.
  **Kein String Catalog, kein `String(localized:)`, kein `Bundle.module`** —
  das steht so in `CLAUDE.md`, aber ältere Kontextabzüge behaupten das
  Gegenteil. Das Deutsche **duzt**; `GermanAddressFormTests` erzwingt es.
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und
  jede Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot,
  sobald die Zahl eindeutiger Warnorte über 1 liegt.**
- Ein Scratch-Pfad je Agent, nach Gebrauch gelöscht.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Die Felder und der Baum

**Files:**
- Modify: `Sources/macSCPCore/Sessions/StoredGroup.swift`,
  `Sources/macSCPCore/Sessions/StoredSession.swift`
- Create: `Sources/macSCPCore/Sessions/GroupTree.swift`
- Test: `Tests/macSCPCoreTests/GroupTreeTests.swift`

**Interfaces:**
- Produces: `StoredGroup.parentID: UUID?`, `StoredGroup.position: Int`,
  `StoredSession.position: Int`, und den Namensraum `GroupTree` mit
  `wouldCycle(moving:under:in:)`, `repaired(_:)` und `children(of:in:)`.
  Tasks 2, 3 und 4 rufen daraus.

**Der gemessene Ist-Zustand:** `StoredGroup` trägt `id` und `name`,
`StoredSession` unter anderem `groupID: UUID?`. Beide sind `Codable`,
`Equatable`, `Sendable`.

- [ ] **Step 1: Den Test zuerst schreiben.**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Group tree")
struct GroupTreeTests {
    private func group(_ name: String, parent: UUID? = nil, at position: Int = 0)
        -> StoredGroup
    {
        StoredGroup(id: UUID(), name: name, parentID: parent, position: position)
    }

    @Test func aGroupCannotBecomeItsOwnParent() {
        let a = group("a")
        #expect(GroupTree.wouldCycle(moving: a.id, under: a.id, in: [a]))
    }

    @Test func aGroupCannotMoveUnderItsOwnDescendant() {
        let a = group("a")
        let b = group("b", parent: a.id)
        let c = group("c", parent: b.id)
        #expect(GroupTree.wouldCycle(moving: a.id, under: c.id, in: [a, b, c]))
    }

    @Test func anUnrelatedMoveIsFine() {
        let a = group("a")
        let b = group("b")
        #expect(!GroupTree.wouldCycle(moving: a.id, under: b.id, in: [a, b]))
    }

    @Test func movingToTheTopLevelIsAlwaysFine() {
        let a = group("a")
        let b = group("b", parent: a.id)
        #expect(!GroupTree.wouldCycle(moving: b.id, under: nil, in: [a, b]))
    }

    @Test func repairLiftsAGroupWhoseParentIsMissing() {
        // An older export carries no parent, and a foreign file can name one
        // that is not in it. Nothing is discarded: the group lands at the top.
        let orphan = group("orphan", parent: UUID())
        let repaired = GroupTree.repaired([orphan])
        #expect(repaired.count == 1)
        #expect(repaired[0].parentID == nil)
    }

    @Test func repairBreaksACycleByLiftingTheFirstMemberItReaches() {
        var a = group("a")
        var b = group("b")
        a.parentID = b.id
        b.parentID = a.id
        let repaired = GroupTree.repaired([a, b])
        #expect(repaired.count == 2)
        #expect(repaired.filter { $0.parentID == nil }.count >= 1)
        #expect(!GroupTree.hasCycle(repaired))
    }

    @Test func repairLeavesAHealthyTreeAlone() {
        let a = group("a")
        let b = group("b", parent: a.id)
        #expect(GroupTree.repaired([a, b]) == [a, b])
    }

    @Test func childrenComeBackInPositionOrder() {
        let parent = group("p")
        let second = group("second", parent: parent.id, at: 1)
        let first = group("first", parent: parent.id, at: 0)
        let names = GroupTree.children(of: parent.id, in: [parent, second, first])
            .map(\.name)
        #expect(names == ["first", "second"])
    }
}
```

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter GroupTree`
Erwartet: FAIL — `StoredGroup` hat keinen solchen Initialisierer, `GroupTree`
gibt es nicht.

- [ ] **Step 3: Die Felder ergänzen.** `parentID: UUID?` und `position: Int`
  an `StoredGroup`, `position: Int` an `StoredSession`. **Beide mit
  Vorgabewert im Initialisierer und beim Dekodieren**, damit eine Datei ohne
  sie unverändert lesbar bleibt — das ist die additive Migration, und sie ist
  der Grund, warum kein neuer Dateiname nötig ist. `position` als
  Vorgabe `0`; `Codable` synthetisiert das nicht von selbst für einen
  fehlenden Schlüssel, also braucht es einen expliziten `decode`-Pfad oder
  einen optionalen Speicher mit nicht-optionalem Zugriff. **Welchen Weg du
  wählst, begründe im Kommentar — und prüfe ihn mit einem Test, der echtes
  JSON ohne die neuen Schlüssel dekodiert.**
- [ ] **Step 4: `GroupTree` umsetzen.** `wouldCycle(moving:under:in:)`,
  `hasCycle(_:)`, `repaired(_:)`, `children(of:in:)`. Alles rein, kein
  Dateizugriff. `repaired` verwirft **nie** einen Ordner.
- [ ] **Step 5: Grün laufen lassen**, plus ein Dekodier-Test für die alte
  Dateiform.
- [ ] **Step 6:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 7: Commit** — `feat(sessions): give groups a parent and a position`

---

### Task 2: Die Ordnung berechnen und schreiben

**Files:**
- Create: `Sources/macSCPCore/Sessions/SidebarOrdering.swift`
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift`,
  `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SidebarOrderingTests.swift`, plus die
  bestehenden Store-Suiten

**Interfaces:**
- Consumes: `GroupTree` aus Task 1.
- Produces: eine Verschiebefunktion, die aus **zwei Identitäten** eine neue
  Ordnung errechnet, und ein einmaliges Sortieren. Task 4 ruft beide.

**Das Vorbild, und es ist verbindlich:** `TabsViewModel.move(tabID:to:)` und
`move(tabID:onto:)` aus dieser Woche. Sie leiten das Ziel aus zwei
Identitäten ab statt aus einem Index — **weil der Index in der Ansicht die
Fehlerklasse war.** Lies beide, bevor du anfängst, und bau dieselbe Form.

- [ ] **Step 1: Rot zuerst.** Tests für: zwischen zwei Geschwister ziehen
  ordnet um; auf einen Ordner ziehen hängt ans Ende von dessen Kindern; ein
  Zug, der einen Zyklus schlösse, **ändert nichts** (und meldet das, statt
  still zu scheitern); Positionen sind nach jedem Zug lückenlos und eindeutig
  je Elternteil.
- [ ] **Step 2: Umsetzen.** Beim Schreiben werden die Geschwister des
  betroffenen Elternteils **durchnummeriert** — das ist die Zusicherung, an
  der jeder spätere Leser hängt, also gehört sie in einen Test und nicht in
  einen Kommentar.
- [ ] **Step 3: Das einmalige Sortieren.** Ordnet die **unmittelbaren**
  Unterelemente eines Ordners nach Namen und schreibt die Positionen neu.
  Wirkt genau eine Ebene tief. Kein gespeicherter Zustand, keine Einstellung.
  Der Namensvergleich folgt dem, was die Seitenleiste heute zum Sortieren
  benutzt — **schlag nach, statt einen neuen zu erfinden**, und nenn im
  Kommentar, welchen du gefunden hast.
- [ ] **Step 4: `dissolveGroup` verallgemeinern.** Sitzungen **und**
  Unterordner des aufgelösten Ordners wandern zu dessen `parentID`. Der
  bestehende Test für den flachen Fall muss unverändert grün bleiben — wird
  er es nicht, ist das ein Fund und gehört in den Bericht, nicht in eine
  angepasste Zusicherung.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `feat(sessions): reorder and nest by identity, never by index`

---

### Task 3: Ausfuhr und Einfuhr ziehen mit

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionExportCodec.swift` und der
  Import-Planer
- Test: die bestehenden Export-/Import-Suiten, plus neue Fälle

**Interfaces:**
- Consumes: `GroupTree.repaired(_:)` aus Task 1.

**Der gemessene Ist-Zustand:** `ExportedGroup` trägt `id` und `name`; sein
Kommentar sagt, die Kennung sei nur dateilokal und der Planer vergebe frische.
**Das ist die Falle dieses Tasks:** ein `parentID` verweist auf eine
dateilokale Kennung, die beim Import neu vergeben wird. Die Zuordnung muss
also **beim Umschlüsseln mitwandern** — ein roh übernommenes `parentID` zeigte
nach dem Import ins Leere.

- [ ] **Step 1: Rot zuerst.** Drei Fälle, jeder ein eigener Test: eine
  Ausfuhr **ohne** die neuen Felder importiert unverändert (die alte Form
  bleibt lesbar); ein `parentID` überlebt den Wechsel der Kennungen; eine
  Datei mit **Zyklus** oder **fehlendem Elternteil** importiert vollständig,
  mit den betroffenen Ordnern oben.
- [ ] **Step 2: Umsetzen.** `repaired(_:)` läuft auf der eingelesenen Datei,
  **bevor** irgendetwas übernommen wird.
- [ ] **Step 3: Der Import meldet, was er begradigt hat.** Der Planer hat
  bereits eine Fläche für seinen Bericht — **finde sie und benutze sie**,
  statt eine neue zu bauen. Nenn im Bericht, welche du gefunden hast.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 5: Commit** — `feat(sessions): carry nesting through export and import`

---

### Task 4: Die Seitenleiste

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/`

**Interfaces:**
- Consumes: alles aus Tasks 1–3.

**Auflage:** die Ansicht rechnet **keine** Position aus. Jede Geste endet in
einer Kernfunktion aus Task 2, mit zwei Identitäten als Argumenten. Wenn du
in der Ansicht einen Index brauchst, ist der Entwurf verletzt — melde das,
statt ihn einzubauen.

- [ ] **Step 1: Verschachtelt anzeigen.** Ordner in Ordnern, in
  Positionsreihenfolge über `GroupTree.children(of:in:)`.
- [ ] **Step 2: Ziehen.** Zwischen Geschwister ordnet um, auf einen Ordner
  verschiebt hinein. **Sichtbares Ziel beim Ziehen**, nach dem Vorbild von
  `TabStripView`s `dropTarget` — die Form ist da, sie hebt das Ziel hervor,
  statt eine Einfügemarke zwischen Elementen zu rechnen.
- [ ] **Step 3: Das Ordner-Kontextmenü.** Ein Eintrag „nach Namen sortieren",
  der Task 2s einmaliges Sortieren auslöst. **Nur zeigen, was möglich ist** —
  stehende Regel dieses Projekts, nichts wird ausgegraut.
- [ ] **Step 4: Die Texte.** In alle vier Kataloge, gleiche Schlüsselmenge,
  das Deutsche duzt.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `feat(sidebar): nest folders and drag them into order`

---

## Was ausdrücklich nicht dazugehört

- **Keine Suche im Baum (D3).** Sie kommt danach, weil die Verschachtelung
  ihre Darstellung mitbestimmt.
- **Keine gespeicherte Sortier-Einstellung pro Ordner.**
- **Kein neuer Dateiname und keine zweite Datei.**
- **Keine Änderung an den Tags** (E1/E2) — dieselbe Seitenleiste, anderer
  Vorgang.
