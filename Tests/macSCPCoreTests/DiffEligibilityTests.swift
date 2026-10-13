import Testing
@testable import macSCPCore

@Suite struct DiffEligibilityTests {
    /// `count` copies of "A", with a NUL written at `nulAt` when given.
    private func ascii(_ count: Int, nulAt: Int? = nil) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x41, count: count)
        if let nulAt { bytes[nulAt] = 0x00 }
        return bytes
    }

    // MARK: - Eligible content

    @Test func plainTextIsEligible() {
        #expect(DiffEligibility.refusal(forBytes: Array("hello\nworld\n".utf8)) == nil)
    }

    @Test func anEmptyFileIsEligible() {
        #expect(DiffEligibility.refusal(forBytes: []) == nil)
    }

    /// Valid UTF-8 that is not ASCII must not be taken for binary: accented
    /// text, CJK, an emoji (four bytes), and a leading byte order mark.
    @Test(arguments: [
        "caf\u{E9}\n",
        "\u{65E5}\u{672C}\u{8A9E}\n",
        "ship it \u{1F680}\n",
        "\u{FEFF}first line behind a byte order mark\n",
    ])
    func validNonASCIITextIsEligible(_ text: String) {
        #expect(DiffEligibility.refusal(forBytes: Array(text.utf8)) == nil)
    }

    // MARK: - The NUL window

    // These tests spell the window's size as the literals 7999, 8000 and 8001
    // on purpose. The number is git's, and a test that read it back from the
    // implementation would move with it and notice nothing.

    @Test func aNulByteAsTheLastByteOfTheFirst8000IsBinary() {
        #expect(DiffEligibility.refusal(forBytes: ascii(8000, nulAt: 7999)) == .binary)
    }

    @Test func aNulByteAt7999WithMoreContentAfterItIsBinary() {
        #expect(DiffEligibility.refusal(forBytes: ascii(8002, nulAt: 7999)) == .binary)
    }

    /// The boundary from the other side: byte 8000 is the first one git's
    /// heuristic does not look at, and neither does this. The NUL is valid
    /// UTF-8, so nothing else refuses the content either.
    @Test func aNulByteAtIndex8000IsNotBinaryByThisRule() {
        #expect(DiffEligibility.refusal(forBytes: ascii(8001, nulAt: 8000)) == nil)
        #expect(DiffEligibility.refusal(forBytes: ascii(8002, nulAt: 8000)) == nil)
    }

    @Test func aNulByteAtIndex8001IsNotBinaryByThisRule() {
        #expect(DiffEligibility.refusal(forBytes: ascii(8002, nulAt: 8001)) == nil)
    }

    @Test func aNulByteAtTheStartIsBinary() {
        #expect(DiffEligibility.refusal(forBytes: ascii(10, nulAt: 0)) == .binary)
    }

    /// Beside the three window tests above: the window limits only the NUL
    /// rule. Bytes that are not valid UTF-8 refuse the content wherever they
    /// sit, so a file whose first NUL is late is still refused, as not UTF-8.
    @Test func invalidUTF8PastTheWindowIsStillRefusedAsNotUTF8() {
        var bytes = ascii(9000)
        bytes[8500] = 0xFF
        #expect(DiffEligibility.refusal(forBytes: bytes) == .notUTF8)
    }

    // MARK: - The two causes are kept apart

    /// Text in a single-byte encoding is the common case behind a UTF-8
    /// failure, and it is text: it must not be reported as binary.
    @Test(arguments: [
        ("Latin-1 'caf\u{E9}'", [0x63, 0x61, 0x66, 0xE9, 0x0A]),
        ("Windows-1252 curly quotes", [0x93, 0x68, 0x69, 0x94, 0x0A]),
    ] as [(String, [UInt8])])
    func textInASingleByteEncodingIsNotUTF8AndNotBinary(_ label: String, _ bytes: [UInt8]) {
        #expect(DiffEligibility.refusal(forBytes: bytes) == .notUTF8, "\(label)")
        #expect(DiffEligibility.refusal(forBytes: bytes) != .binary, "\(label)")
    }

    /// Beside it: a NUL in valid UTF-8 is the binary cause, and it is not
    /// reported as an encoding problem.
    @Test func aNulInOtherwiseValidUTF8IsBinaryAndNotNotUTF8() {
        let bytes = Array("caf\u{E9}".utf8) + [0x00] + Array("\n".utf8)
        #expect(DiffEligibility.refusal(forBytes: bytes) == .binary)
        #expect(DiffEligibility.refusal(forBytes: bytes) != .notUTF8)
    }

    /// Content with both a NUL in the window and invalid bytes is reported by
    /// the earlier check, which is the NUL rule.
    @Test func aNulInTheWindowWinsOverInvalidBytes() {
        #expect(DiffEligibility.refusal(forBytes: [0xE9, 0x00]) == .binary)
        #expect(DiffEligibility.refusal(forBytes: [0x00, 0xE9]) == .binary)
    }

    // MARK: - UTF-8 validity

    /// Each of these is a distinct way to be invalid, and each is the
    /// complete content of the file.
    @Test(arguments: [
        ("a lone continuation byte", [0x80]),
        ("a continuation byte after ASCII", [0x41, 0xBF]),
        ("a lead byte followed by ASCII", [0xC3, 0x28]),
        ("a two-byte sequence cut off at the end", [0x41, 0xC3]),
        ("a three-byte sequence cut off after one byte", [0x41, 0xE2]),
        ("a three-byte sequence cut off after two bytes", [0x41, 0xE2, 0x82]),
        ("a four-byte sequence cut off after three bytes", [0x41, 0xF0, 0x9F, 0x98]),
        ("an overlong two-byte NUL", [0xC0, 0x80]),
        ("an overlong two-byte slash", [0xC1, 0xBF]),
        ("an overlong three-byte NUL", [0xE0, 0x80, 0x80]),
        ("an overlong four-byte NUL", [0xF0, 0x80, 0x80, 0x80]),
        ("a high surrogate half", [0xED, 0xA0, 0x80]),
        ("a low surrogate half", [0xED, 0xBF, 0xBF]),
        ("a scalar above U+10FFFF", [0xF4, 0x90, 0x80, 0x80]),
        ("a lead byte that can never occur", [0xF5, 0x80, 0x80, 0x80]),
        ("the byte 0xFF", [0xFF]),
    ] as [(String, [UInt8])])
    func invalidUTF8IsNotUTF8(_ label: String, _ bytes: [UInt8]) {
        #expect(DiffEligibility.refusal(forBytes: bytes) == .notUTF8, "\(label)")
    }

    /// Beside the invalid table: the complete sequences at the edges that
    /// table rejects from the other side, so a validator that refused every
    /// multi-byte sequence would fail here rather than pass the table above.
    @Test(arguments: [
        ("the smallest two-byte scalar, U+0080", [0xC2, 0x80]),
        ("an accented letter, U+00E9", [0xC3, 0xA9]),
        ("the smallest three-byte scalar, U+0800", [0xE0, 0xA0, 0x80]),
        ("the euro sign, U+20AC", [0xE2, 0x82, 0xAC]),
        ("the scalar just below the surrogates, U+D7FF", [0xED, 0x9F, 0xBF]),
        ("the scalar just above the surrogates, U+E000", [0xEE, 0x80, 0x80]),
        ("the smallest four-byte scalar, U+10000", [0xF0, 0x90, 0x80, 0x80]),
        ("an emoji, U+1F600", [0xF0, 0x9F, 0x98, 0x80]),
        ("the largest scalar, U+10FFFF", [0xF4, 0x8F, 0xBF, 0xBF]),
    ] as [(String, [UInt8])])
    func completeSequencesAtTheEdgesAreEligible(_ label: String, _ bytes: [UInt8]) {
        #expect(DiffEligibility.refusal(forBytes: bytes) == nil, "\(label)")
    }

    /// The truncation that matters most in practice: a download or a read cut
    /// off in the middle of a character, at the very end of a large buffer.
    @Test func aMultiByteSequenceCutOffAtTheEndOfALargeBufferIsNotUTF8() {
        let whole = ascii(100_000) + [0xE2, 0x82, 0xAC]
        #expect(DiffEligibility.refusal(forBytes: whole) == nil)

        let cut = ascii(100_000) + [0xE2, 0x82]
        #expect(DiffEligibility.refusal(forBytes: cut) == .notUTF8)
    }

    // MARK: - The ceiling

    @Test func theCeilingRefusesAboveItAndAdmitsAtIt() {
        let atCeiling = ascii(DiffEligibility.ceilingBytes)
        #expect(DiffEligibility.refusal(forBytes: atCeiling) == nil)

        let overCeiling = ascii(DiffEligibility.ceilingBytes + 1)
        #expect(overCeiling.count > DiffEligibility.ceilingBytes)
        #expect(
            DiffEligibility.refusal(forBytes: overCeiling)
                == .tooLarge(
                    bytes: DiffEligibility.ceilingBytes + 1,
                    ceiling: DiffEligibility.ceilingBytes))
    }

    /// The window tests above build buffers of up to 8002 bytes. If the
    /// ceiling ever fell below that they would go red as `.tooLarge`, each
    /// for an unrelated-looking reason; this names that regression once.
    @Test func theCeilingIsLargerThanTheNulWindow() {
        #expect(DiffEligibility.ceilingBytes > 8002)
    }

    // MARK: - Which refusal wins

    /// Size is checked first: it is the cheaper fact (no byte is read) and
    /// the one the user can act on, and an oversized file is never scanned.
    @Test func anOversizedFileIsReportedAsTooLargeNotItsOtherCause() {
        let nulFirst = ascii(DiffEligibility.ceilingBytes + 1, nulAt: 0)
        #expect(
            DiffEligibility.refusal(forBytes: nulFirst)
                == .tooLarge(
                    bytes: DiffEligibility.ceilingBytes + 1,
                    ceiling: DiffEligibility.ceilingBytes))

        var notUTF8 = ascii(DiffEligibility.ceilingBytes + 1)
        notUTF8[notUTF8.count - 1] = 0xFF
        #expect(
            DiffEligibility.refusal(forBytes: notUTF8)
                == .tooLarge(
                    bytes: DiffEligibility.ceilingBytes + 1,
                    ceiling: DiffEligibility.ceilingBytes))
    }

    /// Beside the order test: at the ceiling itself the same content is
    /// refused for its own cause, so the test above is about the order and
    /// not about the content having been accepted.
    @Test func theSameContentAtTheCeilingIsRefusedForItsOwnCause() {
        let nulFirst = ascii(DiffEligibility.ceilingBytes, nulAt: 0)
        #expect(DiffEligibility.refusal(forBytes: nulFirst) == .binary)

        var notUTF8 = ascii(DiffEligibility.ceilingBytes)
        notUTF8[notUTF8.count - 1] = 0xFF
        #expect(DiffEligibility.refusal(forBytes: notUTF8) == .notUTF8)
    }
}
