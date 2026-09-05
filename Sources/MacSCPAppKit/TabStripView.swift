import SwiftUI
import macSCPCore

/// The window tab strip (M8a) — between toolbar and pane heads. Pure
/// rendering: all rules live in `TabsViewModel`/`SessionTab`.
struct TabStripView: View {
    let tabs: [SessionTab]
    let activeTabID: UUID
    let onActivate: (UUID) -> Void
    let onClose: (SessionTab) -> Void
    let onAdd: () -> Void
    /// Which entries one tab's context menu offers. Asked, not decided:
    /// the strip has no idea what an entry means or when it applies, and
    /// it cannot supply the facts wrongly either, because it supplies
    /// none — the answer is computed where the model is.
    let menuEntries: (SessionTab) -> [TabMenuEntry]
    /// One route out of the tab context menu for every entry the menu can
    /// draw. The strip does not know what any entry means — it hands the
    /// tab and the chosen `TabMenuEntry` back to `ContentView`, which owns
    /// the tab lifecycle those actions run through.
    let onMenuEntry: (SessionTab, TabMenuEntry) -> Void
    /// The THIRD way a tab leaves this window (drag-detach fix,
    /// 2026-09-05): its drag ended where nothing accepted it, so it gets a
    /// window of its own. The strip decides none of that — the route it is
    /// handed is `ContentView.moveToNewWindow(_:)`, the same one the tab
    /// context menu's "Move Tab to New Window" entry and the Window menu
    /// already take, so a detached tab travels exactly one path however the
    /// user asked for it.
    let onDetachToNewWindow: (SessionTab) -> Void
    /// The one route out of a tab drop, in the only two things a drop
    /// knows: the id the payload carried, and the tab it was let go on.
    /// **No position travels this way**, which is what makes shifting one
    /// impossible rather than detectable — see `TabsViewModel.move(tabID:onto:)`.
    /// The two are of different types so that handing them over the wrong
    /// way round does not compile.
    let onReorder: (UUID, SessionTab) -> Void
    /// Which window this strip is drawing (Detachable Tabs plan, Task 3).
    /// The strip does not act on it: it puts it into the drag payload and
    /// hands it to `TabDropPlan.route(payload:ownWindow:)`, which is where
    /// "this window" and "another window" are told apart. Without it every
    /// drop would look alike, because a drop destination is told only that
    /// something was let go on it.
    let windowID: WindowID
    /// The second route out of a tab drop (Task 3): a tab dragged here from
    /// ANOTHER window's strip. Where it comes from is in the payload; what
    /// the move costs — the registry lookup, the close decision on the
    /// window it left — is `ContentView.acceptDroppedTab(_:)`'s, exactly as
    /// the reorder's landing position is `TabsViewModel`'s.
    let onDropFromOtherWindow: (TabDragPayload) -> Void

    /// Which tab the drag in flight is carrying — written where the drag
    /// starts, read where a drop is targeted. See `TabDragOrigin` for why
    /// it is a box rather than state, and for what it is worth.
    @State private var dragOrigin = TabDragOrigin()

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Not enumerated. The menu's move and bulk-close entries
                    // are still decided from a tab's position and the total
                    // count, but both are read off the model where the answer
                    // is computed; a position that never enters this view
                    // cannot be shifted inside it.
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            dragOrigin: dragOrigin,
                            onActivate: { onActivate(tab.id) },
                            onClose: { onClose(tab) },
                            menuEntries: { menuEntries(tab) },
                            onMenuEntry: { entry in onMenuEntry(tab, entry) },
                            onDetachToNewWindow: onDetachToNewWindow,
                            onReorder: onReorder,
                            windowID: windowID,
                            onDropFromOtherWindow: onDropFromOtherWindow)
                    }
                }
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.inkTertiary)
            .help(L10n.string("tabs.newTabHelp", "New tab (⌘N)"))
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        // The mockup's "paper" (window ground) token had no consumer left
        // after M6a and was dropped from `DesignTokens`; there is no custom
        // replacement, so the strip uses the same surface the rest of the
        // window falls back to when nothing overrides it: the system
        // window background.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
        }
    }
}

