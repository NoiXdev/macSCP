# Tab-Kontextmenü und Umordnen — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Reiter bekommt ein Kontextmenü, und die Reihenfolge der Reiter lässt sich per Menü und per Ziehen ändern.

**Grundlage:** `docs/superpowers/specs/2026-08-27-tab-kontextmenue-und-umordnen-design.md`

**Architektur:** Die entscheidbaren Anteile — welche Einträge erscheinen, was das Umordnen mit der Reihenfolge macht, was die Sammelwarnung sagt — liegen als reine Werte in `macSCPCore` und sind dort geprüft. Die Ansicht zeichnet nur und trifft keine eigene Entscheidung. Das Umordnen entsteht **einmal**, beide Bedienwege rufen dieselbe Funktion.

**Reihenfolge:** erst die Werte (prüfbar), dann die Verdrahtung (nicht prüfbar).

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**;
  Katalogwerte sind Übersetzungen, das Deutsche duzt.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Alle vier Kataloge** bei neuen Zeichenketten (`en`, `de`, `fr`, `pl` unter
  `Sources/MacSCPAppKit/Resources/`), gleiche Schlüsselmengen.
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`. **CI wird rot, sobald
  die Zahl eindeutiger Warnorte über 1 liegt** — es darf keine neue Warnung
  zurückbleiben.
- **Lokal grün ist kein Beleg über CI.** Dieser Rechner hat Swift 6.3.3, CI eine
  ältere Toolchain, deren Regionsanalyse ungenauer und damit in der Praxis
  strenger ist. Eine Aussage über einen **Typ** (`Sendable`-Hülle) lesen beide
  gleich; `nonisolated(unsafe)` auf einer Bindung sagt nichts darüber, was eine
  Closure fängt.
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und jede
  Aufzählung von Aufrufstellen wird in dem Durchgang gezählt, der sie schreibt.
- **Kein Test erreicht echten Keychain, Sitzungs-Store oder Konfiguration.**
- Abbau ausschließlich über `teardown(_ tab:reason:)` — die
  Architektur-Invariante (Warteschlange abbrechen → Terminal herunterfahren →
  trennen) darf nicht umgangen werden.
- Die App wird nicht gestartet, nichts gepusht, `scripts/release` läuft nicht.

---

### Task 1: Das Menü als prüfbarer Wert

**Files:**
- Create: `Sources/macSCPCore/Presentation/TabContextMenu.swift`
- Test: `Tests/macSCPCoreTests/TabContextMenuTests.swift`

**Interfaces:**
- Produces: `TabMenuEntry` (Enum, `Equatable`, `Sendable`) und
  `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:) -> [TabMenuEntry]`.
  Task 4 rendert daraus das Menü.

**Vorbild:** `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` — dieselbe
Form (Enum in Anzeigereihenfolge, eine `static func entries`, Entscheidung in
Core statt in der Ansicht). Lies die Datei, bevor du anfängst.

**Eine Festlegung, die aus dem Entwurf abgeleitet ist und die du im Bericht
nennen sollst:** „Terminal öffnen" hängt an `supportsShell` **und**
`isConnected`. Der Entwurf nennt für die Sichtbarkeit das Protokoll, führt
`isConnected` aber als Eingabe — und ein Terminal ohne stehende Verbindung gibt
es nicht.

- [ ] **Step 1: Den Test zuerst schreiben.**

```swift
import Testing
@testable import macSCPCore

@Suite("Tab context menu")
struct TabContextMenuTests {
    @Test func aLoneTabOffersNothingButClosing() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true) == [.close])
    }

    @Test func theFirstOfThreeCannotMoveLeft() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true)
            == [.close, .closeOthers, .moveRight])
    }

    @Test func theLastOfThreeCannotMoveRight() {
        #expect(TabContextMenu.entries(
            atIndex: 2, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true)
            == [.close, .closeOthers, .moveLeft])
    }

    @Test func aMiddleTabMovesBothWays() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: false, isAdHoc: false, isConnected: true)
            == [.close, .closeOthers, .moveLeft, .moveRight])
    }

    @Test func onlyAShellBackendOffersATerminal() {
        let withShell = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: true)
        #expect(withShell.contains(.openTerminal))

        let withoutShell = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true)
        #expect(!withoutShell.contains(.openTerminal))
    }

    @Test func aShellBackendThatIsNotConnectedOffersNoTerminal() {
        let entries = TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: true, isAdHoc: false, isConnected: false)
        #expect(!entries.contains(.openTerminal))
    }

    @Test func savingIsOfferedOnlyForAConnectedAdHocTab() {
        #expect(TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: true, isConnected: true)
            .contains(.saveAsSession))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: true, isConnected: false)
            .contains(.saveAsSession))
        #expect(!TabContextMenu.entries(
            atIndex: 0, ofTabCount: 1,
            supportsShell: false, isAdHoc: false, isConnected: true)
            .contains(.saveAsSession))
    }

    @Test func theOrderIsFixedRegardlessOfWhichEntriesApply() {
        #expect(TabContextMenu.entries(
            atIndex: 1, ofTabCount: 3,
            supportsShell: true, isAdHoc: true, isConnected: true)
            == [.close, .closeOthers, .moveLeft, .moveRight, .openTerminal, .saveAsSession])
    }
}
```

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter TabContextMenu`
Erwartet: FAIL, `cannot find 'TabContextMenu' in scope`.

