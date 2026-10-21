import Foundation
import MacSCPTestSupport
import Testing

/// Keeps the compressible spellings of a localized control from coming back.
///
/// The rigid components (`SegmentedChoice`, `RadioChoice`, `CheckboxRow`) exist
/// because a compressed control truncates its label and NOTHING overflows, so no
/// width measurement can see it. Replacing the call sites made the defect
/// measurable; this suite is what stops a later edit from making it silent
/// again. Everything here reads the blanked code view (`SourceCorpus.code`), so
/// the doc comments that quote these spellings neither trip a negative check nor
/// satisfy a positive one.
///
/// ## Why this is an allow-list and not "only the component file"
///
/// The first form of this task asked for a scan asserting that the three raw
/// styles appear in no file but `RigidControls.swift`. That is not true of the
/// tree. Five raw segmented sites survive in containers no task migrated, none
/// of them a bounded view or a resizable container:
/// `SessionExportImportSheets.swift` (2), `BrowserSheets.swift` (1) and
/// `TunnelProfilesSheet.swift` (2). Seven hand-written menus exist besides, and
/// they are not components at all: a `Picker`, the menu style and `.fixedSize()`,
/// written by hand. A blanket prohibition would have to be red today, and the
/// choices are to weaken it until it is green (a comment that runs) or to
/// migrate five sites this task was not given. So each permitted site is NAMED,
/// the count per file is asserted EXACTLY, and a site that is not on the list is
/// red. The list is a debt register, not a blessing: every entry that is not
/// `RigidControls.swift` is a place a compressible control can still hide.
///
/// ## The three defaults are the real exposure
///
/// An allow-list of USES watches who walks through a seam, not the seam. Three
/// single tokens make controls compressible again with nothing else red, so each
/// declaration has a check of its own: `TagFilterJoinPicker.presentation`'s
/// default (`.segmented`), `CheckboxRow`'s `wraps` default (`false`), and the
/// absence of `isInAResizableContainer`.
///
/// ## What none of this catches
///
/// A `Picker` that names no style at all, a style outside the two families
/// counted in `noPickerOrToggleStyleEscapesTheNamedFamilies`, and the resizable-
/// container seam returning under another name. The first and third are
/// unscannable by spelling; the measurement suites (`BoundedViewLayoutGuardTests`,
/// `ResizableContainerFloorTests`) are what see their effect.
///
/// **A width frame around a rigid component is the fourth, and it is caught
/// one level deep.** A `.frame(width:)`, `.frame(maxWidth:)` or
/// `.frame(minWidth:)` collapses a rigid component's reported minimum exactly
/// as a compressible control does, so neither a width guard nor a floor guard
/// moves — measured by
/// `RigidControlTests.aWidthOrMinWidthFrameCollapsesTheMinimum`, and watched by
/// `noRigidComponentIsHeldToAWidthFrame`, which reads the modifier chain on
/// each of the 19 component calls. **Corrected 2026-10-18:** this paragraph
/// said those calls are "where both instances this branch deleted stood". One
/// of the two stood there. `SnippetsSheet`'s `.frame(width: 150)` sits on a
/// component call and is watched; `FileSearchBar`'s `.frame(width: 118)` was
/// replaced in `aece2e2b` by a hand-written `.pickerStyle(.menu)` picker, and
/// `FileSearchBar.swift` holds no component call at all, so a width frame
/// returning to that line is caught by nothing — item (1) of the
/// coverage-debt row in `docs/BACKLOG.md`. A frame on an ENCLOSING container
/// is not read either, and nothing in this tree measures it.
///
/// **Nor does it see a `Toggle` that names no style.** On macOS a bare
/// `Toggle("label", isOn:)` is a compressible checkbox by default, so "the
/// checkbox style appears only in the component" does NOT mean no compressible
/// checkbox exists outside it. Counted 2026-10-18 with
/// `grep -rn -e '[^a-zA-Z]Toggle(' Sources/MacSCPAppKit`, which prints 37
/// lines; they are not migrated and not listed here, by decision.
@Suite("Rigid control scan")
struct RigidControlScanTests {
    private static let appKitSources: URL = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit", isDirectory: true)

