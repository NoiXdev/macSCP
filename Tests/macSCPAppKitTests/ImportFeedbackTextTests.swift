import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Every `SessionExportError` case, listed by hand. A new case added to the
/// enum without a line here is caught by the exhaustive switch in
/// `ImportFeedbackTextTests.theCaseListIsComplete`, which fails to compile
/// until it is handled.
extension SessionExportError {
    static let allTestCases: [SessionExportError] = [
        .notAnExportFile, .unsupportedVersion(2), .passwordRequired,
        .wrongPasswordOrCorrupted, .randomnessUnavailable,
    ]
}

@Suite("ImportFeedbackText")
struct ImportFeedbackTextTests {
    /// `.passwordRequired`/`.wrongPasswordOrCorrupted` and
    /// `.notAnExportFile`/`.randomnessUnavailable` intentionally share text —
    /// see the doc comments on both pairs in
    /// `ImportFeedbackText.importErrorText`. These are the only collisions
    /// the mapping is allowed to have; every other pair below must be
    /// distinct. `SessionExportError` is `Equatable` but not `Hashable`, so
    /// this is an array of pairs rather than a `Set` — membership is checked
    /// with `contains`.
    static let documentedCollisions: [[SessionExportError]] = [
        [.passwordRequired, .wrongPasswordOrCorrupted],
        [.notAnExportFile, .randomnessUnavailable],
    ]

    private static func isDocumented(_ a: SessionExportError, _ b: SessionExportError) -> Bool {
        documentedCollisions.contains { $0.contains(a) && $0.contains(b) }
    }

    /// An import that failed and says nothing is indistinguishable from one
    /// that silently did nothing.
    @Test func everyExportErrorHasText() {
        for error in SessionExportError.allTestCases {
            let isEmpty = ImportFeedbackText.importErrorText(for: error).isEmpty
            #expect(isEmpty == false, "\(error) has no message")
        }
    }

