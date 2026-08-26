import Foundation
import Testing

/// Guards that the Keep-Alive interval stepper's commit path in
/// `SettingsView.swift` writes `store.keepAliveIntervalSeconds` ONLY
/// through `KeepAliveControlPlan.storedValue(forIntervalChangeTo:isEnabled:)`
/// — however that write is spelled.
///
/// Added in Task 9's fix round 1: review found the stepper's `set` closure
/// writing the committed value straight to the store, bypassing
/// `KeepAliveControlPlan` entirely. That call site was safe only because
/// the Stepper's own `15...600` range and `.disabled` state kept `0` out —
/// not because anything tested said so — so a regression reintroduced at
/// the call site itself could never be caught by mutating the plan, which
/// is the whole point of having extracted it. `KeepAliveControlPlanTests`
/// proves what the plan function itself does; this proves the real call
/// site actually reaches it.
///
/// **Fix round 2 rewrote the check entirely.** Round 1's version matched
/// two independent `contains` substrings for the positive claim and one
/// exact-spelling `contains` for the negative claim. The reviewer defeated
/// it in one mutation: `let committedInterval = newValue; store
/// .keepAliveIntervalSeconds = committedInterval`, plus a decorative
/// comment mentioning `KeepAliveControlPlan.storedValue(forIntervalChangeTo:`
/// — the comment satisfied both positive checks (a `contains` cannot tell
/// prose from code), and the real assignment's spelling never matched the
/// one exact-spelling negative check. All seven tests in round 1's version
/// passed against a genuine bypass. The same evasion — a guard proving a
/// spelling rather than a property — already defeated two guards earlier on
/// this branch (Tasks 6 and 7), which is why `stripCommentsAndStrings`
/// below is a straight reuse of the same helper written for
/// `ReconnectWiringGuardTests`/`ConnectingAttemptWiringGuardTests`, not a
/// third reimplementation of it.
///
/// This version strips comments and strings FIRST — so a comment can
/// neither satisfy the positive claim nor hide a bypass behind prose — then
/// collapses all remaining whitespace, so line-wrapping or reformatting the
/// real call (which broke round 1's positive check once already) cannot
/// affect the match either. What is then checked is not a spelling but a
/// COUNT: `keepAliveIntervalSeconds=` (the property name immediately
/// followed by an assignment, with no whitespace to hide behind) must occur
/// EXACTLY ONCE in the closure — every other appearance of the property
/// name is a read, which is untouched by this check — and that one
/// occurrence's right-hand side must be exactly the sanctioned plan call.
/// An intermediate local, a `self.store.` prefix, or a keypath write that
/// replaces the sanctioned assignment all fail this the same way: either
/// the one write's right-hand side is not the plan call, or the sanctioned
/// shape is simply absent and the count comes back `0`.
///
/// Same boundary as this project's other wiring guards: a SOURCE-TEXT
/// scan, not a behavioral test — this project has no SwiftUI rendering
/// harness, so a `Stepper`'s `set` closure can only be checked by reading
/// it, not by running it. Fail-closed: an unreadable file, a missing
/// anchor, or unbalanced braces all count as failures. Self-tested against
/// synthetic source, including both fix-round-2 mutations described above,
/// so the guard cannot pass silently just because the real file moved, was
/// reformatted past recognition, or was defeated by a decorative comment.
@Suite("Keep-alive interval stepper wiring guard")
struct KeepAliveStepperWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/KeepAliveStepperWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `ConnectTimeoutAppWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")

    /// Anchors the interval stepper's `set` closure, unique in the file
    /// (checked by `theAnchorAppearsExactlyOnceInTheRealFile` below). The
    /// auto-refresh interval's own `set` closure elsewhere in the same file
    /// uses `set: { store.autoRefreshIntervalSeconds = $0 }` — a different
    /// shape entirely, so this anchor cannot accidentally match it.
    private static let anchor = "set: { newValue in"

    private static let writeMarker = "keepAliveIntervalSeconds="
    private static let sanctionedRHS = "KeepAliveControlPlan.storedValue(forIntervalChangeTo:"

    /// Extracts the body of the closure `anchor` opens — everything
    /// between `anchor`'s own `{` (already consumed by the anchor string)
    /// and its matching `}`, by plain brace counting. `nil` on a missing
    /// anchor or unbalanced braces rather than a guess.
    private static func setClosureBody(in source: String) -> String? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        var depth = 1
        var index = anchorRange.upperBound
        let bodyStart = index
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart..<index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Strips `//` and `/* */` comments and both `"..."` and `"""..."""`
    /// string literals, preserving line breaks. Reused verbatim from
    /// `ReconnectWiringGuardTests` rather than reimplemented: this is the
    /// second time on this branch a `contains`-based guard was defeated by
    /// a comment naming the expected call in prose.
    ///
    /// Copied, not shared, because this project keeps one private copy per
    /// guard file. The copies have already drifted — the one in
    /// `ConnectingAttemptWiringGuardTests` handles whitespace and newlines
    /// differently — so a fix to one does not reach the others, which is
    /// exactly how this guard came to repeat a mistake already solved
    /// twice.
    ///
    /// Handles `\"`-escaped quotes and nested `/* */` comments. Does not
    /// parse string interpolation — `\(...)` inside a literal is treated as
    /// string content, which can only make a check find LESS text, never
    /// invent a match that was not code.
    ///
    /// Fails closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse, and an unterminated string or comment means
    /// it ran off the end of the file without finding what it was looking
    /// for. Both throw rather than return whatever was collected so far —
    /// the alternative is a scan that silently reads less than the file it
    /// claims to have checked.
    private enum StripError: Error, CustomStringConvertible {
        case unrecognizedDelimiter
        case unterminatedLiteral

        var description: String {
            switch self {
            case .unrecognizedDelimiter:
                return """
                    unrecognized string delimiter (a raw string's `#"`, `##"`, …) — this \
                    stripper does not parse raw strings and refuses to guess where one ends
                    """
            case .unterminatedLiteral:
                return "unterminated string or comment literal"
            }
        }
    }

    private static func stripCommentsAndStrings(_ source: String) throws -> String {
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
                if j < chars.count, chars[j] == "\"" {
                    throw StripError.unrecognizedDelimiter
                }
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                guard i + 2 < chars.count else { throw StripError.unterminatedLiteral }
                i += 3
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { throw StripError.unterminatedLiteral }
                i += 1
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        guard blockCommentDepth == 0 else { throw StripError.unterminatedLiteral }
        return result
    }

    /// Comment/string-stripped, then whitespace-collapsed — canonical form
    /// a mutation cannot evade by reformatting, wrapping arguments onto new
    /// lines, or writing prose that merely mentions the expected call.
    private static func canonicalize(_ body: String) throws -> String {
        try Self.stripCommentsAndStrings(body).filter { !$0.isWhitespace }
    }

    /// Every right-hand side that follows a `keepAliveIntervalSeconds=`
    /// occurrence in `canonicalBody` — one entry per write to the property,
    /// however it is qualified (`store.`, `self.store.`, or no qualifier
    /// at all): the search is on the property name and the `=` immediately
    /// following it, not on any particular prefix. A read (the property
    /// name followed by anything other than `=`, e.g. a closing paren)
    /// produces no entry.
    private static func writeSiteRHSes(in canonicalBody: String) -> [Substring] {
        var results: [Substring] = []
        var searchStart = canonicalBody.startIndex
        while let markerRange = canonicalBody.range(
            of: Self.writeMarker, range: searchStart..<canonicalBody.endIndex)
        {
            results.append(canonicalBody[markerRange.upperBound...])
            searchStart = markerRange.upperBound
        }
        return results
    }

    /// Extract the anchored `set` closure's body, canonicalize it, and list
    /// its write sites — the same steps the real-file check performs, in one
    /// call, so the synthetic-source self-tests exercise the scanner rather
    /// than a hand-assembled variant of it.
    ///
    /// Unwraps with `#require` rather than optional-chaining the rest of the
    /// checks through a `String?`: a missing anchor and an unbalanced brace
    /// both leave nothing to count, and letting that surface as a failed
    /// count assertion reports the wrong cause. Fail-closed either way — the
    /// `#require` throws, so the calling test fails and can never pass on a
    /// source the scanner could not read. `sourceLocation` is forwarded so
    /// the failure is attributed to the calling test, not to this helper.
    private static func writeSiteRHSesOfSetClosure(
        in source: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [Substring] {
        let body = try #require(
            Self.setClosureBody(in: source),
            """
            no `\(Self.anchor)` closure could be extracted from this source — \
            the anchor is missing or its braces are unbalanced, so the scanner \
            has nothing to check.
            """,
            sourceLocation: sourceLocation)
        return try Self.writeSiteRHSes(in: Self.canonicalize(body))
    }

    // MARK: - The guarded claim, run against the real file

    @Test func theIntervalStepperWritesOnlyThroughThePlan() throws {
        let source = try String(contentsOf: Self.settingsFile, encoding: .utf8)
        let body = try #require(Self.setClosureBody(in: source), """
            no `\(Self.anchor)` closure found in SettingsView.swift — \
            re-anchor this guard.
            """)
        let rhses = try Self.writeSiteRHSes(in: Self.canonicalize(body))
        #expect(rhses.count == 1, """
            expected exactly 1 write to `keepAliveIntervalSeconds` in the \
            interval stepper's `set` closure (comments and strings stripped, \
            whitespace collapsed), found \(rhses.count) — either the plan call \
            is missing entirely, or there is more than one write site.
            """)
        if let rhs = rhses.first {
            #expect(rhs.hasPrefix(Self.sanctionedRHS), """
                the interval stepper's one write to `keepAliveIntervalSeconds` \
                does not start with `\(Self.sanctionedRHS)` — found it assigning \
                from `\(rhs.prefix(60))…` instead. This bypasses \
                `KeepAliveControlPlan`, however the bypass is spelled (an \
                intermediate local, `self.store`, a keypath): comments and \
                strings are already stripped and whitespace already collapsed \
                before this check runs, so neither a decorative comment nor \
                reformatting can satisfy it.
                """)
        }
    }

    /// Fail-closed check, same reasoning as
    /// `ConnectTimeoutAppWiringGuardTests.theAnchorAppearsExactlyOnceInTheRealFile`:
    /// if the anchor ever stops being unique, the guard above could be
    /// matching the wrong closure silently.
    @Test func theAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.settingsFile, encoding: .utf8)
        let count = source.components(separatedBy: Self.anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.anchor)` in \
            SettingsView.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerAcceptsARoutedCommitOnOneLine() throws {
        let source = """
            set: { newValue in
                lastKnownKeepAliveInterval = newValue
                store.keepAliveIntervalSeconds = KeepAliveControlPlan.storedValue(
                    forIntervalChangeTo: newValue, isEnabled: true)
            }
            """
        let rhses = try Self.writeSiteRHSesOfSetClosure(in: source)
        #expect(rhses.count == 1)
        #expect(rhses.first?.hasPrefix(Self.sanctionedRHS) == true)
    }

    /// Wrapped-argument call shape — the ACTUAL shape the real file uses
    /// (`storedValue(` on one line, `forIntervalChangeTo:` on the next).
    /// This is the case that first defeated a single concatenated-literal
    /// `contains` check in round 1 — kept here so the scanner itself, not
    /// just the real-file assertion, is pinned against it.
    @Test func scannerAcceptsARoutedCommitWithWrappedArguments() throws {
        let source = """
            set: { newValue in
                lastKnownKeepAliveInterval = newValue
                store.keepAliveIntervalSeconds = KeepAliveControlPlan.storedValue(
                    forIntervalChangeTo: newValue,
                    isEnabled: KeepAliveControlPlan.isEnabled(
                        storedSeconds: store.keepAliveIntervalSeconds))
            }
            """
        let rhses = try Self.writeSiteRHSesOfSetClosure(in: source)
        #expect(rhses.count == 1)
        #expect(rhses.first?.hasPrefix(Self.sanctionedRHS) == true)
    }

    @Test func scannerFlagsABypassedRawAssignment() throws {
        let source = """
            set: { newValue in
                lastKnownKeepAliveInterval = newValue
                store.keepAliveIntervalSeconds = newValue
            }
            """
        let rhses = try Self.writeSiteRHSesOfSetClosure(in: source)
        #expect(rhses.count == 1)
        #expect(rhses.first?.hasPrefix(Self.sanctionedRHS) == false)
    }

    /// The reviewer's exact fix-round-1 mutation: an intermediate local
    /// carries the committed value, and a decorative comment names the
    /// sanctioned call without the code ever making it. Round 1's guard —
    /// two `contains` checks on raw source — passed this. This one must
    /// not: stripping comments removes the decoy, and the real assignment's
    /// right-hand side (`committedInterval`, not the plan call) fails the
    /// prefix check.
    @Test func scannerFlagsTheReviewersIntermediateLocalMutation() throws {
        let source = """
            set: { newValue in
                lastKnownKeepAliveInterval = newValue
                // KeepAliveControlPlan.storedValue(forIntervalChangeTo:
                let committedInterval = newValue
                store.keepAliveIntervalSeconds = committedInterval
            }
            """
        let rhses = try Self.writeSiteRHSesOfSetClosure(in: source)
        #expect(rhses.count == 1)
        #expect(rhses.first?.hasPrefix(Self.sanctionedRHS) == false)
    }

    /// A second, DIFFERENT mutation from the reviewer's — round 1's guard
    /// would ALSO have passed this one. The decorative comment satisfies
    /// round 1's two positive `contains` checks the same way; the real
    /// assignment bypasses the plan by writing `newValue` directly, but
    /// with the spaces around `=` removed, which slips past round 1's
    /// single exact-spelling negative check (`contains("keepAliveIntervalSeconds
    /// = newValue")`, with spaces) without slipping past this one — the
    /// canonical form already collapses all whitespace before the write
    /// count runs, so reformatting the assignment changes nothing here.
    @Test func scannerFlagsARespacedRawAssignmentBehindADecorativeComment() throws {
        let source = """
            set: { newValue in
                lastKnownKeepAliveInterval = newValue
                // KeepAliveControlPlan.storedValue(forIntervalChangeTo:
                store.keepAliveIntervalSeconds=newValue
            }
            """
        let rhses = try Self.writeSiteRHSesOfSetClosure(in: source)
        #expect(rhses.count == 1)
        #expect(rhses.first?.hasPrefix(Self.sanctionedRHS) == false)
    }

    @Test func scannerFlagsASelfStoreQualifiedBypass() throws {
        let source = """
            set: { newValue in
                lastKnownKeepAliveInterval = newValue
                self.store.keepAliveIntervalSeconds = newValue
            }
            """
        let rhses = try Self.writeSiteRHSesOfSetClosure(in: source)
        #expect(rhses.count == 1)
        #expect(rhses.first?.hasPrefix(Self.sanctionedRHS) == false)
    }

    @Test func scannerFailsClosedOnAMissingAnchor() {
        #expect(Self.setClosureBody(in: "nothing to see here") == nil)
    }

    @Test func scannerFailsClosedOnUnbalancedBraces() {
        let source = "set: { newValue in store.keepAliveIntervalSeconds = newValue"
        #expect(Self.setClosureBody(in: source) == nil)
    }

    /// Fail-closed self-test: a raw-string delimiter (`#"…"#`) is a form
    /// this stripper does not parse. Left unhandled, it used to
    /// desynchronize the plain-quote counting instead — `#"""#`, an
    /// entirely ordinary literal for one quote character, is read as one
    /// opening quote, one closing quote, and a fresh string that swallows
    /// everything up to the next real `"` in the file, which could hide a
    /// bypassed write past that point. The fix must throw instead.
    @Test func stripperFailsClosedOnARawStringDelimiter() throws {
        let source = "static let quote = #\"\"\"#\nstore.keepAliveIntervalSeconds = newValue"
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings(source)
        }
    }

    /// Fail-closed self-test: a string or block comment that never closes
    /// must not be treated as "closed at end of file" — that is the same
    /// truncation risk under a different cause.
    @Test func stripperFailsClosedOnAnUnterminatedLiteral() throws {
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            try Self.stripCommentsAndStrings("/* never closes")
        }
    }

    @Test func stripperSelfTestRemovesLineAndBlockCommentsAndStringLiterals() throws {
        let source = #"""
            let a = "KeepAliveControlPlan.storedValue(" // KeepAliveControlPlan.storedValue(
            /* KeepAliveControlPlan.storedValue( */ let b = 1
            let c = """
                KeepAliveControlPlan.storedValue(
                """
            KeepAliveControlPlan.storedValue(
            """#
        let stripped = try Self.stripCommentsAndStrings(source)
        #expect(stripped.components(separatedBy: "KeepAliveControlPlan.storedValue(").count - 1 == 1, """
            expected exactly 1 real occurrence of `KeepAliveControlPlan.storedValue(` \
            to survive stripping; found \
            \(stripped.components(separatedBy: "KeepAliveControlPlan.storedValue(").count - 1).
            """)
    }
}
