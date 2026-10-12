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
}
