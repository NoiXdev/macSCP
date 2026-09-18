import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Two tabs through one jump host, driven through the REAL sidebar start
/// (`ContentView.connectFromSidebar`) on a real `ContentView`
/// (jump-and-groups plan, Task 1).
///
/// The maintainer's report of 2026-09-18: a second session over the same
/// jump "does not open, the UI returns to the session info, and the first
/// connection drops". The first half has a cause, and
/// `anUnknownTargetKeyBehindTheJumpLeavesTheCardOnScreen` is its proof on
/// the window's own inputs: the target behind the jump is new, its host key
/// unknown, and the trust card lives in the form the overview used to cover.
/// The second half was not reproduced — the investigation's six live-rig
/// topologies all left the first connection intact — and the other three
/// cases pin that the App layer does not drop it either: no path here hands
/// a connected tab to a second dial, and nothing tears it down.
///
/// **The tab factory.** The start's tab rule makes a fresh tab when the
/// active one is connected, and in production that tab carries the real
/// connector. `ContentView.init`'s `sidebarTabFactory:` seam hands this
/// suite's own tabs to that same rule instead, so the real
/// `connectFromSidebar` → `sidebarStart` → `startWithoutAsking` path runs
/// without dialling for real. The refused-jump case passes NO factory, on
/// purpose: it is the one that proves the default is still the real
/// `makeTab()` and the real connector.
///
/// **What stands in for SwiftUI.** No view is rendered in this project's
/// tests. Two things a mounted window would do are therefore done here, and
/// nothing else is:
///
/// * the sidebar selection a double click makes — the window's `@State
///   overviewSessionID` cannot be written from a test (see
///   `ConnectAttemptHandoffTests`, "Isolation, round 2"), so the tab's own
///   `restoredSessionID`, which feeds the same `overviewSession(for:)`, is
///   set instead;
/// * `ConnectAttemptLivenessMirror`'s write, applied from
///   `ConnectAttemptLivenessPlan.write`'s real answer — and applied only
///   AFTER the surface has been read in the update before it, because that
///   lagging update is where a failure used to lose its form (fix round 1);
/// * the person dismissing the form's alert, as
///   `ConnectionViewModel.acknowledgeFailure` with the id the alert
///   carries. What the alert would say is `FormFailureAlertPlan`'s answer
///   on the same state.
///
/// **Isolation.** The same three `ContentView.init` seams as
/// `AlreadyOpenSessionTests`, pointed at a temporary directory and an
/// in-memory secret store. No real host names: every target is under
/// `.invalid`, and the refused jump is `127.0.0.1:1`, which refuses at once.
/// That case makes a real loopback TCP dial on purpose; a machine with a
/// listener on port 1 would change its verdict.
@Suite("Two tabs through one jump", .timeLimit(.minutes(1)))
@MainActor
struct JumpTwoTabsTests {
    // MARK: - Fixtures

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    private func makeContentView(
        storeDirectory: URL, sidebarTabFactory: (@MainActor () -> SessionTab)?
    ) -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let secrets = JumpTabsSecretStore()
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
            managedKeyStore: ManagedKeyStore(directory: storeDirectory),
            sidebarTabFactory: sidebarTabFactory)
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
        })
    }

    private func makeTab(_ connector: @escaping ConnectionViewModel.Connector) -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: connector),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Replaces the window's own tab — which carries the real connector —
    /// with one this suite controls, so the first session's dial is
    /// observed rather than made.
    private func installFirstTab(_ tab: SessionTab, in view: ContentView) {
        let original = view.tabsModel.activeTab
        view.tabsModel.addTab(tab)
        view.tabsModel.closeTab(original.id)
    }

    /// A session through a jump. Agent auth on both hops: neither needs a
    /// stored secret to pass the form's pre-dial validation.
    private func viaJump(
        _ label: String, target: String, jumpHost: String = "bastion.invalid", jumpPort: Int = 22
    ) -> StoredSession {
        StoredSession(
            name: "\(label)-\(UUID().uuidString)", kind: .ssh,
            ssh: StoredSSHConfig(
                host: target, username: "tim", authKind: .agent,
                jump: StoredSession.JumpSpec(
                    host: jumpHost, port: jumpPort, username: "jim", authKind: .agent)))
    }

    /// Stands in for the double click's row selection (see the suite's own
    /// doc comment): stores the session so the window's list resolves it,
    /// and points the tab at it through the per-tab feed.
    private func select(_ stored: StoredSession, on tab: SessionTab, in view: ContentView, directory: URL) throws {
        try SessionStore(directory: directory).upsert(stored)
        view.sessionListViewModel.reload()
        tab.restoredSessionID = stored.id
    }

    /// Stands in for `ConnectAttemptLivenessMirror`, from the plan's real
    /// answer. Only the three writes these cases reach are applied; any
    /// other answer is recorded rather than guessed at.
    private func mirror(_ tab: SessionTab, sourceLocation: SourceLocation = #_sourceLocation) {
        let write = ConnectAttemptLivenessPlan.write(
            for: tab.connectionViewModel.state, hasSession: tab.session != nil,
            describesLostConnection: tab.lostConnection != nil,
            failureKind: tab.connectionViewModel.lastFailureKind)
        switch write {
        case .connecting:
            tab.liveness = .connecting
            tab.connectFailure = nil
        case .failedConnect:
            tab.liveness = nil
            tab.connectFailure = ConnectFailure(
                storedSessionID: tab.connectionViewModel.attemptOrigin)
        case .clear:
            tab.liveness = nil
            tab.connectFailure = nil
        case .lost, .leaveAlone:
            Issue.record("unexpected mirror write \(write)", sourceLocation: sourceLocation)
        }
    }

    private func failed(_ tab: SessionTab) -> Bool {
        if case .failed = tab.connectionViewModel.state { return true }
        return false
    }

    // MARK: - Two sessions, one jump

    @Test func twoSessionsThroughOneJumpOpenASecondTabAndKeepTheFirst() async throws {
        let workDir = makeTempDirectory("jump-two-sessions")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let dialed = JumpDialLog()
        let fs1 = DisconnectCountingFileSystem(), fs2 = DisconnectCountingFileSystem()
        let first = makeTab { config, _ in await dialed.record(config); return fs1 }
        let second = makeTab { config, _ in await dialed.record(config); return fs2 }
        let supply = TabSupply([second])
        let (view, cleanup) = makeContentView(storeDirectory: workDir, sidebarTabFactory: { supply.next() })
        defer { cleanup() }
        installFirstTab(first, in: view)
        let a = viaJump("A", target: "a.invalid"), b = viaJump("B", target: "b.invalid")

        #expect(view.connectFromSidebar(a) == nil)
        try await pollUntil("the first tab connects") { first.isConnected }
        #expect(view.connectFromSidebar(b) == nil, "another session through the same jump is not the same session")
        try await pollUntil("the second tab connects") { second.isConnected }

        #expect(view.activeTab === second, "the sidebar start put the second session in a fresh tab")
        #expect(view.tabsModel.tabs.count == 2)
        #expect(supply.remaining == 0, "the start asked the factory for exactly one tab")
        #expect(first.isConnected)
        #expect(first.activeStoredSessionID == a.id)
        #expect(second.activeStoredSessionID == b.id)
        #expect(await fs1.disconnects == 0, "the first connection was torn down by the second start")
        #expect(await dialed.jumpHosts == ["bastion.invalid", "bastion.invalid"])
    }

    // MARK: - The same session twice

    @Test func theSameSessionTwiceAsksAndOpenAnywayKeepsTheFirst() async throws {
        let workDir = makeTempDirectory("jump-same-session")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let fs1 = DisconnectCountingFileSystem(), fs2 = DisconnectCountingFileSystem()
        let first = makeTab { _, _ in fs1 }
        let second = makeTab { _, _ in fs2 }
        let supply = TabSupply([second])
        let (view, cleanup) = makeContentView(storeDirectory: workDir, sidebarTabFactory: { supply.next() })
        defer { cleanup() }
        installFirstTab(first, in: view)
        let a = viaJump("A", target: "a.invalid")

        #expect(view.connectFromSidebar(a) == nil)
        try await pollUntil("the first tab connects") { first.isConnected }

        let request = try #require(view.connectFromSidebar(a), "the already-open question was not raised")
        #expect(request.existingTabID == first.id)
        #expect(supply.remaining == 1, "asking must not have made a tab")
        #expect(view.tabsModel.tabs.count == 1)

        // "Open Anyway" — the dialog's button calls exactly this with the
        // request's own values (`ContentView+Sheets.swift`).
        view.startWithoutAsking(
            request.stored, paneVisibility: request.paneVisibility,
            pendingSnippet: request.pendingSnippet)
        try await pollUntil("the second tab connects") { second.isConnected }

        #expect(view.activeTab === second)
        #expect(view.tabsModel.tabs.count == 2)
        #expect(first.isConnected)
        #expect(first.activeStoredSessionID == a.id)
        #expect(second.activeStoredSessionID == a.id)
        #expect(await fs1.disconnects == 0)
    }

    // MARK: - The maintainer's bug

    /// The second session's target behind the jump has never been seen, so
    /// the dial stops in the host-key decider. The detail pane must show the
    /// form that owns the trust card, not the overview of the selected row.
    @Test func anUnknownTargetKeyBehindTheJumpLeavesTheCardOnScreen() async throws {
        let workDir = makeTempDirectory("jump-unknown-key")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let fs1 = DisconnectCountingFileSystem(), fs2 = DisconnectCountingFileSystem()
        let first = makeTab { _, _ in fs1 }
        let second = makeTab { _, decider in
            let trusted = await decider(HostKeyCandidate(
                host: "b.invalid", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "AAAA"))
            guard trusted else { throw HostKeyError.rejectedByUser }
            return fs2
        }
        let supply = TabSupply([second])
        let (view, cleanup) = makeContentView(storeDirectory: workDir, sidebarTabFactory: { supply.next() })
        defer { cleanup() }
        installFirstTab(first, in: view)
        let a = viaJump("A", target: "a.invalid"), b = viaJump("B", target: "b.invalid")

        #expect(view.connectFromSidebar(a) == nil)
        try await pollUntil("the first tab connects") { first.isConnected }
        #expect(view.connectFromSidebar(b) == nil)
        #expect(view.activeTab === second)
        try await pollUntil("the second tab raises the host-key card") {
            second.connectionViewModel.hostKeyPrompt != nil
        }
        mirror(second)
        try select(b, on: second, in: view, directory: workDir)

        // Read while the question is pending — before anything answers it
        // (CLAUDE.md, "Tests that watch a defect heal").
        let selection = view.overviewSession(for: second)
        let pendingSurface = view.detailSurface(for: second)
        let pendingHost = second.connectionViewModel.hostKeyPrompt?.candidate.host
        #expect(selection == b, "the selection is in place, so the overview was a candidate")
        #expect(second.liveness == .connecting)
        #expect(pendingSurface == .form, "the overview covered the host-key card")
        #expect(pendingHost == "b.invalid")
        #expect(first.isConnected)

        second.connectionViewModel.resolveHostKeyPrompt(trust: false)
        try await pollUntil("the rejected attempt ends") { failed(second) }

        // The lagging update, read BEFORE the mirror runs (review, fix
        // round 1): the prompt is gone and the failure is written, but
        // `tab.liveness` still reads `.connecting`. Answering `.connecting`
        // here drops the form, and it comes back already failed.
        let laggingLiveness = second.liveness
        let laggingSurface = view.detailSurface(for: second)
        let form = second.connectionViewModel
        let raisedOnChange = FormFailureAlertPlan.onChange(
            to: form.state, unacknowledgedFailure: form.unacknowledgedFailure)
        let raisedOnMount = FormFailureAlertPlan.onAppear(
            state: form.state, unacknowledgedFailure: form.unacknowledgedFailure)
        #expect(laggingLiveness == .connecting, "the lag this case exists for was not reproduced")
        #expect(form.hostKeyPrompt == nil)
        #expect(form.lastFailureKind == .needsPerson)
        #expect(laggingSurface == .form, "the form is dropped for one update and returns already failed")
        #expect(raisedOnChange != nil, "the mounted form does not raise the rejection")
        #expect(raisedOnMount != nil, "a remounted form would not raise the rejection")

        mirror(second)
        #expect(view.detailSurface(for: second) == .form, "the rejection's text is on the form, under the overview")

        // Stands in for the person dismissing the alert: the overview of
        // the selected row comes back.
        let alertID = try #require(raisedOnMount?.failureID)
        form.acknowledgeFailure(alertID)
        #expect(view.detailSurface(for: second) == .overview(b))
        #expect(first.isConnected)
        #expect(await fs1.disconnects == 0)
    }

    // MARK: - A refusal before the dial

    /// A second session whose login set no longer resolves: `fillForm`
    /// refuses before anything is dialled. The new tab must show the form
    /// with the refusal's text, not the overview and not a silent form.
    @Test func aPreDialRefusalOnTheSecondTabShowsItsText() async throws {
        let workDir = makeTempDirectory("jump-predial-refusal")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let fs1 = DisconnectCountingFileSystem()
        let first = makeTab { _, _ in fs1 }
        let second = makeTab { _, _ in
            Issue.record("the dial must never be reached — the fill refuses first")
            throw CancellationError()
        }
        let supply = TabSupply([second])
        let (view, cleanup) = makeContentView(storeDirectory: workDir, sidebarTabFactory: { supply.next() })
        defer { cleanup() }
        installFirstTab(first, in: view)
        let a = viaJump("A", target: "a.invalid")
        var b = viaJump("B", target: "b.invalid")
        b.loginSetID = UUID()   // no such set in the isolated store

        #expect(view.connectFromSidebar(a) == nil)
        try await pollUntil("the first tab connects") { first.isConnected }
        #expect(view.connectFromSidebar(b) == nil)
        #expect(view.activeTab === second)
        try await pollUntil("the refusal is written") { failed(second) }
        try select(b, on: second, in: view, directory: workDir)

        // Read before the mirror, as the window would first see it.
        let form = second.connectionViewModel
        #expect(form.lastFailureKind == .needsPerson)
        #expect(view.detailSurface(for: second) == .form, "the refusal sits under the overview")
        let raised = FormFailureAlertPlan.onAppear(
            state: form.state, unacknowledgedFailure: form.unacknowledgedFailure)
        #expect(raised?.message.isEmpty == false, "the form mounts into the refusal and shows no text")
        mirror(second)
        #expect(view.detailSurface(for: second) == .form)
        #expect(first.isConnected)
        #expect(await fs1.disconnects == 0)
    }

    // MARK: - A jump that refuses

    /// No factory: the new tab is the window's own `makeTab()` with the real
    /// connector, dialling a jump at `127.0.0.1:1`.
    @Test func aRefusedJumpFailsTheNewTabVisiblyAndLeavesTheFirstAlone() async throws {
        let workDir = makeTempDirectory("jump-refused")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let fs1 = DisconnectCountingFileSystem()
        let first = makeTab { _, _ in fs1 }
        let (view, cleanup) = makeContentView(storeDirectory: workDir, sidebarTabFactory: nil)
        defer { cleanup() }
        installFirstTab(first, in: view)
        let a = viaJump("A", target: "a.invalid")
        let b = viaJump("B", target: "b.invalid", jumpHost: "127.0.0.1", jumpPort: 1)

        #expect(view.connectFromSidebar(a) == nil)
        try await pollUntil("the first tab connects") { first.isConnected }
        #expect(view.connectFromSidebar(b) == nil)
        let second = view.activeTab
        #expect(second !== first, "the second start reused the connected tab")
        #expect(view.tabsModel.tabs.count == 2)
        try await pollUntil("the refused attempt ends") { failed(second) }
        mirror(second)
        try select(b, on: second, in: view, directory: workDir)

        #expect(second.connectionViewModel.lastFailureKind == .other)
        #expect(second.connectFailure?.storedSessionID == b.id)
        #expect(view.detailSurface(for: second) == .failed)
        #expect(ConnectFailureDetailText.read(from: second.connectionViewModel.state) != nil)
        if case .failed(let message, _) = second.connectionViewModel.state {
            #expect(!message.isEmpty, "the failed surface has text to show")
        }
        #expect(first.isConnected)
        #expect(await fs1.disconnects == 0)
    }
}

