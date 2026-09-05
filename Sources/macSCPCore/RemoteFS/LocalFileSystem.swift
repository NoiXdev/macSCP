import Crypto
import Darwin
import Foundation

/// Local file system behind the same abstraction as SFTP — so both panes
/// share a view model and table. `disconnect` is a no-op. Errors are mapped
/// to the same typed cases as the SFTP backend.
public struct LocalFileSystem: RemoteFileSystem {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// The two deadlines `metadata(for items:)`'s supervisor drives — see
    /// `MetadataDeadlines`' own doc comment (`LocalMetadataSource.swift`)
    /// for what each one does and why 500 ms / 5 s were chosen. An
    /// instance property rather than a fixed constant (round 2, final fix
    /// round) so a test can drive the whole two-deadline sequence in
    /// milliseconds instead of the production five seconds; every existing
    /// construction site keeps compiling unchanged via `.default` below.
    public let metadataDeadlines: MetadataDeadlines

    /// `fetchesOwnerGroup`: whether `list`/`stat` resolve owner/group NAMES
    /// (default `false`). See `ownerGroup(for:fetchesOwnerGroup:)` for why
    /// this is opt-in.
    public let fetchesOwnerGroup: Bool

    /// The seam `metadata(for items:)` (`LocalMetadataSource.swift`) runs per
    /// entry, on its own child task. Defaults to `Self.item(for:
    /// fetchesOwnerGroup:)` with THIS instance's `fetchesOwnerGroup` baked
    /// in — the closure captures the flag's VALUE, not `self`, so it stays
    /// `Sendable` without capturing the struct.
    ///
    /// `async`, though the real implementation it defaults to never
    /// suspends: a plain synchronous closure satisfies an `async` parameter
    /// type just fine (Swift allows sync code wherever async is expected),
    /// and declaring the SEAM `async` is what lets a test's substitute probe
    /// suspend on an actor-backed `Gate` (`await gate.opened()`) instead of
    /// blocking a thread to simulate "parked" — CLAUDE.md's "tests never
    /// block the pool" forbids a semaphore or any other synchronous wait
    /// here. A genuinely stuck PRODUCTION probe (a dead network mount's
    /// `resourceValues` call) still costs a real thread regardless of the
    /// `async` keyword — that call never reaches a suspension point, it
    /// just never returns — so the design's accepted cost (one thread per
    /// stuck entry) is unchanged; only the TEST'S way of modeling "stuck"
    /// avoids paying that cost against the shared cooperative pool.
    ///
    /// Not `private`: `LocalMetadataSource.swift`'s conformance extension
    /// reads it, and Swift's `private` is scoped to the declaring FILE, not
    /// just the declaring type — an extension of the same type in a
    /// different file needs at least `internal` (the unmarked default) to
    /// see it. Still invisible outside this module.
    let metadataProbe: @Sendable (URL) async -> RemoteFileItem?

    /// Session-scoped memory of paths whose metadata probe was still
    /// running when `metadataDeadlines.stuckEntryDeadline` elapsed on a
    /// PREVIOUS `metadata(for:)` call (final fix round, local-listing-
    /// never-blocks design; the deadline moved from `slowEntryThreshold`
    /// to the longer `stuckEntryDeadline` in round 2, so a merely slow
    /// entry is never blacklisted off one slow listing — see
    /// `MetadataDeadlines`' own doc comment). Default `nil`, so every
    /// existing construction site — every call in this tree before this
    /// parameter existed — is unaffected: no memory means every listing
    /// probes every entry, exactly as before. `ContentView.swift` builds
    /// one `StuckPaths` per browser session and passes it to both
    /// `LocalFileSystem` instances that session owns, so a path proven
    /// stuck through one is remembered by the other. See `StuckPaths`'
    /// own doc comment (`LocalMetadataSource.swift`) and `metadata(for:)`'s
    /// for what "remembered" skips, and how a path that eventually answers
    /// is cleared again.
    public let stuckPaths: StuckPaths?

