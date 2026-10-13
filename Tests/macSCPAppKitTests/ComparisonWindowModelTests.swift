import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// What the comparison window does with the object its seed names (diff view,
/// Task 9). The source-level half — the scene, the registry lookup, nothing
/// stored that is a connection — is `ComparisonWindowWiringGuardTests`.
///
/// Pinned here:
///
/// 1. the window resolves the comparison ONCE and holds it: after the tab's
///    teardown has removed it from `tab.comparisons`, the window still has
///    it, with its rows, progress and outcome;
/// 2. "session closed" is the comparison having let go of its file systems,
///    not a lookup that failed — and a lookup that failed is a different
///    state (`isUnavailable`), which has nothing to show;
/// 3. a window that closes while its tab stays open cancels the walk and
///    releases the comparison's file systems, touches no other comparison of
///    that tab, and leaves the tab's session alone.
///
/// Both sides are the real local file system over temporary directories, so
/// a walk finishes without a network. No test asserts how long anything took;
/// the suite's hang bound is `.timeLimit`.
@Suite("Comparison window model", .timeLimit(.minutes(1)))
@MainActor
struct ComparisonWindowModelTests {

    // MARK: - Fixtures

    private func makeTab() -> SessionTab {
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
        let sessionID = UUID()
        let remote = LocalFileSystem()
        tab.session = BrowserSession(
            id: sessionID,
            localFS: LocalFileSystem(),
            remoteFS: remote,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: remote, startPath: "/"),
            terminal: TerminalPanelViewModel(openShell: { _, _, _ in
                throw CancellationError()
            }),
            editManager: EditSessionManager(sessionID: sessionID, queue: tab.transferQueue),
            homePath: "/")
        return tab
    }

    /// Two temporary directories, the left holding one file the right lacks:
    /// the walk's result is exactly one `.onlyLeft` row.
    private func makeDirectories() throws -> (left: URL, right: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonWindowModelTests-\(UUID().uuidString)")
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: left.appendingPathComponent("only.txt"))
        return (left, right)
    }

    private func startComparison(on tab: SessionTab) throws -> Comparison {
        let directories = try makeDirectories()
        return try #require(
            tab.startComparison(
                left: .local, leftRoot: directories.left.path,
                right: .local, rightRoot: directories.right.path,
                algorithm: .sha256))
    }

    private func register(_ tab: SessionTab) -> TabRegistry {
        let registry = TabRegistry()
        registry.register(tab, in: WindowID())
        return registry
    }

    private func seed(_ tab: SessionTab, _ comparison: Comparison) -> ComparisonSeed {
        ComparisonSeed(tabID: tab.id, comparisonID: comparison.id)
    }

    // MARK: - The seed

    @Test func aSeedIsTwoIdentifiersAndEqualSeedsAreEqual() throws {
        let seed = ComparisonSeed(tabID: UUID(), comparisonID: UUID())
        let again = ComparisonSeed(tabID: seed.tabID, comparisonID: seed.comparisonID)
        // One window per comparison: an equal seed raises the open window
        // rather than opening a second one over the same object.
        #expect(seed == again)
        #expect(seed != ComparisonSeed(tabID: seed.tabID, comparisonID: UUID()))
        #expect(seed != ComparisonSeed(tabID: UUID(), comparisonID: seed.comparisonID))

        let decoded = try JSONDecoder().decode(
            ComparisonSeed.self, from: JSONEncoder().encode(seed))
        #expect(decoded == seed)
    }

    // MARK: - Resolving once

    @Test func theWindowHoldsTheComparisonAfterTheTabHasForgottenIt() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        await comparison.waitForWalk()
        let model = ComparisonWindowModel()
        #expect(!model.hasResolved)
        #expect(model.comparison == nil)

        model.resolve(seed: seed(tab, comparison), registry: registry)

        // Positive control: it resolved to the tab's own object.
        #expect(model.hasResolved)
        #expect(model.comparison === comparison)
        #expect(tab.comparison(id: comparison.id) === comparison)

        // Teardown removes it from the tab. A window that looked it up again
        // would now find nothing.
        tab.endComparisons()
        #expect(tab.comparison(id: comparison.id) == nil)
        #expect(registry.tab(for: tab.id) === tab)

        model.resolve(seed: seed(tab, comparison), registry: registry)
        #expect(model.comparison === comparison)
        #expect(!model.isUnavailable)
        // And what was measured is still readable through it.
        #expect(model.comparison?.rows == [ComparisonRow(relativePath: "only.txt", state: .onlyLeft)])
        guard case .completed? = model.comparison?.outcome else {
            Issue.record("expected .completed, got \(String(describing: model.comparison?.outcome))")
            return
        }
    }

    @Test func aSecondResolveDoesNotReplaceWhatTheWindowHolds() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let first = try startComparison(on: tab)
        let second = try startComparison(on: tab)
        let model = ComparisonWindowModel()

        model.resolve(seed: seed(tab, first), registry: registry)
        // A different seed, as if the view had been handed another value:
        // the latch holds, because a window is for one comparison.
        model.resolve(seed: seed(tab, second), registry: registry)

        #expect(model.comparison === first)
        first.cancel()
        second.cancel()
    }

    // MARK: - Unavailable is not the same as closed

    @Test func aSeedWhoseTabTheRegistryNoLongerKnowsIsUnavailable() throws {
        let model = ComparisonWindowModel()
        model.resolve(
            seed: ComparisonSeed(tabID: UUID(), comparisonID: UUID()), registry: TabRegistry())

        #expect(model.hasResolved)
        #expect(model.isUnavailable)
        #expect(model.comparison == nil)
        // Nothing was held, so "the held comparison lost its session" is not
        // what this is.
        #expect(!model.isSessionClosed)
    }

    @Test func aSeedWhoseComparisonTheTabNoLongerListsIsUnavailable() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        await comparison.waitForWalk()
        let wanted = seed(tab, comparison)
        tab.endComparisons()

        let model = ComparisonWindowModel()
        model.resolve(seed: wanted, registry: registry)

        #expect(model.isUnavailable)
        #expect(model.comparison == nil)
    }

    // MARK: - Session closed

    @Test func sessionClosedIsTheComparisonHavingLetGoOfItsFileSystems() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        await comparison.waitForWalk()
        let model = ComparisonWindowModel()
        model.resolve(seed: seed(tab, comparison), registry: registry)

        // Positive control: a held comparison with its connection is not
        // "closed", and not "unavailable" either.
        #expect(comparison.fileSystems != nil)
        #expect(!model.isSessionClosed)
        #expect(!model.isUnavailable)

        tab.endComparisons()

        #expect(model.isSessionClosed)
        // The comparison is still held, so it is not the other state.
        #expect(!model.isUnavailable)
        #expect(model.comparison === comparison)
    }

    @Test func theTabsTeardownLeavesTheHeldComparisonFinishedNeverUnfinishedAndDisconnected() async throws {
        // Constraint 3 of the task, as an observation rather than a design:
        // after the tab's teardown no held comparison is both unfinished and
        // without file systems, because the cancel runs before the release.
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        let model = ComparisonWindowModel()
        model.resolve(seed: seed(tab, comparison), registry: registry)
        #expect(comparison.isRunning)

        await TabTeardown.run(tab, reason: .userRequested)

        #expect(model.isSessionClosed)
        #expect(comparison.isFinished)
    }

    // MARK: - Closing the window

    @Test func closingTheWindowCancelsAndReleasesAndTheTabStaysOpen() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        let model = ComparisonWindowModel()
        model.resolve(seed: seed(tab, comparison), registry: registry)
        // Positive control: running, with its connection, tab connected.
        #expect(comparison.isRunning)
        #expect(comparison.fileSystems != nil)
        #expect(tab.session != nil)

        model.windowClosed()

        #expect(comparison.fileSystems == nil)
        #expect(comparison.transferQueue == nil)
        #expect(comparison.isFinished)
        guard case .cancelled? = comparison.outcome else {
            Issue.record("expected .cancelled, got \(String(describing: comparison.outcome))")
            return
        }
        // The tab is not the window's to close.
        #expect(tab.session != nil)
        await comparison.waitForWalk()
    }

    @Test func closingTheWindowOfAFinishedComparisonKeepsItsOutcome() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        await comparison.waitForWalk()
        let model = ComparisonWindowModel()
        model.resolve(seed: seed(tab, comparison), registry: registry)

        model.windowClosed()

        #expect(comparison.fileSystems == nil)
        guard case .completed? = comparison.outcome else {
            Issue.record("a close turned the outcome into \(String(describing: comparison.outcome))")
            return
        }
        #expect(comparison.rows.count == 1)
    }

    @Test func closingOneWindowReleasesOnlyItsOwnComparison() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let mine = try startComparison(on: tab)
        let other = try startComparison(on: tab)
        await mine.waitForWalk()
        await other.waitForWalk()
        let model = ComparisonWindowModel()
        model.resolve(seed: seed(tab, mine), registry: registry)

        model.windowClosed()

        #expect(mine.fileSystems == nil)
        // Negative, with the positive above it.
        #expect(other.fileSystems != nil)
        #expect(tab.comparison(id: other.id) === other)
        other.cancel()
    }

    @Test func closingAWindowThatHeldNothingDoesNothing() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        await comparison.waitForWalk()

        // Never resolved.
        ComparisonWindowModel().windowClosed()
        // Resolved to nothing.
        let unavailable = ComparisonWindowModel()
        unavailable.resolve(
            seed: ComparisonSeed(tabID: tab.id, comparisonID: UUID()), registry: registry)
        unavailable.windowClosed()

        #expect(comparison.fileSystems != nil)
    }

    @Test func closingTwiceIsHarmless() async throws {
        let tab = makeTab()
        let registry = register(tab)
        let comparison = try startComparison(on: tab)
        await comparison.waitForWalk()
        let model = ComparisonWindowModel()
        model.resolve(seed: seed(tab, comparison), registry: registry)

        model.windowClosed()
        model.windowClosed()

        #expect(comparison.fileSystems == nil)
        #expect(model.comparison === comparison)
    }
}
