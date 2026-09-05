import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Whether a finished drag means "this tab wants a window of its own".
///
/// A type rather than an `if` inside an AppKit callback, the same split
/// `TabDropPlan` and `TabBackgroundPlan` already make in the strip: a rule
/// written into `draggingSession(_:endedAt:operation:)` is a rule nothing
/// in this package can call, because no test here mounts an
/// `NSViewRepresentable` or synthesises a drag session.
///
/// **Two facts, and both are needed.**
///
/// `operation` is empty exactly when nothing accepted the drop — the
/// desktop, another application (the source refuses `.outsideApplication`
/// outright), or empty space. That alone is not enough: the strip's own
/// blank area accepts nothing either, and letting a tab dropped beside its
/// neighbours fly out into a new window would turn a documented no-op
/// ("only tabs are drop targets, so a drop into the empty space of the
/// strip leaves the order as it was") into a window nobody asked for. So
/// the point where the drag ended must also be outside the window it
/// started in.
///
/// **What this cannot tell apart**, stated rather than implied: a drag
/// CANCELLED with Escape ends with an empty operation too, and AppKit
/// reports no reason. Cancelling over another window, or over the desktop,
/// therefore detaches. Cancelling over the source window — the common case,
/// since that is where the pointer started — does not.
enum TabDropOutsidePlan {
    /// `sourceWindowFrame` is `nil` for a view with no window, which cannot
    /// happen while a drag it started is in flight; it answers "detach"
    /// then, because an empty operation is still an unaccepted drop and the
    /// second fact simply has nothing to say.
    static func detaches(
        operation: NSDragOperation, endedAt screenPoint: CGPoint,
        sourceWindowFrame: CGRect?
    ) -> Bool {
        guard operation.isEmpty else { return false }
        guard let frame = sourceWindowFrame else { return true }
        return !frame.contains(screenPoint)
    }
}

/// The one pasteboard item a tab drag writes: the payload's JSON, offered
/// under the app's own content type and under no other.
///
/// **The whole of the Finder fix lives in `writableTypes(for:)`.** A
/// `String` payload — what this strip dragged until 2026-09-05 — offers
/// `public.utf8-plain-text`, which the Finder accepts by writing a text
/// clipping file. This offers one private type, which nothing outside this
/// app imports.
///
/// **And the whole of the round trip lives in the pasteboard type.**
/// `TabDragPayload`'s `CodableRepresentation(contentType: .macSCPTab)` maps
/// that content type straight onto the pasteboard type of the same
/// identifier, with a default `JSONEncoder`/`JSONDecoder` pair — so
/// SwiftUI's `dropDestination(for: TabDragPayload.self)` on any strip in
/// this app reads back exactly what is written here.
/// `TabDragTests` pins both halves — one type, and bytes that decode to
/// the payload that was written.
final class TabDragPasteboardWriter: NSObject, NSPasteboardWriting {
    /// Spelled once, from the type itself rather than from a literal, so a
    /// change to the identifier moves the writer with it.
    static let pasteboardType = NSPasteboard.PasteboardType(UTType.macSCPTab.identifier)

    private let data: Data

    /// `nil` when the payload cannot be encoded, which for two `UUID`s
    /// cannot happen. Refusing to construct is deliberate: a writer that
    /// offered its type and then answered `nil` for it would begin a drag
    /// carrying an item no destination can read.
    init?(payload: TabDragPayload) {
        guard let data = payload.pasteboardData() else { return nil }
        self.data = data
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [Self.pasteboardType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.pasteboardType ? data : nil
    }
}

/// The tab's drag source — AppKit, because macOS 15 has no SwiftUI hook
/// that reports a drag ending nowhere.
///
/// **Why this replaces `.draggable` rather than sitting beside it.** Two
/// drag sources on one view race the same mouse-down. And the half that
/// matters here is `NSDraggingSource`: `draggingSession(_:endedAt:
/// operation:)` is a method of the object that STARTED the session, and
/// `.draggable` does not vend that object. SwiftUI's own drag-ended
/// callback, `onDragSessionUpdated`, is macOS 26 — eleven major versions
/// above this package's minimum (measured 2026-09-05, recorded in
/// `docs/superpowers/specs/2026-09-03-detachable-tabs-design.md`).
///
/// **Where it sits, and what that costs.** As an overlay over the tab's
/// LABEL — its dots, title and protocol badge — and deliberately not over
/// the close button beside them. An `NSView` inside a SwiftUI hierarchy
/// that answers `hitTest` with itself takes the mouse event outright; the
/// hosting view never sees it, so any SwiftUI control underneath stops
/// working. Covering the ✕ would have made it undismissable, so the overlay
/// stops short of it and the button keeps SwiftUI's own handling.
///
/// **What `hitTest` lets through.** Only the three left-button event types
/// this view actually handles. Everything else — the right-click that opens
/// the tab's SwiftUI `.contextMenu`, the moves that drive `.onHover`, and a
/// `hitTest` asked outside any event at all — is answered with `nil`, which
/// makes this view invisible to it and leaves it to the SwiftUI content
/// underneath. That is what keeps the context menu (and the guards that
/// anchor on it) working with an AppKit view lying over the tab.
///
/// **The click, therefore, is this view's to forward.** A left click that
/// never exceeds the drag threshold is a selection, and it reaches the same
/// `onActivate` the tab's `.onTapGesture` calls for every part of the tab
/// this overlay does not cover. One closure, two regions, no second rule.
struct TabDragSourceView: NSViewRepresentable {
    /// Asked when a drag actually begins rather than when the body is
    /// built — which is also the moment the strip writes down which tab is
    /// being carried (`TabItemView.dragPayload()`).
    let makePayload: () -> TabDragPayload
    /// A left click that did not become a drag.
    let onActivate: () -> Void
    /// A drag that ended where nothing accepted it.
    let onDetach: () -> Void

