import Foundation
import Testing

/// Guards two host-tags wiring facts (P3a/T5, fix round 1) that a passing
/// `ConnectionViewModelTests`/`SessionListViewModelTests` run would not
/// notice if either quietly went missing — the exact "the method is right
/// and is not wired in" shape `PaneRenderConditionGuardTests`/
/// `PaneVisibilityWiringGuardTests` already exist to catch for pane
/// visibility:
///
/// 1. The host-tag field's `text` is local `@State`, seeded once per SwiftUI
///    view IDENTITY rather than re-derived from `tags` on every keystroke
///    (`SnippetTagField`'s own `query` works the same way). Its identity is
///    pinned to the session being edited via `.id(editingSessionID)` — WITHOUT
///    that, switching from editing session A to session B in the same tab
///    would keep showing A's already-typed/seeded tag text, because SwiftUI
///    would treat it as the same view and never re-seed. No unit test can
///    observe this (it is real SwiftUI reseed timing, no rendering harness
///    exists here — see `SnippetsSheet`'s own doc comment on that boundary),
///    but the call site actually carrying `.id(editingSessionID)` can be
///    checked by a source scan, which is exactly the "exists but is not
///    wired" gap these guards close.
/// 2. `SessionListViewModel.save(tags:)` defaults to `[]`, so the ONE call
///    site in the app (`ContentView.persistFormAsSession` — the write every
///    new-session path runs, whether it was reached by "Save as session" /
///    "Save & connect" during a dial or by the form's own Save button)
///    silently drops every typed tag if the `tags: form.tags` argument is
///    ever deleted — the build stays green (the parameter has a default) and
///    every other test stays green too (they call `save` directly with an
///    explicit `tags:`).
///
///    Re-anchored in the tab-context-menu fix round: this write used to sit
///    inline in `ContentView.startSession`, spelled `let stored =
///    sessionListViewModel.save(`. Moving it into its own function so it
///    could run without a connection attempt changed the spelling to a
///    `return`, and this guard failed CLOSED on the missing anchor — which
///    is what it is supposed to do, and why the anchor is a `guard`/
///    `Issue.record` rather than a silently empty scan.
///
/// Both are SOURCE-TEXT scans, not behavioral tests, and share the known
/// blind spots the two precedents above already document: line-based and
/// literal, defeated by a reformat or a rename, aimed at an accidental
/// regression rather than a hostile rewrite.
@Suite("Host tags wiring guard")
struct HostTagsWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/HostTagsWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// two precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let formFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ConnectionFormView.swift")
    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")

    // MARK: - Guard 1: the tag field's identity is pinned to the edited session

    @Test func tagFieldRowPinsIdentityToTheEditedSession() throws {
        let source = try String(contentsOf: Self.formFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let row = Self.range(ofBlockStartingWith: "FormRow(label: tagsLabel) {", in: lines) else {
            Issue.record("`FormRow(label: tagsLabel) {` not found — re-anchor this guard")
            return
        }
        let hasField = row.contains { lines[$0].contains("SnippetTagField(") }
        #expect(hasField, """
            the tag `FormRow` no longer builds a `SnippetTagField(...)` — re-anchor \
            this guard against whatever replaced it.
            """)
        let hasIdentityPin = row.contains { lines[$0].contains(".id(editingSessionID)") }
        #expect(hasIdentityPin, """
            the tag field is missing `.id(editingSessionID)` — without it, switching \
            which session is being edited would keep showing the PREVIOUS session's \
            already-typed tag text, because SwiftUI would treat the field as the same \
            view instance and never reseed its local `@State`.
            """)
    }

    // MARK: - Guard 2: the new-session save call actually forwards the form's tags

    private static let saveCallAnchor = "return sessionListViewModel.save("

    @Test func theNewSessionSaveForwardsFormTagsToSave() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let call = Self.range(ofCallStartingWith: Self.saveCallAnchor, in: lines) else {
            Issue.record("`\(Self.saveCallAnchor)` not found — re-anchor this guard")
            return
        }
        let forwardsTags = call.contains { lines[$0].trimmingCharacters(in: .whitespaces) == "tags: form.tags)" }
        #expect(forwardsTags, """
            `sessionListViewModel.save(...)` in `persistFormAsSession` no longer passes \
            `tags: form.tags` — `tags:` defaults to `[]`, so this compiles and every \
            OTHER test (which all call `save` with an explicit `tags:` of their own) \
            stays green while every tag typed into a NEW connection's form is silently \
            dropped on save.
            """)
    }

    /// Fail-closed companion: the anchor names ONE write, and this suite's
    /// claim is that it is the app's only one. A second
    /// `sessionListViewModel.save(` appearing in this file would mean a
    /// second new-session write path exists that this guard never looks at
    /// — which is exactly what splitting the save out of the dial was
    /// supposed to avoid.
    @Test func theAppHasExactlyOneNewSessionWrite() throws {
        let source = try String(contentsOf: Self.contentViewFile, encoding: .utf8)
        let count = source.components(separatedBy: "sessionListViewModel.save(").count - 1
        #expect(count == 1, """
            expected exactly 1 `sessionListViewModel.save(` in ContentView.swift, \
            found \(count) — a second new-session write path would be unguarded here.
            """)
    }

    // MARK: - Helpers

    /// Brace-counting block scan — same trick as `PaneRenderConditionGuardTests
    /// .range(ofBlockStartingWith:in:)`/`PaneVisibilityWiringGuardTests`'s
    /// counterpart.
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

    /// Same idea as `range(ofBlockStartingWith:in:)`, but for a multi-line
    /// FUNCTION CALL's parentheses rather than a `{ }` block — `save(...)`'s
    /// argument list has no braces of its own to count.
    private static func range(ofCallStartingWith marker: String, in lines: [String]) -> ClosedRange<Int>? {
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var depth = 0
        var sawOpenParen = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "(" { depth += 1; sawOpenParen = true }
                if character == ")" { depth -= 1 }
            }
            if sawOpenParen && depth <= 0 {
                return start...index
            }
        }
        return nil
    }
}
