import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// The throughput step (`DiagnosticScope.throughput`, `ThroughputProbe`)
/// over an in-memory file system: the order of its operations, the removal
/// of its test file on every way out — cancel mid-transfer included — the
/// byte check, and the leftover sweep that touches nothing but its own
/// files.
///
/// **No rate is asserted anywhere here**, and no wall clock bounds a case.
/// A rate is reported, never judged (the brief's decision), and on a
/// starved runner any bound would measure the runner (CLAUDE.md, "A
/// wall-clock ceiling in a test measures the runner"). The fakes that stand
/// in for a transfer in flight PARK until the case cancels them — they wait
/// on an `AsyncSignal` nobody raises, which returns on cancellation — and
/// never finish after a fixed sleep. The suite's time limit is a hang bound
/// and nothing else.
@Suite("The throughput test", .timeLimit(.minutes(2)))
struct ThroughputProbeTests {
    /// Four chunks and a half — enough for a cancel to land mid-transfer
    /// and for the last chunk to be a short one.
    static let payloadBytes = TransferChunk.size * 4 + 1234
    static let seed: UInt64 = 0x5EED_0F_7E57
    static let id = UUID(uuidString: "0B5E55ED-0000-4000-8000-00000000C0DE")!
    static let home = "/home/tester"
    static var testFile: String { RemotePath.join(home, ThroughputProbe.fileName(for: id)) }

    // MARK: - The order, and the natural end

