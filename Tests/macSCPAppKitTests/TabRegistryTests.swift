import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// A `RemoteFileSystem` that answers only what `disconnect()` needs and
/// counts how many times it was called — the one teardown step in
/// `ContentView.teardown`'s sequence (`cancelAll` → `shutdown` →
/// `disconnect`) that sits on a protocol seam a test can substitute.
/// Everything else traps, the same idiom as `ReconnectPathTests
/// .RecordingFileSystem` and `LivenessProbeRaceTests.NeverRespondingFileSystem`
/// — a future change routing through one of them fails loudly instead of
/// passing silently.
private final class DisconnectCountingFileSystem: RemoteFileSystem, @unchecked Sendable {
    private(set) var disconnectCount = 0

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
    func homeDirectoryPath() async throws -> String { "/home/tab-registry-test" }

    func disconnect() async { disconnectCount += 1 }
}

@Suite("TabRegistry")
@MainActor
struct TabRegistryTests {

    // MARK: - Fixtures
    //
    // Same shape `SessionTabTests.makeTab()`/`attachSession(to:)` build:
    // a tab whose collaborators never actually connect, so these tests
    // exercise the registry's bookkeeping without touching the network.

    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Attaches a session built on `remoteFS` — the caller's choice, so a
    /// test can hand in a `DisconnectCountingFileSystem` and read its count
    /// back later.
    private func attachSession(to tab: SessionTab, remoteFS: any RemoteFileSystem) {
        let sessionID = UUID()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remoteFS,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remoteFS, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
    }

    // MARK: - Basic lookups

    @Test func aRegisteredTabIsFoundByIDAndReportsItsWindow() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        registry.register(tab, in: window)

