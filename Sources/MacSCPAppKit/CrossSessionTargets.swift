import Foundation
import macSCPCore

/// Cross-session transfer targets for a tab's context menu (M8b/T4): every
/// OTHER tab that currently has a live session, in tab-strip order, mapped
/// to its remote pane's CURRENT directory. Lifted out of `ContentView` so
/// the two rules — the tab never offers itself, and a tab without a session
/// is skipped — are held by tests rather than by reading.
///
/// Called fresh from inside `menuNeedsUpdate` on every menu open (never
/// cached) — the menu itself freezes the resulting path into
/// `CrossSessionTarget` at build time (Spec §5.3), so staleness is bounded
/// to "between two menu opens", never longer.
enum CrossSessionTargets {
    /// `@MainActor`-isolated because `SessionTab` is; nothing else here needs
    /// the isolation, so it stays on this one function rather than the type.
    @MainActor
    static func targets(excluding tabID: UUID, in tabs: [SessionTab]) -> [CrossSessionTarget] {
        tabs.compactMap { other in
            guard other.id != tabID, let session = other.session else { return nil }
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
        }
    }
}
