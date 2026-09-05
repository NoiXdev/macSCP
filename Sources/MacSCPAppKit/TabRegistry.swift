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
///
/// ## The accepted limit on a parked tab (Task 2 fix round 3)
///
/// A tab moved into a window of its own is parked here until that window
/// appears and claims it. If the window never appears, the tab stays
/// parked: it is in no window, so it is on no tab strip and in no menu,
/// and nothing on screen says it exists. Two things end that state, and
/// there is no third — the source window closing, which sweeps its own
/// unclaimed seeds through the App layer's ordinary teardown, and the app
/// quitting, which sweeps every window's.
///
/// It is a limit rather than a defect because SwiftUI reports no failure
/// from `openWindow(value:)`: there is no signal that says "this window
/// will never appear", and a guess at one is a guess that can beat the
/// real claim. Fix round 2 shipped exactly that guess and it lost the tab
/// out of the new window every time. So the invisible interval is
/// accepted, and made visible in the record instead: one `info` line when
/// a seed is parked, one when it is torn down unclaimed, both written by
/// the App layer (`ContentView.moveToNewWindow` and the two sweeps) so a
/// diagnostic report can show a move that never landed.
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
    /// see `park(_:for:from:onClaimed:)` (Task 2).
    private var parkedTabIDsBySeedID: [UUID: [UUID]] = [:]
    /// Which window parked each of those seeds (Task 2 fix round 3). It is
    /// what lets a closing window be handed exactly its own unclaimed
    /// moves; before this the source was remembered per window, in the
    /// view, and died with it — a window with two moves in flight lost the
    /// unclaimed one the moment the claimed one closed it.
    private var parkedSourceBySeedID: [UUID: WindowID] = [:]
    /// What to run once a window has actually claimed a parked seed — the
    /// signal the window the tab LEFT waits on (Task 2 fix round 2). Held
    /// beside the parked ids and removed with them, so it can fire at most
    /// once per park.
    private var claimHandlersBySeedID: [UUID: () -> Void] = [:]
    /// Each open window's own `TabsViewModel`, held WEAKLY — see
    /// `registerModel(_:for:)`.
    private var modelsByWindow: [WindowID: WeakModel] = [:]
    /// How each open window describes itself for restoration — see
    /// `registerWindowDescriber(_:for:)` (Detachable Tabs plan, Task 5 fix
    /// round 1).
    private var describersByWindow: [WindowID: WindowDescriber] = [:]
    /// The order those windows first registered, which is the order they
    /// appeared. A dictionary has no order and the restored windows must
    /// come back in a stable one, so the sequence is kept beside the
    /// closures rather than inferred from them.

    private var describerWindowOrder: [WindowID] = []
    /// What each open window does to its own tabs when the app quits — see
    /// `registerWindowTeardown(_:for:)` (Quit Teardown plan, Task 1). Kept
    /// beside its own order for the same reason the describers are: a
    /// dictionary has none, and the windows must be torn down in the order
    /// they appeared.
    private var windowTeardowns: [WindowID: WindowTeardown] = [:]
    private var windowTeardownOrder: [WindowID] = []

    /// A weak reference in a place a dictionary cannot hold one directly.
    private struct WeakModel {
        weak var model: TabsViewModel<SessionTab>?
    }

    /// What a window answers when asked to describe itself: a `WindowSeed`
    /// carrying its tabs' descriptions, its sticky flag and whether it is
    /// the primary window.
    ///
    /// A closure rather than a stored value, because the answer changes
    /// with every tab opened, closed, connected or moved, and a value
    /// would have to be refreshed by whoever changed any of those. The
    /// window is asked once, at the one moment the answer is needed.
    typealias WindowDescriber = @MainActor () -> WindowSeed

    /// What a window does to everything it holds when the APP is quitting
    /// (Quit Teardown plan, Task 1): its own close-time sequence — the
    /// unclaimed seeds it parked, then the tabs still on its strip — run to
    /// completion rather than fired off into a `Task` nobody waits on.
    ///
    /// `async`, unlike `WindowDescriber` above, and that is the whole
    /// difference between the two: describing a window is a synchronous read
    /// of values, while tearing one down suspends on every stage of every
    /// tab. `applicationWillTerminate` could hold the first and not the
    /// second, which is why the quit moved to
    /// `applicationShouldTerminate(_:)`, the callback that can defer.
    ///
    /// The registry stores these and hands them back. It never calls one —
    /// see this type's own doc comment, and
    /// `TabRegistryNoTeardownGuardTests`, which reads this file for exactly
    /// that (there is no `await` anywhere in it, so there is nothing here
    /// that COULD run one).
    typealias WindowTeardown = @MainActor () async -> Void

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
    /// hands, and never from `park` itself.
    /// **`from` is what makes an unclaimed seed reachable** (fix round 3).
    /// A parked tab belongs to no window, so nothing about the tab itself
    /// says where it came from; this records it, and `pendingSeeds(for:)` /
    /// `takePendingSeeds(from:)` are how the window that parked it finds it
    /// again on its way out.
    func park(
        _ tabs: [SessionTab], for seedID: UUID, from sourceWindow: WindowID,
        onClaimed: @escaping () -> Void = {}
    ) {
        claimHandlersBySeedID[seedID] = onClaimed
        parkedSourceBySeedID[seedID] = sourceWindow
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
    /// already telling the truth. The seed leaves its source window's
    /// pending list at the same moment: it is somebody else's business now.
    func claim(seedID: UUID, into window: WindowID) -> [SessionTab] {
        let handler = claimHandlersBySeedID.removeValue(forKey: seedID)
        parkedSourceBySeedID[seedID] = nil
        let ids = parkedTabIDsBySeedID.removeValue(forKey: seedID) ?? []
        let claimed = ids.compactMap { id -> SessionTab? in
            guard let tab = tabsByID[id] else { return nil }
            move(id, to: window)
            return tab
        }
        handler?()
        return claimed
    }

    /// A seed that has been parked and not yet claimed, with the tabs
    /// waiting under it (fix round 3).
    struct PendingSeed {
        let seedID: UUID
        let sourceWindow: WindowID
        let tabs: [SessionTab]
    }

    /// Every seed `window` parked that nobody has claimed. Read-only — the
    /// two `take…` functions below are what actually hands them over.
    func pendingSeeds(for window: WindowID) -> [PendingSeed] {
        parkedSourceBySeedID
            .filter { $0.value == window }
            .map { seedID, source in
                PendingSeed(
                    seedID: seedID, sourceWindow: source,
                    tabs: (parkedTabIDsBySeedID[seedID] ?? []).compactMap { tabsByID[$0] })
            }
    }

    /// Hands `window`'s unclaimed seeds over and forgets them — the sweep a
    /// closing window runs.
    ///
    /// **Handing over is all this does.** The caller is what closes those
    /// tabs' connections, through the App layer's own sequence; this type
    /// never touches a session (see its doc comment, and
    /// `TabRegistryNoTeardownGuardTests`, which reads this file for exactly
    /// that). Exactly once, too: a second call answers nothing, so nobody
    /// can be handed the same live session twice.
    func takePendingSeeds(from window: WindowID) -> [PendingSeed] {
        let taken = pendingSeeds(for: window)
        for seed in taken { forgetPendingSeed(seed.seedID) }
        return taken
    }

    /// The same, for every window at once — the sweep the app runs as it
    /// quits.
    func takeAllPendingSeeds() -> [PendingSeed] {
        let taken = parkedSourceBySeedID.map { seedID, source in
            PendingSeed(
                seedID: seedID, sourceWindow: source,
                tabs: (parkedTabIDsBySeedID[seedID] ?? []).compactMap { tabsByID[$0] })
        }
        for seed in taken { forgetPendingSeed(seed.seedID) }
        return taken
    }

    private func forgetPendingSeed(_ seedID: UUID) {
        for id in parkedTabIDsBySeedID[seedID] ?? [] {
            tabsByID[id] = nil
            windowByTabID[id] = nil
        }
        parkedTabIDsBySeedID[seedID] = nil
        parkedSourceBySeedID[seedID] = nil
        claimHandlersBySeedID[seedID] = nil
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

    // MARK: - Each window's description, for the quit that restores it

    /// Records how `window` describes itself, for the restoration sweep at
    /// quit (Detachable Tabs plan, Task 5 fix round 1).
    ///
    /// **Why the registry has to answer this, and why a closure.** The
    /// windows that matter for restoration are exactly the ones still OPEN
    /// when the app quits, and ⌘Q closes none of them — this repository
    /// measured that for the parked-move sweep and it is the whole reason
    /// the first version of restoration, which wrote on `willClose`,
    /// described only the windows the user had deliberately shut. So the
    /// description has to be pulled at terminate, from something that
    /// knows which windows exist. That is this type. What it must NOT
    /// become is a second copy of each window's state: the sticky flag and
    /// the tab list live in the window's own `ContentView`, and a closure
    /// asks that view rather than mirroring it here.
    ///
    /// Idempotent, like `register(_:in:)` and `registerModel(_:for:)`: a
    /// window calls this on every setup pass, the last closure wins, and
    /// the window keeps the position it first registered in.
    ///
    /// The closure is STRONG, unlike `registerModel`'s weak model box,
    /// which is why `unregisterWindowDescriber(for:)` on the window's
    /// close path is not optional bookkeeping. A `ContentView` is a struct
    /// and what a captured copy reaches is SwiftUI's own storage, so the
    /// closure keeps no window alive by itself — but a describer left
    /// behind would still answer at quit for a window that is gone, and
    /// describe it as one to restore.
    func registerWindowDescriber(_ describe: @escaping WindowDescriber, for window: WindowID) {
        if describersByWindow[window] == nil {
            describerWindowOrder.append(window)
        }
        describersByWindow[window] = describe
    }

    /// Forgets how `window` describes itself. Called from the window's
    /// close path — a window the user closed is not one to bring back.
    func unregisterWindowDescriber(for window: WindowID) {
        describersByWindow[window] = nil
        describerWindowOrder.removeAll { $0 == window }
    }

    /// Every open window, described, in the order the windows appeared.
    ///
    /// Pure in the sense that matters here: it reads and returns values
    /// and changes nothing — not the registry, not a window, not a tab. It
    /// is called from `applicationWillTerminate`, which is synchronous and
    /// on the main thread, so anything that could suspend or await would
    /// be a promise this callback cannot keep (see `AppDelegate`).
    func describeAllWindows() -> [WindowSeed] {
        describerWindowOrder.compactMap { describersByWindow[$0]?() }
    }

    // MARK: - Each window's teardown, for the quit that waits for it

    /// Records what `window` does to everything it holds when the app is
    /// quitting (Quit Teardown plan, Task 1).
    ///
    /// **Why the registry has to answer this.** It is the same argument
    /// `registerWindowDescriber(_:for:)` above makes, one step further:
    /// ⌘Q closes no window, so no window's `willClose` handler runs, so
    /// nothing a window does on its own way out happens at quit. The set of
    /// windows that still exist at that moment is known here and nowhere
    /// else, and `AppDelegate` has no `ContentView` to ask.
    ///
    /// **What it must NOT become is a teardown of its own.** The closure is
    /// the window's OWN close-time sequence, and the four stages inside it
    /// are `TabTeardown`'s (Global Constraints: one owner). This type stores
    /// a function value and returns it; it does not know what is in it and
    /// cannot run it.
    ///
    /// Idempotent, and order-stable, like the three registrations above: a
    /// window calls this on every setup pass, the last closure wins, and the
    /// window keeps the position it first registered in.
    ///
    /// STRONG, like the describer, and for the same reason
    /// `unregisterWindowTeardown(for:)` is not optional bookkeeping: a
    /// closure left behind after a window closed would tear down, at quit,
    /// tabs that window already released.
    func registerWindowTeardown(_ run: @escaping WindowTeardown, for window: WindowID) {
        if windowTeardowns[window] == nil {
            windowTeardownOrder.append(window)
        }
        windowTeardowns[window] = run
    }

    /// Forgets what `window` does at quit. Called from the window's close
    /// path, which is running that very sequence itself — so a window the
    /// user closed is torn down exactly once, by its own `willClose`
    /// handler, and never a second time by the quit sweep.
    func unregisterWindowTeardown(for window: WindowID) {
        windowTeardowns[window] = nil
        windowTeardownOrder.removeAll { $0 == window }
    }

    /// Every open window's teardown, in the order the windows appeared,
    /// paired with the window it belongs to.
    ///
    /// Handing over is all this does. The caller — `AppDelegate`'s deferred
    /// quit — is what awaits them, in this order, under its own watchdog.
    func allWindowTeardowns() -> [(WindowID, WindowTeardown)] {
        windowTeardownOrder.compactMap { window in
            windowTeardowns[window].map { (window, $0) }
        }
    }

    /// Every tab the registry knows about — held by a window or parked for
    /// one that never appeared — in no particular order.
    ///
    /// The quit's decision is counted over this (`QuitSequence
    /// .decision(liveTabCount:)`): a parked tab can hold a live session and
    /// is in no window, so counting windows' tabs alone would answer
    /// "nothing to do" for a connection nothing else can reach.
    func allTabs() -> [SessionTab] {
        Array(tabsByID.values)
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