- [ ] **Step 3: Umsetzen.**

```swift
import Foundation

/// Context-menu entries for a tab, in display order. The app layer maps
/// these to localized menu items; the decision lives here so it can be
/// tested without rendering anything — the same split
/// `BrowserContextMenu` uses.
public enum TabMenuEntry: Equatable, Sendable {
    case close
    case closeOthers
    case moveLeft
    case moveRight
    /// Only where the backend has a shell at all — see
    /// `ProtocolCapabilities.supportsShell`, which is `true` for SSH and
    /// `false` for S3 and WebDAV.
    case openTerminal
    /// Persisting a connection that was dialed ad hoc. Absent for a tab
    /// that already belongs to a stored session, because there is nothing
    /// to save.
    case saveAsSession
}

public enum TabContextMenu {
    /// Which entries a tab offers.
    ///
    /// `index` and `count` decide the movement and the bulk close; the
    /// three flags decide the rest. Nothing here reaches for a
    /// `ConnectionKind`: what an entry depends on is a capability or a
    /// state, never which protocol it happens to be.
    public static func entries(
        atIndex index: Int, ofTabCount count: Int,
        supportsShell: Bool, isAdHoc: Bool, isConnected: Bool
    ) -> [TabMenuEntry] {
        var entries: [TabMenuEntry] = [.close]
        if count > 1 { entries.append(.closeOthers) }
        if index > 0 { entries.append(.moveLeft) }
        if index < count - 1 { entries.append(.moveRight) }
        // A terminal needs a shell AND a live connection: the capability
        // says the backend could have one, the state says there is
        // something to attach it to.
        if supportsShell && isConnected { entries.append(.openTerminal) }
        if isAdHoc && isConnected { entries.append(.saveAsSession) }
        return entries
    }
}
```

- [ ] **Step 4: Grün laufen lassen.**

Run: `swift test --filter TabContextMenu`
Erwartet: PASS, acht Tests.

- [ ] **Step 5: Volle Suite grün, keine neue Warnung.**

Run: `swift test` und `swift build --build-tests`

- [ ] **Step 6: Commit** — `feat(tabs): model the tab context menu as a tested value`

---

### Task 2: Umordnen in `TabsViewModel`

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TabsViewModel.swift`
- Test: `Tests/macSCPCoreTests/TabsViewModelTests.swift`

**Interfaces:**
- Produces: `TabsViewModel.move(tabID:to:)`. Task 4 ruft sie mit ±1 aus dem
  Menü, Task 5 mit der Zielposition aus dem Ziehen.

**Der gemessene Ist-Zustand:** `TabsViewModel` ist `@MainActor`, `@Observable`,
generisch über `Tab: Identifiable where Tab.ID == UUID`, und hält
`tabs` sowie `activeTabID` als `private(set)`. `activeTab` schlägt über
`activeTabID` nach — deshalb bleibt der aktive Tab aktiv, solange niemand
`activeTabID` anfasst. **Fass es nicht an.**

- [ ] **Step 1: Den Test zuerst schreiben.** Ergänze die bestehende Datei; halte
  dich an ihren vorhandenen Testpayload-Typ, statt einen zweiten einzuführen.

```swift
    @Test func movingATabPutsItAtTheRequestedPosition() {
        let a = TestTab(), b = TestTab(), c = TestTab()
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.move(tabID: a.id, to: 2)
        #expect(vm.tabs.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func movingSomeOtherTabLeavesTheActiveOneActive() {
        let a = TestTab(), b = TestTab(), c = TestTab()
        let vm = TabsViewModel(initial: a)
        vm.addTab(b); vm.addTab(c)
        vm.activate(b.id)
        vm.move(tabID: c.id, to: 0)
        // b moved from the middle to the end without being touched.
        #expect(vm.tabs.map(\.id) == [c.id, a.id, b.id])
        #expect(vm.activeTabID == b.id)
        #expect(vm.activeTab.id == b.id)
    }

    @Test func movingTheActiveTabKeepsItActive() {
        let a = TestTab(), b = TestTab()
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.activate(a.id)
        vm.move(tabID: a.id, to: 1)
        #expect(vm.tabs.map(\.id) == [b.id, a.id])
        #expect(vm.activeTabID == a.id)
    }

    @Test func aDestinationBeyondTheEndsDoesNothingRatherThanTrapping() {
        let a = TestTab(), b = TestTab()
        let vm = TabsViewModel(initial: a)
        vm.addTab(b)
        vm.move(tabID: a.id, to: -5)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
        vm.move(tabID: b.id, to: 99)
        #expect(vm.tabs.map(\.id) == [a.id, b.id])
    }

    @Test func movingAnUnknownTabIsANoOp() {
        let a = TestTab()
        let vm = TabsViewModel(initial: a)
        vm.move(tabID: UUID(), to: 0)
        #expect(vm.tabs.map(\.id) == [a.id])
    }
