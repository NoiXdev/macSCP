import Foundation
import Testing

/// Guards ONE property of the tab strip's context menu in
/// `Sources/MacSCPAppKit/TabStripView.swift`: **the view does not decide
/// which entries appear.** The list it draws is whatever
/// `TabContextMenu.entries(atIndex:ofTabCount:supportsShell:isAdHoc:isConnected:)`
/// returned — no more, no fewer, in that order — and every rule about when
/// an entry is offered lives in Core, where `TabContextMenuTests` can reach
/// it.
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
/// - **V7** An extra rule folded into the ARGUMENTS (`isConnected:
///   tab.isConnected && …`, or a count that is not the strip's real count),
///   which moves the decision upstream without any `if` appearing in the
///   menu at all.
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
/// - **V7 is a literal comparison of ONE call site.** `sanctionedCall`
///   pins how the five facts are spelled where `entries(…)` is called. It
///   says nothing about what those spellings MEAN: folding a rule into the
///   computed property `isAdHoc` or `supportsShell` — where the argument
///   name at the call site never changes — passes untouched.
/// - **It reads one file.** The facts come from `SessionTab`, and
///   `SessionTab.swift` is not scanned. A doctored `isConnected` there
///   changes which entries appear with nothing in this suite to notice,
///   and the same holds for anything else the five facts are built from.
///
/// So: this catches a condition, a filter, a `.disabled`, an extra item, a
/// second menu, and a swapped iteration source, all under the names they
/// are usually written with. It does not prove the menu shows what Core
/// decided — only that the view asks Core and does not visibly argue.
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
/// braces, and a string form the stripper does not parse all count as
/// failures. Self-tested against synthetic source — one probe per violation
/// site above — so the scanner cannot pass merely because the real file
/// moved or was reformatted past recognition.
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

    private static let anchor = ".contextMenu {"
    private static let decisionCall = "TabContextMenu.entries("

    /// The one sanctioned shape of the iteration: the loop's collection IS
    /// the Core call, with nothing between them but the `Array(…)` wrapper
    /// `ForEach` needs to index a non-`Hashable` element. Checked as a
    /// PREFIX of the canonical body, so nothing can be drawn ahead of the
    /// loop either.
    private static let sanctionedIteration = "ForEach(Array(TabContextMenu.entries("

    /// The call as the view is allowed to spell it: five facts passed
    /// straight through, none of them combined with anything else, and the
    /// closing parenthesis immediately after the last one (V7). The
    /// trailing `)` is what makes this a check and not a prefix — an extra
    /// `&& …` riding along on the final argument pushes the paren away and
    /// the match is gone. Checked in canonical form, so wrapping or
    /// re-indenting the call changes nothing.
    private static let sanctionedCall =
        "TabContextMenu.entries(atIndex:index,ofTabCount:tabCount,supportsShell:supportsShell,"
        + "isAdHoc:isAdHoc,isConnected:tab.isConnected)"

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
            expected exactly 1 `\(Self.anchor)` in TabStripView.swift, found \(count) — \
            either a second menu was attached (its entries decided by nothing), or \
            this guard needs re-anchoring.
            """)
    }

    /// V6: exactly one call to the Core decision in the whole file, so a
    /// second one cannot sit somewhere decorative while the loop walks
    /// something else.
    @Test func theCoreDecisionIsCalledExactlyOnceInTheFile() throws {
        let source = try Self.stripped(String(contentsOf: Self.sourceFile, encoding: .utf8))
        let count = Self.occurrences(of: Self.decisionCall, in: source)
        #expect(count == 1, """
            expected exactly 1 `\(Self.decisionCall)` in TabStripView.swift, found \(count) \
            (comments and string literals already stripped, so prose naming the call \
            does not count).
            """)
    }

    /// V6 and V4 together: the menu body IS the loop over the Core answer,
    /// from its very first character — so nothing is drawn ahead of the
    /// loop and the loop's collection is not something else.
    @Test func theMenuIteratesTheCoreDecisionAndNothingElse() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let menu = try Self.menu(in: source)
        #expect(menu.canonical.hasPrefix(Self.sanctionedIteration), """
            the context menu's body does not begin with `\(Self.sanctionedIteration)` — \
            it begins with `\(menu.canonical.prefix(80))…` instead. Either something is \
            drawn before the loop, or the loop walks something other than \
            `TabContextMenu.entries(…)`.
            """)
    }

    /// V7: the five facts go in as themselves. A rule folded into an
    /// argument moves the decision out of Core without any branch appearing
    /// in the menu.
    @Test func theDecisionIsAskedWithTheRealFactsOnly() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let menu = try Self.menu(in: source)
        #expect(menu.canonical.contains(Self.sanctionedCall), """
            the arguments handed to `TabContextMenu.entries(…)` are not the five facts \
            passed straight through — expected `\(Self.sanctionedCall)` in the \
            canonical body.
            """)
    }

    /// V4: one item per entry, and no other kind of item beside it.
    @Test func theMenuDrawsExactlyOneItemPerEntry() throws {
        let source = try String(contentsOf: Self.sourceFile, encoding: .utf8)
        let menu = try Self.menu(in: source)
        let buttons = Self.occurrences(of: "Button(", in: menu.canonical)
        #expect(buttons == 1, """
            expected exactly 1 `Button(` in the context menu's body (one item per entry, \
            drawn by the loop), found \(buttons).
            """)
        for spelling in Self.foreignItemSpellings {
            #expect(!menu.canonical.contains(spelling), """
                the context menu's body draws a `\(spelling)` beside the loop — that item \
                corresponds to no `TabMenuEntry` and nothing decided it.
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
            the context menu's body contains \(found) — the view is deciding for itself \
            which entries appear (or which are usable), which is \
            `TabContextMenu.entries(…)`'s job and is tested there.
            """)
        for op in Self.forbiddenOperators {
            #expect(!menu.canonical.contains(op), """
                the context menu's body contains `\(op)` — a condition without a keyword \
                is still a condition.
                """)
        }
    }

    /// V7's other half, one level up: the strip must hand each item its
    /// REAL position and the REAL total, or the move and bulk-close entries
    /// are decided from fiction.
    @Test func theStripPassesTheRealPositionAndCount() throws {
        let source = try Self.canonicalize(String(contentsOf: Self.sourceFile, encoding: .utf8))
        let position = Self.occurrences(of: "index:position", in: source)
        let count = Self.occurrences(of: "tabCount:tabs.count", in: source)
        #expect(position == 1, """
            expected exactly 1 `index: position` (the enumerated offset) in \
            TabStripView.swift, found \(position).
            """)
        #expect(count == 1, """
            expected exactly 1 `tabCount: tabs.count` in TabStripView.swift, found \(count).
            """)
    }

    // MARK: - Scanner self-tests: one probe per violation site

    /// The shape the real file has — the scanner must accept it, or every
    /// negative probe below proves nothing.
    private static let sanctionedSource = """
        .contextMenu {
            ForEach(Array(TabContextMenu.entries(
                atIndex: index, ofTabCount: tabCount,
                supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
            ).enumerated()), id: \\.offset) { _, entry in
                Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
            }
        }
        """

    @Test func scannerAcceptsTheSanctionedShape() throws {
        let menu = try Self.menu(in: Self.sanctionedSource)
        #expect(menu.canonical.hasPrefix(Self.sanctionedIteration))
        #expect(menu.canonical.contains(Self.sanctionedCall))
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
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
                ).enumerated()), id: \\.offset) { _, entry in
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
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
                ).filter { $0 != .closeOthers }.enumerated()), id: \\.offset) { _, entry in
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
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
                ).enumerated()), id: \\.offset) { _, entry in
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
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
                ).enumerated()), id: \\.offset) { _, entry in
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
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: tab.isConnected
                ).enumerated()), id: \\.offset) { _, entry in
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
        #expect(Self.occurrences(of: Self.decisionCall, in: menu.canonical) == 0)
    }

    /// V7: the fact is real, the argument is not — an extra rule rides in
    /// on `&&` with no branch anywhere in the body.
    @Test func scannerFlagsARuleFoldedIntoAnArgument() throws {
        let source = """
            .contextMenu {
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc,
                    isConnected: tab.isConnected && !tab.transferQueue.isActive
                ).enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(!menu.canonical.contains(Self.sanctionedCall))
        #expect(menu.canonical.contains("&&"))
    }

    /// V7 in its quieter form: no operator anywhere, the fact simply
    /// replaced by something else. The operator scan cannot see this one;
    /// the call-shape check is what catches it.
    @Test func scannerFlagsASubstitutedFact() throws {
        let source = """
            .contextMenu {
                ForEach(Array(TabContextMenu.entries(
                    atIndex: index, ofTabCount: tabCount,
                    supportsShell: supportsShell, isAdHoc: isAdHoc, isConnected: false
                ).enumerated()), id: \\.offset) { _, entry in
                    Button(TabMenuEntryTitle.title(for: entry)) { onMenuEntry(entry) }
                }
            }
            """
        let menu = try Self.menu(in: source)
        #expect(!menu.canonical.contains(Self.sanctionedCall))
        for op in Self.forbiddenOperators {
            #expect(!menu.canonical.contains(op))
        }
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

    /// A raw-string delimiter is a form this stripper does not parse; left
    /// unhandled it desynchronizes the plain-quote counting and can hide
    /// everything past that point. It must throw instead.
    @Test func stripperFailsClosedOnARawStringDelimiter() {
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("static let quote = #\"\"\"#\nif entry == .close {}")
        }
    }

    @Test func stripperFailsClosedOnAnUnterminatedLiteral() {
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("/* never closes")
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
    /// Fails closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse, and an unterminated string or comment means
    /// it ran off the end without finding what it was looking for. Both
    /// throw rather than return whatever was collected so far.
    private enum StripError: Error, CustomStringConvertible {
        case unrecognizedDelimiter
        case unterminatedLiteral

        var description: String {
            switch self {
            case .unrecognizedDelimiter:
                return """
                    unrecognized string delimiter (a raw string's `#"`, `##"`, …) — this \
                    stripper does not parse raw strings and refuses to guess where one ends
                    """
            case .unterminatedLiteral:
                return "unterminated string or comment literal"
            }
        }
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
                if j < chars.count, chars[j] == "\"" {
                    throw StripError.unrecognizedDelimiter
                }
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
}
