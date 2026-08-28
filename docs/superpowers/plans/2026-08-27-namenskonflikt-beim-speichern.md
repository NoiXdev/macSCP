# Namenskonflikt beim Speichern — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein vorbefüllter Sitzungsname überschreibt keine fremde Sitzung mehr, und ein getippter tut es nur noch sichtbar.

**Grundlage:** `docs/superpowers/specs/2026-08-27-namenskonflikt-beim-speichern-design.md`

**Architektur:** Zwei reine Werte in `macSCPCore` — „kollidiert dieser Name?" und „welcher Name ist frei?" — plus ihre Verdrahtung. `SessionListViewModel.save` wird **nicht** angefasst; sein Upsert über den Namen bleibt.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**;
  Katalogwerte sind Übersetzungen, das Deutsche duzt.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Alle vier Kataloge** (`en`, `de`, `fr`, `pl` unter
  `Sources/MacSCPAppKit/Resources/`), gleiche Schlüsselmengen.
- **Was der Nutzer tippt, wird nie verändert.** Ein Vorschlag darf ausweichen,
  eine Eingabe nicht.
- **Die Ausweich-Regel muss denselben Vergleich benutzen wie `save`.** `save`
  sucht mit `sessions.first(where: { $0.name == name })`, also exakt und mit
  Groß-/Kleinschreibung. Ein anderer Vergleich in der Regel erzeugt genau den
  Fehler, den dieser Vorgang beseitigen soll.
- **Kein Test erreicht echten Keychain, Sitzungs-Store oder Konfiguration.**
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot, sobald
  die Zahl eindeutiger Warnorte über 1 liegt.**
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und jede
  Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Die zwei Regeln in Core

**Files:**
- Create: `Sources/macSCPCore/Sessions/SessionNameCollision.swift`
- Test: `Tests/macSCPCoreTests/SessionNameCollisionTests.swift`

**Interfaces:**
- Produces:
  `SessionNameCollision.collides(_ name: String, with existing: [StoredSession], excluding: UUID?) -> StoredSession?`
  und
  `SessionNameCollision.freeName(basedOn desired: String, avoiding existing: [StoredSession]) -> String`.
  Task 2 ruft beide.

**Warum ein eigener Typ und nicht zwei Zeilen an den Aufrufstellen:** es gibt
zwei Wege, die einen Namen erfinden. Zwei Kopien der Regel weichen früher oder
später verschieden aus, und die Falle oben (derselbe Vergleich wie `save`) muss
an genau einer Stelle stimmen, nicht an zweien.

- [ ] **Step 1: Den Test zuerst schreiben.**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Session name collision")
struct SessionNameCollisionTests {
    private func session(_ name: String) -> StoredSession {
        StoredSession(id: UUID(), name: name, kind: .ssh)
    }

    @Test func aFreeNameIsReturnedUnchanged() {
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("other")]) == "web")
    }

    @Test func aTakenNameStepsAsideToTheNextNumber() {
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("web")]) == "web 2")
    }

    @Test func itKeepsCountingWhileTheAlternativesAreAlsoTaken() {
        let taken = [session("web"), session("web 2"), session("web 3")]
        #expect(SessionNameCollision.freeName(basedOn: "web", avoiding: taken) == "web 4")
    }

    @Test func aNameThatAlreadyEndsInANumberIsNotReinterpreted() {
        // "web 2" is a name in its own right, not "web" at number two: the
        // rule appends, it does not parse what it was given.
        #expect(SessionNameCollision.freeName(
            basedOn: "web 2", avoiding: [session("web 2")]) == "web 2 2")
    }

    @Test func theComparisonIsExactBecauseSaveIsExact() {
        // `SessionListViewModel.save` matches with `==`. A rule that treated
        // "Web" as taken would step aside from a name that saving would have
        // left alone — and one that treated "web" as free when "Web" exists
        // would still overwrite. Both directions are wrong.
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("Web")]) == "web")
    }

    @Test func collisionReportsTheSessionThatWouldBeReplaced() {
        let target = session("web")
        let found = SessionNameCollision.collides(
            "web", with: [session("other"), target], excluding: nil)
        #expect(found?.id == target.id)
    }

    @Test func noCollisionIsReportedForAFreeName() {
        #expect(SessionNameCollision.collides(
            "web", with: [session("other")], excluding: nil) == nil)
    }

    @Test func theSessionBeingEditedIsNotACollisionWithItself() {
        let editing = session("web")
        #expect(SessionNameCollision.collides(
            "web", with: [editing], excluding: editing.id) == nil)
    }

    @Test func editingStillCollidesWithADifferentSessionOfThatName() {
        let editing = session("old")
        let other = session("web")
        let found = SessionNameCollision.collides(
            "web", with: [editing, other], excluding: editing.id)
        #expect(found?.id == other.id)
    }
}
```

- [ ] **Step 2: Rot laufen lassen.**

Run: `swift test --filter SessionNameCollision`
Erwartet: FAIL, `cannot find 'SessionNameCollision' in scope`.

- [ ] **Step 3: Umsetzen.**

```swift
import Foundation

