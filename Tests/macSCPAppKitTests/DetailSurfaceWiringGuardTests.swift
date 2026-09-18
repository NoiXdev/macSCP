import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards that the unconnected tab's detail pane has ONE decision point
/// (jump-and-groups plan, Task 1): `DetailSurfacePlan.surface(…)`, reached
/// through `ContentView.detailSurface(for:)`, and a view that switches on
/// its answer and decides nothing of its own.
///
/// Why it needs guarding rather than trusting: the defect this task fixed
/// was a condition written inline in the view body — the overview branch
/// asked only for a selection and `.new` mode, sat before the form, and so
/// covered the host-key card the form owns. `DetailSurfacePlanTests` pins
/// the plan's answers; they say nothing if the view stops asking the plan,
/// or asks it and then adds a second condition beside it.
///
/// Also guards the sidebar start's tab-factory seam: production passes no
/// factory, so the window's own `makeTab()` — the real connector — is what
/// every sidebar start gets outside a test.
///
/// Reads source with comments and string literals blanked
/// (`SwiftSource.blankingCommentsAndStrings`); every negative check has a
/// positive one beside it that fails first if the thing it scans is gone.
@Suite("Detail surface wiring")
struct DetailSurfaceWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let detailPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"
    private static let contentViewPath = "Sources/MacSCPAppKit/ContentView.swift"
    private static let planPath = "Sources/MacSCPAppKit/DetailSurfacePlan.swift"
    private static let appPath = "Sources/MacSCPAppKit/MacSCPApp.swift"

    /// No trailing `{` — `declarationBodyRange` opens at the first brace
    /// after the declaration text.
    private static let resolverDeclaration = "func detailSurface(for tab: SessionTab) -> DetailSurface"
    private static let planDeclaration = "static func surface("
    private static let startDeclaration = "func startWithoutAsking("
    private static let tabMakerDeclaration = "func makeSidebarTab() -> SessionTab"

    /// The one read of the answer in the view body, and the one branch the
    /// overview is built in.
    private static let surfaceRead = "let surface = detailSurface(for: tab)"
    private static let overviewBranch = "else if case .overview(let stored) = surface"
    /// The seam's own parameter label, as `ContentView.init` spells it.
    private static let seamLabel = "sidebarTabFactory:"

    private static func code(_ relativePath: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    private static func body(of declaration: String, in source: String) throws -> String {
        TransferQueueBarCancelGuardTests.slice(
            try TransferQueueBarCancelGuardTests.declarationBodyRange(of: declaration, in: source),
            of: source)
    }

    /// `source` with `declaration`'s body blanked, length preserved — what
    /// the rest of the file says once the one sanctioned site is taken out.
    private static func blankingBody(of declaration: String, in source: String) throws -> String {
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(of: declaration, in: source)
        var characters = Array(source)
        for index in range where characters[index] != "\n" { characters[index] = " " }
        return String(characters)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - The view reads the plan

    /// The positive half. Fails first, and loudly, if the view stops asking
    /// the plan, if the overview is built anywhere but the plan's own
    /// branch, or if the resolver stops handing the plan the facts its rule
    /// is about.
    @Test func theDetailPaneSwitchesOnThePlansAnswer() throws {
        let detail = try Self.code(Self.detailPath)
        #expect(Self.occurrences(of: Self.surfaceRead, in: detail) == 1, """
            \(Self.detailPath) must read `\(Self.surfaceRead)` exactly once — the unconnected \
            tab's surface is the plan's answer, asked once per render.
            """)
        #expect(Self.occurrences(of: Self.overviewBranch, in: detail) == 1, """
            the session overview is no longer built in the plan's `.overview` branch — it is \
            chosen by a condition of the view's own again.
            """)

        let resolver = try Self.body(of: Self.resolverDeclaration, in: detail)
        for fact in [
            "DetailSurfacePlan.surface(", "overviewSession(for: tab)", ".hostKeyPrompt",
            ".lastFailureKind", ".state", ".mode", "tab.liveness", "tab.connectFailure",
        ] {
            #expect(resolver.contains(fact), """
                `detailSurface(for:)` no longer hands the plan `\(fact)` — the rule it decides \
                on would be reading something else, or nothing.
                """)
        }

        let plan = try Self.body(of: Self.planDeclaration, in: try Self.code(Self.planPath))
        #expect(plan.contains("ConnectionSurfacePlan.surface("), """
            `DetailSurfacePlan.surface` no longer composes `ConnectionSurfacePlan.surface` — the \
            rule that a pending host-key prompt forces the form would then have two homes.
            """)
    }

    /// The negative half: outside `detailSurface(for:)`, the detail file
    /// names none of the facts the overview is decided on, so no second
    /// overview condition can stand beside the plan's. Its positive partner
    /// is the check above, which requires the resolver — the region
    /// blanked here — to exist and to read those facts.
    @Test func noSecondOverviewConditionRemainsInTheView() throws {
        let detail = try Self.code(Self.detailPath)
        let resolver = try Self.body(of: Self.resolverDeclaration, in: detail)
        #expect(resolver.contains("overviewSession(for: tab)"), """
            the resolver is not where the overview's session is read — the negative scan \
            below would be pointed at nothing.
            """)
        let rest = try Self.blankingBody(of: Self.resolverDeclaration, in: detail)
        for condition in [
            "overviewSession(", "mode == .new", "mode != .new", "ConnectionSurfacePlan.surface(",
            "DetailSurfacePlan.surface(",
        ] {
            let count = Self.occurrences(of: condition, in: rest)
            #expect(count == 0, """
                \(Self.detailPath) reads `\(condition)` \(count) time(s) outside \
                `detailSurface(for:)` — a second place deciding what an unconnected tab shows.
                """)
        }
    }

    /// The scan above is measured against a planted violation, so it is
    /// known to be able to fail at all.
    @Test func theNegativeScanCatchesAPlantedInlineCondition() throws {
        let planted = """
            func detailSurface(for tab: SessionTab) -> DetailSurface {
                DetailSurfacePlan.surface(overviewSession: overviewSession(for: tab))
            }
            var body: some View {
                let surface = detailSurface(for: tab)
                if let stored = overviewSession(for: tab), tab.connectionViewModel.mode == .new {
                    SessionOverviewView(session: stored)
                }
            }
            """
        let rest = try Self.blankingBody(of: Self.resolverDeclaration, in: planted)
        #expect(Self.occurrences(of: "overviewSession(", in: rest) == 1)
        #expect(Self.occurrences(of: "mode == .new", in: rest) == 1)
    }

    // MARK: - The tab-factory seam

    /// The sidebar start makes its fresh tab through the seam, and the seam
    /// falls back to the window's own `makeTab()`.
    @Test func theSidebarStartMakesItsTabThroughTheSeam() throws {
        let contentView = try Self.code(Self.contentViewPath)
        let start = try Self.body(of: Self.startDeclaration, in: contentView)
        #expect(start.contains("makeTab: makeSidebarTab"), """
            `startWithoutAsking` no longer takes its fresh tab from `makeSidebarTab` — the \
            factory the jump tests inject would be bypassed, and they would dial for real.
            """)
        let maker = try Self.body(of: Self.tabMakerDeclaration, in: contentView)
        #expect(maker.contains("sidebarTabFactory"))
        #expect(maker.contains("makeTab()"), """
            `makeSidebarTab` no longer falls back to the window's own `makeTab()` — production \
            would lose the real connector.
            """)
    }

    /// Only a test injects a factory: the one production construction of
    /// the window passes none. The positive partner is the first
    /// expectation — the construction site is found and is the one that
    /// passes the app's own stores.
    @Test func theProductionWindowPassesNoTabFactory() throws {
        let app = try Self.code(Self.appPath)
        #expect(Self.occurrences(of: "ContentView(", in: app) == 1, """
            \(Self.appPath) no longer constructs `ContentView(` exactly once — re-point this \
            guard at wherever the window is built now.
            """)
        let arguments = try DiagnosticsDoorsGuardTests.argumentSpan(
            after: "ContentView(", in: app, occurrence: 1)
        #expect(arguments.contains("settingsStore:"), "the scanned span is not the window's construction")
        #expect(!arguments.contains(Self.seamLabel), """
            the production window passes a sidebar tab factory — every sidebar start would stop \
            using the real `makeTab()` and its connector.
            """)
    }
}
