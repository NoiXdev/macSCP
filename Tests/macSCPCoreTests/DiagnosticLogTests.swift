import Foundation
import Testing

@testable import macSCPCore

/// The sink's own behaviour — level filtering, ordering, formatting,
/// rotation, the writer's off-caller shape, `flushSynchronously()` — none
/// of which needs the process-wide production singleton at all.
///
/// Diagnostic-log plan, final fix round 2: every test below constructs its
/// OWN `DiagnosticLog()` (the type's `init` is `internal`, reachable only
/// through `@testable import`, exactly like `setWriterGateForTesting`) and
/// configures THAT instance into its own temporary directory. Round 1 had
/// these tests sharing `DiagnosticLog.shared` under a `.serialized` suite,
/// which only kept two tests IN THIS FILE from racing each other — it said
/// nothing about `ConnectionViewModelTests`/`LocalFileSystemTests`/
/// `TransferEngineTests`, which run in parallel and whose own production
/// code paths log into that SAME shared singleton whenever it happens to
/// be configured at `.info`/`.debug`. Round 1 patched the symptom (every
/// count/`.first` assertion filtered by a per-test marker); round 2 removes
/// the cause: an instance owned by one test cannot be reached by any other
/// suite's code, so there is nothing left to filter, and every marker that
/// round 1 added back is gone from the tests below (see the final fix
/// report's round 2 section for the removed lines).
///
/// `.serialized` is gone too, for the same reason: nothing here shares
/// mutable state with anything else any more, so nothing stops these tests
/// from running in parallel with each other. The handful that still touch
/// the process-wide singleton — because the PRODUCTION CODE under test
/// calls `DiagnosticLog.shared` directly and cannot be pointed at anything
/// else — live in `DiagnosticLogSharedSinkTests.swift` instead, the one
/// file `DiagnosticLogSharedSinkIsolationGuardTests` lets mention
/// `DiagnosticLog.shared`.
///
/// `.timeLimit(.minutes(1))`: nothing here waits on a wall clock — every
/// wait is either an `await flush()` (which the writer resolves through a
/// sequence number, never a timer) or a synchronous read — so the limit is
/// a backstop against a genuine hang, not a duration this suite is expected
/// to approach.
@Suite("DiagnosticLog", .timeLimit(.minutes(1)))
struct DiagnosticLogTests {
    /// A fresh, empty directory under the system temp directory, removed by
    /// the caller in a `defer` — never `~/Library/Logs/macSCP` itself, so a
    /// test can never touch a real log a person might be looking at.
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticLogTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileContents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("a debug line is dropped at .info and kept at .debug")
    func debugLineFilteredByLevel() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "kept-info-marker")
        log.log(.debug, "test", "dropped-debug-marker")
        await log.flush()

        let url = try #require(log.currentFileURL)
        let afterInfo = fileContents(url)
        #expect(afterInfo.contains("kept-info-marker"))
        #expect(!afterInfo.contains("dropped-debug-marker"))

        log.configure(level: .debug, directory: directory)
        log.log(.debug, "test", "kept-debug-marker")
        await log.flush()

        let afterDebug = fileContents(url)
        #expect(afterDebug.contains("kept-debug-marker"))
    }

    @Test("at .off nothing is written and no file is created")
    func offLevelWritesNothing() async {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .off, directory: directory)
        log.log(.error, "test", "unreachable")
        await log.flush()

        #expect(log.currentFileURL == nil)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(entries.isEmpty)
    }

    @Test("the autoclosure of a dropped line is never evaluated")
    func droppedLineNeverEvaluatesItsMessage() async {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .info, directory: directory)

        let counter = EvaluationCounter()
        log.log(.debug, "test", counter.touch())
        await log.flush()

        let evaluated = counter.count == 0
        #expect(evaluated)
    }

    @Test("three lines in call order are three lines in file order")
    func linesPreserveCallOrder() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .debug, directory: directory)
        log.log(.info, "test", "first")
        log.log(.info, "test", "second")
        log.log(.info, "test", "third")
        await log.flush()

        let url = try #require(log.currentFileURL)
        let lines = fileContents(url).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("first"))
        #expect(lines[1].hasSuffix("second"))
        #expect(lines[2].hasSuffix("third"))
    }

    @Test("the line format matches timestamp, level, category, message")
    func lineFormatMatchesRegex() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .info, directory: directory)
        log.log(.info, "browser.local", "list start path=/x")
        await log.flush()

        let url = try #require(log.currentFileURL)
        let line = fileContents(url).split(separator: "\n").map(String.init).first ?? ""

        let pattern =
            #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[info\] browser\.local list start path=/x$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, range: range) != nil)
    }

    @Test("the line format carries a numeric offset in UTC too, never Z")
    func lineFormatUsesNumericOffsetInUTC() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let utc = try #require(TimeZone(identifier: "UTC"))
        log.configure(level: .info, directory: directory, timeZone: utc)
        log.log(.info, "browser.local", "list start path=/x")
        await log.flush()

        let url = try #require(log.currentFileURL)
        let line = fileContents(url).split(separator: "\n").map(String.init).first ?? ""

        // The exact same pattern `lineFormatMatchesRegex` checks against the
        // local zone: `[+-]\d{2}:\d{2}`, never a bare `Z`. A CI runner
        // configured for UTC exercises exactly this path, which is why it
        // is pinned directly here rather than left to depend on whatever
        // zone the machine running the suite happens to be in.
        let pattern =
            #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[info\] browser\.local list start path=/x$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, range: range) != nil)
        let timestamp = line.split(separator: " ").first.map(String.init) ?? ""
        #expect(timestamp.hasSuffix("+00:00"))
        #expect(!timestamp.hasSuffix("Z"))
    }

    @Test("a message with \\n is written with the line-break glyph")
    func messageNewlineIsReplaced() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "line one\nline two")
        await log.flush()

        let url = try #require(log.currentFileURL)
        let contents = fileContents(url)
        #expect(contents.contains("line one⏎line two"))
        #expect(!contents.contains("line one\nline two"))
    }

    @Test("rotation deletes a file older than 7 days and keeps a newer one")
    func rotationPrunesOldFiles() throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldFile = directory.appending(path: "macSCP-2026-08-20.log")
        let recentFile = directory.appending(path: "macSCP-2026-09-01.log")
        #expect(FileManager.default.createFile(atPath: oldFile.path, contents: Data("old".utf8)))
        #expect(
            FileManager.default.createFile(
                atPath: recentFile.path, contents: Data("recent".utf8)))

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 4
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let fixedNow = try #require(calendar.date(from: components))

        log.configure(level: .off, directory: directory, now: { fixedNow })

        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: recentFile.path))
    }

    @Test("configure(.off) after lines were written closes the handle")
    func offAfterWritingClosesHandle() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "before off")
        await log.flush()
        let writtenURL = try #require(log.currentFileURL)
        #expect(FileManager.default.fileExists(atPath: writtenURL.path))

        log.configure(level: .off, directory: directory)
        #expect(log.currentFileURL == nil)

        log.log(.info, "test", "after off")
        await log.flush()
        #expect(log.currentFileURL == nil)

        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(entries.count == 1)
    }

    @Test("configure(.off) resolves a flush() registered for lines it just dropped")
    func offResolvesAPendingFlush() async {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A gate that never opens on its own, installed BEFORE any line is
        // logged. The writer is parked idle (a fresh instance's writer
        // task has never run at all yet) and only checks this gate on its
        // NEXT wake — so once this is installed, the writer provably
        // cannot drain anything until `gate.signal()` runs, below.
        let gate = AsyncSignal()
        log.setWriterGateForTesting { _ = await gate.wait() }
        defer { log.setWriterGateForTesting(nil) }
        // A safety net, not the test's own signal below: `gate.signal()` is
        // idempotent (`AsyncSignal.signal()`'s own doc comment), so this
        // costs nothing when the test reaches its own `gate.signal()` call
        // normally. Without it, a failed `#expect`/`#require` between here
        // and that call would return early and leave the writer parked on a
        // gate nothing else in the process ever opens — hanging every LATER
        // `flush()` this instance's writer is asked for.
        defer { gate.signal() }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "one")
        log.log(.info, "test", "two")

        // Provably not drained: the writer cannot have passed the gate, so
        // nothing it would write can exist yet — no longer merely assumed
        // from a lack of `await`, but guaranteed by construction.
        #expect(log.currentFileURL == nil)
        let beforeOff =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(beforeOff.isEmpty)

        // `configure(.off)` is what is under test: with the writer
        // permanently gated, NOTHING will ever drain these two lines, so
        // it must resolve `pendingSequence` itself rather than leave the
        // `flush()` below registered against a drain that can never
        // happen.
        log.configure(level: .off, directory: directory)
        await log.flush()

        // Opening the gate lets the writer run at last, but the buffer it
        // would drain was already dropped by `configure(.off)` above — so
        // no file can appear from here on, regardless of when the writer
        // actually wakes up and finds nothing to do. No synchronization
        // with the writer is needed for this assertion to be sound.
        gate.signal()
        let afterOpen =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(afterOpen.isEmpty)
    }

    /// Final whole-plan review, Important: `writeRun` used to read
    /// `s.fileHandle` under `state`'s lock, release the lock, and only then
    /// call `handle.write(_:)` — outside any lock. `configure(.off)` closes
    /// that same handle under `state`'s lock alone (it never takes
    /// `writeLock`), so a `configure(.off)` landing in the gap between the
    /// read and the write closed a handle a write was still about to reach.
    /// `FileHandle.write(_:)` on an already-closed handle raises
    /// `NSFileHandleOperationException` — an uncaught Objective-C
    /// exception, confirmed against this exact API by a standalone probe
    /// outside this suite (see the final fix report): it aborts the whole
    /// process rather than becoming a Swift error a `do`/`catch` or `try?`
    /// could intercept. The fix moves the write inside the SAME
    /// `state.withLock` call that reads/opens the handle (so `configure`
    /// cannot close it out from under an in-progress write) and switches to
    /// `write(contentsOf:)`, a throwing API, so `try?` can drop a line on
    /// an I/O failure as a second, independent backstop.
    ///
    /// This test drives the exact sequence the finding names — writer
    /// gated, two lines logged, `configure(.off)`, gate opened — and pins
    /// the outcome a caller can observe: no crash reaching the final
    /// `#expect`, `flush()` returns, and the two lines (dropped by `.off`
    /// before the writer ever got to drain them) never reach disk. It
    /// shares `offResolvesAPendingFlush`'s shape on purpose: with the
    /// writer gated for its ENTIRE lifetime up to `gate.signal()`, the
    /// buffer is already empty by the time the writer's drain runs, so
    /// `writeRun` is never reached in EITHER the pre-fix or the post-fix
    /// code — `setWriterGateForTesting`'s gate sits BEFORE
    /// `drainAndWriteUntilEmpty` starts, not inside it, so no seam here can
    /// force the single-instruction race window between reading and
    /// writing the handle. Forcing that window deterministically would mean
    /// racing `configure(.off)` against an in-flight write on the pre-fix
    /// code, which — if it lands — aborts the whole `swift test` process
    /// rather than reporting a red test; that is not a risk to take inside
    /// the shared test binary. What this test verifies is that the fixed
    /// lock order and the throwing write API introduce no regression in the
    /// already-covered `offResolvesAPendingFlush` behaviour.
    @Test("configure(.off) while the writer is gated with lines buffered does not crash, and flush() still returns")
    func offWhileWriterGatedWithBufferedLinesDoesNotCrash() async {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = AsyncSignal()
        log.setWriterGateForTesting { _ = await gate.wait() }
        defer { log.setWriterGateForTesting(nil) }
        defer { gate.signal() }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "one")
        log.log(.info, "test", "two")

        log.configure(level: .off, directory: directory)
        await log.flush()

        gate.signal()

        // Reaching this line at all is the primary property: the process
        // did not abort. The file assertion is the secondary one — the two
        // buffered lines were dropped by `.off`, never written.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(entries.isEmpty)
    }

    /// `flushSynchronously()` (Diagnostic Log plan, Task 2 round 1): the
    /// path `AppDelegate.applicationWillTerminate` calls, where nothing can
    /// be `await`ed. Same writer-gate shape as `offResolvesAPendingFlush`
    /// above — the gate is installed and never opened until after every
    /// assertion, so both lines are PROVABLY still sitting in the buffer,
    /// undrained by the writer task, at the moment `flushSynchronously()` is
    /// called; a call that happened to work only because the writer's own
    /// `Task` got there first would not be exercised by this test at all.
    @Test("flushSynchronously() writes buffered lines in order without the writer task ever running")
    func flushSynchronouslyWritesBufferedLinesWithTheWriterGated() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = AsyncSignal()
        log.setWriterGateForTesting { _ = await gate.wait() }
        defer { log.setWriterGateForTesting(nil) }
        // Safety net — see `offResolvesAPendingFlush`'s own comment on its
        // matching `defer`: idempotent, so it costs nothing once the test
        // reaches its own `gate.signal()` below, and keeps a failed
        // `#expect`/`#require` above that call from parking the writer
        // forever.
        defer { gate.signal() }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "one")
        log.log(.info, "test", "two")

        // Provably not drained by the writer, exactly as
        // offResolvesAPendingFlush establishes above.
        #expect(log.currentFileURL == nil)
        let beforeSync =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(beforeSync.isEmpty)

        // The call under test: synchronous, no `await`, and the writer
        // remains gated throughout — nothing here depends on its `Task`
        // ever running.
        log.flushSynchronously()

        let url = try #require(log.currentFileURL)
        let lines = fileContents(url).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("one"))
        #expect(lines[1].hasSuffix("two"))

        // Cleanup only, asserted nowhere above: releases the writer so it
        // does not stay parked forever. Its own eventual (no-op, since the
        // buffer is already empty) wake cannot add or reorder anything the
        // assertions above already read.
        gate.signal()
    }

    /// Diagnostic Log plan, Task 2 round 2: `flushSynchronously()` must not
    /// merely write what it drains correctly (the test above already pins
    /// that) — the writer, once its gate finally opens, must find NOTHING
    /// left to write. Before round 2's fix, `drainAndWriteUntilEmpty` took
    /// its batch under `state`'s lock, released it, and only acquired
    /// `writeLock` afterward — so a batch taken here (lines "one"/"two")
    /// and a batch the writer takes later could in principle be written in
    /// either order, or (if this test's own batch were somehow taken
    /// twice) duplicated. This test cannot force that specific
    /// interleaving deterministically — see the round 2 report section for
    /// why the red for that finding is a reviewer's trace of the locking,
    /// not a run of this test — but it does pin the property the fix
    /// restores end to end: `flushSynchronously()` drains everything, the
    /// writer's own later drain (once unblocked) sees an empty buffer, and
    /// a final `await flush()` returns with the file still holding exactly
    /// "one" then "two", never either line twice.
    @Test("flushSynchronously() then the writer waking up leaves the file with each line exactly once, in order")
    func flushSynchronouslyThenTheWriterWakingUpWritesNothingMore() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = AsyncSignal()
        log.setWriterGateForTesting { _ = await gate.wait() }
        defer { log.setWriterGateForTesting(nil) }
        // Safety net — see `offResolvesAPendingFlush`'s own comment on its
        // matching `defer`: idempotent, so it costs nothing once the test
        // reaches its own `gate.signal()` below, and keeps a failed
        // `#expect`/`#require` above that call from parking the writer
        // forever.
        defer { gate.signal() }

        log.configure(level: .info, directory: directory)
        log.log(.info, "test", "one")
        log.log(.info, "test", "two")

        // `flushSynchronously()` is NOT gated (the gate belongs to
        // `runWriter`'s loop alone) — it drains and writes both lines here,
        // synchronously, while the writer task is still parked behind the
        // gate.
        log.flushSynchronously()

        // Now let the writer proceed and, separately, wait for whatever IT
        // drains (nothing, since flushSynchronously already took the whole
        // buffer) to be reported flushed — proving the writer's own wake
        // does not hang and does not find a second copy of the buffer to
        // write.
        gate.signal()
        await log.flush()

        let url = try #require(log.currentFileURL)
        let lines = fileContents(url).split(separator: "\n").map(String.init)
        #expect(lines.count == 2, """
            expected exactly 2 lines (\"one\" then \"two\") after \
            flushSynchronously() plus the writer's own later wake -- \
            \(lines.count) means a line was either dropped or duplicated.
            """)
        #expect(lines[0].hasSuffix("one"))
        #expect(lines[1].hasSuffix("two"))
    }

    @Test("a batch spanning midnight is written to two files, one line each")
    func batchSpanningMidnightSplitsAcrossFiles() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var beforeMidnight = DateComponents()
        beforeMidnight.year = 2026
        beforeMidnight.month = 9
        beforeMidnight.day = 4
        beforeMidnight.hour = 23
        beforeMidnight.minute = 59
        beforeMidnight.second = 59
        var afterMidnight = DateComponents()
        afterMidnight.year = 2026
        afterMidnight.month = 9
        afterMidnight.day = 5
        afterMidnight.hour = 0
        afterMidnight.minute = 0
        afterMidnight.second = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let firstInstant = try #require(calendar.date(from: beforeMidnight))
            .addingTimeInterval(0.999)
        let secondInstant = try #require(calendar.date(from: afterMidnight))
            .addingTimeInterval(0.001)

        // `configure` itself reads `now()` once, for rotation — the clock
        // returns `firstInstant` for every call up to and including that
        // one, then `firstInstant` again for the FIRST logged line, then
        // `secondInstant` for the second — so the two lines under test are
        // exactly the two `log` calls below, regardless of how many times
        // `now` was already read before them.
        let clock = SequencedClock(values: [firstInstant, firstInstant, secondInstant])
        log.configure(level: .info, directory: directory, now: clock.next)
        log.log(.info, "test", "last line of the day")
        log.log(.info, "test", "first line of the next day")
        await log.flush()

        let firstFile = directory.appending(path: "macSCP-2026-09-04.log")
        let secondFile = directory.appending(path: "macSCP-2026-09-05.log")

        let firstLines = fileContents(firstFile).split(separator: "\n").map(String.init)
        let secondLines = fileContents(secondFile).split(separator: "\n").map(String.init)
        #expect(firstLines.count == 1)
        #expect(secondLines.count == 1)
        #expect(firstLines.first?.hasSuffix("last line of the day") == true)
        #expect(secondLines.first?.hasSuffix("first line of the next day") == true)
    }

    @Test("log and flush return without crashing when the directory cannot be created")
    func writesNothingWhenDirectoryCannotBeCreated() async {
        let log = DiagnosticLog()
        // A regular FILE where the log directory would need to go: every
        // `createDirectory(at:)` under it fails, on every platform, without
        // needing a permissions trick.
        let blockerFile = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticLogTests-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blockerFile.path, contents: Data("blocker".utf8))
        defer { try? FileManager.default.removeItem(at: blockerFile) }
        let unusableDirectory = blockerFile.appending(path: "macSCP")

        log.configure(level: .info, directory: unusableDirectory)
        log.log(.info, "test", "should not crash")
        await log.flush()

        #expect(!FileManager.default.fileExists(atPath: unusableDirectory.path))
    }
}

/// Counts how many times its `touch()` autoclosure body actually ran.
///
/// A named constant would not help here — the property under test is
/// whether the closure ran AT ALL, not a value it could leak — so this
/// exists purely to be asked `count == 0` after the call, never printed.
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func touch() -> String {
        lock.lock()
        storage += 1
        lock.unlock()
        return "touched"
    }
}

/// A `now` stub that returns `values` in order, one per call, and repeats
/// the last one for any call past the end — so a test does not have to
/// predict exactly how many times `DiagnosticLog` reads the clock before
/// the calls it actually cares about (`configure` itself reads it once,
/// for rotation, ahead of whatever `log` calls follow).
private final class SequencedClock: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Date]
    private var index = 0

    init(values: [Date]) {
        self.values = values
    }

    var next: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}
