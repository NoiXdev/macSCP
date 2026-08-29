import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The sidebar's drag payload — the App-layer counterpart of `TabDropPlan`,
/// and for the same reason: a drop destination learns nothing about what is
/// being carried until the drop happens, so the payload is the one place the
/// dragged row can name itself.
///
/// What it names is a `SidebarItem`, not a bare uuid, because the sidebar's
/// two gestures act on two KINDS of row: dropping on a folder puts the
/// dragged row inside it, dropping on a connection puts it in that
/// connection's place. A bare uuid would leave the kind to be guessed from a
/// lookup, and a lookup that misses (a row deleted mid-drag) is
/// indistinguishable from a lookup for the other kind.
@Suite("Sidebar drag payload")
struct SidebarDragPayloadTests {
    @Test func aFolderRoundTripsAsAFolder() {
        let id = UUID()
        let payload = SidebarDragPayload.text(for: .group(id))
        #expect(SidebarDragPayload.item(from: [payload]) == .group(id))
    }

    @Test func aConnectionRoundTripsAsAConnection() {
        let id = UUID()
        let payload = SidebarDragPayload.text(for: .session(id))
        #expect(SidebarDragPayload.item(from: [payload]) == .session(id))
    }

    /// The two spellings are distinct even for the same id, which is what
    /// makes the kind a fact the drop is told rather than one it infers.
    @Test func theTwoKindsAreSpelledDifferentlyForTheSameID() {
        let id = UUID()
        #expect(
            SidebarDragPayload.text(for: .group(id)) != SidebarDragPayload.text(for: .session(id)))
    }

    /// A tab dragged out of the tab strip carries a bare uuid string
    /// (`TabItemView.dragPayload`). It is not a sidebar row and must not be
    /// read as one — the mirror image of `TabDropPlan` refusing a sidebar
    /// payload, and the reason neither surface can move the other's rows.
    @Test func aBareUUIDFromTheTabStripIsNotASidebarRow() {
        #expect(SidebarDragPayload.item(from: [UUID().uuidString]) == nil)
    }

    @Test func nonsenseAndAnEmptyPayloadNameNothing() {
        #expect(SidebarDragPayload.item(from: []) == nil)
        #expect(SidebarDragPayload.item(from: ["group:not-a-uuid"]) == nil)
        #expect(SidebarDragPayload.item(from: ["/etc/passwd"]) == nil)
    }

    /// A drag carries one row, so anything past the first item belongs to a
    /// gesture this sidebar did not produce — the same rule `TabDropPlan`
    /// states for the strip.
    @Test func onlyTheFirstItemIsRead() {
        let first = UUID()
        let second = UUID()
        let payload = [
            SidebarDragPayload.text(for: .session(first)),
            SidebarDragPayload.text(for: .group(second)),
        ]
        #expect(SidebarDragPayload.item(from: payload) == .session(first))
    }
}
