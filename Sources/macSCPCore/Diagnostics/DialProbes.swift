import Darwin
import Foundation
import NIOCore

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
        let secret: String
        switch DialSupport.dialSecret(
            usesAgent: usesAgent,
            missing: DialSupport.missingSecretReason(DiagnosticReason.noSecret, secrets: context.secrets),
            context.secret)
        {
        case .secret(let resolved):
            secret = resolved
        case .unanswered(let outcome):
            return timer.finish(outcome, "")
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

/// What the dials above do the same way: turn an error into one printable
/// line, look an SSH login's secret up, hand a transport the step's budget,
/// and send one credential-free HTTP request.
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
    /// `switch` with no `default` — re-counted 2026-09-17: SEVEN of them, over
    /// `HostKeyError`, `TunnelFailure`, `TunnelRefusal`, `SSHKeyError`,
    /// `AgentError`, `SFTPStartError` and `RemoteFSError` (four until the
    /// port-forwarding plan's Task 5 added `TunnelFailure`, five until the
    /// technical-backlog plan's Task 6 added `TunnelRefusal`, six until the
    /// next-build plan's Task 1 added `SFTPStartError`) — so a case added to
    /// any of the seven fails to compile here until someone writes its
    /// sentence and names its kind. `KeychainError`, a struct with no cases, is the one arm that
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
    /// stripped the plain shape but not a secret containing a `/`: the
    /// authority scan ended at the slash and the line was copied through
    /// whole (closed 2026-09-19 by the small follow-ups' re-review, O-1; the
    /// filter still documents a hole of its own, whitespace). So each case
    /// gets one fixed sentence instead, and the two free-text payloads are
    /// dropped rather than rendered.
    ///
    /// `TunnelFailure` is spelled out because it conforms to no
    /// `LocalizedError` either, and its generic rendering was measured on
    /// 2026-09-06 as the exact shape the paragraph above describes:
    /// `portInUse(port: 8080)` reached the tunnel's failed state and the
    /// `tunnel … failed reason=` line as "The operation couldn't be
    /// completed. (macSCPCore.TunnelFailure error 0.)" — the port, the one
    /// thing a person can act on, replaced by a case index.
    ///
    /// Its five `reason:` payloads (the four free-text cases and
    /// `remoteBindRefused`) are passed through rather than dropped,
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
    /// became `TunnelRefusal` the same day. Recounted 2026-09-17 with
    /// `remoteBindRefused` added to that alternation: 12, after the port-0
    /// refusal and the unanswered request became payload-free cases of their
    /// own and the refused remote bind became `remoteBindRefused`. Every one
    /// of the 12 passes either this function's own output or a fixed English
    /// sentence written in this repository: SEVEN pass
    /// `DialSupport.reason(for:)` — `SSHForwardingConnection.openDirectTCPIP` and
    /// `remoteBindFailure(for:bind:)`, `LocalForwardListener.acceptFailure`
    /// and `bindFailure`, `RemoteForward.serve`, `startFailure` and
    /// `pairFailure` — and FIVE pass a literal:
    /// `LocalForwardListener`'s "the bound socket reports no port",
    /// `RemoteForward`'s "ended before the server named a port" and its two
    /// "the forward has been stopped", and `TunnelConnection`'s "built a
    /// non-SSH connection" sentence (named here as "port forwarding needs an
    /// SSH session" until 2026-09-16, a sentence `Sources/` at `9167f325`
    /// held only in this comment). The `GatewayPorts` clause a refused
    /// non-loopback remote bind carries is appended by the arm below from
    /// `TunnelFailureKind.gatewayPortsClause`, not by the throw site. A payload
    /// that is already this function's output must
    /// not be re-mapped (that is `LocalForwardListener.acceptFailure`'s own
    /// argument, one layer down), and a payload that is a fixed sentence has
    /// nothing to hide. The payload reaches the log and the command line's
    /// stderr (`TunnelRunner.failureReason`) only — never the state:
    /// `failureKind(for:)` names these five cases by kind (`bindFailed` …
    /// `pumpFailed`, `remoteBindRefused`) and drops the text, because a
    /// payload built by this
    /// function can be a foreign error's `localizedDescription`.
    ///
    /// Everything else — a `URLError`, an NIO or Citadel error — is reduced
    /// to `localizedDescription` and never `String(describing:)`, because
    /// describing an arbitrary error prints its stored properties, and a
    /// transport error is exactly the kind of value that carries the
    /// configuration it was dialling with. NIO's `IOError` is the one
    /// exception, added for the row `docs/BACKLOG.md` records under "A
    /// forwarding's local-bind failure other than EADDRINUSE/
    /// EADDRNOTAVAIL/EACCES still logs a bare errno number, not its name".
    /// The safety argument does NOT rest on what `IOError` holds — it
    /// holds a free-form `failureDescription` too (`NIOCore/IO.swift`,
    /// surfaced through `.description` and the deprecated `.reason`), the
    /// exact shape this function's own rule exists to keep out. It rests
    /// on what `Self.errnoText(for:)` READS: only `ioError.errnoCode`, an
    /// `Int32` with no free text attached, through `strerror` — never
    /// `ioError.description`, never `.localizedDescription`, never
    /// `String(describing:)`.
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
            case .bindAddressUnavailable(let address):
                return known(.bindAddressUnavailable(address: address))
            case .bindPermissionDenied(let port):
                return known(.bindPermissionDenied(port: port))
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
            case .remotePortZeroRefused:
                return known(.remotePortZeroRefused)
            case .remoteBindRefused(let reason, let needsGatewayPorts):
                // The server's reason goes to the log with the clause it has
                // always carried; the kind keeps only whether the clause
                // applies.
                return (
                    .remoteBindRefused(needsGatewayPorts: needsGatewayPorts),
                    reason + (needsGatewayPorts ? TunnelFailureKind.gatewayPortsClause : "")
                )
            case .remoteForwardUnanswered:
                return known(.remoteForwardUnanswered)
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
            case .managedKeyStoreUnreadable:
                return known(.managedKeyStoreUnreadable)
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
        case let error as SFTPStartError:
            // A tab's dial, never a forwarding's — a forwarding does not
            // open SFTP — so the kind is `.unknown`, like every error a
            // forwarding does not produce.
            switch error {
            case .noResponse:
                return (.unknown, "the server did not start the SFTP subsystem")
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
        case let ioError as IOError:
            // The one route left that still reduced to the case-index
            // bridge below: NIO's `IOError` carries only an `errnoCode`
            // and a syscall label ("bind", "listen", …) neither of which
            // conforms to `LocalizedError`, so casting straight to
            // `NSError` (the `default:` arm) produced the same "The
            // operation couldn't be completed. (NIOCore.IOError error
            // 1.)" every other foreign error used to before this switch
            // existed — a case index, not the refusal. `errnoText(for:)`
            // renders the errno itself: `strerror`'s human sentence, plus
            // the C macro name (`Self.errnoNames`) when this table knows
            // it. The kind stays `.unknown`, like every error a forwarding
            // does not itself throw as a typed case — `bindFailure` and
            // `startFailure`/`pairFailure`/`acceptFailure` wrap this
            // sentence into their OWN kind (`bindFailed`,
            // `channelOpenFailed`, `pumpFailed`) at the call site; nothing
            // here decides which.
            return (.unknown, Self.errnoText(for: ioError.errnoCode))
        default:
            return (.unknown, (error as NSError).localizedDescription)
        }
    }

    /// `strerror`'s human text for an errno, with the C macro name appended
    /// in parentheses when `errnoNames` has it — the same "<text>
    /// (<NAME>)" shape `TunnelFailureKind`'s own `bindAddressUnavailable`/
    /// `bindPermissionDenied` sentences already use for `EADDRNOTAVAIL`/
    /// `EACCES`. `strerror` is not thread-safe on the string it returns
    /// (it may be overwritten by the next call on the same thread), but
    /// this function copies it into a Swift `String` before returning, so
    /// nothing here holds the pointer past that copy.
    private static func errnoText(for code: CInt) -> String {
        let text = strerror(code).map { String(cString: $0) } ?? "errno \(code)"
        guard let name = Self.errnoNames[code] else { return text }
        return "\(text) (\(name))"
    }

    /// Every named errno macro `<sys/errno.h>` declares on Darwin, keyed by
    /// value, transcribed from `$(xcrun --sdk macosx --show-sdk-path)
    /// /usr/include/sys/errno.h` — not a hand-picked subset of the ones a
    /// bind syscall happens to be documented as returning, because the
    /// fall-through this feeds is reached from every foreign `IOError` this
    /// module's callers hand `reason(for:)`, not only a local bind's.
    /// `EWOULDBLOCK` (`#define EWOULDBLOCK EAGAIN`) and `ELAST` (`#define
    /// ELAST 107`, the same value as `ENOTCAPABLE`) are left out: each is a
    /// second macro for a value already a key here, and a `Dictionary`
    /// literal with a repeated key is a runtime trap, not a compile error.
    /// `EOPNOTSUPP` keeps its own entry despite `<sys/errno.h>` defining it
    /// twice under `#if`/`#else` (45, same as `ENOTSUP`, or 102): only one
    /// definition is ever compiled in, and on this project's Darwin target
    /// it is 102, distinct from `ENOTSUP`'s 45.
    ///
    /// `internal`, not `private`: `TunnelFailureKindTests` (`@testable
    /// import macSCPCore`) reads this table directly to assert its
    /// coverage is exact — see that suite's
    /// `everyErrnoUpToELASTHasATableEntry` — because `errnoText(for:)`'s
    /// own `guard let … else { return text }` degrades a missing entry
    /// silently rather than failing loud, which is precisely the shape a
    /// scan of the table's own KEYS has to catch instead.
    static let errnoNames: [CInt: String] = [
        EPERM: "EPERM", ENOENT: "ENOENT", ESRCH: "ESRCH", EINTR: "EINTR", EIO: "EIO",
        ENXIO: "ENXIO", E2BIG: "E2BIG", ENOEXEC: "ENOEXEC", EBADF: "EBADF",
        ECHILD: "ECHILD", EDEADLK: "EDEADLK", ENOMEM: "ENOMEM", EACCES: "EACCES",
        EFAULT: "EFAULT", ENOTBLK: "ENOTBLK", EBUSY: "EBUSY", EEXIST: "EEXIST",
        EXDEV: "EXDEV", ENODEV: "ENODEV", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR",
        EINVAL: "EINVAL", ENFILE: "ENFILE", EMFILE: "EMFILE", ENOTTY: "ENOTTY",
        ETXTBSY: "ETXTBSY", EFBIG: "EFBIG", ENOSPC: "ENOSPC", ESPIPE: "ESPIPE",
        EROFS: "EROFS", EMLINK: "EMLINK", EPIPE: "EPIPE", EDOM: "EDOM",
        ERANGE: "ERANGE", EAGAIN: "EAGAIN", EINPROGRESS: "EINPROGRESS",
        EALREADY: "EALREADY", ENOTSOCK: "ENOTSOCK", EDESTADDRREQ: "EDESTADDRREQ",
        EMSGSIZE: "EMSGSIZE", EPROTOTYPE: "EPROTOTYPE", ENOPROTOOPT: "ENOPROTOOPT",
        EPROTONOSUPPORT: "EPROTONOSUPPORT", ESOCKTNOSUPPORT: "ESOCKTNOSUPPORT",
        ENOTSUP: "ENOTSUP", EPFNOSUPPORT: "EPFNOSUPPORT", EAFNOSUPPORT: "EAFNOSUPPORT",
        EADDRINUSE: "EADDRINUSE", EADDRNOTAVAIL: "EADDRNOTAVAIL", ENETDOWN: "ENETDOWN",
        ENETUNREACH: "ENETUNREACH", ENETRESET: "ENETRESET",
        ECONNABORTED: "ECONNABORTED", ECONNRESET: "ECONNRESET", ENOBUFS: "ENOBUFS",
        EISCONN: "EISCONN", ENOTCONN: "ENOTCONN", ESHUTDOWN: "ESHUTDOWN",
        ETOOMANYREFS: "ETOOMANYREFS", ETIMEDOUT: "ETIMEDOUT",
        ECONNREFUSED: "ECONNREFUSED", ELOOP: "ELOOP", ENAMETOOLONG: "ENAMETOOLONG",
        EHOSTDOWN: "EHOSTDOWN", EHOSTUNREACH: "EHOSTUNREACH", ENOTEMPTY: "ENOTEMPTY",
        EPROCLIM: "EPROCLIM", EUSERS: "EUSERS", EDQUOT: "EDQUOT", ESTALE: "ESTALE",
        EREMOTE: "EREMOTE", EBADRPC: "EBADRPC", ERPCMISMATCH: "ERPCMISMATCH",
        EPROGUNAVAIL: "EPROGUNAVAIL", EPROGMISMATCH: "EPROGMISMATCH",
        EPROCUNAVAIL: "EPROCUNAVAIL", ENOLCK: "ENOLCK", ENOSYS: "ENOSYS",
        EFTYPE: "EFTYPE", EAUTH: "EAUTH", ENEEDAUTH: "ENEEDAUTH", EPWROFF: "EPWROFF",
        EDEVERR: "EDEVERR", EOVERFLOW: "EOVERFLOW", EBADEXEC: "EBADEXEC",
        EBADARCH: "EBADARCH", ESHLIBVERS: "ESHLIBVERS", EBADMACHO: "EBADMACHO",
        ECANCELED: "ECANCELED", EIDRM: "EIDRM", ENOMSG: "ENOMSG", EILSEQ: "EILSEQ",
        ENOATTR: "ENOATTR", EBADMSG: "EBADMSG", EMULTIHOP: "EMULTIHOP",
        ENODATA: "ENODATA", ENOLINK: "ENOLINK", ENOSR: "ENOSR", ENOSTR: "ENOSTR",
        EPROTO: "EPROTO", ETIME: "ETIME", EOPNOTSUPP: "EOPNOTSUPP",
        ENOPOLICY: "ENOPOLICY", ENOTRECOVERABLE: "ENOTRECOVERABLE",
        EOWNERDEAD: "EOWNERDEAD", EQFULL: "EQFULL", ENOTCAPABLE: "ENOTCAPABLE",
    ]

    /// What an SSH dial authenticates with, or the outcome its row reports
    /// when there is nothing to authenticate with.
    enum DialSecret {
        /// The secret — empty for agent auth, which carries none.
        case secret(String)
        /// `skipped` when the lookup found nothing, `unavailable` when the
        /// lookup itself failed.
        case unanswered(DiagnosticOutcome)
    }

    /// The one rule every diagnosis dial of an SSH login looks its secret up
    /// by — the session's own dial (`DiagnosticContribution.sshConnect`) and
    /// both logins of a dial through a jump host (`DiagnosticJumpStep`):
    /// agent auth asks nothing, an empty answer is `skipped` with `missing`
    /// as the reason, and a lookup that throws is `unavailable`.
    ///
    /// Deliberately not the source's own error text on that last path: a
    /// failing vault's message is the one place a wrapper could hand back
    /// something it read.
    ///
    /// `missing` is an autoclosure, evaluated only after the lookup answered
    /// nothing, so a reason that depends on what the lookup saw
    /// (`missingSecretReason(_:secrets:)`) reads it after the fact.
    static func dialSecret(
        usesAgent: Bool, missing: @autoclosure () -> String, _ lookup: () throws -> String?
    ) -> DialSecret {
        guard !usesAgent else { return .secret("") }
        do {
            guard let resolved = try lookup(), !resolved.isEmpty else {
                return .unanswered(.skipped(missing()))
            }
            return .secret(resolved)
        } catch {
            return .unanswered(.unavailable(DiagnosticReason.secretSourceFailed))
        }
    }

    /// `missing`, or `DiagnosticReason.managedKeyStoreUnreadable` when the
    /// managed-key link of `secrets` found `managed_keys.json` unreadable for
    /// a key in the managed key directory on its last read — the reason the
    /// lookup came back empty, where there is one to name.
    ///
    /// Read AFTER the lookup: `dialSecret(usesAgent:missing:_:)` takes
    /// `missing` as an autoclosure and evaluates it only once the lookup has
    /// answered nothing, and the link records what it saw during that
    /// lookup. Evaluated first, this would read the record of a previous
    /// diagnosis, or none.
    ///
    /// For the TARGET's lookup only — `DiagnosticContribution.sshConnect`
    /// and `DiagnosticJumpStep.dialViaJump`, two call sites, counted
    /// 2026-09-18. A jump's secret is not looked up through a managed-key
    /// link: `DiagnosticJump.stored` resolves it with `LoginResolver
    /// .preferringManagedKeyPassphrase`, which drops the resolver's
    /// unreadable-store fact (its own comment says why) and hands back only
    /// a secret, so `noJumpSecret` has no fact to name.
    static func missingSecretReason(_ missing: String, secrets: (any SecretSource)?) -> String {
        guard let secrets,
            ManagedKeyPassphraseSecretSource.unreadableStoreHidAKey(in: [secrets])
        else { return missing }
        return DiagnosticReason.managedKeyStoreUnreadable
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
