import Foundation

/// Parses an S3 `ListObjectsV2` (`ListBucketResult`) XML response into
/// `RemoteFileItem`s (M12/T5). Uses Foundation's `XMLParser` — no new
/// dependency.
///
/// The request that produced `data` MUST have used `delimiter=/`, so the
/// server has already grouped everything past the next `/` into
/// `CommonPrefixes` — this parser does no grouping of its own, it only maps
/// what the server already partitioned:
/// - `<Contents>` → a `.file` item (owner/group/permissions stay nil — S3
///   has no POSIX metadata).
/// - `<CommonPrefixes><Prefix>` → a `.directory` item.
///
/// `prefix` is the same query `prefix` the request was made with (e.g. `""`
/// for the bucket root, or `"sub/"` when listing under `sub`) — it is
/// stripped off each `Key`/`Prefix` to produce the leaf `name`. A `Contents`
/// entry whose `Key` equals `prefix` itself (the zero-byte "folder marker"
/// object some tools create) is skipped: it is the directory being listed,
/// not an entry inside it.
public enum S3ListParser {
    public static func parse(
        _ data: Data, prefix: String
    ) throws -> (items: [RemoteFileItem], continuationToken: String?) {
        let delegate = ParserDelegate(prefix: prefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw RemoteFSError.protocolError(reason: "Failed to parse S3 ListObjectsV2 response: \(reason)")
        }
        return (delegate.items, delegate.continuationToken)
    }

    /// ISO8601 with fractional seconds (`2024-01-02T03:04:05.000Z`, the
    /// usual `LastModified` shape) — falls back to the plain form without
    /// fractional seconds for servers that omit them.
    private static let dateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    fileprivate static func parseDate(_ string: String) -> Date? {
        dateFormatterWithFractionalSeconds.date(from: string) ?? dateFormatter.date(from: string)
    }

    /// Strips the query `prefix` off a `Key`/`Prefix` value to produce a
    /// leaf name, and (for directories) drops the trailing slash.
    fileprivate static func leafName(key: String, prefix: String) -> String {
        var leaf = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        if leaf.hasSuffix("/") {
            leaf = String(leaf.dropLast())
        }
        return leaf
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let prefix: String
        private(set) var items: [RemoteFileItem] = []
        private(set) var continuationToken: String?

        private var elementStack: [String] = []
        private var currentText = ""
        private var isTruncated = false

        private var currentKey: String?
        private var currentSize: UInt64?
        private var currentModifiedAt: Date?
        private var currentPrefixEntry: String?

        init(prefix: String) {
            self.prefix = prefix
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            currentText = ""
            switch elementName {
            case "Contents":
                currentKey = nil
                currentSize = nil
                currentModifiedAt = nil
            case "CommonPrefixes":
                currentPrefixEntry = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : nil

            switch elementName {
            case "Key" where parent == "Contents":
                currentKey = trimmed
            case "Size" where parent == "Contents":
                currentSize = UInt64(trimmed)
            case "LastModified" where parent == "Contents":
                currentModifiedAt = S3ListParser.parseDate(trimmed)
            case "Prefix" where parent == "CommonPrefixes":
                currentPrefixEntry = trimmed
            case "IsTruncated":
                isTruncated = trimmed.lowercased() == "true"
            case "NextContinuationToken":
                continuationToken = trimmed
            case "Contents":
                if let key = currentKey, key != prefix {
                    let name = S3ListParser.leafName(key: key, prefix: prefix)
                    items.append(RemoteFileItem(
                        name: name, path: "/" + key, kind: .file,
                        size: currentSize, modifiedAt: currentModifiedAt))
                }
            case "CommonPrefixes":
                if let prefixEntry = currentPrefixEntry, prefixEntry != prefix {
                    let name = S3ListParser.leafName(key: prefixEntry, prefix: prefix)
                    let path = "/" + (prefixEntry.hasSuffix("/") ? String(prefixEntry.dropLast()) : prefixEntry)
                    items.append(RemoteFileItem(name: name, path: path, kind: .directory))
                }
            default:
                break
            }

            elementStack.removeLast()
            currentText = ""
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if !isTruncated {
                continuationToken = nil
            }
        }
    }
}
