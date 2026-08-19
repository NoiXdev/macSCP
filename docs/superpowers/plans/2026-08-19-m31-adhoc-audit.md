# M31 — Ad-hoc-Verbindungen protokollieren: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine Verbindung, die nicht gespeichert wird, schreibt trotzdem
einen Audit-Eintrag — unter einer festen Pseudo-Sitzung, lesbar im
bestehenden Audit-Sheet.

**Architecture:** Das Anhängen des `AuditRecorder` wandert aus dem
Speicher-Zweig heraus; die Sitzungs-ID kommt aus einem kleinen, getesteten
Core-Typ statt aus der Verschachtelung. Ein Menüeintrag öffnet das
vorhandene Sheet mit einer synthetischen `StoredSession`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-19-m31-adhoc-audit-design.md`

## Global Constraints

- Code, Kommentare, Testnamen, Commit-Messages: **Englisch**. Interne Doku
  (`docs/`) Deutsch.
- Conventional Commits, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Nutzer-sichtbare Strings gehen durch `L10n.string`** und existieren in
  **allen vier** Sprachen (`en`, `de`, `fr`, `pl`) unter
  `Sources/MacSCPAppKit/Resources/<lang>.lproj/Localizable.strings`. Ein
  Wächter-Test hält die Schlüsselmengen gleich.
- Kein Geheimnis in einer Meldung, auch nicht in einer Test-Fehlermeldung.
- TDD rot→grün. Suite: `swift test`.
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung.** Stimmt eine
  Signatur oder ein Feldname nicht: melden, nicht still umbauen.

## Dateien

| Datei | Rolle |
|---|---|
| `Sources/macSCPCore/Sessions/AdHocAudit.swift` (neu) | feste Pseudo-Sitzungs-ID + die Wahl der Log-ID |
| `Tests/macSCPCoreTests/AdHocAuditTests.swift` (neu) | drei Tests dazu |
| `Sources/MacSCPAppKit/ContentView.swift` | Recorder aus dem Speicher-Zweig heben |
| `Sources/MacSCPAppKit/MacSCPApp.swift` | `TabCommands.showAdHocAuditLog` + Menüeintrag |
| `Sources/MacSCPAppKit/ContentView+Detail.swift` | Brücke `showAdHocAuditLog` verdrahten |
| `Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings` | zwei Schlüssel × vier Sprachen |

---

### Task 1: Die Pseudo-Sitzung und die Wahl der Log-ID (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/AdHocAudit.swift`
- Test: `Tests/macSCPCoreTests/AdHocAuditTests.swift`

**Interfaces:**
- Consumes: nichts
- Produces: `AdHocAudit.sessionID: UUID` und
  `AdHocAudit.logSessionID(storedID: UUID?) -> UUID` — Task 2 ruft beide

- [ ] **Step 1: Die drei fehlschlagenden Tests schreiben**

```swift
import Foundation
import Testing
@testable import macSCPCore

/// M31: an unsaved connection has no `StoredSession` and therefore had no
/// session id to log against, so it logged nothing at all -- including the
/// M21 plaintext-transport note. These pin the one decision that fixes
/// that: which id a connect writes its audit trail under.
@Suite("Ad-hoc audit")
struct AdHocAuditTests {
    /// Both directions, so neither a hardcoded stored id nor a hardcoded
    /// ad-hoc id satisfies the pair.
    @Test func aStoredSessionLogsUnderItsOwnID() {
        let stored = UUID()
        #expect(AdHocAudit.logSessionID(storedID: stored) == stored)
    }

    @Test func anUnsavedConnectionLogsUnderTheAdHocID() {
        #expect(AdHocAudit.logSessionID(storedID: nil) == AdHocAudit.sessionID)
    }

    /// The id must be the SAME across calls -- a freshly generated one per
    /// connect would scatter the ad-hoc trail across logs no screen can
    /// reach, which is the very gap this milestone closes.
    @Test func theAdHocIDIsStableAcrossCalls() {
        #expect(AdHocAudit.logSessionID(storedID: nil)
                == AdHocAudit.logSessionID(storedID: nil))
    }
}
```

- [ ] **Step 2: Tests laufen lassen, Rot bestätigen**

```bash
swift test --filter "AdHocAuditTests"
```

Erwartet: FAIL, `cannot find 'AdHocAudit' in scope`.

- [ ] **Step 3: Den Typ anlegen**

