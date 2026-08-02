import CoreGraphics
import Foundation

/// Clamps a frame so it lies fully within a visible rect (M18a/T5b).
///
/// Assumes macOS screen coordinates: y-up, origin at the bottom-left — the
/// same convention as `NSScreen.visibleFrame` and `NSWindow.frame`. `visible`
/// is meant to be the target screen's visible area (menu bar / Dock
/// excluded).
///
/// If `frame` is larger than `visible` in a dimension, it is shrunk to fit
/// that dimension first; the origin is then shifted (never resized further)
/// so the whole frame lies inside `visible`. A frame that is already fully
/// inside `visible` is returned unchanged.
///
/// Pure and AppKit-free by design (only `CGRect`/`CGFloat`, no `NSScreen` or
/// `NSWindow`) so it can be unit tested without a live window server — see
/// `resizeWindow` in `MacSCPApp/ContentView.swift` for the one call site.
public func clampedToVisibleArea(_ frame: CGRect, visible: CGRect) -> CGRect {
    let width = min(frame.width, visible.width)
    let height = min(frame.height, visible.height)

    let x = min(max(frame.origin.x, visible.minX), visible.maxX - width)
    let y = min(max(frame.origin.y, visible.minY), visible.maxY - height)

    return CGRect(x: x, y: y, width: width, height: height)
}
