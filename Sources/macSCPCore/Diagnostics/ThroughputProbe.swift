import Foundation
import Synchronization

// MARK: - What a throughput test moves

/// What the throughput step moves, and the bandwidth limits it moves it
/// under.
///
/// A value the caller hands the runner rather than something the runner
/// reads: Core reads no settings file, and the two callers differ in where
/// the numbers come from. The app passes the payload size from its settings
/// and the two SHARED buckets its transfers are paced by
/// (`BandwidthLimiter`), so the test is paced by the same limit, in the same
/// aggregate, as every transfer in every tab. `macscp-cli diagnose` passes
/// its `--payload-mib` and no bucket, because the command line applies no
/// bandwidth limit to `put` or `get` either.
public struct DiagnosticThroughputSettings: Sendable {
    /// 8 MiB: small enough to be a short visit to somebody's server, large
    /// enough that the transfer, not the round trips around it, is what the
    /// rate measures. Decided for the maintainer in the plan of 2026-09-19,
    /// and the setting's default.
    public static let defaultPayloadMiB = 8
    /// 1–256 MiB, the range the plan of 2026-09-19 decided on. The setting
    /// and the CLI option both clamp or refuse against THIS range, so there
    /// is one copy of it.
    public static let payloadMiBRange: ClosedRange<Int> = 1...256

    /// The payload in MiB, clamped into `payloadMiBRange`.
    public let payloadMiB: Int
    /// The bucket every upload of this app is paced by, or `nil` for none.
    public let uploadThrottle: BandwidthBucket?
    /// The bucket every download of this app is paced by, or `nil` for none.
    public let downloadThrottle: BandwidthBucket?

    public init(
        payloadMiB: Int = defaultPayloadMiB,
        uploadThrottle: BandwidthBucket? = nil,
        downloadThrottle: BandwidthBucket? = nil
    ) {
        self.payloadMiB = min(
            max(payloadMiB, Self.payloadMiBRange.lowerBound), Self.payloadMiBRange.upperBound)
        self.uploadThrottle = uploadThrottle
        self.downloadThrottle = downloadThrottle
    }

    /// The payload in bytes.
    var payloadBytes: Int { payloadMiB * 1024 * 1024 }
}

/// The throughput table's five columns — as catalogue keys, which is what a
/// `DiagnosticTable` carries — and the words its cells are written in.
///
/// Keys here rather than in the App for the reason `DiagnosticTraceColumn`
/// gives: the table is Core's, and the App resolves the names. The cell
/// words are English, like every word the report prints, and the panel maps
/// the two direction words through `diagnostics.throughput.direction.*`.
public enum DiagnosticThroughputColumn {
    public static let direction = "diagnostics.throughput.column.direction"
    public static let bytes = "diagnostics.throughput.column.bytes"
    public static let duration = "diagnostics.throughput.column.duration"
    public static let rate = "diagnostics.throughput.column.rate"
    public static let limit = "diagnostics.throughput.column.limit"

    /// Every column key, in the order the cells are written.
    public static let all = [direction, bytes, duration, rate, limit]

    /// The row that wrote the payload to the server.
    public static let up = "up"
    /// The row that read it back.
    public static let down = "down"
    /// What the limit column says when no bandwidth limit applied, and what
    /// the rate column says for a leg too short for a rate to mean anything.
    /// A symbol rather than a word, so it needs no translation.
    public static let none = "—"
}

/// Opens the connection the throughput step measures over — the step's one
/// seam.
///
/// The live one is `BackendDescriptor.openConnection`, the same funnel the
/// browser's tabs connect through, so what is measured is the backend's own
/// `RemoteFileSystem` and nothing written for the diagnosis. Both trust
/// questions are answered by the refusing deciders, for the reason the dial
/// step gives (`DiagnosticContribution.sshConnect`): a diagnosis has nobody
/// to ask, and a probe that trusted an unknown key would be writing a consent
/// nobody gave. The suite hands the walk an in-memory file system instead.
struct DiagnosticThroughputOpener: Sendable {
    var open:
        @Sendable (ConnectionConfig, _ timeoutSeconds: Int) async throws -> any RemoteFileSystem

