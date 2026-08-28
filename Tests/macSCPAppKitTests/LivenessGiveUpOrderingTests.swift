import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Proves the property no source-text scan can: that
/// `ContentView.handleLivenessGiveUp(_:)` — the real function
/// `LivenessProbeRunner`'s `.giveUp` case calls, not a reimplementation of
/// it — actually leaves a tab `.lost` after tearing its session down, not
/// merely that its source SPELLS "teardown" and "`.lost`" somewhere inside
/// it. A prior round's guard checked exactly that spelling; a reviewer
/// swapped the function's two statements and it still passed, because a
/// scan cannot see which one ran first. This drives the REAL
/// `ContentView.teardown(_:)` end to end (bridge dismiss, queue
/// `cancelAll`, edit-manager `stopAll`, terminal `shutdown`, remote
/// `disconnect`, all the way down) through the actual give-up entry point,
/// the same shape a prior round's reviewer used to catch the original
/// ordering bug.
///
/// Isolation (connection-liveness plan, Task 6 fix round 2, review item 3):
/// `makeContentView()` below constructs a real `ContentView`, the same
/// shape `ConnectAttemptHandoffTests` uses — see that file's own top-level
/// doc comment for the incident that made this suite's own isolation worth
/// checking rather than assumed. Reading `teardown(_:)`'s full body (the
/// only thing `handleLivenessGiveUp(_:)` calls beyond a plain property
/// write) shows it never touches `sessionListViewModel` or any
/// `SecretStore` — this suite's own path genuinely does not reach the real
/// Keychain or the real session store today. It is still built with the
/// SAME temp-directory/in-memory-secrets seam `ConnectAttemptHandoffTests`
/// uses — `ContentView.init`'s `sessionListViewModel:`, `secretStore:` and
/// `managedKeyStore:` parameters, the whole seam rather than the part this
/// suite's own path needs (whole-branch final review, finding M-2: passing
/// only some of them left this `ContentView` holding a real
/// `KeychainSecretStore` and the real Application Support directory, inert
/// only for as long as nothing here called a function that reads them) —
/// and `theRealSessionsFileIsNeverTouched` proves it empirically rather
/// than resting on "the code doesn't call it today" — the property that
/// matters is that a FUTURE change to `teardown(_:)` cannot silently start
/// writing to a developer's real data through this suite without the proof
/// below catching it, not that today's code happens not to.
@Suite("Liveness give-up ordering")
@MainActor
struct LivenessGiveUpOrderingTests {
    private static var realSessionsFileURL: URL {
        SessionStore.defaultDirectory.appendingPathComponent("sessions-v2.json")
    }

    /// Read as raw bytes, not parsed — see `ConnectAttemptHandoffTests
    /// .snapshotRealSessionsFile()` for why a byte-for-byte comparison
    /// (including "the file does not exist, in both snapshots") is the
    /// right shape here.
    private func snapshotRealSessionsFile() -> Data? {
        try? Data(contentsOf: Self.realSessionsFileURL)
    }

