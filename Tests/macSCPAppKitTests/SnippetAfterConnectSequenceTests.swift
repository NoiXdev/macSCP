import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The session overview's "Run" on a snippet, end to end on a REAL
/// `ContentView`: connect through the entry the overview already holds, wait
/// for the tab's own shell, then send — once (session overview plan, Task 3).
///
/// **No clock decides anything here.** "The terminal is open" is the tab's
/// own state (`TerminalPanelViewModel.state == .running`), and every wait is
/// a `pollUntil` on that state or on the shell's recorder. A ceiling on how
/// long the sequence took would measure the runner (CLAUDE.md, "A wall-clock
/// ceiling in a test measures the runner"); what is asserted is the ORDER —
/// nothing is sent before the shell runs, exactly one thing is sent after it,
/// and a failed dial sends nothing at all.
///
/// **The observer stands in for a view.** In the running app a
/// `PendingSnippetRunner` mounted per tab calls
/// `ContentView.deliverPendingSnippetRun(on:)` whenever the facts that
/// method reads change. No test in this project renders a SwiftUI view, so
/// these tests call that method themselves, at the moments the observer
/// would — which is exactly the split this project already uses for
/// `LivenessProbeCoverage` and `ConnectAttemptLivenessPlan`: the decision is
/// a function a test can drive, and that the view calls it is a source-scan
/// claim (`SessionOverviewWiringGuardTests`).
///
/// **Isolation.** The same three seams `AlreadyOpenSessionTests` and
/// `ReconnectPathTests` use (`sessionListViewModel:`/`secretStore:`/
/// `managedKeyStore:`, all pointed at a temporary directory and an in-memory
/// `SecretStore`), and for the reason those files record: reassigning them
/// after construction silently does not take, and the test then runs against
/// the maintainer's real session store and real Keychain. The tab the window
/// starts with is replaced by one of this suite's own, so the only connector
/// reachable from `tabsModel` is the fake.
@Suite("Snippet after connect", .timeLimit(.minutes(1)))
@MainActor
struct SnippetAfterConnectSequenceTests {
    // MARK: - Harness

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func makeContentView(
        storeDirectory: URL
    ) -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let secrets = InMemorySnippetRunSecretStore()
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

    /// A tab whose dial either hands back a file system that can open
    /// shells, or throws. `shells` is `nil` for the failing connector, which
    /// is what makes "the fake terminal received nothing" a claim about a
    /// recorder that exists rather than about one nobody wired.
    ///
    /// `disconnectGate`, when given, holds `disconnect()` open until the test
    /// releases it (`DisconnectGate.open()`) — see that type's own doc
    /// comment for why a held continuation and not a sleep.
    private func makeTab(
        shells: ShellRecorder?, shellOpens: Bool = true, disconnectGate: DisconnectGate? = nil
    ) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                guard let shells else { throw RemoteFSError.protocolError(reason: "dial refused") }
                return ShellingFileSystem(
                    shells: shells, opensShell: shellOpens, disconnectGate: disconnectGate)
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Replaces the window's own tab (which carries the real SSH connector)
    /// with one this suite controls.
    private func installControlledTab(
        in view: ContentView, shells: ShellRecorder?, shellOpens: Bool = true,
        disconnectGate: DisconnectGate? = nil
    ) -> SessionTab {
        let controlled = makeTab(
            shells: shells, shellOpens: shellOpens, disconnectGate: disconnectGate)
        let original = view.tabsModel.activeTab
        view.tabsModel.addTab(controlled)
        view.tabsModel.closeTab(original.id)
        return controlled
    }

    /// `.agent` auth needs neither a typed password nor a keychain lookup to
    /// pass the form's own pre-dial validation — the same choice, for the
    /// same measured reason, as `AlreadyOpenSessionTests`.
    private func storeSession(_ label: String, in directory: URL, view: ContentView)
        -> StoredSession
    {
        let stored = StoredSession(
            name: "\(label)-\(UUID().uuidString)", kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        try? SessionStore(directory: directory).upsert(stored)
        view.sessionListViewModel.reload()
        return stored
    }

    private func snippet(_ command: String) -> Snippet {
        Snippet(name: "overview-run", command: command)
    }

    // MARK: - A failed connect sends nothing

    /// Step (3) of the sequence: the dial did not produce a session, so the
    /// snippet is dropped and the shell is never even opened. What the user
    /// sees instead is the failed-connect surface, which this task did not
    /// touch.
    @Test func aFailedConnectSendsNothingAndDropsThePendingSnippet() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-failed")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        // A recorder that IS wired, on a tab whose connector throws: the
        // "received nothing" assertion below is then about a shell that
        // could have recorded, not about a seam nobody connected.
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: nil)
        let stored = storeSession("failed", in: workDir, view: view)