/// What the tab strip's liveness dot shows for one `ConnectionLiveness?`
/// (connection-liveness plan, Task 5): a color and, since colour is never
/// the only carrier of the message, a `.help` tooltip and a VoiceOver
/// label for every state. Kept as a plain, testable mapping — same move as
/// `SnippetListPlan` (Core) and `LivenessProbeCoverage`
/// (`ContentView+Detail.swift`) — because this project has no SwiftUI
/// rendering harness: nothing here can pin what actually lands on screen,
/// but this function is the part a test CAN call directly and check.
enum LivenessDotPlan {
    struct Appearance: Equatable {
        let color: Color
        let helpKey: String
        let helpDefault: String
        let accessibilityLabelKey: String
        let accessibilityLabelDefault: String
    }

    /// `nil` when there is nothing to show — no dot at all, not some
    /// neutral fifth color. `SessionTab.liveness` is `nil` both before a
    /// tab's first connect attempt and after `ContentView.teardown(_:)`
    /// deliberately clears it (see that property's own doc comment): both
    /// describe a tab with no session to report on, which is exactly what
    /// today's tab strip already shows with nothing but italic, dimmed
    /// title text. A dot claiming a status for a session that is not
    /// currently being described would be a false signal, not a missing
    /// one, so this returns `nil` rather than falling back to any of the
    /// four real states.
    static func appearance(for liveness: ConnectionLiveness?) -> Appearance? {
        guard let liveness else { return nil }
        switch liveness {
        case .connecting:
            return Appearance(
                color: DesignTokens.statusAmber,
                helpKey: "tabs.liveness.connectingHelp", helpDefault: "Connecting…",
                accessibilityLabelKey: "tabs.liveness.connectingA11y", accessibilityLabelDefault: "connecting")
        case .connected:
            return Appearance(
                color: DesignTokens.statusPhosphor,
                helpKey: "tabs.liveness.connectedHelp", helpDefault: "Connected",
                accessibilityLabelKey: "tabs.liveness.connectedA11y", accessibilityLabelDefault: "connected")
        case .degraded:
            return Appearance(
                color: DesignTokens.statusAmber,
                helpKey: "tabs.liveness.degradedHelp", helpDefault: "Not responding — checking again…",
                accessibilityLabelKey: "tabs.liveness.degradedA11y",
                accessibilityLabelDefault: "not responding, checking again")
        case .lost:
            return Appearance(
                color: DesignTokens.statusLost,
                helpKey: "tabs.liveness.lostHelp", helpDefault: "Connection lost",
                accessibilityLabelKey: "tabs.liveness.lostA11y", accessibilityLabelDefault: "connection lost")
        }
    }
}

/// What the tab strip's SECOND dot shows — the pre-existing activity/
/// attention indicator, not the liveness dot above (`LivenessDotPlan`).
///
/// Pulled out of `TabItemView.indicator` for this project's usual reason
/// (nothing renders SwiftUI in a test) and for one specific rule this task
/// added, which is invisible from inside either view: while a tab's
/// connection reads `.lost`, the attention dot is suppressed.
///
/// The maintainer's reasoning, 2026-08-21: the drop EXPLAINS the failed
/// transfer. The liveness dot is already red and already says "connection
/// lost"; a second red dot immediately beside it, saying "needs attention"
/// about the transfer that failed BECAUSE of it, tells the same news twice
/// in the same colour. The attention state itself is not cleared, only
/// hidden — `SessionTab.seenFailureCount` is untouched, so the dot comes
/// back the moment the tab is connected again with failures still unseen.
enum TabIndicatorPlan {
    enum Indicator: Equatable { case none, upload, download, attention }

    /// Attention (static red) wins over activity, as it always has;
    /// activity direction is the caller's `isUploading`, read from
    /// `TransferQueueViewModel.displayDirection`.
    ///
    /// Only `.attention` is suppressed by `.lost`, not the activity cases:
    /// suppressing those would be a claim about what a torn-down tab's
    /// queue can be doing, and this function is not the place that knows
    /// it. In practice `ContentView.teardown(_:)` has already run
    /// `cancelAll(reason:)` by the time a tab reads `.lost`, so the activity
    /// branch answers `.none` on its own — by fact, not by a second rule
    /// here that could disagree with it.
    static func indicator(
        liveness: ConnectionLiveness?, hasConflictPrompt: Bool,
        hasUnseenFailures: Bool, queueIsActive: Bool, isUploading: Bool
    ) -> Indicator {
        if (hasConflictPrompt || hasUnseenFailures) && liveness != .lost {
            return .attention
        }
        guard queueIsActive else { return .none }
        return isUploading ? .upload : .download
    }
}

