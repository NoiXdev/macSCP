import Foundation

/// The `dial` step, one per backend: the app's own connection attempt, timed
/// and reported as a single row (design §2.4).
///
/// Each of the three is written against what its backend can actually do
/// WITHOUT authenticating, and says so honestly where it cannot:
///
/// * **SSH** — Citadel exposes no transport-only connect (there is no way to
///   run the KEX and stop before user-auth), so this step is the FULL connect
///   with the session's credentials, through the same funnel the app dials
///   with. The row is named "SSH connect" for that reason rather than
///   "handshake", and it is the one dial that reads a secret.
/// * **S3** — an unsigned `HEAD` on the configured endpoint. The server
///   refuses it, and the refusal is the measurement: an HTTP status means the
///   endpoint is there, answering, and (over HTTPS) presenting a certificate
///   this machine accepts.
/// * **WebDAV** — an unauthenticated `OPTIONS` on the base URL, which also
///   brings back what the server claims to be (`DAV:` and `Allow`).
///
/// A row is `ok` when the server ANSWERED, whatever it answered: a 401 to an
/// unauthenticated probe is a working server, and calling it a failure would
/// point the user at their network for a question they never asked.
extension DiagnosticContribution {
    /// Builds a contribution whose body is handed a timer already started
    /// under this contribution's own id and key — so a row cannot end up
    /// labelled with a key its contribution does not carry, which is what
    /// happens when both are spelled twice.
    static func measured(
        id: String, titleKey: String,
        _ body: @escaping @Sendable (
            FieldValues, DiagnosticContext, DiagnosticStepTimer
        ) async -> DiagnosticStep
    ) -> DiagnosticContribution {
        DiagnosticContribution(id: id, titleKey: titleKey) { values, context in
            await body(values, context, DiagnosticStepTimer(id: id, titleKey: titleKey))
        }
    }

