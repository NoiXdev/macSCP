import Foundation
import Testing

/// Guards `SessionRow`'s compact-mode wiring (sidebar-polish plan, Task 2,
/// re-anchored TWICE by coordinator ruling on 2026-09-04):
///
/// - the row must read `isCompact`;
/// - its two `.padding(.vertical, …)` densities must be exactly `2`
///   (compact) and `5` (default — unchanged from what the row was before
///   this setting existed), with no third value anywhere in the row;
/// - the protocol badge (`Text(kindBadgeLabel)`) must exist in the row AND
///   must never be wrapped by an `if !isCompact` gate — fix round 2's
///   ruling is that compact mode is the padding change ALONE, because the
///   badge ("ssh"/"s3"/"dav") is how a row reads its backend at a glance,
///   and hiding it in compact mode would make those rows ambiguous.
///
/// ## History of this suite's own anchors
///
/// Fix round 1's ruling: the DEFAULT row must not change at all. An
/// earlier attempt (Task 2's first commit) drew `connectionSummary` as a
/// second, always-visible line whenever `isCompact` was `false`; that line
/// is gone. `connectionSummary` reaches the user only through
/// `.help(connectionSummary)`, exactly as it did before Task 2 started —
/// nothing here re-checks that, since it was never part of Task 2's own
/// diff and this suite has no business scanning unrelated properties.
///
/// Fix round 1's fix then gated the protocol badge behind
/// `if !isCompact` (reading the plan's "kind badge kept" as having been
/// superseded by the ruling's own wording). Fix round 2's ruling reversed
/// that: the plan's file list said "the kind badge KEPT" all along, and
/// keeping it in both densities is what this suite now pins. So the
/// `if !isCompact` branch this suite once required around the badge is
/// now a branch the row must NOT contain at all.
///
/// Same shared scanner as `SettingsViewTransfersToggleGuardTests`
/// (`declarationBodyRange(of:in:)`/`declarationBody(of:in:)`/
/// `occurrenceCount(of:in:)`, all on `TransferQueueBarCancelGuardTests`),
/// reused rather than copied.
///
/// Every scan here reads the STRICT view (comments and string literals
/// blanked): `Text(kindBadgeLabel)` and `if !isCompact` are expressions,
/// not literals, so a comment that happened to quote either one verbatim
/// cannot be mistaken for the real thing (CLAUDE.md, "Source-scanning
/// guards read comments too").
///
/// Two of the checks below are NEGATIVE (no third padding value; no
/// `if !isCompact` anywhere in the row), so each is paired with a positive
/// anchor beside it (CLAUDE.md, "Guards that name what they watch"): the
/// row must actually contain `isCompact` at all, both padding values must
/// actually be present, and the badge view must actually exist in the row
/// -- otherwise a negative check would be satisfied by a row that dropped
/// the feature (or the badge) entirely, which is exactly the silent-pass
/// shape that rule warns about.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view -- nothing
/// here confirms the row actually measures shorter with `isCompact ==
/// true`, or that the padding literal really changes what macOS draws.
/// `SettingsStoreTests` pins `sidebarCompact`'s own round trip; nothing
/// pins the padding numbers themselves, which is a rendering fact no
/// source scan can see. And a row that gated the badge some OTHER way —
/// e.g. `.opacity(isCompact ? 0 : 1)` rather than `if !isCompact` — would
/// not be caught by the specific `if !isCompact` substring this suite
/// looks for; aimed at the accidental regression (re-adding the branch
/// fix round 1 wrote), not a hostile rewrite.
@Suite("SessionSidebar — compact row wiring")
struct SessionSidebarCompactRowGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sidebarFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static let rowDeclaration = "private struct SessionRow: View"
    /// The gate fix round 2's ruling forbids around the badge — and,
    /// since padding is the row's only sanctioned use of `isCompact`
    /// beyond reading it, forbids anywhere else in the row too.
    private static let compactGate = "if !isCompact"
    private static let badgeElement = "Text(kindBadgeLabel)"
    private static let verticalPaddingPrefix = ".padding(.vertical,"
    private static let compactPaddingValue = 2
    private static let defaultPaddingValue = 5

    private static func strictSource() throws -> String {
        let raw = try String(contentsOf: sidebarFile, encoding: .utf8)
        return try SwiftSource.blankingCommentsAndStrings(raw)
    }

    private static func rowBody() throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: try strictSource())
    }

    /// Every integer literal found across every `.padding(.vertical, …)`
    /// call in `body` — regardless of how many such calls there are, so a
    /// row split across two padding modifiers (or one rewritten with a
    /// second, stray call) is still read in full rather than only its
    /// first occurrence.
    private static func verticalPaddingValues(in body: String) -> [Int] {
        var values: [Int] = []
        var searchRange = body.startIndex..<body.endIndex
        while let prefixRange = body.range(of: Self.verticalPaddingPrefix, range: searchRange) {
            guard let closeParen = body.range(of: ")", range: prefixRange.upperBound..<body.endIndex)
            else { break }
            let argument = body[prefixRange.upperBound..<closeParen.lowerBound]
            for token in argument.split(whereSeparator: { !$0.isNumber }) {
                if let value = Int(token) { values.append(value) }
            }
            searchRange = closeParen.upperBound..<body.endIndex
        }
        return values
    }

    // MARK: - The guard

    /// Positive anchor 1: the row reads the setting at all. Without this, a
    /// row that dropped `isCompact` entirely (and so never varied the
    /// padding) would pass the checks below over nothing.
    @Test func theRowReadsTheCompactSetting() throws {
        let body = try Self.rowBody()
        #expect(body.contains("isCompact"), """
            SessionRow no longer reads isCompact -- compact mode (dictated \
            notes item 6) has been dropped from the row builder.
            """)
    }

    /// The padding halves: both densities present, and no unexplained
    /// third value -- the negative half is paired with the positive count
    /// right beside it, per CLAUDE.md's "guards that name what they watch".
    @Test func theRowsVerticalPaddingIsExactlyTheTwoDensitiesAndNothingElse() throws {
        let body = try Self.rowBody()
        let values = Self.verticalPaddingValues(in: body)
        #expect(values.contains(Self.compactPaddingValue), """
            SessionRow's .padding(.vertical, …) never contains \
            \(Self.compactPaddingValue) -- the compact density has been \
            lost or renumbered.
            """)
        #expect(values.contains(Self.defaultPaddingValue), """
            SessionRow's .padding(.vertical, …) never contains \
            \(Self.defaultPaddingValue) -- the DEFAULT row's padding \
            (unchanged from what it was before this setting existed) has \
            been lost or renumbered.
            """)
        let unexpected = Set(values).subtracting([Self.compactPaddingValue, Self.defaultPaddingValue])
        #expect(unexpected.isEmpty, """
            SessionRow's .padding(.vertical, …) also carries \
            \(unexpected.sorted()) -- fix round 2's ruling is explicit that \
            compact mode is a density change ONLY (2 instead of 5); a \
            third value means either a stray extra padding call or a \
            density this task never agreed to.
            """)
    }

    /// Positive anchor 2: the badge exists SOMEWHERE in the row body at
    /// all. Without this, a row that removed the badge entirely would also
    /// satisfy "never gated" trivially — dropping the badge is at least as
    /// serious a regression as hiding it in compact mode, and this guard
    /// must not read that as compliance.
    @Test func theBadgeExistsInTheRow() throws {
        let body = try Self.rowBody()
        #expect(body.contains(Self.badgeElement), """
            SessionRow no longer contains \(Self.badgeElement) -- the \
            protocol badge is gone from the row entirely. Fix round 2's \
            ruling requires it stay visible in BOTH densities: "how a row \
            reads its backend at a glance."
            """)
    }

    /// The negative half: the row must contain no `if !isCompact` gate at
    /// all -- fix round 2's ruling makes compact mode a padding change
    /// alone, so the badge (the row's only other secondary element) is
    /// never conditionally hidden, and neither is anything else keyed off
    /// `isCompact` beyond the padding ternary itself.
    @Test func theBadgeIsNeverWrappedByACompactGate() throws {
        let body = try Self.rowBody()
        #expect(!body.contains(Self.compactGate), """
            SessionRow contains `\(Self.compactGate)` -- fix round 2's \
            ruling is that compact mode changes the padding alone; a gate \
            keyed off `isCompact` (most likely wrapping \
            \(Self.badgeElement) again, as fix round 1's attempt did) \
            would hide something in compact mode that must stay visible.
            """)
    }

    /// Positive anchor for every check above: the strict view must actually
    /// be reaching the row's own declaration, or an unreadable/empty read
    /// would make the `contains` checks pass trivially over nothing.
    @Test func theStrictViewStillContainsTheRowDeclaration() throws {
        let code = try Self.strictSource()
        #expect(code.contains(Self.rowDeclaration), """
            the strict view of SessionSidebar.swift no longer contains \
            SessionRow's own declaration -- the stripper or the path is \
            wrong, and the checks above are reading something other than \
            the row they name.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func theSelfTestNeedlesAreThingsTheRealFileActuallyContains() throws {
        let body = try Self.rowBody()
        #expect(body.contains("isCompact"))
        #expect(body.contains(Self.badgeElement))
        let values = Self.verticalPaddingValues(in: body)
        #expect(values.contains(Self.compactPaddingValue))
        #expect(values.contains(Self.defaultPaddingValue))
        // The mirror of the needle checks above: `compactGate` names
        // something the real row must NOT contain, so its own self-test is
        // the negative check itself (already exercised by
        // `theBadgeIsNeverWrappedByACompactGate`) -- asserting its absence
        // here again would just duplicate that test.
    }

    /// Mutation probe: a badge wrapped in `if !isCompact` (fix round 1's
    /// exact shape, reintroduced by mistake) must be reported as a
    /// violation.
    @Test func scannerSeesTheBadgeGatedByCompactAgain() throws {
        let source = """
            \(Self.rowDeclaration) {
                let isCompact: Bool
                var body: some View {
                    HStack(spacing: 8) {
                        Text(session.name)
                        if !isCompact {
                            Text(kindBadgeLabel)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                    .padding(.vertical, isCompact ? 2 : 5)
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: code)
        // Positive first: the badge really is present, so the negative
        // below reports the gate specifically, not an empty read.
        #expect(body.contains(Self.badgeElement))
        #expect(body.contains(Self.compactGate), """
            the scanner must report a badge wrapped in `if !isCompact` as a \
            violation, not accept it because the badge itself is present
            """)
    }

    /// The compliant shape it must not flag: the badge present, unwrapped,
    /// alongside the padding ternary (which legitimately mentions
    /// `isCompact` without gating anything).
    @Test func scannerAcceptsTheBadgeUngated() throws {
        let source = """
            \(Self.rowDeclaration) {
                let isCompact: Bool
                var body: some View {
                    HStack(spacing: 8) {
                        Text(session.name)
                        Text(kindBadgeLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.vertical, isCompact ? 2 : 5)
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: code)
        #expect(body.contains(Self.badgeElement))
        #expect(!body.contains(Self.compactGate))
    }

    /// Mutation probe for the padding check: a genuine third VERTICAL
    /// padding value alongside the two densities (a second
    /// `.padding(.vertical, …)` call, the shape a "helpful" extra
    /// adjustment would take) must be flagged, not accepted because both
    /// real values are also present.
    @Test func scannerSeesAThirdVerticalPaddingValueAlongsideTheTwoDensities() throws {
        let source = """
            HStack {
                Text("hi")
            }
            .padding(.vertical, isCompact ? 2 : 5)
            .padding(.vertical, 8)
            """
        let values = Self.verticalPaddingValues(in: source)
        // Positive first: both real densities are present, so the negative
        // below reports the stray value specifically.
        #expect(values.contains(Self.compactPaddingValue))
        #expect(values.contains(Self.defaultPaddingValue))
        let unexpected = Set(values).subtracting([Self.compactPaddingValue, Self.defaultPaddingValue])
        #expect(!unexpected.isEmpty, """
            the scanner must flag a second `.padding(.vertical, …)` call \
            carrying a value neither density names, not accept it because \
            the first call already carries both real densities
            """)
    }

    /// The scanner's own honesty check: a HORIZONTAL padding call's digits
    /// must never be mistaken for a vertical one just because both numbers
    /// sit near each other in the source -- the prefix match is
    /// `.padding(.vertical,`, never a bare `.padding(`.
    @Test func scannerIgnoresPaddingThatIsNotVertical() throws {
        let source = """
            .padding(.vertical, isCompact ? 2 : 5)
            .padding(.horizontal, isCompact ? 3 : 9)
            """
        let values = Self.verticalPaddingValues(in: source)
        #expect(Set(values) == Set([Self.compactPaddingValue, Self.defaultPaddingValue]), """
            the scanner must read digits ONLY out of \
            .padding(.vertical, …) calls -- \(values) suggests it also \
            picked up the horizontal call's 3/9
            """)
    }

    /// And the compliant shape it must not flag: exactly the two densities,
    /// however many `.padding(.vertical, …)` calls carry them.
    @Test func scannerAcceptsExactlyTheTwoDensitiesAcrossMultipleCalls() throws {
        let source = """
            .padding(.vertical, isCompact ? 2 : 5)
            .padding(.top, 3)
            .padding(.vertical, isCompact ? 2 : 5)
            """
        let values = Self.verticalPaddingValues(in: source)
        let unexpected = Set(values).subtracting([Self.compactPaddingValue, Self.defaultPaddingValue])
        #expect(unexpected.isEmpty)
    }

    @Test func scannerFailsClosedWhenTheRowIsGone() {
        let source = "struct SomethingElse: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.rowDeclaration, in: source)
        }
    }
}