    @Test func theTestWritesReadsBackAndRemovesItsFileInThatOrder() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .ok, "\(step.outcome.label) — \(step.detail)")
        #expect(await fs.log == [
            "home", "list \(Self.home)", "write \(Self.testFile)", "stat \(Self.testFile)",
            "read \(Self.testFile)", "delete \(Self.testFile)",
        ])
        await Self.expectNothingLeft(on: fs)
        #expect(step.detail.contains(ThroughputProbe.fileName(for: Self.id)))
        #expect(step.detail.contains("read back identical"))
        #expect(step.detail.contains("removed"))
    }

    /// The table: one row per direction, the exact byte count, and no limit
    /// where none was set. The rate cell is only required to be there — its
    /// value is a measurement of this machine and is never compared.
    @Test func theRowCarriesADirectionPerRowAndNoRateIsJudged() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)

        let step = await Self.measure(on: fs)

        let table = try #require(step.table)
        #expect(table.columns == DiagnosticThroughputColumn.all)
        #expect(table.rows.map { $0[0] } == [
            DiagnosticThroughputColumn.up, DiagnosticThroughputColumn.down,
        ])
        #expect(table.rows.map { $0[1] } == ["\(Self.payloadBytes)", "\(Self.payloadBytes)"])
        #expect(table.rows.map { $0[4] } == [
            DiagnosticThroughputColumn.none, DiagnosticThroughputColumn.none,
        ])
        #expect(table.rows.allSatisfy { !$0[3].isEmpty })
    }

    /// What was written is what the payload says, byte for byte — the sink's
    /// "identical" is measured against the same bytes the server received,
    /// not against itself.
    @Test func whatReachesTheServerIsThePatternTheSinkComparesAgainst() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.keepDeletedContents()

        _ = await Self.measure(on: fs)

        let written = try #require(await fs.deletedContents[Self.testFile])
        #expect(written.count == Self.payloadBytes)
        #expect(
            written
                == ThroughputPattern.bytes(seed: Self.seed, offset: 0, count: Self.payloadBytes))
    }

    // MARK: - The byte check

    @Test func aPayloadThatComesBackDifferentFailsAndIsStillRemoved() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let flipped = TransferChunk.size + 17
        await fs.corruptReadBack(atByte: flipped)

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .failed(DiagnosticReason.throughputBytesDiffer))
        #expect(step.detail.contains("first difference at byte \(flipped)"), "\(step.detail)")
        await Self.expectNothingLeft(on: fs)
        #expect(await fs.log.last == "delete \(Self.testFile)")
    }

    @Test func aReadBackThatIsShortFailsAndIsStillRemoved() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.truncateReadBack(to: TransferChunk.size)

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .failed(DiagnosticReason.throughputBytesDiffer))
        #expect(
            step.detail.contains("\(TransferChunk.size) of \(Self.payloadBytes) bytes read back"),
            "\(step.detail)")
        await Self.expectNothingLeft(on: fs)
    }

    // MARK: - Removal on failure

    /// The upload fails after its first chunk landed: a partial file is on
    /// the server, and it goes.
    @Test func aFailedUploadStillRemovesWhatItWrote() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.failWrite(afterChunks: 1)

        let step = await Self.measure(on: fs)

        guard case .failed = step.outcome else {
            Issue.record("a failed upload reported \(step.outcome.label)")
            return
        }
        #expect(step.table == nil, "a table over an upload that never finished")
        #expect(await fs.log.contains("delete \(Self.testFile)"))
        #expect(!(await fs.log.contains("read \(Self.testFile)")))
        await Self.expectNothingLeft(on: fs)
    }

    @Test func aFailedDownloadStillRemovesTheFile() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.failRead(afterChunks: 2)

        let step = await Self.measure(on: fs)

        guard case .failed = step.outcome else {
            Issue.record("a failed download reported \(step.outcome.label)")
            return
        }
        #expect(step.table?.rows.map { $0[0] } == [DiagnosticThroughputColumn.up])
        #expect(await fs.log.last == "delete \(Self.testFile)")
        await Self.expectNothingLeft(on: fs)
    }

    /// A removal the server refuses is the row's verdict, whatever else
    /// happened: a file of this app's on the user's server is the one thing
    /// the row must not bury. The file is named, so the user can find it.
    @Test func aRemovalTheServerRefusesIsReportedAsAFileLeftBehind() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.refuseDelete(of: Self.testFile)

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .failed(DiagnosticReason.throughputFileLeftBehind))
        #expect(step.detail.contains(ThroughputProbe.fileName(for: Self.id)))
        #expect(step.detail.contains("not removed"), "\(step.detail)")
    }

    // MARK: - Removal on cancel

    /// Cancelled while the upload is in flight: the fake has taken one chunk
    /// and parks until the cancellation reaches it. The removal still runs —
    /// and the fake's `delete` REFUSES a caller whose task is cancelled, the
    /// way a `URLSession` request does, so this case is red if the removal
    /// runs in the cancelled task instead of beside it.
    @Test func aCancelMidUploadStillRemovesTheFile() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let reached = AsyncSignal()
        await fs.parkWrite(afterChunks: 1, reached: reached)

        let run = Task { await Self.measure(on: fs) }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        _ = await run.value

        #expect(await fs.log.contains("write \(Self.testFile)"))
        #expect(await fs.log.last == "delete \(Self.testFile)")
        #expect(await fs.refusedCancelledDeletes == 0)
        await Self.expectNothingLeft(on: fs)
    }

    @Test func aCancelMidDownloadStillRemovesTheFile() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let reached = AsyncSignal()
        await fs.parkRead(afterChunks: 1, reached: reached)

        let run = Task { await Self.measure(on: fs) }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        _ = await run.value

        #expect(await fs.log.contains("read \(Self.testFile)"))
        #expect(await fs.log.last == "delete \(Self.testFile)")
        #expect(await fs.refusedCancelledDeletes == 0)
        await Self.expectNothingLeft(on: fs)
    }

    /// The positive half of the two cases above: the fake's refusal is real.
    /// A delete asked from a cancelled task is refused, so the removal
    /// passing there is evidence it did not run in one.
    @Test func theFakeRefusesADeleteFromACancelledTask() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.seed(file: Self.testFile)
        let gate = AsyncSignal()

        let run = Task {
            _ = await gate.wait()
            return try? await fs.delete(path: Self.testFile)
        }
        run.cancel()
        _ = await run.value

        #expect(await fs.refusedCancelledDeletes == 1)
        #expect(await fs.paths == [Self.testFile])
    }

    /// Cancelled before anything of this run was written: nothing is
    /// written and nothing is removed.
    @Test func aCancelBeforeTheUploadWritesNothing() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let reached = AsyncSignal()
        await fs.parkList(reached: reached)

        let run = Task { await Self.measure(on: fs) }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        _ = await run.value

        #expect(!(await fs.log.contains { $0.hasPrefix("write ") }))
        #expect(!(await fs.log.contains { $0.hasPrefix("delete ") }))
    }

    // MARK: - The leftover sweep

    /// A file name, its kind, and whether the sweep may remove it.
    static let leftoverCases: [(name: String, kind: RemoteFileKind, isLeftover: Bool)] = {
        let prefix = ThroughputProbe.namePrefix
        let upper = "0B5E55ED-0000-4000-8000-000000000001"
        let lower = upper.lowercased()
        return [
            (prefix + upper, .file, true),
            (prefix + lower, .file, false),
            (prefix + "notes", .file, false),
            (prefix, .file, false),
            (prefix + upper + ".bak", .file, false),
            ("x" + prefix + upper, .file, false),
            (prefix + upper, .directory, false),
            (prefix + upper, .symlink, false),
            ("report.pdf", .file, false),
        ]
    }()

    @Test(arguments: leftoverCases)
    func onlyAFileNamedExactlyLikeATestFileIsALeftover(
        name: String, kind: RemoteFileKind, isLeftover: Bool
    ) {
        let item = RemoteFileItem(name: name, path: RemotePath.join(Self.home, name), kind: kind)
        #expect(ThroughputProbe.isLeftover(item) == isLeftover, "\(name) (\(kind))")
    }

    /// A folder holding one real leftover beside names that only look like
    /// one: the sweep removes the leftover and touches nothing else — and it
    /// removes it BEFORE this run writes its own file.
    @Test func theSweepRemovesAnEarlierRunsFileAndNothingElse() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let leftover = RemotePath.join(
            Self.home, ThroughputProbe.namePrefix + "0B5E55ED-0000-4000-8000-000000000001")
        let untouched = [
            ThroughputProbe.namePrefix + "0b5e55ed-0000-4000-8000-000000000001",
            ThroughputProbe.namePrefix + "notes",
            ThroughputProbe.namePrefix + "0B5E55ED-0000-4000-8000-000000000001.bak",
            "x" + ThroughputProbe.namePrefix + "0B5E55ED-0000-4000-8000-000000000001",
            "report.pdf",
        ].map { RemotePath.join(Self.home, $0) }
        let directory = RemotePath.join(
            Self.home, ThroughputProbe.namePrefix + "0B5E55ED-0000-4000-8000-000000000002")
        await fs.seed(file: leftover)
        for path in untouched { await fs.seed(file: path) }
        await fs.seed(directory: directory)

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .ok, "\(step.outcome.label) — \(step.detail)")
        #expect(Set(await fs.paths) == Set(untouched + [directory]))
        let log = await fs.log
        let sweptAt = try #require(log.firstIndex(of: "delete \(leftover)"))
        let writtenAt = try #require(log.firstIndex(of: "write \(Self.testFile)"))
        #expect(sweptAt < writtenAt, "\(log)")
        #expect(step.detail.contains("1 leftover from an earlier run removed"), "\(step.detail)")
    }

    /// Housekeeping, not the measurement: a folder that cannot be listed
    /// changes no outcome, and the row says the sweep did not happen.
    @Test func aFolderThatCannotBeListedIsSaidAndChangesNoOutcome() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        await fs.failList()

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .ok, "\(step.outcome.label)")
        #expect(step.detail.contains("could not be listed"), "\(step.detail)")
        await Self.expectNothingLeft(on: fs)
    }

    // MARK: - Where it cannot write

    @Test func aSessionAtTheBucketListHasNoFolderAndWritesNothing() async throws {
        let fs = InMemoryThroughputFileSystem(home: "/", bucketList: true)

        let step = await Self.measure(on: fs)

        #expect(step.outcome == .unavailable(DiagnosticReason.throughputNeedsAFolder))
        let log = await fs.log
        #expect(log.isEmpty, "\(log)")
    }

    // MARK: - The bandwidth limits

    /// A limit set on one direction paces that leg and is named in its row;
    /// the other direction says none applied. The bucket runs on a virtual
    /// clock its own sleep advances, so no real time is spent and none is
    /// measured.
    @Test func aConfiguredLimitIsNamedInTheRowOfTheDirectionItPaces() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let clock = VirtualClock()
        let bucket = BandwidthBucket(
            bytesPerSecond: 65_536, now: { clock.now }, sleep: { clock.advance(by: $0) })

        let step = await ThroughputProbe.measure(
            on: fs, payloadBytes: Self.payloadBytes, uploadThrottle: bucket,
            downloadThrottle: nil, id: Self.id, seed: Self.seed, timer: Self.timer())

        let table = try #require(step.table)
        #expect(table.rows.map { $0[4] } == ["64 KB/s", DiagnosticThroughputColumn.none])
        #expect(clock.sleeps > 0, "the limit did not pace the upload")
    }

    // MARK: - In the walk

    @Test func theThroughputScopeRunsTheResolveAndTheTestAndClosesItsConnection() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let opener = RecordingOpener(fileSystem: fs)

        let report = await Self.diagnostics(opener: opener).run(scope: .throughput)

        #expect(report.steps.map(\.id) == [DiagnosticStepID.resolve, DiagnosticStepID.throughput])
        #expect(report.steps.last?.outcome == .ok, "\(report.steps.last?.outcome.label ?? "")")
        #expect(opener.opened == 1)
        #expect(await fs.log.last == "disconnect")
        await Self.expectNothingLeft(on: fs)
        #expect(report.completion == .complete)
    }

    /// `.complete` is everything that only READS. It never opens the
    /// throughput test's connection — decided for the maintainer: what moves
    /// data on the user's server runs only when chosen by name.
    @Test func theCompleteScopeNeverRunsTheThroughputTest() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let opener = RecordingOpener(
            fileSystem: InMemoryThroughputFileSystem(home: Self.home))

        let report = await Self.diagnostics(opener: opener, port: listener.port).run(
            scope: .complete)

        #expect(!report.steps.contains { $0.id == DiagnosticStepID.throughput })
        #expect(report.steps.contains { $0.id == DiagnosticStepID.tcp }, "the walk ran nothing")
        #expect(opener.opened == 0)
        for scope in DiagnosticScope.allCases {
            #expect(
                scope.runs(.throughput) == (scope == .throughput),
                "\(scope.rawValue) runs the throughput test: \(scope.runs(.throughput))")
        }
    }

    /// Cancelled mid-upload through the walk: the report says cancelled and
    /// carries no throughput row, and the file and the connection are both
    /// gone by the time the walk returns.
    @Test func aWalkCancelledMidUploadRemovesTheFileAndClosesTheConnection() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let reached = AsyncSignal()
        await fs.parkWrite(afterChunks: 1, reached: reached)
        let diagnostics = Self.diagnostics(opener: RecordingOpener(fileSystem: fs))

        let run = Task { await diagnostics.run(scope: .throughput) }
        #expect(await reached.wait() == .signalled)
        run.cancel()
        let report = await run.value

        #expect(report.completion == .cancelled(afterSteps: 1))
        #expect(!report.steps.contains { $0.id == DiagnosticStepID.throughput })
        // The walk names its file with a fresh UUID; the one it wrote is the
        // one it removed.
        let log = await fs.log
        let written = try #require(log.first { $0.hasPrefix("write ") })
        let path = String(written.dropFirst("write ".count))
        #expect(Array(log.suffix(2)) == ["delete \(path)", "disconnect"], "\(log)")
        await Self.expectNothingLeft(on: fs)
    }

    /// The secret is looked up the way the dial looks it up, and a session
    /// that has none opens nothing.
    @Test func withoutASecretTheTestIsSkippedAndOpensNothing() async throws {
        let opener = RecordingOpener(
            fileSystem: InMemoryThroughputFileSystem(home: Self.home))

        let report = await Self.diagnostics(opener: opener, requiresSecret: true).run(
            scope: .throughput)

        #expect(report.steps.last?.outcome == .skipped(DiagnosticReason.noSecret))
        #expect(opener.opened == 0)
    }

    /// Behind a jump host the test's connection is the two-stage one a tab
    /// makes — the target's config carrying the jump — and the walk dials no
    /// jump connection of its own for it.
    @Test func behindAJumpTheConnectionGoesThroughTheJump() async throws {
        let fs = InMemoryThroughputFileSystem(home: Self.home)
        let opener = RecordingOpener(fileSystem: fs)
        let jump = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: 1),
            login: .init(username: "jumper", authKind: .agent, keyPath: nil),
            secret: { nil })

        let report = await Self.diagnostics(opener: opener, jump: jump).run(scope: .throughput)

        #expect(report.steps.map(\.id) == [
            DiagnosticStepID.jumpResolve, DiagnosticStepID.throughput,
        ])
        #expect(report.steps.last?.outcome == .ok, "\(report.steps.last?.outcome.label ?? "")")
        guard case .ssh(let config)? = opener.configs.first else {
            Issue.record("the test did not open an SSH connection: \(opener.configs)")
            return
        }
        #expect(config.jump?.host == "127.0.0.1")
        #expect(config.jump?.username == "jumper")
        #expect(config.host == "127.0.0.1")
    }

    // MARK: - Support

    /// Nothing of the test's is on the server — the one property every
    /// exit path shares.
    static func expectNothingLeft(on fs: InMemoryThroughputFileSystem) async {
        let paths = await fs.paths
        #expect(paths.isEmpty, "left behind: \(paths)")
    }

    static func timer() -> DiagnosticStepTimer {
        DiagnosticStepTimer(
            id: DiagnosticStepID.throughput,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.throughput))
    }

    static func measure(on fs: InMemoryThroughputFileSystem) async -> DiagnosticStep {
        await ThroughputProbe.measure(
            on: fs, payloadBytes: payloadBytes, uploadThrottle: nil, downloadThrottle: nil,
            id: id, seed: seed, timer: timer())
    }

    /// A walk over SSH-shaped values with an agent login (so nothing asks a
    /// secret unless the case says so), a descriptor with no dial and no
    /// contributions, and names that are never looked up.
    static func diagnostics(
        opener: RecordingOpener, port: Int = 22, requiresSecret: Bool = false,
        jump: DiagnosticJump? = nil
    ) -> ConnectionDiagnostics {
        var values = SSHFieldSchema.defaults
        values[SSHField.host] = "127.0.0.1"
        values[SSHField.port] = String(port)
        values[SSHField.username] = "tester"
        values[SSHField.authKind] = StoredSession.AuthKind.agent.rawValue
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        let descriptor = BackendDescriptor(
            kind: .ssh, capabilities: ssh.capabilities,
            connectionSchema: ssh.connectionSchema, credentialSchema: ssh.credentialSchema,
            makeConfig: ssh.makeConfig, displaySummary: ssh.displaySummary, apply: ssh.apply,
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B", secretEnvironmentVariable: nil,
            requiresSecret: { _ in requiresSecret }, fileActions: [],
            endpoint: ssh.endpoint, dial: nil, diagnostics: [])
        return ConnectionDiagnostics(
            descriptor: descriptor, values: values, secrets: nil, sessionID: UUID(),
            jump: jump, jumpDialer: JumpDialerThatIsNeverCalled.dialer,
            lookups: ResolveLookups(reverse: { _, _ in nil }, forward: { _, _, _ in nil }),
            throughput: DiagnosticThroughputSettings(payloadMiB: 1),
            throughputOpener: opener.opener, appVersion: "test")
    }
}

