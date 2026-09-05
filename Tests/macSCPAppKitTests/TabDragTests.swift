import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Dragging a tab from one window's strip into another window's strip
/// (Detachable Tabs plan, Task 3).
///
/// Three properties, one section each below:
///
/// 1. **The payload says where the tab came from.** Reordering inside one
///    strip only ever needed the tab's id; crossing windows needs the
///    window it left, because the target strip is the only place the drop
///    is reported and it holds neither the source model nor its id.
/// 2. **Which route a drop takes is a decision over that payload**
///    (`TabDropPlan.route(payload:ownWindow:)`), not an `if` inside a
///    gesture closure — this project has no SwiftUI rendering harness, so a
///    rule written into `dropDestination`'s body is a rule nothing can
///    call.
/// 3. **A cross-window drop is the Task 1 move, with Task 2's close
///    decision on the source side** — one synchronous step
///    (`TabDetachSequence.moveBetweenWindows`), because
///    `TabsViewModel.detach(tabID:)` empties the source model when the
///    dragged tab was its last, and `TabsViewModel.activeTab` traps on an
///    emptied model.
///
/// **What is NOT pinned here, and where it is pinned instead.** That the
/// move leaves the connection alone is `TabRegistryTests`' property (it
/// owns the `disconnect`-counting double against exactly the
/// `TabRegistry.move(_:from:to:targetWindow:)` this path calls) and
/// `TabRegistryNoTeardownGuardTests`' source guard, which this task widened
/// to the strip's drop handler and to `acceptDroppedTab`'s body. Object
/// identity is re-checked below because it is what "the same tab arrived"
/// means, not because it is a second copy of that property.
@Suite("Tab drag between windows")
@MainActor
struct TabDragTests {

    // MARK: - Fixtures
    //
    // The same never-connecting tab `TabRegistryTests` and
    // `TabsWindowLifecycleTests` build: ownership and sequencing without
    // touching the network.

    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    // MARK: - 1. The payload

    @Test func aPayloadSurvivesAnEncodeDecodeRoundTrip() throws {
        let payload = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        let decoded = try #require(TabDragPayload(encoded: payload.encoded()))
        #expect(decoded == payload)
        #expect(decoded.tabID == payload.tabID)
        #expect(decoded.sourceWindowID == payload.sourceWindowID)
    }

    /// The strip's own drag is the only thing that produces this shape.
    /// Everything else that can land on a tab — a session row from the
    /// sidebar, a line of text from anywhere — is text that is not this
    /// envelope, and must read as "no payload of mine" rather than as a
    /// payload with a made-up source window.
    @Test func textThatIsNotTheEnvelopeIsNotAPayload() {
        #expect(TabDragPayload(encoded: UUID().uuidString) == nil)
        #expect(TabDragPayload(encoded: "") == nil)
        #expect(TabDragPayload(encoded: "{}") == nil)
        #expect(TabDragPayload(encoded: "/Users/someone/a-dropped-file.txt") == nil)
    }

    /// Both fields or nothing: a half-decoded payload would name a tab with
    /// no window to take it from, and the cross-window route has nowhere to
    /// go without one.
    @Test func anEnvelopeMissingItsSourceWindowIsNotAPayload() {
        #expect(TabDragPayload(encoded: "{\"tabID\":\"\(UUID().uuidString)\"}") == nil)
    }

    // MARK: - 2. Which route a drop takes

