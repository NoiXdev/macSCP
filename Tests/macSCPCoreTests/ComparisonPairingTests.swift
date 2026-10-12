import Testing
@testable import macSCPCore

private func item(
    _ name: String, kind: RemoteFileKind = .file, size: UInt64? = 10
) -> RemoteFileItem {
    RemoteFileItem(
        name: name, path: "/x/" + name, kind: kind, size: size,
        modifiedAt: nil, permissions: nil, owner: nil, group: nil)
}

@Suite struct ComparisonPairingTests {
    @Test func aNameOnOneSideOnlyIsPairedWithNothing() {
        let pairs = ComparisonPairing.pairs(left: [item("a")], right: [item("b")])
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.name == "a" && $0.right == nil })
        #expect(pairs.contains { $0.name == "b" && $0.left == nil })
    }

    @Test func aNameOnBothSidesIsOnePair() {
        let pairs = ComparisonPairing.pairs(left: [item("a")], right: [item("a")])
        #expect(pairs.count == 1)
        #expect(pairs[0].left != nil && pairs[0].right != nil)
    }

    /// Review Focus 1. macOS hands back NFD for a local name; a server
    /// usually stored NFC. Both spellings are the same file to a person.
    @Test func namesThatDifferOnlyByUnicodeNormalizationArePairedTogether() {
        let composed = item("\u{00E4}")             // ä
        let decomposed = item("a\u{0308}")          // a + combining diaeresis
        let pairs = ComparisonPairing.pairs(left: [decomposed], right: [composed])
        #expect(pairs.count == 1)
        #expect(pairs[0].left != nil && pairs[0].right != nil)
    }

    /// Review Focus 4. Two remote names that a case-insensitive local side
    /// cannot tell apart must BOTH survive the pairing — dropping one would
    /// hide a file from the comparison.
    @Test func twoNamesDifferingOnlyInCaseBothSurvive() {
        let pairs = ComparisonPairing.pairs(
            left: [item("README")], right: [item("README"), item("readme")])
        #expect(pairs.count == 2)
        #expect(pairs.filter { $0.right != nil }.count == 2)
    }

    @Test func pairsAreOrderedByNameSoTheViewIsStable() {
        let pairs = ComparisonPairing.pairs(
            left: [item("b"), item("a")], right: [])
        #expect(pairs.map(\.name) == ["a", "b"])
    }

    /// The UTF-8 bytes of a name. Swift's `String` equality and hashing are
    /// canonical equivalence, so these are the only faithful way to say
    /// "the same spelling" in an assertion.
    private func bytes(_ name: String) -> [UInt8] { Array(name.utf8) }

    /// Regression. Two distinct files on one side, spelled NFC and NFD, must
    /// both survive; keying a map on the normalized form merged them.
    @Test func twoSpellingsOfOneNameOnOneSideBothSurvive() {
        let pairs = ComparisonPairing.pairs(
            left: [item("\u{00E4}"), item("a\u{0308}")], right: [])
        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.right == nil })
        #expect(Set(pairs.map { bytes($0.name) }).count == 2)
    }

    /// An exact match is never ambiguous, so it wins over a normalization
    /// match. Here the decomposed left name must pair with the decomposed
    /// right name, and the composed right name stays one-sided.
    @Test func anExactNameMatchWinsOverANormalizationMatch() {
        let pairs = ComparisonPairing.pairs(
            left: [item("a\u{0308}")],
            right: [item("a\u{0308}"), item("\u{00E4}")])
        #expect(pairs.count == 2)
        let both = pairs.filter { $0.left != nil && $0.right != nil }
        #expect(both.count == 1)
        #expect(both.first?.right.map { bytes($0.name) } == bytes("a\u{0308}"))
        #expect(pairs.contains { $0.left == nil && $0.right.map { bytes($0.name) } == bytes("\u{00E4}") })
    }

    /// Two distinct remote files that are canonically equivalent to one local
    /// name form an ambiguous group. Pairing them would be a guess about which
    /// one maps to the local file, so all three stay one-sided.
    @Test func anAmbiguousNormalizationGroupIsLeftUnpairedNotGuessed() {
        let pairs = ComparisonPairing.pairs(
            left: [item("a\u{0323}\u{0308}")],
            right: [item("a\u{0308}\u{0323}"), item("\u{1EA1}\u{0308}")])
        #expect(pairs.count == 3)
        #expect(pairs.allSatisfy { $0.left == nil || $0.right == nil })
    }
}
