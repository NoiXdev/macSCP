import Foundation
import Testing

/// Guards ONE property of the tab strip's context menu in
/// `Sources/MacSCPAppKit/TabStripView.swift`: **the view does not decide
/// which entries appear.** The list it draws is whatever it was handed —
/// no more, no fewer, in that order — and every rule about when an entry
/// is offered lives in Core, in
/// `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:
/// isConnected:filesToggle:terminalToggle:)`,
/// where `TabContextMenuTests` can reach it.
///
/// The view no longer asks that function itself (drag task, fix round 3).
/// Two of its facts are positional, and a position that reaches a
/// view is a position that can be shifted inside it — so the question is
/// asked where the model is, and the strip is handed the answer.
///
/// That moved two violation sites rather than removing them, which round 3
/// recorded as a removal and round 4 put right: **V7 travelled with the
/// call** into `ContentView.tabMenuEntries(for:)`, and **V2 gained a second
/// home** at the closure that hands the answer over. Both are guarded
/// where they now live, so this suite reads three files — the strip, the
/// place the decision is asked, and the place its answer is handed on.
///
/// Why a guard at all: `TabContextMenuTests` proves what the decision
/// FUNCTION answers, and it stays green whether or not anything calls it.
/// This project has no SwiftUI rendering harness (the same boundary
/// `PaneRenderConditionGuardTests` and `ConnectTimeoutAppWiringGuardTests`
/// document), so a menu that quietly re-derives visibility in the view —
/// the exact shape the design rejects — can only be caught by reading the
/// source.
///
/// **Where the property could be violated FROM.** This suite's checks were
/// derived from this list, not from the lines that happened to get written:
///
/// - **V1** A condition inside the menu closure wrapping an item (`if`,
///   `guard`, `else`, a ternary), so an entry Core returned is not drawn.
/// - **V2** A transformation of the returned list before it is iterated
///   (`filter`, `prefix`, `dropFirst`, `contains`), so the value is
///   consulted and then overruled. Writable in two places now: inside the
///   menu closure, and in the closure that hands the answer to the strip.
/// - **V3** `.disabled(…)`/`.hidden(…)` on a drawn item — a greyed-out
///   entry is a visibility decision under another name, and the design
///   rejects greyed-out entries outright ("no greyed entry, no error — the
///   entry does not appear there").
/// - **V4** An item drawn beside the loop rather than by it, so the menu
///   carries something the value never named.
/// - **V5** A SECOND menu attachment in the file, whose items nothing
///   decided.
/// - **V6** The iteration source swapped out — the loop walks a
///   hand-written array while a `TabContextMenu.entries` call sits nearby
///   looking like it is still in charge.
/// - **V7** An extra rule folded into the ARGUMENTS of the decision —
///   `isConnected: tab.isConnected && …` — or a fact asserted instead of
///   read. Not possible in the view any more, which supplies no facts; it
///   travelled with the call into `ContentView.tabMenuEntries(for:)` and is
///   guarded there, on that function's whole body, because a positional
///   fact can be rewritten in the `guard` that produces it as easily as in
///   the call that uses it.
///
/// **Deliberately NOT guarded here**, so a green run is not read as more
/// than it is:
///
/// - **A handler that does nothing.** That makes an entry inert, not
///   invisible — a different property, and one this scanner cannot judge.
///   The arm this actually costs something at is `.pane` in
///   `ContentView+Lifecycle.swift`'s `handleTabMenuEntry`: replacing
///   `togglePane(toggle, in: tab)` with `break` compiles, leaves this suite
///   and every other one green, and gives the user two menu entries that
///   silently do nothing. (An earlier version of this bullet illustrated
///   the hole with `case .saveAsSession: break`, which has read
///   `saveAsSession(from: tab)` since the commit that wrote the sentence.
///   Naming an arm that is fine, while the one that can go inert is named
///   nowhere, is worse than saying nothing.)
///
///   The edge of the hole was measured rather than guessed, and it is
///   narrower than "an inert handler is uncatchable": deleting `togglePane`
///   as well DOES go red, because `PaneVisibilityWiringGuardTests` counts
///   the toggle sites in that file and finds three where it expects five.
///   What nothing sees is the function surviving while its one caller stops
///   calling it — Swift emits no warning for an uncalled method. That, and
///   only that, is unguarded.
/// - The title mapping answering an empty string. The item still exists and
///   is still clickable; and `TabMenuEntryTitle.title(for:)` is a total
///   `switch` over `TabMenuEntry` with no `default`, so the compiler already
///   refuses to let a case be dropped.
///
/// **What this guard does NOT catch.** Corrected in fix round 1 after a
/// reviewer got four mutations past it; the technique was kept and the
/// claim narrowed, because chasing each hole with another anchor buys a
/// longer blocklist and no property.
///
/// The list of violation sites says where the property can be violated
/// FROM. What the checks actually recognize is narrower, in the two
/// specific ways set out here, and a green run means only this much:
///
/// - **V2 and V3 are a name blocklist, not a rule.** `forbiddenTokens`
///   names the spellings that were in front of us. A narrowing or
///   suppressing call by any other name passes: `.map { _ in .close }`
///   rewrites every entry into the same one, `.allowsHitTesting(false)`
///   makes an item unclickable, `.opacity(0)` makes it invisible. None is
///   on the list, and none can be, without the list becoming an
///   ever-growing catalogue of SwiftUI's surface.
/// - **It reads three files**, and reads them as text: the strip,
///   `ContentView+Lifecycle.swift` where the decision is asked, and
///   `ContentView+Detail.swift` where its answer is handed over. (Round 3
///   claimed one file here and had already written a check against the
///   second; the undercount is what argued the V7 checks away, so it is
///   corrected rather than trimmed.) What it does not read is where the
///   facts come FROM — `SessionTab.isConnected`, `activeStoredSessionID`,
///   the capabilities `BackendDescriptor` answers. A fact that lies at its
///   source is handed on faithfully by everything scanned here and changes
///   which entries appear with nothing in this suite to notice.
///
/// So: this catches a condition, a filter, a `.disabled`, an extra item, a
/// second menu, a swapped iteration source, an answer narrowed on its way
/// to the strip, and a rule folded into the facts the decision is asked
/// with — all under the names they are usually written with. It does not
/// prove the menu shows what Core decided — only that the view draws what
/// it was handed, that what it was handed is what Core answered, and that
/// Core was asked with the facts as they stand.
///
/// Same boundary as the other wiring guards: a source-text scan aimed at
/// the accidental regression (a "simplification" that reintroduces a
/// condition, a reformat) rather than a hostile rewrite. Renaming
/// `TabContextMenu.entries` wholesale, or moving the menu into a helper
/// view in another file, would leave the anchor missing — which fails
/// closed here, reported as "re-anchor this guard", rather than passing
/// quietly.
///
/// Fail-closed throughout: an unreadable file, a missing anchor, unbalanced
/// braces, and an unterminated string or comment all count as failures.
/// Self-tested against synthetic source — a probe for every violation site
/// named here, two each for V2 and V4, and three for V7, the site that can
/// be written in the most shapes — so the scanner cannot pass merely
/// because the real file moved or was reformatted past recognition.
@Suite("Tab context menu wiring guard")
struct TabContextMenuWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TabContextMenuWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `ConnectTimeoutAppWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabStripView.swift")

    /// Where the strip's menu entries are answered now.
    private static let handlerFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")

    /// Where the answer is handed to the strip, and where the drag's own
    /// route out is wired to the model.
    private static let wiringFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private static let anchor = ".contextMenu {"
    private static let decisionCall = "TabContextMenu.entries("

    /// The closure that hands the strip its answer.
    private static let handOverAnchor = "menuEntries: {"

    /// The one sanctioned shape of that hand-over: the question is asked
    /// and the answer travels on untouched.
    private static let sanctionedHandOver = "tabMenuEntries(for:$0)"

    /// Where the decision is asked, with the facts it is asked with.
    private static let decisionAnchor =
        "func tabMenuEntries(for tab: SessionTab) -> [TabMenuEntry] {"

    /// The one sanctioned shape of asking it: every fact read off the model
    /// or off the tab in the same expression that hands it over, and
    /// nothing folded into any of them. Compared as a whole body rather
    /// than fact by fact, because a fact can also be substituted before the
    /// call as easily as inside it.
    ///
    /// This shape sanctions no asserted value at all. It used to sanction
    /// one: while nothing rendered a `.pane` entry, both pane facts were
    /// the literal `PaneToggleState(isOn: false, isEnabled: false)`, and
    /// that placeholder was allowed here on the condition that it went the
    /// moment the entries went live. It has — both facts are now read from
    /// `SessionTab.paneToggleState`, the method the toolbar's own
    /// `.disabled` reads, so the menu and the window cannot disagree about
    /// which halves are on screen. Re-introducing a constant for either of
    /// them is V7 again, with nothing left to excuse it.
    ///
    /// `terminalIsVisible` is bound once and handed to both readings on
    /// purpose: two readings of `tab.session?.terminal.isVisible` would be
    /// two chances for the halves to be asked about different states.
    private static let sanctionedDecisionBody = """
        guard let index = tabsModel.tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        let capabilities = BackendDescriptor
            .descriptor(for: tab.connectionViewModel.kind).capabilities
        let terminalIsVisible = tab.session?.terminal.isVisible ?? false
        return TabContextMenu.entries(
            atIndex: index,
            ofTabCount: tabsModel.tabs.count,
            supportsShell: capabilities.supportsShell,
            isAdHoc: tab.activeStoredSessionID == nil,
            isConnected: tab.isConnected,
            filesToggle: tab.paneToggleState(
                for: .files, terminalIsVisible: terminalIsVisible,
                hasShell: capabilities.supportsShell),
            terminalToggle: tab.paneToggleState(
                for: .terminal, terminalIsVisible: terminalIsVisible,
                hasShell: capabilities.supportsShell))
        """

    /// The one sanctioned shape of the iteration: the loop's collection IS
    /// the answer the strip was handed, with nothing between them but the
    /// `Array(…)` wrapper `ForEach` needs to index a non-`Hashable`
    /// element. A complete call including its closing parenthesis, and
    /// checked as a PREFIX of the canonical body, so nothing can be drawn
    /// ahead of the loop and nothing can be appended inside the call.
    private static let sanctionedIteration =
        #"ForEach(Array(menuEntries().enumerated()),id:\.offset)"#

    /// Identifier-boundary tokens that have no business inside a menu body
    /// that only draws what it was handed: the branching keywords (V1) and
    /// the list-narrowing / item-suppressing method names (V2, V3). Matched
    /// as whole tokens, not substrings, so `title(for:)`'s `for` and
    /// `\.offset`'s `offset` are untouched.
    ///
    /// A BLOCKLIST, and therefore not a rule — see this suite's doc comment.
    /// The keyword half is closed (Swift has only so many ways to branch);
    /// the method half names the spellings that were in front of us, and
    /// `.map`, `.allowsHitTesting`, `.opacity` and their kin walk straight
    /// past it. Do not grow this list in the hope of closing that: it
    /// cannot be closed by enumeration, and a longer list reads like a
    /// stronger claim than it is.
    private static let forbiddenTokens: Set<String> = [
        "if", "guard", "else", "switch", "case", "where",
        "filter", "contains", "prefix", "suffix", "dropFirst", "dropLast",
        "disabled", "hidden",
    ]

    /// Operators that reintroduce a decision without a keyword: a ternary
    /// (V1) and a condition folded into an argument (V7).
    private static let forbiddenOperators = ["&&", "||", "?", "!"]

    /// Item-producing spellings other than the single `Button` the loop
    /// draws. An entry added beside the loop (V4) shows up either here or
    /// in the `Button` count.
    private static let foreignItemSpellings = ["Divider(", "Section(", "Toggle(", "Menu{", "Menu("]

    // MARK: - Extraction

    /// The body of the closure `anchor` opens — everything between the
    /// anchor's own `{` and its matching `}`, by plain brace counting.
    /// `nil` on a missing anchor or unbalanced braces rather than a guess.
    private static func contextMenuBody(in source: String) -> String? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        var depth = 1
        var index = anchorRange.upperBound
        let bodyStart = index
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return String(source[bodyStart..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Comments and string literals removed, whitespace kept — the form the
    /// token scan reads, so `if` and `iffy` stay distinguishable.
    private static func stripped(_ source: String) throws -> String {
        try stripCommentsAndStrings(source)
    }

    /// The body of the closure or function `anchor` opens — everything
    /// between its first `{` and the matching `}`, by plain brace counting.
    /// `nil` on a missing anchor or unbalanced braces rather than a guess,
    /// so every caller fails closed. Shared with the drag suite, which
    /// needs the same extraction for the gesture's own closures.
    private static func body(after anchor: String, in source: String) -> String? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        var index = anchorRange.lowerBound
        var depth = 0
        var bodyStart: String.Index?
        while index < source.endIndex {
            let char = source[index]
            if char == "{" {
                depth += 1
                if depth == 1 { bodyStart = source.index(after: index) }
            }
            if char == "}" {
                depth -= 1
                if depth == 0, let start = bodyStart { return String(source[start..<index]) }
                if depth < 0 { return nil }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// One brace-balanced body, canonicalized, from source that has already
    /// had its comments and strings removed — so an anchor spelled inside a
    /// comment cannot misdirect the extraction.
    ///
    /// Unwrapped with `#require`: a missing anchor and unbalanced braces
    /// both leave nothing to compare, and letting that surface as a failed
    /// equality would name the wrong cause. `what` is what the message
    /// calls the source, so a probe and a real file read the same way.
    private static func canonicalBody(
        after anchor: String, in source: String, describing what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let body = try #require(
            Self.body(after: anchor, in: try Self.stripped(source)),
            """
            no `\(anchor)` body could be extracted from \(what) — the anchor is \
            missing or its braces are unbalanced, so the scanner has nothing to \
            check. If the code was legitimately rewritten, re-anchor this guard on \
            its new form; if it was removed, say what took its place.
            """,
            sourceLocation: sourceLocation)
        return body.filter { !$0.isWhitespace }
    }

    private static func canonicalBody(
        after anchor: String, inFileAt url: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        try canonicalBody(
            after: anchor, in: String(contentsOf: url, encoding: .utf8),
            describing: url.path, sourceLocation: sourceLocation)
    }

    /// Comments and string literals removed AND all whitespace collapsed
    /// away — the form the shape checks read, so line-wrapping or
    /// re-indenting the call cannot affect a match.
    private static func canonicalize(_ source: String) throws -> String {
        try stripCommentsAndStrings(source).filter { !$0.isWhitespace }
    }

    /// Every identifier-like token in `source`. Splitting on anything that
    /// is not a letter, digit or underscore is what makes the forbidden
    /// list a word match rather than a substring match.
    private static func identifierTokens(in source: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else if !current.isEmpty {
                tokens.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.insert(current) }
        return tokens
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Everything a violation check needs about one menu body, in one call,
    /// so the synthetic self-tests exercise the same steps the real-file
    /// checks do rather than a hand-assembled variant of them.
    ///
    /// Unwraps with `#require`: a missing anchor and unbalanced braces both
    /// leave nothing to scan, and letting that surface as a failed content
    /// assertion would report the wrong cause. Fail-closed either way — the
    /// `#require` throws, so the calling test fails and can never pass on a
    /// source the scanner could not read.
    private static func menu(
        in source: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (canonical: String, tokens: Set<String>) {
        let body = try #require(
            Self.contextMenuBody(in: source),
            """
            no `\(Self.anchor)` closure could be extracted from this source — \
            the anchor is missing or its braces are unbalanced, so the scanner \
            has nothing to check.
            """,
            sourceLocation: sourceLocation)
        return (try Self.canonicalize(body), Self.identifierTokens(in: try Self.stripped(body)))
    }

    // MARK: - The guarded claims, run against the real file

    /// V5: a second `.contextMenu` in the file would carry items no
    /// decision produced, and would also mean this suite's extraction has
    /// been silently reading whichever one comes first.
    @Test func theMenuIsAttachedExactlyOnceInTheFile() throws {
        let source = try Self.stripped(String(contentsOf: Self.sourceFile, encoding: .utf8))
        let count = Self.occurrences(of: Self.anchor, in: source)
        #expect(count == 1, """
            expected exactly 1 `\(Self.anchor)` in \(Self.sourceFile.path), found \
            \(count) — either a second menu was attached, whose entries nothing \
            decided, or the menu moved. If it moved, re-anchor this guard on its new \
            home; if a second one is intended, say what decides its entries and extend \
            this guard to that answer too.
            """)
    }

    /// V7's site, checked as an absence: the view does not ask the Core
    /// decision at all, so there are no arguments in it to fold a rule
    /// into. Counted while writing this check: the strip file has none of
    /// these calls, and `ContentView+Lifecycle.swift` has one.
    @Test func theViewNeverAsksTheCoreDecisionItself() throws {
        let inStrip = Self.occurrences(
            of: Self.decisionCall,
            in: try Self.stripped(String(contentsOf: Self.sourceFile, encoding: .utf8)))
        #expect(inStrip == 0, """
            found \(inStrip) `\(Self.decisionCall)` in \(Self.sourceFile.path) — the \
            decision belongs where the model is, because two of its facts are \
            positional and a position that reaches a view can be shifted inside it. \
            Ask it in `ContentView.tabMenuEntries(for:)` and hand the strip the answer.
            """)
        let inHandler = Self.occurrences(
            of: Self.decisionCall,
            in: try Self.stripped(String(contentsOf: Self.handlerFile, encoding: .utf8)))
        #expect(inHandler == 1, """
            expected exactly 1 `\(Self.decisionCall)` in \(Self.handlerFile.path), found \
            \(inHandler) — that is where the strip's menu entries are answered. If the \
            answer legitimately moved, re-anchor this guard on its new home.
            """)
    }

    /// V6 and V4 together: the menu body IS the loop over the answer the
    /// strip was handed, from its very first character — so nothing is
    /// drawn ahead of the loop and the loop's collection is not something
    /// else.
    @Test func theMenuIteratesWhatItWasHandedAndNothingElse() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let menu = try Self.menu(in: source)
        #expect(menu.canonical.hasPrefix(Self.sanctionedIteration), """
            the context menu's body in \(Self.sourceFile.path) does not begin with \
            `\(Self.sanctionedIteration)` — it begins with \
            `\(menu.canonical.prefix(80))…` instead. Either something is drawn before \
            the loop, or the loop walks something other than the entries this item was \
            handed. If the hand-over was legitimately renamed, update \
            `sanctionedIteration` in this guard.
            """)
    }

    /// V4: one item per entry, and no other kind of item beside it.
    @Test func theMenuDrawsExactlyOneItemPerEntry() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let menu = try Self.menu(in: source)
        let buttons = Self.occurrences(of: "Button(", in: menu.canonical)
        #expect(buttons == 1, """
            expected exactly 1 `Button(` in the context menu's body in \
            \(Self.sourceFile.path) (one item per entry, drawn by the loop), found \
            \(buttons). An item drawn outside the loop corresponds to no \
            `TabMenuEntry`; if the menu needs a new entry, add it to `TabMenuEntry` and \
            let `TabContextMenu.entries` decide when it appears.
            """)
        for spelling in Self.foreignItemSpellings {
            #expect(!menu.canonical.contains(spelling), """
                the context menu's body in \(Self.sourceFile.path) draws a \
                `\(spelling)` outside the loop — that item corresponds to no \
                `TabMenuEntry` and nothing decided it. Add it to `TabMenuEntry` \
                instead, where its rule can be tested.
                """)
        }
    }

    /// V2, one file along from the loop it used to have to be written in.
    /// The strip iterates what it was handed, so the place a narrowing now
    /// fits is the hand-over: `menuEntries: { tabMenuEntries(for: $0).filter { … } }`
    /// consults the decision and then overrules it, with every character
    /// this suite reads in the strip unchanged. The closure asks the
    /// question and passes the answer on; that is its whole content.
    @Test func theStripIsHandedTheAnswerUnnarrowed() throws {
        let body = try Self.canonicalBody(
            after: Self.handOverAnchor, inFileAt: Self.wiringFile)
        #expect(body == Self.sanctionedHandOver, """
            the `\(Self.handOverAnchor)` closure in \(Self.wiringFile.path) is \
            `\(body)`, not `\(Self.sanctionedHandOver)` — the answer is being changed \
            on its way to the strip, and which entries appear is \
            `TabContextMenu.entries(…)`'s decision, tested in Core. If the hand-over \
            legitimately changed shape, update `sanctionedHandOver` in this guard and \
            add a probe for the shape it now has.
            """)
    }

    /// V7, where it now lives. The view has no facts to supply any more,
    /// but the function that supplies them instead can fold a rule into an
    /// argument (`isConnected: tab.isConnected && …`) or hand over a
    /// substituted fact, and either changes which entries appear with
    /// nothing in the strip to notice.
    ///
    /// This suite already reads that file for
    /// `theViewNeverAsksTheCoreDecisionItself`, so re-anchoring V7 there
    /// costs one comparison. The whole body is
    /// compared rather than the argument list alone: a positional fact can
    /// be rewritten in the `guard` that produces it just as easily as in
    /// the call that uses it.
    @Test func theDecisionIsAskedWithTheRealFactsOnly() throws {
        let body = try Self.canonicalBody(
            after: Self.decisionAnchor, inFileAt: Self.handlerFile)
        let sanctioned = try Self.canonicalize(Self.sanctionedDecisionBody)
        #expect(body == sanctioned, """
            the body of `\(Self.decisionAnchor)` in \(Self.handlerFile.path) is \
            `\(body)`, not `\(sanctioned)` — a fact the decision is asked with has \
            been rewritten, or a rule has been folded into one of them. Every rule \
            about which entries exist belongs in `TabContextMenu.entries`, where \
            `TabContextMenuTests` reaches it. If this function legitimately changed \
            shape, update `sanctionedDecisionBody` in this guard and add a probe for \
            the shape it now has.
            """)
    }

    /// V1, V2, V3: no branch, no narrowing of the list, no item suppressed
    /// into a greyed-out state.
    @Test func theMenuBodyMakesNoDecisionOfItsOwn() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let menu = try Self.menu(in: source)
        let found = Self.forbiddenTokens.intersection(menu.tokens).sorted()
        #expect(found.isEmpty, """
            the context menu's body in \(Self.sourceFile.path) contains \(found) — the \
            view is deciding for itself which entries appear, or which are usable, \
            which is `TabContextMenu.entries(…)`'s job and is tested in Core. Move the \
            condition there.
            """)
        for op in Self.forbiddenOperators {
            #expect(!menu.canonical.contains(op), """
                the context menu's body in \(Self.sourceFile.path) contains `\(op)` — a \
                condition without a keyword is still a condition, and belongs in \
                `TabContextMenu.entries`.
                """)
        }
    }

    // MARK: - Scanner self-tests: a probe for every violation site

    /// The shape the real file has — the scanner must accept it, or none of
    /// the negative probes proves anything.
    private static let sanctionedSource = """
        .contextMenu {
            ForEach(Array(menuEntries().enumerated()), id: \\.offset) { _, entry in
                Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
            }
        }
        """

    @Test func scannerAcceptsTheSanctionedShape() throws {
        let menu = try Self.menu(in: Self.sanctionedSource)
        #expect(menu.canonical.hasPrefix(Self.sanctionedIteration))
        #expect(Self.occurrences(of: "Button(", in: menu.canonical) == 1)
        #expect(Self.forbiddenTokens.intersection(menu.tokens).isEmpty)
        for op in Self.forbiddenOperators {
            #expect(!menu.canonical.contains(op))
        }
    }

    /// V1: an entry Core returned is dropped by a condition in the view —
    /// with a decorative comment naming the Core call, the evasion that has
    /// defeated three guards on earlier branches.
    @Test func scannerFlagsAConditionAroundAnItem() throws {
        let source = """
            .contextMenu {
                ForEach(Array(menuEntries().enumerated()), id: \\.offset) { _, entry in
                    // decided by TabContextMenu.entries(
                    if entry != .saveAsSession {
                        Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                    }
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(!Self.forbiddenTokens.intersection(menu.tokens).isEmpty)
    }

    /// V2: the value is consulted, then narrowed.
    @Test func scannerFlagsAFilteredList() throws {
        let source = """
            .contextMenu {
                ForEach(Array(menuEntries().filter { $0 != .closeOthers }.enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(Self.forbiddenTokens.intersection(menu.tokens) == ["filter"])
    }

    /// V3: the entry stays visible but is greyed out — the design rejects
    /// exactly this in place of a missing entry.
    @Test func scannerFlagsADisabledItem() throws {
        let source = """
            .contextMenu {
                ForEach(Array(menuEntries().enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                        .disabled(tab.transferQueue.isActive)
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(Self.forbiddenTokens.intersection(menu.tokens) == ["disabled"])
    }

    /// V4: an item beside the loop, which no `TabMenuEntry` corresponds to.
    @Test func scannerFlagsAnItemDrawnBesideTheLoop() throws {
        let source = """
            .contextMenu {
                ForEach(Array(menuEntries().enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                }
                Divider()
                Button(L10n.string("tabs.menu.rename", "Rename…")) { onMenuEntry(.close) }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(Self.occurrences(of: "Button(", in: menu.canonical) == 2)
        #expect(menu.canonical.contains("Divider("))
    }

    /// V4 in its subtler form: the extra item sits BEFORE the loop, so the
    /// body no longer begins with the sanctioned iteration.
    @Test func scannerFlagsAnItemDrawnAheadOfTheLoop() throws {
        let source = """
            .contextMenu {
                Button(L10n.string("tabs.menu.rename", "Rename…")) { onMenuEntry(.close) }
                ForEach(Array(menuEntries().enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(!menu.canonical.hasPrefix(Self.sanctionedIteration))
    }

    /// V6: the loop walks a hand-written list while the Core call is
    /// reduced to a comment — the shape a `contains`-based guard would wave
    /// through.
    @Test func scannerFlagsAHandWrittenEntryList() throws {
        let source = """
            .contextMenu {
                // entries per TabContextMenu.entries(atIndex:ofTabCount:…)
                ForEach(Array([TabMenuEntry.close, .closeOthers].enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(!menu.canonical.hasPrefix(Self.sanctionedIteration))
        #expect(Self.occurrences(of: "menuEntries(", in: menu.canonical) == 0)
    }

    /// V2 at the hand-over: the answer narrowed on its way to the strip.
    /// The accepting half comes first, or the flagging half proves nothing.
    @Test func scannerFlagsANarrowedAnswer() throws {
        let sanctioned = try Self.canonicalBody(
            after: Self.handOverAnchor,
            in: "menuEntries: { tabMenuEntries(for: $0) },", describing: "a probe")
        #expect(sanctioned == Self.sanctionedHandOver)
        let narrowed = try Self.canonicalBody(
            after: Self.handOverAnchor,
            in: "menuEntries: { tabMenuEntries(for: $0).filter { $0 != .close } },",
            describing: "a probe")
        #expect(narrowed != Self.sanctionedHandOver)
    }

    /// V7: a rule folded into one of the decision's arguments. The fact is
    /// still read off the tab, and then something is `&&`-ed onto it.
    @Test func scannerFlagsARuleFoldedIntoAnArgument() throws {
        let sanctioned = try Self.canonicalize(Self.sanctionedDecisionBody)
        let accepted = try Self.canonicalBody(
            after: Self.decisionAnchor,
            in: "\(Self.decisionAnchor)\n\(Self.sanctionedDecisionBody)\n}",
            describing: "a probe")
        #expect(accepted == sanctioned)
        let folded = try Self.canonicalBody(
            after: Self.decisionAnchor,
            in: """
                \(Self.decisionAnchor)
                \(Self.sanctionedDecisionBody
                    .replacingOccurrences(
                        of: "isConnected: tab.isConnected,",
                        with: "isConnected: tab.isConnected && !tab.transferQueue.isActive,"))
                }
                """,
            describing: "a probe")
        #expect(folded != sanctioned)
    }

    /// V7's other half: the fact is not read at all, it is asserted. Same
    /// effect on which entries appear, no operator to notice.
    @Test func scannerFlagsASubstitutedFact() throws {
        let sanctioned = try Self.canonicalize(Self.sanctionedDecisionBody)
        let substituted = try Self.canonicalBody(
            after: Self.decisionAnchor,
            in: """
                \(Self.decisionAnchor)
                \(Self.sanctionedDecisionBody
                    .replacingOccurrences(
                        of: "supportsShell: capabilities.supportsShell,",
                        with: "supportsShell: true,"))
                }
                """,
            describing: "a probe")
        #expect(substituted != sanctioned)
    }

    /// The pane facts, the two that decide whether the window's halves can
    /// be switched from this menu at all. Three ways they can go wrong, and
    /// the guard has to see each: the reading replaced by a constant (the
    /// placeholder this shape used to sanction, coming back), the reading
    /// kept but pointed at the other half, and the visibility it is read
    /// against asserted while both readings stay in place.
    ///
    /// Every substitution is checked to actually occur first. A probe whose
    /// target has quietly stopped appearing in `sanctionedDecisionBody`
    /// mutates nothing and passes while checking nothing — which is what
    /// happened to `scannerFlagsARuleFoldedIntoAnArgument` when the
    /// argument list gained two entries and its target lost its closing
    /// parenthesis.
    @Test func scannerFlagsAChangedPaneFact() throws {
        let sanctioned = try Self.canonicalize(Self.sanctionedDecisionBody)
        func mutated(_ target: String, into replacement: String) throws -> String {
            #expect(Self.sanctionedDecisionBody.contains(target), """
                the probe's target `\(target)` no longer occurs in \
                `sanctionedDecisionBody`, so this substitution changes nothing and \
                proves nothing — re-point it at the shape the pane facts have now.
                """)
            return try Self.canonicalBody(
                after: Self.decisionAnchor,
                in: """
                    \(Self.decisionAnchor)
                    \(Self.sanctionedDecisionBody
                        .replacingOccurrences(of: target, with: replacement))
                    }
                    """,
                describing: "a probe")
        }
        let asserted = try mutated(
            "filesToggle: tab.paneToggleState(", into: "filesToggle: PaneToggleState(")
        #expect(asserted != sanctioned)
        let otherHalf = try mutated(
            "for: .files, terminalIsVisible: terminalIsVisible,",
            into: "for: .terminal, terminalIsVisible: terminalIsVisible,")
        #expect(otherHalf != sanctioned)
        let assertedVisibility = try mutated(
            "let terminalIsVisible = tab.session?.terminal.isVisible ?? false",
            into: "let terminalIsVisible = false")
        #expect(assertedVisibility != sanctioned)
    }

    /// V5, at the file level: two attachments, so "the menu" is no longer a
    /// single thing to check.
    @Test func scannerCountsASecondMenuAttachment() throws {
        let source = try Self.stripped("""
            .contextMenu { ForEach(entries) { Button("a") {} } }
            .contextMenu { Button("b") {} }
            """)
        #expect(Self.occurrences(of: Self.anchor, in: source) == 2)
    }

    // MARK: - Fail-closed self-tests

    @Test func scannerFailsClosedOnAMissingAnchor() {
        #expect(Self.contextMenuBody(in: "nothing to see here") == nil)
    }

    @Test func scannerFailsClosedOnUnbalancedBraces() {
        #expect(Self.contextMenuBody(in: ".contextMenu { Button(\"a\") {}") == nil)
    }

    /// Raw strings are parsed (fix round 2). The three things that must
    /// hold: the body disappears like any other literal, the code after it
    /// survives to be judged, and a quote inside the body does not end it
    /// early — which is precisely what a plain-quote scanner gets wrong,
    /// and why this used to throw instead.
    @Test func stripperParsesRawStrings() throws {
        let singleLine = try Self.stripCommentsAndStrings(
            "let quote = #\"a \" quote and TabContextMenu.entries(\"#\nlet after = 1")
        #expect(Self.occurrences(of: Self.decisionCall, in: singleLine) == 0)
        #expect(singleLine.contains("let after = 1"))

        let extraHashes = try Self.stripCommentsAndStrings(
            "let quote = ##\"ends only here \"# TabContextMenu.entries(\"##\nlet after = 2")
        #expect(Self.occurrences(of: Self.decisionCall, in: extraHashes) == 0)
        #expect(extraHashes.contains("let after = 2"))

        let multiline = try Self.stripCommentsAndStrings(
            "let quote = #\"\"\"\nTabContextMenu.entries(\n\"\"\"#\nlet after = 3")
        #expect(Self.occurrences(of: Self.decisionCall, in: multiline) == 0)
        #expect(multiline.contains("let after = 3"))

        // A `#` that opens no string must not swallow what follows it.
        let hashKeyword = try Self.stripCommentsAndStrings("#expect(entries.isEmpty)")
        #expect(hashKeyword.contains("#expect(entries.isEmpty)"))
    }

    /// Extended regex literals are parsed for the same reason raw strings
    /// are: they are ordinary Swift, they carry `/` and `"` and `#`, and a
    /// guard that reds on one in an unrelated line gets switched off. The
    /// bare `/…/` form is deliberately not parsed — see the stripper.
    @Test func stripperParsesExtendedRegexLiterals() throws {
        let simple = try Self.stripCommentsAndStrings(
            "let r = #/TabContextMenu.entries\\(/#\nlet after = 1")
        #expect(Self.occurrences(of: Self.decisionCall, in: simple) == 0)
        #expect(simple.contains("let after = 1"))

        // A `/#` inside the body must not end a `##/…/##` literal early.
        let extraHashes = try Self.stripCommentsAndStrings(
            "let r = ##/ends /# only here/##\nlet after = 2")
        #expect(extraHashes.contains("let after = 2"))

        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("let r = #/unterminated")
        }
    }

    @Test func stripperFailsClosedOnAnUnterminatedLiteral() {
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("/* never closes")
        }
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("let x = #\"unterminated raw")
        }
    }

    @Test func stripperRemovesLineAndBlockCommentsAndStringLiterals() throws {
        let source = #"""
            let a = "TabContextMenu.entries(" // TabContextMenu.entries(
            /* TabContextMenu.entries( */ let b = 1
            let c = """
                TabContextMenu.entries(
                """
            TabContextMenu.entries(
            """#
        let stripped = try Self.stripCommentsAndStrings(source)
        let survivors = Self.occurrences(of: Self.decisionCall, in: stripped)
        #expect(survivors == 1, """
            expected exactly 1 real occurrence of `\(Self.decisionCall)` to survive \
            stripping; found \(survivors).
            """)
    }

    /// The token scan must match whole words, or `title(for:)` and
    /// `\\.offset` would read as branching and the guard would be permanently
    /// red for the wrong reason.
    @Test func theTokenScanMatchesWholeWordsOnly() {
        let tokens = Self.identifierTokens(in: "Button(title(for: entry)) { iffy(offset) }")
        #expect(!tokens.contains("if"))
        #expect(tokens.contains("iffy"))
        #expect(tokens.contains("for"))
    }

    // MARK: - Stripper
    //
    // One private copy per guard file, as this project's other wiring
    // guards keep it: the copies have drifted before, and a shared helper
    // was rejected there for the same reason it would be here.

    /// Strips `//` and `/* */` comments and both `"..."` and `"""..."""`
    /// string literals, preserving line breaks. Handles `\"`-escaped quotes
    /// and nested `/* */` comments. Does not parse string interpolation —
    /// `\(...)` inside a literal is treated as string content, which can
    /// only make a check find LESS text, never invent a match that was not
    /// code.
    ///
    /// Raw strings (`#"…"#`, `##"…"##`, `#"""…"""#`) are parsed rather than
    /// refused — changed in fix round 2, and the reasoning is worth keeping
    /// because it reverses an earlier decision. Refusing them was right
    /// while this stripper read one file that has none: "I do not
    /// understand this" beat guessing. It stopped being right when the scan
    /// grew to a whole module, where an ordinary raw string in any
    /// unrelated file turned these guards red with a message that named
    /// neither the file nor a remedy. A guard that fires on innocent code
    /// is switched off by the next person who trips over it. Parsing a raw
    /// string is also not a guess: the delimiter states its own hash count,
    /// and the terminator is that count spelled backwards.
    ///
    /// Still fails closed on an unterminated string or comment — raw ones
    /// included — because that means it ran off the end without finding
    /// what it was looking for, and everything after that point would be
    /// judged as something it is not.
    private enum StripError: Error, CustomStringConvertible {
        case unterminatedLiteral

        var description: String {
            switch self {
            case .unterminatedLiteral:
                return """
                    unterminated string or comment literal — the scanner ran to the end of \
                    the file still inside one, so nothing after it can be judged
                    """
            }
        }
    }

    /// Whether a literal opened with `hashes` hashes and `quotes` quotes
    /// ends exactly at `index`. With `quotes: 0` it answers the same
    /// question for an extended regex literal, whose closing slash the
    /// caller has already stepped over.
    private static func closesRawString(
        _ chars: [Character], at index: Int, quotes: Int, hashes: Int
    ) -> Bool {
        guard index + quotes + hashes <= chars.count else { return false }
        for offset in 0..<quotes where chars[index + offset] != "\"" { return false }
        for offset in 0..<hashes where chars[index + quotes + offset] != "#" { return false }
        return true
    }

    private static func stripCommentsAndStrings(_ source: String) throws -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                result.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    result.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "#" {
                var j = i
                while j < chars.count, chars[j] == "#" { j += 1 }
                let hashes = j - i
                if j < chars.count, chars[j] == "/" {
                    // An extended regex literal, `#/…/#`. Same idea as a
                    // raw string: the delimiter states its hash count and
                    // the terminator is that count spelled backwards. The
                    // BARE form, `/…/`, is not parsed — it cannot be told
                    // from division without parsing Swift, and this
                    // scanner would rather read one as code than guess.
                    var k = j + 1
                    var closed = false
                    while k < chars.count {
                        if chars[k] == "/", closesRawString(
                            chars, at: k + 1, quotes: 0, hashes: hashes)
                        {
                            k += 1 + hashes
                            closed = true
                            break
                        }
                        result.append(chars[k] == "\n" ? "\n" : " ")
                        k += 1
                    }
                    guard closed else { throw StripError.unterminatedLiteral }
                    result.append(" ")
                    i = k
                    continue
                }
                if j < chars.count, chars[j] == "\"" {
                    // A raw string states its own terminator: the same
                    // number of hashes, after the same number of quotes.
                    // Escapes inside need `\` plus those hashes, so nothing
                    // in the body can fake an end.
                    let isMultiline =
                        j + 2 < chars.count && chars[j + 1] == "\"" && chars[j + 2] == "\""
                    let quotes = isMultiline ? 3 : 1
                    var k = j + quotes
                    var closed = false
                    while k < chars.count {
                        if closesRawString(chars, at: k, quotes: quotes, hashes: hashes) {
                            k += quotes + hashes
                            closed = true
                            break
                        }
                        result.append(chars[k] == "\n" ? "\n" : " ")
                        k += 1
                    }
                    guard closed else { throw StripError.unterminatedLiteral }
                    result.append(" ")
                    i = k
                    continue
                }
                // Not a string delimiter: `#expect`, `#filePath`, `#if`.
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                guard i + 2 < chars.count else { throw StripError.unterminatedLiteral }
                i += 3
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { throw StripError.unterminatedLiteral }
                i += 1
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        guard blockCommentDepth == 0 else { throw StripError.unterminatedLiteral }
        return result
    }
    // MARK: - The drag half of the same feature

    /// Guards what is left to guard about reordering by dragging, which is
    /// deliberately little: **the tab carries its own id, and the drop
    /// hands that id and the tab it landed on to the one reordering rule.**
    ///
    /// **Why this suite is under half its previous size.** Three rounds of
    /// review each got a violation past the scanning suite that preceded
    /// this one, and each violation was the same animal: a source scan
    /// compares text at one place, while the meaning of that text is set by
    /// its surroundings — a shadowed name before it, an initializer behind
    /// it, a helper beside it. Answering each spelling bought one more
    /// anchor and revealed the next. The property was never expressible as
    /// a scan.
    ///
    /// So the code changed instead. The drop used to report a POSITION,
    /// computed in the view out of `Array.enumerated()`, and a position is
    /// a number: it can be shifted by a step, rebound behind a `let`, or
    /// altered inside an `init`, each of which moves a tab somewhere else
    /// while every anchored character stays as it was. It now reports two
    /// IDENTITIES, and `TabsViewModel.move(tabID:onto:)` derives the
    /// position from the array that defines it. An identity has no
    /// arithmetic. The whole class of defects stopped existing, and the
    /// checks that watched for it were deleted rather than kept "just in
    /// case" — a guard standing beside a structural guarantee makes the
    /// next reader trust this suite for more than it does.
    ///
    /// **Where that reasoning was stretched too far, and had to be taken
    /// back.** "What the type carries needs no guard" holds for the
    /// position. It does not hold for the two closures the identities
    /// travel through, and round 3 deleted the checks on both. A closure of
    /// the right type can call the real route with a tab of its own
    /// choosing (`onReorder: { id, _ in onReorder(id, tabs[0]) }` sends
    /// every drop to the same tab) or do nothing at all (`onReorder: { _, _ in }`
    /// makes dragging inert), and neither shows up as a compiler error, in
    /// the drop's own body, or in either value's type. Both checks are
    /// back, on the hand-over and on the wiring — an identity can be
    /// substituted as quietly as a number, it just needs a different
    /// expression to do it in.
    ///
    /// **What is impossible now, and therefore not checked**, with the
    /// shape each one used to be watched by:
    ///
    /// - A position shifted anywhere between the model and the drop —
    ///   before the loop, in the item's initializer, inside the gesture.
    ///   There is no position in the view to shift: the strip's loop is
    ///   `ForEach(tabs)`, the item holds no index and no count, and the
    ///   payload of a drop is two ids.
    /// - A destination out of range, and the clamping that used to answer
    ///   it. The destination is an index of the model's own array by
    ///   construction; a target that closed mid-drag is a `nil` lookup, not
    ///   a stale number.
    /// - The two identities handed over the wrong way round: they are a
    ///   `UUID` and a `SessionTab`, so the swapped call does not compile.
    /// - The view supplying the menu's facts wrongly (the old V7): it
    ///   supplies none. The positional facts are read off the model in the
    ///   expression that uses them.
    ///
    /// **What is still possible and is NOT guarded here** — stated so a
    /// green run is not read as more than it is, and stated instead of
    /// chased:
    ///
    /// - **The strip can be handed a re-sorted array.** `let tabs =
    ///   tabs.inDisplayOrder()` before the loop still compiles. What it
    ///   changes is the ORDER TABS ARE DRAWN IN and nothing else: every
    ///   decision — which entries a menu offers, where a drop lands — is
    ///   derived from the model by identity. It is a rendering defect, and
    ///   no test in this project can see what is rendered. Three attempts
    ///   to catch this by scanning produced three passing evasions.
    /// - **A second `TabStripView(…)` in the app layer.** Nothing here
    ///   counts the constructions, and no type forbids a second one, which
    ///   would be a second strip wired by whatever its own call site says.
    /// - **Whether the gesture works at all.** No test here can see SwiftUI
    ///   begin a drag, accept a drop, or place a tab under the pointer.
    ///   That is a maintainer check in the running app.
    /// - **Whether the drop feedback ever appears.** Nothing here sees a
    ///   tab reported as targeted, sees the highlight drawn, or sees the
    ///   targeting cleared again when the drop ends — nor whether SwiftUI
    ///   reports the dragged tab itself as targeted, which is the case the
    ///   drag origin exists to exclude. What the feedback MEANS once
    ///   reported is `TabBackgroundPlan`'s, called directly in
    ///   `TabBackgroundPlanTests`; that it is reported at all is the same
    ///   maintainer check in the running app.
    /// - **What `TabsViewModel.move(tabID:onto:)` does** is
    ///   `TabsViewModelTests`' subject, called directly, not scanned —
    ///   including what it owes for a target on either side at any
    ///   distance, which is checked there over every ordered pair of a
    ///   strip rather than at a couple of chosen distances.
    ///
    /// What remains here are seven claims about the gesture's own wiring,
    /// which no type can carry — counted in the pass that added the
    /// seventh, 2026-09-05: that the drag and the drop each exist exactly
    /// once, that the drag carries this tab's id and this window's rather
    /// than some other string AND writes that same tab down as the drag's
    /// origin, that the drop routes through `TabDropPlan` and hands each of
    /// its two answers to the matching route, that the targeting closure
    /// records the targeting and decides nothing about it, that the reorder
    /// route reaching the item is the strip's own and not a closure in
    /// front of it, that the cross-window route and the window identity
    /// reach it the same way, and that the wiring closure hands both
    /// identities to the one reordering rule. Two files are read for that:
    /// the strip, and the place the route is wired.
    /// Fail-closed: a missing anchor, unbalanced braces, an unterminated
    /// literal or an unreadable file all fail, and every message names the
    /// file, the construct and what to do about it.
    @Suite("Tab drag wiring guard")
    struct TabDragWiringGuardTests {
        private static let stripFile = TabContextMenuWiringGuardTests.sourceFile

        private static let dragSource = ".draggable("
        private static let dropTarget = ".dropDestination("
        private static let dropAnchor = ".dropDestination(for: String.self) {"

        /// The drag as the strip is allowed to spell it: the payload
        /// function below, and nothing else. A complete call, so nothing
        /// can be appended to it and still match.
        private static let sanctionedDrag = ".draggable(dragPayload())"

        /// Where the payload is produced, and where the drag writes down
        /// which tab it is carrying.
        private static let dragPayloadAnchor = "private func dragPayload() -> String {"

        /// The one sanctioned shape of that function: this tab recorded as
        /// the origin, this tab's id carried. Compared as a whole body,
        /// because recording one tab and carrying another is a defect no
        /// single anchor sees, and either half alone can be substituted.
        private static let sanctionedDragPayloadSource = """
            private func dragPayload() -> String {
                dragOrigin.draggedTabID = tab.id
                return TabDragPayload(tabID: tab.id, sourceWindowID: windowID).encoded()
            }
            """

        /// Where the drop reports that something is over this tab.
        private static let targetingAnchor = "isTargeted: {"

        /// The one sanctioned shape of that report: recorded raw. A
        /// condition written here is a rule about what a targeting MEANS,
        /// and that rule is `TabBackgroundPlan.build`'s, where
        /// `TabBackgroundPlanTests` reaches it.
        private static let sanctionedTargeting = "isDropTargeted=$0"

        /// The payload question, asked rather than answered inline. Since
        /// Task 3 it is `route`, not `draggedTabID`: the drop now has two
        /// answers to tell apart (this window's own drag, or another
        /// window's), and where that line is drawn is a rule, so it belongs
        /// in `TabDropPlan` where `TabDragTests` calls it.
        private static let sanctionedPayloadRead = "TabDropPlan.route(payload:payload,ownWindow:windowID)"

        /// The drop's reorder call: the id the payload named and the tab
        /// this item draws. A complete call — `onReorder(draggedID,tab2)`
        /// does not contain it.
        private static let sanctionedRoute = "onReorder(draggedID,tab)"

        /// The drop's OTHER outward call (Task 3), for a tab dragged in from
        /// another window: the payload, whole, handed on. The tab it was let
        /// go on is deliberately not passed — a tab arriving from elsewhere
        /// is appended, and where it lands is not a decision this gesture
        /// gets to make.
        private static let sanctionedCrossWindowRoute = "onDropFromOtherWindow(carried)"

        /// The strip handing the route to the item, up to and including the
        /// comma that ends the argument — so a route wrapped in a closure,
        /// or merely renamed, does not contain it. It was the construction's
        /// closing parenthesis until Task 3 added two arguments after it.
        private static let sanctionedRouteHandOver = "onReorder:onReorder,"

        /// The same for Task 3's two additions: the window this strip is
        /// drawing, and the route a tab arriving from another window takes.
        /// Both bare, for the same reason — a closure in between could hand
        /// the item a different window's id, which would make every drop
        /// look like a reorder, or drop the cross-window route on the floor.
        private static let sanctionedWindowHandOver = "windowID:windowID,"
        private static let sanctionedCrossWindowHandOver =
            "onDropFromOtherWindow:onDropFromOtherWindow)"

        /// The route as a stored property, with its type: one on the strip,
        /// one on the item. A computed property, or a local of another
        /// shape, does not match this.
        private static let sanctionedRouteProperty = "letonReorder:(UUID,SessionTab)->Void"

        /// Any binding of the name at all, whatever its shape — the count
        /// that notices a third one the two text anchors would not.
        private static let anyRouteBinding = "letonReorder"

        /// The same, for Task 3's two additions.
        private static let anyWindowBinding = "letwindowID"
        private static let anyCrossWindowBinding = "letonDropFromOtherWindow"

        /// Where the route is wired to the model.
        private static let wiringFile = TabContextMenuWiringGuardTests.wiringFile

        private static let wiringAnchor = "onReorder: {"

        /// The one sanctioned shape of that wiring: both identities handed
        /// to the one reordering rule, in the order its labels name, and
        /// nothing else done with them.
        private static let sanctionedWiringSource = """
            onReorder: { draggedID, target in
                tabsModel.move(tabID: draggedID, onto: target.id)
            }
            """

        /// Routes out of the tab item that are not the reorder route. A
        /// drop that fires one of these is doing something it was not asked
        /// for.
        private static let foreignRoutes = ["onMenuEntry(", "onActivate(", "onClose(", "onAdd("]

        // MARK: - Extraction

        /// The body of the closure `anchor` opens — everything between its
        /// first `{` and the matching `}`. `nil` on a missing anchor or
        /// unbalanced braces rather than a guess, so every caller fails
        /// closed. One implementation, shared with the menu half, which
        /// needs the same extraction for the hand-over and the decision.
        static func body(after anchor: String, in source: String) -> String? {
            TabContextMenuWiringGuardTests.body(after: anchor, in: source)
        }

        /// The drop closure's body in canonical form. `#require` on the
        /// extraction: a missing anchor and unbalanced braces both leave
        /// nothing to scan, and reporting that as a failed content
        /// assertion would name the wrong cause.
        static func dropBody(
            in source: String, sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> String {
            let body = try #require(
                Self.body(after: Self.dropAnchor, in: source),
                """
                no `\(Self.dropAnchor)` body could be extracted from \
                \(Self.stripFile.path) — the anchor is missing or its braces are \
                unbalanced. If the drop was legitimately rewritten, re-anchor this \
                guard on its new form; if it was removed, this feature is gone and so \
                should this suite be.
                """,
                sourceLocation: sourceLocation)
            return try TabContextMenuWiringGuardTests.canonicalize(body)
        }

        private static func canonicalStrip() throws -> String {
            try TabContextMenuWiringGuardTests.canonicalize(
                String(contentsOf: stripFile, encoding: .utf8))
        }

        private static func occurrences(of needle: String, in haystack: String) -> Int {
            TabContextMenuWiringGuardTests.occurrences(of: needle, in: haystack)
        }

        // MARK: - The seven remaining claims

        /// One drag source, one drop target. A second of either is a second
        /// gesture path, and would also make "the drop closure" ambiguous for
        /// `theDropHandsOverBothIdentitiesAndDoesNothingElse`.
        @Test func theDragAndTheDropAreAttachedExactlyOnceEach() throws {
            let source = try Self.canonicalStrip()
            let drags = Self.occurrences(of: Self.dragSource, in: source)
            let drops = Self.occurrences(of: Self.dropTarget, in: source)
            #expect(drags == 1, """
                expected exactly 1 `\(Self.dragSource)` in \(Self.stripFile.path), found \
                \(drags). A second drag source is a second thing a tab can carry; if \
                that is intended, say what it carries and extend this guard.
                """)
            #expect(drops == 1, """
                expected exactly 1 `\(Self.dropTarget)` in \(Self.stripFile.path), found \
                \(drops). A second drop target is a second thing a drop can mean; if \
                that is intended, extend this guard to describe it.
                """)
        }

        /// The drag carries the tab it is attached to, and writes that same
        /// tab down as the drag's origin. Nothing about the reordering has
        /// to change for a different payload to move the wrong tab, and the
        /// payload is the one value on this path the type system does not
        /// carry: it is a string.
        ///
        /// The origin travels with it because it is written in the same
        /// two lines, and it decides one thing on its own: which tab is
        /// excluded from the drop highlight. Recording a tab other than the
        /// one being carried excludes the wrong tab — the dragged tab
        /// offers itself as somewhere to let go, promising a move that
        /// `TabsViewModel.move(tabID:onto:)` will not make.
        @Test func theDragCarriesTheTabItIsAttachedToAndRecordsItAsTheOrigin() throws {
            let source = try Self.canonicalStrip()
            #expect(source.contains(Self.sanctionedDrag), """
                the drag payload in \(Self.stripFile.path) is not \
                `\(Self.sanctionedDrag)` — a drag carrying anything else names a \
                different tab than the one under the pointer. If the payload type \
                changed deliberately, update `sanctionedDrag` in this guard to the new \
                spelling.
                """)
            let payload = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.dragPayloadAnchor, inFileAt: Self.stripFile)
            let sanctioned = try Self.sanctionedDragPayloadBody()
            #expect(payload == sanctioned, """
                the `\(Self.dragPayloadAnchor)` body in \(Self.stripFile.path) is \
                `\(payload)`, not `\(sanctioned)` — the drag is carrying one tab and \
                recording another, or recording nothing. The recorded tab is the one \
                excluded from the drop highlight, so a wrong one there makes the \
                dragged tab offer itself as a destination it will not honour. If this \
                function legitimately changed shape, update \
                `sanctionedDragPayloadSource` in this guard and add a probe for the \
                shape it now has.
                """)
        }

        static func sanctionedDragPayloadBody() throws -> String {
            try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.dragPayloadAnchor, in: Self.sanctionedDragPayloadSource,
                describing: "this guard's own sanctioned drag payload")
        }

        /// The drop asks `TabDropPlan` and hands each answer to the route
        /// that matches it. It can no longer compute anything: there is
        /// nothing numeric in scope, and the reorder's two values are of
        /// different types.
        ///
        /// Both routes are counted, at exactly one each. A drop that had
        /// lost its cross-window arm would still reorder perfectly, which is
        /// precisely the shape that goes unnoticed.
        @Test func theDropHandsOverBothIdentitiesAndDoesNothingElse() throws {
            let body = try Self.dropBody(
                in: String(contentsOf: Self.stripFile, encoding: .utf8))
            #expect(body.contains(Self.sanctionedPayloadRead), """
                the drop closure in \(Self.stripFile.path) does not ask \
                `\(Self.sanctionedPayloadRead)` — the payload is being read some other \
                way, in a closure no test can call. Move that reading into \
                `TabDropPlan`, where `TabDropPlanTests` reaches it.
                """)
            let routes = Self.occurrences(of: Self.sanctionedRoute, in: body)
            #expect(routes == 1, """
                expected exactly 1 `\(Self.sanctionedRoute)` in the drop closure in \
                \(Self.stripFile.path), found \(routes) — the drop is not handing the \
                dragged id and this tab to the one reorder route. If the route was \
                renamed, update `sanctionedRoute` in this guard.
                """)
            let crossWindow = Self.occurrences(of: Self.sanctionedCrossWindowRoute, in: body)
            #expect(crossWindow == 1, """
                expected exactly 1 `\(Self.sanctionedCrossWindowRoute)` in the drop \
                closure in \(Self.stripFile.path), found \(crossWindow) — a tab dragged \
                in from another window reaches nothing, and the drop still reorders \
                perfectly, so nothing else here notices. If the route was renamed, \
                update `sanctionedCrossWindowRoute` in this guard.
                """)
            for route in Self.foreignRoutes {
                #expect(!body.contains(route), """
                    the drop closure in \(Self.stripFile.path) fires `\(route)` — a drop \
                    is not that gesture. If a drop should also do that, say so where \
                    the lifecycle lives, not inside the gesture.
                    """)
            }
        }

        /// The targeting closure records that something is over this tab
        /// and does nothing else with it. Everything the report MEANS —
        /// that the dragged tab itself is not a destination, that a drop
        /// target outranks the active tab — is `TabBackgroundPlan.build`'s,
        /// where `TabBackgroundPlanTests` calls it directly; a condition
        /// written into this closure would be that same rule spelled a
        /// second time, in a place no test can reach.
        ///
        /// Compared as a whole body: an inverted report
        /// (`isDropTargeted = !$0`), a narrowed one and an empty closure
        /// are the same defect at this site, and only equality sees all
        /// three.
        @Test func theTargetingClosureOnlyRecordsTheTargeting() throws {
            let body = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.targetingAnchor, inFileAt: Self.stripFile)
            #expect(body == Self.sanctionedTargeting, """
                the `\(Self.targetingAnchor)` closure in \(Self.stripFile.path) is \
                `\(body)`, not `\(Self.sanctionedTargeting)` — the drop's report is \
                being judged where it is received instead of recorded, and what a \
                targeting means for a tab's background is `TabBackgroundPlan.build`'s \
                decision, tested in `TabBackgroundPlanTests`. If this closure \
                legitimately changed shape, update `sanctionedTargeting` in this guard \
                and add a probe for the shape it now has.
                """)
        }

        /// The route the drop hands its two identities to must be the one
        /// the strip was given, not a closure standing in front of it.
        ///
        /// This is the half a type cannot carry, and the reason it is back:
        /// the identities are safe from arithmetic, but the route that
        /// carries them is a closure, and a closure can be replaced by one
        /// that calls the real route with a tab of its own choosing.
        /// `onReorder: { id, _ in onReorder(id, tabs[0]) }` sends every drop
        /// to the same tab; the drop's own body, the drag's payload and
        /// both value types are untouched, so nothing else here notices.
        ///
        /// Two anchors and a count, because each covers what the others
        /// miss: the hand-over must be the bare name (a wrapper is not it),
        /// the name must be a stored property of the route's type on both
        /// views (a computed one could wrap without changing the
        /// hand-over), and no third binding of the name may exist (a local
        /// of any shape could shadow it before the hand-over reads it).
        ///
        /// Counted while writing this check: the strip file binds
        /// `onReorder` twice — once as `TabStripView`'s property, once as
        /// the item's — and hands it over once.
        @Test func theReorderRouteReachesTheItemUnwrapped() throws {
            let canonical = try Self.canonicalStrip()
            let handOvers = Self.occurrences(of: Self.sanctionedRouteHandOver, in: canonical)
            #expect(handOvers == 1, """
                expected exactly 1 `\(Self.sanctionedRouteHandOver)` in \
                \(Self.stripFile.path), found \(handOvers) — the item is not being \
                handed the strip's own route. A closure in between can call it with a \
                different tab, which moves every drop to the same place without \
                changing the drop, the payload or either type. If the construction \
                legitimately gained an argument after this one, update \
                `sanctionedRouteHandOver` in this guard.
                """)
            let properties = Self.occurrences(of: Self.sanctionedRouteProperty, in: canonical)
            #expect(properties == 2, """
                expected exactly 2 `\(Self.sanctionedRouteProperty)` in \
                \(Self.stripFile.path), found \(properties) — the route is a stored \
                property on the strip and on the item, and a computed one could wrap \
                it while the hand-over above still reads correctly. If the route's \
                type legitimately changed, update `sanctionedRouteProperty` in this \
                guard.
                """)
            let bindings = Self.occurrences(of: Self.anyRouteBinding, in: canonical)
            #expect(bindings == 2, """
                expected exactly 2 `\(Self.anyRouteBinding)` in \(Self.stripFile.path), \
                found \(bindings) — a third binding of that name can shadow the route \
                before the hand-over reads it. If another `onReorder` is intended, say \
                what it carries and extend this guard to it.
                """)
        }

        /// Task 3's two additions reach the item the same way the reorder
        /// route does: bare, with no closure in between.
        ///
        /// Each is a different silent failure. A wrapped or wrong `windowID`
        /// makes the item compare the payload's source window against
        /// something that is not this window — every drop then reads as a
        /// cross-window move, or every one reads as a reorder, and the drop
        /// closure, both routes and every type are untouched. A wrapped
        /// `onDropFromOtherWindow` can swallow the payload entirely, which
        /// looks exactly like a drag the user aimed badly.
        ///
        /// Counted while writing this check: the strip file binds `windowID`
        /// once on the strip and once on the item, and hands it over once;
        /// `onDropFromOtherWindow` likewise. The properties are counted
        /// through `anyWindowBinding`/`anyCrossWindowBinding` rather than
        /// through their spelled-out types, so a third binding of either
        /// name — which could shadow the real one before the hand-over reads
        /// it — is what the numbers below notice.
        @Test func theCrossWindowRouteAndTheWindowIdentityReachTheItemUnwrapped() throws {
            let canonical = try Self.canonicalStrip()
            let windowHandOvers = Self.occurrences(of: Self.sanctionedWindowHandOver, in: canonical)
            #expect(windowHandOvers == 1, """
                expected exactly 1 `\(Self.sanctionedWindowHandOver)` in \
                \(Self.stripFile.path), found \(windowHandOvers) — the item is not \
                being handed the strip's own window id. Anything else there makes \
                every drop read as the same kind, without changing the drop, the \
                payload or either type.
                """)
            let crossHandOvers = Self.occurrences(
                of: Self.sanctionedCrossWindowHandOver, in: canonical)
            #expect(crossHandOvers == 1, """
                expected exactly 1 `\(Self.sanctionedCrossWindowHandOver)` in \
                \(Self.stripFile.path), found \(crossHandOvers) — a closure in between \
                can swallow the payload, which is indistinguishable from a drag that \
                missed.
                """)
            let windowBindings = Self.occurrences(of: Self.anyWindowBinding, in: canonical)
            #expect(windowBindings == 2, """
                expected exactly 2 `\(Self.anyWindowBinding)` in \(Self.stripFile.path), \
                found \(windowBindings) — the window id is a stored property on the \
                strip and on the item, and a third binding of that name can shadow it \
                before the hand-over reads it.
                """)
            let crossBindings = Self.occurrences(of: Self.anyCrossWindowBinding, in: canonical)
            #expect(crossBindings == 2, """
                expected exactly 2 `\(Self.anyCrossWindowBinding)` in \
                \(Self.stripFile.path), found \(crossBindings) — same shape as above, \
                for the cross-window route.
                """)
        }

        /// What the route is wired to at the other end. The strip hands two
        /// identities out; this is the one place that decides what happens
        /// to them, and `onReorder: { _, _ in }` makes dragging do nothing
        /// at all without a compiler error, a red test, or a character
        /// changing in the strip.
        ///
        /// Compared as a whole body: an inverted pair of labels, an extra
        /// statement and an empty closure are all the same defect at this
        /// site, and only equality sees all three.
        @Test func theWiringClosureCallsTheOneRuleAndNothingElse() throws {
            let wired = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.wiringAnchor, inFileAt: Self.wiringFile)
            let sanctioned = try Self.sanctionedWiringBody()
            #expect(wired == sanctioned, """
                the `\(Self.wiringAnchor)` closure in \(Self.wiringFile.path) is \
                `\(wired)`, not `\(sanctioned)` — a drop reaches the model only \
                through this closure, so anything else written here silently changes \
                or cancels every drag. If the wiring legitimately changed shape, \
                update `sanctionedWiringSource` in this guard and add a probe for the \
                shape it now has.
                """)
        }

        static func sanctionedWiringBody() throws -> String {
            try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.wiringAnchor, in: Self.sanctionedWiringSource,
                describing: "this guard's own sanctioned wiring")
        }

        // MARK: - Scanner self-tests

        static let sanctionedDropSource = """
            .draggable(dragPayload())
            .dropDestination(for: String.self) { payload, _ in
                switch TabDropPlan.route(payload: payload, ownWindow: windowID) {
                case .reorder(let draggedID):
                    onReorder(draggedID, tab)
                    return true
                case .acrossWindows(let carried):
                    onDropFromOtherWindow(carried)
                    return true
                case .none:
                    return false
                }
            } isTargeted: { isDropTargeted = $0 }
            """

        @Test func scannerAcceptsTheSanctionedShape() throws {
            let body = try Self.dropBody(in: Self.sanctionedDropSource)
            #expect(body.contains(Self.sanctionedPayloadRead))
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: body) == 1)
            #expect(Self.occurrences(of: Self.sanctionedCrossWindowRoute, in: body) == 1)
            for route in Self.foreignRoutes { #expect(!body.contains(route)) }
            let canonical = try TabContextMenuWiringGuardTests
                .canonicalize(Self.sanctionedDropSource)
            #expect(canonical.contains(Self.sanctionedDrag))
            let targeting = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.targetingAnchor, in: Self.sanctionedDropSource,
                describing: "a probe")
            #expect(targeting == Self.sanctionedTargeting)
        }

        /// The drop's own body must not swallow the targeting closure that
        /// follows it, or the two would be judged as one.
        @Test func theDropExtractionStopsBeforeTheTargetingClosure() throws {
            let body = try Self.dropBody(in: Self.sanctionedDropSource)
            #expect(!body.contains("isDropTargeted"))
        }

        /// The payload function carrying one tab while recording another —
        /// the shape that excludes the wrong tab from the highlight, with
        /// the drag itself working exactly as before.
        @Test func scannerFlagsAPayloadThatRecordsAnotherTab() throws {
            let sanctioned = try Self.sanctionedDragPayloadBody()
            let accepted = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.dragPayloadAnchor, in: Self.sanctionedDragPayloadSource,
                describing: "a probe")
            #expect(accepted == sanctioned)
            let misrecorded = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.dragPayloadAnchor,
                in: Self.sanctionedDragPayloadSource.replacingOccurrences(
                    of: "dragOrigin.draggedTabID = tab.id",
                    with: "dragOrigin.draggedTabID = tabs[0].id"),
                describing: "a probe")
            #expect(misrecorded != sanctioned)
        }

        /// The mirror image: the origin is recorded correctly and the drag
        /// carries something else. Since Task 3 the probe is the one that
        /// costs nothing to write and cannot be seen from anywhere else — a
        /// payload naming a window that is not this one, which makes every
        /// drop on this strip read as a cross-window move.
        @Test func scannerFlagsAPayloadThatCarriesAnotherValue() throws {
            let sanctioned = try Self.sanctionedDragPayloadBody()
            let miscarried = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.dragPayloadAnchor,
                in: Self.sanctionedDragPayloadSource.replacingOccurrences(
                    of: "sourceWindowID: windowID", with: "sourceWindowID: WindowID()"),
                describing: "a probe")
            #expect(miscarried != sanctioned)
        }

        /// The targeting closure judging the report instead of recording
        /// it: inverted, and narrowed by a rule of its own.
        @Test func scannerFlagsATargetingClosureThatDecidesSomething() throws {
            let inverted = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.targetingAnchor, in: "isTargeted: { isDropTargeted = !$0 }",
                describing: "a probe")
            #expect(inverted != Self.sanctionedTargeting)
            let narrowed = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.targetingAnchor,
                in: "isTargeted: { isDropTargeted = $0 && !isActive }", describing: "a probe")
            #expect(narrowed != Self.sanctionedTargeting)
            let inert = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.targetingAnchor, in: "isTargeted: { _ in }", describing: "a probe")
            #expect(inert != Self.sanctionedTargeting)
        }

        /// A payload naming something other than this tab — the shape the
        /// second claim exists for.
        @Test func scannerFlagsADragThatNamesSomethingElse() throws {
            let canonical = try TabContextMenuWiringGuardTests
                .canonicalize(".draggable(tab.displayTitle)")
            #expect(!canonical.contains(Self.sanctionedDrag))
            #expect(Self.occurrences(of: Self.dragSource, in: canonical) == 1)
        }

        /// A second drag source, carrying who knows what.
        @Test func scannerCountsASecondDragSource() throws {
            let canonical = try TabContextMenuWiringGuardTests.canonicalize("""
                .draggable(tab.id.uuidString)
                .draggable(tab.displayTitle)
                """)
            #expect(Self.occurrences(of: Self.dragSource, in: canonical) == 2)
        }

        /// A drop that fires another of the item's routes instead of
        /// reordering.
        @Test func scannerFlagsADropRoutedSomewhereElse() throws {
            let body = try Self.dropBody(in: """
                .dropDestination(for: String.self) { payload, _ in
                    guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
                    onMenuEntry(.move(.left))
                    return true
                }
                """)
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: body) == 0)
            #expect(body.contains("onMenuEntry("))
        }

        /// A drop that reads the payload itself rather than asking the one
        /// function a test can call.
        @Test func scannerFlagsAPayloadReadInsideTheGesture() throws {
            let body = try Self.dropBody(in: """
                .dropDestination(for: String.self) { payload, _ in
                    guard let draggedID = payload.first.flatMap(UUID.init(uuidString:))
                    else { return false }
                    onReorder(draggedID, tab)
                    return true
                }
                """)
            #expect(!body.contains(Self.sanctionedPayloadRead))
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: body) == 1)
        }

        /// The route wrapped in a closure that supplies a tab of its own —
        /// the shape the hand-over anchor exists for.
        @Test func scannerFlagsAWrappedReorderRoute() throws {
            let sanctioned = try TabContextMenuWiringGuardTests
                .canonicalize("TabItemView(tab: tab, onReorder: onReorder, windowID: windowID)")
            #expect(Self.occurrences(of: Self.sanctionedRouteHandOver, in: sanctioned) == 1)
            let wrapped = try TabContextMenuWiringGuardTests.canonicalize(
                "TabItemView(tab: tab, onReorder: { id, _ in onReorder(id, tabs[0]) }, x: y)")
            #expect(Self.occurrences(of: Self.sanctionedRouteHandOver, in: wrapped) == 0)
        }

        /// The route rebound behind a local of another shape before the
        /// hand-over reads it: the hand-over still spells the bare name and
        /// the typed properties are still both there, so the count of
        /// bindings is the half that notices.
        @Test func scannerCountsARouteReboundBeforeTheHandOver() throws {
            let canonical = try TabContextMenuWiringGuardTests.canonicalize("""
                let onReorder = { (id: UUID, _: SessionTab) in onReorder(id, tabs[0]) }
                TabItemView(tab: tab, onReorder: onReorder, windowID: windowID)
                """)
            #expect(Self.occurrences(of: Self.sanctionedRouteHandOver, in: canonical) == 1)
            #expect(Self.occurrences(of: Self.sanctionedRouteProperty, in: canonical) == 0)
            #expect(Self.occurrences(of: Self.anyRouteBinding, in: canonical) == 1)
        }

        /// Task 3's two hand-overs, accepted bare and flagged wrapped —
        /// the same property `scannerFlagsAWrappedReorderRoute` holds for
        /// the reorder route, for the two arguments that were added beside
        /// it.
        @Test func scannerFlagsAWrappedWindowIdentityOrCrossWindowRoute() throws {
            let sanctioned = try TabContextMenuWiringGuardTests.canonicalize(
                "TabItemView(windowID: windowID, onDropFromOtherWindow: onDropFromOtherWindow)")
            #expect(Self.occurrences(of: Self.sanctionedWindowHandOver, in: sanctioned) == 1)
            #expect(Self.occurrences(of: Self.sanctionedCrossWindowHandOver, in: sanctioned) == 1)
            let wrapped = try TabContextMenuWiringGuardTests.canonicalize(
                "TabItemView(windowID: WindowID(), onDropFromOtherWindow: { _ in })")
            #expect(Self.occurrences(of: Self.sanctionedWindowHandOver, in: wrapped) == 0)
            #expect(Self.occurrences(of: Self.sanctionedCrossWindowHandOver, in: wrapped) == 0)
        }

        /// The drop that lost its cross-window arm: it reorders exactly as
        /// it always did, so only the count of the second route sees it.
        @Test func scannerFlagsADropThatLostItsCrossWindowRoute() throws {
            let body = try Self.dropBody(
                in: Self.sanctionedDropSource.replacingOccurrences(
                    of: "onDropFromOtherWindow(carried)", with: "break"))
            #expect(body.contains(Self.sanctionedPayloadRead))
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: body) == 1)
            #expect(Self.occurrences(of: Self.sanctionedCrossWindowRoute, in: body) == 0)
        }

        /// The wiring closure accepted in its sanctioned shape, and flagged
        /// in the two shapes that cost nothing to write: doing nothing at
        /// all, and calling the rule with the two identities inverted.
        @Test func scannerFlagsAWiringClosureThatDoesNotDoTheOneThing() throws {
            let sanctioned = try Self.sanctionedWiringBody()
            let inert = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.wiringAnchor, in: "onReorder: { _, _ in }", describing: "a probe")
            #expect(inert != sanctioned)
            let inverted = try TabContextMenuWiringGuardTests.canonicalBody(
                after: Self.wiringAnchor,
                in: """
                    onReorder: { draggedID, target in
                        tabsModel.move(tabID: target.id, onto: draggedID)
                    }
                    """,
                describing: "a probe")
            #expect(inverted != sanctioned)
        }

        /// The route anchor is a complete call, so a neighbouring value
        /// that merely starts the same way is not it. This is the one
        /// property every earlier round of this suite got wrong.
        @Test func theRouteAnchorIsNotASpellingPrefix() throws {
            let canonical = try TabContextMenuWiringGuardTests
                .canonicalize("onReorder(draggedID, tabAfterThisOne)")
            #expect(!canonical.contains(Self.sanctionedRoute))
        }

        // MARK: - Fail-closed self-tests

        @Test func scannerFailsClosedOnAMissingAnchor() {
            #expect(Self.body(after: Self.dropAnchor, in: "nothing to see here") == nil)
        }

        @Test func scannerFailsClosedOnUnbalancedBraces() {
            #expect(Self.body(after: Self.dropAnchor, in: """
                .dropDestination(for: String.self) { payload, _ in
                    onReorder(draggedID, tab)
                """) == nil)
        }

        /// The extraction must stop at the drop's own closing brace, or a
        /// later closure's contents would be judged as if they were the
        /// drop's.
        @Test func extractionStopsAtItsOwnClosingBrace() throws {
            let body = try Self.dropBody(in: """
                .dropDestination(for: String.self) { payload, _ in
                    onReorder(draggedID, tab)
                }
                .contextMenu { onMenuEntry(.close) }
                """)
            #expect(!body.contains("onMenuEntry("))
            #expect(body.contains(Self.sanctionedRoute))
        }
    }
}