        #expect(registry.tab(for: tab.id) === tab)
        #expect(registry.windowHolding(tab.id) == window)
        #expect(registry.tabs(in: window).map(\.id) == [tab.id])
    }

    @Test func anUnregisteredIDIsFoundNowhere() {
        let registry = TabRegistry()
        #expect(registry.tab(for: UUID()) == nil)
        #expect(registry.windowHolding(UUID()) == nil)
    }

    @Test func windowCountCountsWindowsThatCurrentlyHoldATab() {
        let registry = TabRegistry()
        #expect(registry.windowCount == 0)
        let windowA = WindowID()
        let windowB = WindowID()
        registry.register(makeTab(), in: windowA)
        #expect(registry.windowCount == 1)
        registry.register(makeTab(), in: windowB)
        #expect(registry.windowCount == 2)
    }

    // MARK: - Moving a tab between two models through the registry

    /// The property the whole task exists for: moving a tab through the
    /// registry's convenience reassigns ownership AND updates both
    /// `TabsViewModel`s, without recreating the tab. Same object identity,
    /// same `BrowserSession.id`, the source no longer lists it, the target
    /// does, and the registry now reports the target window.
    @Test func movingATabReassignsOwnershipWithoutRecreatingIt() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()

        let stayingBehind = makeTab()
        let moving = makeTab()
        attachSession(to: moving, remoteFS: DisconnectCountingFileSystem())
        let movedSessionID = moving.session?.id

        let source = TabsViewModel(initial: stayingBehind)
        source.addTab(moving)
        let target = TabsViewModel(initial: makeTab())

        registry.register(stayingBehind, in: windowA)
        registry.register(moving, in: windowA)
        registry.register(target.activeTab, in: windowB)

        registry.move(moving.id, from: source, to: target, targetWindow: windowB)

        #expect(source.tabs.map(\.id) == [stayingBehind.id], "the source model still lists the moved tab")
        #expect(target.tabs.map(\.id).contains(moving.id), "the target model never received the moved tab")
        #expect(target.tabs.last === moving, "the target holds a different object than the one that moved")
        #expect(moving.session?.id == movedSessionID, "the moved tab's session identity changed")
        #expect(registry.windowHolding(moving.id) == windowB, "the registry still reports the old window")
    }

    /// A drag from a source that no longer holds the tab (already moved, or
    /// a stale drop) touches neither model nor the registry.
    @Test func movingATabTheSourceDoesNotHoldIsANoOp() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let onlyTab = makeTab()
        let elsewhere = makeTab()
        let source = TabsViewModel(initial: onlyTab)
        let target = TabsViewModel(initial: elsewhere)
        registry.register(onlyTab, in: windowA)
        registry.register(elsewhere, in: windowB)

        registry.move(UUID(), from: source, to: target, targetWindow: windowB)

        #expect(source.tabs.map(\.id) == [onlyTab.id])
        #expect(target.tabs.map(\.id) == [elsewhere.id])
    }

    /// `pendingSnippetRun` is arbitrary tab state that has nothing to do
    /// with the registry — it survives a move only because the move never
    /// recreates the tab. Set before, read after, same object.
    @Test func aMovedTabKeepsItsPendingSnippetRun() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let armed = SessionTab.PendingSnippetRun(
            snippet: Snippet(name: "uptime", command: "uptime"),
            storedSessionID: UUID())

        let moving = makeTab()
        moving.pendingSnippetRun = armed
        let source = TabsViewModel(initial: moving)
        let target = TabsViewModel(initial: makeTab())
        registry.register(moving, in: windowA)
        registry.register(target.activeTab, in: windowB)

        registry.move(moving.id, from: source, to: target, targetWindow: windowB)

        #expect(target.tabs.last === moving)
        #expect(target.tabs.last?.pendingSnippetRun == armed)
    }

    // MARK: - A move never touches the connection (Global Constraints)

    /// `disconnect()` sits on a protocol seam (`RemoteFileSystem`), so this
    /// is the one step of the teardown sequence a double can directly
    /// count: zero calls after a move.
    @Test func movingATabNeverDisconnectsItsSession() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let fs = DisconnectCountingFileSystem()
        let moving = makeTab()
        attachSession(to: moving, remoteFS: fs)
        let source = TabsViewModel(initial: moving)
        let target = TabsViewModel(initial: makeTab())
        registry.register(moving, in: windowA)
        registry.register(target.activeTab, in: windowB)

        registry.move(moving.id, from: source, to: target, targetWindow: windowB)

        #expect(fs.disconnectCount == 0)
    }

    /// The positive half of the check above: the counter is not dead code.
    /// Calling `disconnect()` directly — nothing to do with the registry —
    /// moves the count from 0 to 1, so the zero the previous test reads is
    /// evidence a move skipped the call, not evidence the double is inert.
    @Test func theDisconnectCounterCountsARealCall() async {
        let fs = DisconnectCountingFileSystem()
        #expect(fs.disconnectCount == 0)
        await fs.disconnect()
        #expect(fs.disconnectCount == 1)
    }

    /// `terminal.shutdown()` unconditionally forces `isVisible` to `false`
    /// (`TerminalPanelViewModel.shutdown()`), so a terminal set visible
    /// before the move that is STILL visible afterwards is evidence
    /// `shutdown()` was never called — without needing a shell to actually
    /// open, since `isVisible` is a plain, directly settable property.
    @Test func movingATabNeverShutsDownItsTerminal() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let moving = makeTab()
        attachSession(to: moving, remoteFS: DisconnectCountingFileSystem())
        moving.session?.terminal.isVisible = true
        let source = TabsViewModel(initial: moving)
        let target = TabsViewModel(initial: makeTab())
        registry.register(moving, in: windowA)
        registry.register(target.activeTab, in: windowB)

        registry.move(moving.id, from: source, to: target, targetWindow: windowB)

        #expect(moving.session?.terminal.isVisible == true, "the terminal was shut down by the move")
    }

    /// The positive half of the terminal check: `shutdown()` really does
    /// clear `isVisible` unconditionally, so the previous test's "still
    /// true" is sensitive to a `shutdown()` call sneaking into a move, not
    /// a check that could never fail.
    @Test func shutdownReallyClearsIsVisible() async {
        let terminal = TerminalPanelViewModel(openShell: { _, _, _ in throw CancellationError() })
        terminal.isVisible = true
        await terminal.shutdown()
        #expect(terminal.isVisible == false)
    }

    // MARK: - Releasing a window's tabs

    @Test func releasingAWindowsTabsForgetsOnlyItsOwn() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let a1 = makeTab()
        let a2 = makeTab()
        let b1 = makeTab()
        registry.register(a1, in: windowA)
        registry.register(a2, in: windowA)
        registry.register(b1, in: windowB)

        registry.release([a1.id, a2.id], from: windowA)

        #expect(registry.tab(for: a1.id) == nil)
        #expect(registry.tab(for: a2.id) == nil)
        #expect(registry.tab(for: b1.id) === b1, "release touched a tab belonging to a different window")
        #expect(registry.windowHolding(b1.id) == windowB)
        #expect(registry.windowCount == 1)
    }

    /// Releasing an id `window` does not currently hold — because it was
    /// already moved elsewhere — leaves that tab exactly where it is now.
    @Test func releasingATabTheWindowNoLongerHoldsIsANoOp() {
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let moved = makeTab()
        registry.register(moved, in: windowA)
        registry.move(moved.id, to: windowB)

        registry.release([moved.id], from: windowA)

        #expect(registry.tab(for: moved.id) === moved)
        #expect(registry.windowHolding(moved.id) == windowB)
    }
}

