import Foundation

public struct TransferProgress: Equatable, Sendable {
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64?

    public init(bytesTransferred: UInt64, totalBytes: UInt64?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    /// Anteil 0…1; nil, wenn die Gesamtgröße unbekannt oder 0 ist.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

public enum TransferDirection: Equatable, Sendable {
    case upload
    case download
}

/// Kopiert einzelne Dateien zwischen zwei Dateisystemen (M2c: eine zur Zeit,
/// Ziel wird überschrieben; Konfliktregeln und Queue kommen in M5).
public enum TransferEngine {
    /// Kopiert EINE Datei von source nach destinationDirectory/fileName.
    /// Richtungs-agnostisch (lokal→remote, remote→lokal, remote→remote).
    ///
    /// Wirft der Quell-Stream mitten in der Übertragung, bleiben bereits
    /// geschriebene Ziel-Daten stehen (kein Rollback) — Retry/Cleanup ist
    /// Sache von M5.
    ///
    /// Kooperativer Abbruch (M5c/T2): VOR jedem Chunk-Write wird
    /// `Task.checkCancellation()` geprüft. Wird die umgebende Task abgebrochen
    /// (z. B. via `TransferQueueViewModel.cancelAll`), stoppt die Übertragung
    /// chunk-genau (64 KiB) mit `CancellationError`. Der Abbruch hinterlässt
    /// ggf. eine TEIL-Datei am Ziel; es wird NICHT zurückgerollt — das
    /// Aufräumen (bzw. ein Resume) ist Sache des Aufrufers (M5d).
    public static func copyFile(
        from source: any RemoteFileSystem, sourcePath: String,
        to destination: any RemoteFileSystem, destinationDirectory: String, fileName: String,
        onProgress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let total = try await source.stat(path: sourcePath).size
        let input = try await source.readStream(path: sourcePath)
        let destinationPath = RemotePath.join(destinationDirectory, fileName)

        // Zähl-Zwischenstück, pull-basiert: das Ziel zieht Chunk für Chunk,
        // nichts wird über einen Chunk hinaus gepuffert.
        var iterator = input.makeAsyncIterator()
        var transferred: UInt64 = 0
        let counted = AsyncThrowingStream<Data, Error>(unfolding: {
            // Kooperativer Abbruch VOR jedem Chunk: greift chunk-genau.
            try Task.checkCancellation()
            guard let chunk = try await iterator.next() else { return nil }
            transferred += UInt64(chunk.count)
            onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total))
            return chunk
        })

        try await destination.write(path: destinationPath, contents: counted)

        // WICHTIG: `AsyncThrowingStream(unfolding:)` BEENDET sich bei Abbruch der
        // konsumierenden Task still (nächstes `next()` liefert `nil`, ohne die
        // Closure erneut aufzurufen) — der obige `checkCancellation` greift dann
        // NICHT. Der Konsum-Loop im Ziel läuft dadurch chunk-genau aus (kein
        // weiterer Chunk wird geschrieben), kehrt aber regulär zurück. Erst
        // dieser Nachcheck macht den Abbruch für den Aufrufer sichtbar: er wirft
        // `CancellationError`, die Queue mappt ihn auf `.cancelled`. Die bereits
        // geschriebene TEIL-Datei bleibt stehen (kein Rollback, s. o.).
        try Task.checkCancellation()
    }
}
