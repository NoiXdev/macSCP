import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferEngine")
struct TransferEngineTests {
    private func makeSource(content: Data) -> MockRemoteFileSystem {
        MockRemoteFileSystem(
            tree: ["/": [RemoteFileItem(
                name: "quelle.bin", path: "/quelle.bin", kind: .file,
                size: UInt64(content.count))]],
            files: ["/quelle.bin": content]
        )
    }

    @Test func copiesContentToDestinationDirectory() async throws {
        let content = Data((0..<(TransferChunk.size + 512)).map { UInt8($0 % 241) })
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            onProgress: { _ in }
        )
        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
    }

    @Test func reportsMonotonicProgressUpToTotal() async throws {
        let content = Data(repeating: 7, count: TransferChunk.size * 3)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = ProgressRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            onProgress: { progress in recorder.record(progress) }
        )
        let snapshots = recorder.snapshots
        #expect(!snapshots.isEmpty)
        #expect(snapshots.map(\.bytesTransferred) == snapshots.map(\.bytesTransferred).sorted())
        #expect(snapshots.last?.bytesTransferred == UInt64(content.count))
        #expect(snapshots.last?.totalBytes == UInt64(content.count))
    }

    @Test func missingSourceThrowsNotFound() async {
        let source = MockRemoteFileSystem(tree: ["/": []])
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])
        await #expect(throws: RemoteFSError.notFound(path: "/fehlt.bin")) {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/fehlt.bin",
                to: destination, destinationDirectory: "/ziel", fileName: "fehlt.bin",
                onProgress: { _ in }
            )
        }
    }

    @Test func fractionIsNilWithoutTotalAndOneAtCompletion() {
        #expect(TransferProgress(bytesTransferred: 10, totalBytes: nil).fraction == nil)
        #expect(TransferProgress(bytesTransferred: 0, totalBytes: 0).fraction == nil)
        #expect(TransferProgress(bytesTransferred: 50, totalBytes: 100).fraction == 0.5)
    }

    // MARK: - Kooperative Cancellation (M5c/T2)

    /// Wird die Transfer-Task mitten in der Übertragung abgebrochen, muss
    /// `copyFile` chunk-genau stoppen: `CancellationError` fliegt und ab dem
    /// Cancel-Punkt landet KEIN weiterer Chunk am Ziel.
    ///
    /// Aufbau bewusst OHNE abbruchbewusstes Warten im Test-Double: Das Ziel
    /// parkt nach dem ersten Chunk in einer `Task.isCancelled`-Schleife (die
    /// selbst NICHT wirft). Dadurch greift der Abbruch ausschließlich über den
    /// neuen `checkCancellation` in `copyFile` — nicht über ein werfendes
    /// Warten. Ohne den Engine-Check würden nach dem Cancel alle restlichen
    /// Chunks durchlaufen (roter Ausgangszustand).
    @Test func cancellationStopsBeforeNextChunkWrite() async throws {
        let chunkTotal = 4
        let content = Data(repeating: 0xAB, count: TransferChunk.size * chunkTotal)
        let source = makeSource(content: content)
        let reached = PlainSignal()
        let destination = RecordingSpinDestination(reached: reached)

        let task = Task {
            try await TransferEngine.copyFile(
                from: source, sourcePath: "/quelle.bin",
                to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
                onProgress: { _ in })
        }

        // Erster Chunk ist am Ziel angekommen → Transfer läuft, Ziel parkt.
        await reached.wait()
        task.cancel()

        // Timeout-Race, damit ein (regressierter) fehlender Abbruch den Test
        // nicht ewig hängen lässt.
        let outcome = await awaitOutcome(task)
        guard case .failure(let error)? = outcome else {
            Issue.record("CancellationError erwartet, war: \(String(describing: outcome))")
            return
        }
        #expect(error is CancellationError)

        let written = await destination.chunkCount
        #expect(written == 1)                // kein weiterer Chunk nach dem Cancel-Punkt
        #expect(written < chunkTotal)         // nicht alle Chunks übertragen
    }

    // MARK: - Bandbreiten-Drossel (M5c/T5)

    /// Limit 256 KB/s über 1 MiB (= 16 Chunks à 64 KiB) muss insgesamt ~4s
    /// angefordertes Schlafen ergeben (1_048_576 / (256*1024) == 4.0). Der
    /// injizierte `sleep`-Hook schläft NICHT wirklich — er zählt nur die
    /// angeforderten Dauern auf, macht den Test deterministisch statt von
    /// echtem Timing abhängig (kein Flaky-Risiko).
    @Test func throttleRequestsExpectedTotalSleepDuration() async throws {
        let content = Data(repeating: 0x42, count: 1024 * 1024)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = SleepRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            bytesPerSecondLimit: 256 * 1024,
            sleep: { duration in recorder.record(duration) },
            onProgress: { _ in }
        )

        #expect(await destination.writtenData(at: "/ziel/quelle.bin") == content)
        let totalSeconds = recorder.totalSeconds
        // Toleranzfenster statt exakter Gleichheit (Double-Rundung über 16
        // Additionen) — bindend war "Dauer ≥ ~3,5s"; das virtuelle Modell
        // liefert hier exakt 4.0s, ein enges Fenster deckt das plus etwas
        // Spielraum ab.
        #expect(totalSeconds >= 3.5)
        #expect(totalSeconds <= 4.5)
    }

    /// `bytesPerSecondLimit == 0` (Default) bleibt unangetastet: kein einziger
    /// Sleep-Aufruf, exakt das Vor-T5-Verhalten.
    @Test func noThrottleWithoutLimitNeverSleeps() async throws {
        let content = Data(repeating: 0x1, count: TransferChunk.size * 2)
        let source = makeSource(content: content)
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])

        let recorder = SleepRecorder()
        try await TransferEngine.copyFile(
            from: source, sourcePath: "/quelle.bin",
            to: destination, destinationDirectory: "/ziel", fileName: "quelle.bin",
            sleep: { duration in recorder.record(duration) },
            onProgress: { _ in }
        )
        #expect(recorder.callCount == 0)
    }

    /// Wartet auf das Task-Ergebnis, gibt aber nach `timeout` `nil` zurück
    /// (Timeout), statt ewig zu blockieren.
    private func awaitOutcome(
        _ task: Task<Void, Error>, timeout: Duration = .seconds(2)
    ) async -> Result<Void, Error>? {
        let box = ResultBox()
        Task {
            do { try await task.value; box.set(.success(())) }
            catch { box.set(.failure(error)) }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let result = box.value { return result }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return box.value   // nil ⇒ Timeout
    }
}

