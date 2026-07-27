import Foundation
@testable import macSCPCore

/// Test double with a hard-wired directory tree and file contents.
/// Invariant: item.path == RemotePath.join(directoryKey, item.name),
/// otherwise stat won't find the entry.
actor MockRemoteFileSystem: RemoteFileSystem {
    private var tree: [String: [RemoteFileItem]]
    private var files: [String: Data]
    private var written: [String: Data] = [:]
    /// Order of paths newly created via `createDirectory` (for T3 tests).
    private(set) var createdDirectories: [String] = []
    /// Mode of the most recent `write` per path (M5d/T1 groundwork — lets
    /// T2's resume tests assert `.append` was used, not `.overwrite`).
    private(set) var writeModes: [String: WriteMode] = [:]
    /// Paths removed via `delete`, in call order (M5d/T1 groundwork for T2/T3).
    private(set) var deletedPaths: [String] = []
    /// Permission bits set via `setPermissions`, keyed by path (M7a/T1).
    private(set) var permissionsByPath: [String: UInt32] = [:]

    init(tree: [String: [RemoteFileItem]], files: [String: Data] = [:]) {
        self.tree = tree
        self.files = files
    }

    func list(path: String) async throws -> [RemoteFileItem] {
        guard let items = tree[path] else {
            throw RemoteFSError.notFound(path: path)
        }
        return items
    }

    func stat(path: String) async throws -> RemoteFileItem {
        let parent = RemotePath.parent(of: path)
        guard let siblings = tree[parent],
              let item = siblings.first(where: { $0.path == path }) else {
            throw RemoteFSError.notFound(path: path)
        }
        return item
    }

    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard let data = files[path] else {
            throw RemoteFSError.notFound(path: path)
        }
        // Offset at/beyond EOF: `start == data.count`, the loop below never
        // runs — an empty stream, no error.
        let start = min(Int(offset), data.count)
        return AsyncThrowingStream { continuation in
            var position = start
            while position < data.count {
                let end = min(position + TransferChunk.size, data.count)
                continuation.yield(data.subdata(in: position..<end))
                position = end
            }
            continuation.finish()
        }
    }

    func write(path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>) async throws {
        var collected = Data()
        for try await chunk in contents {
            collected.append(chunk)
        }
        writeModes[path] = mode
        switch mode {
        case .overwrite:
            written[path] = collected
            files[path] = collected
        case .append:
            let existing = files[path] ?? Data()
            written[path] = collected
            files[path] = existing + collected
        }
    }

    func writtenData(at path: String) -> Data? {
        written[path]
    }

    /// Deletes a FILE at `path`. `notFound` if nothing exists there,
    /// `protocolError` if a directory is at that path.
    func delete(path: String) async throws {
        let parent = RemotePath.parent(of: path)
        if let siblings = tree[parent],
           siblings.first(where: { $0.path == path })?.kind == .directory {
            throw RemoteFSError.protocolError(reason: "path is a directory: \(path)")
        }
        guard files[path] != nil else {
            throw RemoteFSError.notFound(path: path)
        }
        files[path] = nil
        written[path] = nil
        deletedPaths.append(path)
        if var siblings = tree[parent] {
            siblings.removeAll { $0.path == path }
            tree[parent] = siblings
        }
    }

    /// Idempotent (already exists as a directory in the mock tree: silently
    /// ok), throws `protocolError` for a file at the path, otherwise the path
    /// is added to the tree and logged in `createdDirectories`.
    func createDirectory(at path: String) async throws {
        let parent = RemotePath.parent(of: path)
        if let siblings = tree[parent], let existing = siblings.first(where: { $0.path == path }) {
            if existing.kind == .directory { return }
            throw RemoteFSError.protocolError(reason: "path exists and is not a directory: \(path)")
        }
        let name = String(path.split(separator: "/").last ?? Substring(path))
        var siblings = tree[parent] ?? []
        siblings.append(RemoteFileItem(name: name, path: path, kind: .directory))
        tree[parent] = siblings
        if tree[path] == nil {
            tree[path] = []
        }
        createdDirectories.append(path)
    }

    /// Moves the tree entry (and any tracked file data) from `from` to the
    /// FULL destination path `to`. `notFound` if nothing exists at `from`,
    /// `protocolError` if something already exists at `to` (no silent
    /// overwrite, matching Local/Citadel). Shallow: a directory's own
    /// children in `tree` are not re-keyed, mirroring `delete`'s file-only
    /// scope — no test in this suite renames a non-empty directory.
    func rename(from: String, to: String) async throws {
        let sourceParent = RemotePath.parent(of: from)
        guard let siblings = tree[sourceParent],
              let index = siblings.firstIndex(where: { $0.path == from }) else {
            throw RemoteFSError.notFound(path: from)
        }
        let destParent = RemotePath.parent(of: to)
        if let destSiblings = tree[destParent], destSiblings.contains(where: { $0.path == to }) {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }

        var sourceSiblings = siblings
        let item = sourceSiblings.remove(at: index)
        tree[sourceParent] = sourceSiblings

        let newName = String(to.split(separator: "/").last ?? Substring(to))
        let movedItem = RemoteFileItem(
            name: newName, path: to, kind: item.kind, size: item.size,
            modifiedAt: item.modifiedAt, permissions: item.permissions)
        var destSiblings = tree[destParent] ?? []
        destSiblings.append(movedItem)
        tree[destParent] = destSiblings

        if let data = files[from] {
            files[to] = data
            files[from] = nil
        }
        if let data = written[from] {
            written[to] = data
            written[from] = nil
        }
        if let mode = writeModes[from] {
            writeModes[to] = mode
            writeModes[from] = nil
        }
        if let perms = permissionsByPath[from] {
            permissionsByPath[to] = perms
            permissionsByPath[from] = nil
        }
    }

    /// Records the low-12-bit permission mask for `path` (M7a/T1); `notFound`
    /// if nothing exists there in the mock tree.
    func setPermissions(path: String, permissions: UInt32) async throws {
        let parent = RemotePath.parent(of: path)
        guard let siblings = tree[parent], siblings.contains(where: { $0.path == path }) else {
            throw RemoteFSError.notFound(path: path)
        }
        permissionsByPath[path] = permissions & 0o7777
    }

    /// Recursively removes `path` from the in-memory tree. A directory
    /// recurses into its own `tree[path]` children first (depth-first,
    /// mirroring the Citadel bottom-up walk), then drops its own tree entry.
    /// A non-directory entry (file OR symlink) is removed directly via
    /// `removeTreeEntry` rather than delegating to `delete(path:)`: `delete`
    /// requires seeded `files[path]` data and throws `notFound` otherwise,
    /// which would abort the recursion on every `.symlink` listing entry
    /// (symlinks in this mock carry no file content) — diverging from both
    /// real backends, which remove a symlink's directory-entry regardless of
    /// tracked content. Cooperatively cancellable per entry.
    func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        let parent = RemotePath.parent(of: path)
        guard let siblings = tree[parent],
              let item = siblings.first(where: { $0.path == path }) else {
            throw RemoteFSError.notFound(path: path)
        }
        guard item.kind == .directory else {
            removeTreeEntry(at: path, parent: parent)
            return
        }
        for child in tree[path] ?? [] {
            try Task.checkCancellation()
            try await deleteTree(at: child.path)
        }
        removeTreeEntry(at: path, parent: parent)
    }

    /// Drops `path`'s own tree entry, its parent-listing entry, and any
    /// tracked data (file content, write log, write mode, permissions) —
    /// logged in `deletedPaths`. Shared by both branches of `deleteTree`.
    private func removeTreeEntry(at path: String, parent: String) {
        tree[path] = nil
        files[path] = nil
        written[path] = nil
        writeModes[path] = nil
        permissionsByPath[path] = nil
        if var updatedSiblings = tree[parent] {
            updatedSiblings.removeAll { $0.path == path }
            tree[parent] = updatedSiblings
        }
        deletedPaths.append(path)
    }

    func disconnect() async {}
}
