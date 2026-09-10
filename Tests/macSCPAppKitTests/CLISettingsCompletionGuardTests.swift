import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Guards Settings → Command-Line Tool's "Shell Completion" section (Shell
/// Completion plan, Task 1): the line the user copies is BUILT by
/// `ShellCompletionRecipe`, never spelled in the view, the picker iterates
/// the recipe's own shell list, the label and the copy button read the same
/// one property, the section asks `CLICompletionPresentation` for its tool
/// token, and every `settings.cli.completion.` key the section reads
/// resolves in all four catalogues.
///
/// **What the tool token does per state is NOT scanned here.** It is a pure
/// function now — `CLICompletionPresentation.forState(_:bundledToolPath:)`
/// — and `CLISettingsCompletionPresentationTests` at the bottom of this file runs
/// it over every `CLIInstallState` case. This suite only proves the section
/// asks it, which is what makes that table a test of what the user sees.
///
/// **Why the line must not be spelled here.** Three commands in a view and
/// one function in Core that also spells them is a second copy of a name —
/// the case CLAUDE.md's comment rules are about, one layer over. The Core
/// function is the one the shell-level tests in `CLICompletionScriptTests`
/// actually run; a literal in the view would be a fourth spelling nothing
/// executes.
///
/// Same shared scanner as `SettingsViewDiagnosticLogGuardTests` /
/// `SettingsViewAppearanceToggleGuardTests`
/// (`TransferQueueBarCancelGuardTests.declarationBodyRange(of:in:)` /
/// `.slice(_:of:)`, `SwiftSource.blankingComments` /
/// `.blankingCommentsAndStrings`), reused rather than copied.
///
/// **The two views are not interchangeable here.** Structural claims (the
/// call into the recipe, the `allCases` iteration) read the STRICT view,
/// comments and string literals both blanked. The forbidden-command claim
/// is a claim about a LITERAL, so it reads the view that blanks comments
/// only — the strict view would blank a planted `Text("source <(macscp-cli
/// …)")` and report it as absent, which is the "check pointed at the wrong
/// region" failure CLAUDE.md records. Comments are blanked in both, so this
/// file and the section's own doc comment may name the commands in prose
/// without the scanner reading them (CLAUDE.md, "Source-scanning guards
/// read comments too").
///
/// Known blind spots: SOURCE TEXT only, never a rendered view. Nothing here
/// confirms the section appears on screen, that the picker changes the
/// shown line, or that the pasteboard receives anything — the string the
/// button writes is proven identical to the one the label shows only by
/// both naming the same property.
@Suite("Settings — Shell completion section")
struct CLISettingsCompletionGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    /// No trailing `{`, matching the convention of the other Settings
    /// guards: `declarationBodyRange` opens its span at the first `{` after
    /// this text. It is the span of the POSITIVE claims below — that the
    /// section itself calls the recipe and iterates its shell list. The
    /// negative reads the whole FILE instead: see
    /// `theViewSpellsNoneOfTheCommandsItself`.
    private static let sectionDeclaration = "private struct CLISettingsSection: View"

    /// A tool token no Swift source can contain, so splitting a line around
    /// it leaves exactly the parts `ShellCompletionRecipe` spells itself.
    private static let toolSentinel = "\u{1}TOOL\u{1}"

    /// What `shell`'s line spells AROUND the tool, taken from
    /// `ShellCompletionRecipe.line(for:tool:)` rather than typed here
    /// (CLAUDE.md, "Guards that name what they watch", rule 2). A written-out
    /// list is a second copy of a name: the day `line(for:tool:)` changes,
    /// it goes on forbidding the spelling the tree no longer produces and
    /// permits the one it does — a negative that has quietly stopped
    /// watching anything.
    ///
    /// The sentinel is substituted verbatim, so the line falls into the part
    /// before it and the part after it. fish's first part is empty (its line
    /// opens with the tool) and drops out;
    /// `theForbiddenFragmentsAreTheRecipesOwnSpelling` is the positive that
    /// the split really cut a line in two.
    static func forbiddenFragments(
        for shell: ShellCompletionRecipe.Shell
    ) -> [String] {
        ShellCompletionRecipe.line(for: shell, tool: toolSentinel)
            .components(separatedBy: toolSentinel)
            .filter { !$0.isEmpty }
    }

    /// Every shell's fragments, which is every spelling the view must not
    /// contain.
    private static let forbiddenCommandFragments: [String] =
        ShellCompletionRecipe.Shell.allCases.flatMap(
            CLISettingsCompletionGuardTests.forbiddenFragments(for:))

    private static let keyPrefix = "settings.cli.completion."

    /// The keys the section is expected to read. ELEVEN, counted against
    /// the derived set by `theSectionReadsExactlyTheKeysThisGuardNames`
    /// below rather than by eye: header, intro, the picker label, the copy
    /// button, three "where" sentences, the zsh compinit clause, the two
    /// footers, and the sentence shown INSTEAD of a line while the app runs
    /// translocated (design, "The section").
    private static let expectedKeyCount = 11

    // MARK: - Source access

    private static func views(of file: URL) throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: file, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    private static func sectionBodies() throws -> (code: String, withLiterals: String) {
        let all = try views(of: Self.settingsViewFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.sectionDeclaration, in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    /// Positive anchor for every scan below: the strict view really does
    /// reach the section's own declaration, so a `contains` that comes back
    /// false is a missing call and not an unreadable file.
    @Test func theStrictViewStillContainsTheSectionsDeclaration() throws {
        let code = try Self.views(of: Self.settingsViewFile).code
        #expect(code.contains(Self.sectionDeclaration), """
            the strict view of SettingsView.swift no longer contains \
            \(Self.sectionDeclaration) -- the stripper or the path is wrong, \
            and every check in this suite is reading something other than \
            the section it names.
            """)
    }

    // MARK: - The line comes from the recipe

    @Test func theSectionBuildsItsLineWithTheRecipeAndIteratesItsShellList() throws {
        let code = try Self.sectionBodies().code
        #expect(code.contains("ShellCompletionRecipe.line("), """
            CLISettingsSection no longer calls ShellCompletionRecipe.line( -- \
            the copyable line is being produced somewhere other than the one \
            function the shell-level tests actually run.
            """)
        #expect(code.contains("ShellCompletionRecipe.Shell.allCases"), """
            CLISettingsSection no longer iterates \
            ShellCompletionRecipe.Shell.allCases -- a shell list written out \
            in the view goes one behind the enum the CLI is tested against, \
            and keeps rendering.
            """)
    }

    /// The negative, with the positive above beside it. Its span is the
    /// WHOLE FILE, not the section: a command spelled in a helper next to
    /// the section — an extension, a small view struct, the presentation
    /// type — is the same second copy, and a span that stopped at the
    /// section's closing brace would report it as absent. Counted in this
    /// pass, 2026-09-10: SettingsView.swift contains none of the derived
    /// fragments outside a comment.
    ///
    /// Read on the literals-preserving view: a command SPELLED in the view
    /// is exactly what this forbids, and the strict view would have blanked
    /// it.
    @Test func theViewSpellsNoneOfTheCommandsItself() throws {
        let sectionCode = try Self.sectionBodies().code
        #expect(sectionCode.contains("ShellCompletionRecipe.line("), """
            the positive beside this negative is gone: without a call into \
            the recipe, "spells no command" would hold because the section \
            shows no command at all.
            """)
        #expect(!Self.forbiddenCommandFragments.isEmpty, """
            no fragment was derived from ShellCompletionRecipe at all -- this \
            negative is scanning for nothing and cannot fail.
            """)
        let file = try Self.views(of: Self.settingsViewFile).withLiterals
        for fragment in Self.forbiddenCommandFragments {
            #expect(!file.contains(fragment), """
                SettingsView.swift spells "\(fragment)" itself. The three \
                completion lines live in ShellCompletionRecipe.line(for:tool:) \
                and nowhere else -- a copy here is a spelling no test runs.
                """)
        }
    }

    /// The label and the copy button must read ONE property, or the button
    /// can drift into copying a different line than the one on screen — the
    /// defect a user only discovers in their startup file.
    @Test func theCopyButtonCopiesTheSameLineTheLabelShows() throws {
        let code = try Self.sectionBodies().code
        #expect(code.contains("Text(completionLine)"), """
            CLISettingsSection no longer shows completionLine -- the label \
            and the copy button below can no longer be proven to be the \
            same string.
            """)
        #expect(code.contains("setString(completionLine,"), """
            CLISettingsSection's copy button no longer writes completionLine \
            to the pasteboard -- it is copying something other than what the \
            label shows.
            """)
    }

    /// The wiring, and the whole reason the table test at the bottom of
    /// this file is a test of what the user sees: the section asks
    /// `CLICompletionPresentation` what to show rather than switching on
    /// the install state itself.
    @Test func theSectionAsksThePresentationWhatToShow() throws {
        let code = try Self.sectionBodies().code
        #expect(code.contains("CLICompletionPresentation.forState("), """
            CLISettingsSection no longer calls \
            CLICompletionPresentation.forState( -- the tool token and the \
            translocated case are being decided somewhere the table test in \
            CLISettingsCompletionPresentationTests cannot reach.
            """)
    }

    // MARK: - The catalogue

    /// Every `settings.cli.completion.` key the section reads, taken from
    /// the source rather than listed here (CLAUDE.md, "Guards that name
    /// what they watch", rule 2). Read on the literals-preserving view,
    /// since a catalogue key IS a literal.
    private static let keyRegex = try! NSRegularExpression(
        pattern: #""(settings\.cli\.completion\.[A-Za-z0-9.%@ ]*)""#)

    private static func keysReadBySection() throws -> Set<String> {
        let source = try sectionBodies().withLiterals
        let matches = keyRegex.matches(
            in: source, range: NSRange(source.startIndex..., in: source))
        return Set(matches.compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(catalogPath(locale)))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        guard let entries = parsed as? [String: String] else {
            throw CatalogError.unreadable(catalogPath(locale))
        }
        return entries
    }

    enum CatalogError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let path): return "\(path) does not parse as a strings table"
            }
        }
    }

    /// The positive that keeps every catalogue check below from holding
    /// over an empty set, and the place the count in
    /// `expectedKeyCount` is actually measured.
    @Test func theSectionReadsExactlyTheKeysThisGuardNames() throws {
        let keys = try Self.keysReadBySection()
        #expect(keys.contains("settings.cli.completion.header"), """
            CLISettingsSection reads no settings.cli.completion.header key -- \
            the section is gone, or its keys were renamed out from under \
            this guard. keys: \(keys.sorted())
            """)
        #expect(keys.count == Self.expectedKeyCount, """
            CLISettingsSection reads \(keys.count) settings.cli.completion.* \
            key(s), this guard was written against \(Self.expectedKeyCount): \
            \(keys.sorted())
            """)
    }

    @Test func everyKeyTheSectionReadsResolvesInAllFourCatalogues() throws {
        let keys = try Self.keysReadBySection()
        // The positive beside every negative in this loop: an empty key set
        // would satisfy "nothing missing" and "no orphans" over nothing.
        #expect(!keys.isEmpty, "the section reads no \(Self.keyPrefix)* key at all")
        for locale in Self.catalogLocales {
            let entries = try Self.catalog(locale)
            let missing = keys.subtracting(entries.keys)
            #expect(missing.isEmpty, """
                \(Self.catalogPath(locale)) is missing key(s) the section \
                reads: \(missing.sorted())
                """)
            let orphans = Set(entries.keys.filter { $0.hasPrefix(Self.keyPrefix) })
                .subtracting(keys)
            #expect(orphans.isEmpty, """
                \(Self.catalogPath(locale)) declares \(Self.keyPrefix)* key(s) \
                the section does not read: \(orphans.sorted())
                """)
        }
    }

    /// The commands are not display strings and must not enter a
    /// catalogue: a translator could not test one, and a translated
    /// `source <(…)` would be a line that silently does nothing. The
    /// positive beside it is the non-empty value check in the same loop.
    @Test func noCatalogueValueSpellsOneOfTheCommands() throws {
        let keys = try Self.keysReadBySection()
        #expect(!keys.isEmpty, "the section reads no \(Self.keyPrefix)* key at all")
        for locale in Self.catalogLocales {
            let entries = try Self.catalog(locale)
            for key in keys.sorted() {
                guard let value = entries[key] else { continue }
                #expect(!value.isEmpty, "\(Self.catalogPath(locale)): \(key) is empty")
                for fragment in Self.forbiddenCommandFragments {
                    #expect(!value.contains(fragment), """
                        \(Self.catalogPath(locale)): \(key) spells \
                        "\(fragment)". The command comes from \
                        ShellCompletionRecipe, never from a catalogue.
                        """)
                }
            }
        }
    }

    /// The German catalogue addresses the user as du (CLAUDE.md's language
    /// policy; `GermanAddressFormTests` holds the whole catalogue to it and
    /// this repeats the check for the new keys, where a polite form is
    /// easiest to write by accident). Word-boundary matched, so
    /// "Verknüpfungen" and the like cannot trip it.
    @Test func theGermanValuesUseNoPoliteAddress() throws {
        let keys = try Self.keysReadBySection()
        #expect(!keys.isEmpty, "the section reads no \(Self.keyPrefix)* key at all")
        let entries = try Self.catalog("de")
        let polite = try NSRegularExpression(pattern: #"\b(?:Sie|Ihnen|Ihre?[mnrs]?)\b"#)
        var checked = 0
        for key in keys.sorted() {
            guard let value = entries[key] else { continue }
            checked += 1
            let hits = polite.numberOfMatches(
                in: value, range: NSRange(value.startIndex..., in: value))
            #expect(hits == 0, """
                de.lproj: \(key) addresses the user politely -- this app says \
                du. value: \(value)
                """)
        }
        // The positive: the loop above really read the German values, so a
        // zero cannot mean "nothing was scanned".
        #expect(checked == keys.count, """
            only \(checked) of \(keys.count) keys were found in de.lproj
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The fragments really are the recipe's own parts: the sentinel was
    /// substituted EXACTLY once (so the split cut the line in two rather
    /// than handing back the whole line, which would forbid a fragment
    /// nothing can contain), and every fragment appears in the line the
    /// recipe spells for a real tool.
    @Test(arguments: ShellCompletionRecipe.Shell.allCases)
    func theForbiddenFragmentsAreTheRecipesOwnSpelling(
        shell: ShellCompletionRecipe.Shell
    ) {
        let parts = ShellCompletionRecipe.line(for: shell, tool: Self.toolSentinel)
            .components(separatedBy: Self.toolSentinel)
        #expect(parts.count == 2, """
            the tool token appears \(parts.count - 1) time(s) in the \
            \(shell.rawValue) line -- the fragments are derived by splitting \
            around it, so any other count means they are not its parts
            """)
        let fragments = Self.forbiddenFragments(for: shell)
        #expect(!fragments.isEmpty, "no fragment derived for \(shell.rawValue)")
        let line = ShellCompletionRecipe.line(for: shell, tool: "macscp-cli")
        for fragment in fragments {
            #expect(line.contains(fragment), """
                "\(fragment)" is not part of the \(shell.rawValue) line \
                \(line) -- the derivation is producing something the recipe \
                does not spell
                """)
        }
    }

    /// A section that spells a line itself — the exact violation this guard
    /// exists for — must be caught, and must be caught on the
    /// literals-preserving view. The second expectation is the record of
    /// why: the strict view CANNOT see it.
    ///
    /// Run for every shell, which is how fish's `| source` form — the one a
    /// scan for the process-substitution form alone would miss — is covered
    /// without a second synthetic source of its own. Both views are cut to
    /// the declaration's body first, so the scan measured here is the one
    /// the checks above run.
    @Test(arguments: ShellCompletionRecipe.Shell.allCases)
    func scannerCatchesACommandSpelledInTheView(
        shell: ShellCompletionRecipe.Shell
    ) throws {
        let source = """
            \(Self.sectionDeclaration) {
                var body: some View {
                    Text("\(ShellCompletionRecipe.line(for: shell, tool: "macscp-cli"))")
                }
            }
            """
        let withLiterals = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.sectionDeclaration, in: try SwiftSource.blankingComments(source))
        let strict = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.sectionDeclaration, in: try SwiftSource.blankingCommentsAndStrings(source))
        let fragments = Self.forbiddenFragments(for: shell)
        #expect(!fragments.isEmpty, "no fragment derived for \(shell.rawValue)")
        for fragment in fragments {
            #expect(withLiterals.contains(fragment), """
                the scanner failed to catch "\(fragment)" spelled in the view
                """)
            #expect(!strict.contains(fragment), """
                the strict view was expected to blank "\(fragment)" -- if it \
                sees it too, the note about which view this guard must read \
                is wrong
                """)
        }
    }

    /// A comment naming the commands must NOT be caught: this file's own
    /// prose, and the section's doc comment, describe them.
    @Test func scannerIgnoresACommentThatNamesTheCommands() throws {
        let source = """
            // zsh loads it with source <(macscp-cli --generate-completion-script zsh),
            // fish with macscp-cli --generate-completion-script fish | source.
            \(Self.sectionDeclaration) {
                var body: some View {
                    Text(completionLine)
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        for fragment in Self.forbiddenCommandFragments {
            #expect(!withLiterals.contains(fragment), """
                the scanner read "\(fragment)" out of a COMMENT -- comments \
                must be blanked, or every explanation of this section trips \
                its own guard
                """)
        }
        #expect(withLiterals.contains("Text(completionLine)"), """
            the comment-blanking stripper ate the code under the comment
            """)
    }

    /// A picker that writes the shell list out instead of reading
    /// `allCases` must be reported as not iterating it — not waved through
    /// because a `Picker` with the right label is present.
    @Test func scannerSeesAPickerThatWritesTheShellListOut() throws {
        let source = """
            \(Self.sectionDeclaration) {
                var body: some View {
                    Picker(L10n.string("settings.cli.completion.shell", "Shell"), selection: $completionShell) {
                        ForEach([ShellCompletionRecipe.Shell.zsh, .bash], id: \\.self) { shell in
                            Text(shell.rawValue).tag(shell)
                        }
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.sectionDeclaration, in: code)
        // Positive first: a picker really is there, so the negative reports
        // the written-out list rather than an empty read.
        #expect(body.contains("Picker("))
        #expect(!body.contains("ShellCompletionRecipe.Shell.allCases"), """
            the scanner must report a written-out shell list as not iterating \
            allCases
            """)
    }

    /// The key regex itself, against a synthetic section: it must find the
    /// keys and nothing else, or the catalogue checks above scan a set that
    /// has quietly gone empty.
    @Test func theKeyRegexFindsTheKeysASectionReads() throws {
        let source = """
            \(Self.sectionDeclaration) {
                var body: some View {
                    Text(L10n.string("settings.cli.completion.header", "Shell Completion"))
                    Text(L10n.string("settings.cli.completion.where.zsh", "Add it to ~/.zshrc."))
                    Text(L10n.string("settings.cli.systemWide.copy", "Copy Command"))
                }
            }
            """
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.sectionDeclaration, in: try SwiftSource.blankingComments(source))
        let matches = Self.keyRegex.matches(
            in: body, range: NSRange(body.startIndex..., in: body))
        let keys = Set(matches.compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } })
        #expect(keys == [
            "settings.cli.completion.header", "settings.cli.completion.where.zsh",
        ], "the key regex found \(keys.sorted())")
    }

    @Test func scannerFailsClosedWhenTheSectionIsGone() {
        let source = "struct SomethingElse: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: source)
        }
    }
}

/// What the Shell Completion section shows, per install state — the claim
/// the source guard above deliberately does NOT make.
///
/// It is a pure function rather than a `switch` inside a `private` view,
/// for one reason: a table can run it over EVERY `CLIInstallState` case,
/// and a scan of the view's source can only report that the words
/// `CLIToolInstaller.toolName` appear somewhere in it. The section's own
/// call is pinned by `theSectionAsksThePresentationWhatToShow`, so this
/// table is a test of what a user sees.
///
/// **`.translocated` is the case this type was extracted for** (Task 1
/// review, 2026-09-10). The app then runs from a randomised read-only mount
/// that disappears on quit, so a path into it is exactly the wrong thing to
/// write into a startup file — the section offers no line there at all, the
/// same reason `actionTitle` withholds the Install button.
@Suite("Settings — Shell completion presentation")
struct CLISettingsCompletionPresentationTests {
    /// A translocated-looking bundle path, carrying both a space and an
    /// apostrophe so a token that reaches a line is recognisable as itself.
    private static let bundledToolPath =
        "/private/var/folders/xy/AppTranslocation/mac SCP's copy.app/Contents/MacOS/macscp-cli"

    struct Case: Sendable {
        let state: CLIInstallState
        let expected: CLICompletionPresentation
    }

    /// The state's own name, for a failure message — and the structural
    /// boundary this table rests on: a sixth `CLIInstallState` case does not
    /// COMPILE here, so it cannot be added without deciding what the section
    /// shows for it.
    static func tag(_ state: CLIInstallState) -> String {
        switch state {
        case .notInstalled: return "notInstalled"
        case .installed: return "installed"
        case .stale: return "stale"
        case .occupied: return "occupied"
        case .translocated: return "translocated"
        }
    }

    /// Six entries over five states: `.stale` appears twice, with and
    /// without a readable target, because the target is a display detail and
    /// must not reach the decision.
    static let table: [Case] = [
        Case(state: .installed, expected: .line(tool: CLIToolInstaller.toolName)),
        Case(
            state: .notInstalled,
            expected: .line(
                tool: ShellCompletionRecipe.quotedForShell(
                    CLISettingsCompletionPresentationTests.bundledToolPath))),
        Case(
            state: .stale(target: nil),
            expected: .line(
                tool: ShellCompletionRecipe.quotedForShell(
                    CLISettingsCompletionPresentationTests.bundledToolPath))),
        Case(
            state: .stale(target: "/usr/local/bin/macscp-cli"),
            expected: .line(
                tool: ShellCompletionRecipe.quotedForShell(
                    CLISettingsCompletionPresentationTests.bundledToolPath))),
        Case(
            state: .occupied,
            expected: .line(
                tool: ShellCompletionRecipe.quotedForShell(
                    CLISettingsCompletionPresentationTests.bundledToolPath))),
        Case(state: .translocated, expected: .moveFirst),
    ]

    @Test(arguments: CLISettingsCompletionPresentationTests.table)
    func theInstallStateDecidesWhatTheSectionShows(testCase: Case) {
        let presentation = CLICompletionPresentation.forState(
            testCase.state, bundledToolPath: Self.bundledToolPath)
        #expect(presentation == testCase.expected, """
            \(Self.tag(testCase.state)) is presented as \(presentation), \
            this table was written against \(testCase.expected)
            """)
    }

    /// The positive beside the table: it really covers every state, so a
    /// case quietly dropped from it cannot pass as "all green".
    @Test func theTableCoversEveryInstallState() {
        #expect(Set(Self.table.map { Self.tag($0.state) }) == [
            "notInstalled", "installed", "stale", "occupied", "translocated",
        ], "the table covers \(Set(Self.table.map { Self.tag($0.state) }).sorted())")
    }

    /// Stronger than `== .moveFirst`: whatever the branch returns, no part
    /// of the temporary path may reach a line the user is invited to paste
    /// into a startup file.
    @Test func aTranslocatedAppIsOfferedNoLineAtAll() {
        var offeredTool: String?
        if case .line(let tool) = CLICompletionPresentation.forState(
            .translocated, bundledToolPath: Self.bundledToolPath) {
            offeredTool = tool
        }
        #expect(offeredTool == nil, """
            a translocated app was offered a line invoking \(offeredTool ?? "") \
            -- that path is gone the moment macSCP quits, and a startup file \
            keeps it forever
            """)
    }
}
