import SwiftUI
import macSCPCore

/// What a dragged sidebar row carries, and how a drop reads it back.
///
/// The App-layer counterpart of `TabDropPlan`, and it exists for the same
/// reason: a SwiftUI drop destination is told only THAT something is over it,
/// and the payload is readable only once the drop happens — so the payload is
/// the one place a dragged row can say what it is.
///
/// It names a `SidebarItem` rather than a bare uuid because the sidebar's two
/// gestures act on two KINDS of row (see `SidebarDropTargetPlan`). A bare
/// uuid would leave the kind to a lookup, and a lookup that misses — a row
/// deleted while the drag was in the air — is indistinguishable from a lookup
/// for the other kind.
///
/// The tab strip carries a bare uuid (`TabItemView.dragPayload`), which this
/// deliberately does not parse: a tab dropped on the sidebar names no row
/// here, and a sidebar row dropped on the strip is not a tab id there. Two
/// surfaces, two spellings, neither able to move the other's rows.
enum SidebarDragPayload {
    private static let groupPrefix = "macscp.sidebar.group:"
    private static let sessionPrefix = "macscp.sidebar.session:"

    static func text(for item: SidebarItem) -> String {
        switch item {
        case .group(let id): return groupPrefix + id.uuidString
        case .session(let id): return sessionPrefix + id.uuidString
        }
    }

    /// A drag carries one row, so anything past the first item belongs to a
    /// gesture this sidebar did not produce; the first item is what is read.
    /// Anything that is not one of the two spellings names nothing.
    static func item(from payload: [String]) -> SidebarItem? {
        guard let first = payload.first else { return nil }
        if let raw = first.dropping(prefix: groupPrefix), let id = UUID(uuidString: raw) {
            return .group(id)
        }
        if let raw = first.dropping(prefix: sessionPrefix), let id = UUID(uuidString: raw) {
            return .session(id)
        }
        return nil
    }
}

extension String {
    /// The rest of the string after `prefix`, or `nil` when it does not start
    /// with it — the presence check and the removal in one step, so the two
    /// cannot name different prefixes.
    fileprivate func dropping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// Which row the drag currently in flight started from.
///
/// **Why this exists at all.** A drop destination is told only THAT something
/// is over it: `isTargeted:` hands over a `Bool`, and the payload is readable
/// only once the drop happens. The one place the sidebar can see which row is
/// being carried is the drag's own payload, so that is where it is written
/// down.
///
/// **Why a box and not `@State`.** `draggable(_:)` takes its payload as an
/// `@autoclosure @escaping` closure and calls it when the drag begins, not
/// when the body is built. If that ever stopped holding, a `@State` write
/// there would invalidate the body that just made it, and two rows writing
/// two different values would keep invalidating each other. Writing to a
/// plain reference invalidates nothing, which turns that whole class of
/// failure into at worst a wrong answer for one row's highlight.
///
/// **What it is worth.** The value is never cleared: a cancelled drag leaves
/// the last dragged row named here. That is harmless for the question it is
/// asked — every drag overwrites it before the first target is reported — and
/// it is why the row is compared rather than tested for presence. Same shape,
/// and the same limits, as `TabDragOrigin`.
final class SidebarDragOrigin {
    var draggedItem: SidebarItem?
}

/// What letting go on one row would do, and therefore how that row is drawn
/// while a drag is over it.
///
/// A type rather than a ternary in a view body, the same split
/// `TabBackgroundPlan` and `SessionRowHighlight` already make: a precedence
/// decision written inside a `body` is one no test can reach.
///
/// **The two answers are the two gestures the design names**, and they are
/// distinguished by the KIND of row under the pointer rather than by where in
/// the row the pointer sits. That is the whole reason this sidebar draws no
/// insertion line: a place between two rows is a number, and the number
/// carried through a view was the defect class `SidebarOrdering`'s doc
/// comment records. A folder says "inside me"; a connection says "in my
/// place".
///
/// **A row is never a target for its own drag.** `SidebarOrdering.moved`
/// returns the tree untouched when a row is dropped on itself, so
/// highlighting it would promise a move that will not happen — the same rule
/// `TabBackgroundPlan` states for the strip.
///
/// **What this leaves unpromised.** Dropping a folder into one of its own
/// descendants is refused (`MoveRefusal.wouldCycle`) and still highlights,
/// because that refusal is a fact about the whole tree and this decision sees
/// two rows. The refusal is not silent — `SessionListViewModel` puts it on
/// screen as the sidebar's own error line — so the gesture ends in a reason
/// rather than in nothing, which is the same bargain the tab strip makes for
/// a payload it cannot identify until the drop.
///
/// Colour is not the only carrier: both live answers also draw a border,
/// which is a change in shape rather than in hue.
enum SidebarDropTargetPlan: Equatable {
    /// The row under the pointer is a folder: the dragged row lands inside
    /// it, after whatever is already there.
    case intoFolder
    /// The row under the pointer is a connection: the dragged row takes its
    /// place among its siblings.
    case beforeRow
    /// Nothing is over this row, or what is over it is the row itself.
    case none

    static func build(
        row: SidebarItem, isTargeted: Bool, dragged: SidebarItem?
    ) -> SidebarDropTargetPlan {
        guard isTargeted, dragged != row else { return .none }
        switch row {
        case .group: return .intoFolder
        case .session: return .beforeRow
        }
    }

    /// The surface each answer draws. Here rather than in the row so that the
    /// one claim a test CAN make about a highlight it cannot see — that the
    /// three answers are three different surfaces, so the two meanings are
    /// told apart and neither is a repainted default — is reachable
    /// (`SidebarDropTargetPlanTests`).
    var fill: Color {
        switch self {
        case .intoFolder: return DesignTokens.remoteSoft
        case .beforeRow: return DesignTokens.localSoft
        case .none: return Color.clear
        }
    }

    /// The second channel, so neither answer is carried by hue alone. Drawn
    /// unconditionally by the row, which is what keeps "only a drop target
    /// has a border" here rather than in an `if` in a view body.
    var borderColor: Color {
        switch self {
        case .intoFolder: return DesignTokens.remoteBlue
        case .beforeRow: return DesignTokens.localAmber
        case .none: return Color.clear
        }
    }
}

/// Whether a folder offers its one-shot "sort by name" entry.
///
/// A type rather than an `if` in the menu body, the same move
/// `SessionRowTerminalMenuPlan` makes next door and for the same reason: a
/// visibility decision that only exists inside a SwiftUI body is a decision
/// no test can reach.
///
/// HIDDEN, never greyed out — this project's standing rule. Sorting fewer
/// than two rows can only produce the order that is already there, so the
/// entry would be an offer that does nothing; a dead entry explains nothing
/// about why it is dead, and unlike the "Snippet" submenu next door there is
/// no reason inside it worth keeping reachable.
///
/// The count it is given is the folder's REAL children, not the ones a tag
/// filter left on screen: the sort rewrites the whole folder, so a folder
/// showing one row while holding three has something to sort.
///
/// Untested claim, stated rather than implied: that the folder row really
/// draws the entry for `.shown` and omits it for `.hidden`. This type only
/// proves which answer a count maps to — the drawing is view code, and this
/// project has no rendering harness (the same boundary
/// `SessionRowTerminalMenuPlan` states for itself).
enum SidebarSortMenuPlan: Equatable {
    case hidden
    case shown

    var isShown: Bool { self == .shown }

    static func build(childCount: Int) -> SidebarSortMenuPlan {
        childCount > 1 ? .shown : .hidden
    }
}
