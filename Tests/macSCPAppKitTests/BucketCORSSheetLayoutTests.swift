import AppKit
import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// What the CORS sheet's pane does with the height it is given.
///
/// These draw the view, which the decision suite in `BucketCORSSheetTests`
/// deliberately does not: the two properties here are about layout and
/// nothing else can show them. The instrument is the one `SheetBoundTests`
/// uses — offered nothing a view reports its minimum, offered a huge size its
/// maximum, so the two proposals together recover both ends of a frame.
@Suite("Bucket CORS sheet layout")
struct BucketCORSSheetLayoutTests {
    private static let tiny = CGSize(width: 620, height: 0)
    private static let huge = CGSize(width: 620, height: 100_000)

    @MainActor private static func height<V: View>(of build: @MainActor () -> V, offered: CGSize) -> CGFloat {
        L10n.$localeOverride.withValue("en") {
            NSHostingController(rootView: build()).sizeThatFits(in: offered).height
        }
    }

    private static func rule() -> CORSRule {
        CORSRule(
            id: nil, allowedOrigins: ["https://example.test"], allowedMethods: ["GET"],
            allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: nil)
    }

    /// The sheet is bound to a fixed height, so a pane that stops at its own
    /// figure leaves the difference as dead space under it — which is what the
    /// maintainer saw on 2026-10-26. The pane keeps its floor (that figure is
    /// what the 620 pt bound was measured at) and takes more when there is
    /// more to take.
    @MainActor @Test func thePaneKeepsItsFloorAndTakesWhatItIsOffered() {
        let model = BucketCORSModel(rules: [Self.rule()])
        let floor = Self.height(of: { CORSPane(model: model) }, offered: Self.tiny)
        let stretched = Self.height(of: { CORSPane(model: model) }, offered: Self.huge)
        #expect(floor == BucketCORSSheet.paneHeight)
        #expect(stretched > BucketCORSSheet.paneHeight)
    }

    /// The button that adds a rule sits beside the scrolling list, not inside
    /// it, so a bucket with more rules than fit cannot scroll it out of reach.
    /// Measured with no rules at all: whatever the pane reports then is what
    /// stands outside the scroller, and a scroller on its own reports nothing.
    /// The first expectation is the positive half — a button with no height
    /// would satisfy the second one without any of this being true.
    @MainActor @Test func theAddRuleButtonStaysOutsideTheScroller() {
        let empty = BucketCORSModel(rules: [])
        let pane = Self.height(of: { CORSFormPane(model: empty) }, offered: Self.tiny)
        let button = Self.height(
            of: { Button(BucketCORSModel.addRuleLine.text) {}.buttonStyle(.polished) },
            offered: Self.tiny)
        #expect(button > 0)
        #expect(pane >= button)
    }
}
