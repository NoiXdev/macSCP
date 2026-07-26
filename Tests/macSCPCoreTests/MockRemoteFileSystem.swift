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

    func disconnect() async {}
}
