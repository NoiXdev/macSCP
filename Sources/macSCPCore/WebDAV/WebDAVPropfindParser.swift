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
        /// The status of the propstat currently being read. Properties from a
        /// non-2xx propstat are ignored, but the ENTRY survives — Nextcloud
        /// reports 404 for properties it does not carry.
        var currentPropstatIsOK = true
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
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
            case "propstat": current?.currentPropstatIsOK = true
            case "collection": current?.isCollection = true
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
                // absent. The entry itself stays.
                current?.currentPropstatIsOK = value.contains(" 2")
            case "getcontentlength":
                if current?.currentPropstatIsOK == true { current?.contentLength = UInt64(value) }
            case "getlastmodified":
                if current?.currentPropstatIsOK == true {
                    current?.lastModified = httpDate.date(from: value)
                }
            case "response":
                if let entry = current { entries.append(entry) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
