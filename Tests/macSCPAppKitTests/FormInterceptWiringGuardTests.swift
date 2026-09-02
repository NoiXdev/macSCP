import Foundation
import Testing
import macSCPCore

/// Guards `ConnectionFormView.interceptEdit`'s arms against the failure the
/// hook was invented for (M22/T8 fix round 1): binding a generic control
/// straight to its field, which silently bypasses the view-model COMMAND
/// that field's write is supposed to be — and leaves that command with no
/// production caller at all, which no unit test of the command notices.
///
/// Two commands go through the hook, counted against the file in the pass
/// that writes this: SSH's auth kind (`selectAuthChoice`, which clears the
/// secret) and S3's bucket-list toggle (`selectBucketListMode`, which
/// discards the typed bucket).
///
/// Every check is POSITIVE — it requires a name to be present — so a rename
/// or a removal fails loudly rather than leaving a scan that matches nothing
/// and reads as satisfied.
@Suite("Connection form intercept wiring")
struct FormInterceptWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/FormInterceptWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let formSourceFile =
        repoRoot.appendingPathComponent("Sources/MacSCPAppKit/ConnectionFormView.swift")

    /// Comments in that file name both commands in prose, so an unstripped
    /// read would find the explanation and call it wiring.
    private static func strippedSource() throws -> String {
        SheetFacetWiringGuardTests.strippingLineComments(
            try String(contentsOf: formSourceFile, encoding: .utf8))
    }

    /// The hook is still handed to the generic form. Without this, both
    /// checks below could pass over a file whose `interceptEdit` is dead
    /// code nothing calls.
    @Test func theFormStillHandsItsHookToTheGenericRenderer() throws {
        let source = try Self.strippedSource()
        #expect(source.contains("interceptEdit: interceptEdit"), """
            ConnectionFormView no longer passes `interceptEdit` to \
            SchemaFormView, so every field write lands in `values` directly \
            and both commands below have no caller.
            """)
    }

    /// The pre-existing arm, kept as the sibling of the new one: if this
    /// suite ever scans a file where only one command is wired, it should
    /// be able to say which.
    @Test func theAuthKindPickerStillGoesThroughItsCommand() throws {
        let source = try Self.strippedSource()
        #expect(source.contains("viewModel.selectAuthChoice("), """
            ConnectionFormView's intercept no longer calls selectAuthChoice — \
            the auth picker writes its field directly again, and a password \
            typed for one auth kind carries over into the other.
            """)
    }

    /// The new arm (2026-09-02, Task 4), and that it is keyed off the field
    /// enum rather than a hand-spelled namespaced string.
    @Test func theBucketListToggleGoesThroughItsCommand() throws {
        let source = try Self.strippedSource()

        #expect(source.contains("viewModel.selectBucketListMode("), """
            ConnectionFormView's intercept no longer calls \
            selectBucketListMode, so turning "Start at the bucket list" on \
            leaves the typed bucket in the form and discards it silently on \
            save instead.
            """)
        #expect(source.contains("S3Field.startsAtBucketList.rawValue"), """
            the intercepted key is no longer derived from \
            S3Field.startsAtBucketList — a second, hand-spelled copy of a \
            field id is waiting for a rename to walk past it.
            """)
    }

    /// The compile-time half of the two scans above. Both commands are
    /// referenced by name as unbound method references — nothing is called
    /// and no view model is built — so renaming either one stops THIS FILE
    /// from compiling, instead of leaving its `contains` above looking for a
    /// string nothing writes any more. The assertion is the trivial half;
    /// the compiler is the check.
    @Test @MainActor func coreStillOffersBothCommandsTheFormCalls() {
        let switchAuth: (ConnectionViewModel) -> (ConnectionViewModel.AuthChoice) -> Void =
            ConnectionViewModel.selectAuthChoice
        let switchBucketListMode: (ConnectionViewModel) -> (Bool) -> Void =
            ConnectionViewModel.selectBucketListMode
        #expect(([switchAuth, switchBucketListMode] as [Any]).count == 2)
    }
}
