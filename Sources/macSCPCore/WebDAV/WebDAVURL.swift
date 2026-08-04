import Foundation

/// Maps between browser paths (`/sub/a.txt`, always absolute and
/// single-slash-normalised, as the rest of the app uses them) and absolute
/// WebDAV URLs.
///
/// Its own type, and its own test file, because this is where the silent bugs
/// live: a space that breaks the request, a `+` a server reads back as a
/// space, a `#` that truncates at the fragment, a doubled slash at the root.
/// All of it is pure computation, so all of it is provable without a server.
public struct WebDAVURL: Sendable, Equatable {
    /// Everything below this URL belongs to the session. Stored with a
    /// trailing slash so appending never has to test for one.
    private let root: URL

    /// - Parameter nextcloudUser: when non-nil, `/remote.php/dav/files/<user>/`
    ///   is appended to `baseURL`. This is the one Nextcloud accommodation the
    ///   spec allows; every other server takes `baseURL` as it stands.
    public init(baseURL: URL, nextcloudUser: String?) {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if let user = nextcloudUser, !user.isEmpty {
            text += "/remote.php/dav/files/" + Self.encode(user)
        }
        self.root = URL(string: text + "/") ?? baseURL
    }

    /// Percent-encodes a single path segment.
    ///
    /// `urlPathAllowed` is deliberately NOT used: it permits `+`, `#`, `?` and
    /// `/` inside a segment, and each of those changes the request's meaning
    /// (`+` read as a space, `#` truncating at the fragment, `/` inventing a
    /// directory level). The allowed set here is the unreserved set from
    /// RFC 3986 plus the sub-delims a file name may plausibly carry.
    private static func encode(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*,;=:@")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Absolute URL for a browser path. Collections carry exactly one
    /// trailing slash — several servers answer a PROPFIND on a collection
    /// without one with a 301 to the slashed form.
    public func url(forPath path: String, isDirectory: Bool) -> URL {
        let segments = path.split(separator: "/").map { Self.encode(String($0)) }
        var text = root.absoluteString
        text += segments.joined(separator: "/")
        if isDirectory, !text.hasSuffix("/") { text += "/" }
        if !isDirectory, text.hasSuffix("/"), !segments.isEmpty { text.removeLast() }
        return URL(string: text) ?? root
    }

    /// The reverse: an href from a PROPFIND response back to a browser path.
    /// Returns nil when the URL is not below the session root — reporting it
    /// as a path would invent an entry navigation cannot reach.
    public func path(forURL url: URL) -> String? {
        let rootPath = root.path(percentEncoded: false)
        let candidate = url.path(percentEncoded: false)
        guard candidate.hasPrefix(rootPath) else { return nil }
        var relative = String(candidate.dropFirst(rootPath.count))
        while relative.hasSuffix("/") { relative.removeLast() }
        return relative.isEmpty ? "/" : "/" + relative
    }
}
