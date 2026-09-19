import Foundation
import MacSCPTestSupport
import Testing

/// Guards the folder row's "New group…" entry (Task 4, jump-and-groups
/// plan, closing the Interface row of 2026-09-18: "'New group' is missing
/// from a (sub)folder's context menu"). `SessionSidebar` cannot be
/// instantiated in this project — no view-render harness exists, as the
/// other wiring guards in this target already state — so this is a
/// SOURCE-TEXT scan over `Sources/MacSCPAppKit/SessionSidebar.swift`, the
/// same technique `SidebarMoveToWiringGuardTests` uses.
///
/// Two properties, each a positive check (CLAUDE.md, "Guards that name what
/// they watch" — a negative check needs a positive partner):
///
/// * **`SidebarGroupRow`'s own context menu offers the entry** — a
///   `Button` reading the `sidebar.newGroup` localization key, the same one
///   the session row's "Move to…" submenu and the background menu already
///   use, so all three read one wording rather than three that could drift.
/// * **The folder row's factory wires that entry to the PARENT-TAKING
///   call** — `beginNewGroup(forMoving:inGroup:)` with THIS folder's id,
///   not the two-argument call's `nil` default, which is what the
///   background menu and a session's "Move to…" submenu still pass for a
///   top-level group. Scoped to the `onNewGroup:` closure inside
///   `groupRow(_:)`'s factory body, so a stray call added to the WRONG
///   closure (say, `onDissolve:`) cannot satisfy a check that never reads
///   that span.
///
/// SOURCE TEXT only — comments and string literals blanked
/// (`SwiftSource.blankingCommentsAndStrings`), the same stripper this
/// target's other wiring guards share.
@Suite("Sidebar new-group-in-folder wiring")
struct SidebarNewGroupInFolderWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SidebarNewGroupInFolderWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sidebarPath = "Sources/MacSCPAppKit/SessionSidebar.swift"

    private static func raw() throws -> String {
        try SourceCorpus.text(of: repoRoot.appendingPathComponent(sidebarPath))
    }

    /// Structural view: comments AND string literals blanked, for
    /// declaration-body slicing and call-site checks — "what survives is
    /// code, so a symbol found in it was called, not described or quoted"
    /// (`SwiftSource`'s own doc comment).
    private static func code() throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(sidebarPath))
    }

    /// Literal-keeping view: comments blanked, string literals kept, for the
    /// ONE check below that is itself a claim about a literal — the
    /// `sidebar.newGroup` catalogue key — where the structural view above
    /// would blank the very text being checked. Same reasoning
    /// `TunnelMenuWiringGuardTests` states for its own `L10n.string(` scans.
    private static func codeKeepingLiterals() throws -> String {
        try SourceCorpus.commentFree(of: repoRoot.appendingPathComponent(sidebarPath))
    }

    // MARK: - The folder row's own menu offers the entry

    @Test func theGroupRowsContextMenuOffersANewGroupEntry() throws {
        let literalCode = try Self.codeKeepingLiterals()
        let rowBodyWithLiterals = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private struct SidebarGroupRow: View", in: literalCode)
        #expect(rowBodyWithLiterals.contains("L10n.string(\"sidebar.newGroup\""), """
            SidebarGroupRow's body in \(Self.sidebarPath) no longer offers a button reading the \
            sidebar.newGroup key — the folder row's context menu has no "New group…" entry \
            (or reads a different wording than the background menu and the session's "Move \
            to…" submenu use for the identical action).
            """)

        let code = try Self.code()
        let rowBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private struct SidebarGroupRow: View", in: code)
        #expect(rowBody.contains("onNewGroup()"), """
            SidebarGroupRow's body no longer calls onNewGroup() — even if a "New group…" button \
            is still drawn, it fires nothing.
            """)
    }

    // MARK: - The factory wires that entry to the parent-taking call

    @Test func theGroupRowsFactoryWiresNewGroupToTheParentTakingCall() throws {
        let code = try Self.code()
        let factoryBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func groupRow(_ group: StoredGroup) -> some View", in: code)
        let closure = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "onNewGroup:", in: factoryBody)
        #expect(closure.contains("beginNewGroup("), """
            groupRow(_:)'s onNewGroup: closure in \(Self.sidebarPath) no longer calls \
            beginNewGroup( — the folder row's "New group…" entry, if it still exists at all, no \
            longer starts the same new-group flow every other "New group…" entry in this file \
            starts.
            """)
        #expect(closure.contains("inGroup:"), """
            groupRow(_:)'s onNewGroup: closure no longer passes inGroup: — without it there is \
            no way to tell this call apart from beginNewGroup(forMoving:)'s bare, two-argument \
            top-level default, and a group created from a folder's own menu would land at the \
            top level instead of inside that folder.
            """)
        #expect(closure.contains("group.id"), """
            groupRow(_:)'s onNewGroup: closure no longer names group.id — inGroup: is passed \
            something other than THIS row's own folder, so the new group would nest under the \
            wrong parent (or none, if the argument silently fell back to nil).
            """)
    }

    // MARK: - A nested create expands the folder it landed in (fix round 1)

    /// The maintainer's fix-round-1 ruling: a group created inside a
    /// collapsed folder must not vanish the instant it is named. Scoped to
    /// `commitNewGroup()`'s own body, so a call planted in the WRONG
    /// function (say, a disclosure toggle elsewhere in the file) cannot
    /// satisfy this.
    @Test func commitNewGroupExpandsTheParentChainAfterCreating() throws {
        let code = try Self.code()
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func commitNewGroup()", in: code)
        #expect(body.contains("GroupTree.selfAndAncestors("), """
            commitNewGroup()'s body in \(Self.sidebarPath) no longer calls \
            GroupTree.selfAndAncestors( — a group created inside a collapsed folder is invisible \
            again until the user manually expands that folder, the exact gap fix round 1 exists \
            to close.
            """)
        #expect(body.contains("collapsedGroups.subtract("), """
            commitNewGroup()'s body no longer writes collapsedGroups.subtract( — even if the \
            parent chain is still computed, nothing opens the folders it names, so the new \
            group stays hidden behind a closed disclosure triangle.
            """)
    }

    // MARK: - The alert's title reads the plan (fix round 1)

    /// Bounded to the ARGUMENT LIST of the `.alert(...)` call — the text
    /// between `.alert(` and `isPresented:` — deliberately not
    /// `declarationBody`, which would balance braces from the trailing
    /// closure's `{` and miss the title argument sitting before it
    /// entirely.
    private static func alertTitleArgument(in code: String) throws -> String {
        let start = try #require(code.range(of: ".alert("), """
            \(Self.sidebarPath) no longer calls .alert( — the "New group" alert, if it still \
            exists at all, is built some other way this scan does not read.
            """)
        let end = try #require(
            code.range(of: "isPresented:", range: start.upperBound..<code.endIndex), """
                no isPresented: found after .alert( in \(Self.sidebarPath) — either the alert's \
                shape changed, or this scan is reading the wrong .alert( call entirely.
                """)
        return String(code[start.upperBound..<end.lowerBound])
    }

    @Test func theNewGroupAlertsTitleReadsThePlan() throws {
        let code = try Self.code()
        let titleArgument = try Self.alertTitleArgument(in: code)
        #expect(titleArgument.contains("SidebarNewGroupAlertPlan.title("), """
            the "New group" alert's title argument in \(Self.sidebarPath) no longer calls \
            SidebarNewGroupAlertPlan.title( — it fell back to a fixed title (or some other \
            construction), so a group created inside a folder no longer says which folder it is \
            landing in.
            """)
        #expect(titleArgument.contains("parentID:") && titleArgument.contains("groups:"), """
            SidebarNewGroupAlertPlan.title(...) is no longer called with both parentID: and \
            groups: in \(Self.sidebarPath) — without both the plan cannot look the folder's name \
            up, and would either always show the plain title or crash resolving an argument that \
            no longer exists.
            """)
    }

    // MARK: - The scanner reacts (self-test over a synthetic source)

    /// The exact violation `theGroupRowsFactoryWiresNewGroupToTheParentTakingCall`
    /// exists to catch: an onNewGroup: closure that calls the two-argument
    /// top-level overload instead of naming this folder as the parent.
    @Test func scannerCatchesANewGroupEntryThatLandsAtTheTopLevel() throws {
        let source = """
            private func groupRow(_ group: StoredGroup) -> some View {
                SidebarGroupRow(
                    onNewGroup: { beginNewGroup(forMoving: nil) })
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let factoryBody = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func groupRow(_ group: StoredGroup) -> some View", in: code)
        let closure = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "onNewGroup:", in: factoryBody)
        #expect(!closure.contains("inGroup:"), """
            this synthetic onNewGroup: closure plants the top-level-default violation on \
            purpose — if the scan already sees an inGroup: here, the span it reads is not the \
            one the real check reads.
            """)
    }
}
