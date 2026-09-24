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
    /// Streams the file starting at `offset`, but only while the remote
    /// object still carries the validator `ifMatching` — an entity tag a
    /// caller took from `entityTag(path:)` BEFORE the transfer that is now
    /// being resumed. A backend that can check it and finds it stale throws
    /// rather than handing back a body: appending the tail of a REPLACED
    /// object to the head of the old one produces a file of exactly the
    /// right length and entirely wrong contents, which nothing downstream
    /// can notice. `nil` asks for no check, and so does `offset == 0` —
    /// a fresh read has no partial file to protect.
    ///
    /// Why this is not a cycle with `readStream(path:fromOffset:)`: BOTH
    /// spellings are protocol requirements, so both dispatch through the
    /// witness table. The extension below defaults this one to the
    /// two-argument one; a conformer that overrides only the two-argument
    /// one therefore lands in its own implementation and stops. A backend
    /// that can check the validator — `S3FileSystem` and
    /// `WebDAVFileSystem` — overrides BOTH, its two-argument one
    /// delegating here with `nil`, so the extension's default is out of
    /// the picture for it entirely. The one spelling that would recurse is
    /// a conformer overriding the two-argument one by calling this one
    /// while taking the default for this one; nothing here does that, and
    /// it is the thing to check when a backend grows a validator.
    func readStream(
        path: String, fromOffset offset: UInt64, ifMatching tag: String?
    ) async throws -> AsyncThrowingStream<Data, Error>
    /// A validator for the entry at `path` AS IT IS NOW, to be handed back
    /// to `readStream(path:fromOffset:ifMatching:)` when a download of it is
    /// resumed. The raw header text the server wrote — quotes, and a weak
    /// validator's `W/` prefix, included — because it goes straight back out
    /// as a header value and is never parsed here.
    ///
    /// `nil` when this backend has no validator for that entry, which is
    /// NOT an error: it means a resumed read of it cannot be checked, and
    /// the caller decides what to do about that.
    func entityTag(path: String) async throws -> String?
    /// Writes the chunk stream as a file. `.overwrite` truncates/creates;
    /// `.append` opens (or creates) and appends starting at the file's
    /// current end.
    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws
    /// Deletes a FILE at `path` (not a directory). Throws
    /// `RemoteFSError.notFound` if nothing exists there, and
    /// `RemoteFSError.protocolError` if `path` is a directory. S3's own
    /// backend additionally treats a key that is BOTH an object and a
    /// prefix as its own case, stated once where it is decided: `delete`
    /// refuses it and `deleteTree` removes the object and the subtree
    /// (`S3FileSystem.deleteLookup`/`.both`) — no other backend can reach
    /// that shape.
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
    /// NOTE: both implementations follow symlinks (chmod semantics) — the
    /// UI must not offer the permission editor for `.symlink` entries (M7b).
    func setPermissions(path: String, permissions: UInt32) async throws
    /// Recursively deletes the entry at `path` (file, symlink, or directory
    /// with its entire contents). Symlinks are deleted, NEVER followed — the
    /// walk cannot escape the subtree. Cooperatively cancellable per entry;
    /// a cancellation leaves a partially deleted tree in place (documented,
    /// M7a). A plain file behaves exactly like `delete`.
    func deleteTree(at path: String) async throws
    /// Resolves the connection's home directory (login landing point). Used
    /// once at session start; callers fall back to "/" on failure.
    func homeDirectoryPath() async throws -> String
    func disconnect() async
    /// Whether an interrupted transfer to THIS file system can resume by
    /// appending to a partial destination (`WriteMode.append`). SSH/local
    /// support it; object stores like S3 do not (no append, and a re-PUT
    /// replaces the whole object) — the engine forces a full overwrite for
    /// destinations that return `false`, so a size-mismatched existing object
    /// is never corrupted by an append tail (M13).
    var supportsAppendResume: Bool { get }
    /// Whether this connection's ROOT lists containers rather than files —
    /// `true` only for an S3 session started at the bucket list
    /// (2026-09-02). The browser turns it into a `BrowserScope`, which is
    /// what every action gate reads.
    ///
    /// A property of the CONNECTION, not of the protocol: two S3 sessions to
    /// the same endpoint disagree about it, which is exactly why it is here
    /// and not on `ProtocolCapabilities`. And the smallest thing that could
    /// be exposed — a `Bool`, not the config — because the browser needs to
    /// know that `/` holds containers and nothing else about how they are
    /// addressed.
    var rootIsContainerList: Bool { get }
    /// Whether an upload to `path` that failed on this connection may have
    /// left an INCOMPLETE upload behind that no listing shows and no
    /// `delete(path:)` removes — `true` only for an S3 multipart upload
    /// whose abort did not confirm (`S3MultipartAbortInFlight`). A caller
    /// that promises to leave nothing behind asks this after a failed write.
    /// It may WAIT for that abort's answer, so the transfer queue never
    /// calls it: its cancel path has to return at once.
    func incompleteUploadMayRemain(at path: String) async -> Bool
    /// Waits for every upload abort this connection still has running —
    /// each under its own bound — and answers the object key of each one
    /// that did not confirm, in path order. The command line asks this
    /// before it disconnects and exits (`CLIConnectionScope`), because an
    /// abort still running dies with the process. It WAITS, so the transfer
    /// queue never calls it, for the reason above.
    func awaitUnconfirmedAborts() async -> [String]
}

