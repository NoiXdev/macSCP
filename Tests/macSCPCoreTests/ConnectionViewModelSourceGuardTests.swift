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

    @Test func everyStateAssignmentIsOnTheAllowList() throws {
        let stripped = Self.stripCommentsAndStrings(
            try String(contentsOf: Self.viewModelFile, encoding: .utf8))
        var offenders: [String] = []
        var found = 0
        for rawLine in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
            guard line.hasPrefix("state = ") else { continue }
            found += 1
            let assigned = String(line.dropFirst("state = ".count))
            if !Self.allowedAssignments.contains(where: { assigned.hasPrefix($0) }) {
                offenders.append(line)
            }
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
        let stripped = Self.stripCommentsAndStrings(
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

    /// Self-test: the scan must reject a direct failure write and accept
    /// the sanctioned ones, on synthetic source.
    @Test func theScanRejectsADirectFailureWrite() {
        let stripped = Self.stripCommentsAndStrings("""
            // state = .failed(message: "commented out", field: nil)
            state = .idle
            state = .connecting
            state = newState
            state = .failed(message: m, field: f)
            state = jumpFailure
            """)
        let offenders = stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { $0.hasPrefix("state = ") }
            .filter { line in
                let assigned = String(line.dropFirst("state = ".count))
                return !Self.allowedAssignments.contains { assigned.hasPrefix($0) }
            }
        #expect(offenders.count == 2, "expected the two unsanctioned writes, found \(offenders)")
        #expect(offenders.contains { $0.contains(".failed(") })
        #expect(offenders.contains { $0.contains("jumpFailure") })
    }

    /// Strips `//` and `/* */` comments and string literals, preserving
    /// line breaks so the scan above can work line by line — a commented-out
    /// or quoted assignment must neither trip the guard nor satisfy it.
    private static func stripCommentsAndStrings(_ source: String) -> String {
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
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                i = min(i + 3, chars.count)
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                i = min(i + 1, chars.count)
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }
}
