import Foundation
import NIOCore
import Synchronization

/// The jump host a session reaches its target through, as a diagnosis needs
/// it: where the jump is, who logs in there, and where that login's secret is
/// looked up.
///
/// **Why a diagnosis needs it at all.** Until 2026-09-18 the walk ignored the
/// jump completely: `SSHFieldSchema.makeConfig` leaves the hop to its caller,
/// and the diagnosis's dial was the one caller that never attached it. A
/// target reachable only through a bastion therefore read as "does not
/// resolve" or "refused", and the bastion itself was never examined. With
/// one of these, `ConnectionDiagnostics` walks the jump first and then the
/// target THROUGH it (`run(scope:observer:)`).
///
/// **No secret is held here.** `secret` is a lookup, asked by the jump's own
/// dial and by the target's dial through it — the same moment the target's
/// secret is asked (`DiagnosticContext.secret()`), and never before the user
/// pressed Run. What the two builders below hand it is the resolver the
/// connect itself runs, so the diagnosis cannot authenticate the jump with
/// anything the connect would not.
public struct DiagnosticJump: Sendable {
    /// Who logs in at the jump host, and how. Carries no secret.
    public struct Login: Sendable, Equatable {
        public let username: String
        public let authKind: StoredSession.AuthKind
        /// The key file, for a private-key login; `nil` otherwise.
        public let keyPath: String?

        public init(username: String, authKind: StoredSession.AuthKind, keyPath: String?) {
            self.username = username
            self.authKind = authKind
            self.keyPath = keyPath
        }
    }

    /// Where the jump host is, or `nil` when the session's jump could not be
    /// read at all — a reference to a saved connection that is gone, a login
    /// set that is not an SSH login, a form whose jump names no host. The
    /// walk reports that as its jump's first row and reaches nothing through
    /// it (`DiagnosticReason.jumpUnresolvable`).
    public let endpoint: Endpoint?
    public let login: Login
    /// The jump hop's secret, looked up when a dial asks. `nil` for a hop
    /// with nothing stored; throws whatever the store throws.
    let secret: @Sendable () throws -> String?
    /// What the last `secret()` saw of the managed key store. Written by the
    /// lookup itself, which is a non-mutating `@Sendable` closure and so
    /// cannot reach a stored property — the reason
    /// `ManagedKeyPassphraseSecretSource` keeps its own answer in a box too.
    ///
    /// `private`, and set only by the two builders below, both in this file:
    /// a jump built by anyone else has no lookup of its own to record
    /// anything, and answers `noJumpSecret` exactly as it always did.
    private var lastRead = LastJumpStoreRead()

    public init(
        endpoint: Endpoint?, login: Login,
        secret: @escaping @Sendable () throws -> String?
    ) {
        self.endpoint = endpoint
        self.login = login
        self.secret = secret
    }

    /// Why this hop's dial has no secret: `DiagnosticReason.noJumpSecret`, or
    /// `.jumpManagedKeyStoreUnreadable` when the last lookup found
    /// `managed_keys.json` unreadable for a key in the managed key directory.
    ///
    /// Read AFTER the lookup, the same rule `DialSupport
    /// .missingSecretReason(_:secrets:)` states for the target's half:
    /// `dialSecret(usesAgent:missing:_:)` takes `missing` as an autoclosure
    /// and evaluates it only once the lookup has answered nothing, and the
    /// lookup records what it saw while it ran. Evaluated first, this would
    /// read the record of a previous walk, or none at all.
    ///
    /// Three call sites, counted 2026-09-24: `ConnectionDiagnostics.dialJump`,
    /// `ConnectionDiagnostics.throughput` and `DiagnosticJumpStep.dialViaJump`
    /// — the three places a jump's secret is looked up.
    var missingSecretReason: String {
        lastRead.hidTheKey.withLock { $0 }
            ? DiagnosticReason.jumpManagedKeyStoreUnreadable : DiagnosticReason.noJumpSecret
    }