    /// Two different failures that read the same send the user to fix the
    /// wrong thing — unless the collision is one of the two the mapping
    /// documents as deliberate reuse of a catch-all message. Rewritten from
    /// the brief's "no two errors read the same" claim: `.passwordRequired`/
    /// `.wrongPasswordOrCorrupted` and `.notAnExportFile`/
    /// `.randomnessUnavailable` are both deliberate reuse (see
    /// `ImportFeedbackText`), so a literal "no two share text" test would
    /// fail against the correct implementation. This still catches an
    /// ACCIDENTAL new collision.
    @Test func noUndocumentedExportErrorsReadTheSame() {
        var seen: [String: SessionExportError] = [:]
        for error in SessionExportError.allTestCases {
            let text = ImportFeedbackText.importErrorText(for: error)
            if let existing = seen[text] {
                #expect(
                    Self.isDocumented(error, existing),
                    "\(error) reads the same as \(existing), and neither pairing is in documentedCollisions"
                )
            }
            seen[text] = error
        }
    }

    /// The list above is hand-maintained; this switch makes the compiler
    /// reject a new `SessionExportError` case that nobody added to it. No
    /// `default` — that would silently defeat the exhaustiveness check.
    @Test func theCaseListIsComplete() {
        for error in SessionExportError.allTestCases {
            switch error {
            case .notAnExportFile, .unsupportedVersion, .passwordRequired,
                .wrongPasswordOrCorrupted, .randomnessUnavailable:
                continue
            }
        }
        #expect(SessionExportError.allTestCases.count == 5)
    }

    /// A read failure that discards the underlying error's own description
    /// is indistinguishable from any other read failure. Two synthetic
    /// errors with different descriptions must produce different messages —
    /// if `readErrorMessage` returned a constant this would fail.
    @Test func readErrorMessageVariesWithTheUnderlyingError() {
        struct SampleError: Error, CustomStringConvertible {
            let description: String
        }
        let first = ImportFeedbackText.readErrorMessage(SampleError(description: "disk full"))
        let second = ImportFeedbackText.readErrorMessage(
            SampleError(description: "permission denied"))
        #expect(first.isEmpty == false)
        #expect(second.isEmpty == false)
        #expect(first != second, "readErrorMessage does not vary with the underlying error")
    }

    /// The base imported/skipped/passwords-imported line must vary with the
    /// counts it reports — a constant-return `importResultText` would pass
    /// `everyExportErrorHasText`-style emptiness checks but not this.
    @Test func importResultTextVariesWithTheCounts() {
        let plan = SessionImportPlan()
        let few = SessionListViewModel.SessionImportResult(
            imported: 3, skipped: 1, passwordsImported: 2, passwordFailures: 0, storeFailures: 0)
        var many = few
        many.imported = 30
        let fewText = ImportFeedbackText.importResultText(
            few, plan: plan, includesSecrets: false, encrypted: true)
        let manyText = ImportFeedbackText.importResultText(
            many, plan: plan, includesSecrets: false, encrypted: true)
        #expect(fewText != manyText, "the base line does not vary with the import count")
    }

    /// The password-failures line is added only when there were failures —
    /// tested by line count rather than literal text, so this does not
    /// depend on the exact localized wording.
    @Test func importResultTextAddsALineOnlyWhenThereAreFailures() {
        let plan = SessionImportPlan()
        let clean = SessionListViewModel.SessionImportResult(
            imported: 1, skipped: 0, passwordsImported: 0, passwordFailures: 0, storeFailures: 0)
        var withFailures = clean
        withFailures.passwordFailures = 2

        let cleanText = ImportFeedbackText.importResultText(
            clean, plan: plan, includesSecrets: false, encrypted: true)
        let failureText = ImportFeedbackText.importResultText(
            withFailures, plan: plan, includesSecrets: false, encrypted: true)

        #expect(cleanText.components(separatedBy: "\n").count == 1)
        #expect(
            failureText.components(separatedBy: "\n").count == 2,
            "a password-failure count > 0 should add a line")
    }

    /// Folders the import straightened get their own line, and only when it
    /// straightened one — same line-count shape as the failure lines above,
    /// so this does not depend on the localized wording.
    @Test func importResultTextAddsALineOnlyWhenFoldersWereLifted() {
        let result = SessionListViewModel.SessionImportResult(
            imported: 1, skipped: 0, passwordsImported: 0, passwordFailures: 0, storeFailures: 0)
        var lifted = SessionImportPlan()
        lifted.liftedGroups = ["Orphan"]

        let quietText = ImportFeedbackText.importResultText(
            result, plan: SessionImportPlan(), includesSecrets: false, encrypted: true)
        let liftedText = ImportFeedbackText.importResultText(
            result, plan: lifted, includesSecrets: false, encrypted: true)

        #expect(quietText.components(separatedBy: "\n").count == 1)
        #expect(
            liftedText.components(separatedBy: "\n").count == 2,
            "a lifted folder should add a line")
    }

    /// The unencrypted-secrets notice appears exactly when the file carried
    /// secrets and was not itself encrypted.
    @Test func importResultTextNoticesUnencryptedSecretsOnly() {
        let plan = SessionImportPlan()
        let result = SessionListViewModel.SessionImportResult(
            imported: 1, skipped: 0, passwordsImported: 0, passwordFailures: 0, storeFailures: 0)

        let plainSecrets = ImportFeedbackText.importResultText(
            result, plan: plan, includesSecrets: true, encrypted: false)
        let encryptedSecrets = ImportFeedbackText.importResultText(
            result, plan: plan, includesSecrets: true, encrypted: true)
        let noSecrets = ImportFeedbackText.importResultText(
            result, plan: plan, includesSecrets: false, encrypted: false)

        #expect(plainSecrets != encryptedSecrets, "the notice should depend on `encrypted`")
        #expect(plainSecrets.components(separatedBy: "\n").count == 2)
        #expect(encryptedSecrets.components(separatedBy: "\n").count == 1)
        #expect(noSecrets.components(separatedBy: "\n").count == 1)
    }

    // MARK: - The two lines an import from another program adds

    /// A one-session result and an empty plan, so the body is exactly one
    /// line and every extra line below is attributable.
    private static func oneImported() -> SessionListViewModel.SessionImportResult {
        SessionListViewModel.SessionImportResult(
            imported: 1, skipped: 0, passwordsImported: 0, passwordFailures: 0, storeFailures: 0)
    }

    /// Same shape as `importResultTextAddsALineOnlyWhenThereAreFailures` and
    /// its lifted-folders twin: a count of zero adds nothing, a count above
    /// zero adds exactly one line. Without this, an unconditional append
    /// ends every clean Cyberduck import with "Existing sessions updated: 0",
    /// which reads as a report about something that went wrong.
    @Test func theUpdatedLineAppearsOnlyWhenSomethingWasUpdated() {
        let quiet = ImportFeedbackText.importResultText(
            Self.oneImported(), plan: SessionImportPlan(), includesSecrets: false,
            encrypted: true,
            external: ImportFeedbackText.ExternalImportOutcome(updated: 0, secretsNotRead: 0))
        let updated = ImportFeedbackText.importResultText(
            Self.oneImported(), plan: SessionImportPlan(), includesSecrets: false,
            encrypted: true,
            external: ImportFeedbackText.ExternalImportOutcome(updated: 2, secretsNotRead: 0))

        #expect(quiet.components(separatedBy: "\n").count == 1)
        #expect(updated.components(separatedBy: "\n").count == 2)
    }

    @Test func theUnreadSecretsLineAppearsOnlyWhenSomethingWasNotRead() {
        let quiet = ImportFeedbackText.importResultText(
            Self.oneImported(), plan: SessionImportPlan(), includesSecrets: true,
            encrypted: true,
            external: ImportFeedbackText.ExternalImportOutcome(updated: 0, secretsNotRead: 0))
        let unread = ImportFeedbackText.importResultText(
            Self.oneImported(), plan: SessionImportPlan(), includesSecrets: true,
            encrypted: true,
            external: ImportFeedbackText.ExternalImportOutcome(updated: 0, secretsNotRead: 3))

        #expect(quiet.components(separatedBy: "\n").count == 1)
        #expect(unread.components(separatedBy: "\n").count == 2)
    }

    /// The third behaviour the external argument carries: there is no file
    /// behind an import read out of another program's bookmarks, so the
    /// unencrypted-file notice must not appear for it.
    ///
    /// The positive anchor is in the same test: the SAME arguments without
    /// `external` do produce the notice, so a suppression that stopped
    /// matching would show up as the anchor failing rather than as an
    /// absence that is always satisfied.
    @Test func theUnencryptedFileNoticeIsSuppressedForAnExternalImport() {
        let fileImport = ImportFeedbackText.importResultText(
            Self.oneImported(), plan: SessionImportPlan(), includesSecrets: true,
            encrypted: false)
        let externalImport = ImportFeedbackText.importResultText(
            Self.oneImported(), plan: SessionImportPlan(), includesSecrets: true,
            encrypted: false,
            external: ImportFeedbackText.ExternalImportOutcome(updated: 0, secretsNotRead: 0))

        #expect(fileImport.components(separatedBy: "\n").count == 2,
                "the anchor: a file import with plaintext secrets still gets the notice")
        #expect(externalImport.components(separatedBy: "\n").count == 1)
    }

    /// The file import is untouched by the new parameter: omitting it must
    /// produce byte-for-byte what it produced before, on a plan that
    /// exercises several of the conditional lines at once.
    @Test func aFileImportIsUnchangedByTheExternalParameter() {
        var plan = SessionImportPlan()
        plan.replaced = ["A"]
        plan.rejected = ["B"]
        let result = SessionListViewModel.SessionImportResult(
            imported: 3, skipped: 1, passwordsImported: 1, passwordFailures: 1, storeFailures: 0)

        let omitted = ImportFeedbackText.importResultText(
            result, plan: plan, includesSecrets: true, encrypted: false)
        let explicitlyNil = ImportFeedbackText.importResultText(
            result, plan: plan, includesSecrets: true, encrypted: false, external: nil)

        #expect(omitted == explicitlyNil)
        #expect(omitted.contains(String(
            format: L10n.string("import.result.updated %lld", "Existing sessions updated: %lld"), 0))
            == false)
    }
}
