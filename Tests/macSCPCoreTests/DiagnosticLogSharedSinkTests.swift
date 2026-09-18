import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import macSCPCore

/// The twelve tests that MUST touch `DiagnosticLog.shared`, because the
/// production code under test — `LocalFileSystem`, `TransferEngine`,
/// `ConnectionViewModel`, `RemoteBrowserViewModel`, `TunnelRunner` — logs
/// through that exact singleton and cannot be pointed at a private instance
/// instead (their call sites spell `DiagnosticLog.shared.log(` directly).
/// Twelve counted 2026-09-18 (review follow-ups, Task 1, which added the
/// drained-failure port test); eleven on 2026-09-16 (technical backlog,
/// Task 4, which added the
/// clock-driven `entry slow` test) — ten on 2026-09-06, in Task 5's fix
/// round 2; seven before that task, eight after its first commit, nine
/// after round 1. `dialSupportReasonNamesTheHostNeverTheFingerprintsForAMismatch`
/// sits here too but never touches the singleton, so the file holds one
/// more `@Test` than that count. Every other diagnostic-log test lives in
/// `DiagnosticLogTests.swift` against its own, private `DiagnosticLog()`.
///
/// `DiagnosticLogSharedSinkIsolationGuardTests` holds this split in place:
/// this is the ONE file its scan lets mention `DiagnosticLog.shared`, on
/// the strength of the two things below.
///
/// **`.serialized` is load-bearing** — two of these tests running at once
/// would each see the other's `configure` call on the one shared instance.
///
/// **Never `DiagnosticLog.shared.currentFileURL`.** Diagnostic-log plan,
/// final fix round 2: the re-review traced an intermittent empty-file read
/// (round 1's own final-fix-report named it, unexplained, in its
/// "Not fixed" section) to exactly this property. `currentFileURL` reads
/// the LIVE, process-wide `directory`/`fileDayKey` fields at the moment it
/// is called — fields any OTHER suite's `configure(...)` on the same
/// `.shared` instance can overwrite. `ConnectionViewModelTests`/
/// `LocalFileSystemTests`/`TransferEngineTests` run in parallel with this
/// suite and carry no serialization of their own; a test in one of them
/// calling `DiagnosticLog.shared.configure(...)` — this file's own tests
/// are not the only callers of that method, `MacSCPApp.swift`'s own launch
/// path and any other suite reaching it would do the same — landing in the
/// gap between one of these five tests' own `await flush()` and its
/// FOLLOW-UP read of `currentFileURL` would point that read at a directory
/// or day key this test never wrote to. `flush()` itself was never the
/// bug: `markFlushed` only advances after `writeRun`'s synchronous write
/// returns, so by the time `flush()` resumes, this test's own lines are
/// provably on disk — SOMEWHERE. The bug was asking the singleton, a
/// SECOND time, after the fact, which directory that "somewhere" was.
///
/// The fix: every test below computes the path its own lines went to, out
/// of data it already holds — the directory it configured, and the day
/// key for a `now` it FIXES itself (`dayKeyText(for:timeZone:)`, matching
/// `DiagnosticLog`'s own private `yyyy-MM-dd` formatting, documented on
/// its class-level doc comment as the file-naming contract) — never by
/// reading the live singleton's state back.
@Suite("DiagnosticLog shared sink", .serialized, .timeLimit(.minutes(1)))
struct DiagnosticLogSharedSinkTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticLogSharedSinkTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileContents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// `DiagnosticLog`'s own (private) day-key format, reproduced here
    /// rather than read off the live singleton — see this suite's own doc
    /// comment for why `currentFileURL` is exactly the property round 2
    /// stopped calling. `yyyy-MM-dd`, Gregorian calendar, `en_US_POSIX`
    /// locale: the file-naming contract stated in `DiagnosticLog`'s own
    /// class doc comment (`~/Library/Logs/macSCP/macSCP-<yyyy-MM-dd>.log`)
    /// and already relied on verbatim by `DiagnosticLogTests
    /// .rotationPrunesOldFiles`'s hardcoded file names.
    private func dayKeyText(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The path this test's OWN lines went to: `logDirectory` is this
    /// test's own, private temp directory (never shared with another
    /// test), and `fixedNow` is the SAME instant this test passed to
    /// `configure(now:)` — so the day key here is guaranteed to match the
    /// one `DiagnosticLog` itself stamped the line with, with no dependency
    /// on the real clock or on reading the singleton's state back.
    private func ownFileURL(directory: URL, fixedNow: Date) -> URL {
        directory.appending(path: "macSCP-\(dayKeyText(for: fixedNow, timeZone: .current)).log")
    }

    /// `LocalFileSystem.list`'s own instrumentation (Task 3 of the
    /// diagnostic-log plan) — added here, in this `.serialized` suite that
    /// owns the process-wide singleton, rather than in `LocalFileSystemTests`:
    /// that suite runs its tests in parallel and carries no serialization of
    /// its own.
    ///
    /// Local-listing-never-blocks Task 2 moved the per-entry timed call (and
    /// its `entry slow` line) OUT of `list` and into `metadata(for:)` — so
    /// this test drives both: `list` for `list start`/`list done`, then
    /// drains `metadata(for:)` for the entry timing. `list` itself carries
    /// no per-entry timing any more, by design and permanently: driving
    /// only `list` (as this test once did) would make the `entry slow`
    /// absence structural — as true of a `LocalFileSystem` with the
    /// threshold logic deleted outright as of a correct one — rather than
    /// a live check of anything. Chip `task_baf1cade` flagged exactly this
    /// after Task 1 landed; draining the stream is what closes it.
    ///
    /// `.debug`, not `.info`: both `entry slow` writers in `metadata(for:)`
    /// — the per-child line written ON RETURN, and the supervisor's
    /// `(still pending)` line at the first deadline — log at `.debug`, so
    /// admitting `.debug` is what makes the absence assertion below
    /// actually test the threshold logic; at `.info` neither could appear
    /// regardless of whether the threshold check is right, and the absence
    /// would be trivially true.
    ///
    /// Fast BY CONSTRUCTION, not by the runner's speed (technical backlog
    /// of 2026-09-16): this test used to rely on three plain files probing
    /// under the default 500 ms threshold, and came back red once under a
    /// loaded full run — a wall-clock ceiling. Now the entry timing reads
    /// `LocalFileSystem`'s `metadataNow` seam, pinned to one instant that
    /// never advances, against `slowTestThreshold` (an hour), so every
    /// entry's measured duration is exactly zero; the supervisor's own
    /// first deadline is that same hour of real sleep, cancelled when the
    /// last entry reports. The negative (no `entry slow`) sits beside the
    /// positive (`list start`/`list done` ARE present), and beside
    /// `localFileSystemMetadataWritesAnEntrySlowLineWhenTheClockSaysSlow`,
    /// the same listing and the same threshold with a clock that advances
    /// an hour per reading — so the absence here is the threshold check
    /// answering, not a writer that cannot fire. The supervisor's
    /// `(still pending)` line is proven through the same shared sink by
    /// `metadataSupervisorLogsAStillPendingLineForAPermanentlyStuckEntry`
    /// below.
    @Test("LocalFileSystem.list/metadata write list start/done, with no entry-slow line for fast entries")
    func localFileSystemListWritesStartAndDoneWithoutAnEntrySlowLine() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let listedDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: listedDirectory) }
        let names = Self.ownEntryNames()
        for name in names {
            try Data("x".utf8).write(to: listedDirectory.appendingPathComponent(name))
        }
        let listedPath = listedDirectory.path(percentEncoded: false)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .debug, directory: logDirectory, now: { fixedNow })
        let instant = ContinuousClock().now
        let fs = LocalFileSystem(
            metadataDeadlines: MetadataDeadlines(
                slowEntryThreshold: Self.slowTestThreshold, stuckEntryDeadline: Self.slowTestThreshold),
            metadataNow: { instant })
        let phaseOne = try await fs.list(path: listedPath)
        for await _ in fs.metadata(for: phaseOne) {}
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("list start path=\(listedPath)"))
        #expect(contents.contains("list done path=\(listedPath) count=3"))
        let ownSlowLines = contents.split(separator: "\n").filter { line in
            line.contains("entry slow") && names.contains { line.contains("name=\($0) ") }
        }
        #expect(ownSlowLines.isEmpty, "\(ownSlowLines)")
    }

    /// Three entry names no other test writes. The shared sink is
    /// process-wide, and suites that run in parallel with this `.serialized`
    /// one — `LocalFileSystemTests` drives `metadata(for:)` with 5 ms
    /// thresholds and parked probes — log `entry slow … (still pending)`
    /// lines into whatever directory this suite has configured at that
    /// moment. Measured 2026-09-16: the positive test below read one such
    /// line in a filtered run beside `LocalFileSystemTests`. So both
    /// `entry slow` tests judge only lines naming their own entries; an
    /// unfiltered absence check would be red on another suite's timing.
    private static func ownEntryNames() -> [String] {
        let run = UUID().uuidString
        return ["one-\(run).txt", "two-\(run).txt", "three-\(run).txt"]
    }

    /// The threshold both `entry slow` tests above and below run against: an
    /// hour. Far above an instant that never advances (zero), far below a
    /// clock that advances two hours per reading — and far above any real
    /// sleep the supervisor could finish inside the suite's one-minute
    /// `.timeLimit`, so its `(still pending)` line cannot join either test.
    private static let slowTestThreshold: Duration = .seconds(3600)

    /// A clock that advances two hours every time it is read. Each entry's
    /// two readings are strictly ordered, so every entry measures at least
    /// one step — slow by construction, with no real time passing.
    private final class AdvancingClock: Sendable {
        private let base = ContinuousClock().now
        private let readings = Mutex(0)

        func now() -> ContinuousClock.Instant {
            let reading = readings.withLock { count -> Int in
                count += 1
                return count
            }
            return base.advanced(by: .seconds(7200) * reading)
        }
    }

    /// The positive half of the test above (technical backlog of
    /// 2026-09-16): the same three plain files, the same hour-long
    /// threshold, and a `metadataNow` that advances two hours per reading —
    /// so each entry's on-return `entry slow` line is written because the
    /// clock the line reads says slow, not because this machine was. Every
    /// line is the per-child one: the supervisor sleeps the real hour and is
    /// cancelled long before, so none carries `(still pending)`.
    @Test("LocalFileSystem.metadata writes an entry-slow line for each entry the clock measures as slow")
    func localFileSystemMetadataWritesAnEntrySlowLineWhenTheClockSaysSlow() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let listedDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: listedDirectory) }
        let names = Self.ownEntryNames()
        for name in names {
            try Data("x".utf8).write(to: listedDirectory.appendingPathComponent(name))
        }
        let listedPath = listedDirectory.path(percentEncoded: false)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .debug, directory: logDirectory, now: { fixedNow })
        let clock = AdvancingClock()
        let fs = LocalFileSystem(
            metadataDeadlines: MetadataDeadlines(
                slowEntryThreshold: Self.slowTestThreshold, stuckEntryDeadline: Self.slowTestThreshold),
            metadataNow: { clock.now() })
        let phaseOne = try await fs.list(path: listedPath)
        #expect(phaseOne.count == 3)
        for await _ in fs.metadata(for: phaseOne) {}
        await DiagnosticLog.shared.flush()

        let lines = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
            .split(separator: "\n")
        for name in names {
            let slow = lines.filter { $0.contains("entry slow name=\(name) ms=") }
            #expect(slow.count == 1, "\(name): \(slow)")
        }
        let ownPending = lines.filter { line in
            line.contains("(still pending)") && names.contains { line.contains("name=\($0) ") }
        }
        #expect(ownPending.isEmpty, "\(ownPending)")
    }

    /// Mirrors `LocalFileSystemTests`' own private `Gate`: a probe parks on
    /// `opened()` and never returns while this test never calls `open()`.
    ///
    /// `opened()`'s bare continuation is deliberate — the continuation IS the API under test here.
    /// `consumer.cancel()` (below) cancels the `Task` parked in `opened()`,
    /// and cancellation must not unstick it, mirroring Citadel's real
    /// uncancellable in-flight I/O (CLAUDE.md, architecture invariants) —
    /// the same shape as `LocalFileSystemTests`' and
    /// `ConnectionDiagnosticsTests`' own `Gate.opened()`.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            guard !isOpen else { return }
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func opened() async {
            if isOpen { return }
            // Here too: the continuation IS the API under test here (see Gate's doc comment above).
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Final fix round, Important: the per-entry `entry slow` line only
    /// ever wrote AFTER `metadataProbe` returned — so an entry that never
    /// returns, the exact case this design exists to name in a report,
    /// never got a line at all. `LocalMetadataSource.metadata(for:)` now
    /// runs a supervisor `Task` per call, alongside every child, that
    /// sleeps to `slowEntryThreshold` once and then writes a `(still
    /// pending)` line for every item its tally has not yet accounted for.
    /// This test parks one entry's probe on a `Gate` it never opens and
    /// waits — through `pollUntil`, no clock of the test's own beyond the
    /// suite's `.timeLimit` — for exactly that line to name the parked
    /// entry. Lives here, not in `LocalFileSystemTests`, for the same
    /// singleton reason every other test in this file does: the supervisor
    /// logs through `DiagnosticLog.shared` directly.
    ///
    /// Round 2, Important — the regression this file's own review found:
    /// the FIRST deadline (`slowEntryThreshold`, 500 ms) is a LOG line
    /// only, never a mark — a cloud file that answers a second or two
    /// later must not be blacklisted for the rest of the session. Marking
    /// happens only at the LATER `stuckEntryDeadline` (5 s). So this test
    /// also asserts the path is NOT YET in `StuckPaths` right after the
    /// pending line appears — run red first against the pre-round-2 code,
    /// which marked at the first deadline unconditionally.
    @Test("LocalFileSystem.metadata's supervisor logs a still-pending line for a permanently stuck entry")
    func metadataSupervisorLogsAStillPendingLineForAPermanentlyStuckEntry() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let listedDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: listedDirectory) }
        try Data("x".utf8).write(to: listedDirectory.appendingPathComponent("stuck.txt"))
        let stuckPath = listedDirectory.appendingPathComponent("stuck.txt").path(percentEncoded: false)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .debug, directory: logDirectory, now: { fixedNow })

        let gate = Gate()
        let stuckPaths = StuckPaths()
        let fs = LocalFileSystem(
            metadataProbe: { _ in
                await gate.opened()
                return nil
            },
            stuckPaths: stuckPaths)
        let phaseOne = try await fs.list(path: listedDirectory.path(percentEncoded: false))
        #expect(phaseOne.count == 1)
        // Deliberately never awaited to completion — the stream would only
        // finish once the parked child returns, which this test never lets
        // happen. Consuming it on its own `Task` is enough to drive the
        // supervisor; the loop (and the permanently parked child behind it)
        // is simply abandoned once this test ends, the same accepted cost
        // `LocalFileSystemTests`' own parked-probe tests carry.
        let consumer = Task {
            for await _ in fs.metadata(for: phaseOne) {}
        }

        let fileURL = ownFileURL(directory: logDirectory, fixedNow: fixedNow)
        try await pollUntil("the still-pending line for the stuck entry", every: .milliseconds(20)) {
            await DiagnosticLog.shared.flush()
            let contents = fileContents(fileURL)
            return contents.contains("entry slow name=stuck.txt") && contents.contains("(still pending)")
        }
        // Round 2 regression check: the 500 ms line is a log only — the
        // path must NOT be blacklisted yet. Marking waits for the later
        // `stuckEntryDeadline` (5 s default), which this test never waits
        // out (it cancels the consumer right after).
        #expect(!stuckPaths.contains(stuckPath))
        consumer.cancel()
    }

    /// The OTHER `entry slow` writer in `LocalMetadataSource.metadata(for:)`:
    /// the per-child line written ON RETURN, with a measured `ms=` and no
    /// `(still pending)` suffix, for an entry that was slow but did come
    /// back. The supervisor test above proves the deadline line; nothing
    /// else proved this one — `LocalFileSystemTests` cannot read the shared
    /// sink, and `localFileSystemListWritesStartAndDoneWithoutAnEntrySlowLine`
    /// only ever asserts the line's absence. This is the positive beside
    /// that negative (CLAUDE.md, "Guards that name what they watch").
    ///
    /// Outcome-driven, with no clock of the test's own beyond the suite's
    /// `.timeLimit`: the probe parks on a `Gate` until the supervisor's
    /// `(still pending)` line proves the (5 ms) threshold has elapsed; only
    /// THEN does the gate open, the stream is drained to completion, and
    /// the log must carry exactly one on-return line naming the entry. The
    /// stuck deadline stays at its production five seconds, so the entry
    /// is never marked — this test is about the log line, not the memory.
    @Test("LocalFileSystem.metadata logs an entry-slow line on return for an entry that came back late")
    func metadataLogsAnEntrySlowLineOnReturnForAnEntryThatCameBackLate() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let listedDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: listedDirectory) }
        try Data("x".utf8).write(to: listedDirectory.appendingPathComponent("late.txt"))

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .debug, directory: logDirectory, now: { fixedNow })

        let gate = Gate()
        let fs = LocalFileSystem(
            metadataProbe: { _ in
                await gate.opened()
                return nil
            },
            metadataDeadlines: MetadataDeadlines(slowEntryThreshold: .milliseconds(5)))
        let phaseOne = try await fs.list(path: listedDirectory.path(percentEncoded: false))
        #expect(phaseOne.count == 1)

        let consumer = Task {
            for await _ in fs.metadata(for: phaseOne) {}
        }
        let fileURL = ownFileURL(directory: logDirectory, fixedNow: fixedNow)
        try await pollUntil("the still-pending line, proving the threshold elapsed") {
            await DiagnosticLog.shared.flush()
            let contents = fileContents(fileURL)
            return contents.contains("entry slow name=late.txt") && contents.contains("(still pending)")
        }
        await gate.open()
        await consumer.value
        await DiagnosticLog.shared.flush()

        let onReturnLines = fileContents(fileURL)
            .split(separator: "\n")
            .filter { $0.contains("entry slow name=late.txt ms=") && !$0.contains("(still pending)") }
        #expect(onReturnLines.count == 1, "\(onReturnLines)")
    }

    /// `TransferEngine.copyFile`'s own instrumentation, driven against
    /// `MockRemoteFileSystem` (no rig needed — the `transfer` lines are
    /// written by the engine itself, above the SFTP layer). Lives here for
    /// the same singleton reason as the `LocalFileSystem` test above.
    @Test("TransferEngine.copyFile writes transfer start/done")
    func transferEngineWritesStartAndDoneLines() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let content = Data("hallo".utf8)
        let source = MockRemoteFileSystem(
            tree: [
                "/": [
                    RemoteFileItem(
                        name: "quelle.bin", path: "/quelle.bin", kind: .file,
                        size: UInt64(content.count))
                ]
            ],
            files: ["/quelle.bin": content])
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            direction: .upload,
            onProgress: { _ in })
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("transfer start direction=up path=/ziel/quelle.bin"))
        #expect(contents.contains("transfer done path=/ziel/quelle.bin"))
    }

    /// `ConnectionViewModel.connect()`'s own instrumentation, driven against
    /// a fake connector (same shape `ConnectionViewModelTests.makeVM` uses)
    /// — no rig needed, since the connector itself never dials anything
    /// real. Lives here for the same singleton reason as the two tests
    /// above; `@MainActor` on the test itself, since `ConnectionViewModel`
    /// is `@MainActor`-isolated and this suite otherwise is not.
    @MainActor
    @Test("ConnectionViewModel.connect() writes connect start/done")
    func connectionViewModelWritesConnectStartAndDoneLines() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "geheim"

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        _ = await vm.connect()
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("connect start host=example.com port=22 kind=ssh"))
        #expect(contents.contains("connect done"))
    }

    // MARK: - Fix round 1: a mapped RemoteFSError's own reason never leaks

    /// `RemoteFSError.connectionFailed(reason:)`/`.protocolError(reason:)`
    /// carry FREE TEXT — `S3FileSystem`/`WebDAVFileSystem` build it out of
    /// the endpoint the user typed, a field that takes
    /// `scheme://KEY:SECRET@host` as ordinary input. `RemoteBrowserViewModel
    /// .message(for:path:)`/`load()` both route through `DialSupport
    /// .reason(for:)`, which drops the reason for exactly these two cases.
    ///
    /// The planted secret lives in a named constant, and both checks below
    /// compute their `Bool` BEFORE the expectation (CLAUDE.md "A value a
    /// test must not leak has two exits"): `#expect` reports the SOURCE
    /// TEXT of the expression it checks, and Swift Testing's own rich diff
    /// prints the runtime VALUE of a failing subexpression — writing
    /// `#expect(!message.contains(secret))` directly would print `message`
    /// itself, secret included, into the failure output exactly when the
    /// test is red. `inMessage`/`inLog` carry only the answer, never the
    /// string that was searched.
    @MainActor
    @Test("a connectionFailed reason never reaches the browser message or the log")
    func connectionFailedReasonNeverReachesMessageOrLog() async throws {
        let secret = "AKIA:hunter2@example"
        let leakingReason = "Invalid S3 endpoint: https://\(secret)"
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let fs = MockRemoteFileSystem(tree: [:])
        await fs.setListFailure(RemoteFSError.connectionFailed(reason: leakingReason))
        let vm = RemoteBrowserViewModel(fs: fs, startPath: "/", logCategory: "browser.remote")

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        await vm.load()
        await DiagnosticLog.shared.flush()

        // The positive beside the negative below (CLAUDE.md, "Guards that
        // name what they watch"): without it, an `RemoteBrowserViewModel`
        // that stopped reaching `.failed` at all — the vacuous case this
        // `if`/`else` falls into — would still read `inMessage == false`
        // (`message` is `""`, and `""` never contains `secret`), passing
        // while the very state transition under test had silently broken.
        let stateIsFailed: Bool
        let message: String
        if case .failed(let bannerText) = vm.state {
            stateIsFailed = true
            message = bannerText
        } else {
            stateIsFailed = false
            message = ""
        }
        #expect(stateIsFailed)
        let inMessage = message.contains(secret)
        #expect(inMessage == false)

        let logText = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        let inLog = logText.contains(secret)
        #expect(inLog == false)
    }

    // MARK: - Final whole-plan review: the connect line drops endpoint userinfo

    /// Final whole-plan review, Critical: `ConnectionViewModel
    /// .connectLogFields` interpolated `s3.endpoint`/`webdav.baseURL`
    /// verbatim into `connect start host=…` — free text a user types into
    /// the endpoint field, which takes `scheme://KEY:SECRET@host` as
    /// ordinary input no schema here strips (`ConnectFailureSecrecyTests`).
    /// A stored S3 session whose endpoint carries a credential would
    /// otherwise write that credential straight into the diagnostic log's
    /// `connect start` line. The fix routes both `s3.endpoint` and
    /// `webdav.baseURL` through `URLText.withoutUserinfo` before they reach
    /// the log call; this test drives the S3 side end to end, through
    /// `ConnectionViewModel.connect()` itself, rather than the helper in
    /// isolation.
    ///
    /// The secret lives in a named constant, and both checks below compute
    /// their `Bool` before the expectation, for the same reason
    /// `connectionFailedReasonNeverReachesMessageOrLog` above does:
    /// `#expect` prints the source text of a failing expression, and
    /// `contents.contains(secret)` written directly would print `contents`
    /// — secret included — into the failure output exactly when the test
    /// is red. The negative sits beside a positive: the host name itself
    /// must still reach the line, or the fix would be indistinguishable
    /// from silently dropping `host=` altogether.
    @MainActor
    @Test("ConnectionViewModel.connect() drops the S3 endpoint's userinfo from the connect start line")
    func connectStartLineDropsS3EndpointUserinfo() async throws {
        let secret = "AKIAEXAMPLE:hunter2"
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.kind = .s3
        vm.s3AccessKeyID = "AKIAEXAMPLE"
        vm.s3SecretAccessKey = "shh-secret"
        vm.s3Region = "eu-central-1"
        vm.s3Endpoint = "https://\(secret)@s3.example.test"
        vm.s3Bucket = "my-bucket"
        vm.s3UsePathStyle = true

        let fixedNow = Date()
        DiagnosticLog.shared.configure(level: .info, directory: logDirectory, now: { fixedNow })
        _ = await vm.connect()
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        let inLog = contents.contains(secret)
        #expect(inLog == false)

        let hostStillPresent = contents.contains("s3.example.test")
        #expect(hostStillPresent)
    }

    /// `TunnelRunner`'s own lines, in the `tunnel` category the
    /// port-forwarding plan added to the fixed list.
    ///
    /// Here, and not in `TunnelRunnerTests`, for the reason this whole file
    /// exists: the runner logs through `DiagnosticLog.shared` directly (the
    /// same house pattern `TunnelStore` and `CitadelFileSystem` follow),
    /// which is also what keeps `DiagnosticLogSecrecyGuardTests`' scan able
    /// to read its call site at all — that scan matches the literal text
    /// `DiagnosticLog.shared.log(`, so a runner that logged through an
    /// injected instance would have its category checked by nobody.
    ///
    /// Drives one whole lifecycle — start, active, one accepted connection,
    /// a loss with a reconnect, stop — against the doubles in
    /// `TunnelRunnerFakes.swift`, so every line shape the plan names is
    /// written by the real code path rather than asserted about in the
    /// abstract. `.debug`, because the per-connection lines are `.debug`
    /// and the five lifecycle lines are `.info`: at `.info` the two
    /// `connection` assertions below would be trivially unreachable.
    @Test("TunnelRunner writes its lifecycle and per-connection lines in the tunnel category")
    func tunnelRunnerWritesItsLifecycleLines() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let profile = TunnelProfile(
            sessionID: UUID(), name: "web-\(UUID().uuidString.prefix(8))",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
            reconnects: true)
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 18_080)
        let runner = TunnelRunner(
            profile: profile, connect: connections.connect, runtimes: runtimes,
            sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .debug, directory: logDirectory, now: { fixedNow })

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        runtimes.made[0].onConnectionFailure(
            .channelOpenFailed(reason: "open failed \(Self.tunnelFailurePayload)"))
        try await states.waitFor(
            .active(connections: 0, failedConnections: 1, lastFailure: .channelOpenFailed))
        runtimes.made[0].observer?(.opened)
        try await states.waitFor(.active(connections: 1))
        runtimes.made[0].observer?(
            .closed(bytesIn: 11, bytesOut: 22, duration: .milliseconds(250)))
        try await states.waitFor(.active(connections: 0))
        connections.made[0].drop()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await states.waitFor(.active(connections: 0))
        await runner.stop()
        try await states.waitFor(.stopped)
        await DiagnosticLog.shared.flush()

        // Every line this test asserts on is one this profile's own name
        // makes unique, so a parallel suite logging into the same shared
        // sink cannot satisfy any of them.
        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(contents.contains("[info] tunnel tunnel \(profile.name) start"))
        #expect(contents.contains("[info] tunnel tunnel \(profile.name) active port=18080"))
        #expect(contents.contains("[info] tunnel tunnel \(profile.name) reconnecting attempt=1"))
        #expect(contents.contains("[info] tunnel tunnel \(profile.name) stop"))
        #expect(
            contents.contains(
                "[debug] tunnel tunnel \(profile.name) connection opened to internal:80"))
        #expect(
            contents.contains(
                "[debug] tunnel tunnel \(profile.name) connection closed to internal:80 "
                    + "in=11 out=22 ms=250"))
        // A connection the forward could not carry: one line, the kind's
        // own sentence and the bound port — never the failure's free-text
        // payload, which can be a foreign error's.
        let failedLine =
            "[debug] tunnel tunnel \(profile.name) connection failed port=18080 "
            + TunnelFailureKind.channelOpenFailed.sentence
        #expect(contents.components(separatedBy: failedLine).count - 1 == 1)
        let payloadInLog = contents.contains(Self.tunnelFailurePayload)
        #expect(payloadInLog == false)
    }

    /// A per-connection failure the report reader delivers while a lost
    /// attempt is being released still logs the port the forward was bound
    /// to — never `port=-`.
    ///
    /// Recorded 2026-09-17 in `docs/BACKLOG.md` ("A per-connection failure
    /// logged while a forward is torn down prints `port=-`"):
    /// `releaseCurrent()` dropped the runtime before it awaited the report
    /// reader, and the `debug` line read the port off that runtime. The
    /// window is held open deterministically: the first runtime's `stop()`
    /// is gated, so the failure is sent while the lost attempt's release is
    /// parked inside it, after the runtime was let go and before the reader
    /// was awaited.
    ///
    /// The negative (no `port=-` line) sits beside the positive (the line
    /// with the real port is there exactly once), so the absence is about a
    /// line that was written.
    @Test("TunnelRunner logs a failure drained while a lost attempt is released with its port")
    func tunnelRunnerLogsADrainedFailureWithItsPort() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let profile = TunnelProfile(
            sessionID: UUID(), name: "web-\(UUID().uuidString.prefix(8))",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
            reconnects: true)
        let latch = TunnelLatch()
        defer { latch.release() }
        let connections = TunnelFakeConnections()
        let runtimes = TunnelFakeRuntimes(boundPort: 18_081, firstStopGate: latch)
        let runner = TunnelRunner(
            profile: profile, connect: connections.connect, runtimes: runtimes,
            sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .debug, directory: logDirectory, now: { fixedNow })

        await runner.start(decider: .asking { _ in true })
        try await states.waitFor(.active(connections: 0))
        connections.made[0].drop()
        try await pollUntil("the lost attempt's release to be parked in its stop") {
            runtimes.made[0].stopEntered == 1
        }
        runtimes.made[0].onConnectionFailure(.channelOpenFailed(reason: "refused"))
        latch.release()
        try await states.waitFor(.reconnecting(attempt: 1))
        try await states.waitFor(.active(connections: 0))
        await runner.stop()
        try await states.waitFor(.stopped)
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        let sentence = TunnelFailureKind.channelOpenFailed.sentence
        let withThePort =
            "[debug] tunnel tunnel \(profile.name) connection failed port=18081 \(sentence)"
        let withoutAPort =
            "[debug] tunnel tunnel \(profile.name) connection failed port=- \(sentence)"
        #expect(contents.components(separatedBy: withThePort).count - 1 == 1)
        let portlessLine = contents.contains(withoutAPort)
        #expect(portlessLine == false)
    }

    /// Stands in for text a foreign error could put in a per-connection
    /// failure's `reason:` — an address the log must not carry.
    private static let tunnelFailurePayload = "198.51.100.23:5432"

    /// The `failed` line carries `reason=` through the sanctioned overload.
    ///
    /// Fix round 1, SPEC: the line used to interpolate the already-mapped
    /// sentence into the message itself, so it read `failed <sentence>` with
    /// no `reason=` key — a line nobody could `grep "reason="` for alongside
    /// every other failure this app writes. `DiagnosticLog
    /// .log(_:_:_:reason:)` is the one place that key may be formatted; it
    /// runs `DialSupport.reason(for:)` itself, which is why the runner now
    /// carries the ERROR in `AttemptOutcome.failed` rather than its text.
    ///
    /// A host-key MISMATCH is the fixture because it is both a first-attempt
    /// `failed` (never a confirmation — the TOFU hard stop) and one of the
    /// four error types `DialSupport.reason(for:)` spells out, so the line
    /// proves the mapping ran rather than merely that something was
    /// appended.
    ///
    /// Pinned on the WHOLE line, host included, rather than a prefix
    /// (maintainer decision, 2026-09-16, Task 1): the mismatch sentence no
    /// longer has a fingerprint tail to stop short of, so there is nothing
    /// left a prefix check would be avoiding. The two fingerprints below are
    /// named `let`s, and their absence from the written line is checked as
    /// Bools computed before the `#expect`s that read them (CLAUDE.md, "A
    /// value a test must not leak has two exits") — even though these are
    /// fixture strings, not real key material, the same discipline keeps a
    /// future real fingerprint from being pasted into a failure message by
    /// habit.
    @Test("TunnelRunner's failed line carries reason= through the audited mapper")
    func tunnelRunnerFailedLineCarriesAMappedReason() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let expectedFingerprint = "SHA256:aaa"
        let presentedFingerprint = "SHA256:bbb"
        let profile = TunnelProfile(
            sessionID: UUID(), name: "web-\(UUID().uuidString.prefix(8))",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
            reconnects: true)
        let connections = TunnelFakeConnections()
        connections.failAttempts(
            [1],
            with: HostKeyError.mismatch(
                host: "example.test", expected: expectedFingerprint,
                presented: presentedFingerprint))
        let runner = TunnelRunner(
            profile: profile, connect: connections.connect,
            runtimes: TunnelFakeRuntimes(boundPort: 8080),
            sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .info, directory: logDirectory, now: { fixedNow })

        await runner.start(decider: .asking { _ in true })
        try await states.waitForFailure()
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(
            contents.contains(
                "[info] tunnel tunnel \(profile.name) failed reason=host key MISMATCH for "
                    + "example.test: the presented key differs from the recorded one"))

        let containsExpectedFingerprint = contents.contains(expectedFingerprint)
        let containsPresentedFingerprint = contents.contains(presentedFingerprint)
        #expect(containsExpectedFingerprint == false)
        #expect(containsPresentedFingerprint == false)
    }

    /// The low-level pin behind the integration-level check above, direct on
    /// `DialSupport.reason(for:)` itself rather than through the tunnel
    /// runner and the log sink — so a future consumer of the mapper (Task
    /// 1's Step 2 counts 19 call sites across the tree) is covered by a test
    /// that does not also depend on `TunnelRunner`'s or `DiagnosticLog`'s own
    /// plumbing staying exactly as it is today.
    @Test("DialSupport.reason(for:) names the host, never either fingerprint, for a mismatch")
    func dialSupportReasonNamesTheHostNeverTheFingerprintsForAMismatch() {
        let expectedFingerprint = "SHA256:ccc"
        let presentedFingerprint = "SHA256:ddd"

        let sentence = DialSupport.reason(
            for: HostKeyError.mismatch(
                host: "rig.invalid", expected: expectedFingerprint,
                presented: presentedFingerprint))

        #expect(
            sentence
                == "host key MISMATCH for rig.invalid: the presented key differs from the recorded one"
        )

        let containsExpectedFingerprint = sentence.contains(expectedFingerprint)
        let containsPresentedFingerprint = sentence.contains(presentedFingerprint)
        #expect(containsExpectedFingerprint == false)
        #expect(containsPresentedFingerprint == false)
    }

    /// The same key, for the failure a user actually has to act on: a local
    /// port that is already taken.
    ///
    /// Round 2, IMPORTANT: `DialSupport.reason(for:)` had no `TunnelFailure`
    /// arm and `TunnelFailure` conforms to no `LocalizedError`, so the whole
    /// family reached this line as Foundation's generic sentence with a case
    /// INDEX in it — `portInUse(port: 8080)` wrote "(macSCPCore.TunnelFailure
    /// error 0.)" and dropped the port, which is the one thing the line
    /// exists to say. The arm added in that round is pinned here, on the
    /// whole sentence rather than a prefix.
    ///
    /// The failure is planted on the runtime START, not on the dial, because
    /// that is where a bind failure really comes from — the listener is what
    /// takes the port.
    @Test("TunnelRunner's failed line names the port a bind could not take")
    func tunnelRunnerFailedLineNamesAPortInUse() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off, directory: logDirectory) }

        let profile = TunnelProfile(
            sessionID: UUID(), name: "web-\(UUID().uuidString.prefix(8))",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80))
        let runtimes = TunnelFakeRuntimes(boundPort: 8080)
        runtimes.failStarts([1], with: TunnelFailure.portInUse(port: 8080))
        let runner = TunnelRunner(
            profile: profile, connect: TunnelFakeConnections().connect,
            runtimes: runtimes, sleeper: TunnelRecordedSleeper().sleep)
        let states = TunnelStateCollector(runner.states)

        let fixedNow = Date()
        DiagnosticLog.shared.configure(
            level: .info, directory: logDirectory, now: { fixedNow })

        await runner.start(decider: .asking { _ in true })
        try await states.waitForFailure()
        await DiagnosticLog.shared.flush()

        let contents = fileContents(ownFileURL(directory: logDirectory, fixedNow: fixedNow))
        #expect(
            contents.contains(
                "[info] tunnel tunnel \(profile.name) failed reason=port 8080 is already in use"))
    }
}
