import Foundation
import Observation

/// UI-Zustand des (einen) laufenden Transfers.
@Observable
@MainActor
public final class TransferViewModel {
    public enum State: Equatable {
        case idle
        case running(fileName: String, direction: TransferDirection, progress: TransferProgress)
        case failed(message: String)
        case finished(fileName: String, direction: TransferDirection)
    }

    public private(set) var state: State = .idle

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public init() {}

    /// Führt den Transfer aus; ruft onCompleted bei Erfolg (fürs Ziel-Pane-Refresh).
    public func run(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: @escaping () async -> Void
    ) async {
        guard !isRunning else { return }
        state = .running(
            fileName: fileName, direction: direction,
            progress: TransferProgress(bytesTransferred: 0, totalBytes: nil))
        do {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                onProgress: { progress in
                    Task { @MainActor [weak self] in
                        self?.state = .running(
                            fileName: fileName, direction: direction, progress: progress)
                    }
                }
            )
            state = .finished(fileName: fileName, direction: direction)
            await onCompleted()
        } catch {
            state = .failed(message: Self.message(for: error))
        }
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
