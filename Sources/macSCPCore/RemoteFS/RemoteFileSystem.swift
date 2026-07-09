/// Abstraktion über ein entferntes Dateisystem.
/// M1: nur Lesen (list/stat). Transfer-Operationen kommen in M2 dazu.
public protocol RemoteFileSystem: Sendable {
    func list(path: String) async throws -> [RemoteFileItem]
    func stat(path: String) async throws -> RemoteFileItem
    func disconnect() async
}
