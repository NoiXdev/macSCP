import Foundation

/// Reads a `ListObjectVersions` answer (`ListVersionsResult`) into the types
/// `ObjectVersionProvider` speaks, and encodes the continuation markers for
/// the next request. Foundation's `XMLParser`, no new dependency — the same
/// approach as `S3SettingsXML`.
///
/// **This type reports what arrived.** It does not filter: `prefix=doc.txt`
/// also matches `doc.txt.bak` at the store, and keeping only the exact key is
/// the caller's job, not the parser's.
enum S3VersionsXML {
    /// Reads one page of a version listing.
    ///
    /// - A 2xx is the document; any other status goes through
    ///   `S3FileSystem.mapErrorStatus`, so a named refusal keeps its finding
    ///   (a store that does not implement the call answers `NotImplemented`,
    ///   which is `.finding(.operationNotSupported)` and not an
    ///   authentication failure). There is no "not configured" answer to
    ///   forgive here, unlike `S3SettingsXML.parseObjectLockState`. `path` is
    ///   `""`: the signature names none, and it is only what a `.notFound`
    ///   would carry.
    /// - `Version` and `DeleteMarker` children of the root become
    ///   `ObjectVersion`s in document order. A delete marker has `size` and
    ///   `entityTag` of `nil` whatever its element holds.
    /// - `NextKeyMarker` and `NextVersionIdMarker` are the continuation. The
    ///   `KeyMarker` and `VersionIdMarker` beside them are the REQUEST's echo
    ///   and are not read. Both are kept exactly as written: they are opaque
    ///   tokens (spec §4.9 measured a store returning an internal handle
    ///   inside one), so nothing here trims, splits or reads inside them.
    ///   `<IsTruncated>` is not read either: `ObjectVersionPage.isTruncated`
    ///   is derived from the key marker alone, and a second truth for it
    ///   would be a way to disagree with it.
    /// - A document whose root is not `ListVersionsResult` (a proxy's error
    ///   page, say), one that is not well-formed, an entry with no `Key` or no
    ///   `VersionId`, and a `Size` that is not a non-negative integer are
    ///   `.protocolError`: reading any of them as "no history" or as a blank
    ///   entry would offer a restore of something that is not there. A
    ///   `LastModified` that is not a timestamp is `nil` instead, which is
    ///   what `ObjectVersion.modifiedAt` documents.
    static func parsePage(_ body: Data, status: Int) throws -> ObjectVersionPage {
        guard (200..<300).contains(status) else {
            throw S3FileSystem.mapErrorStatus(status, body: body, path: "")
        }
        let delegate = PageDelegate()
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            // An abort is the delegate's own doing, so Foundation's
            // description of it would be about the abort.
            let reason =
                delegate.abortReason
                ?? parser.parserError?.localizedDescription
                ?? "no ListVersionsResult element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 version listing response: \(reason)")
        }
        return ObjectVersionPage(
            versions: delegate.versions,
            nextKeyMarker: delegate.nextKeyMarker,
            nextVersionIdMarker: delegate.nextVersionIdMarker)
    }

    /// `marker` percent-encoded for use as the value of a query parameter
    /// (`key-marker`, `version-id-marker`): every byte but an RFC 3986
    /// unreserved one (`A-Za-z0-9-._~`) becomes an uppercase `%XX` escape.
    ///
    /// Not a shortcut for a key: a marker may carry `[`, `]`, `,` and `:`
    /// (spec §4.9), and pasting one into a URL by concatenation sends
    /// something else. The marker is encoded as a whole and never looked
    /// into.
    static func markerQueryValue(_ marker: String) -> String {
        var result = ""
        result.reserveCapacity(marker.utf8.count)
        for byte in marker.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"),
                UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.append(Character(UnicodeScalar(byte)))
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    private final class PageDelegate: NSObject, XMLParserDelegate {
        private(set) var sawRoot = false
        private(set) var abortReason: String?
        private(set) var versions: [ObjectVersion] = []
        private(set) var nextKeyMarker: String?
        private(set) var nextVersionIdMarker: String?
        private var depth = 0
        private var currentText = ""
        /// Which kind of entry is open: `Version` or `DeleteMarker`.
        private var entry: String?
        private var key: String?
        private var versionId: String?
        private var isLatest = false
        private var size: UInt64?
        private var modifiedAt: Date?
        private var entityTag: String?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if depth == 0 {
                guard elementName == "ListVersionsResult" else {
                    // Not a version listing: stop reading and let the caller
                    // report it.
                    abortReason = "no ListVersionsResult element"
                    parser.abortParsing()
                    return
                }
                sawRoot = true
            } else if depth == 1 && (elementName == "Version" || elementName == "DeleteMarker") {
                entry = elementName
                key = nil
                versionId = nil
                isLatest = false
                size = nil
                modifiedAt = nil
                entityTag = nil
            }
            depth += 1
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            // `depth` still counts the element that is ending: an entry is 2
            // (root 1, entry 2) and a field of an entry is 3.
            if entry != nil && depth == 3 {
                // Text is kept AS WRITTEN: a key may begin or end with a
                // space, and an id or a tag is the store's own. Only a
                // boolean, a number and a timestamp are trimmed; whitespace
                // around those is formatting.
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                switch elementName {
                case "Key": key = currentText
                case "VersionId": versionId = currentText
                case "IsLatest": isLatest = trimmed.lowercased() == "true"
                case "LastModified": modifiedAt = S3SettingsXML.timestamp(trimmed)
                case "ETag": entityTag = currentText
                case "Size":
                    guard let bytes = UInt64(trimmed) else {
                        abortReason = "Size \"\(trimmed)\" is not an integer"
                        parser.abortParsing()
                        return
                    }
                    size = bytes
                default: break
                }
            } else if entry != nil && depth == 2 {
                finishEntry(parser)
            } else if depth == 2 {
                // A direct child of the root that is not an entry. Only the
                // NEXT markers continue a listing; `KeyMarker` and
                // `VersionIdMarker` are the request's echo. An empty element
                // is no marker.
                switch elementName {
                case "NextKeyMarker" where !currentText.isEmpty:
                    nextKeyMarker = currentText
                case "NextVersionIdMarker" where !currentText.isEmpty:
                    nextVersionIdMarker = currentText
                default: break
                }
            }
            depth -= 1
            currentText = ""
        }

        private func finishEntry(_ parser: XMLParser) {
            guard let kind = entry else { return }
            entry = nil
            guard let key, !key.isEmpty else {
                abortReason = "\(kind) has no Key"
                parser.abortParsing()
                return
            }
            guard let versionId, !versionId.isEmpty else {
                abortReason = "\(kind) has no VersionId"
                parser.abortParsing()
                return
            }
            let isMarker = kind == "DeleteMarker"
            versions.append(
                ObjectVersion(
                    versionId: versionId, key: key, isLatest: isLatest, isDeleteMarker: isMarker,
                    size: isMarker ? nil : size, modifiedAt: modifiedAt,
                    entityTag: isMarker ? nil : entityTag))
        }
    }
}
