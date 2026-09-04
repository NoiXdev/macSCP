import Foundation
import Testing

/// Guards `SessionRow`'s compact-mode wiring (sidebar-polish plan, Task 2):
/// the row must read `isCompact`, and its host-subtitle line
/// (`Text(connectionSummary)`) must sit ONLY inside the `if !isCompact`
/// branch — never outside it, where it would draw in compact mode too and
/// defeat the whole point of the setting.
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
/// blanked): `Text(connectionSummary)` is an expression, not a literal, so
/// a comment that happened to quote it verbatim cannot be mistaken for the
/// real call (CLAUDE.md, "Source-scanning guards read comments too").
///
/// This is a NEGATIVE check (the subtitle must not appear outside the
/// branch), so it is paired with two positive anchors alongside it
/// (CLAUDE.md, "Guards that name what they watch"): the row must actually
/// contain `isCompact` at all, and the subtitle view must actually exist
/// somewhere in the row -- otherwise the negative check would be satisfied
/// by a row that dropped the feature entirely, which is exactly the
/// silent-pass shape that rule warns about.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view -- nothing
/// here confirms the row actually measures shorter with `isCompact == true`,
/// or that the padding literal really changes. `SettingsStoreTests` pins
/// `sidebarCompact`'s own round trip; nothing pins the padding numbers
/// themselves, which is a rendering fact no source scan can see.
@Suite("SessionSidebar — compact row wiring")
struct SessionSidebarCompactRowGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sidebarFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static let rowDeclaration = "private struct SessionRow: View"
    private static let compactBranch = "if !isCompact"
    private static let subtitle = "Text(connectionSummary)"

    private static func strictSource() throws -> String {
        let raw = try String(contentsOf: sidebarFile, encoding: .utf8)
        return try SwiftSource.blankingCommentsAndStrings(raw)
    }

    private static func rowBody() throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: try strictSource())
    }

    // MARK: - The guard

    /// Positive anchor 1: the row reads the setting at all. Without this, a
    /// row that dropped `isCompact` entirely (and so never drew the
    /// subtitle either) would pass the negative check below over nothing.
    @Test func theRowReadsTheCompactSetting() throws {
        let body = try Self.rowBody()
        #expect(body.contains("isCompact"), """
            SessionRow no longer reads isCompact -- compact mode (dictated \
            notes item 6) has been dropped from the row builder.
            """)
    }

    /// Positive anchor 2: the host-subtitle view exists SOMEWHERE in the
    /// row body at all. Without this, a row that removed the subtitle
    /// entirely would also satisfy "not outside the branch" trivially.
    @Test func theHostSubtitleViewExistsInTheRow() throws {
        let body = try Self.rowBody()
        #expect(body.contains(Self.subtitle), """
            SessionRow no longer contains \(Self.subtitle) -- the host \
            subtitle line is gone from the row entirely, not merely hidden \
            in compact mode.
            """)
    }

    /// The negative half: every occurrence of the subtitle in the row must
    /// sit inside the `if !isCompact` branch -- none outside it, where it
    /// would draw regardless of the setting and defeat compact mode.
    @Test func theHostSubtitleSitsOnlyInsideTheNonCompactBranch() throws {
        let body = try Self.rowBody()
        let total = TransferQueueBarCancelGuardTests.occurrenceCount(of: Self.subtitle, in: body)
        // Restates the positive anchor above as a count, so the comparison
        // below cannot be satisfied by 0 == 0.
        #expect(total > 0, "the subtitle needle names something the row does not contain")

        let branchBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.compactBranch, in: body)
        let insideBranch = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.subtitle, in: branchBody)
        #expect(insideBranch == total, """
            SessionRow draws \(Self.subtitle) \(total) time(s) but only \
            \(insideBranch) of them sit inside `if !isCompact` -- the host \
            subtitle must never draw outside the non-compact branch, or \
            compact mode would still show it.
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
        #expect(body.contains(Self.subtitle))
        #expect(body.contains(Self.compactBranch))
    }

    /// Mutation probe: a subtitle drawn OUTSIDE the branch (as well as
    /// inside it) must be reported as a violation, not waved through
    /// because the branch itself still contains one copy.
    @Test func scannerSeesTheSubtitleLeakingOutsideTheBranch() throws {
        let source = """
            \(Self.rowDeclaration) {
                let isCompact: Bool
                var body: some View {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(session.name)
                        }
                        Text(connectionSummary)
                            .font(.caption2)
                        if !isCompact {
                            Text(connectionSummary)
                                .font(.caption2)
                        }
                    }
                    .padding(.vertical, isCompact ? 2 : 5)
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: code)
        let total = TransferQueueBarCancelGuardTests.occurrenceCount(of: Self.subtitle, in: body)
        // Positive first: the subtitle really is present (twice), so the
        // negative below reports the leak rather than an empty read.
        #expect(total == 2)
        let branchBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.compactBranch, in: body)
        let insideBranch = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.subtitle, in: branchBody)
        #expect(insideBranch != total, """
            the scanner must report a subtitle drawn outside `if !isCompact` \
            as a violation, not accept it because one copy inside the \
            branch is also present
            """)
    }

    /// The mirror case: a row that never gates the subtitle at all (no
    /// `if !isCompact` branch in the row body) must fail closed rather than
    /// reporting "0 outside" as clean.
    @Test func scannerFailsClosedWhenTheBranchIsGoneButTheSubtitleRemains() throws {
        let source = """
            \(Self.rowDeclaration) {
                var body: some View {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(session.name)
                        }
                        Text(connectionSummary)
                            .font(.caption2)
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.rowDeclaration, in: code)
        #expect(body.contains(Self.subtitle))
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.compactBranch, in: body)
        }
    }

    @Test func scannerFailsClosedWhenTheRowIsGone() {
        let source = "struct SomethingElse: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.rowDeclaration, in: source)
        }
    }
}
