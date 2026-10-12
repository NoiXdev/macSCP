import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the user-defined file actions (file-actions plan,
/// 2026-10-12) where a unit test cannot reach: the pane dispatching the
/// menu entry, the sheet it opens, and — from Task 10 — the rule that a run
/// is owned by the activity rather than by a `Task` nothing owns.
///
/// Structural claims read `SourceCorpus.code` (comments AND string literals
/// blanked), catalogue-key claims read `SourceCorpus.commentFree`.
///
/// Known blind spot: SOURCE TEXT only. That the sheet renders and that the
/// confirm button is reachable by mouse are sight checks, and Task 12
/// assigns them to the maintainer.
@Suite("File action pane wiring guard")
struct FileActionPaneWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func literals(_ name: String) throws -> String {
        try SourceCorpus.commentFree(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(
            contentsOf: path("Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private static let keys = [
        "fileAction.confirm.title",
        "fileAction.confirm.message",
        "fileAction.confirm.run",
        "fileAction.confirm.cancel",
        "fileAction.confirm.refused",
    ]

    @Test func theMenuEntryReachesTheExtensionAndNotAnInlineClosure() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("case .userFileAction(let action):"))
        #expect(pane.contains("beginFileAction(action, selection: selection)"))
    }

    @Test func theExtensionBuildsThePlanThroughThePlanner() throws {
        let code = try Self.code("BrowserPane+FileActions.swift")
        #expect(code.contains("FileActionPlanner.plan("))
        #expect(code.contains("fileActionRequest ="))
    }

    @Test func theSheetIsPresentedFromTheRequest() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("FileActionConfirmSheet("))
        #expect(pane.contains("$fileActionRequest"))
    }

    @Test func everyConfirmKeyIsInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let entries = try Self.catalog(locale)
            for key in Self.keys {
                let value = entries[key] ?? ""
                #expect(value.isEmpty == false, "\(locale) has no \(key)")
            }
        }
    }

    @Test func theSheetUsesTheCatalogueKeysAndNoBareStrings() throws {
        let literals = try Self.literals("FileActionConfirmSheet.swift")
        for key in Self.keys {
            #expect(literals.contains("\"\(key)\""), "the sheet does not use \(key)")
        }
    }

    /// The inline default is what a missing bundle falls back to, so it must be
    /// the `en` value to the byte. Read from the source with its key as the
    /// anchor; a key that matches nothing fails the positive check beside it.
    @Test func everyInlineDefaultEqualsTheEnglishCatalogueValue() throws {
        let literals = try Self.literals("FileActionConfirmSheet.swift")
        let english = try Self.catalog("en")
        for key in Self.keys {
            let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\",\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(literals.startIndex..., in: literals)
            let matches = regex.matches(in: literals, range: range)
            #expect(matches.count == 1, "\(key) is looked up \(matches.count) times in the sheet")
            guard let match = matches.first, let inline = Range(match.range(at: 1), in: literals)
            else { continue }
            #expect(String(literals[inline]) == english[key], "the default of \(key) drifted")
        }
    }

    /// The user's actions are the last run in the model, after `delete`; the
    /// table view puts one divider before the first of them. The positive
    /// half is the `.userFileAction` case being asked about at all.
    @Test func theTableViewDividesTheUserActionsFromTheBuiltInEntries() throws {
        let table = try Self.code("RemoteFileTableView.swift")
        #expect(table.contains("if case .userFileAction = entry, menu.items.isEmpty == false"))
        #expect(table.contains("menu.addItem(.separator())"))
    }

    @Test func theGermanConfirmMessageAddressesTheUserAsDu() throws {
        let message = try #require(try Self.catalog("de")["fileAction.confirm.message"])
        #expect(message.contains(" du "))
    }
}
