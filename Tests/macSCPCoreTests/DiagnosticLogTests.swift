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

    /// Lines this test itself wrote, out of a file `DiagnosticLog.shared`
    /// may also be receiving lines from another suite running in parallel.
    ///
    /// `.serialized` (on this suite's own `@Suite`) only keeps two tests
    /// IN THIS FILE from configuring the shared sink at once — it says
    /// nothing about `LocalFileSystemTests`, `TransferEngineTests`, or any
    /// other suite that runs concurrently with this one and logs through
    /// the very same process-wide `DiagnosticLog.shared` while this suite
    /// holds `.info`/`.debug`. A raw `lines.count` on the file this test
    /// configured could count a line a different suite's production code
    /// happened to write into the same file during that window. Filtering
    /// by both `category` (the field the format spells as `] <category> `)
    /// and a `marker` unique to this one test call narrows the count back
    /// down to lines only this call could have produced.
    private func ownLines(_ contents: String, category: String, marker: String) -> [String] {
        contents.split(separator: "\n").map(String.init)
            .filter { $0.contains("] \(category) ") && $0.contains(marker) }
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
        let marker = UUID().uuidString

        DiagnosticLog.shared.configure(level: .debug, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "\(marker) first")
        DiagnosticLog.shared.log(.info, "test", "\(marker) second")
        DiagnosticLog.shared.log(.info, "test", "\(marker) third")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let lines = ownLines(fileContents(url), category: "test", marker: marker)
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("first"))
        #expect(lines[1].hasSuffix("second"))
        #expect(lines[2].hasSuffix("third"))
    }

    @Test("the line format matches timestamp, level, category, message")
    func lineFormatMatchesRegex() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = UUID().uuidString

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "browser.local", "list start path=/x-\(marker)")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        // `.first`, not the raw file's first line: another suite's
        // production code can log a `browser.local` line into this same
        // process-wide sink while this test holds `.info` (see `ownLines`'
        // own doc comment), and that line could land ahead of this one.
        // The marker (baked into the path, since the pattern below anchors
        // the message with `$`) picks this call's own line out regardless
        // of where it landed.
        let line = ownLines(fileContents(url), category: "browser.local", marker: marker).first ?? ""

        let pattern =
            #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[info\] browser\.local list start path=/x-\#(marker)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        #expect(regex.firstMatch(in: line, range: range) != nil)
    }

    @Test("the line format carries a numeric offset in UTC too, never Z")
    func lineFormatUsesNumericOffsetInUTC() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = UUID().uuidString

        let utc = try #require(TimeZone(identifier: "UTC"))
        DiagnosticLog.shared.configure(level: .info, directory: directory, timeZone: utc)
        DiagnosticLog.shared.log(.info, "browser.local", "list start path=/x-\(marker)")
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        // Same reasoning as `lineFormatMatchesRegex` above: filtered by
        // this call's own marker, not the file's raw first line.
        let line = ownLines(fileContents(url), category: "browser.local", marker: marker).first ?? ""

        // The exact same pattern `lineFormatMatchesRegex` checks against the
        // local zone: `[+-]\d{2}:\d{2}`, never a bare `Z`. A CI runner
        // configured for UTC exercises exactly this path, which is why it
        // is pinned directly here rather than left to depend on whatever
        // zone the machine running the suite happens to be in.
        let pattern =
            #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[info\] browser\.local list start path=/x-\#(marker)$"#
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
        // A safety net, not the test's own signal below: `gate.signal()` is
        // idempotent (`AsyncSignal.signal()`'s own doc comment), so this
        // costs nothing when the test reaches its own `gate.signal()` call
        // normally. Without it, a failed `#expect`/`#require` between here
        // and that call would return early and leave the writer parked on a
        // gate nothing else in the process ever opens — hanging every LATER
        // `flush()` this process calls, not just this test's.
        defer { gate.signal() }

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
    /// code — like `flushSynchronouslyThenTheWriterWakingUpWritesNothingMore`'s
    /// own doc comment states for a sibling finding, `setWriterGateForTesting`'s
    /// gate sits BEFORE `drainAndWriteUntilEmpty` starts, not inside it, so
    /// no seam here can force the single-instruction race window between
    /// reading and writing the handle. Forcing that window deterministically
    /// would mean racing `configure(.off)` against an in-flight write on
    /// the pre-fix code, which — if it lands — aborts the whole `swift
    /// test` process rather than reporting a red test; that is not a risk
    /// to take inside the shared test binary. What this test verifies is
    /// that the fixed lock order and the throwing write API introduce no
    /// regression in the already-covered `offResolvesAPendingFlush`
    /// behaviour.
    @Test("configure(.off) while the writer is gated with lines buffered does not crash, and flush() still returns")
    func offWhileWriterGatedWithBufferedLinesDoesNotCrash() async {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gate = AsyncSignal()
        DiagnosticLog.shared.setWriterGateForTesting { _ = await gate.wait() }
        defer { DiagnosticLog.shared.setWriterGateForTesting(nil) }
        defer { gate.signal() }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "one")
        DiagnosticLog.shared.log(.info, "test", "two")

        DiagnosticLog.shared.configure(level: .off, directory: directory)
        await DiagnosticLog.shared.flush()

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
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = UUID().uuidString

        let gate = AsyncSignal()
        DiagnosticLog.shared.setWriterGateForTesting { _ = await gate.wait() }
        defer { DiagnosticLog.shared.setWriterGateForTesting(nil) }
        // Safety net — see `offResolvesAPendingFlush`'s own comment on its
        // matching `defer`: idempotent, so it costs nothing once the test
        // reaches its own `gate.signal()` below, and keeps a failed
        // `#expect`/`#require` above that call from parking the writer
        // forever.
        defer { gate.signal() }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "\(marker) one")
        DiagnosticLog.shared.log(.info, "test", "\(marker) two")

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
        let lines = ownLines(fileContents(url), category: "test", marker: marker)
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
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = UUID().uuidString

        let gate = AsyncSignal()
        DiagnosticLog.shared.setWriterGateForTesting { _ = await gate.wait() }
        defer { DiagnosticLog.shared.setWriterGateForTesting(nil) }
        // Safety net — see `offResolvesAPendingFlush`'s own comment on its
        // matching `defer`: idempotent, so it costs nothing once the test
        // reaches its own `gate.signal()` below, and keeps a failed
        // `#expect`/`#require` above that call from parking the writer
        // forever.
        defer { gate.signal() }

        DiagnosticLog.shared.configure(level: .info, directory: directory)
        DiagnosticLog.shared.log(.info, "test", "\(marker) one")
        DiagnosticLog.shared.log(.info, "test", "\(marker) two")

        // `flushSynchronously()` is NOT gated (the gate belongs to
        // `runWriter`'s loop alone) — it drains and writes both lines here,
        // synchronously, while the writer task is still parked behind the
        // gate.
        DiagnosticLog.shared.flushSynchronously()

        // Now let the writer proceed and, separately, wait for whatever IT
        // drains (nothing, since flushSynchronously already took the whole
        // buffer) to be reported flushed — proving the writer's own wake
        // does not hang and does not find a second copy of the buffer to
        // write.
        gate.signal()
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let lines = ownLines(fileContents(url), category: "test", marker: marker)
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
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = UUID().uuidString

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
        DiagnosticLog.shared.log(.info, "test", "\(marker) last line of the day")
        DiagnosticLog.shared.log(.info, "test", "\(marker) first line of the next day")
        await DiagnosticLog.shared.flush()

        let firstFile = directory.appending(path: "macSCP-2026-09-04.log")
        let secondFile = directory.appending(path: "macSCP-2026-09-05.log")

        // Filtered by `marker`, not raw `lines.count`: this test's own
        // `now` closure (`clock.next`) becomes the SHARED sink's `now` for
        // as long as this configuration stands, so any other suite's
        // production code that logs through the same process-wide
        // `DiagnosticLog.shared` during this narrow window lands in the
        // SAME directory and, once `clock.next` has exhausted its fixed
        // values, the SAME day file as this test's own second line
        // (`SequencedClock` repeats its last value past the end) —
        // observed directly: `secondLines.count` came back `3`, not `1`,
        // under exactly this raw count before this fix.
        let firstLines = ownLines(fileContents(firstFile), category: "test", marker: marker)
        let secondLines = ownLines(fileContents(secondFile), category: "test", marker: marker)
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

    // MARK: - Task 3: the instrumentation writes what it says

    /// `LocalFileSystem.list`'s own instrumentation (Task 3 of the
    /// diagnostic-log plan) — added here, in the already-`.serialized` suite
    /// that owns `DiagnosticLog.shared`, rather than in `LocalFileSystemTests`:
    /// that suite runs its tests in parallel and carries no serialization of
    /// its own, and the singleton this test configures is exactly the shared
    /// state `.serialized`'s own doc comment above warns two tests racing on
    /// would each see the other's `configure` call — a risk this file's
    /// tests already avoid by living here, and a new test elsewhere would
    /// reintroduce for every OTHER suite in this target, not just its own.
    ///
    /// `.debug`, not `.info`: admitting `.debug` is what makes the absence
    /// assertion below actually test the threshold logic — at `.info` an
    /// `entry slow` line could never appear regardless of whether the
    /// threshold check is right, and the absence would be trivially true.
    /// Three PLAIN files read well under `LocalFileSystem.slowEntryThreshold`
    /// (500 ms), so the negative (no `entry slow`) sits beside the positive
    /// (`list start`/`list done` ARE present) rather than standing alone.
    @Test("LocalFileSystem.list writes list start/done, with no entry-slow line for fast entries")
    func localFileSystemListWritesStartAndDoneWithoutAnEntrySlowLine() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

        let listedDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: listedDirectory) }
        for name in ["eins.txt", "zwei.txt", "drei.txt"] {
            try Data("x".utf8).write(to: listedDirectory.appendingPathComponent(name))
        }
        let listedPath = listedDirectory.path(percentEncoded: false)

        DiagnosticLog.shared.configure(level: .debug, directory: logDirectory)
        _ = try await LocalFileSystem().list(path: listedPath)
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let contents = fileContents(url)
        #expect(contents.contains("list start path=\(listedPath)"))
        #expect(contents.contains("list done path=\(listedPath) count=3"))
        #expect(!contents.contains("entry slow"))
    }

    /// `TransferEngine.copyFile`'s own instrumentation, driven against
    /// `MockRemoteFileSystem` (no rig needed — the `transfer` lines are
    /// written by the engine itself, above the SFTP layer). Lives here for
    /// the same singleton reason as the `LocalFileSystem` test above, rather
    /// than added to `TransferEngineTests` (not `.serialized`, and shared
    /// with every other test in that file).
    @Test("TransferEngine.copyFile writes transfer start/done")
    func transferEngineWritesStartAndDoneLines() async throws {
        let logDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        defer { DiagnosticLog.shared.configure(level: .off) }

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

        DiagnosticLog.shared.configure(level: .info, directory: logDirectory)
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            direction: .upload,
            onProgress: { _ in })
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let contents = fileContents(url)
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
        defer { DiagnosticLog.shared.configure(level: .off) }

        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.host = "example.com"
        vm.port = "22"
        vm.username = "tim"
        vm.password = "geheim"

        DiagnosticLog.shared.configure(level: .info, directory: logDirectory)
        _ = await vm.connect()
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let contents = fileContents(url)
        #expect(contents.contains("connect start host=example.com port=22 kind=ssh"))
        #expect(contents.contains("connect done"))
    }

    // MARK: - Fix round 1: a mapped RemoteFSError's own reason never leaks

    /// `RemoteFSError.connectionFailed(reason:)`/`.protocolError(reason:)`
    /// carry FREE TEXT — `S3FileSystem`/`WebDAVFileSystem` build it out of
    /// the endpoint the user typed, a field that takes
    /// `scheme://KEY:SECRET@host` as ordinary input. Before this fix round,
    /// `RemoteBrowserViewModel.message(for:path:)` returned that text
    /// verbatim (the on-screen banner) and `load()` wrote it to the
    /// diagnostic log via a hand-formatted `reason=\(message)` — two
    /// separate exits for the same secret. Both now route through
    /// `DialSupport.reason(for:)`, which drops the reason for exactly these
    /// two cases.
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
        defer { DiagnosticLog.shared.configure(level: .off) }

        let fs = MockRemoteFileSystem(tree: [:])
        await fs.setListFailure(RemoteFSError.connectionFailed(reason: leakingReason))
        let vm = RemoteBrowserViewModel(fs: fs, startPath: "/", logCategory: "browser.remote")

        DiagnosticLog.shared.configure(level: .info, directory: logDirectory)
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

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let logText = fileContents(url)
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
        defer { DiagnosticLog.shared.configure(level: .off) }

        let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem(tree: ["/": []]) })
        vm.kind = .s3
        vm.s3AccessKeyID = "AKIAEXAMPLE"
        vm.s3SecretAccessKey = "shh-secret"
        vm.s3Region = "eu-central-1"
        vm.s3Endpoint = "https://\(secret)@s3.example.test"
        vm.s3Bucket = "my-bucket"
        vm.s3UsePathStyle = true

        DiagnosticLog.shared.configure(level: .info, directory: logDirectory)
        _ = await vm.connect()
        await DiagnosticLog.shared.flush()

        let url = try #require(DiagnosticLog.shared.currentFileURL)
        let contents = fileContents(url)
        let inLog = contents.contains(secret)
        #expect(inLog == false)

        let hostStillPresent = contents.contains("s3.example.test")
        #expect(hostStillPresent)
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
