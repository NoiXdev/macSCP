import Foundation
import macSCPCore

// The three rules everything in this file obeys, written once here because
// `TabDetachSequence` and `TabWindowCloseRequest` below are two halves of
// the same sequence (Detachable Tabs plan, Tasks 2 and 3).
//
// **The model is never left empty, not even for a turn.**
// `TabsViewModel.detach(tabID:)` empties the model when the tab it removes
// was the only one, and sets `activeTabID` to `nil` (Task 1 fix round 1);
// `TabsViewModel.activeTab` traps on a `nil` or unresolved id, which is
// that class's documented invariant. Both moves therefore put a fresh tab
// in the leaver's place whenever the detach would empty the model —
// unconditionally, including for a window that is about to close, because
// the close happens on a later turn than the detach and a view body runs at
// the end of every turn.
//
// **Open before close** (fix round 1). `move` opens the new window itself,
// through the `openWindow` closure it is handed, and it does so AFTER the
// tab is parked and BEFORE anything closes: `NSWindow.close()` is
// synchronous and tears its scene down where it stands, so a close that ran
// first would leave a refused or lost open with a parked tab that has a
// live connection, no window, and no teardown.
//
// **The claim is the signal, and the reclaim is the safety net** (fix round
// 2). The source window does NOT close on a turn count: the window opened
// for a seed claims it from its own setup pass, which is a later DISPLAY
// pass and not a later main-actor turn, so a next-turn close-or-reclaim beat
// it, pulled the tab back, and left the new window blank. The close is
// driven instead by `TabRegistry.park(_:for:onClaimed:)`, which fires when a
// window has actually taken the tab over. `reclaim` is the other half, and
// it runs only from a definitely-later trigger — the source window being
// activated again with the seed still unclaimed — putting the tab back where
// it came from and removing the placeholder that stood in for it. A tab back
// where it started is a visible outcome; a tab parked forever is not.

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
/// closure still on the stack — the same reasoning as "open before close"
/// in this file's opening comment, one task earlier.
///
/// Task 2's own path posts it too, from the `onClaimed` handler it parks
/// with: the window a tab was moved OUT of learns from the registry that
/// some window took it, and asks itself to close by the same route the drag
/// already used.
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

/// Everything that happens to a window's own model and to the registry when
/// one of its tabs leaves — for a window of its own (Task 2) or for another
/// open window (Task 3). Outside any view, so it can be driven with values
/// instead of read as text; see this file's opening comment for the
/// ordering rules all of it obeys.
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
    /// afterwards, so the ordering this file's opening comment sets out
    /// cannot be got wrong at a call site — and so a test can hand in a
    /// closure that does nothing and drive the "the window never opened"
    /// path.
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
        openWindow: (WindowSeed) -> Void,
        onClaimed: @escaping @MainActor (Outcome) -> Void
    ) -> Outcome {
        let closesWindow = WindowCloseDecision.after(
            removing: tabID, in: model.tabs.map(\.id), windowCount: registry.windowCount)
        guard let tab = model.detach(tabID: tabID) else { return .none }
        // The replacement is decided BEFORE the park, so the outcome handed
        // to `onClaimed` is the finished one — the handler must not be given
        // a half-built answer it would then have to complete itself.
        var replacementID: UUID?
        if model.tabs.isEmpty {
            let fresh = replacement()
            replacementID = fresh.id
            model.addTab(fresh)
        }
        let outcome = Outcome(closesWindow: closesWindow, replacementID: replacementID)
        registry.park([tab], for: seed.id, onClaimed: { onClaimed(outcome) })
        openWindow(seed)
        return outcome
    }

    /// Moves `tabID` from one OPEN window's model into another's — the drag
    /// between two windows (Task 3) — and answers whether the source window
    /// is now left with nothing of its own.
    ///
    /// **No parking, and no reclaim.** Both windows already exist, so there
    /// is no gap between letting go and being taken over: the whole handover
    /// is `TabRegistry.move(_:from:to:targetWindow:)`, which detaches from
    /// one model, reassigns ownership and adds to the other in one call. The
    /// asymmetry with
    /// `move(_:outOf:parkingUnder:in:replacement:openWindow:onClaimed:)`
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
    /// Nothing here touches the tab's connection: see
    /// `TabRegistry.move(_:from:to:targetWindow:)`, which is the whole of
    /// the handover, and `TabRegistryNoTeardownGuardTests`, which reads this
    /// file for the four names a move must never reach.
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
    /// **Never called on a turn count** (fix round 2). The window opened for
    /// a seed claims it from its own setup pass, on a later display pass,
    /// so "one turn later" is not late enough and was measured wrong. The
    /// trigger is the source window being ACTIVATED again with the seed
    /// still unclaimed: by then a window that was going to appear has
    /// appeared. `false` — the ordinary case — means a window claimed the
    /// tab and there was nothing to put back.
    ///
    /// It goes through `TabRegistry.unpark(seedID:into:)` rather than
    /// `claim(seedID:into:)` precisely because this is NOT a claim: firing
    /// the seed's `onClaimed` handler here would tell this same window to
    /// close over the tab it has just been handed back.
    @discardableResult
    static func reclaim(
        seedID: UUID,
        into model: TabsViewModel<SessionTab>,
        from registry: TabRegistry,
        window: WindowID,
        removing replacementID: UUID?
    ) -> Bool {
        let stranded = registry.unpark(seedID: seedID, into: window)
        guard !stranded.isEmpty else { return false }
        // Added BEFORE the placeholder goes, so the model is never empty and
        // `activeTabID` never dangles — `addTab` also makes the returning
        // tab the active one, which is where the user left it.
        for tab in stranded { model.addTab(tab) }
        if let replacementID { model.detach(tabID: replacementID) }
        return true
    }
}
