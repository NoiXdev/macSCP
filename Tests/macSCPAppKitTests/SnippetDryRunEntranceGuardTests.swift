import Foundation
import Testing

/// Pins that the two entrances to a snippet dry run show the SAME value.
///
/// There are two of them and there is one description: the way out of a
/// refusal when a snippet is triggered (`ContentView.triggerSnippet`) and
/// the "Test" button in the editor (`SnippetsSheet`). Both must reach
/// `SnippetDryRun.describing`, and neither may assemble a description of
/// its own out of the parts that function composes — a resolve, a send
/// plan and a colouring. Two assemblies would be two answers to "what
/// would this send", and the one that drifted would be the rehearsal,
/// because nobody holds it against a real run.
///
/// No test in this project renders a SwiftUI view (see
/// `SnippetActionSheet`'s own doc comment for the same boundary), so this
/// is a source scan, and it is built to this project's three rules for
/// one:
///
/// 1. **A negative check needs a positive check beside it.** "No surface
///    calls `SnippetSendPlanner.plan`" is a filter expected to come back
///    empty: the day the marker stops matching anything at all, it goes on
///    passing and says nothing. So every test below that asserts an
///    absence first asserts the presence of the two call sites the absence
///    is about — `theTwoEntrancesAreTheOnesThatDescribe` is asserted
///    inside the negative tests too, not only in its own.
///
/// 2. **Whole statements, not lines.** A `SnippetDryRun.describing(…)`
///    call spans four lines at both call sites, and the thing worth
///    forbidding — a nested `SnippetSendPlanner.plan(…)` handed in as an
///    argument — sits on a line the marker is not on. The scanner reads
///    from the marker forward until the parenthesis it opened balances
///    again, so the unit it judges is the call, however many lines it
///    takes. `theScanReadsACallThatSpansLines` is that claim as a fixture.
///
/// 3. **It must not anchor on a comment.** A guard elsewhere in this
///    project was satisfied by prose describing the code rather than the
///    code, and every doc comment in `ContentView.swift` and
///    `SnippetsSheet.swift` names these very symbols. So the source is
///    stripped of `//` and `/* … */` comments before anything is looked
///    for, string literals intact — `theScanIgnoresACallThatOnlyAppearsInAComment`
///    and `theScanKeepsCodeAfterAStringThatLooksLikeAComment` hold both
///    halves of that.
@Suite("Snippet dry run entrance guard")
struct SnippetDryRunEntranceGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetDryRunEntranceGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSourceDirectory = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit")

    /// The one producer of a dry run. `SnippetDryRun`'s memberwise
    /// initializer is private, so this marker is not a convention the
    /// scanner hopes for — it is the only way to get the value at all.
    private static let describeMarker = "SnippetDryRun.describing("

    /// The two entrances, by file. Named rather than derived, because the
    /// claim being made is exactly "these two and no others": a set
    /// equality against this list fails in BOTH directions — a third
    /// surface that starts describing, and an entrance that stopped.
    private static let entranceFileNames: Set<String> = ["ContentView.swift", "SnippetsSheet.swift"]

    /// The parts `SnippetDryRun.describing` composes. A surface reaching
    /// for one of these is assembling a second description of what would
    /// be sent.
    ///
    /// `SnippetVariableSubstitution.resolve(` is deliberately NOT here:
    /// the editor's live command preview under the Tags row calls it with
    /// stand-in values while the user types, which is a different picture
    /// from a dry run and predates it.
    private static let assemblyMarkers = ["SnippetSendPlanner.plan(", "SnippetHighlighter.tokens("]

    /// The one App-layer file allowed to colour for itself:
    /// `SnippetCommandEditor` paints an `NSTextView` while the command is
    /// being typed, where there is no resolved command and therefore no
    /// dry run to take tokens from. Held as a set equality rather than an
    /// exemption, after `SnippetCommandSurveyTests`'s own colouring scan: a
    /// per-file `!contains` keeps passing when the marker stops matching,
    /// an equality fails in both directions.
    private static let fileAllowedToColourWhileTyping: Set<String> = ["SnippetCommandEditor.swift"]

    // MARK: - The positive check: both entrances exist, and only those two

    @Test func theTwoEntrancesAreTheOnesThatDescribe() throws {
        #expect(try Self.fileNamesCalling(Self.describeMarker) == Self.entranceFileNames)
    }

    /// Each entrance's call must be the whole question — the snippet, the
    /// values, the Insert/Execute choice and the remote's paste mode. A
    /// call missing an argument does not compile today; a call whose
    /// arguments were reordered into a different `describing` overload
    /// tomorrow would.
    @Test func eachEntrancePassesTheWholeQuestion() throws {
        let calls = try Self.allCalls(to: Self.describeMarker)
        #expect(calls.count >= Self.entranceFileNames.count)
        for call in calls {
            #expect(call.contains("values:"), "\(call)")
            #expect(call.contains("execute:"), "\(call)")
            #expect(call.contains("bracketedPaste:"), "\(call)")
        }
    }

    // MARK: - The negative check, with the positive one beside it

    /// No App-layer file assembles a description itself. Asserted together
    /// with the positive above, in the same test: on its own this is a
    /// filter expected to come back empty, and a marker that stopped
    /// matching would report success forever.
    @Test func neitherEntranceAssemblesADescriptionOfItsOwn() throws {
        #expect(try Self.fileNamesCalling(Self.describeMarker) == Self.entranceFileNames)

        #expect(try Self.fileNamesCalling("SnippetSendPlanner.plan(").isEmpty, """
            An App-layer file plans a snippet's bytes for itself. What a snippet would send is \
            described in one place (`SnippetDryRun.describing`); a surface that plans again is a \
            second answer to the same question, and it is the one that will drift.
            """)
        #expect(
            try Self.fileNamesCalling("SnippetHighlighter.tokens(")
                == Self.fileAllowedToColourWhileTyping)
    }

    /// And the same rule inside a single call: `describing` must be asked
    /// about a snippet, not handed something a caller already planned or
    /// coloured. This is the check that needs whole statements — at both
    /// call sites the arguments sit on lines the marker is not on.
    @Test func noEntranceHandsDescribingSomethingItAlreadyPlanned() throws {
        let calls = try Self.allCalls(to: Self.describeMarker)
        #expect(calls.count >= Self.entranceFileNames.count)
        for call in calls {
            for marker in Self.assemblyMarkers {
                #expect(!call.contains(marker), "\(call)")
            }
        }
    }

    // MARK: - The editor rehearsal remembers nothing

    /// The editor asks for values with the SAME prompt the trigger path
    /// uses, seeded from the same remembered values — and it cannot write
    /// one back, because all it holds is a reading closure.
    ///
    /// Positive first (the prompt and the read are there at all), then the
    /// absence: nothing in the sheet reaches `remember`.
    ///
    /// Each check is made on a `Bool` computed beforehand, so a failure
    /// reports `writesARememberedValue → true` rather than reprinting a
    /// thousand lines of source — the same reason `SnippetDryRunTests`
    /// gives for keeping a value out of an expectation.
    @Test func theEditorsRehearsalRemembersNothing() throws {
        let source = try Self.strippedSource(named: "SnippetsSheet.swift")
        let opensTheSharedPrompt = source.contains("SnippetVariablePromptSheet(")
        let readsWhatWasRemembered = source.contains("rememberedValue")
        let writesARememberedValue = source.contains(".remember(")
        #expect(opensTheSharedPrompt, """
            The snippet editor no longer opens `SnippetVariablePromptSheet` — a second prompt \
            shape would be a second truth about what a value is.
            """)
        #expect(readsWhatWasRemembered, """
            The snippet editor no longer reads remembered values — its rehearsal would open on \
            `defaultValue` while the real run opens on what was remembered, and the two would \
            show different commands for the same snippet.
            """)
        #expect(writesARememberedValue == false, """
            The snippet editor writes a remembered value. A rehearsal must not pre-fill the next \
            real run.
            """)
    }

    // MARK: - Every string the dry run shows is in all four catalogues

    /// Derived, not listed: the keys are read out of the two files that
    /// produce the dry run's text, and each one is looked for in every
    /// `.lproj` the App target ships. A key spelled into a test would be a
    /// second copy of a name — this project's rule about second copies
    /// applies to tests too.
    @Test func everyStringTheDryRunShowsIsInAllFourCatalogues() throws {
        let files = ["SnippetDryRunSheet.swift", "SnippetsPresentation.swift"]
        var keys: Set<String> = []
        for file in files {
            keys.formUnion(try Self.localizationKeys(in: Self.strippedSource(named: file)))
        }
        #expect(!keys.isEmpty, "no `L10n.string(` keys found — re-anchor this guard")

        let catalogues = try FileManager.default.contentsOfDirectory(
            atPath: Self.appSourceDirectory.appendingPathComponent("Resources")
                .path(percentEncoded: false)
        ).filter { $0.hasSuffix(".lproj") }.sorted()
        #expect(catalogues.count == 4, "\(catalogues)")

        for catalogue in catalogues {
            let table = try String(
                contentsOf: Self.appSourceDirectory
                    .appendingPathComponent("Resources/\(catalogue)/Localizable.strings"),
                encoding: .utf8)
            for key in keys.sorted() {
                #expect(table.contains("\"\(key)\" = "), "\(catalogue) is missing \(key)")
            }
        }
    }

    // MARK: - The scanner reacts (fixtures over synthetic sources)

    /// Rule 3. Every doc comment in both entrance files names these
    /// symbols; a scan that read them would pass over a deleted call site.
    @Test func theScanIgnoresACallThatOnlyAppearsInAComment() {
        let source = """
            struct Fake {
                /// Shows what `SnippetDryRun.describing(snippet, values: …)` would send.
                func triggerSnippet() {
                    // SnippetDryRun.describing(snippet, values: [:], execute: true)
                    /* SnippetDryRun.describing(snippet, values: [:], execute: false) */
                    pendingSnippetVariableRefusal = "no"
                }
            }
            """
        #expect(SnippetSourceScan.calls(to: Self.describeMarker, in: source).isEmpty)
    }

    /// The other half of rule 3: stripping comments must not eat code that
    /// merely follows a `//` inside a string literal.
    @Test func theScanKeepsCodeAfterAStringThatLooksLikeAComment() {
        let source = """
            struct Fake {
                let help = "https://example.invalid/snippets"
                func test() {
                    let dryRun = SnippetDryRun.describing(
                        snippet, values: values, execute: true, bracketedPaste: false)
                }
            }
            """
        #expect(SnippetSourceScan.calls(to: Self.describeMarker, in: source).count == 1)
    }

    /// Rule 2, as a fixture. The offending argument is three lines below
    /// the marker: a line-based scan of the `describing(` line sees a clean
    /// call and reports success.
    @Test func theScanReadsACallThatSpansLines() {
        let source = """
            struct Fake {
                func test() {
                    let dryRun = SnippetDryRun.describing(
                        snippet,
                        values: values,
                        execute: SnippetSendPlanner.plan(command: c, execute: true).isSend,
                        bracketedPaste: false)
                }
            }
            """
        let calls = SnippetSourceScan.calls(to: Self.describeMarker, in: source)
        #expect(calls.count == 1)
        #expect(calls.first?.contains("SnippetSendPlanner.plan(") == true)
        #expect(calls.first?.hasSuffix("bracketedPaste: false)") == true)
    }

    /// And the call after it is still found — the balance walk must stop at
    /// the right parenthesis, not run to the end of the file.
    @Test func theScanSeparatesTwoCallsInOneFile() {
        let source = """
            struct Fake {
                func a() { _ = SnippetDryRun.describing(s, values: v, execute: true, bracketedPaste: (a || b)) }
                func b() { _ = SnippetDryRun.describing(s, values: [:], execute: false, bracketedPaste: false) }
            }
            """
        let calls = SnippetSourceScan.calls(to: Self.describeMarker, in: source)
        #expect(calls.count == 2)
        #expect(calls.first?.hasSuffix("(a || b))") == true)
        #expect(calls.last?.contains("values: [:]") == true)
    }

    /// The regression the positive check exists for: an entrance that
    /// stopped describing. Nothing about the remaining call site would say
    /// so.
    @Test func theScanReportsAnEntranceThatStoppedDescribing() {
        let onlyOne = ["ContentView.swift"]
        #expect(Set(onlyOne) != Self.entranceFileNames)
    }

    /// The localization scan reads keys, not defaults — a default value
    /// containing a quote must not be mistaken for one.
    @Test func theLocalizationScanReadsKeysAndNotDefaults() {
        let source = """
            struct Fake {
                var a: String { L10n.string("snippets.dryRun.form.refused", "Nothing would be sent.") }
                var b: String { L10n.string("snippets.dryRun.sendAnyway", "Send anyway") }
            }
            """
        #expect(
            SnippetSourceScan.localizationKeys(in: source)
                == ["snippets.dryRun.form.refused", "snippets.dryRun.sendAnyway"])
    }

    // MARK: - Reading the tree

    private static func appSourceFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: appSourceDirectory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func strippedSource(named name: String) throws -> String {
        SnippetSourceScan.withoutComments(
            try String(
                contentsOf: appSourceDirectory.appendingPathComponent(name), encoding: .utf8))
    }

    private static func calls(to marker: String, inFileAt url: URL) throws -> [String] {
        SnippetSourceScan.calls(
            to: marker, in: try String(contentsOf: url, encoding: .utf8))
    }

    private static func allCalls(to marker: String) throws -> [String] {
        try appSourceFiles().flatMap { try calls(to: marker, inFileAt: $0) }
    }

    private static func fileNamesCalling(_ marker: String) throws -> Set<String> {
        var found: Set<String> = []
        for file in try appSourceFiles() where !(try calls(to: marker, inFileAt: file)).isEmpty {
            found.insert(file.lastPathComponent)
        }
        return found
    }

    private static func localizationKeys(in source: String) throws -> Set<String> {
        Set(SnippetSourceScan.localizationKeys(in: source))
    }
}

/// A scanner that reads Swift source as calls rather than as lines.
///
/// Separate from the suite so its own fixtures above can drive it over
/// synthetic sources, the same shape `SnippetVariablePromptWiringGuardTests`
/// gives its line-based scanner.
enum SnippetSourceScan {
    /// Where the walk currently is. `code` is the only state whose
    /// characters survive `withoutComments`, and the two string states
    /// exist so that a `//` inside a literal is not read as the start of a
    /// comment.
    private enum Position {
        case code
        case lineComment
        case blockComment(depth: Int)
        case string
        case multilineString
    }

    /// `source` with `//` line comments and (nesting) `/* … */` block
    /// comments removed, string literals kept whole. Newlines are kept
    /// wherever a comment was, so nothing else the caller might do to the
    /// result depends on comments being short.
    static func withoutComments(_ source: String) -> String {
        var out = ""
        var position = Position.code
        let characters = Array(source)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            func next(_ offset: Int) -> Character? {
                i + offset < characters.count ? characters[i + offset] : nil
            }
            switch position {
            case .code:
                if c == "\"", next(1) == "\"", next(2) == "\"" {
                    position = .multilineString
                    out += "\"\"\""
                    i += 3
                    continue
                }
                if c == "\"" {
                    position = .string
                    out.append(c)
                    i += 1
                    continue
                }
                if c == "/", next(1) == "/" {
                    position = .lineComment
                    i += 2
                    continue
                }
                if c == "/", next(1) == "*" {
                    position = .blockComment(depth: 1)
                    i += 2
                    continue
                }
                out.append(c)
                i += 1
            case .lineComment:
                if c == "\n" {
                    position = .code
                    out.append(c)
                }
                i += 1
            case .blockComment(let depth):
                if c == "/", next(1) == "*" {
                    position = .blockComment(depth: depth + 1)
                    i += 2
                    continue
                }
                if c == "*", next(1) == "/" {
                    position = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    i += 2
                    continue
                }
                if c == "\n" { out.append(c) }
                i += 1
            case .string:
                out.append(c)
                if c == "\\" {
                    if let escaped = next(1) { out.append(escaped) }
                    i += 2
                    continue
                }
                // A single-quoted Swift string cannot span a line, so a
                // newline here is a source this scanner misread rather
                // than a literal that continues — returning to `code` keeps
                // one bad guess from swallowing the rest of the file.
                if c == "\"" || c == "\n" { position = .code }
                i += 1
            case .multilineString:
                if c == "\"", next(1) == "\"", next(2) == "\"" {
                    position = .code
                    out += "\"\"\""
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Every WHOLE call to `marker` in `source`, comments stripped first.
    ///
    /// `marker` ends in its opening parenthesis; each result runs from the
    /// start of the marker to the `)` that closes it, however many lines
    /// away that is. Parentheses inside string literals do not count.
    static func calls(to marker: String, in source: String) -> [String] {
        let stripped = Array(withoutComments(source))
        let needle = Array(marker)
        guard !needle.isEmpty else { return [] }
        var results: [String] = []
        var i = 0
        while i + needle.count <= stripped.count {
            guard Array(stripped[i..<(i + needle.count)]) == needle else {
                i += 1
                continue
            }
            var depth = 1
            var j = i + needle.count
            var inString = false
            while j < stripped.count, depth > 0 {
                let c = stripped[j]
                if inString {
                    if c == "\\" { j += 2; continue }
                    if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                }
                j += 1
            }
            // An unbalanced call runs to the end of the source rather than
            // being dropped: a call the scanner cannot close is a call it
            // must still report, or a truncated file would read as clean.
            results.append(String(stripped[i..<min(j, stripped.count)]))
            i = j
        }
        return results
    }

    /// The keys of every `L10n.string("…", …)` call in `source`, in order
    /// of appearance and without duplicates removed.
    static func localizationKeys(in source: String) -> [String] {
        calls(to: "L10n.string(", in: source).compactMap { call in
            guard let openQuote = call.firstIndex(of: "\"") else { return nil }
            let afterOpen = call.index(after: openQuote)
            guard let closeQuote = call[afterOpen...].firstIndex(of: "\"") else { return nil }
            return String(call[afterOpen..<closeQuote])
        }
    }
}
