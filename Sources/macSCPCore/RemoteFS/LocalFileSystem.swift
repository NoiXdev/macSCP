import Crypto
import Foundation

/// Local file system behind the same abstraction as SFTP — so both panes
/// share a view model and table. `disconnect` is a no-op. Errors are mapped
/// to the same typed cases as the SFTP backend.
public struct LocalFileSystem: RemoteFileSystem {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// `fetchesOwnerGroup`: whether `list`/`stat` resolve owner/group NAMES
    /// (default `false`). See `ownerGroup(for:)` for why this is opt-in.
    public let fetchesOwnerGroup: Bool

    public init(fetchesOwnerGroup: Bool = false) {
        self.fetchesOwnerGroup = fetchesOwnerGroup
    }

    /// How this file system expresses permissions — the one capability of
    /// the local pane that a surface reads (`PermissionsAvailability`).
    /// macOS is a POSIX system and `setPermissions` below writes a mode, so
    /// this is `.posixMode`; declared here, beside the code that makes it
    /// true, the way each remote backend's descriptor declares its own.
    ///
    /// The listing leaves `RemoteFileItem.permissions` nil (`item(for:)`
    /// reads no mode), so on the local pane the editor is OFFERED and the
    /// sheet then says the entry carried no bits — the entry sentence, and
    /// a true one.
    public static let permissionModel: PermissionModel = .posixMode

    public func list(path: String) async throws -> [RemoteFileItem] {
        let url = URL(fileURLWithPath: path)
        // Uses the STRING-path API (`contentsOfDirectory(atPath:)`), not the
        // URL-based one: `contentsOfDirectory(at:includingPropertiesForKeys:)`
        // rejects a symlinked directory outright with ENOTDIR (POSIX code
        // 20) — confirmed live against `/usr/X11` (`lrwxr-xr-x /usr/X11 ->
        // ../private/var/select/X11`, an ordinary symlink), which throws
        // through the URL API. It only *appears* to work for macOS's
        // `/tmp`, `/var`, `/etc` — those are plain symlinks too (`/tmp ->
        // private/tmp`), not some special case — because Foundation
        // hardcodes a `/private` prefix rewrite for exactly those three
        // paths and resolves the real, non-symlinked location before
        // opening it; that's also why the URL API's returned children come
        // back as `/private/etc/...` rather than `/etc/...` (T1/M11g review
        // I-1 follow-up: this is exactly what `navigate(to:)`'s "try
        // list()" symlink check depends on to be correct for an ordinary
        // symlinked directory, not just the three Foundation-mapped ones).
        // Each child URL below is a normal path, so `item(for:)`'s
        // per-entry `resourceValues` lookups are unaffected by how the
        // parent was reached.
        //
        // Cost: dropping `includingPropertiesForKeys:` also drops
        // Foundation's metadata prefetch, which the M11g review measured at
        // roughly 3x slower per-entry metadata lookups (31.5 ms → 93.8 ms
        // for a 5000-entry directory, ~12-14 µs/entry). The coordinator
        // accepted this deliberately: correctness over a saving that's
        // immaterial below tens of thousands of entries. If it ever does
        // matter, a try-URL-first-then-fall-back-to-`atPath` variant is
        // possible — not implemented here.
        //
        // M11m adds a second per-entry cost on top of the above: `item(for:)`
        // calls `ownerGroup(for:)`, which does its own
        // `FileManager.attributesOfItem(atPath:)` (an `lstat` plus
        // `getpwuid`/`getgrgid` to resolve NAMEs, not just numeric ids —
        // `getpwuid`/`getgrgid` can block on directory-service-bound Macs,
        // e.g. AD/LDAP-joined machines) for every entry. Owner/group account
        // NAMEs are not exposed via `URLResourceValues` at all (only the
        // numeric `.ownerAccountID`/`.groupOwnerAccountID` are), so there is
        // no way to fold this into the `resourceValues` call above — but
        // M18a made the whole lookup opt-in via `fetchesOwnerGroup` (see
        // `ownerGroup(for:)`), since on TCC-protected folders it can also
        // trigger a blocking macOS permission prompt, not just a slow syscall.
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
        return names.map { url.appendingPathComponent($0) }.map(item(for:))
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
        return item(for: url)
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
    /// removes symlinks WITHOUT following them — PROVIDED the path has no
    /// trailing slash. With one (`"<symlink>/"`), `removeItem` instead
    /// FOLLOWS the link and destroys the TARGET's contents (proven live in
    /// the M7a final review) — so a trailing slash is stripped up front,
    /// before the existence probe or the delete itself. Cancellation
    /// granularity is the whole call here (Foundation offers no per-entry
    /// hook) — acceptable for local trees.
    ///
    /// Existence probe reuses `Self.exists(atPath:)` (symlink-first, same
    /// pattern as `stat`/`rename`): a dangling symlink still "exists" as a
    /// link and must still be reported as existing (and is still deletable
    /// via `removeItem`), whereas a bare `fileExists` follows symlinks and
    /// would miss it.
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        // A trailing slash makes the delete FOLLOW a symlink argument and
        // destroy the TARGET's contents (proven on both backends in the M7a
        // final review) — strip it before anything else.
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard Self.exists(atPath: path) else {
            throw RemoteFSError.notFound(path: path)
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw Self.map(error, path: path)
        }
    }

