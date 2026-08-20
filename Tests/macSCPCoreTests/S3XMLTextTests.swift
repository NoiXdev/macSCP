import Foundation
import Testing

@testable import macSCPCore

/// The escaper that stands between a value this process did not author and
/// a request body this process assembles by string interpolation.
///
/// It had no tests at all: mutated to return its input unchanged, the whole
/// suite stayed green, and so did removing the `&` case. Being correct
/// today is not the same as being protected, and this is the kind of
/// function that gets "simplified" back into a chain of
/// `replacingOccurrences` calls by someone who does not know why it is a
/// loop.
@Suite("S3 XML text")
struct S3XMLTextTests {
    @Test func allFivePredefinedEntitiesAreReplaced() {
        #expect(S3XMLText.escaped("&") == "&amp;")
        #expect(S3XMLText.escaped("<") == "&lt;")
        #expect(S3XMLText.escaped(">") == "&gt;")
        #expect(S3XMLText.escaped("\"") == "&quot;")
        #expect(S3XMLText.escaped("'") == "&apos;")
    }

    @Test func textWithoutMetacharactersIsUnchanged() {
        #expect(S3XMLText.escaped("") == "")
        #expect(S3XMLText.escaped("photos/2026/münchen ünlü.txt") == "photos/2026/münchen ünlü.txt")
    }

    /// The trap a chain of `replacingOccurrences` calls has and this does
    /// not: replacing `<` with `&lt;` introduces an ampersand, so a later
    /// `&` pass escapes it again unless `&` went first. One pass over the
    /// scalars appends its output and never re-reads it, so the ordering
    /// question does not exist.
    @Test func anIntroducedAmpersandIsNotEscapedTwice() {
        #expect(S3XMLText.escaped("a<b") == "a&lt;b")
        #expect(S3XMLText.escaped("a&<b") == "a&amp;&lt;b")
        #expect(!S3XMLText.escaped("<>\"'&").contains("&amp;lt;"))
    }

    /// The reason it is a scalar walk rather than a `String` API call:
    /// `replacingOccurrences` matches on extended grapheme clusters, so an
    /// ampersand carrying a combining mark is not an occurrence of `&` to it
    /// and goes into the request body raw. A scalar walk sees the ampersand
    /// and the mark separately, which is what an XML parser does too.
    @Test func aMetacharacterCarryingACombiningMarkIsStillEscaped() {
        #expect(S3XMLText.escaped("a&\u{0308}b") == "a&amp;\u{0308}b")
        #expect(S3XMLText.escaped("a<\u{FE0F}b") == "a&lt;\u{FE0F}b")
        #expect("a&\u{0308}b".replacingOccurrences(of: "&", with: "&amp;") == "a&\u{0308}b")
    }
}

/// The `CompleteMultipartUpload` body, whose ETags come from the SERVER.
@Suite("S3 multipart XML")
struct S3MultipartXMLTests {
    private func body(_ parts: [(number: Int, etag: String)]) -> String {
        String(data: S3MultipartXML.completeBody(parts: parts), encoding: .utf8)!
    }

    @Test func partsAreListedInAscendingPartNumberOrder() {
        let xml = body([(3, "\"c\""), (1, "\"a\""), (2, "\"b\"")])
        let first = xml.range(of: "<PartNumber>1</PartNumber>")!
        let second = xml.range(of: "<PartNumber>2</PartNumber>")!
        let third = xml.range(of: "<PartNumber>3</PartNumber>")!
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
    }

    /// An ETag is a server-chosen string interpolated into a body this
    /// process signs and sends. Unescaped, a `<` in it would close the
    /// `<ETag>` element early and let the rest of the value be read as
    /// markup — the request would stop being the one this code wrote.
    /// Nothing in this branch had touched this line; it was found while
    /// fixing its sibling in `S3FileSystem`, which had the escaper.
    @Test func aServerSuppliedETagCannotChangeTheShapeOfTheBody() {
        let hostile = "\"abc\"</ETag><Part><PartNumber>9</PartNumber><ETag>\"x\""
        let xml = body([(1, hostile)])
        #expect(!xml.contains("<PartNumber>9</PartNumber>"))
        #expect(xml.contains("&lt;/ETag&gt;"))
        #expect(xml.hasSuffix("</CompleteMultipartUpload>"))
    }

    /// The ordinary ETag still round-trips: its quotes are escaped rather
    /// than dropped, and an XML parser turns them back into the same bytes
    /// S3 compares against what it stored.
    @Test func anOrdinaryETagKeepsItsQuotesThroughEscaping() {
        let xml = body([(1, "\"9bb58f26192e4ba00f01e2e7b136bbd8\"")])
        #expect(xml.contains("<ETag>&quot;9bb58f26192e4ba00f01e2e7b136bbd8&quot;</ETag>"))
    }
}