    @Test func aPayloadFromThisWindowRoutesToTheReorder() {
        let window = WindowID()
        let tabID = UUID()
        let payload = TabDragPayload(tabID: tabID, sourceWindowID: window)
        #expect(
            TabDropPlan.route(payload: [payload.encoded()], ownWindow: window)
                == .reorder(tabID))
    }

    @Test func aPayloadFromAnotherWindowRoutesAcrossWindows() {
        let payload = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        #expect(
            TabDropPlan.route(payload: [payload.encoded()], ownWindow: WindowID())
                == .acrossWindows(payload))
    }

    /// What this strip dragged before Task 3. It names no window, so it
    /// cannot be a cross-window drop — it is the reorder, exactly as it
    /// was. (The session sidebar is NOT an example of this: it prefixes its
    /// uuid, and `aSidebarRowIsRefusedOutright` below is what that costs.)
    @Test func aBareUUIDStillRoutesToTheReorder() {
        let id = UUID()
        #expect(TabDropPlan.route(payload: [id.uuidString], ownWindow: WindowID()) == .reorder(id))
    }

    /// A session row from the sidebar is not "a foreign uuid that reorders
    /// nothing" — it is not a uuid at all. `SidebarDragPayload` prefixes it
    /// (`macscp.sidebar.session:<uuid>`), so the route is `.none` and the
    /// strip's drop closure returns `false`: the drop is refused, not
    /// accepted-and-ignored. Built through `SidebarDragPayload` rather than
    /// spelled out, so its prefixes live in one place.
    @Test func aSidebarRowIsRefusedOutright() {
        let session = SidebarDragPayload.text(for: .session(UUID()))
        let group = SidebarDragPayload.text(for: .group(UUID()))
        #expect(TabDropPlan.route(payload: [session], ownWindow: WindowID()) == .none)
        #expect(TabDropPlan.route(payload: [group], ownWindow: WindowID()) == .none)
    }

    @Test func aPayloadThisStripDidNotProduceRoutesNowhere() {
        #expect(TabDropPlan.route(payload: [], ownWindow: WindowID()) == .none)
        #expect(
            TabDropPlan.route(payload: ["/Users/someone/a-file.txt"], ownWindow: WindowID())
                == .none)
    }

    // MARK: - 3. The cross-window move

    @Test func aCrossWindowDropMovesTheSameTabObject() {
        let registry = TabRegistry()
        let sourceWindow = WindowID()
        let targetWindow = WindowID()
        let travelling = makeTab()
        let staying = makeTab()
        let source = TabsViewModel<SessionTab>(initial: staying)
        source.addTab(travelling)
        let target = TabsViewModel<SessionTab>(initial: makeTab())
        registry.register(staying, in: sourceWindow)
        registry.register(travelling, in: sourceWindow)
        registry.register(target.tabs[0], in: targetWindow)

        let outcome = TabDetachSequence.moveBetweenWindows(
            travelling.id, from: source, sourceWindow: sourceWindow,
            to: target, targetWindow: targetWindow, in: registry,
            replacement: { self.makeTab() })

        #expect(outcome.closesWindow == false)
        #expect(outcome.replacementID == nil)
        #expect(!source.tabs.contains { $0.id == travelling.id })
        #expect(target.tabs.contains { $0 === travelling })
        #expect(registry.windowHolding(travelling.id) == targetWindow)
        #expect(registry.tab(for: travelling.id) === travelling)
    }

    /// A drop back onto the strip the drag started from is the reorder, and
    /// `route` says so — but the move itself refuses the same model too, so
    /// a caller that reaches it anyway cannot detach a tab and add it back
    /// as a "move" that renumbers the strip.
    @Test func aDropOntoTheModelTheTabAlreadyLivesInChangesNothing() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)

        let outcome = TabDetachSequence.moveBetweenWindows(
            tab.id, from: model, sourceWindow: window,
            to: model, targetWindow: window, in: registry,
            replacement: { self.makeTab() })

        #expect(outcome == .none)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0] === tab)
        #expect(registry.windowHolding(tab.id) == window)
    }

    /// A stale payload — the tab moved on, or its window already closed.
    /// Nothing is detached, nothing is added, and no replacement is made,
    /// so a repeated drop cannot mint tabs.
    @Test func aDropNamingATabTheSourceNoLongerHoldsChangesNothing() {
        let registry = TabRegistry()
        let sourceWindow = WindowID()
        let targetWindow = WindowID()
        let source = TabsViewModel<SessionTab>(initial: makeTab())
        let target = TabsViewModel<SessionTab>(initial: makeTab())
        registry.register(source.tabs[0], in: sourceWindow)
        registry.register(target.tabs[0], in: targetWindow)
        var replacementsMade = 0

        let outcome = TabDetachSequence.moveBetweenWindows(
            UUID(), from: source, sourceWindow: sourceWindow,
            to: target, targetWindow: targetWindow, in: registry,
            replacement: { replacementsMade += 1; return self.makeTab() })

        #expect(outcome == .none)
        #expect(replacementsMade == 0)
        #expect(source.tabs.count == 1)
        #expect(target.tabs.count == 1)
    }

    /// The case the menu could never produce (Task 2's sight check, step 3):
    /// a window's LAST tab leaves. The source is asked to close, and — since
    /// the close happens a main-actor turn later, with a view body in
    /// between — it is left holding a fresh tab rather than an empty model.
    @Test func theSourceIsAskedToCloseWhenItsLastTabLeavesAndItIsNotTheLastWindow() {
        let registry = TabRegistry()
        let sourceWindow = WindowID()
        let targetWindow = WindowID()
        let travelling = makeTab()
        let source = TabsViewModel<SessionTab>(initial: travelling)
        let target = TabsViewModel<SessionTab>(initial: makeTab())
        registry.register(travelling, in: sourceWindow)
        registry.register(target.tabs[0], in: targetWindow)
        #expect(registry.windowCount == 2)

        let outcome = TabDetachSequence.moveBetweenWindows(
            travelling.id, from: source, sourceWindow: sourceWindow,
            to: target, targetWindow: targetWindow, in: registry,
            replacement: { self.makeTab() })

        #expect(outcome.closesWindow)
        let replacementID = outcome.replacementID
        #expect(replacementID != nil)
        #expect(source.tabs.count == 1)
        #expect(source.tabs[0].id == replacementID)
        // READ, not just counted: `activeTab` traps on an emptied model, so
        // this line is the assertion that the source is safe to render for
        // the turn it still exists (`TabsWindowLifecycleTests` makes the
        // same read for the menu's path).
        #expect(source.activeTab.id == replacementID)
        #expect(target.tabs.contains { $0 === travelling })
    }

    /// The mirror image: the source is the only window the registry counts,
    /// so it stays open — with the same fresh tab in the leaver's place,
    /// which is the state the user is left looking at.
    @Test func theOnlyWindowIsNotAskedToCloseWhenItsLastTabLeaves() {
        let registry = TabRegistry()
        let sourceWindow = WindowID()
        let targetWindow = WindowID()
        let travelling = makeTab()
        let source = TabsViewModel<SessionTab>(initial: travelling)
        let target = TabsViewModel<SessionTab>(initial: makeTab())
        registry.register(travelling, in: sourceWindow)
        #expect(registry.windowCount == 1)

        let outcome = TabDetachSequence.moveBetweenWindows(
            travelling.id, from: source, sourceWindow: sourceWindow,
            to: target, targetWindow: targetWindow, in: registry,
            replacement: { self.makeTab() })

        #expect(outcome.closesWindow == false)
        #expect(outcome.replacementID != nil)
        #expect(source.tabs.count == 1)
        #expect(source.activeTab.id == outcome.replacementID)
    }

    // MARK: - The close request

    /// The source window is told to close by the window the tab arrived in,
    /// because a drop is reported only to the strip it landed on and no
    /// window here can close another. The notification carries the
    /// `WindowID` it names, and every window filters on its own.
    @Test func aCloseRequestNamesTheWindowItIsFor() {
        let window = WindowID()
        let notification = Notification(
            name: TabWindowCloseRequest.notification, object: nil,
            userInfo: [TabWindowCloseRequest.windowIDKey: window])
        #expect(TabWindowCloseRequest.windowID(from: notification) == window)
    }

    /// A request naming nothing matches no window, so it closes nothing —
    /// rather than matching the first window to read it.
    @Test func aCloseRequestWithoutAWindowNamesNone() {
        let empty = Notification(name: TabWindowCloseRequest.notification)
        #expect(TabWindowCloseRequest.windowID(from: empty) == nil)
        let foreign = Notification(
            name: TabWindowCloseRequest.notification, object: nil,
            userInfo: [TabWindowCloseRequest.windowIDKey: UUID()])
        #expect(TabWindowCloseRequest.windowID(from: foreign) == nil)
    }

    // MARK: - The model lookup

    /// The target window's strip is where a cross-window drop is reported,
    /// and it does not hold the source window's `TabsViewModel` — nothing
    /// in this app ever did. The registry already knew which window a tab
    /// belongs to; this is the other half of that, the model that window
    /// renders.
    @Test func theRegistryHandsBackTheModelAWindowRegistered() {
        let registry = TabRegistry()
        let window = WindowID()
        let model = TabsViewModel<SessionTab>(initial: makeTab())
        registry.registerModel(model, for: window)
        #expect(registry.model(for: window) === model)
    }

    @Test func aWindowThatRegisteredNothingHasNoModel() {
        let registry = TabRegistry()
        #expect(registry.model(for: WindowID()) == nil)
    }

    @Test func aWindowsModelIsGoneOnceItUnregisters() {
        let registry = TabRegistry()
        let window = WindowID()
        let model = TabsViewModel<SessionTab>(initial: makeTab())
        registry.registerModel(model, for: window)
        #expect(registry.model(for: window) === model)
        registry.unregisterModel(for: window)
        #expect(registry.model(for: window) == nil)
    }

    /// Held weakly, so a window whose close path never ran — a crash, an
    /// order this file cannot foresee — cannot leave the registry owning a
    /// whole window's worth of live sessions. The explicit
    /// `unregisterModel(for:)` above is what makes the common case
    /// immediate; this is what makes the uncommon one harmless.
    @Test func theRegistryHoldsAWindowsModelWeakly() {
        let registry = TabRegistry()
        let window = WindowID()
        var model: TabsViewModel<SessionTab>? = TabsViewModel(initial: makeTab())
        registry.registerModel(model!, for: window)
        #expect(registry.model(for: window) != nil)
        model = nil
        #expect(registry.model(for: window) == nil)
    }
}