    public init(
        fetchesOwnerGroup: Bool = false,
        metadataProbe: (@Sendable (URL) async -> RemoteFileItem?)? = nil,
        metadataDeadlines: MetadataDeadlines = .default,
        stuckPaths: StuckPaths? = nil
    ) {
        self.fetchesOwnerGroup = fetchesOwnerGroup
        self.metadataProbe = metadataProbe ?? { url in
            Self.item(for: url, fetchesOwnerGroup: fetchesOwnerGroup)
        }
        self.metadataDeadlines = metadataDeadlines
        self.stuckPaths = stuckPaths
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

    /// Phase one of the local-listing-never-blocks design
    /// (`docs/superpowers/specs/2026-09-04-local-listing-never-blocks-design.md`):
    /// returns names and kinds straight from the directory read, with every
    /// `size`/`modifiedAt`/`owner`/`group`/`permissions` nil. `item(for:)`
    /// below — the per-entry metadata call — is NOT invoked from this loop
    /// any more; Task 2 adds a `metadata(for items:)` stream that calls it
    /// once per entry, on its own child task, so one entry's stuck syscall
    /// can no longer hold up the rest of the listing the way it did when
    /// this ran `item(for:)` in a plain loop.
    ///
    /// Getting there took two Foundation quirks into account, both measured
    /// live on 2026-09-05:
    ///
    /// 1. The URL-based enumeration, `contentsOfDirectory(at:
    ///    includingPropertiesForKeys:)`, throws ENOTDIR (POSIX 20) for a
    ///    symlinked PARENT whose target directory exists — confirmed against
    ///    a fresh `real/` + `link -> real` pair — which is why an earlier
    ///    version of this method used the string-path API instead
    ///    (`contentsOfDirectory(atPath:)`, one `readdir`, no bulk metadata
    ///    prefetch, and therefore a `stat`/`lstat` per child in `item(for:)`
    ///    to get anything beyond the name). Resolving the parent's own
    ///    symlinks ONCE — `resolvingSymlinksInPath()` — before the URL call
    ///    fixes exactly that case: the resolved directory has no symlink of
    ///    its own left for the API to reject, and the one bulk
    ///    `getattrlistbulk` read (`includingPropertiesForKeys:`) answers
    ///    `.isDirectoryKey`/`.isSymbolicLinkKey` for every child in a single
    ///    call, not one `stat` per child.
    /// 2. `resolvingSymlinksInPath()` is a no-op for a path it cannot fully
    ///    resolve — a DANGLING symlinked parent, whose target does not
    ///    exist, is the case that stays broken even after step 1. Confirmed
    ///    live against `/usr/X11` (`lrwxr-xr-x /usr/X11 ->
    ///    ../private/var/select/X11`, and that target does not exist on
    ///    this machine): resolving is a no-op, the URL API still throws
    ///    ENOTDIR, and `listByReaddir(at:)` below is the fallback —
    ///    `opendir`/`readdir` on the ORIGINAL path, reading the kind
    ///    straight from `d_type`. Separately (and unrelated to the ENOTDIR
    ///    case): `resolvingSymlinksInPath()` also leaves `/tmp`, `/var` and
    ///    `/etc` themselves unresolved — a documented `NSString` exclusion,
    ///    not a bug — but the URL enumeration API already has its own
    ///    `/private` rewrite for exactly those three (confirmed live), so
    ///    they list correctly through the primary path regardless.
    ///
    /// Either way, every returned item's `path` is rebuilt from the
    /// ORIGINAL, UNRESOLVED parent plus the child's own name — never from
    /// the resolved directory — so a listing through a symlinked directory
    /// keeps the path the user navigated to (T1/M11g review I-1 follow-up:
    /// this is exactly what `navigate(to:)`'s "try list()" symlink check
    /// depends on).
    public func list(path: String) async throws -> [RemoteFileItem] {
        let originalURL = URL(fileURLWithPath: path)
        DiagnosticLog.shared.log(.info, "browser.local", "list start path=\(path)")
        let clock = ContinuousClock()
        let listStart = clock.now
        let items: [RemoteFileItem]
        do {
            items = try Self.listNamesAndKinds(originalURL: originalURL)
        } catch {
            let mapped = Self.map(error, path: path)
            // The ORIGINAL (mapped) `RemoteFSError`, not a hand-formatted
            // `reason=\(mapped)` (fix round 1, Structural): the overload
            // computes `DialSupport.reason(for:)` itself.
            DiagnosticLog.shared.log(
                .info, "browser.local", "list failed path=\(path)", reason: mapped)
            throw mapped
        }
        let listMs = Int(listStart.duration(to: clock.now).milliseconds.rounded())
        DiagnosticLog.shared.log(
            .info, "browser.local", "list done path=\(path) count=\(items.count) ms=\(listMs)")
        return items
    }

    /// The primary path: resolve `originalURL`'s symlinks once, read the
    /// resolved directory through the bulk-prefetching URL API, and fall
    /// back to `listByReaddir` on the ORIGINAL path when that still throws
    /// ENOTDIR (a dangling symlinked parent — see `list`'s doc comment).
    /// Every other error (missing path, permission denied) propagates
    /// unchanged, to `Self.map` in `list`.
    private static func listNamesAndKinds(originalURL: URL) throws -> [RemoteFileItem] {
        let resolvedURL = originalURL.resolvingSymlinksInPath()
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: resolvedURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .nameKey])
            return children.map { child in
                let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .nameKey])
                let name = values?.name ?? child.lastPathComponent
                let kind = Self.kind(
                    isSymbolicLink: values?.isSymbolicLink, isDirectory: values?.isDirectory)
                return Self.phaseOneItem(name: name, kind: kind, originalParent: originalURL)
            }
        } catch {
            guard Self.isENOTDIR(error) else { throw error }
            return try Self.listByReaddir(originalParent: originalURL)
        }
    }

    /// The ENOTDIR fallback: `opendir`/`readdir` on the ORIGINAL (unresolved)
    /// path, deriving each child's kind from `d_type` rather than any
    /// `stat` call — `DT_DIR`/`DT_LNK`/`DT_REG` map to `.directory`/
    /// `.symlink`/`.file`; `DT_UNKNOWN` (some network file systems don't
    /// populate `d_type`) and every other value map to `.other`, resolved
    /// only once metadata arrives in Task 2. `.` and `..` are skipped, same
    /// as `FileManager.contentsOfDirectory` already omits them.
    private static func listByReaddir(originalParent: URL) throws -> [RemoteFileItem] {
        let path = originalParent.path(percentEncoded: false)
        guard let directory = opendir(path) else {
            // `errno` is a POSIX code (e.g. ENOENT, EACCES) — `Self.map`
            // below has its own `NSPOSIXErrorDomain` branch for exactly
            // this, so a dangling symlinked parent (opendir fails ENOENT,
            // since there is no target to open) still maps to `.notFound`,
            // not a generic `.protocolError`.
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: path])
        }
        defer { closedir(directory) }
        var items: [RemoteFileItem] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            let kind: RemoteFileKind
            switch Int32(entry.pointee.d_type) {
            case Int32(DT_DIR): kind = .directory
            case Int32(DT_LNK): kind = .symlink
            case Int32(DT_REG): kind = .file
            default: kind = .other
            }
            items.append(Self.phaseOneItem(name: name, kind: kind, originalParent: originalParent))
        }
        return items
    }

    /// Kind precedence shared by phase one and `item(for:)`: a symlink is
    /// `.symlink` even when it points at a directory (checked first), a
    /// dangling symlink is still `.symlink` (there is no target to answer
    /// `isDirectory`), and anything else that isn't a directory is `.file`.
    private static func kind(isSymbolicLink: Bool?, isDirectory: Bool?) -> RemoteFileKind {
        if isSymbolicLink == true {
            .symlink
        } else if isDirectory == true {
            .directory
        } else {
            .file
        }
    }

    /// Builds one phase-one `RemoteFileItem`: `path` is `originalParent`
    /// (the UNRESOLVED path `list` was called with) plus `name`, normalized
    /// the same way `item(for:)` normalizes its own `path` (no trailing
    /// slash). Every metadata field is nil — that is the entire point of
    /// phase one.
    private static func phaseOneItem(
        name: String, kind: RemoteFileKind, originalParent: URL
    ) -> RemoteFileItem {
        var normalizedPath = originalParent.appendingPathComponent(name).path(percentEncoded: false)
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return RemoteFileItem(
            name: name,
            path: normalizedPath,
            kind: kind,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            owner: nil,
            group: nil
        )
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
        return Self.item(for: url, fetchesOwnerGroup: fetchesOwnerGroup)
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

    /// The per-entry metadata call. Local-listing-never-blocks Task 1 stopped
    /// calling this from `list`'s own loop (see `list`'s doc comment); Task 2
    /// makes it back `stat` (a single-entry call may stay synchronous) AND
    /// the default `metadataProbe` that `metadata(for items:)` runs once per
    /// entry, each call on its own child task (`LocalMetadataSource.swift`).
    /// `entry slow` — the debug line that used to wrap calls to this method
    /// inside `list`'s loop — moves to `metadata(for:)`; nothing in this
    /// function logs timing on its own.
    ///
    /// `static`, taking `fetchesOwnerGroup` as a parameter rather than
    /// reading `self.fetchesOwnerGroup`: the default `metadataProbe` closure
    /// built in `init` captures the flag's VALUE (a plain `Bool`, trivially
    /// `Sendable`) instead of `self` — so the closure stored on the struct
    /// does not have to capture the struct that holds it.
    private static func item(for url: URL, fetchesOwnerGroup: Bool) -> RemoteFileItem {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        let kind = Self.kind(isSymbolicLink: values?.isSymbolicLink, isDirectory: values?.isDirectory)
        var normalizedPath = url.path(percentEncoded: false)
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        let (owner, group) = ownerGroup(for: url, fetchesOwnerGroup: fetchesOwnerGroup)
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
    ///
    /// Reached only through `item(for:fetchesOwnerGroup:)`, so Task 1 already
    /// moved this behind `stat` and Task 2's `metadata(for items:)` stream —
    /// `list` itself never calls it any more, flag or no flag. `static` for
    /// the same reason `item(for:fetchesOwnerGroup:)` is: the flag arrives as
    /// a parameter, not read off `self`.
    private static func ownerGroup(for url: URL, fetchesOwnerGroup: Bool) -> (owner: String?, group: String?) {
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
        // `listByReaddir`'s `opendir` failure surfaces as a raw
        // `NSPOSIXErrorDomain` error (there is no Cocoa wrapping for it, the
        // way there is for `FileManager`'s own calls above) — measured live
        // on 2026-09-05: a dangling symlinked parent's `opendir` fails
        // ENOENT (there is no target to open), the same outcome a missing
        // path already gets above.
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ENOENT, ENOTDIR: return RemoteFSError.notFound(path: path)
            case EACCES: return RemoteFSError.permissionDenied(path: path)
            default: break
            }
        }
        return RemoteFSError.protocolError(reason: String(describing: error))
    }

    /// Whether `error` is the URL enumeration API's ENOTDIR failure for a
    /// symlinked parent (see `list`'s doc comment) — checked on the
    /// UNDERLYING POSIX error, not the top-level Cocoa code alone: Cocoa
    /// wraps several distinct POSIX failures under the same
    /// `NSFileReadUnknownError` (256), and only POSIX code 20 is the one
    /// this fallback exists for. Measured live on 2026-09-05 against both a
    /// working symlinked parent and a dangling one (`/usr/X11`): both throw
    /// exactly `NSCocoaErrorDomain` code 256 with an `NSUnderlyingError` of
    /// `NSPOSIXErrorDomain` code 20.
    private static func isENOTDIR(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain,
              let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying.domain == NSPOSIXErrorDomain
        else { return false }
        return underlying.code == Int(ENOTDIR)
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
