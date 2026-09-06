import Foundation
import macSCPCore

/// One profile's runner, as the manager needs it.
///
/// A seam, and the reason is the same one `TunnelRuntimeFactory` gives one
/// layer down: `TunnelManagerTests` drives start, stop and every published
/// state without a socket, a server or a key. `TunnelRunner` is the one
/// production conformance, and it needs no adapter — `start(decider:)` and
/// `stop()` are already `async`, and `states` is already `nonisolated`.
///
/// Deliberately smaller than `TunnelRunner`: the manager reads no
/// `boundPort` and no `state` of its own. What the views read is the state
/// this manager mirrored off `states`, so there is one answer and not two
/// that could disagree.
protocol TunnelRunning: Sendable {
    /// Every state this runner has published, in order. Buffered without
    /// bound and never finished, so the manager's mirror misses nothing and
    /// survives a stop.
    nonisolated var states: AsyncStream<TunnelState> { get }

    /// Starts the tunnel. The decider answers for an UNKNOWN host key: a
    /// tunnel started from a window hands in the window's prompt, an
    /// autostart hands in `.refusing`. A key MISMATCH never reaches it.
    func start(decider: HostKeyDecider) async

    /// Stops the tunnel and returns once its connection and forward are
    /// gone.
    func stop() async
}

extension TunnelRunner: TunnelRunning {}

/// The app's port forwardings: which profiles exist, which are running, and
/// the two commands that change that (port-forwarding plan, Task 6).
///
/// **Process-wide, like `TabRegistry`, and unlike it the owner of what it
/// holds.** A tunnel belongs to no tab and to no window: it dials its own
/// SSH connection (`TunnelConnection`), it survives the tab that started it,
/// and it can be running before any window exists. `TabRegistry` holds
/// ownership and never state; this type holds the runners themselves,
/// because there is no window-scoped place a tunnel could live without
/// dying when that window closes.
///
/// **The state the views read is mirrored, never asked for.** Every runner
/// publishes to an `AsyncStream`, one mirror task per runner copies each
/// state into `states`, and `@Observable` re-renders whoever reads it. So
/// the sidebar glyph, the Dock badge and the profile sheet (Task 7 builds
/// the first two on this) all read one dictionary rather than awaiting an
/// actor per row.
///
/// **No ceiling on retries.** A profile with `reconnects` on retries
/// forever, 2 s doubling to 60 s (`BackoffPlan`), and nothing here cuts that
/// short — the plan gives no ceiling, and a manager that invented one would
/// be deciding for the user that a server which has been down for an hour is
/// not coming back. `stop()` is the only end.
@MainActor
@Observable
final class TunnelManager {
    /// Builds the runner for one profile. The seam the tests replace; see
    /// `TunnelRunning`.
    typealias RunnerFactory = @MainActor (TunnelProfile) -> any TunnelRunning

    /// The app's one manager. Its store sits beside `sessions-v2.json`, and
    /// its runners dial through `TunnelConnection` from the session each
    /// profile names.
    static let shared = TunnelManager(
        store: TunnelStore(directory: SessionStore.defaultDirectory),
        makeRunner: { profile in TunnelManager.liveRunner(for: profile) })

    @ObservationIgnored private let store: TunnelStore
    @ObservationIgnored private let makeRunner: RunnerFactory
    @ObservationIgnored private var runners: [UUID: any TunnelRunning] = [:]
    @ObservationIgnored private var mirrors: [UUID: Task<Void, Never>] = [:]

    /// Every stored profile, as the store last read them. Kept here rather
    /// than re-read per row: a context menu asks for one session's profiles
    /// on every redraw, and a JSON read per redraw is not what a menu is for.
    private(set) var allProfiles: [TunnelProfile]

    /// The live state per profile id — what every view reads. A profile with
    /// no entry has never been started, which is `.stopped`.
    private(set) var states: [UUID: TunnelState] = [:]

    init(store: TunnelStore, makeRunner: @escaping RunnerFactory) {
        self.store = store
        self.makeRunner = makeRunner
        allProfiles = store.allProfiles()
    }

    /// The store this manager owns, handed to `SessionListViewModel
    /// .addDeletionObserver(_:)` so a deleted session takes its profiles with
    /// it (`TunnelStore`'s `SessionDeletionObserver` conformance).
    var deletionObserver: any SessionDeletionObserver { store }

    // MARK: - What a view reads

    func profiles(for sessionID: UUID) -> [TunnelProfile] {
        allProfiles.filter { $0.sessionID == sessionID }
    }