    /// The jump of a session that has one but whose jump could not be read.
    static func unresolvable() -> DiagnosticJump {
        DiagnosticJump(
            endpoint: nil, login: Login(username: "", authKind: .password, keyPath: nil),
            secret: { nil })
    }
}

// MARK: - Where a jump comes from

extension DiagnosticJump {
    /// A stored session's jump, resolved the way the connect resolves it, or
    /// `nil` for a session without one.
    ///
    /// Host, port and login come from `LoginResolver.resolveJump(spec:sets:
    /// secrets:sessions:referencingSessionID:)` — the manual, login-set and
    /// saved-connection modes alike, with the same refusals — handed a store
    /// that holds nothing, so building this reads no Keychain item. The
    /// secret is the SAME resolution again, with the real store, followed by
    /// the managed key's fallback (`LoginResolver
    /// .preferringManagedKeyPassphrase`) — the two calls the App's connect
    /// fill makes (`SessionListViewModel.resolvedJump(for:)`) — deferred until
    /// a dial asks. So the slot the diagnosis reads is the slot the connect
    /// reads, by construction rather than by a second statement of which slot
    /// that is.
    ///
    /// A jump the resolver refuses is `unresolvable()`: the diagnosis says so
    /// in its first row instead of dialling the target without its bastion.
    public static func stored(
        for session: StoredSession, sets: [LoginSet], sessions: [StoredSession],
        secrets: any SecretStore, keys: ManagedKeyStore
    ) -> DiagnosticJump? {
        guard let spec = session.jump else { return nil }
        let shape: ResolvedJump
        do {
            shape = try LoginResolver.resolveJump(
                spec: spec, sets: sets, secrets: NoSecretsStore(), sessions: sessions,
                referencingSessionID: session.id)
        } catch {
            return .unresolvable()
        }
        let host = shape.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let referencingID = session.id
        let lastRead = LastJumpStoreRead()
        var jump = DiagnosticJump(
            endpoint: host.isEmpty ? nil : Endpoint(host: host, port: shape.port),
            login: Login(
                username: shape.login.username, authKind: shape.login.authKind,
                keyPath: shape.login.keyPath),
            secret: {
                let resolved = try LoginResolver.resolveJump(
                    spec: spec, sets: sets, secrets: secrets, sessions: sessions,
                    referencingSessionID: referencingID)
                let preferred = LoginResolver.preferringManagedKeyPassphrase(
                    resolved.login, keys: keys, secrets: secrets)
                // The fallback carries the unreadable-store fact out of the
                // resolver (`ResolvedLogin.unreadableStoreHidTheKey`); this
                // is where it is kept, for `missingSecretReason` to read once
                // the lookup has answered.
                lastRead.hidTheKey.withLock { $0 = preferred.unreadableStoreHidTheKey }
                return preferred.secret
            })
        jump.lastRead = lastRead
        return jump
    }

