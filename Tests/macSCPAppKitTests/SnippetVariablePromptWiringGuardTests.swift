import Foundation
import Testing

/// Guards two `ContentView.swift` call-site facts (Snippet-Variablen, Task 6,
/// fix round 1) that no functional test can reach — the same
/// "exists but is not wired right" shape `SnippetAuditWiringGuardTests`,
/// `PaneVisibilityWiringGuardTests`, and `PaneRenderConditionGuardTests`
/// already exist to catch elsewhere in this project:
///
/// 1. `runSnippet` must pass the ORIGINAL `snippet` — never the resolved
///    command, nor a `Snippet` built around it — to
///    `SnippetAuditDetail.text(for:)`. `SnippetAuditDetailTests
///    .variableValuesStayOutOfTheAuditLog` (Core layer) proves the
///    substitution mechanism WOULD leak a value into a resolved command if
///    fed to `text(for:)`; it cannot see which argument `runSnippet` actually
///    passes, because `SnippetAuditDetail.text(for:)` takes a `Snippet`, and
///    the wrong choice is entirely an App-layer call-site mistake. Proven
///    non-hypothetical by review: rewiring the real call site to log the
///    resolved command left the full suite green, `variableValuesStayOutOfTheAuditLog`
///    included.
/// 2. `rememberOptedInValues` must filter on `SnippetVariable
///    .remembersLastValue` BEFORE calling `.remember(...)`.
///    `SnippetVariableMemoryStore` deliberately does not check the opt-in
///    itself (see its own doc comment: "This store does not know which
///    declarations opted in"), so this filter is the ONLY thing standing
///    between a user's typed value and a plain JSON file they never agreed
///    to persist. No functional test reaches it either: `SnippetVariableMemoryStoreTests`
///    exercises the store directly with values it is TOLD to remember, never
///    through this filter, so a deleted `where` clause would still pass every
///    other test in the suite.
///
/// Both are SOURCE-TEXT scans, not behavioral tests — this project has no
/// SwiftUI rendering/instantiation harness (see `SnippetActionSheet`'s own
/// doc comment for the same boundary) — and share the known blind spots the
/// precedent guards above already document: line-based and literal, aimed at
/// an accidental regression (a rewiring, a deleted clause) rather than a
/// hostile rewrite that disguises itself under a different spelling.
@Suite("Snippet variable prompt wiring guard")
struct SnippetVariablePromptWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SnippetVariablePromptWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")

    // MARK: - Guard 1: the audit call carries the template, not a resolved value

    /// `runSnippet(_:execute:values:)` is the ONE place a resolved command
    /// exists at all — the audit call inside it must still read
    /// `SnippetAuditDetail.text(for: snippet)`, the exact literal shape that
    /// reads the template.
    @Test func runSnippetAuditsTheTemplateNotTheResolvedCommand() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func runSnippet(_ snippet: Snippet, execute: Bool, values:",
            in: lines)
        else {
            Issue.record(
                "`func runSnippet(_:execute:values:)` not found — re-anchor this guard")
            return
        }
        #expect(Self.auditCallPassesTheTemplate(in: lines, range: range), """
            `runSnippet` no longer calls `SnippetAuditDetail.text(for: snippet)` — if it now \
            passes the resolved command (or a `Snippet` built from it) instead, a variable's \
            typed value would reach the audit log, which the project's rule forbids.
            """)
    }

    // MARK: - Guard 2: remembering filters on the opt-in before writing

    /// `rememberOptedInValues(for:values:)` must call `.remember(` only
    /// after a `remembersLastValue` check has already excluded the
    /// declarations that never opted in.
    @Test func rememberOptedInValuesFiltersOnRemembersLastValueBeforeWriting() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func rememberOptedInValues(for snippet: Snippet, values:",
            in: lines)
        else {
            Issue.record(
                "`func rememberOptedInValues(for:values:)` not found — re-anchor this guard")
            return
        }
        guard let rememberLine = Self.rememberCallLine(in: lines, range: range) else {
            Issue.record("""
                `rememberOptedInValues` no longer calls `.remember(` at all — a confirmed \
                value would never be persisted, silently breaking "remember last value".
                """)
            return
        }
        #expect(Self.isFilteredByRemembersLastValue(rememberLine: rememberLine, in: lines, range: range), """
            `rememberOptedInValues` calls `.remember(` without a `remembersLastValue` check \
            appearing earlier in the same function — `SnippetVariableMemoryStore` does not \
            check the opt-in itself, so every declaration's value (opted in or not) would be \
            written to a plain JSON file the user never agreed to persist.
            """)
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// The exact regression the review demonstrated: the audit call fed a
    /// `Snippet` built around the resolved command instead of the original.
    @Test func scannerFlagsAnAuditCallBuiltFromTheResolvedCommand() {
        let source = """
            struct Fake {
                func runSnippet(_ snippet: Snippet, execute: Bool, values: [String: String]) {
                    let resolvedCommand = SnippetVariableSubstitution.resolve(
                        command: snippet.command, variables: snippet.variables, values: values)
                    terminal.send(bytes) {
                        recorder?.recordAction(AuditEvent(
                            kind: .snippetExecuted,
                            detail: SnippetAuditDetail.text(for: Snippet(
                                name: snippet.name, command: resolvedCommand))))
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func runSnippet(_ snippet: Snippet, execute: Bool, values:",
            in: lines)
        else {
            Issue.record("self-test source does not anchor — fix the synthetic source above")
            return
        }
        #expect(!Self.auditCallPassesTheTemplate(in: lines, range: range))
    }

    /// The passing shape: the real call site, unmodified.
    @Test func scannerAcceptsTheAuditCallBuiltFromTheTemplate() {
        let source = """
            struct Fake {
                func runSnippet(_ snippet: Snippet, execute: Bool, values: [String: String]) {
                    terminal.send(bytes) {
                        recorder?.recordAction(
                            AuditEvent(kind: .snippetExecuted, detail: SnippetAuditDetail.text(for: snippet)))
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func runSnippet(_ snippet: Snippet, execute: Bool, values:",
            in: lines)
        else {
            Issue.record("self-test source does not anchor — fix the synthetic source above")
            return
        }
        #expect(Self.auditCallPassesTheTemplate(in: lines, range: range))
    }

    /// The exact regression a deleted opt-in filter would look like: every
    /// declaration's value remembered, none of them checked first.
    @Test func scannerFlagsARememberCallWithNoOptInFilter() {
        let source = """
            struct Fake {
                func rememberOptedInValues(for snippet: Snippet, values: [String: String]) {
                    guard let store = snippetVariableMemoryStore else { return }
                    for variable in snippet.variables {
                        guard let value = values[variable.name] else { continue }
                        try? store.remember(value, snippetID: snippet.id, name: variable.name)
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func rememberOptedInValues(for snippet: Snippet, values:",
            in: lines)!
        let rememberLine = Self.rememberCallLine(in: lines, range: range)!
        #expect(!Self.isFilteredByRemembersLastValue(rememberLine: rememberLine, in: lines, range: range))
    }

    /// The passing shape: the real call site, unmodified.
    @Test func scannerAcceptsARememberCallFilteredByRemembersLastValue() {
        let source = """
            struct Fake {
                func rememberOptedInValues(for snippet: Snippet, values: [String: String]) {
                    guard let store = snippetVariableMemoryStore else { return }
                    for variable in snippet.variables where variable.remembersLastValue {
                        guard let value = values[variable.name] else { continue }
                        try? store.remember(value, snippetID: snippet.id, name: variable.name)
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func rememberOptedInValues(for snippet: Snippet, values:",
            in: lines)!
        let rememberLine = Self.rememberCallLine(in: lines, range: range)!
        #expect(Self.isFilteredByRemembersLastValue(rememberLine: rememberLine, in: lines, range: range))
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like `PaneVisibilityWiringGuardTests`'s and
    // `HostTagsWiringGuardTests`'s scanners.

    /// The line range of a `{ … }` block anchored by the first line
    /// containing `marker` (which must itself contain the opening brace),
    /// found by counting braces until depth returns to zero. 0-based,
    /// inclusive of both the anchor line and the closing brace's line. Same
    /// approach as `PaneVisibilityWiringGuardTests.range(ofBlockStartingWith:in:)`.
    private static func range(ofBlockStartingWith marker: String, in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var depth = 0
        var sawOpenBrace = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace && depth <= 0 {
                return start...index
            }
        }
        return nil
    }

    /// Whether `SnippetAuditDetail.text(for: snippet)` — the exact literal
    /// call shape that reads the template — appears anywhere in `range`.
    private static func auditCallPassesTheTemplate(in lines: [String], range: ClosedRange<Int>) -> Bool {
        range.contains { lines[$0].contains("SnippetAuditDetail.text(for: snippet)") }
    }

    /// The line index of the first `.remember(` call inside `range`, or
    /// `nil` if there is none.
    private static func rememberCallLine(in lines: [String], range: ClosedRange<Int>) -> Int? {
        range.first { lines[$0].contains(".remember(") }
    }

    /// Whether a line mentioning `remembersLastValue` appears BEFORE
    /// `rememberLine` inside `range` — the structural stand-in for "the
    /// opt-in check guards the write", checked textually rather than by
    /// actually parsing the `for`/`guard` nesting.
    private static func isFilteredByRemembersLastValue(
        rememberLine: Int, in lines: [String], range: ClosedRange<Int>
    ) -> Bool {
        range.contains { $0 < rememberLine && lines[$0].contains("remembersLastValue") }
    }
}
