import Foundation
import Synchronization

/// How much a `DiagnosticLog` line matters, and how verbose the sink
/// currently is.
///
/// Ordered by declaration (`off < error < info < debug`), which is also the
/// order the design (`docs/superpowers/specs/2026-09-04-diagnostic-log-design.md`,
/// "The sink") states it in. A line is written when its own level is at most
/// the configured level — `error` passes at `.info`, `debug` does not — and
/// nothing is ever written while the configured level is `.off`, which
/// `DiagnosticLog.log` checks separately from the ordering (`.off <= .off`
/// would otherwise admit a line logged at `.off`, which no call site does,
/// but the guard does not rely on that).
public enum DiagnosticLogLevel: String, CaseIterable, Sendable, Codable {
    case off, error, info, debug
}

extension DiagnosticLogLevel: Comparable {
    /// Declaration order as an integer, so `<` reads the enum's own case
    /// order rather than a second, hand-written ranking that could drift
    /// from it.
    private var rank: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .info: return 2
        case .debug: return 3
        }
    }

    public static func < (lhs: DiagnosticLogLevel, rhs: DiagnosticLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The app-wide diagnostic log sink.
///
/// One line per call, appended to `~/Library/Logs/macSCP/macSCP-<yyyy-MM-dd>.log`
/// by a single long-lived writer task — never by the caller. `log` only ever
/// formats a string and appends it to a lock-protected buffer; the disk
/// write, the file open, and the day rollover all happen off the caller's
/// path, so a listing that logs thousands of entries is not made slower by
/// the disk, and a wedged disk cannot wedge the UI. See the design's "The
/// sink" section for the line format and the rules this type implements.
///
/// **Concurrency.** All mutable state lives in one `Mutex<State>`
/// (`Synchronization`, macOS 15+) rather than an `NSLock` behind
/// `@unchecked Sendable` — the shape most locked classes in this tree use
/// (`NetworkTrace.TraceHopCollector`, `BlockingProbe.OneShot`). `Mutex<Value>`
/// is unconditionally `Sendable` regardless of `Value`'s own sendability, so
/// wrapping every mutable field in it is what lets this class declare plain
/// `Sendable` — the conformance the design's own signature
/// (`public final class DiagnosticLog: Sendable`) states — with nothing
/// unchecked anywhere in this file.
///
/// **The writer.** `log` appends a formatted line and rings a doorbell
/// (an `AsyncStream<Void>.Continuation`, buffered to at most one pending
/// ring); a single `Task`, started lazily on the first line ever logged,
/// consumes that stream and drains the whole buffer to disk each time it
/// wakes — one task for the sink's entire lifetime, never one task per
/// line. `flush()` hands out a monotonic sequence number per appended line
/// and awaits a continuation that the writer resumes once its own
/// `flushedSequence` has caught up — no polling, no sleep.
public final class DiagnosticLog: Sendable {
    public static let shared = DiagnosticLog()

    public static let defaultDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/macSCP")

    /// How long a rotated-out file is allowed to sit in the directory before
    /// `configure` deletes it.
    private static let retention = 7

    private struct State {
        var level: DiagnosticLogLevel = .off
        var directory: URL = DiagnosticLog.defaultDirectory
        var now: @Sendable () -> Date = Date.init

        var buffer: [String] = []
        /// Incremented once per appended line, never reset. `flush()` reads
        /// this as its target; the writer reports back through
        /// `flushedSequence` once every line up to some point is on disk.
        var pendingSequence: UInt64 = 0
        var flushedSequence: UInt64 = 0
        var flushWaiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

        var fileHandle: FileHandle?
        /// The `yyyy-MM-dd` key the open handle was opened for, so a line
        /// logged after midnight rolls to a new file without being told to.
        var fileDayKey: String?

        var writerStarted = false
        var doorbell: AsyncStream<Void>.Continuation?
    }

    private let state = Mutex(State())

    private init() {}

    /// Sets the level, the directory lines are written to, and the clock the
    /// sink reads timestamps and rotation from — `now` defaults to the real
    /// clock and exists so a test can pin rotation to a fixed day.
    ///
    /// Creates `directory` (with intermediate directories) if it does not
    /// exist yet, then deletes every `macSCP-*.log` file in it whose date —
    /// parsed from its own name — is more than 7 days before `now()`. A file
    /// name that does not parse as `macSCP-<yyyy-MM-dd>.log` is left alone.
    ///
    /// Takes effect at once: a level change applies to the next `log` call,
    /// and switching TO `.off` closes the open file handle and drops
    /// whatever is still buffered and not yet on disk — those lines are
    /// never written. Safe to call while the app is running and lines are
    /// in flight.
    public func configure(
        level: DiagnosticLogLevel,
        directory: URL = DiagnosticLog.defaultDirectory,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        Self.pruneOldFiles(in: directory, now: now())

        state.withLock { s in
            s.fileHandle?.closeFile()
            s.fileHandle = nil
            s.fileDayKey = nil
            s.directory = directory
            s.now = now
            s.level = level
            if level == .off {
                s.buffer = []
            }
        }
    }

    /// Appends one line, iff `level` is admitted by the configured level.
    ///
    /// `message` is an `@autoclosure`, evaluated only when the line is going
    /// to be written — a `debug` call costs one lock and one comparison when
    /// the configured level is `.off` or `.info`.
    ///
    /// A `category` containing a space has each space replaced by `_`
    /// (categories are dotted lower-case words, and this keeps a stray space
    /// from splitting the `key=value` tail visually). A `message` containing
    /// `\n` or `\r` has each such character replaced by `⏎`, so one call to
    /// `log` is always exactly one line in the file.
    public func log(
        _ level: DiagnosticLogLevel, _ category: String,
        _ message: @autoclosure @Sendable () -> String
    ) {
        let admittedNow: (@Sendable () -> Date)? = state.withLock { s in
            guard s.level != .off, level <= s.level else { return nil }
            return s.now
        }
        guard let now = admittedNow else { return }

        let line = Self.formatLine(
            level: level, category: category, message: message(), timestamp: now())

        state.withLock { s in
            s.buffer.append(line)
            s.pendingSequence += 1
            ensureWriterStarted(&s)
            s.doorbell?.yield(())
        }
    }

    /// Returns once every line appended before this call is on disk.
    ///
    /// Captures the current pending sequence number and awaits a
    /// continuation the writer resumes once its own flushed sequence has
    /// reached at least that number — registered under the same lock that is
    /// re-checked before parking, so a writer that flushes between the first
    /// check and the registration cannot leave this call waiting forever.
    public func flush() async {
        enum Outcome {
            case alreadyFlushed
            case pending(UInt64)
        }
        let outcome = state.withLock { s -> Outcome in
            s.flushedSequence >= s.pendingSequence
                ? .alreadyFlushed : .pending(s.pendingSequence)
        }
        guard case .pending(let target) = outcome else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { s in
                if s.flushedSequence >= target {
                    continuation.resume()
                } else {
                    s.flushWaiters.append((target, continuation))
                }
            }
        }
    }

    /// The file the next line would be written to, or the file the last
    /// line WAS written to once the day has rolled — `nil` before the first
    /// line has ever opened one.
    public var currentFileURL: URL? {
        state.withLock { s in
            guard let dayKey = s.fileDayKey else { return nil }
            return s.directory.appending(path: "macSCP-\(dayKey).log")
        }
    }

    // MARK: - The writer

    /// Starts the single long-lived writer task, if it has not started yet.
    /// Called only under `state`'s lock — `writerStarted` is itself part of
    /// `State`, so two racing `log` calls cannot both start one.
    private func ensureWriterStarted(_ s: inout State) {
        guard !s.writerStarted else { return }
        s.writerStarted = true
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        s.doorbell = continuation
        Task { await self.runWriter(events: stream) }
    }

    /// The writer's whole lifetime: wait for a doorbell ring, drain
    /// everything buffered at that moment, write it, report the sequence
    /// number back, and wait again. One task, for as long as the process
    /// runs — never one task per line, never one per ring (multiple rings
    /// collapse into the one drain that follows them, since a ring says only
    /// "something is buffered", never how much).
    private func runWriter(events: AsyncStream<Void>) async {
        for await _ in events {
            drainAndWriteUntilEmpty()
        }
    }

    private func drainAndWriteUntilEmpty() {
        while true {
            let batch = state.withLock { s -> (lines: [String], sequence: UInt64, directory: URL, now: Date)? in
                guard !s.buffer.isEmpty else { return nil }
                let lines = s.buffer
                s.buffer = []
                return (lines, s.pendingSequence, s.directory, s.now())
            }
            guard let batch else { return }
            writeToDisk(lines: batch.lines, directory: batch.directory, now: batch.now)
            markFlushed(through: batch.sequence)
        }
    }

    /// Opens (or reuses) today's file and appends `lines`. Runs only on the
    /// writer task, so this is the one place in the type that touches the
    /// file system for writing — never on a caller's thread.
    private func writeToDisk(lines: [String], directory: URL, now: Date) {
        let dayKey = Self.dayKey(for: now, timeZone: .current)

        let handle = state.withLock { s -> FileHandle? in
            if s.fileHandle == nil || s.fileDayKey != dayKey {
                s.fileHandle?.closeFile()
                s.fileHandle = nil
                s.fileDayKey = nil
                guard let opened = Self.openHandle(directory: directory, dayKey: dayKey) else {
                    return nil
                }
                s.fileHandle = opened
                s.fileDayKey = dayKey
            }
            return s.fileHandle
        }
        guard let handle else { return }

        let payload = Data((lines.map { $0 + "\n" }.joined()).utf8)
        handle.write(payload)
    }

    /// Resumes every `flush()` waiter whose target sequence is now on disk.
    /// Continuations are resumed OUTSIDE the lock — the same shape
    /// `AgentEnvLock.release()` uses for its waiter queue — so resuming one
    /// can never re-enter `state`'s lock from inside the critical section
    /// that just released it.
    private func markFlushed(through sequence: UInt64) {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { s in
            guard sequence > s.flushedSequence else { return [] }
            s.flushedSequence = sequence
            var resumed: [CheckedContinuation<Void, Never>] = []
            var remaining: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in s.flushWaiters {
                if waiter.target <= sequence {
                    resumed.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            s.flushWaiters = remaining
            return resumed
        }
        for continuation in toResume { continuation.resume() }
    }

    private static func openHandle(directory: URL, dayKey: String) -> FileHandle? {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "macSCP-\(dayKey).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    // MARK: - Formatting

    /// `2026-09-04T13:02:11.417+02:00 [info] browser.local list start path=/x`
    /// — timestamp, level in brackets, category, then free `key=value` text.
    private static func formatLine(
        level: DiagnosticLogLevel, category: String, message: String, timestamp: Date
    ) -> String {
        let ts = timestampText(for: timestamp)
        let cat = sanitizeCategory(category)
        let msg = sanitizeMessage(message)
        return "\(ts) [\(level.rawValue)] \(cat) \(msg)"
    }

    /// ISO 8601 with millisecond precision and the LOCAL zone's offset —
    /// `+02:00`, never `Z` unless the zone genuinely is UTC (in which case
    /// `ISO8601FormatStyle` prints `Z` on its own; nothing here special-cases
    /// it).
    private static func timestampText(for date: Date) -> String {
        let style = Date.ISO8601FormatStyle(timeZone: .current)
            .year().month().day()
            .dateSeparator(.dash)
            .time(includingFractionalSeconds: true)
            .timeSeparator(.colon)
            .timeZone(separator: .colon)
        return date.formatted(style)
    }

    /// A space in a category would visually split the `key=value` tail, so
    /// it is replaced by `_` rather than rejected — `log` takes no failure
    /// path.
    private static func sanitizeCategory(_ category: String) -> String {
        category.replacingOccurrences(of: " ", with: "_")
    }

    /// One call to `log` is one line on disk: every `\n` and every `\r` in
    /// `message` is replaced by `⏎`, character by character (so `"\r\n"`
    /// becomes two `⏎`, not one — each of the two characters is replaced on
    /// its own, exactly as the design states it).
    private static func sanitizeMessage(_ message: String) -> String {
        String(message.map { $0 == "\n" || $0 == "\r" ? "⏎" : $0 })
    }

    /// The `yyyy-MM-dd` key a file name carries, and the key `configure`'s
    /// rotation parses file names back into.
    private static func dayKey(for date: Date, timeZone: TimeZone) -> String {
        dayKeyFormatter(timeZone: timeZone).string(from: date)
    }

    private static func dayKeyFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    // MARK: - Rotation

    /// Deletes every `macSCP-*.log` file in `directory` whose date is more
    /// than `retention` (7) days before `now`. A file name that does not
    /// parse — wrong prefix, wrong suffix, or an unparseable date — is left
    /// alone rather than guessed at.
    private static func pruneOldFiles(in directory: URL, now: Date) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let cutoff = calendar.date(byAdding: .day, value: -retention, to: now) else {
            return
        }

        let formatter = dayKeyFormatter(timeZone: .current)
        let prefix = "macSCP-"
        let suffix = ".log"
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let dateText = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard let fileDate = formatter.date(from: dateText) else { continue }
            if fileDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
