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
    // and now anchor on `struct X: View`; three of the six rows below (the
    // lost and failed surfaces, and the snippet editor) have since moved on
    // to `struct X: BoundedView`, with the types they name. Widening an
    // anchor can only add matches, and each of those guards reads the FIRST
    // one, so the failure that is still reachable is a second site the guard
    // would read instead.
    //
    // The anchor and the file of every row are read from the guard's own
    // constants, not spelled here, so editing an anchor or repointing a
    // guard at another file moves this count with it. What cannot be read
    // is WHICH VIEW of the file a guard scans (`SourceCorpus.code(of:)`,
    // comments and strings blanked, or `SourceCorpus.text(of:)`, raw): that
    // is decided inside each guard's own helper, and deriving it would mean
    // restructuring five guards. So `reading` stays a literal per row, and a
    // guard that moves between the two views is NOT caught here.

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private enum Reading {
        case code, raw
    }

    private struct WidenedAnchor {
        let guardName: String
        let anchor: String
        let file: URL
        let reading: Reading
    }

    private static func relative(_ path: String) -> URL {
        repoRoot.appendingPathComponent(path)
    }

    private static let widenedAnchors: [WidenedAnchor] = [
        WidenedAnchor(
            guardName: "CLISettingsCompletionGuardTests",
            anchor: CLISettingsCompletionGuardTests.sectionDeclaration,
            file: CLISettingsCompletionGuardTests.settingsViewFile, reading: .code),
        WidenedAnchor(
            guardName: "TerminalKeyboardWiringGuardTests",
            anchor: TerminalKeyboardWiringGuardTests.settingsTab,
            file: relative(TerminalKeyboardWiringGuardTests.settingsViewFile), reading: .code),
        WidenedAnchor(
            guardName: "TerminalMouseWiringGuardTests",
            anchor: TerminalMouseWiringGuardTests.settingsTab,
            file: relative(TerminalMouseWiringGuardTests.settingsViewFile), reading: .code),
        WidenedAnchor(
            guardName: "ReconnectWiringGuardTests (lost)",
            anchor: ReconnectWiringGuardTests.lostConnectionAnchor,
            file: ReconnectWiringGuardTests.detailFile, reading: .raw),
        WidenedAnchor(
            guardName: "ReconnectWiringGuardTests (failed)",
            anchor: ReconnectWiringGuardTests.connectFailureAnchor,
            file: ReconnectWiringGuardTests.detailFile, reading: .raw),
        WidenedAnchor(
            guardName: "SnippetCommandEditorGuardTests",
            anchor: SnippetCommandEditorGuardTests.editorDeclaration,
            file: SnippetCommandEditorGuardTests.sheetSourceFile, reading: .raw),
    ]

    @Test(arguments: BoundedViewVisibilityTests.widenedAnchors.indices)
    func eachWidenedGuardAnchorMatchesExactlyOnce(index: Int) throws {
        let entry = Self.widenedAnchors[index]
        let text = try entry.reading == .code
            ? SourceCorpus.code(of: entry.file) : SourceCorpus.text(of: entry.file)
        let count = text.components(separatedBy: entry.anchor).count - 1
        #expect(count == 1, """
            \(entry.guardName) reads the first match of `\(entry.anchor)` in \
            \(entry.file.lastPathComponent) (\(entry.reading) view); there are \(count) \
            matches, so it may be reading the wrong site.
            """)
    }
}
