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
enum DialSupport {
    /// A short, technical reason for a step's `failed` outcome.
    ///
    /// The three typed SSH errors are spelled out because none of them
    /// conforms to `LocalizedError`: bridged to `NSError` they all read "The
    /// operation couldn't be completed. (macSCPCore.HostKeyError error N.)"
    /// — `N` being the case index, whatever it is — which says nothing about
    /// host keys — in the row this file documents
    /// as the answer to "why does this not connect", and for the four
    /// commonest SSH dial failures. The arms are exhaustive `switch`es, so a
    /// case added to any of the three enums fails to compile here until
    /// someone writes its sentence.
    ///
    /// `RemoteFSError` is described rather than spelled: every one of its
    /// cases carries strings this project wrote (paths, mapped connect
    /// reasons), so its raw description is already readable and already
    /// credential-free.
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
    static func reason(for error: any Error) -> String {
        switch error {
        case let error as HostKeyError:
            switch error {
            case .mismatch(let host, let expected, let presented):
                return "host key MISMATCH for \(host): expected \(expected), got \(presented)"
            case .rejectedByUser:
                return "the host key is not known to this app and was not accepted"
            }
        case let error as SSHKeyError:
            switch error {
            case .fileNotFound(let path):
                // The path is printed on purpose, and it is typically
                // `/Users/<login>/.ssh/id_ed25519`: a local account name in
                // an artifact written to be pasted publicly. Kept because the
                // whole finding is WHICH file is missing, and a login name is
                // not a credential — but kept deliberately, not by accident.
                return "no key file at \(path)"
            case .passphraseRequired:
                return "the key is encrypted and no passphrase was available"
            case .wrongPassphrase:
                return "the key's passphrase was rejected"
            case .unsupportedFormat:
                // The payload is deliberately dropped. `SSHPrivateKeyLoader`
                // builds it as `String(describing: error)` over Citadel's or
                // CryptoKit's error — out of a call the PASSPHRASE was handed
                // to — and describing an arbitrary error prints its stored
                // properties. That is the rule this function states above,
                // and this arm was the one place that broke it. Nothing a
                // user can act on is lost: the file does not parse.
                return "the key file could not be parsed"
            case .typeNotLoadable(let algorithm):
                return "this app cannot load a key of type \(algorithm)"
            case .pemNotSupported:
                return "the key is in PEM format, which this app does not read"
            }
        case let error as AgentError:
            switch error {
            case .socketUnavailable:
                return "no ssh-agent answered on SSH_AUTH_SOCK"
            case .noIdentities:
                return "the ssh-agent holds no identities"
            case .noUsableIdentities:
                return "the ssh-agent holds no identity of a type this app can offer"
            case .refused:
                return "the ssh-agent refused every identity it offered"
            case .protocolError:
                // Dropped for the same reason, one step weaker: the agent is
                // never handed the passphrase, but `SSHAgentClient` builds
                // this payload as "\(error)" over a NIO error, and "no
                // foreign error's description is printed by this module" is
                // one rule rather than a judgement per error type.
                return "the ssh-agent connection misbehaved"
            }
        case let error as RemoteFSError:
            return String(describing: error)
        default:
            return (error as NSError).localizedDescription
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