/// The one question a tab drop asks that is not an identity: which tab a
/// dropped payload names.
///
/// Pulled out for the same reason as `LivenessDotPlan` and
/// `TabIndicatorPlan` — this project has no SwiftUI rendering harness, so
/// a rule written into a gesture closure is a rule nothing can call.
///
/// **Where the tab lands is deliberately not here, and no longer anywhere
/// in this layer.** The drop reports the tab it was let go on;
/// `TabsViewModel.move(tabID:onto:)` derives the position from the array
/// that defines it. Nothing between the gesture and the model holds an
/// index, so nothing between them can shift one.
enum TabDropPlan {
    /// The tab a drop payload names, or `nil` for a drop that carried
    /// nothing.
    ///
    /// **There is only one spelling left to read.** Until 2026-09-05 the
    /// destination took `String`, and this function told three of them
    /// apart: the JSON envelope, the bare uuid the strip dragged before
    /// Task 3, and everything else. The destination now takes
    /// `TabDragPayload` itself over a `UTType` of this app's own, so the
    /// system decides what may arrive here at all — a line of text, a file,
    /// a session row from the sidebar (`SidebarDragPayload`, a `String`)
    /// reach no destination on this strip and no closure of ours runs for
    /// them. That is a stronger refusal than the parse that used to stand
    /// here, and it is the same change that stopped the Finder accepting
    /// the drag (see `TabDragPayload`).
    ///
    /// A drag carries one tab, so anything past the first item belongs to a
    /// gesture this strip did not start; the first item is what is read.
    /// What is still NOT filtered is an id naming no tab this strip
    /// renders: `move(tabID:onto:)` leaves the order alone for an id it
    /// does not know, and the tabs the strip renders are not this type's to
    /// know.
    static func draggedTabID(from payload: [TabDragPayload]) -> UUID? {
        payload.first?.tabID
    }

    /// What a drop on this strip should DO — the whole decision, taken from
    /// the payload and the receiving window's own id (Detachable Tabs plan,
    /// Task 3).
    ///
    /// The strip cannot take it: a drop destination is told only that
    /// something was let go on it, so the payload is the only evidence there
    /// is, and reading it is the last moment anything can be decided. The
    /// three answers are the three things a drop can be worth.
    ///
    /// **`.none` is now only the empty drop.** Since the destination reads
    /// this app's own type, nothing a user can carry from elsewhere — a
    /// line of text, a file, a session row from the sidebar — reaches this
    /// function at all; the system refuses it a step earlier. What remains
    /// is a payload this strip produced, and the one question left is which
    /// window produced it.
    ///
    /// Built ON `draggedTabID(from:)` rather than beside it: which tab a
    /// payload names is that function's, and stays pinned by
    /// `TabDropPlanTests` alone. What is added here is one comparison, and
    /// it is the only thing this function decides.
    static func route(payload: [TabDragPayload], ownWindow: WindowID) -> TabDropRoute {
        guard let first = payload.first else { return .none }
        if first.sourceWindowID != ownWindow { return .acrossWindows(first) }
        guard let id = draggedTabID(from: payload) else { return .none }
        return .reorder(id)
    }

}

/// The three things a drop on a tab can be worth — see
/// `TabDropPlan.route(payload:ownWindow:)`, which is the only thing that
/// makes one.
enum TabDropRoute: Equatable {
    /// A drag that never left this window's strip: the named tab takes the
    /// position of the tab it was let go on.
    case reorder(UUID)
    /// A tab dragged in from another window's strip.
    case acrossWindows(TabDragPayload)
    /// Nothing this strip produced, and nothing it can act on.
    case none
}

