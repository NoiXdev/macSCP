# Polish: the Terminal Follows the Window; Transfers Cancel and Show Their Paths — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three of the maintainer's notes of 2026-09-02, chosen first:
(1) the terminal does not resize with the window — a bug, measured
before it is touched; (7) cancel active transfers, one and all, beside
the "Clean up" button; (9) the full source and destination paths of a
transfer row, visible on demand.

**Architecture:**

*Terminal.* The resize path exists end to end and is worth reading
before believing the bug is where it seems: SwiftTerm's `TerminalView`
calls `TerminalViewDelegate.sizeChanged(source:newCols:newRows:)`
(`Sources/MacSCPAppKit/SSHTerminalView.swift:203`) →
`TerminalPanelViewModel.resize(cols:rows:)`
(`Presentation/TerminalPanelViewModel.swift:250`) →
`CitadelShell.resize` → `TTYStdinWriter.changeSize` → an SSH
`WindowChangeRequest`. So a terminal that keeps its size has one of
three causes, and Task 1 measures which: (a) the AppKit view never gets
a new frame (the `NSViewRepresentable` is created with `frame: .zero`
and SwiftUI may not be constraining it to its container), so SwiftTerm
never recomputes cols/rows; (b) SwiftTerm recomputes but the delegate
call does not reach the view model (a coordinator swap, an `assumeIsolated`
that throws, a guard in `resize`); (c) the window-change request is sent
but the remote side ignores it (then `stty size` inside the shell shows
the old size — that is the one measurement a human at the app can do,
and the implementer asks for it in the report rather than launching the
GUI). The fix is written only after (a)/(b)/(c) is named.

*Transfers.* `TransferQueueViewModel` has `cancelAll(reason:)` today
(teardown, connection lost) and per-item state; the bar
(`Sources/MacSCPAppKit/TransferQueueBar.swift`) has "Clean up" →
`clearCompleted()`. Two actions beside it: "Cancel all" (every item that
is queued or running, reason `.userRequested` — a new `CancelReason` case
if none fits; read the enum) and per-row "Cancel" for a queued/running
item (a `cancel(itemID:)` that exists or is added on the view model,
honouring the queue's invariants: exactly-once waiter continuations,
`onCompleted` once per group, no orphaned shells — the queue's own tests
say how). "Full paths": the row shows source and destination as today
(names); a disclosure/tooltip/expanded row shows the full remote and
local paths — one presentation value, `TransferRowPaths`, computed in
Core from the item so the App renders and the CLI's `transfers` output (if
any) could reuse it; copyable.

**Tech Stack:** SwiftTerm (`.build/checkouts/SwiftTerm`), `SSHTerminalView`,
`TerminalPanelViewModel`, `CitadelShell`; `TransferQueueViewModel`,
`TransferQueueBar`, four App catalogs; Swift Testing; the App test target
can instantiate real views ("A real MacSCPAppKit view can be
instantiated from the test target" is an existing test).

**Source:** `docs/superpowers/specs/2026-09-02-backlog-maintainer-notes.md`
items 1, 7, 9 and its "Decided" section.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **The terminal bug is measured before it is fixed** (systematic
  debugging): Task 1 ends with a named cause and a red test that shows
  it; no fix without that.
- **Transfer-queue invariants hold** (CLAUDE.md): FIFO start, exactly-once
  waiter continuations, `cancelAll` leaves no orphaned shells/transfers,
  group `onCompleted` fires exactly once — the existing queue tests stay
  green and a cancel-one test pins the same properties for one item.
- Four App catalogs, du-form German, parity guards.
- No GUI launch by the implementer; a human measurement (`stty size`) is
  asked for in the report, not performed.
- Swift 6; warning budget 1; TDD red first; commit per task; do not push.

---

### Task 1: Measure why the terminal keeps its size

**Files:**
- Test: `Tests/macSCPAppKitTests/SSHTerminalViewSizingTests.swift` — build
  the real `SSHTerminalView` through its `makeNSView`/coordinator (read
  how the existing "real view" test does it), give the `TerminalView` a
  frame of 800×600 then 1200×900 (set `frame`, call `layoutSubtreeIfNeeded`),
  and assert the coordinator received `sizeChanged` with larger cols/rows
  — through a recording `TerminalPanelViewModel` double or by observing
  the view model's last `resize(cols:rows:)` (read what it stores). Also a
  second assertion at the view-model level: `resize` forwards to the shell
  (a fake `RemoteShell` records the call).
- [ ] **Step 1:** Run it. Three outcomes: the view never calls
  `sizeChanged` after a frame change → cause (a); it calls but the shell
  double sees nothing → cause (b); both fire → cause (c), and the report
  asks the maintainer for `stty size` before/after a resize in the app.
  Write the outcome into the report and the plan's ledger BEFORE any fix.
- [ ] **Step 2:** Fix the named cause — (a): make the representable size
  itself to its container (`translatesAutoresizingMaskIntoConstraints`,
  `autoresizingMask = [.width, .height]`, or SwiftUI's `sizeThatFits`) and
  keep the red test as the pin; (b): the guard/hop that swallows the call;
  (c): stop — it is the remote side, and the entry gets the measurement.
- [ ] **Step 3: Commit** — `fix(terminal): the terminal follows the window` (or `docs(spec): …` if (c)).

### Task 2: Cancel one, cancel all

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
  (`cancel(itemID:)` for a queued or running item; `cancelAll(reason: .userRequested)`
  or the existing reason that fits — read `CancelReason`; both honour the
  invariants), `Sources/MacSCPAppKit/TransferQueueBar.swift` ("Cancel all"
  beside "Clean up", enabled only while something is queued or running;
  a per-row cancel button for queued/running rows), four App catalogs
  (`transfers.cancelAll`, `transfers.cancel`).
- Test: `TransferQueueViewModelTests` — cancel one running item: it ends
  `.cancelled`, its waiter continuation resumed exactly once, the next
  queued item starts (FIFO), the group's `onCompleted` fires once; cancel
  one queued item: never starts; cancel all with a mix; the bar's
  enabling pinned the way the bar's other buttons are.
- [ ] Red → green → commit `feat(transfers): cancel one transfer, or all of them`

### Task 3: Full paths in a row

**Files:**
- Create: `Sources/macSCPCore/Presentation/TransferRowPaths.swift`
  (`struct TransferRowPaths { let source: String; let destination: String }`
  from an `Item`, remote paths as the session shows them (`name:/path`
  style is the CLI's; here the plain remote path plus the session name),
  local paths as absolute file paths)
- Modify: `TransferQueueBar.swift` (a disclosure or tooltip on the row
  showing both full paths; "Copy paths" in the row's context menu), catalogs.
- Test: `TransferRowPathsTests` (an SSH→local download, a local→S3 upload,
  a cross-session transfer: both paths named with their sessions).
- [ ] Red → green → commit `feat(transfers): a row can show its full source and destination`

### Task 4: Closeout

- [ ] `docs/superpowers/specs/2026-09-02-backlog-maintainer-notes.md`
  (items 1, 7, 9 → Done, with Task 1's measured cause), `docs/BACKLOG.md`
  row; commit `docs(backlog): terminal resize measured and fixed; transfers cancel and show paths`.

## What is explicitly not in this plan

- The other eight small notes and the ten features.
- No change to the queue's slot count or ordering.
