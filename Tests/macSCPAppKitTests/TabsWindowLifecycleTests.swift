import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// What a second window costs and what it must not cost (Detachable Tabs
/// plan, Task 2).
///
/// Four properties, each with its own section below:
///
/// 1. **The seed a window opens with is a value** — `Codable` so SwiftUI's
///    `WindowGroup(for:)` can carry it, and never equal to another seed, so
///    a value-keyed group cannot answer a second move by raising the window
///    the first one opened.
/// 2. **Whether a window closes is a decision, not a side effect** —
///    `WindowCloseDecision.after(removing:in:windowCount:)` is a pure
///    function this suite drives directly, because the view that calls it
///    cannot be rendered here (this project has no SwiftUI rendering
///    harness; the same boundary every wiring guard in this target
///    documents).
/// 3. **A tab crosses windows without changing hands** — parked by the
///    window it leaves, claimed by the window that opens for its seed, the
///    same object on both sides.
/// 4. **The order those two happen in is what keeps `activeTab` safe.**
///    `TabsViewModel.detach(tabID:)` sets `activeTabID` to `nil` when it
///    empties the model (Task 1 fix round 1), and `activeTab` traps on a
///    `nil` or unresolved id either way (`TabsViewModel`'s own documented
///    invariant). So `TabDetachSequence.move` performs the detach, the park and the
///    close decision in ONE synchronous step, and — when the window is
///    staying — puts a fresh tab in place before it returns. The tests
///    below read the model after that step, which is the only moment a view
///    could.
///
/// Plus source guards for the three wirings no value test in this target
/// can reach: the window's close path, the what's-new sheet's one window,
/// and the menu item's catalogue key.
@Suite("Tabs and windows")
@MainActor
struct TabsWindowLifecycleTests {

    // MARK: - Fixtures
    //
    // Same shape `TabRegistryTests` builds: a tab whose collaborators never
    // connect, so these tests exercise ownership and sequencing without
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

    // MARK: - The seed

    @Test func aSeedSurvivesACodableRoundTrip() throws {
        let seed = WindowSeed(tabIDs: [UUID(), UUID()])
        let decoded = try JSONDecoder().decode(
            WindowSeed.self, from: try JSONEncoder().encode(seed))
        #expect(decoded == seed)
        #expect(decoded.tabIDs == seed.tabIDs)
        #expect(decoded.id == seed.id)
    }

    /// `WindowGroup(for:)` raises the window it already opened for an EQUAL
    /// value. A seed is consumed the moment its window appears, so two
    /// moves of the same tab — or of two tabs that happen to carry the same
    /// ids — must never compare equal, or the second move would raise the
    /// first window instead of opening one.
    @Test func twoSeedsOverTheSameTabsAreNeverEqual() {
        let tabID = UUID()
        let first = WindowSeed(tabIDs: [tabID])
        let second = WindowSeed(tabIDs: [tabID])
        #expect(first != second)
        #expect(first.hashValue != second.hashValue || first.id != second.id)
    }

    /// The positive beside the inequality above: a seed IS equal to itself,
    /// so the check above measures the id and not a type that refuses every
    /// comparison.
    @Test func aSeedEqualsItself() {
        let seed = WindowSeed(tabIDs: [UUID()])
        #expect(seed == seed)
    }

    // MARK: - The close decision

