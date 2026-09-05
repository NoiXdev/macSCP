import Foundation
import Observation

/// Window-scoped tab collection rules (M8a). Pure state machine — no UI,
/// no SSH: the app layer instantiates it with its session payload and
/// renders `tabs`/`activeTabID`. Payload-generic so the rules stay unit
/// testable (the app target has no test target).
@MainActor
@Observable
public final class TabsViewModel<Tab: Identifiable> where Tab.ID == UUID {
    public private(set) var tabs: [Tab]
    public private(set) var activeTabID: UUID

    public init(initial: Tab) {
        self.tabs = [initial]
        self.activeTabID = initial.id
    }

    /// The active tab. `activeTabID` is maintained to always reference an
    /// existing element, so lookup failure is a programmer error.
    public var activeTab: Tab {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else {
            fatalError("activeTabID does not reference an existing tab")
        }
        return tab
    }

    public var isLastTab: Bool { tabs.count == 1 }

    /// Appends and activates (⊕ / Cmd-N / sidebar-into-new-tab).
    public func addTab(_ tab: Tab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Moves a tab to another position. The only reordering there is — the
    /// context menu reaches it through `move(tabID:oneStep:)` and dragging
    /// through `move(tabID:onto:)`, so the rule exists once. Neither route
    /// names a position of its own: both hand this function one derived
    /// here, from the array that defines it.
    ///
    /// `activeTabID` is deliberately untouched: it names a tab, not a
    /// position, so the active tab stays active however the order changes.
    /// Out-of-range destinations and unknown ids leave the order alone
    /// rather than trapping — a gesture that ends outside the strip is an
    /// ordinary outcome, not a programmer error.
    public func move(tabID: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs.indices.contains(destination), destination != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: destination)
    }

    /// Moves a tab onto the position another tab holds right now — the
    /// drag's way in, phrased in the only two things a drop actually
    /// knows: which tab was picked up, and which tab it was let go on.
    ///
    /// **Why a position is not a parameter here.** A view that carries an
    /// index carries something that can be shifted: by a step, by a
    /// shadowed name, inside an initializer — each of which changes where a
    /// tab lands while the surrounding code stays character for character
    /// what it was. Three rounds of scanning for those spellings found a
    /// new one each time. An identity has no arithmetic, so the shapes stop
    /// existing rather than being watched for; the position is derived
    /// here, from the array that defines it, in the same instant it is
    /// used.
    ///
    /// A no-op when either id names no tab: the dragged one may have been
    /// closed by a menu on another tab, and the target may be gone by the
    /// time the drop lands. That also disposes of the clamping the drag
    /// used to need — there is no stale index to clamp into range, only a
    /// target that is or is not there.
    public func move(tabID: UUID, onto targetID: UUID) {
        guard let destination = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        move(tabID: tabID, to: destination)
    }