    static let live = DiagnosticThroughputOpener { config, seconds in
        try await BackendDescriptor.openConnection(
            config, hostKey: .refusing, certificate: .refusing, timeoutSeconds: seconds)
    }
}

// MARK: - The measurement

/// The throughput step's measurement over an open connection: a generated
/// payload written to a uniquely named file in the session's start folder,
/// read back, compared byte for byte, and removed.
///
/// **Through the transfer path the browser uses.** Both legs are
/// `TransferEngine.copyFile` — the call every queued transfer makes — between
/// the session's own `RemoteFileSystem` and two small stand-ins on this side:
/// `ThroughputPayload`, which generates the bytes as they are pulled, and
/// `ThroughputSink`, which compares them as they arrive. Nothing is buffered
/// beyond one chunk, so a 256 MiB payload costs no 256 MiB of memory, and the
/// configured bandwidth limits pace each leg exactly as they pace a transfer
/// (`throttle:`).
///
/// **The order**, on every run: the start folder, then the leftover sweep,
/// then the upload, then the download and its byte check, then the removal.
///
/// **The removal runs on every way out once the upload has started** — a
/// finished run, a failed upload or download, a payload that came back
/// different, and a cancellation mid-transfer. A request made from a
/// cancelled task may be refused for that reason alone — a `URLSession`
/// request throws when its task is cancelled (read from its documentation,
/// not measured here); the rig's SFTP delete was measured on 2026-09-19 to
/// go through regardless — so the
/// removal does not run in the caller's task: it runs through
/// `BoundedClose.run`, whose operation is an
/// unstructured task that the caller's cancellation does not reach, and
/// which the caller still awaits up to a bound. It is the helper
/// `BoundedSFTPSession.closeBounded()` closes a session through and the
/// teardown bounds its stages with; here it is used for the property those
/// callers get with it — the operation does not inherit the caller's
/// cancellation.
///
/// **Reported, never judged.** A row is `ok` when the payload went up, came
/// back identical and was removed, whatever the two rates are. No rate
/// decides an outcome, and no test asserts one.
enum ThroughputProbe {
    /// Every test file's name starts with this, followed by a UUID in its
    /// canonical upper-case spelling and nothing else — the exact pattern the
    /// leftover sweep removes (`isLeftover(_:)`). A leading dot keeps the
    /// file out of a default listing; the word keeps it recognisable to a
    /// person who finds one.
    static let namePrefix = ".macscp-throughput-"

    /// The backstop on the removal and on the step's closing of its
    /// connection: how long either may take before the step stops waiting.
    ///
    /// A backstop and not the way out. A removal that returns — whatever it
    /// answers — ends the wait at once; this only decides what happens to a
    /// server that stops answering mid-cleanup, where waiting for ever would
    /// leave the panel's spinner, and the CLI, hanging after a Cancel. A
    /// removal that runs past it is reported as a file that may have been
    /// left behind, and the next run's sweep finds it.
    static let cleanupBoundSeconds = 30

    /// The test file's name for one run.
    static func fileName(for id: UUID) -> String { namePrefix + id.uuidString }

    /// Whether `item` is a test file an earlier run left behind: a FILE whose
    /// name is exactly `namePrefix` followed by a canonical upper-case UUID.
    ///
    /// Strict on purpose. A user's `.macscp-throughput-notes`, a lower-case
    /// UUID, a `.bak` suffix, a directory or a link of that name are not
    /// something this app wrote, and the sweep deletes only what it wrote.
    static func isLeftover(_ item: RemoteFileItem) -> Bool {
        guard item.kind == .file, item.name.hasPrefix(namePrefix) else { return false }
        let suffix = String(item.name.dropFirst(namePrefix.count))
        return UUID(uuidString: suffix)?.uuidString == suffix
    }

