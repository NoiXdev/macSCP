import Foundation

/// XML (de)serialization for the S3 multipart upload handshake (M13/T6):
/// parses the `UploadId` out of an `InitiateMultipartUploadResult` response,
/// and builds the `CompleteMultipartUpload` request body listing every part's
/// number and ETag. Uses Foundation's `XMLParser` — no new dependency, same
/// approach as `S3ListParser`.
public enum S3MultipartXML {
    /// Extracts `<UploadId>` from an `InitiateMultipartUploadResult` XML
    /// response. Throws `.protocolError` if the document fails to parse or
    /// has no `UploadId` element — a malformed/empty response should never
    /// silently produce an empty upload ID that later requests would sign
    /// against.
    public static func parseUploadID(_ data: Data) throws -> String {
        let delegate = UploadIDDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let uploadID = delegate.uploadID, !uploadID.isEmpty else {
            let reason = parser.parserError?.localizedDescription ?? "no UploadId element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 InitiateMultipartUpload response: \(reason)")
        }
        return uploadID
    }

    /// Builds the `CompleteMultipartUpload` XML body, listing `parts` in
    /// ascending part-number order regardless of the order they were
    /// collected in. ETags are echoed VERBATIM — including their surrounding
    /// quotes exactly as the `UploadPart` response's `ETag` header carried
    /// them — since S3 compares the ETag it is given against what it stored
    /// byte-for-byte.
    public static func completeBody(parts: [(number: Int, etag: String)]) -> Data {
        let sorted = parts.sorted { $0.number < $1.number }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<CompleteMultipartUpload>"
        for part in sorted {
            xml += "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(part.etag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    private final class UploadIDDelegate: NSObject, XMLParserDelegate {
        private(set) var uploadID: String?
        private var currentText = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            if elementName == "UploadId" {
                uploadID = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentText = ""
        }
    }
}
