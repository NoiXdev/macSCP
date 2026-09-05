import Foundation
import macSCPCore

/// A tab entering a window — the other end of `TabDetachSequence`, which is
/// a tab leaving one (Detachable Tabs plan, Task 3 fix round 1).
///
/// **Why this is a type and not two lines at each call site.** Five places
/// in `ContentView*` make a tab: the strip's ⊕ button, ⌘N, "New connection"
/// over a connected tab, `formTarget()` over a connected tab, and the claim
/// of a seed. Each of them used to call `tabsModel.addTab(…)` alone, and
/// `TabRegistry` caught up later — from `registerHeldTabs()` in the
/// `.onChange(of: tabIDs)` handler, which is a SwiftUI update pass and not
/// the same main-actor turn.
///
/// That gap is not theoretical for one particular reader: `WindowCloseDecision
/// .after(removing:in:windowCount:)` is called SYNCHRONOUSLY inside both of
/// `TabDetachSequence`'s moves, and `windowCount` is a registry number. A
/// drop landing in the same turn a tab was made would take the close
/// decision against a registry one pass behind the model. `MainWindowPresence`
/// reads the same number.
///
/// So the pair is written once, here, and `TabRegistrationWiringGuardTests`
/// pins that `ContentView*` contains no other `tabsModel.addTab(` at all.
/// `registerHeldTabs()` stays where it is — it is the sweep that keeps the
/// registry right after a route this file does not know about, and it is
/// idempotent, so it costs nothing now that it has nothing to catch up on.
///
/// Nothing here touches the tab's connection: `addTab` appends a reference
/// to an array and `register` writes two dictionary entries.
@MainActor
enum TabAdmission {
    /// Puts `tab` in `model` and records it as `window`'s, in one
    /// statement, with no suspension point between the two.
    ///
    /// `register(_:in:)` relocates a tab the registry already knows rather
    /// than duplicating it, so admitting a tab the registry placed here
    /// first — which is exactly what the claim path does — says the same
    /// thing twice and changes nothing.
    ///
    /// `after` places the arriving tab next to another one instead of at
    /// the far end of the strip — "Duplicate Tab"'s own admission, through
    /// `ContentView.addTabRegistering(_:after:)` — and is `nil` for every
    /// other caller, which keeps `model.addTab(_:)`'s ordinary append.
    static func add(
        _ tab: SessionTab,
        to model: TabsViewModel<SessionTab>,
        in registry: TabRegistry,
        window: WindowID,
        after id: UUID? = nil
    ) {
        if let id {
            model.addTab(tab, after: id)
        } else {
            model.addTab(tab)
        }
        registry.register(tab, in: window)
    }
}
