import AppKit
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// `SheetBound` is the one marker that replaces the three spellings a view
/// used to bound its own size with (`.frame(width:)`,
/// `.frame(width:height:)`, `.frame(minWidth:maxWidth:)`). These tests pin
/// what the marker grants and that applying it renders the frame it
/// replaces.
@Suite("Sheet bound")
@MainActor
struct SheetBoundTests {
    /// A cap clips at its MAXIMUM. Comparing a measurement against the
    /// minimum would pass every view always, so the maximum is the figure.
    @Test func aCapIsMeasuredAgainstItsMaximum() {
        let cap = SheetBound.capped(minWidth: 420, maxWidth: 460)
        #expect(cap.grantedWidth == 460)
        // The positive half: the minimum is a different number, so the
        // equality above cannot be satisfied by returning either one.
        let minimum: CGFloat = 420
        #expect(cap.grantedWidth != minimum)
        #expect(cap.grantedHeight == nil)
    }

    @Test func aFixedWidthIsItsOwnGrant() {
        #expect(SheetBound.width(520).grantedWidth == 520)
        #expect(SheetBound.width(520).grantedHeight == nil)
    }

    @Test func aFixedSizeGrantsBothAxes() {
        let size = SheetBound.size(width: 720, height: 460)
        #expect(size.grantedWidth == 720)
        #expect(size.grantedHeight == 460)
    }

    /// What a view takes when offered `proposal`. Offered nothing it reports
    /// its minimum, offered a huge size its maximum, so the two proposals
    /// together recover both ends of a frame.
    private static func size<V: View>(
        of view: V, offered proposal: CGSize
    ) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: proposal)
    }

    private static let tiny = CGSize(width: 0, height: 0)
    private static let huge = CGSize(width: 100_000, height: 100_000)

    @Test func theModifierRendersTheFrameItReplaces() {
        let width = Self.size(of: Color.clear.sheetBound(.width(520)), offered: Self.huge)
        #expect(width.width == 520, "\(width)")
        let narrow = Self.size(of: Color.clear.sheetBound(.width(520)), offered: Self.tiny)
        #expect(narrow.width == 520, "\(narrow)")

        let fixed = SheetBound.size(width: 720, height: 460)
        let both = Self.size(of: Color.clear.sheetBound(fixed), offered: Self.huge)
        #expect(both.width == fixed.grantedWidth, "\(both)")
        #expect(both.height == fixed.grantedHeight, "\(both)")
        let small = Self.size(of: Color.clear.sheetBound(fixed), offered: Self.tiny)
        #expect(small.width == 720 && small.height == 460, "\(small)")

        let cap = SheetBound.capped(minWidth: 420, maxWidth: 460)
        let atMost = Self.size(of: Color.clear.sheetBound(cap), offered: Self.huge)
        let atLeast = Self.size(of: Color.clear.sheetBound(cap), offered: Self.tiny)
        #expect(atMost.width == cap.grantedWidth, "\(atMost)")
        #expect(atLeast.width == 420, "\(atLeast)")
    }

    /// Each case measures identically to the explicit frame it replaces,
    /// offered both extremes.
    @Test func theModifierMeasuresLikeTheExplicitFrames() {
        for offered in [Self.tiny, Self.huge] {
            #expect(
                Self.size(of: Color.clear.sheetBound(.width(380)), offered: offered)
                    == Self.size(of: Color.clear.frame(width: 380), offered: offered))
            #expect(
                Self.size(
                    of: Color.clear.sheetBound(.size(width: 640, height: 480)), offered: offered)
                    == Self.size(of: Color.clear.frame(width: 640, height: 480), offered: offered))
            #expect(
                Self.size(
                    of: Color.clear.sheetBound(.capped(minWidth: 420, maxWidth: 460)),
                    offered: offered)
                    == Self.size(
                        of: Color.clear.frame(minWidth: 420, maxWidth: 460), offered: offered))
        }
    }

    /// Reads a bound knowing nothing about the conformer but the protocol.
    private static func grantedWidth<V: BoundedView>(of _: V.Type) -> CGFloat {
        V.bound.grantedWidth
    }

    /// A conformer is reachable from the test target and states its bound
    /// as a type-level value.
    @Test func aBoundedViewStatesItsBoundOnTheType() {
        #expect(BoundProbe.bound.grantedWidth == 300)
        // The same figure reached through the protocol alone. This is how a
        // registry of bounded views reads each bound, and it fails to
        // compile if the `bound` requirement leaves `BoundedView`.
        #expect(Self.grantedWidth(of: BoundProbe.self) == 300)
        let hosted = Self.size(of: BoundProbe(), offered: Self.huge)
        #expect(hosted.width == BoundProbe.bound.grantedWidth, "\(hosted)")
    }
}

/// A conformer declared at file scope, so the test reads it by name and
/// through the protocol alike.
private struct BoundProbe: BoundedView {
    static let bound = SheetBound.width(300)
    var body: some View { Color.clear.sheetBound(Self.bound) }
}
