import AppKit
import Carbon
import ServiceManagement

/// The login item's state, as the SYSTEM reports it — never as this app
/// wishes it were (port-forwarding plan, Task 7).
///
/// There are four answers and each one means something different to the
/// user, which is why this is not a `Bool`:
///
/// - `.enabled` — macOS will launch macSCP at login.
/// - `.notRegistered` — it will not, and nothing is pending.
/// - `.requiresApproval` — macSCP asked, and the user has to allow it in
///   System Settings › General › Login Items. `register()` returns without
///   throwing in this case, so a `Bool` would read "on" while nothing
///   happens at login.
/// - `.notFound` — the service is not installed at all. A dev build run out
///   of `swift run`, or an ad-hoc-signed `.app` the system will not accept
///   as a login item, lands here.
///
/// `.unknown` is the honest answer to a future case: `SMAppService.Status`
/// is not frozen, and a `default:` that silently reported `.notRegistered`
/// would be this app inventing a fact.
enum LoginItemStatus: Hashable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

/// The pure half of the login item: `SMAppService.Status` → `LoginItemStatus`.
///
/// Split out so it can be measured without a service. Reading
/// `SMAppService.Status.enabled` is reading an enum constant; it registers
/// nothing, queries nothing and touches no launchd job, which is the line
/// `LoginItemTests` stays on the safe side of.
enum LoginItemStatusPlan {
    static func status(_ raw: SMAppService.Status) -> LoginItemStatus {
        switch raw {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
}

/// The seam between this app and `SMAppService`.
///
/// Everything that TOUCHES the service is behind it, and the reason is the
/// same one `TunnelRunning` gives one layer down: a test must be able to
/// drive every branch — including the ones that throw and the one the system
/// answers `.requiresApproval` to — without registering a real login item on
/// the machine running `swift test`. `LoginItemGuardTests` scans the test
/// sources for `SMAppService.mainApp` to keep that true.
@MainActor
protocol LoginItemRegistering {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

/// The one production conformance: the app's own bundle as a login item.
struct SystemLoginItem: LoginItemRegistering {
    func status() -> LoginItemStatus {
        LoginItemStatusPlan.status(SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// What the autostart overlay's "Open macSCP at login" row shows and does.
///
/// **The toggle shows the STATUS, never the last thing that was asked for**
/// (design, "the status shown as the system reports it"). `register()` can
/// return without throwing and leave the service at `.requiresApproval`, and
/// an ad-hoc-signed dev build can be refused outright — so the row is
/// re-read from the service after every change rather than mirrored from the
/// click.
///
/// A thrown `SMAppService` error is a DISPLAYED failure: `errorMessage`
/// carries `error.localizedDescription` beside a localized lead-in, and the
/// app goes on running. Nothing here traps.
@MainActor
@Observable
final class LoginItemModel {
    @ObservationIgnored private let service: any LoginItemRegistering

    private(set) var status: LoginItemStatus
    /// The last failure, or `nil`. Cleared at the start of every attempt so
    /// a stale sentence cannot outlive the state it described.
    private(set) var errorMessage: String?

    init(service: any LoginItemRegistering = SystemLoginItem()) {
        self.service = service
        status = service.status()
    }

    /// Whether the toggle is drawn on. `.requiresApproval` counts as on: the
    /// app HAS asked, and what is missing is the user's approval, which the
    /// row's own explanation names.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = service.status()
    }

    /// Registers or unregisters, then re-reads. The re-read runs even when
    /// the call threw: a partial registration is exactly the case where the
    /// wish and the fact disagree.
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = String(
                format: L10n.string("tunnel.autostart.loginItem.error %@", "Could not change the login item: %@"),
                error.localizedDescription)
        }
        refresh()
    }
}

/// Whether THIS launch was started by macOS at login.
///
/// **What it reads.** The Apple event that opened the app: an
/// `kAEOpenApplication` event whose `keyAEPropData` parameter carries
/// `keyAELaunchedAsLogInItem`. That is the only signal macOS offers, it is
/// only present while the launch event is current — which is why the one
/// production caller asks inside `applicationDidFinishLaunching(_:)` and
/// nowhere else — and it is asked through a seam so the decision is testable
/// without a login.
///
/// **What it cannot answer, stated.** This flag has NOT been observed true
/// on this project's own machine: doing so needs a real login launch of a
/// signed, registered `.app`, which no test and no dev build here performs
/// (`swift run` and the dev-build recipe both launch from a shell). So the
/// failure mode is deliberately the conservative one: an unreadable or
/// absent flag reads `false`, and a profile set to "At login" then simply
/// does not start on its own — the user starts it from the menu. It never
/// goes the other way, and no launch starts a forwarding the user did not
/// ask for.
///
/// **What is NOT shipped because of that.** The design's optional "Start in
/// the background" toggle — ordering the main window out at a login launch —
/// is not here. It is only correct if the flag is right, and a wrong `true`
/// would hide the window of an ordinary launch. `docs/BACKLOG.md` carries
/// the row.
enum LoginLaunchDetector {
    /// The current launch's answer, read from the Apple Event Manager.
    @MainActor
    static func launchedAtLogin() -> Bool {
        launchedAtLogin(event: NSAppleEventManager.shared().currentAppleEvent)
    }

    /// The same decision over an event a test supplies.
    static func launchedAtLogin(event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
            event.eventClass == AEEventClass(kCoreEventClass),
            event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == UInt32(keyAELaunchedAsLogInItem)
    }
}
