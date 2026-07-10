import Foundation
@testable import macSCPCore

/// Test-Double mit fest verdrahtetem Verzeichnisbaum und Datei-Inhalten.
/// Invariante: item.path == RemotePath.join(verzeichnisSchlüssel, item.name),
/// sonst findet stat den Eintrag nicht.
actor MockRemoteFileSystem: RemoteFileSystem {
    private var tree: [String: [RemoteFileItem]]
    private var files: [String: Data]
    private var written: [String: Data] = [:]
    /// Reihenfolge der per `createDirectory` neu angelegten Pfade (für T3-Tests).
    private(set) var createdDirectories: [String] = []

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

    func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
        guard let data = files[path] else {
            throw RemoteFSError.notFound(path: path)
        }
        return AsyncThrowingStream { continuation in
            var offset = 0
            while offset < data.count {
                let end = min(offset + TransferChunk.size, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
        var collected = Data()
        for try await chunk in contents {
            collected.append(chunk)
        }
        written[path] = collected
        files[path] = collected
    }

    func writtenData(at path: String) -> Data? {
        written[path]
    }

    /// Idempotent (existiert bereits als Verzeichnis im Mock-Baum: still ok),
    /// wirft `protocolError` bei einer Datei am Pfad, sonst wird der Pfad im
    /// Baum ergänzt und in `createdDirectories` protokolliert.
    func createDirectory(at path: String) async throws {
        let parent = RemotePath.parent(of: path)
        if let siblings = tree[parent], let existing = siblings.first(where: { $0.path == path }) {
            if existing.kind == .directory { return }
            throw RemoteFSError.protocolError(reason: "Pfad existiert als Datei: \(path)")
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
