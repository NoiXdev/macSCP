import Foundation
import Testing
@testable import macSCPCore

/// `clampedToVisibleArea` (M18a/T5b): keeps a window-sized frame inside a
/// screen's visible area after `resizeWindow` grows/shrinks it. Growing
/// downward while the window sits low on the screen can push the bottom
/// edge below the visible area (`constrainFrameRect` only guards the top) —
/// this is the pure geometry fix for that. All frames here use macOS
/// screen coordinates: y-up, origin at the bottom-left.
@Suite("WindowGeometry")
struct WindowGeometryTests {
    /// A typical primary-screen visible area, minus a menu bar strip at the
    /// top (menu bar reduces `maxY`, not `minY`).
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func frameAlreadyInsideIsUnchanged() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 620)
        #expect(clampedToVisibleArea(frame, visible: visible) == frame)
    }

    @Test func bottomEdgeBelowVisibleAreaIsMovedUpWithSizePreserved() {
        // Sits low on the screen; origin.y is negative, so the bottom edge
        // (origin.y) is below the visible area's bottom (visible.minY == 0).
        let frame = CGRect(x: 100, y: -160, width: 900, height: 620)
        let result = clampedToVisibleArea(frame, visible: visible)
        #expect(result.size == frame.size)
        #expect(result.origin.x == frame.origin.x)
        #expect(result.origin.y == visible.minY)
    }

    @Test func frameOffToTheRightIsMovedLeftWithSizePreserved() {
        let frame = CGRect(x: 900, y: 100, width: 900, height: 620)
        let result = clampedToVisibleArea(frame, visible: visible)
        #expect(result.size == frame.size)
        #expect(result.origin.y == frame.origin.y)
        #expect(result.origin.x == visible.maxX - frame.width)
    }

    @Test func frameOffTheTopIsMovedDownWithSizePreserved() {
        // Top edge (origin.y + height) above visible.maxY.
        let frame = CGRect(x: 100, y: 700, width: 900, height: 620)
        let result = clampedToVisibleArea(frame, visible: visible)
        #expect(result.size == frame.size)
        #expect(result.origin.x == frame.origin.x)
        #expect(result.origin.y == visible.maxY - frame.height)
    }

    @Test func frameWiderThanVisibleAreaIsShrunkAndPinnedToTheLeftEdge() {
        let frame = CGRect(x: -50, y: 100, width: 2000, height: 620)
        let result = clampedToVisibleArea(frame, visible: visible)
        #expect(result.width == visible.width)
        #expect(result.origin.x == visible.minX)
        #expect(result.height == frame.height)
        #expect(result.origin.y == frame.origin.y)
    }

    @Test func frameTallerThanVisibleAreaIsShrunkAndPinnedToTheBottomEdge() {
        let frame = CGRect(x: 100, y: -50, width: 900, height: 2000)
        let result = clampedToVisibleArea(frame, visible: visible)
        #expect(result.height == visible.height)
        #expect(result.origin.y == visible.minY)
        #expect(result.width == frame.width)
        #expect(result.origin.x == frame.origin.x)
    }

    @Test func frameExactlyFillingVisibleAreaIsUnchanged() {
        #expect(clampedToVisibleArea(visible, visible: visible) == visible)
    }
}
