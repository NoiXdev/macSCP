import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the terminal's two mouse settings (next build of
/// 2026-09-17, Task 6) where `TerminalMouseBehaviourTests` cannot reach:
/// the SwiftUI wrapper handing the settings to the view, the Settings tab
/// binding the toggles, and the shape of the two overrides that act on
/// them — which, since review follow-ups Task 8 (2026-09-18), are three
/// for the right click: `rightMouseDown(with:)`, `menu(for:)` and
/// `mouseDown(with:)`.
///
/// Structural claims read the source with comments AND string literals
/// blanked (`SwiftSource.blankingCommentsAndStrings`); catalogue-key claims
/// are claims about literals and read the comments-only view. Every
/// negative check has a positive check beside it naming the thing it scans.
///
/// Known blind spot: SOURCE TEXT only. The behaviour of the overrides is
/// `TerminalMouseBehaviourTests`; AppKit delivering a real click is a sight
/// check.
@Suite("Terminal mouse settings wiring guard")
struct TerminalMouseWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    /// Derived from the type, so a rename of the class moves the guard with
    /// it instead of leaving it reading a file that no longer exists.
    private static let terminalViewFileName = "\(String(describing: MacSCPTerminalView.self)).swift"
    private static let terminalViewFile = "Sources/MacSCPAppKit/\(terminalViewFileName)"
    private static let wrapperFile = "Sources/MacSCPAppKit/SSHTerminalView.swift"
    private static let settingsViewFile = "Sources/MacSCPAppKit/SettingsView.swift"

    private static let menuOverride = "override func menu(for event: NSEvent) -> NSMenu?"
    private static let rightMouseDownOverride = "override func rightMouseDown(with event: NSEvent)"
    private static let mouseDownOverride = "override func mouseDown(with event: NSEvent)"
    private static let decisionHelper = "private func rightClickAction(for event: NSEvent) -> TerminalRightClickPlan"
    private static let controlClickTest = "private static func isControlClick(_ event: NSEvent) -> Bool"
    private static let mouseUpOverride = "override func mouseUp(with event: NSEvent)"
    private static let settingsTab = "private struct TerminalSettingsTab: View"

    private static let keys = [
        "settings.terminal.copyOnSelect",
        "settings.terminal.pasteOnRightClick",
        "settings.terminal.pasteOnRightClick.footer",
    ]

    private static func views(_ relative: String) throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: path(relative), encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw), try SwiftSource.blankingComments(raw))
    }

    private static func body(of declaration: String, in source: String) throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: source)
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let relative = "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
        let data = try Data(contentsOf: path(relative))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    // MARK: - The right-click hooks

    /// The plan is asked in exactly one place, and the three hooks act on
    /// that one answer.
    @Test func thePlanIsAskedInOnePlace() throws {
        let code = try Self.views(Self.terminalViewFile).code
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "TerminalRightClickPlan.action(", in: code) == 1)
        let helper = try Self.body(of: Self.decisionHelper, in: code)
        #expect(helper.contains("TerminalRightClickPlan.action("))
        let control = try Self.body(of: Self.controlClickTest, in: code)
        #expect(control.contains(".leftMouseDown"))
        #expect(control.contains(".control"))
    }

    /// The real right mouse button pastes, through SwiftTerm's own
    /// `paste(_:)` — the action ⌘V sends — and hands every other answer to
    /// `NSView`, which asks `menu(for:)`.
    @Test func theRightMouseButtonPastesThroughPaste() throws {
        let body = try Self.body(of: Self.rightMouseDownOverride, in: Self.views(Self.terminalViewFile).code)
        #expect(body.contains("rightClickAction(for: event) == .paste"))
        #expect(body.contains("paste(self)"), """
            the paste branch must call SwiftTerm's own paste(_:) -- the action \
            Command-V sends -- so bracketed paste applies to it unchanged
            """)
        #expect(body.contains("super.rightMouseDown(with: event)"))
        try Self.expectNoDirectWrite(in: body)
    }

    /// A control-click pastes where AppKit delivers it, and only a
    /// control-click does: the plain click still goes to SwiftTerm.
    @Test func aControlClickPastesFromMouseDown() throws {
        let body = try Self.body(of: Self.mouseDownOverride, in: Self.views(Self.terminalViewFile).code)
        #expect(body.contains("Self.isControlClick(event) && rightClickAction(for: event) == .paste"))
        #expect(body.contains("paste(self)"))
        #expect(body.contains("super.mouseDown(with: event)"))
        try Self.expectNoDirectWrite(in: body)
        // Copy on select reads no selection when a click starts.
        #expect(!body.contains("getSelection("))
    }

    /// The menu lookup never pastes — a menu request with no mouse button
    /// behind it (VoiceOver's "show menu") must get the menu. It declines
    /// only a control-click that is to paste, so AppKit delivers that click.
    @Test func theMenuLookupNeverPastes() throws {
        let body = try Self.body(of: Self.menuOverride, in: Self.views(Self.terminalViewFile).code)
        // Positive beside the negative: this is the lookup, and it answers.
        #expect(body.contains("super.menu(for: event)"))
        #expect(body.contains("Self.isControlClick(event) && rightClickAction(for: event) == .paste"))
        #expect(!body.contains("paste("), "menu(for:) must never paste")
        try Self.expectNoDirectWrite(in: body)
    }

    /// Negative: a hook neither reads the pasteboard nor writes to the
    /// shell itself. Positive beside it: the body scanned asks the plan's
    /// helper, so it is one of the three hooks.
    private static func expectNoDirectWrite(in body: String) throws {
        #expect(body.contains("rightClickAction(for: event)"), "scanning the wrong body")
        for forbidden in ["NSPasteboard", "send(", "insertText(", "feed("] {
            #expect(!body.contains(forbidden), """
                a right-click hook must not reach \(forbidden) itself -- pasting \
                goes through paste(_:) and nowhere else
                """)
        }
    }

    @Test func scannerSeesAHookThatWritesPasteboardTextToTheShell() throws {
        let source = """
            class MacSCPTerminalView: TerminalView {
                \(Self.rightMouseDownOverride) {
                    guard rightClickAction(for: event) == .paste else {
                        super.rightMouseDown(with: event)
                        return
                    }
                    send(txt: NSPasteboard.general.string(forType: .string) ?? "")
                }
            }
            """
        let body = try Self.body(
            of: Self.rightMouseDownOverride, in: try SwiftSource.blankingCommentsAndStrings(source))
        #expect(body.contains("rightClickAction(for: event)"))
        #expect(!body.contains("paste(self)"))
        #expect(body.contains("NSPasteboard"))
        #expect(body.contains("send("))
    }

    @Test func scannerSeesAMenuLookupThatPastes() throws {
        let source = """
            class MacSCPTerminalView: TerminalView {
                \(Self.menuOverride) {
                    if rightClickAction(for: event) == .paste {
                        paste(self)
                        return nil
                    }
                    return super.menu(for: event)
                }
            }
            """
        let body = try Self.body(
            of: Self.menuOverride, in: try SwiftSource.blankingCommentsAndStrings(source))
        #expect(body.contains("super.menu(for: event)"))
        #expect(body.contains("paste("))
    }

    // MARK: - Copy on select

    /// The write happens after, and only through, the plan's non-empty
    /// answer, into `copyPasteboard` — whose declared value is the general
    /// pasteboard and which no production file reassigns. The selection
    /// text is built in one place in the file: inside the plan call, which
    /// builds it only for a gesture that changed the selection.
    @Test func mouseUpWritesThePlansTextAfterThePlan() throws {
        let code = try Self.views(Self.terminalViewFile).code
        let body = try Self.body(of: Self.mouseUpOverride, in: code)
        let plan = try #require(body.range(of: "TerminalCopyOnSelectPlan.textToCopy("))
        let read = try #require(body.range(of: "selection: { getSelection() }"))
        let write = try #require(body.range(of: "copyPasteboard.setString("))
        #expect(plan.upperBound <= read.lowerBound, "the selection is read inside the plan call")
        #expect(read.upperBound <= write.lowerBound, "the write must come after the plan's answer")
        #expect(code.contains("var copyPasteboard: NSPasteboard = NSPasteboard.general"))
        // One write and one read in the whole file, and they are the ones
        // above.
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(of: "setString(", in: code) == 1)
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(of: "getSelection(", in: code) == 1)
    }

    /// An assignment to `copyPasteboard` — `=` not followed by `=`, so a
    /// comparison is not one, and the declaration's `:` type annotation is
    /// not either.
    private static func assignsCopyPasteboard(_ code: String) -> Bool {
        code.contains(#/copyPasteboard\s*=(?!=)/#)
    }

    /// Every production file is scanned, the declaring one included: there
    /// no line may assign the property after its declaration; everywhere
    /// else the property is not even named.
    @Test func noProductionFileReassignsTheCopyPasteboard() throws {
        let sources = Self.path("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var declaringFileSeen = false
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try SwiftSource.blankingCommentsAndStrings(String(contentsOf: url, encoding: .utf8))
            scanned += 1
            #expect(!Self.assignsCopyPasteboard(code), "\(url.lastPathComponent) reassigns copyPasteboard")
            if url.lastPathComponent == Self.terminalViewFileName {
                declaringFileSeen = code.contains("var copyPasteboard: NSPasteboard = NSPasteboard.general")
                continue
            }
            #expect(!code.contains("copyPasteboard"), "\(url.lastPathComponent) touches copyPasteboard")
        }
        // Positive beside the negatives: the walk really read the tree, and
        // it read the declaring file, whose declaration is really there.
        #expect(scanned > 50)
        #expect(declaringFileSeen)
    }

    @Test func scannerSeesAReassignmentButNotTheDeclaration() throws {
        let declaration = "var copyPasteboard: NSPasteboard = NSPasteboard.general"
        #expect(!Self.assignsCopyPasteboard(declaration))
        #expect(!Self.assignsCopyPasteboard("if copyPasteboard == other { }"))
        #expect(Self.assignsCopyPasteboard("copyPasteboard = NSPasteboard(name: .find)"))
        #expect(Self.assignsCopyPasteboard("self.copyPasteboard=other"))
    }

    // MARK: - The SwiftUI wrapper

    @Test func theWrapperBuildsTheSubclassAndHandsItBothSettings() throws {
        let code = try Self.views(Self.wrapperFile).code
        let make = try Self.body(of: "func makeNSView(", in: code)
        let update = try Self.body(of: "func updateNSView(", in: code)
        #expect(make.contains("MacSCPTerminalView(frame:"))
        for body in [make, update] {
            #expect(body.contains("terminal.copyOnSelect = settingsStore.terminalCopyOnSelect"))
            #expect(body.contains("terminal.pasteOnRightClick = settingsStore.terminalPasteOnRightClick"))
        }
    }

    // MARK: - Settings tab

    @Test func theSettingsTabBindsBothTogglesThroughTheCatalogueKeys() throws {
        let views = try Self.views(Self.settingsViewFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.settingsTab, in: views.code)
        let code = TransferQueueBarCancelGuardTests.slice(range, of: views.code)
        let literals = TransferQueueBarCancelGuardTests.slice(range, of: views.withLiterals)
        #expect(code.contains("$store.terminalCopyOnSelect"))
        #expect(code.contains("$store.terminalPasteOnRightClick"))
        for key in Self.keys {
            #expect(literals.contains("\"\(key)\""), "TerminalSettingsTab does not use \(key)")
        }
    }

    @Test func theKeysAreInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.keys {
                #expect(entries[key] != nil, "\(locale) has no \(key)")
            }
        }
    }

    @Test func theGermanFooterAddressesTheUserAsDu() throws {
        let footer = try #require(try Self.catalog("de")["settings.terminal.pasteOnRightClick.footer"])
        #expect(footer.contains(" du "))
    }
}
