import Foundation

/// Reads the `<Code>` out of an S3 error body and names the few refusals
/// whose status alone does not say what happened.
///
/// A 403 used to become `.authenticationFailed` whatever the store meant by
/// it, so a delete refused under a legal hold told the user their
/// credentials were wrong. The body carries the real code; this reads it.
/// Uses Foundation's `XMLParser`, as `S3MultipartXML` and `S3ListParser` do.
///
/// ## Five names, on purpose
///
/// Five codes are named in `finding(forCode:status:path:)`, counted on
/// 2026-10-19 with `grep -c '^        case "' Sources/macSCPCore/S3/S3ErrorCode.swift`
/// (which prints 5; the pattern is eight spaces then `case "`, the arms of
/// that one switch). An earlier version of this heading said five while the
/// switch held three. The two delete refusals
/// (`.objectUnderLegalHold`, `.objectUnderRetention`) are built elsewhere
/// and are not among the five.
///
/// Each named code costs a `RemoteFSFinding` case, a `Name` case, a `name`
/// arm and four catalogue sentences, so only the refusals a user of the
/// bucket settings can provoke are named. Every other code returns `nil`,
/// which is the signal to fall through to the status-only mapping in
/// `S3FileSystem.mapErrorStatus`, unchanged.
///
/// ## What a finding may carry
///
/// Nothing the store wrote. The body's `<Message>` is never read, and the
/// only payload a finding built here holds is the caller's own `path`.
public enum S3ErrorCode {
    /// The text of the first non-empty `<Code>` element in `body`, or `nil`
    /// when the body is not XML or has no such element (a `HEAD` answer has
    /// no body at all, and a proxy's refusal is often HTML).
    public static func parse(_ body: Data) -> String? {
        let delegate = CodeDelegate()
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        _ = parser.parse()
        // Read the delegate, not `parse()`'s verdict: the delegate aborts the
        // parse once it has the code, which makes `parse()` answer `false`.
        return delegate.code
    }

    /// The finding for a named `code`, or `nil` for any code not named here.
    ///
    /// `AccessDenied` is deliberately NOT named: a legal hold and a retention
    /// period both answer with it, so the code cannot tell
    /// `.objectUnderLegalHold` from `.objectUnderRetention`. The delete path
    /// that has read the object's `?legal-hold` can, and it builds the
    /// finding itself; guessing here would tell the user the wrong thing,
    /// which is the defect this type exists to remove. Parsing the store's
    /// message to split them is out too: that is the server's sentence, and a
    /// finding carries none.
    ///
    /// `status` and `path` are both accepted and NEITHER is read: the
    /// signature is the shape the call sites were planned around, and the
    /// five findings named here need no payload. The code alone decides —
    /// stores that speak S3 disagree on the status for the same code, and a
    /// code that is named here is named whatever status it came with. A
    /// future named finding that carries a path (as `.objectUnderLegalHold`
    /// does) is why `path` is kept rather than dropped.
    public static func finding(forCode code: String, status: Int, path: String) -> RemoteFSError? {
        switch code {
        case "ObjectLockConfigurationNotFoundError":
            return .finding(.objectLockNotConfigured)
        case "BucketNotEmpty":
            return .finding(.bucketNotEmpty)
        case "BucketAlreadyExists":
            return .finding(.bucketNameTaken)
        case "BucketAlreadyOwnedByYou":
            return .finding(.bucketAlreadyOwnedByYou)
        case "NotImplemented":
            return .finding(.operationNotSupported)
        default:
            return nil
        }
    }

    /// The per-key refusals listed in a `DeleteObjects` answer: one
    /// `(key, code)` per `<Error>` element, in document order.
    ///
    /// `DeleteObjects` reports a key it could not delete INSIDE an HTTP 200
    /// `<DeleteResult>`, so that refusal never reaches the non-2xx path that
    /// feeds `parse`. `key` is the text of the echoed `<Key>`, exactly as
    /// written (not trimmed: a key may begin or end with a space, and a
    /// caller matches it against the keys it sent). It is a value the STORE
    /// wrote, so it is not trusted to be one of those keys, and a finding must
    /// never carry it as a path: `S3FileSystem.deleteTree` looks it up among
    /// the keys of the batch it sent and uses its own spelling.
    /// `code` is looked up in `finding(forCode:status:path:)` the same way a
    /// whole-response code is. The element's `<Message>` is not read, so the
    /// store's sentence cannot travel. A body that is not XML, or lists no
    /// `<Error>`, yields an empty list.
    public static func perKeyRefusals(in body: Data) -> [(key: String, code: String)] {
        let delegate = RefusalDelegate()
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.refusals
    }

    private final class CodeDelegate: NSObject, XMLParserDelegate {
        private(set) var code: String?
        private var inCode = false
        private var currentText = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            inCode = elementName == "Code"
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCode { currentText += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard elementName == "Code", inCode else { return }
            inCode = false
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty element names nothing; keep looking for the first
            // one that does.
            guard !text.isEmpty else { return }
            code = text
            parser.abortParsing()
        }
    }

    private final class RefusalDelegate: NSObject, XMLParserDelegate {
        private(set) var refusals: [(key: String, code: String)] = []
        private var inError = false
        private var key = ""
        private var code = ""
        private var field: String?
        private var currentText = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "Error" {
                inError = true
                key = ""
                code = ""
            }
            field = inError && (elementName == "Key" || elementName == "Code") ? elementName : nil
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if field != nil { currentText += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            switch elementName {
            case "Key" where field == "Key":
                key = currentText
            case "Code" where field == "Code":
                code = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "Error":
                if inError, !code.isEmpty { refusals.append((key: key, code: code)) }
                inError = false
            default:
                break
            }
            field = nil
            currentText = ""
        }
    }
}
