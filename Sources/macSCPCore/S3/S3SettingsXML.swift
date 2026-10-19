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

    // MARK: - Object Lock

    /// What a bucket's `GET ?object-lock` says, with the one distinction the
    /// public read hides: a bucket with no Object Lock at all, against one
    /// that has it but no default retention. `setObjectLockDefault` needs
    /// the difference (it must not be a way to switch Object Lock on).
    enum ObjectLockState: Equatable {
        /// `404` with `ObjectLockConfigurationNotFoundError`.
        case notConfigured
        /// Object Lock is on; `defaultRetention` is `nil` when the bucket
        /// carries no default.
        case enabled(defaultRetention: DefaultRetention?)
    }

    /// A bucket's default retention as `parseObjectLockState` reads it.
    struct DefaultRetention: Equatable {
        let days: Int
        let mode: RetentionMode
    }

    /// Reads a `GetObjectLockConfiguration` ANSWER for
    /// `S3BucketSettings.objectLockDefault(ofBucket:)`: the status as well
    /// as the body, because a bucket without Object Lock reports it as an
    /// error response.
    ///
    /// - `ObjectLockConfigurationNotFoundError` in a non-2xx body is `nil`:
    ///   not configured. The code decides, not the status (see
    ///   `S3ErrorCode`). Measured 2026-10-19 against the rig: `404`, and not
    ///   an empty configuration, which is why this is `nil` and never a
    ///   zero-day default.
    /// - A 2xx with Object Lock on and no default retention is `nil` too.
    ///   `parseObjectLockState` keeps those two apart.
    /// - Any other non-2xx goes through `S3FileSystem.mapErrorStatus`;
    ///   `path` is only what that mapping puts into a `.notFound`.
    static func parseObjectLockResponse(
        status: Int, body: Data, path: String = ""
    ) throws -> (days: Int, mode: RetentionMode)? {
        guard
            case .enabled(let retention?) = try parseObjectLockState(
                status: status, body: body, path: path)
        else { return nil }
        return (days: retention.days, mode: retention.mode)
    }

    /// `parseObjectLockResponse` without discarding what tells "no Object
    /// Lock" from "Object Lock, no default".
    static func parseObjectLockState(
        status: Int, body: Data, path: String = ""
    ) throws -> ObjectLockState {
        if (200..<300).contains(status) {
            return try parseObjectLock(body)
        }
        if S3ErrorCode.parse(body) == "ObjectLockConfigurationNotFoundError" {
            return .notConfigured
        }
        throw S3FileSystem.mapErrorStatus(status, body: body, path: path)
    }

    /// Reads an `ObjectLockConfiguration` document.
    ///
    /// Held to `parseVersioning`'s standard, and the fields do not depend on
    /// their order (the rig writes `Days` before `Mode`, measured
    /// 2026-10-19): a foreign root and a document that is not well-formed
    /// are `.protocolError`, and only an element at its place in the schema
    /// counts (`Rule/DefaultRetention/Days`, not a `Days` anywhere else).
    /// Refused rather than guessed: an `ObjectLockEnabled` that is absent or
    /// is not `Enabled` (a 2xx is not S3's way of saying "none"), a default
    /// with no `Mode` or an unknown one, a default naming neither `Days` nor
    /// `Years` or both, `Days` that is not a positive integer, and a default
    /// in `Years`, which is not a number of days.
    static func parseObjectLock(_ data: Data) throws -> ObjectLockState {
        let what = "object lock"
        let values = try leaves(of: data, root: "ObjectLockConfiguration", what: what)
        func refuse(_ reason: String) -> RemoteFSError {
            .protocolError(reason: "Failed to parse S3 \(what) response: \(reason)")
        }
        guard let enabled = values["ObjectLockEnabled"]?.last else {
            throw refuse("no ObjectLockEnabled element")
        }
        guard enabled == "Enabled" else {
            throw refuse("unknown ObjectLockEnabled \"\(enabled)\"")
        }
        let rule = "Rule/DefaultRetention"
        guard values[rule] != nil else { return .enabled(defaultRetention: nil) }
        guard let modeText = values[rule + "/Mode"]?.last,
            let mode = RetentionMode(rawValue: modeText)
        else {
            throw refuse("DefaultRetention has no known Mode")
        }
        switch (values[rule + "/Days"]?.last, values[rule + "/Years"]?.last) {
        case (nil, nil):
            throw refuse("DefaultRetention names neither Days nor Years")
        case (_?, _?):
            throw refuse("DefaultRetention names both Days and Years")
        case (nil, _?):
            throw refuse("DefaultRetention is in years, which cannot be given as a number of days")
        case (let daysText?, nil):
            guard let days = Int(daysText), days >= 1 else {
                throw refuse("Days \"\(daysText)\" is not a positive integer")
            }
            return .enabled(defaultRetention: DefaultRetention(days: days, mode: mode))
        }
    }

    /// The `PutObjectLockConfiguration` request body for a default of `days`
    /// in `mode`. Fewer than one day throws `.protocolError`: S3 refuses it,
    /// and the store is not the gate (the rig is the more permissive one).
    ///
    /// The body names `ObjectLockEnabled` because the schema asks for it; it
    /// does not turn Object Lock on for a bucket that has none, which is
    /// `setObjectLockDefault`'s business to refuse before this is sent.
    static func objectLockBody(days: Int, mode: RetentionMode) throws -> Data {
        guard days >= 1 else {
            throw RemoteFSError.protocolError(
                reason: "S3 object lock default must be at least one day, got \(days)")
        }
        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<ObjectLockConfiguration xmlns=\"\(namespace)\">"
            + "<ObjectLockEnabled>Enabled</ObjectLockEnabled>"
            + "<Rule><DefaultRetention><Mode>\(mode.rawValue)</Mode><Days>\(days)</Days>"
            + "</DefaultRetention></Rule></ObjectLockConfiguration>"
        return Data(xml.utf8)
    }

    /// Reads a `GetObjectRetention` ANSWER. `nil` is "no retention": a 2xx
    /// whose `<Retention>` is empty (what the rig answers for an unlocked
    /// object, measured 2026-10-19) and a non-2xx `NoSuchObjectLockConfiguration`
    /// (what AWS answers). Any other non-2xx goes through `mapErrorStatus`;
    /// a bucket without Object Lock is one of those (`400 InvalidRequest`
    /// at the rig), never `nil`.
    static func parseRetentionResponse(
        status: Int, body: Data, path: String = ""
    ) throws -> ObjectRetention? {
        if (200..<300).contains(status) {
            return try parseRetention(body)
        }
        if S3ErrorCode.parse(body) == "NoSuchObjectLockConfiguration" {
            return nil
        }
        throw S3FileSystem.mapErrorStatus(status, body: body, path: path)
    }

    /// Reads a `Retention` document. An empty one is `nil`; one with only a
    /// `Mode` or only a date, an unknown mode and a date that is not an
    /// ISO 8601 timestamp are `.protocolError`, as is a foreign root.
    static func parseRetention(_ data: Data) throws -> ObjectRetention? {
        let what = "retention"
        let values = try leaves(of: data, root: "Retention", what: what)
        func refuse(_ reason: String) -> RemoteFSError {
            .protocolError(reason: "Failed to parse S3 \(what) response: \(reason)")
        }
        let modeText = values["Mode"]?.last
        let dateText = values["RetainUntilDate"]?.last
        if modeText == nil && dateText == nil { return nil }
        guard let modeText, let dateText else {
            throw refuse("Mode and RetainUntilDate are not both present")
        }
        guard let mode = RetentionMode(rawValue: modeText) else {
            throw refuse("unknown Mode \"\(modeText)\"")
        }
        guard let date = timestamp(dateText) else {
            throw refuse("RetainUntilDate \"\(dateText)\" is not a timestamp")
        }
        return ObjectRetention(mode: mode, retainUntil: date)
    }

    /// The `PutObjectRetention` request body. The date is written in UTC to
    /// the millisecond, the form the rig itself reads back.
    static func retentionBody(_ retention: ObjectRetention) -> Data {
        let date = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .format(retention.retainUntil)
        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Retention xmlns=\"\(namespace)\"><Mode>\(retention.mode.rawValue)</Mode>"
            + "<RetainUntilDate>\(date)</RetainUntilDate></Retention>"
        return Data(xml.utf8)
    }

    /// Reads a `GetObjectLegalHold` ANSWER. `NoSuchObjectLockConfiguration`
    /// in a non-2xx body is `false`: an object never put under a hold. Any
    /// other non-2xx goes through `mapErrorStatus`.
    static func parseLegalHoldResponse(
        status: Int, body: Data, path: String = ""
    ) throws -> Bool {
        if (200..<300).contains(status) {
            return try parseLegalHold(body)
        }
        if S3ErrorCode.parse(body) == "NoSuchObjectLockConfiguration" {
            return false
        }
        throw S3FileSystem.mapErrorStatus(status, body: body, path: path)
    }

    /// Reads a `LegalHold` document: `ON` is `true`, `OFF` is `false`. A
    /// missing or other `Status` and a foreign root are `.protocolError`:
    /// neither says the object is not held.
    static func parseLegalHold(_ data: Data) throws -> Bool {
        let what = "legal hold"
        let values = try leaves(of: data, root: "LegalHold", what: what)
        switch values["Status"]?.last {
        case "ON":
            return true
        case "OFF":
            return false
        case let other?:
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 \(what) response: unknown status \"\(other)\"")
        case nil:
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 \(what) response: no Status element")
        }
    }

    /// The `PutObjectLegalHold` request body.
    static func legalHoldBody(_ on: Bool) -> Data {
        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<LegalHold xmlns=\"\(namespace)\"><Status>\(on ? "ON" : "OFF")</Status></LegalHold>"
        return Data(xml.utf8)
    }

    /// An S3 timestamp: ISO 8601 in UTC, with or without fractional seconds
    /// (the rig writes `.000`, other stores omit it).
    private static func timestamp(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// The text of every element of a document whose root is `root`, keyed
    /// by its path below the root (`Rule/DefaultRetention/Days`), in the
    /// order found. Trimmed: the callers read enumerations, numbers and
    /// timestamps, where whitespace is formatting. An element with children
    /// is keyed too (with no meaningful text), so presence can be asked.
    ///
    /// A foreign root and a document that is not well-formed are
    /// `.protocolError`, with the delegate's own reason for the first.
    private static func leaves(of data: Data, root: String, what: String) throws -> [String: [String]] {
        let delegate = LeafDelegate(root: root)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            // An abort for a foreign root is the delegate's own doing, so
            // Foundation's description of it would be about the abort.
            let reason =
                delegate.rejectedRoot
                ? "no \(root) element"
                : parser.parserError?.localizedDescription ?? "no \(root) element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 \(what) response: \(reason)")
        }
        return delegate.values
    }

    private final class LeafDelegate: NSObject, XMLParserDelegate {
        private let root: String
        private(set) var sawRoot = false
        private(set) var rejectedRoot = false
        private(set) var values: [String: [String]] = [:]
        private var path: [String] = []
        private var currentText = ""

        init(root: String) {
            self.root = root
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if path.isEmpty {
                guard elementName == root else {
                    rejectedRoot = true
                    parser.abortParsing()
                    return
                }
                sawRoot = true
            }
            path.append(elementName)
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            // The root itself has no key: every key is relative to it.
            if path.count > 1 {
                values[path.dropFirst().joined(separator: "/"), default: []].append(
                    currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            path.removeLast()
            currentText = ""
        }
    }
}
