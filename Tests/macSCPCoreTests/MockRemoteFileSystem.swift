import Foundation
@testable import macSCPCore

/// Test-Double mit fest verdrahtetem Verzeichnisbaum und Datei-Inhalten.
/// Invariante: item.path == RemotePath.join(verzeichnisSchlüssel, item.name),
/// sonst findet stat den Eintrag nicht.
actor MockRemoteFileSystem: RemoteFileSystem {
    private let tree: [String: [RemoteFileItem]]
    private var files: [String: Data]
    private var written: [String: Data] = [:]

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

    func disconnect() async {}
}
