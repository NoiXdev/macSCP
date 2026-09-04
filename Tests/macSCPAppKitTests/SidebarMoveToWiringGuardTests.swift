import Foundation
import Testing

/// Guards the "Move to…" submenu (Sidebar Polish, Task 3): the session row
/// had one already; this suite exists because the group row got one on this
/// task, and both had to end up reading the SAME target rule instead of two
/// hand-rolled ones that could drift apart.
///
/// The properties, each a `@Test` below:
///
/// * **Both submenus route through one shared entry builder**, and that
///   builder — not either row — is what calls `SidebarOrdering.moveTargets`.
///   Two call sites of the shared `moveToMenuItems(` free function, one call
///   site of `SidebarOrdering.moveTargets(` inside it: "both submenus read
///   `SidebarOrdering.moveTargets`" is then a fact about the ONE place that
///   reads it, not a claim that has to be re-verified at each row.
/// * **Each row's "Move to…" entry calls `move(` with `intoGroup:`, and
///   nothing else that moves anything** — no rename, no dissolve, no sort,
///   no duplicate. Scoped to each row's own `onMove:` closure, so a stray
///   mutating call added to the WRONG place in the file cannot satisfy or
///   fail a check that never reads that place.
/// * **The root entry passes `nil`.** Read out of the shared builder's own
///   body, not out of either row — there is exactly one place that builds a
///   root button, and this is it.
///
/// ## The negative check has a positive partner
///
/// CLAUDE.md, "Guards that name what they watch". Each negative below
/// (`entryCallsNothingElseThatMoves` for either row) is scoped to a span a
/// positive check on the SAME method proves is still there and still names
/// `move(` — so a row that lost its `onMove:` argument entirely, or renamed
/// it, fails the positive half loudly instead of the negative half reading
/// an empty span as "nothing else that moves" found.
///
/// ## What it reads
///
/// SOURCE TEXT only — comments and string literals blanked
/// (`SwiftSource.blankingCommentsAndStrings`), the same stripper this
/// target's other wiring guards share. Nothing here renders a menu or fires
/// a click; that a context menu actually opens with these entries in it, in
/// this order, is outside what a scan can say.
@Suite("Sidebar move-to wiring")
struct SidebarMoveToWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SidebarMoveToWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sidebarPath = "Sources/MacSCPAppKit/SessionSidebar.swift"

    private static func raw() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(sidebarPath), encoding: .utf8)
    }

    private static func code() throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try raw())
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchFrom = text.startIndex
        while let hit = text.range(of: needle, range: searchFrom..<text.endIndex) {
            count += 1
            searchFrom = hit.upperBound
        }
        return count
    }

    // MARK: - The shared builder is what reads SidebarOrdering.moveTargets

    /// The positive partner `theSharedBuilderIsWhatCallsMoveTargets` needs
    /// first: the shared entry builder really is called from two places, so
    /// "one call site inside it" describes something both submenus reach
    /// rather than dead code neither does.
    @Test func theSharedEntryBuilderHasExactlyTwoCallSites() throws {
        let code = try Self.code()
        let total = Self.occurrences(of: "moveToMenuItems(", in: code)
        let declarations = Self.occurrences(of: "func moveToMenuItems(", in: code)
        let callSites = total - declarations
        #expect(callSites == 2, """
            \(Self.sidebarPath) calls moveToMenuItems( \(callSites) time(s) outside its own \
            declaration, expected exactly two — one from SessionRow's context menu, one from \
            SidebarGroupRow's. Fewer than two means a submenu stopped using the shared builder \
            (and, per CLAUDE.md's rule on second copies, is rolling its own exclusion logic \
            again); more than two means a third caller this suite does not otherwise account \
            for.
            """)
    }

    /// `SidebarOrdering.moveTargets` is called from exactly one place in the
    /// App target — inside the shared builder — which combined with the two
    /// call sites above is what "both submenus read `SidebarOrdering.
    /// moveTargets`" means: not two separate reads that happen to agree
    /// today, but one read two menus share.
    @Test func theSharedBuilderIsWhatCallsMoveTargets() throws {
        let code = try Self.code()
        let count = Self.occurrences(of: "SidebarOrdering.moveTargets(", in: code)
        #expect(count == 1, """
            \(Self.sidebarPath) calls SidebarOrdering.moveTargets( \(count) time(s), expected \
            exactly one. Zero means the shared builder stopped deriving targets from Core \
            entirely; more than one means a second, independent read that the "one target rule \
            for both submenus" claim no longer holds for.
            """)
        let declaration = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func moveToMenuItems(", in: code)
        #expect(declaration.contains("SidebarOrdering.moveTargets("), """
            moveToMenuItems's own body no longer calls SidebarOrdering.moveTargets( — the one \
            occurrence found above is then somewhere else in the file, not inside the function \
            both submenus call.
            """)
    }

    // MARK: - The root entry passes nil

    @Test func theSharedBuilderOffersARootEntryThatPassesNil() throws {
        let code = try Self.code()
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func moveToMenuItems(", in: code)
        #expect(body.contains("onMove(nil)"), """
            moveToMenuItems's body no longer calls onMove(nil) — the root ("No group") entry \
            it draws for a `nil` target then either does nothing or passes the wrong value, and \
            a session or folder dragged to the top level through the menu lands somewhere else.
            """)
    }

    // MARK: - Each row's onMove: calls move( with intoGroup:, and nothing else that moves

    /// Mutating calls this suite knows about, none of which belongs inside
    /// an `onMove:` closure whose whole job is "put this item there and
    /// nothing more". Counted while writing this file: eight names, drawn
    /// from `SessionListViewModel`'s own other write methods reachable from
    /// a sidebar row's context menu.
    private static let otherMutatingEntries = [
        "dissolveGroup(", "sortChildrenByName(", "renameGroup(", "renameSession(",
        "duplicateSession(", "createGroup(", "delete(", "applyOrdering(",
    ]

    private static func onMoveClosure(inFactory declaration: String) throws -> String {
        let code = try Self.code()
        let factoryBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: declaration, in: code)
        // The anchor is "onMove:" WITHOUT the brace — `declarationBodyRange`
        // opens its span at the first `{` AFTER the anchor text, so an
        // anchor that already carries its own brace makes the scan balance
        // the closure's first NESTED brace instead of the closure itself
        // (`ConnectionFormScrollGuardTests.bodyDeclaration` documents the
        // same trap, paid for there).
        return try TransferQueueBarCancelGuardTests.declarationBody(
            of: "onMove:", in: factoryBody)
    }

    @Test func theSessionRowsOnMoveCallsMoveWithIntoGroupAndNothingElse() throws {
        let closure = try Self.onMoveClosure(
            inFactory: "private func sessionRow(_ session: StoredSession) -> some View")
        #expect(closure.contains("viewModel.move("), """
            SessionRow's onMove: closure in \(Self.sidebarPath) no longer calls \
            viewModel.move( — picking any entry in the session's "Move to…" submenu then does \
            nothing.
            """)
        #expect(closure.contains("intoGroup:"), """
            SessionRow's onMove: closure no longer passes intoGroup: — without it there is no \
            way to tell this call apart from the OTHER move( overload \
            (`move(_:before:)`), which reorders among siblings rather than changing a folder.
            """)
        for entry in Self.otherMutatingEntries {
            #expect(!closure.contains(entry), """
                SessionRow's onMove: closure names \(entry) — a second effect riding along with \
                a plain "move this session" menu pick. Read: \(closure)
                """)
        }
    }

    @Test func theGroupRowsOnMoveCallsMoveWithIntoGroupAndNothingElse() throws {
        let closure = try Self.onMoveClosure(
            inFactory: "private func groupRow(_ group: StoredGroup) -> some View")
        #expect(closure.contains("viewModel.move("), """
            SidebarGroupRow's onMove: closure in \(Self.sidebarPath) no longer calls \
            viewModel.move( — picking any entry in the folder's "Move to…" submenu then does \
            nothing, which is exactly the gap Task 3 exists to close.
            """)
        #expect(closure.contains("intoGroup:"), """
            SidebarGroupRow's onMove: closure no longer passes intoGroup: — see the same \
            reasoning on the session row's own check.
            """)
        for entry in Self.otherMutatingEntries {
            #expect(!closure.contains(entry), """
                SidebarGroupRow's onMove: closure names \(entry) — a second effect riding along \
                with a plain "move this folder" menu pick. Read: \(closure)
                """)
        }
    }

    // MARK: - The scanner reacts (self-test over a synthetic source)

    /// The exact violation `theGroupRowsOnMoveCallsMoveWithIntoGroupAndNothingElse`
    /// exists to catch: an onMove: closure that moves the item AND does
    /// something else besides.
    @Test func scannerCatchesASecondEffectInsideOnMove() throws {
        let source = """
            private func groupRow(_ group: StoredGroup) -> some View {
                SidebarGroupRow(
                    onMove: { parentID in
                        viewModel.move(.group(group.id), intoGroup: parentID)
                        viewModel.dissolveGroup(group)
                    })
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let factoryBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func groupRow(_ group: StoredGroup) -> some View", in: code)
        let closure = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "onMove:", in: factoryBody)
        #expect(closure.contains("dissolveGroup("), """
            this synthetic onMove: closure plants a second effect on purpose — if the scan does \
            not see it, the span it reads is not the one the real check reads.
            """)
    }
}
