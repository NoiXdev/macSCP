import Foundation
import Testing

/// Guards call-site facts in `ContentView.swift` and `SnippetsSheet.swift`
/// (Snippet-Variablen, Task 6, fix rounds 1 and 2) that no functional test
/// can reach — the same "exists but is not wired right" shape
/// `SnippetAuditWiringGuardTests`, `PaneVisibilityWiringGuardTests`, and
/// `PaneRenderConditionGuardTests` already exist to catch elsewhere in this
/// project:
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
/// 3. `triggerSnippet` must still intercept on `snippet.variables.isEmpty`,
///    and must still seed the prompt from `SnippetVariableMemoryStore`
///    rather than from `defaultValue` alone; `SnippetsSheet.save()` must
///    still pass `variables: variables`. A later review mutated each of
///    these three lines and watched the full suite stay green: without the
///    interception the prompt never opens and every value resolves to `''`,
///    without the store lookup "remember last value" is an opt-in that does
///    nothing, and with `variables: []` the declarations are never persisted
///    at all. `Snippet`'s initializer defaults `variables`, so the last one
///    does not even need a wrong value — a dropped argument compiles.
///
/// 4. `triggerSnippet` must still run `SnippetVariableSubstitution
///    .firstDeclarationProblem` and RETURN on a problem BEFORE it opens the
///    prompt. This is the load-bearing one: the check is the last thing
///    between an imported snippet — whose declarations never passed the
///    editor — and a value being placed into a command macSCP cannot
///    survey. Deleting those lines left the whole suite green, because
///    every functional test of the check calls Core directly and no test
///    reaches this call site. The guard requires the order too, not just
///    the presence of a call: a check whose refusal does not `return`
///    before `pendingSnippetVariablePrompt` is set is a check that runs and
///    is then ignored.
///
/// All are SOURCE-TEXT scans, not behavioral tests — this project has no
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
    private static let sheetSourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SnippetsSheet.swift")

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

    // MARK: - Guard 3: the prompt is opened at all
    //
    // Each of the three below was verified by mutation in a whole-branch
    // review: the named line was removed or changed, the full suite was run,
    // and it stayed green. They are the "silently does nothing" shape --
    // the feature disappears and no behavioural test notices, because no
    // behavioural test can instantiate a SwiftUI view here.

    /// `triggerSnippet` must intercept a snippet that declares variables.
    /// Deleting the `guard snippet.variables.isEmpty else { … }` block makes
    /// the prompt never appear: every declared value resolves to `''` and
    /// the command runs anyway, which is worse than not running it.
    @Test func triggerSnippetInterceptsASnippetThatDeclaresVariables() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)
        else {
            Issue.record("`func triggerSnippet(_:execute:)` not found — re-anchor this guard")
            return
        }
        #expect(Self.interceptsDeclaredVariables(in: lines, range: range), """
            `triggerSnippet` no longer guards on `snippet.variables.isEmpty` — the prompt \
            would never open, every declared value would resolve to an empty string, and the \
            command would be sent anyway.
            """)
        #expect(Self.prefillsFromTheMemoryStore(in: lines, range: range), """
            `triggerSnippet` no longer reads `SnippetVariableMemoryStore.value(snippetID:…)` \
            when seeding the prompt — "remember last value" would be an opt-in that silently \
            does nothing, since the prompt would always open on `defaultValue`.
            """)
    }

    /// `SnippetsSheet.save()` must hand the edited declarations to
    /// `Snippet`. Passing `variables: []` there persists none of them, and
    /// `Snippet`'s initializer defaults that argument, so even DROPPING the
    /// argument compiles.
    @Test func theSnippetEditorSavesTheEditedDeclarations() throws {
        let source = try String(contentsOf: Self.sheetSourceFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(ofBlockStartingWith: "private func save() {", in: lines)
        else {
            Issue.record("`private func save()` not found in SnippetsSheet — re-anchor this guard")
            return
        }
        #expect(Self.savesTheEditedVariables(in: lines, range: range), """
            `save()` no longer passes `variables: variables` to `Snippet` — the declarations \
            the user just authored would never be persisted, and nothing else in the suite \
            would notice.
            """)
    }

    // MARK: - Scanner reacts (self-tests for guard 3)

    @Test func scannerFlagsATriggerSnippetWithNoInterception() {
        let source = """
            struct Fake {
                func triggerSnippet(_ snippet: Snippet, execute: Bool) {
                    guard activeTab.session?.terminal != nil else { return }
                    runSnippet(snippet, execute: execute, values: [:])
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)!
        #expect(!Self.interceptsDeclaredVariables(in: lines, range: range))
        #expect(!Self.prefillsFromTheMemoryStore(in: lines, range: range))
    }

    @Test func scannerFlagsAPromptSeededFromTheDefaultValueOnly() {
        let source = """
            struct Fake {
                func triggerSnippet(_ snippet: Snippet, execute: Bool) {
                    guard snippet.variables.isEmpty else {
                        var initialValues: [String: String] = [:]
                        for variable in snippet.variables {
                            initialValues[variable.name] = variable.defaultValue
                        }
                        pendingSnippetVariablePrompt = PendingSnippetVariablePrompt(
                            snippet: snippet, execute: execute, initialValues: initialValues)
                        return
                    }
                    runSnippet(snippet, execute: execute, values: [:])
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)!
        #expect(Self.interceptsDeclaredVariables(in: lines, range: range))
        #expect(!Self.prefillsFromTheMemoryStore(in: lines, range: range))
    }

    @Test func scannerFlagsASaveThatPersistsNoDeclarations() {
        let source = """
            struct Fake {
                private func save() {
                    let snippet = Snippet(
                        id: existing?.id ?? UUID(), name: trimmedName, command: command,
                        tags: tags, variables: [])
                    try store.save(snippet)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "private func save() {", in: lines)!
        #expect(!Self.savesTheEditedVariables(in: lines, range: range))
    }

    @Test func scannerAcceptsASaveThatPersistsTheEditedDeclarations() {
        let source = """
            struct Fake {
                private func save() {
                    let snippet = Snippet(
                        id: existing?.id ?? UUID(), name: trimmedName, command: command,
                        tags: tags, variables: variables)
                    try store.save(snippet)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(ofBlockStartingWith: "private func save() {", in: lines)!
        #expect(Self.savesTheEditedVariables(in: lines, range: range))
    }

    // MARK: - Guard 4: the run path refuses before it prompts

    /// The refusal must sit between "this snippet declares variables" and
    /// "ask the user for them", and it must leave the method. Order is the
    /// whole content of the guard: a `firstDeclarationProblem` call whose
    /// result is computed after the prompt is already scheduled protects
    /// nothing.
    @Test func triggerSnippetRefusesAnUnsurveyableCommandBeforeOpeningThePrompt() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)
        else {
            Issue.record("`func triggerSnippet(_:execute:)` not found — re-anchor this guard")
            return
        }
        #expect(Self.refusesBeforePrompting(in: lines, range: range), """
            `triggerSnippet` no longer refuses an unsurveyable command before opening the \
            variable prompt. An imported snippet's declarations never passed the editor, so \
            this call is the last thing before a typed value is placed into a command whose \
            quoting macSCP could not survey.
            """)
    }

    /// The exact regression: the five lines deleted. A reviewer verified
    /// that this left the whole suite green, which is why the guard exists
    /// at all.
    @Test func scannerFlagsATriggerThatPromptsWithoutChecking() {
        let source = """
            struct Fake {
                func triggerSnippet(_ snippet: Snippet, execute: Bool) {
                    guard snippet.variables.isEmpty else {
                        let store = snippetVariableMemoryStore
                        var initialValues: [String: String] = [:]
                        for variable in snippet.variables {
                            initialValues[variable.name] =
                                store?.value(snippetID: snippet.id, name: variable.name)
                        }
                        pendingSnippetVariablePrompt = PendingSnippetVariablePrompt(
                            snippet: snippet, execute: execute, initialValues: initialValues)
                        return
                    }
                    runSnippet(snippet, execute: execute, values: [:])
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)!
        #expect(!Self.refusesBeforePrompting(in: lines, range: range))
    }

    /// The subtler regression: the check is still there, its message is
    /// still raised, but nothing leaves the method — so the prompt opens
    /// anyway and the refusal is decoration.
    @Test func scannerFlagsARefusalThatDoesNotLeaveTheMethod() {
        let source = """
            struct Fake {
                func triggerSnippet(_ snippet: Snippet, execute: Bool) {
                    guard snippet.variables.isEmpty else {
                        if let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                            command: snippet.command, variables: snippet.variables) {
                            pendingSnippetVariableRefusal = snippetVariableProblemText(for: problem)
                        }
                        pendingSnippetVariablePrompt = PendingSnippetVariablePrompt(
                            snippet: snippet, execute: execute, initialValues: [:])
                        return
                    }
                    runSnippet(snippet, execute: execute, values: [:])
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)!
        #expect(!Self.refusesBeforePrompting(in: lines, range: range))
    }

    /// And the order regression: the check runs, but only after the prompt
    /// has already been scheduled.
    @Test func scannerFlagsACheckThatRunsAfterThePromptIsScheduled() {
        let source = """
            struct Fake {
                func triggerSnippet(_ snippet: Snippet, execute: Bool) {
                    guard snippet.variables.isEmpty else {
                        pendingSnippetVariablePrompt = PendingSnippetVariablePrompt(
                            snippet: snippet, execute: execute, initialValues: [:])
                        if let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                            command: snippet.command, variables: snippet.variables) {
                            pendingSnippetVariableRefusal = snippetVariableProblemText(for: problem)
                            return
                        }
                        return
                    }
                    runSnippet(snippet, execute: execute, values: [:])
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)!
        #expect(!Self.refusesBeforePrompting(in: lines, range: range))
    }

    /// The passing shape: the real call site, unmodified.
    @Test func scannerAcceptsARefusalThatPrecedesThePrompt() {
        let source = """
            struct Fake {
                func triggerSnippet(_ snippet: Snippet, execute: Bool) {
                    guard snippet.variables.isEmpty else {
                        if let problem = SnippetVariableSubstitution.firstDeclarationProblem(
                            command: snippet.command, variables: snippet.variables) {
                            pendingSnippetVariableRefusal = snippetVariableProblemText(for: problem)
                            return
                        }
                        pendingSnippetVariablePrompt = PendingSnippetVariablePrompt(
                            snippet: snippet, execute: execute, initialValues: [:])
                        return
                    }
                    runSnippet(snippet, execute: execute, values: [:])
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        let range = Self.range(
            ofBlockStartingWith: "func triggerSnippet(_ snippet: Snippet, execute: Bool) {",
            in: lines)!
        #expect(Self.refusesBeforePrompting(in: lines, range: range))
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

    /// Whether the "this snippet declares variables, so do not send
    /// anything" guard is still in `range`.
    private static func interceptsDeclaredVariables(
        in lines: [String], range: ClosedRange<Int>
    ) -> Bool {
        range.contains { lines[$0].contains("guard snippet.variables.isEmpty else {") }
    }

    /// Whether the prompt's initial values are still looked up in
    /// `SnippetVariableMemoryStore` rather than taken from `defaultValue`
    /// alone. Anchored on the `value(snippetID:` call, the only thing that
    /// distinguishes the two.
    private static func prefillsFromTheMemoryStore(
        in lines: [String], range: ClosedRange<Int>
    ) -> Bool {
        range.contains { lines[$0].contains("value(snippetID:") }
    }

    /// Whether `save()` still hands the edited declarations to `Snippet`.
    private static func savesTheEditedVariables(
        in lines: [String], range: ClosedRange<Int>
    ) -> Bool {
        range.contains { lines[$0].contains("variables: variables") }
    }
    /// Whether the run path still refuses before it asks: the declaration
    /// check is called, its refusal is raised, the method returns on it, and
    /// all of that happens above the line that schedules the prompt.
    /// Fail-closed — a missing anchor is `false`, never a shrug, because the
    /// thing being guarded against is precisely a call site that vanished.
    private static func refusesBeforePrompting(
        in lines: [String], range: ClosedRange<Int>
    ) -> Bool {
        guard let checkLine = range.first(where: {
            lines[$0].contains("SnippetVariableSubstitution.firstDeclarationProblem(")
        }),
        let refusalLine = range.first(where: {
            lines[$0].contains("pendingSnippetVariableRefusal =")
        }),
        let promptLine = range.first(where: {
            lines[$0].contains("pendingSnippetVariablePrompt =")
        })
        else { return false }
        guard checkLine < refusalLine, refusalLine < promptLine else { return false }
        return (refusalLine + 1..<promptLine).contains {
            lines[$0].trimmingCharacters(in: .whitespaces) == "return"
        }
    }
}
