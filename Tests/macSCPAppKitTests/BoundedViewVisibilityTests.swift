import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

/// The views that bound their own size are measured from a test, so a test
/// has to be able to name each of them. `private` types cannot be named even
/// through `@testable import`; this file only builds when every one of the
/// fourteen is at least `internal`.
///
/// The compile is the check: a type that goes back to `private` turns this
/// file into a build failure, not into a failing assertion.
@Suite struct BoundedViewVisibilityTests {
    @Test func everyBoundedViewIsReachableFromTests() {
        let types: [Any.Type] = [
            ChangeKeyPassphraseSheet.self,
            ConnectFailureView.self,
            ConnectingAttemptView.self,
            CorrectKeyPassphraseSheet.self,
            GenerateKeySheet.self,
            LoginSetEditorView.self,
            LostConnectionView.self,
            RenameKeySheet.self,
            SnippetEditorView.self,
            TagFilterSheet.self,
            TerminalPanelHeader.self,
            TerminalSettingsTab.self,
            CLISettingsSection.self,
            TagFilterJoinPicker.self,
        ]
        #expect(types.count == 14)
    }

    // MARK: - The widened guard anchors

    // Five source-scanning guards used to anchor on `private struct X: View`
    // and now anchor on `struct X: View`. Widening an anchor can only add
    // matches, and each of those guards reads the FIRST one, so the failure
    // that is still reachable is a second site the guard would read instead.
    // Each count below is taken in the view the guard itself reads:
    // `SourceCorpus.code(of:)` (comments and string literals blanked) where
    // the guard scans `.code`, `SourceCorpus.text(of:)` (raw) where it scans
    // raw text.

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private enum Reading {
        case code, raw
    }

    private static func occurrences(
        of anchor: String, in relative: String, view: Reading
    ) throws -> Int {
        let url = repoRoot.appendingPathComponent(relative)
        let text = try view == .code ? SourceCorpus.code(of: url) : SourceCorpus.text(of: url)
        return text.components(separatedBy: anchor).count - 1
    }

    private static let widenedAnchors: [(anchor: String, file: String, view: Reading)] = [
        // CLISettingsCompletionGuardTests.sectionDeclaration, reads `.code`
        ("struct CLISettingsSection: View", "Sources/MacSCPAppKit/SettingsView.swift", .code),
        // TerminalKeyboardWiringGuardTests / TerminalMouseWiringGuardTests.settingsTab, read `.code`
        ("struct TerminalSettingsTab: View", "Sources/MacSCPAppKit/SettingsView.swift", .code),
        // ReconnectWiringGuardTests.strippedBody(after:in:), anchor found in RAW text
        ("struct LostConnectionView: View", "Sources/MacSCPAppKit/ContentView+Detail.swift", .raw),
        ("struct ConnectFailureView: View", "Sources/MacSCPAppKit/ContentView+Detail.swift", .raw),
        // SnippetCommandEditorGuardTests.functionBody(containing:in:), reads RAW text
        ("struct SnippetEditorView: View {", "Sources/MacSCPAppKit/SnippetsSheet.swift", .raw),
    ]

    @Test(arguments: BoundedViewVisibilityTests.widenedAnchors.indices)
    func eachWidenedGuardAnchorMatchesExactlyOnce(index: Int) throws {
        let entry = Self.widenedAnchors[index]
        let count = try Self.occurrences(of: entry.anchor, in: entry.file, view: entry.view)
        #expect(count == 1)
    }
}
