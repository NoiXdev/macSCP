import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards the read-only session overview: the branch that puts it on screen,
/// the three actions it offers, the responsive split that keeps it usable in
/// a narrow pane, and the catalogue the labels resolve out of (design:
/// `docs/superpowers/specs/2026-09-04-session-overview-design.md`).
///
/// **The properties are the `@Test` names below.** This header does not list
/// them, for the reason `DiagnosticsDoorsGuardTests`' own header gives: an
/// enumeration in a comment is a claim about the rest of the file, and it
/// goes stale exactly when nobody is reading it.
///
/// The decisions this suite encodes:
///
/// * **The overview adds no fourth way to connect, edit or diagnose.** Its
///   three actions are the window's existing effects handed over as values —
///   the connect one under the `SessionRowConnectEffect` discipline, so the
///   view can fire it only by naming an input and cannot swap it for
///   another effect. The wiring in `ContentView+Detail.swift` is where the
///   three resolve, and this suite reads them there.
/// * **The head stays put while the rest scrolls.** Name, kind, endpoint and
///   the three actions sit OUTSIDE the `ScrollView`; the facts, the recent
///   connections and the snippets sit inside it. Same split
///   `ConnectionFormView` got on 2026-09-04, and this suite is written in
///   the shape of `ConnectionFormScrollGuardTests`, which guards that one.
/// * **Every label the model can emit exists in the App's catalogues.**
///   `SessionOverviewModel` in Core emits `overview.fact.<id>` label keys
///   and resolves none of them; the App owns all four catalogues. The ids
///   are READ out of Core's own source here rather than spelled a second
///   time, so a sixteenth fact fails this suite until it has a label.
///
/// ## The negative checks have positive partners
///
/// CLAUDE.md, "Guards that name what they watch". Two checks here are
/// negative — `noOtherHostReachingEntryIsWiredIntoTheOverview` and
/// `theViewFileNamesNoConnectFunctionOfItsOwn` — and each would pass
/// trivially over a wiring that had lost its actions altogether, or over a
/// view file that had stopped existing in the shape this scans. Their
/// partners are `theThreeActionsResolveToTheWindowsExistingEntries` and
/// `theViewFiresTheConnectEffectItIsHanded`, which fail first, and loudly,
/// when that happens.
///
/// ## What it reads
///
/// SOURCE TEXT and catalogue files. Nothing here renders a view: that the
/// head is actually pinned on screen, that `ViewThatFits` picks the narrow
/// row at the width the maintainer resizes to, or that a fact's label reads
/// well in Polish are all outside what a scan can say.
@Suite("Session overview wiring")
struct SessionOverviewWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SessionOverviewWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let viewPath = "Sources/MacSCPAppKit/SessionOverviewView.swift"
    private static let detailPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"
    /// Core's model — read for the label ids it emits, never edited by this
    /// task's App-side work.
    private static let modelPath = "Sources/macSCPCore/Presentation/SessionOverviewModel.swift"

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    // MARK: - Anchors

    /// The view type, named once. Everything else about the view is derived
    /// from the file this points at.
    private static let viewTypeName = "SessionOverviewView"

    /// No trailing `{` — `declarationBodyRange` opens its span at the first
    /// `{` AFTER the declaration text, so a declaration carrying its own
    /// brace makes the scan balance the first child instead of the body
    /// (`ConnectionFormScrollGuardTests.bodyDeclaration` documents the same
    /// trap, which it paid for).
    private static let bodyDeclaration = "var body: some View"
    private static let scrollAnchor = "ScrollView("

    /// The three entries the overview's actions must resolve to — the
    /// window's existing ones, spelled as they are called.
    ///
    /// `showDiagnostics(for: .stored` rather than `showDiagnostics(`: the
    /// window has a second target case (`.tab`), and the overview is a
    /// STORED session's surface. The failed history row's "Open diagnosis"
    /// reaches the same entry, which is why this is a substring check over
    /// the whole wiring rather than a count.
    private static let expectedEntries = [
        "connectFromSidebar(", "editStored(", "showDiagnostics(for: .stored",
    ]

    /// Every other way this window reaches the user's host, or reaches it by
    /// proxy. Read together with `SessionRowActivation.swift`'s own doc
    /// comments, which state the rule these names belong to: an input that
    /// STARTS A SESSION on the user's host is an effect value, not a plain
    /// callback. Counted while writing this: SIX names.
    ///
    /// `connectFromSidebar` is deliberately absent — it is the one the
    /// overview is allowed to reach, and `expectedEntries` above requires it.
    private static let otherHostReachingEntries = [
        "openTerminalFromSidebar", "openExternalTerminalFromSidebar", "sidebarStart",
        "retryConnect", "reconnect(", "connect(in:",
    ]

    // MARK: - Source access

    private static func url(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    private static func raw(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    /// The two views one file is read in: comments AND literals blanked for
    /// structural claims, comments only where the claim is about a
    /// catalogue key. Both preserve length, so a span found in one slices
    /// out of the other (`SwiftSource`'s own doc comment).
    private static func views(of source: String) throws -> (code: String, withLiterals: String) {
        (try SwiftSource.blankingCommentsAndStrings(source), try SwiftSource.blankingComments(source))
    }

    private static func viewFileViews() throws -> (code: String, withLiterals: String) {
        try views(of: try raw(viewPath))
    }

    /// `body`'s own brace-balanced span in the overview's file, in both
    /// views.
    private static func bodySpan() throws -> (code: String, withLiterals: String) {
        let file = try viewFileViews()
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: bodyDeclaration, in: file.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: file.code),
                TransferQueueBarCancelGuardTests.slice(range, of: file.withLiterals))
    }

    /// The `ScrollView(`'s own trailing-closure span, sliced out of an
    /// already-restricted `body` span.
    private static func scrollSpan(
        of body: (code: String, withLiterals: String)
    ) throws -> (code: String, withLiterals: String) {
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: scrollAnchor, in: body.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: body.code),
                TransferQueueBarCancelGuardTests.slice(range, of: body.withLiterals))
    }

    /// The argument list the detail pane hands `SessionOverviewView(` —
    /// where the three actions resolve.
    private static func wiring() throws -> String {
        try DiagnosticsDoorsGuardTests.argumentSpan(
            after: "\(viewTypeName)(",
            in: try SwiftSource.blankingCommentsAndStrings(try raw(detailPath)),
            occurrence: 1)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchFrom = text.startIndex
        while let hit = text.range(of: needle, range: searchFrom..<text.endIndex) {
            count += 1
            searchFrom = hit.upperBound
        }
        return count
    }

    // MARK: - The branch and the three actions

    @Test func theDetailPaneShowsTheOverview() throws {
        let detail = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.detailPath))
        #expect(detail.contains("\(Self.viewTypeName)("), """
            \(Self.detailPath) no longer constructs \(Self.viewTypeName)( — a single click on \
            a stored session shows the empty connection form again, which is the state this \
            whole design replaced.
            """)
    }

    /// The positive partner of `noOtherHostReachingEntryIsWiredIntoTheOverview`.
    @Test func theThreeActionsResolveToTheWindowsExistingEntries() throws {
        let wiring = try Self.wiring()
        for entry in Self.expectedEntries {
            #expect(wiring.contains(entry), """
                the overview's wiring in \(Self.detailPath) no longer names \(entry). The \
                overview's three actions are the window's EXISTING entries handed over as \
                values — a fourth way to connect, edit or diagnose is a second place a \
                security rule can be forgotten. Wiring read: \(wiring)
                """)
        }
    }

    @Test func noOtherHostReachingEntryIsWiredIntoTheOverview() throws {
        let wiring = try Self.wiring()
        for entry in Self.otherHostReachingEntries {
            #expect(!wiring.contains(entry), """
                the overview's wiring in \(Self.detailPath) names \(entry) — a route onto the \
                user's host that this read-only surface does not offer. The overview's only \
                connect is `connectFromSidebar`, handed over as a \
                `SessionRowConnectEffect`.
                """)
        }
    }

    /// The positive partner of `theViewFileNamesNoConnectFunctionOfItsOwn`:
    /// the view really does hold and fire a connect effect, so "the view
    /// names no connect function" reports "it fires the value it was
    /// handed" rather than "it connects not at all".
    @Test func theViewFiresTheConnectEffectItIsHanded() throws {
        let file = try Self.viewFileViews()
        #expect(file.code.contains("SessionRowConnectEffect"), """
            \(Self.viewPath) no longer holds a SessionRowConnectEffect — its Connect action \
            has become an ordinary closure, which is exactly the shape a one-token edit turns \
            into a stray dial (see SessionRowConnectEffect's own doc comment).
            """)
        #expect(file.code.contains("performSessionRowInput("), """
            \(Self.viewPath) no longer calls performSessionRowInput( — the only sanctioned \
            way to fire a connect effect. Either the Connect action is dead, or it found \
            another way to run, which is the capability this discipline exists to withhold.
            """)
    }

    @Test func theViewFileNamesNoConnectFunctionOfItsOwn() throws {
        let file = try Self.viewFileViews()
        for entry in Self.otherHostReachingEntries + ["connectFromSidebar"] {
            #expect(!file.code.contains(entry), """
                \(Self.viewPath) names \(entry). The view holds effect VALUES and knows the \
                name of nothing that dials: a view that can call a connect entry by name can \
                connect without naming an input.
                """)
        }
    }

    // MARK: - The responsive split

    @Test func theBodyScrolls() throws {
        let body = try Self.bodySpan()
        #expect(body.code.contains(Self.scrollAnchor), """
            \(Self.viewPath)'s body no longer contains a ScrollView( — a session with ten \
            recent connections and a dozen snippets runs off the bottom of a short window \
            with no way to reach it.
            """)
    }

    @Test func theHeadSitsOutsideTheScrollView() throws {
        let body = try Self.bodySpan()
        let scroll = try Self.scrollSpan(of: body)
        #expect(body.code.contains("head"), """
            \(Self.viewPath)'s body no longer names `head` — the pinned region (name, kind, \
            endpoint, the three actions) is gone from body.
            """)
        #expect(!scroll.code.contains("head"), """
            `head` is inside the ScrollView's own body: the name of the session and its three \
            actions would scroll away instead of staying reachable at any window height.
            """)
    }

    @Test func theScrollingRegionCarriesTheThreeSections() throws {
        let scroll = try Self.scrollSpan(of: try Self.bodySpan())
        for section in ["factsSection", "historySection", "snippetsSection"] {
            #expect(scroll.code.contains(section), """
                \(section) is not inside the ScrollView's own body — either it moved out of \
                the scrolling region (and would then be clipped rather than scrolled) or it \
                was renamed without this guard following it.
                """)
        }
    }

    /// Two narrow fallbacks are required by the plan — the actions row (one
    /// row, else two) and the facts grid (two columns, else one). The
    /// recent-connections table has a third, which is why this is a
    /// minimum rather than an equality: a fourth fallback is an
    /// improvement, and a guard that forbade it would be a guard against
    /// the feature.
    @Test func theNarrowFallbacksAreThere() throws {
        let file = try Self.viewFileViews()
        let count = Self.occurrences(of: "ViewThatFits(", in: file.code)
        #expect(count >= 2, """
            \(Self.viewPath) contains \(count) ViewThatFits( — the plan requires at least \
            two: the actions row falls back from one row to two, and the facts grid from two \
            columns to one. Without them a narrow detail pane truncates a button title letter \
            by letter, which is what the maintainer's screenshot of the diagnostics footer \
            showed before that panel got the same treatment.
            """)
        #expect(file.code.contains("Grid("), """
            \(Self.viewPath) no longer contains a Grid( — the facts are meant to be a \
            two-column grid whose labels and values line up, not a stack of ad-hoc rows.
            """)
    }

    @Test func theSnippetsUseAnAdaptiveGrid() throws {
        let file = try Self.viewFileViews()
        #expect(file.code.contains("LazyVGrid("), """
            \(Self.viewPath) no longer contains a LazyVGrid( — the snippets are meant to \
            reflow into as many columns as the pane can hold.
            """)
        #expect(file.code.contains("GridItem(.adaptive(minimum: 260))"), """
            the snippets' LazyVGrid no longer uses GridItem(.adaptive(minimum: 260)) — a \
            fixed column count is the shape that overflows a narrow pane instead of reflowing \
            in it.
            """)
    }

    /// The overview's "Open diagnosis" row only ever appears for a failed
    /// connect, and a failed connect only reaches the log because something
    /// writes it. Task 1 added the kind with no producer; this is the check
    /// that one exists, and that there is exactly ONE — a second appender
    /// would be a second chance to store an error's own text where the fixed
    /// sentence belongs.
    @Test func theFailedConnectRowHasExactlyOneProducer() throws {
        // The whole app target, not just the file the call happens to be in
        // today: "exactly one producer" is a claim about the program, and a
        // scan of one file could only ever have said "exactly one here".
        var sites: [String] = []
        for file in try DiagnosticsDoorsGuardTests.appTargetFiles() {
            let count = Self.occurrences(
                of: "recordConnectFailed(",
                in: try SwiftSource.blankingCommentsAndStrings(try Self.raw(file)))
            sites.append(contentsOf: Array(repeating: file, count: count))
        }
        #expect(sites.count == 1, """
            the app target calls recordConnectFailed( \(sites.count) times \(sites), expected \
            exactly one. Zero means AuditEvent.Kind.connectFailed is a kind nothing writes, and \
            the overview's recent-connections list can never show a failure; more than one \
            means two paths compose that row, and only one of them gets read when the sentence \
            it stores has to change.
            """)
    }

    // MARK: - The catalogue

    /// The label ids Core's model emits, read out of its own source.
    ///
    /// Derived from `label("…")` — the ONE helper `SessionOverviewModel`
    /// composes every `labelKey` through — rather than from a list typed
    /// here. A list would be a second copy of a vocabulary that lives in
    /// another target, and it is the copy that stops growing.
    static func factLabelIDs() throws -> Set<String> {
        let source = try SwiftSource.blankingComments(try raw(modelPath))
        return Set(DiagnosticsDoorsGuardTests.matches(of: #"label\("([\w.]+)"\)"#, in: source))
    }

    private static func catalogKeys(_ locale: String) throws -> Set<String> {
        let data = try Data(contentsOf: url(catalogPath(locale)))
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

    @Test func everyFactLabelTheModelEmitsHasAnEnglishEntry() throws {
        let ids = try Self.factLabelIDs()
        #expect(ids.count == 15, """
            SessionOverviewModel emits \(ids.count) distinct fact label ids, not the fifteen \
            counted when this check was written: \(ids.sorted()). Recount, and give any new \
            one a label in all four catalogues before changing this number.
            """)
        // The Bool is computed BEFORE the expectation and the whole
        // catalogue never reaches one: `#expect` reports the SOURCE TEXT and
        // the values of what it checks, so `english.contains(…)` would print
        // every key in `en.lproj` on each of fifteen failures. The same rule
        // CLAUDE.md states for a value a test must not leak applies to a
        // value nobody can read.
        let english = try Self.catalogKeys("en")
        let missing = ids.sorted().filter { !english.contains("overview.fact.\($0)") }
        #expect(missing.isEmpty, """
            these fact labels are missing from \(Self.catalogPath("en")): \
            \(missing.map { "overview.fact.\($0)" }). Core emits the keys and resolves none \
            of them — an unlisted key renders as its own key text in the facts grid.
            """)
    }

    @Test func theOverviewKeysAgreeAcrossAllFourCatalogues() throws {
        let english = try Self.catalogKeys("en").filter { $0.hasPrefix("overview.") }
        #expect(!english.isEmpty, """
            \(Self.catalogPath("en")) declares no overview. keys at all — the set-equality \
            check below would then be satisfied by four empty sets.
            """)
        for locale in Self.catalogLocales where locale != "en" {
            let keys = try Self.catalogKeys(locale).filter { $0.hasPrefix("overview.") }
            #expect(keys == english, """
                \(Self.catalogPath(locale))'s overview. keys differ from en.lproj's.
                missing here: \(english.subtracting(keys).sorted())
                extra here: \(keys.subtracting(english).sorted())
                """)
        }
    }

    /// The catalogue checks above read FILES. This one reads what the app
    /// reads: a key appended to `Localizable.strings` is only useful if the
    /// resource bundle `L10n` resolves actually carries it, and a file check
    /// cannot tell a listed key from a shipped one.
    ///
    /// One key stands for the block — they were appended together, in one
    /// pass, to one file per locale — and the fallback is deliberately
    /// absurd, the way `L10nTests` writes its own: no language can return
    /// it, so the assertion holds in all four.
    @Test func theNewLabelsAreInTheBundleTheAppActuallyReads() {
        #expect(L10n.string("overview.fact.username", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(L10n.string("overview.section.history", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The exact violation `theHeadSitsOutsideTheScrollView` exists to
    /// catch: the head moved inside the scroll region.
    @Test func scannerCatchesAHeadMovedInsideTheScrollView() throws {
        let source = """
            var body: some View {
                VStack {
                    ScrollView(.vertical) {
                        VStack {
                            head
                            factsSection
                        }
                    }
                }
            }
            """
        let file = try Self.views(of: source)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.bodyDeclaration, in: file.code)
        let body = (code: TransferQueueBarCancelGuardTests.slice(range, of: file.code),
                    withLiterals: TransferQueueBarCancelGuardTests.slice(range, of: file.withLiterals))
        let scroll = try Self.scrollSpan(of: body)
        #expect(scroll.code.contains("head"), """
            this synthetic source puts `head` inside the ScrollView on purpose — if the scan \
            does not see it there, the span it reads is not the one the real check reads.
            """)
    }

    /// A comment naming a connect entry must not be mistaken for a call to
    /// it (CLAUDE.md, "Source-scanning guards read comments too"): the
    /// strict view blanks comments, so a doc comment explaining that the
    /// overview does NOT call `openTerminalFromSidebar` cannot fail the
    /// negative check that says it does not.
    @Test func aCommentNamingAConnectEntryDoesNotFailTheNegativeCheck() throws {
        let source = """
            // Deliberately no openTerminalFromSidebar here: the overview is read-only.
            struct S { let onConnect: SessionRowConnectEffect<StoredSession> }
            """
        let file = try Self.views(of: source)
        #expect(!file.code.contains("openTerminalFromSidebar"), """
            the strict view must blank the comment naming openTerminalFromSidebar — a scan \
            reading raw source would report the prose as a wiring.
            """)
        #expect(file.code.contains("SessionRowConnectEffect"), """
            blanking comments must leave the code alone; if this fails, the stripper is \
            eating more than comments and every check above is reading a hollowed-out file.
            """)
    }

    @Test func scannerFailsClosedWhenTheScrollViewIsGone() throws {
        let source = """
            var body: some View {
                VStack {
                    head
                    factsSection
                }
            }
            """
        let file = try Self.views(of: source)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.bodyDeclaration, in: file.code)
        let body = (code: TransferQueueBarCancelGuardTests.slice(range, of: file.code),
                    withLiterals: TransferQueueBarCancelGuardTests.slice(range, of: file.withLiterals))
        #expect(throws: (any Error).self) {
            try Self.scrollSpan(of: body)
        }
    }
}