    /// The macOS sandbox/user home — always succeeds, never throws.
    public func homeDirectoryPath() async throws -> String {
        NSHomeDirectory()
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

    private func item(for url: URL) -> RemoteFileItem {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
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
        let (owner, group) = ownerGroup(for: url)
        return RemoteFileItem(
            name: url.lastPathComponent,
            path: normalizedPath,
            kind: kind,
            size: (values?.fileSize).map(UInt64.init),
            modifiedAt: values?.contentModificationDate,
            permissions: nil,
            owner: owner,
            group: group
        )
    }

    /// Owner/group NAMES via `FileManager.attributesOfItem` (there is no
    /// `URLResourceKey` for owner/group account NAMES — only the numeric
    /// `.ownerAccountID`/`.groupOwnerAccountID` `URLResourceValues` exist;
    /// the NAME lookup lives on the `FileAttributeKey` dictionary instead).
    /// Falls back to the numeric uid/gid as a string when no passwd/group
    /// entry resolves a name (M11m design: name when resolvable, otherwise
    /// the raw number, never a guess) — mirrors the remote precedence.
    /// `attributesOfItem` reports the SYMLINK's own owner/group, not the
    /// target's, matching this file's existing no-follow behavior for kind/size.
    ///
    /// Gated behind `fetchesOwnerGroup` (M18a): `attributesOfItem` is a
    /// separate syscall PER ENTRY, on top of the `resourceValues` lookup
    /// already done for kind/size/date, and on TCC-protected folders
    /// (Desktop/Documents/Downloads) it can trigger a blocking macOS
    /// permission prompt — which is what made a plain directory listing
    /// (e.g. behind the "New Folder" dialog) appear to hang. When the flag
    /// is off, this returns the nil pair without touching the filesystem.
    private func ownerGroup(for url: URL) -> (owner: String?, group: String?) {
        guard fetchesOwnerGroup else { return (nil, nil) }
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path(percentEncoded: false))
        else { return (nil, nil) }
        let owner = (attributes[.ownerAccountName] as? String)
            ?? (attributes[.ownerAccountID] as? NSNumber)?.stringValue
        let group = (attributes[.groupOwnerAccountName] as? String)
            ?? (attributes[.groupOwnerAccountID] as? NSNumber)?.stringValue
        return (owner, group)
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

/// The checksum capability for files that are already on this machine.
///
/// The maintainer's ruling of 2026-08-27 — a checksum is never obtained by
/// DOWNLOADING — is what shapes the other backends, and it rules nothing out
/// here: reading a local file is not a transfer, it is reading the file the
/// question is about. So this is the one backend where this process itself
/// computes the digest over the content, and the value says exactly that
/// (`ChecksumProvenance.computedLocally`).
///
/// Conformance rather than a method of its own, because the surface reaches
/// every backend the same way — `as? any RemoteChecksumProvider` — and never
/// branches on which side of the window it is looking at.
extension LocalFileSystem: RemoteChecksumProvider {
    /// Computes `algorithm`'s digest of the file at `path`.
    ///
    /// Never `.unavailableOnThisConnection`: there is no far side that could
    /// be missing a tool. What it does refuse is a path that is not a file
    /// with bytes to hash — a missing one as `notFound`, a directory as a
    /// `protocolError` — because a digest of "nothing readable" is the one
    /// answer that would look like a result.
    public func remoteChecksum(
        forFileAt path: String, algorithm: ChecksumAlgorithm
    ) async throws -> RemoteChecksumOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw RemoteFSError.notFound(path: path)
        }
        guard !isDirectory.boolValue else {
            throw RemoteFSError.protocolError(reason: "path is a directory: \(path)")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw Self.map(error, path: path)
        }
        defer { try? handle.close() }

        let hex: String
        do {
            hex = try Self.streamedDigest(of: algorithm, reading: handle)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw RemoteFSError.protocolError(reason: String(describing: error))
        }

        // The factory checks the hex and may refuse it. It cannot refuse
        // this one — `fold` emits exactly the digit count the algorithm
        // prescribes, in lowercase — but there is no construction that
        // skips the check, and that is the point of `FileChecksum`'s private
        // initializer rather than something to route around here.
        guard let checksum = FileChecksum.computedLocally(algorithm, hex: hex) else {
            throw RemoteFSError.protocolError(reason: "the computed digest was not readable as hex")
        }
        return .checksum(checksum)
    }

    /// The digest as lowercase hex, one algorithm per case so the hasher and
    /// the `ChecksumAlgorithm` case cannot drift apart in a defaulted branch.
    private static func streamedDigest(
        of algorithm: ChecksumAlgorithm, reading handle: FileHandle
    ) throws -> String {
        switch algorithm {
        case .sha256: try fold(SHA256(), reading: handle)
        case .sha1: try fold(Insecure.SHA1(), reading: handle)
        case .md5: try fold(Insecure.MD5(), reading: handle)
        }
    }

    /// Folds the file into `function` one `TransferChunk.size` read at a
    /// time — the same chunk every transfer on this backend uses.
    ///
    /// This is what makes the operation safe for the sizes the design names:
    /// a 40 GB file costs one chunk of memory, not 40 GB, because the whole
    /// file is never a `Data`. There is no time bound and there must not be
    /// one — the bound the SSH path carries exists for a far side that stops
    /// answering, and a local read either returns or fails. What bounds this
    /// one is the caller: `Task.checkCancellation` runs once per chunk, so a
    /// cancelled request stops within one chunk's work rather than at the
    /// end of the file.
    private static func fold<Function: HashFunction>(
        _ function: Function, reading handle: FileHandle
    ) throws -> String {
        var function = function
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: TransferChunk.size), !chunk.isEmpty
            else { break }
            function.update(data: chunk)
        }
        return function.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