    /// The whole measurement over `fileSystem`, finished as a row by
    /// `timer`.
    ///
    /// Does not close `fileSystem`; the caller that opened it does
    /// (`ConnectionDiagnostics.throughput(_:)`). `id` and `seed` are
    /// parameters so the suite can name the file and predict the bytes; the
    /// runner passes fresh ones.
    static func measure(
        on fileSystem: any RemoteFileSystem, payloadBytes: Int,
        uploadThrottle: BandwidthBucket?, downloadThrottle: BandwidthBucket?,
        id: UUID = UUID(), seed: UInt64 = UInt64.random(in: .min ... .max),
        timer: DiagnosticStepTimer
    ) async -> DiagnosticStep {
        // An S3 session started at the bucket list has no folder at its
        // root, only buckets, and nowhere a file could be written.
        guard !fileSystem.rootIsContainerList else {
            return timer.finish(.unavailable(DiagnosticReason.throughputNeedsAFolder), "")
        }
        let directory: String
        do {
            directory = try await fileSystem.homeDirectoryPath()
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
        let sweep = await sweepLeftovers(in: directory, on: fileSystem)
        // Nothing of this run is on the server yet, so a cancellation here
        // leaves nothing to remove. The row is never appended — the walk
        // re-reads `Task.isCancelled` — and says only that.
        guard !Task.isCancelled else { return timer.finish(.timedOut, "") }

        let name = fileName(for: id)
        let path = RemotePath.join(directory, name)
        let payload = ThroughputPayload(seed: seed, size: payloadBytes)
        let sink = ThroughputSink(seed: seed)
        var legs: [Leg] = []
        var failure: (leg: String, reason: String)?

        // From the first byte of the upload to the removal there is no
        // `return`: every way out of this block — a leg that throws, a
        // cancellation, the natural end — reaches the removal below.
        do {
            legs.append(
                try await leg(DiagnosticThroughputColumn.up, payloadBytes, uploadThrottle) {
                    try await TransferEngine.copyFile(
                        from: payload, sourcePath: ThroughputPayload.path,
                        to: fileSystem, destinationDirectory: directory, fileName: name,
                        direction: .upload, throttle: uploadThrottle, onProgress: { _ in })
                })
        } catch {
            failure = ("the upload", DialSupport.reason(for: error))
        }
        if failure == nil {
            do {
                legs.append(
                    try await leg(DiagnosticThroughputColumn.down, payloadBytes, downloadThrottle)
                    {
                        try await TransferEngine.copyFile(
                            from: fileSystem, sourcePath: path,
                            to: sink, destinationDirectory: "/", fileName: ThroughputSink.name,
                            direction: .download, throttle: downloadThrottle,
                            onProgress: { _ in })
                    })
            } catch {
                failure = ("the download", DialSupport.reason(for: error))
            }
        }
        let removal = await remove(path, from: fileSystem)

        return row(
            timer: timer, name: name, payloadBytes: payloadBytes, legs: legs,
            failure: failure, verdict: failure == nil ? sink.verdict(expected: payloadBytes) : nil,
            removal: removal, sweep: sweep)
    }

    // MARK: The legs

    /// One timed direction, and the limit that paced it.
    struct Leg {
        let direction: String
        let bytes: Int
        let duration: Duration
        let limitBytesPerSecond: Int?
    }

    private static func leg(
        _ direction: String, _ bytes: Int, _ throttle: BandwidthBucket?,
        _ transfer: () async throws -> Void
    ) async throws -> Leg {
        // Read BEFORE the leg: the limit the leg starts under is the one it
        // was paced by, and a re-rate mid-leg is a Settings change the row
        // cannot describe in one cell either way.
        let limit = await throttle?.bytesPerSecond
        let clock = ContinuousClock()
        let started = clock.now
        try await transfer()
        return Leg(
            direction: direction, bytes: bytes, duration: started.duration(to: clock.now),
            limitBytesPerSecond: limit)
    }

    // MARK: The removal

    /// What became of the test file.
    enum Removal: Sendable, Equatable {
        /// It was there and is gone.
        case removed
        /// There was nothing to remove: the upload never created it.
        case absent
        /// The server refused, with this sentence.
        case failed(String)
        /// The removal did not answer inside `cleanupBoundSeconds`.
        case unanswered
    }

    /// Removes `path`, in a task the caller's cancellation does not reach,
    /// and waits for it — up to `cleanupBoundSeconds`.
    static func remove(_ path: String, from fileSystem: any RemoteFileSystem) async -> Removal {
        let outcome = CleanupOutcome<Removal>()
        let finished = await BoundedClose.run(boundSeconds: cleanupBoundSeconds) {
            do {
                try await fileSystem.delete(path: path)
                outcome.store(.removed)
            } catch RemoteFSError.notFound {
                outcome.store(.absent)
            } catch {
                outcome.store(.failed(DialSupport.reason(for: error)))
            }
        }
        guard finished, let removal = outcome.value else { return .unanswered }
        return removal
    }

    /// Closes the step's connection the way `remove(_:from:)` removes its
    /// file: out of the reach of the caller's cancellation, and bounded.
    static func close(_ fileSystem: any RemoteFileSystem) async {
        _ = await BoundedClose.run(boundSeconds: cleanupBoundSeconds) {
            await fileSystem.disconnect()
        }
    }

    // MARK: The leftover sweep

    /// What the sweep found and did.
    struct Sweep: Equatable {
        var removed = 0
        var notRemoved = 0
        var couldNotList = false
    }

    /// Removes every test file an earlier run left in `directory` — a run
    /// that crashed, or whose removal the server refused — and nothing else
    /// (`isLeftover(_:)`).
    ///
    /// Housekeeping, not the measurement: a folder that cannot be listed or
    /// a leftover that cannot be removed is said in the row's detail and
    /// changes no outcome. It runs in the caller's task, before anything of
    /// this run exists, so a cancellation simply stops it.
    ///
    /// Each file is deleted by the name the check read, joined to the folder
    /// the check listed — never by a path the listing handed back, which a
    /// backend is free to spell differently.
    static func sweepLeftovers(
        in directory: String, on fileSystem: any RemoteFileSystem
    ) async -> Sweep {
        let items: [RemoteFileItem]
        do {
            items = try await fileSystem.list(path: directory)
        } catch {
            return Sweep(couldNotList: true)
        }
        var sweep = Sweep()
        for item in items where isLeftover(item) {
            guard !Task.isCancelled else { break }
            do {
                try await fileSystem.delete(path: RemotePath.join(directory, item.name))
                sweep.removed += 1
            } catch {
                sweep.notRemoved += 1
            }
        }
        return sweep
    }

    // MARK: The row

    private static func row(
        timer: DiagnosticStepTimer, name: String, payloadBytes: Int, legs: [Leg],
        failure: (leg: String, reason: String)?, verdict: ThroughputSink.Verdict?,
        removal: Removal, sweep: Sweep
    ) -> DiagnosticStep {
        var parts = ["\(name), \(payloadBytes) bytes"]
        switch verdict {
        case .matches?:
            parts.append("read back identical")
        case .differs(let offset)?:
            parts.append("first difference at byte \(offset)")
        case .length(let received)?:
            parts.append("\(received) of \(payloadBytes) bytes read back")
        case nil:
            break
        }
        switch removal {
        case .removed:
            parts.append("removed")
        case .absent:
            break
        case .failed(let reason):
            parts.append("not removed: \(reason)")
        case .unanswered:
            parts.append("the removal did not answer")
        }
        if sweep.removed > 0 {
            parts.append(
                sweep.removed == 1
                    ? "1 leftover from an earlier run removed"
                    : "\(sweep.removed) leftovers from an earlier run removed")
        }
        if sweep.notRemoved > 0 {
            parts.append(
                sweep.notRemoved == 1
                    ? "1 leftover from an earlier run not removed"
                    : "\(sweep.notRemoved) leftovers from an earlier run not removed")
        }
        if sweep.couldNotList {
            parts.append("the folder could not be listed for leftovers")
        }

        let outcome: DiagnosticOutcome
        switch (removal, failure, verdict) {
        case (.failed, _, _), (.unanswered, _, _):
            // A file on the user's server that the user did not put there is
            // the one thing the row must not bury, so it wins over whatever
            // else went wrong — and that goes into the detail instead.
            if let failure { parts.append("\(failure.leg) failed: \(failure.reason)") }
            outcome = .failed(DiagnosticReason.throughputFileLeftBehind)
        case (_, let failure?, _):
            outcome = .failed(failure.reason)
        case (_, nil, .matches?):
            outcome = .ok
        case (_, nil, _):
            outcome = .failed(DiagnosticReason.throughputBytesDiffer)
        }
        return timer.finish(
            outcome, parts.joined(separator: "; "), table: table(legs))
    }

    /// The legs that finished, one row each — or `nil` when not even the
    /// upload did, because a header over no rows claims a measurement nobody
    /// made (`ConnectionDiagnostics.traceTable(_:)` states the rule).
    static func table(_ legs: [Leg]) -> DiagnosticTable? {
        guard !legs.isEmpty else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        return DiagnosticTable(
            columns: DiagnosticThroughputColumn.all,
            rows: legs.map { leg in
                let seconds = leg.duration.seconds
                let rate =
                    seconds > 0
                    ? TransferRateFormatting.rateString(
                        bytesPerSecond: Double(leg.bytes) / seconds, locale: posix)
                    : nil
                let limit = leg.limitBytesPerSecond.flatMap {
                    TransferRateFormatting.rateString(bytesPerSecond: Double($0), locale: posix)
                }
                return [
                    leg.direction, "\(leg.bytes)", DurationText.milliseconds(leg.duration),
                    rate ?? DiagnosticThroughputColumn.none,
                    limit ?? DiagnosticThroughputColumn.none,
                ]
            })
    }
}

/// One value carried out of a `BoundedClose.run` operation, read only after
/// `run` reported that the operation finished.
///
/// `@unchecked Sendable` because `stored` is reached only under `lock`; the
/// payload type is not required to be `Sendable`, and nothing reaches the
/// storage without taking the lock.
private final class CleanupOutcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func store(_ value: Value) {
        lock.withLock { stored = value }
    }