/// Two questions about a session name, asked in one place because two call
/// sites need them and a second copy would drift.
///
/// Both use the SAME comparison `SessionListViewModel.save` uses to find the
/// session it overwrites — exact, case sensitive. That is the point rather
/// than an implementation detail: a rule that judged names differently than
/// saving does would either step aside from a name saving would have left
/// alone, or call a name free that saving then overwrites.
public enum SessionNameCollision {
    /// The session `name` would replace, or `nil` if none. `excluding` is the
    /// session currently being edited: a form editing a stored session shows
    /// that session's own name, and warning that it replaces itself would
    /// make the warning appear always — and an always-visible warning stops
    /// being read.
    public static func collides(
        _ name: String, with existing: [StoredSession], excluding: UUID?
    ) -> StoredSession? {
        existing.first { $0.name == name && $0.id != excluding }
    }

    /// `desired` if it is free, otherwise the first free `"<desired> N"`.
    ///
    /// Only for names macSCP invents. What the user typed is never rewritten:
    /// an app that silently edits typed text is worse than one that
    /// overwrites, because afterwards nobody trusts what they type.
    ///
    /// The suffix is appended, never parsed: `"web 2"` is a name in its own
    /// right, so the next free form of it is `"web 2 2"` rather than
    /// `"web 3"`. Parsing would guess at what a name means.
    public static func freeName(
        basedOn desired: String, avoiding existing: [StoredSession]
    ) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains(desired) else { return desired }
        var counter = 2
        while taken.contains("\(desired) \(counter)") { counter += 1 }
        return "\(desired) \(counter)"
    }
}
```

- [ ] **Step 4: Grün laufen lassen.** `swift test --filter SessionNameCollision`
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `feat(sessions): decide when a session name collides`

---

### Task 2: Verdrahten

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (Vorbefüllung
  „Als Sitzung speichern"), `Sources/MacSCPAppKit/ContentView.swift`
  (Vorbefüllung ssh-config-Import), `Sources/MacSCPAppKit/ConnectionFormView.swift`
  (die Warnung)
- Modify: alle vier `Localizable.strings`

**Interfaces:**
- Consumes: beide Funktionen aus Task 1.

**Der gemessene Ist-Zustand:** `saveName` wird an drei Stellen gesetzt — beim
Bearbeiten aus `stored.name` (**bleibt unangetastet**, das *ist* diese
Sitzung), bei „Als Sitzung speichern" aus `tab.displayTitle`, und beim
ssh-config-Import aus `host.alias`. Die letzten beiden erfinden einen Namen.
`ConnectionViewModel.mode` ist `FormMode.edit(sessionID: UUID)` im
Bearbeiten-Fall und liefert die auszunehmende ID.

- [ ] **Step 1: Die zwei erfundenen Namen ausweichen lassen.** Beide Stellen
  setzen künftig `SessionNameCollision.freeName(basedOn:avoiding:)` statt des
  rohen Namens. **Die dritte Stelle nicht anfassen** — beim Bearbeiten würde
  ein Ausweichen die Sitzung umbenennen, statt sie zu aktualisieren.
- [ ] **Step 2: Die Warnung.** Das Formular zeigt, wenn der eingetragene Name
  eine vorhandene Sitzung trifft, welche das ist — und dass Speichern sie
  ersetzt. Die auszunehmende ID kommt aus `mode`; im `.new`-Fall ist sie `nil`.
  **Die Warnung blockiert nicht** — kein `.disabled` am Speichern-Knopf.
- [ ] **Step 3: Der Text.** Ein Schlüssel in alle vier Kataloge, der die
  betroffene Sitzung benennt. Das Deutsche duzt. Trägt der Text die Zahl der
  Sitzungen nicht, genügt eine `.strings`-Zeile; trägt er einen Namen, ist das
  ein Argument und der Schlüssel bekommt seinen Platzhalter im Namen, wie es
  die bestehenden Schlüssel dieses Projekts tun.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 5: Commit** — `feat(sessions): say when saving would replace another session`

---

## Was ausdrücklich nicht dazugehört

- **Keine Änderung an `SessionListViewModel.save`.** Das Upsert über den Namen
  bleibt, einschließlich der Protokollkonvertierung, die sein Kommentar
  beschreibt.
- **Kein Blockieren** des Speicherns auf einen vorhandenen Namen.
- **Kein Umbenennen bestehender Sitzungen**, und kein Ausweichen bei einem
  Namen, den der Nutzer selbst getippt hat.
- Keine Eindeutigkeitsregel im Store: zwei Sitzungen dürfen weiterhin denselben
  Namen tragen, wenn sie anders dorthin gelangt sind.
