import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Drives the recovery path end to end on a REAL `ContentView`
/// (connection-liveness plan, Task 7) — the half `ReconnectWiringGuardTests`
/// cannot reach. A source scan can prove `reconnect(_:)` names
/// `connect(in:stored:)`; only running it proves the redial actually
/// reaches the connector with the stored session's own configuration, and
/// that the tab it lands on is the one that lost its connection.
///
/// **Isolation.** Every `ContentView` here is built through `init`'s
/// `sessionListViewModel:`/`secretStore:`/`managedKeyStore:` seams, pointed
/// at a temporary directory and an in-memory `SecretStore`. That is not
/// caution for its own sake: an earlier round on this branch reassigned
/// those properties AFTER construction, the reassignment silently did not
/// take, and a mutation experiment wrote a real entry into the maintainer's
/// real `sessions-v2.json` and a real Keychain item. Every save name below
/// is run-unique for the same reason `ConnectAttemptHandoffTests`' are —
/// see that file's own "Isolation, round 3" — and
/// `theRealSessionsFileIsNeverTouched` proves the isolation empirically
/// rather than by reading the code.
@Suite("Reconnect path")
@MainActor
struct ReconnectPathTests {
    private static var realSessionsFileURL: URL {
        SessionStore.defaultDirectory.appendingPathComponent("sessions-v2.json")
    }

