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
        // swiftlint:disable:next force_try
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
    /// The left edge is `(?:^|\W)`, not `\b`: a Unicode word boundary finds no
    /// edge in `x.sheetBound(` or `Module.Name`, and an earlier scan on this
    /// branch matched nothing because of it. The right edge is `(?!\w)`.
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
    /// `grep -rn 'wraps:' Sources/MacSCPAppKit`, which prints the component's
    /// declaration and the one site that opts in; the comment lines it also
    /// prints are not code and are not read here. The first read of this scan
    /// listed `wraps: true` once per file by count only; the site is named.
    @Test func onlyTheListedSitesOptIntoWrapping() throws {
        let sources = try Self.blankedSources().filter { $0.key != Self.componentFile }
        let labelled = Self.counts(#"(?:^|\W)wraps\s*:"#, in: sources)
        let wrapping = Self.counts(#"(?:^|\W)wraps\s*:\s*true(?!\w)"#, in: sources)
        let expected = ["SnippetsSheet.swift": 1]
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