```

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter TabsViewModel`
Erwartet: FAIL, `value of type 'TabsViewModel<TestTab>' has no member 'move'`.

- [ ] **Step 3: Umsetzen.** Direkt nach `addTab` einfügen:

```swift
    /// Moves a tab to another position. The only reordering there is —
    /// the context menu calls it with the neighbouring index, dragging
    /// calls it with the drop position, so the rule exists once.
    ///
    /// `activeTabID` is deliberately untouched: it names a tab, not a
    /// position, so the active tab stays active however the order changes.
    /// Out-of-range destinations and unknown ids leave the order alone
    /// rather than trapping — a gesture that ends outside the strip is an
    /// ordinary outcome, not a programmer error.
    public func move(tabID: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let clamped = max(0, min(destination, tabs.count - 1))
        guard clamped != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
    }
```

- [ ] **Step 4: Grün laufen lassen.**

Run: `swift test --filter TabsViewModel`
Erwartet: PASS.

- [ ] **Step 5: Volle Suite grün, keine neue Warnung.**
- [ ] **Step 6: Commit** — `feat(tabs): reorder tabs through one rule in the view model`

---

### Task 3: Die Sammelwarnung

**Files:**
- Modify: `Sources/MacSCPAppKit/TabCloseWarning.swift`
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/TabCloseWarningTests.swift`

**Interfaces:**
- Consumes: nichts aus Task 1 und 2.
- Produces: `TabCloseWarning.bulkMessage(tabsClosing:transferring:incoming:) -> String`,
  `TabCloseWarning.transferringCount(among:) -> Int` und
  `TabCloseWarning.incomingCount(among:in:) -> Int`. Task 4 ruft alle drei.

**Der gemessene Ist-Zustand:** `TabCloseWarning` hat heute zwei Funktionen —
`hasIncomingTransfers(for:in:)` (`@MainActor`, weil `SessionTab` es ist) und
`message(activeTransfers:incomingTransfers:)` (frei von Isolation, weil es sie
nicht braucht). Halte diese Trennung ein: das Zählen ist `@MainActor`, das
Formulieren nicht.

- [ ] **Step 1: Den Test zuerst schreiben.** In der bestehenden Datei ergänzen:

```swift
    @Test func theBulkMessageNamesHowManyTabsAreTransferring() {
        let text = TabCloseWarning.bulkMessage(
            tabsClosing: 4, transferring: 2, incoming: 0)
        #expect(text.contains("4"))
        #expect(text.contains("2"))
    }

    @Test func theBulkMessageIsEmptyWhenNothingIsTransferring() {
        #expect(TabCloseWarning.bulkMessage(
            tabsClosing: 3, transferring: 0, incoming: 0).isEmpty)
    }

    @Test func theBulkMessageCarriesBothReasonsWhenBothHold() {
        let text = TabCloseWarning.bulkMessage(
            tabsClosing: 5, transferring: 2, incoming: 1)
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func theBulkMessageMentionsIncomingAloneWhenThatIsTheOnlyReason() {
        let text = TabCloseWarning.bulkMessage(
            tabsClosing: 3, transferring: 0, incoming: 2)
        #expect(!text.isEmpty)
        #expect(text.split(separator: "\n").count == 1)
    }
```

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter TabCloseWarning`
Erwartet: FAIL, `type 'TabCloseWarning' has no member 'bulkMessage'`.

- [ ] **Step 3: Umsetzen.** In `TabCloseWarning` ergänzen:

```swift
    /// How many of `closing` hold a non-terminal item of their own.
    /// `@MainActor` for the same reason `hasIncomingTransfers` is:
    /// `SessionTab` is.
    @MainActor
    static func transferringCount(among closing: [SessionTab]) -> Int {
        closing.count { $0.transferQueue.isActive }
    }

    /// How many of `closing` are the destination of another tab's transfer.
    @MainActor
    static func incomingCount(among closing: [SessionTab], in tabs: [SessionTab]) -> Int {
        closing.count { hasIncomingTransfers(for: $0.id, in: tabs) }
    }

    /// The one question asked before closing several tabs at once. Empty
    /// when neither reason holds — the caller decides whether a dialog
    /// appears at all, exactly as with `message`.
    ///
    /// One question and one answer: declining cancels the whole operation
    /// rather than sparing the transferring tabs, because closing the quiet
    /// half would be a third behaviour nobody asked for.
    static func bulkMessage(tabsClosing: Int, transferring: Int, incoming: Int) -> String {
        var lines: [String] = []
        if transferring > 0 {
            lines.append(String(
                format: L10n.string(
                    "tabs.closeOthers.activeTransfers",
                    "Closing %1$d tabs cancels active transfers in %2$d of them."),
                tabsClosing, transferring))
        }
        if incoming > 0 {
            lines.append(String(
                format: L10n.string(
                    "tabs.closeOthers.incomingTransfers",
                    "%d of them are receiving transfers from other tabs; closing cancels those."),
                incoming))
        }
        return lines.joined(separator: "\n")
    }
```

**Zu `isActive`, damit du nicht danach suchst:** `hasActiveItems` gibt es nur
mit `destinationTabID:`; für „dieser Reiter überträgt selbst" liest
`requestClose` in `ContentView+Lifecycle` genau `tab.transferQueue.isActive`.
Dieselbe Quelle nehmen, damit Einzel- und Sammelwarnung nicht auseinanderlaufen.

- [ ] **Step 4:** Die zwei neuen Schlüssel in **alle vier** Kataloge, gleiche
  Schlüsselmenge. Das Deutsche duzt.
- [ ] **Step 5: Grün laufen lassen.** `swift test --filter TabCloseWarning`
- [ ] **Step 6:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 7: Commit** — `feat(tabs): ask once before closing several tabs`

---

### Task 4: Das Menü verdrahten

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/` (neue Wächterdatei)

**Interfaces:**
- Consumes: `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:)`
  aus Task 1, `TabsViewModel.move(tabID:to:)` aus Task 2,
  `TabCloseWarning.bulkMessage(tabsClosing:transferring:incoming:)` aus Task 3.

**Der gemessene Ist-Zustand:** `TabStripView` hat heute **kein** `contextMenu`.
`TabItemView` trägt bereits `.onTapGesture(perform: onActivate)` und einen
Schließen-Knopf mit `onClose`.

- [ ] **Step 1:** `TabItemView` bekommt `.contextMenu`, das **ausschließlich**
  über das Ergebnis von `TabContextMenu.entries(…)` iteriert. Kein `if` in der
  Ansicht darüber, ob ein Eintrag erscheint — diese Entscheidung ist in Task 1
  getroffen und geprüft. Die Ansicht bildet `TabMenuEntry` auf Titel und
  Aktion ab.
- [ ] **Step 2:** Sechs Titel-Schlüssel in alle vier Kataloge:
  `tabs.menu.close`, `tabs.menu.closeOthers`, `tabs.menu.moveLeft`,
  `tabs.menu.moveRight`, `tabs.menu.openTerminal`, `tabs.menu.saveAsSession`.
- [ ] **Step 3: Die Handler in `ContentView+Lifecycle`.**
  - `moveLeft`/`moveRight` rufen `tabsModel.move(tabID:to:)` mit Index ∓1.
  - `closeOthers` schließt **alle außer dem angeklickten Tab** — nicht außer
    dem aktiven. Vorher die Zählungen holen und, wenn `bulkMessage` nicht leer
    ist, einmal fragen; bei Ablehnung passiert **nichts**. Jeder Tab geht
    einzeln durch `teardown(_ tab:reason:)`. Ist der angeklickte Tab nicht der
    aktive, wird er es danach.
  - `openTerminal` — **hier ist eine Messung nötig, bevor du etwas baust.**
    `openTerminalFromSidebar` ist NICHT der Weg: es ruft
    `connect(in:stored:paneVisibility:)` und baut damit eine **neue**
    Verbindung auf. Dieser Reiter ist bereits verbunden; gemeint ist, seinen
    Terminalbereich einzublenden. Stelle fest, wie die Sichtbarkeit der
    Bereiche an einem **laufenden** Reiter geändert wird, und benutze das.
    **Gibt es keinen solchen Weg, halte an und melde es**, statt einen zweiten
    Verbindungspfad zu bauen — ein Menüeintrag, der heimlich neu verbindet,
    wäre schlimmer als ein fehlender.
  - `saveAsSession` öffnet den bestehenden Speichern-Weg, vorbefüllt aus
    `values` des `ConnectionViewModel` dieses Tabs — **nicht** aus
    `lastConnectedConfig`, das ist ein `SSHConnectionConfig?` und trägt S3 und
    WebDAV nicht.
- [ ] **Step 4: Ein Wächter, der die Ansicht an den Wert bindet.** Er muss
  belegen, dass das Menü seine Einträge aus `TabContextMenu.entries` bezieht
  und nicht selbst entscheidet.

  **Bevor du den Anker wählst, frag dich, von WO aus die Eigenschaft „die
  Ansicht entscheidet nicht selbst über Sichtbarkeit" verletzt werden könnte,
  und zähl diese Orte auf.** Ein Wächter, der nach der Umsetzung geschrieben
  wird, ist auf die gerade geschriebenen Zeilen zugeschnitten; das ist der
  häufigste Fehler in diesem Projekt. Der Wächter muss **fail-closed** sein und
  eigene Selbsttests haben — Vorbilder sind die vier Wächter-Suiten unter
  `Tests/macSCPAppKitTests/` mit `stripCommentsAndStrings`.

  **Mutationsproben sind Pflicht:** pflanze für jeden aufgezählten Ort eine
  Verletzung und belege, dass der Wächter rot wird. Entferne jede Probe und
  prüfe `git status --porcelain` am Ende. Prüfe jede Probendatei vor dem Messen
  darauf, dass sie das enthält, was du beabsichtigt hast — eine kaputte Probe,
  die nicht kompiliert, sieht aus wie ein geschlossenes Loch.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `feat(tabs): give the tab a context menu`

---

### Task 5: Ziehen

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift`
- Test: `Tests/macSCPAppKitTests/` (Wächter aus Task 4 erweitern)