/// The two wirings on the WINDOW side of a cross-window drop that no value
/// test in this target can reach: this project has no SwiftUI rendering
/// harness, so nothing here can make a drag happen.
///
/// **What is deliberately not here.** The strip's own half — the payload the
/// drag carries, the routing the drop performs, and the bare hand-over of
/// both to the tab item — belongs to
/// `TabContextMenuWiringGuardTests.TabDragWiringGuardTests`, which already
/// pins those bodies whole and was extended for Task 3 rather than
/// duplicated here. Two guards over one body are two claims that can
/// disagree.
///
/// Every check here is POSITIVE: each names something that must be present,
/// so a rename or a deletion leaves it with nothing to find and turns it
/// red, rather than silently matching nothing (CLAUDE.md, "Guards that name
/// what they watch": only a negative check can go stale in silence). The
/// negatives that belong to this path — the four teardown names, inside the
/// strip's drop handler and inside `acceptDroppedTab(_:)` — live in
/// `TabRegistryNoTeardownGuardTests`, each with a positive beside it there.
@Suite("Cross-window tab drop wiring (source guard)")
struct CrossWindowDropWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func strictSource(of path: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            String(
                contentsOf: repoRoot.appendingPathComponent(path),
                encoding: .utf8))
    }

    /// The handler: it finds the source window's model through the registry
    /// — the target window has never held it — and performs the move as the
    /// one synchronous sequence that also takes the close decision.
    @Test func theHandlerResolvesTheSourceModelAndMovesThroughTheSequence() throws {
        let source = try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        #expect(source.contains("TabRegistry.shared.model(for: payload.sourceWindowID)"))
        #expect(source.contains("TabDetachSequence.moveBetweenWindows("))
    }

    /// Both ends of the model registration, in the two places the window's
    /// life is already bracketed: its setup pass and its close path.
    /// Registering without unregistering would leave the registry naming a
    /// closed window's model as a live drop target — and a window that never
    /// registers cannot be dragged out of at all.
    @Test func aWindowRegistersItsModelAndGivesItUpOnClose() throws {
        let source = try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        #expect(source.contains("TabRegistry.shared.registerModel(tabsModel, for: windowID)"))
        #expect(source.contains("TabRegistry.shared.unregisterModel(for: closingWindow)"))
    }

    /// The close request's two ends: the window the tab arrived in posts it,
    /// and every window observes it. Without the observer the source window
    /// would be left open and empty — which looks like a working drag until
    /// someone notices the abandoned window.
    @Test func theCloseRequestIsPostedAndObserved() throws {
        let lifecycle = try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        #expect(lifecycle.contains("TabWindowCloseRequest.post(leavingWindow)"))
        #expect(lifecycle.contains("TabWindowCloseRequest.windowID(from: notification)"))
        let detail = try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Detail.swift")
        #expect(detail.contains("publisher(for: TabWindowCloseRequest.notification)"))
        #expect(detail.contains("perform: handleWindowShouldCloseAfterMove"))
    }
}
