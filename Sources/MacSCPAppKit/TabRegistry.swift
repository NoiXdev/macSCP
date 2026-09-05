import Foundation
import macSCPCore

/// Identifies a window slot the registry can hold tabs for (Detachable
/// Tabs plan, Task 1). A UUID wrapper, not a raw `UUID`, so "the id of a
/// window" and "the id of a tab" are two types a call site cannot
/// accidentally swap — `move(_:to:)` below takes one of each.
///
/// `Codable` since Task 3, because a tab's drag payload carries the window
/// it started in (`TabDragPayload`) and that payload travels as text.
struct WindowID: Hashable, Sendable, Codable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Process-wide registry of every live `SessionTab`, keyed by its own id,
/// and which window currently holds it (Detachable Tabs plan). Ownership
/// bookkeeping only: the registry never touches a tab's connection, and it
/// never tears anything down — closing a window's tabs runs through that
/// window's own teardown path (`cancelAll` → `shutdown` → `disconnect`,
/// `ContentView.teardown`) BEFORE `release(_:from:)` is asked to forget
/// them; this type performs no `deinit` cleanup either, matching the
/// project's "lifecycles stay explicit" rule for `SessionTab` itself.
///
/// `@MainActor`, like `SessionTab` and `TabsViewModel`: every tab it holds
/// is already main-actor-isolated, so the registry adds no isolation
/// boundary of its own — a plain, ordinary main-actor object.
@MainActor
final class TabRegistry {
    /// The process-wide instance every window shares. Tests build their
    /// OWN instance with `TabRegistry()` instead — never this one — so
    /// registrations from one test can never leak into another.
    static let shared = TabRegistry()

    private var tabsByID: [UUID: SessionTab] = [:]
    private var windowByTabID: [UUID: WindowID] = [:]
    private var tabIDsByWindow: [WindowID: [UUID]] = [:]
    /// Tabs that have left a window and whose new window does not exist
    /// yet, keyed by the `WindowSeed.id` that window will appear with —
    /// see `park(_:for:onClaimed:)` (Task 2).
    private var parkedTabIDsBySeedID: [UUID: [UUID]] = [:]
    /// What to run once a window has actually claimed a parked seed — the
    /// signal the window the tab LEFT waits on (Task 2 fix round 2). Held
    /// beside the parked ids and removed with them, so it can fire at most
    /// once per park.
    private var claimHandlersBySeedID: [UUID: () -> Void] = [:]
    /// Each open window's own `TabsViewModel`, held WEAKLY — see
    /// `registerModel(_:for:)`.
    private var modelsByWindow: [WindowID: WeakModel] = [:]

    /// A weak reference in a place a dictionary cannot hold one directly.
    private struct WeakModel {
        weak var model: TabsViewModel<SessionTab>?
    }

    init() {}

    /// The number of windows currently holding at least one tab. A window
    /// emptied by `move(_:to:)` or `release(_:from:)` stops counting the
    /// moment its last tab leaves — this is "how many windows are open
    /// right now", not "how many windows have ever registered a tab".
    var windowCount: Int { tabIDsByWindow.count }

    /// Records that `tab` lives in `window`. Registering a tab already
    /// known under a different window simply moves it — the same
    /// reassignment `move(_:to:)` performs — since a tab can only ever be
    /// in one window at a time.
    func register(_ tab: SessionTab, in window: WindowID) {
        tabsByID[tab.id] = tab
        move(tab.id, to: window)
    }

    func tab(for id: UUID) -> SessionTab? {
        tabsByID[id]
    }

    func windowHolding(_ id: UUID) -> WindowID? {
        windowByTabID[id]
    }

    /// Every tab `window` currently holds, in no particular order (nothing
    /// here needs the tab-strip order — that lives on each window's own
    /// `TabsViewModel`, not on the registry).
    func tabs(in window: WindowID) -> [SessionTab] {
        (tabIDsByWindow[window] ?? []).compactMap { tabsByID[$0] }
    }

    /// Reassigns ownership only: `id` now belongs to `window`, wherever it
    /// belonged before. A no-op for an id the registry has never seen —
    /// nothing to reassign. This function alone does not touch any
    /// `TabsViewModel`; see `move(_:from:to:targetWindow:)` for the
    /// convenience that also performs the matching model edits a drag
    /// needs.
    func move(_ id: UUID, to window: WindowID) {
        guard tabsByID[id] != nil else { return }
        if let previous = windowByTabID[id] {
            tabIDsByWindow[previous]?.removeAll { $0 == id }
            if tabIDsByWindow[previous]?.isEmpty == true {
                tabIDsByWindow[previous] = nil
            }
        }
        windowByTabID[id] = window
        var held = tabIDsByWindow[window] ?? []
        if !held.contains(id) { held.append(id) }
        tabIDsByWindow[window] = held
    }

