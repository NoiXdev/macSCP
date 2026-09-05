import Foundation
import macSCPCore

/// Everything that happens to a window's own model and to the registry when
/// one of its tabs leaves for a window of its own (Detachable Tabs plan,
/// Task 2) — outside any view, so it can be driven with values instead of
/// read as text.
///
/// **The model is never left empty, not even for a turn.**
/// `TabsViewModel.detach(tabID:)` empties the model when the tab it removes
/// was the only one, and sets `activeTabID` to `nil` (Task 1 fix round 1);
/// `TabsViewModel.activeTab` traps on a `nil` or unresolved id, which is
/// that class's documented invariant. `move` therefore puts a fresh tab in
/// the leaver's place whenever the detach would empty the model —
/// unconditionally, including for a window that is about to close, because
/// the close no longer happens in the same turn (see below) and a view body
/// runs at the end of every turn.
///
/// **Open before close** (fix round 1). `move` opens the new window itself,
/// through the `openWindow` closure it is handed, and it does so AFTER the
/// tab is parked and BEFORE anything closes: `NSWindow.close()` is
/// synchronous and tears its scene down where it stands, so a close that
/// ran first would leave a refused or lost open with a parked tab that has
/// a live connection, no window, and no teardown. The caller closes on the
/// NEXT main-actor turn, and only after `reclaim(seedID:into:from:window:
/// removing:)` has confirmed the tab really did leave.
///
/// **The reclaim is the safety net.** One turn later the window opened for
/// the seed has had its chance to claim; anything still parked under that
/// seed means no window took it. `reclaim` puts it back in the window it
/// came from and removes the placeholder that stood in for it, and the
/// caller then leaves that window open — a tab back where it started is a
/// visible outcome, a tab parked forever is not.
/// "The window this tab was dragged out of is now empty and should close."
///
/// A cross-window drop is reported to the window the tab arrived IN, and
/// that window can close only itself — an `NSWindow` belongs to the
/// `ContentView` that `WindowAccessor` handed it to, and no window in this
/// app holds another's. So the outcome travels back as a notification the
/// source window recognises by its own `WindowID`, the same shape
/// `handleWindowWillClose(_:)` already uses for the close it observes.
///
/// The post happens on the main-actor turn AFTER the move, never inside the
/// drop handler: `NSWindow.close()` is synchronous and tears its scene down
/// where it stands, and the source window's model has just been edited by a
/// closure still on the stack (`TabDetachSequence`'s own doc comment, "open
/// before close", for the same reasoning one task earlier).
enum TabWindowCloseRequest {
    static let notification = Notification.Name("dev.noix.macscp.tabWindowShouldClose")
    /// Spelled once, read by both halves below, so the two cannot disagree.
    static let windowIDKey = "windowID"

    static func post(_ window: WindowID) {
        NotificationCenter.default.post(
            name: notification, object: nil, userInfo: [windowIDKey: window])
    }

    /// The window a request names, or `nil` for a notification that carries
    /// none — which no window matches, so an unreadable request closes
    /// nothing rather than closing the wrong thing.
    static func windowID(from notification: Notification) -> WindowID? {
        notification.userInfo?[windowIDKey] as? WindowID
    }
}

@MainActor
enum TabDetachSequence {
    /// What one move did, and what the caller still owes it.
    struct Outcome: Equatable {
        /// The source window is left with nothing of its own and is not the
        /// last window (`WindowCloseDecision`), so it should close — but
        /// only once `reclaim` has confirmed the tab is gone.
        let closesWindow: Bool
        /// The fresh tab put in the leaver's place, if the detach would
        /// otherwise have emptied the model. `reclaim` removes it again if
        /// the tab comes back.
        let replacementID: UUID?

        /// Nothing happened — the id was not in the model.
        static let none = Outcome(closesWindow: false, replacementID: nil)
    }

    /// Moves `tabID` out of `model`, parks it under `seed.id`, and asks
    /// `openWindow` for a window to claim it.
    ///
    /// `openWindow` is a parameter rather than a call the caller makes
    /// afterwards, so the ordering this type documents cannot be got wrong
    /// at a call site — and so a test can hand in a closure that does
    /// nothing and drive the "the window never opened" path.
    ///
    /// `replacement` is called at most once, and only when the detach would
    /// leave `model` empty.
    ///
    /// `Outcome.none` for an id `model` does not hold: nothing is detached,
    /// nothing is parked, and no window is opened, so a stale or repeated
    /// invocation cannot open a window over a tab that is already somewhere
    /// else.
    ///
    /// Nothing here touches the tab's connection: `detach` and `park` move a
    /// reference between collections and read nothing off the tab but its
    /// id (Global Constraints: "a move never touches the connection", pinned
    /// against the session itself in `TabRegistryTests` and structurally by
    /// `TabRegistryNoTeardownGuardTests`).
    @discardableResult
    static func move(
        _ tabID: UUID,
        outOf model: TabsViewModel<SessionTab>,
        parkingUnder seed: WindowSeed,
        in registry: TabRegistry,
        replacement: () -> SessionTab,
        openWindow: (WindowSeed) -> Void
    ) -> Outcome {
        let closesWindow = WindowCloseDecision.after(
            removing: tabID, in: model.tabs.map(\.id), windowCount: registry.windowCount)
        guard let tab = model.detach(tabID: tabID) else { return .none }
        registry.park([tab], for: seed.id)
        var replacementID: UUID?
        if model.tabs.isEmpty {
            let fresh = replacement()
            replacementID = fresh.id
            model.addTab(fresh)
        }
        openWindow(seed)
        return Outcome(closesWindow: closesWindow, replacementID: replacementID)
    }

