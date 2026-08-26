import Foundation
import Testing

/// One property, guarded the only way it can be: **`ConnectionViewModel
/// .state` never becomes `.failed` except through `fail(_:kind:)`**, so
/// every failure this type publishes carries a `lastFailureKind` verdict
/// and no failure can silently default to "worth retrying unattended".
///
/// Why a source scan rather than a behavioural test: the property is about
/// paths that do not exist yet. A behavioural test can only check the
/// failures somebody thought to write a test for — which is exactly how the
/// first version of this feature shipped classifying only what the dial
/// threw, while every pre-dial refusal (a dangling login set, a stored
/// secret that is gone) left the verdict `nil`, was read as retryable, and
/// made `.automatic` loop on a question only a person could answer.
///
/// Written as an allow-list of what the right-hand side of a `state = `
/// assignment may be, not as a search for `.failed`. That inversion is
/// deliberate and is the lesson this branch paid for twice: a deny-list
/// passes whatever nobody thought of, an allow-list fails it. Adding a new
/// `state = .idle` needs no edit here; writing a failure any other way
/// fails this suite by default.
@Suite("ConnectionViewModel source guard")
struct ConnectionViewModelSourceGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPCoreTests/ConnectionViewModelSourceGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let viewModelFile = repoRoot.appendingPathComponent(
        "Sources/macSCPCore/Presentation/ConnectionViewModel.swift")

    /// What may follow `state = `. Three entries, counted while writing
    /// this sentence:
    ///
    /// - `.idle` and `.connecting` — neither can be a failure, so neither
    ///   needs a verdict. Any number of them, anywhere.
    /// - `newState` — the parameter inside `fail(_:kind:)`, the one writer
    ///   that sets `lastFailureKind` in the same breath.
    ///
    /// A failure written directly (`state = .failed(...)`) or through any
    /// other local (`state = failure`, `state = jumpFailure`) is not on the
    /// list — which is what all seven of this type's failure sites used to
    /// look like before they were routed through `fail(_:kind:)`.
    private static let allowedAssignments = [".idle", ".connecting", "newState"]

    /// Finds a write to `state` wherever it appears, not where it happens
    /// to start a line.
    ///
    /// Round 2 anchored this on the normalized line PREFIX, and the
    /// reviewer walked past it twice: `self.state = .failed(…)` — mandatory
    /// inside the `Task { @MainActor [weak self] in … }` block this very
    /// file already contains — and `guard ok else { state = .failed(…);
    /// return }`. The identical write at line start was caught. The lesson
    /// is the same one this whole round is about: an anchor is a spelling,
    /// and a spelling fails open.
    ///
    /// `(?<![A-Za-z0-9_])` keeps `newState = …` from matching while letting
    /// any receiver through, since `.`/`?`/`!` and whitespace are all
    /// outside that class — so `self.state`, `self?.state` and a bare
    /// `state` are all seen. `=\s*(?!=)` excludes `==`.
    ///
    /// `_?` covers the `@Observable` macro's backing store: a hand-written
    /// `_state = .failed(…)` inside the type would set the property while
    /// spelling nothing this pattern would otherwise look for. Found by
    /// asking where the property could be violated FROM rather than
    /// whether the pattern still catches what it was written against.
    private static let stateWritePattern = #"(?<![A-Za-z0-9_])_?state\s*=\s*(?!=)"#

    @Test func everyStateAssignmentIsOnTheAllowList() throws {
        let stripped = try Self.stripCommentsAndStrings(
            try String(contentsOf: Self.viewModelFile, encoding: .utf8))
        let writes = try Self.stateWrites(in: stripped)
        var offenders: [String] = []
        let found = writes.count
        for assigned in writes
        where !Self.allowedAssignments.contains(where: { assigned.hasPrefix($0) }) {
            offenders.append("state = \(assigned)")
        }
        #expect(found >= 3, """
            only \(found) `state = ` assignments found in ConnectionViewModel.swift — the \
            scan is not reaching the file it is meant to guard.
            """)
        #expect(offenders.isEmpty, """
            `ConnectionViewModel.state` is assigned something outside the allow-list:
            \(offenders.joined(separator: "\n"))

            A `.failed` state must be published through `fail(_:kind:)`, which sets \
            `lastFailureKind` in the same breath. Written directly, the failure carries no \
            verdict — and a verdict-less failure on a lost tab is read as "worth retrying", \
            which is how an unattended reconnect ends up asking a question nobody is there to \
            answer, on a schedule.
            """)
    }

    /// `fail(_:kind:)` has to actually be what the allow-list assumes it
    /// is: the writer that sets the verdict before the state.
    @Test func theOneFailureWriterSetsTheVerdictFirst() throws {
        let stripped = try Self.stripCommentsAndStrings(
            try String(contentsOf: Self.viewModelFile, encoding: .utf8))
        let normalized = stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        guard let bodyStart = normalized.firstIndex(where: {
            $0.hasPrefix("private func fail(_ newState: State")
        }) else {
            Issue.record("`fail(_:kind:)` no longer exists in ConnectionViewModel.swift")
            return
        }
        let body = normalized[bodyStart...].prefix(5)
        guard let verdictIndex = body.firstIndex(of: "lastFailureKind = kind"),
            let stateIndex = body.firstIndex(of: "state = newState")
        else {
            Issue.record("`fail(_:kind:)` no longer writes both `lastFailureKind` and `state`")
            return
        }
        #expect(verdictIndex < stateIndex, """
            `fail(_:kind:)` writes `state` before `lastFailureKind`. Anything observing \
            `state` would then be able to read the previous attempt's verdict.
            """)
    }

    /// Self-test: the scan must reject a direct failure write wherever it
    /// sits, and accept the sanctioned ones. The last three lines are the
    /// evasions round 2 shipped — a receiver, a weak-self receiver, and a
    /// write buried in a `guard … else` clause.
    @Test func theScanRejectsADirectFailureWriteWhereverItSits() throws {
        let stripped = try Self.stripCommentsAndStrings("""
            // state = .failed(message: "commented out", field: nil)
            state = .idle
            state = .connecting
            state = newState
            if state == .failed(message: m, field: f) { return }
            state = .failed(message: m, field: f)
            self.state = .failed(message: m, field: f)
            Task { @MainActor [weak self] in self?.state = jumpFailure }
            guard ok else { state = .failed(message: m, field: f); return }
            _state = .failed(message: m, field: f)
            """)
        let writes = try Self.stateWrites(in: stripped)
        let offenders = writes.filter { assigned in
            !Self.allowedAssignments.contains { assigned.hasPrefix($0) }
        }
        #expect(writes.count == 8, """
            expected the three allowed writes and the five unsanctioned ones (the comparison \
            and the commented-out line must not count); found \(writes)
            """)
        #expect(offenders.count == 5, "expected the five unsanctioned writes, found \(offenders)")
        #expect(offenders.filter { $0.hasPrefix(".failed(") }.count == 4, """
            a `.failed` written with a receiver, inside a `guard … else` clause, or straight \
            into the observable backing store must be seen exactly like one at the start of a \
            line: \(offenders)
            """)
        #expect(offenders.contains { $0.hasPrefix("jumpFailure") })
    }

    /// Fail-closed self-test: a raw-string delimiter (`#"…"#`) is a form
    /// this stripper does not parse. Left unhandled, it used to
    /// desynchronize the plain-quote counting instead — `#"""#`, an
    /// entirely ordinary literal for one quote character, is read as one
    /// opening quote, one closing quote, and a fresh string that swallows
    /// everything up to the next real `"` in the file, which could be far
    /// below. A `.failed(...)` write hiding past that point would vanish
    /// from the scan along with it. The fix must throw instead.
    @Test func stripperFailsClosedOnARawStringDelimiter() throws {
        let source = "static let quote = #\"\"\"#\nstate = .failed(message: m, field: f)"
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

    /// Every write to `state`, as the text assigned. Returns what follows
    /// the `=` up to the end of that line, whitespace-normalized — enough
    /// for the allow-list to judge, and enough for a failure message to
    /// quote.
    private static func stateWrites(in stripped: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: stateWritePattern)
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.matches(in: stripped, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: stripped) else { return nil }
            let rest = stripped[matchRange.upperBound...]
            let line = rest.prefix { $0 != "\n" }
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
    }

    /// Raised when the source contains something this hand-rolled stripper
    /// cannot parse: a raw-string delimiter it does not understand, or a
    /// string/comment literal that never closes. Either one means the rest
    /// of the read is not trustworthy, so the scan must stop rather than
    /// silently hand back a truncated result.
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

    /// Strips `//` and `/* */` comments and string literals, preserving
    /// line breaks so the scan above can work line by line — a commented-out
    /// or quoted assignment must neither trip the guard nor satisfy it.
    ///
    /// Fails closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse, and an unterminated string or comment means
    /// it ran off the end of the file without finding what it was looking
    /// for. Both throw rather than return whatever was collected so far —
    /// the alternative is a scan that silently reads less than the file it
    /// claims to have checked.
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
}
