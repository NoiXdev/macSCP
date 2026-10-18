import SwiftUI

/// The size a view bounds itself to, as a value.
///
/// A view that bounds its own size used to do it in one of three spellings
/// (`.frame(width:)`, `.frame(width:height:)`, `.frame(minWidth:maxWidth:)`),
/// which no single search finds. This is the one marker that replaces all
/// three: a view declares `static let bound: SheetBound` (see
/// `BoundedView`) and applies it with `View.sheetBound(_:)`, so a layout
/// guard can enumerate the conformers and compare each against what it
/// grants.
enum SheetBound: Equatable, Sendable {
    /// `.frame(width:)`.
    case width(CGFloat)
    /// `.frame(width:height:)`.
    case size(width: CGFloat, height: CGFloat)
    /// `.frame(minWidth:maxWidth:)`.
    case capped(minWidth: CGFloat, maxWidth: CGFloat)

    /// The width a measurement is compared against: the fixed width, or a
    /// cap's MAXIMUM. A cap clips at its maximum, so comparing a measurement
    /// against its minimum would pass every view always.
    var grantedWidth: CGFloat {
        switch self {
        case .width(let width): width
        case .size(let width, _): width
        case .capped(_, let maxWidth): maxWidth
        }
    }

    /// The height a measurement is compared against, or nil where the view
    /// does not fix one.
    var grantedHeight: CGFloat? {
        switch self {
        case .width, .capped: nil
        case .size(_, let height): height
        }
    }
}

/// A view that states the size it bounds itself to as a type-level value.
protocol BoundedView: View {
    /// The view's bound. Declare it as a constant (`static let bound = ...`),
    /// never a computed `static var` that can answer differently over time:
    /// `sheetBound(_:)` wraps the view in a different frame per case, which
    /// is a different place in the view tree, so a bound that changed while
    /// the view is on screen would rebuild the wrapped content and reset its
    /// `@State`.
    ///
    /// Main-actor isolated, like `View`: read it from a main-actor context,
    /// for one conformer by name or for any through a generic
    /// `V: BoundedView` (see `SheetBoundTests`). A nonisolated read compiles
    /// only as a warning, because `View` is `@preconcurrency`, and CI counts
    /// warnings.
    static var bound: SheetBound { get }
}

extension View {
    /// Applies `bound` as the frame its case names, so a view's rendered
    /// size is exactly what the explicit `.frame` call it replaces gave it.
    @ViewBuilder
    func sheetBound(_ bound: SheetBound) -> some View {
        switch bound {
        case .width(let width):
            frame(width: width)
        case .size(let width, let height):
            frame(width: width, height: height)
        case .capped(let minWidth, let maxWidth):
            frame(minWidth: minWidth, maxWidth: maxWidth)
        }
    }
}
