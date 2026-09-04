import Foundation
import Testing

@testable import macSCPCore

/// `DiagnosticLog` is a process-wide singleton (`.shared`) — every test in
/// this suite reconfigures it, so `.serialized` is load-bearing the same way
/// it is in `AgentEnvLock`'s callers: two of these tests running at once
/// would each see the other's `configure` call.
///
/// `.timeLimit(.minutes(1))`: nothing here waits on a wall clock — every
/// wait is either an `await flush()` (which the writer resolves through a
/// sequence number, never a timer) or a synchronous read — so the limit is
/// a backstop against a genuine hang, not a duration this suite is expected
/// to approach.
@Suite("DiagnosticLog", .serialized, .timeLimit(.minutes(1)))
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
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "kept-info-marker")
        DiagnosticLog.shared.log(.debug, "test", "dropped-debug-marker")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let afterInfo = fileContents(url)
        #expect(afterInfo.contains("kept-info-marker"))
        #expect(!afterInfo.contains("dropped-debug-marker"))

        DiagnosticLog.shared.configure(level: .debug, directory: directory)
        DiagnosticLog.shared.log(.debug, "test", "kept-debug-marker")
        await DiagnosticLog.shared.flush()

        let afterDebug = fileContents(url)
        #expect(afterDebug.contains("kept-debug-marker"))
    }

    @Test("at .off nothing is written and no file is created")
    func offLevelWritesNothing() async {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .off, directory: directory)
        DiagnosticLog.shared.log(.error, "test", "unreachable")
        await DiagnosticLog.shared.flush()

        #expect(DiagnosticLog.shared.currentFileURL == nil)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(entries.isEmpty)
    }

    @Test("the autoclosure of a dropped line is never evaluated")
    func droppedLineNeverEvaluatesItsMessage() async {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)

        let counter = EvaluationCounter()
        DiagnosticLog.shared.log(.debug, "test", counter.touch())
        await DiagnosticLog.shared.flush()

        let evaluated = counter.count == 0
        #expect(evaluated)
    }

    @Test("three lines in call order are three lines in file order")
    func linesPreserveCallOrder() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .debug, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "first")
        DiagnosticLog.shared.log(.info, "test", "second")
        DiagnosticLog.shared.log(.info, "test", "third")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let lines = fileContents(url).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("first"))
        #expect(lines[1].hasSuffix("second"))
        #expect(lines[2].hasSuffix("third"))
    }

    @Test("the line format matches timestamp, level, category, message")
    func lineFormatMatchesRegex() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "browser.local", "list start path=/x")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let line = fileContents(url).split(separator: "\n").map(String.init).first ?? ""

        let pattern =
            #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[info\] browser\.local list start path=/x$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, range: range) != nil)
    }

    @Test("the line format carries a numeric offset in UTC too, never Z")
    func lineFormatUsesNumericOffsetInUTC() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let utc = try #require(TimeZone(identifier: "UTC"))
        DiagnosticLog.shared.configure(level: .info, directory: directory, timeZone: utc)
        DiagnosticLog.shared.log(.info, "browser.local", "list start path=/x")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
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
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "line one\nline two")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let contents = fileContents(url)
        #expect(contents.contains("line one⏎line two"))
        #expect(!contents.contains("line one\nline two"))
    }

    @Test("rotation deletes a file older than 7 days and keeps a newer one")
    func rotationPrunesOldFiles() throws {
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

        DiagnosticLog.shared.configure(level: .off, directory: directory, now: { fixedNow })

        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: recentFile.path))
    }

    @Test("configure(.off) after lines were written closes the handle")
    func offAfterWritingClosesHandle() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "before off")
        await DiagnosticLog.shared.flush()
        let writtenURL = try #require(DiagnosticLog.shared.currentFileURL)
        #expect(FileManager.default.fileExists(atPath: writtenURL.path))

        DiagnosticLog.shared.configure(level: .off, directory: directory)
        #expect(DiagnosticLog.shared.currentFileURL == nil)

        DiagnosticLog.shared.log(.info, "test", "after off")
        await DiagnosticLog.shared.flush()
        #expect(DiagnosticLog.shared.currentFileURL == nil)

        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(entries.count == 1)
    }

    @Test("configure(.off) resolves a flush() registered for lines it just dropped")
    func offResolvesAPendingFlush() async {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A gate that never opens on its own, installed BEFORE any line is
        // logged. The writer is parked idle (the previous test's own
        // `flush()` guarantees it had already drained everything and
        // looped back to waiting) and only checks this gate on its NEXT
        // wake — so once this is installed, the writer provably cannot
        // drain anything until `gate.signal()` runs, below. This replaces
        // a race: the original version of this test relied on two `log`
        // calls and `configure(.off)` outrunning an already-running writer
        // task through having no `await` in between, which held on this
        // machine but was never guaranteed — see the report's Round 2
        // section.
        let gate = AsyncSignal()
        DiagnosticLog.shared.setWriterGateForTesting { _ = await gate.wait() }
        defer { DiagnosticLog.shared.setWriterGateForTesting(nil) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "one")
        DiagnosticLog.shared.log(.info, "test", "two")

        // Provably not drained: the writer cannot have passed the gate, so
        // nothing it would write can exist yet — no longer merely assumed
        // from a lack of `await`, but guaranteed by construction.
        #expect(DiagnosticLog.shared.currentFileURL == nil)
        let beforeOff =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(beforeOff.isEmpty)

        // `configure(.off)` is what is under test: with the writer
        // permanently gated, NOTHING will ever drain these two lines, so
        // it must resolve `pendingSequence` itself rather than leave the
        // `flush()` below registered against a drain that can never
        // happen. Before the round-1 fix this call hangs — see the
        // report's Round 2 section for what was actually observed
        // reverting it.
        DiagnosticLog.shared.configure(level: .off, directory: directory)
        await DiagnosticLog.shared.flush()

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
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = AsyncSignal()
        DiagnosticLog.shared.setWriterGateForTesting { _ = await gate.wait() }
        defer { DiagnosticLog.shared.setWriterGateForTesting(nil) }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "one")
        DiagnosticLog.shared.log(.info, "test", "two")

        // Provably not drained by the writer, exactly as
        // offResolvesAPendingFlush establishes above.
        #expect(DiagnosticLog.shared.currentFileURL == nil)
        let beforeSync =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(beforeSync.isEmpty)

        // The call under test: synchronous, no `await`, and the writer
        // remains gated throughout — nothing here depends on its `Task`
        // ever running.
        DiagnosticLog.shared.flushSynchronously()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let lines = fileContents(url).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("one"))
        #expect(lines[1].hasSuffix("two"))

        // Cleanup only, asserted nowhere above: releases the writer so it
        // does not stay parked for the next test in this `.serialized`
        // suite. Its own eventual (no-op, since the buffer is already
        // empty) wake cannot add or reorder anything the assertions above
        // already read.
        gate.signal()
    }

    @Test("a batch spanning midnight is written to two files, one line each")
    func batchSpanningMidnightSplitsAcrossFiles() async throws {
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
        DiagnosticLog.shared.configure(level: .info, directory: directory, now: clock.next)
        DiagnosticLog.shared.log(.info, "test", "last line of the day")
        DiagnosticLog.shared.log(.info, "test", "first line of the next day")
        await DiagnosticLog.shared.flush()

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
        // A regular FILE where the log directory would need to go: every
        // `createDirectory(at:)` under it fails, on every platform, without
        // needing a permissions trick.
        let blockerFile = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticLogTests-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blockerFile.path, contents: Data("blocker".utf8))
        defer { try? FileManager.default.removeItem(at: blockerFile) }
        let unusableDirectory = blockerFile.appending(path: "macSCP")

        DiagnosticLog.shared.configure(level: .info, directory: unusableDirectory)
        DiagnosticLog.shared.log(.info, "test", "should not crash")
        await DiagnosticLog.shared.flush()

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