    /// Forgets `ids` — but only the ones `window` currently holds; an id
    /// already moved to a different window is left alone, so a stale
    /// release from a window that no longer owns a tab cannot undo a move
    /// that already happened. Called once a window's OWN teardown of those
    /// tabs has already finished; this function performs no teardown of
    /// its own (see the type's doc comment).
    func release(_ ids: [UUID], from window: WindowID) {
        for id in ids where windowByTabID[id] == window {
            tabsByID[id] = nil
            windowByTabID[id] = nil
            tabIDsByWindow[window]?.removeAll { $0 == id }
        }
        if tabIDsByWindow[window]?.isEmpty == true {
            tabIDsByWindow[window] = nil
        }
    }

    // MARK: - Parking, for a window that does not exist yet

    /// Takes `tabs` out of whatever window holds them and holds them under
    /// `seedID` until a window claims them (Task 2).
    ///
    /// It exists because of an ordering a move cannot avoid: the window a
    /// tab is moving INTO has no `WindowID` at the moment `openWindow` is
    /// called — it has no window yet — while the window it is moving OUT of
    /// must let go of it in that same synchronous step, or its own close
    /// path would tear the tab down on the way out. So the tab is parked
    /// under the `WindowSeed.id` the new window will appear with, and
    /// `claim(seedID:into:)` is what the new window calls once it has a
    /// `WindowID` of its own.
    ///
    /// A parked tab is still KNOWN to the registry — `tab(for:)` finds it —
    /// but belongs to no window, so `windowHolding(_:)` answers `nil` and
    /// `windowCount` stops counting a window the parking emptied. Nothing
    /// about the tab itself is touched: this is the same reference
    /// bookkeeping the rest of this type does.
    ///
    /// Takes the tab OBJECTS rather than ids on purpose — a tab the
    /// registry has never seen (a window that never registered it) is
    /// parked correctly rather than silently dropped.
    ///
    /// **`onClaimed` is how the source window learns the move happened**
    /// (Task 2 fix round 2). The window a tab leaves cannot work that out by
    /// waiting: the new window claims from its own setup pass, which is a
    /// later DISPLAY pass, not a later main-actor turn, so no number of
    /// turns is enough and a fixed count is a guess that was measured wrong
    /// (a next-turn reclaim ran first and left the new window blank). The
    /// claim itself is the only honest signal, and this is it. It fires from
    /// `claim(seedID:into:)` exactly once, after the tabs have changed
    /// hands, and never from `park` or `unpark(seedID:into:)`.
    func park(
        _ tabs: [SessionTab], for seedID: UUID,
        onClaimed: @escaping () -> Void = {}
    ) {
        claimHandlersBySeedID[seedID] = onClaimed
        var parked = parkedTabIDsBySeedID[seedID] ?? []
        for tab in tabs {
            tabsByID[tab.id] = tab
            if let previous = windowByTabID[tab.id] {
                tabIDsByWindow[previous]?.removeAll { $0 == tab.id }
                if tabIDsByWindow[previous]?.isEmpty == true {
                    tabIDsByWindow[previous] = nil
                }
            }
            windowByTabID[tab.id] = nil
            if !parked.contains(tab.id) { parked.append(tab.id) }
        }
        parkedTabIDsBySeedID[seedID] = parked
    }

    /// Hands `seedID`'s parked tabs to `window` and empties the slot, in
    /// park order. The window that calls this is the one SwiftUI opened for
    /// that seed; it adds the returned tabs to its own `TabsViewModel`.
    ///
    /// An empty answer is an ordinary outcome, not an error: a window
    /// SwiftUI RESTORED from a previous launch carries a seed nobody parked
    /// anything under, and it must come up with its own fresh tab rather
    /// than with someone else's.
    ///
    /// This is the CLAIM, so the seed's `onClaimed` handler runs — after the
    /// tabs have changed hands, so the window it wakes finds the registry
    /// already telling the truth. `unpark(seedID:into:)` below is the same
    /// hand-over without the signal, for the window taking its own tab back.
    func claim(seedID: UUID, into window: WindowID) -> [SessionTab] {
        let handler = claimHandlersBySeedID.removeValue(forKey: seedID)
        let claimed = unpark(seedID: seedID, into: window)
        handler?()
        return claimed
    }

