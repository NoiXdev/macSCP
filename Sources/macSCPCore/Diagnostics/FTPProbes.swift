import Foundation

/// The two FTP rows of a diagnosis: the login itself (`DiagnosticContribution
/// .ftpConnect`, the dial) and what the server says it can do
/// (`.ftpFeatures`, the contribution). Both are the same question asked at
/// different depths, so they share the one way a diagnosis opens an FTP
/// connection, here.
///
/// **A diagnosis opens the control connection itself, and does not go through
/// `BackendDescriptor.openConnection`.** The descriptor's path reports a failed
/// dial as `RemoteFSError.connectionFailed(reason:)`, and `DialSupport` drops a
/// `connectionFailed` reason on purpose (it is where an HTTP backend's
/// endpoint travels). For FTP that would turn "the login was refused" and "the
/// TLS upgrade was refused" into the same fixed phrase, and a row whose job is
/// to say which one it was would say neither. Opened here, the failure arrives
/// as the `FTPConnectionFailure` it is, and `DialSupport.reason(for:)` renders
/// that as its own catalogue sentence (Ruling T8.1).
///
/// **Three rules this file keeps, the same three the other probes keep.**
/// The secret is read through `DiagnosticContext.secret()`, the source the
/// connect path uses, never a second copy of it. A certificate nobody has
/// trusted is REFUSED, not asked about: a diagnosis has nobody to ask, and a
/// probe that trusted one would be writing a consent nobody gave (the SSH
/// dial's refusing host-key decider, the WebDAV claims' refusing certificate
/// decider). And no row prints a host, a user name, a reply code or a word the
/// server wrote: the details below are this project's own phrases, chosen by
/// what the server's feature list contained.
///
/// **Plain FTP is not dialled with a password.** The connect flow asks the
/// user before it sends credentials unencrypted (`PlaintextTransportGate`),
/// and a diagnosis cannot ask. Its answer is the same as for the certificate:
/// the rows that need a login are skipped, with a reason that says why, and
/// the rows that need none (resolve, TCP, route) have already run.
enum FTPProbe {
    /// What opening a connection for a row came to.
    enum Opened {
        /// An authenticated, binary-mode control connection, and the config
        /// it was opened from (without its password).
        case connection(FTPControlConnection, FTPConnectionConfig)
        /// The outcome the row reports instead: nothing was dialled, or the
        /// dial failed.
        case unanswered(DiagnosticOutcome)
    }

    /// `trustStore` has no default, for the reason
    /// `FTPControlConnection.connect` gives (Ruling T5.7): `nil` is "remember
    /// nothing", and a caller says so out loud.
    static func open(
        _ values: FieldValues, _ context: DiagnosticContext,
        decider: CertificateDecider, trustStore: TrustedCertificateStore?
    ) async -> Opened {
        // BEFORE the secret is read. A plain-mode login is never sent, so
        // "no credential is saved, save one and run the check again" would be
        // advice about a login this diagnosis will not make, and the keychain
        // would be read (on a locked one, prompted for) for nothing. The mode
        // is read from the values with the function `makeConfig` reads it with.
        if FTPFieldSchema.security(values) == .plain {
            return .unanswered(.skipped(DiagnosticReason.plaintextLogin))
        }
        let secret: String
        switch DialSupport.dialSecret(
            usesAgent: false,
            missing: DialSupport.missingSecretReason(DiagnosticReason.noSecret, secrets: context.secrets),
            context.secret)
        {
        case .secret(let resolved):
            secret = resolved
        case .unanswered(let outcome):
            return .unanswered(outcome)
        }

        var config: FTPConnectionConfig
        do {
            guard case .ftp(let built) = try FTPFieldSchema.makeConfig(values, secret) else {
                return .unanswered(.failed("these values do not describe an FTP connection"))
            }
            config = built
        } catch {
            return .unanswered(.failed(DialSupport.reason(for: error)))
        }
        config.password = ""

        do {
            let connection = try await FTPControlConnection.connect(
                config, password: secret, certificateDecider: decider,
                timeout: .seconds(Int64(DialSupport.connectSeconds(context.timeout))),
                trustStore: trustStore)
            return .connection(connection, config)
        } catch {
            return .unanswered(.failed(DialSupport.reason(for: error)))
        }
    }

