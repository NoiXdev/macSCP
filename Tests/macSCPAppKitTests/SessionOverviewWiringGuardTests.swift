import Foundation
import Testing
import macSCPCore

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
/// * **Nothing a secret could arrive in is spelled in the view.** The
///   design's "Never in the overview" paragraph: no secret value, no
///   passphrase, no private key contents, no endpoint userinfo. The
///   enforceable half of that at this layer is that the view names none of
///   the backends' SECRET field ids and renders nothing through
///   `String(describing:)`, which prints an arbitrary value's stored
///   properties. The ids are derived from `BackendDescriptor`, and the
///   patterns are proved to match at all against a fixture that carries
///   every one of them.
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
    /// The window itself — read for the sequence a snippet card's Run starts
    /// (Task 3), never for anything the view draws.
    private static let contentViewPath = "Sources/MacSCPAppKit/ContentView.swift"
    private static let lifecyclePath = "Sources/MacSCPAppKit/ContentView+Lifecycle.swift"
    /// Core's model — read for the label ids it emits, never edited by this
    /// task's App-side work.
    private static let modelPath = "Sources/macSCPCore/Presentation/SessionOverviewModel.swift"
    /// The compiling counter-example the two secret checks are measured
    /// against — see its own doc comment for why it is a file rather than a
    /// synthetic string, and why it sits outside the scanned tree.
    private static let leakFixturePath = "Tests/MacSCPTestSupport/SessionOverviewLeakFixture.swift"

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
    /// `runSnippetAfterConnecting(` joined the three on 2026-09-04 (Task 3),
    /// and it is the one entry here that did not already exist: a snippet
    /// card's Run. It is listed as an EXPECTED entry rather than added to
    /// `otherHostReachingEntries` below because it is not a fourth way to
    /// connect — its own dial is `connectFromSidebar`, which
    /// `theOverviewsSnippetRunDialsThroughTheSidebarConnectAndNothingElse`
    /// reads out of its body rather than taking on trust.
    private static let expectedEntries = [
        "connectFromSidebar(", "editStored(", "showDiagnostics(for: .stored",
        "runSnippetAfterConnecting(",
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

    /// One construction, and exactly one — which is what makes
    /// `wiring()`'s `occurrence: 1` name the branch this suite is about
    /// rather than whichever of several came first in the file. Fix round 1
    /// added the equality; before it, a second `SessionOverviewView(` in
    /// another branch would have been read by nothing and every action check
    /// below would have gone on describing the first one.
    @Test func theDetailPaneShowsTheOverviewExactlyOnce() throws {
        let detail = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.detailPath))
        let count = Self.occurrences(of: "\(Self.viewTypeName)(", in: detail)
        #expect(count == 1, """
            \(Self.detailPath) constructs \(Self.viewTypeName)( \(count) times, expected \
            exactly one. Zero means a single click on a stored session shows the empty \
            connection form again, which is the state this whole design replaced; more than \
            one means the checks that read the FIRST construction's arguments are silent about \
            the others.
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

    /// `runSnippetAfterConnecting` is in this list for the same reason
    /// `connectFromSidebar` is: it dials, and the view must hold it as a
    /// value it was handed (`onRunSnippet`) rather than as a name it can
    /// call. Its positive partner is `theSnippetCardsRunIsWiredToTheWindow`
    /// below, which requires the callback to be there and fired.
    @Test func theViewFileNamesNoConnectFunctionOfItsOwn() throws {
        let file = try Self.viewFileViews()
        for entry in Self.otherHostReachingEntries
            + ["connectFromSidebar", "runSnippetAfterConnecting"] {
            #expect(!file.code.contains(entry), """
                \(Self.viewPath) names \(entry). The view holds effect VALUES and knows the \
                name of nothing that dials: a view that can call a connect entry by name can \
                connect without naming an input.
                """)
        }
    }

    // MARK: - The snippet card's Run (Task 3)

    /// The Run button really is wired, and really is no longer dead.
    ///
    /// The negative half — no `.disabled(` left in the card — is scoped to
    /// `snippetCard`'s own span and paired with two positives read out of
    /// that same span, so a card that lost its button altogether fails here
    /// rather than reporting that nothing is disabled.
    @Test func theSnippetCardsRunIsWiredToTheWindow() throws {
        let file = try Self.viewFileViews()
        #expect(file.code.contains("let onRunSnippet: (Snippet) -> Void"), """
            \(Self.viewPath) no longer takes an onRunSnippet callback — the snippet card's Run \
            has nothing to hand a snippet to, so pressing it can only be a no-op or a second \
            route onto the host written inside this view.
            """)
        let card = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func snippetCard(_ snippet: Snippet) -> some View", in: file.code)
        #expect(card.contains("onRunSnippet(snippet)"), """
            snippetCard no longer fires onRunSnippet(snippet) — the card draws a Run control \
            that reaches nothing.
            """)
        #expect(!card.contains(".disabled("), """
            snippetCard still disables a control. Task 2 shipped Run dead on purpose to settle \
            the layout; Task 3 is what gives it its action, and a Run that stays greyed out is \
            that task not landing.
            """)
    }

    /// Run is not a fourth way onto the host: read out of
    /// `runSnippetAfterConnecting`'s own body, not taken from the sentence
    /// that says so.
    ///
    /// The positive check comes first for the reason this file's header
    /// states — the loop below is a filter expected to come back empty, and
    /// on a body that no longer dials at all it would report satisfaction
    /// over nothing.
    @Test func theOverviewsSnippetRunDialsThroughTheSidebarConnectAndNothingElse() throws {
        let source = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.contentViewPath))
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func runSnippetAfterConnecting(_ snippet: Snippet, on stored: StoredSession)",
            in: source)
        #expect(body.contains("connectFromSidebar("), """
            runSnippetAfterConnecting no longer calls connectFromSidebar( — its dial is then \
            something else, and every rule that path applies (the already-open query, the tab \
            rule, TOFU, the keychain reads, the plaintext confirmation, the attempt token) is \
            a rule this one now has to repeat.
            """)
        for entry in Self.otherHostReachingEntries {
            #expect(!body.contains(entry), """
                runSnippetAfterConnecting names \(entry) — a second route onto the user's host \
                inside the one function that was allowed exactly one.
                """)
        }
    }

    /// The hand-off has a watcher, and the watcher calls the decision.
    /// Neither half is observable at runtime here: nothing in this project
    /// renders a SwiftUI view, so that `PendingSnippetRunner` is mounted at
    /// all is a source claim, while what it decides is
    /// `SnippetAfterConnectSequenceTests`' job on the real method.
    @Test func thePendingRunIsDeliveredByAViewThatWatchesTheTab() throws {
        let detail = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.detailPath))
        #expect(detail.contains("PendingSnippetRunner("), """
            \(Self.detailPath) no longer mounts PendingSnippetRunner( — a snippet armed by Run \
            is then never delivered, and the button connects and goes quiet.
            """)
        #expect(detail.contains("deliverPendingSnippetRun("), """
            nothing in \(Self.detailPath) calls deliverPendingSnippetRun( — the runner is \
            mounted but watches on behalf of nobody.
            """)
    }

    /// Task 3 MOVED the key-window guard off `triggerSnippet(_:execute:)`
    /// and onto the Terminal menu's own bridge, which is the one caller it
    /// was ever about. Both halves are pinned, because either one alone is
    /// the bug: left on `triggerSnippet`, the overview's Run cannot send at
    /// all from anywhere the window is not key (and no test can reach the
    /// send path, since `window` is `@State`); missing from the bridge, the
    /// Terminal menu's snippet entries fire against a window that is not in
    /// front.
    @Test func theSnippetMenuBridgeIsWhatChecksForTheKeyWindow() throws {
        let lifecycle = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.lifecyclePath))
        let bridge = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "tabCommands.runSnippet =", in: lifecycle)
        #expect(bridge.contains("triggerSnippet("), """
            the tabCommands.runSnippet bridge no longer calls triggerSnippet( — the Terminal \
            menu's snippet entries reach nothing, and the check below would then be about a \
            closure that does not act.
            """)
        #expect(bridge.contains("isKeyWindow"), """
            the tabCommands.runSnippet bridge no longer checks isKeyWindow. SwiftUI attaches \
            one .commands menu app-wide and every window assigns this same closure, so without \
            it a snippet picked from the Terminal menu runs in whichever window last wired \
            itself rather than the one in front.
            """)
        let contentView = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.contentViewPath))
        let trigger = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func triggerSnippet(_ snippet: Snippet, execute: Bool)", in: contentView)
        #expect(trigger.contains("SnippetVariableSubstitution"), """
            triggerSnippet's body no longer names SnippetVariableSubstitution — the span this \
            check reads is not the function it means (SnippetVariablePromptWiringGuardTests \
            owns what that call has to do).
            """)
        #expect(!trigger.contains("isKeyWindow"), """
            triggerSnippet checks isKeyWindow again. Every caller but the menu bridge is a \
            control inside one window, and `window` is @State — a ContentView built outside a \
            SwiftUI hierarchy reads it as nil, which makes the whole send path unreachable \
            from SnippetAfterConnectSequenceTests.
            """)
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

    /// The two lines that keep one selection's facts from being shown under
    /// another's head, pinned as SOURCE because neither is reachable any
    /// other way from here.
    ///
    /// Why a scan and not a behavioural test: the reset is a write to a
    /// SwiftUI `@State` from inside a `.task(id:)` body, and the
    /// cancellation check reads `Task.isCancelled` inside that same body.
    /// Nothing in this project renders a view (`ViewTestabilitySpike` can
    /// instantiate one offscreen; it cannot drive a `.task`), so there is no
    /// way to change the id, cancel the first body and observe which result
    /// won. `load(session:groupName:loginSetName:)` itself has nothing to
    /// test here — it is a pure read with no cancellation semantics of its
    /// own, which is exactly why the check has to sit at the call.
    ///
    /// So this asserts the ORDER of three anchors inside that one body,
    /// which is the whole of the property: reset, then await, then the
    /// cancellation check, then the assignment. Positive throughout — every
    /// anchor must be found, and a body missing any of them fails on that
    /// anchor rather than on the ordering.
    @Test func theLoadResetsFirstAndRefusesToLandAfterCancellation() throws {
        let body = try Self.bodySpan()
        let task = TransferQueueBarCancelGuardTests.slice(
            try TransferQueueBarCancelGuardTests.declarationBodyRange(
                of: ".task(id: session)", in: body.code),
            of: body.code)
        let anchors = ["model = nil", "await Self.load(", "guard !Task.isCancelled", "model = loaded"]
        var positions: [Int] = []
        for anchor in anchors {
            guard let range = task.range(of: anchor) else {
                Issue.record("""
                    the .task(id: session) body does not contain `\(anchor)`. \
                    Read: \(task)
                    """)
                return
            }
            positions.append(task.distance(from: task.startIndex, to: range.lowerBound))
        }
        #expect(positions == positions.sorted(), """
            the .task(id: session) body has these four in the wrong order \(anchors) at \
            \(positions). The reset must precede the await, or session B's head renders over \
            session A's facts; the cancellation check must sit between the await and the \
            assignment, or a slow keychain query started for the PREVIOUS selection can land \
            on top of the current one's model.
            """)
    }

    /// The scanner reacts: the shape this suite buys must not also be bought
    /// by the shape it forbids. Both violations the ruling names — no reset,
    /// and a result assigned without the check — are rejected by the same
    /// scan the real file passes.
    @Test func theOrderingScanRejectsAnUnguardedLoad() throws {
        let source = """
            var body: some View {
                VStack {
                    head
                }
                .task(id: session) {
                    let loaded = await Self.load(session: session)
                    model = loaded
                }
            }
            """
        let file = try Self.views(of: source)
        let body = TransferQueueBarCancelGuardTests.slice(
            try TransferQueueBarCancelGuardTests.declarationBodyRange(
                of: Self.bodyDeclaration, in: file.code),
            of: file.code)
        let task = TransferQueueBarCancelGuardTests.slice(
            try TransferQueueBarCancelGuardTests.declarationBodyRange(
                of: ".task(id: session)", in: body),
            of: body)
        #expect(!task.contains("model = nil"), """
            this synthetic body omits the reset on purpose — if the scan finds one, it is not \
            reading the task body the real check reads.
            """)
        #expect(!task.contains("guard !Task.isCancelled"), """
            this synthetic body omits the cancellation check on purpose — same reasoning.
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
        // THREE, counted in the pass that writes this line: the actions row
        // (one row, else two), the facts grid (two columns, else one) and
        // the recent-connections table (with the transfers column, else
        // without). An equality rather than a minimum, and fix round 1 is
        // why: `>= 2` let the history table's narrow form be deleted with
        // this suite green, which is the shape CLAUDE.md warns about — a
        // bound that a violation can satisfy is not a guard on the thing it
        // names. A fourth fallback is welcome and has to say so here.
        #expect(count == 3, """
            \(Self.viewPath) contains \(count) ViewThatFits(, not the three this design has: \
            the actions row falls back from one row to two, the facts grid from two columns to \
            one, and the recent-connections table drops its transfers column. Without them a \
            narrow detail pane truncates a button title letter by letter, which is what the \
            maintainer's screenshot of the diagnostics footer showed before that panel got the \
            same treatment. A fourth fallback is a change to this number, made on purpose.
            """)
        // The count alone cannot say WHICH three, and the history table's is
        // the one that reads as an argument rather than as a second view:
        // both of its forms are the same function called twice, so deleting
        // the narrow call leaves the `ViewThatFits` standing with one child.
        for form in ["showsTransfers: true", "showsTransfers: false"] {
            #expect(file.code.contains(form), """
                \(Self.viewPath) no longer builds the recent-connections table with \(form) — \
                the table has lost one of its two forms, and a ViewThatFits with a single \
                child is a fallback that cannot fall back.
                """)
        }
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

    // MARK: - Never in the overview (design's own paragraph)

    /// Every SECRET field id the three backends declare, derived from the
    /// descriptors rather than listed here.
    ///
    /// Both schemas of every kind, because a secret can be declared in
    /// either: `credentialSchema` holds the ordinary password/passphrase and
    /// `connectionSchema` is where a backend could put one beside its
    /// address fields. `ConnectionField.isSecret` is the same predicate
    /// `BackendDescriptorTests.everySecretFieldDeclaresItsRole` iterates, so
    /// a fourth backend, or a fourth secret on an existing one, enters this
    /// set without an edit here.
    static func secretFieldIDs() -> Set<String> {
        var ids: Set<String> = []
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            for schema in [descriptor.connectionSchema, descriptor.credentialSchema] {
                for field in schema.fields where field.isSecret {
                    ids.insert(field.id)
                }
            }
        }
        return ids
    }

    /// The render that prints an arbitrary value's stored properties. Named
    /// once, used by the negative check and by the fixture check that proves
    /// it matches.
    private static let describingRender = "String(describing:"

    /// The positive companion both negatives below need FIRST: the scan is
    /// reading a file that renders the model at all.
    ///
    /// A view emptied, renamed or replaced by a placeholder carries no
    /// secret id and no describing call either, and both negatives would
    /// report an all-clear over it. What is asserted is the model's own
    /// public stored properties — read out of Core's source, not spelled —
    /// of which the view must name at least three. Three rather than all of
    /// them because the view legitimately reaches some through a local
    /// (`model.facts` is mapped into `lines`) and the point is that it
    /// reaches the model, not which members it happens to touch this month.
    @Test func theSecretScanReadsAFileThatRendersTheModel() throws {
        let modelSource = try SwiftSource.blankingCommentsAndStrings(try Self.raw(Self.modelPath))
        let members = Set(
            DiagnosticsDoorsGuardTests.matches(
                of: #"public let (\w+):"#, in: modelSource))
        #expect(members.count >= 5, """
            \(Self.modelPath) declares \(members.count) public stored properties \
            \(members.sorted()) — the derivation this check rests on is not reading the model.
            """)
        let file = try Self.viewFileViews()
        let named = members.filter { file.code.contains("model.\($0)") || file.code.contains("model?.\($0)") }
        #expect(named.count >= 3, """
            \(Self.viewPath) reads only \(named.count) of SessionOverviewModel's properties \
            \(named.sorted()) — the file the two secret checks below scan is no longer a view \
            that renders a session, so "it contains no secret field id" would be an absence \
            measured over nothing.
            """)
    }

    /// The design's "Never in the overview", as far as a scan can carry it:
    /// the view does not name a single one of the backends' secret fields.
    ///
    /// It cannot name one innocently — the model hands over `Fact` values
    /// whose text is already stripped, and the credential question arrives
    /// as a `Bool?` — so an occurrence means the view went looking for a
    /// secret by name, which is the one move that could put a value on this
    /// surface.
    @Test func theViewNamesNoSecretField() throws {
        let ids = Self.secretFieldIDs()
        let file = try Self.viewFileViews()
        let found = ids.sorted().filter { file.code.contains($0) }
        #expect(found.isEmpty, """
            \(Self.viewPath) names \(found) — a secret field id, in a read-only surface that \
            must never hold a credential. The model answers the only credential question this \
            view asks (`hasStoredSecret`) as a Bool?, which cannot carry a value; reaching for \
            a field by name is how one gets here.
            """)
    }

    /// `String(describing:)` prints an arbitrary value's stored properties,
    /// which for a configuration value is the configuration it was built
    /// from. Same rule the diagnostics module keeps
    /// (`DialSupport.reason(for:)`'s own doc comment says why), applied to
    /// the surface that renders a stored session.
    @Test func theViewRendersNothingThroughDescribing() throws {
        let file = try Self.viewFileViews()
        #expect(!file.code.contains(Self.describingRender), """
            \(Self.viewPath) renders a value through \(Self.describingRender)) — that prints \
            whatever the value's stored properties are, and on this surface the values in \
            reach are stored sessions and their configuration.
            """)
    }

    /// The second positive companion, and the one the two negatives are
    /// actually measured by: run the identical scans over a file that DOES
    /// violate both, and require every pattern to match.
    ///
    /// Without it, a typo in a derived id, a schema that stopped marking a
    /// field secret, or a renamed describing call would leave the negatives
    /// passing over patterns that match nothing anywhere.
    @Test func everySecretPatternMatchesTheFixture() throws {
        let fixture = try SwiftSource.blankingCommentsAndStrings(
            try Self.raw(Self.leakFixturePath))
        let ids = Self.secretFieldIDs()
        #expect(!ids.isEmpty, """
            no backend declares a secret field at all — the derivation feeding \
            theViewNamesNoSecretField found nothing to look for.
            """)
        let missing = ids.sorted().filter { !fixture.contains($0) }
        #expect(missing.isEmpty, """
            \(Self.leakFixturePath) does not carry \(missing). The fixture is what proves the \
            scan can see a secret field id at all, so every id the descriptors declare has to \
            appear in it — add the new one there (as a property, not in a comment or a string, \
            which the scan blanks).
            """)
        #expect(fixture.contains(Self.describingRender), """
            \(Self.leakFixturePath) no longer contains \(Self.describingRender)) — \
            theViewRendersNothingThroughDescribing is then a check nothing has ever been \
            observed to fail.
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
