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