```swift
import Foundation

/// Where a connection that was never saved writes its audit trail (M31).
///
/// The audit log is keyed by session id, and an unsaved connection has no
/// `StoredSession` -- so until now the whole trail was skipped, the M21
/// plaintext-transport note included. One FIXED id gives every such
/// connection the same log, which the existing per-session audit sheet can
/// show like any other.
///
/// It is a value, not a record: nothing writes it to `sessions.json`, it has
/// no sidebar row, and it can be neither connected to, renamed, deleted nor
/// exported. Entries stay distinguishable because `recordConnected(summary:)`
/// already puts host and user into the detail text.
public enum AdHocAudit {
    /// Hardcoded rather than derived: a derived id would change whenever its
    /// input changed, and an ad-hoc log that silently moves to a new id is
    /// an unreachable log.
    public static let sessionID = UUID(uuidString: "AD400C00-0000-4000-8000-000000000001")!

    /// The id this connect should log under. The one place that decides it,
    /// so no call site has to remember the rule -- and the reason it lives
    /// here rather than in the view: `ContentView` has no tests.
    public static func logSessionID(storedID: UUID?) -> UUID {
        storedID ?? sessionID
    }
}
```

- [ ] **Step 4: Tests laufen lassen, Grün bestätigen**

```bash
swift test --filter "AdHocAuditTests"
```

