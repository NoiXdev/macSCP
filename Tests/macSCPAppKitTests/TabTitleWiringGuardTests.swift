import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards that the tab strip and the window title draw
/// `TabTitlePlan.title(…)`'s answer (jump-and-groups plan, Task 3), reached
/// through `ContentView.tabTitle(for:)`, and that the resolver takes
/// "showing the overview" from the detail pane's own answer.
///
/// Why it needs guarding rather than trusting: `TabTitlePlanTests` pins the
/// plan's answers, and they say nothing if the strip goes back to reading
/// `SessionTab.displayTitle` — which is exactly what it read while every
/// edited, dialed or previewed tab said "New Connection" — or if the window
/// title keeps a rule of its own beside the strip's.
///
/// Reads source with comments and string literals blanked
/// (`SwiftSource.blankingCommentsAndStrings`), compared with whitespace
/// removed; every negative check has a positive one beside it that fails
/// first if the thing it scans is gone.
@Suite("Tab title wiring")
struct TabTitleWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appDirectory = "Sources/MacSCPAppKit"
    private static let stripPath = "Sources/MacSCPAppKit/TabStripView.swift"
    private static let detailPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"
    private static let resolverPath = "Sources/MacSCPAppKit/ContentView+TabTitle.swift"

    /// No trailing `{` — `declarationBodyRange` opens at the first brace
    /// after the declaration text.
    private static let resolverDeclaration = "func tabTitle(for tab: SessionTab) -> TabTitle"

    /// The strip's label, drawn from the value it was handed.
    private static let stripLabel = "Text(title.tabLabel)"
    /// The strip hands each item its own tab's title, bare.
    private static let itemHandOver = "title:title(tab),"
    /// The two stored properties that carry it: the strip's question, the
    /// item's answer.
    private static let stripProperty = "lettitle:(SessionTab)->TabTitle"
    private static let itemProperty = "lettitle:TabTitle"
    /// The window hands the strip the resolver, bare.
    private static let stripWiring = "title:{tabTitle(for:$0)},"
    /// The window title, from the same resolver, for the tab the window
    /// shows.
    private static let windowTitle = ".navigationTitle(tabTitle(for:activeTab).windowTitle)"

    private static func code(_ relativePath: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - The strip draws the plan's answer

    /// The positive half for the strip: it draws the title it was handed,
    /// it is handed one per tab, and the window hands it the resolver.
    @Test func theTabStripDrawsThePlansTitle() throws {
        let strip = Self.compact(try Self.code(Self.stripPath))
        #expect(Self.occurrences(of: Self.stripLabel, in: strip) == 1, """
            \(Self.stripPath) must draw `\(Self.stripLabel)` exactly once — the tab's label is \
            the plan's answer, handed in, not something the strip reads off the tab.
            """)
        #expect(Self.occurrences(of: Self.stripProperty, in: strip) == 1, """
            the strip no longer stores `\(Self.stripProperty)` — it is not being asked for a \
            title per tab.
            """)
        #expect(Self.occurrences(of: Self.itemProperty, in: strip) == 1, """
            the tab item no longer stores `\(Self.itemProperty)` — what `\(Self.stripLabel)` \
            reads is not the handed-in value.
            """)
        let construction = Self.compact(try DiagnosticsDoorsGuardTests.argumentSpan(
            after: "TabItemView(", in: try Self.code(Self.stripPath), occurrence: 1))
        #expect(construction.contains("tab:tab,"), "the scanned span is not the item's construction")
        #expect(construction.contains(Self.itemHandOver), """
            the strip no longer hands each item `\(Self.itemHandOver)` — an item could be drawing \
            another tab's title, or a title the strip made up.
            """)

        let detail = try Self.code(Self.detailPath)
        let wiring = Self.compact(try DiagnosticsDoorsGuardTests.argumentSpan(
            after: "TabStripView(", in: detail, occurrence: 1))
        #expect(wiring.contains("tabs:tabsModel.tabs,"), "the scanned span is not the strip's construction")
        #expect(wiring.contains(Self.stripWiring), """
            the window no longer hands the strip `\(Self.stripWiring)` — the strip's titles are \
            not the resolver's.
            """)
    }

    /// The negative half: the strip reads no title of its own. Its
    /// positive partner is the first expectation — the label that replaced
    /// these reads is there.
    @Test func theTabStripReadsNoTitleOfItsOwn() throws {
        let strip = Self.compact(try Self.code(Self.stripPath))
        #expect(Self.occurrences(of: Self.stripLabel, in: strip) == 1)
        for read in ["displayTitle", "titleName"] {
            let count = Self.occurrences(of: read, in: strip)
            #expect(count == 0, """
                \(Self.stripPath) reads `\(read)` \(count) time(s) — a title that is not the \
                plan's, which knows only "connected or not".
                """)
        }
    }

    // MARK: - The window title draws the same answer

    /// Positive by construction, and exclusive: the one `.navigationTitle(`
    /// in the app is the resolver's answer for the active tab.
    @Test func theWindowTitleDrawsThePlansTitle() throws {
        let detail = Self.compact(try Self.code(Self.detailPath))
        #expect(Self.occurrences(of: Self.windowTitle, in: detail) == 1, """
            \(Self.detailPath) must set `\(Self.windowTitle)` exactly once — the window title \
            and the active tab's label are the same answer.
            """)
        var titles = 0
        for file in try Self.appSources() {
            titles += Self.occurrences(of: ".navigationTitle(", in: Self.compact(try Self.code(file)))
        }
        #expect(titles == 1, """
            the app sets \(titles) `.navigationTitle(`s, expected exactly one — a second one is \
            a window title with a rule of its own.
            """)
    }

    // MARK: - The resolver

    /// The resolver hands the plan every fact its rule is about, and takes
    /// "showing the overview" from the detail pane's own answer.
    @Test func theResolverAsksThePlanWithTheDetailPanesAnswer() throws {
        let resolver = Self.compact(try Self.body(of: Self.resolverDeclaration, in: Self.resolverPath))
        for fact in [
            "TabTitlePlan.title(", "connectedName:tab.titleName", "liveness:tab.liveness",
            "lostConnection:tab.lostConnection", "connectFailure:tab.connectFailure",
            ".unacknowledgedFailure", ".attemptOrigin", ".mode",
            "surface:detailSurface(for:tab)", "isActive:tab.id==activeTab.id",
            "sessions:sessionListViewModel.sessions",
        ] {
            #expect(resolver.contains(fact), """
                `tabTitle(for:)` no longer hands the plan `\(fact)` — the rule it decides on \
                would be reading something else, or nothing.
                """)
        }
    }

    /// The overview reaches the title only through `detailSurface(for:)`.
    /// Its positive partner is the expectation above that the resolver
    /// reads `detailSurface(for: tab)`.
    @Test func theResolverDoesNotDecideTheOverviewItself() throws {
        let resolver = Self.compact(try Self.body(of: Self.resolverDeclaration, in: Self.resolverPath))
        #expect(resolver.contains("surface:detailSurface(for:tab)"))
        for read in ["overviewSession", "overviewSessionID", "restoredSessionID", "DetailSurfacePlan"] {
            #expect(!resolver.contains(read), """
                `tabTitle(for:)` reads `\(read)` — "showing the overview" would be decided a \
                second time, beside the answer the detail pane switches on.
                """)
        }
    }

    /// The plan is asked in exactly one place in the app.
    @Test func thePlanIsAskedOnlyByTheResolver() throws {
        var asks: [String: Int] = [:]
        for file in try Self.appSources() {
            let count = Self.occurrences(of: "TabTitlePlan.title(", in: try Self.code(file))
            if count > 0 { asks[file] = count }
        }
        #expect(asks == [Self.resolverPath: 1], """
            `TabTitlePlan.title(` is asked in \(asks) — expected once, in `tabTitle(for:)`.
            """)
    }

    // MARK: - Helpers

    private static func body(of declaration: String, in relativePath: String) throws -> String {
        let source = try code(relativePath)
        return TransferQueueBarCancelGuardTests.slice(
            try TransferQueueBarCancelGuardTests.declarationBodyRange(of: declaration, in: source),
            of: source)
    }

    /// Every Swift file of the app target, subdirectories included,
    /// relative to the repository.
    private static func appSources() throws -> [String] {
        let directory = repoRoot.appendingPathComponent(appDirectory)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { "\(appDirectory)/\($0)" }
        #expect(files.contains(stripPath) && files.contains(detailPath), """
            the app's source list is not the one this guard was written against
            """)
        return files
    }
}