    private func snapshotRealSessionsFile() -> Data? {
        try? Data(contentsOf: Self.realSessionsFileURL)
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func uniqueSaveName(_ label: String) -> String {
        "\(label)-\(UUID().uuidString)"
    }

    /// Same shape as `ConnectAttemptHandoffTests.makeContentView`, including
    /// all three isolation seams.
    private func makeContentView(
        secrets: ReconnectSecretStore, storeDirectory: URL
    ) -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: storeDirectory),
            secrets: secrets,
            auditStore: AuditLogStore(directory: storeDirectory.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: storeDirectory),
            keys: ManagedKeyStore(directory: storeDirectory))
        let view = ContentView(
            settingsStore: SettingsStore(directory: settingsDir),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel,
            secretStore: secrets,
            managedKeyStore: ManagedKeyStore(directory: storeDirectory))
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
        })
    }

    private func makeTab(connector: @escaping ConnectionViewModel.Connector) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: connector),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Same shape as `LivenessGiveUpOrderingTests.attachSession(to:)`: a
    /// tab that looks connected, without a network anywhere.
    private func attachSession(to tab: SessionTab) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in throw CancellationError() }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        tab.liveness = .connected
    }

    @discardableResult
    private func waitUntil(
        _ description: Comment, timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var satisfied = await condition()
        while !satisfied, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            satisfied = await condition()
        }
        #expect(satisfied, description, sourceLocation: sourceLocation)
        return satisfied
    }

    // MARK: - Giving up records what the way back needs

    /// The fact `handleLivenessGiveUp(_:)` has to capture BEFORE the
    /// teardown that erases it: `teardown(_:)` clears
    /// `activeStoredSessionID` along with the session, so a give-up that
    /// read it afterwards would leave the surface with a Reconnect button
    /// and nothing to dial. Behavioural, not a source scan — the order of
    /// two statements is exactly what a scan cannot see, which is the
    /// lesson `LivenessGiveUpOrderingTests` was written for.
    @Test func givingUpRemembersWhichStoredSessionToRedial() async {
        let workDir = makeTempDirectory("giveup")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }
        let tab = makeTab(connector: { _, _ in throw CancellationError() })
        attachSession(to: tab)
        let storedID = UUID()
        tab.activeStoredSessionID = storedID

        await view.handleLivenessGiveUp(tab)

        #expect(tab.liveness == .lost)
        #expect(tab.activeStoredSessionID == nil, "teardown still clears the live session's id")
        #expect(tab.lostConnection?.storedSessionID == storedID, """
            the give-up did not record which stored session dropped. `teardown(_:)` clears \
            `activeStoredSessionID`, so reading it after the teardown — instead of before — \
            leaves "Reconnect" with nothing to dial.
            """)
        #expect(tab.lostConnection?.reason == .probeGaveUp)
        #expect(tab.lostConnection?.automaticAttempts == 0)
    }

    /// An ad-hoc connection has no stored session, and the surface must say
    /// so rather than offering a button that cannot work.
    @Test func givingUpOnAnAdHocConnectionOffersNoRedialTarget() async {
        let workDir = makeTempDirectory("giveup-adhoc")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }
        let tab = makeTab(connector: { _, _ in throw CancellationError() })
        attachSession(to: tab)

        await view.handleLivenessGiveUp(tab)

        #expect(tab.lostConnection?.storedSessionID == nil)
        #expect(view.reconnectTarget(for: tab) == nil)
    }

    // MARK: - The redial itself

    /// The load-bearing claim of this task, run rather than read: the
    /// reconnect reaches the connector — through `connect(in:stored:)`,
    /// which means through `fillForm(_:from:)`, through
    /// `ConnectionViewModel.connect()`'s validation, and with the host-key
    /// decider Core hands every backend — and lands a session on the tab
    /// that lost one.
    @Test func reconnectDialsTheStoredSessionAndBringsTheTabBack() async {
        let workDir = makeTempDirectory("reconnect-dial")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let secrets = ReconnectSecretStore()
        let (view, cleanup) = makeContentView(secrets: secrets, storeDirectory: workDir)
        defer { cleanup() }

        // `.agent` auth needs neither a typed password nor a keychain
        // lookup to pass the form's own pre-dial validation — the same
        // choice, for the same measured reason, as
        // `ConnectAttemptHandoffTests.runStoredSessionHandoffScenario`.
        let stored = StoredSession(
            name: uniqueSaveName("reconnect-target"), kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        try? SessionStore(directory: workDir).upsert(stored)
        view.sessionListViewModel.reload()

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.lostConnection = LostConnection(reason: .probeGaveUp, storedSessionID: stored.id)
        tab.liveness = .lost

        view.reconnect(tab)

        guard await waitUntil("the reconnect must reach the connector", {
            await recorder.dialCount == 1
        }) else { return }
        guard await waitUntil("the reconnect must hand a session to the tab", {
            tab.session != nil
        }) else { return }

        #expect(await recorder.dialedHost == "example.com", """
            the reconnect dialed something other than the stored session it recorded — the \
            redial must use the SAME stored configuration the dropped connection used.
            """)
        #expect(tab.activeStoredSessionID == stored.id)
        #expect(tab.liveness == .connected)
        #expect(tab.lostConnection == nil, """
            a tab with a live session again must stop describing the connection that dropped \
            — otherwise the next failed attempt returns to a stale surface, and an unattended \
            schedule keeps pacing itself by the old attempt count.
            """)
    }

    /// A session deleted while its tab sat on the lost surface: the button
    /// resolves to nothing and nothing is dialed. `reconnectTarget(for:)`
    /// is resolved against the live list on every call precisely so this
    /// cannot dial a session that is gone.
    @Test func reconnectDialsNothingWhenTheStoredSessionIsGone() async {
        let workDir = makeTempDirectory("reconnect-missing")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.lostConnection = LostConnection(reason: .probeGaveUp, storedSessionID: UUID())
        tab.liveness = .lost

        #expect(view.reconnectTarget(for: tab) == nil)
        view.reconnect(tab)
        // Nothing to await: with no target the call returns before the
        // `Task` inside `connect(in:stored:)` would ever be created. A
        // short settle keeps this from passing merely because the check
        // ran first.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.dialCount == 0)
        #expect(tab.session == nil)
        #expect(tab.liveness == .lost, "the tab stays on the surface that explains why")
    }

    @Test func dismissingTheSurfaceClearsBothFacts() async {
        let workDir = makeTempDirectory("reconnect-dismiss")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }
        let tab = makeTab(connector: { _, _ in throw CancellationError() })
        tab.lostConnection = LostConnection(reason: .probeGaveUp, storedSessionID: UUID())
        tab.liveness = .lost

        view.dismissLostConnection(tab)

        #expect(tab.liveness == nil, "the surface would otherwise stay up")
        #expect(tab.lostConnection == nil, """
            clearing only the liveness would leave the tab still "describing a lost \
            connection" — the next failed attempt would jump straight back to the surface \
            from under the form the user is typing into.
            """)
    }

    /// Everything that puts the FORM on a tab has to leave the lost
    /// surface first — `isConnected` is false for a lost tab, so these
    /// paths reuse it, and `ConnectionSurfacePlan` would keep the error
    /// view on screen over the freshly blanked form.
    @Test func newConnectionOnALostTabReturnsToTheForm() async {
        let workDir = makeTempDirectory("reconnect-newconnection")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }
        let tab = view.tabsModel.activeTab
        tab.lostConnection = LostConnection(reason: .probeGaveUp, storedSessionID: UUID())
        tab.liveness = .lost

        view.newConnection()

        #expect(tab.liveness == nil)
        #expect(tab.lostConnection == nil)
    }

    /// The user moved on: a connect aimed at a DIFFERENT stored session
    /// ends the episode, so a failure belongs to what they just asked for
    /// rather than sending them back to a surface offering to redial
    /// something else. The reconnect itself passes the same id, which is
    /// what keeps its own failures on the surface that explains them —
    /// `reconnectDialsTheStoredSessionAndBringsTheTabBack` above is the
    /// other half of this pair.
    @Test func connectingToADifferentSessionEndsTheLostEpisode() async {
        let workDir = makeTempDirectory("reconnect-different")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let other = StoredSession(
            name: uniqueSaveName("other-session"), kind: .ssh,
            ssh: StoredSSHConfig(host: "elsewhere.example", username: "tim", authKind: .agent))
        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.lostConnection = LostConnection(reason: .probeGaveUp, storedSessionID: UUID())
        tab.liveness = .lost

        view.connect(in: tab, stored: other)

        #expect(tab.lostConnection == nil, "a connect to a different stored session left the previous drop's record in place — a failure would then return to a surface offering to redial the OLD session.")
        guard await waitUntil("the connect must reach the connector", {
            await recorder.dialCount == 1
        }) else { return }
        #expect(await recorder.dialedHost == "elsewhere.example")
    }

    // MARK: - Pre-dial refusals reach the schedule as "needs a person"

    /// The reviewer's first measured example, driven end to end through the
    /// real code: a stored session whose login set no longer resolves.
    /// `ContentView.fillForm(_:from:)` reports it through
    /// `ConnectionViewModel.showFailure`, which round 1 had CLEARING the
    /// verdict — so the reason became `.reconnectFailed` and `.automatic`
    /// re-asked a question only a person could answer, on a schedule,
    /// forever.
    ///
    /// The chain is followed with the real pieces at every link: the real
    /// `fillForm`, the real `lastFailureKind` it leaves behind, the real
    /// `ConnectAttemptLivenessPlan.write` the mirror consults, and the real
    /// `ReconnectPlan.step` the runner consults. Only the SwiftUI mirror
    /// and runner themselves are stood in for — this project renders no
    /// views in a test.
    @Test func aDanglingLoginSetStopsTheUnattendedSchedule() throws {
        let workDir = makeTempDirectory("predial-loginset")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let stored = StoredSession(
            name: uniqueSaveName("dangling-set"),
            loginSetID: UUID(),   // no such set in the isolated store
            kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim"))
        let form = ConnectionViewModel(connector: { _, _ in
            Issue.record("the dial must never be reached — the fill refuses first")
            throw CancellationError()
        })

        let filled = try view.fillForm(form, from: stored)

        #expect(filled == false, "a dangling login set must refuse before the dial")
        #expect(form.lastFailureKind == .needsPerson, """
            a refusal decided before the dial left no verdict, so an unattended retry would \
            read it as worth repeating.
            """)
        expectTheScheduleStops(for: form, sourceLocation: #_sourceLocation)
    }

    /// The reviewer's second measured example: a stored session whose
    /// secret is gone from the store. Nothing throws — `fillForm` fills a
    /// blank password and `resolveConfigWithoutDialing()` refuses on the
    /// schema violation, a route that never reaches `connect()`'s `catch`
    /// at all, which is why round 1 left it unclassified.
    @Test func aMissingStoredSecretStopsTheUnattendedSchedule() async throws {
        let workDir = makeTempDirectory("predial-secret")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let stored = StoredSession(
            name: uniqueSaveName("missing-secret"), kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .password))
        let form = ConnectionViewModel(connector: { _, _ in
            Issue.record("the dial must never be reached — validation refuses first")
            throw CancellationError()
        })

        #expect(try view.fillForm(form, from: stored) == true, "the fill itself succeeds here")
        let fs = await form.connect()

        #expect(fs == nil)
        #expect(form.lastFailureKind == .needsPerson, """
            the schema violation for the empty secret left no verdict — this is the route that \
            never reaches the dial's `catch`, and round 1 classified only what the dial threw.
            """)
        expectTheScheduleStops(for: form, sourceLocation: #_sourceLocation)
    }

    /// The rest of the chain, shared by the two tests above: the verdict the
    /// form is carrying must make the mirror publish `.needsPerson`, and
    /// that reason must make the schedule stop — under `.automatic`, the
    /// behaviour where looping would actually happen.
    private func expectTheScheduleStops(
        for form: ConnectionViewModel, sourceLocation: SourceLocation
    ) {
        let write = ConnectAttemptLivenessPlan.write(
            for: form.state, hasSession: false, describesLostConnection: true,
            failureKind: form.lastFailureKind)
        guard case .lost(let reason) = write else {
            Issue.record(
                "a failed attempt on a lost tab must return to the lost surface, got \(write)",
                sourceLocation: sourceLocation)
            return
        }
        #expect(reason == .needsPerson, sourceLocation: sourceLocation)
        // The reason the plan ACTUALLY produced, threaded on rather than a
        // literal `.needsPerson` (round 3, after review): fed a literal,
        // this would answer `.stop` even if the chain above had produced
        // something else entirely, which is the whole thing it is checking.
        let step = ReconnectPlan.step(
            liveness: .lost,
            lost: LostConnection(reason: reason, storedSessionID: UUID()),
            targetIsKnown: true, behaviour: .automatic)
        #expect(step == .stop, sourceLocation: sourceLocation)
    }

    // MARK: - The failed-connect surface's own actions (Task 3)

    /// The load-bearing claim of the failed-connect surface, run rather
    /// than read: "Try again" reaches the connector THROUGH
    /// `connect(in:stored:)`, which means through `fillForm(_:from:)`, the
    /// form's own validation and the host-key decider Core hands every
    /// backend — with the stored session's own configuration, on the tab
    /// that failed.
    ///
    /// `ReconnectWiringGuardTests` can only prove `retryConnect(_:)` names
    /// the shared function; this proves the dial that comes out the other
    /// end is the stored session's.
    @Test func retryDialsTheStoredSessionThroughTheSharedConnect() async {
        let workDir = makeTempDirectory("retry-dial")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        // `.agent` auth for the same reason
        // `reconnectDialsTheStoredSessionAndBringsTheTabBack` uses it: it
        // passes the form's pre-dial validation without a typed password
        // or a keychain lookup.
        let stored = StoredSession(
            name: uniqueSaveName("retry-target"), kind: .ssh,
            ssh: StoredSSHConfig(host: "retry.example.com", username: "tim", authKind: .agent))
        try? SessionStore(directory: workDir).upsert(stored)
        view.sessionListViewModel.reload()

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.connectFailure = ConnectFailure(storedSessionID: stored.id)

        view.retryConnect(tab)

        guard await waitUntil("the retry must reach the connector", {
            await recorder.dialCount == 1
        }) else { return }
        guard await waitUntil("the retry must hand a session to the tab", {
            tab.session != nil
        }) else { return }

        #expect(await recorder.dialedHost == "retry.example.com", """
            the retry dialed something other than the stored session the failed attempt \
            recorded.
            """)
        #expect(tab.activeStoredSessionID == stored.id)
        #expect(tab.connectionViewModel.attemptOrigin == stored.id, """
            `connect(in:stored:)` did not hand the dial's origin to the attempt, so a \
            second failure would offer no way to edit the session it failed on.
            """)
    }

    /// A `fillForm` refusal never dials, and must therefore leave no origin
    /// behind either: an origin recorded here would outlive an attempt that
    /// never happened and be read by whatever failed next.
    ///
    /// What this test pins CHANGED with M3, and the change is worth stating
    /// rather than leaving to be inferred from a passing run. It used to
    /// pin an ordering — `connect(in:stored:)` wrote the origin onto the
    /// tab after the fill rather than before it, and writing it one line
    /// earlier made this red. There is no such line any more: the origin
    /// travels as an argument to `connect(origin:)`, which the refusal
    /// returns above, and `ConnectionViewModel.attemptOrigin` is
    /// `private(set)` so the App layer could not write it early even
    /// deliberately. The origin half below is therefore now structural, and
    /// the assertion that still has teeth is the one above it: the refusal
    /// happens BEFORE the dial, which is what makes "no origin" mean
    /// anything at all.
    @Test func afillRefusalRecordsNoDialOrigin() async {
        let workDir = makeTempDirectory("retry-refusal")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let stored = StoredSession(
            name: uniqueSaveName("dangling-on-retry"),
            loginSetID: UUID(),  // no such set in the isolated store
            kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim"))
        try? SessionStore(directory: workDir).upsert(stored)
        view.sessionListViewModel.reload()

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.connectFailure = ConnectFailure(storedSessionID: stored.id)

        view.retryConnect(tab)

        guard await waitUntil("the refusal must reach the form", {
            tab.connectionViewModel.lastFailureKind != nil
        }) else { return }
        #expect(await recorder.dialCount == 0, "a dangling login set must refuse before the dial")
        #expect(tab.connectionViewModel.attemptOrigin == nil)
    }

    /// The defect this task closes (two-open-questions design, M3): a
    /// stored-session dial that `ConnectionViewModel.connect()` REFUSES —
    /// because the form is already dialing something else — must contribute
    /// no origin to the attempt that is actually in flight.
    ///
    /// The refusal (`guard state != .connecting else { return nil }`)
    /// returns without touching `state`, so nothing downstream observes an
    /// attempt beginning or ending. An origin recorded outside the attempt
    /// therefore survives the refusal and is read by whatever fails next —
    /// here the ad-hoc dial, which offers "Edit session" for a session it
    /// never chose.
    ///
    /// Reachable exactly as the design describes: the form's own Connect
    /// button does not take `tab.isReconnecting`, and both paths are on the
    /// main actor, so the sidebar click lands squarely inside the window.
    ///
    /// The origin is read BEFORE the connector is released: after that the
    /// attempt ends, and a check that reads a transient condition after the
    /// thing that resolves it is not a check.
    @Test func aRefusedStoredDialLeavesNoOriginOnTheAttemptInFlight() async {
        let workDir = makeTempDirectory("refused-dial-origin")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        // `.agent` for the same reason as the tests above: it passes the
        // form's pre-dial validation without a typed password or a keychain
        // lookup, so `fillForm` cannot refuse before the dial is attempted.
        let stored = StoredSession(
            name: uniqueSaveName("never-dialed"), kind: .ssh,
            ssh: StoredSSHConfig(
                host: "never-dialed.example.com", username: "tim", authKind: .agent))
        try? SessionStore(directory: workDir).upsert(stored)
        view.sessionListViewModel.reload()

        let recorder = DialRecorder()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            for await _ in stream {}   // hangs until this test releases it
            throw CancellationError()
        })

        // The form's own ad-hoc dial — typed in, never saved, and the one
        // attempt that is genuinely in flight.
        let form = tab.connectionViewModel
        form.host = "ad-hoc.example.com"
        form.username = "tim"
        form.password = "geheim"
        let adHoc = Task { await form.connect() }
        guard await waitUntil("the ad-hoc dial must reach the connector", {
            await recorder.dialCount == 1
        }) else {
            continuation.finish()
            _ = await adHoc.value
            return
        }

        // A sidebar click on a stored session, mid-dial. `connect(in:stored:)`
        // fills the form and reaches `form.connect()`, which refuses.
        view.connect(in: tab, stored: stored)
        guard await waitUntil("the refused stored dial must run to completion", {
            !tab.isReconnecting
        }) else {
            continuation.finish()
            _ = await adHoc.value
            return
        }

        let originAfterRefusal = tab.connectionViewModel.attemptOrigin

        continuation.finish()
        _ = await adHoc.value

        // The positive half, without which the expectation at the end is a
        // claim about an attempt that never happened: a refusal that never
        // refused, or a dial that never failed, would both let it pass.
        #expect(await recorder.dialCount == 1, """
            the refused stored dial reached the connector — it was not refused at all, so \
            this test is no longer about the window it was written for.
            """)
        guard case .failed = form.state else {
            Issue.record("""
                the ad-hoc attempt did not end in a failure, so there is no failed attempt for \
                an origin to be attached to.
                """)
            return
        }

        #expect(originAfterRefusal == nil, """
            a refused stored dial left its origin behind, and the ad-hoc attempt that failed \
            carries it — the failed-connect surface would offer "Edit session" for a session \
            this attempt never dialed.
            """)
    }

    /// The neighbouring path, measured while M3 was being built and fixed
    /// in the same pass: a failure that is not an attempt at all must not
    /// wear the label of the attempt before it.
    ///
    /// `attemptOrigin` is assigned at the head of `connect()` and survives
    /// that attempt — that is what makes it readable mid-dial. So a form
    /// that has already dialed a stored session carries its id afterwards,
    /// and the NEXT thing to publish `.failed` on that form inherits it
    /// unless it says otherwise. `fillForm` refusing a dangling login set
    /// is exactly that: `showFailure` publishes `.failed` without any dial
    /// having happened.
    ///
    /// Before the fix this read the FIRST session's id, so the surface
    /// offered "Edit session" for a session the user had moved on from —
    /// the same mislabelling M3 removes from the refusal path, one door
    /// down. `fail(_:kind:origin:)` is where both are now stated.
    @Test func aFailureThatNeverDialedDoesNotInheritTheLastAttemptsOrigin() async {
        let workDir = makeTempDirectory("origin-not-inherited")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let dialed = StoredSession(
            name: uniqueSaveName("dialed-first"), kind: .ssh,
            ssh: StoredSSHConfig(
                host: "dialed-first.example.com", username: "tim", authKind: .agent))
        let dangling = StoredSession(
            name: uniqueSaveName("dangling-second"),
            loginSetID: UUID(),  // no such set in the isolated store
            kind: .ssh,
            ssh: StoredSSHConfig(host: "dangling-second.example.com", username: "tim"))
        try? SessionStore(directory: workDir).upsert(dialed)
        try? SessionStore(directory: workDir).upsert(dangling)
        view.sessionListViewModel.reload()

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            throw CancellationError()
        })

        view.connect(in: tab, stored: dialed)
        guard await waitUntil("the first stored dial must fail and finish", {
            await recorder.dialCount == 1 && !tab.isReconnecting
        }) else { return }
        // The precondition IS the setup: without an origin on record there
        // is nothing for the second failure to inherit, and the assertion
        // at the end would hold for a form that never dialed anything.
        #expect(tab.connectionViewModel.attemptOrigin == dialed.id, """
            the first attempt did not record its own origin, so this test is no longer about \
            inheriting one.
            """)

        view.connect(in: tab, stored: dangling)
        guard await waitUntil("the refused fill must run to completion", {
            !tab.isReconnecting
        }) else { return }

        #expect(await recorder.dialCount == 1, """
            the dangling login set must refuse BEFORE the dial — otherwise this is a second \
            attempt, not a failure without one.
            """)
        guard case .failed = tab.connectionViewModel.state else {
            Issue.record("the fill refusal must publish a failure for an origin to be read from")
            return
        }
        #expect(tab.connectionViewModel.attemptOrigin == nil, """
            a failure that never dialed carries the previous attempt's origin — the surface \
            offers "Edit session" for the session the user has just moved on from.
            """)
    }

    /// An ad-hoc attempt — typed into the form, never saved — has no stored
    /// session to redial and no second dial on this branch to redial it
    /// with, so the surface does not offer Retry at all (round 2, after
    /// review). Two halves, and the second is the one that matters: the
    /// plan omits the button, AND the tab is left exactly as it was rather
    /// than being quietly sent back to the form.
    ///
    /// Round 1 had `retryConnect(_:)` call `dismissConnectFailure(_:)` in
    /// this case — the same call `onEdit` makes — so a user who pressed
    /// "Erneut versuchen" got the prefilled form and no dial, which is the
    /// complaint this whole surface answers. Both #expects below fail
    /// against that version.
    @Test func anAdHocFailureOffersNoRetryAtAll() async {
        let workDir = makeTempDirectory("retry-adhoc")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.connectFailure = ConnectFailure(storedSessionID: nil)

        #expect(view.failedConnectTarget(for: tab) == nil)
        #expect(
            ConnectFailurePlan.content(
                hasStoredSession: view.failedConnectTarget(for: tab) != nil).retryButton == nil,
            "the surface must not offer a Retry the app has no way to perform")

        // Reachable only if a target vanished between render and click.
        view.retryConnect(tab)

        #expect(await recorder.dialCount == 0)
        #expect(tab.connectFailure != nil, """
            `retryConnect(_:)` cleared the surface for an ad-hoc failure — that is round 1's \
            defect: a button named "try again" that dials nothing and returns the form.
            """)
    }

    /// A session deleted while its tab sat on this surface: `Edit session`
    /// resolves to nothing and Retry dials nothing, because
    /// `failedConnectTarget(for:)` is answered against the live list on
    /// every call rather than remembered.
    @Test func aDeletedSessionLeavesNothingToRetryOrEdit() async {
        let workDir = makeTempDirectory("retry-missing")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let recorder = DialRecorder()
        let tab = makeTab(connector: { config, _ in
            await recorder.record(config)
            return RecordingFileSystem(recorder: recorder)
        })
        tab.connectFailure = ConnectFailure(storedSessionID: UUID())  // never in the store

        #expect(view.failedConnectTarget(for: tab) == nil)

        view.retryConnect(tab)
        #expect(await recorder.dialCount == 0)
    }

    /// "Close" on the only tab leads back to the form.
    ///
    /// Review round 1, measured on this path before the fix: `performClose`
    /// tears the tab down and then removes it — except on the LAST tab,
    /// which `TabsViewModel.closeTab` refuses to remove, so it stays as a
    /// torn-down form tab. `teardown(_:reason:)` cleared `liveness` and
    /// `lostConnection` but not `connectFailure`, and
    /// `ConnectionSurfacePlan` reads nothing else for this surface: the
    /// window shrank and the surface stood there with all four buttons.
    /// One tab is the normal case at launch, so this was the ordinary way
    /// to meet it.
    ///
    /// Driven through `performClose` rather than through the property, so
    /// what is pinned is the path a click takes, and asserted through
    /// `ConnectionSurfacePlan.surface` rather than only the property, so a
    /// future second source for this surface cannot pass this test while
    /// leaving the view up.
    @Test func closingTheOnlyTabLeavesTheFailedSurface() async {
        let workDir = makeTempDirectory("close-last-tab")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let tab = view.tabsModel.activeTab
        tab.connectFailure = ConnectFailure(storedSessionID: nil)
        #expect(view.tabsModel.isLastTab, "the case this test exists for is the single tab")
        #expect(
            ConnectionSurfacePlan.surface(
                for: tab.liveness, hostKeyPromptPending: false,
                connectAttemptFailed: tab.connectFailure != nil) == .failed,
            "the surface has to be up before Close can be measured against it")

        await view.performClose(tab)

        #expect(tab.connectFailure == nil, """
            `teardown(_:reason:)` left the failed-connect record on the tab, so "Close" on \
            the only tab does visibly nothing — the window shrinks and the surface stays.
            """)
        #expect(
            ConnectionSurfacePlan.surface(
                for: tab.liveness, hostKeyPromptPending: false,
                connectAttemptFailed: tab.connectFailure != nil) == .form,
            "closing a tab has to end on the entry form, whatever the tab was showing")
    }

    /// The sibling fact, on the same path: a tab that LOST its connection
    /// survives its own Close in neither form. This was already true —
    /// `teardown` has always cleared `liveness` — and is pinned here so the
    /// two surfaces cannot drift apart again in the direction the fix above
    /// came from.
    @Test func closingTheOnlyTabLeavesTheLostSurface() async {
        let workDir = makeTempDirectory("close-last-tab-lost")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let tab = view.tabsModel.activeTab
        tab.lostConnection = LostConnection(reason: .probeGaveUp, storedSessionID: UUID())
        tab.liveness = .lost

        await view.performClose(tab)

        #expect(tab.liveness == nil)
        #expect(tab.lostConnection == nil)
        #expect(
            ConnectionSurfacePlan.surface(
                for: tab.liveness, hostKeyPromptPending: false,
                connectAttemptFailed: tab.connectFailure != nil) == .form)
    }

    /// "Edit session" opens the real session editor on the session that
    /// failed, and leaves the surface — the form it puts up would otherwise
    /// sit behind an error view, which is the same defect `newConnection()`
    /// and `formTarget()` already carry a clear for.
    @Test func editSessionOpensTheEditorAndLeavesTheSurface() async {
        let workDir = makeTempDirectory("retry-edit")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(
            secrets: ReconnectSecretStore(), storeDirectory: workDir)
        defer { cleanup() }

        let stored = StoredSession(
            name: uniqueSaveName("edit-target"), kind: .ssh,
            ssh: StoredSSHConfig(host: "edit.example.com", username: "tim", authKind: .agent))
        try? SessionStore(directory: workDir).upsert(stored)
        view.sessionListViewModel.reload()

        // The view's OWN active tab, not a detached one: `editStored(_:)`
        // resolves its target through `formTarget()`, which reads
        // `activeTab` — the tab this surface is rendered for by
        // construction.
        let tab = view.tabsModel.activeTab
        tab.connectFailure = ConnectFailure(storedSessionID: stored.id)

        view.editFailedSession(tab)

        #expect(tab.connectFailure == nil)
        #expect(tab.connectionViewModel.mode == .edit(sessionID: stored.id), """
            "Edit session" did not put the form into edit mode for the session that failed.
            """)
        #expect(tab.connectionViewModel.host == "edit.example.com")
    }

    // MARK: - Isolation proof

    @Test func theRealSessionsFileIsNeverTouched() async {
        let before = snapshotRealSessionsFile()
        await reconnectDialsTheStoredSessionAndBringsTheTabBack()
        await givingUpRemembersWhichStoredSessionToRedial()
        // The failed-connect surface's own two store-writing scenarios
        // (Task 3), added here rather than trusted to look isolated: both
        // upsert a session and both drive the real `connect`/`editStored`
        // paths, which is exactly the shape that wrote into the
        // maintainer's real store on an earlier round of this branch.
        await retryDialsTheStoredSessionThroughTheSharedConnect()
        await editSessionOpensTheEditorAndLeavesTheSurface()
        let after = snapshotRealSessionsFile()
        #expect(before == after, """
            the real on-disk session store changed while this suite ran. `before` had \
            \(before?.count.description ?? "no file"), `after` had \
            \(after?.count.description ?? "no file").
            """)
    }
}

/// Records what the connector was handed, and how often — an actor so the
/// polling loops above can read it while the dial runs.
private actor DialRecorder {
    private(set) var dialCount = 0
    private(set) var dialedHost: String?
    private(set) var disconnectCount = 0

    func record(_ config: ConnectionConfig) {
        dialCount += 1
        if case .ssh(let ssh) = config { dialedHost = ssh.host }
    }

    func markDisconnected() { disconnectCount += 1 }
}

/// A `RemoteFileSystem` that answers only what a successful connect needs
/// (`homeDirectoryPath()`), and traps on everything else so a future change
/// routing through one of them fails loudly instead of passing silently —
/// the same idiom as `ConnectAttemptHandoffTests
/// .HangingHomeDirectoryFileSystem` and `LivenessProbeRaceTests
/// .NeverRespondingFileSystem`.
private struct RecordingFileSystem: RemoteFileSystem {
    let recorder: DialRecorder

    func list(path: String) async throws -> [RemoteFileItem] {
        fatalError("not exercised by this test")
    }

    func stat(path: String) async throws -> RemoteFileItem {
        fatalError("not exercised by this test")
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        fatalError("not exercised by this test")
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        fatalError("not exercised by this test")
    }

    func delete(path: String) async throws { fatalError("not exercised by this test") }
    func createDirectory(at path: String) async throws { fatalError("not exercised by this test") }
    func rename(from: String, to: String) async throws { fatalError("not exercised by this test") }
    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }
    func deleteTree(at path: String) async throws { fatalError("not exercised by this test") }

    func homeDirectoryPath() async throws -> String { "/home/reconnect-test" }

    func disconnect() async { await recorder.markDisconnected() }
}

/// In-memory `SecretStore` — `macSCPAppKitTests` cannot import
/// `macSCPCoreTests`' own double (separate SwiftPM test targets), and the
/// point of passing one at all is that no test in this file can reach the
/// real Keychain.
private final class ReconnectSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
