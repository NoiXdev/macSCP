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
            guard let chunk = try await iterator.next() else { return nil }
            transferred += UInt64(chunk.count)
            onProgress(TransferProgress(bytesTransferred: transferred, totalBytes: total))
            return chunk
        })

        try await destination.write(path: destinationPath, contents: counted)
    }
}
