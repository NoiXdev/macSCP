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
///    `TabsViewModel.detach(tabID:)` may leave `activeTabID` naming the tab
///    that just left when it empties the model, and `activeTab` traps on an
///    id it cannot resolve (`TabsViewModel`'s own documented invariant). So
///    `TabDetachSequence.move` performs the detach, the park and the
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

    /// The window is leaving, so the model is allowed to end up empty — and
    /// this test reads it in exactly the state a view would find it in, one
    /// synchronous step after the move. `activeTab` is deliberately NOT
    /// read: on an emptied model it traps, and the whole point of the
    /// sequence returning `true` here is that the window closes before
    /// anything can read it.
    @Test func theLastTabOfANonLastWindowLeavesAnEmptyModelAndAsksForTheClose() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)
        // A second window, so this one is not the last.
        registry.register(makeTab(), in: WindowID())
        let seedID = UUID()

        let closing = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seedID, in: registry,
            replacement: { self.makeTab() })

        #expect(closing)
        #expect(model.tabs.isEmpty)
        #expect(registry.parkedTabs(for: seedID).first === tab)
    }

    /// The last window stays, so the invariant `activeTab` depends on has to
    /// be restored before the step returns: a fresh tab is put in its place
    /// and `activeTab` resolves again. Reading `activeTab` here is the
    /// assertion — it would trap if the model had been left empty.
    @Test func theLastTabOfTheLastWindowIsReplacedRatherThanLeavingItEmpty() {
        let registry = TabRegistry()
        let window = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: window)

        let closing = TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: UUID(), in: registry,
            replacement: { self.makeTab() })

        #expect(closing == false)
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

        let closing = TabDetachSequence.move(
            leaving.id, outOf: model, parkingUnder: UUID(), in: registry,
            replacement: { self.makeTab() })

        #expect(closing == false)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0] === staying)
        #expect(model.activeTab.id == staying.id)
    }

    /// The whole point of the move: the object that arrives is the object
    /// that left. Its `BrowserSession` is untouched because nothing on this
    /// path can touch it — `detach`, `park` and `claim` move a reference
    /// between collections and nothing else (Global Constraints: "a move
    /// never touches the connection", pinned against the connection itself
    /// in `TabRegistryTests`).
    @Test func theTabThatArrivesIsTheTabThatLeft() {
        let registry = TabRegistry()
        let source = WindowID()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        model.addTab(makeTab())
        registry.register(tab, in: source)
        let seedID = UUID()

        TabDetachSequence.move(
            tab.id, outOf: model, parkingUnder: seedID, in: registry,
            replacement: { self.makeTab() })

        let target = WindowID()
        let arrived = registry.claim(seedID: seedID, into: target)
        #expect(arrived.first === tab)
        #expect(registry.windowHolding(tab.id) == target)
    }

    /// An id the model does not hold moves nothing and parks nothing — a
    /// repeated or stale invocation cannot conjure a window.
    @Test func anIDTheModelDoesNotHoldMovesNothing() {
        let registry = TabRegistry()
        let tab = makeTab()
        let model = TabsViewModel<SessionTab>(initial: tab)
        registry.register(tab, in: WindowID())
        let seedID = UUID()

        let closing = TabDetachSequence.move(
            UUID(), outOf: model, parkingUnder: seedID, in: registry,
            replacement: { self.makeTab() })

        #expect(closing == false)
        #expect(model.tabs.count == 1)
        #expect(registry.parkedTabs(for: seedID).isEmpty)
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
        let closePath = try #require(
            Self.body(after: "func releaseHeldTabsOnClose() {", in: source), """
                ContentView+Lifecycle.swift no longer declares \
                releaseHeldTabsOnClose() — re-anchor this guard.
                """)
        let terminates = closePath.contains("terminate(")
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
        let app = try Self.codeWithLiterals(of: Self.appFile)
        let stripResolves = strip.contains("L10n.string(\"window.moveTabToNewWindow\"")
        let appResolves = app.contains("L10n.string(\"window.moveTabToNewWindow\"")
        #expect(stripResolves, """
            TabStripView.swift no longer resolves window.moveTabToNewWindow \
            through L10n.string( — the context-menu entry would render as its \
            own key text.
            """)
        #expect(appResolves, """
            MacSCPApp.swift no longer resolves window.moveTabToNewWindow \
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