    var value: Value? {
        lock.withLock { stored }
    }
}

// MARK: - The two stand-ins on this side

/// The bytes a throughput test writes: a deterministic stream derived from a
/// seed, so the sink can compute what it should receive without holding what
/// was sent.
///
/// SplitMix64 over the index of each eight-byte word. Not for secrecy — the
/// seed is random per run only so two runs never write the same file — but
/// incompressible enough that a link which compresses does not report a rate
/// it did not carry.
enum ThroughputPattern {
    /// The `count` bytes starting at `offset`.
    static func bytes(seed: UInt64, offset: Int, count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let buffer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var cachedIndex = -1
            var cached: UInt64 = 0
            for index in 0..<count {
                let position = offset + index
                let wordIndex = position >> 3
                if wordIndex != cachedIndex {
                    cached = word(seed: seed, index: UInt64(wordIndex))
                    cachedIndex = wordIndex
                }
                buffer[index] = UInt8(truncatingIfNeeded: cached >> (UInt64(position & 7) * 8))
            }
        }
        return data
    }

    private static func word(seed: UInt64, index: UInt64) -> UInt64 {
        var mixed = seed &+ (index &+ 1) &* 0x9E37_79B9_7F4A_7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// The upload's source: a file system of exactly one file, whose bytes are
/// generated as `TransferEngine` pulls them.
///
/// Every member a transfer does not call refuses, so a caller that used this
/// as anything but a source would find out at once.
struct ThroughputPayload: RemoteFileSystem {
    static let path = "/payload"
    let seed: UInt64
    let size: Int

    func stat(path: String) async throws -> RemoteFileItem {
        RemoteFileItem(name: "payload", path: path, kind: .file, size: UInt64(size))
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let cursor = Cursor(offset: Int(min(offset, UInt64(size))))
        let seed = self.seed
        let size = self.size
        return AsyncThrowingStream(unfolding: {
            guard let range = cursor.advance(limit: size) else { return nil }
            return ThroughputPattern.bytes(seed: seed, offset: range.lowerBound, count: range.count)
        })
    }

    /// Where the stream has got to. A class so the `unfolding:` closure can
    /// advance it, and a `Mutex` because that closure is `@Sendable`.
    private final class Cursor: Sendable {
        private let offset: Mutex<Int>

        init(offset: Int) { self.offset = Mutex(offset) }

        /// The next chunk's range, or `nil` at the end.
        func advance(limit: Int) -> Range<Int>? {
            offset.withLock { offset in
                guard offset < limit else { return nil }
                let end = min(offset + TransferChunk.size, limit)
                defer { offset = end }
                return offset..<end
            }
        }
    }

    func list(path: String) async throws -> [RemoteFileItem] { throw Self.refusal }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws { throw Self.refusal }
    func delete(path: String) async throws { throw Self.refusal }
    func createDirectory(at path: String) async throws { throw Self.refusal }
    func rename(from: String, to: String) async throws { throw Self.refusal }
    func setPermissions(path: String, permissions: UInt32) async throws { throw Self.refusal }
    func deleteTree(at path: String) async throws { throw Self.refusal }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}

    private static let refusal = RemoteFSError.protocolError(
        reason: "the throughput payload is a source and nothing else")
}

