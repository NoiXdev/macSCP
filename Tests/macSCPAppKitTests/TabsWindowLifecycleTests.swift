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

        registry.park([tab], for: seedID)
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
        registry.park([tab], for: UUID())
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
            tab.id, outOf: model, parkingUnder: seed, in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in })

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
            tab.id, outOf: model, parkingUnder: WindowSeed(tabIDs: [tab.id]), in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in })

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
            in: registry, replacement: { self.makeTab() }, openWindow: { _ in })

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
            tab.id, outOf: model, parkingUnder: seed, in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in })

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
            UUID(), outOf: model, parkingUnder: seed, in: registry,
            replacement: { self.makeTab() }, openWindow: { opened.append($0) })

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
        registry.register(tab, in: WindowID())
        let seed = WindowSeed(tabIDs: [tab.id])
        var parkedWhenOpened: [UUID] = []

        TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, in: registry,
            replacement: { self.makeTab() },
            openWindow: { parkedWhenOpened = registry.parkedTabs(for: $0.id).map(\.id) })

        #expect(parkedWhenOpened == [tab.id])
    }

    // MARK: The reclaim (the window never opened)

    /// The failure the ordering exists for (fix round 1): the open is
    /// refused or lost, nothing claims the seed, and one turn later the tab
    /// must be back where it started rather than parked forever with a live
    /// connection and no window. Driven through the seam — an `openWindow`
    /// that does nothing is exactly "the window never opened".
    @Test func aWindowThatNeverOpenedGivesTheTabBack() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)
        registry.register(makeTab(), in: WindowID())
        let seed = WindowSeed(tabIDs: [tab.id])

        let outcome = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, in: registry,
            replacement: { self.makeTab() }, openWindow: { _ in })
        #expect(outcome.closesWindow)

        let cameBack = TabDetachSequence.reclaim(
            seedID: seed.id, into: model, from: registry,
            window: window, removing: outcome.replacementID)

        #expect(cameBack)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0] === tab)
        #expect(model.activeTab.id == tab.id)
        #expect(registry.windowHolding(tab.id) == window)
        #expect(registry.parkedTabs(for: seed.id).isEmpty)
    }

    /// The positive beside it: when a window DID claim the seed, the
    /// reclaim finds nothing, answers `false`, and leaves the source window
    /// exactly as the move left it — so the caller goes on to close it.
    @Test func aWindowThatClaimedTheSeedLeavesNothingToReclaim() {
        let registry = TabRegistry()
        let window = WindowID()
        let target = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)
        registry.register(makeTab(), in: WindowID())
        let seed = WindowSeed(tabIDs: [tab.id])

        let outcome = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seed, in: registry,
            replacement: { self.makeTab() },
            openWindow: { _ = registry.claim(seedID: $0.id, into: target) })

        let cameBack = TabDetachSequence.reclaim(
            seedID: seed.id, into: model, from: registry,
            window: window, removing: outcome.replacementID)

        #expect(cameBack == false)
        #expect(outcome.closesWindow)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == outcome.replacementID)
        #expect(registry.windowHolding(tab.id) == target)
    }

    /// A reclaim into a window that never lost anything is a no-op — the
    /// same reading every other function here takes of an id or a seed it
    /// does not know.
    @Test func aSeedNothingWasParkedUnderReclaimsNothing() {
        let registry = TabRegistry()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        let cameBack = TabDetachSequence.reclaim(
            seedID: UUID(), into: model, from: registry,
            window: WindowID(), removing: nil)
        #expect(cameBack == false)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0] === tab)
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
    @Test func theWindowsClosePathTearsDownWhatItHoldsAndThenReleasesIt() throws {
        let source = try Self.code(of: Self.lifecycleFile)
        let closePath = try #require(
            Self.body(after: "func releaseHeldTabsOnClose() {", in: source), """
                ContentView+Lifecycle.swift no longer declares \
                releaseHeldTabsOnClose() — re-anchor this guard on whatever \
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
        let teardown = try #require(
            Self.body(
                after: "func teardown(_ tab: SessionTab, reason: CancelReason) async {",
                in: source), """
                ContentView+Lifecycle.swift no longer declares \
                teardown(_:reason:) with that signature — re-anchor this guard.
                """)
        let stopsWatchers = teardown.contains("TeardownStage.stopEditWatchers.runBounded")
        let shutsDownTerminal = teardown.contains("TeardownStage.shutDownTerminal.runBounded")
        #expect(stopsWatchers, """
            teardown(_:reason:) no longer runs the edit watchers through \
            TeardownStage.stopEditWatchers.runBounded.
            """)
        #expect(shutsDownTerminal, """
            teardown(_:reason:) no longer runs the terminal shutdown through \
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
        for (name, source) in [
            ("MacSCPCommands.swift", commands),
            ("ContentView+Lifecycle.swift", lifecycle),
            ("ContentView+Detail.swift", detail),
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
        let publishesTabs = publish.contains("menuBarModel.tabs = tabsModel.tabs")
        #expect(gated, """
            the menu-bar publish is no longer gated on this window being key — \
            a background window's tabs would appear in the status item.
            """)
        #expect(publishesTabs, """
            the menu-bar publish no longer writes menuBarModel.tabs — the gate \
            above would then be guarding nothing.
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
