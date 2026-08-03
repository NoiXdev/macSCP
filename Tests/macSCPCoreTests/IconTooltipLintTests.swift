import Foundation
import Testing

/// Guards ONE property: that every icon in the app target has been DECIDED
/// about — it carries a hover hint, or it is on the decorative list below with
/// a reason. It deliberately does not check that a hint is good, or even that
/// it sits on the right element: a `.help` on a NEIGHBOURING control within the
/// proximity window satisfies the scan (`SheetSearchField`'s magnifier passes
/// on the regex toggle's hint, seven lines down). The window is a heuristic,
/// unusual formatting can fool it, and the list needs maintenance by hand. In
/// M19 a lint of this shape caught two real gaps — but only after a reviewer
/// defeated an earlier version of it with a line break, so treat its reach as
/// narrow and its value as "nobody adds an icon without thinking", nothing
/// more.
///
/// `.accessibilityLabel` does NOT count as a decision. It labels the control
/// for VoiceOver and produces no hover hint at all — the "remove rule" button
/// in `SettingsView` had exactly that and still needed a `.help` (M19a/T1), so
/// the two live side by side there with the same key.
///
/// Known blind spots, so nobody mistakes a green run for a proof:
/// - The app target has no test target of its own (`Package.swift` declares
///   only `macSCPCoreTests`), so this reads SOURCE TEXT and never renders a
///   view. Nothing here can tell whether a tooltip actually appears.
/// - A list entry allows EVERY occurrence of that symbol in that file, not one
///   line — keying on line numbers would go stale on the next edit.
/// - Icons named through a variable (`SettingsSection.systemImage`'s `switch`
///   returns bare strings) are invisible; the decision is recorded at the call
///   site that passes them, which is what the scan sees.
@Suite("IconTooltipLint")
struct IconTooltipLintTests {
    private struct DecorativeIcon {
        let file: String
        let symbol: String
        let reason: String
    }

