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
            // TWO PROVENANCES IN ONE SENTENCE, left that way on purpose
            // (maintainer's decision, 2026-10-01; docs/BACKLOG.md row
            // "`S3MultipartXML.parseUploadID` composes one sentence out of an
            // in-scope half and a foreign half").
            //
            // `reason` is either Foundation's own `parserError`
            // `localizedDescription` — a foreign string, out of scope for typing
            // since 2026-09-28 — or this project's own "no UploadId element".
            // Typing the second half would mean a finding, which the parity
            // guard turns into four catalogue sentences; the phrase reaches a
            // reader, and two of those four would go into catalogues whose
            // native-speaker review was closed unreviewed. So the in-scope half
            // stays untyped here, deliberately, and this comment is the record.
            //
            // The phrase DOES reach a reader, which an earlier draft of this
            // comment denied: `S3Uploader.uploadMultipart` lets the
            // `.protocolError` through `S3FileSystem.write`, and from there the
            // app shows `transfers.failure.protocolError` ("The server sent an
            // answer that could not be used.") with this text appended as a
            // marked technical detail, while the CLI prints it after "Error: ".
            // What it is NOT is the only text a reader gets: the sentence in
            // front of it is already translated, and the English half arrives
            // labelled as technical. Typing the in-scope half would trade that
            // pair for one translated sentence with no suffix — a real but small
            // gain, against four catalogue sentences, two of them in `fr`/`pl`
            // catalogues whose native-speaker review was closed unreviewed.
            //
            // Revisit if the technical-detail suffix is ever dropped, or if this
            // phrase becomes the only text a reader gets.
            let reason = parser.parserError?.localizedDescription ?? "no UploadId element"
            throw RemoteFSError.protocolError(
                reason: "Failed to parse S3 InitiateMultipartUpload response: \(reason)")
        }
        return uploadID
    }

    /// Builds the `CompleteMultipartUpload` XML body, listing `parts` in
    /// ascending part-number order regardless of the order they were
    /// collected in.
    ///
    /// An ETag keeps the surrounding quotes the `UploadPart` response's
    /// `ETag` header carried, because S3 compares the ETag it is given
    /// against what it stored byte-for-byte — but it goes through
    /// `S3XMLText.escaped` on the way in, which those quotes make the point
    /// of rather than an exception to. The value is chosen by the SERVER,
    /// this body is assembled by string interpolation, and an ETag holding a
    /// `<` would otherwise decide where `<ETag>` ends. Escaping is
    /// transparent to the receiver (`&quot;` parses back to `"`), so the
    /// bytes S3 compares are unchanged; the shape of the document stops
    /// being the server's to choose.
    public static func completeBody(parts: [(number: Int, etag: String)]) throws -> Data {
        let sorted = parts.sorted { $0.number < $1.number }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<CompleteMultipartUpload>"
        for part in sorted {
            let etag = try S3XMLText.escaped(part.etag)
            xml += "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(etag)</ETag></Part>"
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
