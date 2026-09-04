import Foundation
import Testing

/// Keeps the wall-clock deadline shape out of the test tree, now that
/// every poll goes through `pollUntil`. Every negative check here is
/// pinned by a positive one beside it, per CLAUDE.md "Guards that name
/// what they watch". Two shapes were the `ContinuousClock` literal this
/// suite was built to catch; two more, added for the "ceilings under
/// other spellings" plan, are the same property under a `Duration` bound
/// instead — `wait(timeout:)` and a `Task.sleep` child racing real work
/// inside a task group (CLAUDE.md, "A wall-clock ceiling in a test
/// measures the runner").
@Suite("Polling guard")
struct PollingGuardTests {
    private static var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPCoreTests
            .deletingLastPathComponent()   // Tests
    }

    /// Every Swift file under Tests/, minus this guard, the helper that
    /// defines `pollUntil` itself, and `SleepingChildRegexFixture.swift` —
    /// a fixture that intentionally carries the shape
    /// `noSleepingChildRacesWorkInAGroup` looks for, kept out of the scan
    /// it exists to feed a positive check about instead.
    private static func sources() throws -> [(path: String, text: String)] {
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)!
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.path
            if path.hasSuffix("PollingGuardTests.swift")
                || path.hasSuffix("PollUntil.swift")
                || path.hasSuffix("SleepingChildRegexFixture.swift")
            { continue }
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

    /// Negative: no latch is waited on with a wall-clock ceiling.
    /// `AsyncSignal.wait(timeout:)` is `noTestAssertsAnElapsedCeiling`'s
    /// shape under another spelling — a `Duration` bound raced against
    /// scheduled work instead of a `ContinuousClock` literal — and the
    /// "ceilings under other spellings" plan retired every caller that
    /// was not one of three exemptions.
    ///
    /// Two exemptions are found by path: `AsyncSignalTests.swift` tests
    /// the bounded API itself (the positive below), and
    /// `Support/AsyncSignal.swift` declares `wait(timeout:)`, so its own
    /// signature spells the phrase. The third is found by neither path
    /// nor file name, per the brief for this check: `SubprocessRunnerTests.swift`
    /// keeps one bound — `started.wait(timeout: startBound)` — because
    /// there the bound IS the saturation being measured, and the comment
    /// above the call says exactly that ("the bound IS the measurement").
    /// Matching that phrase instead of the file name means a file rename
    /// cannot silently widen the exemption, and rewording the comment
    /// without also removing the wait would turn this check red rather
    /// than quietly staying green.
    @Test func noLatchIsWaitedOnWithATimeout() throws {
        let measurementSentence = "the bound IS the measurement"
        let sources = try Self.sources()

        let callers = sources.filter { $0.text.contains("wait(timeout:") }
        let offenders = callers.filter {
            !$0.path.hasSuffix("AsyncSignalTests.swift")
                && !$0.path.hasSuffix("Support/AsyncSignal.swift")
                && !$0.text.contains(measurementSentence)
        }.map(\.path)

        // Positive: the bounded API is still exercised directly — without
        // this, the negative above could pass over a tree with no callers
        // at all, exempt or otherwise.
        #expect(callers.contains { $0.path.hasSuffix("AsyncSignalTests.swift") })

        // Positive for the third exemption specifically: the measurement
        // sentence is actually live in `SubprocessRunnerTests.swift`,
        // beside a real `wait(timeout:)` call. Without this, that
        // exemption is proven only by the negative below failing to land
        // the file in `offenders` — which is exactly what a rewritten or
        // deleted sentence would also produce, so nothing here would
        // distinguish "the pairing holds" from "the pairing quietly broke
        // and nobody noticed because the file happened not to be scanned
        // as an offender for some other reason."
        #expect(sources.contains {
            $0.path.hasSuffix("SubprocessRunnerTests.swift")
                && $0.text.contains("wait(timeout:")
                && $0.text.contains(measurementSentence)
        })

        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Negative: no test races a sleeping sibling against real work inside
    /// a task group — `ConnectMainActorLivenessTests` and
    /// `CitadelShellIntegrationTests` both carried this shape before the
    /// "ceilings under other spellings" plan: a `group.addTask` whose
    /// first statement is `Task.sleep(for:`, standing in for the harness
    /// `.timeLimit` that already ends a hung test. Scanned over
    /// comment-and-string-blanked source, per CLAUDE.md "Source-scanning
    /// guards read comments too" — a doc comment that writes out the
    /// banned shape to explain it (as this file's own history did, for
    /// the `elapsed <` ceiling) is otherwise indistinguishable from the
    /// shape itself.
    @Test func noSleepingChildRacesWorkInAGroup() throws {
        let pattern = try NSRegularExpression(
            pattern: #"addTask(?:\([^)]*\))?\s*\{\s*(?:try\??\s+)?(?:await\s+)?Task\.sleep\(for:"#)

        let offenders = try Self.sources().compactMap { source -> String? in
            let blanked = try Self.blankCommentsAndStrings(source.text)
            let range = NSRange(blanked.startIndex..., in: blanked)
            return pattern.firstMatch(in: blanked, range: range) != nil ? source.path : nil
        }
        #expect(offenders.isEmpty, "\(offenders)")

        // Positive: the regex matches real, compiling code in this exact
        // shape — `SleepingChildRegexFixture.swift`, excluded from
        // `sources()` above the same way this guard's own file is, so
        // the match it demonstrates can never itself become an offender.
        let fixtureURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/SleepingChildRegexFixture.swift")
        let fixtureText = try String(contentsOf: fixtureURL, encoding: .utf8)
        let fixtureBlanked = try Self.blankCommentsAndStrings(fixtureText)
        let fixtureRange = NSRange(fixtureBlanked.startIndex..., in: fixtureBlanked)
        #expect(pattern.firstMatch(in: fixtureBlanked, range: fixtureRange) != nil)
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
        case unterminatedLiteral
    }

    // MARK: - Comment-and-string blanking, for `noSleepingChildRacesWorkInAGroup`
    //
    // Adapted from `TabContextMenuWiringGuardTests`'s own copy — the only
    // other place in `Tests/` that PARSES a raw string rather than
    // refusing one (counted 2026-09-04, `grep -rl 'hashes: Int' Tests`:
    // two hits, that file and this one — the second). Two more private
    // copies of `stripCommentsAndStrings` exist (`ReconnectWiringGuardTests.swift`,
    // `ConnectingAttemptWiringGuardTests.swift`), plus a shared module per
    // test target (`Tests/macSCPCoreTests/SwiftSourceStripping.swift`,
    // `Tests/macSCPAppKitTests/SwiftSourceStripping.swift`) — but all four
    // FAIL CLOSED on a raw-string delimiter instead of parsing one, which
    // a single-file guard can afford and this scan cannot: it reads the
    // whole test tree, and 35 files under `Tests/` carry a raw string
    // (counted 2026-09-04, `grep -rl '#"' Tests | wc -l`), so refusing
    // them would make the check unusable rather than merely cautious.
    // `TabContextMenuWiringGuardTests`'s own comment states why a private
    // copy at all, rather than a shared one, is kept — the copies had
    // already drifted once — and that reasoning is not restated here.

    /// Whether a raw-string/regex-literal opened with `hashes` hashes and
    /// `quotes` quotes ends exactly at `index`. With `quotes: 0` it answers
    /// the same question for an extended regex literal (`#/…/#`), whose
    /// closing slash the caller has already stepped over.
    private static func closesRawString(
        _ chars: [Character], at index: Int, quotes: Int, hashes: Int
    ) -> Bool {
        guard index + quotes + hashes <= chars.count else { return false }
        for offset in 0..<quotes where chars[index + offset] != "\"" { return false }
        for offset in 0..<hashes where chars[index + quotes + offset] != "#" { return false }
        return true
    }

    /// Strips `//` and `/* */` comments (nesting-aware) and `"..."`,
    /// `"""..."""`, and raw (`#"…"#`, `##"…"##`, `#"""…"""#`) string
    /// literals, replacing their content with spaces so a regex sees only
    /// real code. Line breaks are preserved, so a scan can still work line
    /// by line. Raw strings are parsed rather than refused: this scan
    /// covers the whole test tree, and 35 files under `Tests/` carry one
    /// (counted 2026-09-04, `grep -rl '#"' Tests | wc -l`) — refusing them
    /// would make this check unusable rather than merely cautious. The
    /// delimiter states its own hash count, and the terminator is that
    /// count spelled backwards, so parsing it is not a guess.
    ///
    /// Still fails closed on an unterminated literal — string, comment, or
    /// raw — because that means the scan ran off the end of the file still
    /// inside one, and everything after that point would be judged as
    /// something it is not.
    private static func blankCommentsAndStrings(_ source: String) throws -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                result.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    result.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "#" {
                var j = i
                while j < chars.count, chars[j] == "#" { j += 1 }
                let hashes = j - i
                if j < chars.count, chars[j] == "/" {
                    var k = j + 1
                    var closed = false
                    while k < chars.count {
                        if chars[k] == "/", Self.closesRawString(
                            chars, at: k + 1, quotes: 0, hashes: hashes)
                        {
                            k += 1 + hashes
                            closed = true
                            break
                        }
                        result.append(chars[k] == "\n" ? "\n" : " ")
                        k += 1
                    }
                    guard closed else { throw ScanError.unterminatedLiteral }
                    result.append(" ")
                    i = k
                    continue
                }
                if j < chars.count, chars[j] == "\"" {
                    let isMultiline =
                        j + 2 < chars.count && chars[j + 1] == "\"" && chars[j + 2] == "\""
                    let quotes = isMultiline ? 3 : 1
                    var k = j + quotes
                    var closed = false
                    while k < chars.count {
                        if Self.closesRawString(chars, at: k, quotes: quotes, hashes: hashes) {
                            k += quotes + hashes
                            closed = true
                            break
                        }
                        result.append(chars[k] == "\n" ? "\n" : " ")
                        k += 1
                    }
                    guard closed else { throw ScanError.unterminatedLiteral }
                    result.append(" ")
                    i = k
                    continue
                }
                // Not a string delimiter: `#expect`, `#filePath`, `#if`.
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                guard i + 2 < chars.count else { throw ScanError.unterminatedLiteral }
                i += 3
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { throw ScanError.unterminatedLiteral }
                i += 1
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        guard blockCommentDepth == 0 else { throw ScanError.unterminatedLiteral }
        return result
    }
}