// MARK: - Test doubles

/// Hands out the suite's own tabs, one per call, to the sidebar start's tab
/// rule. Running dry is a finding, not a fallback: a start that asks for a
/// second tab gets one whose dial fails at once, and the test is told.
@MainActor
private final class TabSupply {
    private var tabs: [SessionTab]

    init(_ tabs: [SessionTab]) { self.tabs = tabs }

    var remaining: Int { tabs.count }

    func next() -> SessionTab {
        guard !tabs.isEmpty else {
            Issue.record("the sidebar start asked for more tabs than this test supplied")
            return SessionTab(
                connectionViewModel: ConnectionViewModel(connector: { _, _ in throw CancellationError() }),
                certificateBridge: CertificatePromptBridge(),
                limiter: BandwidthLimiter(),
                maxConcurrent: 2)
        }
        return tabs.removeFirst()
    }
}

private actor JumpDialLog {
    private(set) var jumpHosts: [String?] = []

    func record(_ config: ConnectionConfig) {
        guard case .ssh(let ssh) = config else {
            jumpHosts.append(nil)
            return
        }
        jumpHosts.append(ssh.jump?.host)
    }
}

/// A connected file system that does nothing but count how often it was
/// disconnected — the "first connection drops" half of the report, as a
/// number.
private actor DisconnectCountingFileSystem: RemoteFileSystem {
    private(set) var disconnects = 0

    func list(path: String) async throws -> [RemoteFileItem] { [] }
    func stat(path: String) async throws -> RemoteFileItem { throw RemoteFSError.notFound(path: path) }
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {}
    func delete(path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(path: String, permissions: UInt32) async throws {}
    func deleteTree(at path: String) async throws {}
    func homeDirectoryPath() async throws -> String { "/home/tim" }
    func disconnect() async { disconnects += 1 }
}

private final class JumpTabsSecretStore: SecretStore, @unchecked Sendable {
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
