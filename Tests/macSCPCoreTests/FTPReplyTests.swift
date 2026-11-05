import Foundation
import Testing
@testable import macSCPCore

/// RFC 959 section 4.2: a reply is a three-digit code and text. A multiline
/// reply opens with `<code>-` and closes with the same code followed by a
/// space, at the very start of a line. These pin the parser as a pure
/// function over one line plus the partial state -- no connection involved.
@Suite("FTP reply parsing")
struct FTPReplyTests {
    @Test func aSingleLineReplyIsCompleteAtOnce() throws {
        var partial: [String] = []
        let reply = try #require(try FTPReplyAccumulator.feed("220 ready", into: &partial))
        #expect(reply.code == 220)
        #expect(reply.lines == ["ready"])
        #expect(partial.isEmpty)
    }

    @Test func aMultilineReplyIsOpenUntilItsCodeRepeatsWithASpace() throws {
        var partial: [String] = []
        #expect(try FTPReplyAccumulator.feed("211-Features:", into: &partial) == nil)
        #expect(try FTPReplyAccumulator.feed(" MLSD", into: &partial) == nil)
        let reply = try #require(try FTPReplyAccumulator.feed("211 End", into: &partial))
        #expect(reply.code == 211)
        #expect(reply.lines == ["Features:", " MLSD", "End"])
        #expect(partial.isEmpty)
    }

    @Test func anInnerLineWhoseDigitsMatchDoesNotCloseTheReply() throws {
        // A server listing a file called "211 notes" inside a 211 block.
        var partial: [String] = []
        #expect(try FTPReplyAccumulator.feed("211-Features:", into: &partial) == nil)
        #expect(try FTPReplyAccumulator.feed("211-211 notes", into: &partial) == nil)
        let reply = try #require(try FTPReplyAccumulator.feed("211 End", into: &partial))
        #expect(reply.lines == ["Features:", "211-211 notes", "End"])
    }

    @Test func aBareInnerLineWithTheCodeAndASpaceIsTheCloser() throws {
        // The converse: "<code><space>" at the very start IS the closer, so
        // a file listed as "211 notes" without the dash prefix ends the reply.
        var partial: [String] = []
        #expect(try FTPReplyAccumulator.feed("211-Features:", into: &partial) == nil)
        let reply = try #require(try FTPReplyAccumulator.feed("211 notes", into: &partial))
        #expect(reply.lines == ["Features:", "notes"])
    }

    @Test func aContinuationLineMayBeAnything() throws {
        // Only "<code><space>" at the start of a line closes the reply; a
        // line of other digits, of plain prose or an empty one stays inside.
        var partial: [String] = []
        #expect(try FTPReplyAccumulator.feed("214-The following commands are recognized:", into: &partial) == nil)
        #expect(try FTPReplyAccumulator.feed("226 other code", into: &partial) == nil)
        #expect(try FTPReplyAccumulator.feed("hello", into: &partial) == nil)
        #expect(try FTPReplyAccumulator.feed("", into: &partial) == nil)
        #expect(try FTPReplyAccumulator.feed("2140 not the closer", into: &partial) == nil)
        let reply = try #require(try FTPReplyAccumulator.feed("214 Help OK.", into: &partial))
        #expect(reply.code == 214)
        #expect(reply.lines == [
            "The following commands are recognized:",
            "226 other code",
            "hello",
            "",
            "2140 not the closer",
            "Help OK.",
        ])
    }

    @Test func aCodeWithNoTextClosesAsAnEmptyLine() throws {
        var partial: [String] = []
        let reply = try #require(try FTPReplyAccumulator.feed("200", into: &partial))
        #expect(reply.code == 200)
        #expect(reply.lines == [""])
    }

    @Test func aSecondReplyStartsCleanAfterTheFirstCloses() throws {
        var partial: [String] = []
        _ = try FTPReplyAccumulator.feed("211-Features:", into: &partial)
        _ = try FTPReplyAccumulator.feed("211 End", into: &partial)
        let next = try #require(try FTPReplyAccumulator.feed("226 done", into: &partial))
        #expect(next.lines == ["done"])
    }

    @Test(arguments: [
        ("hello", FTPReplyError.Malformation.notThreeDigits),
        ("12 ready", .notThreeDigits),
        ("2200 ready", .badSeparator),
        ("22", .tooShort),
        ("", .tooShort),
        ("abc def", .notThreeDigits),
        ("000 zero", .notThreeDigits),
        ("2x0 odd", .notThreeDigits),
        ("220ready", .badSeparator),
        // Arabic-Indic digits: not ASCII, so not digits.
        ("\u{0662}\u{0662}\u{0660} ready", .notThreeDigits),
    ])
    func aLineThatIsNotAReplyIsRefusedRatherThanGuessed(line: String, why: FTPReplyError.Malformation) {
        var partial: [String] = []
        #expect(throws: FTPReplyError.notAReply(why, byteCount: line.utf8.count)) {
            try FTPReplyAccumulator.feed(line, into: &partial)
        }
        // Refusing a line leaves no half-open reply behind.
        #expect(partial.isEmpty)
    }

    @Test func aRefusalCarriesNoTextFromTheLine() {
        // A server may echo the client's command line, PASS included. The
        // marker stands in for such text; the Bool is computed first so a
        // failure report cannot print the marker either.
        let marker = "ECHOED-SECRET-MARKER"
        var partial: [String] = []
        var described = ""
        do {
            _ = try FTPReplyAccumulator.feed("PASS \(marker)", into: &partial)
        } catch {
            described = "\(error) \(String(reflecting: error))"
        }
        let refused = !described.isEmpty
        let leaked = described.contains(marker) || described.contains("PASS")
        #expect(refused)
        #expect(leaked == false)
    }

    @Test(arguments: [
        ["hello"],            // not a reply at all
        ["211 End"],          // a reply head, but a closer rather than an opener
        ["2110 odd", "more"], // not a head
    ])
    func anOpenReplyWithoutAValidOpenerIsDiscardedAndRefused(stored: [String]) {
        var partial = stored
        #expect(throws: FTPReplyError.notAReply(.unusableOpener, byteCount: stored[0].utf8.count)) {
            try FTPReplyAccumulator.feed("211 End", into: &partial)
        }
        // The documented exception to "a refusal leaves partial untouched":
        // a corrupt partial is dropped so the next line starts clean.
        #expect(partial.isEmpty)
    }

    @Test(arguments: [
        (150, true, false, false),
        (226, true, false, false),
        (331, true, false, false),
        (421, false, true, false),
        (550, false, false, true),
    ])
    func replyClassesFollowTheirLeadingDigit(
        code: Int, positive: Bool, transient: Bool, permanent: Bool
    ) {
        let reply = FTPReply(code: code, lines: ["x"])
        #expect(reply.isPositive == positive)
        #expect(reply.isTransient == transient)
        #expect(reply.isPermanent == permanent)
    }
}