    func makeNSView(context: Context) -> TabDragSourceNSView {
        let view = TabDragSourceNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: TabDragSourceNSView, context: Context) {
        apply(to: nsView)
    }

    /// Rewritten on every update, not only at creation: the three closures
    /// capture the tab this item currently draws, and a `ForEach` reuses
    /// its views across changes to the strip.
    private func apply(to view: TabDragSourceNSView) {
        view.makePayload = makePayload
        view.onActivate = onActivate
        view.onDetach = onDetach
    }
}

/// The `NSView` behind `TabDragSourceView` — see that type's doc comment
/// for where it sits and why.
final class TabDragSourceNSView: NSView, NSDraggingSource {
    /// How far the pointer must travel before a press becomes a drag. Below
    /// it the gesture is a click; there is no timer, so a press held still
    /// stays a click however long it lasts.
    private static let dragThreshold: CGFloat = 3

    var makePayload: (() -> TabDragPayload)?
    var onActivate: (() -> Void)?
    var onDetach: (() -> Void)?

    /// The press this view is currently tracking, kept because
    /// `beginDraggingSession(with:event:source:)` wants the event that
    /// STARTED the gesture, not the one that crossed the threshold.
    /// Cleared the moment the press resolves into either outcome, so
    /// neither can fire twice.
    private var pressEvent: NSEvent?

    // MARK: - Which events this view is visible to

    /// `nil` for everything but the three left-button events below, which
    /// makes this view transparent to the right-click that opens the tab's
    /// SwiftUI context menu and to the pointer moves that drive its hover
    /// state. `NSApp.currentEvent` is `nil` when AppKit asks outside an
    /// event — a cursor-rect update, say — and that is answered the same
    /// way, because a hit with no event to handle is a hit this view has no
    /// use for.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    // MARK: - Press, drag, click

    override func mouseDown(with event: NSEvent) {
        pressEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent else { return }
        let dx = event.locationInWindow.x - press.locationInWindow.x
        let dy = event.locationInWindow.y - press.locationInWindow.y
        guard (dx * dx + dy * dy).squareRoot() > Self.dragThreshold else { return }
        pressEvent = nil
        beginDrag(startedBy: press)
    }

    /// A press that never crossed the threshold is a selection. Guarded on
    /// the tracked press so that the `mouseUp` AppKit may deliver after a
    /// drag session does not select the tab a second time.
    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        pressEvent = nil
        onActivate?()
    }

    private func beginDrag(startedBy event: NSEvent) {
        guard let payload = makePayload?(),
            let writer = TabDragPasteboardWriter(payload: payload)
        else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// What the pointer carries: a snapshot of the tab region this view
    /// covers, taken from the SwiftUI content underneath it. `nil` when
    /// AppKit cannot make a cache representation, in which case the drag
    /// still runs — with no image under the pointer, which is a cosmetic
    /// loss and not a broken gesture.
    private func dragImage() -> NSImage? {
        guard let content = superview else { return nil }
        let region = convert(bounds, to: content)
        guard let representation = content.bitmapImageRepForCachingDisplay(in: region)
        else { return nil }
        content.cacheDisplay(in: region, to: representation)
        let image = NSImage(size: region.size)
        image.addRepresentation(representation)
        return image
    }

    // MARK: - NSDraggingSource

    /// `.move` inside this app — every destination that takes this payload
    /// moves the tab rather than copying it, and there is no such thing as
    /// a second copy of a live session.
    ///
    /// **`[]` outside it**, which is the source's own half of the Finder
    /// fix: with no operation offered, no other application can accept the
    /// drop at all, whatever it makes of the pasteboard type. The payload's
    /// private `UTType` is the other half, and neither is relied on alone.
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication: return .move
        case .outsideApplication: return []
        @unknown default: return []
        }
    }

    /// The report the whole AppKit detour exists for. A drop one of this
    /// app's strips accepted arrives here with a non-empty operation and is
    /// already done — SwiftUI delivered it, the registry moved the tab, and
    /// there is nothing left to do. An empty one means nothing took it, and
    /// `TabDropOutsidePlan` decides whether that counts as "outside every
    /// window of ours".
    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        guard
            TabDropOutsidePlan.detaches(
                operation: operation, endedAt: screenPoint,
                sourceWindowFrame: window?.frame)
        else { return }
        onDetach?()
    }
}
