import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Starting a stored session a tab already holds asks instead of dialing
/// ("Sitzung ist schon offen", C2) — driven on a REAL `ContentView`, with a
/// connector that records every dial.
///
/// The dial is what these tests watch, not the prompt: the prompt itself is
/// `@State`, and a `ContentView` built outside a SwiftUI hierarchy drops
/// writes to those (measured in `ConnectAttemptHandoffTests`' "Isolation,
/// round 2"). The design says the same thing from the other side — that the
/// query appears in the running window and reads well is the one part no
/// test of this project can see. What IS decidable is whether a start
/// reached the user's host, and that is exactly what the two answers
/// differ in.
///
/// **Isolation.** Same three seams as `ReconnectPathTests`
/// (`sessionListViewModel:`/`secretStore:`/`managedKeyStore:`, all pointed
/// at a temporary directory and an in-memory `SecretStore`), for the reason
/// that file records: reassigning them after construction silently does not
/// take, and a mutation experiment then runs against the maintainer's real
/// session store and real Keychain. Every save name is run-unique for the
/// same reason.
///
/// **Why the tabs are built here rather than taken from the window.** The
/// tab `ContentView.init` creates carries the real SSH connector. Every tab
/// these tests leave in the strip is one of their own, built around
/// `StartRecorder`, so a start that DOES go ahead is observed instead of
/// dialed for real.
@Suite("Session already open", .timeLimit(.minutes(1)))
@MainActor
struct AlreadyOpenSessionTests {
    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func uniqueSaveName(_ label: String) -> String {
        "\(label)-\(UUID().uuidString)"
    }

    /// Same shape as `ReconnectPathTests.makeContentView`, including all
    /// three isolation seams.
    private func makeContentView(
        storeDirectory: URL
    ) -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let secrets = InMemorySecretStore()
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

