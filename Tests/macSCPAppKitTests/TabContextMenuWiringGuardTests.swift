import Foundation
import Testing

/// Guards ONE property of the tab strip's context menu in
/// `Sources/MacSCPAppKit/TabStripView.swift`: **the view does not decide
/// which entries appear.** The list it draws is whatever it was handed —
/// no more, no fewer, in that order — and every rule about when an entry
/// is offered lives in Core, in
/// `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:)`,
/// where `TabContextMenuTests` can reach it.
///
/// The view no longer asks that function itself (drag task, fix round 3).
/// Two of its five facts are positional, and a position that reaches a
/// view is a position that can be shifted inside it — so the question is
/// asked where the model is, and the strip is handed the answer. That
/// removed a violation site rather than a check: **V7 below no longer
/// exists**, because the view supplies no facts to fold a rule into.
///
/// Why a guard at all: `TabContextMenuTests` proves what the decision
/// FUNCTION answers, and it stays green whether or not anything calls it.
/// This project has no SwiftUI rendering harness (the same boundary
/// `PaneRenderConditionGuardTests` and `KeepAliveStepperWiringGuardTests`
/// document), so a menu that quietly re-derives visibility in the view —
/// the exact shape the design rejects — can only be caught by reading the
/// source.
///
/// **Where the property could be violated FROM.** The checks below were
/// derived from this list, not from the lines that happened to get written:
///
/// - **V1** A condition inside the menu closure wrapping an item (`if`,
///   `guard`, `else`, a ternary), so an entry Core returned is not drawn.
/// - **V2** A transformation of the returned list before it is iterated
///   (`filter`, `prefix`, `dropFirst`, `contains`), so the value is
///   consulted and then overruled.
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
/// - **V7** *(no longer possible in this file)* An extra rule folded into
///   the ARGUMENTS of the decision — `isConnected: tab.isConnected && …`,
///   or a count that is not the strip's real count. The view has no
///   arguments to fold anything into any more. The three non-positional
///   facts moved with the call, into `ContentView.tabMenuEntries(for:)`,
///   and are not guarded there: same boundary as this suite's last limit
///   below, one file further along.
///
/// **Deliberately NOT guarded here**, so a green run is not read as more
/// than it is:
///
/// - A handler that does nothing (`case .saveAsSession: break` in
///   `ContentView+Lifecycle.swift`). That makes an entry inert, not
///   invisible — a different property, and one this scanner cannot judge.
/// - The title mapping answering an empty string. The item still exists and
///   is still clickable; and `TabMenuEntryTitle.title(for:)` is a total
///   `switch`, so the compiler already refuses to let a case be dropped.
///
/// **What this guard does NOT catch.** Corrected in fix round 1 after a
/// reviewer got four mutations past it; the technique was kept and the
/// claim narrowed, because chasing each hole with another anchor buys a
/// longer blocklist and no property.
///
/// The list above says where the property can be violated FROM. What the
/// checks actually recognize is narrower, in three specific ways, and a
/// green run means only this much:
///
/// - **V2 and V3 are a name blocklist, not a rule.** `forbiddenTokens`
///   names the spellings that were in front of us. A narrowing or
///   suppressing call by any other name passes: `.map { _ in .close }`
///   rewrites every entry into the same one, `.allowsHitTesting(false)`
///   makes an item unclickable, `.opacity(0)` makes it invisible. None is
///   on the list, and none can be, without the list becoming an
///   ever-growing catalogue of SwiftUI's surface.
/// - **It reads one file.** The facts come from `SessionTab` and are
///   assembled in `ContentView.tabMenuEntries(for:)`; neither is scanned.
///   A doctored `isConnected`, or a rule folded in where the facts are
///   read, changes which entries appear with nothing in this suite to
///   notice. That is where V7 went: not closed, moved and declared.
///
/// So: this catches a condition, a filter, a `.disabled`, an extra item, a
/// second menu, and a swapped iteration source, all under the names they
/// are usually written with. It does not prove the menu shows what Core
/// decided — only that the view draws what it was handed and does not
/// visibly argue.
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
/// Self-tested against synthetic source — a probe for every violation
/// site named here, and two for V4, whose extra item can be drawn either
/// ahead of the loop or after it — so the scanner cannot pass merely
/// because the real file moved or was reformatted past recognition.
@Suite("Tab context menu wiring guard")
struct TabContextMenuWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TabContextMenuWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `KeepAliveStepperWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabStripView.swift")

    /// Where the strip's menu entries are answered now.
    private static let handlerFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")

    private static let anchor = ".contextMenu {"
    private static let decisionCall = "TabContextMenu.entries("

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
    /// decision produced, and would also mean the extraction above has been
    /// silently reading whichever one comes first.
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

    /// The shape the real file has — the scanner must accept it, or every
    /// negative probe below proves nothing.
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
                    // decided by TabContextMenu.entries( above
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
    /// **Why this suite is a third of its previous size.** Three rounds of
    /// review each got a violation past it, and each violation was the same
    /// animal: a source scan compares text at one place, while the meaning
    /// of that text is set by its surroundings — a shadowed name before it,
    /// an initializer behind it, a helper beside it. Answering each spelling
    /// bought one more anchor and revealed the next. The property was never
    /// expressible as a scan.
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
    /// - **The wiring closure could call the rule with the ids inverted.**
    ///   `move(tabID: target.id, onto: draggedID)` compiles. It is one
    ///   visible call site with two labels, not a silent change behind an
    ///   intact anchor.
    /// - **Whether the gesture works at all.** No test here can see SwiftUI
    ///   begin a drag, accept a drop, or place a tab under the pointer.
    ///   That is a maintainer check in the running app.
    /// - **What `TabsViewModel.move(tabID:onto:)` does** is
    ///   `TabsViewModelTests`' subject, called directly, not scanned.
    ///
    /// What remains here are three claims about the gesture's own wiring,
    /// which no type can carry: that the drag exists exactly once, that it
    /// carries this tab's id rather than some other string, and that the
    /// drop hands both identities on rather than doing something else with
    /// them. Fail-closed: a missing anchor, unbalanced braces, an
    /// unterminated literal or an unreadable file all fail, and every
    /// message names the file, the construct and what to do about it.
    @Suite("Tab drag wiring guard")
    struct TabDragWiringGuardTests {
        private static let stripFile = TabContextMenuWiringGuardTests.sourceFile

        private static let dragSource = ".draggable("
        private static let dropTarget = ".dropDestination("
        private static let dropAnchor = ".dropDestination(for: String.self) {"

        /// The drag as the strip is allowed to spell it: the tab this view
        /// was handed, and nothing else. A complete call, so nothing can be
        /// appended to it and still match.
        private static let sanctionedDrag = ".draggable(tab.id.uuidString)"

        /// The payload question, asked rather than answered inline.
        private static let sanctionedPayloadRead = "TabDropPlan.draggedTabID(from:payload)"

        /// The drop's only outward call: the id the payload named and the
        /// tab this item draws. Also a complete call — `onReorder(draggedID,tab2)`
        /// does not contain it.
        private static let sanctionedRoute = "onReorder(draggedID,tab)"

        /// Routes out of the tab item that are not the reorder route. A
        /// drop that fires one of these is doing something it was not asked
        /// for.
        private static let foreignRoutes = ["onMenuEntry(", "onActivate(", "onClose(", "onAdd("]

        // MARK: - Extraction

        /// The body of the closure `anchor` opens — everything between its
        /// first `{` and the matching `}`. `nil` on a missing anchor or
        /// unbalanced braces rather than a guess, so every caller fails
        /// closed.
        static func body(after anchor: String, in source: String) -> String? {
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

        // MARK: - The three remaining claims

        /// One drag source, one drop target. A second of either is a second
        /// gesture path, and would also make "the drop closure" ambiguous
        /// for the claim below it.
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

        /// The drag carries the tab it is attached to. Nothing about the
        /// reordering has to change for a different payload to move the
        /// wrong tab, and the payload is the one value on this path the
        /// type system does not carry: it is a string.
        @Test func theDragCarriesTheTabItIsAttachedTo() throws {
            let source = try Self.canonicalStrip()
            #expect(source.contains(Self.sanctionedDrag), """
                the drag payload in \(Self.stripFile.path) is not \
                `\(Self.sanctionedDrag)` — a drag carrying anything else names a \
                different tab than the one under the pointer. If the payload type \
                changed deliberately, update `sanctionedDrag` in this guard to the new \
                spelling.
                """)
        }

        /// The drop reads the payload and hands both identities on. It can
        /// no longer compute anything: there is nothing numeric in scope,
        /// and the two values are of different types.
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
            for route in Self.foreignRoutes {
                #expect(!body.contains(route), """
                    the drop closure in \(Self.stripFile.path) fires `\(route)` — a drop \
                    is not that gesture. If a drop should also do that, say so where \
                    the lifecycle lives, not inside the gesture.
                    """)
            }
        }

        // MARK: - Scanner self-tests

        static let sanctionedDropSource = """
            .draggable(tab.id.uuidString)
            .dropDestination(for: String.self) { payload, _ in
                guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
                onReorder(draggedID, tab)
                return true
            }
            """

        @Test func scannerAcceptsTheSanctionedShape() throws {
            let body = try Self.dropBody(in: Self.sanctionedDropSource)
            #expect(body.contains(Self.sanctionedPayloadRead))
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: body) == 1)
            for route in Self.foreignRoutes { #expect(!body.contains(route)) }
            let canonical = try TabContextMenuWiringGuardTests
                .canonicalize(Self.sanctionedDropSource)
            #expect(canonical.contains(Self.sanctionedDrag))
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
                    onMenuEntry(.moveLeft)
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
