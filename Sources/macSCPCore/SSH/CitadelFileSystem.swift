import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// SFTP implementation of RemoteFileSystem based on Citadel.
/// M1: password auth, no host-key verification (TOFU arrives in M3).
public final class CitadelFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let client: SSHClient
    private let sftp: SFTPClient
    private let jumpClient: SSHClient?
    /// I-2's dedicated event-loop group, if `.agent` auth caused one to be
    /// created — `nil` for password/privateKey connections, which stay on
    /// the shared `.singleton` default. Owned by THIS instance once a
    /// connection attempt actually succeeds (see `connect()`'s comment on
    /// why it must not be shut down there): the client's own channel still
    /// runs on this group's loop, so shutdown is deferred to `disconnect()`.
    private let dedicatedGroup: MultiThreadedEventLoopGroup?

    private init(
        client: SSHClient, sftp: SFTPClient, jumpClient: SSHClient? = nil,
        dedicatedGroup: MultiThreadedEventLoopGroup? = nil
    ) {
        self.client = client
        self.sftp = sftp
        self.jumpClient = jumpClient
        self.dedicatedGroup = dedicatedGroup
    }

    /// Marks a stage-1 (jump host) failure so the outer retry loop can tell
    /// it apart from a stage-2 (target) failure WITHOUT disturbing the
    /// host-key box evaluation — verdicts still flow through `jumpBox`/
    /// `targetBox` exactly as before; this only wraps the underlying error
    /// for `mapStageAware` to route correctly.
    private struct JumpStageError: Error {
        let underlying: Error
    }

    /// Connects with Trust-on-First-Use host-key verification, optionally
    /// through one jump host (M10c ProxyJump).
    ///
    /// - known & identical → connect silently
    /// - known & different → `HostKeyError.mismatch` (the decider is NEVER
    ///   asked) — on EVERY hop, jump or target
    /// - unknown → `onUnknownHostKey`; on `true` → `upsert` + retry (bounded
    ///   to one accept per hop), on `false` → `HostKeyError.rejectedByUser`
    ///   (nothing is stored)
    ///
    /// Implementation (phase 2 of the drift strategy): Citadel's host-key hook
    /// is the synchronous, Promise-based `NIOSSHClientServerAuthenticationDelegate`
    /// — it cannot call the async decider itself. So the hook rejects
    /// unknown/differing keys and reports the candidate outward via a box;
    /// here the decider is consulted and, after `upsert`, the WHOLE attempt
    /// (both hops) is retried (then the known-identical path takes over
    /// silently). Without a jump, this is behaviorally unchanged from the
    /// original single-hop path (one accept-retry, same error mapping):
    /// `targetBox` is the only box that ever carries a verdict, and exactly
    /// one accept-retry is allowed.
    ///
    /// M10d (`.agent`): per spec, whichever hop(s) use `.agent` get their
    /// ssh-agent connection established and identities listed EXACTLY ONCE
    /// here, BEFORE the TOFU retry loop below, reused across every retry,
    /// and closed on every exit (success or failure). Each hop that needs
    /// the agent gets its OWN `AgentAuthContext` (independent socket
    /// connection, same underlying `SSH_AUTH_SOCK` agent process) rather
    /// than a single shared client — simpler than coordinating concurrent
    /// access from two hops, with no correctness cost since ssh-agent
    /// natively serves multiple connections.
    public static func connect(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        onUnknownHostKey: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) async throws -> CitadelFileSystem {
        var jumpAgent: AgentAuthContext?
        if let jump = config.jump, isAgentAuth(jump.auth) {
            do {
                jumpAgent = try await AgentAuthContext.connect()
            } catch {
                throw mapStageAware(JumpStageError(underlying: error))
            }
        }
        var targetAgent: AgentAuthContext?
        if isAgentAuth(config.auth) {
            do {
                targetAgent = try await AgentAuthContext.connect()
            } catch {
                await jumpAgent?.close()
                throw mapConnectError(error)
            }
        }
        // I-2: agent-backed signing blocks synchronously on a semaphore
        // (AgentBackedPrivateKey.signature) while a stalled `ssh-add`/hardware
        // token round trip completes — on the process-wide default group
        // (`SSHClient.connect`'s `group:` defaults to
        // `MultiThreadedEventLoopGroup.singleton`, shared by every open tab)
        // that would freeze every other tab's traffic for the duration of the
        // stall. Give agent-authenticated connects their OWN single-threaded
        // group instead, scoped to this `connect()` call's lifetime; the jump
        // hop's child channel (`SSHClient.jump(to:)`) inherits its parent's
        // event loop automatically, so this one group covers both hops.
        let dedicatedGroup: MultiThreadedEventLoopGroup? =
            (jumpAgent != nil || targetAgent != nil)
                ? MultiThreadedEventLoopGroup(numberOfThreads: 1) : nil
        // R-1: tracks whether THIS call ever reached `client.openSFTP()` on
        // `dedicatedGroup` before failing — see the flag type's doc comment
        // and the `catch` below for why that gates immediate vs. deferred
        // shutdown.
        let sftpOpenAttempted = SFTPOpenAttemptFlag()
        do {
            let result = try await connectWithTOFURetries(
                config: config, knownHosts: knownHosts, onUnknownHostKey: onUnknownHostKey,
                jumpAgent: jumpAgent, targetAgent: targetAgent, group: dedicatedGroup,
                sftpOpenAttempted: sftpOpenAttempted)
            await jumpAgent?.close()
            await targetAgent?.close()
            // NOT shut down here on success: `result`'s own SSHClient (and,
            // for a jump, the jump client too) still runs its channel on
            // this group's event loop. `result` now owns `dedicatedGroup`
            // (see `attemptConnect`) and releases it in `disconnect()`.
            return result
        } catch {
            await jumpAgent?.close()
            await targetAgent?.close()
            // No `CitadelFileSystem` survived to take ownership — the group
            // would otherwise leak its thread, so it must be released here.
            if let dedicatedGroup {
                if sftpOpenAttempted.attempted {
                    // R-1: this attempt got as far as calling `client.openSFTP()`
                    // on `dedicatedGroup` before failing (e.g. `openSFTP` itself
                    // timed out) — Citadel already scheduled its uncancelled 15s
                    // "no reply" timer on this group's loop the moment `openSFTP`
                    // was called, win or lose (see `disconnect()`'s comment for
                    // the exact citation). Shutting the group down immediately
                    // here would race that timer exactly like `disconnect()`
                    // used to, so defer it the same way.
                    Task.detached {  // outlive Citadel's uncancelled 15s openSFTP timer (SFTPClient.swift:535)
                        try? await Task.sleep(for: .seconds(16))
                        try? await dedicatedGroup.shutdownGracefully()
                    }
                } else {
                    // `openSFTP` was never reached (host-key rejection, auth
                    // failure, or a transport error during the SSH handshake
                    // itself) — Citadel's timer was never scheduled on this
                    // group, so there's nothing to outlive; shutting down
                    // immediately is correct and avoids leaking the thread.
                    try? await dedicatedGroup.shutdownGracefully()
                }
            }
            throw error
        }
    }

    /// The TOFU accept-retry loop itself, unchanged in shape from before
    /// M10d — `jumpAgent`/`targetAgent` are just threaded through to
    /// `attemptConnect` so the SAME already-listed identities are reused
    /// across every retry (a host-key accept-and-retry reconnects both hops
    /// from scratch, so trying every identity again from the start on such
    /// a retry is correct: the previous attempt never got far enough into
    /// user-auth to consume any of them).
    private static func connectWithTOFURetries(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        onUnknownHostKey: @escaping @Sendable (HostKeyCandidate) async -> Bool,
        jumpAgent: AgentAuthContext?,
        targetAgent: AgentAuthContext?,
        group: MultiThreadedEventLoopGroup?,
        sftpOpenAttempted: SFTPOpenAttemptFlag
    ) async throws -> CitadelFileSystem {
        var acceptRetries = 0
        let maxAcceptRetries = config.jump == nil ? 1 : 2  // one accept per hop
        while true {
            let jumpBox = TOFUHostKeyValidator.Box()
            let targetBox = TOFUHostKeyValidator.Box()
            do {
                return try await attemptConnect(
                    config: config, knownHosts: knownHosts, jumpBox: jumpBox, targetBox: targetBox,
                    jumpAgent: jumpAgent, targetAgent: targetAgent, group: group,
                    sftpOpenAttempted: sftpOpenAttempted)
            } catch {
                // At most ONE hop can carry a verdict per attempt (stage 2
                // only starts after stage 1 succeeds) — check the jump hop first.
                switch jumpBox.result ?? targetBox.result {
                case .mismatch(let host, let expected, let presented):
                    // Hard stop — no override, the decider is NEVER asked.
                    throw HostKeyError.mismatch(host: host, expected: expected, presented: presented)
                case .lookupFailed(let reason):
                    // Corrupt known_hosts store → hard, typed error instead of a
                    // silent downgrade to TOFU (fail closed).
                    throw RemoteFSError.connectionFailed(reason: "known_hosts store unreadable: \(reason)")
                case .unknown(let candidate):
                    guard acceptRetries < maxAcceptRetries else { throw mapStageAware(error) }
                    let accepted = await onUnknownHostKey(candidate)
                    guard accepted else { throw HostKeyError.rejectedByUser }
                    try knownHosts.upsert(KnownHostKey(
                        host: candidate.host, port: candidate.port,
                        keyType: candidate.keyType, publicKeyBase64: candidate.publicKeyBase64))
                    acceptRetries += 1
                    continue  // full reconnect of both hops
                case .none:
                    // No host-key verdict → a genuine connection/auth/key error.
                    throw mapStageAware(error)
                }
            }
        }
    }

    private static func isAgentAuth(_ auth: SSHConnectionConfig.AuthMethod) -> Bool {
        if case .agent = auth { return true }
        return false
    }

    /// Test hook for how `connect()` establishes the ssh-agent connection.
    ///
    /// The brief asks for an injectable factory WITHOUT changing `connect`'s
    /// public signature, so this is a `@TaskLocal` override rather than a
    /// new parameter: scoped to the structured task tree that sets it via
    /// `withValue`, so parallel tests never race on shared mutable state the
    /// way a plain `static var` would. Defaults to the real
    /// `SSHAgentClient.connect(socketPath:)`.
    enum AgentClientFactory {
        @TaskLocal static var override: (@Sendable (String) async throws -> SSHAgentClient)?

        static var current: @Sendable (String) async throws -> SSHAgentClient {
            override ?? { socketPath in try await SSHAgentClient.connect(socketPath: socketPath) }
        }
    }

    /// The ONE ssh-agent connection + identity list a hop's `.agent` auth
    /// reuses across every connect attempt (spec §1: listed once, kept open
    /// for signing, closed exactly once when `connect()` returns or throws).
    private struct AgentAuthContext: Sendable {
        let client: SSHAgentClient
        let identities: [AgentIdentity]

        static func connect() async throws -> AgentAuthContext {
            guard let socketPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
                  !socketPath.isEmpty
            else {
                throw AgentError.socketUnavailable
            }
            let client = try await AgentClientFactory.current(socketPath)
            do {
                let identities = try await client.listIdentities()
                guard !identities.isEmpty else { throw AgentError.noIdentities }
                return AgentAuthContext(client: client, identities: identities)
            } catch {
                await client.close()
                throw error
            }
        }

        func close() async {
            await client.close()
        }
    }

    /// R-1: lets `attemptConnect` signal back to `connect()`'s failure-cleanup
    /// path whether Citadel's `openSFTP()` was ever invoked on `dedicatedGroup`
    /// before the error that unwinds the whole `connect()` call. `openSFTP`
    /// schedules its internal 15s timer (see `disconnect()`'s comment for the
    /// exact citation) as soon as it is CALLED, even if it then fails — so
    /// this must be set the moment the call is made, not on success. Same
    /// `NSLock`-boxed-reference shape as `TOFUHostKeyValidator.Box` above.
    private final class SFTPOpenAttemptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func markAttempted() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }

        var attempted: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// A single connection attempt with the TOFU validators. Throws raw
    /// errors; `connect` handles the evaluation (decider, mismatch, mapping).
    /// Without a jump, this is behaviorally unchanged from the pre-M10c
    /// single-hop path (one accept-retry, same error mapping) — the box is
    /// evaluated on every attempt, which differs only in the
    /// `.lookupFailed`-on-retry case (now a fail-closed typed error, strictly
    /// better than before).
    private static func attemptConnect(
        config: SSHConnectionConfig,
        knownHosts: KnownHostsStore,
        jumpBox: TOFUHostKeyValidator.Box,
        targetBox: TOFUHostKeyValidator.Box,
        jumpAgent: AgentAuthContext?,
        targetAgent: AgentAuthContext?,
        group: MultiThreadedEventLoopGroup?,
        sftpOpenAttempted: SFTPOpenAttemptFlag
    ) async throws -> CitadelFileSystem {
        if let jump = config.jump {
            // Stage 1 (jump host) — any failure here (auth, key loading,
            // host-key rejection, transport) is marked as a JumpStageError so
            // the outer loop / mapStageAware can attribute it to the jump hop.
            let jumpClient: SSHClient
            do {
                let jumpValidator = TOFUHostKeyValidator(
                    host: jump.host, port: jump.port, knownHosts: knownHosts, box: jumpBox)
                jumpClient = try await connectHop(
                    auth: jump.auth, username: jump.username, agent: jumpAgent, box: jumpBox
                ) { method in
                    // I-2: `group` is the dedicated event-loop group `connect()`
                    // creates whenever either hop uses `.agent`; the target
                    // hop's `jump(to:)` call below inherits THIS group's loop
                    // via the jump client's own channel, so passing it only
                    // here still covers both hops.
                    try await SSHClient.connect(
                        host: jump.host,
                        port: jump.port,
                        authenticationMethod: method,
                        hostKeyValidator: .custom(jumpValidator),
                        reconnect: .never,
                        group: group ?? .singleton
                    )
                }
            } catch {
                throw JumpStageError(underlying: error)
            }
            // Stage 2 (target, reached through the jump channel) — every
            // failure from here on closes the jump client before propagating.
            do {
                let targetValidator = TOFUHostKeyValidator(
                    host: config.host, port: config.port, knownHosts: knownHosts, box: targetBox)
                let client = try await connectHop(
                    auth: config.auth, username: config.username, agent: targetAgent, box: targetBox
                ) { method in
                    let settings = SSHClientSettings(
                        host: config.host,
                        port: config.port,
                        authenticationMethod: { method },
                        hostKeyValidator: .custom(targetValidator)
                    )
                    return try await jumpClient.jump(to: settings)
                }
                do {
                    sftpOpenAttempted.markAttempted()
                    let sftp = try await client.openSFTP()
                    return CitadelFileSystem(
                        client: client, sftp: sftp, jumpClient: jumpClient, dedicatedGroup: group)
                } catch {
                    try? await client.close()
                    throw error
                }
            } catch {
                try? await jumpClient.close()
                throw error
            }
        }

        let validator = TOFUHostKeyValidator(
            host: config.host, port: config.port, knownHosts: knownHosts, box: targetBox)
        let client = try await connectHop(
            auth: config.auth, username: config.username, agent: targetAgent, box: targetBox
        ) { method in
            // I-2: see the jump-hop call above — same dedicated group.
            try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: method,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                group: group ?? .singleton
            )
        }
        do {
            sftpOpenAttempted.markAttempted()
            let sftp = try await client.openSFTP()
            return CitadelFileSystem(client: client, sftp: sftp, dedicatedGroup: group)
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Builds the `SSHAuthenticationMethod` for ONE connect attempt and
    /// drives that attempt via `connectOnce`.
    ///
    /// For password/privateKey this is exactly the pre-M10d behavior: a
    /// FRESH auth method built for this one call (M10c lesson —
    /// `SSHAuthenticationMethod` consumes its offer list, so it must never
    /// be reused across attempts).
    ///
    /// For `.agent` it is NOT a single call: Citadel's
    /// `SSHAuthenticationMethod.custom(_:)` forwards to the wrapped
    /// `NIOSSHClientUserAuthenticationDelegate` exactly ONCE per connection
    /// attempt (see `AgentAuthDelegate`'s doc comment for the exact
    /// vendored-source citation) — offering N identities in sequence
    /// therefore means N separate `connectOnce` calls, each wrapping a
    /// FRESH `SSHAuthenticationMethod.custom(...)` around the SAME
    /// `AgentAuthDelegate` instance so its internal cursor advances to the
    /// next not-yet-tried identity. A host-key verdict captured in `box`
    /// during any of those calls stops the loop immediately and rethrows:
    /// it would recur identically for every remaining identity (host-key
    /// validation happens before user-auth) and must be handled by the TOFU
    /// retry loop in `connect`, not masked as if it were an identity
    /// rejection.
    private static func connectHop(
        auth: SSHConnectionConfig.AuthMethod,
        username: String,
        agent: AgentAuthContext?,
        box: TOFUHostKeyValidator.Box,
        connectOnce: (SSHAuthenticationMethod) async throws -> SSHClient
    ) async throws -> SSHClient {
        switch auth {
        case .password(let password):
            return try await connectOnce(.passwordBased(username: username, password: password))
        case .privateKey(let keyPath, let passphrase):
            let method = try SSHPrivateKeyLoader.authentication(
                username: username, keyPath: keyPath, passphrase: passphrase)
            return try await connectOnce(method)
        case .agent:
            guard let agent else {
                // `connect()` always establishes an `AgentAuthContext` for
                // every hop whose `auth` is `.agent` before attemptConnect
                // ever runs — reaching this means that invariant broke.
                throw AgentError.noIdentities
            }
            // M-1: pre-filter to the types `AgentPrivateKeyFactory` actually
            // offers. `AgentAuthDelegate` already skips an unsupported
            // identity internally, but only mid-loop inside a single
            // `nextAuthenticationType` call — the OUTER reconnect loop below
            // would still spend a whole extra `connectOnce` round trip (fresh
            // TCP + SSH handshake) on nothing once the real identities are
            // exhausted, if its bound stayed `agent.identities.count`
            // instead of the filtered count.
            let offerableIdentities = agent.identities.filter {
                AgentPrivateKeyFactory.supports(keyType: $0.keyType)
            }
            let delegate = AgentAuthDelegate(
                username: username, identities: offerableIdentities, client: agent.client)
            // M-3: bound the number of per-identity reconnects at
            // MaxAuthTries parity (OpenSSH's own default is 6) — without a
            // cap, an agent holding many identities could drive unbounded
            // reconnects against the server (each one its own visible failed
            // login, see the M10d design spec §4a).
            let attempts = min(offerableIdentities.count, 6)
            var lastError: Error = AgentError.noIdentities
            // M-2: an outright auth rejection (the server tried the offered
            // identity and said no) must never be masked by a LATER, unrelated
            // failure from trying yet another identity (e.g. a transient
            // transport hiccup). The assignment below runs unconditionally on
            // EVERY rejection seen, so it holds the LAST one, not the first —
            // still preferred over whatever `lastError` ends up being.
            var authRejectionError: Error?
            for _ in 0..<attempts {
                do {
                    return try await connectOnce(.custom(delegate))
                } catch {
                    if box.result != nil { throw error }
                    // I-1: retry another identity ONLY when the server
                    // actually rejected the one we offered
                    // (allAuthenticationOptionsFailed). Any other error --
                    // connect timeout, DNS failure, a transport hiccup -- is
                    // not an auth rejection and would just be repeated up to
                    // `attempts` times (times the outer TOFU loop) for
                    // nothing; rethrow it immediately instead.
                    guard case SSHClientError.allAuthenticationOptionsFailed = error else {
                        throw error
                    }
                    lastError = error
                    authRejectionError = error
                }
            }
            throw authRejectionError ?? lastError
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
        case let error as AgentError:
            // `.socketUnavailable`/`.noIdentities` are their OWN honest,
            // localized conditions (spec §2/§5) — never stringified into a
            // generic connectionFailed. T4 maps these to localized text.
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

    /// Like `mapConnectError`, but attributes stage-1 (jump) failures
    /// distinctly: `allAuthenticationOptionsFailed` becomes
    /// `.jumpAuthenticationFailed` (not `.authenticationFailed`, so the form
    /// highlights the jump credentials, not the target's) and an `SSHKeyError`
    /// from loading the JUMP key is passed through unwrapped — it already
    /// carries its own context (e.g. `fileNotFound(path:)`). Everything that
    /// isn't a `JumpStageError` (i.e. every target-hop failure) goes through
    /// the existing `mapConnectError` unchanged.
    private static func mapStageAware(_ error: Error) -> Error {
        guard let jumpStageError = error as? JumpStageError else {
            return mapConnectError(error)
        }
        switch jumpStageError.underlying {
        case let keyError as SSHKeyError:
            return keyError
        case let agentError as AgentError:
            // Same discipline as mapConnectError: typed, never stringified.
            // The jump context is implicit (T4 already knows which segment
            // — target or jump — it is mapping) so no wrapping is needed
            // here beyond keeping the type intact.
            return agentError
        case let clientError as SSHClientError:
            switch clientError {
            case .allAuthenticationOptionsFailed:
                return RemoteFSError.jumpAuthenticationFailed
            default:
                return RemoteFSError.connectionFailed(
                    reason: "jump host: \(String(describing: clientError))")
            }
        default:
            // Typed security errors (host-key verdicts, key-loading failures)
            // must never be downgraded to a resumable generic failure — only
            // stringify what's left after `mapConnectError` has had a chance
            // to recognize a typed error underneath.
            let mapped = mapConnectError(jumpStageError.underlying)
            if mapped is HostKeyError || mapped is SSHKeyError {
                return mapped
            }
            return RemoteFSError.connectionFailed(
                reason: "jump host: \(String(describing: jumpStageError.underlying))")
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
        // Close the SFTP child channel explicitly (its own closeFuture),
        // rather than relying solely on the parent SSH channel's close to
        // cascade to it, before closing the parent connection(s) and (I-2)
        // releasing the dedicated event-loop group they ran on.
        try? await sftp.close()
        try? await client.close()
        try? await jumpClient?.close()
        // I-2/R-1: release the dedicated event-loop group this connection
        // took ownership of at construction time (see `connect()`) — but not
        // immediately. Citadel's `SFTPClient.openSFTP` schedules an internal
        // 15-second "no reply" timeout task on the connection's event loop
        // unconditionally when it's CALLED, and never cancels it once
        // `openSFTP` succeeds
        // (`Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift:535`).
        // Shutting `dedicatedGroup` down right here, before that timer fires,
        // used to race it: measured at 5 NIO "Cannot schedule tasks on an
        // EventLoop that has already shut down" ERRORs per 5 successful agent
        // sessions (routine quick browse-and-disconnect, well under 15s) —
        // currently a logged error, but NIO documents this becoming a forced
        // crash on future versions. The timer lives entirely inside vendored
        // Citadel and cannot be cancelled from here, so outlive it instead of
        // racing it: detached from this call (so `disconnect()` itself still
        // returns immediately) and past the 15s mark.
        if let dedicatedGroup {
            Task.detached {  // outlive Citadel's uncancelled 15s openSFTP timer (SFTPClient.swift:535)
                try? await Task.sleep(for: .seconds(16))
                try? await dedicatedGroup.shutdownGracefully()
            }
        }
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
