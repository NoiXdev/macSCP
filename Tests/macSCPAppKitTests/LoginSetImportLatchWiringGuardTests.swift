import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

/// Login-set import runs through `SessionListViewModel.loginSetImports`, a
/// `OneAtATime` latch, and the sheet greys its Import action out while the
/// latch is held.
///
/// Why it needs one: planning and applying are both `async` — applying
/// awaits `ssh-keygen` once per embedded key since 2026-09-19 (the
/// CI-starvation plan, Task 2) — so a second import started while the first
/// is suspended would plan against the same `loginSets` snapshot and write
/// duplicate sets and keys. `OneAtATimeTests` proves the latch refuses an
/// overlapping run; this pins that the sheet actually goes through it.
///
/// Read from the corpus's code view (`SwiftSource.blankingCommentsAndStrings`),
/// so a comment quoting the wiring is not the wiring. The latch's property
/// name is read off a key path, so renaming the property breaks compilation
/// here instead of leaving a check that matches nothing.
///
/// `@MainActor` only because a key path to a main-actor-isolated property
/// can be formed only there; the checks themselves read one file.
@Suite("Login-set import latch wiring")
@MainActor
struct LoginSetImportLatchWiringGuardTests {
    private static let sheetFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/LoginSetsSheet.swift")

    /// `loginSetImports`, derived from the key path rather than spelled.
    private static let latchName: String = {
        let described = String(describing: \SessionListViewModel.loginSetImports)
        return String(described.split(separator: ".").last ?? "")
    }()

    private static let runningName: String = {
        let described = String(describing: \OneAtATime.isRunning)
        return String(described.split(separator: ".").last ?? "")
    }()

    /// The derivation itself, so a key-path description that stopped naming
    /// the property cannot turn every check below into a search for "".
    @Test func theNamesAreDerived() {
        #expect(Self.latchName == "loginSetImports")
        #expect(Self.runningName == "isRunning")
    }

    /// Positive: the sheet's Import action is offered only while the latch
    /// is free.
    @Test func theImportActionIsGreyedWhileAnImportRuns() throws {
        let code = try SourceCorpus.code(of: Self.sheetFile)
        let wiring = "canImport: !sessionList.\(Self.latchName).\(Self.runningName)"
        #expect(code.contains(wiring), "LoginSetsSheet.swift does not pass `\(wiring)`")
    }

    /// Negative, beside a positive that the argument is there at all: the
    /// sheet does not offer Import unconditionally.
    @Test func theImportActionIsNeverOfferedUnconditionally() throws {
        let code = try SourceCorpus.code(of: Self.sheetFile)
        #expect(code.contains("canImport:"), "LoginSetsSheet.swift no longer passes `canImport:` at all")
        #expect(code.contains("canImport: true") == false)
    }

    /// Positive: the plan-and-apply body runs inside the latch.
    @Test func thePlanAndApplyRunInsideTheLatch() throws {
        let code = try SourceCorpus.code(of: Self.sheetFile)
        let body = try #require(Self.body(of: "func applyImport(", in: code))
        #expect(body.contains("sessionList.\(Self.latchName).run"), "applyImport does not run through the latch")
        #expect(body.contains("applyLoginSetImport("), "applyImport no longer applies the plan — re-anchor this guard")
    }

    /// The brace-balanced body after the first occurrence of `anchor`.
    private static func body(of anchor: String, in code: String) -> String? {
        guard let start = code.range(of: anchor),
              let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(code[open...index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }
}
