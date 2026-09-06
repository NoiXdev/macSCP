import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The app-wide tunnel manager: what it starts, what it stops, and what a
/// view can read while it does (port-forwarding plan, Task 6).
///
/// **Nothing here dials.** The manager takes its runners from a factory, and
/// every test below hands it `FakeTunnelRunner`s — so a start is a counter
/// and a published state, never a socket. That is also what makes the
/// autostart claim measurable: a fake runner ASKS the decider it was handed,
/// and records the answer, which is the only thing about a `HostKeyDecider`
/// an outside observer can see.
///
/// The store is a real `TunnelStore` on a temporary directory: the profiles
/// the manager hands out come back through JSON, so a save that does not
/// persist fails here rather than in a dev build.
@Suite("Tunnel manager", .timeLimit(.minutes(1)))
@MainActor
struct TunnelManagerTests {

    // MARK: - Fakes and fixtures

    /// A runner that records what it was asked to do and publishes whatever
    /// a test tells it to.
    ///
    /// `deciderAnswers` is the one observable fact about the decider the
    /// manager handed in: a `HostKeyDecider` exposes nothing but its answer,
    /// so the fake asks it about a candidate and keeps the `Bool`.
    /// `.refusing` answers `false`; a decider built from a window's prompt
    /// answers whatever the prompt was told to.
    @MainActor
    final class FakeTunnelRunner: TunnelRunning {
        nonisolated let states: AsyncStream<TunnelState>
        private let publish: AsyncStream<TunnelState>.Continuation

        let profile: TunnelProfile
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var deciderAnswers: [Bool] = []

        init(profile: TunnelProfile) {
            self.profile = profile
            (states, publish) = AsyncStream.makeStream(of: TunnelState.self)
        }

        func start(decider: HostKeyDecider) async {
            startCount += 1
            deciderAnswers.append(await decider(Self.candidate))
            publish.yield(.active(connections: 0))
        }

        /// Awaited INSIDE `stop()`, before it counts or publishes anything.
        /// A test that has to hold a stop open — a discard racing a start, n
        /// stops proving they run at once — sets this; everything else
        /// leaves it nil and `stop()` returns straight away.
        var beforeStop: (@MainActor () async -> Void)?

        func stop() async {
            await beforeStop?()
            stopCount += 1
            publish.yield(.stopped)
        }

        /// Publishes a state the runner would have reached by itself — a
        /// loss, a failure, a reconnect.
        func emit(_ state: TunnelState) { publish.yield(state) }

        /// Carries no key material: the base64 is empty, so the fingerprint
        /// this candidate renders is the "unknown" placeholder.
        private static let candidate = HostKeyCandidate(
            host: "example.invalid", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "")
    }

    /// A latch several parked stops can wait on, and a count of how many
    /// arrived.
    ///
    /// Polls rather than parking on a continuation: several waiters need to
    /// be released at once, a single `AsyncStream` fans out to none of them,
    /// and a bare `withCheckedContinuation` is what `PollingGuardTests
    /// .noBareContinuationEscapesAwaitResumption` exists to keep out of this
    /// tree. No deadline of its own — the wait ends when the gate opens or
    /// when the awaiting task is cancelled, which for a wait that never
    /// finishes is this suite's `.timeLimit` (CLAUDE.md, "A wall-clock
    /// ceiling in a test measures the runner").
    @MainActor
    final class Gate {
        private var isOpen = false
        private(set) var arrived = 0

        func wait() async {
            arrived += 1
            while !isOpen {
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
            }
        }

        func open() { isOpen = true }
    }

    /// "That task got to its end" — the cancellable substitute for
    /// `await task.value`, which ignores its awaiter's cancellation and so
    /// hangs a suite instead of failing it.
    @MainActor
    final class Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    /// Every runner the factory built, by profile id. Its own object because
    /// the factory closure is built before the rig below finishes
    /// initializing and has to write somewhere that outlives the call.
    @MainActor
    final class RunnerLog {
        private(set) var runners: [UUID: FakeTunnelRunner] = [:]
        func record(_ runner: FakeTunnelRunner) { runners[runner.profile.id] = runner }
    }

