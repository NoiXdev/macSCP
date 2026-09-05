import Foundation

/// What a window opens with (Detachable Tabs plan, Task 2).
///
/// SwiftUI's `WindowGroup(for:)` keys each window instance on a value, and
/// `openWindow(value:)` is what opens a second one. This is that value: the
/// ids of the tabs the new window is to take over. The tabs themselves are
/// parked in `TabRegistry` by the window they leave and claimed by the
/// window that appears for this seed — a seed carries identifiers, never
/// objects, because SwiftUI persists it (it is `Codable` for exactly that
/// reason) and a persisted `SessionTab` would be a connection written to
/// disk.
///
/// **ONE type, which Task 5 grows.** Task 5 (window restoration) adds, per
/// tab, the session id, the pane visibility and the window's sticky flag —
/// as FIELDS on this struct, not as a second seed type beside it. It is
/// declared `Codable` from the start so that addition is a field, and the
/// window that reads a seed is the same window in both tasks.
///
/// **`id` exists to defeat window reuse.** A value-keyed `WindowGroup`
/// raises the window it already opened for an EQUAL value instead of
/// opening a new one. A seed is consumed the moment its window appears, so
/// two moves must never present equal values — the second would raise the
/// first window and the tab would go nowhere. A fresh `id` per seed makes
/// equality per-move, and it is what the registry parks under
/// (`TabRegistry.park(_:for:)` / `claim(seedID:into:)`), so the claim can
/// only ever pick up what THIS move parked.
///
/// A seed SwiftUI restored from a previous launch names ids no live tab
/// carries; `claim(seedID:into:)` answers it with nothing and the window
/// comes up with its own fresh tab, which is what Task 5 will replace with
/// a real restoration.
struct WindowSeed: Codable, Hashable, Sendable {
    /// Unique per seed — see the type's doc comment for why equality must
    /// be per-move rather than per-tab-list.
    let id: UUID
    /// The tabs this window takes over, in the order it should show them.
    var tabIDs: [UUID]

    init(tabIDs: [UUID], id: UUID = UUID()) {
        self.id = id
        self.tabIDs = tabIDs
    }
}
