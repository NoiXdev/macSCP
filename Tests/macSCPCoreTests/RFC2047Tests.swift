import Foundation
import Testing

@testable import macSCPCore

/// `RFC2047` puts a custom metadata value on the wire as pure ASCII and reads
/// it back. The review focus numbers in the comments below are those of the
/// plan these tests were written for.
@Suite struct RFC2047Tests {
    @Test func anASCIIValueIsReturnedUnchanged() {
        #expect(RFC2047.encodedWord("max-age=60, must-revalidate")
            == "max-age=60, must-revalidate")
        #expect(RFC2047.encodedWord("") == "")
        #expect(RFC2047.encodedWord("   ") == "   ")
    }

    @Test func aNonASCIIValueBecomesOneBase64EncodedWord() {
        #expect(RFC2047.encodedWord("Jahresübersicht")
            == "=?UTF-8?B?SmFocmVzw7xiZXJzaWNodA==?=")
    }

    @Test func anEncodedWordDecodesToTheBytesItCarries() {
        #expect(RFC2047.decoded("=?UTF-8?B?SmFocmVzw7xiZXJzaWNodA==?=")
            == "Jahresübersicht")
    }

    @Test func theQEncodingIsDecodedToo() {
        #expect(RFC2047.decoded("=?UTF-8?Q?Jahres=C3=BCbersicht?=") == "Jahresübersicht")
        #expect(RFC2047.decoded("=?UTF-8?Q?a_b?=") == "a b")
    }

    @Test func adjacentEncodedWordsAreJoined() {
        #expect(RFC2047.decoded("=?UTF-8?B?SmFocmVz?= =?UTF-8?B?w7xiZXJzaWNodA==?=")
            == "Jahresübersicht")
    }

    /// Review Focus 2: a store that answers with the raw value, and any value
    /// that is simply not an encoded word, survives the decoder untouched.
    /// What text raw non-ASCII header bytes become before they reach the
    /// decoder is the transport's step, and it is unmeasured.
    @Test func anythingThatIsNotAnEncodedWordPassesThrough() {
        #expect(RFC2047.decoded("Jahresübersicht") == "Jahresübersicht")
        #expect(RFC2047.decoded("attachment; filename=\"report.pdf\"")
            == "attachment; filename=\"report.pdf\"")
        #expect(RFC2047.decoded("=?UTF-8?B?not valid base64!?=")
            == "=?UTF-8?B?not valid base64!?=")
        #expect(RFC2047.decoded("=?SHIFT_JIS?B?gqA=?=") == "=?SHIFT_JIS?B?gqA=?=")
    }

    /// Review Focus 1: what the person typed comes back, even when what they
    /// typed looks like an encoded word. The encoder treats it as text.
    @Test func aValueThatLooksLikeAnEncodedWordRoundTripsLiterally() {
        let typed = "=?UTF-8?B?SGk=?="
        let round = RFC2047.decoded(RFC2047.encodedWord(typed))
        #expect(round == typed)
    }

    /// Review Focus 4: one word of any length, and the round trip holds.
    @Test func aLongValueRoundTrips() {
        let typed = String(repeating: "übersicht-日本語-", count: 40)
        #expect(RFC2047.decoded(RFC2047.encodedWord(typed)) == typed)
    }

    /// The encoder's output is pure ASCII for every input, including an
    /// ASCII input that only looks like an encoded word. The Bool is computed
    /// first so a failing run does not print the value.
    @Test func theEncodedFormIsAlwaysPureASCII() {
        for typed in ["Jahresübersicht", "=?UTF-8?B?SGk=?=", "a =? b", "日本語"] {
            let ascii = RFC2047.encodedWord(typed).unicodeScalars.allSatisfy { $0.value < 0x80 }
            #expect(ascii)
        }
    }

    /// A leading U+FEFF is part of the text, not a byte-order mark to strip.
    /// The sheet's trim keeps it, so a pasted value can start with one; a
    /// decoder that dropped it would make the read-back disagree with what
    /// was typed. Both the base64 and the quoted-printable path are checked,
    /// and each expectation is a precomputed `Bool` so a failing run does not
    /// print the value.
    @Test func aLeadingByteOrderMarkSurvivesTheRoundTrip() {
        let typed = "\u{FEFF}M\u{00FC}ller"
        let viaEncoder = RFC2047.decoded(RFC2047.encodedWord(typed)) == typed
        #expect(viaEncoder)
        let viaQ = RFC2047.decoded("=?UTF-8?Q?=EF=BB=BFabc?=") == "\u{FEFF}abc"
        #expect(viaQ)
        let aloneInTheWord = RFC2047.decoded("=?UTF-8?B?77u/?=") == "\u{FEFF}"
        #expect(aloneInTheWord)
    }

    /// An ASCII value that merely contains the two-character opener, without
    /// being a word, is encoded and comes back as typed.
    @Test func anASCIIValueWithAStrayOpenerRoundTripsAsTyped() {
        let typed = "a =? b"
        let round = RFC2047.decoded(RFC2047.encodedWord(typed)) == typed
        #expect(round)
    }

    /// The base64 half of "the payload does not decode": a payload that is
    /// not base64 at all, as opposed to one that decodes to invalid UTF-8
    /// (the `/w==` case in `aMalformedWordDoesNotSpoilItsNeighbours`).
    @Test func aPayloadThatIsNotBase64StaysUndecoded() {
        #expect(RFC2047.decoded("=?UTF-8?B?!!!!?=") == "=?UTF-8?B?!!!!?=")
    }

    /// Text between two words is kept; only whitespace-only gaps vanish.
    @Test func textBetweenEncodedWordsIsKeptVerbatim() {
        #expect(RFC2047.decoded("=?UTF-8?Q?a?= and =?UTF-8?Q?b?=") == "a and b")
        #expect(RFC2047.decoded("x =?UTF-8?Q?a?= y") == "x a y")
    }

    /// The charset and the encoding letter are matched without regard to case.
    @Test func charsetAndEncodingAreCaseInsensitive() {
        #expect(RFC2047.decoded("=?utf-8?b?SGk=?=") == "Hi")
        #expect(RFC2047.decoded("=?utf-8?q?H=69?=") == "Hi")
    }

    /// A word that does not decode stays as it stands, and a later good word
    /// still decodes.
    @Test func aMalformedWordDoesNotSpoilItsNeighbours() {
        #expect(RFC2047.decoded("=?UTF-8?X?SGk=?= =?UTF-8?B?SGk=?=")
            == "=?UTF-8?X?SGk=?= Hi")
        #expect(RFC2047.decoded("=?UTF-8?Q?bad=ZZ?=") == "=?UTF-8?Q?bad=ZZ?=")
        #expect(RFC2047.decoded("=?UTF-8?B?/w==?=") == "=?UTF-8?B?/w==?=")
        #expect(RFC2047.decoded("=?") == "=?")
    }
}