**Interfaces:**
- Consumes: `TabsViewModel.move(tabID:to:)` aus Task 2 — **dieselbe** Funktion,
  die das Menü ruft. Es entsteht keine zweite Umordnung.

- [ ] **Step 1:** `TabItemView` wird ziehbar und die Leiste nimmt einen Wurf an.
  Getragen wird die Tab-`UUID`; der Wurf berechnet die Zielposition und ruft
  `move(tabID:to:)`.
- [ ] **Step 2: Ein Wächter, dass das Ziehen dieselbe Funktion ruft.** Er muss
  eine zweite, eigene Umordnungslogik in der Ansicht ausschließen — genau das
  ist der Fehler, vor dem der Backlog-Eintrag warnt. Wieder mit Mutationsprobe
  belegen.
- [ ] **Step 3:** Ein Wurf außerhalb der Leiste lässt die Reihenfolge, wie sie
  war. Kein Herausziehen in ein neues Fenster — Mehrfenster ist v2.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 5: Commit** — `feat(tabs): reorder tabs by dragging them`

**Am Ende dieser Aufgabe ausdrücklich in den Bericht:** dass SwiftUI das Ziehen
auslöst und den Reiter an der erwarteten Stelle einfügt, **kann kein Test dieses
Projekts sehen**. Das ist eine Prüfung des Maintainers in der laufenden App und
wird nicht als „grün" verbucht.

---

## Was ausdrücklich nicht dazugehört

- Kein Umbenennen eines Reiters, kein „Rechts schließen" — beides
  Maintainer-Entscheidung vom 2026-08-27.
- Kein Wiederherstellen von Reitern über einen Neustart.
- Kein Herausziehen in ein neues Fenster — Mehrfenster ist v2.
- Keine Änderung an `fileActions` oder am Browser-Kontextmenü.
- Keine Antwort auf C2 („Sitzung ist schon offen") — eigener Backlog-Punkt.
