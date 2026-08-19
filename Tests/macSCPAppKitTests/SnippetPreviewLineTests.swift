import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// Pins `SnippetPreviewLine.row`, the one new decision behind the terminal
/// header popover's fixed command line (P3d, Task 3): a live hover always
/// wins over a right-click "Preview" pin. Everything else about the
/// popover — the gesture split, the context menu, row highlighting — is
/// SwiftUI view code with no test tool in this project (see
/// `TerminalPanelHeader`'s own doc comment); this is the only piece of the
/// popover's new behavior that is NOT view code and can be asserted
/// directly.
@Suite("SnippetPreviewLine")
struct SnippetPreviewLineTests {
    /// `SnippetListPlan.Row` has no public initializer (by design — see
    /// that type's own doc comment: it is meant to be produced only by
    /// `SnippetListPlan.build`), so real rows here come from a tiny model
    /// with two distinctly named snippets, exactly like
    /// `SnippetListPlanTests` builds its own fixtures.
    private func tworows() -> (hovered: SnippetListPlan.Row, pinned: SnippetListPlan.Row) {
        let hovered = Snippet(name: "hovered", command: "echo hovered")
        let pinned = Snippet(name: "pinned", command: "echo pinned")
        let model = SnippetMenuModel.build(
            snippets: [hovered, pinned], isConnected: true, supportsShell: true)
        let rows = SnippetListPlan.build(model: model).flatMap(\.rows)
        return (
            rows.first { $0.snippet.id == hovered.id }!,
            rows.first { $0.snippet.id == pinned.id }!
        )
    }

    @Test func neitherHoveredNorPinnedProducesNil() {
        #expect(SnippetPreviewLine.row(hovered: nil, pinned: nil) == nil)
    }

    @Test func pinnedIsUsedWhenNothingIsHovered() {
        let (_, pinned) = tworows()
        #expect(SnippetPreviewLine.row(hovered: nil, pinned: pinned) == pinned)
    }

    @Test func hoveredIsUsedWhenNothingIsPinned() {
        let (hovered, _) = tworows()
        #expect(SnippetPreviewLine.row(hovered: hovered, pinned: nil) == hovered)
    }

    /// The exact claim this type's doc comment makes: hover wins even
    /// while a DIFFERENT row is pinned. A constant `pinned ?? hovered`
    /// (the reverse precedence) would fail exactly this case while still
    /// passing the two single-sided tests above — this is the test that
    /// actually distinguishes the two orderings.
    @Test func hoveredWinsOverADifferentPinnedRow() {
        let (hovered, pinned) = tworows()
        #expect(SnippetPreviewLine.row(hovered: hovered, pinned: pinned) == hovered)
    }
}