    /// Every Swift file under the app's sources, keyed by its path relative to
    /// that directory, blanked of comments and string literals.
    private static func blankedSources() throws -> [String: String] {
        let urls = try SourceCorpus.files(under: appKitSources).filter { $0.pathExtension == "swift" }
        let code = try SourceCorpus.code(ofAll: urls)
        let prefix = appKitSources.path + "/"
        var result: [String: String] = [:]
        for (url, text) in zip(urls, code) {
            result[String(url.path.dropFirst(prefix.count))] = text
        }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // A pattern that does not compile is a bug in this file, not a result.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        regex(pattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// File to number of occurrences, for the files with at least one.
    private static func counts(_ pattern: String, in sources: [String: String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (name, code) in sources {
            let n = count(pattern, in: code)
            if n > 0 { result[name] = n }
        }
        return result
    }

    private static func describe(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    // MARK: - The raw styles

    /// One compressible spelling, the pattern that finds it, and every file
    /// that is allowed to carry it, with how many times.
    ///
    /// The left edge is `(?:^|\W)`, not `\b`: in Swift's `Regex` a word
    /// boundary finds no edge in `x.sheetBound(` or `Module.Name`, and an
    /// earlier scan on this branch matched nothing because of it. The right edge
    /// is `(?!\w)`. This file reads through `NSRegularExpression`, where `\b` DOES
    /// match those (measured 2026-10-18 with a throwaway program over
    /// `x.isInAResizableContainer`: `NSRegularExpression` 1, `range(of:)` true,
    /// `Regex` false), so swapping the edges back to `\b` here stays green, and
    /// that was observed: the edges are spelled for the engine this file might
    /// be ported to, and the samples below that put a `.` before the name are
    /// what would catch the port.
    fileprivate struct Style: Sendable, CustomTestStringConvertible {
        let name: String
        let pattern: String
        let allowed: [String: Int]
        let matching: [String]
        let notMatching: [String]
        var testDescription: String { name }
    }

    /// Counted 2026-10-18 with
    /// `grep -rn 'pickerStyle[(][.]segmented[)]' Sources/MacSCPAppKit`, which
    /// prints 6 lines (bracketed, so that no comment matches its own pattern).
    /// Five are the survivors named in the suite comment; the sixth is the
    /// component. `SegmentedPickerStyle` as a type is the other spelling of the
    /// same style, and the tree has none: `grep -rn 'SegmentedPickerStyle'
    /// Sources/MacSCPAppKit` prints nothing.
    private static let segmented = Style(
        name: "segmented",
        pattern: #"\.pickerStyle\(\s*\.segmented\s*\)|(?:^|\W)SegmentedPickerStyle(?!\w)"#,
        allowed: [
            "RigidControls.swift": 1,
            "SessionExportImportSheets.swift": 2,
            "BrowserSheets.swift": 1,
            "TunnelProfilesSheet.swift": 2,
        ],
        matching: [
            "        .pickerStyle(.segmented)",
            "x\n    .pickerStyle(\n        .segmented\n    )",
            "    .pickerStyle(SegmentedPickerStyle())",
            "SwiftUI.SegmentedPickerStyle()",
            "SegmentedPickerStyle()",
        ],
        notMatching: [
            "    .pickerStyle(.menu)", "    .pickerStyle(.segmentedX)", "MySegmentedPickerStyleX()",
        ])

    /// Counted the same way, `grep -rn 'pickerStyle[(][.]radioGroup'
    /// Sources/MacSCPAppKit`: one line, in the component.
    private static let radioGroup = Style(
        name: "radio group",
        pattern: #"\.pickerStyle\(\s*\.radioGroup\s*\)|(?:^|\W)RadioGroupPickerStyle(?!\w)"#,
        allowed: ["RigidControls.swift": 1],
        matching: [
            "        .pickerStyle(.radioGroup)", "    .pickerStyle(RadioGroupPickerStyle())",
            "SwiftUI.RadioGroupPickerStyle()", "RadioGroupPickerStyle()",
        ],
        notMatching: ["    .pickerStyle(.menu)", "MyRadioGroupPickerStyleX()"])

    /// Counted the same way, `grep -rn 'toggleStyle[(][.]checkbox'
    /// Sources/MacSCPAppKit`: one line, in the component.
    private static let checkbox = Style(
        name: "checkbox",
        pattern: #"\.toggleStyle\(\s*\.checkbox\s*\)|(?:^|\W)CheckboxToggleStyle(?!\w)"#,
        allowed: ["RigidControls.swift": 1],
        matching: [
            "            .toggleStyle(.checkbox)", "    .toggleStyle(CheckboxToggleStyle())",
            "SwiftUI.CheckboxToggleStyle()", "CheckboxToggleStyle()",
        ],
        notMatching: ["    .toggleStyle(.switch)", "MyCheckboxToggleStyleX()"])

    /// The menu style is not a component and not forbidden: a pop-up shows ONE
    /// label, which is why it fits where a segmented control of the same labels
    /// did not. Its rigidity is a hand-written `.fixedSize()`, checked by
    /// `everyHandWrittenMenuCarriesFixedSize`. Counted the same way,
    /// `grep -rn 'pickerStyle[(][.]menu[)]' Sources/MacSCPAppKit`, which prints
    /// 7 lines: `ConnectionFormView` (2), and one each in `AuditLogSheet`,
    /// `DiagnosticsPanel`, `FileSearchBar`, `SheetFacetPicker` and
    /// `SidebarTagFilterBar`.
    private static let menu = Style(
        name: "menu",
        pattern: #"\.pickerStyle\(\s*\.menu\s*\)|(?:^|\W)MenuPickerStyle(?!\w)"#,
        allowed: [
            "ConnectionFormView.swift": 2,
            "AuditLogSheet.swift": 1,
            "DiagnosticsPanel.swift": 1,
            "FileSearchBar.swift": 1,
            "SheetFacetPicker.swift": 1,
            "SidebarTagFilterBar.swift": 1,
        ],
        matching: [
            "        .pickerStyle(.menu)", "x\n    .pickerStyle(\n        .menu\n    )",
            "    .pickerStyle(MenuPickerStyle())", "SwiftUI.MenuPickerStyle()",
        ],
        notMatching: ["    .pickerStyle(.segmented)", "MyMenuPickerStyleX()"])

    /// The one `toggleStyle(.button)` in the tree: the search bar's regular
    /// expression switch, whose face is the literal `.*` and no localized text,
    /// so there is no label to compress. It is listed so that the catch-all in
    /// `noPickerOrToggleStyleEscapesTheNamedFamilies` can balance. Counted with
    /// `grep -rn 'toggleStyle[(][.]button' Sources/MacSCPAppKit`: one line.
    private static let toggleButton = Style(
        name: "toggle button",
        pattern: #"\.toggleStyle\(\s*\.button\s*\)|(?:^|\W)ButtonToggleStyle(?!\w)"#,
        allowed: ["FileSearchBar.swift": 1],
        matching: [
            "            .toggleStyle(.button)", "    .toggleStyle(ButtonToggleStyle())",
            "SwiftUI.ButtonToggleStyle()", "ButtonToggleStyle()",
        ],
        notMatching: ["    .toggleStyle(.checkbox)", "MyButtonToggleStyleX()"])

    fileprivate static let styles = [segmented, radioGroup, checkbox, toggleButton, menu]

    /// The negative half. Each style's occurrences, per file, equal its
    /// allow-list EXACTLY. Equality is also what makes this carry its own
    /// positive: a pattern that has stopped matching returns an empty
    /// dictionary and the listed files read 0 against their expected count.
    @Test(arguments: RigidControlScanTests.styles)
    fileprivate func aStyleAppearsOnlyWhereItIsListed(style: Style) throws {
        let sources = try Self.blankedSources()
        let actual = Self.counts(style.pattern, in: sources)
        #expect(
            actual == style.allowed,
            "\(style.name): found [\(Self.describe(actual))], listed [\(Self.describe(style.allowed))]")
    }

    /// The positive half for the patterns themselves. Every sample is checked
    /// against its OWN style's pattern (a mismatch is red) and the other styles'
    /// patterns do not match it.
    @Test func theStylePatternsMatchWhatTheyAreWrittenToMatch() {
        for style in Self.styles {
            for sample in style.matching {
                #expect(Self.count(style.pattern, in: sample) >= 1, "\(style.name) must match: \(sample)")
                for other in Self.styles where other.name != style.name {
                    #expect(
                        Self.count(other.pattern, in: sample) == 0,
                        "\(other.name) must not match a \(style.name) sample: \(sample)")
                }
            }
            for sample in style.notMatching {
                #expect(Self.count(style.pattern, in: sample) == 0, "\(style.name) must not match: \(sample)")
            }
            #expect(!style.matching.isEmpty && !style.notMatching.isEmpty, "\(style.name) has no samples")
        }
    }

    /// A style the patterns above do not name (`.automatic`, `.inline`,
    /// `.palette`, `.switch`) would walk past every allow-list. So the number of
    /// `.pickerStyle(` and `.toggleStyle(` calls is held to the sum of the
    /// styles that ARE named. Counted 2026-10-18 with
    /// `grep -rn 'pickerStyle[(]' Sources/MacSCPAppKit`, which prints 14 lines
    /// (6 segmented, 1 radio group, 7 menu), and
    /// `grep -rn 'toggleStyle[(]' Sources/MacSCPAppKit`, which prints 2 (the
    /// checkbox, the toggle button).
    @Test func noPickerOrToggleStyleEscapesTheNamedFamilies() throws {
        let sources = try Self.blankedSources()
        let pickerCalls = Self.counts(#"\.pickerStyle\("#, in: sources)
        let toggleCalls = Self.counts(#"\.toggleStyle\("#, in: sources)

        func total(_ counts: [String: Int]) -> Int { counts.values.reduce(0, +) }
        func listed(_ styles: [Style]) -> Int { styles.reduce(0) { $0 + total($1.allowed) } }

        #expect(
            total(pickerCalls) == listed([Self.segmented, Self.radioGroup, Self.menu]),
            "pickerStyle calls: [\(Self.describe(pickerCalls))]")
        #expect(
            total(toggleCalls) == listed([Self.checkbox, Self.toggleButton]),
            "toggleStyle calls: [\(Self.describe(toggleCalls))]")

        // Positive: the call patterns see what they are written to see, and a
        // style none of the four names IS one more call.
        #expect(total(pickerCalls) > 0 && total(toggleCalls) > 0)
        #expect(Self.count(#"\.pickerStyle\("#, in: "    .pickerStyle(.inline)") == 1)
        #expect(Self.count(#"\.toggleStyle\("#, in: "    .toggleStyle(.switch)") == 1)
    }

    // MARK: - The hand-written rigid menus

    /// The lines of the modifier chain that `lines[start]` belongs to: that
    /// line, then every following line that starts with `.`, skipping blank
    /// ones (a blanked comment is blank). The first other line ends it.
    ///
    /// It reads FORWARD only: a `.fixedSize()` written before the style
    /// (`Picker {}.fixedSize().pickerStyle(.menu)`) is rigid and still reads as
    /// missing. That is the loud direction, and every listed menu writes the
    /// style first, so it stands.
    private static func modifierChain(startingAt start: Int, in lines: [Substring]) -> [String] {
        var chain = [lines[start].trimmingCharacters(in: .whitespaces)]
        var index = start + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            guard trimmed.hasPrefix(".") else { break }
            chain.append(trimmed)
            index += 1
        }
        return chain
    }

