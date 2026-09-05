import Foundation
import Testing
@testable import MacSCPAppKit

/// Guards `WindowLevelPlan` (Detachable Tabs plan, Task 4) and the "Keep on
/// Top" wiring around it: the Window menu's checkmark item, the per-window
/// `TabCommands` box it toggles, and the one place `NSWindow.level` may be
/// assigned in this target.
///
/// `WindowLevelPlan.level(keepOnTop:)` is a pure, stateless mapping — no
/// window, no tab, no timing has any say in the answer — so the two cases
/// below are the whole decision table; nothing else needs a case added
/// here when a third `NSWindow.Level` shows up, because there is no third
/// state this plan represents. `Sendable`/purity holds by construction: an
/// `enum` with only a `static func` closing over nothing carries no state
/// to race on, and needs no separate test to prove it.
///
/// Known blind spot: SOURCE TEXT only, never a running window — nothing
/// here confirms a floating window actually renders above another on
/// screen. That is the maintainer's sight check (Window ▸ Keep on Top on a
/// second window), not something this suite can see headless.
@MainActor
@Suite("WindowLevelPlan and Keep on Top wiring")
struct WindowLevelPlanTests {

    // MARK: - The decision value

    @Test func keepingOnTopFloats() {
        #expect(WindowLevelPlan.level(keepOnTop: true) == .floating)
    }

    @Test func notKeepingOnTopIsNormal() {
        #expect(WindowLevelPlan.level(keepOnTop: false) == .normal)
    }

    // MARK: - Source access

