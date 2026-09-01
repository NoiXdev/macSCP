# M31 — Logging ad-hoc connections: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A connection that is not saved still writes an audit entry —
under a fixed pseudo-session, readable in the existing audit sheet.

**Architecture:** Attaching the `AuditRecorder` moves out of the save
branch; the session id comes from a small, tested Core type instead of
from the nesting. A menu entry opens the existing sheet with a synthetic
`StoredSession`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-19-m31-adhoc-audit-design.md`

## Global Constraints

- Code, comments, test names, commit messages: **English**. Internal docs
  (`docs/`) German.
- Conventional Commits, footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **User-visible strings go through `L10n.string`** and exist in **all
  four** languages (`en`, `de`, `fr`, `pl`) under
  `Sources/MacSCPAppKit/Resources/<lang>.lproj/Localizable.strings`. A
  guard test keeps the key sets equal.
- No secret in any message, not even a test failure message.
- TDD red→green. Suite: `swift test`.
- **The prose of this plan is a claim to be checked.** If a signature or a
  field name is wrong: report it, don't silently rebuild around it.

## Files

| File | Role |
|---|---|
| `Sources/macSCPCore/Sessions/AdHocAudit.swift` (new) | fixed pseudo-session id + the choice of log id |
| `Tests/macSCPCoreTests/AdHocAuditTests.swift` (new) | three tests for it |
| `Sources/MacSCPAppKit/ContentView.swift` | lift the recorder out of the save branch |
| `Sources/MacSCPAppKit/MacSCPApp.swift` | `TabCommands.showAdHocAuditLog` + menu entry |
| `Sources/MacSCPAppKit/ContentView+Detail.swift` | wire up the `showAdHocAuditLog` bridge |
| `Sources/MacSCPAppKit/Resources/*.lproj/Localizable.strings` | two keys × four languages |

---

### Task 1: The pseudo-session and the choice of log id (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/AdHocAudit.swift`
- Test: `Tests/macSCPCoreTests/AdHocAuditTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `AdHocAudit.sessionID: UUID` and
  `AdHocAudit.logSessionID(storedID: UUID?) -> UUID` — Task 2 calls both

- [ ] **Step 1: Write the three failing tests**

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

- [ ] **Step 2: Run the tests, confirm red**

```bash
swift test --filter "AdHocAuditTests"
```

Expected: FAIL, `cannot find 'AdHocAudit' in scope`.

- [ ] **Step 3: Create the type**

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

- [ ] **Step 4: Run the tests, confirm green**

```bash
swift test --filter "AdHocAuditTests"
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/AdHocAudit.swift Tests/macSCPCoreTests/AdHocAuditTests.swift
git commit -m "feat(core): give unsaved connections a fixed audit session id

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Un-nest the recorder, menu entry, L10n (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (in the submit path, at the `if form.shouldSaveSession { … }` block)
- Modify: `Sources/MacSCPAppKit/MacSCPApp.swift` (Sessions menu, after "Hidden Imports…")
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (wire up the bridge)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `AdHocAudit.sessionID`, `AdHocAudit.logSessionID(storedID:)` from Task 1
- Produces: nothing

- [ ] **Step 1: Lift the recorder out of the save branch**

Today the attaching sits INSIDE `if form.shouldSaveSession { … }`, in an
`if let stored { … }`. That is the defect: it logs because it saved. `stored`
moves ahead of the block, the attaching after it.

The summary stays **word-for-word** for the saved session, so nothing
changes in the log of a saved connection; only the ad-hoc case reads it
from the form, which is the only source there.

```swift
        var titleName = storedName
        var storedSession: StoredSession?
        if form.shouldSaveSession {
            // … unchanged up to and including `let stored = sessionListViewModel.save(…)` …
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

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: no errors. On a name or signature mismatch, the Global Constraint
applies: report it, don't guess around it.

- [ ] **Step 3: Add the two strings in all four languages**

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

- [ ] **Step 4: Declare and wire up the bridge**

The property first, otherwise Step 5 has nothing to call. In
`MacSCPApp.swift`, in `final class TabCommands`, next to `showSSHKeys`:

```swift
    /// Opens the ad-hoc connection log (M31). Its own entry rather than a
    /// parameter on the existing audit hook, because there is no session to
    /// pass -- the ad-hoc log's session is a value the App layer builds.
    var showAdHocAuditLog: (() -> Void)?
```

`ContentView+Detail.swift` sets it
(it already has `onShowAuditLog: { stored in auditLogSession = stored }`).
A new closure `showAdHocAuditLog` sets the same `@State` variable to the
synthetic session:

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

- [ ] **Step 5: Add the menu entry**

In `MacSCPApp.swift`, in the "Sessions" `CommandMenu`, directly after the
"Hidden Imports…" entry and BEFORE the `Divider()`:

```swift
                // "Ad-hoc Connection Log…" (M31): the audit trail of every
                // connection that was never saved. It has no sidebar row to
                // open it from -- its session is a value, not a record.
                Button(L10n.string("menu.adHocAuditLog", "Ad-hoc Connection Log…")) {
                    tabCommands.showAdHocAuditLog?()
                }
```

- [ ] **Step 6: Full suite**

```bash
swift test
```

Expected: PASS. The L10n guard fails if a key is missing in any of the
four languages — that is exactly its purpose.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacSCPAppKit
git commit -m "fix(app): log connections that were never saved

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Close-out

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-m31-abschluss.md`

**Interfaces:**
- Consumes: the commits from Task 1 and 2
- Produces: nothing

- [ ] **Step 1: Full suite, read the output BEFORE committing**

```bash
swift test
```

Note the test and suite count.

- [ ] **Step 2: Verify the attaching no longer sits in the save branch**

```bash
awk '/if form.shouldSaveSession \{/,/^        \}$/' Sources/MacSCPAppKit/ContentView.swift | grep -c "attachAuditRecorder" | sed 's/^0$/0 (no longer in the branch)/'
```

Expected: `0 (no longer in the branch)`. Positive control against a tool
that does not notice its own failure: the same command without the
`awk` excerpt must very well find `attachAuditRecorder` —

```bash
grep -c "attachAuditRecorder" Sources/MacSCPAppKit/ContentView.swift
```

Expected: at least 1. If this number is 0, the first command is measuring
nothing and its "success" is worthless.

- [ ] **Step 3: Write the close-out report**

`docs/superpowers/specs/2026-08-19-m31-abschluss.md`, German: what was
implemented, the result of Step 2, the suite counts, and explicitly what
remains open (no global audit view; the visual check of the menu entry
and the sheet is pending with the maintainer, because no test starts the
GUI).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-m31-abschluss.md
git commit -m "docs(m31): record the close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
