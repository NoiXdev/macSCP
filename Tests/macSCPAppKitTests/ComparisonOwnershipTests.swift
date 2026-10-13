import Foundation
import MacSCPTestSupport
import Synchronization
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// The comparison model belongs to the tab whose connection it uses (diff
/// view, Task 7). What is pinned here:
///
/// 1. a comparison started on a tab is held by THAT tab and by no other;
/// 2. `TabTeardown.run` ends every comparison on the tab — including one
///    that has not had a turn on the main actor yet — and the walk really
///    stops, not only the flag;
/// 3. a cancel that arrives after the walk's last cancellation check, so the
///    walk returns normally with a complete-looking result, still ends as
///    cancelled and keeps no row that arrived after the cancel;
/// 4. the comparison stores no connection of its own, asserted by reflecting
///    over its stored properties and not by reading the call site.
///
/// The source-level half of the ownership rule (who constructs a
/// `Comparison`, and where `TabTeardown` ends it) is
/// `ComparisonOwnershipWiringGuardTests`.
///
/// No test here asserts how long anything took. A walk parked on a peer is
/// modelled by a call that waits until it is cancelled; the suite's hang
/// bound is `.timeLimit`.
@Suite("Comparison ownership", .timeLimit(.minutes(1)))
@MainActor
struct ComparisonOwnershipTests {

    // MARK: - Fixtures

    private static let digest = String(repeating: "a", count: 64)

    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// The same session shape `CrossSessionTargetsTests` builds: a tab whose
    /// remote side is `remoteFS` and whose local side is the real local file
    /// system, so a walk over a temporary directory needs no network.
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

    private func connectedTab(remote: any RemoteFileSystem) -> SessionTab {
        let tab = makeTab()
        attachSession(to: tab, remoteFS: remote)
        return tab
    }

    /// Local temporary directory against the remote root: the local `list`
    /// returns, the remote one is the call a `ParkedFS` holds.
    private func startOverTemporaryDirectory(on tab: SessionTab) -> Comparison {
        tab.startComparison(
            left: .local, leftRoot: NSTemporaryDirectory(),
            right: .remote, rightRoot: "/remote",
            algorithm: .sha256)!
    }

    // MARK: - 1. The tab holds what it started

    @Test func aComparisonStartedOnATabIsHeldByThatTabAndNoOther() async {
        let mine = connectedTab(remote: ParkedFS())
        let other = connectedTab(remote: ParkedFS())

        let comparison = startOverTemporaryDirectory(on: mine)

        #expect(mine.comparisons.count == 1)
        #expect(mine.comparisons.first === comparison)
        #expect(mine.comparison(id: comparison.id) === comparison)
        // Negative, with the positive above it: the other tab holds nothing
        // and cannot resolve this id.
        #expect(other.comparisons.isEmpty)
        #expect(other.comparison(id: comparison.id) == nil)

        Self.settle(comparison)
    }

    @Test func aTabWithoutASessionStartsNoComparison() {
        let tab = makeTab()
        let comparison = tab.startComparison(
            left: .local, leftRoot: "/", right: .remote, rightRoot: "/",
            algorithm: .sha256)
        #expect(comparison == nil)
        #expect(tab.comparisons.isEmpty)
    }

    // MARK: - 2. Teardown ends them

    @Test func teardownEndsEveryComparisonOnTheTabAndTheirWalksStop() async throws {
        let remote = ParkedFS()
        let tab = connectedTab(remote: remote)
        let first = startOverTemporaryDirectory(on: tab)
        let second = startOverTemporaryDirectory(on: tab)

        // Positive control: both walks reached the remote side and are
        // running, so what follows ends something that was alive.
        try await remote.waitUntilParked(count: 2)
        #expect(first.isRunning)
        #expect(second.isRunning)
        #expect(first.fileSystems != nil)
        #expect(second.fileSystems != nil)
        #expect(tab.comparisons.count == 2)

        await TabTeardown.run(tab, reason: .userRequested)

        #expect(tab.comparisons.isEmpty)
        for comparison in [first, second] {
            #expect(comparison.isFinished)
            #expect(!comparison.isRunning)
            #expect(comparison.fileSystems == nil)
            guard case .cancelled? = comparison.outcome else {
                Issue.record("expected .cancelled, got \(String(describing: comparison.outcome))")
                continue
            }
        }
        // The walks themselves stopped, not only the flags. Awaited BEFORE
        // the cleanup below, which would cancel them itself.
        try await remote.waitUntilCancelled(count: 2)
        #expect(remote.cancelledCalls == 2)
        // Cleanup, after every assertion above; see `settle`.
        for comparison in [first, second] { Self.settle(comparison) }
    }

