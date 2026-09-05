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
/// strip leaves the order as it was") into a window nobody asked for.
///
/// **"Outside" means outside EVERY window of ours** (fix round 2). Until
/// then the second fact was the SOURCE window's frame alone, and the
/// consequence contradicted what the feature says it does: a drop on
/// another of our windows but not on its strip — its file list, its
/// terminal, its sidebar — is accepted by nothing and lands outside the
/// source window, so the tab was detached into a THIRD window. A window of
/// ours was under the pointer; the drag did not land nowhere. It is a
/// no-op now, and the tab stays where it was. Which windows count is
/// `TabDropWindowFrames.ours(_:)`'s answer.
///
/// **What this cannot tell apart**, stated rather than implied: a drag
/// CANCELLED with Escape ends with an empty operation too, and AppKit
/// reports no reason. Cancelling over the desktop, or over another
/// application's window, therefore detaches. Cancelling over any window of
/// ours does not — which since round 2 is the larger half of the screen a
/// user is likely to be over.
enum TabDropOutsidePlan {
    /// Empty `ourWindowFrames` cannot happen while a drag one of those
    /// windows started is in flight; it answers "detach" then, because an
    /// empty operation is still an unaccepted drop and the second fact
    /// simply has nothing to say.
    ///
    /// `contains(where:)` over all of them rather than a comparison against
    /// one: the question is "is this point inside NONE of our windows", and
    /// consulting only the first would be the round-1 rule wearing the
    /// round-2 signature.
    static func detaches(
        operation: NSDragOperation, endedAt screenPoint: CGPoint,
        ourWindowFrames: [CGRect]
    ) -> Bool {
        guard operation.isEmpty else { return false }
        return ourWindowFrames.contains { $0.contains(screenPoint) } == false
    }
}

/// Which of the application's windows count as "ours" for the question
/// above.
///
/// A pure filter over four facts read off each `NSWindow`, because
/// `NSApp.windows` cannot be built in a test and a filter written inline
/// at the call site would be a rule nothing in this package could call.
///
/// **Three exclusions, and each has a reason of its own.**
///
/// A window that is not ordered in has no area a pointer can be inside,
/// and `NSApp.windows` holds plenty of them — windows AppKit keeps around
/// after a close, windows never shown. Counting one would make a drop onto
/// the desktop read as "inside a window of ours" whenever a stale frame
/// happened to cover the point, and the tab would stay put with nothing to
/// show for the gesture.
///
/// **A window on another Space is NOT one of those**, and assuming it was
/// is what fix round 3 corrected. `isVisible` reports whether a window is
/// ordered in, not whether the user can see it: a window on another Space
/// answers `true`. The case that matters is a second macSCP window left
/// FULL-SCREEN on another Space — ordered in, and carrying a screen-sized
/// frame that covers wherever the pointer happens to be. Every drop onto
/// the desktop would read as "inside a window of ours", and detach would
/// silently stop working, with no error and nothing on screen to explain
/// it. So `isOnActiveSpace` is asked separately: a frame on another Space
/// describes a rectangle in a place the pointer is not.
///
/// A panel is not a window a tab can live in: sheets, popovers, the font
/// and colour panels. A tab let go over one was let go over nothing that
/// could have taken it, so it gets a window of its own — which is the
/// answer for the desktop, and a panel is closer to the desktop here than
/// it is to a window with a strip.
enum TabDropWindowFrames {
    struct Candidate: Equatable {
        let frame: CGRect
        let isVisible: Bool
        let isOnActiveSpace: Bool
        let isPanel: Bool

        init(frame: CGRect, isVisible: Bool, isOnActiveSpace: Bool, isPanel: Bool) {
            self.frame = frame
            self.isVisible = isVisible
            self.isOnActiveSpace = isOnActiveSpace
            self.isPanel = isPanel
        }
    }

    static func ours(_ candidates: [Candidate]) -> [CGRect] {
        candidates
            .filter { $0.isVisible && $0.isOnActiveSpace && $0.isPanel == false }
            .map(\.frame)
    }
}

/// Which mouse events the drag overlay takes for itself, and which it
/// leaves to the SwiftUI tab underneath.
///
/// An `NSView` inside a SwiftUI hierarchy that answers `hitTest` takes the
/// event outright — the hosting view never sees it, and every SwiftUI
/// gesture on the content below stops working for that event. So this is
/// the narrowest question in the file, and it is asked here rather than
/// inside the override, where nothing in this package could call it.
///
/// **A left-button event carrying `.control` is a SECONDARY click**, and
/// that is the whole of what fix round 1 changed here. macOS delivers
/// control-click as `.leftMouseDown` with `.control` set; it is how the
/// context menu is opened on a one-button mouse, and how many people open
/// it on a trackpad. Claiming it by event type alone meant `mouseDown`
/// swallowed it and control-clicking a tab's label opened nothing —
/// exactly the failure the right-click exemption exists to prevent, in the
/// spelling nobody tried. All three left-button types are exempted, not
/// just the down: the modifier is carried on each of them, and an overlay
/// that let the down through but claimed the drag or the up would be
/// half-in on a gesture it must stay out of entirely.
///
/// The OTHER modifiers change nothing. `⌘`, `⇧` and `⌥` do not make a
/// secondary click, and a tab click is still a tab click while one is
/// held; "ignore modified clicks" is the obvious wrong generalisation of
/// the rule above, and `TabDragSourceDecisionTests` pins against it.
enum TabDragHitTestDecision {
    /// `eventType` is optional because `NSApp.currentEvent` is `nil` when
    /// AppKit asks outside an event — a cursor-rect update, say — and a hit
    /// with no event to handle is a hit this overlay has no use for.
    static func claims(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.control) == false else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return true
        default: return false
        }
    }
}