/// Lock-geschütztes Test-Double statt Actor: `onProgress` ist synchron, daher
/// würde ein Actor + `Task { await ... }` unstrukturierte Tasks erzeugen,
/// deren Abschluss vor den Assertions nicht garantiert ist (beobachtete,
/// intermittierende Fehlschläge). Synchrones Locking macht die Reihenfolge
/// deterministisch.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [TransferProgress] = []
    var snapshots: [TransferProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _snapshots
    }
    func record(_ p: TransferProgress) {
        lock.lock()
        defer { lock.unlock() }
        _snapshots.append(p)
    }
}

/// Cancellation-UNABHÄNGIGES Einmal-Signal: `wait()` ignoriert Task-Cancellation
/// (anders als das abbruchbewusste `TestSignal` der Queue-Tests). Damit greift
/// der Abbruch im Test ausschließlich über `copyFile`s `checkCancellation`.
private final class PlainSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Ziel-Double, das jeden geschriebenen Chunk zählt und nach dem ERSTEN Chunk
/// in einer abbruch-UNBEWUSSTEN `Task.isCancelled`-Schleife parkt. Wird die
/// Transfer-Task gecancelt, läuft die Schleife aus und der nächste Pull aus dem
/// Quell-Strom deckt der Engine-`checkCancellation` ab.
private actor RecordingSpinDestination: RemoteFileSystem {
    private let reached: PlainSignal
    private(set) var chunkCount = 0

    init(reached: PlainSignal) { self.reached = reached }

    func list(path: String) async throws -> [RemoteFileItem] { [] }

    func stat(path: String) async throws -> RemoteFileItem {
        throw RemoteFSError.notFound(path: path)
    }

    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        var isFirst = true
        for try await _ in contents {
            chunkCount += 1
            if isFirst {
                isFirst = false
                reached.fire()
                // Abbruch-UNBEWUSST parken: nur die Cancellation weckt die Schleife.
                while !Task.isCancelled { await Task.yield() }
            }
        }
    }

    func createDirectory(at path: String) async throws {}
    func disconnect() async {}
}

/// Zählt die an den injizierten `sleep`-Hook übergebenen Dauern auf, OHNE
/// wirklich zu schlafen (M5c/T5) — macht den Drossel-Test deterministisch
/// statt von echtem Timing abhängig.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _totalSeconds: Double = 0
    private var _callCount = 0
    var totalSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return _totalSeconds
    }
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }
    func record(_ duration: Duration) {
        lock.lock()
        _totalSeconds += duration.secondsAsDouble
        _callCount += 1
        lock.unlock()
    }
}

/// Threadsicherer Ergebnis-Halter für den Timeout-Race in `awaitOutcome`.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Result<Void, Error>?
    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func set(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if _value == nil { _value = result }
    }
}
