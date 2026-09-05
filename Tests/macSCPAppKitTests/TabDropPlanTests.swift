import Foundation
import Testing

@testable import MacSCPAppKit

/// Direct tests over `TabDropPlan` — the one question a tab drop asks that
/// is not an identity: which tab a dropped payload names.
///
/// Same boundary as `LivenessDotPlanTests`: this project has no SwiftUI
/// rendering harness, so nothing here proves that a drag fires or that the
/// tab lands under the pointer.
///
/// **The destination is not tested here because it is not computed here,
/// or anywhere in the app layer.** The drop reports the tab it was let go
/// on and `TabsViewModel.move(tabID:onto:)` derives the position;
/// `TabsViewModelTests` owns that, and owns it alone.
@Suite("Tab drop plan")
struct TabDropPlanTests {
    // MARK: - Which tab was dragged

    @Test func anEmptyPayloadNamesNoTab() {
        #expect(TabDropPlan.draggedTabID(from: []) == nil)
    }

    @Test func aPayloadThatIsNotAUUIDNamesNoTab() {
        #expect(TabDropPlan.draggedTabID(from: ["/Users/someone/a-dropped-file.txt"]) == nil)
        #expect(TabDropPlan.draggedTabID(from: [""]) == nil)
    }

    @Test func aUUIDPayloadNamesThatTab() {
        let id = UUID()
        #expect(TabDropPlan.draggedTabID(from: [id.uuidString]) == id)
    }

    /// A drag carries one tab. Anything past the first item belongs to a
    /// gesture this strip did not start, so the first item is what is read
    /// rather than a search for the first item that happens to parse.
    @Test func onlyTheFirstPayloadItemIsRead() {
        let first = UUID()
        let second = UUID()
        #expect(TabDropPlan.draggedTabID(from: [first.uuidString, second.uuidString]) == first)
        #expect(TabDropPlan.draggedTabID(from: ["not a uuid", second.uuidString]) == nil)
    }

    /// A well-formed uuid from somewhere else parses here — and is meant
    /// to. The no-op comes from `move(tabID:onto:)` not knowing the id, not
    /// from a second rule here about which ids are real.
    ///
    /// The session sidebar is not such a case, though this comment claimed
    /// it was until 2026-09-05: `SidebarDragPayload` prefixes its uuid, so
    /// a sidebar row names no tab here at all — see
    /// `aSidebarRowNamesNoTab` below.
    @Test func aForeignUUIDStillParsesAndIsLeftToTheModelToRefuse() {
        let strangerID = UUID()
        #expect(TabDropPlan.draggedTabID(from: [strangerID.uuidString]) == strangerID)
    }

    /// What the sidebar actually drags, built through `SidebarDragPayload`
    /// itself rather than spelled out here — a literal would be a second
    /// copy of that type's prefixes, and the first thing a rename would
    /// leave behind (CLAUDE.md, "Guards that name what they watch").
    @Test func aSidebarRowNamesNoTab() {
        let session = SidebarDragPayload.text(for: .session(UUID()))
        let group = SidebarDragPayload.text(for: .group(UUID()))
        #expect(TabDropPlan.draggedTabID(from: [session]) == nil)
        #expect(TabDropPlan.draggedTabID(from: [group]) == nil)
    }
}
