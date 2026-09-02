import Foundation
import Testing

/// Guards the "Generate SSH Key" sheet's `keys.notConnectable` caption
/// against regressing to a literal `KeyTypeChoice` comparison (found by
/// review, 2026-09-02: `SSHKeysSheet.swift:607` read `typeChoice !=
/// .ed25519` — the pre-Task-5 predicate, spelled out by hand — instead of
/// asking `resolvedType.isConnectable`, so the caption kept telling users a
/// freshly generated RSA or ECDSA key was "not usable as a macSCP login"
/// after `KeyType.isConnectable` had already started saying otherwise for
/// both).
///
/// This is a source scan, not a rendered check, for the same reason
/// `SheetFacetWiringGuardTests` is one: this project renders no view in a
/// test. `SheetFacetWiringGuardTests` itself does not cover this — it scans
/// `SSHKeysSheet.swift` only for facet wiring (`SheetFacetPicker(`,
/// `.narrowing(`, `SheetListEmptyState(`, `searchText.isEmpty`), never for
/// this caption or its guard.
@Suite("Generate key caption wiring")
struct GenerateKeyCaptionWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/GenerateKeyCaptionWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sheetSourceFile =
        repoRoot.appendingPathComponent("Sources/MacSCPAppKit/SSHKeysSheet.swift")

    private static func strippedSource() throws -> String {
        SheetFacetWiringGuardTests.strippingLineComments(
            try String(contentsOf: sheetSourceFile, encoding: .utf8))
    }

    /// Every range of the catalog-key literal in `source`, in order.
    /// `SSHKeysSheet.swift` draws the same caption from two places (the
    /// key-list row and the "Generate SSH Key" sheet), so a scan that only
    /// found the FIRST occurrence would check the row's guard — already
    /// correct before this task — and never reach the generate sheet's,
    /// which is where the review found the bug.
    private static func occurrences(of needle: String, in source: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while let found = source.range(of: needle, range: searchStart..<source.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound
        }
        return ranges
    }

    /// Positive anchor for the test below: without it, a sheet that dropped
    /// the caption entirely (catalog key and all) would satisfy a scan that
    /// only checked for the ABSENCE of `.ed25519` in its guard — an empty
    /// file passes a check that finds nothing to complain about.
    @Test func theNotConnectableCaptionIsStillDrawn() throws {
        let source = try Self.strippedSource()
        #expect(source.contains("\"keys.notConnectable\""), """
            SSHKeysSheet.swift no longer references the \
            "keys.notConnectable" catalog key — either the caption was \
            removed (fine on its own, but then this guard has nothing left \
            to check) or its string literal changed (then this guard's \
            anchor needs updating to the new one).
            """)
    }

    /// The negative check this guard exists for: EVERY `if` guarding a
    /// "keys.notConnectable" reference must read the resolved type's
    /// `isConnectable`, not repeat the old ed25519-only predicate by hand.
    /// Paired with the positive anchor above per this project's rule that a
    /// negative check needs a positive one beside it.
    @Test func theCaptionsGuardsReadIsConnectableRatherThanRepeatingTheOldPredicate() throws {
        let source = try Self.strippedSource()
        let keyOccurrences = Self.occurrences(of: "\"keys.notConnectable\"", in: source)
        #expect(!keyOccurrences.isEmpty, "keys.notConnectable not found — see theNotConnectableCaptionIsStillDrawn")

        for keyRange in keyOccurrences {
            let before = source[source.startIndex..<keyRange.lowerBound]
            guard let ifRange = before.range(of: "if ", options: .backwards) else {
                Issue.record("""
                    No `if ` found before one of the "keys.notConnectable" references \
                    in SSHKeysSheet.swift — that caption is no longer conditionally \
                    drawn, or its guarding `if` moved further away than this scan looks.
                    """)
                continue
            }
            let guardClause = String(source[ifRange.lowerBound..<keyRange.lowerBound])
            #expect(guardClause.contains("isConnectable"), """
                An `if` guarding a "keys.notConnectable" caption in \
                SSHKeysSheet.swift does not mention `isConnectable`:
                \(guardClause)
                It should read `KeyType.isConnectable` off the resolved type \
                rather than deciding some other way.
                """)
            #expect(!guardClause.contains(".ed25519"), """
                An `if` guarding a "keys.notConnectable" caption in \
                SSHKeysSheet.swift names a specific `KeyTypeChoice` case by hand:
                \(guardClause)
                That is the predicate this guard exists to catch — it was true \
                only while ed25519 was the sole connectable type, and it no \
                longer agrees with `KeyType.isConnectable`.
                """)
        }
    }
}