/// Which tab the drag currently in flight started from.
///
/// **Why this exists at all.** A drop destination is told only THAT
/// something is over it, never what: `isTargeted:` hands over a `Bool`, and
/// the payload is readable only once the drop happens. The one place the
/// strip can see which tab is being carried is the drag's own payload, so
/// that is where it is written down — `TabItemView.dragPayload()`.
///
/// **Why a box and not `@State`.** `draggable(_:)` takes its payload as an
/// `@autoclosure @escaping` closure and calls it when the drag begins, not
/// when the body is built. If that ever stopped holding, a `@State` write
/// there would invalidate the body that just made it, and two tabs writing
/// two different ids would keep invalidating each other. Writing to a plain
/// reference invalidates nothing, which turns that whole class of failure
/// into at worst a wrong answer for one tab's highlight.
///
/// **What it is worth.** The value is never cleared: a drag that is
/// cancelled leaves the last dragged tab named here. That is harmless for
/// the question it is asked — every drag of a tab overwrites it before the
/// first target is reported — and it is why the id is compared rather than
/// tested for presence: a stale name is not evidence that a drag is in
/// flight. See `TabBackgroundPlan.build` for what is and is not promised
/// because of that.
final class TabDragOrigin {
    var draggedTabID: UUID?
}

/// Which background one tab draws, and which of the reasons to draw one
/// wins when more than one holds at once — the same split as
/// `SessionRowHighlight`, and for the same reason: precedence is a
/// decision, and one written as a ternary chain inside a view body is one
/// no test can reach.
///
/// **The precedence: a drop target outranks the active tab.** The drop
/// highlight answers a question that exists only while a drag is in flight
/// — "does letting go here do something, and where does it land" — and it
/// has to be answerable on any tab, the active one included. Nothing is
/// lost by letting it take the background: the active tab keeps two
/// channels of its own that no background touches, its blue underline and
/// its semibold ink title, exactly as `SessionRowHighlight` lets the
/// selection outrank the connected session.
///
/// **A tab is never a drop target for its own drag.**
/// `TabsViewModel.move(tabID:onto:)` leaves the order alone when the two
/// ids are the same, so highlighting there would promise a move that will
/// not happen.
///
/// Colour is not the only carrier: the drop target also draws a border,
/// which is a change in shape rather than in hue.
enum TabBackgroundPlan: Equatable {
    case dropTarget
    case active
    case plain

    /// `draggedTabID` is what `TabDragOrigin` last recorded, and `tabID`
    /// the tab being drawn.
    ///
    /// The comparison is between two identities, never a presence test: an
    /// origin is left behind by a finished drag, so "some id is recorded"
    /// says nothing about whether a drag is in flight, while "the recorded
    /// id is this tab" is exactly the case that must not be highlighted.
    ///
    /// **What that leaves unpromised.** A payload from outside this strip
    /// — a sidebar row dragged over the strip carries a string too, in
    /// `SidebarDragPayload`'s own spelling — targets a tab like any other
    /// drag and is highlighted like one, while its drop moves nothing,
    /// because `TabDropPlan.draggedTabID` reads no tab id out of it.
    /// Telling the two apart needs the payload, and the payload is not
    /// readable until the drop.
    static func build(
        isActive: Bool, isDropTargeted: Bool, draggedTabID: UUID?, tabID: UUID
    ) -> TabBackgroundPlan {
        if isDropTargeted && draggedTabID != tabID { return .dropTarget }
        return isActive ? .active : .plain
    }

    /// The surface each case draws. Here rather than in the item so that
    /// the one claim a test CAN make about a background it cannot see —
    /// that the three cases are three different colours, so the drop
    /// target is a distinction and not a repainted default — is reachable
    /// (`TabBackgroundPlanTests`).
    var fill: Color {
        switch self {
        case .dropTarget: return DesignTokens.remoteSoft
        case .active: return DesignTokens.card
        case .plain: return Color.clear
        }
    }

    /// The second channel, so the drop target is not carried by hue alone.
    /// Drawn unconditionally by the item, which is what keeps the "only the
    /// drop target has a border" rule here rather than in an `if` in a view
    /// body.
    var borderColor: Color {
        switch self {
        case .dropTarget: return DesignTokens.remoteBlue
        case .active, .plain: return Color.clear
        }
    }
}

