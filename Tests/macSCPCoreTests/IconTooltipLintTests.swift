import Foundation
import Testing

/// Guards ONE property: that every icon in the app target has been DECIDED
/// about — it carries a hover hint, or it is on the decorative list below with
/// a reason. The app is not purely SwiftUI, so BOTH halves are scanned:
/// SwiftUI's `Image(systemName:)` / `systemImage:` and AppKit's
/// `NSImage(systemSymbolName:)`, and a hint is either a `.help(…)` or an
/// AppKit `toolTip =` assignment. It deliberately does not check that a hint
/// is good, or even that it sits on the right element: a `.help` on a
/// NEIGHBOURING control within the proximity window satisfies the scan
/// (`SheetSearchField`'s magnifier passes on the regex toggle's hint, seven
/// lines down). The window is a heuristic, unusual formatting can fool it, and
/// the list needs maintenance by hand. In M19 a lint of this shape caught two
/// real gaps — but only after a reviewer defeated an earlier version of it
/// with a line break, so treat its reach as narrow and its value as "nobody
/// adds an icon without thinking", nothing more.
///
/// Neither `.accessibilityLabel` (SwiftUI) nor `accessibilityDescription:`
/// (AppKit) counts as a decision. They label the control for VoiceOver and
/// produce no hover hint at all — the "remove rule" button in `SettingsView`
/// had exactly that and still needed a `.help` (M19a/T1), so the two live side
/// by side there with the same key; the menu-bar status item had exactly that
/// and still needed a `toolTip` (M19a/T2, found the day the AppKit spelling
/// was added to this scan).
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
/// - A HELPER that builds an icon (`func iconButton(_ name: String) -> some
///   View { … Image(systemName: name) … }`) is scanned once, at its body, with
///   the symbol `name`; every call site then becomes invisible and a single
///   entry blankets all of them. No such helper exists today — but extracting
///   one is ordinary refactoring, not evasion, so a later reader has to know
///   that it silently shrinks this test's reach.
/// - The area a hint may live in is small but LOPSIDED. **Measured
///   2026-09-03 at `8997c955`** (the file grew five lines in the commit
///   that wrote this, so the numbers describe that tree, not HEAD) by replaying this file's own scanner (`code(of:)` →
///   `icons(in:)`, the union of the `hintWindow` lines every icon opens,
///   divided by the file's line count): the windows cover **2.01%** of the
///   app target's lines overall (569 of 28373, across 69 files), and they
///   bunch up in exactly the icon-dense files where the next icon-only
///   button will be added — `SheetSearchField` **21.7%**,
///   `TransferQueueBar` **18.5%**, `FileSearchBar` **17.0%**,
///   `MenuBarController` **11.8%**. In those files a stray `.help` on an
///   unrelated control is fairly likely to sit inside somebody else's
///   window.
///
///   Every one of those figures is a claim about the rest of the tree, so
///   it carries the date it was counted on. The five it replaces were
///   written on 2026-08-03 (`27456c70`) and never recounted: four had gone
///   stale by 2026-09-03, the worst by 10.5 points (`TabStripView`, then
///   15%, now **4.5%** — the file more than tripled in length while its
///   icons did not), and it is no longer in the top four at all. Recount
///   them here rather than adjust them: the method above reproduces the
///   2026-08-03 figures exactly at `27456c70`, which is how it was
///   validated.
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
            file: "SnippetsSheet.swift", symbol: "plus",
            reason: "Inside a `Label` whose visible title is \"Add variable\" — the button is not icon-only."),
        DecorativeIcon(
            file: "SessionSidebar.swift", symbol: "checkmark",
            reason: "Marks the session's current group in the \"Move to\" menu; a menu item's own text is its explanation."),
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "section.systemImage",
            reason: "Settings sidebar rows; each `Label` shows the section title next to the glyph and macOS gives list rows no tooltip."),
        // The five "Manage Data" rows. Each glyph sits inside the `Label` of
        // the button it decorates, whose visible title IS the name of the
        // sheet that button opens ("SSH Keys…", "Logins…", …) — a hint could
        // only repeat it. Listed one per symbol rather than routed through a
        // variable, so adding a sixth row still trips this scan.
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "key",
            reason: "Inside the \"SSH Keys…\" button's `Label` in the Manage Data list; the button's own title names the sheet."),
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "person.badge.key",
            reason: "Inside the \"Logins…\" button's `Label` in the Manage Data list; the button's own title names the sheet."),
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "lock.shield",
            reason: "Inside the \"Known Hosts…\" button's `Label` in the Manage Data list; the button's own title names the sheet."),
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "checkmark.seal",
            reason: "Inside the \"Server Certificates…\" button's `Label` in the Manage Data list; the button's own title names the sheet."),
        DecorativeIcon(
            file: "SettingsView.swift", symbol: "eye.slash",
            reason: "Inside the \"Hidden Imports…\" button's `Label` in the Manage Data list; the button's own title names the sheet (with its count)."),
        DecorativeIcon(
            file: "MenuBarController.swift", symbol: "circle.fill",
            reason: "Colour-coded status dot on a menu ITEM, whose own title already spells the state out in words (Connected/Connecting…/Failed/Ready); `NSMenuItem.image` takes no tooltip of its own."),
        DecorativeIcon(
            file: "ContentView+Detail.swift", symbol: "exclamationmark.triangle.fill",
            reason: "Heads the lost-connection surface, directly above its own headline (\"Connection lost\") and a sentence saying what happened; it takes no click, and a tooltip could only repeat the two lines under it."),
        DecorativeIcon(
            file: "ContentView+Detail.swift", symbol: "bolt.horizontal.circle.fill",
            reason: "Heads the failed-connect surface, directly above its own headline (\"No connection possible\") and a sentence saying what happened, exactly as the lost-connection icon above it does; it takes no click, and the technical detail a tooltip could add lives behind that surface's own Details control instead."),
    ]

    /// How far below an icon a hover hint still counts as belonging to it.
    ///
    /// Measured against the real code rather than guessed — but read the shape
    /// of the measurement, not just its maximum. Of the 24 icons that reach a
    /// hint at all, 18 sit at a distance of 2–4 lines; the tail is thin and
    /// almost entirely made of single cases: 7 (four icons), then 8 exactly
    /// once (`SettingsView`'s `minus.circle`, padded by a four-line comment —
    /// comments are blanked in place, not deleted, so they still cost lines),
    /// then **9** exactly once (`SessionSidebar.swift:292 → 301`,
    /// `arrow.down.doc`, whose hint sits on the enclosing `HStack` after the
    /// label, spacer and gesture modifiers). So 12 is the lone 9-line outlier
    /// plus room for a couple more modifiers — not a typical distance doubled.
    /// Re-derive it the same way if it ever needs to move; do not widen it to
    /// silence a finding.
    private static let hintWindow = 12

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/IconTooltipLintTests.swift`; three
    /// `deletingLastPathComponent()` calls recover the repo root regardless of
    /// `swift test`'s working directory (same trick as `LocalizableStringsTests`
    /// and `EmbeddedKeyPorterTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSources: URL = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit")

    /// Findings name a REPO-RELATIVE path, so the reader can open the file
    /// straight from the failure line; the absolute path is the fallback when
    /// something unexpected sits outside the checkout.
    ///
    /// The trailing slash has to come off first: `repoRoot` is a DIRECTORY
    /// URL, and `path(percentEncoded:)` keeps its trailing separator where the
    /// older `.path` property stripped it. Without this, the prefix compared
    /// is `…/macSCP//` — which never matches, so every finding silently took
    /// the absolute-path fallback (`findingsNameARepoRelativePath` holds this
    /// down).
    private static func repoRelativePath(of file: URL) -> String {
        var root = repoRoot.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        let path = file.path(percentEncoded: false)
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

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
            let path = Self.repoRelativePath(of: file)
            for finding in Self.undecidedIcons(file: name, source: source) {
                Issue.record("""
                    \(path):\(finding.line): icon "\(finding.symbol)" has no hover hint. \
                    Add a `.help(…)` — or, in AppKit, a `toolTip` — to the control it \
                    belongs to, or, if it explains nothing because it is not a hit \
                    target, put it on `decorativeIcons` with a reason. \
                    (`.accessibilityLabel` and `accessibilityDescription:` do not \
                    count: they are for VoiceOver and produce no tooltip.)
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

    /// The AppKit half of the app is scanned by the same rules: an
    /// `NSImage(systemSymbolName:)` on a hit target needs a `toolTip`, and the
    /// `accessibilityDescription:` sitting right there does NOT stand in for
    /// one. This is the shape of the live gap the needle surfaced on the
    /// menu-bar status item (M19a/T2).
    @Test func scanFlagsAnAppKitSymbolWithNoToolTip() {
        let source = """
            let image = NSImage(
                systemSymbolName: "arrow.up.arrow.down",
                accessibilityDescription: "macSCP")
            button.image = image
            """
        let found = Self.undecidedIcons(file: "Synthetic.swift", source: source)
        #expect(found.map(\.symbol) == ["arrow.up.arrow.down"])
        #expect(found.first?.line == 2)
    }

    /// …and the same symbol passes once the button carries a real tooltip.
    @Test func scanAcceptsAToolTipAsAHint() {
        let hinted = """
            button.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
            button.toolTip = "Settings"
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: hinted).isEmpty)

        // A reset to nil is not a hint — it is the other half of a recycling
        // branch, and vouching for the icon on it would be a lie.
        let cleared = """
            cell.imageView?.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            cell.toolTip = nil
            """
        #expect(Self.undecidedIcons(file: "Synthetic.swift", source: cleared).count == 1)
    }

    /// A finding names a path the reader can act on. Worth its own test
    /// because the obvious spelling silently does the wrong thing:
    /// `URL.path(percentEncoded:)` KEEPS a directory URL's trailing slash
    /// (unlike the older `.path` property), so a naive
    /// `hasPrefix(root + "/")` never matches and every finding quietly falls
    /// back to the absolute path — green tests, useless output.
    @Test func findingsNameARepoRelativePath() {
        let file = Self.appSources.appendingPathComponent("TabStripView.swift")
        #expect(Self.repoRelativePath(of: file) == "Sources/MacSCPAppKit/TabStripView.swift")

        // Anything outside the checkout keeps its absolute path rather than
        // being mangled into a misleading relative one.
        let outside = URL(fileURLWithPath: "/somewhere/else/Other.swift")
        #expect(Self.repoRelativePath(of: outside) == "/somewhere/else/Other.swift")
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

    /// All three spellings of "this is an SF Symbol": SwiftUI's
    /// `Image(systemName:)` and the `systemImage:` label shared by `Label`,
    /// `Button`, `Toggle` and friends, plus AppKit's
    /// `NSImage(systemSymbolName:)` — the app is not purely SwiftUI (menu bar,
    /// file table), and an icon the scan cannot spell is an icon nobody has to
    /// decide about. Each label is matched on its own rather than as part of
    /// `Image(` so a call that wrapped after the opening paren is still seen.
    private static func icons(in code: [String]) -> [Icon] {
        var found: [Icon] = []
        for (index, line) in code.enumerated() {
            for needle in ["systemName:", "systemImage:", "systemSymbolName:"] {
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

    /// A hover hint anywhere in the `hintWindow` lines starting at the icon's
    /// own line (a one-line `Button { … }.help(…)` counts), in either
    /// framework's spelling: SwiftUI's `.help(…)` or AppKit's `toolTip = …`.
    /// Whitespace is squeezed out of the window first: Swift lets a call wrap
    /// anywhere, so `.help(\n…)` and `.help\n(…)` are the same call and must
    /// satisfy the same needle — matching literal text is exactly how the M19
    /// source lint was walked past.
    private static func hasHint(below line: Int, in code: [String]) -> Bool {
        let start = line - 1
        let end = min(start + hintWindow, code.count - 1)
        guard start <= end else { return false }
        let window = code[start...end].joined().filter { !$0.isWhitespace }
        if window.contains(".help(") { return true }
        // `toolTip = nil` is the OPPOSITE of a decision — it is the reset half
        // of a cell-recycling branch (`RemoteFileTableView` writes both on
        // every reuse), so only an assignment of something else vouches.
        var cursor = window.startIndex
        while let match = window.range(of: "toolTip=", range: cursor..<window.endIndex) {
            cursor = match.upperBound
            if !window[match.upperBound...].hasPrefix("nil") { return true }
        }
        return false
    }
}
