import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The type a tab drag carries, and the only one it carries.
    ///
    /// **Exported, not merely declared.** `UTType(exportedAs:)` says this
    /// process OWNS the identifier; the matching `UTExportedTypeDeclarations`
    /// entry in `scripts/package-app` is what makes a packaged build say the
    /// same thing to the rest of the system. `TabDragTypeDeclarationTests`
    /// reads that script and pins the two spellings against each other, so
    /// the declaration cannot drift from the code that names it.
    ///
    /// **What it conforms to, and what it deliberately is not.**
    /// `public.data` and nothing more: no `public.text`, no
    /// `public.utf8-plain-text`, and no filename extension in the
    /// declaration. That combination is the whole of the Finder fix — see
    /// `TabDragPayload`'s own doc comment.
    static let macSCPTab = UTType(exportedAs: "dev.noix.macscp.tab")
}

/// What a dragged tab carries (Detachable Tabs plan, Task 3): the tab, and
/// the window it was dragged out of.
///
/// **Why the source window is in it at all.** A drop destination is told
/// only that something was let go on it. The strip that RECEIVES a drop is
/// the target window's, and it holds neither the source window's
/// `TabsViewModel` nor its `WindowID` — no window in this app has ever held
/// another's. So the drag is the only channel that can say where the tab
/// came from, and the target resolves the source's model out of
/// `TabRegistry` from that (`TabRegistry.model(for:)`).
///
/// It is also what tells a REORDER from a cross-window move: a payload
/// whose `sourceWindowID` is the receiving window's own is a drag that
/// never left its strip. `TabDropPlan.route(payload:ownWindow:)` is where
/// that comparison lives.
///
/// ## Carried as a type of this app's own, not as text
///
/// Until 2026-09-05 this envelope travelled as JSON *text*, through a
/// `.draggable(_:)` over `String` and a `dropDestination(for: String.self)`.
/// That was reported as a defect and it was one: **a `String` drag exports
/// `public.utf8-plain-text`**, the Finder accepts anything that conforms to
/// it, and dragging a tab onto the desktop therefore wrote a text clipping
/// file carrying this JSON — while no window opened, because nothing on the
/// SwiftUI side could learn that the drag had ended nowhere.
///
/// So the payload is a `Transferable` over a private `UTType`. Three
/// properties do the work, and they are worth stating separately because
/// each closes a different half of the report:
///
/// 1. **No text representation at all.** The only representation is the
///    `CodableRepresentation` below, so the drag advertises exactly
///    `dev.noix.macscp.tab` and nothing that any text destination accepts.
///    `TabDragTests` pins that the declared list is one entry long.
/// 2. **A private type nothing else claims.** `dev.noix.macscp.tab` is
///    exported by this app; no other app declares an importer for it, so
///    no other app offers to take the drop.
/// 3. **No filename extension in the declaration.** A Finder drop writes a
///    file named after the type's preferred extension; with none declared
///    there is nothing for it to write, which is the belt beside the two
///    braces above.
///
/// The drag SOURCE is AppKit now (`TabDragSourceView`), because the second
/// half of the report — "no new window opens" — needs
/// `NSDraggingSource.draggingSession(_:endedAt:operation:)`, which
/// `.draggable` does not vend. The pasteboard writer there offers this same
/// single type with this same JSON, so SwiftUI's `dropDestination(for:)`
/// reads it back unchanged: `CodableRepresentation` maps the content type
/// straight onto the pasteboard type, and its coder is a default
/// `JSONEncoder`/`JSONDecoder` pair — which is exactly what
/// `pasteboardData()` below produces.
struct TabDragPayload: Codable, Equatable, Sendable, Transferable {
    let tabID: UUID
    let sourceWindowID: WindowID

    init(tabID: UUID, sourceWindowID: WindowID) {
        self.tabID = tabID
        self.sourceWindowID = sourceWindowID
    }

    /// One representation, over one content type. Adding a second — a
    /// `ProxyRepresentation` to `String` for "convenience", say — would put
    /// `public.utf8-plain-text` back on the pasteboard and hand the Finder
    /// its clipping again.
    ///
    /// The return type is written unparameterised. `some
    /// TransferRepresentation<TabDragPayload>` — the spelling that names
    /// the item type — does not compile here (Swift 6.3.3, macOS 26.5 SDK,
    /// measured 2026-09-05): the conformance is rejected with "protocol
    /// requires nested type 'Representation'", because `CodableRepresentation`
    /// constrains its `Item` to `Transferable` and naming the item inside
    /// the very declaration that establishes that conformance closes the
    /// circle. Reproduced on a four-line file outside this package before
    /// being written down.
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .macSCPTab)
    }

    /// The bytes the AppKit drag source puts on the pasteboard, in the
    /// encoding `CodableRepresentation` decodes: a default `JSONEncoder`.
    ///
    /// `nil` cannot happen for two `UUID`s — `JSONEncoder` has nothing here
    /// to refuse — and the writer that calls this refuses to construct
    /// rather than offering an item with no data, so a drag either carries a
    /// readable payload or never begins.
    func pasteboardData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
