import Foundation

/// Local file system behind the same abstraction as SFTP — so both panes
/// share a view model and table. `disconnect` is a no-op. Errors are mapped
/// to the same typed cases as the SFTP backend.
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
        // fileExists(atPath:) follows symlinks — but a broken link still
        // exists AS a link. So check first whether the path itself is a symlink.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink != true,
           !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw RemoteFSError.notFound(path: path)
        }
        return Self.item(for: url)
    }

    public func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Self.map(error, path: path)
        }
        do {
            // Seeking past EOF is valid POSIX behavior (no error); the
            // subsequent read then naturally yields an empty stream.
            try handle.seek(toOffset: offset)
        } catch {
            try? handle.close()
            throw RemoteFSError.protocolError(reason: String(describing: error))
        }
        // Pull-based (unfolding): the consumer sets the pace,
        // never more than one chunk is buffered.
        return AsyncThrowingStream(unfolding: {
            do {
                if let chunk = try handle.read(upToCount: TransferChunk.size),
                   !chunk.isEmpty {
                    return chunk
                }
                try? handle.close()
                return nil
            } catch {
                try? handle.close()
                throw RemoteFSError.protocolError(reason: String(describing: error))
            }
        })
    }

    public func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        let url = URL(fileURLWithPath: path)
        let rawPath = url.path(percentEncoded: false)
        switch mode {
        case .overwrite:
            guard FileManager.default.createFile(atPath: rawPath, contents: nil) else {
                throw RemoteFSError.permissionDenied(path: path)
            }
        case .append:
            if !FileManager.default.fileExists(atPath: rawPath) {
                guard FileManager.default.createFile(atPath: rawPath, contents: nil) else {
                    throw RemoteFSError.permissionDenied(path: path)
                }
            }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw Self.map(error, path: path)
        }
        defer { try? handle.close() }
        if mode == .append {
            do {
                try handle.seekToEnd()
            } catch {
                throw RemoteFSError.protocolError(reason: String(describing: error))
            }
        }
        for try await chunk in contents {
            try handle.write(contentsOf: chunk)
        }
    }

    /// Deletes a FILE at `path`. Throws `notFound` if nothing exists there,
    /// `protocolError` if a directory is at that path (this call never
    /// deletes directories).
    public func delete(path: String) async throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else { throw RemoteFSError.notFound(path: path) }
        if isDirectory.boolValue {
            throw RemoteFSError.protocolError(reason: "path is a directory: \(path)")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }

    /// Creates the directory including any missing intermediate levels. If the
    /// path already exists as a directory, the call returns silently
    /// (idempotent). If a file exists there, throws `protocolError`.
    public func createDirectory(at path: String) async throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists {
            if isDirectory.boolValue { return }
            throw RemoteFSError.protocolError(reason: "path exists and is not a directory: \(path)")
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        } catch {
            throw Self.map(error, path: path)
        }
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
        var normalizedPath = url.path(percentEncoded: false)
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return RemoteFileItem(
            name: url.lastPathComponent,
            path: normalizedPath,
            kind: kind,
            size: (values?.fileSize).map(UInt64.init),
            modifiedAt: values?.contentModificationDate,
            permissions: nil
        )
    }

    private static func map(_ error: Error, path: String) -> Error {
        let ns = error as NSError
        // FileManager operations throw NSFileReadNoSuchFileError (260),
        // while FileHandle(forReadingFrom:) throws NSFileNoSuchFileError (4) —
        // both mean "file not found".
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return RemoteFSError.notFound(path: path)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return RemoteFSError.permissionDenied(path: path)
        }
        return RemoteFSError.protocolError(reason: String(describing: error))
    }
}
