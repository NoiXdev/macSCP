# Tab Context Menu and Reordering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tab gets a context menu, and the order of the tabs can be changed both via the menu and by dragging.

**Basis:** `docs/superpowers/specs/2026-08-27-tab-context-menu-and-reorder-design.md`

**Architecture:** The decidable parts — which entries appear, what reordering does to the order, what the bulk warning says — live as pure values in `macSCPCore` and are tested there. The view only draws and makes no decision of its own. Reordering exists **once**; both ways of operating it call the same function.

**Order:** first the values (testable), then the wiring (not testable).

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**;
  catalog values are translations, the German addresses the user as "du".
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **All four catalogs** for new strings (`en`, `de`, `fr`, `pl` under
  `Sources/MacSCPAppKit/Resources/`), same key sets.
- All six targets are set to `.swiftLanguageMode(.v6)`. **CI turns red as soon as
  the count of distinct warning sites exceeds 1** — no new warning is allowed
  to remain.
- **Green locally is not evidence about CI.** This machine has Swift 6.3.3, CI has an
  older toolchain whose region analysis is less precise and thus stricter in practice.
  A statement about a **type** (`Sendable` wrapper) reads the same on both;
  `nonisolated(unsafe)` on a binding says nothing about what a closure
  captures.
- **No line numbers, no location references in comments.** Every number and every
  enumeration of call sites is counted in the pass that writes it.
- **No test reaches the real keychain, session store, or configuration.**
- Teardown exclusively via `teardown(_ tab:reason:)` — the
  architecture invariant (cancel queue → shut down terminal →
  disconnect) must not be bypassed.
- The app is not launched, nothing is pushed, `scripts/release` does not run.

---

### Task 1: The menu as a testable value

**Files:**
- Create: `Sources/macSCPCore/Presentation/TabContextMenu.swift`
- Test: `Tests/macSCPCoreTests/TabContextMenuTests.swift`

**Interfaces:**
- Produces: `TabMenuEntry` (Enum, `Equatable`, `Sendable`) and
  `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:) -> [TabMenuEntry]`.
  Task 4 renders the menu from it.

**Model:** `Sources/macSCPCore/Presentation/BrowserContextMenu.swift` — the same
shape (enum in display order, one `static func entries`, decision in
Core instead of in the view). Read the file before you start.

**One decision that is derived from the design and that you should name in
the report:** "Open Terminal" is gated on `supportsShell` **and**
`isConnected`. The design names the protocol for visibility, but carries
`isConnected` as an input — and a terminal without a standing connection does
not exist.

- [ ] **Step 1: Write the test first.**

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

- [ ] **Step 2: Run red.**

Run: `swift test --filter TabContextMenu`
Expected: FAIL, `cannot find 'TabContextMenu' in scope`.

- [ ] **Step 3: Implement.**

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

- [ ] **Step 4: Run green.**

Run: `swift test --filter TabContextMenu`
Expected: PASS, eight tests.

- [ ] **Step 5: Full suite green, no new warning.**

Run: `swift test` and `swift build --build-tests`

- [ ] **Step 6: Commit** — `feat(tabs): model the tab context menu as a tested value`

---

### Task 2: Reordering in `TabsViewModel`

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TabsViewModel.swift`
- Test: `Tests/macSCPCoreTests/TabsViewModelTests.swift`

**Interfaces:**
- Produces: `TabsViewModel.move(tabID:to:)`. Task 4 calls it with ±1 from
  the menu, Task 5 with the drop position from dragging.

**The measured current state:** `TabsViewModel` is `@MainActor`, `@Observable`,
generic over `Tab: Identifiable where Tab.ID == UUID`, and holds
`tabs` as well as `activeTabID` as `private(set)`. `activeTab` looks up via
`activeTabID` — that is why the active tab stays active as long as nobody
touches `activeTabID`. **Do not touch it.**

- [ ] **Step 1: Write the test first.** Extend the existing file; stick to
  its existing test-payload type instead of introducing a second one.

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

- [ ] **Step 2: Run red.**

Run: `swift test --filter TabsViewModel`
Expected: FAIL, `value of type 'TabsViewModel<TestTab>' has no member 'move'`.

- [ ] **Step 3: Implement.** Insert directly after `addTab`:

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

- [ ] **Step 4: Run green.**

Run: `swift test --filter TabsViewModel`
Expected: PASS.

- [ ] **Step 5: Full suite green, no new warning.**
- [ ] **Step 6: Commit** — `feat(tabs): reorder tabs through one rule in the view model`

---

### Task 3: The bulk warning

**Files:**
- Modify: `Sources/MacSCPAppKit/TabCloseWarning.swift`
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/TabCloseWarningTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1 and 2.
- Produces: `TabCloseWarning.bulkMessage(tabsClosing:transferring:incoming:) -> String`,
  `TabCloseWarning.transferringCount(among:) -> Int` and
  `TabCloseWarning.incomingCount(among:in:) -> Int`. Task 4 calls all three.

**The measured current state:** `TabCloseWarning` currently has two functions —
`hasIncomingTransfers(for:in:)` (`@MainActor`, because `SessionTab` is) and
`message(activeTransfers:incomingTransfers:)` (free of isolation, because it does
not need it). Keep that split: the counting is `@MainActor`, the wording is not.

- [ ] **Step 1: Write the test first.** Extend the existing file:

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

- [ ] **Step 2: Run red.**

Run: `swift test --filter TabCloseWarning`
Expected: FAIL, `type 'TabCloseWarning' has no member 'bulkMessage'`.

- [ ] **Step 3: Implement.** Add to `TabCloseWarning`:

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

**About `isActive`, so you do not have to search for it:** `hasActiveItems` only exists
with `destinationTabID:`; for "this tab is transferring itself"
`requestClose` in `ContentView+Lifecycle` reads exactly `tab.transferQueue.isActive`.
Use the same source, so the single and bulk warnings do not diverge.

- [ ] **Step 4:** The two new keys into **all four** catalogs, same
  key set. The German addresses the user as "du".
- [ ] **Step 5: Run green.** `swift test --filter TabCloseWarning`
- [ ] **Step 6:** Full suite green, no new warning.
- [ ] **Step 7: Commit** — `feat(tabs): ask once before closing several tabs`

---

### Task 4: Wire the menu up

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`
- Modify: all four `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/` (new guard file)