    /// Moves a tab one place in the direction its menu entry names — the
    /// context menu's way in, phrased in the only thing that entry knows:
    /// which way the user asked for.
    ///
    /// **Why a direction and not an offset.** The step used to be taken in
    /// the app layer, which turned each move entry into a number and handed
    /// that number to `move(tabID:to:)`. Nothing there could be called with a
    /// value, so the pair of numbers was the one piece of arithmetic in the
    /// whole feature that no test reached: swapping them left every test
    /// green and made "Move Right" on the first tab a silent no-op, because
    /// that tab is offered no other move entry and the swapped step aimed
    /// off the end of the strip (final review, I1). Taking the step here
    /// puts it where both directions can be asked for and the resulting
    /// order read back.
    ///
    /// No clamping, for the same reason `move(tabID:to:)` needs none: an
    /// end tab is offered only the step that has a neighbour
    /// (`TabContextMenu.entries`), and a menu that went stale between
    /// opening and clicking aims past the end, which that function already
    /// answers by leaving the order alone.
    public func move(tabID: UUID, oneStep step: TabMoveStep) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        switch step {
        case .left: move(tabID: tabID, to: from - 1)
        case .right: move(tabID: tabID, to: from + 1)
        }
    }

    /// No-op for unknown ids (defensive: a stale click on a closing tab).
    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Removes the tab. The LAST tab is not removable (the app interprets
    /// closing the last unconnected tab as closing the window). Closing the
    /// active tab activates the right neighbor, or the left one at the
    /// rightmost position (browser convention).
    @discardableResult
    public func closeTab(_ id: UUID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tabs.remove(at: index)
        if activeTabID == id {
            let successor = min(index, tabs.count - 1)
            activeTabID = tabs[successor].id
        }
        return true
    }

    /// Removes the tab WITHOUT `closeTab`'s last-tab rule and without any
    /// close side effect (Detachable Tabs plan, Task 1): a move into
    /// another window's model is not a close, and the rule that refuses to
    /// empty a model exists for closing a window's last tab, which has
    /// nothing to do with a tab this model is simply handing to another
    /// one. The model IS allowed to end up empty here.
    ///
    /// Selection moves exactly like `closeTab` moves it — the right
    /// neighbor, or the left one at the rightmost position — for every tab
    /// count above one. At exactly one, the model empties and
    /// `activeTabID` is left naming the tab that just left: there is no
    /// neighbor to hand it to, and this type has no optional "no active
    /// tab" state to put it in instead. That is safe precisely because
    /// nothing is expected to read `activeTab` on an emptied model — the
    /// caller that just detached its only tab is a window with nothing
    /// left to render, not one asking this type what is active.
    ///
    /// Returns the removed tab so the caller can hand it to another
    /// model's `addTab(_:)`; `nil` for an unknown id, mirroring
    /// `closeTab`'s `false`.
    @discardableResult
    public func detach(tabID: UUID) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabID == tabID, !tabs.isEmpty {
            let successor = min(index, tabs.count - 1)
            activeTabID = tabs[successor].id
        }
        return tab
    }

    /// The tabs a bulk close covers: **everything except the one it was
    /// asked about** — not everything except the ACTIVE one. The context
    /// menu hangs off a particular row and the user means that row, so a
    /// bulk close opened on a background tab closes the active one along
    /// with the rest.
    ///
    /// That distinction is the design's most emphatic rule about this
    /// feature and it is easy to get wrong by reading `activeTabID`, which
    /// is right there and almost always the same tab. It is a value
    /// question — a list and an id in, a list out — so it is answered here
    /// rather than inside a view where nothing can check it.
    ///
    /// Order is preserved, and an unknown id yields every tab: the caller
    /// then has nothing to keep, which `closeOthers(besides:)` refuses to
    /// act on.
    public func tabsToClose(besides id: UUID) -> [Tab] {
        tabs.filter { $0.id != id }
    }

    /// Removes every tab but one and makes that one active — the second
    /// half of the same rule. The caller runs its own per-tab teardown over
    /// `tabsToClose(besides:)` first; this is the model change that follows
    /// it, in one step rather than a loop of `closeTab`, because "keep
    /// exactly this one" is the intent and `closeTab`'s last-tab refusal
    /// describes a different one.
    ///
    /// A no-op for an unknown id, rather than emptying the strip: `tabs` is
    /// never allowed to be empty (`activeTab` treats a missing active tab
    /// as a programmer error), and a stale click on a tab that has already
    /// gone is an ordinary outcome, the same reading `activate(_:)` and
    /// `move(tabID:to:)` take.
    public func closeOthers(besides id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id != id }
        activeTabID = id
    }

    /// The tab that already holds stored session `storedSessionID`, or
    /// `nil` when none does. It answers WHICH tab, and deliberately not
    /// what to do about one: jumping there and opening a second tab anyway
    /// are both sensible, and choosing between them is the user's, through
    /// the app's own query.
    ///
    /// **The FIRST in tab order wins.** More than one holder becomes
    /// reachable the moment somebody answers "open anyway" once, and from
    /// then on the order the tabs are in is the only rule that invents no
    /// preference — not the most recently connected, not the one nearest
    /// the active tab. `tabs` IS that order (`move(tabID:to:)` is what
    /// changes it), so the answer is derived here from the array that
    /// defines it, rather than from anything remembered alongside it.
    ///
    /// **Why the caller passes the projection.** This type is generic over
    /// its payload and cannot read a stored-session id off one. The rule
    /// still belongs here: the app target has no test target of its own, so
    /// a version of this written at the call site would be the one part of
    /// the feature nothing could check.
    ///
    /// **Why `storedSessionID` is not optional.** A tab connected ad hoc
    /// projects `nil`, and asking this question with an optional would let
    /// two `nil`s match — every ad-hoc tab would hold every session at
    /// once. That is not a rounding error in the rule but its inverse: a
    /// typed connection to the same host can carry other credentials,
    /// another key, another jump host, so it looks like the stored session
    /// and is not one. Taking a plain `UUID` makes the mistake unspellable
    /// instead of guarded against.
    public func tabHolding(
        _ storedSessionID: UUID, storedSessionIDOf: (Tab) -> UUID?
    ) -> Tab? {
        tabs.first { storedSessionIDOf($0) == storedSessionID }
    }

    /// Sidebar-connect rule (spec 1.2): an unconnected active tab is reused
    /// in place; a connected one spawns a fresh tab so the running session
    /// is never torn down by a sidebar connect.
    ///
    /// Unchanged by the "session is already open" query, and deliberately:
    /// that query is asked BEFORE this rule is consulted (see the app's
    /// sidebar start), and answering it with "open anyway" means arriving
    /// here and getting exactly what a start has always got — including the
    /// reuse of an unconnected active tab.
    public func sidebarConnectTarget(
        activeTabIsConnected: Bool, makeTab: () -> Tab
    ) -> Tab {
        guard activeTabIsConnected else { return activeTab }
        let fresh = makeTab()
        addTab(fresh)
        return fresh
    }
}
