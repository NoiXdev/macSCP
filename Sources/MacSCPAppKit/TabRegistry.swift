import Foundation
import macSCPCore

/// Identifies a window slot the registry can hold tabs for (Detachable
/// Tabs plan, Task 1). A UUID wrapper, not a raw `UUID`, so "the id of a
/// window" and "the id of a tab" are two types a call site cannot
/// accidentally swap — `move(_:to:)` below takes one of each.
struct WindowID: Hashable, Sendable {
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
