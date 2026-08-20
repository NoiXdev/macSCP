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
    @Test func allFivePredefinedEntitiesAreReplaced() throws {
        #expect(try S3XMLText.escaped("&") == "&amp;")
        #expect(try S3XMLText.escaped("<") == "&lt;")
        #expect(try S3XMLText.escaped(">") == "&gt;")
        #expect(try S3XMLText.escaped("\"") == "&quot;")
        #expect(try S3XMLText.escaped("'") == "&apos;")
    }

    @Test func textWithoutMetacharactersIsUnchanged() throws {
        #expect(try S3XMLText.escaped("") == "")
        #expect(try S3XMLText.escaped("photos/2026/münchen ünlü.txt") == "photos/2026/münchen ünlü.txt")
    }

    /// The trap a chain of `replacingOccurrences` calls has and this does
    /// not: replacing `<` with `&lt;` introduces an ampersand, so a later
    /// `&` pass escapes it again unless `&` went first. One pass over the
    /// scalars appends its output and never re-reads it, so the ordering
    /// question does not exist.
    @Test func anIntroducedAmpersandIsNotEscapedTwice() throws {
        #expect(try S3XMLText.escaped("a<b") == "a&lt;b")
        #expect(try S3XMLText.escaped("a&<b") == "a&amp;&lt;b")
        #expect(!(try S3XMLText.escaped("<>\"'&")).contains("&amp;lt;"))
    }

    /// The reason it is a scalar walk rather than a `String` API call:
    /// `replacingOccurrences` matches on extended grapheme clusters, so an
    /// ampersand carrying a combining mark is not an occurrence of `&` to it
    /// and goes into the request body raw. A scalar walk sees the ampersand
    /// and the mark separately, which is what an XML parser does too.
    @Test func aMetacharacterCarryingACombiningMarkIsStillEscaped() throws {
        #expect(try S3XMLText.escaped("a&\u{0308}b") == "a&amp;\u{0308}b")
        #expect(try S3XMLText.escaped("a<\u{FE0F}b") == "a&lt;\u{FE0F}b")
        #expect("a&\u{0308}b".replacingOccurrences(of: "&", with: "&amp;") == "a&\u{0308}b")
    }

    /// A character XML 1.0 cannot carry is a refusal, not an escape and not
    /// a deletion.
    ///
    /// It used to go through untouched, and a review measured the result: a
    /// real `XMLParser` rejected the document. Dropping the character is the
    /// obvious repair and the wrong one — these values are identities
    /// compared byte-for-byte, so `a\u{1}b.txt` with the control removed is
    /// `ab.txt`, which may be a different object in the same bucket, and a
    /// `DeleteObjects` body would then name it. Failing the request is the
    /// honest outcome: the request was already impossible.
    @Test func aCharacterXMLCannotCarryIsRefused() {
        #expect(throws: RemoteFSError.self) { try S3XMLText.escaped("a\u{0001}b") }
        #expect(throws: RemoteFSError.self) { try S3XMLText.escaped("\u{FFFE}") }
        #expect(throws: RemoteFSError.self) { try S3XMLText.escaped("\u{001F}") }
    }

    /// The three control characters XML does admit stay, and so does the
    /// rest of the range — a refusal that swallowed a tab would break
    /// ordinary keys.
    @Test func theControlCharactersXMLAdmitsAreKept() throws {
        #expect(try S3XMLText.escaped("a\tb\nc\rd") == "a\tb\nc\rd")
        #expect(try S3XMLText.escaped("\u{7F}\u{FFFD}\u{10000}") == "\u{7F}\u{FFFD}\u{10000}")
    }

    /// And the whole point of the refusal, executed: what comes out of the
    /// escaper parses. Round-tripped through a real `XMLParser`, because
    /// "well-formed" is a claim about a parser, not about our loop.
    @Test func whatTheEscaperProducesParses() throws {
        let hostile = "a&b<c>d\"e'f ü€ ]]>"
        let document = "<Key>\(try S3XMLText.escaped(hostile))</Key>"
        let parser = XMLParser(data: Data(document.utf8))
        let delegate = TextCollector()
        parser.delegate = delegate
        #expect(parser.parse())
        #expect(delegate.text == hostile)
    }

    private final class TextCollector: NSObject, XMLParserDelegate {
        private(set) var text = ""

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }
    }
}

/// The `CompleteMultipartUpload` body, whose ETags come from the SERVER.
@Suite("S3 multipart XML")
struct S3MultipartXMLTests {
    private func body(_ parts: [(number: Int, etag: String)]) throws -> String {
        String(data: try S3MultipartXML.completeBody(parts: parts), encoding: .utf8)!
    }

    @Test func partsAreListedInAscendingPartNumberOrder() throws {
        let xml = try body([(3, "\"c\""), (1, "\"a\""), (2, "\"b\"")])
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
    @Test func aServerSuppliedETagCannotChangeTheShapeOfTheBody() throws {
        let hostile = "\"abc\"</ETag><Part><PartNumber>9</PartNumber><ETag>\"x\""
        let xml = try body([(1, hostile)])
        #expect(!xml.contains("<PartNumber>9</PartNumber>"))
        #expect(xml.contains("&lt;/ETag&gt;"))
        #expect(xml.hasSuffix("</CompleteMultipartUpload>"))
    }

    /// The ordinary ETag still round-trips: its quotes are escaped rather
    /// than dropped, and an XML parser turns them back into the same bytes
    /// S3 compares against what it stored.
    @Test func anOrdinaryETagKeepsItsQuotesThroughEscaping() throws {
        let xml = try body([(1, "\"9bb58f26192e4ba00f01e2e7b136bbd8\"")])
        #expect(xml.contains("<ETag>&quot;9bb58f26192e4ba00f01e2e7b136bbd8&quot;</ETag>"))
    }
}