Erwartet: PASS (3 Tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/AdHocAudit.swift Tests/macSCPCoreTests/AdHocAuditTests.swift
git commit -m "feat(core): give unsaved connections a fixed audit session id

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Recorder un-verschachteln, Menüeintrag, L10n (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (im Submit-Pfad, am Block `if form.shouldSaveSession { … }`)
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (Sessions-Menü, nach „Hidden Imports…")
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (Brücke verdrahten)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `AdHocAudit.sessionID`, `AdHocAudit.logSessionID(storedID:)` aus Task 1
- Produces: nichts

- [ ] **Step 1: Den Recorder aus dem Speicher-Zweig heben**

Heute steht das Anhängen INNERHALB von `if form.shouldSaveSession { … }`, in
einem `if let stored { … }`. Das ist der Defekt: protokolliert wird, weil
gespeichert wurde. `stored` wandert vor den Block, das Anhängen dahinter.

Die Zusammenfassung bleibt für die gespeicherte Sitzung **wortgleich**, damit
sich am Log einer gespeicherten Verbindung nichts ändert; nur der Ad-hoc-Fall
liest sie aus dem Formular, das dort die einzige Quelle ist.

```swift
        var titleName = storedName
        var storedSession: StoredSession?
        if form.shouldSaveSession {
            // … unverändert bis einschließlich `let stored = sessionListViewModel.save(…)` …
            storedSession = stored
            tab.activeStoredSessionID = stored?.id
            form.shouldSaveSession = false
            titleName = stored?.name ?? titleName
        }
        // M31: attaching the recorder used to sit INSIDE the branch above, so
        // the audit trail depended on whether the connection was SAVED rather
        // than on whether it happened. An unsaved connect logged nothing at
        // all -- not even the M21 plaintext-transport note, which
        // `attachAuditRecorder` writes.
        //
        // `displaySummary` (M22/T11), not host/username directly: a legacy S3
        // or WebDAV session still carries the `"unused"` placeholder in those
        // two, which is what used to leave "connected to unused as unused" in
        // the trail for anything but SSH.
        //
        // `form.jumpHost` (M-1 fix, final review), not `stored.jump?.host`:
        // for a session-mode jump it already holds the freshly resolved host,
        // and it is the one field guaranteed to be current in both connect
        // paths.
        let auditDescriptor = BackendDescriptor.descriptor(
            for: storedSession?.kind ?? form.kind)
        attachAuditRecorder(
            to: tab,
            sessionID: AdHocAudit.logSessionID(storedID: storedSession?.id),
            summary: storedSession.map {
                auditDescriptor.displaySummary(auditDescriptor.sessionValues($0))
            } ?? auditDescriptor.displaySummary(form.values),
            viaJumpHost: form.jumpEnabled ? form.jumpHost : nil)
```

- [ ] **Step 2: Bauen**

```bash
swift build
```

Erwartet: keine Fehler. Bei einem Namens- oder Signaturfehler gilt die
Global-Constraint: melden, nicht danebengreifen.

- [ ] **Step 3: Die zwei Strings in allen vier Sprachen anlegen**

In `Sources/MacSCPAppKit/Resources/<lang>.lproj/Localizable.strings`:

```
en:
"menu.adHocAuditLog" = "Ad-hoc Connection Log…";
"audit.adhoc.name" = "Ad-hoc connections";

de:
"menu.adHocAuditLog" = "Protokoll der Ad-hoc-Verbindungen…";
"audit.adhoc.name" = "Ad-hoc-Verbindungen";

fr:
"menu.adHocAuditLog" = "Journal des connexions ad hoc…";
"audit.adhoc.name" = "Connexions ad hoc";

pl:
"menu.adHocAuditLog" = "Dziennik połączeń doraźnych…";
"audit.adhoc.name" = "Połączenia doraźne";
```

- [ ] **Step 4: Die Brücke deklarieren und verdrahten**

Zuerst die Eigenschaft, sonst hat Step 5 nichts zum Aufrufen. In
`MacSCPApp.swift`, in `final class TabCommands`, neben `showSSHKeys`:

```swift
    /// Opens the ad-hoc connection log (M31). Its own entry rather than a
    /// parameter on the existing audit hook, because there is no session to
    /// pass -- the ad-hoc log's session is a value the App layer builds.
    var showAdHocAuditLog: (() -> Void)?
```

`ContentView+Detail.swift` setzt sie
(dort steht bereits `onShowAuditLog: { stored in auditLogSession = stored }`).
Eine neue Closure `showAdHocAuditLog` setzt dieselbe `@State`-Variable auf die
synthetische Sitzung:

```swift
        // M31: the ad-hoc log is reached from the menu rather than from a
        // sidebar row, because its session is a VALUE, not a record -- there
        // is no row to right-click. `AuditLogSheet` needs nothing from this
        // session but its id and its name.
        tabCommands.showAdHocAuditLog = {
            auditLogSession = StoredSession(
                id: AdHocAudit.sessionID,
                name: L10n.string("audit.adhoc.name", "Ad-hoc connections"),
                kind: .ssh)
        }
```

- [ ] **Step 5: Den Menüeintrag ergänzen**

In `MacSCPApp.swift`, im `CommandMenu` „Sessions", direkt nach dem
„Hidden Imports…"-Eintrag und VOR dem `Divider()`:

```swift
                // "Ad-hoc Connection Log…" (M31): the audit trail of every
                // connection that was never saved. It has no sidebar row to
                // open it from -- its session is a value, not a record.
                Button(L10n.string("menu.adHocAuditLog", "Ad-hoc Connection Log…")) {
                    tabCommands.showAdHocAuditLog?()
                }
```

- [ ] **Step 6: Volle Suite**

```bash
swift test
```

Erwartet: PASS. Der L10n-Wächter fällt aus, wenn ein Schlüssel in einer der
vier Sprachen fehlt — das ist genau sein Zweck.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacSCPAppKit
git commit -m "fix(app): log connections that were never saved

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-m31-abschluss.md`

**Interfaces:**
- Consumes: die Commits aus Task 1 und 2
- Produces: nichts

- [ ] **Step 1: Volle Suite, Ausgabe lesen BEVOR committet wird**

```bash
swift test
```

Test- und Suitenzahl notieren.

- [ ] **Step 2: Prüfen, dass das Anhängen nicht mehr im Speicher-Zweig hängt**

```bash
awk '/if form.shouldSaveSession \{/,/^        \}$/' Sources/MacSCPAppKit/ContentView.swift | grep -c "attachAuditRecorder" | sed 's/^0$/0 (nicht mehr im Zweig)/'
```

Erwartet: `0 (nicht mehr im Zweig)`. Positivkontrolle gegen ein Werkzeug, das
seinen eigenen Ausfall nicht bemerkt: derselbe Befehl ohne den
`awk`-Ausschnitt muss `attachAuditRecorder` sehr wohl finden —

```bash
grep -c "attachAuditRecorder" Sources/MacSCPAppKit/ContentView.swift
```

Erwartet: mindestens 1. Ist diese Zahl 0, misst der erste Befehl nichts und
sein „Erfolg" ist wertlos.

- [ ] **Step 3: Abschlussbericht schreiben**

`docs/superpowers/specs/2026-08-19-m31-abschluss.md`, Deutsch: was umgesetzt
wurde, das Ergebnis von Step 2, die Suite-Zahlen, und ausdrücklich, was
offen bleibt (keine globale Audit-Ansicht; die Sichtprüfung des Menüeintrags
und des Sheets steht beim Maintainer aus, weil kein Test die GUI startet).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-m31-abschluss.md
git commit -m "docs(m31): record the close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