/// A `SecretStore` for the session lists below, which never reach a secret at
/// all: their sessions are written straight into the store file and read back
/// by `reload()`, and nothing here connects. Every call traps, the same idiom
/// `DisconnectCountingFileSystem` above follows — a change that started
/// reading a secret on this path would fail loudly rather than pass.
private final class UnreachedSecretStore: SecretStore, @unchecked Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws {
        fatalError("not exercised by this test")
    }
    func password(for sessionID: UUID) throws -> String? {
        fatalError("not exercised by this test")
    }
    func deletePassword(for sessionID: UUID) throws {
        fatalError("not exercised by this test")
    }
}

/// The terminal type of a tab reads the session list of the window that holds
/// it NOW (plan of 2026-09-24, Task 6), not the one it was built in.
///
/// The resolution itself is pure and belongs to Core
/// (`TerminalType.resolved(sessionOverride:global:)`, exercised by
/// `TerminalTypeTests`); what is under test here is the LOOKUP that feeds it —
/// `windowHolding(_:)` into the registry's per-window session list. These
/// tests compose the two exactly as `ContentView`'s `terminalType:` closure
/// does, which `TerminalTypeWiringGuardTests` pins on the source side.
///
/// `TabRegistry()` instances of their own, never `.shared` — the rule that
/// type's own doc comment states.
@Suite("A tab's terminal type follows the tab", .timeLimit(.minutes(1)))
@MainActor
struct TerminalTypeWindowScopeTests {

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-type-window-scope-\(UUID().uuidString)")
    }

    /// A session list holding one session, `id`, whose SSH block carries
    /// `override`. Written through the store and read back by the view
    /// model's own `reload()`, since `sessions` is `private(set)`.
    private static func makeSessionList(
        in directory: URL, session id: UUID, override: TerminalType?
    ) throws -> SessionListViewModel {
        let store = SessionStore(directory: directory)
        var session = StoredSession(id: id, name: "scoped", kind: .ssh)
        session.ssh = StoredSSHConfig(host: "example.invalid", username: "tester")
        session.ssh?.terminalType = override
        try store.upsert(session)
        return SessionListViewModel(
            store: store,
            secrets: UnreachedSecretStore(),
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
    }

    private func makeTab(connectedTo storedSessionID: UUID?) -> SessionTab {
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
        tab.activeStoredSessionID = storedSessionID
        return tab
    }

    /// The composition `ContentView`'s `terminalType:` closure performs when
    /// a shell opens, spelled once here.
    private func resolved(
        for tab: SessionTab, in registry: TabRegistry, global: TerminalType?
    ) -> TerminalType {
        TerminalType.resolved(
            sessionOverride: TerminalType.sessionOverride(
                of: tab.activeStoredSessionID,
                in: registry.sessionsOfWindowHolding(tab.id)),
            global: global)
    }

    /// The property the task exists for: the SAME stored session carries a
    /// different override in each window's list, and the tab reads the list
    /// of the window holding it — before and after a move.
    @Test func aTabReadsTheOverrideStoredInTheWindowThatHoldsItNow() throws {
        let directoryA = Self.makeDirectory()
        let directoryB = Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directoryA)
            try? FileManager.default.removeItem(at: directoryB)
        }
        let registry = TabRegistry()
        let windowA = WindowID()
        let windowB = WindowID()
        let storedSessionID = UUID()
        let listA = try Self.makeSessionList(
            in: directoryA, session: storedSessionID, override: .vt100)
        let listB = try Self.makeSessionList(
            in: directoryB, session: storedSessionID, override: .xterm)
        registry.registerSessionList(listA, for: windowA)
        registry.registerSessionList(listB, for: windowB)

        let tab = makeTab(connectedTo: storedSessionID)
        registry.register(tab, in: windowB)

        #expect(resolved(for: tab, in: registry, global: .xterm256Color) == .xterm)

        registry.move(tab.id, to: windowA)

        #expect(resolved(for: tab, in: registry, global: .xterm256Color) == .vt100)
    }

    /// A tab whose window is no longer registered — it closed — falls back to
    /// the global setting.
    ///
    /// **Another window stays registered throughout**, carrying an override
    /// of its own for the same stored session: a lookup that answered with
    /// SOME window's list rather than the tab's own would resolve to that
    /// one, and this test would read `.vt100` where it asserts the global
    /// `.xterm`.
    @Test func aTabWhoseWindowIsNoLongerRegisteredResolvesTheGlobalSetting() throws {
        let directory = Self.makeDirectory()
        let otherDirectory = Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let registry = TabRegistry()
        let window = WindowID()
        let otherWindow = WindowID()
        let storedSessionID = UUID()
        let other = try Self.makeSessionList(
            in: otherDirectory, session: storedSessionID, override: .vt100)
        registry.registerSessionList(other, for: otherWindow)
        let list = try Self.makeSessionList(
            in: directory, session: storedSessionID, override: .xterm)
        registry.registerSessionList(list, for: window)
        let tab = makeTab(connectedTo: storedSessionID)
        registry.register(tab, in: window)
        #expect(resolved(for: tab, in: registry, global: .xterm256Color) == .xterm)

        registry.unregisterSessionList(for: window)

        #expect(registry.sessionsOfWindowHolding(tab.id).isEmpty)
        #expect(registry.sessionList(for: otherWindow) === other, """
            the other window's list went away too — the check below would \
            then pass for the wrong reason.
            """)
        #expect(resolved(for: tab, in: registry, global: .xterm) == .xterm)
    }

    /// A tab the registry holds in no window at all — parked for a window
    /// that has not appeared yet — reads no list either.
    @Test func aTabInNoWindowResolvesTheGlobalSetting() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = TabRegistry()
        let window = WindowID()
        let storedSessionID = UUID()
        let list = try Self.makeSessionList(
            in: directory, session: storedSessionID, override: .vt100)
        registry.registerSessionList(list, for: window)
        let tab = makeTab(connectedTo: storedSessionID)

        #expect(registry.windowHolding(tab.id) == nil)
        #expect(registry.sessionsOfWindowHolding(tab.id).isEmpty)
        #expect(resolved(for: tab, in: registry, global: .xterm) == .xterm)
    }

    /// The per-window accessor keeps `registerSessionList(_:for:)`'s weak
    /// semantics: a window whose model went away without unregistering is not
    /// resurrected, and its stale slot is dropped rather than left to answer
    /// `nil` forever — the same rule `allSessionLists()` follows, which is why
    /// the drop is read back through that one here.
    ///
    /// The model's lifetime is a SCOPE, not an `= nil`, for the reason
    /// `SessionListRegistrationTests
    /// .aSessionListThatWentAwayIsDroppedRatherThanReloaded` records.
    @Test func aSessionListThatWentAwayIsNotHandedBackByTheWindowLookup() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = TabRegistry()
        let window = WindowID()
        let storedSessionID = UUID()
        let tab = makeTab(connectedTo: storedSessionID)
        registry.register(tab, in: window)

        do {
            let list = try Self.makeSessionList(
                in: directory, session: storedSessionID, override: .vt100)
            registry.registerSessionList(list, for: window)
            #expect(registry.sessionList(for: window) === list)
            #expect(resolved(for: tab, in: registry, global: .xterm) == .vt100)
        }

        #expect(registry.sessionList(for: window) == nil)
        #expect(registry.sessionsOfWindowHolding(tab.id).isEmpty)
        #expect(registry.allSessionLists().isEmpty)
        #expect(resolved(for: tab, in: registry, global: .xterm) == .xterm)
    }
}