    /// The dial row: the login, as far as the connect path takes it.
    static func connectRow(
        _ values: FieldValues, _ context: DiagnosticContext, _ timer: DiagnosticStepTimer,
        decider: CertificateDecider, trustStore: TrustedCertificateStore?
    ) async -> DiagnosticStep {
        switch await open(values, context, decider: decider, trustStore: trustStore) {
        case .unanswered(let outcome):
            return timer.finish(outcome, "")
        case .connection(let connection, let config):
            await connection.close()
            return timer.finish(.ok, connectDetail(config.security))
        }
    }

    /// The contribution row: what the server's `FEAT` list says, and whether
    /// the permission editor would be offered.
    static func featuresRow(
        _ values: FieldValues, _ context: DiagnosticContext, _ timer: DiagnosticStepTimer,
        decider: CertificateDecider, trustStore: TrustedCertificateStore?
    ) async -> DiagnosticStep {
        switch await open(values, context, decider: decider, trustStore: trustStore) {
        case .unanswered(let outcome):
            return timer.finish(outcome, "")
        case .connection(let connection, _):
            let detail = await featureDetail(of: connection)
            await connection.close()
            return timer.finish(.ok, detail)
        }
    }

    /// What a successful login consisted of, per mode. Fixed phrases.
    static func connectDetail(_ security: FTPSecurityMode) -> String {
        switch security {
        case .plain:
            return "greeting, login and binary mode, without TLS"
        case .explicitTLS:
            return "greeting, TLS upgrade, login and binary mode"
        case .implicitTLS:
            return "TLS handshake, greeting, login and binary mode"
        }
    }

    /// The features macSCP acts on, in the order they are reported. Each one
    /// is this project's own phrase for a `FEAT` line the dial read; nothing
    /// the server wrote is copied. The first element of a pair is the line
    /// as `FTPControlConnection.features` keys it.
    ///
    /// `REST STREAM` is the whole line (the resume offset a download asks
    /// for), `SIZE` and `MDTM` are what a listing falls back to for sizes and
    /// times, `MLSD` is the listing the browser prefers, and `EPSV` and
    /// `UTF8` are the data-connection form and the name encoding.
    static let reportedFeatures = ["MLSD", "MDTM", "SIZE", "REST STREAM", "UTF8", "EPSV"]

    static func featureDetail(of connection: FTPControlConnection) async -> String {
        let advertised = await connection.features
        let present = reportedFeatures.filter { advertised.contains($0) }
        let absent = reportedFeatures.filter { !advertised.contains($0) }
        // The same QUESTION the browser asks (`FTPSiteChmodMemory`), asked of
        // this diagnosis's own connection. It is a fresh memory, not the
        // session's, so it is not the same cached ANSWER: a server that
        // answers `SITE HELP` differently twice can make this row and the
        // editor's offer disagree. (Withdrawn wording, verbatim: "Asked of the
        // connection, once, the way the browser asks it (`FTPSiteChmodMemory`):
        // the answer here is the answer the editor's offer will be made from.")
        let offered = await FTPSiteChmodMemory().isAvailable(on: connection)
        var parts: [String] = []
        parts.append("FEAT advertises " + (present.isEmpty ? "none of the features used" : present.joined(separator: ", ")))
        if !absent.isEmpty, !present.isEmpty {
            parts.append("not advertised: " + absent.joined(separator: ", "))
        }
        parts.append("permission editor " + (offered ? "offered" : "not offered (no SITE CHMOD)"))
        return parts.joined(separator: "; ")
    }
}
