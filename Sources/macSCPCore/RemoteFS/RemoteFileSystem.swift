import Foundation

/// Einheitliche Transfer-Chunk-Größe für alle Backends.
public enum TransferChunk {
    public static let size = 64 * 1024
}

/// Abstraktion über ein (entferntes oder lokales) Dateisystem.
/// M1: list/stat. M2c: Chunk-Streams für Einzeldatei-Transfers.
public protocol RemoteFileSystem: Sendable {
    func list(path: String) async throws -> [RemoteFileItem]
    func stat(path: String) async throws -> RemoteFileItem
    /// Dateiinhalt als Chunk-Strom (Chunks ≤ TransferChunk.size).
    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error>
    /// Schreibt den Chunk-Strom als Datei; vorhandene Dateien werden überschrieben.
    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws
    func disconnect() async
}
