import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MacSCPAppKit
@testable import macSCPCore

/// Dragging a tab from one window's strip into another window's strip
/// (Detachable Tabs plan, Task 3).
///
/// Three properties, one section each below:
///
/// 1. **The payload says where the tab came from, and says it in a type
///    of this app's own.** Reordering inside one strip only ever needed the
///    tab's id; crossing windows needs the window it left, because the
///    target strip is the only place the drop is reported and it holds
///    neither the source model nor its id. Since 2026-09-05 the envelope
///    travels as a `Transferable` over `dev.noix.macscp.tab` rather than as
///    JSON text — see `TabDragPayload` for the report that forced the
///    change, and for what a text payload let the Finder do.
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

    /// The real round trip, through the machinery a drag actually uses:
    /// register the payload on an `NSItemProvider` exactly as SwiftUI's own
    /// drag does, then load it back as the same type. Nothing here spells
    /// JSON — `CodableRepresentation` owns the wire format, and a test that
    /// re-implemented it would pin its own spelling rather than the one
    /// that travels.
    ///
    /// `withCheckedThrowingContinuation`, not a semaphore: every wait in a
    /// test target of this project is an `await` (CLAUDE.md, "Tests never
    /// block the cooperative pool").
    @Test func aPayloadSurvivesARoundTripThroughItsTransferRepresentation() async throws {
        let payload = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        let provider = NSItemProvider()
        provider.register(payload)
        let decoded: TabDragPayload = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: TabDragPayload.self) { result in
                continuation.resume(with: result)
            }
        }
        #expect(decoded == payload)
        #expect(decoded.tabID == payload.tabID)
        #expect(decoded.sourceWindowID == payload.sourceWindowID)
    }

    /// **The reported defect, as a property.** A drag registers exactly the
    /// types its `Transferable` declares, and this one declares one: the
    /// app's own. While the payload was a `String`, that list read
    /// `public.utf8-plain-text` (plus the text types conforming to it),
    /// which is what the Finder accepts — a tab dropped on the desktop
    /// became a text clipping.
    ///
    /// Asserted as equality against a single-element list rather than as
    /// "does not contain text": a `!contains` here would pass the day the
    /// payload grew a second, non-text representation nobody meant to add,
    /// and it would pass for a payload that registered nothing at all
    /// (CLAUDE.md, "Guards that name what they watch").
    @Test func aDragOffersTheAppsOwnTypeAndNothingElse() {
        let provider = NSItemProvider()
        provider.register(TabDragPayload(tabID: UUID(), sourceWindowID: WindowID()))
        #expect(provider.registeredTypeIdentifiers == [UTType.macSCPTab.identifier])
    }

    /// The pasteboard writer the AppKit drag source uses says the same
    /// thing, and it has to: SwiftUI's `dropDestination(for:)` reads the
    /// pasteboard type that `CodableRepresentation`'s content type maps to,
    /// so an item offered under any other type reaches no strip in this app.
    @Test func theWriterOffersTheSameSingleTypeTheRepresentationDeclares() throws {
        let payload = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        let writer = try #require(TabDragPasteboardWriter(payload: payload))
        let types = writer.writableTypes(for: NSPasteboard.general)
        #expect(types == [NSPasteboard.PasteboardType(UTType.macSCPTab.identifier)])
    }

    /// And the bytes it writes for that type are the payload. Decoded with
    /// the decoder `CodableRepresentation` uses by default, which is the
    /// claim being made: what the AppKit source puts on the pasteboard is
    /// what the SwiftUI destination reads off it.
    @Test func theWriterWritesThePayloadForItsOwnTypeAndNothingForAnother() throws {
        let payload = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        let writer = try #require(TabDragPasteboardWriter(payload: payload))
        let written = try #require(
            writer.pasteboardPropertyList(
                forType: NSPasteboard.PasteboardType(UTType.macSCPTab.identifier)) as? Data)
        #expect(try JSONDecoder().decode(TabDragPayload.self, from: written) == payload)
        let asText = writer.pasteboardPropertyList(forType: .string)
        #expect(asText == nil)
    }

    // MARK: - 2. Which route a drop takes

    @Test func aPayloadFromThisWindowRoutesToTheReorder() {
        let window = WindowID()
        let tabID = UUID()
        let payload = TabDragPayload(tabID: tabID, sourceWindowID: window)
        #expect(TabDropPlan.route(payload: [payload], ownWindow: window) == .reorder(tabID))
    }

    @Test func aPayloadFromAnotherWindowRoutesAcrossWindows() {
        let payload = TabDragPayload(tabID: UUID(), sourceWindowID: WindowID())
        #expect(
            TabDropPlan.route(payload: [payload], ownWindow: WindowID())
                == .acrossWindows(payload))
    }

    /// A drop carrying nothing is the one `.none` left. Everything that
    /// used to land here as text — a file path, a sentence, a session row
    /// from the sidebar — no longer reaches the strip at all: the
    /// destination takes `TabDragPayload`, so the system refuses those a
    /// step earlier and no closure of ours runs. `TabDropPlanTests` states
    /// the same boundary from the other side.
    @Test func aDropCarryingNothingRoutesNowhere() {
        #expect(TabDropPlan.route(payload: [], ownWindow: WindowID()) == .none)
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

/// The third way a tab can leave a window: its drag ends where nothing
/// accepted it, and the tab gets a window of its own (maintainer report,
/// dev build dev-46da7909 — "a new file is created on the Desktop and no
/// new window opens").
///
/// **Why this is a source guard and not a behavior test.** Every step of
/// the path is AppKit event handling inside an `NSView` that only exists
/// once SwiftUI has mounted it: `mouseDragged` past a threshold,
/// `beginDraggingSession(with:event:source:)`, and the
/// `NSDraggingSource` callback that reports where the session ended.
/// Nothing in this package draws an `NSViewRepresentable` (the same
/// boundary `SnippetCommandEditor`'s own doc comment states), and no test
/// here can synthesise a real drag session. What CAN be called directly is
/// the one decision that path takes — `TabDropOutsidePlan.detaches(...)`,
/// exercised by `TabDropOutsidePlanTests` — so what is left for a scanner
/// is the wiring around it.
///
/// Each negative below has a positive beside it naming the same construct
/// (CLAUDE.md, "Guards that name what they watch").
@Suite("Detach on a drop that landed nowhere (source guard)")
struct TabDetachOnDropOutsideGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func strictSource(of path: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            String(
                contentsOf: repoRoot.appendingPathComponent(path),
                encoding: .utf8))
    }

    private static let dragSourcePath = "Sources/MacSCPAppKit/TabDragSourceView.swift"
    private static let stripPath = "Sources/MacSCPAppKit/TabStripView.swift"
    private static let wiringPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"

    /// The view really is an `NSDraggingSource` that starts sessions of its
    /// own. Without both of these the file could be anything, and the
    /// negative below would have nothing to prove.
    @Test func theTabsDragSourceIsTheAppKitOne() throws {
        let source = try Self.strictSource(of: Self.dragSourcePath)
        #expect(source.contains("NSDraggingSource"))
        #expect(source.contains("beginDraggingSession("))
        #expect(source.contains("NSViewRepresentable"))
    }

    /// The negative beside it, in the file that would otherwise be the
    /// obvious place to put a second gesture: the strip no longer uses
    /// SwiftUI's drag source at all. `.draggable(_:)` over a `String`
    /// exports `public.utf8-plain-text` — that is the whole of the reported
    /// defect — and it vends no `NSDraggingSource`, so no drag started
    /// through it can report that it ended nowhere.
    ///
    /// The count of the AppKit source above it is the positive: a strip
    /// that dragged nothing at all would satisfy the `== 0` perfectly.
    @Test func theStripHasNoSwiftUIDragSourceLeft() throws {
        let strip = try Self.strictSource(of: Self.stripPath)
        // Both answers are computed before the expectation, so a failure
        // message names the claim rather than reprinting the whole file.
        let hasAppKitSource = strip.contains("TabDragSourceView(")
        let hasSwiftUIDrag = strip.contains(".draggable(")
        #expect(hasAppKitSource, "the strip has no drag source at all")
        #expect(hasSwiftUIDrag == false, "TabStripView.swift still calls .draggable(")
    }

    /// The nowhere-branch: the callback that reports a finished session
    /// asks the one decision a test can call, and a `true` there goes out
    /// through the detach route.
    @Test func theEndedCallbackAsksThePlanAndTakesTheDetachRoute() throws {
        let source = try Self.strictSource(of: Self.dragSourcePath)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "endedAt screenPoint: NSPoint, operation: NSDragOperation", in: source)
        #expect(
            body.contains("TabDropOutsidePlan.detaches("),
            "the scanned span is not the drag-ended callback")
        #expect(
            body.contains("onDetach?()"),
            "a drag that ended nowhere reaches no detach route")
    }

    /// And the other end of that route: the strip's detach callback is
    /// wired to the window's existing "move this tab to a window of its
    /// own" path, the same one the tab context menu and the Window menu
    /// use. A route wired to anything else — or to nothing — is a drag
    /// that still ends in no window.
    @Test func theDetachRouteIsWiredToTheWindowsMovePath() throws {
        let wiring = try Self.strictSource(of: Self.wiringPath)
        let isWired = wiring.contains("onDetachToNewWindow: { moveToNewWindow($0) }")
        #expect(isWired, """
            the strip's detach route in \(Self.wiringPath) is not wired to \
            `moveToNewWindow(_:)` — a tab dropped outside every window reaches no \
            window-opening path, which is the defect this fix repaired.
            """)
    }
}


/// The one decision the AppKit drag source takes, called directly — the
/// half of `draggingSession(_:endedAt:operation:)` a test can reach at all.
///
/// Two facts go in, and both matter; see `TabDropOutsidePlan`'s own doc
/// comment for why the second is there. The cases below are the four
/// corners of that pair plus the no-window edge.
@Suite("A drag that ended nowhere")
struct TabDropOutsidePlanTests {
    /// The window the drag started in, at a frame with room around it in
    /// every direction, so "outside" can be expressed on all four sides.
    private let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    /// The reported case: let go over the desktop, nothing accepted it.
    @Test func anUnacceptedDropOutsideTheSourceWindowDetaches() {
        #expect(
            TabDropOutsidePlan.detaches(
                operation: [], endedAt: CGPoint(x: 900, y: 900), sourceWindowFrame: window))
    }

    /// A drop one of this app's strips took. SwiftUI has already delivered
    /// it and the registry has already moved the tab; a second window here
    /// would be one window too many.
    @Test func anAcceptedDropDetachesNothingWhereverItLanded() {
        #expect(
            TabDropOutsidePlan.detaches(
                operation: .move, endedAt: CGPoint(x: 900, y: 900), sourceWindowFrame: window)
                == false)
        #expect(
            TabDropOutsidePlan.detaches(
                operation: .move, endedAt: CGPoint(x: 200, y: 200), sourceWindowFrame: window)
                == false)
    }

    /// The strip's own blank area, and everything else inside the window
    /// the drag started in. `TabItemView` is the only drop target, so a
    /// drop beside the tabs is accepted by nothing — and it has always been
    /// a no-op ("only tabs are drop targets, so a drop into the empty space
    /// of the strip leaves the order as it was"). It stays one.
    @Test func anUnacceptedDropInsideTheSourceWindowDetachesNothing() {
        #expect(
            TabDropOutsidePlan.detaches(
                operation: [], endedAt: CGPoint(x: 200, y: 200), sourceWindowFrame: window)
                == false)
    }

    /// Just past each edge, so the comparison cannot be satisfied by one
    /// axis alone — a `<` written for the wrong side passes on three of
    /// these four and fails on the fourth.
    @Test func eachSideOfTheSourceWindowIsOutsideIt() {
        let outside = [
            CGPoint(x: 99, y: 200), CGPoint(x: 501, y: 200),
            CGPoint(x: 200, y: 99), CGPoint(x: 200, y: 401),
        ]
        for point in outside {
            #expect(
                TabDropOutsidePlan.detaches(
                    operation: [], endedAt: point, sourceWindowFrame: window),
                "\(point) should count as outside \(window)")
        }
    }

    /// A source with no window cannot happen while a drag it started is in
    /// flight. It answers "detach" rather than "do nothing": an empty
    /// operation is still a drop nobody took, and the second fact simply
    /// has nothing to say.
    @Test func aSourceWithNoWindowFallsBackToTheOperationAlone() {
        #expect(
            TabDropOutsidePlan.detaches(
                operation: [], endedAt: CGPoint(x: 200, y: 200), sourceWindowFrame: nil))
        #expect(
            TabDropOutsidePlan.detaches(
                operation: .move, endedAt: CGPoint(x: 200, y: 200), sourceWindowFrame: nil)
                == false)
    }
}

/// The drag's content type is declared in two places that must agree: the
/// `UTType` the code drags under, and the `UTExportedTypeDeclarations`
/// entry a packaged build ships. A type exported by the code and absent
/// from the bundle is a type the system does not know this app owns.
///
/// The identifier is never spelled here. It is read off `UTType.macSCPTab`
/// and searched for in the script, so renaming the type moves this guard
/// with it instead of leaving it matching a string nobody uses (CLAUDE.md,
/// "Guards that name what they watch": a guard that spells a symbol it
/// could read instead is waiting for a rename).
///
/// **What this cannot check.** The packaged `Info.plist` is written by a
/// shell heredoc at release time; nothing here runs `scripts/package-app`,
/// so this reads the recipe rather than the artefact. A `plutil -lint` of
/// the produced file is the script's own step.
@Suite("The tab drag's exported type declaration")
struct TabDragTypeDeclarationTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func packagingScript() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/package-app"), encoding: .utf8)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Exactly once: absent means the packaged app never claims the type,
    /// and twice means two declarations of one identifier, which is a plist
    /// the system reads unpredictably.
    @Test func theBundleDeclaresTheIdentifierTheCodeDragsUnder() throws {
        let script = try Self.packagingScript()
        let identifier = UTType.macSCPTab.identifier
        let declarations = Self.occurrences(of: identifier, in: script)
        #expect(declarations == 1, """
            expected exactly 1 `\(identifier)` in scripts/package-app, found \
            \(declarations). The type the tab drag is exported under must be declared \
            in the bundle the release ships, once.
            """)
        #expect(script.contains("<string>macSCP Tab</string>"))
    }

    /// The three properties that keep the Finder out of it, as they appear
    /// in the entry itself: `public.data` and no text conformance, and no
    /// filename extension for a drop to name a file after.
    ///
    /// Read from the entry's own span rather than the whole script, because
    /// the file declares three other types that DO conform to `public.json`
    /// and DO carry extensions — a whole-file scan would find theirs and
    /// call it this one's (CLAUDE.md, "A negative check whose SPAN is wrong
    /// can never match").
    @Test func theDeclarationCarriesNoTextConformanceAndNoFileExtension() throws {
        let script = try Self.packagingScript()
        let entry = try #require(
            Self.declarationEntry(for: UTType.macSCPTab.identifier, in: script),
            "no <dict> entry around \(UTType.macSCPTab.identifier) in scripts/package-app")
        #expect(entry.contains("<string>public.data</string>"), "the entry declares no conformance")
        let conformsToText = entry.contains("public.text") || entry.contains("public.utf8-plain-text")
        let conformsToJSON = entry.contains("public.json")
        let namesAnExtension = entry.contains("public.filename-extension")
        #expect(conformsToText == false, "the tab type conforms to a text type")
        #expect(conformsToJSON == false, "the tab type conforms to public.json")
        #expect(namesAnExtension == false, "the tab type declares a filename extension")
    }

    /// The `<dict>`…`</dict>` around one identifier: from the last `<dict>`
    /// before it to the first `</dict>` after it. `nil` when either is
    /// missing, so a caller fails rather than scanning a guessed span.
    private static func declarationEntry(for identifier: String, in script: String) -> String? {
        guard let hit = script.range(of: identifier),
            let open = script.range(
                of: "<dict>", options: .backwards, range: script.startIndex..<hit.lowerBound),
            let close = script.range(of: "</dict>", range: hit.upperBound..<script.endIndex)
        else { return nil }
        return String(script[open.upperBound..<close.lowerBound])
    }
}
