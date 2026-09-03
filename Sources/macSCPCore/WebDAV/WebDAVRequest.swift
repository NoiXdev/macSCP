import Foundation

/// The WebDAV requests this app sends, built in one place.
///
/// `PROPFIND` in particular has a BODY, and that body is a promise: it names
/// exactly the three properties `WebDAVPropfindParser` reads. A second copy
/// of it — one in the file system, one in a probe — is a second promise that
/// can drift from the parser without anything failing, which is why the two
/// callers share this one.
enum WebDAVRequest {
    /// An explicit prop set rather than `allprop`: `allprop` invites servers
    /// to return large, irrelevant property sets (Nextcloud especially).
    static let propfindBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
          <d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
        </d:prop></d:propfind>
        """.utf8)

    static func propfind(url: URL, depth: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = propfindBody
        return request
    }

    /// `OPTIONS`, which carries no body and asks for nothing but the
    /// server's own headers — the `DAV:` compliance classes and `Allow`.
    static func options(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        return request
    }
}
