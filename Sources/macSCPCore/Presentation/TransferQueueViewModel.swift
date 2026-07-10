import Foundation
import Observation

/// UI-Zustand einer seriellen Transfer-Warteschlange (FIFO).
///
/// Ersetzt das Einzeltransfer-`TransferViewModel`: `enqueue` verwirft nichts
/// mehr, sondern reiht immer ein und startet bei Bedarf einen schlafenden
/// Worker neu. Genau ein Worker läuft; er arbeitet die `order` seriell ab.
///
/// Nebenläufigkeit: Die Klasse ist `@MainActor`; der eigentliche `copyFile`
/// läuft in einer eigenen `runningTransferTask` (damit `cancelAll` ihn abbrechen
/// kann) und gibt den MainActor während der Übertragung frei.
@Observable
@MainActor
public final class TransferQueueViewModel {
    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case queued
            case running(TransferProgress)
            case finished
            case failed(String)      // deutsche Meldung
            case cancelled

            /// true, solange dieses Item aktiv überträgt — die UI braucht das.
            public var isRunning: Bool {
                if case .running = self { return true }
                return false
            }
        }
        public let id: UUID
        public let fileName: String
        public let direction: TransferDirection
        public internal(set) var status: Status
    }

    public private(set) var items: [Item] = []

    /// true, solange irgendein Item queued/running ist (Sidebar-Gate).
    public var isActive: Bool {
        items.contains { $0.status == .queued || $0.status.isRunning }
    }

    /// Anzahl offener (queued+running) Items — fürs "n ausstehend"-Label.
    public var pendingCount: Int {
        items.reduce(into: 0) { count, item in
            if item.status == .queued || item.status.isRunning { count += 1 }
        }
    }

    // MARK: - Privater Zustand

    private struct Job {
        let id: UUID
        let source: any RemoteFileSystem
        let sourcePath: String
        let destination: any RemoteFileSystem
        let destinationDirectory: String
        let fileName: String
        let onCompleted: (@MainActor () async -> Void)?
    }

    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []                                  // FIFO der queued-IDs
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var workerTask: Task<Void, Never>?
    private var runningTransferTask: Task<Void, Error>?            // fürs Cancel des aktiven copyFile

    public init() {}

    // MARK: - Öffentliche API

    /// Reiht ein und startet den Worker, falls er schläft. Läuft IMMER an —
    /// kein `isRunning`-Verwerfen mehr.
    @discardableResult
    public func enqueue(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
    ) -> UUID {
        let id = UUID()
        jobs[id] = Job(
            id: id, source: source, sourcePath: sourcePath,
            destination: destination, destinationDirectory: destinationDirectory,
            fileName: fileName, onCompleted: onCompleted)
        order.append(id)
        items.append(Item(id: id, fileName: fileName, direction: direction, status: .queued))
        kickWorker()
        return id
    }

    /// Wie `enqueue`, kehrt aber erst zurück, wenn GENAU dieses Item fertig ist.
    /// Wirft bei failed/cancelled (Promise-Pfad: der Finder braucht die Datei).
    public func enqueueAndWait(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Synchron auf dem MainActor: erst einreihen, dann Waiter hinterlegen,
            // bevor der Worker überhaupt loslaufen kann — so kann kein Ergebnis
            // den Waiter verpassen.
            let id = enqueue(
                fileName: fileName, direction: direction,
                source: source, sourcePath: sourcePath,
                destination: destination, destinationDirectory: destinationDirectory,
                onCompleted: nil)
            waiters[id] = continuation
        }
    }

    /// Bricht alles ab: laufenden Transfer canceln, queued → `.cancelled`,
    /// wartende Continuations werfen. Kehrt erst nach Worker-Stopp zurück.
    public func cancelAll() async {
        // 1. Alle noch nicht gestarteten (queued) IDs abräumen.
        let queued = order
        order.removeAll()
        for id in queued {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // 2. Den aktiven Transfer abbrechen — sein copyFile endet mit
        //    CancellationError, `process` setzt das Item auf `.cancelled`.
        runningTransferTask?.cancel()
        // 3. Auf das Worker-Ende warten: `nextQueuedID()` liefert nichts mehr,
        //    die Schleife läuft aus und setzt `workerTask = nil`.
        let worker = workerTask
        await worker?.value
    }

    /// Entfernt finished/failed/cancelled aus der Liste.
    public func clearCompleted() {
        items.removeAll { item in
            switch item.status {
            case .finished, .failed, .cancelled: return true
            case .queued, .running: return false
            }
        }
    }

    // MARK: - Worker

    private func kickWorker() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            while let self, let jobID = self.nextQueuedID() {
                await self.process(jobID)
            }
            self?.workerTask = nil
        }
    }

    private func nextQueuedID() -> UUID? {
        order.isEmpty ? nil : order.removeFirst()
    }

    private func process(_ jobID: UUID) async {
        guard let job = jobs[jobID] else { return }

        setStatus(jobID, .running(TransferProgress(bytesTransferred: 0, totalBytes: nil)))

        // Geordnete Zustellung: AsyncStream puffert in Reihenfolge, EIN Konsument
        // aktualisiert den Status — kein Task-pro-Chunk, kein Race mit .finished.
        let (progressStream, progressContinuation) = AsyncStream<TransferProgress>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.setStatus(jobID, .running(progress))
            }
        }

        // Nur Sendable-Werte in die Transfer-Task ziehen (kein Job/onCompleted).
        let source = job.source
        let sourcePath = job.sourcePath
        let destination = job.destination
        let destinationDirectory = job.destinationDirectory
        let fileName = job.fileName
        let transfer = Task<Void, Error> {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                onProgress: { progressContinuation.yield($0) }
            )
        }
        runningTransferTask = transfer

        do {
            try await transfer.value
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .finished)
            jobs[jobID] = nil
            runningTransferTask = nil
            if let onCompleted = job.onCompleted { await onCompleted() }
            resumeWaiter(jobID, with: .success(()))
        } catch is CancellationError {
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            runningTransferTask = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
        } catch {
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .failed(Self.message(for: error)))
            jobs[jobID] = nil
            runningTransferTask = nil
            resumeWaiter(jobID, with: .failure(error))
        }
    }

    // MARK: - Helfer

    private func setStatus(_ id: UUID, _ status: Item.Status) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    private func resumeWaiter(_ id: UUID, with result: Result<Void, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    static func message(for error: Error) -> String {
        switch error {
        case RemoteFSError.notFound(let path):
            return "Datei nicht gefunden: \(path)"
        case RemoteFSError.permissionDenied(let path):
            return "Keine Berechtigung für: \(path)"
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung verloren: \(reason)"
        case RemoteFSError.protocolError(let reason):
            return "Übertragung fehlgeschlagen: \(reason)"
        default:
            return "Übertragung fehlgeschlagen: \(String(describing: error))"
        }
    }
}