    /// The jump a connection FORM describes — a tab's — or `nil` when the
    /// form's jump is switched off.
    ///
    /// Where and who come from the form's own jump fields, the ones the tab
    /// dialled with (the connect fills them from a login set or a saved
    /// connection before it dials, `SessionListViewModel.prepareForSubmit`).
    /// The secret does NOT come from the form: the diagnosis reads no typed
    /// secret for the target either (`DiagnosticsTarget`'s doc comment), and
    /// the jump follows the same rule. It is `stored`'s lookup — the stored
    /// session behind the tab — and a tab backed by no stored jump has no
    /// secret to offer, so its jump dial reports that rather than dialling
    /// without one.
    ///
    /// **And only when the form's jump IS the stored jump** (fix round 1 of
    /// the 2026-09-18 plan's Task 6, the coordinator's ruling): host, port,
    /// user name and auth kind all equal to the stored jump's. A form whose
    /// jump was edited and not saved names another login, and handing it the
    /// stored bastion's password would send that password to whatever host
    /// the form now names. Such a jump has no secret either, and its dial
    /// reports `noJumpSecret`. Compared exactly, the host included: a
    /// spelling that differs only in case is still not the value the secret
    /// was stored for, and a refusal costs one skipped row.
    public static func form(
        _ values: FieldValues, isEnabled: Bool, stored: DiagnosticJump?
    ) -> DiagnosticJump? {
        guard isEnabled else { return nil }
        let host = values[SSHField.jump, SSHJumpField.host]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(
            values[SSHField.jump, SSHJumpField.port]
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        let authKind =
            StoredSession.AuthKind(rawValue: values[SSHField.jump, SSHJumpField.authKind])
            ?? .password
        let keyPath = values[SSHField.jump, SSHJumpField.keyPath]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = host.isEmpty ? nil : Endpoint(host: host, port: port)
        let login = Login(
            username: values[SSHField.jump, SSHJumpField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            authKind: authKind,
            keyPath: authKind == .privateKey && !keyPath.isEmpty ? keyPath : nil)
        let noSecret: @Sendable () throws -> String? = { nil }
        let adopted: DiagnosticJump?
        if let stored, let endpoint, stored.endpoint == endpoint,
            stored.login.username == login.username, stored.login.authKind == login.authKind
        {
            adopted = stored
        } else {
            adopted = nil
        }
        var jump = DiagnosticJump(
            endpoint: endpoint, login: login, secret: adopted?.secret ?? noSecret)
        // The fact rides with the lookup it came from: a form that took the
        // stored jump's secret takes what that lookup records too, so its
        // dial names the store for the same read. A form that took nothing
        // has no lookup, and no fact.
        if let adopted { jump.lastRead = adopted.lastRead }
        return jump
    }
}

// MARK: - The two configs a jump diagnosis dials

extension DiagnosticJump {
    /// The jump host's own login as a config: what `jump.dial` opens, with no
    /// hop of its own (one hop only, `LoginResolver.resolveJump`).
    func jumpConfig(secret: String) throws -> SSHConnectionConfig {
        guard let endpoint else { throw SSHConnectionConfig.ConfigError.emptyJumpHost }
        return try SSHConnectionConfig(
            host: endpoint.host, port: endpoint.port, username: login.username,
            auth: auth(secret: secret))
    }

    /// The target's config THROUGH this jump — what `target.dialViaJump`
    /// dials: the target's own config (`SSHFieldSchema.makeConfig`), with
    /// this hop attached.
    ///
    /// The attaching is the whole point, and `theTargetDialThroughAJumpCarriesTheJump`
    /// pins it: `makeConfig` returns a config whose `jump` is always nil
    /// (it takes one secret and a jump has a second), so a caller that
    /// forgot this step would dial the target directly — which is exactly
    /// what the diagnosis did before it knew about jumps.
    func targetConfig(
        values: FieldValues, targetSecret: String, jumpSecret: String
    ) throws -> SSHConnectionConfig {
        guard case .ssh(let target) = try SSHFieldSchema.makeConfig(values, targetSecret) else {
            throw RemoteFSError.protocolError(reason: "wrong config for the SSH backend")
        }
        let hop = try jumpConfig(secret: jumpSecret)
        // Through the throwing initializer, so the hop meets the jump's own
        // whitelists (`isValidJumpHost`, `isValidJumpUsername`) exactly as
        // the connect's `attachingJump(to:)` makes it.
        return try SSHConnectionConfig(
            host: target.host, port: target.port, username: target.username,
            auth: target.auth,
            jump: SSHConnectionConfig.Jump(
                host: hop.host, port: hop.port, username: hop.username, auth: hop.auth))
    }

    /// The jump login's auth method, through the target's own mapping
    /// (`SSHFieldSchema.authMethod`) so the two logins cannot mean different
    /// things by the same kind.
    private func auth(secret: String) -> SSHConnectionConfig.AuthMethod {
        SSHFieldSchema.authMethod(
            kind: login.authKind.rawValue, keyPath: login.keyPath ?? "", secret: secret)
    }
}

// MARK: - The connection a jump diagnosis holds open

/// The authenticated connection to the jump host that `jump.dial` opens and
/// every `target.` step after it measures through.
///
/// A protocol for the seam's sake: the suite hands the walk a fake that
/// records what was asked of it and whether it was closed, so the order, the
/// skipping and the closing are measured without a server. Production is
/// `SSHForwardingConnection`, the connection a port forwarding is carried
/// over — authenticated, with no child channel opened on it.
///
/// Two things are asked of it besides closing: a channel to the target
/// (`target.tcpViaJump`), and a probe command run ON the jump host
/// (`target.resolveOnJump`, `target.icmpFromJump`, `target.traceFromJump`,
/// `JumpProbes.swift`). The connection is open for the whole target half
/// and closed after it.
protocol DiagnosticJumpConnection: Sendable {
    /// Opens one `direct-tcpip` channel to `host:port` as the jump host
    /// reaches it, and closes it again. Throws `DirectTCPIPRejection` when
    /// the jump refuses the channel — carrying the refusal's reason code, so
    /// the step can tell a refusal to forward from a target the jump could
    /// not connect to (`DirectTCPIPRefusal`) — and the transport's own error
    /// for anything else.
    func probeDirectTCPIP(host: String, port: Int) async throws

    /// Runs `command` on the jump host as one `exec` request and hands back
    /// its standard output and exit status; standard error is dropped.
    /// Each chunk of standard output is also appended to `transcript` as it
    /// arrives. Throws `RemoteCommandOutputTooLarge` past
    /// `JumpProbeCommand.maxStandardOutputBytes`, and the channel's own error
    /// when the jump host refuses the channel or the request.
    ///
    /// A `JumpProbeCommand` and never a `String`, so a fake that records
    /// what it was asked records exactly what production would have sent.
    func run(
        _ command: JumpProbeCommand, into transcript: JumpProbeTranscript
    ) async throws -> RemoteCommandOutput

    /// Ends the connection. Awaited: the walk returns only once it is gone.
    func disconnect() async
}

/// The two dials a jump diagnosis makes, as a seam.
///
/// `live(knownHosts:)` is what ships; the suite builds its own. Both dials
/// answer the host-key question with `HostKeyDecider.refusing` — a diagnosis
/// has nobody to ask, and a probe that trusted an unknown key would be
/// writing a TOFU consent nobody gave — for the jump's key as much as for
/// the target's. A mismatch is decided inside the connect, before any
/// decider is consulted.
struct DiagnosticJumpDialer: Sendable {
    /// Opens the jump connection: transport, the jump's host key, the jump's
    /// login. Nothing else — no SFTP.
    var connectJump:
        @Sendable (SSHConnectionConfig, _ timeoutSeconds: Int) async throws
            -> any DiagnosticJumpConnection
    /// The target's own dial through the jump — the two-stage connect a tab
    /// makes, SFTP channel included — closed again once it succeeded.
    var dialTarget: @Sendable (SSHConnectionConfig, _ timeoutSeconds: Int) async throws -> Void

    /// The real dials, over `knownHosts`. The runner's default is the store
    /// the app's own connect reads (`BackendDescriptor`'s SSH `connect`); the
    /// rig case hands one holding the rig's recorded keys.
    static func live(knownHosts: KnownHostsStore) -> DiagnosticJumpDialer {
        DiagnosticJumpDialer(
            connectJump: { config, seconds in
                try await SSHForwardingConnection.connect(
                    config: config, connectTimeout: .seconds(Int64(seconds)),
                    knownHosts: knownHosts, onUnknownHostKey: .refusing)
            },
            dialTarget: { config, seconds in
                let fileSystem = try await CitadelFileSystem.connect(
                    config: config, connectTimeout: .seconds(Int64(seconds)),
                    knownHosts: knownHosts, onUnknownHostKey: .refusing)
                await fileSystem.disconnect()
            })
    }
}

extension SSHForwardingConnection: DiagnosticJumpConnection {
    func probeDirectTCPIP(host: String, port: Int) async throws {
        let channel: Channel
        do {
            channel = try await directTCPIPChannel(host: host, port: port)
        } catch {
            throw DirectTCPIPRejection(error) ?? error
        }
        try? await channel.close()
    }

    func run(
        _ command: JumpProbeCommand, into transcript: JumpProbeTranscript
    ) async throws -> RemoteCommandOutput {
        try await standardOutput(of: command, into: transcript)
    }
}

// MARK: - The steps measured through the jump

/// One step of the target half: measured THROUGH the open jump connection,
/// under the scope phase that runs it.
///
/// A list of these is the target half (`ConnectionDiagnostics.targetHalf`),
/// walked in order once the jump has been reached and skipped, row by row,
/// when it has not. Adding a step through the jump is one entry there and
/// nothing else — the connection it needs is opened when any entry in scope
/// needs it, and closed after the last.
struct DiagnosticJumpStep: Sendable {
    /// What a step measures with.
    struct Context: Sendable {
        /// The open, authenticated connection to the jump host.
        let connection: any DiagnosticJumpConnection
        let jump: DiagnosticJump
        /// The target as the session names it, and as the jump must reach it.
        let target: Endpoint
        /// The session's field values — the target's login.
        let values: FieldValues
        /// The target's secret source and the step budget.
        let diagnostic: DiagnosticContext
        let dialer: DiagnosticJumpDialer
        /// The budget THIS step is raced against — its `Budget`, resolved —
        /// for a step that sizes a command to it.
        let budget: Duration
        /// What this step's commands have printed so far. Fresh per step
        /// (`forStep(budget:)`), and read by the step's `cut` when the
        /// budget abandons it.
        let transcript: JumpProbeTranscript

        /// This context for one step: its own budget, and an empty
        /// transcript.
        func forStep(budget: Duration) -> Context {
            Context(
                connection: connection, jump: jump, target: target, values: values,
                diagnostic: diagnostic, dialer: dialer, budget: budget,
                transcript: JumpProbeTranscript())
        }
    }

    /// Which of the walk's two budgets a step is raced against.
    ///
    /// Every step of the target half used to race `stepTimeout` (5 s), and
    /// the trace's own budget never reached this half at all — so a trace
    /// run on the jump host, which may walk up to thirty hops at a second
    /// each, would have been cut off a few silent hops in, for the reason
    /// the jump's own trace once was (`ConnectionDiagnostics.init`'s note on
    /// `traceTimeout`).
    enum Budget: Sendable, Equatable {
        /// `stepTimeout`: one probe, one answer.
        case step
        /// `traceTimeout`: a hop-by-hop walk.
        case trace

        /// The duration this budget names, out of the walk's two.
        func duration(step: Duration, trace: Duration) -> Duration {
            switch self {
            case .step: return step
            case .trace: return trace
            }
        }
    }

    let id: String
    /// Which scope phase runs this step (`DiagnosticScope.runs(_:)`).
    let phase: DiagnosticScope.OptionalStep
    /// Which budget the walk races this step against
    /// (`ConnectionDiagnostics.bounded(_:_:_:)`).
    let budget: Budget
    let measure: @Sendable (Context, DiagnosticStepTimer) async -> DiagnosticStep
    /// The row when the budget abandoned `measure`, read from what the step
    /// had collected by then (`Context.transcript`) — or `nil` for a step
    /// with nothing to salvage, whose row is then a plain `timedOut`.
    let cut: (@Sendable (Context, DiagnosticStepTimer) -> DiagnosticStep)?

    init(
        id: String, phase: DiagnosticScope.OptionalStep, budget: Budget = .step,
        cut: (@Sendable (Context, DiagnosticStepTimer) -> DiagnosticStep)? = nil,
        measure: @escaping @Sendable (Context, DiagnosticStepTimer) async -> DiagnosticStep
    ) {
        self.id = id
        self.phase = phase
        self.budget = budget
        self.cut = cut
        self.measure = measure
    }

    /// A `direct-tcpip` channel to the target, opened over the jump
    /// connection and closed again: the jump's name resolution of the target,
    /// its TCP connect, and whether it forwards at all, in one open. A
    /// refusal names which of the last two it was (`DirectTCPIPRefusal`).
    static let tcpViaJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetTCPViaJump, phase: .tcp
    ) { context, timer in
        do {
            try await context.connection.probeDirectTCPIP(
                host: context.target.host, port: context.target.port)
            return timer.finish(.ok, "the jump host opened a channel to \(context.target.text)")
        } catch {
            return timer.finish(.failed(DirectTCPIPRefusal.reason(for: error)), "")
        }
    }

    /// The target's own dial through the jump: the two-stage connect a tab
    /// makes — the jump's host key and login, then the target's host key,
    /// login and SFTP channel — with both host keys answered by the refusing
    /// decider (`DiagnosticJumpDialer`).
    ///
    /// Its own jump hop, not the connection the steps before it share: that
    /// is the connect path a tab takes, and a dial through a borrowed
    /// connection would measure a path the app never dials.
    static let dialViaJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetDialViaJump, phase: .dial
    ) { context, timer in
        let targetSecret: String
        switch DialSupport.dialSecret(
            usesAgent: context.values[SSHField.authKind]
                == StoredSession.AuthKind.agent.rawValue,
            missing: DialSupport.missingSecretReason(
                DiagnosticReason.noSecret, secrets: context.diagnostic.secrets),
            context.diagnostic.secret)
        {
        case .secret(let secret): targetSecret = secret
        case .unanswered(let outcome): return timer.finish(outcome, "")
        }
        let jumpSecret: String
        switch DialSupport.dialSecret(
            usesAgent: context.jump.login.authKind == .agent,
            missing: context.jump.missingSecretReason, context.jump.secret)
        {
        case .secret(let secret): jumpSecret = secret
        case .unanswered(let outcome): return timer.finish(outcome, "")
        }
        do {
            let config = try context.jump.targetConfig(
                values: context.values, targetSecret: targetSecret, jumpSecret: jumpSecret)
            try await context.dialer.dialTarget(
                config, DialSupport.connectSeconds(context.diagnostic.timeout))
            return timer.finish(
                .ok, "both host keys, both logins and the SFTP channel, through the jump host")
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
    }
}

/// The reference-type box behind `DiagnosticJump.missingSecretReason`: the
/// hop's secret lookup is a non-mutating `@Sendable` closure and cannot write
/// to a struct's stored property. The same shape, and for the same reason, as
/// `ManagedKeyPassphraseSecretSource`'s own `LastStoreRead`; a `Mutex`, so the
/// class is plainly `Sendable`.
final class LastJumpStoreRead: Sendable {
    let hidTheKey = Mutex(false)
}

// MARK: - A refused channel, read

/// What `target.tcpViaJump` fails with when the jump host refused its
/// channel (`DirectTCPIPRejection`), by reason code (RFC 4254 §5.1): the two
/// causes a user can act on — the jump may not forward at all, or it tried
/// and could not reach the target — each a fixed sentence, and any other
/// code named by its number. Never the server's own words, the rule
/// `DialSupport.reason(for:)` keeps for every foreign error.
enum DirectTCPIPRefusal {
    static func reason(for error: any Error) -> String {
        guard let rejection = error as? DirectTCPIPRejection else {
            return DialSupport.reason(for: error)
        }
        switch rejection.reasonCode {
        case DirectTCPIPRejection.administrativelyProhibited:
            return DiagnosticReason.jumpForwardingProhibited
        case DirectTCPIPRejection.connectFailed:
            return DiagnosticReason.jumpCouldNotConnect
        default:
            return DiagnosticReason.jumpRefusedChannel(code: rejection.reasonCode)
        }
    }
}
