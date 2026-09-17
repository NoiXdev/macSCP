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

    /// The session ids the manager's reconcile is told exist. `nil` — the
    /// default — is what an unreadable session store answers, and keeps
    /// every row, so a case that is not about orphans never meets the rule.
    @MainActor
    final class KnownSessions {
        var ids: Set<UUID>?
    }

    /// One manager over a fresh store directory, plus the record of every
    /// runner it built.
    @MainActor
    final class Rig {
        let directory: URL
        let store: TunnelStore
        let manager: TunnelManager
        let log: RunnerLog
        let sessions: KnownSessions

        init() {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tunnel-manager-\(UUID().uuidString)")
            let store = TunnelStore(directory: directory)
            let log = RunnerLog()
            let sessions = KnownSessions()
            self.directory = directory
            self.store = store
            self.log = log
            self.sessions = sessions
            manager = TunnelManager(
                store: store,
                makeRunner: { profile in
                    let runner = FakeTunnelRunner(profile: profile)
                    log.record(runner)
                    return runner
                },
                sessionIDs: { sessions.ids })
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

    /// Autostart reads the disk, not a mirror that may predate it: a
    /// profile written after this manager was built still starts.
    ///
    /// It is also what keeps `startAutoStart` and `start(_:decider:)` from
    /// disagreeing — the start refuses a profile the mirror does not list,
    /// so the reload has to happen before the loop, not after it (fix round
    /// 3).
    @Test func autoStartReadsWhatIsOnDiskNow() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let profile = Self.profile(
            session: sessionID, name: "written later", autoStart: .appStart)

        // Straight into the store, with no `reload()` — the manager has
        // never seen this profile.
        try rig.store.upsert(profile)
        #expect(rig.manager.profiles(for: sessionID).isEmpty)

        await rig.manager.startAutoStart(.appStart)

        #expect(try rig.runner(profile).startCount == 1)
        #expect(rig.manager.profiles(for: sessionID).count == 1)
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

    /// A `tunnels.json` that cannot be decoded refuses the sheet's save and
    /// delete, and the manager hands the store's own error up — which is
    /// what the sheet turns into `tunnel.store.unreadable` — instead of the
    /// store starting over from empty with the one profile being saved.
    @Test func savingOrRemovingOverAnUnreadableStoreThrowsAndLeavesTheFile() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let profile = Self.profile(session: UUID(), name: "web")
        try await rig.manager.save(profile)
        let fileURL = rig.directory.appendingPathComponent("tunnels.json")
        let before = Data("kein json".utf8)
        try before.write(to: fileURL)
        let refusal = TunnelStoreError.unreadable(path: fileURL.path(percentEncoded: false))

        await #expect(throws: refusal) { try await rig.manager.save(profile) }
        await #expect(throws: refusal) { try await rig.manager.remove(profile) }

        #expect(try Data(contentsOf: fileURL) == before, "a refused write rewrote tunnels.json")
    }

    /// A save or delete the store refuses changes nothing — including the
    /// tunnel. The runner used to be discarded BEFORE the write, so a
    /// refused edit of a running forwarding stopped it although nothing on
    /// disk had changed.
    @Test func aRefusedSaveOrRemoveLeavesTheRunningTunnelRunning() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        var profile = Self.profile(session: sessionID, name: "web")
        try await rig.manager.save(profile)
        await rig.manager.start(profile, decider: Self.accepting)
        try await pollUntil("the forwarding is running") { rig.manager.runningCount == 1 }
        let runner = try rig.runner(profile)
        let fileURL = rig.directory.appendingPathComponent("tunnels.json")
        try Data("kein json".utf8).write(to: fileURL)

        profile.name = "web (renamed)"
        await #expect(throws: TunnelStoreError.self) { try await rig.manager.save(profile) }
        await #expect(throws: TunnelStoreError.self) { try await rig.manager.remove(profile) }

        #expect(runner.stopCount == 0, "a refused write stopped the running forwarding")
        #expect(try rig.runner(profile) === runner, "a refused write replaced the runner")
        #expect(rig.manager.state(of: profile.id) == .active(connections: 0))
        #expect(rig.manager.runningCount == 1)
        #expect(rig.manager.profiles(for: sessionID).map(\.name) == ["web"])

        // The control: once the file reads again, the same save does stop
        // the runner — an edited profile is not left forwarding old ports.
        try Data("{\"profiles\":[]}".utf8).write(to: fileURL)
        try await rig.manager.save(profile)
        #expect(runner.stopCount == 1, "a successful save no longer drops the runner")
    }

    /// The sheet's text for that refusal names the file, and it is not the
    /// generic "Could not save" line — that line prints the error's
    /// `localizedDescription`, which for this error is a type name and a
    /// number.
    @Test func theSheetNamesTheUnreadableFileInsteadOfTheGenericFailure() {
        let path = "/tmp/macscp-sheet/tunnels.json"
        let refusal = TunnelStoreError.unreadable(path: path)
        for action in [TunnelProfilesSheet.WriteAction.save, .delete] {
            let message = TunnelProfilesSheet.writeFailureMessage(for: refusal, during: action)
            #expect(message.contains(path), "\(action): \(message)")
            // The control: an unrelated error still gets the generic line,
            // so the check above is not satisfied by a function that always
            // answered the store sentence.
            let generic = TunnelProfilesSheet.writeFailureMessage(
                for: CocoaError(.fileWriteNoPermission), during: action)
            #expect(generic != message)
            #expect(!generic.contains(path))
        }
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

        try rig.runner(profile).emit(.failed(.portInUse(port: 8080)))
        try await pollUntil("the failure reached the manager") {
            rig.manager.state(of: profile.id) == .failed(.portInUse(port: 8080))
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
            .failed(.portInUse(port: 8080)),
        ])
        #expect(failing.active == 1)
        #expect(
            failing.worst == .failed(.portInUse(port: 8080)),
            "a failure must outrank a reconnect — the glyph's colour is the worst state")
    }

    /// Every `.active` has the same rank, so the sidebar's tooltip — which
    /// reads `worst` — showed whichever active tunnel came first. A healthy
    /// forwarding listed before a failing one hid the failures. Within
    /// `active`, one that is failing connections wins; the rank, and so the
    /// tint, is unchanged.
    @Test func anActiveTunnelFailingConnectionsIsTheOneTheAggregateKeeps() {
        let failing = TunnelState.active(
            connections: 0, failedConnections: 3, lastFailure: .channelOpenFailed)
        let healthyFirst = TunnelManager.Aggregate.of([.active(connections: 2), failing])
        #expect(healthyFirst.worst == failing)
        #expect(healthyFirst.active == 2)

        let failingFirst = TunnelManager.Aggregate.of([failing, .active(connections: 2)])
        #expect(failingFirst.worst == failing)

        let healthyOnly = TunnelManager.Aggregate.of([.active(connections: 2), .active(connections: 5)])
        #expect(healthyOnly.worst == .active(connections: 2))

        let reconnecting = TunnelManager.Aggregate.of([failing, .reconnecting(attempt: 1)])
        #expect(reconnecting.worst == .reconnecting(attempt: 1))
    }

    // MARK: - A store another process wrote

    /// What the app does when it becomes active (CLI sessions and tunnels
    /// plan, Task 5): it re-reads `tunnels.json`, because the CLI writes the
    /// same file and no IPC tells the app about it.
    ///
    /// **Two claims, and the second is the one worth a test.** A profile
    /// written from outside appears — that is the point of the reload. And a
    /// forwarding that is RUNNING and still STORED is not disturbed by it:
    /// the manager keys its runners by profile id and an edit on disk does
    /// not touch them, so the runner is the SAME OBJECT afterwards. The
    /// identity is read off the factory's log, so a reload that rebuilt its
    /// runners would be caught by the second runner the factory had to
    /// build — the design records this as the accepted limit that a profile
    /// EDITED on disk keeps running as it was until it is stopped and
    /// started. A profile DELETED on disk is the opposite case, and is the
    /// test below.
    @Test func reloadPicksUpAnOutsideWriteAndLeavesARunningRunnerAlone() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let running = Self.profile(session: sessionID, name: "web")
        try await rig.manager.save(running)
        await rig.manager.start(running, decider: Self.accepting)
        try await pollUntil("the forwarding is running") { rig.manager.runningCount == 1 }
        let runnerBeforeReload = try rig.runner(running)

        // Straight to the store, the way another process writes it — the
        // manager is told nothing.
        let fromOutside = Self.profile(session: sessionID, name: "db", port: 5432)
        try rig.store.upsert(fromOutside)
        #expect(
            rig.manager.allProfiles.contains { $0.id == fromOutside.id } == false, """
                the manager listed a profile written straight to the store before it reloaded \
                — this test would then prove nothing about the reload.
                """)

        await rig.manager.reloadReconciling()

        #expect(
            rig.manager.profiles(for: sessionID).map(\.name).sorted() == ["db", "web"],
            "the reload did not pick up the profile written outside the app")
        #expect(
            try rig.runner(running) === runnerBeforeReload, """
                the reload rebuilt the running forwarding's runner — a forwarding the user \
                started would be replaced by an activation of the app.
                """)
        #expect(runnerBeforeReload.stopCount == 0, "the reload stopped a running forwarding")
        #expect(rig.manager.runningCount == 1, "the reload lost a running forwarding")
    }

    /// The other half of the same reload, and the reason it reconciles at
    /// all (fix round 1): a profile the CLI DELETES while the app is running
    /// it must not survive as a runner nothing can reach.
    ///
    /// Without the reconciliation the row leaves `allProfiles` — so it
    /// leaves the sheet, the context menu and the Dock block, and every
    /// caller of `stop(_:)` needs a `TunnelProfile` out of `allProfiles` —
    /// while `runners[id]` and `states[id]` survive: a bound port and a live
    /// forward with no control anywhere to stop it, under a Dock header
    /// still counting it as running. A deletion on disk is a deletion.
    @Test func reloadStopsARunningForwardingWhoseProfileWasDeletedOnDisk() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let doomed = Self.profile(session: sessionID, name: "web")
        let survivor = Self.profile(session: sessionID, name: "db", port: 5432)
        try await rig.manager.save(doomed)
        try await rig.manager.save(survivor)
        await rig.manager.start(doomed, decider: Self.accepting)
        await rig.manager.start(survivor, decider: Self.accepting)
        try await pollUntil("both forwardings are running") { rig.manager.runningCount == 2 }
        let doomedRunner = try rig.runner(doomed)
        let survivorRunner = try rig.runner(survivor)

        // Straight to the store, the way `macscp tunnels rm` writes it.
        try rig.store.delete(id: doomed.id)

        await rig.manager.reloadReconciling()

        #expect(
            rig.manager.profiles(for: sessionID).map(\.name) == ["db"],
            "the reload did not pick up the deletion written outside the app")
        #expect(doomedRunner.stopCount == 1, """
            the deleted forwarding's runner was never stopped — it would hold its port and \
            its forward with no row anywhere left to stop it from.
            """)
        #expect(rig.manager.states[doomed.id] == nil, """
            the deleted forwarding kept a state entry — runningCount is counted over states, \
            so the Dock badge would go on reporting a forwarding nothing lists.
            """)
        #expect(rig.manager.runningCount == 1, "the deleted forwarding is still counted")

        // The control beside it: the profile that is still stored keeps the
        // very runner it had. Without this the assertions above would be
        // satisfied by a reload that stopped everything.
        #expect(
            try rig.runner(survivor) === survivorRunner,
            "the reload rebuilt a runner for a profile that was not deleted")
        #expect(survivorRunner.stopCount == 0, "the reload stopped a forwarding nobody deleted")
    }

    /// A file that cannot be READ is not a file that says "everything was
    /// deleted" (fix round 2).
    ///
    /// `TunnelStore.allProfiles()` answers `[]` for a present-but-undecodable
    /// `tunnels.json` — deliberately, for the glyph and autostart readers,
    /// which have nowhere to put a failure. Handed to a reconcile, that empty
    /// answer means every id disappeared, so a corrupt or version-mismatched
    /// file would have stopped every running forwarding on the next ⌘-Tab.
    /// The reconcile therefore reads through `readProfiles()` and keeps
    /// everything it has when the read fails.
    @Test func anUnreadableStoreLeavesTheMirrorAndEveryRunnerAlone() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let running = Self.profile(session: sessionID, name: "web")
        try await rig.manager.save(running)
        await rig.manager.start(running, decider: Self.accepting)
        try await pollUntil("the forwarding is running") { rig.manager.runningCount == 1 }
        let runnerBefore = try rig.runner(running)
        let statesBefore = rig.manager.states

        try Data("kein json".utf8).write(to: rig.directory.appendingPathComponent("tunnels.json"))

        await rig.manager.reloadReconciling()

        #expect(rig.manager.allProfiles == [running], """
            an unreadable tunnels.json emptied the mirror — every row would leave the sheet, \
            the context menu and the Dock block.
            """)
        #expect(try rig.runner(running) === runnerBefore, "the unreadable file rebuilt a runner")
        #expect(runnerBefore.stopCount == 0, """
            an unreadable tunnels.json stopped a running forwarding — a corrupt or \
            version-mismatched file would drop every tunnel on the next activation.
            """)
        #expect(rig.manager.states == statesBefore, "the unreadable file disturbed the states")
        #expect(rig.manager.runningCount == 1)

        // The control beside it, and the reason the assertions above are not
        // satisfied by a reconcile that does nothing at all: a file that
        // READS fine and no longer lists the profile still discards it.
        try Data("{\"profiles\":[]}".utf8)
            .write(to: rig.directory.appendingPathComponent("tunnels.json"))

        await rig.manager.reloadReconciling()

        #expect(rig.manager.allProfiles.isEmpty)
        #expect(runnerBefore.stopCount == 1, "a readable deletion no longer stops its runner")
        #expect(rig.manager.states[running.id] == nil)
        #expect(rig.manager.runningCount == 0)
    }

    /// Rows whose session no longer exists leave the mirror on the
    /// activation reconcile, and the file keeps them.
    ///
    /// They arise when a session is deleted while `tunnels.json` cannot be
    /// read: the store refuses the `deleteAll`, and once the file is repaired
    /// the deleted session's rows read back — invisible in every sheet (no
    /// session to open one from) but present in `allProfiles`. The control
    /// beside it: a session store that cannot be read (`nil`) drops nothing,
    /// so the rule is not satisfied by a reconcile that drops everything.
    @Test func theReconcileDropsRowsWhoseSessionIsGoneAndLeavesTheFile() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let kept = UUID()
        let deleted = UUID()
        let mine = Self.profile(session: kept, name: "web")
        let orphan = Self.profile(session: deleted, name: "db", port: 5432)
        for profile in [mine, orphan] { try rig.store.upsert(profile) }

        rig.sessions.ids = nil
        await rig.manager.reloadReconciling()
        #expect(Set(rig.manager.allProfiles.map(\.id)) == [mine.id, orphan.id], """
            an unreadable session store dropped rows — every forwarding would vanish \
            whenever sessions-v2.json failed to decode.
            """)
        // The orphan is RUNNING when the reconcile drops it, so the claim
        // that a dropped row is discarded "runner included" is measured
        // rather than satisfied by a row that never had a runner.
        await rig.manager.start(orphan, decider: Self.accepting)
        try await pollUntil("the orphan's forwarding is running") { rig.manager.runningCount == 1 }
        let orphanRunner = try rig.runner(orphan)

        rig.sessions.ids = [kept]
        await rig.manager.reloadReconciling()

        #expect(rig.manager.allProfiles == [mine], "a deleted session's row is still in the mirror")
        #expect(orphanRunner.stopCount == 1, "a dropped row's runner was left running")
        #expect(rig.manager.states[orphan.id] == nil, "a dropped row's state was kept")
        #expect(rig.manager.runningCount == 0)
        #expect(
            Set(rig.store.allProfiles().map(\.id)) == [mine.id, orphan.id],
            "the reconcile rewrote tunnels.json")
    }

    /// Every OTHER read of the store applies the same rule: a `save`'s
    /// `reload()` and a freshly built manager's `init` do not bring an
    /// orphan row back into the mirror.
    @Test func aSaveOrANewManagerDoesNotBringAnOrphanBack() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let kept = UUID()
        var mine = Self.profile(session: kept, name: "web")
        let orphan = Self.profile(session: UUID(), name: "db", port: 5432)
        for profile in [mine, orphan] { try rig.store.upsert(profile) }
        rig.sessions.ids = [kept]
        await rig.manager.reloadReconciling()
        #expect(rig.manager.allProfiles == [mine])

        mine.name = "web (renamed)"
        try await rig.manager.save(mine)
        #expect(rig.manager.allProfiles == [mine], "a save's reload brought the orphan back")
        rig.manager.reload()
        #expect(rig.manager.allProfiles == [mine], "reload() brought the orphan back")

        let sessions = rig.sessions
        let fresh = TunnelManager(
            store: rig.store, makeRunner: { FakeTunnelRunner(profile: $0) },
            sessionIDs: { sessions.ids })
        #expect(fresh.allProfiles == [mine], "a new manager's init listed the orphan")
        #expect(Set(rig.store.allProfiles().map(\.id)) == [mine.id, orphan.id])
    }

    /// A RUNNING orphan that a `reload()` has already taken out of the
    /// mirror is still stopped by the next reconcile. `reload()` is
    /// synchronous and stops nothing, so the reconcile cannot find what to
    /// discard only in the mirror it replaces: it also discards every
    /// runner whose profile it does not list.
    @Test func aRunningOrphanDroppedByAReloadIsStoppedByTheNextReconcile() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let kept = UUID()
        let mine = Self.profile(session: kept, name: "web")
        let orphan = Self.profile(session: UUID(), name: "db", port: 5432)
        for profile in [mine, orphan] { try rig.store.upsert(profile) }
        rig.sessions.ids = nil
        rig.manager.reload()
        await rig.manager.start(orphan, decider: Self.accepting)
        try await pollUntil("the orphan's forwarding is running") { rig.manager.runningCount == 1 }
        let orphanRunner = try rig.runner(orphan)

        rig.sessions.ids = [kept]
        try await rig.manager.save(mine)
        #expect(rig.manager.allProfiles == [mine])

        await rig.manager.reloadReconciling()

        #expect(orphanRunner.stopCount == 1, """
            an orphan's runner outlived its row — a bound port with nothing anywhere left to \
            stop it from until quit.
            """)
        #expect(rig.manager.states[orphan.id] == nil)
        #expect(rig.manager.runningCount == 0)
    }

    /// An orphan set to start on its own is not started: at launch
    /// `startAutoStart(_:)` runs before any activation reconcile, and a
    /// dial of a session that no longer exists ends in a `.failed` that
    /// stays in the Dock badge. Nor is it a row in the autostart overlay,
    /// whose Start button would do nothing for it.
    @Test func autoStartDoesNotStartAnOrphan() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let kept = UUID()
        let mine = Self.profile(session: kept, name: "web", autoStart: .appStart)
        let orphan = Self.profile(session: UUID(), name: "db", port: 5432, autoStart: .appStart)
        for profile in [mine, orphan] { try rig.store.upsert(profile) }
        rig.sessions.ids = [kept]

        await rig.manager.startAutoStart(.appStart)

        #expect(try rig.runner(mine).startCount == 1, "the control: a stored session's profile starts")
        #expect(rig.log.runners[orphan.id] == nil, "autostart dialled an orphan row")
        #expect(rig.manager.reloadAutoStartProfiles() == [mine], "the overlay lists an orphan row")
    }

    /// The production reader behind that rule: a session store that cannot
    /// be decoded answers `nil` — keep every row — while a MISSING one is a
    /// successful read of no sessions.
    @Test func theLiveSessionReaderTellsAnUnreadableStoreFromAnEmptyOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-manager-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = SessionStore(directory: directory)

        #expect(TunnelManager.liveSessionIDs(sessions: sessions) == [])

        try Data("kein json".utf8).write(to: directory.appendingPathComponent("sessions-v2.json"))
        #expect(TunnelManager.liveSessionIDs(sessions: sessions) == nil)
    }

    /// Two activations arriving close together never DISCARD at the same time
    /// (fix round 2): the second waits for the pass in flight instead of
    /// running one beside it.
    ///
    /// It waits and then runs a pass of its own, which is fix round 3's
    /// correction — see
    /// `aDeletionArrivingDuringAReconcileStillStopsItsForwardings` for why
    /// waiting alone was not enough. That second pass finds the runner
    /// already gone from the dictionary, which is why the stop is entered
    /// once here and the count below is 1.
    ///
    /// Driven by parking the fake runner's `stop()` inside the first
    /// reconcile, which is exactly where the real one suspends — a
    /// `TunnelRunner.stop()` waits for its run task, and a run task in a dial
    /// is bounded by `connectTimeoutSeconds`. Nothing here asserts how LONG
    /// anything took; what is asserted is that the second call had not
    /// returned while the first was still parked, and that the runner was
    /// stopped once rather than twice.
    @Test func aSecondActivationWaitsForTheReconcileInFlight() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let doomed = Self.profile(session: UUID(), name: "web")
        try await rig.manager.save(doomed)
        await rig.manager.start(doomed, decider: Self.accepting)
        try await pollUntil("the forwarding is running") { rig.manager.runningCount == 1 }
        let runner = try rig.runner(doomed)

        let gate = Gate()
        runner.beforeStop = { await gate.wait() }
        try rig.store.delete(id: doomed.id)

        let firstDone = Flag()
        let secondDone = Flag()
        let first = Task { @MainActor in
            await rig.manager.reloadReconciling()
            firstDone.set()
        }
        try await pollUntil("the first reconcile is parked inside the stop") { gate.arrived == 1 }
        // `secondStarted` is the synchronisation point, and it has to be:
        // an unserialised second call SUSPENDS NOWHERE (the first discard
        // already took the runner out of the dictionary, so its own discard
        // returns at the `guard`), so waiting on the gate's arrival count
        // would read the flag before that call had run at all — and pass.
        // Set inside the task, immediately before the call, so observing it
        // means the second reconcile has run to its first suspension.
        let secondStarted = Flag()
        let second = Task { @MainActor in
            secondStarted.set()
            await rig.manager.reloadReconciling()
            secondDone.set()
        }
        try await pollUntil("the second activation reached the manager") { secondStarted.isSet }

        // Read BEFORE the gate opens — after it, both calls have returned
        // and the two outcomes are indistinguishable (CLAUDE.md, "a check
        // that reads after the healing is not a check").
        #expect(secondDone.isSet == false, """
            the second activation returned while a reconcile was still parked in a stop — it \
            ran a pass of its own instead of waiting for the one in flight.
            """)
        #expect(gate.arrived == 1, """
            the runner's stop was entered \(gate.arrived) times — two reconciles were \
            discarding at once.
            """)

        gate.open()
        await first.value
        await second.value

        #expect(firstDone.isSet)
        #expect(secondDone.isSet)
        #expect(runner.stopCount == 1, "the deleted forwarding was stopped more than once")
        #expect(rig.manager.allProfiles.isEmpty)
        #expect(rig.manager.states[doomed.id] == nil)
    }

    /// Waiting for the pass in flight is not the same as being reconciled
    /// (fix round 3).
    ///
    /// A pass reads the store when it STARTS. A caller that writes the store
    /// and then coalesces onto a pass already in flight is therefore waiting
    /// for a read that happened before its own write — so
    /// `forgetEverything(for:)` could return having deleted the rows from
    /// `tunnels.json` and stopped nothing at all, with the deleted session's
    /// profiles still in `allProfiles`, its runners still forwarding and
    /// `runningCount` still counting them. That is round 1's defect back
    /// again, reached through round 2's gate; two rapid session deletions
    /// have the same shape.
    ///
    /// So a coalesced caller waits AND THEN runs a pass of its own. The cost
    /// is one extra read per coalesced caller, which is a JSON file of a
    /// handful of rows.
    @Test func aDeletionArrivingDuringAReconcileStillStopsItsForwardings() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let firstSession = UUID()
        let secondSession = UUID()
        let parked = Self.profile(session: firstSession, name: "web")
        let deletedLater = Self.profile(session: secondSession, name: "db", port: 5432)
        try await rig.manager.save(parked)
        try await rig.manager.save(deletedLater)
        await rig.manager.start(parked, decider: Self.accepting)
        await rig.manager.start(deletedLater, decider: Self.accepting)
        try await pollUntil("both forwardings are running") { rig.manager.runningCount == 2 }
        let parkedRunner = try rig.runner(parked)
        let laterRunner = try rig.runner(deletedLater)

        // Pass A: the first profile is deleted on disk and the reconcile
        // parks inside its runner's stop.
        let gate = Gate()
        parkedRunner.beforeStop = { await gate.wait() }
        try rig.store.delete(id: parked.id)
        let passA = Task { @MainActor in await rig.manager.reloadReconciling() }
        try await pollUntil("pass A is parked inside the stop") { gate.arrived == 1 }

        // The session deletion lands while pass A is parked. Its own write
        // is later than pass A's read, which is the whole point.
        let deletionStarted = Flag()
        let deletionDone = Flag()
        let deletion = Task { @MainActor in
            deletionStarted.set()
            await rig.manager.forgetEverything(for: secondSession)
            deletionDone.set()
        }
        try await pollUntil("the deletion reached the manager") { deletionStarted.isSet }
        #expect(deletionDone.isSet == false, "the deletion returned while pass A was parked")

        gate.open()
        await passA.value
        await deletion.value

        #expect(rig.manager.allProfiles.isEmpty, """
            forgetEverything returned with the deleted session's rows still in the mirror — \
            it coalesced onto a pass whose read predated its own write.
            """)
        #expect(laterRunner.stopCount == 1, """
            forgetEverything stopped nothing: the deleted session's forwarding is still \
            holding its port and its forward, with no row anywhere left to stop it from.
            """)
        #expect(rig.manager.states[deletedLater.id] == nil)
        #expect(rig.manager.runningCount == 0)

        // The control beside it: pass A did its own work too, so this is not
        // satisfied by one pass that happened to stop everything.
        #expect(parkedRunner.stopCount == 1)
        #expect(rig.manager.states[parked.id] == nil)
    }

    /// The ORDINARY-PATH POSITIVE: a reconcile that follows a completed one
    /// runs a pass of its own, which is what a single ⌘-Tab does all day.
    ///
    /// Round 3's doc said this pinned where the in-flight handle was cleared.
    /// It never did, and no test here could: that placement's failure mode
    /// was a livelock — no verdict at all rather than a red — which is why
    /// it was measured by a plant and written into a comment instead. Round
    /// 4 removed the handle's clear along with the loop it was coupled to,
    /// so what remains is this: the manager's stored handle goes on naming
    /// the previous, FINISHED task, and awaiting it must not stand in for
    /// this caller's own read of the store.
    @Test func aReconcileFollowingACompletedOneRunsItsOwnPass() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let doomed = Self.profile(session: UUID(), name: "web")
        try await rig.manager.save(doomed)
        await rig.manager.start(doomed, decider: Self.accepting)
        try await pollUntil("the forwarding is running") { rig.manager.runningCount == 1 }
        let runner = try rig.runner(doomed)

        // One pass that changes nothing, so the next call is the first one
        // with anything to do.
        await rig.manager.reloadReconciling()
        #expect(runner.stopCount == 0)
        #expect(rig.manager.allProfiles == [doomed])

        try rig.store.delete(id: doomed.id)
        await rig.manager.reloadReconciling()

        #expect(rig.manager.allProfiles.isEmpty, """
            the second reconcile read nothing — it awaited the first pass's finished task \
            instead of running one of its own.
            """)
        #expect(runner.stopCount == 1)
        #expect(rig.manager.states[doomed.id] == nil)
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

    /// A session deleted while `tunnels.json` cannot be decoded still takes
    /// its RUNNING forwardings with it.
    ///
    /// The store refuses the `deleteAll` now, and the reconcile that would
    /// normally stop the deleted rows keeps everything when the read fails —
    /// so without a path of its own this left a deleted session's tunnel
    /// holding its port. The file itself is left exactly as it was: the rows
    /// stay in it until someone repairs it, which is the store's promise.
    @Test func deletingASessionOverAnUnreadableStoreStillStopsItsTunnels() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let doomed = UUID()
        let survivor = UUID()
        let mine = Self.profile(session: doomed, name: "web")
        let foreign = Self.profile(session: survivor, name: "elsewhere", port: 9000)
        for profile in [mine, foreign] { try await rig.manager.save(profile) }
        await rig.manager.start(mine, decider: Self.accepting)
        await rig.manager.start(foreign, decider: Self.accepting)
        try await pollUntil("both forwardings are running") { rig.manager.runningCount == 2 }
        let fileURL = rig.directory.appendingPathComponent("tunnels.json")
        let before = Data("kein json".utf8)
        try before.write(to: fileURL)

        await rig.manager.forgetEverything(for: doomed)

        #expect(try rig.runner(mine).stopCount == 1, """
            the deleted session's forwarding is still running — an unreadable store \
            left a tunnel holding its port with no row anywhere left to stop it from.
            """)
        #expect(rig.manager.profiles(for: doomed).isEmpty, "the mirror still lists the rows")
        #expect(rig.manager.states[mine.id] == nil)
        #expect(try rig.runner(foreign).stopCount == 0, "another session's tunnel was stopped")
        #expect(rig.manager.profiles(for: survivor) == [foreign])
        #expect(rig.manager.runningCount == 1)
        #expect(try Data(contentsOf: fileURL) == before, "the deletion rewrote tunnels.json")
    }

    /// On a refused `deleteAll`, the deleted session's rows leave the mirror
    /// BEFORE the first runner is stopped — which is what makes
    /// `start(_:decider:)`'s guard refuse them while the stops are parked.
    ///
    /// The case above reads its results after `forgetEverything(for:)` has
    /// returned, by which point a removal placed after the `await` would
    /// have caught up. Here the first stop is held open on a gate and the
    /// mirror and a racing start are read INSIDE it, before the gate opens.
    @Test func aRefusedDeletionDropsTheRowsBeforeItStopsAnything() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let doomed = UUID()
        let first = Self.profile(session: doomed, name: "web")
        let second = Self.profile(session: doomed, name: "db", port: 9000)
        for profile in [first, second] {
            try await rig.manager.save(profile)
            await rig.manager.start(profile, decider: Self.accepting)
        }
        let gate = Gate()
        let started = try [rig.runner(first), rig.runner(second)]
        for runner in started { runner.beforeStop = { await gate.wait() } }
        try Data("kein json".utf8).write(to: rig.directory.appendingPathComponent("tunnels.json"))

        let finished = Flag()
        _ = Task { @MainActor in
            await rig.manager.forgetEverything(for: doomed)
            finished.set()
        }
        try await pollUntil("a stop is parked inside the deletion") { gate.arrived == 1 }

        // Read while parked, before anything heals.
        let listedWhileParked = rig.manager.profiles(for: doomed)
        await rig.manager.start(first, decider: Self.accepting)
        await rig.manager.start(second, decider: Self.accepting)
        let rebuiltWhileParked = [first, second].filter { profile in
            rig.log.runners[profile.id] !== started.first { $0.profile.id == profile.id }
        }
        let restartsWhileParked = started.map(\.startCount)

        gate.open()
        try await pollUntil("the deletion finished") { finished.isSet }

        #expect(listedWhileParked.isEmpty, """
            the deleted session's rows were still in the mirror while its runners were being \
            stopped — a menu click there passes start()'s guard.
            """)
        #expect(rebuiltWhileParked.isEmpty, "a start during the deletion built a new runner")
        #expect(restartsWhileParked == [1, 1], "a start during the deletion restarted a runner")
        #expect(started.allSatisfy { $0.stopCount == 1 })
        #expect(rig.manager.runningCount == 0)
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

    /// The same refusal, during the deletion rather than after it.
    ///
    /// Stopping a runner takes as long as the dial it is inside — up to the
    /// connect timeout — and the deletion awaits every one of them. While it
    /// does, the profiles must already be gone from the store and from
    /// `allProfiles`, because `start(_:decider:)` decides on `allProfiles`:
    /// a Dock-menu click inside that window would otherwise build a runner
    /// the resuming deletion no longer knows about, holding a port and a
    /// connection with no row anywhere left to stop it from.
    ///
    /// The deletion snapshots the ids it is about to stop, so deleting
    /// first costs it nothing.
    @Test func aStartDuringADeletionReachesNothing() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let sessionID = UUID()
        let first = Self.profile(session: sessionID, name: "web")
        let second = Self.profile(session: sessionID, name: "db", port: 9000)
        for profile in [first, second] {
            try await rig.manager.save(profile)
            await rig.manager.start(profile, decider: Self.accepting)
        }
        let gate = Gate()
        let started = try [rig.runner(first), rig.runner(second)]
        for runner in started { runner.beforeStop = { await gate.wait() } }

        rig.manager.deletionObserver.sessionDeleted(id: sessionID)
        try await pollUntil("a stop is parked inside the deletion") { gate.arrived == 1 }

        // The window this test exists for: a menu drawn before the deletion,
        // clicked while it runs.
        #expect(
            rig.manager.profiles(for: sessionID).isEmpty,
            "the profiles are still listed while their runners are being stopped")
        await rig.manager.start(first, decider: Self.accepting)
        #expect(
            rig.log.runners[first.id] === started[0],
            "the start built a second runner for a profile being deleted")
        #expect(started[0].startCount == 1, "the deleted profile was started again")

        gate.open()
        try await pollUntil("both runners were stopped") {
            started.allSatisfy { $0.stopCount == 1 }
        }
        try await pollUntil("the deletion finished") { rig.manager.runningCount == 0 }
        #expect(rig.manager.allProfiles.isEmpty)
        #expect(rig.store.profiles(for: sessionID).isEmpty)
        #expect(rig.manager.state(of: first.id) == .stopped)
        #expect(rig.manager.state(of: second.id) == .stopped)
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

    /// The states a session's row aggregates are that session's and no
    /// other's — the property `SessionSidebar` depends on when it colours the
    /// forwarding glyph.
    ///
    /// Built here from `profiles(for:)` and `state(of:)`, the way the sidebar
    /// builds it (`Aggregate.of(tunnelStates)`). A `manager.aggregate(for:)`
    /// used to do it in one call, but this suite held its only two callers —
    /// test-only production API, deleted in the final review's fix round
    /// (2026-09-06).
    @Test func theStatesOfOneSessionAreThatSessionsOnly() async throws {
        let rig = Rig()
        defer { rig.tearDown() }
        let mine = UUID()
        let other = UUID()
        let first = Self.profile(session: mine, name: "web")
        let foreign = Self.profile(session: other, name: "elsewhere", port: 9000)
        for profile in [first, foreign] { try await rig.manager.save(profile) }

        await rig.manager.start(foreign, decider: Self.accepting)
        try await pollUntil("the other session's tunnel is active") {
            aggregate(rig, of: other).active == 1
        }
        #expect(aggregate(rig, of: mine).active == 0)
    }

    /// One session's states, aggregated — the sidebar's own two steps.
    private func aggregate(_ rig: Rig, of sessionID: UUID) -> TunnelManager.Aggregate {
        TunnelManager.Aggregate.of(
            rig.manager.profiles(for: sessionID).map { rig.manager.state(of: $0.id) })
    }
}
