import AppKit
import macSCPCore

/// The Dock tile's badge, as a seam (port-forwarding plan, Task 7).
///
/// `NSApp.dockTile` is a process-wide AppKit singleton that exists only in a
/// running application; a test that wrote to it would be writing to the
/// harness's own Dock tile. So the controller below writes THROUGH this, and
/// `TunnelDockPresenceTests` hands it a recorder.
@MainActor
protocol DockBadgeDisplaying: AnyObject {
    var badge: String? { get set }
}

/// The one production conformance.
///
/// `display()` after every write: `NSDockTile` documents that a badge change
/// is not guaranteed to be drawn until the tile is asked to redraw, and a
/// forwarding failing while the app is in the background is exactly the case
/// where nobody is going to give it another reason to.
@MainActor
final class SystemDockBadge: DockBadgeDisplaying {
    var badge: String? {
        get { NSApp.dockTile.badgeLabel }
        set {
            NSApp.dockTile.badgeLabel = newValue
            NSApp.dockTile.display()
        }
    }
}

/// Keeps the Dock badge equal to `DockBadgePlan.label(states:)` for as long
/// as the app runs.
///
/// **Observed, not polled.** `TunnelManager` is `@Observable` and its
/// `states` dictionary is what every state change writes to, so
/// `withObservationTracking` fires once per change and this re-arms — the
/// same shape `MenuBarController.observe()` uses for its own two values, and
/// for the same reason: a timer would either lag a failure or spend the
/// app's whole life waking up to find nothing changed.
///
/// **Re-arming is the load-bearing half.** `withObservationTracking` fires
/// its `onChange` exactly once; a controller that forgot to arm again would
/// paint the first change and then go quiet forever — which looks precisely
/// like a badge that is up to date.
@MainActor
final class DockBadgeController {
    private let manager: TunnelManager
    private let display: any DockBadgeDisplaying

    init(manager: TunnelManager, display: any DockBadgeDisplaying = SystemDockBadge()) {
        self.manager = manager
        self.display = display
    }

    /// Paints the badge once and starts watching. Called from the launch
    /// path; there is no `stop()` because the badge's life is the process's.
    func start() {
        apply()
        observe()
    }

    /// The badge as the states currently read. `internal` rather than
    /// private so the tests can drive one turn of it without depending on
    /// when the observation fires.
    func apply() {
        display.badge = DockBadgePlan.label(states: currentStates)
    }

    private var currentStates: [TunnelState] {
        manager.allProfiles.map { manager.state(of: $0.id) }
    }

    private func observe() {
        withObservationTracking {
            // BOTH are read on purpose: `states` changes when a tunnel does,
            // and `allProfiles` changes when one is added, edited or deleted
            // — a badge that tracked only the first would keep counting a
            // profile that no longer exists.
            _ = manager.states
            _ = manager.allProfiles
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply()
                self.observe()
            }
        }
    }
}

/// The forwarding block that the two menus with no session in front of them
/// draw: the Dock menu (`AppDelegate.applicationDockMenu(_:)`) and the
/// menu-bar item (`MenuBarController.menuNeedsUpdate(_:)`).
///
/// **One builder for both**, because they are the same block: the design asks
/// the menu-bar item to carry what the Dock menu carries, and two copies of
/// an NSMenu assembly is exactly the second spelling this project keeps
/// paying for.
///
/// **Every start here uses `.refusing`.** Neither menu belongs to a window,
/// so there is nowhere to draw a host-key question — the same situation
/// autostart is in, and it gets the same answer: an unknown key leaves the
/// profile at `.needsConfirmation` and the user connects that session once,
/// by hand, in a window. There is no accept-anything path anywhere in this
/// file.
///
/// **What "all" means here.** `Start all`/`Stop all` act on the profiles this
/// block LISTS — and `TunnelMenuBlockPlan` is the one place that decides which
/// those are: running, asking to start on their own, or needing attention
/// (`.failed`/`.needsConfirmation`, added in fix round 1 so the Dock badge's
/// `"!"` always has a row behind it). Never on every profile the app has
/// stored: a Dock click must not be able to dial a host the user never asked
/// this menu about, and those are reached from their own session's row.
///
/// A consequence of the third ground, stated because it is a behaviour and not
/// only a listing: `Start all` retries a `.failed` forwarding, which is the
/// same thing clicking that row does and the same thing the session row's own
/// "Start all" has always done for one.
@MainActor
final class TunnelMenuBlockController: NSObject {
    private let manager: TunnelManager

    init(manager: TunnelManager) {
        self.manager = manager
        super.init()
    }

    private var entries: [TunnelMenuBlockPlan.Entry] {
        TunnelMenuBlockPlan.entries(
            profiles: manager.allProfiles, state: { manager.state(of: $0) })
    }

    /// The block, rebuilt per menu open — both callers rebuild their whole
    /// menu that way, so nothing here has to stay live between opens.
    func items() -> [NSMenuItem] {
        let listed = entries
        var items: [NSMenuItem] = [header(running: manager.runningCount)]

        if listed.isEmpty {
            items.append(disabled(L10n.string("tunnel.dock.empty", "No forwardings set up")))
            return items
        }

        for entry in listed {
            let item = NSMenuItem(
                title: entry.profile.name, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.profile.id
            item.state = entry.isRunning ? .on : .off
            // The second channel beside the checkmark: the state's own
            // label, which for a `.failed` tunnel is its failure kind in the
            // app's language (`TunnelProfilesSheet.stateLabel`).
            item.toolTip = TunnelProfilesSheet.stateLabel(manager.state(of: entry.profile.id))
            items.append(item)
        }

        items.append(.separator())
        items.append(
            action(L10n.string("tunnel.menu.startAll", "Start all"), #selector(startAll)))
        items.append(
            action(L10n.string("tunnel.menu.stopAll", "Stop all"), #selector(stopAll)))
        return items
    }

    /// "n forwardings running" — a plural form, because "1 forwardings" is
    /// how a count without one reads.
    private func header(running: Int) -> NSMenuItem {
        disabled(String(
            format: L10n.string("tunnel.dock.running %lld", "%lld forwardings running"), running))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let profile = manager.allProfiles.first(where: { $0.id == id })
        else { return }
        let running = TunnelManager.Aggregate.isRunning(manager.state(of: id))
        Task { @MainActor in
            if running {
                await manager.stop(profile)
            } else {
                await manager.start(profile, decider: .refusing)
            }
        }
    }

    @objc private func startAll() {
        let listed = entries.filter { !$0.isRunning }.map(\.profile)
        Task { @MainActor in
            for profile in listed {
                await manager.start(profile, decider: .refusing)
            }
        }
    }

    @objc private func stopAll() {
        let listed = entries.filter(\.isRunning).map(\.profile)
        Task { @MainActor in
            for profile in listed {
                await manager.stop(profile)
            }
        }
    }
}
