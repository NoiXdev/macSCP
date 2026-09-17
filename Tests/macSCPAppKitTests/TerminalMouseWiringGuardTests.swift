import Foundation
import MacSCPTestSupport
import Testing

/// Guards the wiring of the terminal's two mouse settings (next build of
/// 2026-09-17, Task 6) where `TerminalMouseBehaviourTests` cannot reach:
/// the SwiftUI wrapper handing the settings to the view, the Settings tab
/// binding the toggles, and the shape of the two overrides that act on
/// them.
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

    private static let terminalViewFile = "Sources/MacSCPAppKit/MacSCPTerminalView.swift"
    private static let wrapperFile = "Sources/MacSCPAppKit/SSHTerminalView.swift"
    private static let settingsViewFile = "Sources/MacSCPAppKit/SettingsView.swift"

    private static let menuOverride = "override func menu(for event: NSEvent) -> NSMenu?"
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

    // MARK: - The right-click hook

    /// The right-click decision lives in the one hook the snippet menu
    /// already used — `menu(for:)` — and it is the plan that decides.
    @Test func theMenuHookAsksThePlanAndPastesThroughPaste() throws {
        let body = try Self.body(of: Self.menuOverride, in: Self.views(Self.terminalViewFile).code)
        #expect(body.contains("TerminalRightClickPlan.action("))
        #expect(body.contains("case .paste"))
        #expect(body.contains("paste(self)"), """
            the paste branch must call SwiftTerm's own paste(_:) -- the action \
            Command-V sends -- so bracketed paste applies to it unchanged
            """)
        #expect(body.contains("super.menu(for: event)"))
        try Self.expectNoDirectWrite(in: body)
    }

    /// Negative: the hook itself neither reads the pasteboard nor writes to
    /// the shell. Positive beside it: the body scanned is the hook's (it
    /// calls the plan), checked by the caller above and here again.
    private static func expectNoDirectWrite(in body: String) throws {
        #expect(body.contains("TerminalRightClickPlan.action("), "scanning the wrong body")
        for forbidden in ["NSPasteboard", "send(", "insertText(", "feed("] {
            #expect(!body.contains(forbidden), """
                the right-click hook must not reach \(forbidden) itself -- pasting \
                goes through paste(_:) and nowhere else
                """)
        }
    }

    @Test func scannerSeesAHookThatWritesPasteboardTextToTheShell() throws {
        let source = """
            class MacSCPTerminalView: TerminalView {
                \(Self.menuOverride) {
                    switch TerminalRightClickPlan.action(pasteOnRightClick: true, optionPressed: false, snippetsExist: false) {
                    case .paste:
                        send(txt: NSPasteboard.general.string(forType: .string) ?? "")
                        return nil
                    case .snippetMenu, .systemDefault:
                        return super.menu(for: event)
                    }
                }
            }
            """
        let body = try Self.body(
            of: Self.menuOverride, in: try SwiftSource.blankingCommentsAndStrings(source))
        #expect(body.contains("TerminalRightClickPlan.action("))
        #expect(!body.contains("paste(self)"))
        #expect(body.contains("NSPasteboard"))
        #expect(body.contains("send("))
    }

    // MARK: - Copy on select

    /// The write happens after, and only through, the plan's non-empty
    /// answer, into `copyPasteboard` — whose declared value is the general
    /// pasteboard and which no production file reassigns.
    @Test func mouseUpWritesThePlansTextAfterThePlan() throws {
        let code = try Self.views(Self.terminalViewFile).code
        let body = try Self.body(of: Self.mouseUpOverride, in: code)
        let plan = try #require(body.range(of: "TerminalCopyOnSelectPlan.textToCopy("))
        let write = try #require(body.range(of: "copyPasteboard.setString("))
        #expect(plan.upperBound <= write.lowerBound, "the write must come after the plan's answer")
        #expect(code.contains("var copyPasteboard: NSPasteboard = NSPasteboard.general"))
        // One write in the whole file, and it is the one above.
        #expect(TransferQueueBarCancelGuardTests.occurrenceCount(of: "setString(", in: code) == 1)
    }

    @Test func noProductionFileReassignsTheCopyPasteboard() throws {
        let sources = Self.path("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var declaringFileSeen = false
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try SwiftSource.blankingCommentsAndStrings(String(contentsOf: url, encoding: .utf8))
            scanned += 1
            if url.lastPathComponent == "MacSCPTerminalView.swift" {
                declaringFileSeen = code.contains("var copyPasteboard")
                continue
            }
            #expect(!code.contains("copyPasteboard"), "\(url.lastPathComponent) touches copyPasteboard")
        }
        // Positive beside the negative: the walk really read the tree and
        // the property it looks for really exists.
        #expect(scanned > 50)
        #expect(declaringFileSeen)
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
