import Foundation

/// XML (de)serialization for a bucket's settings (`S3BucketSettings`).
/// Foundation's `XMLParser`, no new dependency — the same approach as
/// `S3ListParser` and `S3MultipartXML`. Each setting adds its parse and
/// body functions here.
public enum S3SettingsXML {
    private static let namespace = "http://s3.amazonaws.com/doc/2006-03-01/"

    // MARK: - Versioning

    /// Reads a `GetBucketVersioning` answer.
    ///
    /// A `VersioningConfiguration` with no `<Status>` is `.never`: that is
    /// how S3 says versioning has never been switched on, and it is a normal
    /// answer rather than a malformed one. A status other than `Enabled` or
    /// `Suspended`, a document that is not well-formed, and a document whose
    /// root is some other element (a proxy's error page, say) are
    /// `.protocolError` — reading any of them as `.never` would tell a
    /// caller a bucket is unversioned on the strength of an answer that said
    /// nothing about it.
    public static func parseVersioning(_ data: Data) throws -> BucketVersioning {
        let delegate = VersioningDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            // An abort for a foreign root is the delegate's own doing, so
            // Foundation's description of it would be about the abort.
            let reason =
                delegate.rejectedRoot
                ? "no VersioningConfiguration element"
                : parser.parserError?.localizedDescription ?? "no VersioningConfiguration element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 versioning response: \(reason)")
        }
        switch delegate.status {
        case nil:
            return .never
        case "Enabled":
            return .enabled
        case "Suspended":
            return .suspended
        case let other?:
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 versioning response: unknown status \"\(other)\"")
        }
    }

    /// The `PutBucketVersioning` request body for `state`.
    ///
    /// `.never` has no body and throws
    /// `RemoteFSError.finding(.operationNotSupported)`: S3 cannot express
    /// "return this bucket to never-versioned", and sending an empty
    /// configuration instead would not do it either — it would be accepted
    /// and leave the bucket as it was, which is a silent no-op where the
    /// caller asked for a change.
    public static func versioningBody(_ state: BucketVersioning) throws -> Data {
        let status: String
        switch state {
        case .never:
            throw RemoteFSError.finding(.operationNotSupported)
        case .enabled:
            status = "Enabled"
        case .suspended:
            status = "Suspended"
        }
        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<VersioningConfiguration xmlns=\"\(namespace)\">"
            + "<Status>\(status)</Status></VersioningConfiguration>"
        return Data(xml.utf8)
    }

    private final class VersioningDelegate: NSObject, XMLParserDelegate {
        private(set) var sawRoot = false
        private(set) var rejectedRoot = false
        private(set) var status: String?
        private var depth = 0
        private var currentText = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if depth == 0 {
                if elementName == "VersioningConfiguration" {
                    sawRoot = true
                } else {
                    // Not a versioning document: stop reading and let the
                    // caller report it.
                    rejectedRoot = true
                    parser.abortParsing()
                    return
                }
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
            // Only the root's own child counts: a `Status` nested somewhere
            // deeper is not this document's status.
            if elementName == "Status" && depth == 2 {
                status = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            depth -= 1
            currentText = ""
        }
    }
}
