import Foundation

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
/// ## Carried as JSON text, through the destination the strip already had
///
/// The strip's drop destination is `dropDestination(for: String.self)` and
/// stays that way; `encoded()`/`init(encoded:)` are the whole of the wire
/// format. The alternative — a `Transferable` conformance with a `UTType`
/// of this app's own (`dev.noix.macscp.tab`) — was measured and rejected
/// for three reasons:
///
/// 1. **The reorder path would have to change type.** A second
///    `dropDestination` for a custom type beside the `String` one, or a
///    single destination over a new type, both rewrite the code path that
///    reorders tabs today. This payload has to be additive to that path,
///    not a replacement for it.
/// 2. **A custom `UTType` wants a declaration in the bundle.**
///    `Scripts/package-app` writes `UTExportedTypeDeclarations` by hand
///    (three entries today: sessions, logins, snippets), so a fourth would
///    be a packaging change for a type that never leaves the process — a
///    tab drag is meaningful only to the window that started it.
/// 3. **Text is what the other drags on this surface already speak.** The
///    session sidebar drags `SidebarDragPayload`'s own string spelling, and
///    a bare uuid is what this strip dragged before Task 3.
///    `TabDropPlan.route` still reads a bare uuid as a reorder, so nothing
///    that used to work stopped working.
///
/// What that costs: a tab dragged to the Finder still makes a text clipping,
/// as it did before, now carrying this JSON instead of a bare uuid. No path
/// there opens a window or touches any strip.
struct TabDragPayload: Codable, Equatable, Sendable {
    let tabID: UUID
    let sourceWindowID: WindowID

    init(tabID: UUID, sourceWindowID: WindowID) {
        self.tabID = tabID
        self.sourceWindowID = sourceWindowID
    }

    /// `nil` for anything that is not this envelope — a bare uuid, a file
    /// path, a sentence, an envelope missing either field. Refusing rather
    /// than filling a gap in is the point: a payload with a made-up source
    /// window would name a model the registry cannot resolve, and the drop
    /// would silently do nothing instead of falling through to the reorder
    /// route that a bare uuid correctly takes.
    init?(encoded: String) {
        guard let data = encoded.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(TabDragPayload.self, from: data)
        else { return nil }
        self = decoded
    }

    /// The string the drag carries. Encoding cannot fail for two `UUID`s —
    /// `JSONEncoder` has nothing here to refuse — so the fallback is a
    /// spelling `init?(encoded:)` will itself refuse, which routes the drop
    /// to nothing rather than to a wrong window.
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