    @Test func teardownEndsAComparisonThatHasNotHadATurnYet() async {
        let tab = connectedTab(remote: ParkedFS())
        let comparison = startOverTemporaryDirectory(on: tab)
        // The walk's task exists but has not run: this test occupies the main
        // actor and has not suspended since `startComparison`.
        #expect(comparison.isRunning)

        await TabTeardown.run(tab, reason: .userRequested)

        #expect(comparison.isFinished)
        #expect(tab.comparisons.isEmpty)
        Self.settle(comparison)
    }

    /// The result outlives the connection. A comparison that finished before
    /// its tab was torn down keeps its rows, its progress and its outcome —
    /// they are local data, and a window that resolved the object goes on
    /// showing them — and holds no file system afterwards, so nothing that
    /// needs the connection can be attempted on it.
    @Test func aTornDownComparisonKeepsWhatWasMeasuredAndHoldsNoFileSystem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A file only the remote side has: `.onlyRight`, which needs neither a
        // size nor a checksum.
        let remoteItem = RemoteFileItem(name: "a.txt", path: "/remote/a.txt", kind: .file, size: 3)
        let tab = connectedTab(remote: ScriptedFS(listings: ["/remote": [remoteItem]]))
        let comparison = tab.startComparison(
            left: .local, leftRoot: directory.path,
            right: .remote, rightRoot: "/remote", algorithm: .sha256)!
        await comparison.waitForWalk()

        // Positive control: there IS a result to keep, and a connection to lose.
        let expectedRows = [ComparisonRow(relativePath: "a.txt", state: .onlyRight)]
        let expectedProgress = ComparisonProgress(directoriesVisited: 1, rowsProduced: 1)
        #expect(comparison.rows == expectedRows)
        #expect(comparison.progress == expectedProgress)
        guard case .completed? = comparison.outcome else {
            Issue.record("expected .completed, got \(String(describing: comparison.outcome))")
            return
        }
        #expect(comparison.fileSystems != nil)

        await TabTeardown.run(tab, reason: .userRequested)

