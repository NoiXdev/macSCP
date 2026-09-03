import Foundation

/// What the server says it is, as the WebDAV seam contribution measures it
/// (design §3): `OPTIONS` on the session's root for the `DAV:` compliance
/// classes and the `Allow` list, then a `Depth: 0` `PROPFIND` on the same URL
/// for the resource type.
///
/// The two questions are separate on purpose. `OPTIONS` is what the SERVER
/// claims about itself, and `PROPFIND` is what it says about the one
/// collection this session would browse — a server can be a perfectly good
/// DAV server whose configured root is a file, or is not there at all, and a
/// row that asked only the first would call that connection healthy.
///
/// Unlike the WebDAV dial (`DiagnosticContribution.webdavOptions`), which
/// sends an UNAUTHENTICATED `OPTIONS` and reports a 401 as a working server,
/// this one carries the session's credentials: what it reports is what this
/// login sees. That is what a contribution is for.
struct WebDAVClaimsProbe: Sendable {
    /// One measurement, filled in as far as the server let it get.
    ///
    /// Every field is optional and none is inferred from another: a server
    /// that answers `OPTIONS` and then refuses `PROPFIND` has said two things,
    /// and the row prints both.
    struct Claims: Sendable, Equatable {
        var optionsStatus: Int?
        var optionsFailure: String?
        var davClasses: String?
        var allow: String?
        var propfindStatus: Int?
        var propfindFailure: String?
        /// `nil` when the PROPFIND did not answer, or answered with a body
        /// that named no resource — never defaulted to `false`, which would
        /// read as "the root is a file".
        var rootIsCollection: Bool?
    }

    /// What a row says about a call that neither answered nor recorded a
    /// failure. One spelling for the three places that need it, so a
    /// reworded sentence cannot leave two of them disagreeing.
    static let noAnswerReason = "no answer"

    let base: WebDAVURL
    let transport: any HTTPTransport

    /// The one URL both calls address: the collection this session's root
    /// maps to, Nextcloud accommodation included (`WebDAVURL`). Asking about
    /// the bare base URL instead would answer for a collection the session
    /// never browses.
    private var rootURL: URL { base.url(forPath: "/", isDirectory: true) }

    func run() async -> Claims {
        var claims = Claims()

        do {
            let (_, response) = try await transport.send(WebDAVRequest.options(url: rootURL))
            claims.optionsStatus = response.statusCode
            // Absent on a server that answered the request without being a
            // DAV server at all — a finding rather than an error, and the
            // line below says which header was missing.
            claims.davClasses = response.value(forHTTPHeaderField: "DAV")
            claims.allow = response.value(forHTTPHeaderField: "Allow")
        } catch {
            claims.optionsFailure = DialSupport.reason(for: error)
        }

        // The runner's deadline cancels this probe from outside and drops
        // whatever it returns; a second request nobody will read is worth
        // skipping.
        guard !Task.isCancelled else { return claims }

        do {
            let (data, response) = try await transport.send(
                WebDAVRequest.propfind(url: rootURL, depth: "0"))
            claims.propfindStatus = response.statusCode
            // Only a multistatus carries resource types; an error status's
            // body is the server's own error document, and parsing it would
            // report "no resource type" for something that was never asked.
            if response.statusCode == 207 {
                claims.rootIsCollection = try? WebDAVPropfindParser
                    .firstResourceIsCollection(data)
            }
        } catch {
            claims.propfindFailure = DialSupport.reason(for: error)
        }

        return claims
    }

    /// The step's one line.
    ///
    /// ` · ` rather than `; `, because a server's own error sentence can
    /// contain a semicolon and the reader has to see where one answer ends.
    /// Both headers are named even when absent: a gap in a line is something
    /// a reader has to interpret, and "no DAV header" is a measurement.
    static func detail(_ claims: Claims) -> String {
        var parts: [String] = []
        if let status = claims.optionsStatus {
            parts.append("OPTIONS \(status)")
            parts.append(claims.davClasses.map { "DAV: \($0)" } ?? "no DAV header")
            parts.append(claims.allow.map { "Allow: \($0)" } ?? "no Allow header")
        } else {
            parts.append("OPTIONS failed (\(claims.optionsFailure ?? Self.noAnswerReason))")
        }
        if let status = claims.propfindStatus {
            parts.append("PROPFIND \(status)")
            switch claims.rootIsCollection {
            case true?: parts.append("the root is a collection")
            case false?: parts.append("the root is not a collection")
            case nil: break
            }
        } else {
            parts.append("PROPFIND failed (\(claims.propfindFailure ?? Self.noAnswerReason))")
        }
        return parts.joined(separator: " · ")
    }

    /// `ok` when the server ANSWERED either call, whatever it answered — the
    /// rule the dials already follow (`DialProbes`): a 401 or a 403 is a
    /// working server refusing a login, and reporting it as a failed check
    /// would point the user at their network for a question they never asked.
    /// Neither status set means `OPTIONS` did not answer, and `OPTIONS` is
    /// always attempted, so its failure is the one that is set — there is no
    /// path here through which a sentence about name resolution
    /// (`DiagnosticReason.nothingToProbe`) could be true.
    static func outcome(of claims: Claims) -> DiagnosticOutcome {
        guard claims.optionsStatus == nil, claims.propfindStatus == nil else { return .ok }
        return .failed(claims.optionsFailure ?? Self.noAnswerReason)
    }
}
