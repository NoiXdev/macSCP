import Foundation

/// Uniform transfer chunk size for all backends.
public enum TransferChunk {
    public static let size = 64 * 1024
}

/// Write mode for `write(path:mode:contents:)` (M5d/T1, resume support).
/// `.overwrite` truncates an existing file (or creates a new one) — today's
/// behavior. `.append` opens an existing file (or creates one) and writes
/// starting at its current end, for continuing an interrupted transfer.
public enum WriteMode: Sendable, Equatable {
    case overwrite
    case append
}

/// Abstraction over a (remote or local) file system.
/// M1: list/stat. M2c: chunk streams for single-file transfers. M5d/T1:
/// offset reads, append writes, delete — groundwork for resume (T2/T3).
public protocol RemoteFileSystem: Sendable {
    func list(path: String) async throws -> [RemoteFileItem]
    func stat(path: String) async throws -> RemoteFileItem
    /// Streams the file starting at `offset` bytes. Offset 0 behaves exactly
    /// like the plain `readStream(path:)`. Offset at or beyond EOF yields an
    /// empty stream (no error).
    func readStream(path: String, fromOffset offset: UInt64) async throws -> AsyncThrowingStream<Data, Error>
    /// Writes the chunk stream as a file. `.overwrite` truncates/creates;
    /// `.append` opens (or creates) and appends starting at the file's
    /// current end.
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws
    /// Deletes a FILE at `path` (not a directory). Throws
    /// `RemoteFSError.notFound` if nothing exists there, and
    /// `RemoteFSError.protocolError` if `path` is a directory.
    func delete(path: String) async throws
    /// Creates the directory. IDEMPOTENT: if it already exists as a directory,
    /// the call returns silently. If a FILE exists at the path, throws
    /// RemoteFSError.protocolError. Missing intermediate directories: Local
    /// creates them (withIntermediateDirectories); Citadel creates ONLY the
    /// last level — the recursion (T3) runs top-down, so parents always exist.
    func createDirectory(at path: String) async throws
    /// Renames/moves the entry at `from` to the FULL destination path `to`.
    /// An existing destination is an error (`RemoteFSError`) — this call
    /// never silently overwrites. The UI builds same-directory paths for a
    /// rename; the protocol stays generic (M7a).
    func rename(from: String, to: String) async throws
    /// Sets the POSIX permission bits of the entry at `path`. Only the low
    /// 12 bits (rwx for owner/group/other + setuid/setgid/sticky) are
    /// applied — file-type bits are never written (M7a).
    func setPermissions(path: String, permissions: UInt32) async throws
    func disconnect() async
}

extension RemoteFileSystem {
    /// Convenience over `readStream(path:fromOffset:)` with offset 0 — kept
    /// so existing call sites (TransferEngine, tests) compile unchanged.
    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await readStream(path: path, fromOffset: 0)
    }

    /// Convenience over `write(path:mode:contents:)` with `.overwrite` — kept
    /// so existing call sites (TransferEngine, tests) compile unchanged.
    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        try await write(path: path, mode: .overwrite, contents: contents)
    }
}
