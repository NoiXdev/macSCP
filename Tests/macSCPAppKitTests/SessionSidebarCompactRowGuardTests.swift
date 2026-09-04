import Foundation
import Testing

/// Guards `SessionRow`'s compact-mode wiring (sidebar-polish plan, Task 2,
/// re-anchored in the fix round that reopened this task, coordinator
/// ruling 2026-09-04): the row must read `isCompact`, its two
/// `.padding(.vertical, …)` densities must be exactly `2` (compact) and `5`
/// (default — unchanged from what the row was before this setting
/// existed) with no third value anywhere in the row, and the one
/// secondary element compact sheds — the protocol badge
/// (`Text(kindBadgeLabel)`) — must sit ONLY inside the `if !isCompact`
/// branch.
///
/// The ruling that reopened this task is explicit that the DEFAULT row
/// must not change at all. An earlier attempt drew `connectionSummary` as
/// a second, always-visible line whenever `isCompact` was `false` — this
/// suite originally guarded THAT shape. It is rewritten here because that
/// shape is gone: the row has no secondary element beyond the protocol
/// badge once the subtitle attempt was reverted, so the badge is what
/// `isCompact` now gates. `connectionSummary` itself is untouched — it
/// still reaches the user only through `.help(connectionSummary)`, exactly
/// as it did before this task, and nothing here re-checks that (it was
/// never part of Task 2's own diff).
///
/// Same shared scanner as `SettingsViewTransfersToggleGuardTests`
/// (`declarationBodyRange(of:in:)`/`declarationBody(of:in:)`/
/// `occurrenceCount(of:in:)`, all on `TransferQueueBarCancelGuardTests`),
/// reused rather than copied. `declarationBodyRange` balances the first `{`
/// found after ANY needle, not just a struct/function declaration -- it
/// works unchanged over `"if !isCompact"` the same way it works over a
/// struct's own name.
///
/// Every scan here reads the STRICT view (comments and string literals
/// blanked): `Text(kindBadgeLabel)` is an expression, not a literal, so a
/// comment that happened to quote it verbatim cannot be mistaken for the
/// real call (CLAUDE.md, "Source-scanning guards read comments too").
///
/// Two of the checks below are NEGATIVE (no third padding value; the badge
/// never appears outside the branch), so each is paired with a positive
/// anchor beside it (CLAUDE.md, "Guards that name what they watch"): the
/// row must actually contain `isCompact` at all, both padding values must
/// actually be present, and the badge view must actually exist somewhere
/// in the row -- otherwise a negative check would be satisfied by a row
/// that dropped the feature (or the badge) entirely, which is exactly the
/// silent-pass shape that rule warns about.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view -- nothing
/// here confirms the row actually measures shorter with `isCompact ==
/// true`, or that the padding literal really changes what macOS draws.
/// `SettingsStoreTests` pins `sidebarCompact`'s own round trip; nothing
/// pins the padding numbers themselves, which is a rendering fact no
/// source scan can see.
@Suite("SessionSidebar — compact row wiring")
struct SessionSidebarCompactRowGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sidebarFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static let rowDeclaration = "private struct SessionRow: View"
    private static let compactBranch = "if !isCompact"
    /// The one secondary element the default row carries, and the one
    /// `isCompact` sheds — see this suite's doc comment for why it is the
    /// badge and not a subtitle line.
    private static let gatedElement = "Text(kindBadgeLabel)"
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
    /// row that dropped `isCompact` entirely (and so never gated the badge
    /// or varied the padding) would pass the checks below over nothing.
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
            \(unexpected.sorted()) -- the ruling that reopened this task is \
            explicit that compact mode is a density change ONLY (2 instead \
            of 5); a third value means either a stray extra padding call or \
            a density this task never agreed to.
            """)
    }

    /// Positive anchor 2: the gated element exists SOMEWHERE in the row
    /// body at all. Without this, a row that removed the badge entirely
    /// would also satisfy "not outside the branch" trivially.
    @Test func theGatedElementExistsInTheRow() throws {
        let body = try Self.rowBody()
        #expect(body.contains(Self.gatedElement), """
            SessionRow no longer contains \(Self.gatedElement) -- the \
            protocol badge is gone from the row entirely, not merely \
            hidden in compact mode. (If the row now carries no secondary \
            element at all, compact mode is padding-only and this guard \
            needs re-anchoring to say so explicitly, per the ruling that \
            reopened this task.)
            """)
    }

    /// The negative half: every occurrence of the gated element in the row
    /// must sit inside the `if !isCompact` branch -- none outside it, where
    /// it would draw regardless of the setting and defeat compact mode.
    @Test func theGatedElementSitsOnlyInsideTheNonCompactBranch() throws {
        let body = try Self.rowBody()
        let total = TransferQueueBarCancelGuardTests.occurrenceCount(of: Self.gatedElement, in: body)
        // Restates the positive anchor above as a count, so the comparison
        // below cannot be satisfied by 0 == 0.
        #expect(total > 0, "the gated-element needle names something the row does not contain")

        let branchBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.compactBranch, in: body)
        let insideBranch = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.gatedElement, in: branchBody)
        #expect(insideBranch == total, """
            SessionRow draws \(Self.gatedElement) \(total) time(s) but only \
            \(insideBranch) of them sit inside `if !isCompact` -- the \
            protocol badge must never draw outside the non-compact branch, \
            or compact mode would still show it.
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
        #expect(body.contains(Self.gatedElement))
        #expect(body.contains(Self.compactBranch))
        let values = Self.verticalPaddingValues(in: body)
        #expect(values.contains(Self.compactPaddingValue))
        #expect(values.contains(Self.defaultPaddingValue))
    }

    /// Mutation probe: the gated element drawn OUTSIDE the branch (as well
    /// as inside it) must be reported as a violation, not waved through
    /// because the branch itself still contains one copy.
    @Test func scannerSeesTheGatedElementLeakingOutsideTheBranch() throws {
        let source = """
            \(Self.rowDeclaration) {
                let isCompact: Bool
                var body: some View {
                    HStack(spacing: 8) {
                        Text(session.name)
                        Text(kindBadgeLabel)
                            .font(.system(size: 10.5, weight: .semibold))
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
        let total = TransferQueueBarCancelGuardTests.occurrenceCount(of: Self.gatedElement, in: body)
        // Positive first: the element really is present (twice), so the
        // negative below reports the leak rather than an empty read.
        #expect(total == 2)
        let branchBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.compactBranch, in: body)
        let insideBranch = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.gatedElement, in: branchBody)
        #expect(insideBranch != total, """
            the scanner must report a badge drawn outside `if !isCompact` \
            as a violation, not accept it because one copy inside the \
            branch is also present
            """)
    }

    /// The mirror case: a row that never gates the element at all (no
    /// `if !isCompact` branch in the row body) must fail closed rather than
    /// reporting "0 outside" as clean.
    @Test func scannerFailsClosedWhenTheBranchIsGoneButTheElementRemains() throws {
        let source = """
            \(Self.rowDeclaration) {
                var body: some View {
                    HStack(spacing: 8) {
                        Text(session.name)
                        Text(kindBadgeLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: code)
        #expect(body.contains(Self.gatedElement))
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.compactBranch, in: body)
        }
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