extension RemoteFileSystem {
    /// Convenience over `readStream(path:fromOffset:)` with offset 0 — kept
    /// so existing call sites (TransferEngine, tests) compile unchanged.
    public func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await readStream(path: path, fromOffset: 0)
    }

    /// Default: no validator check. Every backend that cannot evaluate one
    /// takes this and reads exactly as it did before. See the requirement's
    /// own comment above for why calling the two-argument spelling from
    /// here does not recurse.
    public func readStream(
        path: String, fromOffset offset: UInt64, ifMatching tag: String?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await readStream(path: path, fromOffset: offset)
    }

    /// Default: no validator. True of SSH, of the local disk and of every
    /// test double; the two HTTP backends are the overriders, because HTTP
    /// is where a validator both exists (`ETag`, `getetag`) and can be sent
    /// back (`If-Match`).
    public func entityTag(path: String) async throws -> String? { nil }

    /// Convenience over `write(path:mode:contents:)` with `.overwrite` — kept
    /// so existing call sites (TransferEngine, tests) compile unchanged.
    public func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        try await write(path: path, mode: .overwrite, contents: contents)
    }

    /// Default: appendable (SSH/local). Kept so every existing conformer
    /// (including test doubles) compiles unchanged; only backends that
    /// cannot append (e.g. `S3FileSystem`) override to `false` (M13).
    public var supportsAppendResume: Bool { true }

    /// Default: an ordinary file system whose root holds files and folders.
    /// True of the local file system, of SSH, of WebDAV, and of an S3
    /// session pointed at one bucket — everything but `S3FileSystem` in
    /// bucket-list mode, which is the sole overrider. Kept defaulted for the
    /// same reason as `supportsAppendResume`: every conformer, test doubles
    /// included, compiles unchanged.
    public var rootIsContainerList: Bool { false }

    /// Default: no backend but S3 has an upload that can outlive its own
    /// failure unseen — a file written through SFTP, WebDAV or the local
    /// disk is where `list` and `delete` can reach it. `S3FileSystem` is the
    /// sole overrider; every other conformer, test doubles included,
    /// compiles unchanged.
    public func incompleteUploadMayRemain(at path: String) async -> Bool { false }

    /// Default: nothing to wait for, for the reason above. `S3FileSystem` is
    /// the sole overrider.
    public func awaitUnconfirmedAborts() async -> [String] { [] }
}
