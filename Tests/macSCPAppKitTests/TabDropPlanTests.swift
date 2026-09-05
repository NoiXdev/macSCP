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

    @Test func aPayloadNamesTheTabItCarries() {
        let id = UUID()
        #expect(
            TabDropPlan.draggedTabID(
                from: [TabDragPayload(tabID: id, sourceWindowID: WindowID())]) == id)
    }

    /// A drag carries one tab. Anything past the first item belongs to a
    /// gesture this strip did not start, so the first item is what is read
    /// rather than a search for the first item that happens to parse.
    @Test func onlyTheFirstPayloadItemIsRead() {
        let window = WindowID()
        let first = TabDragPayload(tabID: UUID(), sourceWindowID: window)
        let second = TabDragPayload(tabID: UUID(), sourceWindowID: window)
        #expect(TabDropPlan.draggedTabID(from: [first, second]) == first.tabID)
    }

    /// A payload naming a tab this strip does not render parses here — and
    /// is meant to. The no-op comes from `move(tabID:onto:)` not knowing
    /// the id, not from a second rule here about which ids are real.
    @Test func aForeignTabIDStillParsesAndIsLeftToTheModelToRefuse() {
        let stranger = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        #expect(TabDropPlan.draggedTabID(from: [stranger]) == stranger.tabID)
    }

    // **What used to be tested here, and why it is gone.** Until
    // 2026-09-05 this function took `[String]` and had to tell three
    // spellings apart: the JSON envelope, a bare uuid, and everything
    // else — a file path, a sentence, the session sidebar's prefixed row
    // (`SidebarDragPayload`). It takes `[TabDragPayload]` from that day
    // on, so none of those can be handed to it: the strip's destination is
    // typed on the app's own `UTType`, and the system refuses a text drag
    // before any closure here runs. The refusal moved from a parse to a
    // type, which is the stronger place for it — and it means this suite
    // can no longer state it, because the violation no longer compiles.
    //
    // What stands guard over that boundary instead: `TabDragTests`'
    // `aDragOffersTheAppsOwnTypeAndNothingElse`, which pins that the drag
    // declares exactly one content type, and
    // `TabDragTypeDeclarationTests`, which pins that the bundle declares
    // the same identifier with no text conformance and no filename
    // extension.
}
