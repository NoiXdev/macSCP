import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `SidebarNewGroupAlertPlan.title(…)` (Task 4, fix round
/// 1: the review's Minor #2 — the shared "New group" alert gave no
/// indication of which folder the group would land in when started from a
/// folder's own context menu).
///
/// A plain function over plain values, the same reason `TabTitlePlan`
/// exists as a free-standing type: nothing in this project can render a
/// view in a test, so the decision the alert's title makes has to live
/// somewhere a test can reach it directly. That `SessionSidebar`'s
/// `.alert(...)` reads this plan's answer is
/// `SidebarNewGroupInFolderWiringGuardTests`' claim, not this suite's.
@Suite("Sidebar new-group alert plan")
struct SidebarNewGroupAlertPlanTests {
    private static let folder = StoredGroup(name: "Work")

    @Test func withNoParentTheTitleIsThePlainOne() {
        #expect(
            SidebarNewGroupAlertPlan.title(parentID: nil, groups: [Self.folder])
                == L10n.string("sidebar.newGroup.title", "New group"))
    }

    @Test func withAKnownParentTheTitleNamesTheFolder() {
        #expect(
            SidebarNewGroupAlertPlan.title(parentID: Self.folder.id, groups: [Self.folder])
                == String(
                    format: L10n.string("sidebar.newGroup.title.inFolder %@", "New group in “%@”"),
                    "Work"))
    }

    /// A stale id — the folder named by `parentID` vanished between the
    /// menu click and the alert rendering — falls back to the plain title
    /// rather than showing a placeholder or a blank name.
    @Test func withAParentIDNamingNoGroupTheTitleFallsBackToThePlainOne() {
        #expect(
            SidebarNewGroupAlertPlan.title(parentID: UUID(), groups: [Self.folder])
                == L10n.string("sidebar.newGroup.title", "New group"))
    }

    @Test func withNoGroupsAtAllAndNoParentTheTitleIsStillThePlainOne() {
        #expect(
            SidebarNewGroupAlertPlan.title(parentID: nil, groups: [])
                == L10n.string("sidebar.newGroup.title", "New group"))
    }
}
