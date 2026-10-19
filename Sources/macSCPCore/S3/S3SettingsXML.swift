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

    // MARK: - CORS

    /// Reads a `GetBucketCors` ANSWER: the status as well as the body,
    /// because "no CORS configuration" is how S3 reports an unset bucket and
    /// it arrives as an error response.
    ///
    /// - A 2xx is `parseCORS(body)`; an empty `<CORSConfiguration/>` is `[]`.
    /// - `NoSuchCORSConfiguration` in a non-2xx body is `nil`: none set. The
    ///   code decides, not the status, for the reason `S3ErrorCode` gives.
    ///   `nil` and `[]` are different answers and stay different.
    /// - Any other non-2xx goes through `S3FileSystem.mapErrorStatus`, so a
    ///   named refusal keeps its finding; `path` is only what that mapping
    ///   puts into a `.notFound`.
    static func parseCORSResponse(status: Int, body: Data, path: String = "") throws -> [CORSRule]? {
        if (200..<300).contains(status) {
            return try parseCORS(body)
        }
        if S3ErrorCode.parse(body) == "NoSuchCORSConfiguration" {
            return nil
        }
        throw S3FileSystem.mapErrorStatus(status, body: body, path: path)
    }

    /// Reads a `CORSConfiguration` document.
    ///
    /// The fields of a rule are read WITHOUT depending on their order: the
    /// rig returns `AllowedHeader`, `AllowedMethod`, `AllowedOrigin`,
    /// `ExposeHeader`, `ID`, `MaxAgeSeconds` alphabetically whatever order
    /// they were written in (measured 2026-10-19). The order of the RULES
    /// themselves, and of the values under one element name, is kept.
    ///
    /// Held to `parseVersioning`'s standard: a document whose root is not
    /// `CORSConfiguration` and a document that is not well-formed are
    /// `.protocolError` (reading either as "no rules" would report a bucket
    /// unconfigured on the strength of an answer that said nothing about
    /// it), a `MaxAgeSeconds` that is not an integer is too, and only a
    /// `CORSRule` directly under the root and a field directly under a rule
    /// count. An element inside a rule that this type has no field for is
    /// skipped, which makes this read lossy; that is why
    /// `S3BucketSettings.cors(ofBucket:)` hands back the raw document beside
    /// the rules, so a caller can tell "these rules are everything" from
    /// "these rules are what was understood". Text values are kept as
    /// written; `MaxAgeSeconds` is trimmed before it is read as a number.
    public static func parseCORS(_ data: Data) throws -> [CORSRule] {
        let delegate = CORSDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            // An abort for a foreign root or a bad number is the delegate's
            // own doing, so Foundation's description would be about the abort.
            let reason =
                delegate.abortReason
                ?? parser.parserError?.localizedDescription
                ?? "no CORSConfiguration element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 CORS response: \(reason)")
        }
        return delegate.rules
    }

    /// The `PutBucketCors` request body for `rules`. Values are XML-escaped
    /// (`S3XMLText.escaped`, which refuses what XML cannot carry). Fields
    /// are written in the order the spec's section 4 names the schema
    /// (`docs/superpowers/specs/2026-10-19-s3-bucket-settings-design.md`:
    /// `ID`, `AllowedOrigin`, `AllowedMethod`, `AllowedHeader`,
    /// `ExposeHeader`, `MaxAgeSeconds`), which the rig accepted; the store
    /// does not hold it to that order. An absent `ID` or `MaxAgeSeconds`
    /// writes no element.
    ///
    /// Does NOT validate: `CORSRule.validate()` is the caller's gate
    /// (`setCORS`), so this stays the inverse of `parseCORS` for any rule,
    /// valid or not. Values are kept exactly as written, spaces at either
    /// end included (`parseCORS` does not trim them, and
    /// `S3CORSTests.spacesAroundAValueSurviveTheRoundTrip` holds that).
    public static func corsBody(_ rules: [CORSRule]) throws -> Data {
        var xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<CORSConfiguration xmlns=\"\(namespace)\">"
        for rule in rules {
            xml += "<CORSRule>"
            if let id = rule.id { xml += "<ID>\(try S3XMLText.escaped(id))</ID>" }
            for origin in rule.allowedOrigins {
                xml += "<AllowedOrigin>\(try S3XMLText.escaped(origin))</AllowedOrigin>"
            }
            for method in rule.allowedMethods {
                xml += "<AllowedMethod>\(try S3XMLText.escaped(method))</AllowedMethod>"
            }
            for header in rule.allowedHeaders {
                xml += "<AllowedHeader>\(try S3XMLText.escaped(header))</AllowedHeader>"
            }
            for header in rule.exposeHeaders {
                xml += "<ExposeHeader>\(try S3XMLText.escaped(header))</ExposeHeader>"
            }
            if let maxAge = rule.maxAgeSeconds {
                xml += "<MaxAgeSeconds>\(maxAge)</MaxAgeSeconds>"
            }
            xml += "</CORSRule>"
        }
        xml += "</CORSConfiguration>"
        return Data(xml.utf8)
    }

    private final class CORSDelegate: NSObject, XMLParserDelegate {
        private(set) var sawRoot = false
        private(set) var abortReason: String?
        private(set) var rules: [CORSRule] = []
        private var depth = 0
        private var currentText = ""
        private var inRule = false
        private var id: String?
        private var origins: [String] = []
        private var methods: [String] = []
        private var allowedHeaders: [String] = []
        private var exposeHeaders: [String] = []
        private var maxAge: Int?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if depth == 0 {
                guard elementName == "CORSConfiguration" else {
                    // Not a CORS document: stop reading and let the caller
                    // report it.
                    abortReason = "no CORSConfiguration element"
                    parser.abortParsing()
                    return
                }
                sawRoot = true
            } else if depth == 1 && elementName == "CORSRule" {
                inRule = true
                id = nil
                origins = []
                methods = []
                allowedHeaders = []
                exposeHeaders = []
                maxAge = nil
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
            // `depth` still counts the element that is ending: a rule is 2
            // (root 1, rule 2) and a field of a rule is 3.
            if inRule && depth == 3 {
                // Text values are kept AS WRITTEN: `S3XMLText.escaped`
                // preserves whitespace, so trimming here would make a value
                // with a leading or trailing space come back as another
                // value. Only the number is trimmed; whitespace around a
                // number is formatting.
                switch elementName {
                case "ID": id = currentText
                case "AllowedOrigin": origins.append(currentText)
                case "AllowedMethod": methods.append(currentText)
                case "AllowedHeader": allowedHeaders.append(currentText)
                case "ExposeHeader": exposeHeaders.append(currentText)
                case "MaxAgeSeconds":
                    let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let seconds = Int(text) else {
                        abortReason = "MaxAgeSeconds \"\(text)\" is not an integer"
                        parser.abortParsing()
                        return
                    }
                    maxAge = seconds
                default: break
                }
            } else if inRule && depth == 2 && elementName == "CORSRule" {
                rules.append(
                    CORSRule(
                        id: id, allowedOrigins: origins, allowedMethods: methods,
                        allowedHeaders: allowedHeaders, exposeHeaders: exposeHeaders,
                        maxAgeSeconds: maxAge))
                inRule = false
            }
            depth -= 1
            currentText = ""
        }
    }
}
