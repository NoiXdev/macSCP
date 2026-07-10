import Foundation

/// Uniform transfer chunk size for all backends.
public enum TransferChunk {
    public static let size = 64 * 1024
}

/// Abstraction over a (remote or local) file system.
/// M1: list/stat. M2c: chunk streams for single-file transfers.
public protocol RemoteFileSystem: Sendable {
    func list(path: String) async throws -> [RemoteFileItem]
    func stat(path: String) async throws -> RemoteFileItem
    /// File contents as a chunk stream (chunks ≤ TransferChunk.size).
    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error>
    /// Writes the chunk stream as a file; existing files are overwritten.
    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws
    /// Creates the directory. IDEMPOTENT: if it already exists as a directory,
    /// the call returns silently. If a FILE exists at the path, throws
    /// RemoteFSError.protocolError. Missing intermediate directories: Local
    /// creates them (withIntermediateDirectories); Citadel creates ONLY the
    /// last level — the recursion (T3) runs top-down, so parents always exist.
    func createDirectory(at path: String) async throws
    func disconnect() async
}