        #expect(tab.comparisons.isEmpty)
        #expect(comparison.rows == expectedRows)
        #expect(comparison.progress == expectedProgress)
        guard case .completed? = comparison.outcome else {
            Issue.record("teardown changed the outcome to \(String(describing: comparison.outcome))")
            return
        }
        #expect(comparison.fileSystems == nil)
        // What was compared stays readable: a window says so.
        #expect(comparison.leftRoot == directory.path)
        #expect(comparison.rightRoot == "/remote")
    }

    @Test func aCancelledComparisonStaysCancelledAndCannotBeStartedAgain() async {
        let fs = ScriptedFS(listings: ["/l": [], "/r": []])
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256)

        comparison.cancel()
        comparison.start()
        await comparison.waitForWalk()

        #expect(fs.listedPaths.isEmpty)
        guard case .cancelled? = comparison.outcome else {
            Issue.record("expected .cancelled, got \(String(describing: comparison.outcome))")
            return
        }
    }

    // MARK: - 3. A cancel the walk does not notice

    /// The walk's last cancellation check precedes the classification of the
    /// last pair; a cancel that lands inside that classification does not make
    /// `walk` throw — it returns normally, having called `onRow`. The model
    /// must not read that as a completed comparison.
    @Test func aCancelThatTheWalkNeverNoticesStillEndsAsCancelled() async {
        let item = RemoteFileItem(name: "a.txt", path: "/l/a.txt", kind: .file, size: 3)
        let holder = ComparisonHolder()
        let fs = ScriptedFS(
            listings: ["/l": [item], "/r": [item]],
            checksums: ["/l/a.txt": Self.digest, "/r/a.txt": Self.digest],
            beforeAnsweringChecksum: { await holder.cancel() })
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256)
        holder.comparison = comparison

        comparison.start()
        await comparison.waitForWalk()

        // The premise: the walk got as far as asking for a checksum, i.e. it
        // was past the check that would have thrown.
        #expect(fs.checksumCalls >= 1)
        guard case .cancelled? = comparison.outcome else {
            Issue.record("expected .cancelled, got \(String(describing: comparison.outcome))")
            return
        }
        // Nothing the walk produced after the cancel reaches the model.
        #expect(comparison.rows.isEmpty)
    }

    /// The positive control for the case above: the very same trees, with no
    /// cancel, complete and keep the row. Without it the case above would
    /// pass for a model that never completes anything.
    @Test func theSameWalkWithoutACancelCompletesAndKeepsItsRow() async {
        let item = RemoteFileItem(name: "a.txt", path: "/l/a.txt", kind: .file, size: 3)
        let fs = ScriptedFS(
            listings: ["/l": [item], "/r": [item]],
            checksums: ["/l/a.txt": Self.digest, "/r/a.txt": Self.digest])
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256)

        comparison.start()
        await comparison.waitForWalk()

        guard case .completed? = comparison.outcome else {
            Issue.record("expected .completed, got \(String(describing: comparison.outcome))")
            return
        }
        #expect(comparison.rows == [ComparisonRow(relativePath: "a.txt", state: .same)])
        #expect(comparison.progress == ComparisonProgress(directoriesVisited: 1, rowsProduced: 1))
    }

    @Test func aRootThatCannotBeListedFailsTheComparisonWithTheError() async {
        let fs = ScriptedFS(listings: [:])
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256)

        comparison.start()
        await comparison.waitForWalk()

        guard case .failed(let error)? = comparison.outcome else {
            Issue.record("expected .failed, got \(String(describing: comparison.outcome))")
            return
        }
        #expect((error as? RemoteFSError) == .notFound(path: "/l"))
    }

    // MARK: - 4. No connection of its own

    /// Reads the stored properties. A comparison may hold the two file
    /// systems it was handed — and those must be the very objects the tab's
    /// session holds — and nothing that could open or keep a connection of
    /// its own: no session, no tab, no connection model, no configuration, no
    /// closure (a connector or a factory would be one).
    @Test func aComparisonStoresNoConnectionOfItsOwn() async {
        let remote = ParkedFS()
        let tab = connectedTab(remote: remote)
        let comparison = startOverTemporaryDirectory(on: tab)
        let children = Self.storedValues(of: comparison, path: "comparison")

        // Positive: reflection sees the file systems at all. Without this the
        // negative checks below would hold for an empty mirror.
        let systems = children.compactMap { $0.value as? any RemoteFileSystem }
        #expect(systems.count == 2)
        // The local side is a stateless value type, so it has no identity to
        // compare; the remote side is the object the session holds.
        #expect(systems.contains { $0 is LocalFileSystem })
        #expect(systems.contains { ($0 as AnyObject) === (remote as AnyObject) })

        // Types, not values: a back-reference to the tab declared as
        // `SessionTab?` is `nil` here, and a nil is not a `SessionTab`.
        for child in children {
            let label = child.label
            let typeName = String(describing: type(of: child.value))
            if child.value is any RemoteFileSystem { continue }
            for forbidden in Self.forbiddenTypeNames {
                #expect(!typeName.contains(forbidden), "\(label) is a \(typeName)")
            }
            #expect(!typeName.contains("->"), "\(label) is a closure: \(typeName)")
        }

        // Positive controls for the checks themselves: the type-name scan
        // names a nil optional tab, and the closure scan names a closure.
        let nilTab: SessionTab? = nil
        let closure: @Sendable () -> Void = {}
        let scan = { (value: Any) -> Bool in
            let name = String(describing: type(of: value))
            return Self.forbiddenTypeNames.contains { name.contains($0) } || name.contains("->")
        }
        #expect(scan(nilTab as Any))
        #expect(scan(closure))
        #expect(!scan(comparison.id))
        #expect(!scan(comparison.rows))

        Self.settle(comparison)
    }

    /// Every stored value reachable from `value`, labelled by path. The file
    /// systems sit inside `Comparison.FileSystems` inside an optional, so the
    /// walk descends through optionals and structs — and stops at a file
    /// system, which is a leaf here whatever it holds.
    private static func storedValues(of value: Any, path: String) -> [(label: String, value: Any)] {
        var found: [(label: String, value: Any)] = []
        for child in Mirror(reflecting: value).children {
            let label = path + "." + (child.label ?? "?")
            found.append((label, child.value))
            if child.value is any RemoteFileSystem { continue }
            let style = Mirror(reflecting: child.value).displayStyle
            if style == .struct || style == .optional {
                found += storedValues(of: child.value, path: label)
            }
        }
        return found
    }

    /// Fragments of the type names that would mean a comparison carries a
    /// connection or the means to make one: the tab or the session (and so
    /// the connection behind them), a connection model, a configuration, a
    /// connector.
    private static let forbiddenTypeNames = [
        "SessionTab", "BrowserSession", "ConnectionViewModel", "ConnectionConfig", "Connector",
    ]

    /// Test cleanup for a walk parked on a double: cancels it from the test
    /// itself, and does NOT wait for it. The cancel is a no-op when the code
    /// under test already ended the comparison; it is there so that code
    /// which failed to do so fails at the assertions and does not leave a
    /// walk parked for an hour. Waiting is the wrong half: `waitForWalk()` is
    /// not cancellable, so the suite's `.timeLimit` could not end it — found
    /// twice, when a planted `endComparisons()` that did not cancel, and then
    /// a planted `cancel()` that did not cancel the task, each hung the suite
    /// instead of turning it red. That the walks really stopped is asserted
    /// by `ParkedFS.waitUntilCancelled`, which the time limit CAN end.
    private static func settle(_ comparison: Comparison) {
        comparison.cancel()
    }

}

