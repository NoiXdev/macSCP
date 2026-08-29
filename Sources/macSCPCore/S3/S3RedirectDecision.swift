import Foundation

/// What the S3 dial does when its endpoint answers with a redirect.
///
/// The whole rule is a function of two URLs, so it is a value that can be
/// asked in a test — the same shape `SessionNameCollision` and
/// `SidebarOrdering` have, and for the same reason: a rule written inside a
/// `URLSessionTaskDelegate` method is reachable only through a real
/// session, and only for the redirects a stub can be made to produce.
/// `S3RedirectSessionDelegate` asks this and carries out the answer; it
/// decides nothing itself.
///
/// **Why a redirect needs deciding at all.** Measured 2026-08-28 over ten
/// cases: Foundation strips the hand-set `Authorization` on EVERY redirect,
/// same origin or not, but carries `x-amz-date`, `x-amz-content-sha256` and
/// the hand-set `Host` — and follows the redirect. So a foreign origin
/// learned the bucket path, the list query, the timestamps and, through the
/// stale `Host`, the configured endpoint; and a legitimate provider
/// redirect arrived unsigned and failed. One rule answers both.
public enum S3RedirectDecision: Equatable, Sendable {
    /// The target is the endpoint's own origin. The request is rebuilt and
    /// signed for the new target, then followed — which is also what fixes
    /// the functional half, since Foundation's own proposal arrives naked.
    case reSignAndFollow

    /// The target is somewhere else. Nothing is sent there.
    ///
    /// The two origins travel with the decision, as text, because the
    /// message that reports this is the point of refusing loudly: a user
    /// who is only told "connection failed" cannot tell that their endpoint
    /// tried to send them elsewhere, and that is the fact worth having.
    case refuse(from: String, to: String)

    /// The catalog key for the refusal sentence — two origins, configured
    /// first. Read by the test that checks it resolves rather than spelled
    /// there a second time.
    public static let refusalMessageKey = "core.s3.redirectRefused %@ %@"

    /// The sentence a refusal reports, or `nil` for a decision that refuses
    /// nothing.
    public var refusalMessage: String? {
        guard case .refuse(let from, let to) = self else { return nil }
        return String(format: CoreL10n.string(Self.refusalMessageKey), from, to)
    }

    /// Same origin — scheme, host and port, RFC 6454, with no discretion.
    ///
    /// So `https` → `http` on the same host is FOREIGN, which is the case
    /// this definition is chosen for: a redirect that takes the encryption
    /// away is the one least worth following. A port change is foreign too.
    ///
    /// Fails closed on anything it cannot read as an origin — a target with
    /// no host, or a scheme that is neither `http` nor `https`. There is no
    /// default port to fill in for an unknown scheme, and inventing one
    /// would be inventing a match.
    public static func decide(from current: URL, to target: URL) -> S3RedirectDecision {
        if let here = Origin(current), let there = Origin(target), here == there {
            return .reSignAndFollow
        }
        return .refuse(from: describe(current), to: describe(target))
    }

    /// `scheme://host:port`, with the port always spelled out even when it
    /// is the scheme's default — two origins that differ only in scheme
    /// would otherwise print the same name twice, which is exactly the
    /// downgrade case.
    ///
    /// Deliberately origin only: no path, no query. The endpoint chose this
    /// text by writing a `Location` header, and what a reader needs from it
    /// is which server, not which object. `WebDAVSessionDelegate` names a
    /// foreign challenge the same way and for the same reason.
    private static func describe(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "?"
        let host = url.host()?.lowercased() ?? "?"
        let port = url.port ?? Origin.defaultPort(forScheme: scheme)
        return "\(scheme)://\(host):\(port.map(String.init) ?? "?")"
    }

    /// Scheme, host and port together. Not public: it is the comparison
    /// `decide` makes, not a thing a caller has business building.
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        /// `nil` when the URL is not one this rule can judge — see
        /// `decide`, which turns that into a refusal.
        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host()?.lowercased(), !host.isEmpty,
                  let defaultPort = Self.defaultPort(forScheme: scheme)
            else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? defaultPort
        }

        static func defaultPort(forScheme scheme: String) -> Int? {
            switch scheme {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
    }
}
