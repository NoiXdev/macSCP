import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The Dock badge, driven end to end over the real `TunnelManager` and a
/// recorded tile (port-forwarding plan, Task 7).
///
/// **Nothing here touches `NSApp.dockTile`.** That is a process-wide AppKit
/// singleton belonging to whatever is running the tests; the controller
/// writes through `DockBadgeDisplaying`, and this suite hands it a recorder.
///
/// **What only an end-to-end drive can show** is that the observation
/// RE-ARMS. `withObservationTracking` fires exactly once, so a controller
/// that forgot to arm again would paint the first change and then go silent
/// — which looks exactly like a badge that is up to date. So every test
/// below drives at least two changes, and reads the badge after each.
///
/// The manager runs on `TunnelManagerTests.Rig` — the same fake runners, the
/// same real `TunnelStore` on a temporary directory — reused rather than
/// copied.
@Suite("Tunnel Dock presence", .timeLimit(.minutes(1)))
@MainActor
struct TunnelDockPresenceTests {

    /// The tile, as a value. Records every label it was given so a test can
    /// tell "never written" from "written back to nil".
    @MainActor
    final class RecordingTile: DockBadgeDisplaying {
        private(set) var writes: [String?] = []
        var badge: String? {
            get { writes.last ?? nil }
            set { writes.append(newValue) }
        }
    }

    private static func profile(
        session: UUID, name: String, port: Int,
        autoStart: TunnelProfile.AutoStart = .off
    ) -> TunnelProfile {
        TunnelProfile(
            sessionID: session, name: name,
            kind: .local(bind: "127.0.0.1", localPort: port, host: "internal", remotePort: 80),
            autoStart: autoStart)
    }

    private static let refusing = HostKeyDecider.refusing

    // MARK: - The badge

    /// A start, a failure and a stop — three changes, each read back. The
    /// second and third are what prove the observation re-armed.
    @Test func theBadgeFollowsEveryChangeAndNotJustTheFirst() async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let session = UUID()
        let profile = Self.profile(session: session, name: "web", port: 8080)
        try rig.store.upsert(profile)
        rig.manager.reload()

        let tile = RecordingTile()
        let controller = DockBadgeController(manager: rig.manager, display: tile)
        controller.start()
        #expect(tile.badge == nil, "a stopped forwarding put a badge on the Dock")

        await rig.manager.start(profile, decider: Self.refusing)
        try await pollUntil("the badge counts the started forwarding") { tile.badge == "1" }

        try rig.runner(profile).emit(.failed(reason: "port 8080 is in use"))
        try await pollUntil("the badge marks the failure") { tile.badge == "!" }

        try rig.runner(profile).emit(.stopped)
        try await pollUntil("the badge clears when nothing is up") { tile.badge == nil }
    }

    /// A second forwarding changes the number, and the number is of TUNNELS
    /// — a tunnel carrying several connections is still one.
    @Test func theBadgeCountsTunnels() async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let session = UUID()
        let first = Self.profile(session: session, name: "web", port: 8080)
        let second = Self.profile(session: session, name: "db", port: 5432)
        try rig.store.upsert(first)
        try rig.store.upsert(second)
        rig.manager.reload()

        let tile = RecordingTile()
        // Bound to a `let`: the controller re-arms its observation from a
        // `[weak self]` closure, so one that nothing holds stops watching the
        // moment it is collected. That is why the app delegate keeps its own.
        let controller = DockBadgeController(manager: rig.manager, display: tile)
        controller.start()

        await rig.manager.start(first, decider: Self.refusing)
        try await pollUntil("one forwarding is counted") { tile.badge == "1" }

        try rig.runner(first).emit(.active(connections: 12))
        await rig.manager.start(second, decider: Self.refusing)
        try await pollUntil("two forwardings are counted") { tile.badge == "2" }
    }

    /// A profile DELETED while its badge is up takes its count with it. The
    /// controller observes `allProfiles` as well as `states` for exactly this
    /// case; watching only the second would leave the Dock counting a
    /// forwarding that no longer exists.
    @Test func deletingAProfileClearsWhatItContributed() async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let session = UUID()
        let profile = Self.profile(session: session, name: "web", port: 8080)
        try rig.store.upsert(profile)
        rig.manager.reload()

        let tile = RecordingTile()
        let controller = DockBadgeController(manager: rig.manager, display: tile)
        controller.start()
        await rig.manager.start(profile, decider: Self.refusing)
        try await pollUntil("the badge counts it") { tile.badge == "1" }

        try await rig.manager.remove(profile)
        try await pollUntil("the badge forgets a deleted forwarding") { tile.badge == nil }
    }

    // MARK: - The block

    /// The block lists what the plan says over the manager's live state, and
    /// the entry for a running profile is checked.
    @Test func theBlockReflectsTheManagersLiveState() async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let session = UUID()
        let manual = Self.profile(session: session, name: "manual", port: 8080)
        let atLaunch = Self.profile(
            session: session, name: "at launch", port: 9090, autoStart: .appStart)
        try rig.store.upsert(manual)
        try rig.store.upsert(atLaunch)
        rig.manager.reload()

        let block = TunnelMenuBlockController(manager: rig.manager)
        // Only the autostart profile is listed while nothing runs — plus the
        // header, which is the first item.
        let titles = block.items().map(\.title)
        #expect(titles.contains("at launch"))
        #expect(!titles.contains("manual"), "a stopped, manual forwarding is listed in the Dock menu")

        // The manager mirrors a runner's states through an `AsyncStream`, so
        // `start` returning is not the same moment as the state landing.
        await rig.manager.start(manual, decider: Self.refusing)
        try await pollUntil("the started forwarding reads as running") {
            TunnelManager.Aggregate.isRunning(rig.manager.state(of: manual.id))
        }
        let running = block.items()
        #expect(
            running.map(\.title).contains("manual"),
            "a running forwarding is missing from the Dock menu")
        let entry = try #require(running.first { $0.title == "manual" })
        #expect(entry.state == .on, "a running forwarding is not checked")
        #expect(entry.representedObject as? UUID == manual.id)
    }

    /// The header counts what is running, and it is a plural form rather than
    /// a bare number glued to a noun.
    @Test func theBlockHeaderCountsWhatIsRunning() async throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let session = UUID()
        let profile = Self.profile(
            session: session, name: "web", port: 8080, autoStart: .appStart)
        try rig.store.upsert(profile)
        rig.manager.reload()

        let block = TunnelMenuBlockController(manager: rig.manager)
        let idle = try #require(block.items().first).title
        #expect(idle.contains("0"))

        await rig.manager.start(profile, decider: Self.refusing)
        try await pollUntil("the started forwarding reads as running") {
            TunnelManager.Aggregate.isRunning(rig.manager.state(of: profile.id))
        }
        let busy = try #require(block.items().first).title
        #expect(busy.contains("1"))
        #expect(busy != idle, "the header does not change when a forwarding starts")
    }

    /// Nothing configured: the block says so rather than showing an empty
    /// stretch of menu.
    @Test func anEmptyBlockSaysSo() throws {
        let rig = TunnelManagerTests.Rig()
        defer { rig.tearDown() }
        let block = TunnelMenuBlockController(manager: rig.manager)
        let items = block.items()
        #expect(items.count == 2, "an empty block should be a header and one explanation")
        #expect(items.allSatisfy { $0.action == nil }, "an empty block offers a clickable entry")
    }
}
