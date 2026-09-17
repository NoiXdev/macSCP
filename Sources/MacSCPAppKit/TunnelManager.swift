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

    /// The ids of every stored session, or `nil` when the session store
    /// cannot be read. What the activation reconcile drops orphan rows by —
    /// see `performReconcilingReload()`.
    typealias SessionIDReader = @MainActor () -> Set<UUID>?

    /// The app's one manager. Its store sits beside `sessions-v2.json`, and
    /// its runners dial through `TunnelConnection` from the session each
    /// profile names.
    static let shared = TunnelManager(
        store: TunnelStore(directory: SessionStore.defaultDirectory),
        makeRunner: { profile in TunnelManager.liveRunner(for: profile) },
        sessionIDs: { TunnelManager.liveSessionIDs() })

    @ObservationIgnored private let store: TunnelStore
    @ObservationIgnored private let makeRunner: RunnerFactory
    @ObservationIgnored private let sessionIDs: SessionIDReader
    @ObservationIgnored private var runners: [UUID: any TunnelRunning] = [:]
    /// One mirror task per RUNNER, keyed by that runner's generation — not
    /// by the profile, which is what round 1 keyed it by. Two runners for
    /// one profile can be alive at once (a start landing inside a discard's
    /// `stop()`), and both write the same `states` entry; keying by profile
    /// meant the second overwrote the first's task in the dictionary and the
    /// first's writes went on landing unnoticed. See `runner(for:)`.
    @ObservationIgnored private var mirrors: [Int: Task<Void, Never>] = [:]
    /// Which generation of runner each profile's slot currently holds, and
    /// the counter that hands them out.
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    @ObservationIgnored private var generation = 0
    /// The LAST reconcile installed — the tail of the chain
    /// `reloadReconciling()` links each new pass onto. It is not cleared
    /// when its pass finishes: the handle goes on naming that completed task
    /// until the next call replaces it, which is what lets a caller arriving
    /// after a quiet period link onto a task that returns at once. A `Task`
    /// handle rather than a `Bool` because a caller has to be able to WAIT
    /// for what is ahead of it, not merely notice it.
    @ObservationIgnored private var reconcileInFlight: Task<Void, Never>?

    /// Every stored profile, as the store last read them. Kept here rather
    /// than re-read per row: a context menu asks for one session's profiles
    /// on every redraw, and a JSON read per redraw is not what a menu is for.
    private(set) var allProfiles: [TunnelProfile]

    /// The live state per profile id — what every view reads. A profile with
    /// no entry has never been started, which is `.stopped`.
    private(set) var states: [UUID: TunnelState] = [:]

    init(
        store: TunnelStore, makeRunner: @escaping RunnerFactory,
        sessionIDs: @escaping SessionIDReader
    ) {
        self.store = store
        self.makeRunner = makeRunner
        self.sessionIDs = sessionIDs
        allProfiles = Self.listed(store.allProfiles(), known: sessionIDs())
    }

    /// Handed to `SessionListViewModel.addDeletionObserver(_:)` so a deleted
    /// session takes its forwardings with it.
    ///
    /// **The adapter, not the store.** Round 1 handed out `TunnelStore`
    /// itself, whose `sessionDeleted(id:)` rewrote `tunnels.json` and
    /// nothing else — so deleting a connected session left its RUNNERS
    /// running: a bound local port, a forward still registered at the
    /// server, an SSH connection open, `allProfiles` still listing the
    /// deleted rows and `runningCount` still counting them, with no menu
    /// anywhere left to stop them from. The manager owns the runners, so the
    /// manager has to be the one told. The store's conformance is gone
    /// altogether since the final review's fix round (2026-09-06): a seam
    /// nothing registers is not a seam, and the one test that did register
    /// it now hands `SessionListViewModel` an observer of its own.
    var deletionObserver: any SessionDeletionObserver {
        DeletionObserver(manager: self)
    }

    /// `SessionDeletionObserver.sessionDeleted(id:)` is synchronous and
    /// `Sendable`; stopping a runner is neither. So the adapter hops onto
    /// the main actor and the cleanup finishes AFTER the deletion returns —
    /// stated rather than hidden, because it is what a test has to wait for
    /// (`pollUntil`) and what a reader of `delete(_:)` should expect. The
    /// deletion itself is unaffected either way: `SessionListViewModel
    /// .delete(_:)` has already written the session store by the time
    /// observers are told.
    private struct DeletionObserver: SessionDeletionObserver {
        let manager: TunnelManager

        func sessionDeleted(id: UUID) {
            Task { @MainActor in await manager.forgetEverything(for: id) }
        }
    }

    /// Deletes `sessionID`'s profiles, then stops every runner they had and
    /// forgets their states — the whole of what a deleted session leaves
    /// behind.
    ///
    /// **The store goes first, and the order is the point** (final review,
    /// 2026-09-06). Stopping a runner takes as long as the dial it is inside
    /// — `connectTimeoutSeconds`, 10 s by default and up to 120 s — and this
    /// awaits every one of them. Stopping BEFORE the delete left the rows in
    /// `tunnels.json` and in `allProfiles` for that whole window, and
    /// `start(_:decider:)` decides on `allProfiles`: a Dock-menu or
    /// context-menu click landing there passed the guard, built a runner for
    /// a profile about to be deleted, and the resuming loop — iterating the
    /// snapshot it took at entry — never stopped it. A tunnel holding a port
    /// and a connection, with no row anywhere left to stop it from, which is
    /// the exact outcome that guard exists to prevent. Deleting first loses
    /// nothing, and the paragraph on `reloadReconciling()` below says why:
    /// the ids it discards are read off the MIRROR, which this call has not
    /// touched.
    ///
    /// Throw-free, like every other cleanup on the deletion path
    /// (`SessionListViewModel.delete(_:)`'s audit-log and stray-secret
    /// steps): an unwritable `tunnels.json` is a residual, never a reason to
    /// leave a tunnel running. The session itself is already gone from its
    /// store when this runs, so there is nothing a failure here could still
    /// stop, and no window to show one in.
    ///
    /// **The stop-and-forget loop is `reloadReconciling()`'s** (fix round
    /// 1). This used to snapshot the doomed ids itself and run its own copy
    /// of that loop; the activation re-read needs exactly the same one, for
    /// exactly the same reason, so there is one of them
    /// (`discardAndForget(_:)`) and a successful delete goes through the
    /// reconcile to reach it. Deleting first still loses nothing — but NOT
    /// because "the mirror has not been re-read yet", which the chain makes
    /// false as soon as another pass is in flight and reads after the
    /// `deleteAll` above.
    /// What holds either way is that some pass sees the TRANSITION. Every
    /// read older than the delete left a mirror still listing these rows, so
    /// whichever chained pass performs the first read AFTER it snapshots
    /// them off that mirror and finds them gone from the file — and discards
    /// them there. That pass is this call's own when no other is in flight,
    /// and one ahead of it in the chain otherwise; either way it is ordered
    /// before this call returns.
    ///
    /// **And it is reconciled by a pass of its OWN** (fix round 3). A pass
    /// already in flight read the store before the `deleteAll` above, so
    /// waiting for one would have returned with this session's rows still
    /// in the mirror and its runners still forwarding. `reloadReconciling()`
    /// waits and then runs its own pass, which is what makes this function
    /// correct while another one is parked in a `stop()`.
    ///
    /// **A refused or failed `deleteAll` takes a path of its own**
    /// (technical backlog of 2026-09-16, Task 2). The reconcile discards
    /// only what a SUCCESSFUL read no longer lists, and after a failed
    /// delete no read can say that: an undecodable file fails the read, and
    /// a file that decoded but could not be written still lists the rows.
    /// This paragraph used to call the first case almost unreachable,
    /// because `deleteAll(for:)` read an undecodable file as empty and wrote
    /// a valid one — which was the defect, since every OTHER session's
    /// profiles went with it. The store now refuses that write
    /// (`TunnelStoreError.unreadable`) and leaves the file alone. So on any
    /// failure the deleted session's rows leave the MIRROR here — first,
    /// before any `await`, so `start(_:decider:)`'s guard already refuses
    /// them — and their runners are stopped from it. The rows stay in the
    /// file, and the line written says so.
    ///
    /// Reported in the diagnostic log only, not to the user: the session
    /// deletion has already happened and there is no sheet open for this
    /// call to put a sentence in. A later save in the sheet meets the same
    /// file and shows `tunnel.store.unreadable` there.
    func forgetEverything(for sessionID: UUID) async {
        do {
            try store.deleteAll(for: sessionID)
        } catch {
            DiagnosticLog.shared.log(
                .error, "app",
                "tunnels.json not updated, stopping a deleted session's forwardings without removing them from it",
                reason: error)
            let doomed = allProfiles.filter { $0.sessionID == sessionID }.map(\.id)
            allProfiles.removeAll { $0.sessionID == sessionID }
            await discardAndForget(doomed)
            return
        }
        await reloadReconciling()
    }

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

    /// `hasProfiles(for:)` and `aggregate()` used to sit here, and both were
    /// deleted in fix round 1 (review finding I-1) because nothing read
    /// either. `hasProfiles(for:)`'s own doc comment claimed the sidebar glyph
    /// asked it before drawing anything — it never did: the row hands
    /// `TunnelGlyphPlan.glyph(states:)` this session's states and the plan
    /// answers `nil` for an empty array, so "no profile, no glyph" is decided
    /// there and in one place. A comment describing a caller that does not
    /// exist is the exact failure mode CLAUDE.md's "Comments that describe
    /// other code" is about, so the honest fix was to remove the code rather
    /// than to correct the sentence about it. `aggregate()` — the whole app's
    /// aggregate — had no caller and no claim; the Dock badge reads
    /// `DockBadgePlan.label(states:)` instead.
    ///
    /// `aggregate(for:)` — the per-session one — followed them in the final
    /// review's fix round (2026-09-06), for the same reason and one round
    /// later: its only two callers were in `TunnelManagerTests`, so it was
    /// test-only production API. Every surface that wants a session's
    /// aggregate builds it from the two things a view reads anyway,
    /// `profiles(for:)` and `state(of:)` — `SessionSidebar` does exactly that
    /// (`Aggregate.of(tunnelStates)`), and so does the test that used to call
    /// this.

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
                if case .active(let connections, _, _) = state {
                    aggregate.active += 1
                    aggregate.connections += connections
                }
                if let worst = aggregate.worst {
                    let kept = rank(of: worst)
                    let seen = rank(of: state)
                    if kept > seen { continue }
                    // Equal ranks keep the first — except that an `active`
                    // failing connections replaces a healthy `active`, or a
                    // healthy forwarding listed first would hide the
                    // failures from the sidebar's tooltip. Same rank, so the
                    // tint does not change.
                    if kept == seen, !(isFailingConnections(state) && !isFailingConnections(worst)) {
                        continue
                    }
                }
                if rank(of: state) > 0 { aggregate.worst = state }
            }
            return aggregate
        }

        private static func isFailingConnections(_ state: TunnelState) -> Bool {
            guard case .active(_, let failed, _) = state else { return false }
            return failed > 0
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
    ///
    /// **A profile that is no longer stored is not started** (fix round 2).
    /// A menu holds the profile it was drawn with, and `forgetEverything(for:)`
    /// takes its own snapshot, so a click landing after a session was
    /// deleted — or on a stale menu — would otherwise build a runner and a
    /// `states` entry for a profile nothing lists any more: a tunnel with no
    /// row anywhere to stop it from. Silent, because there is nothing to
    /// report: the thing the user asked for is gone, and the row they asked
    /// from is gone with it.
    func start(_ profile: TunnelProfile, decider: HostKeyDecider) async {
        guard allProfiles.contains(where: { $0.id == profile.id }) else { return }
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
    /// **Concurrent, and that is a quit-time decision** (fix round 1). A
    /// `stop()` waits for its run task, and a run task parked in a DIAL is
    /// bounded by `connectTimeoutSeconds` — 10 s by default and settable to
    /// 120 s. Sequentially that is n × the timeout in front of a quit whose
    /// own watchdog is 15 s; concurrently it is one timeout however many
    /// forwardings are up. The per-session `stopAll(for:)` above stays
    /// sequential on purpose: it is a menu action on a handful of profiles,
    /// and one tunnel at a time reads better in the log.
    ///
    /// The bound itself is NOT here — the quit owns its own clock. See
    /// `AppDelegate.runBoundedTunnelStop()`, which races this against
    /// `QuitWatchdog.bound`.
    func stopAll() async {
        let running = Array(runners.values)
        await withTaskGroup(of: Void.self) { group in
            for runner in running {
                group.addTask { await runner.stop() }
            }
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
    /// **Reloads first, then reads the mirror**, and the order is the point.
    /// The one caller is a launch, so what is on disk is what was asked for
    /// — but `start(_:decider:)` refuses a profile the mirror does not list
    /// (see its own doc comment), so handing it rows straight out of the
    /// store would mean starting them past a guard that had never seen them.
    /// One read, one list, and the guard cannot disagree with the loop.
    ///
    /// `TunnelStore.autoStart(_:)` is therefore not called from here. It is
    /// Core's own filter, and the one place it IS called from is
    /// `reloadAutoStartProfiles()` below — the autostart overlay's list,
    /// which spans every session and needs no per-profile guard because it
    /// starts nothing itself.
    func startAutoStart(_ when: TunnelProfile.AutoStart) async {
        reload()
        for profile in allProfiles where profile.autoStart == when {
            await start(profile, decider: .refusing)
        }
    }

    // MARK: - The store behind it

    /// Every profile that starts on its own, across every session — the
    /// autostart overlay's rows (Task 7).
    ///
    /// **It reloads first, and that is not a convenience.**
    /// `start(_:decider:)` refuses a profile the mirror does not list, so a
    /// list read past the mirror would be a table of rows whose Start button
    /// silently did nothing. One read, one list, the same rule
    /// `startAutoStart(_:)` above states for itself.
    ///
    /// The filter is Core's (`TunnelStore.autoStart(_:)`) rather than a
    /// second `allProfiles.filter` here: what "starts on its own" means is
    /// one decision, and it belongs beside the model that spells
    /// `AutoStart`. `.off` is excluded by asking for every OTHER case, so a
    /// fourth moment added to `AutoStart` appears here without an edit.
    ///
    /// The store's rows are kept only where the mirror lists them, so a
    /// row whose session is gone (`listed(_:known:)`) is not offered here
    /// either — its Start button would be refused by the same guard.
    func reloadAutoStartProfiles() -> [TunnelProfile] {
        reload()
        let mirrored = Set(allProfiles.map(\.id))
        return TunnelProfile.AutoStart.allCases
            .filter { $0 != .off }
            .flatMap { store.autoStart($0) }
            .filter { mirrored.contains($0.id) }
    }

    /// Re-reads the store into the mirror, through the same session filter
    /// as `init` and the activation reconcile (`listed(_:known:)`).
    func reload() {
        allProfiles = Self.listed(store.allProfiles(), known: sessionIDs())
    }

    /// The rows the mirror lists out of what the store read: every row whose
    /// session the session store lists, or every row when the session store
    /// could not be read (`known == nil`). The one spelling of that rule;
    /// its three callers, counted 2026-09-17, are `init`, `reload()` and
    /// `performReconcilingReload()`. `reload()`'s own four callers in this
    /// file, counted the same day, are `save(_:)`, `remove(_:)`,
    /// `startAutoStart(_:)` and `reloadAutoStartProfiles()`, so none of them
    /// brings an orphan row back — at launch
    /// `startAutoStart(_:)` runs before any activation reconcile, and an
    /// orphan with autostart set would otherwise be dialled into a
    /// `sessionMissing` failure.
    private static func listed(_ profiles: [TunnelProfile], known: Set<UUID>?) -> [TunnelProfile] {
        guard let known else { return profiles }
        return profiles.filter { known.contains($0.sessionID) }
    }

    /// The re-read the app performs when it becomes active (CLI sessions and
    /// tunnels plan, Task 5, fix rounds 1 and 2): the store is read, the
    /// mirror is replaced, and the runners belonging to profiles that are no
    /// longer stored are stopped and forgotten.
    ///
    /// **A deletion on disk is a deletion.** `reload()` alone assigns
    /// `allProfiles` and nothing else, so a profile the CLI removed while
    /// the app was RUNNING it left the sheet, the context menu and the Dock
    /// block — every caller of `stop(_:)` needs a `TunnelProfile` out of
    /// `allProfiles` — while `runners[id]` and `states[id]` survived: a
    /// bound port and a live forward with nothing anywhere left to stop it
    /// from until ⌘Q, under a Dock header still counting it. That is the
    /// same outcome `start(_:decider:)`'s own guard and
    /// `forgetEverything(for:)` exist to prevent, arriving by a third door.
    ///
    /// **Edited is not deleted.** Only ids that DISAPPEARED are discarded; a
    /// profile whose ports or name changed on disk keeps the runner it has,
    /// which is the design's stated limit (and what the profiles sheet's
    /// `tunnel.help.externalEdits` tells the user).
    ///
    /// **Unreadable is not deleted either** (fix round 2). The read goes
    /// through `TunnelStore.readProfiles()`, which reports a failure instead
    /// of flattening it: `allProfiles()` answers `[]` for a present-but-
    /// undecodable file, and handing that to this loop would have read a
    /// corrupt or version-mismatched `tunnels.json` as "every profile was
    /// deleted" and dropped every running forwarding on the next ⌘-Tab. A
    /// failed read changes nothing at all and writes one line.
    ///
    /// **A MISSING file is a successful read of an empty store**, not a
    /// failure — a fresh install has none, and emptying the store leaves a
    /// present file holding `"profiles": []` rather than no file (measured
    /// on the store side; see `TunnelStore.decode()`). So the reconcile does
    /// not need to tell the two empty states apart.
    ///
    /// **A row without a session is not listed** (next build of
    /// 2026-09-17, Task 2). A session deleted while `tunnels.json` could not
    /// be read leaves its rows in the file — the store refuses the
    /// `deleteAll`, and `forgetEverything(for:)` removes them from the
    /// mirror only — so once the file is repaired they read back: in
    /// `allProfiles`, in no sheet (there is no session to open one from),
    /// and unable to dial (`TunnelRefusal.sessionMissing`). The pass drops
    /// every row whose `sessionID` the session store does not list, from
    /// the mirror and not from the file: this is a reader, and the rows are
    /// the user's to inspect in a file the earlier refusal named. A session
    /// store that cannot be read drops nothing. A row dropped here is
    /// discarded like a deleted one, runner included — and so is a runner
    /// whose row `reload()` dropped earlier by the same rule, since
    /// `reload()` is synchronous and stops nothing: the ids discarded are
    /// the mirror's AND the runners', minus what this pass lists
    /// (`aRunningOrphanDroppedByAReloadIsStoppedByTheNextReconcile`).
    ///
    /// The ids are snapshotted BEFORE the mirror is replaced, because after
    /// it the deleted ones are exactly what is no longer there to name.
    /// `discardAndForget(_:)` is the loop, and `forgetEverything(for:)`
    /// reaches it too: through this function after a successful delete,
    /// directly after a failed one — so there is one such loop rather than
    /// two.
    ///
    /// **The passes are CHAINED** (fix round 4): every call links a pass of
    /// its own behind whatever was installed last, and awaits it. Passes
    /// never overlap, every caller gets a read that follows its own entry,
    /// and they run in the order they arrived.
    func reloadReconciling() async {
        // Two properties are wanted here, and the chain below is both of
        // them at once.
        //
        // **One pass at a time** (round 2): two activations arriving close
        // together — ⌘-Tab away and back — must not discard runners beside
        // each other, and a pass suspends for as long as a discarded
        // runner's `stop()` takes, which for a runner parked in a dial is
        // `connectTimeoutSeconds`.
        //
        // **Waiting is not the same as being reconciled** (round 3): a pass
        // reads the store when it STARTS, so a caller that WROTE the store
        // and then coalesced onto a pass already in flight was waiting for a
        // read older than its own write. `forgetEverything(for:)` could
        // return having deleted the rows and stopped nothing — round 1's
        // defect, reached through round 2's gate. The price of a pass per
        // caller is one extra read of a small JSON file.
        //
        // Rounds 2 and 3 spelled those as a GATE: a `while` loop over the
        // handle, and a clear written as the task's last statement. That
        // code was correct, and its two halves were coupled by a liveness
        // invariant nothing enforced — with the clear moved to the caller's
        // side there is a turn in which a waiter re-checks, on an actor it
        // never yields, a handle only that caller can clear. Planting
        // exactly that move on 2026-09-06 produced NO VERDICT in 100 s
        // rather than a red. That is history: the loop and the clear are
        // both gone, so the invariant is not documented here, it does not
        // exist.
        //
        // What replaces them, as structure rather than as a rule to keep:
        //
        // - **No two passes overlap**, because every pass awaits its
        //   predecessor as its first statement.
        // - **Every caller's read follows its own write**, because the pass
        //   this call installs cannot start before this call entered.
        // - **FIFO by entry**, because the read of `reconcileInFlight` and
        //   the assignment below it have nothing suspending between them on
        //   the main actor.
        //
        // The handle is never cleared. It names the last task installed and
        // keeps it alive after that task has completed, until the next call
        // replaces it — one finished `Task<Void, Never>`. A caller arriving
        // then awaits a task that is already done, which costs it a resume
        // and no read; its own pass runs after that, which is what
        // `aReconcileFollowingACompletedOneRunsItsOwnPass` reads.
        let previous = reconcileInFlight
        let task = Task { @MainActor in
            await previous?.value
            await performReconcilingReload()
        }
        reconcileInFlight = task
        await task.value
    }

    /// The pass itself. Separate from the chaining above so the `Task` each
    /// call installs has exactly one body, and so a caller awaiting the task
    /// ahead of it cannot re-enter this.
    private func performReconcilingReload() async {
        // Read through `readProfiles()`, NOT `reload()` (fix round 2).
        // `TunnelStore.allProfiles()` answers `[]` for a present-but-
        // undecodable file — right for the glyph and autostart, and exactly
        // wrong here: it would say every profile had been deleted and this
        // would stop every running forwarding. A read that failed leaves the
        // mirror, the runners and the states as they are; the one line
        // written is the only record, since `readProfiles()` deliberately
        // writes none of its own.
        //
        // `.error`, matching `TunnelStore.load()`'s level for the same
        // condition (fix round 3, N7). At `.info` this line was dropped by
        // any sink configured at `.error` — which is the level a user turns
        // the log down to precisely when they are looking for failures, and
        // the one setting under which an unreadable store would have left no
        // record at all.
        let profiles: [TunnelProfile]
        switch store.readProfiles() {
        case .success(let read):
            profiles = read
        case .failure(let error):
            DiagnosticLog.shared.log(
                .error, "app", "tunnels.json unreadable, keeping the forwardings as they are",
                reason: error)
            return
        }
        // The mirror is assigned here rather than through `reload()`, which
        // would be a second read of the same file — and, having gone through
        // `allProfiles()`, a read that could disagree with the one above.
        //
        // Rows whose session is gone are dropped from the mirror, never from
        // the file — see "A row without a session" on
        // `reloadReconciling()`. A session store that cannot be read answers
        // `nil`, and that drops nothing, for the reason an unreadable
        // `tunnels.json` drops nothing above.
        let listed = Self.listed(profiles, known: sessionIDs())
        // `runners.keys` beside the mirror: a synchronous `reload()` can
        // already have taken an orphan's row out of the mirror while its
        // runner is still up, and `reload()` stops nothing.
        let before = Set(allProfiles.map(\.id)).union(runners.keys)
        allProfiles = listed
        await discardAndForget(before.subtracting(Set(listed.map(\.id))))
    }

    /// Stops each profile's runner and forgets its state — what a profile
    /// that is gone for good leaves behind. The one copy of that loop; its
    /// two callers, counted 2026-09-16, are `performReconcilingReload()` and
    /// `forgetEverything(for:)`'s failed-delete path.
    private func discardAndForget(_ profileIDs: some Sequence<UUID>) async {
        for profileID in profileIDs {
            await discardRunner(for: profileID)
            states[profileID] = nil
        }
    }

    /// Writes a profile and drops whatever runner it had.
    ///
    /// **An edited profile is stopped**, and that is a decision rather than a
    /// side effect: a runner holds the profile it was built with, so a
    /// running tunnel that kept its runner after an edit would go on
    /// forwarding the OLD ports while the sheet showed the new ones. Stopping
    /// is the honest answer, and starting again is one click in the same
    /// menu.
    ///
    /// **The write comes first, and only a write that happened stops
    /// anything** (next build of 2026-09-17, Task 2). The stop is for an
    /// edit that took effect; a write the store refuses — an unreadable
    /// `tunnels.json` (`TunnelStoreError.unreadable`) — changed nothing, so
    /// the running tunnel is still forwarding exactly the profile that is
    /// still stored, and it is left running. `upsert` is synchronous, so the
    /// order changes nothing else: the discard still follows before this
    /// returns, and the runner it stops is still the one built from the old
    /// profile. `aRefusedSaveOrRemoveLeavesTheRunningTunnelRunning` is the
    /// measurement.
    func save(_ profile: TunnelProfile) async throws {
        try store.upsert(profile)
        await discardRunner(for: profile.id)
        reload()
    }

    /// Deletes a profile, then stops it and forgets its state — a state
    /// left behind would keep a row's colour alive for a profile that no
    /// longer exists.
    ///
    /// The delete comes first for `save(_:)`'s reason: a delete the store
    /// refuses removed nothing, so it stops nothing either.
    func remove(_ profile: TunnelProfile) async throws {
        try store.delete(id: profile.id)
        await discardRunner(for: profile.id)
        states[profile.id] = nil
        reload()
    }

    // MARK: - Runners

    /// This profile's runner, built and mirrored on first use.
    ///
    /// Every runner gets a GENERATION, and it is what keeps two runners for
    /// one profile from writing over each other. `discardRunner(for:)`
    /// suspends inside `stop()`, and anything that starts the same profile
    /// in that window builds a fresh runner here — so for a moment the OLD
    /// runner is still finishing its stop while the NEW one is already
    /// active. Two things follow, and round 1 had neither:
    ///
    /// - the mirror writes `states` only while its own generation is still
    ///   the profile's current one, so the old runner's parting `.stopped`
    ///   cannot land on the new runner's tunnel;
    /// - the discard clears the mirror and the state only for the
    ///   generation it was discarding.
    ///
    /// `aStartDuringADiscardKeepsItsOwnRunner` is the measurement, and it
    /// caught the first version of this fix (which had the second half and
    /// not the first: the old runner's own mirror published `.stopped` over
    /// a live tunnel anyway).
    private func runner(for profile: TunnelProfile) -> any TunnelRunning {
        if let existing = runners[profile.id] { return existing }
        let created = makeRunner(profile)
        runners[profile.id] = created
        generation += 1
        let mine = generation
        generations[profile.id] = mine
        states[profile.id] = .stopped
        // One mirror per runner, for that runner's whole life: `states` is a
        // single-consumer stream (see `TunnelRunner.states`), and this is
        // that consumer. It ends when the runner is discarded, never when
        // the tunnel stops — a stopped tunnel can be started again, and a
        // second mirror on the same stream would split the states between
        // two readers.
        mirrors[mine] = Task { [weak self] in
            for await state in created.states {
                guard let self else { return }
                guard generations[profile.id] == mine else { return }
                states[profile.id] = state
            }
        }
        return created
    }

    /// Stops a runner and forgets it, mirror included — leaving any NEWER
    /// runner for the same profile entirely alone.
    ///
    /// The slot is cleared before the `await` on purpose: a start landing in
    /// that window must build a new runner rather than hand out the one
    /// being torn down. The generation check is the other half — this call
    /// then cleans up only what it was cleaning up.
    private func discardRunner(for profileID: UUID) async {
        guard let runner = runners.removeValue(forKey: profileID) else { return }
        let mine = generations[profileID]
        await runner.stop()
        // Cancelled either way: this runner's mirror has nothing left to
        // report, whoever holds the profile's slot now.
        if let mine { mirrors.removeValue(forKey: mine)?.cancel() }
        guard generations[profileID] == mine else { return }
        generations[profileID] = nil
        states[profileID] = .stopped
    }

    // MARK: - The production runner

    /// The ids of every session in the App's own session store, or `nil`
    /// when that store cannot be read — the reader `shared` hands the
    /// reconcile.
    static func liveSessionIDs(
        sessions: SessionStore = SessionStore(directory: SessionStore.defaultDirectory)
    ) -> Set<UUID>? {
        guard let stored = try? sessions.all() else { return nil }
        return Set(stored.map(\.id))
    }

    /// A runner that dials for itself, from the stored session the profile
    /// names.
    ///
    /// The session is looked up at DIAL time, not here: a profile outlives
    /// any particular read of `sessions-v2.json`, and a reconnect an hour
    /// later must use the session as it stands then. A profile whose session
    /// is gone fails with `TunnelRefusal.sessionMissing` — a kind the state
    /// carries and the App translates, and whose English sentence the
    /// diagnostic log writes (`DialSupport.reason(for:)`).
    ///
    /// The stores are the App's own, all four rooted at
    /// `SessionStore.defaultDirectory`: the sessions, the known hosts, the
    /// managed keys and the Keychain.
    ///
    /// **The secret chain is `TunnelSecretSources.chain(for:keys:secrets:)`,
    /// not `secretSources(for:passwordCommand:)`** (fix round 1). The latter
    /// is the command line's: it consults `MACSCP_PASSWORD` BEFORE the
    /// Keychain, which must not decide a GUI dial. At fix round 1 it also
    /// reached only session-keyed slots — so a session using a managed
    /// private key, whose passphrase is stored under the KEY's id, resolved
    /// to nothing and the forwarding failed authentication while the same
    /// session's tab connected; both chains now end in the same
    /// `ManagedKeyPassphraseSecretSource`. See that type for what the chain
    /// is and why it is in that order.
    ///
    /// No secret is stored, logged or carried on the profile; it is resolved
    /// per dial and handed straight to the connect.
    ///
    /// `connectTimeout` is read per dial rather than captured, like every
    /// other setting this app reads on a loop: a forwarding can be up for
    /// days, and the number a reconnect uses should be the one currently in
    /// Settings. `async` because `SettingsStore` is main-actor isolated and
    /// a dial is not — the hop is one main-actor step per dial, not per
    /// byte.
    static func liveRunner(
        for profile: TunnelProfile,
        sessions: SessionStore = SessionStore(directory: SessionStore.defaultDirectory),
        knownHosts: KnownHostsStore = KnownHostsStore(directory: SessionStore.defaultDirectory),
        keys: ManagedKeyStore = ManagedKeyStore(directory: SessionStore.defaultDirectory),
        secrets: any SecretStore = KeychainSecretStore(),
        connectTimeout: @escaping @Sendable () async -> Int = {
            await MainActor.run {
                SettingsStore(directory: SessionStore.defaultDirectory).connectTimeoutSeconds
            }
        }
    ) -> any TunnelRunning {
        let sessionID = profile.sessionID
        return TunnelRunner(profile: profile, connect: { decider in
            guard let session = (try? sessions.all())?.first(where: { $0.id == sessionID }) else {
                throw TunnelRefusal.sessionMissing
            }
            return try await TunnelConnection.connect(
                session: session,
                secrets: TunnelSecretSources.chain(
                    for: session, keys: keys, secrets: secrets),
                knownHosts: knownHosts,
                decider: decider,
                connectTimeoutSeconds: await connectTimeout())
        })
    }
}