    /// Hands `seedID`'s parked tabs to `window` WITHOUT telling anyone the
    /// move succeeded — because it did not. This is the window that parked
    /// them taking them back (`TabDetachSequence.reclaim`), and firing
    /// `onClaimed` here would tell that same window to close over a tab it
    /// had just been handed back.
    ///
    /// The handler is dropped rather than kept: the park it belonged to is
    /// over either way, and a handler left behind would fire on some later,
    /// unrelated claim of a seed id that no longer means anything.
    func unpark(seedID: UUID, into window: WindowID) -> [SessionTab] {
        claimHandlersBySeedID[seedID] = nil
        let ids = parkedTabIDsBySeedID.removeValue(forKey: seedID) ?? []
        return ids.compactMap { id in
            guard let tab = tabsByID[id] else { return nil }
            move(id, to: window)
            return tab
        }
    }

    /// What is parked under `seedID` right now — the slot `claim(seedID:
    /// into:)` empties. Nothing in the app reads this; it is what lets a
    /// test say the slot was filled and then emptied, rather than inferring
    /// both from the claim's own return value.
    func parkedTabs(for seedID: UUID) -> [SessionTab] {
        (parkedTabIDsBySeedID[seedID] ?? []).compactMap { tabsByID[$0] }
    }

    // MARK: - Each window's model, for a drop that arrives in another one

    /// Records the `TabsViewModel` `window` renders, so a drop that lands in
    /// a DIFFERENT window can reach it (Detachable Tabs plan, Task 3).
    ///
    /// **Why the registry has to answer this.** A drop is reported only to
    /// the strip it landed on. That strip belongs to the target window,
    /// which holds its own model and nothing else — no window in this app
    /// has ever held another's, and the plan's "connection state belongs to
    /// the window scope" is the reason it must not start to. The registry
    /// already answers "which window holds this tab"; this is the same
    /// bookkeeping from the other side, and it is the only thing added here
    /// that a window did not already tell the registry.
    ///
    /// **Weak, and also unregistered explicitly.** The explicit
    /// `unregisterModel(for:)` on the window's close path is what makes the
    /// ordinary case immediate: the moment a window is closing it stops
    /// being a place a drop can move a tab into. The weak reference is what
    /// makes any other order harmless — the registry must never be the thing
    /// that keeps a whole window's worth of live sessions alive, and this
    /// type performs no `deinit` cleanup of its own (see the type's doc
    /// comment).
    ///
    /// Registering is idempotent, like `register(_:in:)`: a window calls it
    /// on every setup pass and the last call wins.
    func registerModel(_ model: TabsViewModel<SessionTab>, for window: WindowID) {
        modelsByWindow[window] = WeakModel(model: model)
    }

    /// Forgets `window`'s model. Called from the window's close path, before
    /// its tabs are torn down — this removes a lookup, never a tab.
    func unregisterModel(for window: WindowID) {
        modelsByWindow[window] = nil
    }

    /// `window`'s model, or `nil` if it never registered one, has
    /// unregistered, or has gone away. A stale entry is dropped here rather
    /// than left to answer `nil` forever.
    func model(for window: WindowID) -> TabsViewModel<SessionTab>? {
        guard let box = modelsByWindow[window] else { return nil }
        guard let model = box.model else {
            modelsByWindow[window] = nil
            return nil
        }
        return model
    }

    /// The convenience Task 2's drag calls: moves `id`'s ownership in the
    /// registry AND performs the matching `TabsViewModel` edits — `detach`
    /// out of `source`, `addTab` into `target` — as one call, so a caller
    /// can never update the registry without updating the models, or the
    /// other way around.
    ///
    /// Nothing here does anything beyond that: no teardown, no
    /// reconnection, no access to `SessionTab`'s session at all. The
    /// `Tab`'s object identity, its `BrowserSession`, its transfer queue
    /// and its terminal are exactly what they were before the call —
    /// `detach`/`addTab` only ever move a reference between two arrays
    /// (Global Constraints: "a move never touches the connection").
    ///
    /// A no-op — the registry and both models exactly as they were — when
    /// `source` does not currently hold `id`: `detach(tabID:)` returns
    /// `nil` and neither the registry reassignment nor the `addTab` runs,
    /// so a stale or repeated drag can never register a tab under a
    /// window's model that never received it.
    func move(
        _ id: UUID,
        from source: TabsViewModel<SessionTab>,
        to target: TabsViewModel<SessionTab>,
        targetWindow: WindowID
    ) {
        guard let tab = source.detach(tabID: id) else { return }
        move(id, to: targetWindow)
        target.addTab(tab)
    }
}