    /// One manager over a fresh store directory, plus the record of every
    /// runner it built.
    @MainActor
    final class Rig {
        let directory: URL
        let store: TunnelStore
        let manager: TunnelManager
        let log: RunnerLog

        init() {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tunnel-manager-\(UUID().uuidString)")
            let store = TunnelStore(directory: directory)
            let log = RunnerLog()
            self.directory = directory
            self.store = store
            self.log = log
            manager = TunnelManager(store: store, makeRunner: { profile in
                let runner = FakeTunnelRunner(profile: profile)
                log.record(runner)
                return runner
            })
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }

        func runner(_ profile: TunnelProfile) throws -> FakeTunnelRunner {
            try #require(log.runners[profile.id], "the manager built no runner for \(profile.name)")
        }
    }

    private static func profile(
        session: UUID, name: String, port: Int = 8080,
        autoStart: TunnelProfile.AutoStart = .off
    ) -> TunnelProfile {
        TunnelProfile(
            sessionID: session, name: name,
            kind: .local(bind: "127.0.0.1", localPort: port, host: "internal", remotePort: 80),
            autoStart: autoStart)
    }

    /// A decider that would accept — what a window hands in. Never reaches a
    /// real host here: the fake runner asks it and keeps the answer.
    private static let accepting = HostKeyDecider.asking { _ in true }

    // MARK: - Start and stop, one profile

    @Test func startingAProfileStartsItsRunnerAndPublishesItsState() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let profile = Self.profile(session: sessionID, name: "web")
        try rig.store.upsert(profile)
        rig.manager.reload()

        await rig.manager.start(profile, decider: Self.accepting)