    private func makeTab(recorder: StartRecorder?) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { config, _ in
                guard let recorder else { throw CancellationError() }
                await recorder.record(config)
                return StartRecordingFileSystem(recorder: recorder)
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Replaces the window's own tab with one this suite controls, so the
    /// only connector reachable from `tabsModel` is the recorder's.
    private func installControlledTab(in view: ContentView, recorder: StartRecorder) -> SessionTab {
        let controlled = makeTab(recorder: recorder)
        let original = view.tabsModel.activeTab
        view.tabsModel.addTab(controlled)
        view.tabsModel.closeTab(original.id)
        return controlled
    }

    /// `.agent` auth needs neither a typed password nor a keychain lookup
    /// to pass the form's own pre-dial validation — the same choice, for
    /// the same measured reason, as `ReconnectPathTests`.
    private func storeSession(_ label: String, in directory: URL, view: ContentView)
        -> StoredSession
    {
        let stored = StoredSession(
            name: uniqueSaveName(label), kind: .ssh,
            ssh: StoredSSHConfig(host: "example.com", username: "tim", authKind: .agent))
        try? SessionStore(directory: directory).upsert(stored)
        view.sessionListViewModel.reload()
        return stored
    }

    // MARK: - The question is asked instead of a second tab appearing

    /// The behaviour C2 exists for. Before it, this dialed and opened a
    /// second tab onto a session already on screen, without a word.
    @Test func aStartOfASessionAnotherTabHoldsDialsNothing() async {
        let workDir = makeTempDirectory("already-open-holder")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-holder", in: workDir, view: view)

        let holder = makeTab(recorder: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(starting.id)

        view.connectFromSidebar(stored)

        // Nothing to await: a start that asks never creates the `Task`
        // inside `connect(in:stored:)`. The settle keeps this from passing
        // merely because the check ran first.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.dialCount == 0, """
            the start dialed although a tab already holds this stored session — the user is \
            supposed to be asked whether to jump to that tab or open another one.
            """)
        #expect(view.tabsModel.tabs.count == 2, "asking must not open a tab of its own")
        #expect(!starting.isReconnecting, """
            the start locked the tab it would have connected in, which leaves the sidebar \
            disabled behind a query that has not been answered yet.
            """)
    }

    /// The positive half, and the reason the check above is not merely a
    /// check that nothing ever dials: with no tab holding the session, the
    /// start goes through untouched — including the rule that an
    /// unconnected active tab is reused rather than a second one opened.
    @Test func aStartOfASessionNobodyHoldsStillDials() async throws {
        let workDir = makeTempDirectory("already-open-free")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-free", in: workDir, view: view)

        view.connectFromSidebar(stored)

        try await pollUntil("a session no tab holds must still be dialed") {
            await recorder.dialCount == 1
        }
        #expect(await recorder.dialedHost == "example.com")
        #expect(view.tabsModel.tabs.map(\.id) == [starting.id], """
            the unconnected active tab must still be reused in place — C2 changes what \
            happens when a tab already HOLDS the session, and nothing else.
            """)
    }

    /// The query is raised for the tab in front too. Jumping is then a
    /// no-op — the right effect of that choice, not a reason to withhold
    /// the question, since "open another one" means exactly what it means
    /// anywhere else.
    @Test func theActiveTabHoldingTheSessionStillRaisesTheQuery() async {
        let workDir = makeTempDirectory("already-open-active")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let active = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-active", in: workDir, view: view)
        active.activeStoredSessionID = stored.id

        let request = view.sidebarStart(stored, paneVisibility: nil)

        #expect(request?.existingTabID == active.id, """
            the active tab holding the session was treated as no holder at all, so a second \
            tab onto the session already in front would open without a word.
            """)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.dialCount == 0)
    }

    /// With several holders the FIRST in tab order wins — the order the
    /// strip shows, which `TabsViewModel.move` is what changes.
    @Test func theQueryNamesTheFirstHolderInTabOrder() async {
        let workDir = makeTempDirectory("already-open-first")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-first", in: workDir, view: view)

        let firstHolder = makeTab(recorder: nil)
        firstHolder.activeStoredSessionID = stored.id
        let secondHolder = makeTab(recorder: nil)
        secondHolder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(firstHolder)
        view.tabsModel.addTab(secondHolder)
        view.tabsModel.activate(starting.id)

        #expect(view.sidebarStart(stored, paneVisibility: nil)?.existingTabID == firstHolder.id)
    }

    // MARK: - What the two answers do

    /// "Go to Existing Tab" activates the tab the query named, and touches
    /// nothing else: no tab is closed, nothing is merged, and no dial
    /// happens.
    @Test func jumpingActivatesTheTabTheQueryNamed() async {
        let workDir = makeTempDirectory("already-open-jump")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-jump", in: workDir, view: view)

        let holder = makeTab(recorder: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(starting.id)

        guard let request = view.sidebarStart(stored, paneVisibility: nil) else {
            Issue.record("the start must raise the query when a tab holds the session")
            return
        }
        view.jumpToOpenSession(request)

        #expect(view.tabsModel.activeTabID == holder.id)
        #expect(view.tabsModel.tabs.count == 2, "jumping closes nothing")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.dialCount == 0, "jumping dials nothing")
    }

    /// "Open Anyway" is today's behaviour, unchanged — the same function a
    /// start reaches when no tab holds the session, including the rule that
    /// an unconnected active tab is reused in place.
    @Test func openingAnywayStartsTheSessionAfterAll() async throws {
        let workDir = makeTempDirectory("already-open-anyway")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-anyway", in: workDir, view: view)

        let holder = makeTab(recorder: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(starting.id)

        guard let request = view.sidebarStart(stored, paneVisibility: nil) else {
            Issue.record("the start must raise the query when a tab holds the session")
            return
        }
        view.startWithoutAsking(request.stored, paneVisibility: request.paneVisibility)

        try await pollUntil("\"Open Anyway\" must actually start the session") {
            await recorder.dialCount == 1
        }
        #expect(view.tabsModel.tabs.map(\.id) == [starting.id, holder.id], """
            the unconnected active tab must still be reused in place — "open anyway" is \
            today's behaviour and nothing else.
            """)
    }

    /// The row's pane override travels through the query, so answering an
    /// "Open Terminal" still opens the terminal rather than quietly turning
    /// into a plain connect.
    @Test func theQueryCarriesTheRowsPaneOverride() {
        let workDir = makeTempDirectory("already-open-pane")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-pane", in: workDir, view: view)

        let holder = makeTab(recorder: nil)
        holder.activeStoredSessionID = stored.id
        view.tabsModel.addTab(holder)
        view.tabsModel.activate(starting.id)

        #expect(view.sidebarStart(stored, paneVisibility: .terminalOnly)?.paneVisibility
            == .terminalOnly)
        #expect(view.sidebarStart(stored, paneVisibility: nil)?.paneVisibility == nil, """
            an ordinary connect must NOT acquire a pane override on its way through the \
            query — the pair is what shows the override is carried rather than invented.
            """)
    }

    /// An ad-hoc connection to the same host is not the same session: it
    /// can carry other credentials, another key, another jump host. A tab
    /// holding none must therefore not stop a start.
    @Test func anAdHocTabDoesNotCountAsHoldingTheSession() async throws {
        let workDir = makeTempDirectory("already-open-adhoc")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (view, cleanup) = makeContentView(storeDirectory: workDir)
        defer { cleanup() }
        let recorder = StartRecorder()
        let starting = installControlledTab(in: view, recorder: recorder)
        let stored = storeSession("already-open-adhoc", in: workDir, view: view)

        let adHoc = makeTab(recorder: nil)
        adHoc.activeStoredSessionID = nil
        view.tabsModel.addTab(adHoc)
        view.tabsModel.activate(starting.id)

        view.connectFromSidebar(stored)

        try await pollUntil("an ad-hoc tab must not suppress a stored session's start") {
            await recorder.dialCount == 1
        }
    }
}

/// Records what the connector was handed, and how often — an actor so the
/// polling loops above can read it while the dial runs.
private actor StartRecorder {
    private(set) var dialCount = 0
    private(set) var dialedHost: String?

    func record(_ config: ConnectionConfig) {
        dialCount += 1
        if case .ssh(let ssh) = config { dialedHost = ssh.host }
    }
}

/// Answers only what a successful connect needs (`homeDirectoryPath()`),
/// and traps on everything else — the same idiom as
/// `ReconnectPathTests.RecordingFileSystem`, which is `private` to its own
/// file and therefore not reachable from here.
private struct StartRecordingFileSystem: RemoteFileSystem {
    let recorder: StartRecorder

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

    func homeDirectoryPath() async throws -> String { "/home/already-open-test" }

    func disconnect() async {}
}

/// In-memory `SecretStore` — `macSCPAppKitTests` cannot import
/// `macSCPCoreTests`' own double (separate SwiftPM test targets), and the
/// point of passing one at all is that no test in this file can reach the
/// real Keychain.
private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
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