    /// `<repoRoot>/Tests/macSCPAppKitTests/WindowLevelPlanTests.swift`, so
    /// three `deletingLastPathComponent()` calls reach the repo root —
    /// same climb every other guard suite in this file uses.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceDir = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    private static let commandsFile = sourceDir.appendingPathComponent("MacSCPCommands.swift")
    private static let appFile = sourceDir.appendingPathComponent("MacSCPApp.swift")

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    private static func code(of url: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: url, encoding: .utf8))
    }

    private static func codeWithLiterals(of url: URL) throws -> String {
        try SwiftSource.blankingComments(try String(contentsOf: url, encoding: .utf8))
    }

    private static func catalogKeys(_ locale: String) throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(catalogPath(locale)))
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: String]
        else {
            throw CatalogError.unreadable(catalogPath(locale))
        }
        return Set(plist.keys)
    }

    enum CatalogError: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path): "\(path) could not be parsed as a property list"
            }
        }
    }

    /// Every `.swift` file under `Sources/MacSCPAppKit`, recursively —
    /// `find Sources/MacSCPAppKit -type d` turns up `Presentation/`
    /// alongside the top level and `Resources/*.lproj`, so a non-recursive
    /// listing would silently skip a `.level =` assignment placed there.
    /// `Resources/*.lproj` holds no `.swift` files, so the extension
    /// filter excludes it without a separate directory exclusion.
    private static func allAppKitSourceFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceDir, includingPropertiesForKeys: nil)
        else {
            throw CatalogError.unreadable(sourceDir.path)
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    // MARK: - The menu item

    /// The Window menu resolves its label through `L10n.string(` — a
    /// hardcoded literal would never pick up a translation.
    @Test func theKeepOnTopEntryResolvesThroughL10n() throws {
        let source = try Self.codeWithLiterals(of: Self.commandsFile)
        #expect(source.contains("L10n.string(\"window.keepOnTop\""), """
            MacSCPCommands.swift no longer resolves window.keepOnTop through \
            L10n.string( — the Window menu entry would render as its own key text.
            """)
    }

    /// Positive beside the source scans below: the key really is bound to
    /// `tabCommands` and really does call `toggleKeepOnTop` — so the
    /// "reads keepOnTop" / "calls toggleKeepOnTop" checks are pinned
    /// against an entry that is known to exist at all before either
    /// negative reading is trusted.
    @Test func theWindowMenuDeclaresAKeepOnTopEntry() throws {
        let source = try Self.code(of: Self.commandsFile)
        #expect(source.contains("keepOnTop"), """
            MacSCPCommands.swift no longer mentions keepOnTop at all — the \
            Window menu entry appears to have been removed.
            """)
    }

    /// The checkmark reflects the FOCUSED window's state: the entry reads
    /// `tabCommands?.keepOnTop`, not a local `@State` of its own (there is
    /// none to have — `MacSCPCommands` is app-wide) and not a constant.
    @Test func theCheckmarkReadsTheFocusedBoxsKeepOnTop() throws {
        let source = try Self.code(of: Self.commandsFile)
        #expect(source.contains("tabCommands?.keepOnTop"), """
            MacSCPCommands.swift's Window menu entry no longer reads \
            tabCommands?.keepOnTop — the checkmark would not follow the \
            focused window's sticky state.
            """)
    }

    /// Toggling the entry calls the focused box's `toggleKeepOnTop`, the
    /// same bridge shape as `moveTabToNewWindow`/`toggleTerminal` above it.
    @Test func theEntryTogglesThroughTheFocusedBox() throws {
        let source = try Self.code(of: Self.commandsFile)
        #expect(source.contains("tabCommands?.toggleKeepOnTop"), """
            MacSCPCommands.swift's Window menu entry no longer calls \
            tabCommands?.toggleKeepOnTop — the checkmark would toggle nothing.
            """)
    }

    /// Disabled — not absent — with no window focused, the same rule
    /// `newTab`/`closeActiveTab` follow just above it in this same file.
    @Test func theEntryIsDisabledWithNoWindowFocused() throws {
        let source = try Self.code(of: Self.commandsFile)
        #expect(source.contains(".disabled(tabCommands == nil)"), """
            MacSCPCommands.swift no longer disables an entry on \
            tabCommands == nil anywhere — if that guard moved off the Keep \
            on Top entry, this anchor needs to move with it.
            """)
    }

    /// `TabCommands` (`MacSCPApp.swift`) carries both members this bridge
    /// needs: a `Bool` the menu reads, and a closure it calls. Same shape
    /// as `canMoveTabToNewWindow`/`moveTabToNewWindow` beside them.
    @Test func theBoxDeclaresKeepOnTopAndItsToggle() throws {
        let source = try Self.code(of: Self.appFile)
        #expect(source.contains("var keepOnTop"), """
            TabCommands (MacSCPApp.swift) no longer declares a keepOnTop \
            property — the Window menu would have nothing to read.
            """)
        #expect(source.contains("var toggleKeepOnTop"), """
            TabCommands (MacSCPApp.swift) no longer declares a \
            toggleKeepOnTop closure — the Window menu would have nothing to call.
            """)
    }

    // MARK: - Catalogue parity

    @Test func theKeepOnTopKeyIsInAllFourCatalogues() throws {
        for locale in Self.catalogLocales {
            let present = try Self.catalogKeys(locale).contains("window.keepOnTop")
            #expect(present, """
                \(Self.catalogPath(locale)) has no window.keepOnTop entry — \
                the menu item would render as its key text in that language.
                """)
        }
    }

    /// The catalogue check above reads FILES; this one reads what the app
    /// actually reads — a key appended to `Localizable.strings` is only
    /// useful if the resource bundle `L10n` resolves carries it. The
    /// fallback is deliberately absurd, the same convention `L10nTests` and
    /// `TabsWindowLifecycleTests` use for this exact check: no language can
    /// return it, so the assertion holds in all four.
    @Test func theKeepOnTopKeyResolvesInTheBundleTheAppReads() {
        #expect(L10n.string("window.keepOnTop", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }

    // MARK: - The level source guard

    /// Positive beside the negative below: `WindowLevelPlan.level(` really
    /// is assigned to something's `.level` somewhere in this target — so
    /// the "only from the plan" reading is pinned against a scan that is
    /// known to find at least one real assignment, not one that has quietly
    /// stopped matching anything (CLAUDE.md, "Guards that name what they
    /// watch").
    @Test func theLevelIsAssignedFromThePlanAtLeastOnce() throws {
        var found = false
        for file in try Self.allAppKitSourceFiles() {
            let code = try Self.code(of: file)
            for line in code.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains(".level = ") && line.contains("WindowLevelPlan.level(") {
                found = true
            }
        }
        #expect(found, """
            no line under Sources/MacSCPAppKit assigns .level = \
            WindowLevelPlan.level( — ContentView appears to have stopped \
            applying the plan's decision to any window at all.
            """)
    }

    /// The negative half: every OTHER `.level = ` assignment line in the
    /// target — if there is one — also names `WindowLevelPlan.level(` on
    /// the same line. A bare `window.level = .floating` anywhere would
    /// bypass the one decision point this plan exists to be.
    @Test func noOtherLevelAssignmentBypassesThePlan() throws {
        var offendingLines: [String] = []
        for file in try Self.allAppKitSourceFiles() {
            let code = try Self.code(of: file)
            for line in code.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains(".level = ") && !line.contains("WindowLevelPlan.level(") {
                offendingLines.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offendingLines.isEmpty, """
            found .level = assignment(s) that do not read from \
            WindowLevelPlan.level(: \(offendingLines.joined(separator: "; ")) — \
            NSWindow.level is being set outside the one decision point this \
            plan exists to be.
            """)
    }
}