    func state(of profileID: UUID) -> TunnelState {
        states[profileID] ?? .stopped
    }

    /// How many tunnels are HOLDING something — a connection, a bound port,
    /// or a retry that will take one. A `.failed`, `.needsConfirmation` or
    /// `.stopped` tunnel holds nothing, which is why the quit decision may
    /// leave without waiting for one.
    var runningCount: Int {
        states.values.count(where: Aggregate.isRunning)
    }

    /// Every session that has at least one profile — what Task 7's sidebar
    /// glyph asks before drawing anything at all.
    func hasProfiles(for sessionID: UUID) -> Bool {
        allProfiles.contains { $0.sessionID == sessionID }
    }

    func aggregate() -> Aggregate {
        Aggregate.of(allProfiles.map { state(of: $0.id) })
    }

    func aggregate(for sessionID: UUID) -> Aggregate {
        Aggregate.of(profiles(for: sessionID).map { state(of: $0.id) })
    }

    /// What a glyph, a badge or a tooltip needs about a SET of tunnels,
    /// derived from their states and nothing else.
    ///
    /// `worst` is the state a colour is picked from, in the design's own
    /// order — a failure outranks a reconnect outranks anything running —
    /// and it is `nil` when every tunnel is stopped, which is the case that
    /// draws grey (or nothing at all). Task 7 owns the drawing; this type
    /// owns the counting, so the count and the colour cannot come from two
    /// different readings of the same states.
    struct Aggregate: Equatable, Sendable {
        /// Tunnels in `.active`, whatever their connection count.
        var active: Int = 0
        /// Connections carried across every active tunnel.
        var connections: Int = 0
        /// Tunnels this aggregate was computed over.
        var total: Int = 0
        /// The worst state present, or `nil` when nothing is worse than
        /// stopped.
        var worst: TunnelState?

        static func of(_ states: [TunnelState]) -> Aggregate {
            var aggregate = Aggregate(total: states.count)
            for state in states {
                if case .active(let connections) = state {
                    aggregate.active += 1
                    aggregate.connections += connections
                }
                if let worst = aggregate.worst, rank(of: worst) >= rank(of: state) { continue }
                if rank(of: state) > 0 { aggregate.worst = state }
            }
            return aggregate
        }

        /// The design's precedence — "colour by the worst state among the
        /// session's tunnels (red > amber > green)" — as a number, so the
        /// comparison is one `>` rather than a nest of cases. `.stopped` is
        /// zero and therefore never becomes `worst`.
        private static func rank(of state: TunnelState) -> Int {
            switch state {
            case .stopped: return 0
            case .active: return 1
            case .connecting: return 2
            case .reconnecting: return 3
            case .needsConfirmation: return 4
            case .failed: return 5
            }
        }

        /// Whether a state means the tunnel is holding a connection, a port,
        /// or a retry on its way to one.
        static func isRunning(_ state: TunnelState) -> Bool {
            switch state {
            case .connecting, .active, .reconnecting: return true
            case .stopped, .failed, .needsConfirmation: return false
            }
        }
    }

    // MARK: - Start and stop

    /// Starts one profile. The decider is the caller's: a window's prompt
    /// from the context menu, `.refusing` from autostart.
    func start(_ profile: TunnelProfile, decider: HostKeyDecider) async {
        await runner(for: profile).start(decider: decider)
    }

    /// Stops one profile. A profile that was never started has no runner and
    /// this does nothing — deliberately not "build one and stop it", which
    /// would dial nothing but leave an object behind for every row a user
    /// right-clicks.
    func stop(_ profile: TunnelProfile) async {
        await runners[profile.id]?.stop()
    }

    func startAll(for sessionID: UUID, decider: HostKeyDecider) async {
        for profile in profiles(for: sessionID) {
            await start(profile, decider: decider)
        }
    }

    func stopAll(for sessionID: UUID) async {
        for profile in profiles(for: sessionID) {
            await stop(profile)
        }
    }

    /// Stops every tunnel this manager holds — the quit chain's own step,
    /// run before the windows close (`QuitStep.stopTunnels`).
    ///
    /// Sequential rather than concurrent: each `stop()` is bounded by the
    /// forward underneath it, and a quit that tears down one tunnel at a
    /// time is easier to read in the log than one that interleaves six.
    func stopAll() async {
        for runner in runners.values {
            await runner.stop()
        }
    }