    /// Moves `tabID` from one OPEN window's model into another's — the drag
    /// between two windows (Task 3) — and answers whether the source window
    /// is now left with nothing of its own.
    ///
    /// **No parking, and no reclaim.** Both windows already exist, so there
    /// is no gap between letting go and being taken over: the whole handover
    /// is `TabRegistry.move(_:from:to:targetWindow:)`, which detaches from
    /// one model, reassigns ownership and adds to the other in one call. The
    /// asymmetry with `move(_:outOf:parkingUnder:in:replacement:openWindow:)`
    /// above is entirely that one, and it is why nothing here can strand a
    /// tab.
    ///
    /// **What is the same is the ordering, and why.** The close decision is
    /// taken while the source model still holds the tab, and a fresh tab
    /// takes the leaver's place whenever the detach would empty the model —
    /// unconditionally, exactly as above, because the caller closes the
    /// source window on a LATER main-actor turn and a view body runs over
    /// that model in between. `TabsViewModel.activeTab` traps on an emptied
    /// model, which is that class's documented invariant.
    ///
    /// `Outcome.none`, changing nothing at all, in three cases: the two
    /// windows are the same, `source` and `target` are the same model — both
    /// describe a drop back onto the strip the drag started from, which is
    /// the in-strip REORDER that `TabsViewModel.move(tabID:onto:)` owns —
    /// or `source` does not hold `tabID` (a stale or repeated drop). None of
    /// the three makes a replacement tab, so a repeated drop cannot mint
    /// tabs into a window.
    ///
    /// The two same-window refusals are checked separately on purpose: a
    /// window is its `WindowID` to the registry and its `TabsViewModel` to
    /// the view, and the close decision below is about the first while the
    /// detach is about the second. Checking only one would leave the other
    /// able to express a "move" from a window to itself.
    ///
    /// Nothing here touches the tab's connection: see this type's doc
    /// comment, `TabRegistry.move(_:from:to:targetWindow:)`, and
    /// `TabRegistryNoTeardownGuardTests`.
    @discardableResult
    static func moveBetweenWindows(
        _ tabID: UUID,
        from source: TabsViewModel<SessionTab>,
        sourceWindow: WindowID,
        to target: TabsViewModel<SessionTab>,
        targetWindow: WindowID,
        in registry: TabRegistry,
        replacement: () -> SessionTab
    ) -> Outcome {
        guard sourceWindow != targetWindow, source !== target else { return .none }
        guard source.tabs.contains(where: { $0.id == tabID }) else { return .none }
        let closesWindow = WindowCloseDecision.after(
            removing: tabID, in: source.tabs.map(\.id), windowCount: registry.windowCount)
        registry.move(tabID, from: source, to: target, targetWindow: targetWindow)
        var replacementID: UUID?
        if source.tabs.isEmpty {
            let fresh = replacement()
            replacementID = fresh.id
            source.addTab(fresh)
        }
        return Outcome(closesWindow: closesWindow, replacementID: replacementID)
    }

    /// Puts back anything still parked under `seedID` — i.e. anything no
    /// window claimed — and removes the placeholder `move` left in its
    /// place. Answers whether it had to.
    ///
    /// Called on the main-actor turn AFTER `move`, which is the earliest
    /// moment a window opened for the seed could have claimed. `true` means
    /// the move did not happen after all, and the caller must NOT close the
    /// source window: the tab is back in it.
    @discardableResult
    static func reclaim(
        seedID: UUID,
        into model: TabsViewModel<SessionTab>,
        from registry: TabRegistry,
        window: WindowID,
        removing replacementID: UUID?
    ) -> Bool {
        let stranded = registry.claim(seedID: seedID, into: window)
        guard !stranded.isEmpty else { return false }
        // Added BEFORE the placeholder goes, so the model is never empty and
        // `activeTabID` never dangles — `addTab` also makes the returning
        // tab the active one, which is where the user left it.
        for tab in stranded { model.addTab(tab) }
        if let replacementID { model.detach(tabID: replacementID) }
        return true
    }
}
