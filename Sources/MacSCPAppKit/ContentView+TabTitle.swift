import Foundation
import macSCPCore

extension ContentView {
    /// What `tab` is titled (jump-and-groups plan, Task 3):
    /// `TabTitlePlan.title`'s answer, with the facts it decides on read off
    /// the tab and the window here, and nowhere else. The tab strip draws
    /// it for every tab and the window title for the active one.
    ///
    /// "Showing the overview" is not decided here. It is
    /// `detailSurface(for:)` — the very answer the detail pane switches on
    /// — so the title cannot name an overview the pane is not showing,
    /// and cannot miss one it is. What this adds to it is only the one
    /// fact the surface does not carry: whether this tab is the one the
    /// detail pane is drawing. `TabTitleWiringGuardTests` holds the
    /// resolver to both.
    ///
    /// In a file of its own rather than beside `detailSurface(for:)`:
    /// `DetailSurfaceWiringGuardTests` holds `ContentView+Detail.swift` to
    /// reading the form's mode and failure marker in that one resolver
    /// only, as the facts an overview is decided on. The title reads the
    /// mode for a different rule — the session an `.edit` form holds — and
    /// takes the overview itself from the surface.
    func tabTitle(for tab: SessionTab) -> TabTitle {
        let form = tab.connectionViewModel
        return TabTitlePlan.title(
            connectedName: tab.titleName, liveness: tab.liveness,
            lostConnection: tab.lostConnection, connectFailure: tab.connectFailure,
            unacknowledgedFailure: form.unacknowledgedFailure != nil,
            attemptOrigin: form.attemptOrigin, formMode: form.mode,
            surface: detailSurface(for: tab), isActive: tab.id == activeTab.id,
            sessions: sessionListViewModel.sessions)
    }
}