**Interfaces:**
- Consumes: `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:)`
  from Task 1, `TabsViewModel.move(tabID:to:)` from Task 2,
  `TabCloseWarning.bulkMessage(tabsClosing:transferring:incoming:)` from Task 3.

**The measured current state:** `TabStripView` currently has **no** `contextMenu`.
`TabItemView` already carries `.onTapGesture(perform: onActivate)` and a
close button with `onClose`.

- [ ] **Step 1:** `TabItemView` gets a `.contextMenu` that **exclusively**
  iterates over the result of `TabContextMenu.entries(…)`. No `if` in the
  view about whether an entry appears — that decision was made and tested
  in Task 1. The view maps `TabMenuEntry` to title and action.
- [ ] **Step 2:** Six title keys into all four catalogs:
  `tabs.menu.close`, `tabs.menu.closeOthers`, `tabs.menu.moveLeft`,
  `tabs.menu.moveRight`, `tabs.menu.openTerminal`, `tabs.menu.saveAsSession`.
- [ ] **Step 3: The handlers in `ContentView+Lifecycle`.**
  - `moveLeft`/`moveRight` call `tabsModel.move(tabID:to:)` with index ∓1.
  - `closeOthers` closes **everything except the clicked tab** — not except
    the active one. First fetch the counts and, if `bulkMessage` is not
    empty, ask once; on decline **nothing** happens. Each tab goes
    through `teardown(_ tab:reason:)` individually. If the clicked tab is not the
    active one, it becomes so afterward.
  - `openTerminal` — **a measurement is needed here before you build anything.**
    `openTerminalFromSidebar` is NOT the way: it calls
    `connect(in:stored:paneVisibility:)` and thereby establishes a **new**
    connection. This tab is already connected; what is meant is to
    reveal its terminal pane. Determine how the visibility of the
    panes is changed on a **running** tab, and use that.
    **If there is no such way, stop and report it**, rather than building a
    second connection path — a menu entry that secretly reconnects
    would be worse than a missing one.
  - `saveAsSession` opens the existing save path, prefilled from
    `values` of that tab's `ConnectionViewModel` — **not** from
    `lastConnectedConfig`, which is an `SSHConnectionConfig?` and does not carry S3 and
    WebDAV.
- [ ] **Step 4: A guard that binds the view to the value.** It must
  prove that the menu draws its entries from `TabContextMenu.entries`
  and does not decide on its own.

  **Before choosing the anchor, ask yourself from WHERE the property "the
  view does not decide visibility on its own" could be violated,
  and enumerate those places.** A guard written after the
  implementation is tailored to the lines just written; that is the
  most common mistake in this project. The guard must be **fail-closed** and
  have its own self-tests — models are the four guard suites under
  `Tests/macSCPAppKitTests/` using `stripCommentsAndStrings`.

  **Mutation probes are mandatory:** for each enumerated place, plant a
  violation and prove that the guard goes red. Remove every probe and
  check `git status --porcelain` at the end. Check every probe file before
  measuring for whether it contains what you intended — a broken probe
  that does not compile looks like a closed hole.
- [ ] **Step 5:** Full suite green, no new warning.
- [ ] **Step 6: Commit** — `feat(tabs): give the tab a context menu`

---

### Task 5: Dragging

**Files:**
- Modify: `Sources/MacSCPAppKit/TabStripView.swift`
- Test: `Tests/macSCPAppKitTests/` (extend the guard from Task 4)

**Interfaces:**
- Consumes: `TabsViewModel.move(tabID:to:)` from Task 2 — the **same** function
  the menu calls. No second reordering comes into existence.

- [ ] **Step 1:** `TabItemView` becomes draggable and the strip accepts a drop.
  The tab `UUID` is carried; the drop computes the target position and calls
  `move(tabID:to:)`.
- [ ] **Step 2: A guard that dragging calls the same function.** It must
  rule out a second, own reordering logic in the view — that is exactly
  the mistake the backlog entry warns about. Prove it again with a mutation
  probe.
- [ ] **Step 3:** A drop outside the strip leaves the order as it
  was. No pulling out into a new window — multi-window is v2.
- [ ] **Step 4:** Full suite green, no new warning.
- [ ] **Step 5: Commit** — `feat(tabs): reorder tabs by dragging them`

**Explicitly state in the report at the end of this task:** that SwiftUI triggers the drag
and inserts the tab at the expected place **cannot be seen by any test in this
project**. This is a check by the maintainer in the running app and
is not counted as "green".

---

## What is explicitly out of scope

- No renaming a tab, no "close to the right" — both are
  maintainer decisions from 2026-08-27.
- No restoring tabs across a restart.
- No pulling out into a new window — multi-window is v2.
- No change to `fileActions` or to the browser context menu.
- No answer to C2 ("session is already open") — separate backlog item.
