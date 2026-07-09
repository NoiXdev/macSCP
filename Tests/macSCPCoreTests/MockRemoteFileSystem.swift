@testable import macSCPCore

/// Test-Double mit fest verdrahtetem Verzeichnisbaum.
/// Schlüssel = Verzeichnispfad, Wert = dessen Einträge.
actor MockRemoteFileSystem: RemoteFileSystem {
    private let tree: [String: [RemoteFileItem]]

    /// Baum-Invariante: Für jeden Eintrag muss `item.path == RemotePath.join(directoryKey, item.name)`
    /// gelten, sonst findet `stat` ihn nicht.
    init(tree: [String: [RemoteFileItem]]) {
        self.tree = tree
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

    func disconnect() async {}
}