/// What the drag source offers a destination, per dragging context.
///
/// **`[.move, .copy]` within the application** (fix round 1). The tab is
/// always moved — there is no such thing as a second copy of a live
/// session, and `TabDetachSequence` is what actually runs — but the mask
/// is not a statement of intent, it is the set a destination may choose
/// from. SwiftUI's `dropDestination` negotiates its own operation and has
/// historically asked for `.copy`; a source offering `.move` alone can
/// therefore be REFUSED by one of this app's own strips. The consequence
/// was not a drop that quietly did nothing: the refused session ends with
/// an empty operation, the pointer is outside the source window's frame
/// for every drop on another window, and `TabDropOutsidePlan` reads that
/// pair as "landed nowhere" — so a move between two windows would have
/// detached into a THIRD one. Offering both leaves the destination free to
/// pick either, and nothing downstream reads which it picked.
///
/// **`[]` outside it**, unchanged: the source's own half of the Finder
/// fix. With no operation offered, no other application can accept the
/// drop at all, whatever it makes of the pasteboard type. The payload's
/// private `UTType` is the other half, and neither is relied on alone.
enum TabDragOperationMask {
    static func offered(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication: return [.move, .copy]
        case .outsideApplication: return []
        @unknown default: return []
        }
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
/// **What `hitTest` lets through.** Only an UNMODIFIED left-button event of
/// the three types this view actually handles — `TabDragHitTestDecision`
/// owns that rule and states why the modifier is part of it. Everything
/// else — the right-click that opens the tab's SwiftUI `.contextMenu`, the
/// control-click that opens the same menu, the moves that drive `.onHover`,
/// and a `hitTest` asked outside any event at all — is answered with `nil`,
/// which makes this view invisible to it and leaves it to the SwiftUI
/// content underneath. That is what keeps the context menu (and the guards
/// that anchor on it) working with an AppKit view lying over the tab.
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

    /// Asked of `TabDragHitTestDecision`, which carries the reasoning and
    /// is where `TabDragSourceDecisionTests` reaches it: `nil` for
    /// everything but an unmodified left-button event, which makes this
    /// view transparent to BOTH ways of opening the tab's SwiftUI context
    /// menu — the right-click and the control-click — and to the pointer
    /// moves that drive its hover state.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let event = NSApp.currentEvent
        guard
            TabDragHitTestDecision.claims(
                eventType: event?.type, modifiers: event?.modifierFlags ?? [])
        else { return nil }
        return super.hitTest(point)
    }

    /// A press on a tab of a window that is not in front is the gesture it
    /// looks like, not a throwaway that only brings the window forward.
    /// AppKit's default is `false`, so without this a drag from a
    /// background window's tab cost two gestures: one to activate, one to
    /// drag.
    ///
    /// What this does NOT change: the click still activates the window.
    /// AppKit orders a window front on a press regardless of this answer —
    /// `acceptsFirstMouse` decides whether that same press is ALSO
    /// delivered to the view, not whether the window comes forward. So a
    /// background tab dragged straight out both raises its window and
    /// starts the drag, and a background tab merely clicked both raises its
    /// window and selects the tab.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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

    /// The frames of every window this application currently shows on
    /// screen, in screen coordinates — the facts `TabDropOutsidePlan` needs
    /// and cannot gather, since it is pure and knows nothing of `NSApp`.
    ///
    /// Which windows count is `TabDropWindowFrames.ours(_:)`'s answer, not
    /// this function's: gathering and filtering are separated so the filter
    /// is reachable by a test, and so this function has nothing in it that
    /// could be wrong except the four facts it reads off each window.
    static func ourWindowFrames() -> [CGRect] {
        TabDropWindowFrames.ours(
            NSApp.windows.map {
                TabDropWindowFrames.Candidate(
                    frame: $0.frame, isVisible: $0.isVisible,
                    isOnActiveSpace: $0.isOnActiveSpace, isPanel: $0 is NSPanel)
            })
    }

    // MARK: - NSDraggingSource

    /// Asked of `TabDragOperationMask`, which carries the reasoning for
    /// both branches and is where `TabDragSourceDecisionTests` reaches
    /// them.
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        TabDragOperationMask.offered(for: context)
    }

    /// The report the whole AppKit detour exists for. A drop one of this
    /// app's strips accepted arrives here with a non-empty operation and is
    /// already done — SwiftUI delivered it, the registry moved the tab, and
    /// there is nothing left to do. An empty one means nothing took it, and
    /// `TabDropOutsidePlan` decides whether that counts as "outside every
    /// window of ours" — asked with every one of their frames, not just
    /// this view's own (fix round 2).
    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        guard
            TabDropOutsidePlan.detaches(
                operation: operation, endedAt: screenPoint,
                ourWindowFrames: Self.ourWindowFrames())
        else { return }
        onDetach?()
    }
}
