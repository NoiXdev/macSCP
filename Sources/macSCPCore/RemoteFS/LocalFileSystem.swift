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

    /// Renames/moves to the FULL destination path. Refuses an existing
    /// destination — `moveItem` would too, but the explicit check yields a
    /// stable, mapped error instead of a Foundation-specific one.
    ///
    /// Both existence probes use `Self.exists(atPath:)` (symlink-first, same
    /// pattern as `stat`), not a bare `fileExists`: a dangling symlink AT
    /// `from` still "exists" as a link (though `moveItem` can move it) —
    /// plain `fileExists` follows symlinks and would misreport it as
    /// `notFound`. Symmetrically, a dangling symlink already AT `to` must
    /// still trip the collision guard, otherwise `moveItem` falls through to
    /// a raw Foundation error instead of our stable `protocolError`.
    public func rename(from: String, to: String) async throws {
        guard Self.exists(atPath: from) else {
            throw RemoteFSError.notFound(path: from)
        }
        guard !Self.exists(atPath: to) else {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
        } catch {
            throw Self.map(error, path: from)
        }
    }

    /// Applies only the low 12 permission bits; type bits are stripped.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(permissions & 0o7777)], ofItemAtPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }

    /// Recursive delete. `FileManager.removeItem` is natively recursive and
    /// removes symlinks WITHOUT following them, which matches the protocol
    /// contract exactly. Cancellation granularity is the whole call here
    /// (Foundation offers no per-entry hook) — acceptable for local trees.
    ///
    /// Existence probe reuses `Self.exists(atPath:)` (symlink-first, same
    /// pattern as `stat`/`rename`): a dangling symlink still "exists" as a
    /// link and must still be reported as existing (and is still deletable
    /// via `removeItem`), whereas a bare `fileExists` follows symlinks and
    /// would miss it.
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        guard Self.exists(atPath: path) else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func disconnect() async {}

    /// `path` "exists" if it is a symlink (even a dangling one) OR
    /// `fileExists` reports it — mirrors the check `stat` already uses, so a
    /// dangling symlink is never misreported as absent (plain `fileExists`
    /// follows symlinks and would miss it).
    private static func exists(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true || FileManager.default.fileExists(atPath: path)
    }

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
