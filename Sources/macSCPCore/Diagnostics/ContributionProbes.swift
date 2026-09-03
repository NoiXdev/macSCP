import Foundation

/// The first two entries of the per-protocol seam (design §3): the S3 key's
/// access level and the WebDAV server's claims.
///
/// The difference from the dials in `DialProbes` is authentication. A dial
/// asks "is anything there", and answers it without a credential wherever the
/// backend allows; a contribution asks the protocol's OWN question, with the
/// session's credentials, resolved through `DiagnosticContext.secret()` — the
/// same source the connect path uses, never a second copy of a secret.
///
/// Neither of them prints a URL. The dials render their target through
/// `URLText.hostPortPath(of:)` because they have one to name; these two are
/// about what the server said, and the endpoint is already on the row above.
/// The rule they do share: no probe interpolates a raw endpoint string into a
/// message (`URLText`'s own doc comment states why the redaction backstop is
/// not the defence).
///
/// SSH contributes nothing here yet. Its question — the negotiated KEX, the
/// host-key type, the cipher, which auth method succeeded — needs an observer
/// inside NIOSSH that the fork does not expose yet, and a row that guessed at
/// it would be inventing the one thing the user came to check. It is in the
/// backlog, not in this file.
extension DiagnosticContribution {
    /// S3: what this key may do here — `HeadBucket`, `ListObjectsV2` with
    /// `MaxKeys=1`, `ListBuckets`, each with its status and the server's
    /// `x-amz-request-id`.
    static let s3AccessLevel = DiagnosticContribution.measured(
        id: "s3.access", titleKey: "diagnostics.contribution.s3Access"
    ) { values, context, timer in
        let secret: String
        do {
            guard let resolved = try context.secret(), !resolved.isEmpty else {
                return timer.finish(.skipped(DiagnosticReason.noSecret), "")
            }
            secret = resolved
        } catch {
            // Deliberately not the source's own error text, for the reason
            // `DiagnosticContribution.sshConnect` gives: a failing vault's
            // message is the one place a wrapper could hand back something it
            // read.
            return timer.finish(.unavailable(DiagnosticReason.secretSourceFailed), "")
        }
        let config: S3ConnectionConfig
        do {
            guard case .s3(let s3) = try S3FieldSchema.makeConfig(values, secret) else {
                return timer.finish(.failed("these values do not describe an S3 connection"), "")
            }
            config = s3
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }

        // Its own ephemeral session, invalidated straight after, for the
        // reason `S3FileSystem.connect` states: a probe that could be answered
        // from `URLSession.shared`'s process-wide on-disk cache would not be a
        // probe. The redirect delegate comes with it, so a redirect inside the
        // endpoint's origin is re-signed and one that leaves it is refused —
        // the same policy the real dial has.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(1, context.timeout.seconds)
        let redirects = S3RedirectSessionDelegate(config: config)
        let session = URLSession(
            configuration: configuration, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let results = await S3AccessProbe(
            config: config, transport: URLSessionHTTPTransport(session: session)
        ).run()
        return timer.finish(S3AccessProbe.outcome(of: results), S3AccessProbe.detail(results))
    }

    /// WebDAV: what the server claims to be — the `DAV:` compliance classes
    /// and `Allow` list from an AUTHENTICATED `OPTIONS`, and the resource type
    /// of the session's own root from a `Depth: 0` `PROPFIND`.
    static let webdavClaims = DiagnosticContribution.measured(
        id: "webdav.claims", titleKey: "diagnostics.contribution.webdavClaims"
    ) { values, context, timer in
        let secret: String
        do {
            guard let resolved = try context.secret(), !resolved.isEmpty else {
                return timer.finish(.skipped(DiagnosticReason.noSecret), "")
            }
            secret = resolved
        } catch {
            return timer.finish(.unavailable(DiagnosticReason.secretSourceFailed), "")
        }
        let config: WebDAVConnectionConfig
        do {
            guard case .webdav(let webdav) = try WebDAVFieldSchema.makeConfig(values, secret)
            else {
                return timer.finish(
                    .failed("these values do not describe a WebDAV connection"), "")
            }
            config = webdav
        } catch {
            return timer.finish(.failed(DialSupport.reason(for: error)), "")
        }
        guard let url = URL(string: config.baseURL), url.scheme != nil, url.host() != nil else {
            return timer.finish(.skipped(DiagnosticReason.noServerURL), "")
        }

        // The credentials travel the way they do on the real connect: through
        // `WebDAVSessionDelegate`, which answers the server's Basic or Digest
        // challenge and decides what to do about a TLS certificate. The
        // certificate decider is `.refusing` for the same reason the SSH dial
        // uses a refusing host-key decider — a diagnosis has nobody to ask,
        // and a probe that trusted an unknown certificate would be writing a
        // consent nobody gave. An already-trusted certificate is in the store
        // and dials through.
        let delegate = WebDAVSessionDelegate(
            baseURL: url, username: config.username, password: config.password,
            trustStore: TrustedCertificateStore(directory: SessionStore.defaultDirectory),
            decider: .refusing)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(1, context.timeout.seconds)
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let claims = await WebDAVClaimsProbe(
            base: WebDAVURL(
                baseURL: url, nextcloudUser: config.useNextcloudPath ? config.username : nil),
            transport: URLSessionHTTPTransport(session: session)
        ).run()
        return timer.finish(
            WebDAVClaimsProbe.outcome(of: claims), WebDAVClaimsProbe.detail(claims))
    }
}
