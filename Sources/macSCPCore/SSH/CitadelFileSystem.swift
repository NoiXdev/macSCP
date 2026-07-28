import Citadel
import Foundation
import NIOCore
import NIOSSH

/// SFTP implementation of RemoteFileSystem based on Citadel.
/// M1: password auth, no host-key verification (TOFU arrives in M3).
public final class CitadelFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let client: SSHClient
    private let sftp: SFTPClient

    private init(client: SSHClient, sftp: SFTPClient) {
        self.client = client
        self.sftp = sftp
    }

    /// Connects with Trust-on-First-Use host-key verification.
    ///
    /// - known & identical → connect silently
    /// - known & different → `HostKeyError.mismatch` (the decider is NEVER asked)
    /// - unknown → `onUnknownHostKey`; on `true` → `upsert` + exactly ONE retry,
    ///   on `false` → `HostKeyError.rejectedByUser` (nothing is stored)
    ///
    /// Implementation (phase 2 of the drift strategy): Citadel's host-key hook
    /// is the synchronous, Promise-based `NIOSSHClientServerAuthenticationDelegate`
    /// — it cannot call the async decider itself. So the hook rejects
    /// unknown/differing keys and reports the candidate outward via a box;
    /// here the decider is consulted and, after `upsert`, connects again
    /// (then the known-identical path takes over silently).
    public static func connect(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        onUnknownHostKey: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) async throws -> CitadelFileSystem {
        let box = TOFUHostKeyValidator.Box()
        do {
            return try await attemptConnect(config: config, knownHosts: knownHosts, box: box)
        } catch {
            switch box.result {
            case .mismatch(let host, let expected, let presented):
                // Hard stop — no override, the decider is NEVER asked.
                throw HostKeyError.mismatch(host: host, expected: expected, presented: presented)
            case .lookupFailed(let reason):
                // Corrupt known_hosts store → hard, typed error instead of a
                // silent downgrade to TOFU (fail closed).
                throw RemoteFSError.connectionFailed(reason: "known_hosts store unreadable: \(reason)")
            case .unknown(let candidate):
                let accepted = await onUnknownHostKey(candidate)
                guard accepted else { throw HostKeyError.rejectedByUser }
                try knownHosts.upsert(KnownHostKey(
                    host: candidate.host, port: candidate.port,
                    keyType: candidate.keyType, publicKeyBase64: candidate.publicKeyBase64))
                // Exactly ONE retry: the key is now known → the hook accepts silently.
                do {
                    let retryBox = TOFUHostKeyValidator.Box()
                    return try await attemptConnect(
                        config: config, knownHosts: knownHosts, box: retryBox)
                } catch {
                    throw mapConnectError(error)
                }
            case .none:
                // No host-key verdict → a genuine connection/auth/key error.
                throw mapConnectError(error)
            }
        }
    }

    /// A single connection attempt with the TOFU validator. Throws raw errors;
    /// `connect` handles the evaluation (decider, mismatch, mapping).
    private static func attemptConnect(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        box: TOFUHostKeyValidator.Box
    ) async throws -> CitadelFileSystem {
        let authMethod: SSHAuthenticationMethod
        switch config.auth {
        case .password(let password):
            authMethod = .passwordBased(username: config.username, password: password)
        case .privateKey(let keyPath, let passphrase):
            authMethod = try SSHPrivateKeyLoader.authentication(
                username: config.username, keyPath: keyPath, passphrase: passphrase)
        }

        let validator = TOFUHostKeyValidator(
            host: config.host, port: config.port, knownHosts: knownHosts, box: box)
        let client = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .custom(validator),
            reconnect: .never
        )
        do {
            let sftp = try await client.openSFTP()
            return CitadelFileSystem(client: client, sftp: sftp)
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Translates raw connection errors into typed errors (auth/key/generic).
    private static func mapConnectError(_ error: Error) -> Error {
        switch error {
        case let error as SSHKeyError:
            return error
        case let error as HostKeyError:
            return error
        case let error as RemoteFSError:
            return error
        case let error as SSHClientError:
            // Auth errors surface via Citadel as allAuthenticationOptionsFailed
            // (verified against the Docker test server with a wrong password).
            switch error {
            case .allAuthenticationOptionsFailed:
                return RemoteFSError.authenticationFailed
            default:
                return RemoteFSError.connectionFailed(reason: String(describing: error))
            }
        default:
            return RemoteFSError.connectionFailed(reason: String(describing: error))
        }
    }

    public func list(path: String) async throws -> [RemoteFileItem] {
        do {
            let names = try await sftp.listDirectory(atPath: path)
            return names
                .flatMap { $0.components }
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    SFTPAttributeMapper.item(
                        name: component.filename,
                        directory: path,
                        size: component.attributes.size,
                        permissions: component.attributes.permissions,
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime
                    )
                }
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    public func stat(path: String) async throws -> RemoteFileItem {
        do {
            let attributes = try await sftp.getAttributes(at: path)
            let name = path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
            return SFTPAttributeMapper.item(
                name: name,
                directory: RemotePath.parent(of: path),
                size: attributes.size,
                permissions: attributes.permissions,
                modifiedAt: attributes.accessModificationTime?.modificationTime
            )
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    /// True for errors that mean "the SSH connection/channel is gone".
    /// A mid-transfer disconnect does NOT surface as a typed Citadel error:
    /// in-flight SFTP requests fail with NIO's `ChannelError.ioOnClosedChannel`
    /// (verified via live kill test against the Docker rig), or with Citadel's
    /// `SFTPError.connectionClosed` when the channel closes with pending
    /// request promises; NIOSSH signals a dropped transport as `.tcpShutdown`.
    /// Deliberately conservative: only these clear connection-loss shapes
    /// match — everything else keeps its existing mapping.
    private static func isConnectionLoss(_ error: Error) -> Bool {
        switch error {
        case ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed:
            return true
        case SFTPError.connectionClosed:
            return true
        case let error as NIOSSHError where error.type == .tcpShutdown:
            return true
        default:
            return false
        }
    }

    /// Translates Citadel's raw SFTP status errors into typed RemoteFSError.
    /// The server responds with SSH_FXP_STATUS; Citadel throws that as
    /// SFTPMessage.Status with an errorCode (SFTPStatusCode).
    /// Connection-loss shapes map to `connectionFailed` FIRST so the transfer
    /// queue (M5d) classifies the item `.interrupted` (resumable) instead of
    /// `.failed`.
    /// Internal (not private) so the mapping is unit-testable without a server.
    static func mapSFTPError(_ error: Error, path: String) -> Error {
        if isConnectionLoss(error) {
            return RemoteFSError.connectionFailed(reason: String(describing: error))
        }
        guard let status = error as? SFTPMessage.Status else {
            return RemoteFSError.protocolError(reason: String(describing: error))
        }
        switch status.errorCode {
        case .noSuchFile: return RemoteFSError.notFound(path: path)
        case .permissionDenied: return RemoteFSError.permissionDenied(path: path)
        default: return RemoteFSError.protocolError(reason: String(describing: status))
        }
    }

    public func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: path, flags: .read)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
        // Pull-based (unfolding): the consumer sets the pace. Starting at
        // `offset` beyond EOF: the first read returns 0 readable bytes, so
        // the stream ends immediately (empty), no error.
        var currentOffset = offset
        return AsyncThrowingStream(unfolding: {
            do {
                let buffer = try await file.read(
                    from: currentOffset, length: UInt32(TransferChunk.size))
                guard buffer.readableBytes > 0 else {
                    try await file.close()
                    return nil
                }
                currentOffset += UInt64(buffer.readableBytes)
                return Data(buffer.readableBytesView)
            } catch is CancellationError {
                // Cooperative cancellation (M5c/T2): an in-flight read request
                // throws `CancellationError` on task cancellation — pass it
                // through unchanged, do NOT map it to protocolError, otherwise
                // the item would end `.failed` instead of `.cancelled`. The
                // channel stays usable (file.close).
                try? await file.close()
                throw CancellationError()
            } catch {
                try? await file.close()
                throw Self.mapSFTPError(error, path: path)
            }
        })
    }

    public func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws {
        // SSH_FXF_APPEND (SFTPOpenFileFlags.append) forces the server to
        // append every write to the file's current end regardless of the
        // offset the client sends — but not every server implementation
        // honors that consistently, so belt-and-suspenders: also pre-stat
        // the file's size and start our own offset counter there.
        let flags: SFTPOpenFileFlags
        switch mode {
        case .overwrite: flags = [.create, .write, .truncate]
        case .append: flags = [.create, .write, .append]
        }
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: path, flags: flags)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
        do {
            var offset: UInt64 = 0
            if mode == .append {
                offset = try await file.readAttributes().size ?? 0
            }
            for try await chunk in contents {
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
            }
            try await file.close()
        } catch is CancellationError {
            // Cooperative cancellation (M5c/T2): normally the counting stream
            // from copyFile runs out SILENTLY on cancellation (it ends,
            // doesn't throw) — then copyFile's post-check takes over. But if
            // an in-flight write request itself throws `CancellationError` on
            // task cancellation, pass it through unchanged here (do NOT map
            // to protocolError), otherwise the item would end `.failed`
            // instead of `.cancelled`. Channel stays usable.
            try? await file.close()
            throw CancellationError()
        } catch {
            try? await file.close()
            throw Self.mapSFTPError(error, path: path)
        }
    }

    /// Deletes a FILE at `path` via SFTP `remove` (SSH_FXP_REMOVE). Throws
    /// `notFound` if nothing exists there; a directory at `path` is reported
    /// as `protocolError` by the server-side status mapping (SFTP has no
    /// generic "is a directory" status code).
    public func delete(path: String) async throws {
        do {
            try await sftp.remove(at: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    /// Creates ONLY the last level (parents must already exist — the
    /// recursion in T3 runs top-down). Idempotent: if the path already exists
    /// as a directory (even in a race between two clients), the call returns
    /// silently. If a file exists there, throws `protocolError`.
    public func createDirectory(at path: String) async throws {
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            // mkdir can fail even though the directory (already or by now)
            // exists — verify via stat instead of blindly passing the error on.
            if let existing = try? await sftp.getAttributes(at: path) {
                switch SFTPAttributeMapper.kind(fromPermissions: existing.permissions) {
                case .directory:
                    return
                default:
                    throw RemoteFSError.protocolError(reason: "path exists and is not a directory: \(path)")
                }
            }
            throw Self.mapSFTPError(error, path: path)
        }
    }

    /// Renames/moves to the FULL destination path. The explicit existence
    /// probe keeps the no-silent-overwrite contract server-independent
    /// (SFTP rename semantics differ between servers).
    ///
    /// The probe is SFTP stat (SSH_FXP_STAT), which follows symlinks —
    /// Citadel exposes no lstat. So a DANGLING symlink already at `to` is
    /// invisible to this check and falls through to the server's own
    /// duplicate-name handling in `sftp.rename` instead of our stable
    /// `protocolError` (residual, accepted — matches the Local backend's
    /// best effort, not its exact guarantee).
    public func rename(from: String, to: String) async throws {
        if (try? await sftp.getAttributes(at: to)) != nil {
            throw RemoteFSError.protocolError(reason: "destination already exists: \(to)")
        }
        do {
            try await sftp.rename(at: from, to: to)
        } catch {
            throw Self.mapSFTPError(error, path: from)
        }
    }

    /// Sets only the low 12 permission bits via SFTP setstat.
    public func setPermissions(path: String, permissions: UInt32) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = permissions & 0o7777
        do {
            try await sftp.setAttributes(at: path, to: attributes)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    /// Recursive delete via bottom-up walk: SFTP has no recursive remove.
    /// Files and symlinks go through `remove` (a symlink is removed as the
    /// link itself — never followed, the walk descends only into REAL
    /// directories per the listed entry kind); directories are emptied
    /// first, then removed with rmdir. Cooperatively cancellable per entry;
    /// a partially deleted tree can result not only from cancellation but
    /// also from a mid-walk error (e.g. permissionDenied on a child, or a
    /// rmdir race against a concurrent writer) — both are documented,
    /// accepted best-effort behavior, matching Local.
    ///
    /// GUARANTEE: a top-level symlink argument is NEVER followed. SFTP stat
    /// follows symlinks and Citadel exposes no lstat, so the top level's
    /// kind is instead derived from the PARENT's listing (SSH_FXP_READDIR
    /// reports entries unresolved, exactly like every child encountered
    /// deeper in the walk). Only "/" (no parent to list) or a parent we
    /// cannot list falls back to SFTP stat.
    ///
    /// A trailing slash defeats the parent-listing match below (the listing
    /// never contains an entry whose path ends in "/") and falls through to
    /// the stat fallback, which FOLLOWS the symlink and destroys the
    /// TARGET's contents (proven live in the M7a final review) — so it is
    /// stripped up front, before the kind lookup or anything else.
    public func deleteTree(at path: String) async throws {
        try Task.checkCancellation()
        let path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        try await deleteTree(at: path, kind: try await topLevelKind(of: path))
    }

    /// Derives `path`'s kind WITHOUT ever following a symlink at `path`
    /// itself. SFTP stat follows symlinks and Citadel exposes no lstat, so
    /// the primary source of truth is the PARENT's listing (SSH_FXP_READDIR,
    /// which reports entries unresolved — same guarantee every child in the
    /// walk relies on). `path` is assumed already normalized (no trailing
    /// slash) by the caller.
    ///
    /// Branches:
    /// - `parent == path` (i.e. `path` is "/", the root — it has no parent
    ///   to list): fall back to stat. There is no symlink-following risk
    ///   here, "/" can never itself be a symlink.
    /// - Parent listing succeeds AND contains an entry at `path`: use that
    ///   entry's kind directly — the exact, unresolved, ground-truth answer.
    ///   This is the common case and the only one for anything reachable in
    ///   a normal walk.
    /// - Parent listing succeeds but does NOT contain `path` (e.g. a
    ///   non-normalized form like "/a//b" that the listing's exact-path
    ///   match can't see, or a race where the entry vanished between listing
    ///   and lookup): fall back to stat, but do not trust a `.directory`
    ///   verdict blindly — stat would happily follow a symlink the parent
    ///   listing simply didn't recognize the path as, and reporting
    ///   `.directory` for that would let a symlink argument slip through as
    ///   "is a directory" and get walked into. So: if stat throws (most
    ///   commonly `notFound` — the entry is genuinely gone), propagate that
    ///   error naturally; if stat succeeds and reports `.directory`, that is
    ///   precisely the unverifiable case — throw `protocolError` instead of
    ///   trusting it. Non-directory stat results (`.file`/`.symlink`) are
    ///   safe to trust as-is: `deleteTree(at:kind:)` sends anything that
    ///   isn't `.directory` straight to `delete`, which removes a symlink AS
    ///   the link (never follows), so there is no walk-into-target risk.
    /// - Parent listing fails outright (e.g. permission denied on the
    ///   parent): fall back to stat, same reasoning as above.
    private func topLevelKind(of path: String) async throws -> RemoteFileKind {
        let parent = RemotePath.parent(of: path)
        guard parent != path else {
            // Root: no parent to list, and "/" cannot be a symlink.
            return try await stat(path: path).kind
        }
        if let siblings = try? await list(path: parent),
           let entry = siblings.first(where: { $0.path == path }) {
            return entry.kind
        }
        let statKind = try await stat(path: path).kind
        guard statKind == .directory else {
            // .file / .symlink is safe to trust: deleteTree(at:kind:) routes
            // anything but .directory straight to `delete`, which removes a
            // symlink as the link itself, never following it.
            return statKind
        }
        // The parent listing did not vouch for this path, yet stat (which
        // follows symlinks) reports a directory — this is exactly the
        // shape of a symlink slipping through on a non-normalized path.
        // Refuse to walk into it.
        throw RemoteFSError.protocolError(reason: "cannot verify entry kind for: \(path)")
    }

    private func deleteTree(at path: String, kind: RemoteFileKind) async throws {
        try Task.checkCancellation()
        guard kind == .directory else {
            try await delete(path: path)
            return
        }
        // Reuse `list` (the file has no separate mapping helper besides its
        // inline flatMap/filter/map over SFTPAttributeMapper) instead of
        // re-deriving RemoteFileItems from `sftp.listDirectory` here.
        for child in try await list(path: path) {
            try Task.checkCancellation()
            try await deleteTree(at: child.path, kind: child.kind)
        }
        do {
            try await sftp.rmdir(at: path)
        } catch {
            throw Self.mapSFTPError(error, path: path)
        }
    }

    /// Resolves the login home directory via SFTP `realpath(".")`
    /// (SSH_FXP_REALPATH) — the canonical way an SFTP client discovers the
    /// server's landing directory, same idea as `pwd` right after login.
    public func homeDirectoryPath() async throws -> String {
        do {
            return try await sftp.getRealPath(atPath: ".")
        } catch {
            throw Self.mapSFTPError(error, path: ".")
        }
    }

    public func disconnect() async {
        try? await client.close()
    }
}

extension CitadelFileSystem: RemoteShellProvider {
    /// Shell channel over the SAME connection as SFTP (multiplexed, like WinSCP).
    public func openShell(
        terminal: String, cols: Int, rows: Int
    ) async throws -> any RemoteShell {
        try await CitadelShell.open(
            client: client, terminal: terminal, cols: cols, rows: rows)
    }
}
