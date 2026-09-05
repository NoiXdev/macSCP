import Foundation
import Testing

/// A move between windows must never touch a tab's connection (Global
/// Constraints: "a move never touches the connection"). `TabRegistry`,
/// `TabsViewModel.detach`, and `TabDetachSequence` are all concrete over
/// `SessionTab`/`TabsViewModel<SessionTab>` — nothing about their TYPES
/// stops a future edit from slipping a real teardown call into one of
/// them, and no VALUE test would catch it either: `TabRegistryTests` and
/// `TabsWindowLifecycleTests` pin what a move produces (object identity,
/// which model holds which id), not what it refrains from calling
/// alongside that — a `tab.transferQueue.cancelAll(...)` planted next to
/// the reassignment would cost none of them a single red (Task 1 report,
/// "The double's shape": the transfer-queue leg was already noted there as
/// having no protocol seam to build a call-counting double against).
///
/// This guard closes that gap from the other side: it reads the SOURCE,
/// not the behavior.
///
/// **NEGATIVE half.** None of five names a move must never reach —
/// `cancelAll(`, `shutdown(`, `disconnect(`, `teardown`, `TabTeardown` —
/// appear, outside a comment or a string, in `TabRegistry.swift`, in
/// `TabsViewModel.detach`'s body, or in `TabDetachSequence.swift`.
///
/// A FIFTH name joined them in the Quit Teardown plan, Task 1:
/// `TabTeardown`, the type the four stages moved into. Without it the
/// lowercase `teardown` needle would not catch `TabTeardown.run(` — the
/// capital T means the two spellings are different strings — and calling
/// the one owner from inside the registry is exactly the violation this
/// guard exists for. The registry's own `WindowTeardown` API
/// (`registerWindowTeardown`, `unregisterWindowTeardown`,
/// `allWindowTeardowns`) also spells the word with a capital T and is
/// deliberately NOT forbidden: storing a closure is not running one, and
/// `theRegistryStoresWindowTeardownsWithoutRunningThem` below is the check
/// that says so structurally rather than by spelling.
///
/// **POSITIVE half beside it** (CLAUDE.md, "Guards that name what they
/// watch": a negative check needs a positive beside it, or it is a
/// comment that runs). The same names genuinely occur, as real calls, in
/// the App's own teardown path — which is now TWO files, because the four
/// stages left `ContentView` so that a delegate with no view (the app's
/// quit) could reach them. Counted in the stripped
/// (comments-and-string-literals-blanked) view, on 2026-09-05, after that
/// extraction, with a throwaway script built on this file's own
/// `SwiftSource.blankingCommentsAndStrings`: in `TabTeardown.swift`,
/// `cancelAll(` once, `shutdown(` once, `disconnect(` once, `TabTeardown`
/// once (and `teardown`, lowercase, not at all — that file declares the
/// sequence, it does not call `ContentView.teardown`); in
/// `ContentView+Lifecycle.swift`, `teardown` six times (the declaration
/// plus five `await teardown(` call sites; the other three of the eight
/// in the App target are in `ContentView.swift` and
/// `ContentView+Detail.swift`) and `TabTeardown` once, and none of the
/// other three names at all. The two positive tests below assert presence
/// (>= 1), not these exact counts — a number this specific belongs to the
/// doc comment that was counted for it, not to an assertion that would
/// need re-counting on every unrelated edit to either file.
///
/// **Sensitivity, checked by hand, not just claimed** (fix round 1,
/// 2026-09-05): before this guard existed,
/// `tab.transferQueue.cancelAll(reason: .userRequested)` was planted
/// inside `TabRegistry.move(_:from:to:targetWindow:)`, right after
/// `let tab = source.detach(tabID: id)`. `swift test --filter
/// TabRegistryNoTeardownGuard` then failed
/// `theRegistryFileNeverCallsTeardown` with `TabRegistry.swift contains
/// "cancelAll("` — the negative check the plant exists to exercise.
/// Reverting the plant turned the suite green again; nothing else in this
/// file changed between the two runs.
///
/// Known blind spot: this is source text, not a rendered behavior — the
/// same limitation `TransferQueueBarCancelGuardTests`'s own doc comment
/// names for its guard. A call reached only through a stored closure or a
/// protocol witness rather than spelled out at the call site would not be
/// found by any of these five literal needles. For `TabRegistry.swift`
/// that blind spot is closed from the other side by
/// `theRegistryStoresWindowTeardownsWithoutRunningThem`'s `await` check,
/// which no spelling can slip past; the other scanned spans still have it.
@Suite("TabRegistry: a move never tears anything down (source guard)")
struct TabRegistryNoTeardownGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TabRegistryNoTeardownGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory — the same recipe
    /// `TransferQueueBarCancelGuardTests` uses.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let registryFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabRegistry.swift")
    private static let tabsViewModelFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/Presentation/TabsViewModel.swift")
    private static let detachSequenceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabDetachSequence.swift")
    private static let lifecycleFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
    /// Added by Task 3 (drag between windows): the strip's drop handler is
    /// the second place a move now starts from, and it lives inside a view
    /// body rather than in a file of its own — hence a span rather than a
    /// whole file below.
    private static let stripFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabStripView.swift")
    /// Added by the drag-detach fix (2026-09-05): the tab's drag SOURCE is
    /// now an AppKit view of this project's own, and its
    /// `draggingSession(_:endedAt:operation:)` starts the third path a tab
    /// can leave a window by. It reaches a route out to `moveToNewWindow`,
    /// so it is exactly the kind of place a teardown call could be added
    /// without any type refusing it.
    private static let dragSourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabDragSourceView.swift")

    /// Matches the strip's drop modifier; the brace that follows it opens
    /// the drop handler's own closure body. The destination reads the
    /// payload STRUCT since the drag-detach fix (2026-09-05) — it used to
    /// read `String.self`, which is what let the Finder accept the drag and
    /// write a text clipping.
    private static let dropDestinationDeclaration =
        ".dropDestination(for: TabDragPayload.self)"

    /// Matches `func acceptDroppedTab(_ payload: TabDragPayload)` in
    /// `ContentView+Lifecycle.swift` — the window-side half of a
    /// cross-window drop, and one of two functions in that file this
    /// suite scans NEGATIVELY (the file as a whole is its positive
    /// control).
    private static let acceptDropDeclaration = "func acceptDroppedTab(_ payload: TabDragPayload)"

    /// Matches `func moveToNewWindow(_ tab: SessionTab)` in
    /// `ContentView+Lifecycle.swift` — the menu/context-menu route for
    /// "Move Tab to New Window", the other function this suite scans
    /// NEGATIVELY (final review fix, Detachable Tabs plan: the drag route
    /// through `acceptDroppedTab` was covered, this menu route was not).
    private static let moveToNewWindowDeclaration = "func moveToNewWindow(_ tab: SessionTab)"

    /// Matches `public func detach(tabID: UUID) -> Tab?` in
    /// `TabsViewModel.swift` — the brace that follows it opens the body
    /// `declarationBodyRange(of:in:)` isolates.
    private static let detachDeclaration = "public func detach(tabID: UUID) -> Tab?"

    /// The five names, spelled once here — a rename of any of them turns
    /// this guard red (nothing left to find) rather than silently
    /// satisfying it, the same "positive, not a literal nobody would ever
    /// plant" shape `TransferQueueBarCancelGuardTests`'s own needles take.
    private static let forbidden = [
        "cancelAll(", "shutdown(", "disconnect(", "teardown", "TabTeardown",
    ]

    /// The one owner of the four stages since the Quit Teardown plan, Task
    /// 1 — where three of the five names above are now real calls.
    private static let tabTeardownFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabTeardown.swift")

    /// The strict (comments-and-string-literals-blanked) view of one file
    /// — a guard reading raw source cannot tell a call from a sentence
    /// about a call (CLAUDE.md, "Source-scanning guards read comments
    /// too").
    private static func strictSource(of file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            String(contentsOf: file, encoding: .utf8))
    }

    // MARK: - NEGATIVE: none of the four names reach a move

    /// `TabRegistry.swift` in full — `register`, both `move` overloads,
    /// `release`, `park`, `claim` — none of it calls into teardown.
    @Test func theRegistryFileNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.registryFile)
        for name in Self.forbidden {
            #expect(!source.contains(name), "TabRegistry.swift contains \"\(name)\"")
        }
    }

    /// Just `detach`'s body, via the same brace-balanced body reader
    /// `TransferQueueBarCancelGuardTests` uses — the rest of
    /// `TabsViewModel.swift` (`closeTab`, the `move` overloads, …) is out
    /// of scope for this specific claim, though a whole-file scan finds
    /// nothing there either (this type has no knowledge of `SessionTab`
    /// at all, let alone its queue or terminal).
    @Test func detachsBodyNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.tabsViewModelFile)
        let bodyRange = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.detachDeclaration, in: source)
        let body = TransferQueueBarCancelGuardTests.slice(bodyRange, of: source)
        for name in Self.forbidden {
            #expect(!body.contains(name), "detach(tabID:)'s body contains \"\(name)\"")
        }
    }

    /// `TabDetachSequence.swift` in full — one type, one function
    /// (`move`), which only ever calls `WindowCloseDecision.after`,
    /// `model.detach`, `registry.park`, and `model.addTab`.
    @Test func theDetachSequenceFileNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.detachSequenceFile)
        for name in Self.forbidden {
            #expect(!source.contains(name), "TabDetachSequence.swift contains \"\(name)\"")
        }
    }

    /// The strip's drop handler (Task 3), which now routes a drop either to
    /// the in-strip reorder or to the window's cross-window handler. It
    /// reaches a `TabsViewModel` and the registry, so it is exactly the kind
    /// of place a teardown call could be added without any type refusing it.
    ///
    /// The three POSITIVE expectations come FIRST and are not decoration:
    /// `declarationBodyRange` throws when the anchor is gone, but it cannot
    /// tell a mislocated span from the right one, and a span that is not the
    /// drop handler would satisfy four `!contains` checks perfectly
    /// (CLAUDE.md, "A negative check whose SPAN is wrong can never match").
    /// These three say the span really is the handler, by naming the plan it
    /// asks and both routes it can take.
    @Test func theStripsDropHandlerNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.stripFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.dropDestinationDeclaration, in: source)
        #expect(body.contains("TabDropPlan.route("), "the scanned span is not the drop handler")
        #expect(body.contains("onReorder("), "the drop handler's reorder route is gone")
        #expect(body.contains("onDropFromOtherWindow("), "the drop handler's cross-window route is gone")
        for name in Self.forbidden {
            #expect(!body.contains(name), "the strip's drop handler contains \"\(name)\"")
        }
    }

    /// `acceptDroppedTab(_:)`'s body — the window's side of a cross-window
    /// drop. Same shape: one positive naming the sequence it delegates to,
    /// so the span is known to be the right one, then the four negatives.
    @Test func theCrossWindowDropHandlerNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.lifecycleFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.acceptDropDeclaration, in: source)
        #expect(
            body.contains("TabDetachSequence.moveBetweenWindows("),
            "the scanned span is not the cross-window drop handler")
        for name in Self.forbidden {
            #expect(!body.contains(name), "acceptDroppedTab(_:)'s body contains \"\(name)\"")
        }
    }

    /// `moveToNewWindow(_:)`'s body — the menu/context-menu route for
    /// "Move Tab to New Window" (final review fix, Detachable Tabs plan:
    /// the drag route through `acceptDroppedTab` was covered here, this
    /// menu route was not). Same shape as the cross-window drop handler
    /// above: one positive naming the sequence it delegates to, then the
    /// four negatives.
    ///
    /// Sensitivity checked by hand: planting
    /// `tab.transferQueue.cancelAll(reason: .userRequested)` right after
    /// `let ownWindowID = windowID` inside this function's body turned
    /// `theMoveToNewWindowMenuRouteNeverCallsTeardown` red with
    /// `moveToNewWindow(_:)'s body contains "cancelAll("`; reverting the
    /// plant turned the suite green again, nothing else in this file
    /// changed between the two runs.
    @Test func theMoveToNewWindowMenuRouteNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.lifecycleFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.moveToNewWindowDeclaration, in: source)
        #expect(
            body.contains("TabDetachSequence.move("),
            "the scanned span is not moveToNewWindow(_:)'s body")
        for name in Self.forbidden {
            #expect(!body.contains(name), "moveToNewWindow(_:)'s body contains \"\(name)\"")
        }
    }

    /// `TabDragSourceView.swift` in full — the AppKit drag source, its
    /// pasteboard writer and the one decision it takes
    /// (`TabDropOutsidePlan`). A drag that ends nowhere hands the tab to
    /// `moveToNewWindow`, which is a move like any other: the connection
    /// travels with the tab and nothing here may end it.
    ///
    /// The two POSITIVE expectations come first, and are not decoration:
    /// a whole-file `!contains` scan of a file that no longer exists under
    /// this name, or that has been emptied, passes perfectly (CLAUDE.md,
    /// "Guards that name what they watch"). They say the file really is
    /// the drag source, by naming the AppKit call that starts a session and
    /// the callback that reports one ended.
    @Test func theDragSourceFileNeverCallsTeardown() throws {
        let source = try Self.strictSource(of: Self.dragSourceFile)
        #expect(
            source.contains("beginDraggingSession("),
            "the scanned file is not the tab's drag source")
        #expect(
            source.contains("endedAt screenPoint"),
            "the drag source no longer reports where a session ended")
        for name in Self.forbidden {
            #expect(!source.contains(name), "TabDragSourceView.swift contains \"\(name)\"")
        }
    }

    // MARK: - POSITIVE: the same four names are real vocabulary here

    /// Beside the negatives above: `TabTeardown.swift` — the one owner of
    /// the four stages — really does call three of the five names, so a
    /// scan that found nothing everywhere would prove nothing about a move
    /// in particular. See this suite's own doc comment for the exact counts
    /// at the commit this was written against.
    ///
    /// `teardown` (lowercase) is not among them and must not be: this file
    /// declares the sequence rather than calling `ContentView.teardown`.
    /// Its own control is the lifecycle file below.
    @Test func teardownVocabularyIsRealInTheOneOwner() throws {
        let source = try Self.strictSource(of: Self.tabTeardownFile)
        for name in ["cancelAll(", "shutdown(", "disconnect(", "TabTeardown"] {
            #expect(source.contains(name), """
                "\(name)" is missing from TabTeardown.swift — the positive half of this suite \
                has nothing left to stand on if the one teardown owner stops naming it.
                """)
        }
    }

    /// The other half of the same control: `ContentView+Lifecycle.swift` is
    /// still the window's own teardown path, so the two names a move must
    /// never reach from THERE are real there — `teardown`, its own method
    /// and its callers, and `TabTeardown`, the owner it hands the stages to.
    @Test func teardownVocabularyIsRealInTheLifecyclePath() throws {
        let source = try Self.strictSource(of: Self.lifecycleFile)
        for name in ["teardown", "TabTeardown"] {
            #expect(source.contains(name), """
                "\(name)" is missing from ContentView+Lifecycle.swift — the positive half of \
                this suite has nothing left to stand on if the window's own teardown path stops \
                naming it.
                """)
        }
    }

    /// The registry's `WindowTeardown` API (Quit Teardown plan, Task 1)
    /// hands closures out; it never runs one.
    ///
    /// **POSITIVE first:** the three API members really are there, so the
    /// negative below is read over a file that actually stores teardowns —
    /// a scan of a registry that never grew the API would satisfy any
    /// `!contains` perfectly (CLAUDE.md, "Guards that name what they
    /// watch").
    ///
    /// **NEGATIVE, and structural rather than spelled:** there is no
    /// `await ` anywhere in this file's code. A `WindowTeardown` is
    /// `@MainActor () async -> Void`, so running one requires an `await`,
    /// and a file with none cannot run one under ANY spelling — including a
    /// closure reached through a stored value, which the four literal
    /// needles above would miss. It is also the negative that cannot go
    /// stale in silence: `await` is a keyword, not a name somebody can
    /// rename out from under it.
    @Test func theRegistryStoresWindowTeardownsWithoutRunningThem() throws {
        let source = try Self.strictSource(of: Self.registryFile)
        #expect(
            source.contains("typealias WindowTeardown"),
            "TabRegistry.swift no longer declares WindowTeardown")
        #expect(
            source.contains("func registerWindowTeardown("),
            "TabRegistry.swift no longer stores a window's teardown")
        #expect(
            source.contains("func allWindowTeardowns("),
            "TabRegistry.swift no longer hands the teardowns back")
        #expect(!source.contains("await "), """
            TabRegistry.swift contains an "await" — the registry has no async work of its own, \
            so the only thing it could be awaiting is somebody else's teardown.
            """)
    }
}
