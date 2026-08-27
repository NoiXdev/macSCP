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

    // MARK: - The drag half of the same feature

    /// Guards ONE property, in two halves: **the order the user sees is
    /// `TabsViewModel.tabs`' order, and `move(tabID:to:)` is the only thing
    /// that changes it.** The drag reaches that rule and reorders nothing
    /// itself (D-sites); and no second ordering is applied to the tabs on
    /// their way to the screen (W-sites).
    ///
    /// The context menu's move entries and a dropped tab are two ways to
    /// one rule, which is the whole point of building them together — built
    /// apart, the reordering exists twice, and that is precisely what the
    /// backlog entry behind this feature warns about. A guard that watched
    /// only the drop closure would not be guarding that sentence: it is
    /// just as easy to write a second ordering where the strip is FED as
    /// where it is dragged. Fix round 1 was that hole, found by review, and
    /// the W-sites are what closed it.
    ///
    /// Nested inside the menu guard rather than started as its own file: it
    /// watches the same view file and reads the same source with the same
    /// stripper, and a second copy of that stripper has drifted from its
    /// sibling before. The menu guard keeps its own claim, unchanged and
    /// unwidened — this one makes a different claim about different lines,
    /// and states its own limits.
    ///
    /// **Where the property could be violated FROM.** Enumerated before any
    /// check was written, from the ways a reordering can appear in a view
    /// layer at all — not from the lines that ended up in the diff:
    ///
    /// - **D1** The drop rearranges a collection in the view itself
    ///   (`remove`/`insert`/`swapAt`/`sort`/`reverse` on the tabs), a
    ///   second reordering with the real one nowhere in sight.
    /// - **D2** SwiftUI's own reordering is adopted instead — `.onMove` on
    ///   a `ForEach`, which mutates a collection through a binding and
    ///   never passes through Core.
    /// - **D3** The drop routes out through something other than the one
    ///   reorder route: a second closure on the strip, or the existing
    ///   `onMenuEntry` fired with `.moveLeft`/`.moveRight` repeatedly, which
    ///   is a step-by-step reordering written in a gesture handler.
    /// - **D4** The view computes the destination itself — arithmetic on
    ///   the index, or drop-point geometry — so the position rule lives
    ///   where nothing can call it.
    /// - **D5** The handler stops calling `TabsViewModel.move`: it reaches
    ///   into `tabsModel.tabs`, or a second move-like helper joins
    ///   `moveTab(_:by:)` and `reorderTab(_:toDropPosition:)`.
    /// - **D6** The clamp disappears and a raw drop position is forwarded.
    ///   `move(tabID:to:)` answers an out-of-range destination with silence
    ///   by design, so this one does not look like a bug from inside the
    ///   model — it looks like a drag that did nothing.
    /// - **D7** A SECOND drag source or drop target in the strip file, so
    ///   the file carries a reorder path nothing here checked.
    /// - **D8** The drag payload stops naming the tab it is attached to
    ///   (the active tab's id, an index, a title), which moves the wrong
    ///   tab without a single line of reordering logic changing.
    ///
    /// **And where the SECOND half — no other ordering touches the tabs —
    /// could be violated FROM.** Enumerated the same way, in fix round 1,
    /// from the places a tab collection is handled between the model and
    /// the screen rather than from the two probes the review supplied:
    ///
    /// - **W1** The strip is FED a different order: `tabs:
    ///   tabsModel.tabs.sorted { … }`, or a computed `orderedTabs` standing
    ///   in for the model's own array, where the strip is constructed.
    /// - **W2** The strip RENDERS a different order: the loop walks
    ///   `tabs.reversed()`, `tabs.sorted(…)`, a filtered copy.
    /// - **W3** A rearranging call applied to `tabsModel.tabs` anywhere in
    ///   the app layer, whose result is then shown or fed back — including
    ///   in files neither the strip nor the handler.
    /// - **W4** The position is rewritten on its way to the reorder route,
    ///   outside the drop closure: `onReorder: { id, _ in onReorder(id, 0) }`
    ///   where the item is constructed, or the closure property turned into
    ///   a computed wrapper. Every token the checks look for stays present
    ///   and correctly spelled, and every tab jumps to the same position.
    /// - **W5** A THIRD call to the one rule, in a file this guard never
    ///   read — a reordering that is reached from somewhere nothing here
    ///   describes.
    /// - **W6** A SECOND `TabStripView(…)`, fed something else entirely, so
    ///   the checked construction site is no longer the one on screen.
    ///
    /// **What this guard does NOT catch**, stated so a green run is not
    /// read as more than it is — and re-measured in fix round 1, because a
    /// widened guard with an unchanged limits section is the same defect as
    /// a narrow one with a boast:
    ///
    /// - **That the gesture works at all.** No test in this project can see
    ///   SwiftUI begin a drag, accept a drop, or place the tab where the
    ///   pointer was. That is a maintainer check in the running app.
    /// - **The rearrangement vocabulary is a blocklist, not a rule** — the
    ///   same limit the menu guard documents for its own token list.
    ///   `applying(_:)`, a swap written as two subscript assignments, or a
    ///   helper with an innocent name all walk past it. W1, W2 and W6 do
    ///   not depend on it (they pin the hand-off verbatim, so ANY other
    ///   spelling fails); W3 does.
    /// - **W3 recognizes a rearranging call applied DIRECTLY to
    ///   `tabsModel.tabs`.** Copy the array into a local first, or reach it
    ///   through another name for the model, and the scan sees nothing.
    /// - **The token scan of a whole file is run on the strip only.** The
    ///   handler and wiring files legitimately rearrange other collections,
    ///   so they are checked by shape and by W3, not by vocabulary.
    /// - **`TabsViewModel` itself is not scanned.** A second ordering
    ///   written inside Core — an `orderedTabs` beside `tabs` — is
    ///   invisible here. It is also the one place where a test can call it
    ///   directly, which is `TabsViewModelTests`' subject.
    /// - **It checks that the clamp is ASKED FOR, never that it is right.**
    ///   A `TabDropPlan.destination` rewritten to return the raw index
    ///   passes every check here and fails in `TabDropPlanTests`.
    ///
    /// Fail-closed throughout: an unreadable file, a missing anchor,
    /// unbalanced braces, a string form the stripper does not parse, and a
    /// source tree the scan finds no Swift files in all count as failures.
    /// Renaming `onReorder` or `reorderTab(_:toDropPosition:)` leaves an
    /// anchor missing, which is reported as "re-anchor this guard" rather
    /// than passing quietly. Self-tested against synthetic source, one
    /// probe per violation site.
    @Suite("Tab drag wiring guard")
    struct TabDragWiringGuardTests {
        private static let stripFile = TabContextMenuWiringGuardTests.sourceFile
        private static let handlerFile = TabContextMenuWiringGuardTests.repoRoot
            .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        private static let wiringFile = TabContextMenuWiringGuardTests.repoRoot
            .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

        /// Every Swift file of the app layer, for the checks that are about
        /// the app layer rather than about one file (W3, W5, W6).
        private static let appSources = TabContextMenuWiringGuardTests.repoRoot
            .appendingPathComponent("Sources")

        private static let dragSource = ".draggable("
        private static let dropAnchor = ".dropDestination(for: String.self) {"
        private static let handlerAnchor = "func reorderTab("

        /// Receiver-agnostic on purpose (fix round 1, F3): the claim is
        /// about the app layer, so a call through any other name for the
        /// model must count too. Core's own `func move(tabID:` has no
        /// leading dot and is not a call.
        private static let reorderingRule = ".move(tabID:"

        /// The drag as the strip is allowed to spell it: the tab this view
        /// was handed, and nothing else (D8).
        private static let sanctionedDrag = ".draggable(tab.id.uuidString)"

        /// The drop's only outward call: the tab the payload named, and
        /// THIS item's own position — no arithmetic, no geometry, no second
        /// route (D3, D4).
        private static let sanctionedRoute = "onReorder(draggedID,index)"

        /// The payload question asked rather than answered inline (D4).
        private static let sanctionedPayloadRead = "TabDropPlan.draggedTabID(from:payload)"

        /// The clamp, against the tabs that exist at the moment of the drop
        /// rather than the count the strip was rendered with (D6).
        private static let sanctionedClamp =
            "TabDropPlan.destination(forDropOnIndex:position,tabCount:tabsModel.tabs.count)"

        /// The one reordering rule, called with what the clamp answered
        /// (D5).
        private static let sanctionedMove = "tabsModel.move(tabID:tabID,to:destination)"

        /// The strip's reorder route wired to the drop handler (D5, one
        /// level up).
        private static let sanctionedWiring = "reorderTab(tabID,toDropPosition:position)"

        /// The model's own array handed to the strip as itself (W1).
        private static let sanctionedFeed = "tabs:tabsModel.tabs"

        /// The strip rendering the tabs it was handed, in the order it was
        /// handed them (W2).
        private static let sanctionedRender = #"ForEach(Array(tabs.enumerated()),id:\.element.id)"#

        /// The reorder closure handed to the item as itself, with no
        /// position rewritten on the way (W4).
        private static let sanctionedHandOff = "onReorder:onReorder"

        /// Both ends of that hand-off as STORED properties — a computed one
        /// could wrap the closure without changing the hand-off (W4).
        /// Counted while writing this check: the strip declares one and the
        /// item declares one.
        private static let reorderProperty = "letonReorder:(UUID,Int)->Void"

        /// The construction site of the strip itself (W6).
        private static let stripConstruction = "TabStripView("

        /// The model's tab array as the app layer spells it (W3).
        private static let tabsExpression = "tabsModel.tabs"

        /// Identifier-boundary tokens that rearrange a collection, plus
        /// SwiftUI's own reordering (D1, D2). Matched as whole tokens, so
        /// `autoreverses` and `moveLeft` are untouched.
        ///
        /// A BLOCKLIST, and therefore not a rule — see this suite's doc
        /// comment. It names the spellings a reordering is normally written
        /// with; it cannot name every way a collection can be rearranged,
        /// and growing it would only make the claim sound larger.
        private static let rearrangementTokens: Set<String> = [
            "remove", "removeAll", "removeFirst", "removeLast", "insert", "append",
            "swapAt", "sort", "sorted", "reverse", "reversed", "shuffle", "shuffled",
            "partition", "onMove", "moveDisabled", "move",
        ]

        /// Routes out of the tab item that are not the reorder route. A
        /// drop that fires one of these is doing something the strip's
        /// reorder closure was not asked for (D3).
        private static let foreignRoutes = ["onMenuEntry(", "onActivate(", "onClose(", "onAdd("]

        /// Operators that would mean the view computed the destination
        /// rather than passing its own position (D4).
        private static let arithmeticOperators = ["+", "-", "*", "/", "%"]

        // MARK: - Extraction

        /// The body of the closure or function that `anchor` opens —
        /// everything between the first `{` at or after the anchor and its
        /// matching `}`. `nil` on a missing anchor or unbalanced braces
        /// rather than a guess, so every caller fails closed.
        ///
        /// Separate from the menu suite's own extractor because that one is
        /// bound to its single anchor; the brace walk is the same walk.
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

        /// Everything a check needs about one extracted body, in one call,
        /// so the synthetic probes below exercise the same steps the
        /// real-file checks do. `#require` on the extraction: a missing
        /// anchor and unbalanced braces both leave nothing to scan, and
        /// reporting that as a failed content assertion would name the
        /// wrong cause.
        static func scan(
            _ anchor: String, in source: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> (canonical: String, tokens: Set<String>) {
            let body = try #require(
                Self.body(after: anchor, in: source),
                """
                no `\(anchor)` body could be extracted from this source — the anchor is \
                missing or its braces are unbalanced, so the scanner has nothing to \
                check. Re-anchor this guard.
                """,
                sourceLocation: sourceLocation)
            return (
                try TabContextMenuWiringGuardTests.canonicalize(body),
                TabContextMenuWiringGuardTests.identifierTokens(
                    in: try TabContextMenuWiringGuardTests.stripped(body))
            )
        }

        private static func stripped(_ file: URL) throws -> String {
            try TabContextMenuWiringGuardTests.stripped(String(contentsOf: file, encoding: .utf8))
        }

        private static func canonical(_ file: URL) throws -> String {
            try TabContextMenuWiringGuardTests.canonicalize(
                String(contentsOf: file, encoding: .utf8))
        }

        private static func occurrences(of needle: String, in haystack: String) -> Int {
            TabContextMenuWiringGuardTests.occurrences(of: needle, in: haystack)
        }

        /// Every `.swift` file of the app layer. Fail-closed at the call
        /// site: a scan that found nothing to read would report every
        /// app-layer claim as satisfied.
        static func appSourceFiles() -> [URL] {
            let enumerator = FileManager.default.enumerator(
                at: appSources, includingPropertiesForKeys: nil)
            let all = enumerator?.allObjects as? [URL] ?? []
            return all.filter { $0.pathExtension == "swift" }
        }

        /// The member call applied DIRECTLY to each occurrence of
        /// `expression` — the identifier right after the dot that follows
        /// it, once per occurrence that has one.
        ///
        /// This is what turns a token blocklist into something closer to a
        /// rule for W3: it does not ask whether a file contains the word
        /// `sorted`, it asks what is being applied to the tabs. A prefix
        /// match with no dot after it (`tabsModel.tabsToClose`) yields
        /// nothing, and neither does a subscript or an argument separator.
        static func membersApplied(to expression: String, in canonical: String) -> [String] {
            var members: [String] = []
            var search = canonical.startIndex
            while let range = canonical.range(
                of: expression, range: search..<canonical.endIndex)
            {
                search = range.upperBound
                var index = range.upperBound
                guard index < canonical.endIndex, canonical[index] == "." else { continue }
                index = canonical.index(after: index)
                var identifier = ""
                while index < canonical.endIndex,
                    canonical[index].isLetter || canonical[index].isNumber
                        || canonical[index] == "_"
                {
                    identifier.append(canonical[index])
                    index = canonical.index(after: index)
                }
                if !identifier.isEmpty { members.append(identifier) }
            }
            return members
        }

        // MARK: - The guarded claims, run against the real files

        /// D1, D2: the strip file rearranges nothing. Not the drop closure
        /// alone — the whole file, because a reordering hidden in a private
        /// helper further down would be just as much a second rule.
        @Test func theStripFileRearrangesNoCollectionOfItsOwn() throws {
            let source = try Self.stripped(Self.stripFile)
            let tokens = TabContextMenuWiringGuardTests.identifierTokens(in: source)
            let found = Self.rearrangementTokens.intersection(tokens).sorted()
            #expect(found.isEmpty, """
                TabStripView.swift contains \(found) — the strip is rearranging tabs \
                itself. Reordering is `TabsViewModel.move(tabID:to:)`'s job, the same \
                one the context menu's move entries reach, and it exists once.
                """)
        }

        /// D7: one drag source, one drop target. A second of either would
        /// mean a reorder path this suite never looked at, and would also
        /// make "the drop closure" ambiguous for every check below.
        @Test func theDragAndTheDropAreAttachedExactlyOnceEach() throws {
            let source = try Self.stripped(Self.stripFile)
            let drags = Self.occurrences(of: Self.dragSource, in: source)
            let drops = Self.occurrences(of: ".dropDestination(", in: source)
            #expect(drags == 1, """
                expected exactly 1 `\(Self.dragSource)` in TabStripView.swift, found \(drags) — \
                either a second drag source was added, or this guard needs re-anchoring.
                """)
            #expect(drops == 1, """
                expected exactly 1 `.dropDestination(` in TabStripView.swift, found \(drops) — \
                either a second drop target was added, or this guard needs re-anchoring.
                """)
        }

        /// D8: the drag carries the tab it is attached to. Nothing about
        /// the reordering has to change for this to move the wrong tab.
        @Test func theDragCarriesTheTabItIsAttachedTo() throws {
            let source = try Self.canonical(Self.stripFile)
            #expect(source.contains(Self.sanctionedDrag), """
                the strip's drag payload is not `\(Self.sanctionedDrag)` — a drag that \
                carries anything else names a different tab than the one under the \
                pointer, and every reordering check below would still pass.
                """)
        }

        /// D3, D4: the drop reads the payload, hands over the tab and this
        /// item's own position, and decides nothing else.
        @Test func theDropRoutesOutThroughTheReorderClosureOnly() throws {
            let source = try String(contentsOf: Self.stripFile, encoding: .utf8)
            let drop = try Self.scan(Self.dropAnchor, in: source)
            #expect(drop.canonical.contains(Self.sanctionedPayloadRead), """
                the drop closure does not ask `\(Self.sanctionedPayloadRead)` — the payload \
                is being read some other way, in a closure no test can call.
                """)
            let routes = Self.occurrences(of: Self.sanctionedRoute, in: drop.canonical)
            #expect(routes == 1, """
                expected exactly 1 `\(Self.sanctionedRoute)` in the drop closure, found \
                \(routes) — the drop either reorders through something other than the \
                strip's one reorder route, or hands over a position it computed itself.
                """)
            for route in Self.foreignRoutes {
                #expect(!drop.canonical.contains(route), """
                    the drop closure fires `\(route)` — a drop is not that gesture, and a \
                    reordering assembled out of menu entries is a second reordering.
                    """)
            }
            for op in Self.arithmeticOperators {
                #expect(!drop.canonical.contains(op), """
                    the drop closure contains `\(op)` — the position it hands over is \
                    computed rather than its own, which puts a placement rule where \
                    nothing can call it.
                    """)
            }
        }

        /// D1, D2 inside the drop specifically: the closure that receives
        /// the gesture is the likeliest place for a hand-rolled reordering,
        /// so it is checked on its own as well as inside the file scan.
        @Test func theDropClosureRearrangesNothing() throws {
            let source = try String(contentsOf: Self.stripFile, encoding: .utf8)
            let drop = try Self.scan(Self.dropAnchor, in: source)
            let found = Self.rearrangementTokens.intersection(drop.tokens).sorted()
            #expect(found.isEmpty, """
                the drop closure contains \(found) — it is reordering rather than routing.
                """)
        }

        /// D5, D6: the handler clamps, then calls the one rule. Both halves
        /// in one test, because either without the other is a broken drop:
        /// no clamp means a stale position silently does nothing, and no
        /// `move` means the reordering happened somewhere else.
        @Test func theDropHandlerClampsAndThenCallsTheOneReorderingRule() throws {
            let source = try String(contentsOf: Self.handlerFile, encoding: .utf8)
            let handler = try Self.scan(Self.handlerAnchor, in: source)
            #expect(handler.canonical.contains(Self.sanctionedClamp), """
                the drop handler does not clamp through `\(Self.sanctionedClamp)` — \
                `move(tabID:to:)` refuses an out-of-range destination as a no-op, so a \
                raw drop position produces a drag that silently does nothing.
                """)
            #expect(handler.canonical.contains(Self.sanctionedMove), """
                the drop handler does not call `\(Self.sanctionedMove)` — the drag is \
                reordering through something other than the one rule the context menu \
                also uses.
                """)
            let moves = Self.occurrences(of: "move(", in: handler.canonical)
            #expect(moves == 1, """
                expected exactly 1 `move(` in the drop handler, found \(moves) — a second \
                move call in the same handler is a second answer to where the tab goes.
                """)
        }

        /// D5 and W5 together, and now over the whole app layer rather than
        /// over one file — the name promised that and the scan did not
        /// (fix round 1, F3). Counted while writing this check, over every
        /// Swift file under `Sources/`: two calls, the context menu's
        /// `moveTab(_:by:)` and the drop's `reorderTab(_:toDropPosition:)`,
        /// both in `ContentView+Lifecycle.swift`. A third call site
        /// anywhere is a third way to reorder, and this guard wants to be
        /// told about it.
        @Test func theAppLayerReachesTheReorderingRuleFromTwoPlaces() throws {
            let files = Self.appSourceFiles()
            try #require(!files.isEmpty, """
                no Swift files were found under Sources/ — the app-layer scans would \
                pass by reading nothing. Re-anchor this guard.
                """)
            var perFile: [String: Int] = [:]
            for file in files {
                let calls = Self.occurrences(
                    of: Self.reorderingRule,
                    in: try TabContextMenuWiringGuardTests.stripped(
                        String(contentsOf: file, encoding: .utf8)))
                if calls > 0 { perFile[file.lastPathComponent] = calls }
            }
            let total = perFile.values.reduce(0, +)
            #expect(total == 2, """
                expected exactly 2 `\(Self.reorderingRule)` calls in the app layer (the \
                menu's move entries and the drop), found \(total) — \
                \(perFile.sorted { $0.key < $1.key }).
                """)
            #expect(perFile == ["ContentView+Lifecycle.swift": 2], """
                the app layer's reordering calls are not both in \
                ContentView+Lifecycle.swift — found \(perFile.sorted { $0.key < $1.key }). \
                A reordering reached from another file is a path this guard does not \
                describe.
                """)
        }

        // MARK: - The second half: nothing else orders the tabs

        /// W1: the strip is fed the model's own array, as itself. Two
        /// spellings of a second ordering are refused here by two different
        /// means — a different source (`orderedTabs`) makes the hand-off
        /// disappear, and a rearranging call ON the hand-off shows up as a
        /// member applied to it. The second means is the general one and is
        /// checked over the whole app layer as well.
        @Test func theStripIsFedTheModelsOwnOrder() throws {
            let source = try Self.canonical(Self.wiringFile)
            let feeds = Self.occurrences(of: Self.sanctionedFeed, in: source)
            #expect(feeds == 1, """
                expected exactly 1 `\(Self.sanctionedFeed)` in ContentView+Detail.swift, \
                found \(feeds) — the strip is being fed something other than the model's \
                tabs, which is a second ordering wherever it was produced.
                """)
            let members = Self.membersApplied(to: Self.sanctionedFeed, in: source)
            let rearranged = Self.rearrangementTokens.intersection(members).sorted()
            #expect(rearranged.isEmpty, """
                the tabs handed to the strip have \(rearranged) applied to them — the \
                order on screen is then not the order `TabsViewModel.move` produced.
                """)
        }

        /// W6: exactly one strip, so the construction site checked above is
        /// the one on screen.
        @Test func theStripIsConstructedExactlyOnceInTheAppLayer() throws {
            let files = Self.appSourceFiles()
            try #require(!files.isEmpty)
            var total = 0
            for file in files {
                total += Self.occurrences(
                    of: Self.stripConstruction,
                    in: try TabContextMenuWiringGuardTests.stripped(
                        String(contentsOf: file, encoding: .utf8)))
            }
            #expect(total == 1, """
                expected exactly 1 `\(Self.stripConstruction)` construction in the app \
                layer, found \(total) — a second strip is fed by something this guard \
                never looked at.
                """)
        }

        /// W2: the strip renders the tabs it was handed, in the order it
        /// was handed them. Pinned verbatim rather than by vocabulary, so
        /// `reversed()`, `sorted(by:)` and any other spelling fail alike.
        @Test func theStripRendersTheOrderItWasHanded() throws {
            let source = try Self.canonical(Self.stripFile)
            let renders = Self.occurrences(of: Self.sanctionedRender, in: source)
            #expect(renders == 1, """
                expected exactly 1 `\(Self.sanctionedRender)` in TabStripView.swift, \
                found \(renders) — the strip is iterating something other than the tabs \
                it was handed, in the order it was handed them.
                """)
        }

        /// W3: no rearranging call is applied to the model's tabs anywhere
        /// in the app layer. This is the check the review's second probe
        /// got past, and the one that makes "the reordering exists once" a
        /// claim about the app layer rather than about one file.
        @Test func nothingInTheAppLayerRearrangesTheModelsTabs() throws {
            let files = Self.appSourceFiles()
            try #require(!files.isEmpty, """
                no Swift files were found under Sources/ — this scan would pass by \
                reading nothing. Re-anchor this guard.
                """)
            try #require(files.contains { $0.lastPathComponent == "TabStripView.swift" }, """
                the strip file is not among the scanned app-layer sources — the scan is \
                looking somewhere else than it thinks. Re-anchor this guard.
                """)
            for file in files {
                let canonical = try TabContextMenuWiringGuardTests.canonicalize(
                    String(contentsOf: file, encoding: .utf8))
                let members = Self.membersApplied(to: Self.tabsExpression, in: canonical)
                let rearranged = Self.rearrangementTokens.intersection(members).sorted()
                #expect(rearranged.isEmpty, """
                    \(file.lastPathComponent) applies \(rearranged) to \
                    `\(Self.tabsExpression)` — a second ordering of the tabs, which is \
                    exactly what building the menu and the drag together was meant to \
                    prevent.
                    """)
            }
        }

        /// W4: the reorder closure reaches the item as itself. A wrapper
        /// here — `onReorder: { id, _ in onReorder(id, 0) }` — leaves every
        /// token the other checks look for present and correctly spelled,
        /// and sends every dragged tab to the same position (fix round 1,
        /// F1).
        @Test func theReorderRouteReachesTheItemUnwrapped() throws {
            let source = try Self.canonical(Self.stripFile)
            let handOffs = Self.occurrences(of: Self.sanctionedHandOff, in: source)
            #expect(handOffs == 1, """
                expected exactly 1 `\(Self.sanctionedHandOff)` in TabStripView.swift, \
                found \(handOffs) — the strip is wrapping the reorder route instead of \
                handing it on, which can rewrite the position outside the drop closure.
                """)
            let properties = Self.occurrences(of: Self.reorderProperty, in: source)
            #expect(properties == 2, """
                expected exactly 2 stored `\(Self.reorderProperty)` properties in \
                TabStripView.swift (the strip's and the item's), found \(properties) — a \
                computed one could wrap the closure with the hand-off left intact.
                """)
        }

        /// D5, one level up: the strip's reorder route reaches the handler
        /// that clamps and calls the rule, and there is one such route.
        @Test func theStripsReorderRouteIsWiredToTheDropHandler() throws {
            let source = try Self.canonical(Self.wiringFile)
            let routes = Self.occurrences(of: "onReorder:", in: source)
            #expect(routes == 1, """
                expected exactly 1 `onReorder:` argument in ContentView+Detail.swift, \
                found \(routes).
                """)
            #expect(source.contains(Self.sanctionedWiring), """
                the strip's `onReorder` is not wired to `\(Self.sanctionedWiring)` — the \
                drop is being answered by something other than the clamping handler.
                """)
        }

        // MARK: - Scanner self-tests: one probe per violation site

        /// The shape the real files have — the scanner must accept it, or
        /// every negative probe below proves nothing.
        static let sanctionedDropSource = """
            .draggable(tab.id.uuidString)
            .dropDestination(for: String.self) { payload, _ in
                guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
                onReorder(draggedID, index)
                return true
            }
            """

        static let sanctionedHandlerSource = """
            func reorderTab(_ tabID: UUID, toDropPosition position: Int) {
                guard let destination = TabDropPlan.destination(
                    forDropOnIndex: position, tabCount: tabsModel.tabs.count)
                else { return }
                tabsModel.move(tabID: tabID, to: destination)
            }
            """

        @Test func scannerAcceptsTheSanctionedShapes() throws {
            let drop = try Self.scan(Self.dropAnchor, in: Self.sanctionedDropSource)
            #expect(drop.canonical.contains(Self.sanctionedPayloadRead))
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: drop.canonical) == 1)
            #expect(Self.rearrangementTokens.intersection(drop.tokens).isEmpty)
            for op in Self.arithmeticOperators { #expect(!drop.canonical.contains(op)) }
            for route in Self.foreignRoutes { #expect(!drop.canonical.contains(route)) }

            let handler = try Self.scan(Self.handlerAnchor, in: Self.sanctionedHandlerSource)
            #expect(handler.canonical.contains(Self.sanctionedClamp))
            #expect(handler.canonical.contains(Self.sanctionedMove))
            #expect(Self.occurrences(of: "move(", in: handler.canonical) == 1)

            let canonicalDrop = try TabContextMenuWiringGuardTests
                .canonicalize(Self.sanctionedDropSource)
            #expect(canonicalDrop.contains(Self.sanctionedDrag))
        }

        /// D1: the drop rearranges the tabs itself, with the real rule named
        /// only in a comment — the evasion that has defeated guards on
        /// earlier branches.
        @Test func scannerFlagsAReorderingWrittenIntoTheDrop() throws {
            let source = """
                .dropDestination(for: String.self) { payload, _ in
                    // same order TabsViewModel.move would produce
                    guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
                    var reordered = tabs
                    let from = reordered.firstIndex { $0.id == draggedID }
                    reordered.insert(reordered.remove(at: from!), at: index)
                    onReorder(draggedID, index)
                    return true
                }
                """
            let drop = try Self.scan(Self.dropAnchor, in: source)
            #expect(Self.rearrangementTokens.intersection(drop.tokens) == ["insert", "remove"])
        }

        /// D2: SwiftUI's own reordering adopted in the strip file, which
        /// mutates a binding and never reaches Core.
        @Test func scannerFlagsSwiftUIsOwnMoveHandler() throws {
            let source = try TabContextMenuWiringGuardTests.stripped("""
                ForEach(tabs) { tab in TabItemView(tab: tab) }
                    .onMove { offsets, destination in orderedTabs.move(fromOffsets: offsets, toOffset: destination) }
                """)
            let tokens = TabContextMenuWiringGuardTests.identifierTokens(in: source)
            #expect(Self.rearrangementTokens.intersection(tokens) == ["move", "onMove"])
        }

        /// D3: the drop reorders by firing menu entries — a step-by-step
        /// reordering written into a gesture handler, with no rearrangement
        /// vocabulary anywhere for the token scan to see.
        @Test func scannerFlagsADropRoutedThroughTheMenu() throws {
            let source = """
                .dropDestination(for: String.self) { payload, _ in
                    guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
                    onMenuEntry(.moveLeft)
                    return true
                }
                """
            let drop = try Self.scan(Self.dropAnchor, in: source)
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: drop.canonical) == 0)
            #expect(drop.canonical.contains("onMenuEntry("))
        }

        /// D4: the position is the view's own arithmetic, not the position
        /// it was rendered at.
        @Test func scannerFlagsADestinationComputedInTheView() throws {
            let source = """
                .dropDestination(for: String.self) { payload, _ in
                    guard let draggedID = TabDropPlan.draggedTabID(from: payload) else { return false }
                    onReorder(draggedID, index + 1)
                    return true
                }
                """
            let drop = try Self.scan(Self.dropAnchor, in: source)
            #expect(Self.occurrences(of: Self.sanctionedRoute, in: drop.canonical) == 0)
            #expect(drop.canonical.contains("+"))
        }

        /// D5: the handler reorders the model's array directly, so the one
        /// rule is bypassed while the call site still looks like a handler.
        @Test func scannerFlagsAHandlerThatBypassesTheRule() throws {
            let source = """
                func reorderTab(_ tabID: UUID, toDropPosition position: Int) {
                    guard let from = tabsModel.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                    tabsModel.tabs.insert(tabsModel.tabs.remove(at: from), at: position)
                }
                """
            let handler = try Self.scan(Self.handlerAnchor, in: source)
            #expect(!handler.canonical.contains(Self.sanctionedMove))
            #expect(Self.rearrangementTokens.intersection(handler.tokens) == ["insert", "remove"])
        }

        /// D6: the clamp is gone and the raw drop position goes straight to
        /// a rule that answers out-of-range with silence. Nothing here
        /// looks wrong; the drag simply stops working at the edges.
        @Test func scannerFlagsAnUnclampedDestination() throws {
            let source = """
                func reorderTab(_ tabID: UUID, toDropPosition position: Int) {
                    tabsModel.move(tabID: tabID, to: position)
                }
                """
            let handler = try Self.scan(Self.handlerAnchor, in: source)
            #expect(!handler.canonical.contains(Self.sanctionedClamp))
            #expect(handler.canonical.contains(Self.reorderingRule))
        }

        /// D7: a second drag source in the file, carrying who knows what.
        @Test func scannerCountsASecondDragSource() throws {
            let source = try TabContextMenuWiringGuardTests.stripped("""
                .draggable(tab.id.uuidString)
                .draggable(activeTabID.uuidString)
                """)
            #expect(Self.occurrences(of: Self.dragSource, in: source) == 2)
        }

        /// D8: the drag carries something other than this tab — the whole
        /// reordering path stays exactly as it is and moves the wrong tab.
        @Test func scannerFlagsADragThatNamesAnotherTab() throws {
            let source = try TabContextMenuWiringGuardTests
                .canonicalize(".draggable(activeTabID.uuidString)")
            #expect(!source.contains(Self.sanctionedDrag))
            #expect(Self.occurrences(of: Self.dragSource, in: source) == 1)
        }

        // MARK: - Self-tests for the second half, one probe per W site

        /// W1 in the spelling the review used: the hand-off is still there,
        /// character for character, and the order is not the model's any
        /// more. The occurrence count cannot see this; the member scan can.
        @Test func scannerFlagsAFeedThatRearrangesTheTabs() throws {
            let source = try TabContextMenuWiringGuardTests.canonicalize(
                "tabs: tabsModel.tabs.sorted { $0.displayTitle < $1.displayTitle },")
            #expect(Self.occurrences(of: Self.sanctionedFeed, in: source) == 1)
            let members = Self.membersApplied(to: Self.sanctionedFeed, in: source)
            #expect(Self.rearrangementTokens.intersection(members) == ["sorted"])
        }

        /// W1 in its other spelling: the order is produced elsewhere and
        /// the hand-off simply names something else. No vocabulary is
        /// involved at all, which is why this half is pinned verbatim.
        @Test func scannerFlagsAFeedFromSomewhereElse() throws {
            let source = try TabContextMenuWiringGuardTests.canonicalize("tabs: orderedTabs,")
            #expect(Self.occurrences(of: Self.sanctionedFeed, in: source) == 0)
        }

        /// W2: the loop walks a re-ordered copy of the tabs the strip was
        /// handed.
        @Test func scannerFlagsARenderInAnotherOrder() throws {
            let source = try TabContextMenuWiringGuardTests.canonicalize(
                "ForEach(Array(tabs.reversed().enumerated()), id: \\.element.id) { position, tab in")
            #expect(Self.occurrences(of: Self.sanctionedRender, in: source) == 0)
        }

        /// W3: the second ordering sits in a file that is neither the strip
        /// nor the handler, as a computed property with an innocent name.
        @Test func scannerFlagsARearrangementInAnyAppLayerFile() throws {
            let source = try TabContextMenuWiringGuardTests.canonicalize("""
                private var orderedTabs: [SessionTab] {
                    tabsModel.tabs.sorted { $0.displayTitle < $1.displayTitle }
                }
                """)
            let members = Self.membersApplied(to: Self.tabsExpression, in: source)
            #expect(Self.rearrangementTokens.intersection(members) == ["sorted"])
        }

        /// W4: the position is rewritten where the item is constructed, one
        /// closure outside everything the drop-body checks can see.
        @Test func scannerFlagsAWrappedReorderRoute() throws {
            let source = try TabContextMenuWiringGuardTests.canonicalize(
                "onReorder: { id, _ in onReorder(id, 0) })")
            #expect(Self.occurrences(of: Self.sanctionedHandOff, in: source) == 0)
        }

        /// W5: a third way to the one rule, under a different name for the
        /// model — which is why the anchor carries no receiver.
        @Test func scannerFlagsAThirdCallToTheOneRule() throws {
            let source = try TabContextMenuWiringGuardTests.stripped("""
                tabsModel.move(tabID: tab.id, to: from + offset)
                tabsModel.move(tabID: tabID, to: destination)
                model.move(tabID: tab.id, to: 0)
                """)
            #expect(Self.occurrences(of: Self.reorderingRule, in: source) == 3)
        }

        /// W6: a second strip, fed by something nothing checked.
        @Test func scannerFlagsASecondStripConstruction() throws {
            let source = try TabContextMenuWiringGuardTests.stripped("""
                TabStripView(tabs: tabsModel.tabs, activeTabID: tabsModel.activeTabID)
                TabStripView(tabs: [], activeTabID: UUID())
                """)
            #expect(Self.occurrences(of: Self.stripConstruction, in: source) == 2)
        }

        /// The member scan must answer about the expression it was asked
        /// about and nothing adjacent, or W1 and W3 would be red for the
        /// wrong reason — `tabsToClose` starts with the same characters,
        /// and a subscript is not a member call.
        @Test func theMemberScanReadsOnlyDirectMemberCalls() {
            #expect(Self.membersApplied(
                to: Self.tabsExpression, in: "tabsModel.tabsToClose(besides:id)").isEmpty)
            #expect(Self.membersApplied(
                to: Self.tabsExpression, in: "tabsModel.tabs[index]").isEmpty)
            #expect(Self.membersApplied(
                to: Self.tabsExpression, in: "tabs:tabsModel.tabs,").isEmpty)
            #expect(Self.membersApplied(
                to: Self.tabsExpression,
                in: "tabsModel.tabs.first(where:{$0.id==id})") == ["first"])
            #expect(Self.membersApplied(
                to: Self.tabsExpression,
                in: "tabsModel.tabs.count+tabsModel.tabs.indices") == ["count", "indices"])
        }

        // MARK: - Fail-closed self-tests

        @Test func scannerFailsClosedOnAMissingAnchor() {
            #expect(Self.body(after: Self.dropAnchor, in: "nothing to see here") == nil)
            #expect(Self.body(after: Self.handlerAnchor, in: "nothing to see here") == nil)
        }

        @Test func scannerFailsClosedOnUnbalancedBraces() {
            #expect(Self.body(after: Self.dropAnchor, in: """
                .dropDestination(for: String.self) { payload, _ in
                    onReorder(draggedID, index)
                """) == nil)
        }

        /// The extraction must stop at the anchor's OWN closing brace, not
        /// run on into whatever follows — otherwise a later, unrelated
        /// closure's contents would be judged as if they were the drop's.
        @Test func extractionStopsAtItsOwnClosingBrace() throws {
            let source = """
                .dropDestination(for: String.self) { payload, _ in
                    onReorder(draggedID, index)
                }
                .contextMenu { if entry == .close { Button("x") {} } }
                """
            let drop = try Self.scan(Self.dropAnchor, in: source)
            #expect(!drop.tokens.contains("if"))
            #expect(drop.canonical.contains(Self.sanctionedRoute))
        }

        /// The token scan must match whole words, or `autoreverses` in the
        /// strip's pulse animation would read as a reordering and this
        /// guard would be permanently red for the wrong reason.
        @Test func theTokenScanMatchesWholeWordsOnly() {
            let tokens = TabContextMenuWiringGuardTests.identifierTokens(
                in: "autoreverses: true, moveLeft, removal, inserted")
            #expect(Self.rearrangementTokens.intersection(tokens).isEmpty)
            #expect(tokens.contains("autoreverses"))
            #expect(tokens.contains("moveLeft"))
        }

        /// The stripper the checks above run everything through is the menu
        /// suite's, so prose naming a rearrangement — and this file is full
        /// of it — cannot make a scan go red.
        @Test func commentsAndStringsCannotTriggerTheTokenScan() throws {
            let source = try TabContextMenuWiringGuardTests.stripped("""
                // remove the tab and insert it at the drop position
                let hint = "swapAt"
                let realCode = 1
                """)
            let tokens = TabContextMenuWiringGuardTests.identifierTokens(in: source)
            #expect(Self.rearrangementTokens.intersection(tokens).isEmpty)
            #expect(tokens.contains("realCode"))
        }
    }
}
