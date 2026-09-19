import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

/// The "Generate SSH Key" sheet drives `GenerateKeyForm` and nothing else.
///
/// `SSHKeyGenerator.generate` is awaited since 2026-09-19 (the CI-starvation
/// plan, Task 2), so the sheet is live while `ssh-keygen` runs. The form
/// captures its inputs when a run starts and cancels cleanly
/// (`GenerateKeyFormTests`); what this pins is the sheet's half: it keeps no
/// field state of its own that a run could read after the await, it fixes
/// the fields while a run is in flight, and every way out of the sheet
/// cancels the run, so a dismissed sheet adds no key.
///
/// Read from the corpus's code view, so a comment quoting the wiring is not
/// the wiring. The form's type name is derived from the type.
@Suite("Generate key sheet run wiring")
struct GenerateKeySheetRunWiringGuardTests {
    private static let sheetFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/SSHKeysSheet.swift")
    private static let form = String(describing: GenerateKeyForm.self)

    private static func sheetBody() throws -> String {
        let code = try SourceCorpus.code(of: sheetFile)
        guard let body = body(of: "struct GenerateKeySheet", in: code) else {
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
        guard let body = body(of: "struct GenerateKeySheet", in: code) else {
            throw BodyMissing()
        }
        let lower = code.distance(from: code.startIndex, to: body.lowerBound)
        let upper = code.distance(from: code.startIndex, to: body.upperBound)
        let start = literals.index(literals.startIndex, offsetBy: lower)
        let end = literals.index(literals.startIndex, offsetBy: upper)
        return String(literals[start..<end])
    }

    /// Positive beside the negative below: the sheet holds a form.
    @Test func theSheetHoldsTheForm() throws {
        let body = try Self.sheetBody()
        #expect(body.contains("@State private var form = \(Self.form)()"))
    }

    /// Negative: no other `@State`. A field kept on the sheet itself is one
    /// a run could read after `ssh-keygen` returns — the defect the form
    /// exists to make unwritable.
    @Test func theSheetKeepsNoFieldStateOfItsOwn() throws {
        let body = try Self.sheetBody()
        let states = body.components(separatedBy: "@State").count - 1
        #expect(states == 1, "GenerateKeySheet declares \(states) @State properties")
    }

    @Test func theFieldsAreFixedWhileARunIsInFlight() throws {
        let body = try Self.sheetBody()
        #expect(body.contains(".disabled(form.isGenerating)"))
    }

    /// Both ways out cancel: the Cancel button, and `onDisappear` for every
    /// other one (Escape, the parent closing).
    @Test func leavingTheSheetCancelsTheRun() throws {
        #expect(try Self.sheetBody().contains(".onDisappear { form.cancel() }"))
        let body = try Self.sheetBodyKeepingLiterals()
        let cancelButton = try #require(body.range(of: "\"common.cancel\""))
        let afterCancel = body[cancelButton.upperBound...].prefix(120)
        #expect(afterCancel.contains("form.cancel()"), "the Cancel button does not cancel the run")
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
