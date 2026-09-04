import Foundation
import Testing

/// Keeps the wall-clock deadline shape out of the test tree, now that
/// every poll goes through `pollUntil`. Two negative checks, each pinned
/// by a positive one beside it, per CLAUDE.md "Guards that name what
/// they watch".
@Suite("Polling guard")
struct PollingGuardTests {
    private static var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPCoreTests
            .deletingLastPathComponent()   // Tests
    }

    /// Every Swift file under Tests/, minus this guard and the helper that
    /// defines `pollUntil` itself.
    private static func sources() throws -> [(path: String, text: String)] {
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)!
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.path
            if path.hasSuffix("PollingGuardTests.swift") || path.hasSuffix("PollUntil.swift") { continue }
            result.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    /// Positive: the helper is in use. Without this, the negative checks
    /// below could pass over an empty tree.
    @Test func theTreePollsThroughTheSharedHelper() throws {
        let callers = try Self.sources().filter { $0.text.contains("pollUntil(") }
        #expect(callers.count >= 10, "\(callers.count) files call pollUntil")
    }

    /// Negative: no test builds its own deadline from the clock.
    @Test func noTestCarriesItsOwnDeadline() throws {
        let offenders = try Self.sources().filter {
            $0.text.contains("let deadline = ContinuousClock.now")
                || $0.text.contains("ContinuousClock.now.advanced(by:")
        }.map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Negative: no elapsed-time ceiling. The floor (`>=`, `>`) is allowed.
    ///
    /// This scans prose too, not only code — CLAUDE.md "Source-scanning
    /// guards read comments too": a comment that quotes the banned shape
    /// verbatim is indistinguishable from the shape itself to this regex.
    /// A historical note in `LivenessProbeRaceTests.swift` used to spell
    /// `elapsed < .seconds(20)` to explain what an earlier version
    /// asserted; it now describes the same fact in prose instead of
    /// quoting the code, per that same rule.
    @Test func noTestAssertsAnElapsedCeiling() throws {
        let pattern = try NSRegularExpression(pattern: #"elapsed\s*<=?\s*\."#)
        let offenders = try Self.sources().filter {
            pattern.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil
        }.map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Positive for the two negatives above, the other way round: a floor
    /// exists in the tree, so the ceiling regex is looking at real
    /// `elapsed` comparisons, not at nothing.
    @Test func aFloorExistsSoTheCeilingCheckHasSomethingToRead() throws {
        let floors = try Self.sources().filter { $0.text.contains("elapsed >= ") || $0.text.contains("elapsed > ") }
        #expect(!floors.isEmpty)
    }

    /// Every file that reaches `pollUntil` — directly, or through a helper
    /// function defined in a file with no suite of its own — declares a
    /// time limit, so a condition that never holds is a red, not a hang.
    ///
    /// Drafted first as a flat per-file `pollUntil(` scan, that version
    /// was red on `Tests/macSCPCoreTests/LoopbackHTTPStub.swift`: a helper
    /// file with no `@Suite`/`@Test` of its own, so no test to put a
    /// `.timeLimit` on, and it missed the four suites
    /// (`S3SessionIsolationTests`, `S3RedirectControlTests`,
    /// `S3RedirectAuthorizationMeasurementTests`,
    /// `ConnectFailureSecrecyTests`) that reach an unbounded poll only
    /// through `LoopbackHTTPStub.waitForRequests` and so contain no literal
    /// `pollUntil(` themselves. Both are fixed here structurally rather
    /// than by naming files: a file that declares neither `@Suite` nor
    /// `@Test` is a helper, and every `func` such a file declares whose
    /// body — found by brace-balancing from the parameter list, the
    /// technique `TransferQueueBarCancelGuardTests.declarationBodyRange`
    /// uses in the App target for the same reason — contains `pollUntil(`
    /// is a helper name. A suite file that calls `pollUntil(` directly, or
    /// calls one of those helper names, must carry `.timeLimit(`.
    @Test func everyCallerOfPollUntilDeclaresATimeLimit() throws {
        let sources = try Self.sources()
        let helperFiles = sources.filter { !$0.text.contains("@Suite") && !$0.text.contains("@Test") }
        let suiteFiles = sources.filter { $0.text.contains("@Suite") || $0.text.contains("@Test") }

        let helperNames = try Self.pollingHelperFunctionNames(in: helperFiles)

        let directCallers = suiteFiles.filter { $0.text.contains("pollUntil(") }
        let indirectCallers = suiteFiles.filter { file in
            !file.text.contains("pollUntil(")
                && helperNames.contains { file.text.contains("\($0)(") }
        }
        let callers = directCallers + indirectCallers
        let withoutLimit = callers.filter { !$0.text.contains(".timeLimit(") }.map(\.path)

        // Positive pairing: the helper set is not accidentally empty (it
        // must at least contain the one this check exists for), and there
        // are direct callers for the negative check to have found in the
        // first place.
        #expect(!helperNames.isEmpty)
        #expect(helperNames.contains("waitForRequests"), "\(helperNames)")
        #expect(!directCallers.isEmpty)

        #expect(withoutLimit.isEmpty, "\(withoutLimit)")
    }

    /// The name of every `func` a helper file declares whose body contains
    /// `pollUntil(`. A small local brace-balancer, not a shared one: this
    /// guard lives in Core and the model
    /// (`TransferQueueBarCancelGuardTests.declarationBodyRange`) lives in
    /// the App target's test tree, which Core's tests do not depend on.
    private static func pollingHelperFunctionNames(
        in files: [(path: String, text: String)]
    ) throws -> Set<String> {
        let funcPattern = try NSRegularExpression(
            pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\("#)
        var names: Set<String> = []
        for file in files {
            let text = file.text
            let nsrange = NSRange(text.startIndex..., in: text)
            for match in funcPattern.matches(in: text, range: nsrange) {
                guard let nameRange = Range(match.range(at: 1), in: text),
                    let wholeRange = Range(match.range, in: text)
                else { continue }
                let name = String(text[nameRange])
                // `wholeRange` ends just past the parameter list's opening
                // '(' — that character is where the brace balancer starts.
                let openParen = text.index(before: wholeRange.upperBound)
                guard let body = try? Self.functionBody(afterParametersAt: openParen, in: text) else { continue }
                if body.contains("pollUntil(") {
                    names.insert(name)
                }
            }
        }
        return names
    }

    /// Balances the parameter list's parens first — so a default argument
    /// like `every interval: Duration = .milliseconds(5)` cannot be read
    /// as closing the list early — then balances the braces of the body
    /// that follows, the same two-pass shape
    /// `TransferQueueBarCancelGuardTests.declarationBodyRange` uses.
    private static func functionBody(
        afterParametersAt openParen: String.Index, in text: String
    ) throws -> String {
        var parenDepth = 0
        var index = openParen
        while index < text.endIndex {
            if text[index] == "(" {
                parenDepth += 1
            } else if text[index] == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let afterParams = text.index(after: index)
                    guard let openBrace = text[afterParams...].firstIndex(of: "{") else {
                        throw ScanError.bodyNotFound
                    }
                    var braceDepth = 0
                    var cursor = openBrace
                    while cursor < text.endIndex {
                        if text[cursor] == "{" {
                            braceDepth += 1
                        } else if text[cursor] == "}" {
                            braceDepth -= 1
                            if braceDepth == 0 {
                                return String(text[text.index(after: openBrace)..<cursor])
                            }
                        }
                        cursor = text.index(after: cursor)
                    }
                    throw ScanError.unbalancedBraces
                }
            }
            index = text.index(after: index)
        }
        throw ScanError.bodyNotFound
    }

    private enum ScanError: Error {
        case bodyNotFound
        case unbalancedBraces
    }
}
