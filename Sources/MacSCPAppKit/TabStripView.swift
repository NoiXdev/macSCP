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
    /// One route out of the tab context menu for every entry the menu can
    /// draw. The strip does not know what any entry means — it hands the
    /// tab and the chosen `TabMenuEntry` back to `ContentView`, which owns
    /// the tab lifecycle those actions run through.
    let onMenuEntry: (SessionTab, TabMenuEntry) -> Void
    /// The one route out of a tab drop: the dragged tab's id and the
    /// position it was dropped on. The strip does not reorder anything —
    /// `TabsViewModel.move(tabID:to:)` is the only reordering rule there
    /// is, the same one the menu's move entries reach, and `ContentView`
    /// owns the model it lives on.
    let onReorder: (UUID, Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Enumerated, because the context menu's move/close-others
                    // entries are decided from the tab's POSITION and the
                    // total count — see `TabContextMenu.entries`.
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { position, tab in
                        TabItemView(
                            tab: tab,
                            index: position,
                            tabCount: tabs.count,
                            isActive: tab.id == activeTabID,
                            onActivate: { onActivate(tab.id) },
                            onClose: { onClose(tab) },
                            onMenuEntry: { entry in onMenuEntry(tab, entry) },
                            onReorder: onReorder)
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

/// What a drop on the tab strip means, as the two value questions the
/// strip must not answer inside a gesture closure: which tab was dragged,
/// and which position it should land on.
///
/// Pulled out for the same reason as `LivenessDotPlan` and
/// `TabIndicatorPlan` above — this project has no SwiftUI rendering
/// harness, so a rule written into a drop closure is a rule nothing can
/// call. What lands here is decidable from values alone; what cannot be
/// decided here (does SwiftUI fire the drag, does the tab appear where the
/// pointer was) is not decidable anywhere in this project's tests.
///
/// **Reordering itself is deliberately not here.** The one reordering rule
/// is `TabsViewModel.move(tabID:to:)`, which the context menu's move
/// entries already call; this type only decides what to hand it. A second
/// reordering — an array rearranged in the view, or a rule that computes a
/// new order rather than a destination — is exactly the shape the design
/// rejects, and `TabContextMenuWiringGuardTests` watches for it.
enum TabDropPlan {
    /// The tab a drop payload names, or `nil` when there is nothing in the
    /// payload this strip could act on.
    ///
    /// The payload is a plain uuid string, the same spelling the session
    /// sidebar's rows are dragged with, so a session row dropped onto a tab
    /// arrives here as a well-formed uuid that names no tab. That is not
    /// this function's problem to catch: `move(tabID:to:)` leaves the order
    /// alone for an id it does not know, which is the outcome a foreign
    /// drop should have anyway. Answering `nil` here would only trade one
    /// no-op for another, at the price of a second rule about which ids are
    /// real — and the tabs the strip renders are not this type's to know.
    ///
    /// A drag carries one tab, so anything past the first item is a payload
    /// this gesture did not produce; the first item is what is read.
    static func draggedTabID(from payload: [String]) -> UUID? {
        guard let first = payload.first else { return nil }
        return UUID(uuidString: first)
    }

    /// The position a tab dropped ON the tab at `dropIndex` should move to,
    /// clamped into the tabs that exist right now — or `nil` when there are
    /// no tabs at all, which leaves the caller nothing to move onto.
    ///
    /// The clamp is this side's job by design. `move(tabID:to:)` refuses an
    /// out-of-range destination as a no-op rather than clamping it (its own
    /// doc comment says why: a gesture that ends outside the strip must
    /// leave the order alone), so a caller that forwards a raw position
    /// gets silence instead of a move. And the position a drop carries was
    /// read off the strip as it was RENDERED: a tab that closed while the
    /// drag was in flight makes it describe a strip that no longer exists.
    static func destination(forDropOnIndex dropIndex: Int, tabCount: Int) -> Int? {
        guard tabCount > 0 else { return nil }
        return min(max(dropIndex, 0), tabCount - 1)
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
        case .moveLeft:
            return L10n.string("tabs.menu.moveLeft", "Move Left")
        case .moveRight:
            return L10n.string("tabs.menu.moveRight", "Move Right")
        case .openTerminal:
            return L10n.string("tabs.menu.openTerminal", "Open Terminal")
        case .saveAsSession:
            return L10n.string("tabs.menu.saveAsSession", "Save as Session…")
        }
    }
}

private struct TabItemView: View {
    let tab: SessionTab
    /// This tab's position in the strip and the strip's total, the two
    /// facts `TabContextMenu.entries` turns into the move and bulk-close
    /// entries.
    let index: Int
    let tabCount: Int
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onMenuEntry: (TabMenuEntry) -> Void
    /// Handed straight through from the strip — see `TabStripView`'s own
    /// property for what the two values mean and who acts on them.
    let onReorder: (UUID, Int) -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

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
        .background(isActive ? DesignTokens.card : .clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(DesignTokens.remoteBlue).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            if !isActive { Rectangle().fill(DesignTokens.hairline).frame(width: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        // Reordering by dragging, in two halves: the tab carries its own
        // id, and a tab dropped on this one takes this one's position.
        // Both halves are plain uuid strings, the spelling the session
        // sidebar's rows already use.
        //
        // Only tabs are drop targets, which is what makes a drop into the
        // empty space beside the strip leave the order as it was — there is
        // nothing there to drop onto, so no destination is ever computed
        // for it. Dragging a tab OUT of the window is not offered at all:
        // multi-window is v2 and a session's state belongs to its window.
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { payload, _ in
            // Reads the payload and routes; decides nothing else. Which
            // position this is, and whether it still exists, are
            // `TabDropPlan`'s and `TabsViewModel.move`'s answers.
            guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
            onReorder(draggedID, index)
            return true
        }
        // The tab context menu. Everything about WHICH entries appear is
        // `TabContextMenu.entries`' answer, drawn here without a single
        // condition of this view's own: no `if` around an item, no filter
        // over the list, no `.disabled` standing in for a missing entry
        // (the design rejects greyed-out entries outright). A rule spelled
        // a second time here is a rule that can disagree with the one Core
        // tests — which is exactly what `TabContextMenuWiringGuardTests`
        // watches this closure for.
        .contextMenu {
            ForEach(Array(TabContextMenu.entries(
                atIndex: index, ofTabCount: tabCount,
                supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
            ).enumerated()), id: \.offset) { _, entry in
                Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
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

    /// The backend capability half of the "Open Terminal" precondition,
    /// read the same way `ContentView.activeTabSupportsShell` reads it —
    /// from the descriptor, never from a `ConnectionKind` comparison.
    private var supportsShell: Bool {
        BackendDescriptor.descriptor(for: tab.connectionViewModel.kind).capabilities.supportsShell
    }

    /// Ad hoc means "dialed without a stored session behind it".
    /// `SessionTab.activeStoredSessionID` is set only once a connect
    /// actually landed on a stored session, and is cleared again by
    /// `ContentView.teardown(_:reason:)`, so it is the fact, not a guess.
    private var isAdHoc: Bool { tab.activeStoredSessionID == nil }

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