// MARK: - Doubles

/// Lets a test cancel the comparison from inside a file system call, which
/// is built before the comparison exists.
@MainActor
private final class ComparisonHolder {
    var comparison: Comparison?
    func cancel() { comparison?.cancel() }
}

/// A file system whose `list` waits until its task is cancelled — a peer that
/// stopped answering — and counts how many waits were parked and cancelled.
private final class ParkedFS: RemoteFileSystem, Sendable {
    private struct State {
        var parked = 0
        var cancelled = 0
        var waiter: (satisfied: @Sendable (State) -> Bool, continuation: CheckedContinuation<Void, Never>)?
    }
    private let state = Mutex(State())

    var cancelledCalls: Int { state.withLock { $0.cancelled } }

    /// Returns once `count` calls are parked.
    func waitUntilParked(count: Int) async throws {
        try await wait { $0.parked >= count }
    }

    /// Returns once `count` parked calls have been cancelled, i.e. once the
    /// walks have actually stopped talking to this file system. Unlike
    /// reading `cancelledCalls` after a cleanup cancel, this cannot be
    /// satisfied by the cleanup: a test that reaches it with a walk nobody
    /// cancelled ends at the suite's `.timeLimit`.
    func waitUntilCancelled(count: Int) async throws {
        try await wait { $0.cancelled >= count }
    }

    /// Through `awaitResumption`, the house replacement for a bare
    /// continuation: a wait that is never satisfied is ended by the suite's
    /// `.timeLimit`, which works by cancelling the test's task, and a bare
    /// continuation would ignore that cancellation.
    private func wait(until satisfied: @escaping @Sendable (State) -> Bool) async throws {
        try await awaitResumption { (continuation: CheckedContinuation<Void, Never>) in
            let ready = self.state.withLock { s -> Bool in
                if satisfied(s) { return true }
                s.waiter = (satisfied, continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Applies a change and resumes the waiter if the state now satisfies it.
    private func change(_ mutate: (inout State) -> Void) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            mutate(&s)
            guard let waiter = s.waiter, waiter.satisfied(s) else { return nil }
            s.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        change { $0.parked += 1 }
        do {
            // Ends only by cancellation: no test lets this elapse, and a test
            // that failed to cancel is stopped by the suite's `.timeLimit`.
            try await Task.sleep(for: .seconds(3600))
        } catch {
            change { $0.cancelled += 1 }
            throw error
        }
        return []
    }

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
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}

/// Answers `list` and checksums from tables and counts both. A directory that
/// is not in `listings` throws `notFound`.
private final class ScriptedFS: RemoteFileSystem, RemoteChecksumProvider, Sendable {
    private struct State {
        var listed: [String] = []
        var checksumCalls = 0
    }
    private let listings: [String: [RemoteFileItem]]
    private let checksums: [String: String]
    private let beforeAnsweringChecksum: @Sendable () async -> Void
    private let state = Mutex(State())

    init(
        listings: [String: [RemoteFileItem]],
        checksums: [String: String] = [:],
        beforeAnsweringChecksum: @escaping @Sendable () async -> Void = {}
    ) {
        self.listings = listings
        self.checksums = checksums
        self.beforeAnsweringChecksum = beforeAnsweringChecksum
    }

    var listedPaths: [String] { state.withLock { $0.listed } }
    var checksumCalls: Int { state.withLock { $0.checksumCalls } }

    func list(path: String) async throws -> [RemoteFileItem] {
        state.withLock { $0.listed.append(path) }
        guard let items = listings[path] else { throw RemoteFSError.notFound(path: path) }
        return items.map {
            RemoteFileItem(
                name: $0.name, path: RemotePath.join(path, $0.name), kind: $0.kind, size: $0.size)
        }
    }

    func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        state.withLock { $0.checksumCalls += 1 }
        await beforeAnsweringChecksum()
        guard let hex = checksums[path],
            let value = FileChecksum.computedOnRemote(algorithm, hex: hex)
        else { return .unavailableOnThisConnection }
        return .checksum(value)
    }

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
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}
}
