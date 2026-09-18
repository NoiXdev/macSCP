import Foundation
import macSCPCore

/// What a tab is titled (jump-and-groups plan, Task 3): the name of the
/// session it shows or edits, or "New Connection" when it has none.
///
/// One value for two places — the tab strip's label and the window title —
/// so the two cannot say different things about the same tab. Each place
/// renders it in its own way (`tabLabel`, `windowTitle`); neither decides
/// which name applies.
enum TabTitle: Equatable {
    /// A session's name — the connected one, the one an attempt dials, the
    /// one the form edits, or the one the detail pane describes.
    case named(String)
    /// Nothing to name: the catalogue's "New Connection".
    case newConnection

    /// The tab strip's text. The italic that marks an unconnected tab is
    /// the strip's own, read off the tab, and applies to every case here
    /// but a connected one.
    var tabLabel: String {
        switch self {
        case .named(let name): name
        case .newConnection: L10n.string("tabs.newConnection", "New Connection")
        }
    }

    /// The window title. Window chrome, deliberately not localized, and
    /// the bare app name when there is nothing to name — what an
    /// unconnected window said before this type existed.
    var windowTitle: String {
        switch self {
        case .named(let name): "macSCP — \(name)"
        case .newConnection: "macSCP"
        }
    }
}

/// The one decision behind `TabTitle` — a plain function over plain values,
/// for the reason every other decision about a tab was pulled out of a view
/// body: nothing in this project can render a view in a test.
///
/// Takes plain values. `ContentView.tabTitle(for:)` is the one place they
/// are read off a tab and the window; this type never sees either.
enum TabTitlePlan {
    /// The first rule that has a name answers:
    ///
    /// 1. **Connected** — `connectedName`, the tab's `titleName`, which is
    ///    set on a successful connect and cleared in teardown.
    /// 2. **Connecting, failed or lost** — the stored session the attempt
    ///    was for, resolved against `sessions`: a dropped connection's
    ///    `LostConnection.storedSessionID`, a failed attempt's
    ///    `ConnectFailure.storedSessionID`, and otherwise, while a dial is
    ///    in flight (`liveness == .connecting`) or its failure is still
    ///    unread on the form (`unacknowledgedFailure`), the form's own
    ///    `attemptOrigin`. An ad-hoc attempt has no stored session and so
    ///    no name here.
    /// 3. **Editing** — the session an `.edit` form holds, resolved against
    ///    `sessions`, so the tab shows the stored name, not the draft.
    /// 4. **Showing the overview** — the session in `surface`'s `.overview`
    ///    case, and only on the ACTIVE tab. `surface` is
    ///    `DetailSurfacePlan.surface`'s answer for this tab, the same one
    ///    the detail pane switches on, so the title cannot claim an overview
    ///    the pane is not showing. The active-tab condition is the
    ///    maintainer decision of 2026-09-18 (taken on their behalf): the
    ///    overview's session comes from the window's sidebar selection
    ///    unless the tab was restored pointing at one, and the detail pane
    ///    only ever shows the active tab — so without it every unconnected
    ///    tab in the window would take the selected session's name.
    /// 5. Otherwise **"New Connection"**.
    ///
    /// A resolved name that is empty does not answer; the next rule does.
    /// A session deleted while a tab points at it resolves to nothing, for
    /// the same reason.
    static func title(
        connectedName: String?, liveness: ConnectionLiveness?,
        lostConnection: LostConnection?, connectFailure: ConnectFailure?,
        unacknowledgedFailure: Bool, attemptOrigin: UUID?,
        formMode: ConnectionViewModel.FormMode, surface: DetailSurface, isActive: Bool,
        sessions: [StoredSession]
    ) -> TabTitle {
        func named(_ name: String?) -> TabTitle? {
            guard let name, !name.isEmpty else { return nil }
            return .named(name)
        }
        func stored(_ id: UUID?) -> TabTitle? {
            guard let id else { return nil }
            return named(sessions.first { $0.id == id }?.name)
        }

        if let connected = named(connectedName) { return connected }

        let attemptTarget: UUID?
        if let lostConnection {
            attemptTarget = lostConnection.storedSessionID
        } else if let connectFailure {
            attemptTarget = connectFailure.storedSessionID
        } else if liveness == .connecting || unacknowledgedFailure {
            attemptTarget = attemptOrigin
        } else {
            attemptTarget = nil
        }
        if let attempt = stored(attemptTarget) { return attempt }

        if case .edit(let sessionID) = formMode, let editing = stored(sessionID) { return editing }

        if isActive, case .overview(let shown) = surface, let overview = named(shown.name) {
            return overview
        }
        return .newConnection
    }
}
