import Foundation
import MacSCPTestSupport
import Testing

/// `ImportKeySheet.performImport()` runs two suspensions —
/// `SSHKeyConverter.copyAsOpenSSH` and `SSHKeyImporter.inspect` — where
/// `GenerateKeySheet` (before `f392c5ad`) and this sheet (before the
/// CI-starvation plan's final review, Important 1) both had the same defect:
/// the `@State` fields stayed live and readable across the `await`, so a
/// passphrase edited mid-run could reach the Keychain under a different
/// secret than the one the key was converted and inspected with.
///
/// `GenerateKeySheet`'s fix moved its fields into a Core `@Observable` type
/// (`GenerateKeySheetRunWiringGuardTests`), which an existing guard
/// (`ConvertKeyWiringGuardTests.theImportSheetConvertsOnTheWayIn`) forbids
/// here: it requires `SSHKeysSheet.swift`'s `performImport(` to call
/// `SSHKeyConverter.copyAsOpenSSH(` directly, in the sheet file, not through
/// an injected default. So this fix stays in the View: every field the run
/// reads is captured into a `let` before the first `await`, the fields are
/// disabled while a run is in flight, and Cancel (plus every other way out
/// of the sheet) cancels the run.
///
/// Read from the corpus's code view, so a comment quoting the wiring is not
/// the wiring.
@Suite("Import key sheet run wiring")
struct ImportKeySheetRunWiringGuardTests {
    private static let sheetFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/SSHKeysSheet.swift")

    private static func sheetBody() throws -> String {
        let code = try SourceCorpus.code(of: sheetFile)
        guard let body = body(of: "struct ImportKeySheet", in: code) else {
            throw BodyMissing()
        }
        return String(code[body])
    }

    /// The same span with string literals kept (comments still blanked):
    /// both views preserve length, so the span found in the strict view
    /// slices this one without a second search.
    private static func sheetBodyKeepingLiterals() throws -> String {
        let code = try SourceCorpus.code(of: sheetFile)
        let literals = try SourceCorpus.commentFree(of: sheetFile)
        guard let body = body(of: "struct ImportKeySheet", in: code) else {
            throw BodyMissing()
        }
        let lower = code.distance(from: code.startIndex, to: body.lowerBound)
        let upper = code.distance(from: code.startIndex, to: body.upperBound)
        let start = literals.index(literals.startIndex, offsetBy: lower)
        let end = literals.index(literals.startIndex, offsetBy: upper)
        return String(literals[start..<end])
    }

    private static func performImportBody() throws -> String {
        let sheet = try sheetBody()
        guard let body = body(of: "private func performImport(", in: sheet) else {
            throw BodyMissing()
        }
        return String(sheet[body])
    }

    @Test func theFieldsAreFixedWhileAnImportIsInFlight() throws {
        let body = try Self.sheetBody()
        #expect(body.contains(".disabled(isImporting)"))
    }

    /// Both ways out cancel: the Cancel button, and `onDisappear` for every
    /// other one (Escape, the parent closing).
    @Test func leavingTheSheetCancelsTheImport() throws {
        #expect(try Self.sheetBody().contains(".onDisappear { importTask?.cancel() }"))
        let body = try Self.sheetBodyKeepingLiterals()
        let cancelButton = try #require(body.range(of: "\"common.cancel\""))
        let afterCancel = body[cancelButton.upperBound...].prefix(120)
        #expect(afterCancel.contains("importTask?.cancel()"), "the Cancel button does not cancel the run")
    }

    /// Positive beside the negative below: every field the run reads is
    /// captured into a named `let` before `performImport()`'s Task starts
    /// (and so before its first `await`).
    @Test func everyFieldTheRunReadsIsCaptured() throws {
        let body = try Self.performImportBody()
        for capture in ["let trimmedName =", "let trimmedComment =", "let capturedPassphrase ="] {
            #expect(body.contains(capture), "\(capture) is missing from performImport()")
        }
        let firstAwait = try #require(body.range(of: "await "))
        for capture in ["trimmedName", "trimmedComment", "capturedPassphrase"] {
            let captureRange = try #require(
                body.range(of: "let \(capture) ="),
                "let \(capture) = is missing from performImport()")
            #expect(
                captureRange.lowerBound < firstAwait.lowerBound,
                "\(capture) is captured after the first await")
        }
    }

    /// Negative, pinned by the positive above: once `capturedPassphrase` is
    /// captured, nothing after the first `await` reads the live `@State`
    /// `passphrase` again — the defect this whole file exists to forbid. A
    /// scan for the bare identifier, excluding `capturedPassphrase` (case
    /// differs) and the `passphrase:` argument LABEL that both calls still
    /// spell.
    @Test func nothingAfterTheFirstAwaitReadsTheLivePassphrase() throws {
        let body = try Self.performImportBody()
        let firstAwait = try #require(body.range(of: "await "))
        let afterFirstAwait = String(body[firstAwait.lowerBound...])
        let regex = try NSRegularExpression(pattern: "\\bpassphrase\\b(?!:)")
        let range = NSRange(afterFirstAwait.startIndex..., in: afterFirstAwait)
        let matches = regex.matches(in: afterFirstAwait, range: range)
        #expect(matches.isEmpty, "the live `passphrase` field is read \(matches.count) time(s) after the first await")
    }

    private struct BodyMissing: Error {}

    /// The span of the brace-balanced body after the first occurrence of
    /// `anchor`.
    private static func body(of anchor: String, in code: String) -> Range<String.Index>? {
        guard let start = code.range(of: anchor),
              let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return open..<code.index(after: index) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }
}