// MARK: - Fakes

/// A jump dialer for walks that must not dial a jump: both closures record
/// an issue if they are reached.
enum JumpDialerThatIsNeverCalled {
    static let dialer = DiagnosticJumpDialer(
        connectJump: { _, _ in
            Issue.record("the walk dialled a jump connection")
            throw RemoteFSError.protocolError(reason: "no jump here")
        },
        dialTarget: { _, _ in
            Issue.record("the walk dialled the target through a jump")
            throw RemoteFSError.protocolError(reason: "no jump here")
        })
}

/// The throughput step's connection seam, handing over one in-memory file
/// system and counting how often it was asked, and with what.
final class RecordingOpener: Sendable {
    private struct State {
        var configs: [ConnectionConfig] = []
    }

    private let state = Mutex(State())
    let fileSystem: InMemoryThroughputFileSystem

    init(fileSystem: InMemoryThroughputFileSystem) { self.fileSystem = fileSystem }

    var opened: Int { state.withLock { $0.configs.count } }
    var configs: [ConnectionConfig] { state.withLock { $0.configs } }

    var opener: DiagnosticThroughputOpener {
        DiagnosticThroughputOpener { [self] config, _ in
            state.withLock { $0.configs.append(config) }
            return fileSystem
        }
    }
}

/// A clock a `BandwidthBucket` can be paced by without real time passing:
/// every sleep moves it forward by exactly what was asked.
final class VirtualClock: Sendable {
    private struct State {
        var now = ContinuousClock.now
        var sleeps = 0
    }