        view.runSnippetAfterConnecting(snippet("uptime"), on: stored)
        #expect(tab.pendingSnippetRun != nil, """
            the Run never armed anything — with nothing pending, the two checks below would \
            be satisfied by a sequence that never started.
            """)

        // The attempt has settled when the tab releases its own dial lock;
        // `isReconnecting` is the App-side token `connect(in:stored:)` sets
        // synchronously and clears in its `defer`. No clock, no ceiling.
        try await pollUntil("the failed dial to settle") { !tab.isReconnecting }
        view.deliverPendingSnippetRun(on: tab)

        #expect(tab.session == nil, "the dial was supposed to fail")
        #expect(tab.pendingSnippetRun == nil, """
            the snippet is still pending after a failed connect — it would then fire at \
            whatever this tab connects to next, which is not what the user asked for.
            """)
        #expect(await shells.openCount == 0, "no shell may be opened for a connect that failed")
        #expect(await shells.sendCount == 0, "nothing may be sent for a connect that failed")
    }

    // MARK: - A successful connect sends once, after the shell is running

    @Test func theSnippetIsSentOnceTheShellRunsAndOnlyOnce() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-ok")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells)
        let stored = storeSession("ok", in: workDir, view: view)
        let command = "echo overview-run-marker"

        view.runSnippetAfterConnecting(snippet(command), on: stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }

        // The observer's first useful firing: connected, but no shell yet.
        // Nothing may go out here — the ordering claim this test exists for.
        view.deliverPendingSnippetRun(on: tab)
        #expect(await shells.sendCount == 0, """
            bytes went out before the shell was running. The sequence is connect → shell → \
            send; sending into a panel that has not opened is what the pending hand-off \
            exists to avoid.
            """)
        #expect(tab.pendingSnippetRun != nil, "the snippet must stay pending until it is sent")

        try await pollUntil("the shell to reach .running") {
            tab.session?.terminal.state == .running
        }
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the snippet to reach the shell") { await shells.sendCount >= 1 }

        // Read once, into a local: `#expect` reports the SOURCE TEXT of what
        // it checks, and an `await` inside its autoclosure does not compile
        // at all — the same rule this project states for a value a test must
        // not leak, met here by the compiler rather than by discipline.
        let received = await shells.text
        #expect(received.contains(command), """
            the shell did not receive the snippet's command. Received: \(received.debugDescription)
            """)
        #expect(tab.pendingSnippetRun == nil, """
            the pending snippet survived its own send — a second `.running` would then send \
            it again.
            """)

        // Exactly once: the observer fires for every later change of the
        // facts it watches, and a second firing must send nothing more.
        view.deliverPendingSnippetRun(on: tab)
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the terminal's send queue to drain") {
            tab.session?.terminal.state == .running
        }
        let sends = await shells.sendCount
        #expect(sends == 1, """
            \(sends) sends reached the shell, expected exactly one — the pending snippet is \
            cleared before the send precisely so a repeated observation cannot repeat the \
            command.
            """)
    }

    /// Step (3) of the delivery guards: `triggerSnippet` acts on the ACTIVE
    /// tab, so a tab whose shell comes up in the background must not deliver
    /// — the command would go to whatever shell is on screen instead. It
    /// stays pending and is delivered when that tab is looked at again.
    @Test func aBackgroundTabDoesNotSendIntoTheTabOnScreen() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-background")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells)
        let stored = storeSession("background", in: workDir, view: view)

        view.runSnippetAfterConnecting(snippet("echo background"), on: stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the shell to reach .running") {
            tab.session?.terminal.state == .running
        }

        // The user has moved to another tab while the dial was running.
        let other = makeTab(shells: nil)
        view.tabsModel.addTab(other)
        view.tabsModel.activate(other.id)

        view.deliverPendingSnippetRun(on: tab)
        #expect(await shells.sendCount == 0, """
            the snippet was delivered while another tab was on screen — `triggerSnippet` acts \
            on `activeTab`, so those bytes went to a different shell than the one the Run was \
            armed against.
            """)
        #expect(tab.pendingSnippetRun != nil, """
            the snippet was dropped instead of waiting: coming back to the tab it belongs to \
            is supposed to deliver it, not find it gone.
            """)

        // Coming back is what delivers.
        view.tabsModel.activate(tab.id)
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the snippet to reach the shell") { await shells.sendCount >= 1 }
        #expect(tab.pendingSnippetRun == nil)
    }

    /// Fix round 1, Important 2. A start answered by the already-open
    /// QUESTION dials nothing (see `ContentView.sidebarStart`), so nothing is
    /// armed yet — the snippet rides on the REQUEST. "Open Anyway" starts
    /// what was asked for, and before the fix that answer connected with the
    /// snippet silently dropped.
    @Test func aRunAnsweredByOpenAnywayStillRunsTheSnippet() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-anyway")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells)
        let stored = storeSession("anyway", in: workDir, view: view)
        let command = "echo answered-anyway"

        // Another tab already holds this stored session.
        let holder = makeTab(shells: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(tab.id)

        let query = try #require(
            view.runSnippetAfterConnecting(snippet(command), on: stored),
            """
            the start did not raise the already-open query although another tab holds this \
            session — the rest of this test is about the answer to a question nobody asked.
            """)
        #expect(tab.pendingSnippetRun == nil, """
            the Run armed a snippet before the question was answered. Nothing is dialling yet, \
            and a snippet parked here would fire at whatever this tab connected to next.
            """)
        #expect(query.pendingSnippet?.command == command, """
            the query does not carry the snippet, so the answer below has nothing to start \
            with — which is exactly the silent drop this fix is about.
            """)

        // "Open Anyway", as `ContentView+Sheets` presses it.
        view.startWithoutAsking(
            query.stored, paneVisibility: query.paneVisibility,
            pendingSnippet: query.pendingSnippet)

        try await pollUntil("the tab to hold a session") { tab.session != nil }
        #expect(tab.pendingSnippetRun != nil, "the answer must arm what the question carried")
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the shell to reach .running") {
            tab.session?.terminal.state == .running
        }
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the snippet to reach the shell") { await shells.sendCount >= 1 }
        let received = await shells.text
        #expect(received.contains(command), "received: \(received.debugDescription)")
    }

    /// The other answer: "Go to Existing Tab" opens no connection here, so
    /// the snippet goes with the request. Nothing is armed on any tab and
    /// nothing is sent — and nothing had to be un-armed to get there, which
    /// is the whole reason the snippet rides on the question.
    @Test func aRunAnsweredByGoToExistingTabRunsNothing() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-jump")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells)
        let stored = storeSession("jump", in: workDir, view: view)

        let holder = makeTab(shells: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(tab.id)

        let query = try #require(view.runSnippetAfterConnecting(snippet("echo jumped"), on: stored))
        view.jumpToOpenSession(query)

        // Nothing to await: neither answer creates the `Task` inside
        // `connect(in:stored:)` here. The settle keeps this from passing
        // merely because the checks ran first.
        try? await Task.sleep(for: .milliseconds(50))
        let armed = view.tabsModel.tabs.filter { $0.pendingSnippetRun != nil }
        #expect(armed.isEmpty, """
            \(armed.count) tab(s) hold a pending snippet after "Go to Existing Tab" — that \
            answer opens no connection, so the snippet has nothing to run against and would \
            wait for some later connect.
            """)
        #expect(tab.session == nil, "the answer was supposed to jump, not dial")
        #expect(await shells.sendCount == 0)
    }

    /// Fix round 1, Critical. `TerminalPanelViewModel.openIfNeeded()` returns
    /// early for `.opening`/`.running` but REOPENS from `.ended`, and the
    /// runner wakes on every state change — so an unconditional
    /// `openIfNeeded()` in the delivery turns a shell that will not open into
    /// an `.opening → .ended → .opening` loop: a tight main-actor spin for a
    /// backend whose opener throws at once, and repeated shell-channel opens
    /// against the server for an SSH one.
    ///
    /// What is measured is the DECISION and a COUNT, never a duration:
    /// `openIfNeeded()` writes `.opening` synchronously, before its own Task
    /// runs, so reading the state straight after a delivery reads the answer
    /// this method just gave rather than a race with the open.
    @Test func aShellThatWillNotOpenIsAttemptedOnceAndDropsTheSnippet() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-noshell")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells, shellOpens: false)
        let stored = storeSession("noshell", in: workDir, view: view)

        view.runSnippetAfterConnecting(snippet("echo never"), on: stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }

        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the shell open to fail") {
            if case .ended = tab.session?.terminal.state { return true }
            return false
        }

        // The runner's next firing, replayed by hand: it wakes on the state
        // change the failed open produced, and would wake again on each open
        // it started.
        view.deliverPendingSnippetRun(on: tab)

        let stateAfter = tab.session?.terminal.state
        #expect(stateAfter != .opening, """
            a delivery on an .ended shell started another open. openIfNeeded() reopens from \
            .ended, so this is a loop: every attempt fails, the failure is a state change, and \
            the state change drives the next attempt.
            """)
        view.deliverPendingSnippetRun(on: tab)
        view.deliverPendingSnippetRun(on: tab)

        let opens = await shells.openCount
        #expect(opens == 1, """
            the shell was opened \(opens) times, expected exactly one.
            """)
        #expect(tab.pendingSnippetRun == nil, """
            the snippet is still pending after the shell failed to open — it is what keeps the \
            runner interested in this tab, and there is no shell coming.
            """)
        #expect(await shells.sendCount == 0, "nothing may be sent to a shell that never opened")
    }

    /// The hand-off is per TAB and names the session it was armed for: a tab
    /// that ended up connected to something else drops it rather than
    /// running a snippet against a host the user did not choose.
    @Test func aSnippetArmedForOneSessionIsNotSentToAnother() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-other")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells)
        let stored = storeSession("other", in: workDir, view: view)

        view.runSnippetAfterConnecting(snippet("echo elsewhere"), on: stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }
        // The tab is connected — to a DIFFERENT stored session than the one
        // the snippet was armed for.
        tab.activeStoredSessionID = UUID()

        view.deliverPendingSnippetRun(on: tab)
        #expect(tab.pendingSnippetRun == nil, "a snippet that cannot be delivered is dropped")
        #expect(await shells.sendCount == 0, """
            the snippet was sent to a session it was not armed for.
            """)
    }

    // MARK: - Teardown drops an armed snippet before it can reopen a dying shell

    /// Final fix round, item 1. A snippet can still be armed when the user
    /// disconnects — the shell was running, but `deliverPendingSnippetRun`
    /// had not yet fired for the `.running` transition that would have sent
    /// it and cleared it. `teardown(_:reason:)` must drop the armed snippet
    /// before `terminal.shutdown()` sets the panel `.closed`, or the same
    /// observer that would have delivered the snippet reads "closed, and
    /// still armed" as "reopen the shell" — on a connection this function is
    /// in the middle of taking down, not one that dropped.
    ///
    /// **No clock.** `disconnect()` on this test's own file system is held
    /// open by `DisconnectGate`, a stored continuation the test resumes by
    /// hand, not a sleep — so the moment `deliverPendingSnippetRun` is
    /// replayed here is the exact moment `teardown(_:reason:)` has itself
    /// reached: between `terminal.shutdown()` returning (the panel is
    /// `.closed`) and `session.remote.disconnect()` returning (the tab still
    /// has a `session` and its `activeStoredSessionID`, since `teardown`
    /// clears both only after that call).
    @Test func teardownDropsAnArmedSnippetBeforeTheTerminalCloses() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-teardown")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let gate = DisconnectGate()
        let tab = installControlledTab(in: view, shells: shells, disconnectGate: gate)
        let stored = storeSession("teardown", in: workDir, view: view)

        view.runSnippetAfterConnecting(snippet("echo never-sent"), on: stored)
        try await pollUntil("the tab to hold a session") { tab.session != nil }

        // Opens the shell without sending anything: the `.closed` case of
        // `deliverPendingSnippetRun` only calls `openIfNeeded()`; it does not
        // clear `pendingSnippetRun` (only `.ended` and `.running` do, and
        // this stops short of both), which is what keeps the snippet armed
        // into the disconnect below.
        view.deliverPendingSnippetRun(on: tab)
        try await pollUntil("the shell to reach .running") {
            tab.session?.terminal.state == .running
        }
        #expect(tab.pendingSnippetRun != nil, """
            the snippet must still be armed when the disconnect starts below — that is the \
            whole scenario this test reproduces, and the two checks after it would be \
            satisfied by an empty one otherwise.
            """)
        let opensBeforeDisconnect = await shells.openCount

        let teardownTask = Task { await view.teardown(tab, reason: .userRequested) }
        try await pollUntil("the terminal to close") {
            tab.session?.terminal.state == .closed
        }

        // The observer's own moment, replayed by hand (this project renders
        // no SwiftUI view under test — see this file's own doc comment):
        // `PendingSnippetRunner` wakes on every state change the tab
        // produces, and the terminal has just changed. `teardown` itself is
        // still suspended on the gated `disconnect()` below, exactly as it
        // would be mid-way through a real one.
        view.deliverPendingSnippetRun(on: tab)

        await gate.open()
        await teardownTask.value

        let opensAfter = await shells.openCount
        #expect(opensAfter == opensBeforeDisconnect, """
            \(opensAfter - opensBeforeDisconnect) extra shell open(s) started during teardown — \
            a snippet still armed when the terminal closes must not reopen a connection that is \
            being torn down.
            """)
        #expect(tab.pendingSnippetRun == nil, "teardown must still drop the snippet on its way out")
    }
}

// MARK: - Doubles

/// Counts what reached the fake shell. An actor so the polling loops above
/// can read it while `TerminalPanelViewModel`'s own send task runs.
private actor ShellRecorder {
    private(set) var chunks: [[UInt8]] = []
    private(set) var openCount = 0

    var sendCount: Int { chunks.count }
    var text: String { String(decoding: chunks.flatMap { $0 }, as: UTF8.self) }

    func record(_ bytes: [UInt8]) { chunks.append(bytes) }
    func noteOpen() { openCount += 1 }
}

private final class RecordingShell: RemoteShell, Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let recorder: ShellRecorder

    init(recorder: ShellRecorder) {
        self.recorder = recorder
        var escaped: AsyncThrowingStream<[UInt8], Error>.Continuation!
        output = AsyncThrowingStream { escaped = $0 }
        continuation = escaped
    }

    func send(_ bytes: [UInt8]) async throws { await recorder.record(bytes) }
    func resize(cols: Int, rows: Int) async throws {}
    func close() async { continuation.finish() }
}

/// Answers what a successful connect needs (`homeDirectoryPath()`), opens
/// recording shells, and traps on everything else — the same idiom as
/// `AlreadyOpenSessionTests.StartRecordingFileSystem`, which is `private` to
/// its own file and therefore not reachable from here.
private final class ShellingFileSystem: RemoteFileSystem, RemoteShellProvider, Sendable {
    private let shells: ShellRecorder
    /// `false` makes every `openShell` throw AFTER counting the attempt —
    /// the shape a shell-less backend's opener has in the real app
    /// (`ContentView.startSession` throws "This connection does not support a
    /// terminal."), and the shape an SSH shell channel that will not open
    /// has. Counting first is the point: the attempts are what
    /// `aShellThatWillNotOpenIsAttemptedOnceAndDropsTheSnippet` measures.
    private let opensShell: Bool
    /// Held open by `disconnect()` when set — see `DisconnectGate`'s own doc
    /// comment. `nil` for every test that has no need to observe teardown
    /// mid-flight.
    private let disconnectGate: DisconnectGate?

    init(shells: ShellRecorder, opensShell: Bool = true, disconnectGate: DisconnectGate? = nil) {
        self.shells = shells
        self.opensShell = opensShell
        self.disconnectGate = disconnectGate
    }

    func openShell(terminal: String, cols: Int, rows: Int) async throws -> any RemoteShell {
        await shells.noteOpen()
        guard opensShell else {
            throw RemoteFSError.protocolError(reason: "This connection does not support a terminal.")
        }
        return RecordingShell(recorder: shells)
    }

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

    func homeDirectoryPath() async throws -> String { "/home/snippet-after-connect" }

    func disconnect() async { await disconnectGate?.wait() }
}

/// Holds `ShellingFileSystem.disconnect()` open until the test resumes it —
/// a stored continuation, not a sleep, for the reason this project always
/// gives for synchronising on a seam instead of the clock (CLAUDE.md, "the
/// subprocess timeout test synchronises on the reader, not the clock"). It
/// is what makes `teardownDropsAnArmedSnippetBeforeTheTerminalCloses`
/// deterministic: `session.remote.disconnect()` does not return until
/// `open()` is called, so replaying the observer between the terminal
/// closing and that return lands at the exact point the fix is about,
/// every run, rather than at whatever point a race happened to reach.
private actor DisconnectGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// In-memory `SecretStore` — `macSCPAppKitTests` cannot import
/// `macSCPCoreTests`' own double (separate SwiftPM test targets), and the
/// point of passing one at all is that no test in this file can reach the
/// real Keychain.
private final class InMemorySnippetRunSecretStore: SecretStore, @unchecked Sendable {
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