    @Test func theLastTabLeavingANonLastWindowClosesIt() {
        let leaving = UUID()
        #expect(WindowCloseDecision.after(
            removing: leaving, in: [leaving], windowCount: 2))
    }

    @Test func theLastTabLeavingTheLastWindowLeavesItOpen() {
        let leaving = UUID()
        #expect(WindowCloseDecision.after(
            removing: leaving, in: [leaving], windowCount: 1) == false)
    }

    @Test func aTabLeavingBesideAnotherLeavesTheWindowOpen() {
        let leaving = UUID()
        #expect(WindowCloseDecision.after(
            removing: leaving, in: [leaving, UUID()], windowCount: 2) == false)
    }

    /// An id this window does not hold takes nothing away from it, so
    /// nothing about the window changes — the same reading `TabRegistry
    /// .move(_:to:)` takes of an id it has never seen.
    @Test func anIDTheWindowDoesNotHoldClosesNothing() {
        #expect(WindowCloseDecision.after(
            removing: UUID(), in: [UUID()], windowCount: 2) == false)
    }

    // MARK: - Park and claim

    @Test func aParkedTabIsClaimedByTheWindowThatOpensForItsSeed() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        registry.register(tab, in: source)
        let seedID = UUID()

        registry.park([tab], for: seedID, from: source)
        #expect(registry.windowHolding(tab.id) == nil)
        #expect(registry.parkedTabs(for: seedID).count == 1)

        let target = WindowID()
        let claimed = registry.claim(seedID: seedID, into: target)
        #expect(claimed.count == 1)
        #expect(claimed.first === tab)
        #expect(registry.windowHolding(tab.id) == target)
        #expect(registry.parkedTabs(for: seedID).isEmpty)
    }

    /// A window SwiftUI restored from a previous launch carries a seed
    /// nobody parked anything under. It gets nothing rather than another
    /// window's tabs, and the claim is not an error.
    @Test func aSeedNobodyParkedUnderYieldsNothing() {
        let registry = TabRegistry()
        #expect(registry.claim(seedID: UUID(), into: WindowID()).isEmpty)
    }

    /// Parking takes the tab out of the window it was in — the source
    /// window stops counting once its last tab is parked, which is what
    /// `windowCount` has to report for the close decision above to be asked
    /// with the truth.
    @Test func parkingTheLastTabEmptiesItsWindow() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        registry.register(tab, in: source)
        #expect(registry.windowCount == 1)
        registry.park([tab], for: UUID(), from: source)
        #expect(registry.windowCount == 0)
        #expect(registry.tabs(in: source).isEmpty)
    }

    // MARK: - The sequence

    /// A window that is losing its only tab still ends the step with a tab
    /// in it — a fresh one, standing in for the leaver. It has to: the
    /// close no longer happens in this turn (it waits for `reclaim`), so a
    /// view body WILL run over this model, and `activeTab` traps on the
    /// emptied one. Reading `activeTab` here is the assertion.
    @Test func theLastTabOfANonLastWindowIsReplacedAndTheWindowIsToldToClose() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)
        // A second window, so this one is not the last.
        registry.register(makeTab(), in: WindowID())
        let seed = WindowSeed(tabIDs: [tab.id])

        let outcome = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, from: window, in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in },
            onClaimed: { _ in })

        #expect(outcome.closesWindow)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == outcome.replacementID)
        #expect(model.activeTab.id == outcome.replacementID)
        #expect(registry.parkedTabs(for: seed.id).first === tab)
    }

    /// The last window is told to stay, and gets the same replacement — the
    /// only difference between the two cases is the answer, not the state.
    @Test func theLastTabOfTheLastWindowIsReplacedAndTheWindowStays() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)

        let outcome = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: WindowSeed(tabIDs: [tab.id]), from: window,
            in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in },
            onClaimed: { _ in })

        #expect(outcome.closesWindow == false)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id != tab.id)
        #expect(model.activeTab.id == model.tabs[0].id)
    }

    @Test func aTabLeavingBesideAnotherKeepsTheWindowAndTheRest() {
        let registry = TabRegistry()
        let window = WindowID()
        let leaving = makeTab()
        let staying = makeTab()
        let model = TabsViewModel<SessionTab>(initial: leaving)
        model.addTab(staying)
        registry.register(leaving, in: window)
        registry.register(staying, in: window)
        registry.register(makeTab(), in: WindowID())

        let outcome = TabDetachSequence.move(
            leaving.id, outOf: model, parkingUnder: WindowSeed(tabIDs: [leaving.id]),
            from: window, in: registry, replacement: { self.makeTab() }, openWindow: { _ in },
            onClaimed: { _ in })

        #expect(outcome.closesWindow == false)
        #expect(outcome.replacementID == nil)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0] === staying)
        #expect(model.activeTab.id == staying.id)
    }

    /// The whole point of the move: the object that arrives is the object
    /// that left. Its `BrowserSession` is untouched because nothing on this
    /// path can touch it — `detach`, `park` and `claim` move a reference
    /// between collections and nothing else (Global Constraints: "a move
    /// never touches the connection", pinned against the connection itself
    /// in `TabRegistryTests` and structurally in
    /// `TabRegistryNoTeardownGuardTests`).
    @Test func theTabThatArrivesIsTheTabThatLeft() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        model.addTab(makeTab())
        registry.register(tab, in: source)
        let seed = WindowSeed(tabIDs: [tab.id])

        TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, from: source, in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in },
            onClaimed: { _ in })

        let target = WindowID()
        let arrived = registry.claim(seedID: seed.id, into: target)
        #expect(arrived.first === tab)
        #expect(registry.windowHolding(tab.id) == target)
    }

    /// An id the model does not hold moves nothing, parks nothing, and — the
    /// part the `openWindow` seam makes visible — opens no window.
    @Test func anIDTheModelDoesNotHoldMovesNothing() {
        let registry = TabRegistry()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: WindowID())
        let seed = WindowSeed(tabIDs: [UUID()])
        var opened: [WindowSeed] = []

        let outcome = TabDetachSequence.move(
            UUID(), outOf: model, parkingUnder: seed, from: WindowID(), in: registry,
            replacement: { self.makeTab() }, openWindow: { opened.append($0) },
            onClaimed: { _ in })

        #expect(outcome == .none)
        #expect(opened.isEmpty)
        #expect(model.tabs.count == 1)
        #expect(registry.parkedTabs(for: seed.id).isEmpty)
    }

    /// The tab is parked BEFORE the window is asked for, so a window that
    /// claims synchronously finds something to claim. Read through the seam:
    /// the closure sees the parked tab at the moment it is called.
    @Test func theTabIsParkedBeforeTheWindowIsOpened() {
        let registry = TabRegistry()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        model.addTab(makeTab())
        let window = WindowID()
        registry.register(tab, in: window)
        let seed = WindowSeed(tabIDs: [tab.id])
        var parkedWhenOpened: [UUID] = []

        TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, from: window, in: registry,
            replacement: { self.makeTab() },
            openWindow: { parkedWhenOpened = registry.parkedTabs(for: $0.id).map(\.id) },
            onClaimed: { _ in })

        #expect(parkedWhenOpened == [tab.id])
    }

    // MARK: The claim is the signal (fix round 2)

    /// The registry tells the source window when its tab has actually been
    /// taken over. Nothing else can: the new window's claim happens on a
    /// later DISPLAY pass, not a later main-actor turn, so no amount of
    /// hopping turns will see it (fix round 2's Critical — a next-turn
    /// reclaim ran before the new window's setup and pulled the tab back,
    /// leaving the new window blank).
    @Test func parkingDoesNotFireTheClaimHandlerButClaimingDoes() {
        let registry = TabRegistry()
        let tab = makeTab()
        let seedID = UUID()
        var claims = 0

        registry.park([tab], for: seedID, from: WindowID(), onClaimed: { claims += 1 })
        #expect(claims == 0)

        _ = registry.claim(seedID: seedID, into: WindowID())
        #expect(claims == 1)
    }

    /// Exactly once, however often the claim is repeated: the handler goes
    /// with the tabs, so a second claim of the same seed finds neither.
    @Test func theClaimHandlerFiresExactlyOnce() {
        let registry = TabRegistry()
        let tab = makeTab()
        let seedID = UUID()
        var claims = 0

        registry.park([tab], for: seedID, from: WindowID(), onClaimed: { claims += 1 })
        _ = registry.claim(seedID: seedID, into: WindowID())
        _ = registry.claim(seedID: seedID, into: WindowID())
        #expect(claims == 1)
    }

    /// The move tells the source window what to do WHEN the tab is claimed,
    /// and not before. Driven through both seams: an `openWindow` that never
    /// claims leaves the handler unfired and the tab parked.
    @Test func aWindowThatNeverClaimsLeavesTheTabParkedAndTheSourceOpen() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)
        registry.register(makeTab(), in: WindowID())
        let seed = WindowSeed(tabIDs: [tab.id])
        var closeRequests = 0

        let outcome = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, from: window, in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in },
            onClaimed: { _ in closeRequests += 1 })

        #expect(outcome.closesWindow)
        #expect(closeRequests == 0)
        #expect(registry.parkedTabs(for: seed.id).first === tab)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == outcome.replacementID)
    }

    /// And when a window DOES claim it, the handler fires with the outcome
    /// the move decided — which is what the source window closes on.
    @Test func aClaimFiresTheHandlerWithTheMovesOwnOutcome() {
        let registry = TabRegistry()
        let window = WindowID()
        let target = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)
        registry.register(makeTab(), in: WindowID())
        let seed = WindowSeed(tabIDs: [tab.id])
        var claimed: [TabDetachSequence.Outcome] = []

        let outcome = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, from: window, in: registry,
            replacement: { self.makeTab() },
            openWindow: { _ = registry.claim(seedID: $0.id, into: target) },
            onClaimed: { claimed.append($0) })

        #expect(claimed == [outcome])
        #expect(outcome.closesWindow)
        #expect(registry.windowHolding(tab.id) == target)
    }

    // MARK: The registry owns pending moves (fix round 3)

    /// The registry knows WHICH window parked a seed, so the window that
    /// closes can be handed exactly its own unclaimed moves.
    @Test func aParkedSeedIsListedAgainstTheWindowThatParkedIt() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        let seedID = UUID()

        registry.park([tab], for: seedID, from: source)

        let pending = registry.pendingSeeds(for: source)
        #expect(pending.count == 1)
        #expect(pending.first?.seedID == seedID)
        #expect(pending.first?.tabs.first === tab)
        #expect(registry.pendingSeeds(for: WindowID()).isEmpty)
    }

    /// A claim empties the pending list: the seed is another window's
    /// business now, and the one that parked it has nothing left to answer
    /// for.
    @Test func claimingASeedTakesItOffItsSourcesPendingList() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        let seedID = UUID()
        registry.park([tab], for: seedID, from: source)

        _ = registry.claim(seedID: seedID, into: WindowID())

        #expect(registry.pendingSeeds(for: source).isEmpty)
    }

    /// The sweep hands the tabs over EXACTLY ONCE. The App layer is what
    /// tears them down (the registry never does — see
    /// `TabRegistryNoTeardownGuardTests`), so handing the same live session
    /// out twice would mean tearing it down twice.
    @Test func takingAWindowsPendingSeedsHandsThemOverExactlyOnce() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        let seedID = UUID()
        registry.park([tab], for: seedID, from: source)

        let first = registry.takePendingSeeds(from: source)
        #expect(first.count == 1)
        #expect(first.first?.tabs.first === tab)

        let second = registry.takePendingSeeds(from: source)
        #expect(second.isEmpty)
        #expect(registry.pendingSeeds(for: source).isEmpty)
        #expect(registry.parkedTabs(for: seedID).isEmpty)
    }

    /// The quit sweep takes every window's, and empties the registry of
    /// them the same way.
    @Test func takingEveryPendingSeedEmptiesThemAll() {
        let registry = TabRegistry()
        let firstWindow = WindowID()
        let secondWindow = WindowID()
        registry.park([makeTab()], for: UUID(), from: firstWindow)
        registry.park([makeTab()], for: UUID(), from: secondWindow)

        let all = registry.takeAllPendingSeeds()
        #expect(all.count == 2)
        #expect(registry.takeAllPendingSeeds().isEmpty)
        #expect(registry.pendingSeeds(for: firstWindow).isEmpty)
        #expect(registry.pendingSeeds(for: secondWindow).isEmpty)
    }

    /// Two moves from ONE window — the case this round exists for. The
    /// second move's claim closes the source window while the first is
    /// still parked; both are on the same window's pending list, so the
    /// close path reaches the one nobody claimed. Round 2's per-window
    /// `pendingMoves` died with the window and left it unreachable.
    @Test func aSecondMoveDoesNotHideTheFirstsUnclaimedSeed() {
        let registry = TabRegistry()
        let source = WindowID()
        let stranded = makeTab()
        let taken = makeTab()
        let strandedSeed = UUID()
        let takenSeed = UUID()

        registry.park([stranded], for: strandedSeed, from: source)
        registry.park([taken], for: takenSeed, from: source)
        _ = registry.claim(seedID: takenSeed, into: WindowID())

        let left = registry.takePendingSeeds(from: source)
        #expect(left.count == 1)
        #expect(left.first?.seedID == strandedSeed)
        #expect(left.first?.tabs.first === stranded)
    }

    // MARK: - How the windows describe themselves at quit

    /// The registry is asked once, at `applicationWillTerminate`, for
    /// every window still open — because ⌘Q closes none of them, so
    /// nothing on any window's own close path can see the set that
    /// matters (Task 5 fix round 1).
    ///
    /// Order is part of the answer: a dictionary has none, and the
    /// restored windows have to come back in a stable one, so the registry
    /// keeps the order the windows registered in.
    @Test func everyRegisteredWindowDescribesItselfInTheOrderItAppeared() {
        let registry = TabRegistry()
        let first = WindowID()
        let second = WindowID()
        let firstSeed = WindowSeed(tabs: [TabSeed(sessionID: UUID())],
                                   keepOnTop: false, isPrimary: true)
        let secondSeed = WindowSeed(tabs: [TabSeed(sessionID: UUID())],
                                    keepOnTop: true, isPrimary: false)
        registry.registerWindowDescriber({ firstSeed }, for: first)
        registry.registerWindowDescriber({ secondSeed }, for: second)
        #expect(registry.describeAllWindows() == [firstSeed, secondSeed])
    }

    /// A window that has closed is not one to bring back, and the
    /// remaining windows keep their order.
    @Test func aWindowThatUnregisteredIsNotDescribed() {
        let registry = TabRegistry()
        let first = WindowID()
        let second = WindowID()
        let third = WindowID()
        let firstSeed = WindowSeed(tabs: [TabSeed(sessionID: UUID())],
                                   keepOnTop: false, isPrimary: true)
        let thirdSeed = WindowSeed(tabs: [TabSeed(sessionID: UUID())],
                                   keepOnTop: false, isPrimary: false)
        registry.registerWindowDescriber({ firstSeed }, for: first)
        registry.registerWindowDescriber(
            { WindowSeed(tabs: [], keepOnTop: false, isPrimary: false) }, for: second)
        registry.registerWindowDescriber({ thirdSeed }, for: third)
        registry.unregisterWindowDescriber(for: second)
        #expect(registry.describeAllWindows() == [firstSeed, thirdSeed])
    }

    /// A window runs its setup pass more than once. Re-registering must
    /// replace the closure and keep the window where it was, or a window
    /// would be described twice, or jump to the back of the order for
    /// having repainted.
    @Test func reRegisteringReplacesTheDescriberAndKeepsThePosition() {
        let registry = TabRegistry()
        let first = WindowID()
        let second = WindowID()
        let firstSeed = WindowSeed(tabs: [TabSeed(sessionID: UUID())],
                                   keepOnTop: false, isPrimary: true)
        let laterFirstSeed = WindowSeed(tabs: [TabSeed(sessionID: UUID())],
                                        keepOnTop: true, isPrimary: true)
        let secondSeed = WindowSeed(tabs: [], keepOnTop: false, isPrimary: false)
        registry.registerWindowDescriber({ firstSeed }, for: first)
        registry.registerWindowDescriber({ secondSeed }, for: second)
        registry.registerWindowDescriber({ laterFirstSeed }, for: first)
        #expect(registry.describeAllWindows() == [laterFirstSeed, secondSeed])
    }

    /// The answer is pulled at the moment it is needed, not stored when
    /// the window registers: a window's tabs, its sticky flag and its
    /// connections all change after the setup pass that registers it.
    @Test func aDescriberIsAskedAtTheMomentItIsRead() {
        let registry = TabRegistry()
        let window = WindowID()
        var answer = WindowSeed(tabs: [], keepOnTop: false, isPrimary: true)
        registry.registerWindowDescriber({ answer }, for: window)
        let later = WindowSeed(
            tabs: [TabSeed(sessionID: UUID(), paneVisibility: .bothVisible)],
            keepOnTop: true, isPrimary: true)
        answer = later
        #expect(registry.describeAllWindows() == [later])
    }

    @Test func aRegistryNoWindowRegisteredWithDescribesNothing() {
        #expect(TabRegistry().describeAllWindows().isEmpty)
    }

    // MARK: - Is there a main window left?

    /// The Settings window's "Manage Data" entries route into A main
    /// window. Which one does not matter; that one exists does. Before fix
    /// round 2 any window's close wrote `false`, greying those entries while
    /// another window was still open (fix round 2, finding 2).
    @Test func anotherOpenWindowKeepsTheManageDataEntriesAlive() {
        #expect(MainWindowPresence.remains(windowCount: 2, closingOneOfThem: true))
    }

    @Test func theLastWindowClosingLeavesNoMainWindow() {
        #expect(MainWindowPresence.remains(windowCount: 1, closingOneOfThem: true) == false)
    }

    @Test func anOpenWindowIsAMainWindow() {
        #expect(MainWindowPresence.remains(windowCount: 1, closingOneOfThem: false))
        #expect(MainWindowPresence.remains(windowCount: 2, closingOneOfThem: false))
    }

    @Test func noWindowAtAllIsNoMainWindow() {
        #expect(MainWindowPresence.remains(windowCount: 0, closingOneOfThem: false) == false)
        // A count that has already dropped to zero and a window that says it
        // is closing must not read as -1 remaining and wrap into anything
        // truthy.
        #expect(MainWindowPresence.remains(windowCount: 0, closingOneOfThem: true) == false)
    }

    // MARK: - The menu bar follows the window that published it

    /// A closed window's tabs leave the status item with it (fix round 2,
    /// finding 5). The model remembers WHICH window published, so a window
    /// closing in the background cannot wipe the front window's list.
    @Test func aClosedWindowsEntriesLeaveTheMenuBar() {
        let model = MenuBarStatusModel()
        let publisher = WindowID()
        model.publish(tabs: [makeTab()], from: publisher, focusTab: { _ in }, showMainWindow: {})
        #expect(model.tabs.count == 1)

        model.clearIfPublished(by: publisher)
        #expect(model.tabs.isEmpty)
    }

    /// The positive beside it: another window closing leaves the published
    /// list alone.
    @Test func aDifferentWindowClosingLeavesTheMenuBarAlone() {
        let model = MenuBarStatusModel()
        let publisher = WindowID()
        model.publish(tabs: [makeTab()], from: publisher, focusTab: { _ in }, showMainWindow: {})

        model.clearIfPublished(by: WindowID())
        #expect(model.tabs.count == 1)
    }

    // MARK: - Source guards
    //
    // Everything below reads source text, for the reason every wiring guard
    // in this target states: there is no SwiftUI rendering harness here, so
    // a scene's structure and a close path's steps can only be read.

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift")
    private static let lifecycleFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
    /// The one owner of a tab's four teardown stages since the Quit
    /// Teardown plan, Task 1 — they used to be spelled inside
    /// `ContentView.teardown(_:reason:)`, which no delegate could call.
    private static let tabTeardownFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabTeardown.swift")
    private static let stripFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabStripView.swift")
    /// Every menu this app adds — its own `Commands` type since the bridge
    /// became a focused scene value (fix round 1).
    private static let commandsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/MacSCPCommands.swift")
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")
    private static let sheetsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Sheets.swift")
    private static let sequenceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabDetachSequence.swift")

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    /// The comments-and-strings-blanked view of a file: what survives is
    /// code, so a symbol found in it was called rather than described. The
    /// project's own rule — a comment that quotes the code it describes is
    /// indistinguishable from that code to a scanner — is why every check
    /// below reads this view unless it is a claim about a literal.
    private static func code(of url: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            try String(contentsOf: url, encoding: .utf8))
    }

    /// The literals-kept view, for the checks that are about a catalogue
    /// key — blanking it would delete the very thing being scanned.
    private static func codeWithLiterals(of url: URL) throws -> String {
        try SwiftSource.blankingComments(
            try String(contentsOf: url, encoding: .utf8))
    }

    /// Everything between `anchor`'s own `{` and its matching `}`, by plain
    /// brace counting. `nil` on a missing anchor or unbalanced braces
    /// rather than a guess — every caller treats that as a failure, so this
    /// guard fails closed when the thing it names moves.
    static func body(after anchor: String, in source: String) -> String? {
        guard let range = source.range(of: anchor) else { return nil }
        var depth = 1
        var index = range.upperBound
        let start = index
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[start..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func catalogKeys(_ locale: String) throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(catalogPath(locale)))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        guard let entries = parsed as? [String: String] else {
            throw CatalogError.unreadable(catalogPath(locale))
        }
        return Set(entries.keys)
    }

    enum CatalogError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let path): return "\(path) does not parse as a strings table"
            }
        }
    }

    // MARK: The close path

    /// Positive: the window's close path hands its tabs to the teardown
    /// this project already has, and only then asks the registry to forget
    /// them.
    ///
    /// The loop moved into `tearDownHeldTabs(_:from:)` (Quit Teardown plan,
    /// Task 1) so the app's quit can AWAIT the same sequence a `willClose`
    /// handler can only fire into a `Task`. Both entry points are pinned
    /// first, then the one body they share — a scan of the shared half alone
    /// would stay green if nothing called it any more.
    @Test func theWindowsClosePathTearsDownWhatItHoldsAndThenReleasesIt() throws {
        let source = try Self.code(of: Self.lifecycleFile)
        let notified = try #require(
            Self.body(after: "func releaseHeldTabsOnClose() {", in: source), """
                ContentView+Lifecycle.swift no longer declares \
                releaseHeldTabsOnClose() — re-anchor this guard on whatever \
                the window's close path is called now.
                """)
        let awaited = try #require(
            Self.body(after: "func releaseHeldTabsOnCloseAndWait() async {", in: source), """
                ContentView+Lifecycle.swift no longer declares \
                releaseHeldTabsOnCloseAndWait() — the app's quit has nothing \
                left to await.
                """)
        #expect(notified.contains("tearDownHeldTabs("), """
            releaseHeldTabsOnClose() no longer hands its tabs to \
            tearDownHeldTabs(_:from:).
            """)
        #expect(awaited.contains("tearDownHeldTabs("), """
            releaseHeldTabsOnCloseAndWait() no longer hands its tabs to \
            tearDownHeldTabs(_:from:) — the quit would await a different \
            sequence than the close path runs.
            """)
        let closePath = try #require(
            Self.body(
                after: "private func tearDownHeldTabs("
                    + "_ held: [SessionTab], from closingWindow: WindowID) async {",
                in: source), """
                ContentView+Lifecycle.swift no longer declares \
                tearDownHeldTabs(_:from:) — re-anchor this guard on whatever \
                the window's close path is called now.
                """)
        // Each Bool is computed BEFORE the expectation: `#expect` reports
        // the source text AND the values of what it checks, so a bare
        // `closePath.contains(…)` prints the whole extracted body on every
        // failure. Same rule CLAUDE.md states for a value a test must not
        // leak, applied to a value nobody can read.
        let tearsDown = closePath.contains("await teardown(tab, reason:")
        let releases = closePath.contains("TabRegistry.shared.release(")
        #expect(tearsDown, """
            the window's close path no longer runs each held tab through \
            teardown(_:reason:) — a window closing would leave its shells and \
            SFTP channels open.
            """)
        #expect(releases, """
            the window's close path no longer releases its tabs from the \
            registry — the registry would go on counting a window that is gone.
            """)
    }

    /// The positive anchor the negative below needs, and the one that says
    /// what "the existing teardown" IS: the staged sequence, named by its
    /// stages. `releaseHeldTabsOnClose` calling `teardown` means nothing if
    /// `teardown` stopped being that sequence.
    @Test func theTeardownTheClosePathCallsIsStillTheStagedOne() throws {
        let source = try Self.code(of: Self.lifecycleFile)
        let view = try #require(
            Self.body(
                after: "func teardown(_ tab: SessionTab, reason: CancelReason) async {",
                in: source), """
                ContentView+Lifecycle.swift no longer declares \
                teardown(_:reason:) with that signature — re-anchor this guard.
                """)
        // The stages left the view for `TabTeardown` (Quit Teardown plan,
        // Task 1), so "the staged sequence" is now two claims: the view
        // calls the one owner, and the one owner runs the stages.
        #expect(view.contains("TabTeardown.run(tab, reason: reason)"), """
            ContentView.teardown(_:reason:) no longer calls the one teardown \
            owner — a second copy of the four stages is what that means.
            """)
        let teardown = try #require(
            Self.body(
                after: "static func run(_ tab: SessionTab, reason: CancelReason) async {",
                in: try Self.code(of: Self.tabTeardownFile)), """
                TabTeardown.swift no longer declares run(_:reason:) with that \
                signature — re-anchor this guard.
                """)
        let stopsWatchers = teardown.contains("TeardownStage.stopEditWatchers.runBounded")
        let shutsDownTerminal = teardown.contains("TeardownStage.shutDownTerminal.runBounded")
        #expect(stopsWatchers, """
            TabTeardown.run(_:reason:) no longer runs the edit watchers through \
            TeardownStage.stopEditWatchers.runBounded.
            """)
        #expect(shutsDownTerminal, """
            TabTeardown.run(_:reason:) no longer runs the terminal shutdown through \
            TeardownStage.shutDownTerminal.runBounded — the one stage measured \
            to need a bound.
            """)
    }

    /// Negative, beside the two positives above: a window closing is not
    /// the process ending. The diagnostic log's "app quit" line is written
    /// from `AppDelegate.applicationWillTerminate`, and a non-last window
    /// closing must not reach it.
    @Test func theWindowsClosePathNeverTerminatesTheApplication() throws {
        let source = try Self.code(of: Self.lifecycleFile)
        // BOTH halves of the close path, not just the second (fix round 1):
        // `handleWindowWillClose(_:)` is what the notification reaches, and
        // it could quit the app before ever calling the function below.
        let notified = try #require(
            Self.body(after: "func handleWindowWillClose(_ notification: Notification) {",
                      in: source), """
                ContentView+Lifecycle.swift no longer declares \
                handleWindowWillClose(_:) — re-anchor this guard.
                """)
        let closePath = try #require(
            Self.body(after: "func releaseHeldTabsOnClose() {", in: source), """
                ContentView+Lifecycle.swift no longer declares \
                releaseHeldTabsOnClose() — re-anchor this guard.
                """)
        // The positive: the notified half really does hand over to the
        // released half, so neither body is being scanned in isolation from
        // the other.
        let handsOver = notified.contains("releaseHeldTabsOnClose()")
        #expect(handsOver, """
            handleWindowWillClose(_:) no longer calls releaseHeldTabsOnClose() — \
            a closing window would leave its tabs connected and registered.
            """)
        let terminates = notified.contains("terminate(") || closePath.contains("terminate(")
        #expect(terminates == false, """
            the window's close path terminates the application — closing one \
            window of several would quit macSCP and take every other \
            window's connections with it.
            """)
    }

    /// A window closing tears down the moves nobody claimed BEFORE it
    /// releases the tabs it still holds (fix round 3).
    ///
    /// The order is the claim: an unclaimed seed's tab belongs to no
    /// window, so nothing else will ever reach it, and
    /// `releaseHeldTabsOnClose()` starts an async teardown of everything
    /// else. Both calls are pinned, and so is which comes first.
    @Test func aClosingWindowTearsDownItsUnclaimedMovesBeforeItsHeldTabs() throws {
        let source = try Self.code(of: Self.lifecycleFile)
        let notified = try #require(
            Self.body(after: "func handleWindowWillClose(_ notification: Notification) {",
                      in: source), """
                ContentView+Lifecycle.swift no longer declares \
                handleWindowWillClose(_:) — re-anchor this guard.
                """)
        let unclaimed = notified.range(of: "releaseUnclaimedSeedsOnClose()")
        let held = notified.range(of: "releaseHeldTabsOnClose()")
        #expect(unclaimed != nil, """
            the window's close path no longer tears down the moves nobody \
            claimed — a parked tab would keep a live connection with no window \
            and nothing left that could reach it.
            """)
        #expect(held != nil, """
            the window's close path no longer releases the tabs it holds — \
            re-anchor this guard.
            """)
        if let unclaimed, let held {
            #expect(unclaimed.lowerBound < held.lowerBound, """
                the window's close path releases its held tabs before its \
                unclaimed moves. The unclaimed ones have to be taken out of \
                the registry first — the held release starts an async teardown \
                and the sweep must not race it.
                """)
        }
    }

    /// The teardown itself is the App layer's, through the same
    /// `teardown(_:reason:)` every other path uses — the registry only hands
    /// the tabs out (`TabRegistryNoTeardownGuardTests` is what holds that
    /// boundary from the other side).
    @Test func theUnclaimedSweepTearsDownThroughTheOrdinaryPath() throws {
        let source = try Self.code(of: Self.lifecycleFile)
        let sweep = try #require(
            Self.body(after: "private func takeUnclaimedSeedsOnClose() -> [SessionTab] {",
                      in: source), """
                ContentView+Lifecycle.swift no longer declares \
                takeUnclaimedSeedsOnClose() — re-anchor this guard.
                """)
        let teardownLoop = try #require(
            Self.body(after: "private func tearDownUnclaimedSeeds(_ tabs: [SessionTab]) async {",
                      in: source), """
                ContentView+Lifecycle.swift no longer declares \
                tearDownUnclaimedSeeds(_:) — re-anchor this guard.
                """)
        let asksTheRegistry = sweep.contains("takePendingSeeds(from:")
        let tearsDown = teardownLoop.contains("await teardown(")
        #expect(asksTheRegistry, """
            the unclaimed sweep no longer asks the registry for this window's \
            pending seeds.
            """)
        #expect(tearsDown, """
            the unclaimed sweep no longer runs what it took through \
            teardown(_:reason:) — it would drop live sessions instead of \
            closing them.
            """)
    }

    /// Quitting sweeps what is left, from the one callback AppKit holds the
    /// process open for.
    @Test func quittingSweepsEveryStillParkedMove() throws {
        let app = try Self.code(of: Self.appFile)
        // `applicationShouldTerminate(_:)` since the Quit Teardown plan,
        // Task 1 — the callback that can defer, and therefore the one that
        // can tear the swept tabs down instead of only recording them.
        let terminate = try #require(
            Self.body(after: "func applicationShouldTerminate(", in: app), """
                MacSCPApp.swift no longer declares applicationShouldTerminate(_:) — \
                re-anchor this guard.
                """)
        let sweeps = terminate.contains("sweepUnclaimedMoves()")
        let stillFlushes = terminate.contains("flushSynchronously()")
        #expect(sweeps, """
            applicationShouldTerminate(_:) no longer sweeps the registry's still \
            parked moves — a tab whose window never appeared would go \
            unrecorded at quit.
            """)
        let sweep = try #require(
            Self.body(after: "private func sweepUnclaimedMoves() -> [SessionTab] {", in: app), """
                MacSCPApp.swift no longer declares sweepUnclaimedMoves() — \
                re-anchor this guard.
                """)
        let takesThemAll = sweep.contains("takeAllPendingSeeds()")
        #expect(takesThemAll, """
            the quit sweep no longer takes the registry's pending seeds — the \
            call above would then be doing nothing.
            """)
        #expect(stillFlushes, """
            applicationShouldTerminate(_:) no longer flushes the diagnostic log — \
            the sweep's own lines are the durable half of what it does, so \
            this is what makes them worth writing.
            """)
    }

    /// The negative beside them: round 2's activation-triggered reclaim is
    /// gone, and nothing has quietly put another guess in its place. There
    /// is no signal for "this window will never appear" — SwiftUI reports
    /// no `openWindow` failure — so a trigger that can beat the real claim
    /// is worse than none.
    @Test func noActivationTriggeredReclaimRemains() throws {
        let lifecycle = try Self.code(of: Self.lifecycleFile)
        let sequence = try Self.code(of: Self.sequenceFile)
        // The positive: the activation hook is still there, doing the one
        // thing it is still for.
        let stillPublishes = lifecycle.contains(".onChange(of: controlActiveState")
            && lifecycle.contains("publishToMenuBarIfKey()")
        #expect(stillPublishes, """
            the controlActiveState hook or its menu-bar publish is gone — the \
            negative below would then be forbidding something nothing does \
            any more.
            """)
        #expect(lifecycle.contains("reclaim") == false, """
            ContentView+Lifecycle.swift reclaims a parked tab again. An \
            unclaimed move is torn down when its source window closes, not \
            guessed at from an activation.
            """)
        #expect(sequence.contains("reclaim") == false, """
            TabDetachSequence.swift declares a reclaim again — see above.
            """)
    }

    // MARK: The scene

    @Test func theWindowGroupIsKeyedByTheSeed() throws {
        let source = try Self.code(of: Self.appFile)
        let hasGroup = source.contains("WindowGroup(")
        let isKeyed = source.contains("for: WindowSeed.self")
        #expect(hasGroup, """
            MacSCPApp.swift declares no WindowGroup at all — re-anchor this guard.
            """)
        #expect(isKeyed, """
            MacSCPApp.swift's WindowGroup is no longer keyed by WindowSeed — \
            openWindow(value:) has nothing to open a second window with.
            """)
    }

    /// Positive: the primary window really does present the what's-new
    /// sheet, and exactly once in the whole file.
    @Test func theWhatsNewSheetIsPresentedByThePrimaryWindow() throws {
        let source = try Self.code(of: Self.appFile)
        let primary = try #require(
            Self.body(after: "private func primaryWindow() -> some View {", in: source), """
                MacSCPApp.swift no longer declares primaryWindow() — re-anchor \
                this guard on whatever the seedless branch is called now.
                """)
        let presents = primary.contains("showWhatsNew")
        #expect(presents, """
            the primary window no longer presents the what's-new sheet — the \
            release notes would never be shown.
            """)
        #expect(Self.occurrences(of: ".sheet(isPresented: $showWhatsNew)", in: source) == 1, """
            MacSCPApp.swift attaches the what's-new sheet a number of times \
            other than once.
            """)
    }

    /// Negative, beside the positive above: a detached window does not
    /// present it. The decision was made once per PROCESS, in `init`; a
    /// window opened by a move would otherwise show the release notes a
    /// second time.
    @Test func aDetachedWindowDoesNotPresentTheWhatsNewSheet() throws {
        let source = try Self.code(of: Self.appFile)
        let detached = try #require(
            Self.body(
                after: "private func detachedWindow(seed: WindowSeed) -> some View {",
                in: source), """
                MacSCPApp.swift no longer declares detachedWindow(seed:) — \
                re-anchor this guard on whatever the seeded branch is called now.
                """)
        let presents = detached.contains("showWhatsNew")
        #expect(presents == false, """
            a detached window presents the what's-new sheet — moving a tab \
            into its own window would re-show the release notes.
            """)
    }

    // MARK: The menu item

    /// Both surfaces the plan asks for — the tab's context menu and the
    /// Window menu — resolve the SAME key, so the two can never come to
    /// read differently.
    @Test func bothSurfacesResolveTheMoveEntryThroughOneKey() throws {
        let strip = try Self.codeWithLiterals(of: Self.stripFile)
        let app = try Self.codeWithLiterals(of: Self.commandsFile)
        let stripResolves = strip.contains("L10n.string(\"window.moveTabToNewWindow\"")
        let appResolves = app.contains("L10n.string(\"window.moveTabToNewWindow\"")
        #expect(stripResolves, """
            TabStripView.swift no longer resolves window.moveTabToNewWindow \
            through L10n.string( — the context-menu entry would render as its \
            own key text.
            """)
        #expect(appResolves, """
            MacSCPCommands.swift no longer resolves window.moveTabToNewWindow \
            through L10n.string( — the Window menu entry would render as its \
            own key text.
            """)
    }

    @Test func theMoveEntrysKeyIsInAllFourCatalogues() throws {
        for locale in Self.catalogLocales {
            let present = try Self.catalogKeys(locale).contains("window.moveTabToNewWindow")
            #expect(present, """
                \(Self.catalogPath(locale)) has no window.moveTabToNewWindow \
                entry — the menu item would read as its key text in that language.
                """)
        }
    }

    /// The catalogue check above reads FILES. This one reads what the app
    /// reads: a key appended to `Localizable.strings` is only useful if the
    /// resource bundle `L10n` resolves actually carries it. The fallback is
    /// deliberately absurd, the way `L10nTests` writes its own — no
    /// language can return it, so the assertion holds in all four.
    @Test func theMoveEntrysKeyResolvesInTheBundleTheAppReads() {
        #expect(L10n.string("window.moveTabToNewWindow", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }

    // MARK: The menus follow the focused window

    /// The shape that replaced one app-wide bridge and its key-window
    /// guards (fix round 1): each window publishes its own `TabCommands`
    /// and the menus read the focused one back.
    @Test func theMenusReadTheFocusedWindowsBridge() throws {
        let commands = try Self.code(of: Self.commandsFile)
        let detail = try Self.code(of: Self.detailFile)
        let readsFocusedValue = commands.contains("@FocusedValue(\\.tabCommands)")
        let windowPublishesIt = detail.contains(".focusedSceneValue(\\.tabCommands, tabCommands)")
        #expect(readsFocusedValue, """
            MacSCPCommands.swift no longer reads @FocusedValue(\\.tabCommands) — \
            the menus would act on no window, or on whichever one wrote last.
            """)
        #expect(windowPublishesIt, """
            ContentView+Detail.swift no longer publishes this window's bridge \
            with .focusedSceneValue(\\.tabCommands, tabCommands) — the menus \
            would read nil from every window.
            """)
    }

    /// The negative beside the two positives above: nothing works out
    /// afterwards WHICH window it is. A `NSApp.keyWindow` read or a
    /// `didBecomeKeyNotification` observer in either file is the old shape
    /// coming back — one bridge, several writers, and a guard in every
    /// closure to sort out the mess.
    @Test func nothingReAsksWhichWindowIsKey() throws {
        let commands = try Self.code(of: Self.commandsFile)
        let lifecycle = try Self.code(of: Self.lifecycleFile)
        let detail = try Self.code(of: Self.detailFile)
        // `ContentView+Sheets.swift` joined the list in fix round 2: a live
        // `window?.isKeyWindow` guard survived there, in `presentSnippets()`,
        // because the scan named only the three files round 1 had edited.
        // The positive below is what stops that from happening again in the
        // other direction — a file that stopped containing the thing it is
        // scanned for would otherwise pass every negative here vacuously.
        let sheets = try Self.code(of: Self.sheetsFile)
        let sheetsIsTheRightFile = sheets.contains("func presentSnippets()")
        #expect(sheetsIsTheRightFile, """
            ContentView+Sheets.swift no longer declares presentSnippets() — \
            re-anchor this guard on wherever the menu-driven sheets are \
            presented now.
            """)
        for (name, source) in [
            ("MacSCPCommands.swift", commands),
            ("ContentView+Lifecycle.swift", lifecycle),
            ("ContentView+Detail.swift", detail),
            ("ContentView+Sheets.swift", sheets),
        ] {
            let readsKeyWindow = source.contains("NSApp.keyWindow")
            let observesBecomeKey = source.contains("didBecomeKeyNotification")
            let guardsOnKeyWindow = source.contains("isKeyWindow")
            #expect(readsKeyWindow == false, """
                \(name) reads NSApp.keyWindow again — the focused value already \
                names the window the menus act on.
                """)
            #expect(observesBecomeKey == false, """
                \(name) observes didBecomeKeyNotification again — the re-wire it \
                drove was replaced by the focused value.
                """)
            #expect(guardsOnKeyWindow == false, """
                \(name) guards on isKeyWindow again — being focused is already the \
                precondition for the bridge being read at all.
                """)
        }
    }

    /// The menu-bar status item shows the KEY window's tabs, and says so
    /// where it publishes them.
    @Test func theMenuBarIsPublishedOnlyByTheKeyWindow() throws {
        let lifecycle = try Self.code(of: Self.lifecycleFile)
        let publish = try #require(
            Self.body(after: "func publishToMenuBarIfKey() {", in: lifecycle), """
                ContentView+Lifecycle.swift no longer declares \
                publishToMenuBarIfKey() — re-anchor this guard.
                """)
        let gated = publish.contains("controlActiveState == .key")
        let publishesTabs = publish.contains("menuBarModel.publish(")
            && publish.contains("tabs: tabsModel.tabs")
        #expect(gated, """
            the menu-bar publish is no longer gated on this window being key — \
            a background window's tabs would appear in the status item.
            """)
        #expect(publishesTabs, """
            the menu-bar publish no longer hands this window's tabs to \
            menuBarModel.publish( — the gate above would then be guarding \
            nothing.
            """)
    }

    /// The update-check alert belongs to the primary window, like the
    /// what's-new sheet: one check writes one result, and every window that
    /// attached the alert raised its own copy of it.
    @Test func theUpdateAlertIsPresentedByThePrimaryWindowAlone() throws {
        let sheets = try Self.code(of: Self.sheetsFile)
        let lifecycle = try Self.code(of: Self.lifecycleFile)
        let alertIsThere = sheets.contains("updateModel.presentedResult != nil")
        let alertIsGated = sheets.contains("isPrimaryWindow && updateModel.presentedResult != nil")
        let targetIsGated = sheets.contains("isPrimaryWindow")
            && lifecycle.contains("if isPrimaryWindow { updateModel.hasPresentationTarget = true }")
        #expect(alertIsThere, """
            ContentView+Sheets.swift no longer presents updateModel.presentedResult \
            at all — re-anchor this guard.
            """)
        #expect(alertIsGated, """
            the update-check alert is no longer gated on isPrimaryWindow — every \
            open window would raise its own copy of one result.
            """)
        #expect(targetIsGated, """
            a window that does not present the alert still claims \
            updateModel.hasPresentationTarget — a manual check's result would go \
            to an alert nobody shows instead of to the NSAlert fallback.
            """)
    }

    /// The primary window keeps remembering where it was, even though the
    /// group opts out of system restoration (fix round 2).
    /// `.restorationBehavior(.disabled)` is per GROUP — SwiftUI offers no
    /// per-value knob — so the frame is preserved the AppKit way instead,
    /// by an autosave name, and only for the seedless window.
    @Test func onlyThePrimaryWindowRemembersItsFrame() throws {
        let lifecycle = try Self.code(of: Self.lifecycleFile)
        let autosave = try #require(
            Self.body(after: "func applyFrameAutosave(to window: NSWindow?) {", in: lifecycle), """
                ContentView+Lifecycle.swift no longer declares \
                applyFrameAutosave(to:) — re-anchor this guard.
                """)
        let savesTheFrame = autosave.contains("setFrameAutosaveName(")
        let onlyForThePrimary = autosave.contains("guard isPrimaryWindow")
        // And somebody calls it (fix round 3): the two checks below said
        // what `applyFrameAutosave(to:)` does, and nothing said it ran.
        let detail = try Self.code(of: Self.detailFile)
        let isCalled = detail.contains("applyFrameAutosave(")
        #expect(isCalled, """
            ContentView+Detail.swift never calls applyFrameAutosave( — the \
            primary window's frame would be forgotten however correct that \
            function is.
            """)
        #expect(savesTheFrame, """
            applyFrameAutosave(to:) no longer sets a frame autosave name — the \
            primary window would forget its position, which is what \
            .restorationBehavior(.disabled) took away.
            """)
        #expect(onlyForThePrimary, """
            applyFrameAutosave(to:) is no longer gated on isPrimaryWindow — a \
            window opened by a move would fight the primary one for the same \
            saved frame.
            """)
        // The negative beside them, over the whole App target: there is
        // exactly ONE place a frame autosave name is set, so no seeded
        // window can quietly acquire one somewhere else.
        let sources = try FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/MacSCPAppKit"),
            includingPropertiesForKeys: nil)
        var callSites = 0
        for file in sources where file.pathExtension == "swift" {
            callSites += Self.occurrences(
                of: "setFrameAutosaveName(", in: try Self.code(of: file))
        }
        #expect(callSites == 1, """
            Sources/MacSCPAppKit sets a frame autosave name in \(callSites) \
            places, not the one applyFrameAutosave(to:) owns. Counted in the \
            pass that writes this; a second call site means two windows can \
            claim the same saved frame.
            """)
    }

    // MARK: Restoration

    /// A `Codable` seed on a value-keyed `WindowGroup` is enough for macOS
    /// to reopen every detached window at the next launch, each with a seed
    /// nobody parked anything under. Task 5 is what makes restoration mean
    /// something; until then the group opts out.
    @Test func theWindowGroupOptsOutOfSystemRestoration() throws {
        let source = try Self.code(of: Self.appFile)
        let keyed = source.contains("for: WindowSeed.self")
        let optedOut = source.contains(".restorationBehavior(.disabled)")
        #expect(keyed, """
            MacSCPApp.swift's WindowGroup is no longer value-keyed — re-anchor \
            this guard, and check whether restoration is still a hazard.
            """)
        #expect(optedOut, """
            MacSCPApp.swift's WindowGroup no longer declares \
            .restorationBehavior(.disabled) — the next launch would reopen one \
            window per moved tab, each holding an empty form tab.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic source)

    @Test func theBodyExtractorStopsAtItsOwnClosingBrace() {
        let source = "func a() {\n  if x { y() }\n}\nfunc b() { z() }\n"
        let extracted = Self.body(after: "func a() {", in: source)
        #expect(extracted?.contains("y()") == true)
        #expect(extracted?.contains("z()") == false)
    }

    @Test func theBodyExtractorFailsClosedOnAMissingAnchor() {
        #expect(Self.body(after: "func nothing() {", in: "func a() { }") == nil)
    }

    @Test func theBodyExtractorFailsClosedOnUnbalancedBraces() {
        #expect(Self.body(after: "func a() {", in: "func a() { if x {") == nil)
    }

    /// The negative check above would be satisfied by an empty body, so
    /// here is the proof it reacts to the violation it names: a close path
    /// that quits the app is seen.
    @Test func theTerminationScanFlagsAQuittingClosePath() {
        let planted = """
            func releaseHeldTabsOnClose() {
                NSApp.terminate(nil)
            }
            """
        let closePath = Self.body(after: "func releaseHeldTabsOnClose() {", in: planted)
        #expect(closePath?.contains("terminate(") == true)
    }

    /// And the what's-new negative: a sheet planted in the detached branch
    /// is seen.
    @Test func theSheetScanFlagsASecondPresentation() {
        let planted = """
            private func detachedWindow(seed: WindowSeed) -> some View {
                windowContent(seed: seed)
                    .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
            }
            """
        let detached = Self.body(
            after: "private func detachedWindow(seed: WindowSeed) -> some View {", in: planted)
        #expect(detached?.contains("showWhatsNew") == true)
    }
}