    private func makeTempDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-\(label)-\(UUID().uuidString)")
    }

    /// The same minimal, `ContentView.init`-shaped fixture a window would
    /// hand it — no live window or rendering involved; `body` is never
    /// called, only the plain `handleLivenessGiveUp(_:)` method. Isolated
    /// through every seam `ContentView.init` offers, even though this
    /// suite's own call path reaches none of them — see this file's own
    /// top-level doc comment.
    private func makeContentView() -> (view: ContentView, cleanup: () -> Void) {
        let settingsDir = makeTempDirectory("settings")
        let auditDir = makeTempDirectory("audit")
        let workDir = makeTempDirectory("sessions")
        let sessionListViewModel = SessionListViewModel(
            store: SessionStore(directory: workDir),
            secrets: NoOpSecretStore(),
            auditStore: AuditLogStore(directory: workDir.appendingPathComponent("audit")),
            loginSetStore: LoginSetStore(directory: workDir),
            keys: ManagedKeyStore(directory: workDir))
        let view = ContentView(
            settingsStore: SettingsStore(directory: settingsDir),
            bandwidthLimiter: BandwidthLimiter(),
            auditStore: AuditLogStore(directory: auditDir),
            tabCommands: TabCommands(),
            updateModel: UpdateCheckModel(),
            menuBarModel: MenuBarStatusModel(),
            sessionListViewModel: sessionListViewModel,
            secretStore: NoOpSecretStore(),
            managedKeyStore: ManagedKeyStore(directory: workDir))
        return (view, {
            try? FileManager.default.removeItem(at: settingsDir)
            try? FileManager.default.removeItem(at: auditDir)
            try? FileManager.default.removeItem(at: workDir)
        })
    }

    /// Same shape as `SessionTabTests.makeTab()`.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Same shape as `SessionTabTests.attachSession(to:)`.
    private func attachSession(to tab: SessionTab) {
        let sessionID = UUID()
        let remoteFS = LocalFileSystem()
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
        tab.liveness = .degraded
    }

    @Test func givingUpLeavesTheTabLostWithNoSession() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)

        await view.handleLivenessGiveUp(tab)

        #expect(tab.session == nil)
        #expect(tab.liveness == .lost)
    }

    /// Fix round 1: the property no test previously pinned. The Core suite's
    /// `cancelAllDueToConnectionLossFailsRunningAndKeepsQueuedListed` proves
    /// what `TransferQueueViewModel.cancelAll(reason:)` DOES for each
    /// reason; nothing proved that `handleLivenessGiveUp(_:)` actually
    /// PASSES `.connectionLost` rather than `.userRequested` at its one
    /// real call site — a reviewer flipping that single literal left the
    /// full suite green before this test existed. This drives the real
    /// give-up path with an item still in the queue and asserts the
    /// reason it reads afterward, so that flip cannot pass silently again.
    ///
    /// **How the item is kept non-terminal, and why it is kept that way
    /// with no help from scheduling.** This test used to enqueue a job whose
    /// paths did not exist and rely on there being NO suspension point
    /// between `enqueue` and `cancelAll`: the worker `Task` could not run,
    /// so the item was still resolving when the sweep reached it. That
    /// assumption stopped holding for one commit (`eed1c8a`), while
    /// `teardown(_:reason:)` ran its first stage through
    /// `TeardownStage.runBounded` — which suspends before the sweep, so the
    /// worker got a turn, opened the bogus path, and the item read
    /// `.failed("File not found: …")` instead.
    ///
    /// That bound is gone again (maintainer's ruling, 2026-08-28), so the
    /// old fixture would work today. This one is kept anyway, because the
    /// two properties are separate and each deserves a test that fails for
    /// one reason only: THIS test is about the reason literal
    /// `handleLivenessGiveUp(_:)` passes, and the source below suspends
    /// rather than failing, which keeps the job non-terminal however many
    /// turns the main actor takes before the sweep. Whether the sweep finds
    /// the job in `resolvingJobIDs` or in `runningTransferTasks` no longer
    /// matters — both paths mark it with the reason this test is about. The
    /// scheduling property the old fixture pinned by accident is pinned
    /// deliberately, and named, by
    /// `theQueueIsSweptInTeardownsOwnFirstMainActorTurn` below. No real disk
    /// access happens, and no network is dialled.
    @Test func givingUpMarksQueuedTransfersConnectionLost() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)
        let session = tab.session!
        let destinationDirectory = makeTempDirectory("giveup-destination")
        try? FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        let itemID = tab.transferQueue.enqueue(
            fileName: "never-touched.txt", direction: .download,
            source: SuspendsUntilCancelledFileSystem(), sourcePath: "/never-touched.txt",
            destination: session.localFS,
            destinationDirectory: destinationDirectory.path(percentEncoded: false),
            onCompleted: nil)

        await view.handleLivenessGiveUp(tab)

        let item = tab.transferQueue.items.first { $0.id == itemID }
        let expectedReason = CoreL10n.string("core.transfer.connectionLost")
        #expect(item?.status == .failed(expectedReason), """
            expected the queued item to read .failed("\(expectedReason)") after a liveness \
            give-up, found \(String(describing: item?.status)) instead — \
            handleLivenessGiveUp(_:) must pass .connectionLost to teardown(_:reason:), not \
            .userRequested.
            """)
    }

    /// The property the maintainer chose over a bound around teardown's
    /// first stage, pinned on purpose rather than as a side effect of some
    /// other test's fixture.
    ///
    /// `teardown(_:reason:)` reaches `transferQueue.cancelAll(reason:)`
    /// without suspending: everything before it (`editErrorMessage`,
    /// `conflictBridge.cancelOpenPrompt()`) is synchronous, and `cancelAll`
    /// is called directly rather than through `TeardownStage.runBounded`.
    /// So the queue is swept in teardown's OWN first main-actor turn, and a
    /// worker `Task` created by `enqueue`'s `kickWorker()` cannot have run
    /// yet — a freshly created task's body cannot start until the currently
    /// executing main-actor code reaches its own suspension point.
    ///
    /// **What it watches, and why not the item's status.** The obvious
    /// fixture — a job whose paths do not exist, asserting it does not read
    /// `.failed("File not found: …")` — was tried and MEASURED in the pass
    /// that removed the bound: with `cancelAll` wrapped in `BoundedClose`
    /// again, that fixture went red in only four of six runs. It is a race
    /// between the sweep and how far the worker gets, not a test. What is
    /// NOT a race is whether the worker ran at all: `process(_:)` bails on
    /// its `guard let job = jobs[jobID]` once the sweep has cleared the job,
    /// so a destination that records being touched is touched if and only if
    /// the worker got its turn first. Under the same re-wrapped bound, this
    /// version was red in ten runs out of ten, and green in ten out of ten
    /// without it. It is also sharper than the status fixture on the
    /// smallest possible version of the defect: with a bare
    /// `await Task.yield()` inserted in front of the sweep, this check was
    /// red in five runs out of five, while the status fixture passed the one
    /// run it was given.
    ///
    /// So the negative check below is the guard, and it does not stand
    /// alone (`CLAUDE.md`): the status assertion beside it is the positive
    /// half, failing loudly if this fixture ever stops enqueueing a real,
    /// sweepable item — a "was never touched" that holds because nothing was
    /// ever queued would otherwise read exactly like a pass.
    @Test func theQueueIsSweptInTeardownsOwnFirstMainActorTurn() async {
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)
        let session = tab.session!
        let touched = TouchFlag()

        // Upload, so the recording double is the DESTINATION: the first
        // thing `process` does after its guard is stat the destination
        // (`resolveConflictIfNeeded`), which makes this the earliest touch
        // a worker turn can produce.
        let itemID = tab.transferQueue.enqueue(
            fileName: "never-touched.txt", direction: .upload,
            source: session.localFS, sourcePath: "/never-touched.txt",
            destination: RecordsBeingTouchedFileSystem(touched: touched),
            destinationDirectory: "/never-touched",
            onCompleted: nil)

        await view.handleLivenessGiveUp(tab)

        #expect(touched.isRaised == false, """
            the transfer worker reached its destination file system before teardown swept the \
            queue. teardown(_:reason:) must reach transferQueue.cancelAll(reason:) without \
            suspending — most likely cause: cancelAll was wrapped in a bound again \
            (TeardownStage.runBounded/BoundedClose), which puts a main-actor turn in front of \
            the sweep and lets a transfer that settles inside it keep its own error text \
            instead of reading as a connection loss.
            """)
        let item = tab.transferQueue.items.first { $0.id == itemID }
        let expectedReason = CoreL10n.string("core.transfer.connectionLost")
        #expect(item?.status == .failed(expectedReason), """
            the check above only means something if there was a real item for the sweep to \
            find: expected .failed("\(expectedReason)"), found \
            \(String(describing: item?.status)).
            """)
    }

    /// Demonstrated, not just asserted by construction — same reasoning as
    /// `ConnectAttemptHandoffTests.theRealSessionsFileIsNeverTouched`, whose
    /// own doc comment explains why a snapshot comparison is the standard
    /// this branch now holds any test that builds a real `ContentView` to.
    @Test func theRealSessionsFileIsNeverTouched() async {
        let before = snapshotRealSessionsFile()
        let (view, cleanup) = makeContentView()
        defer { cleanup() }
        let tab = makeTab()
        attachSession(to: tab)

        await view.handleLivenessGiveUp(tab)

        let after = snapshotRealSessionsFile()
        #expect(before == after, """
            the real on-disk session store changed while this suite ran. \
            `before` had \(before?.count.description ?? "no file"), \
            `after` had \(after?.count.description ?? "no file").
            """)
    }
}

/// Test double for `SecretStore`, local to this file for the same reason
/// `ConnectAttemptHandoffTests`' own `RecordingSecretStore` is (`macSCPAppKitTests`
/// does not depend on `macSCPCoreTests`, so `Tests/macSCPCoreTests
/// /InMemorySecretStore.swift` is not importable here). No recording
/// needed here — this suite's own path never calls it (see this file's
/// top-level doc comment) — so a bare no-op is enough; its only job is to
/// not be `KeychainSecretStore`.
private struct NoOpSecretStore: SecretStore {
    func savePassword(_ password: String, for sessionID: UUID) throws {}
    func password(for sessionID: UUID) throws -> String? { nil }
    func deletePassword(for sessionID: UUID) throws {}
}

/// A transfer source that never finishes on its own and unwinds the moment
/// the queue cancels it — the fixture
/// `givingUpMarksQueuedTransfersConnectionLost` needs so that its item is
/// non-terminal whenever the sweep arrives, without any assumption about
/// how many turns the main actor takes to get there.
///
/// `Task.sleep` rather than a never-resumed continuation (the shape
/// `LivenessProbeCancellationTests.NeverRespondingFileSystem` uses): that
/// double models a peer that never answers even a cancelled call, which is
/// the right model for a liveness probe and the wrong one here — a source
/// that ignored cancellation would leave `cancelAll`'s step 3 waiting on it
/// forever, and nothing bounds that step: teardown calls it directly (see
/// `ContentView.teardown(_:reason:)`), so an uncooperative source here
/// would hang the ungated suite rather than merely slow it down.
/// `Task.sleep` throws `CancellationError` immediately when cancelled,
/// which is exactly the cooperative source the queue's cancel path expects.
/// The duration is long enough that it can only ever end by cancellation.
///
/// Read-side methods suspend; everything else traps, so a future change
/// that routes a transfer through one of them fails loudly instead of
/// passing quietly.
private struct SuspendsUntilCancelledFileSystem: RemoteFileSystem {
    private func suspendUntilCancelled() async throws -> Never {
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        try await suspendUntilCancelled()
    }

    func stat(path: String) async throws -> RemoteFileItem {
        try await suspendUntilCancelled()
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await suspendUntilCancelled()
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        fatalError("not exercised by this test")
    }

    func delete(path: String) async throws {
        fatalError("not exercised by this test")
    }

    func createDirectory(at path: String) async throws {
        fatalError("not exercised by this test")
    }

    func rename(from: String, to: String) async throws {
        fatalError("not exercised by this test")
    }

    func setPermissions(path: String, permissions: UInt32) async throws {
        fatalError("not exercised by this test")
    }

    func deleteTree(at path: String) async throws {
        fatalError("not exercised by this test")
    }

    func homeDirectoryPath() async throws -> String {
        fatalError("not exercised by this test")
    }

    func disconnect() async {}
}

/// A destination that records being reached and then fails immediately —
/// the whole fixture of `theQueueIsSweptInTeardownsOwnFirstMainActorTurn`.
///
/// Every method raises the flag and throws `RemoteFSError.notFound`; none
/// of them suspends and none of them traps, and both of those are
/// deliberate. A double that suspended here would be reached only when the
/// property under test is BROKEN — and then it would park the queue's
/// `cancelAll` step 3 on a job it does not cancel (a resolving job is swept
/// but its process task is awaited), turning a broken invariant into a
/// hung ungated suite instead of a red test. A `fatalError` would turn it
/// into a crashed one. Throwing lets the worker finish immediately, so the
/// regression shows up as the two assertions failing and nothing else.
private struct RecordsBeingTouchedFileSystem: RemoteFileSystem {
    let touched: TouchFlag

    private func record(_ path: String = "/never-touched") throws -> Never {
        touched.raise()
        throw RemoteFSError.notFound(path: path)
    }

    func list(path: String) async throws -> [RemoteFileItem] { try record(path) }
    func stat(path: String) async throws -> RemoteFileItem { try record(path) }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try record()
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        try record(path)
    }

    func delete(path: String) async throws { try record(path) }
    func createDirectory(at path: String) async throws { try record(path) }
    func rename(from: String, to: String) async throws { try record(from) }
    func setPermissions(path: String, permissions: UInt32) async throws { try record(path) }
    func deleteTree(at path: String) async throws { try record(path) }
    func homeDirectoryPath() async throws -> String { try record() }
    func disconnect() async {}
}

/// One-way flag, written by `RecordsBeingTouchedFileSystem` from whatever
/// executor the queue's worker happens to be on and read back on the main
/// actor. `@unchecked Sendable` because `lock` is what serializes
/// the write and the read — the shape `TeardownStageTests.Flag` uses for
/// the same job.
private final class TouchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}