        #expect(try rig.runner(profile).startCount == 1)
        try await pollUntil("the manager mirrors the runner's state") {
            rig.manager.state(of: profile.id) == .active(connections: 0)
        }
    }

    @Test func stoppingAProfileStopsItsRunner() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let profile = Self.profile(session: UUID(), name: "web")
        try rig.store.upsert(profile)
        rig.manager.reload()

        await rig.manager.start(profile, decider: Self.accepting)
        await rig.manager.stop(profile)

        #expect(try rig.runner(profile).stopCount == 1)
        try await pollUntil("the manager mirrors the stop") {
            rig.manager.state(of: profile.id) == .stopped
        }
    }

    /// A profile nobody started has no runner at all, and stopping it is a
    /// no-op rather than a dial.
    @Test func stoppingAProfileThatNeverRanBuildsNoRunner() async {
        let rig = Rig()
        defer { rig.tearDown() }
        let profile = Self.profile(session: UUID(), name: "web")

        await rig.manager.stop(profile)

        #expect(rig.log.runners.isEmpty)
        #expect(rig.manager.state(of: profile.id) == .stopped)
    }

    // MARK: - Start and stop, per session

    @Test func startAllStartsEveryProfileOfThatSessionAndNoOther() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let mine = UUID()
        let other = UUID()
        let first = Self.profile(session: mine, name: "web")
        let second = Self.profile(session: mine, name: "db", port: 5432)
        let foreign = Self.profile(session: other, name: "elsewhere", port: 9000)
        for profile in [first, second, foreign] { try rig.store.upsert(profile) }
        rig.manager.reload()

        await rig.manager.startAll(for: mine, decider: Self.accepting)

        #expect(try rig.runner(first).startCount == 1)
        #expect(try rig.runner(second).startCount == 1)
        #expect(rig.log.runners[foreign.id] == nil, "startAll reached another session's profile")
    }

    @Test func stopAllForASessionStopsOnlyThatSessionsTunnels() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let mine = UUID()
        let other = UUID()
        let first = Self.profile(session: mine, name: "web")
        let foreign = Self.profile(session: other, name: "elsewhere", port: 9000)
        for profile in [first, foreign] { try rig.store.upsert(profile) }
        rig.manager.reload()

        await rig.manager.start(first, decider: Self.accepting)
        await rig.manager.start(foreign, decider: Self.accepting)
        await rig.manager.stopAll(for: mine)

        #expect(try rig.runner(first).stopCount == 1)
        #expect(try rig.runner(foreign).stopCount == 0)
    }

    @Test func stopAllStopsEveryRunningTunnel() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let first = Self.profile(session: UUID(), name: "web")
        let second = Self.profile(session: UUID(), name: "db", port: 5432)
        for profile in [first, second] { try rig.store.upsert(profile) }
        rig.manager.reload()

        await rig.manager.start(first, decider: Self.accepting)
        await rig.manager.start(second, decider: Self.accepting)
        await rig.manager.stopAll()

        #expect(try rig.runner(first).stopCount == 1)
        #expect(try rig.runner(second).stopCount == 1)
        // The count is read off the MIRROR, which is a task of its own: a
        // stop that has returned has ended the tunnel, and the state the
        // views read catches up one hop later. Polled rather than asserted
        // on the spot for exactly that reason — and with no deadline of its
        // own, so a slow machine cannot turn it red (CLAUDE.md, "A
        // wall-clock ceiling in a test measures the runner").
        try await pollUntil("every tunnel's stop reached the manager's states") {
            rig.manager.runningCount == 0
        }
    }

    // MARK: - Autostart

    /// `.appStart` starts the `.appStart` profiles and nothing else — and it
    /// hands in a decider that answers no without asking anyone, which is
    /// the design's stated limit: autostart never prompts.
    @Test func autoStartStartsOnlyTheProfilesForThatMomentAndNeverPrompts() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let atLaunch = Self.profile(session: sessionID, name: "web", autoStart: .appStart)
        let atLogin = Self.profile(session: sessionID, name: "db", port: 5432, autoStart: .login)
        let never = Self.profile(session: sessionID, name: "manual", port: 6000, autoStart: .off)
        for profile in [atLaunch, atLogin, never] { try rig.store.upsert(profile) }
        rig.manager.reload()

        await rig.manager.startAutoStart(.appStart)

        #expect(try rig.runner(atLaunch).startCount == 1)
        #expect(rig.log.runners[atLogin.id] == nil, "an .appStart run started a .login profile")
        #expect(rig.log.runners[never.id] == nil, "an .appStart run started an .off profile")
        #expect(
            try rig.runner(atLaunch).deciderAnswers == [false],
            "autostart handed in a decider that would accept an unknown host key")
    }

    // MARK: - The store behind it

    @Test func savingAProfilePersistsItAndDropsItsRunner() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        var profile = Self.profile(session: sessionID, name: "web")
        try await rig.manager.save(profile)

        await rig.manager.start(profile, decider: Self.accepting)
        profile.name = "web (renamed)"
        try await rig.manager.save(profile)

        #expect(try rig.runner(profile).stopCount == 1, "an edited profile kept its old runner")
        #expect(rig.store.profiles(for: sessionID).map(\.name) == ["web (renamed)"])
        #expect(rig.manager.profiles(for: sessionID).map(\.name) == ["web (renamed)"])
    }

    @Test func removingAProfileStopsItAndForgetsIt() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let profile = Self.profile(session: sessionID, name: "web")
        try await rig.manager.save(profile)
        await rig.manager.start(profile, decider: Self.accepting)

        try await rig.manager.remove(profile)

        #expect(try rig.runner(profile).stopCount == 1)
        #expect(rig.store.profiles(for: sessionID).isEmpty)
        #expect(rig.manager.profiles(for: sessionID).isEmpty)
        #expect(rig.manager.state(of: profile.id) == .stopped)
    }

    // MARK: - What a view reads

    /// `runningCount` counts what is HOLDING something — a failed or
    /// confirmation-blocked tunnel holds no port and no connection, so the
    /// quit decision must not defer for one.
    @Test func runningCountIgnoresWhatHoldsNothing() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let profile = Self.profile(session: UUID(), name: "web")
        try await rig.manager.save(profile)
        await rig.manager.start(profile, decider: Self.accepting)
        try await pollUntil("the tunnel is active") { rig.manager.runningCount == 1 }

        try rig.runner(profile).emit(.failed(reason: "port 8080 is already in use"))
        try await pollUntil("the failure reached the manager") {
            rig.manager.state(of: profile.id) == .failed(reason: "port 8080 is already in use")
        }
        #expect(rig.manager.runningCount == 0)
    }

    /// The aggregate Task 7's glyph and Dock badge read, as a pure function
    /// of the states — so the count and the worst state are measurable
    /// without a manager at all.
    @Test func theAggregateCountsActiveTunnelsAndKeepsTheWorstState() {
        let none = TunnelManager.Aggregate.of([])
        #expect(none.active == 0)
        #expect(none.worst == nil)

        let mixed = TunnelManager.Aggregate.of([
            .active(connections: 2), .stopped, .reconnecting(attempt: 3),
        ])
        #expect(mixed.active == 1)
        #expect(mixed.connections == 2)
        #expect(mixed.worst == .reconnecting(attempt: 3))

        let failing = TunnelManager.Aggregate.of([
            .active(connections: 1), .reconnecting(attempt: 1),
            .failed(reason: "port 8080 is already in use"),
        ])
        #expect(failing.active == 1)
        #expect(
            failing.worst == .failed(reason: "port 8080 is already in use"),
            "a failure must outrank a reconnect — the glyph's colour is the worst state")
    }

    // MARK: - A deleted session takes its tunnels with it

    /// The `SessionDeletionObserver` seam, driven directly — which is what
    /// `SessionListViewModel.delete(_:)` does with it (pinned on the Core
    /// side by `TunnelStoreTests`).
    ///
    /// Round 1 handed the STORE out as the observer, so this rewrote
    /// `tunnels.json` and left the runner running: a bound port, a forward
    /// still registered at the server, and a profile list still naming rows
    /// that no longer exist.
    @Test func deletingASessionStopsItsTunnelsAndForgetsItsProfiles() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let doomed = UUID()
        let survivor = UUID()
        let mine = Self.profile(session: doomed, name: "web")
        let foreign = Self.profile(session: survivor, name: "elsewhere", port: 9000)
        for profile in [mine, foreign] { try await rig.manager.save(profile) }
        await rig.manager.start(mine, decider: Self.accepting)
        await rig.manager.start(foreign, decider: Self.accepting)

        rig.manager.deletionObserver.sessionDeleted(id: doomed)

        // The observer is synchronous and stopping a runner is not, so the
        // cleanup lands after the call returns — see `DeletionObserver`.
        try await pollUntil("the deleted session's tunnel was stopped") {
            rig.log.runners[mine.id]?.stopCount == 1
        }
        try await pollUntil("the deleted session's profiles are gone") {
            rig.manager.profiles(for: doomed).isEmpty
        }
        #expect(rig.store.profiles(for: doomed).isEmpty, "tunnels.json still lists the profiles")
        #expect(rig.manager.state(of: mine.id) == .stopped)
        #expect(
            rig.log.runners[foreign.id]?.stopCount == 0,
            "deleting one session stopped another session's tunnel")
        #expect(rig.store.profiles(for: survivor).count == 1)
    }

    /// A menu holds the profile it was drawn with. Clicking it after the
    /// session was deleted must reach nothing — a runner built here would
    /// hold a port and a connection with no row anywhere left to stop it
    /// from.
    @Test func startingAProfileThatIsNoLongerStoredReachesNothing() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let profile = Self.profile(session: sessionID, name: "web")
        try await rig.manager.save(profile)

        rig.manager.deletionObserver.sessionDeleted(id: sessionID)
        try await pollUntil("the profile is gone") { rig.manager.profiles(for: sessionID).isEmpty }

        // The stale menu entry, clicked.
        await rig.manager.start(profile, decider: Self.accepting)

        #expect(rig.log.runners[profile.id] == nil, "a deleted profile was dialled")
        #expect(rig.manager.state(of: profile.id) == .stopped)
        #expect(rig.manager.runningCount == 0)
    }

    // MARK: - A start racing a discard

    /// A `save` discards the profile's runner and suspends inside its
    /// `stop()`; a start landing in that window builds a NEW runner. The
    /// resuming discard must leave that one alone.
    ///
    /// Round 1 cleared the mirror and wrote `.stopped` unconditionally, so
    /// the new tunnel was live with its state published as stopped and
    /// nothing watching its stream any more.
    @Test func aStartDuringADiscardKeepsItsOwnRunner() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        var profile = Self.profile(session: UUID(), name: "web")
        try await rig.manager.save(profile)
        await rig.manager.start(profile, decider: Self.accepting)

        let gate = Gate()
        let first = try rig.runner(profile)
        first.beforeStop = { await gate.wait() }

        profile.name = "web (renamed)"
        let saved = Flag()
        _ = Task { @MainActor in
            try? await rig.manager.save(profile)
            saved.set()
        }
        try await pollUntil("the discard is parked inside stop()") { gate.arrived == 1 }

        // The slot is free while the discard is parked, so this builds a
        // second runner rather than handing back the one being torn down.
        await rig.manager.start(profile, decider: Self.accepting)
        let second = try rig.runner(profile)
        #expect(second !== first, "the start reused the runner that was being discarded")
        try await pollUntil("the new runner's state reached the manager") {
            rig.manager.state(of: profile.id) == .active(connections: 0)
        }

        gate.open()
        // Polled, not `await saving.value`: a `Task`'s `value` ignores its
        // awaiter's cancellation, so a save that never finished would hang
        // this suite instead of failing it (817bbee3 removed the same shape
        // from the bridge suite; these two were missed).
        try await pollUntil("the save finished") { saved.isSet }

        #expect(
            rig.manager.state(of: profile.id) == .active(connections: 0),
            "the finishing discard published .stopped over the runner that replaced it")
        // And its mirror is still connected: a state the new runner
        // publishes now still arrives.
        second.emit(.reconnecting(attempt: 2))
        try await pollUntil("the new runner's mirror is still alive") {
            rig.manager.state(of: profile.id) == .reconnecting(attempt: 2)
        }
    }

    // MARK: - The quit's stop

    /// `stopAll()` stops the runners CONCURRENTLY. Sequentially, a runner
    /// parked in a dial holds every later one behind it for up to
    /// `connectTimeoutSeconds` each, in front of a quit whose watchdog is
    /// fifteen seconds.
    ///
    /// The measurement is the gate: all three stops must be inside it at
    /// once. A sequential `stopAll` never gets past the first, and what ends
    /// that wait is this suite's `.timeLimit` — deliberately, since a
    /// deadline of this test's own would be a wall-clock ceiling.
    @Test func stopAllStopsEveryRunnerAtOnce() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let profiles = (0..<3).map {
            Self.profile(session: UUID(), name: "tunnel \($0)", port: 8000 + $0)
        }
        for profile in profiles {
            try await rig.manager.save(profile)
            await rig.manager.start(profile, decider: Self.accepting)
        }
        let gate = Gate()
        for profile in profiles { try rig.runner(profile).beforeStop = { await gate.wait() } }

        let stopped = Flag()
        _ = Task { @MainActor in
            await rig.manager.stopAll()
            stopped.set()
        }
        try await pollUntil("all three stops are running at once") { gate.arrived == 3 }
        gate.open()
        try await pollUntil("stopAll returned") { stopped.isSet }

        for profile in profiles { #expect(try rig.runner(profile).stopCount == 1) }
    }

    @Test func theAggregateOfOneSessionReadsOnlyThatSessionsProfiles() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let mine = UUID()
        let other = UUID()
        let first = Self.profile(session: mine, name: "web")
        let foreign = Self.profile(session: other, name: "elsewhere", port: 9000)
        for profile in [first, foreign] { try await rig.manager.save(profile) }

        await rig.manager.start(foreign, decider: Self.accepting)
        try await pollUntil("the other session's tunnel is active") {
            rig.manager.aggregate(for: other).active == 1
        }
        #expect(rig.manager.aggregate(for: mine).active == 0)
    }
}
