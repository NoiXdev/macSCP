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

    /// The file system is created HERE and tracked weakly, so this function's
    /// return leaves no strong reference in the caller.
    private func connectedTabWithParkedComparison(
        tracking box: WeakBox<ParkedFS>
    ) -> (SessionTab, Comparison) {
        let remote = ParkedFS()
        box.value = remote
        let tab = connectedTab(remote: remote)
        return (tab, startOverTemporaryDirectory(on: tab))
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
        let expectedRows = [
            fixtureRow(
                "a.txt", .onlyRight, leftRoot: directory.path, rightRoot: "/remote")
        ]
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

    /// Shape-independent. A dedicated CLASS file system is created inside a
    /// helper and tracked with a weak reference; the tab is torn down, the
    /// walk unwinds, and the test then asks only whether anything still holds
    /// the object — wherever and however it is held. The comparison and the
    /// tab stay alive, which is the point: the window keeps the comparison.
    /// What this cannot see is a capture inside a walk that never unwinds,
    /// which `Comparison` documents as deliberate.
    @Test func aTornDownComparisonRetainsNoFileSystemInAnyShape() async throws {
        let box = WeakBox<ParkedFS>()
        let (tab, comparison) = connectedTabWithParkedComparison(tracking: box)

        // Positive control: the object is alive and in use while attached.
        try await box.value?.waitUntilParked(count: 1)
        #expect(box.value != nil)

        await TabTeardown.run(tab, reason: .userRequested)
        try await box.value?.waitUntilCancelled(count: 1)
        await comparison.waitForWalk()

        #expect(box.value == nil, "something still holds the file system after teardown")
        // Kept alive to here, deliberately.
        #expect(comparison.isFinished)
        #expect(tab.comparisons.isEmpty)
    }

    /// The same, for a remote-to-remote comparison ("two files of one
    /// session"), where BOTH sides are remote and the left is no longer a
    /// value type a weak box cannot track. One session has one remote file
    /// system, so both sides are the same object here; the case where the two
    /// sides are different objects is the next test.
    @Test func aTornDownRemoteToRemoteComparisonRetainsNoFileSystemInAnyShape() async throws {
        let box = WeakBox<ParkedFS>()
        let remote = { () -> (SessionTab, Comparison) in
            let fs = ParkedFS()
            box.value = fs
            let tab = self.connectedTab(remote: fs)
            let comparison = tab.startComparison(
                left: .remote, leftRoot: "/a", right: .remote, rightRoot: "/b",
                algorithm: .sha256)!
            return (tab, comparison)
        }
        let (tab, comparison) = remote()

        try await box.value?.waitUntilParked(count: 1)
        #expect(box.value != nil)

        await TabTeardown.run(tab, reason: .userRequested)
        try await box.value?.waitUntilCancelled(count: 1)
        await comparison.waitForWalk()

        #expect(box.value == nil, "something still holds the file system after teardown")
        #expect(comparison.isFinished)
        #expect(tab.comparisons.isEmpty)
    }

    /// Two DISTINCT class file systems, weakly tracked on both sides. A
    /// session has one remote object, so this cannot go through a tab; it
    /// performs the two calls `SessionTab.endComparisons()` makes, in its
    /// order, on a `Comparison` built over two objects. What it adds is the
    /// LEFT side: a file system held on the left only (a spare, a wrapper, a
    /// global) is invisible to every test whose left is the local value type.
    @Test func aReleasedComparisonRetainsNeitherOfTwoDistinctFileSystems() async throws {
        let left = WeakBox<ParkedFS>()
        let right = WeakBox<ParkedFS>()
        let build = { () -> Comparison in
            let leftFS = ParkedFS()
            let rightFS = ParkedFS()
            left.value = leftFS
            right.value = rightFS
            let comparison = Comparison(
                left: leftFS, leftRoot: "/a", right: rightFS, rightRoot: "/b", algorithm: .sha256,
                transferQueue: TransferQueueViewModel())
            comparison.start()
            return comparison
        }
        let comparison = build()

        // The walk lists the left side first and parks there.
        try await left.value?.waitUntilParked(count: 1)
        #expect(left.value != nil)
        #expect(right.value != nil)

        comparison.cancel()
        comparison.releaseFileSystems()
        try await left.value?.waitUntilCancelled(count: 1)
        await comparison.waitForWalk()

        #expect(left.value == nil, "something still holds the LEFT file system")
        #expect(right.value == nil, "something still holds the RIGHT file system")
        #expect(comparison.isFinished)
    }

    /// `tab.session` stays attached through every suspension point of the
    /// teardown, so "no session" cannot be what refuses a comparison started
    /// from one. The attempt is made from inside `disconnect()`, which the
    /// teardown awaits last but one.
    @Test func aComparisonCannotBeStartedWhileTheTabIsBeingTornDown() async {
        let attempt = TeardownAttempt()
        let tab = makeTab()
        attempt.tab = tab
        attachSession(to: tab, remoteFS: ParkedFS(onDisconnect: { await attempt.tryStart() }))

        // Positive control: outside a teardown the very same call is accepted.
        let accepted = startOverTemporaryDirectory(on: tab)
        #expect(tab.comparisons.count == 1)
        accepted.cancel()
        tab.endComparisons()

        await TabTeardown.run(tab, reason: .userRequested)

        // The attempt really ran at the suspension point, with the session
        // still attached and the teardown in flight.
        #expect(attempt.ran)
        #expect(attempt.sessionWasAttached)
        #expect(attempt.sawTearingDown)
        #expect(attempt.started == nil)
        #expect(tab.comparisons.isEmpty)
        // And the counter is back to zero: a teardown that finished does not
        // leave the tab refusing for ever.
        #expect(!tab.isTearingDown)
    }

    /// `.cancelled` means somebody called `cancel()`. A `CancellationError`
    /// nobody asked for — a backend throws one too — is a failure.
    @Test func aStrayCancellationErrorIsAFailureAndNotAUserStop() async {
        let fs = ScriptedFS(listings: [:], listFailure: CancellationError())
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256,
            transferQueue: TransferQueueViewModel())

        comparison.start()
        await comparison.waitForWalk()

        #expect(fs.listedPaths.count >= 1)
        guard case .failed(let error)? = comparison.outcome else {
            Issue.record("expected .failed, got \(String(describing: comparison.outcome))")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func aCancelledComparisonStaysCancelledAndCannotBeStartedAgain() async {
        let fs = ScriptedFS(listings: ["/l": [], "/r": []])
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256,
            transferQueue: TransferQueueViewModel())

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
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256,
            transferQueue: TransferQueueViewModel())
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
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256,
            transferQueue: TransferQueueViewModel())

        comparison.start()
        await comparison.waitForWalk()

        guard case .completed? = comparison.outcome else {
            Issue.record("expected .completed, got \(String(describing: comparison.outcome))")
            return
        }
        #expect(comparison.rows == [fixtureRow("a.txt", .same, leftRoot: "/l", rightRoot: "/r")])
        #expect(comparison.progress == ComparisonProgress(directoriesVisited: 1, rowsProduced: 1))
    }

    @Test func aRootThatCannotBeListedFailsTheComparisonWithTheError() async {
        let fs = ScriptedFS(listings: [:])
        let comparison = Comparison(
            left: fs, leftRoot: "/l", right: fs, rightRoot: "/r", algorithm: .sha256,
            transferQueue: TransferQueueViewModel())

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
        // And the transfer queue, which Task 8 added beside them: exactly
        // ONE, and the very object the tab owns. A queue is a leaf for this
        // scan (below) because its own graph holds closures and, while a job
        // is retained, file systems; what is pinned is that this object
        // reaches the tab's queue and no other, not what the queue holds.
        let queues = children.compactMap { $0.value as? TransferQueueViewModel }
        #expect(queues.count == 1)
        #expect(queues.first === tab.transferQueue)
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
            if child.value is TransferQueueViewModel { continue }
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
    /// walk descends through optionals and structs — and through every other
    /// shape a stored reference can hide in: classes, arrays, sets,
    /// dictionaries, tuples and enum payloads. It stops at a file system and
    /// at a transfer queue, each a leaf here whatever it holds, and never
    /// enters one class instance twice, so a cycle cannot hang it.
    ///
    /// This is the SECOND guard against a stored connection. The first, and
    /// the one that does not depend on shape, is the weak-reference test
    /// below; this one names WHERE a stray reference sits.
    private static func storedValues(of value: Any, path: String) -> [(label: String, value: Any)] {
        var visited = Set<ObjectIdentifier>()
        return storedValues(of: value, path: path, visited: &visited)
    }

    private static func storedValues(
        of value: Any, path: String, visited: inout Set<ObjectIdentifier>
    ) -> [(label: String, value: Any)] {
        var found: [(label: String, value: Any)] = []
        let root = Mirror(reflecting: value)
        if root.displayStyle == .class {
            guard visited.insert(ObjectIdentifier(value as AnyObject)).inserted else { return [] }
        }
        var level: Mirror? = root
        while let mirror = level {
            for child in mirror.children {
                let label = path + "." + (child.label ?? "?")
                found.append((label, child.value))
                if child.value is any RemoteFileSystem { continue }
                // A leaf too, like a file system: the tab's queue is not part
                // of this object, and walking into it would count whatever
                // jobs it happens to retain as the comparison's own.
                if child.value is TransferQueueViewModel { continue }
                switch Mirror(reflecting: child.value).displayStyle {
                case .struct, .optional, .class, .collection, .set, .dictionary, .tuple, .enum:
                    found += storedValues(of: child.value, path: label, visited: &visited)
                default:
                    break
                }
            }
            level = mirror.superclassMirror
        }
        return found
    }

    private static func fileSystems(in values: [(label: String, value: Any)]) -> Int {
        values.filter { $0.value is any RemoteFileSystem }.count
    }

    /// Positive controls for `storedValues`: a file system hidden in each
    /// shape is found, exactly once, and a holder with none finds none. Each
    /// fixture is a shape that a planted spare reference once escaped (or
    /// could have). Without these the guard above could pass over a shape it
    /// cannot see, which is how it went blind to arrays and classes.
    @Test func theReflectionFindsAFileSystemInEveryShapeItCanHideIn() {
        let leaf = LocalFileSystem()
        let cyclic = Box(inner: leaf)
        cyclic.loop = cyclic

        let cases: [(String, Any, Int)] = [
            ("array", ArrayHolder(systems: [leaf]), 1),
            ("empty array", ArrayHolder(systems: []), 0),
            ("dictionary", DictionaryHolder(byName: ["a": leaf]), 1),
            ("tuple", TupleHolder(pair: (1, leaf)), 1),
            ("enum payload", EnumHolder(payload: .holds(leaf)), 1),
            ("empty enum case", EnumHolder(payload: .empty), 0),
            ("class", ClassHolder(box: Box(inner: leaf)), 1),
            ("class behind an optional struct", OptionalHolder(inner: ClassHolder(box: Box(inner: leaf))), 1),
            ("self-referencing class", ClassHolder(box: cyclic), 1),
            ("subclass", Derived(inner: leaf), 1),
        ]
        for (name, holder, expected) in cases {
            #expect(Self.fileSystems(in: Self.storedValues(of: holder, path: "h")) == expected, "\(name)")
        }
    }

    /// The queue is a leaf, found once and not entered: a holder with one
    /// yields exactly one value, so the scan reports the queue and none of the
    /// closures and jobs behind it. Without this the exemption in the guard
    /// above could be a scan that never reaches a queue at all.
    @Test func theReflectionFindsATransferQueueAndStopsThere() {
        let queue = TransferQueueViewModel()
        let values = Self.storedValues(of: QueueHolder(queue: queue), path: "h")
        #expect(values.count == 1)
        #expect(values.first?.value is TransferQueueViewModel)
        #expect(values.allSatisfy { !$0.label.hasPrefix("h.queue.") })
        #expect(Self.fileSystems(in: values) == 0)
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

@MainActor
private final class WeakBox<T: AnyObject> {
    weak var value: T?
}

/// Starts a comparison from inside a teardown-time suspension point, and
/// records what the tab looked like when it did.
@MainActor
private final class TeardownAttempt {
    var tab: SessionTab?
    private(set) var ran = false
    private(set) var sessionWasAttached = false
    private(set) var sawTearingDown = false
    private(set) var started: Comparison?

    func tryStart() {
        ran = true
        sessionWasAttached = tab?.session != nil
        sawTearingDown = tab?.isTearingDown ?? false
        started = tab?.startComparison(
            left: .local, leftRoot: NSTemporaryDirectory(),
            right: .remote, rightRoot: "/remote", algorithm: .sha256)
    }
}

// Fixtures for the reflection's positive controls: one file system hidden in
// each shape a stored reference can take.
private struct QueueHolder { var queue: TransferQueueViewModel }
private struct ArrayHolder { var systems: [any RemoteFileSystem] }
private struct DictionaryHolder { var byName: [String: any RemoteFileSystem] }
private struct TupleHolder { var pair: (Int, any RemoteFileSystem) }
private enum Payload {
    case holds(any RemoteFileSystem)
    case empty
}
private struct EnumHolder { var payload: Payload }
private class Box {
    var inner: (any RemoteFileSystem)?
    var loop: Box?
    init(inner: (any RemoteFileSystem)?) { self.inner = inner }
}
private final class Derived: Box {}
private struct ClassHolder { var box: Box }
private struct OptionalHolder { var inner: ClassHolder? }

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
    private let onDisconnect: @Sendable () async -> Void

    /// `onDisconnect` runs inside `disconnect()`, which `TabTeardown` awaits
    /// late in its sequence: a suspension point at which the tab's session is
    /// still attached.
    init(onDisconnect: @escaping @Sendable () async -> Void = {}) {
        self.onDisconnect = onDisconnect
    }

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
    func disconnect() async { await onDisconnect() }
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
    private let listFailure: (any Error)?
    private let state = Mutex(State())

    /// `listFailure` is thrown by every `list`, after the call is counted.
    init(
        listings: [String: [RemoteFileItem]],
        checksums: [String: String] = [:],
        listFailure: (any Error)? = nil,
        beforeAnsweringChecksum: @escaping @Sendable () async -> Void = {}
    ) {
        self.listings = listings
        self.checksums = checksums
        self.listFailure = listFailure
        self.beforeAnsweringChecksum = beforeAnsweringChecksum
    }

    var listedPaths: [String] { state.withLock { $0.listed } }
    var checksumCalls: Int { state.withLock { $0.checksumCalls } }

    func list(path: String) async throws -> [RemoteFileItem] {
        state.withLock { $0.listed.append(path) }
        if let listFailure { throw listFailure }
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
