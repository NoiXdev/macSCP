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
    /// The text of the first `<Code>` element in `body`, or `nil` when the
    /// body is not XML or has no such element (a `HEAD` answer has no body
    /// at all, and a proxy's refusal is often HTML).
    public static func parse(_ body: Data) -> String? {
        let delegate = CodeDelegate()
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        _ = parser.parse()
        // Read the delegate, not `parse()`'s verdict: the delegate aborts the
        // parse once it has the code, which makes `parse()` answer `false`.
        guard let code = delegate.code, !code.isEmpty else { return nil }
        return code
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
    /// `status` is accepted so the call site reads as one question, but the
    /// code decides: stores that speak S3 disagree on the status for the same
    /// code, and a code that is named here is named whatever status it came
    /// with.
    public static func finding(forCode code: String, status: Int, path: String) -> RemoteFSError? {
        switch code {
        case "ObjectLockConfigurationNotFoundError":
            return .finding(.objectLockNotConfigured)
        case "BucketNotEmpty":
            return .finding(.bucketNotEmpty)
        case "NotImplemented":
            return .finding(.operationNotSupported)
        default:
            return nil
        }
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
            code = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            inCode = false
            parser.abortParsing()
        }
    }
}
