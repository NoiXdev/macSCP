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
    private func makeTab(shells: ShellRecorder?) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                guard let shells else { throw RemoteFSError.protocolError(reason: "dial refused") }
                return ShellingFileSystem(shells: shells)
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Replaces the window's own tab (which carries the real SSH connector)
    /// with one this suite controls.
    private func installControlledTab(in view: ContentView, shells: ShellRecorder?) -> SessionTab {
        let controlled = makeTab(shells: shells)
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

    /// A start that is answered by the already-open QUESTION dials nothing
    /// (see `ContentView.sidebarStart`), so a Run pressed there must leave
    /// nothing parked on the tab — a snippet waiting there would fire at
    /// whatever this tab connected to next.
    @Test func aRunAnsweredByTheAlreadyOpenQuestionArmsNothing() async throws {
        let workDir = makeTempDirectory("snippet-after-connect-asks")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let shells = ShellRecorder()
        let tab = installControlledTab(in: view, shells: shells)
        let stored = storeSession("asks", in: workDir, view: view)

        // Another tab already holds this stored session.
        let holder = makeTab(shells: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(tab.id)

        view.runSnippetAfterConnecting(snippet("echo asked"), on: stored)

        #expect(tab.pendingSnippetRun == nil, """
            the Run armed a snippet although the start only asked a question — nothing is \
            dialling, and this snippet would sit here until some later connect fired it.
            """)
        // Nothing to await: a start that asks never creates the `Task` inside
        // `connect(in:stored:)`. The settle keeps this from passing merely
        // because the check ran first.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(tab.session == nil, "the start was supposed to ask, not dial")
        #expect(await shells.sendCount == 0)
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

    init(shells: ShellRecorder) { self.shells = shells }

    func openShell(terminal: String, cols: Int, rows: Int) async throws -> any RemoteShell {
        await shells.noteOpen()
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

    func disconnect() async {}
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
