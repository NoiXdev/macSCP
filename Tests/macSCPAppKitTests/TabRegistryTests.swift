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