/// The localized title for one `TabMenuEntry`. A TOTAL mapping: every case
/// answers a string, and there is no way to answer "nothing". Which entries
/// exist at all is `TabContextMenu.entries`' decision, made in Core and
/// tested there — this type only names them.
enum TabMenuEntryTitle {
    static func title(for entry: TabMenuEntry) -> String {
        switch entry {
        case .close:
            return L10n.string("tabs.menu.close", "Close Tab")
        case .closeOthers:
            return L10n.string("tabs.menu.closeOthers", "Close Other Tabs")
        case .move(.left):
            return L10n.string("tabs.menu.moveLeft", "Move Left")
        case .move(.right):
            return L10n.string("tabs.menu.moveRight", "Move Right")
        // The same key the Window menu's own entry resolves
        // (`MacSCPApp.swift`) — one string for one action, so the two
        // surfaces cannot come to name it differently.
        case .moveToNewWindow:
            return L10n.string("window.moveTabToNewWindow", "Move Tab to New Window")
        case .pane(.files, .show):
            return L10n.string("tabs.menu.showFiles", "Show Files")
        case .pane(.files, .hide):
            return L10n.string("tabs.menu.hideFiles", "Hide Files")
        case .pane(.terminal, .show):
            return L10n.string("tabs.menu.showTerminal", "Show Terminal")
        case .pane(.terminal, .hide):
            return L10n.string("tabs.menu.hideTerminal", "Hide Terminal")
        case .openExternalTerminal:
            return L10n.string("tabs.menu.openExternalTerminal", "Open in External Terminal")
        case .saveAsSession:
            return L10n.string("tabs.menu.saveAsSession", "Save as Session…")
        }
    }
}

private struct TabItemView: View {
    let tab: SessionTab
    let isActive: Bool
    /// The strip's shared note of which tab a drag is carrying — written by
    /// this item's own `dragPayload()`, read when a drop is targeted here.
    let dragOrigin: TabDragOrigin
    let onActivate: () -> Void
    let onClose: () -> Void
    /// This tab's menu entries, asked for when the menu opens rather than
    /// computed for every tab on every repaint.
    let menuEntries: () -> [TabMenuEntry]
    let onMenuEntry: (TabMenuEntry) -> Void
    /// Handed straight through from the strip, like the three below it —
    /// `TabStripView`'s own properties document them.
    let onDetachToNewWindow: (SessionTab) -> Void
    let onReorder: (UUID, SessionTab) -> Void
    let windowID: WindowID
    let onDropFromOtherWindow: (TabDragPayload) -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    /// Whether a drag is over this tab right now — the raw answer of the
    /// drop's `isTargeted:` closure, kept raw so that what it MEANS is
    /// `TabBackgroundPlan`'s to say.
    @State private var isDropTargeted = false

    /// The activity/attention dot, decided by `TabIndicatorPlan` — see that
    /// type's own doc comment for the rules, including the `.lost`
    /// suppression this view cannot state on its own.
    ///
    /// The attention comparison uses `totalFailureCount` (monotonic), not the
    /// old item-based `failedCount`: `clearCompleted()` removes `.failed`
    /// items, so a `failedCount`-based watermark could get "stuck" — visit
    /// (seen = totalFailureCount), clean up (removes the failed items),
    /// then a NEW failure would still compare against the same absolute
    /// count and never re-trigger. `totalFailureCount` only ever grows, so
    /// this comparison always detects a genuinely new failure (M8a T5
    /// review, finding 2).
    ///
    /// `displayDirection` (spec 2): the last-started item's direction while
    /// something is running, falling back to the first queued item's
    /// direction otherwise — see that property's doc comment (M8a T5 review
    /// finding 4).
    private var indicator: TabIndicatorPlan.Indicator {
        // Tab indicator decision (connection-liveness plan, Task 7)
        TabIndicatorPlan.indicator(
            liveness: tab.liveness,
            hasConflictPrompt: tab.conflictBridge.currentPrompt != nil,
            hasUnseenFailures: tab.transferQueue.totalFailureCount > tab.seenFailureCount,
            queueIsActive: tab.transferQueue.isActive,
            isUploading: tab.transferQueue.displayDirection == .upload)
    }

