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
    /// THREE rules now, counted 2026-09-02 against the two `guard`
    /// statements below (the first carries two conditions): the tab never offers itself, a
    /// tab without a session is skipped, and — since fix round 1 of the
    /// bucket-list task — a tab whose remote pane is sitting at a bucket
    /// list is not offered either.
    ///
    /// The third is the same destination-side question the drop target and
    /// `BrowserContextMenu.entries(…, destination:)` ask, asked here because
    /// this is the one place each target's OWN destination is known: a
    /// cross-session transfer aims at another tab's remote pane, not at this
    /// window's other pane, so `entries` cannot answer for it. A target that
    /// cannot receive is removed rather than offered-and-refused, which is
    /// what "only show what is possible" means for every other door.
    ///
    /// `@MainActor`-isolated because `SessionTab` is; nothing else here needs
    /// the isolation, so it stays on this one function rather than the type.
    @MainActor
    static func targets(excluding tabID: UUID, in tabs: [SessionTab]) -> [CrossSessionTarget] {
        tabs.compactMap { other in
            guard other.id != tabID, let session = other.session else { return nil }
            let scope = BrowserScope(
                rootIsContainerList: session.remoteFS.rootIsContainerList,
                currentPath: session.remote.currentPath)
            guard scope.acceptsIncomingFiles else { return nil }
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
        }
    }
}
