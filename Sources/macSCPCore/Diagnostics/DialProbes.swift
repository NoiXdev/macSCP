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
                    return timer.finish(.skipped("no secret available for this session"), "")
                }
                secret = resolved
            } catch {
                // Deliberately not the source's own error text: a failing
                // vault's message is the one place a wrapper could hand back
                // something it read.
                return timer.finish(.unavailable("the secret source failed"), "")
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
            return timer.finish(.skipped("this session names no endpoint"), "")
        }
        return await DialSupport.request(
            url: url, method: "HEAD", timeout: context.timeout, timer: timer
        ) { response in
            "HTTP \(response.statusCode) to an unsigned HEAD on \(url.absoluteString)"
        }
    }

    /// WebDAV: an unauthenticated `OPTIONS` on the base URL.
    static let webdavOptions = DiagnosticContribution.measured(
        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.webdavOptions"
    ) { values, context, timer in
        guard let url = WebDAVFieldSchema.baseURL(values) else {
            return timer.finish(.skipped("this session names no server URL"), "")
        }
        return await DialSupport.request(
            url: url, method: "OPTIONS", timeout: context.timeout, timer: timer
        ) { response in
            var detail = "HTTP \(response.statusCode) to an unauthenticated OPTIONS"
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
    /// `RemoteFSError` is described directly: every one of its cases carries
    /// strings this project wrote (paths, mapped connect reasons), never a
    /// credential — `ConnectFailureSecrecyTests` is what holds the mapping to
    /// that. Anything else — a `URLError`, an NIO or Citadel error — is
    /// reduced to `localizedDescription` rather than `String(describing:)`,
    /// because describing an arbitrary error prints its stored properties,
    /// and a transport error is exactly the kind of value that carries the
    /// configuration it was dialling with.
    static func reason(for error: any Error) -> String {
        if let remote = error as? RemoteFSError { return String(describing: remote) }
        return (error as NSError).localizedDescription
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
