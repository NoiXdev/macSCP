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
/// And, since fix round 1, the other half of the same outcome: the form the
/// plan sends a failure to must SHOW it. The form's failure text lives in
/// an alert, and the view is the only place that can raise it, so the
/// raising has to be read from source — `FormFailureAlertPlanTests` pins
/// what is raised, this suite pins that the form asks.
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
    private static let formPath = "Sources/MacSCPAppKit/ConnectionFormView.swift"

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
    /// The seam's parameter TYPE, as `ContentView.init` spells it. The
    /// label is read off the parameter that has this type rather than
    /// spelled here (fix round 1): a spelled label matched the internal
    /// name of a renamed parameter (`tabFactory sidebarTabFactory:`) and
    /// kept passing, measured as probe Q10.
    private static let seamType = "(@MainActor () -> SessionTab)?"

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(relativePath))
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
            ".unacknowledgedFailure", ".mode", "tab.liveness", "tab.connectFailure",
            "tab.lostConnection",
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

    /// Everything outside `detailSurface(for:)` that would be a second
    /// overview condition: the overview's session, ANY read of the form's
    /// mode (so no spelling of a mode comparison — `== .new`, `!= .edit`,
    /// `case .new`, a `switch` — can be written without reading it), the
    /// failure marker, and both plans. Fix round 1 replaced a list of two
    /// comparison spellings with the read itself, after review found the
    /// list missed `!= .edit` and `case .new`.
    private static let decisionFacts = [
        "overviewSession(", ".mode", ".unacknowledgedFailure", "ConnectionSurfacePlan.surface(",
        "DetailSurfacePlan.surface(",
    ]

    /// Occurrences of `fact` as a whole member name — `.mode` does not
    /// count `.modes` or `.modeLabel`.
    private static func reads(of fact: String, in text: String) -> Int {
        guard fact.hasPrefix("."), fact.last?.isLetter == true else { return occurrences(of: fact, in: text) }
        let pattern = NSRegularExpression.escapedPattern(for: fact) + "(?![A-Za-z0-9_])"
        guard let regex = try? CompiledPattern.regex(pattern) else { return -1 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The negative half: outside `detailSurface(for:)`, the detail file
    /// reads none of the facts the overview is decided on, so no second
    /// overview condition can stand beside the plan's. Its positive
    /// partners are the first expectations here and the check above, which
    /// require the resolver — the region blanked here — to exist and to
    /// read every one of those facts.
    @Test func noSecondOverviewConditionRemainsInTheView() throws {
        let detail = try Self.code(Self.detailPath)
        let resolver = try Self.body(of: Self.resolverDeclaration, in: detail)
        for fact in Self.decisionFacts where fact != "ConnectionSurfacePlan.surface(" {
            #expect(Self.reads(of: fact, in: resolver) > 0, """
                the resolver does not read `\(fact)` — the negative scan below would be \
                pointed at nothing for it.
                """)
        }
        let rest = try Self.blankingBody(of: Self.resolverDeclaration, in: detail)
        for fact in Self.decisionFacts {
            let count = Self.reads(of: fact, in: rest)
            #expect(count == 0, """
                \(Self.detailPath) reads `\(fact)` \(count) time(s) outside \
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
                } else if case .new = tab.connectionViewModel.mode {
                } else if tab.connectionViewModel.mode != .edit(sessionID: id) {
                }
                let modes = tab.modes
            }
            """
        let rest = try Self.blankingBody(of: Self.resolverDeclaration, in: planted)
        #expect(Self.reads(of: "overviewSession(", in: rest) == 1)
        #expect(Self.reads(of: ".mode", in: rest) == 3, "each spelling of a mode comparison reads `.mode`; `.modes` does not")
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
        // The label the negative check below looks for is READ off the
        // init's one parameter of the seam's type, so it follows a rename
        // (review, fix round 1). Positive: that parameter must exist.
        let contentView = try Self.code(Self.contentViewPath)
        var initialiser: String?
        var occurrence = 1
        while initialiser == nil,
              let span = try? DiagnosticsDoorsGuardTests.argumentSpan(
                  after: "init(", in: contentView, occurrence: occurrence)
        {
            if span.contains("settingsStore: SettingsStore") { initialiser = span }
            occurrence += 1
        }
        let labels = Self.externalLabels(ofParametersTyped: Self.seamType, in: initialiser ?? "")
        #expect(initialiser != nil, "ContentView's own init was not found in \(Self.contentViewPath)")
        #expect(labels.count == 1, """
            ContentView.init has \(labels.count) parameter(s) of type `\(Self.seamType)`, expected \
            exactly one — the sidebar tab factory. Without it the check below has no label to \
            look for and would pass over anything.
            """)
        let seamLabel = (labels.first ?? "<missing>") + ":"

        let app = try Self.code(Self.appPath)
        #expect(Self.occurrences(of: "ContentView(", in: app) == 1, """
            \(Self.appPath) no longer constructs `ContentView(` exactly once — re-point this \
            guard at wherever the window is built now.
            """)
        let arguments = try DiagnosticsDoorsGuardTests.argumentSpan(
            after: "ContentView(", in: app, occurrence: 1)
        #expect(arguments.contains("settingsStore:"), "the scanned span is not the window's construction")
        #expect(!arguments.contains(seamLabel), """
            the production window passes a sidebar tab factory — every sidebar start would stop \
            using the real `makeTab()` and its connector.
            """)
    }

    /// The EXTERNAL label of every parameter of `type` in a parameter
    /// list: the first identifier of the parameter, whether it is written
    /// `name: T` or `label name: T`.
    static func externalLabels(ofParametersTyped type: String, in parameters: String) -> [String] {
        let identifier = "[A-Za-z_][A-Za-z0-9_]*"
        let pattern = "(?:^|[,(])\\s*(\(identifier))(?:\\s+\(identifier))?\\s*:\\s*"
            + NSRegularExpression.escapedPattern(for: type)
        guard let regex = try? CompiledPattern.regex(pattern) else { return [] }
        let range = NSRange(parameters.startIndex..., in: parameters)
        return regex.matches(in: parameters, range: range).compactMap { match in
            Range(match.range(at: 1), in: parameters).map { String(parameters[$0]) }
        }
    }

    /// The label reader, on both spellings and a list that has neither.
    @Test func theLabelReaderReadsTheExternalLabel() {
        let type = "(@MainActor () -> SessionTab)?"
        #expect(Self.externalLabels(ofParametersTyped: type, in: """
            a: Int,
                sidebarTabFactory: (@MainActor () -> SessionTab)? = nil
            """) == ["sidebarTabFactory"])
        #expect(Self.externalLabels(ofParametersTyped: type, in: """
            a: Int,
                tabFactory sidebarTabFactory: (@MainActor () -> SessionTab)? = nil
            """) == ["tabFactory"])
        #expect(Self.externalLabels(ofParametersTyped: type, in: "a: Int, b: String").isEmpty)
    }

    // MARK: - The form shows the failure it is sent

    /// The bodies of every `anchor` modifier's closure in `source`.
    private static func closureBodies(after anchor: String, in source: String) throws -> [String] {
        var bodies: [String] = []
        var rest = Substring(source)
        while let hit = rest.range(of: anchor) {
            let tail = String(rest[hit.lowerBound...])
            let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(of: anchor, in: tail)
            bodies.append(TransferQueueBarCancelGuardTests.slice(range, of: tail))
            rest = rest[hit.upperBound...]
        }
        return bodies
    }

    /// A form that mounts into an unread failure raises it: an `.onAppear`
    /// asks `FormFailureAlertPlan.onAppear` with the marker. Positive by
    /// construction — it fails the moment the call moves or goes.
    @Test func theFormRaisesAnUnreadFailureWhenItAppears() throws {
        let form = try Self.code(Self.formPath)
        let appears = try Self.closureBodies(after: ".onAppear", in: form)
        #expect(!appears.isEmpty, "\(Self.formPath) has no `.onAppear` at all")
        #expect(appears.contains { $0.contains("FormFailureAlertPlan.onAppear(")
            && $0.contains("viewModel.unacknowledgedFailure") }, """
            no `.onAppear` in the form asks `FormFailureAlertPlan.onAppear` with \
            `viewModel.unacknowledgedFailure` — a form mounted into a failure shows no text.
            """)
    }

    /// A mounted form still raises every transition into a failure, and
    /// through the same plan, so the marker travels with the alert.
    @Test func theFormRaisesEveryTransitionThroughThePlan() throws {
        let form = try Self.code(Self.formPath)
        let changes = try Self.closureBodies(after: ".onChange(of: viewModel.state)", in: form)
        #expect(changes.count == 1, "expected exactly one `.onChange(of: viewModel.state)` in the form")
        #expect(changes.first?.contains("FormFailureAlertPlan.onChange(") == true)
    }

    /// Dismissing the alert — by any of its buttons — acknowledges the
    /// failure it showed, which is what stops it being raised again.
    @Test func dismissingTheFormsAlertAcknowledgesTheFailure() throws {
        let form = try Self.code(Self.formPath)
        #expect(Self.occurrences(of: ".alert(", in: form) == 1, "expected the form's one `.alert(`")
        let arguments = try DiagnosticsDoorsGuardTests.argumentSpan(after: ".alert(", in: form, occurrence: 1)
        #expect(arguments.contains("isPresented:"), "the scanned span is not the alert's arguments")
        #expect(arguments.contains("viewModel.acknowledgeFailure("), """
            the form's alert no longer acknowledges the failure when it is dismissed — every \
            remount would raise the same text again.
            """)
    }
}