    private let state = Mutex(State())

    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    var sleeps: Int { state.withLock { $0.sleeps } }

    func advance(by duration: Duration) {
        state.withLock {
            $0.now = $0.now.advanced(by: duration)
            $0.sleeps += 1
        }
    }
}

/// An in-memory server for the throughput step: one home folder, files and
/// folders in it, every operation logged, and the failures and parks a case
/// asks for.
///
/// **Parks wait on cancellation, never on a clock.** A parked write or read
/// raises `reached` and then awaits an `AsyncSignal` nobody raises, which
/// returns when the calling task is cancelled.
///
/// **`delete` refuses a cancelled caller**, the way a `URLSession` request
/// does: a removal that ran in the cancelled task would be refused here and
/// counted (`refusedCancelledDeletes`), leaving the file in place.
actor InMemoryThroughputFileSystem: RemoteFileSystem {
    private let home: String
    private nonisolated let bucketList: Bool
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private(set) var log: [String] = []
    private(set) var refusedCancelledDeletes = 0
    private(set) var deletedContents: [String: Data] = [:]
    private var keepsDeletedContents = false

    private var writeFailsAfter: Int?
    private var readFailsAfter: Int?
    private var writeParksAfter: (chunks: Int, reached: AsyncSignal)?
    private var readParksAfter: (chunks: Int, reached: AsyncSignal)?
    private var listParks: AsyncSignal?
    private var listFails = false
    private var corruptAt: Int?
    private var truncateTo: Int?
    private var refusedDeletes: Set<String> = []

    init(home: String, bucketList: Bool = false) {
        self.home = home
        self.bucketList = bucketList
    }

    nonisolated var rootIsContainerList: Bool { bucketList }

    /// Every path that exists, files and folders.
    var paths: [String] { Array(files.keys) + Array(directories) }

    func seed(file path: String) { files[path] = Data("user data".utf8) }
    func seed(directory path: String) { directories.insert(path) }
    func keepDeletedContents() { keepsDeletedContents = true }
    func failWrite(afterChunks chunks: Int) { writeFailsAfter = chunks }
    func failRead(afterChunks chunks: Int) { readFailsAfter = chunks }
    func parkWrite(afterChunks chunks: Int, reached: AsyncSignal) {
        writeParksAfter = (chunks, reached)
    }
    func parkRead(afterChunks chunks: Int, reached: AsyncSignal) {
        readParksAfter = (chunks, reached)
    }
    func parkList(reached: AsyncSignal) { listParks = reached }
    func failList() { listFails = true }
    func corruptReadBack(atByte offset: Int) { corruptAt = offset }
    func truncateReadBack(to count: Int) { truncateTo = count }
    func refuseDelete(of path: String) { refusedDeletes.insert(path) }

    func homeDirectoryPath() async throws -> String {
        log.append("home")
        return home
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        log.append("list \(path)")
        if let reached = listParks {
            reached.signal()
            _ = await AsyncSignal().wait()
        }
        if listFails { throw RemoteFSError.permissionDenied(path: path) }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        func child(_ candidate: String) -> String? {
            guard candidate.hasPrefix(prefix) else { return nil }
            let name = String(candidate.dropFirst(prefix.count))
            return name.contains("/") ? nil : name
        }
        return files.keys.compactMap { key in
            child(key).map { RemoteFileItem(name: $0, path: key, kind: .file) }
        } + directories.compactMap { key in
            child(key).map { RemoteFileItem(name: $0, path: key, kind: .directory) }
        }
    }

    func stat(path: String) async throws -> RemoteFileItem {
        log.append("stat \(path)")
        guard let data = files[path] else { throw RemoteFSError.notFound(path: path) }
        return RemoteFileItem(
            name: String(path.split(separator: "/").last ?? ""), path: path, kind: .file,
            size: UInt64(data.count))
    }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        log.append("write \(path)")
        files[path] = Data()
        var chunks = 0
        for try await chunk in contents {
            files[path, default: Data()].append(chunk)
            chunks += 1
            if let failing = writeFailsAfter, chunks >= failing {
                throw RemoteFSError.protocolError(reason: "the disk is full")
            }
            if let park = writeParksAfter, chunks == park.chunks {
                park.reached.signal()
                _ = await AsyncSignal().wait()
            }
        }
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        log.append("read \(path)")
        guard var data = files[path] else { throw RemoteFSError.notFound(path: path) }
        if let corruptAt, corruptAt < data.count { data[corruptAt] ^= 0xFF }
        if let truncateTo { data = data.prefix(truncateTo) }
        let chunks = stride(from: 0, to: data.count, by: TransferChunk.size).map {
            data.subdata(in: $0..<min($0 + TransferChunk.size, data.count))
        }
        let failsAfter = readFailsAfter
        let parksAfter = readParksAfter
        let cursor = Mutex(0)
        return AsyncThrowingStream(unfolding: {
            let index = cursor.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            if let failsAfter, index >= failsAfter {
                throw RemoteFSError.connectionFailed(reason: "the connection dropped")
            }
            if let parksAfter, index == parksAfter.chunks {
                parksAfter.reached.signal()
                _ = await AsyncSignal().wait()
            }
            return index < chunks.count ? chunks[index] : nil
        })
    }

    func delete(path: String) async throws {
        log.append("delete \(path)")
        if Task.isCancelled {
            refusedCancelledDeletes += 1
            throw CancellationError()
        }
        if refusedDeletes.contains(path) { throw RemoteFSError.permissionDenied(path: path) }
        guard let data = files.removeValue(forKey: path) else {
            throw RemoteFSError.notFound(path: path)
        }
        if keepsDeletedContents { deletedContents[path] = data }
    }

    func disconnect() async { log.append("disconnect") }

    func createDirectory(at path: String) async throws { throw Self.unused }
    func rename(from: String, to: String) async throws { throw Self.unused }
    func setPermissions(path: String, permissions: UInt32) async throws { throw Self.unused }
    func deleteTree(at path: String) async throws { throw Self.unused }

    private static let unused = RemoteFSError.protocolError(reason: "not part of the test")
}
