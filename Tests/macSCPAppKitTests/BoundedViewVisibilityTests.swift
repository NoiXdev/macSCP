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
}