/// The download's destination: compares what arrives with what was sent,
/// chunk by chunk, and keeps nothing.
final class ThroughputSink: RemoteFileSystem {
    static let name = "payload"

    /// What the bytes read back were.
    enum Verdict: Equatable {
        /// Every byte, and no more.
        case matches
        /// The first byte that is not the one written.
        case differs(atByte: Int)
        /// As many bytes as came back, where that is not what was written.
        case length(received: Int)
    }

    private struct State {
        var received = 0
        var firstDifference: Int?
    }

    private let seed: UInt64
    private let state = Mutex(State())

    init(seed: UInt64) { self.seed = seed }

    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        for try await chunk in contents {
            state.withLock { state in
                guard state.firstDifference == nil else {
                    state.received += chunk.count
                    return
                }
                let expected = ThroughputPattern.bytes(
                    seed: seed, offset: state.received, count: chunk.count)
                if chunk != expected {
                    let index = zip(chunk, expected).enumerated()
                        .first { $0.element.0 != $0.element.1 }?.offset ?? 0
                    state.firstDifference = state.received + index
                }
                state.received += chunk.count
            }
        }
    }

    func verdict(expected: Int) -> Verdict {
        state.withLock { state in
            if let first = state.firstDifference { return .differs(atByte: first) }
            return state.received == expected ? .matches : .length(received: state.received)
        }
    }

    func list(path: String) async throws -> [RemoteFileItem] { throw Self.refusal }
    func stat(path: String) async throws -> RemoteFileItem { throw Self.refusal }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> { throw Self.refusal }
    func delete(path: String) async throws { throw Self.refusal }
    func createDirectory(at path: String) async throws { throw Self.refusal }
    func rename(from: String, to: String) async throws { throw Self.refusal }
    func setPermissions(path: String, permissions: UInt32) async throws { throw Self.refusal }
    func deleteTree(at path: String) async throws { throw Self.refusal }
    func homeDirectoryPath() async throws -> String { "/" }
    func disconnect() async {}

    private static let refusal = RemoteFSError.protocolError(
        reason: "the throughput sink is a destination and nothing else")
}