    var body: some View {
        HStack(spacing: 7) {
            // The label and the close button are separated so that the drag
            // source can lie over the first without lying over the second.
            // An `NSView` that answers `hitTest` takes the mouse event
            // outright, and a ✕ underneath one would never be clickable —
            // see `TabDragSourceView`'s own doc comment. The inner stack
            // holds exactly what the outer one used to hold before the
            // button, in the same order and at the same spacing, and the
            // title is still the only flexible child, so the layout is the
            // one that was there.
            label
                .contentShape(Rectangle())
                .overlay {
                    TabDragSourceView(
                        makePayload: dragPayload,
                        onActivate: onActivate,
                        onDetach: { onDetachToNewWindow(tab) })
                }
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.inkTertiary)
                .help(L10n.string("tabs.closeTabHelp", "Close tab (⌘W)"))
            } else {
                Color.clear.frame(width: 15, height: 15)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, maxWidth: 200, maxHeight: .infinity)
        // The surface and the border are both `TabBackgroundPlan`'s answer,
        // drawn without a condition of this view's own — including which
        // case has a border at all, which is why the stroke is attached
        // unconditionally and reads `.clear` for the other two.
        .background(background.fill)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(DesignTokens.remoteBlue).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            if !isActive { Rectangle().fill(DesignTokens.hairline).frame(width: 1) }
        }
        .overlay { Rectangle().strokeBorder(background.borderColor, lineWidth: 2) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        // Dragging, in two halves: the tab carries its own id and the
        // window it lives in, and what a drop does with that is
        // `TabDropPlan.route`'s answer — this one's position for a drag
        // that started here, a hand-over to the window for a drag that
        // started in another one.
        //
        // The session sidebar's rows carry a prefixed spelling of their own
        // (`SidebarDragPayload`), because a row there is a folder or a
        // connection and the drop has to know which. Neither surface parses
        // the other's payload, and the consequence is worth stating in the
        // direction that reaches this closure: a sidebar row let go on a
        // tab is refused here, not merely ignored downstream — `route`
        // answers `.none` and this closure returns `false`.
        //
        // The drop also reports whether a drag is over this tab, which is
        // the whole of the feedback a drop destination gets: a `Bool`, with
        // nothing in it about what is being carried. What that `Bool` means
        // for the tab's background is `TabBackgroundPlan`'s to say.
        //
        // Only tabs are drop targets, which is what makes a drop into the
        // empty space of the strip leave the order as it was — there is
        // nothing there to drop onto, so no destination is ever computed
        // for it.
        //
        // What a tab dragged OUT of the app does is no longer bounded but
        // refused, which is the drag-detach fix of 2026-09-05. The payload
        // used to be a string: the system let it land wherever text was
        // accepted, and the Finder wrote a clipping carrying it while no
        // window opened. It is now a type of this app's own, offered under
        // no operation at all outside the process, and a drag that ends
        // where nothing took it hands the tab to a window of its own
        // instead. `TabDragPayload` and `TabDragSourceView` carry the whole
        // reasoning; the drag SOURCE is the AppKit overlay attached above,
        // not a modifier here.
        //
        // The reverse direction stays refused for the mirror-image reason:
        // the session sidebar reads its drops through `SidebarDragPayload`,
        // a string, which this envelope is not, so a tab dropped there names
        // no row.
        .dropDestination(for: TabDragPayload.self) { payload, _ in
            // Reads the payload and routes; decides nothing else. Where this
            // tab sits is `TabsViewModel.move(tabID:onto:)`'s answer, and
            // what a tab arriving from another window costs is
            // `ContentView.acceptDroppedTab(_:)`'s.
            switch TabDropPlan.route(payload: payload, ownWindow: windowID) {
            case .reorder(let draggedID):
                onReorder(draggedID, tab)
                return true
            case .acrossWindows(let carried):
                onDropFromOtherWindow(carried)
                return true
            case .none:
                return false
            }
        } isTargeted: { isDropTargeted = $0 }
        // The tab context menu. Everything about WHICH entries appear was
        // answered before this view saw it, and is drawn here without a
        // single condition of this view's own: no `if` around an item, no
        // filter over the list, no `.disabled` standing in for a missing
        // entry (the design rejects greyed-out entries outright). A rule
        // spelled a second time here is a rule that can disagree with the
        // one Core tests — which is what `TabContextMenuWiringGuardTests`
        // watches this closure for.
        //
        // The facts the answer is made of are not this view's to hand over
        // any more either: it has neither a position nor a count to get
        // wrong.
        .contextMenu {
            ForEach(Array(menuEntries().enumerated()), id: \.offset) { _, entry in
                Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    /// Everything in the tab except the close button: the two dots, the
    /// title and the protocol badge. Greedy, so it takes the width the
    /// close button leaves and the title inside it truncates exactly as it
    /// did while these were the outer stack's own children.
    @ViewBuilder
    private var label: some View {
        HStack(spacing: 7) {
            livenessDot
            switch indicator {
            case .none: EmptyView()
            case .upload: dot(DesignTokens.localAmber, pulse: true)
            case .download: dot(DesignTokens.remoteBlue, pulse: true)
            case .attention: dot(.red, pulse: false)
            }
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .italic(!tab.isConnected)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(
                    isActive ? DesignTokens.ink
                    : tab.isConnected ? DesignTokens.inkSecondary : DesignTokens.inkTertiary)
            // Protocol badge (M12/T7b): same small-label typography as the
            // sidebar's own badge — "SSH"/"S3" from the backend descriptor.
            Text(kindBadgeLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DesignTokens.inkTertiary)
        }
    }

    /// This tab's surface, decided by `TabBackgroundPlan` — see that type's
    /// own doc comment for the precedence, and for what a highlight does
    /// and does not promise.
    private var background: TabBackgroundPlan {
        TabBackgroundPlan.build(
            isActive: isActive,
            isDropTargeted: isDropTargeted,
            draggedTabID: dragOrigin.draggedTabID,
            tabID: tab.id)
    }

    /// The payload a drag of this tab carries — and the one moment the
    /// strip can learn WHICH tab is being carried, because a drop
    /// destination is told only that something is over it.
    ///
    /// Handed to `TabDragSourceView` as a function rather than a value, so
    /// it runs when a drag actually begins rather than when the body is
    /// built. That is the same timing `draggable(_:)`'s `@autoclosure
    /// @escaping` payload had, and it is why `TabDragOrigin` is a box
    /// rather than `@State` — see that type's doc comment.
    ///
    /// Since Task 3 it carries the window as well as the tab (see
    /// `TabDragPayload` for why the source window has to travel with the
    /// drag); since 2026-09-05 it carries them as that struct rather than
    /// as its JSON text, which is what stopped the Finder accepting the
    /// drag.
    private func dragPayload() -> TabDragPayload {
        dragOrigin.draggedTabID = tab.id
        return TabDragPayload(tabID: tab.id, sourceWindowID: windowID)
    }

    /// "SSH"/"S3" (M12/T7b) — reads `tab.connectionViewModel.kind`, the
    /// live form state. Stable once connected (`beginEditing`/
    /// `exitEditMode` are the only mutators, and neither runs again after a
    /// successful connect), so this reflects the CONNECTED backend for a
    /// live tab, and the form's current pick for a still-open one.
    private var kindBadgeLabel: String {
        let descriptor = BackendDescriptor.descriptor(for: tab.connectionViewModel.kind)
        return L10n.string(descriptor.badgeLabelKey, descriptor.badgeLabelDefault)
    }

    private var accessibilityState: String {
        switch indicator {
        case .none: return ""
        case .upload: return L10n.string("tabs.a11y.uploading", "uploading")
        case .download: return L10n.string("tabs.a11y.downloading", "downloading")
        case .attention: return L10n.string("tabs.a11y.attention", "needs attention")
        }
    }

    // Liveness dot (connection-liveness plan, Task 5)
    //
    // Drawn before `dot(_:pulse:)`'s own upload/download/attention dot, not
    // instead of it: liveness (is this session's connection alive at all)
    // and activity (is a transfer running, does something need attention)
    // are two independent axes, and a tab can legitimately be `.connected`
    // while also mid-upload.
    @ViewBuilder
    private var livenessDot: some View {
        if let appearance = LivenessDotPlan.appearance(for: tab.liveness) {
            Circle()
                .fill(appearance.color)
                .frame(width: 7, height: 7)
                .help(L10n.string(appearance.helpKey, appearance.helpDefault))
                .accessibilityLabel(
                    L10n.string(appearance.accessibilityLabelKey, appearance.accessibilityLabelDefault))
        }
    }

    @ViewBuilder
    private func dot(_ color: Color, pulse: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulse && pulsing && !reduceMotion ? 0.35 : 1.0)
            .animation(
                pulse && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulsing)
            .onAppear { pulsing = pulse }
    }
}