    /// Starts every profile that asked to be started at this moment, with a
    /// decider that answers no without asking anyone.
    ///
    /// **Autostart never prompts** (design, "Limits, stated"): a profile
    /// whose session has an unknown host key or no stored secret comes to
    /// rest at `.needsConfirmation`, and the way out of that is connecting
    /// the session once, by hand, in a window — not a dialog that appears
    /// while nobody is looking at the app.
    ///
    /// Read from the STORE rather than from `allProfiles`, because the one
    /// caller is a launch: whatever is on disk is what was asked for.
    func startAutoStart(_ when: TunnelProfile.AutoStart) async {
        for profile in store.autoStart(when) {
            await start(profile, decider: .refusing)
        }
    }

    // MARK: - The store behind it

    func reload() {
        allProfiles = store.allProfiles()
    }

    /// Writes a profile and drops whatever runner it had.
    ///
    /// **An edited profile is stopped**, and that is a decision rather than a
    /// side effect: a runner holds the profile it was built with, so a
    /// running tunnel that kept its runner after an edit would go on
    /// forwarding the OLD ports while the sheet showed the new ones. Stopping
    /// is the honest answer, and starting again is one click in the same
    /// menu.
    func save(_ profile: TunnelProfile) async throws {
        await discardRunner(for: profile.id)
        try store.upsert(profile)
        reload()
    }

    /// Deletes a profile, stopping it first, and forgets its state — a state
    /// left behind would keep a row's colour alive for a profile that no
    /// longer exists.
    func remove(_ profile: TunnelProfile) async throws {
        await discardRunner(for: profile.id)
        try store.delete(id: profile.id)
        states[profile.id] = nil
        reload()
    }

    // MARK: - Runners

    /// This profile's runner, built and mirrored on first use.
    private func runner(for profile: TunnelProfile) -> any TunnelRunning {
        if let existing = runners[profile.id] { return existing }
        let created = makeRunner(profile)
        runners[profile.id] = created
        states[profile.id] = .stopped
        // One mirror per runner, for the runner's whole life: `states` is a
        // single-consumer stream (see `TunnelRunner.states`), and this is
        // that consumer. It ends when the runner is discarded, never when
        // the tunnel stops — a stopped tunnel can be started again, and a
        // second mirror on the same stream would split the states between
        // two readers.
        mirrors[profile.id] = Task { [weak self] in
            for await state in created.states {
                guard let self else { return }
                states[profile.id] = state
            }
        }
        return created
    }

    /// Stops a runner and forgets it, mirror included.
    private func discardRunner(for profileID: UUID) async {
        guard let runner = runners.removeValue(forKey: profileID) else { return }
        await runner.stop()
        mirrors.removeValue(forKey: profileID)?.cancel()
        states[profileID] = .stopped
    }

    // MARK: - The production runner

    /// A runner that dials for itself, from the stored session the profile
    /// names.
    ///
    /// The session is looked up at DIAL time, not here: a profile outlives
    /// any particular read of `sessions-v2.json`, and a reconnect an hour
    /// later must use the session as it stands then. A profile whose session
    /// is gone fails with a sentence rather than a case index — the same
    /// rule every other `TunnelFailure.connectFailed(reason:)` in this
    /// project follows (`DialSupport.reason(for:)` passes those payloads
    /// through because they are fixed English written here, never composed
    /// out of what a user typed).
    ///
    /// The three stores are the App's own: the sessions and known hosts in
    /// `SessionStore.defaultDirectory`, and the Keychain behind
    /// `secretSources(for:passwordCommand:)` — the same chain the session
    /// row's Connect resolves through. No secret is stored, logged or
    /// carried on the profile; it is resolved per dial and handed straight
    /// to the connect.
    static func liveRunner(
        for profile: TunnelProfile,
        sessions: SessionStore = SessionStore(directory: SessionStore.defaultDirectory),
        knownHosts: KnownHostsStore = KnownHostsStore(directory: SessionStore.defaultDirectory),
        secrets: any SecretStore = KeychainSecretStore()
    ) -> any TunnelRunning {
        let sessionID = profile.sessionID
        return TunnelRunner(profile: profile, connect: { decider in
            guard let session = (try? sessions.all())?.first(where: { $0.id == sessionID }) else {
                throw TunnelFailure.connectFailed(
                    reason: "the connection this forwarding belongs to no longer exists")
            }
            return try await TunnelConnection.connect(
                session: session,
                secrets: secretSources(
                    for: session, passwordCommand: nil, keychainStore: secrets),
                knownHosts: knownHosts,
                decider: decider)
        })
    }
}
