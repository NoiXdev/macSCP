import Foundation
import Synchronization

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
/// A `Contents` entry's `<ETag>` is returned SEPARATELY, keyed by the same
/// `path` the item carries, rather than as a field on `RemoteFileItem`: an
/// ETag is an object store's own notion and every other backend would carry
/// `nil` for it. `S3FileSystem`'s checksum capability is the one reader, and
/// it interprets the raw text through `FileChecksum.objectStorageETag` —
/// nothing here decides whether an ETag is a file hash.
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
    ) throws -> (items: [RemoteFileItem], continuationToken: String?, eTags: [String: String]) {
        let delegate = ParserDelegate(prefix: prefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw RemoteFSError.protocolError(reason: "Failed to parse S3 ListObjectsV2 response: \(reason)")
        }
        return (delegate.items, delegate.continuationToken, delegate.eTags)
    }

    /// Whether a `ListObjectsV2` response matched ANYTHING at all under its
    /// query prefix — used only by `S3FileSystem`'s cheap delete lookup,
    /// which asks a different question than `parse` does.
    ///
    /// `parse` drops a `Contents` entry whose `Key` equals the query prefix
    /// exactly, because in every OTHER caller that entry is the directory
    /// being listed, not something inside it. The delete lookup queries
    /// `<key>/` to ask "is this key a directory", and an empty directory's
    /// own folder-marker object (`createDirectory`'s zero-byte `<key>/`) IS
    /// that excluded entry — so reusing `parse` and checking `items.isEmpty`
    /// would call an empty directory absent. This checks presence only, with
    /// no such exclusion: `<Contents>` or `<CommonPrefixes>` anywhere in the
    /// response, marker included, means something is there.
    public static func hasAnyEntries(_ data: Data) throws -> Bool {
        let delegate = PresenceParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw RemoteFSError.protocolError(reason: "Failed to parse S3 ListObjectsV2 response: \(reason)")
        }
        return delegate.foundAny
    }

    /// Parses a `ListBuckets` (`ListAllMyBucketsResult`) response into one
    /// row per bucket (2026-09-02, design §4).
    ///
    /// A bucket is a second kind of directory: it carries a name and a
    /// creation date and nothing else — no size, no permissions, no owner —
    /// so the `RemoteFileItem` it becomes leaves all of those `nil` and puts
    /// the creation date in `modifiedAt`, which is the only date the bucket
    /// level has. Its `path` is `"/<name>"`: the path that opens it, and the
    /// one `S3FileSystem.RootMode.resolve` splits back into a bucket.
    ///
    /// The `<Name>` guard is on `Bucket` as the parent element, not on the
    /// element name alone: the same response carries an `<Owner>` whose
    /// `<DisplayName>`/`<ID>` sit at the same depth, and a real MinIO
    /// answer has one.
    public static func parseBuckets(_ data: Data) throws -> [RemoteFileItem] {
        let delegate = BucketsParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 ListBuckets response: \(reason)")
        }
        return delegate.items
    }

    /// ISO8601 with fractional seconds (`2024-01-02T03:04:05.000Z`, the
    /// usual `LastModified` shape) — falls back to the plain form without
    /// fractional seconds for servers that omit them.
    ///
    /// Shared instances behind a `Mutex`, not one formatter per call:
    /// `parseDate` runs in the `XMLParser` delegate once per `<LastModified>`,
    /// and a single `ListObjectsV2` page carries up to 1000 objects — each of
    /// which may consult both formatters when the fallback is taken.
    /// An `ISO8601DateFormatter` is expensive to construct and cheap to
    /// reuse, so building one per date — thousands per listing page — would
    /// be a change in timing behaviour, not a refactor.
    ///
    /// `Mutex` rather than a suppression: `ISO8601DateFormatter` is not
    /// thread-safe for concurrent use, and `withLock` is the only route to
    /// the instance — so this is a guarantee the compiler checks.
    private static let dateFormatterWithFractionalSeconds = Mutex<ISO8601DateFormatter>({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }())

    private static let dateFormatter = Mutex<ISO8601DateFormatter>({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    /// The fallback order is preserved exactly: the fractional-seconds
    /// formatter is asked first, and the plain one only when it returned
    /// `nil`. Two separate `withLock` calls, never nested — the second is
    /// only entered after the first has released.
    fileprivate static func parseDate(_ string: String) -> Date? {
        dateFormatterWithFractionalSeconds.withLock { $0.date(from: string) }
            ?? dateFormatter.withLock { $0.date(from: string) }
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

    /// `ListAllMyBucketsResult` -> one directory row per `<Bucket>`.
    private final class BucketsParserDelegate: NSObject, XMLParserDelegate {
        private(set) var items: [RemoteFileItem] = []

        private var elementStack: [String] = []
        private var currentText = ""
        private var currentName: String?
        private var currentCreationDate: Date?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            currentText = ""
            if elementName == "Bucket" {
                currentName = nil
                currentCreationDate = nil
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
            case "Name" where parent == "Bucket":
                currentName = trimmed
            case "CreationDate" where parent == "Bucket":
                currentCreationDate = S3ListParser.parseDate(trimmed)
            case "Bucket":
                if let name = currentName, !name.isEmpty {
                    items.append(RemoteFileItem(
                        name: name, path: "/" + name, kind: .directory,
                        size: nil, modifiedAt: currentCreationDate, isBucket: true))
                }
            default:
                break
            }

            elementStack.removeLast()
            currentText = ""
        }
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let prefix: String
        private(set) var items: [RemoteFileItem] = []
        private(set) var continuationToken: String?
        /// The raw `<ETag>` text of each file entry, by the item's `path`.
        /// Absent for an entry whose listing carried no ETag at all.
        private(set) var eTags: [String: String] = [:]

        private var elementStack: [String] = []
        private var currentText = ""
        private var isTruncated = false

        private var currentKey: String?
        private var currentSize: UInt64?
        private var currentETag: String?
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
                currentETag = nil
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
            case "ETag" where parent == "Contents":
                currentETag = trimmed
            case "Prefix" where parent == "CommonPrefixes":
                currentPrefixEntry = trimmed
            case "IsTruncated":
                isTruncated = trimmed.lowercased() == "true"
            case "NextContinuationToken":
                continuationToken = trimmed
            case "Contents":
                if let key = currentKey, key != prefix {
                    let name = S3ListParser.leafName(key: key, prefix: prefix)
                    let path = "/" + key
                    items.append(RemoteFileItem(
                        name: name, path: path, kind: .file,
                        size: currentSize, modifiedAt: currentModifiedAt))
                    if let currentETag, !currentETag.isEmpty { eTags[path] = currentETag }
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

    /// Backs `hasAnyEntries`: sets a flag the moment either element starts,
    /// with no leaf-name computation and no exclusion of the entry that
    /// equals the query prefix.
    private final class PresenceParserDelegate: NSObject, XMLParserDelegate {
        private(set) var foundAny = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "Contents" || elementName == "CommonPrefixes" {
                foundAny = true
            }
        }
    }
}