    private static func chainHoldsItsIdealWidth(_ chain: [String]) -> Bool {
        chain.contains { count(#"^\.fixedSize\(\)"#, in: $0) == 1 }
    }

    /// Nothing but this keeps a hand-written menu from being compressed: the
    /// style alone is not rigid. Each `.pickerStyle(.menu)` must sit in a
    /// modifier chain that also carries `.fixedSize()`.
    @Test func everyHandWrittenMenuCarriesFixedSize() throws {
        let sources = try Self.blankedSources()
        var inspected = 0
        var offenders: [String] = []
        for (name, code) in sources {
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where Self.count(Self.menu.pattern, in: String(line)) > 0 {
                inspected += 1
                if !Self.chainHoldsItsIdealWidth(Self.modifierChain(startingAt: index, in: lines)) {
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "menus without .fixedSize(): \(offenders.sorted().joined(separator: ", "))")
        // Positive: it looked at every menu on the list, so a scan that stopped
        // finding the style does not pass by inspecting nothing.
        #expect(inspected == Self.menu.allowed.values.reduce(0, +), "\(inspected) menus inspected")
    }

    @Test func theChainReaderSeesWhatItIsWrittenToSee() {
        func lines(_ text: String) -> [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
        let held = lines("""
            Picker {}
            .pickerStyle(.menu)
            .labelsHidden()

            .fixedSize()
            }
            """)
        #expect(Self.chainHoldsItsIdealWidth(Self.modifierChain(startingAt: 1, in: held)))

        let bare = lines("""
            Picker {}
            .pickerStyle(.menu)
            .labelsHidden()
            Text("x")
            .fixedSize()
            """)
        // The chain ends at `Text`, so a `.fixedSize()` that belongs to another
        // view does not count.
        #expect(!Self.chainHoldsItsIdealWidth(Self.modifierChain(startingAt: 1, in: bare)))
        #expect(!Self.chainHoldsItsIdealWidth(Self.modifierChain(startingAt: 1, in: lines("a\n.pickerStyle(.menu)"))))
    }

    // MARK: - A width frame around a rigid component

    /// One rigid component, the pattern that finds a call to it, and every
    /// file that writes one, with how many times.
    ///
    /// Counted 2026-10-18 with `grep -rn 'SegmentedChoice[(]' Sources/MacSCPAppKit`
    /// (12 lines), `grep -rn 'RadioChoice[(]' Sources/MacSCPAppKit` (2) and
    /// `grep -rn 'CheckboxRow[(]' Sources/MacSCPAppKit` (6), the parentheses
    /// bracketed so that this comment does not match its own pattern, and the
    /// same three figures under `/usr/bin/grep`. 20 lines in all; the counts
    /// below sum to 19, because the sixth `CheckboxRow[(]` line is
    /// `RigidControls.swift:57`, that file's own header prose, which the
    /// blanked view does not see. `theCallSiteScanReadsCodeAndNotProse` is the
    /// check on that.
    ///
    /// **Corrected 2026-10-20 (S3 bucket settings, Task 9).** The paragraph
    /// above read, verbatim: "(12 lines)" for `SegmentedChoice`, "(6)" for
    /// `CheckboxRow`, "20 lines in all" and "the counts below sum to 19". The CORS
    /// sheet adds one site of each, so the same three commands, run again and
    /// under `/usr/bin/grep` alike, print 13, 2 and 7: 22 lines in all, and the
    /// counts below sum to 21 (the same one line of header prose is the
    /// difference).
    ///
    /// **Corrected 2026-10-21 (S3 bucket settings, Task 10).** The Task 9
    /// paragraph directly above read, verbatim: "print 13, 2 and 7: 22 lines in
    /// all, and the counts below sum to 21". The two Object Lock sheets add two
    /// `RadioChoice` sites (one each) and three `CheckboxRow` sites
    /// (`ObjectLockSheet` two, `BucketObjectLockSheet` one), so the same three
    /// commands, run again and under `/usr/bin/grep` alike, print 13, 4 and 10:
    /// 27 lines in all, and the counts below sum to 26 (the same one line of
    /// header prose is the difference). The Task 9 paragraph is left as it
    /// stands: it records what the commands printed when it was written.
    fileprivate struct Component: Sendable, CustomTestStringConvertible {
        let name: String
        let pattern: String
        let sites: [String: Int]
        var testDescription: String { name }
    }

    fileprivate static let components = [
        Component(
            name: "SegmentedChoice",
            pattern: #"(?:^|\W)SegmentedChoice\("#,
            sites: [
                "BucketCORSSheet.swift": 1,
                "ConnectionFormView.swift": 3,
                "FileActionEditor.swift": 1,
                "LoginSetsSheet.swift": 1,
                "PresignedURLSheet.swift": 1,
                "SSHKeysSheet.swift": 2,
                "SettingsView.swift": 2,
                "SidebarTagFilterBar.swift": 1,
                "SnippetsSheet.swift": 1,
            ]),
        Component(
            name: "RadioChoice",
            pattern: #"(?:^|\W)RadioChoice\("#,
            sites: [
                "BucketObjectLockSheet.swift": 1,
                "ExtractDestinationSheet.swift": 1,
                "FileActionEditor.swift": 1,
                "ObjectLockSheet.swift": 1,
            ]),
        Component(
            name: "CheckboxRow",
            pattern: #"(?:^|\W)CheckboxRow\("#,
            sites: [
                "BucketCORSSheet.swift": 1,
                "BucketObjectLockSheet.swift": 1,
                "FileActionEditor.swift": 2,
                "ObjectLockSheet.swift": 2,
                "SheetSearchField.swift": 1,
                "SnippetsSheet.swift": 2,
            ]),
    ]

    /// A frame spelling that collapses a rigid component's reported minimum.
    /// Which spellings those are is measured, not reasoned:
    /// `RigidControlTests.aWidthOrMinWidthFrameCollapsesTheMinimum` reports,
    /// through this repository's own `LayoutMeasure`,
    ///
    /// ```
    /// MACSCP_BOUND_FIGURES=1 swift test --filter aWidthOrMinWidthFrameCollapsesTheMinimum
    /// frame: de alone 149.0 width100 100.0 maxWidth100 100.0 minWidth100 100.0 maxWidthInfinity 149.0 minWidth100AndInfinity 100.0
    /// frame: fr alone 174.0 width100 100.0 maxWidth100 100.0 minWidth100 100.0 maxWidthInfinity 174.0 minWidth100AndInfinity 100.0
    /// ```
    ///
    /// So `width:`, `maxWidth:` and `minWidth:` are all matched, and
    /// `maxWidth: .infinity` — which leaves the minimum exactly where it was —
    /// is excluded by the lookahead. A frame writing both
    /// (`minWidth: 100, maxWidth: .infinity`) collapses to 100.0 and is caught
    /// on its `minWidth`. `idealWidth:` is not matched and is not measured
    /// either way.
    ///
    /// **Corrected 2026-10-18, by measurement.** This comment read "A width
    /// frame, in the two spellings that CAP a width. `minWidth:` and
    /// `idealWidth:` raise a floor rather than cap, so they are not matched".
    /// That is a claim about how SwiftUI behaves and it is false of
    /// `minWidth:`: a floor of 100 reports 100, the same figure a hard width
    /// gives. `theCallChainReaderSeesWhatItIsWrittenToSee` asserted the hole
    /// open, in a must-not-match sample, which is worse than leaving it
    /// unsaid. `grep -rn -F -e '.frame(minWidth:' Sources/MacSCPAppKit` prints
    /// 25 lines, so the spelling is a house idiom; none of them sits on a
    /// component call, so widening the pattern reds nothing today.
    ///
    /// The lookahead swallows the whitespace itself, `:(?!\s*\.infinity)` and
    /// not `:\s*(?!\.infinity)`. The second form was written first and read
    /// `.frame(maxWidth: .infinity)` as a hit: `\s*` backtracks to zero
    /// characters, the lookahead then stands before a SPACE rather than before
    /// the dot, and a negative lookahead that cannot see what it excludes
    /// always succeeds.
    private static let widthFramePattern =
        #"\.frame\((?:[^)]*[,\s])?(?:width|maxWidth|minWidth)\s*:(?!\s*\.infinity)"#

    /// The modifier chain written on the call whose opening parenthesis ends at
    /// `openParenEnd`: the rest of the line that call closes on, then every
    /// following line beginning with `.`, blank lines skipped (a blanked
    /// comment is blank). The first other line ends it, so a modifier on an
    /// enclosing container — whose `}` line breaks the chain — is not read as
    /// this call's.
    ///
    /// It reads FORWARD and it reads ONE level. A frame written on a container
    /// (`VStack { SegmentedChoice(…) }.frame(width: 100)`) collapses the
    /// component's reported minimum exactly as a frame on the call does, and
    /// nothing here sees it: this check narrows the hole rather than closing
    /// it, as the suite header says.
    private static func chainAfterCall(openParenEnd: Int, in text: NSString) -> [String] {
        let open = UInt16(UnicodeScalar("(").value)
        let close = UInt16(UnicodeScalar(")").value)
        var depth = 1
        var index = openParenEnd
        while index < text.length, depth > 0 {
            let character = text.character(at: index)
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
            }
            index += 1
        }
        guard depth == 0 else { return [] }
        let rest = text.substring(from: index).split(
            separator: "\n", omittingEmptySubsequences: false)
        var chain: [String] = []
        if let closingLine = rest.first {
            chain.append(closingLine.trimmingCharacters(in: .whitespaces))
        }
        for line in rest.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix(".") else { break }
            chain.append(trimmed)
        }
        return chain
    }

    /// Every call to `component`, as `file:line`, with the modifier chain
    /// written on it.
    private static func callChains(
        of component: Component, in sources: [String: String]
    ) -> [(site: String, chain: [String])] {
        var result: [(site: String, chain: [String])] = []
        for (name, code) in sources.sorted(by: { $0.key < $1.key }) {
            let text = code as NSString
            let matches = regex(component.pattern).matches(
                in: code, range: NSRange(location: 0, length: text.length))
            for match in matches {
                let end = match.range.location + match.range.length
                let line = text.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
                result.append(
                    (site: "\(name):\(line)", chain: chainAfterCall(openParenEnd: end, in: text)))
            }
        }
        return result
    }

    /// A width frame around a RIGID component collapses the minimum width it
    /// reports, exactly as a compressible control does, and no measurement in
    /// this tree moves.
    ///
    /// The measurement that reproduces as committed is
    /// `RigidControlTests.aWidthOrMinWidthFrameCollapsesTheMinimum`
    /// (`MACSCP_BOUND_FIGURES=1 swift test --filter aWidthOrMinWidthFrameCollapsesTheMinimum`),
    /// which reports a rigid `SegmentedChoice` at 149.0 in German and 100.0
    /// under each of `.frame(width: 100)`, `.frame(maxWidth: 100)` and
    /// `.frame(minWidth: 100)`. The overflow is drawn clipped, and
    /// `BoundedViewLayoutGuardTests` then reads the frame's figure instead of
    /// the content's — which withdraws the Task 8 conclusion that "A caller can
    /// still wrap the result in `.frame(width:)`, but that clips and overflows,
    /// which the Task 6 guard sees".
    ///
    /// The final reviewer's own figures — a segmented control with three German
    /// labels at minimum 477.0 alone, 100.0 in `.frame(width: 100)`, 100.0
    /// inside `.frame(maxWidth: 100)` and 100.0 in a `VStack` inside
    /// `.frame(width: 100)` — were taken in a standalone binary outside this
    /// repository and **are not reproducible as committed**; the last of the
    /// four is the one the test above cannot show, because nothing here
    /// measures a frame on an enclosing container.
    ///
    /// The shape is not hypothetical: this branch deleted `SnippetsSheet`'s
    /// `.frame(width: 150)` in `c8bfdb63`, and nothing but this check stops it
    /// coming back. **Corrected 2026-10-18:** this paragraph read "this branch
    /// deleted two instances of it, `SnippetsSheet`'s `.frame(width: 150)` in
    /// `c8bfdb63` and `FileSearchBar`'s `.frame(width: 118)` in `aece2e2b`.
    /// Nothing but this check stops either from coming back." The second half
    /// is false of this check: `aece2e2b` replaced that call with a
    /// hand-written `.pickerStyle(.menu)` picker, there is no component call
    /// anywhere in `FileSearchBar.swift`, and so this scan never looks at the
    /// line. A width frame returning there is caught by nothing — which is
    /// item (1) of the coverage-debt row in `docs/BACKLOG.md`, the one
    /// recording that the menu kind has no component.
    ///
    /// The positive half is the second expectation: the per-file call counts
    /// equal the list above EXACTLY, so a scan that has stopped finding the
    /// component — a rename, a changed spelling — reads 0 against a listed
    /// count and is red, instead of passing by inspecting nothing.
    ///
    /// **Proved red 2026-10-18, twice.** Each plant puts a frame back on the
    /// snippet kind picker, through `scripts/mutation-probe`, which reverts
    /// index-safely and refuses a dirty tree. The first plants the width frame
    /// `c8bfdb63` deleted, the second the `minWidth` floor the pattern was
    /// widened for:
    ///
    /// ```
    /// scripts/mutation-probe --filter noRigidComponentIsHeldToAWidthFrame \
    ///   --label 'width frame back on the snippet kind picker' \
    ///   --apply "perl -0pi -e 's/\n                        \]\)\n                \} else \{\n/\n                        ])\n                    .frame(width: 150)\n                } else {\n/' Sources/MacSCPAppKit/SnippetsSheet.swift"
    ///
    /// scripts/mutation-probe --filter noRigidComponentIsHeldToAWidthFrame \
    ///   --label 'minWidth floor back on the snippet kind picker' \
    ///   --apply "perl -0pi -e 's/\n                        \]\)\n                \} else \{\n/\n                        ])\n                    .frame(minWidth: 100)\n                } else {\n/' Sources/MacSCPAppKit/SnippetsSheet.swift"
    /// ```
    ///
    /// Both printed, verbatim:
    ///
    /// ```
    /// ── control: 1 test(s) ran, 0 pre-existing failures
    /// RESULT: RED — 1 test(s) ran, and the plant was caught by:
    ///   macSCPAppKitTests.RigidControlScanTests/noRigidComponentIsHeldToAWidthFrame(component:)
    /// ```
    ///
    /// The issue message is not quoted because the script deletes its log
    /// before printing (`docs/BACKLOG.md`, the row beginning
    /// "`scripts/mutation-probe` prints the names of the tests that caught a
    /// plant"); the catcher's name and the control's zero are what it reports.
    @Test(arguments: RigidControlScanTests.components)
    fileprivate func noRigidComponentIsHeldToAWidthFrame(component: Component) throws {
        let sources = try Self.blankedSources()
        let calls = Self.callChains(of: component, in: sources)
        let offenders = calls.filter { call in
            call.chain.contains { Self.count(Self.widthFramePattern, in: $0) > 0 }
        }
        #expect(
            offenders.isEmpty,
            "\(component.name) in a width frame at: \(offenders.map(\.site).joined(separator: ", "))")

        var inspected: [String: Int] = [:]
        for call in calls {
            inspected[String(call.site.split(separator: ":")[0]), default: 0] += 1
        }
        #expect(inspected == component.sites, "\(component.name) called at [\(Self.describe(inspected))]")
    }

    /// The positive for the reader itself: a planted frame is found in each
    /// place one can be written, and a frame belonging to another view is not.
    @Test func theCallChainReaderSeesWhatItIsWrittenToSee() {
        func chains(_ text: String) -> [[String]] {
            Self.callChains(of: Self.components[0], in: ["X.swift": text]).map(\.chain)
        }
        func caught(_ text: String) -> Bool {
            chains(text).contains { chain in
                chain.contains { Self.count(Self.widthFramePattern, in: $0) > 0 }
            }
        }

        // The frame on the line that closes the call.
        #expect(caught("SegmentedChoice(a, selection: b).frame(width: 150)"))
        // A multi-line call with nested parentheses and a bracketed array, the
        // frame on the line after the one that closes it.
        #expect(
            caught(
                """
                SegmentedChoice(
                    x, selection: y,
                    options: [
                        (false, f(a)),
                        (true, f(b)),
                    ])
                .frame(width: 150)
                """))
        // Another modifier and a blank line do not end the chain.
        #expect(caught("SegmentedChoice(a)\n.help(h)\n\n.frame(maxWidth: 118)"))
        // A frame on an enclosing view, past the `}` that ends the chain.
        #expect(!caught("VStack {\nSegmentedChoice(a)\n}\n.frame(width: 150)"))
        // The modifier shapes the call sites really carry.
        #expect(!caught("SegmentedChoice(a)\n.help(h)"))
        #expect(!caught("SegmentedChoice(a)"))
        // A call the reader cannot close reads as an empty chain, not as a hit.
        #expect(chains("SegmentedChoice(a, selection: b") == [[]])

        // The frame pattern's own edges. `.frame(minWidth: 100)` sat in the
        // must-NOT-match list until 2026-10-18, on the strength of the
        // withdrawn sentence quoted above `widthFramePattern`; measured, it
        // collapses the minimum to 100.0 exactly as a hard width does, so it
        // belongs here. An infinite cap is the one spelling that does not.
        for sample in [
            ".frame(width: 150)", ".frame( width : 150)", ".frame(maxWidth: 118)",
            ".frame(minWidth: 100)", ".frame(minWidth: 100, maxWidth: 200)",
            ".frame(minWidth: 100, maxWidth: .infinity)", ".padding().frame(width: 150)",
        ] {
            #expect(Self.count(Self.widthFramePattern, in: sample) == 1, "must match: \(sample)")
        }
        for sample in [
            ".frame(height: 150)", ".frame(idealWidth: 100)", ".frame(maxWidth: .infinity)",
            ".fixedSize()",
        ] {
            #expect(Self.count(Self.widthFramePattern, in: sample) == 0, "must not match: \(sample)")
        }
    }

    /// Why the blanked view is read here too: `RigidControls.swift`'s header
    /// writes a call in prose, and a scanner cannot tell that from a call. It
    /// is the twentieth line the three greps return, and the nineteen counted
    /// above exclude it.
    @Test func theCallSiteScanReadsCodeAndNotProse() throws {
        let sources = try Self.blankedSources()
        let component = try #require(sources[Self.componentFile])
        #expect(component.contains("struct CheckboxRow"))
        #expect(Self.callChains(of: Self.components[2], in: [Self.componentFile: component]).isEmpty)

        let prose = "// CheckboxRow(_:isOn:wraps:)\nCheckboxRow(x)\n.frame(width: 10)\n"
        #expect(Self.count(Self.components[2].pattern, in: prose) == 2)
        let blanked = try SwiftSource.blankingCommentsAndStrings(prose)
        let found = Self.callChains(of: Self.components[2], in: ["X.swift": blanked])
        #expect(found.count == 1)
        let chain = try #require(found.first?.chain)
        #expect(chain.contains { Self.count(Self.widthFramePattern, in: $0) > 0 })
    }

    // MARK: - Default 1: the tag filter's join picker

    private static let joinPickerFile = "SidebarTagFilterBar.swift"
    private static let joinDefaultPattern =
        #"(?:^|\W)var\s+presentation\s*:\s*Presentation\s*(?:=\s*(\.\w+))?"#

    /// The text after the declaration of `typeName`, or nil when it is gone.
    private static func text(after marker: String, in code: String) -> String? {
        code.range(of: marker).map { String(code[$0.upperBound...]) }
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        let nsText = text as NSString
        return regex(pattern).matches(in: text, range: NSRange(location: 0, length: nsText.length)).map {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? nsText.substring(with: $0.range(at: 1)) : ""
        }
    }

    /// Flip the default and the tag dialog, whose call names no presentation,
    /// silently becomes a pop-up, with nothing else red: the bound guard on the
    /// dialog only gets narrower. This is the declaration's own check.
    @Test func theJoinPickerDefaultsToTheSegmentedForm() throws {
        let sources = try Self.blankedSources()
        let code = try #require(sources[Self.joinPickerFile])
        let body = try #require(Self.text(after: "struct TagFilterJoinPicker", in: code))
        let defaults = Self.captures(Self.joinDefaultPattern, in: body)
        #expect(defaults == [".segmented"], "presentation declarations and their defaults: \(defaults)")
    }

    /// The declaration check reads one default; this reads who relies on it. The
    /// dialog is the one call that names no presentation and the sidebar row is
    /// the one that names `.compactMenu`. Arguments are read up to the first
    /// `)`, so a call with a nested parenthesis in front of `presentation:` is
    /// read short and counted as a default user, which is the loud direction.
    @Test func theJoinPickerHasTwoCallSitesAndOnlyTheSidebarNamesAForm() throws {
        let sources = try Self.blankedSources()
        var arguments: [String] = []
        for (_, code) in sources {
            arguments += Self.captures(#"(?:^|\W)TagFilterJoinPicker\(([^)]*)\)"#, in: code)
        }
        let named = arguments.filter { Self.count(#"(?:^|\W)presentation\s*:"#, in: $0) > 0 }
        let defaulted = arguments.filter { Self.count(#"(?:^|\W)presentation\s*:"#, in: $0) == 0 }
        #expect(defaulted.count == 1, "calls relying on the default: \(defaulted)")
        #expect(named.count == 1, "calls naming a presentation: \(named)")
        #expect(
            named.allSatisfy { Self.count(#"presentation\s*:\s*\.compactMenu(?!\w)"#, in: $0) == 1 },
            "\(named)")
    }

    @Test func theJoinPickerPatternsMatchWhatTheyAreWrittenToMatch() {
        func defaults(_ text: String) -> [String] { Self.captures(Self.joinDefaultPattern, in: text) }
        #expect(defaults("    var presentation: Presentation = .segmented") == [".segmented"])
        #expect(defaults("    var presentation: Presentation = .compactMenu") == [".compactMenu"])
        #expect(defaults("    var presentation: Presentation") == [""])
        #expect(defaults("    @State var presentation: Presentation = .segmented") == [".segmented"])
        #expect(defaults("    let presentation: Presentation = .segmented").isEmpty)
        #expect(defaults("    var presentationX: Presentation = .segmented").isEmpty)

        func calls(_ text: String) -> [String] {
            Self.captures(#"(?:^|\W)TagFilterJoinPicker\(([^)]*)\)"#, in: text)
        }
        #expect(calls("TagFilterJoinPicker(filter: $filter)") == ["filter: $filter"])
        #expect(calls("    TagFilterJoinPicker(filter: $f, presentation: .compactMenu)").count == 1)
        #expect(calls("x = Module.TagFilterJoinPicker(filter: $f)").count == 1)
        #expect(calls("TagFilterJoinPicker(\n  filter: $f,\n  presentation: .compactMenu\n)").count == 1)
        #expect(calls("struct TagFilterJoinPicker: View {").isEmpty)
        #expect(calls("MyTagFilterJoinPicker(filter: $f)").isEmpty)
    }

    // MARK: - Default 2: the checkbox's wrapping

    private static let componentFile = "RigidControls.swift"
    private static let wrapsDefaultPattern = #"(?:^|\W)wraps\s*:\s*Bool\s*=\s*(\w+)"#
    private static let checkboxBodyPattern =
        #"\.fixedSize\(\s*horizontal\s*:\s*!wraps\s*,\s*vertical\s*:\s*true\s*\)"#

    /// Flip the default and every rigid checkbox starts wrapping; the width
    /// guards stay green because a wrapped label loses no text. Flip the `!` in
    /// the body and the same happens for the sites that pass `wraps: true`, in
    /// reverse. Both are single tokens, so both are read.
    @Test func theCheckboxRowDefaultsToRigid() throws {
        let sources = try Self.blankedSources()
        let code = try #require(sources[Self.componentFile])
        let body = try #require(Self.text(after: "struct CheckboxRow", in: code))
        #expect(Self.captures(Self.wrapsDefaultPattern, in: body) == ["false"])
        #expect(Self.count(Self.checkboxBodyPattern, in: body) == 1)
    }

    /// The seam's users. Counted 2026-10-18 with
    /// `grep -rn 'wraps:' Sources/MacSCPAppKit`, which prints 5 lines: in
    /// `RigidControls.swift` two comments, the stored property and the
    /// initializer (all excluded here), and in `SnippetsSheet.swift` the one
    /// site that opts in.
    ///
    /// **Corrected 2026-10-21 (S3 bucket settings, Task 10).** The paragraph
    /// above read, verbatim: "which prints 5 lines" and "the one site that opts
    /// in". The same command now prints 7 (`grep -rn 'wraps:' Sources/MacSCPAppKit | wc -l`,
    /// under the session's `grep` and `/usr/bin/grep` alike): the five, plus the
    /// COMPLIANCE acknowledgement in each of the two Object Lock sheets
    /// (`ObjectLockSheet.swift`, `BucketObjectLockSheet.swift`), one site each.
    /// Each is a sentence too long for one line, and it is the line that must
    /// not be cut.
    @Test func onlyTheListedSitesOptIntoWrapping() throws {
        let sources = try Self.blankedSources().filter { $0.key != Self.componentFile }
        let labelled = Self.counts(#"(?:^|\W)wraps\s*:"#, in: sources)
        let wrapping = Self.counts(#"(?:^|\W)wraps\s*:\s*true(?!\w)"#, in: sources)
        let expected = [
            "BucketObjectLockSheet.swift": 1, "ObjectLockSheet.swift": 1, "SnippetsSheet.swift": 1,
        ]
        #expect(wrapping == expected, "wraps: true at [\(Self.describe(wrapping))]")
        // Every use of the label is the literal `true`; a variable or a `false`
        // is a site this list does not know.
        #expect(labelled == wrapping, "wraps: at [\(Self.describe(labelled))]")
    }

    @Test func theCheckboxPatternsMatchWhatTheyAreWrittenToMatch() {
        func defaults(_ text: String) -> [String] { Self.captures(Self.wrapsDefaultPattern, in: text) }
        #expect(defaults("init(_ label: String, isOn: Binding<Bool>, wraps: Bool = false) {") == ["false"])
        #expect(defaults("init(_ label: String, isOn: Binding<Bool>, wraps: Bool = true) {") == ["true"])
        #expect(defaults("init(wraps: Bool = false)") == ["false"])
        #expect(defaults("init(_ label: String, isOn: Binding<Bool>, wraps: Bool) {").isEmpty)
        #expect(Self.count(Self.checkboxBodyPattern, in: "            .fixedSize(horizontal: !wraps, vertical: true)") == 1)
        #expect(Self.count(Self.checkboxBodyPattern, in: "            .fixedSize(horizontal: wraps, vertical: true)") == 0)
        #expect(Self.count(#"(?:^|\W)wraps\s*:\s*true(?!\w)"#, in: "x, wraps: true)") == 1)
        #expect(Self.count(#"(?:^|\W)wraps\s*:\s*true(?!\w)"#, in: "x, wraps: trueish)") == 0)
        #expect(Self.count(#"(?:^|\W)wraps\s*:"#, in: "CheckboxRow(\"a\", isOn: $x, wraps: flag)") == 1)
    }

    // MARK: - Default 3: the resizable-container seam

    private static let seamPattern = #"(?:^|\W)isInAResizableContainer(?!\w)"#

    /// Both sites that carried `isInAResizableContainer` were resolved rather
    /// than opted out (`ResizableContainerFloorTests` measures why), so there are
    /// zero declarations and zero uses. The name is read in the blanked view,
    /// because the component file's header quotes it in prose.
    @Test func theResizableContainerSeamIsGone() throws {
        let sources = try Self.blankedSources()
        let found = Self.counts(Self.seamPattern, in: sources)
        #expect(found.isEmpty, "isInAResizableContainer appears at [\(Self.describe(found))]")
    }

    /// The positive beside it. A scan for something ABSENT passes on an empty
    /// corpus, so this requires the corpus to hold the two files the seam used
    /// to live in, and the pattern to see a declaration and a use in each of
    /// the places a name can stand.
    @Test func theSeamScanReadsTheFilesTheSeamUsedToLiveIn() throws {
        let sources = try Self.blankedSources()
        let picker = try #require(sources[Self.joinPickerFile])
        #expect(picker.contains("TagFilterJoinPicker"))
        let search = try #require(sources["SheetSearchField.swift"])
        #expect(search.contains("SheetSearchField"))

        let samples = [
            "    var isInAResizableContainer: Bool = false",
            "SheetSearchField(text: $t, isInAResizableContainer: true)",
            "isInAResizableContainer",
            "self.isInAResizableContainer",
            "Module.isInAResizableContainer",
            "(isInAResizableContainer)",
        ]
        for sample in samples {
            #expect(Self.count(Self.seamPattern, in: sample) == 1, "must match: \(sample)")
        }
        for sample in ["isInAResizableContainers", "xisInAResizableContainer", "isInAResizableContainerX"] {
            #expect(Self.count(Self.seamPattern, in: sample) == 0, "must not match: \(sample)")
        }

        // The reason the blanked view is read: prose that names the seam must
        // not count, and a use in code must.
        let prose = "// isInAResizableContainer was removed\n/// `isInAResizableContainer: true`\nlet x = 1\n"
        #expect(Self.count(Self.seamPattern, in: prose) == 2)
        let blanked = try SwiftSource.blankingCommentsAndStrings(prose)
        #expect(Self.count(Self.seamPattern, in: blanked) == 0)
        let used = try SwiftSource.blankingCommentsAndStrings("f(isInAResizableContainer: true)\n")
        #expect(Self.count(Self.seamPattern, in: used) == 1)
    }
}