    /// SSH: transport, host-key check, authentication and the SFTP channel,
    /// as one row.
    ///
    /// The host-key question is answered by `HostKeyDecider.refusing`: a
    /// diagnosis has nobody to ask, and a probe that trusted an unknown key
    /// on the user's behalf would be writing a TOFU consent nobody gave. A
    /// session whose key is already known dials through; an unknown one is
    /// reported as the failure it is, which is itself the answer to "why does
    /// this not connect".
    static let sshConnect = DiagnosticContribution.measured(
        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.sshConnect"
    ) { values, context, timer in
        let usesAgent = values[SSHField.authKind] == StoredSession.AuthKind.agent.rawValue
        var secret = ""
        if !usesAgent {
            do {
                guard let resolved = try context.secret(), !resolved.isEmpty else {
                    return timer.finish(.skipped(DiagnosticReason.noSecret), "")
                }
                secret = resolved
            } catch {
                // Deliberately not the source's own error text: a failing
                // vault's message is the one place a wrapper could hand back
                // something it read.
                return timer.finish(.unavailable(DiagnosticReason.secretSourceFailed), "")
            }
        }
        let config: ConnectionConfig
        do {
            config = try SSHFieldSchema.makeConfig(values, secret)
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
        do {
            let fileSystem = try await BackendDescriptor.openConnection(
                config, hostKey: .refusing, certificate: .refusing,
                timeoutSeconds: DialSupport.connectSeconds(context.timeout))
            await fileSystem.disconnect()
            return timer.finish(.ok, "transport, host key, authentication and the SFTP channel")
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
    }

    /// S3: an unsigned `HEAD` on the endpoint.
    static let s3EndpointHead = DiagnosticContribution.measured(
        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.s3Endpoint"
    ) { values, context, timer in
        guard let url = S3FieldSchema.endpointURL(values) else {
            return timer.finish(.skipped(DiagnosticReason.noEndpoint), "")
        }
        return await DialSupport.request(
            url: url, method: "HEAD", timeout: context.timeout, timer: timer
        ) { response in
            "HTTP \(response.statusCode) to an unsigned HEAD on \(URLText.hostPortPath(of: url))"
        }
    }

    /// WebDAV: an unauthenticated `OPTIONS` on the base URL.
    static let webdavOptions = DiagnosticContribution.measured(
        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.webdavOptions"
    ) { values, context, timer in
        guard let url = WebDAVFieldSchema.baseURL(values) else {
            return timer.finish(.skipped(DiagnosticReason.noServerURL), "")
        }
        return await DialSupport.request(
            url: url, method: "OPTIONS", timeout: context.timeout, timer: timer
        ) { response in
            var detail = "HTTP \(response.statusCode) to an unauthenticated OPTIONS on "
                + URLText.hostPortPath(of: url)
            // What the server claims to be. Absent on a server that answered
            // the request without being a DAV server at all, which is a
            // finding rather than an error.
            if let dav = response.value(forHTTPHeaderField: "DAV") {
                detail += "; DAV: \(dav)"
            }
            if let allow = response.value(forHTTPHeaderField: "Allow") {
                detail += "; Allow: \(allow)"
            }
            return detail
        }
    }
}

/// The three things the dials above do the same way: turn an error into one
/// printable line, hand a transport the step's budget, and send one
/// credential-free HTTP request.
public enum DialSupport {
    /// A short, technical reason for a step's `failed` outcome.
    ///
    /// `public` since the session-overview work: the App records a failed
    /// connect as `AuditEvent.Kind.connectFailed`, and the sentence it
    /// stores has to be THIS one. Task 2 of the session-overview plan is the
    /// caller to come — the connect path in `MacSCPAppKit`, which today has
    /// no way to reach a fixed sentence and would otherwise store an error's
    /// own text, which is exactly what the paragraphs below explain must
    /// never be stored. The rest of this enum stays module-internal: only
    /// the sentence crosses the target boundary, not the request helper or
    /// the timeout arithmetic.
    ///
    /// The three typed SSH errors are spelled out because none of them
    /// conforms to `LocalizedError`: bridged to `NSError` they all read "The
    /// operation couldn't be completed. (macSCPCore.HostKeyError error N.)"
    /// — `N` being the case index, whatever it is — which says nothing about
    /// host keys — in the row this file documents
    /// as the answer to "why does this not connect", and for the four
    /// commonest SSH dial failures. Every enum arm below is an exhaustive
    /// `switch` with no `default` — re-counted 2026-09-16: SIX of them, over
    /// `HostKeyError`, `TunnelFailure`, `TunnelRefusal`, `SSHKeyError`,
    /// `AgentError` and `RemoteFSError` (four until the port-forwarding
    /// plan's Task 5 added `TunnelFailure`, five until the technical-backlog
    /// plan's Task 6 added `TunnelRefusal`) — so a case added to any of the
    /// six fails to compile here until someone writes its sentence and names
    /// its kind. `KeychainError`, a struct with no cases, is the one arm that
    /// is not a switch.
    ///
    /// `RemoteFSError` is spelled out too, and this comment used to argue
    /// the opposite — that every one of its cases carries strings this
    /// project wrote, so its raw description was "already credential-free".
    /// Measured false on 2026-09-04. `connectionFailed(reason:)` and
    /// `protocolError(reason:)` carry FREE TEXT, and the two URL-shaped
    /// backends compose that text out of the endpoint the user typed —
    /// a field that takes `scheme://KEY:SECRET@host` as ordinary input
    /// (`ConnectFailureSecrecyTests`). `DiagnosticStep.init`'s backstop
    /// strips the plain shape but cannot strip a secret containing a `/`:
    /// `URLText.withoutUserinfo` documents that hole about itself, the
    /// authority scan ends at the slash and the line is copied through
    /// whole. So each case gets one fixed sentence instead, and the two
    /// free-text payloads are dropped rather than rendered.
    ///
    /// `TunnelFailure` is spelled out because it conforms to no
    /// `LocalizedError` either, and its generic rendering was measured on
    /// 2026-09-06 as the exact shape the paragraph above describes:
    /// `portInUse(port: 8080)` reached the tunnel's failed state and the
    /// `tunnel … failed reason=` line as "The operation couldn't be
    /// completed. (macSCPCore.TunnelFailure error 0.)" — the port, the one
    /// thing a person can act on, replaced by a case index.
    ///
    /// Its four `reason:` payloads are passed through rather than dropped,
    /// which is the OPPOSITE of the decision taken for `RemoteFSError` above,
    /// and the difference is where the text comes from. `RemoteFSError`'s
    /// free text is composed out of an endpoint the user typed;
    /// `TunnelFailure`'s is not composed out of user input at all. Counted
    /// 2026-09-06 as 14 construction sites under `Sources/` that carry a
    /// `reason:`. Recounted 2026-09-16 with `grep -rnE
    /// '(bindFailed|channelOpenFailed|connectFailed|pumpFailed)\((reason:|\s*$)'
    /// Sources/`, doc-comment lines and the case declarations dropped: 16 at
    /// `9167f325` — the two that count had not listed were
    /// `TunnelConnection`'s refusal, which passed `TunnelCarriers`' sentence,
    /// and `TunnelManager`'s "no longer exists" literal — and 14 after both
    /// became `TunnelRefusal` the same day. Every one of the 14 passes either
    /// this function's own output or a fixed English sentence written in this
    /// repository: SEVEN pass
    /// `DialSupport.reason(for:)` (or `CitadelFileSystem.bindReason(for:
    /// bind:)`, which is that plus a fixed clause naming `GatewayPorts`) —
    /// `CitadelFileSystem.openDirectTCPIP` and `withRemotePortForward`,
    /// `LocalForwardListener.acceptFailure` and `bindFailure`,
    /// `RemoteForward.serve`, `startFailure` and `pairFailure` — and SEVEN
    /// pass a literal: `CitadelFileSystem`'s port-0 refusal,
    /// `LocalForwardListener`'s "the bound socket reports no port",
    /// `RemoteForward`'s two answer-bound sentences and its two "the forward
    /// has been stopped", and `TunnelConnection`'s "built a non-SSH
    /// connection" sentence (named here as "port forwarding needs an SSH
    /// session" until 2026-09-16, a sentence `Sources/` at `9167f325` held
    /// only in this comment). A payload
    /// that is already this function's output must
    /// not be re-mapped (that is `LocalForwardListener.acceptFailure`'s own
    /// argument, one layer down), and a payload that is a fixed sentence has
    /// nothing to hide. The payload reaches the log and the command line's
    /// stderr (`TunnelRunner.failureReason`) only — never the state:
    /// `failureKind(for:)` names these four cases `bindFailed` …
    /// `pumpFailed` and drops the text, because a payload built by this
    /// function can be a foreign error's `localizedDescription`.
    ///
    /// Everything else — a `URLError`, an NIO or Citadel error — is reduced
    /// to `localizedDescription` and never `String(describing:)`, because
    /// describing an arbitrary error prints its stored properties, and a
    /// transport error is exactly the kind of value that carries the
    /// configuration it was dialling with.
    ///
    /// English, like every other sentence this module produces: the report is
    /// a paste artifact. The panel is the localized surface, and Task 4 owns
    /// the keys — the report for this task lists the ones these sentences
    /// need.
    public static func reason(for error: any Error) -> String {
        classify(error).sentence
    }

    /// What a forwarding's failure IS, for `TunnelState.failed`: the kind,
    /// from the same switch `reason(for:)` renders its sentence from, so the
    /// state and the log line describe one failure.
    ///
    /// An error a forwarding's dial or start does not produce — a bucket
    /// refusal, a path not found — is `.unknown`; its sentence is unchanged.
    public static func failureKind(for error: any Error) -> TunnelFailureKind {
        classify(error).kind
    }

    /// The one switch behind both. An arm whose kind carries everything its
    /// sentence needs returns `known(_:)` — the sentence is then the kind's
    /// own (`TunnelFailureKind.sentence`) and has no second spelling here.
    /// An arm whose sentence carries text the kind must not hold (a
    /// `TunnelFailure` payload, a path) names its kind beside the sentence.
    private static func classify(_ error: any Error) -> (kind: TunnelFailureKind, sentence: String) {
        func known(_ kind: TunnelFailureKind) -> (kind: TunnelFailureKind, sentence: String) {
            (kind, kind.sentence)
        }
        switch error {
        case let error as HostKeyError:
            switch error {
            case .mismatch(let host, _, _):
                // Names the host, never the fingerprints (maintainer
                // decision, 2026-09-16): this sentence is what
                // `DiagnosticLog`, the tunnel failure reason and the
                // diagnostics report persist or display verbatim, and a
                // fingerprint pasted into one of those is a fingerprint
                // pasted into a public issue. The App's mismatch alert
                // (`core.hostkey.mismatch %@ %@ %@`) and the CLI's stderr
                // (`CLIErrorMapping`) build their own sentence straight from
                // `expected`/`presented` instead of calling this function,
                // and keep showing both — they are shown only to the person
                // deciding whether to trust the new key, never persisted.
                return known(.hostKeyMismatch(host: host))
            case .rejectedByUser:
                return known(.hostKeyNotAccepted)
            }
        case let error as TunnelFailure:
            switch error {
            case .portInUse(let port):
                return known(.portInUse(port: port))
            case .bindFailed(let reason):
                return (.bindFailed, reason)
            case .channelOpenFailed(let reason):
                return (.channelOpenFailed, reason)
            case .connectFailed(let reason):
                return (.connectFailed, reason)
            case .pumpFailed(let reason):
                return (.pumpFailed, reason)
            case .alreadyStarted:
                return known(.alreadyStarted)
            }
        case let error as TunnelRefusal:
            // The refusals a stored session earns before anything is dialled.
            // Each sentence names the session and the rule; none names a
            // jump's host or a login set's contents.
            switch error {
            case .loginSet(let session):
                return known(.sessionUsesLoginSet(session: session))
            case .jumpHost(let session):
                return known(.sessionUsesJumpHost(session: session))
            case .notSSH(let session, let connectionKind):
                return known(.sessionIsNotSSH(session: session, connectionKind: connectionKind))
            case .sessionMissing:
                return known(.sessionMissing)
            }
        case is KeychainError:
            // The status code is dropped: `KeychainError` has no
            // `LocalizedError` conformance, so the generic rendering was
            // "The operation couldn't be completed. (macSCPCore.KeychainError
            // error 1.)" — a case index where the finding is that the
            // Keychain would not answer (BACKLOG, 2026-09-16).
            return known(.keychainUnreadable)
        case let error as SSHKeyError:
            switch error {
            case .fileNotFound(let path):
                // The path is printed on purpose, and it is typically
                // `/Users/<login>/.ssh/id_ed25519`: a local account name in
                // an artifact written to be pasted publicly. Kept because the
                // whole finding is WHICH file is missing, and a login name is
                // not a credential — but kept deliberately, not by accident.
                return known(.keyFileNotFound(path: path))
            case .passphraseRequired:
                return known(.keyPassphraseRequired)
            case .wrongPassphrase:
                return known(.keyPassphraseRejected)
            case .unsupportedFormat:
                // The payload is deliberately dropped. `SSHPrivateKeyLoader`
                // builds it as `String(describing: error)` over Citadel's or
                // CryptoKit's error — out of a call the PASSPHRASE was handed
                // to — and describing an arbitrary error prints its stored
                // properties. That is the rule this function states above,
                // and this arm was the one place that broke it. Nothing a
                // user can act on is lost: the file does not parse.
                return known(.keyUnparsable)
            case .typeNotLoadable(let algorithm):
                return known(.keyTypeNotLoadable(algorithm: algorithm))
            case .pemNotReadable:
                // The payload is dropped, like `unsupportedFormat`'s above,
                // though for the milder reason: it is one of the decoder's
                // own constants, not a foreign error's description. The rule
                // this function states is fixed sentences with no payload,
                // and the connect form is where the feature gets named.
                return known(.keyPEMNotReadable)
            }
        case let error as AgentError:
            switch error {
            case .socketUnavailable:
                return known(.agentUnavailable)
            case .noIdentities:
                return known(.agentHasNoIdentities)
            case .noUsableIdentities:
                return known(.agentHasNoUsableIdentity)
            case .refused:
                return known(.agentRefusedEveryIdentity)
            case .protocolError:
                // Dropped for the same reason, one step weaker: the agent is
                // never handed the passphrase, but `SSHAgentClient` builds
                // this payload as "\(error)" over a NIO error, and "no
                // foreign error's description is printed by this module" is
                // one rule rather than a judgement per error type.
                return known(.agentMisbehaved)
            }
        case let error as RemoteFSError:
            switch error {
            case .connectionFailed:
                // The `reason` is dropped, and it is the whole point of this
                // arm: it is where an ENDPOINT travels. `S3FileSystem` and
                // `WebDAVFileSystem` build it out of the URL they were
                // dialling, and that URL is user input which may carry
                // `KEY:SECRET@`. Nothing a reader can act on is lost — the
                // row already carries the endpoint, the duration and the
                // step that failed.
                return known(.connectionFailed)
            case .authenticationFailed:
                return known(.authenticationFailed)
            case .jumpAuthenticationFailed:
                return (.authenticationFailed, "authentication at the jump host failed")
            case .notFound(let path):
                // Paths are kept: a path is this project's own string, it is
                // what the finding IS, and the browser shows it already.
                return (.unknown, "nothing at \(path)")
            case .permissionDenied(let path):
                return (.unknown, "permission denied at \(path)")
            case .protocolError:
                // Dropped for the same reason as `connectionFailed`: the
                // backends compose this text too, and a server's own message
                // can quote the request line it refused.
                return known(.serverAnswerUnusable)
            case .bucketListForbidden:
                return (.unknown, "the key may not list the account's buckets")
            case .bucketListEmpty:
                return (.unknown, "the account has no buckets")
            case .bucketLevelRefused(let operation, let path):
                // The operation names itself through its `rawValue` — the
                // same derivation `BucketLevelOperation.refusalMessageKey`
                // uses for its catalogue key — rather than through the
                // enum's description, so a renamed case carries this
                // sentence with it.
                return (.unknown, "\(operation.rawValue) is not available at the bucket list (\(path))")
            case .crossBucketRenameRefused:
                // Both paths dropped. They are bucket-qualified paths and
                // the finding is the refusal, not where it pointed; the
                // browser knows what the user asked for.
                return (.unknown, "a rename across buckets is refused")
            }
        default:
            return (.unknown, (error as NSError).localizedDescription)
        }
    }

    /// The step budget as whole seconds, for the connect timeout SSH takes.
    /// Never below one: a sub-second budget rounds to zero, and zero is
    /// "wait forever" to more than one transport.
    static func connectSeconds(_ timeout: Duration) -> Int {
        max(1, Int(timeout.seconds.rounded()))
    }

    /// One request, no credentials, its own ephemeral session.
    ///
    /// Not through `HTTPTransport`: that seam exists so a backend's
    /// request-building can be tested against a fake, and there is nothing to
    /// fake here — the whole point of the step is that a real request reached
    /// a real server. The session is ephemeral and invalidated straight after
    /// for the reason `S3FileSystem.connect` states: `URLSession.shared`
    /// carries a process-wide on-disk cache, and a probe that could be
    /// answered from a cache would not be a probe.
    static func request(
        url: URL, method: String, timeout: Duration, timer: DiagnosticStepTimer,
        detail: @Sendable (HTTPURLResponse) -> String
    ) async -> DiagnosticStep {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = max(1, timeout.seconds)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return timer.finish(.failed("the server answered without an HTTP status"), "")
            }
            return timer.finish(.ok, detail(http))
        } catch {
            return timer.finish(.failed(reason(for: error)), "")
        }
    }
}
