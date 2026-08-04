import Foundation

/// Turns a `multistatus` PROPFIND body into browser entries.
///
/// Deliberately lenient about namespaces and unknown elements: it keys on the
/// LOCAL element name (`href`, `collection`, `getcontentlength`, …) and
/// ignores everything it does not recognise. Nextcloud answers with `oc:` and
/// `nc:` properties interleaved with the DAV: ones, and a parser that keys on
/// qualified names or rejects unknown children drops every entry it sees.
///
/// The requested collection itself is excluded from the result — a `Depth: 1`
/// PROPFIND reports it as the first response, and the browser must not list a
/// directory inside itself.
public enum WebDAVPropfindParser {
    public static func parse(
        _ data: Data, base: WebDAVURL, requestedPath: String
    ) throws -> [RemoteFileItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw RemoteFSError.protocolError(
                reason: "WebDAV PROPFIND response is not valid XML")
        }

        var items: [RemoteFileItem] = []
        for entry in delegate.entries {
            guard let href = entry.href,
                  let url = URL(string: href, relativeTo: base.url(forPath: "/", isDirectory: true)),
                  let path = base.path(forURL: url.absoluteURL),
                  path != normalized(requestedPath)
            else { continue }
            let name = path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
            items.append(RemoteFileItem(
                name: name,
                path: path,
                kind: entry.isCollection ? .directory : .file,
                size: entry.isCollection ? nil : entry.contentLength,
                modifiedAt: entry.lastModified))
        }
        return items
    }

    private static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }

    private struct Entry {
        var href: String?
        var isCollection = false
        var contentLength: UInt64?
        var lastModified: Date?
    }

    /// Properties parsed from the propstat currently being read, held back
    /// until `</propstat>` closes and its status is therefore known.
    /// Properties from a non-2xx propstat are discarded, but the ENTRY
    /// survives — Nextcloud reports 404 for properties it does not carry.
    ///
    /// `<prop>` and `<status>` are buffered rather than applied straight to
    /// the entry because their document order is the server's choice: RFC
    /// 4918's own examples (and every real server) put `<prop>` before
    /// `<status>`, but nothing in the spec forbids the reverse. Applying
    /// properties directly to the entry as they are read would make the gate
    /// depend on `<status>` having already been seen — true only for one of
    /// the two orders.
    private struct PendingPropstat {
        var isCollection = false
        var contentLength: UInt64?
        var lastModified: Date?
        var statusIsOK = true
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var pending = PendingPropstat()
        private var text = ""

        /// RFC 1123, the format `getlastmodified` is specified to use.
        private let httpDate: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            text = ""
            switch elementName {
            case "response": current = Entry()
            case "propstat": pending = PendingPropstat()
            case "collection": pending.isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "href":
                if current?.href == nil { current?.href = value }
            case "status":
                // "HTTP/1.1 404 Not Found" -> properties in THIS propstat are
                // absent. The entry itself stays. Buffered, not applied yet:
                // <prop> may still be read after this if the server emits
                // <status> first.
                pending.statusIsOK = Self.isSuccessStatus(value)
            case "getcontentlength":
                pending.contentLength = UInt64(value)
            case "getlastmodified":
                pending.lastModified = httpDate.date(from: value)
            case "propstat":
                if pending.statusIsOK {
                    if pending.isCollection { current?.isCollection = true }
                    if let length = pending.contentLength { current?.contentLength = length }
                    if let modified = pending.lastModified { current?.lastModified = modified }
                }
            case "response":
                if let entry = current { entries.append(entry) }
                current = nil
            default: break
            }
            text = ""
        }

        /// Parses the 3-digit status code out of a status line such as
        /// "HTTP/1.1 200 OK" and reports whether it is in the 2xx range.
        /// A status line that cannot be parsed is treated as non-OK.
        private static func isSuccessStatus(_ statusLine: String) -> Bool {
            let components = statusLine.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 2, let code = Int(components[1]) else { return false }
            return (200...299).contains(code)
        }
    }
}