    /// Icons that are deliberately left without a hover hint — they are not a
    /// hit target of their own, or a visible label right next to them already
    /// says what the control does, so a hint would have nothing to add. One
    /// line of reasoning per entry: the point of this list is that somebody
    /// DECIDED, not that the list is short.
    private static let decorativeIcons: [DecorativeIcon] = [
        DecorativeIcon(
            file: "TransferQueueBar.swift", symbol: "arrow.up",
            reason: "Direction glyph on a queue row; the row is not clickable and its text names the file being moved."),
        // Not load-bearing today — the `.failed` case's `.help(message)` seven
        // lines down happens to fall inside the window, which is the blind spot
        // above in the flesh. The entry stays because it records the decision
        // the scan is currently making for the wrong reason.
        DecorativeIcon(
            file: "TransferQueueBar.swift", symbol: "checkmark.circle.fill",
            reason: "Status glyph for a finished transfer, in the slot the other states fill with the word (queued/cancelled/…)."),
        DecorativeIcon(
            file: "FileSearchBar.swift", symbol: "magnifyingglass",
            reason: "Leading glyph of the search field itself; the field's placeholder is the label and the glyph takes no click."),
        DecorativeIcon(
            file: "SessionSidebar.swift", symbol: "plus",
            reason: "Inside a `Label` whose visible title is \"New connection\" — the button is not icon-only."),
        DecorativeIcon(
            file: "SessionSidebar.swift", symbol: "checkmark",
            reason: "Marks the session's current group in the \"Move to\" menu; a menu item's own text is its explanation."),
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "section.systemImage",
            reason: "Settings sidebar rows; each `Label` shows the section title next to the glyph and macOS gives list rows no tooltip."),
        DecorativeIcon(
            file: "ContentView.swift", symbol: "xmark.circle.fill",
            reason: "Dismisses the inline edit-error banner it sits in; the banner's own text is the message, and the ✕ is its only control."),
    ]

    /// How far below an icon a `.help` still counts as belonging to it.
    ///
    /// Measured against the real code rather than guessed: the longest gap any
    /// currently hinted icon has to its `.help` is **9** lines
    /// (`SessionSidebar`'s `arrow.down.doc`, whose hint sits on the enclosing
    /// `HStack` after the label, spacer and gesture modifiers); second longest
    /// is 8 (`SettingsView`'s `minus.circle`, padded by a four-line comment —
    /// comments are blanked in place, not deleted, so they still cost lines).
    /// Twelve is that 9 plus room for a couple more modifiers before a future
    /// chain trips this test for the wrong reason. Re-derive it the same way if
    /// it ever needs to move; do not widen it to silence a finding.
    private static let hintWindow = 12

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/IconTooltipLintTests.swift`; three
    /// `deletingLastPathComponent()` calls recover the repo root regardless of
    /// `swift test`'s working directory (same trick as `LocalizableStringsTests`
    /// and `EmbeddedKeyPorterTests`).
    private static let appSources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPApp")

    // MARK: - The guard

    @Test func everyIconIsExplainedOrDeliberatelyDecorative() throws {
        let files = try Self.swiftFiles()
        // A moved or renamed source tree must FAIL here, not scan nothing and
        // report success. The app target has had well over twenty files since
        // M8; the number is a floor, not a census.
        guard files.count >= 20 else {
            Issue.record(
                "only \(files.count) Swift file(s) under \(Self.appSources.path) — re-anchor this lint")
            return
        }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            for finding in Self.undecidedIcons(file: name, source: source) {
                Issue.record("""
                    \(name):\(finding.line): icon "\(finding.symbol)" has no hover hint. \
                    Add a `.help(…)` to the control it belongs to, or — if it explains \
                    nothing because it is not a hit target — put it on `decorativeIcons` \
                    with a reason. (`.accessibilityLabel` does not count: it is for \
                    VoiceOver and produces no tooltip.)
                    """)
            }
        }
    }

    /// The list is an allowance, and an allowance for something that no longer
    /// exists is a lie about the code. This is the only thing that prunes it.
    @Test func everyDecorativeEntryStillNamesALiveIcon() throws {
        let files = try Self.swiftFiles()
        for entry in Self.decorativeIcons {
            guard let file = files.first(where: { $0.lastPathComponent == entry.file }) else {
                Issue.record("decorativeIcons names \(entry.file), which no longer exists")
                continue
            }
            let icons = Self.icons(in: Self.code(of: try String(contentsOf: file, encoding: .utf8)))
            #expect(
                icons.contains { $0.symbol == entry.symbol },
                "\(entry.file) no longer uses \(entry.symbol) — drop the decorativeIcons entry")
        }
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The mutations the M19a plan asks for by hand, kept as a permanent test
    /// so a later rewrite of the scanner cannot quietly stop reacting.
    @Test func scanFlagsAnIconWithNoHintNearby() {
        let source = """
            Button(action: onTap) {
                Image(systemName: "star")
            }
            .buttonStyle(.plain)
            """
        let found = Self.undecidedIcons(file: "Synthetic.swift", source: source)
        #expect(found.map(\.symbol) == ["star"])
        #expect(found.first?.line == 2)
    }

    /// `.accessibilityLabel` is the trap this whole lint exists to name: it
    /// looks like a label and produces no tooltip.
    @Test func scanDoesNotAcceptAnAccessibilityLabelAsAHint() {
        let source = """
            Button(action: onTap) {
                Image(systemName: "gear")
            }
            .accessibilityLabel("Settings")
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: source).count == 1)
    }

    /// A hint is a hint however the call wraps — the M19 lesson: an earlier
    /// source lint in this suite was defeated first by a line break and then by
    /// an ordinary alternative spelling of the same call. Whitespace is
    /// squeezed out of the window before matching for exactly that reason.
    @Test func scanAcceptsAHintHoweverItIsWrapped() {
        let variants = [
            #"    .help("Add")"#,
            "    .help(\n        \"Add\")",
            "    .help\n        (\"Add\")",
        ]
        for variant in variants {
            let source = """
                Button(action: onTap) {
                    Image(systemName: "plus")
                }
                \(variant)
                """
            #expect(
                Self.undecidedIcons(file: "Synthetic.swift", source: source).isEmpty,
                "the scan missed a hint spelled <\(variant)>")
        }
        // …and a hint further away than the window is NOT a hint for this icon.
        let distant = ["Image(systemName: \"plus\")"]
            + Array(repeating: "    .padding()", count: Self.hintWindow)
            + ["    .help(\"Add\")"]
        #expect(Self.undecidedIcons(
            file: "Synthetic.swift", source: distant.joined(separator: "\n")).count == 1)
    }

    /// Commented-out code must not vouch for live code — nor may prose about
    /// `.help` in a comment count as a hint.
    @Test func scanIgnoresComments() {
        let commentedIcon = """
            // Image(systemName: "star")
            Text("hello")
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: commentedIcon).isEmpty)

        let commentedHint = """
            Image(systemName: "star")
            // was: .help("Star")
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: commentedHint).count == 1)

        // A `//` inside a string literal is not a comment.
        let urlInString = """
            Image(systemName: "star")
            Text("https://example.invalid").help("Star")
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: urlInString).isEmpty)
    }

    /// `SettingsSection` declares `var systemImage: String` — a property, not
    /// an icon. The declaration has nothing to explain; its call sites do, and
    /// they are scanned.
    @Test func scanIgnoresASystemImagePropertyDeclaration() {
        let source = """
            var systemImage: String {
                switch self {
                case .general: return "gearshape"
                }
            }
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: source).isEmpty)
    }

    @Test func scanNamesTheSymbolItFound() {
        // A ternary reports its FIRST branch — one occurrence, one name.
        let ternary = #"Image(systemName: flag ? "arrow.up" : "arrow.down")"#
        #expect(Self.icons(in: Self.code(of: ternary)).map(\.symbol) == ["arrow.up"])
        // A non-literal argument reports the expression, which is what the
        // decorative list then has to name.
        let indirect = "Label(section.title, systemImage: section.systemImage)"
        #expect(Self.icons(in: Self.code(of: indirect)).map(\.symbol) == ["section.systemImage"])
        // An argument that wrapped onto the next line is still found.
        let wrapped = "Label(title,\n      systemImage: \"tray.full\")"
        #expect(Self.icons(in: Self.code(of: wrapped)).map(\.symbol) == ["tray.full"])
    }

    // MARK: - Scanner

    private struct Icon {
        let line: Int
        let symbol: String
    }

    private static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: appSources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Every icon in `source` that neither has a `.help` within
    /// `hintWindow` lines nor an entry on `decorativeIcons`.
    private static func undecidedIcons(file: String, source: String) -> [Icon] {
        let code = self.code(of: source)
        return icons(in: code).filter { icon in
            if hasHint(below: icon.line, in: code) { return false }
            return !decorativeIcons.contains { $0.file == file && $0.symbol == icon.symbol }
        }
    }

    /// Comments go before anything is matched, so a commented-out icon does not
    /// count and prose about `.help` does not vouch for anything. Lines are
    /// BLANKED rather than removed, because the finding has to name a line
    /// number the reader can open. String literals are respected, so a `//` in
    /// a URL does not swallow the rest of its line.
    private static func code(of source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var out = ""
            var inString = false
            var escaped = false
            var previous: Character?
            for character in line {
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    out.append(character)
                    previous = character
                    continue
                }
                if character == "\"" {
                    inString = true
                } else if character == "/", previous == "/" {
                    out.removeLast()
                    break
                }
                out.append(character)
                previous = character
            }
            return out
        }
    }

    /// Both spellings of "this is an SF Symbol": `Image(systemName:)` and the
    /// `systemImage:` label shared by `Label`, `Button`, `Toggle` and friends.
    /// The label is matched on its own rather than as part of `Image(` so a
    /// call that wrapped after the opening paren is still seen.
    private static func icons(in code: [String]) -> [Icon] {
        var found: [Icon] = []
        for (index, line) in code.enumerated() {
            for needle in ["systemName:", "systemImage:"] {
                var cursor = line.startIndex
                while let match = line.range(of: needle, range: cursor..<line.endIndex) {
                    cursor = match.upperBound
                    // `var systemImage: String { … }` is a property, not an
                    // icon; the call sites passing it are scanned separately.
                    let head = line[line.startIndex..<match.lowerBound]
                    let lastToken = head
                        .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                        .last
                    if lastToken == "var" || lastToken == "let" { continue }

                    // The argument may wrap; two more lines is more than any
                    // real call needs, and parsing stops at the argument's own
                    // closing paren, so trailing code cannot be mistaken for it.
                    let tail = ([String(line[match.upperBound...])]
                        + code[(index + 1)..<min(index + 3, code.count)]).joined(separator: " ")
                    found.append(Icon(line: index + 1, symbol: symbol(ofArgument: tail)))
                }
            }
        }
        return found
    }

    /// The first string literal inside the argument, or — when the icon is
    /// named indirectly — the argument expression itself, which is then what
    /// `decorativeIcons` has to spell.
    private static func symbol(ofArgument tail: String) -> String {
        var argument = ""
        var depth = 0
        var inString = false
        var escaped = false
        for character in tail {
            if inString {
                argument.append(character)
                if escaped { escaped = false } else if character == "\\" {
                    escaped = true
                } else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; argument.append(character); continue }
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if character == "," && depth == 0 { break }
            argument.append(character)
        }
        if let open = argument.firstIndex(of: "\""),
            let close = argument[argument.index(after: open)...].firstIndex(of: "\"")
        {
            return String(argument[argument.index(after: open)..<close])
        }
        return argument.trimmingCharacters(in: .whitespaces)
    }

    /// A `.help` anywhere in the `hintWindow` lines starting at the icon's own
    /// line (a one-line `Button { … }.help(…)` counts). Whitespace is squeezed
    /// out of the window first: Swift lets a call wrap anywhere, so `.help(\n…)`
    /// and `.help\n(…)` are the same call and must satisfy the same needle —
    /// matching literal text is exactly how the M19 source lint was walked past.
    private static func hasHint(below line: Int, in code: [String]) -> Bool {
        let start = line - 1
        let end = min(start + hintWindow, code.count - 1)
        guard start <= end else { return false }
        return code[start...end].joined().filter { !$0.isWhitespace }.contains(".help(")
    }
}
