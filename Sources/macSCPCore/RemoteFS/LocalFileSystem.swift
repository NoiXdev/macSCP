import Foundation

/// Lokales Dateisystem hinter derselben Abstraktion wie SFTP — dadurch teilen
/// sich beide Panes ViewModel und Tabelle. `disconnect` ist ein No-op.
/// Fehler werden auf dieselben typisierten Fälle gemappt wie beim SFTP-Backend.
public struct LocalFileSystem: RemoteFileSystem {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    public init() {}

    public func list(path: String) async throws -> [RemoteFileItem] {
        let url = URL(fileURLWithPath: path)
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Self.resourceKeys)
        } catch {
            throw Self.map(error, path: path)
        }
        return contents.map(Self.item(for:))
    }

    public func stat(path: String) async throws -> RemoteFileItem {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw RemoteFSError.notFound(path: path)
        }
        return Self.item(for: url)
    }

    public func disconnect() async {}

    private static func item(for url: URL) -> RemoteFileItem {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let kind: RemoteFileKind
        if values?.isSymbolicLink == true {
            kind = .symlink
        } else if values?.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }
        return RemoteFileItem(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            kind: kind,
            size: (values?.fileSize).map(UInt64.init),
            modifiedAt: values?.contentModificationDate,
            permissions: nil
        )
    }

    private static func map(_ error: Error, path: String) -> Error {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError {
            return RemoteFSError.notFound(path: path)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return RemoteFSError.permissionDenied(path: path)
        }
        return RemoteFSError.protocolError(reason: String(describing: error))
    }
}
