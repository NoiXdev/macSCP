import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards the sidebar host-tag filter's wiring (P3a/T6) — the same "the
/// method is right and is not wired in" shape `PaneRenderConditionGuardTests`,
/// `PaneVisibilityWiringGuardTests`, and `HostTagsWiringGuardTests` already
/// exist to catch. `SidebarVisibility.compute`/`availableTags`/`resolvedTag`
/// (Task 4) are already pinned by `SidebarVisibilityTests` without ever
/// touching `SessionSidebar.swift` — a `compute` that is correct in
/// isolation but silently not called, or called and then re-checked against
/// `session.tags` a second time in the view, would leave every one of those
/// tests green. This suite is the wiring check those cannot be.
///
/// `SessionSidebar` cannot be instantiated in this project (no view-render
/// harness — the same boundary `PaneRenderConditionGuardTests` and the other
/// three precedents already document), so, like them, this is a SOURCE-TEXT
/// scan over `Sources/MacSCPAppKit/SessionSidebar.swift`, not a rendered-view
/// assertion.
///
/// Known blind spots, stated up front rather than discovered later (the same
/// honesty the four precedent guards hold themselves to):
/// - Line-based and literal. `if activeTag == nil ? true :
///   session.tags.contains(activeTag!)` written across several lines, a
///   reformat, or a rename of `visibility`/`activeTag` to something else
///   entirely would all slip past this exact pattern match. Aimed at the
///   accidental regression (someone "simplifying" a section back to a direct
///   `session.tags` check while editing nearby code), not a hostile rewrite.
/// - The `tags.contains(` scan is file-wide, not scoped to `body` — broader
///   than the precedents' single-function scope, because this file's
///   decision-reading is split across `body`, `importedSection`, and
///   `emptyStateRow`. That breadth is also the scan's only precision: it
///   cannot say WHICH function a violation sits in, only that the file
///   contains one. It also does not see a violation moved to a DIFFERENT
///   file entirely.
/// - `sidebarComputesVisibilityExactlyOnce` only proves the string `let
///   visibility = SidebarVisibility.compute(` appears once; it does not
///   verify every read below actually names THAT local rather than some
///   other `visibility` shadowing it — the same gap
///   `PaneRenderConditionGuardTests`'s own doc comment already names for its
///   `detailAssemblesVisibilityFromEffectivePaneVisibility` check.
/// - `sessionRowsPassTheFullUnfilteredSnippetListRegardlessOfTheActiveTagFilter`
///   (the `TagList` independence pin, below) only checks the literal
///   argument text `snippets: snippets,` at the one `SessionRow(...)` call
///   site that exists today. A second call site constructing a `SessionRow`
///   some other way — or a rename of the `snippets` property — would not be
///   recognized as either compliant or a violation; it would simply not be
///   seen.
@Suite("Sidebar filter wiring guard")
struct SidebarFilterWiringTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SidebarFilterWiringTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// four precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    // MARK: - Guard 1: the decision is computed exactly once

    @Test func sidebarComputesVisibilityExactlyOnce() throws {
        let lines = try Self.sourceLines()
        let assemblyLines = lines.filter {
            $0.contains("let visibility = SidebarVisibility.compute(")
        }
        #expect(assemblyLines.count == 1, """
            expected exactly one `let visibility = SidebarVisibility.compute(...)` in \
            SessionSidebar.swift, found \(assemblyLines.count) — the sidebar must ask this \
            question in ONE place, not recompute it (or a variant of it) elsewhere.
            """)
    }

    // MARK: - Guard 2: nothing re-derives the filter from raw tags

    @Test func sidebarNeverComparesSessionTagsDirectlyAgainstTheActiveFilter() throws {
        let lines = try Self.sourceLines()
        let violations = Self.tagsContainsViolations(in: lines)
        #expect(violations.isEmpty, """
            `SessionSidebar.swift` compares `.tags` directly at line(s) \
            \(violations.map { $0 + 1 }) instead of reading the decision off \
            `SidebarVisibility` — see this suite's doc comment for why P2 already paid \
            for this exact regression once (a view re-deriving a display decision it \
            should only be reading).
            """)
    }

    // MARK: - Guard 3: present-tense check — the real reads are still there

    /// Without this, a scanner that quietly stopped recognizing the
    /// `visibility.…` pattern at all would report Guard 2's all-clear for
    /// the wrong reason: zero violations because zero reads were seen, not
    /// because the real ones are correctly wired. Same shape as
    /// `PaneRenderConditionGuardTests.detailStillGatesBothHalvesOnTheAssembledVisibility`.
    @Test func bodyStillReadsSectionsAndEmptinessFromTheAssembledVisibility() throws {
        let lines = try Self.sourceLines()
        guard let body = Self.range(ofBlockStartingWith: "var body: some View {", in: lines) else {
            Issue.record("`var body: some View {` not found — re-anchor this guard")
            return
        }
        let expectedReads = [
            "sessionRows(visibility.ungrouped)",
            "ForEach(visibility.groupSections, id: \\.group.id) { section in",
            "if visibility.showsImportedSection {",
            "switch visibility.emptiness {",
        ]
        for expected in expectedReads {
            let found = body.contains { lines[$0].contains(expected) }
            #expect(found, "expected `body` to contain `\(expected)`, but it does not — re-anchor this guard")
        }
    }

    // MARK: - Guard 4: the active-tag fallback (Step 3) is actually wired

    /// The brief's fallback rule: when the active tag's last carrier is
    /// deleted or retagged away from it, `activeTag` must fall back to `nil`
    /// rather than keep pointing at a tag nothing can ever match again.
    /// `SidebarVisibilityTests.aTagNobodyCarriesAnymoreResolvesToNoFilter`
    /// (Task 4) already proves what `resolvedTag` decides; nothing there
    /// touches `SessionSidebar`, so a deleted `.onChange(of:
    /// viewModel.sessions)` call — the method right, unwired, the exact
    /// shape every guard in this phase exists to catch — would leave that
    /// test green while a stale filter silently persists on screen after its
    /// own tag disappears.
    @Test func bodyFallsBackTheActiveTagWhenSessionsChange() throws {
        let lines = try Self.sourceLines()
        guard let body = Self.range(ofBlockStartingWith: "var body: some View {", in: lines) else {
            Issue.record("`var body: some View {` not found — re-anchor this guard")
            return
        }
        guard let onChange = Self.range(
            ofBlockStartingWith: ".onChange(of: viewModel.sessions) { _, sessions in", in: lines)
        else {
            Issue.record("`.onChange(of: viewModel.sessions) { _, sessions in` not found inside body — re-anchor this guard")
            return
        }
        #expect(body.contains(onChange.lowerBound), "the sessions-change fallback must live inside `body`")
        let assignsResolvedTag = onChange.contains {
            lines[$0].trimmingCharacters(in: .whitespaces)
                == "activeTag = SidebarVisibility.resolvedTag(activeTag, in: sessions)"
        }
        #expect(assignsResolvedTag, """
            `.onChange(of: viewModel.sessions)` no longer assigns \
            `SidebarVisibility.resolvedTag(activeTag, in: sessions)` to `activeTag` — a \
            session-list change (e.g. the active tag's last carrier deleted) would leave a \
            now-unmatchable filter selected instead of falling back to "no filter".
            """)
    }

    // MARK: - Guard 5: the `TagList` independence claim

    /// Pins the claim `TagList`'s doc comment states as design intent: a
    /// host tag hides no snippet. `SessionSidebar` is the one place
    /// `activeTag` (which sessions the tag filter shows) and `snippets`
    /// (what a row's "Snippet" submenu offers) are both in scope — see
    /// `SidebarVisibility.compute`'s own doc comment for why the claim could
    /// not be pinned in Core, where `Snippet` and `activeTag` never meet.
    ///
    /// The regression this guards against: a caller "helpfully" threading
    /// `activeTag` into the `snippets` list handed to a row's trigger
    /// surface — e.g. hiding a snippet whose own tags happen to overlap the
    /// active host-tag filter. `SessionRowSnippetMenuPlanTests` already
    /// proves `SessionRowSnippetMenuPlan.build` treats `snippets` as opaque
    /// (it has no `tags` parameter at all to filter by), but that test says
    /// nothing about what THIS caller passes in — an unfiltered `snippets`
    /// property could still be swapped for a filtered one at the call site
    /// without any existing test noticing, since none of them constructs a
    /// `SessionSidebar` to observe it.
    @Test func sessionRowsPassTheFullUnfilteredSnippetListRegardlessOfTheActiveTagFilter() throws {
        let lines = try Self.sourceLines()
        guard let call = Self.range(ofCallStartingWith: "SessionRow(", in: lines) else {
            Issue.record("`SessionRow(` call not found — re-anchor this guard")
            return
        }
        let passesUnfilteredSnippets = call.contains {
            lines[$0].trimmingCharacters(in: .whitespaces) == "snippets: snippets,"
        }
        #expect(passesUnfilteredSnippets, """
            `SessionRow(...)` no longer passes `snippets: snippets` verbatim — if this now \
            reads something derived from `activeTag` or `session.tags`, a host tag would be \
            hiding snippets from a row's "Snippet" submenu, which `TagList`'s doc comment \
            says must never happen.
            """)
    }

    // MARK: - Guard 5: the new catalog keys resolve

    /// The four keys this task adds — a missing key would render as its own
    /// literal string in the UI rather than fail a build, same guard shape
    /// as `SessionRowSnippetMenuPlanTests.theSnippetSubmenuNoticesResolveFromTheCatalog`.
    @Test func theNewFilterKeysResolveFromTheCatalog() {
        for key in ["sidebar.filter.all", "sidebar.empty.noSessions", "sidebar.empty.noMatches", "sidebar.empty.clearFilter"] {
            #expect(L10n.string(key, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ", "key `\(key)` did not resolve")
        }
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    /// The exact regression Guard 2 exists to catch: a section re-derives
    /// the filter by checking `session.tags` directly instead of reading
    /// `visibility.ungrouped`.
    @Test func scannerFlagsARawTagsContainsComparison() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
                List {
                    ForEach(viewModel.sessions.filter { activeTag == nil || $0.tags.contains(activeTag!) }) { session in
                        EmptyView()
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(!Self.tagsContainsViolations(in: lines).isEmpty)
    }

    @Test func scannerAcceptsTheAssembledVisibilityReadsWithNoTagsComparison() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
                List {
                    sessionRows(visibility.ungrouped)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.tagsContainsViolations(in: lines).isEmpty)
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like the four precedent guards' scanners.

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: Self.sourceFile, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Every line containing the literal substring `tags.contains(` — the
    /// raw per-session tag check this file must never perform; every session
    /// visibility decision belongs to `SidebarVisibility.compute` instead.
    /// Comments are not stripped (same deliberate choice
    /// `PaneVisibilityOwnershipGuardTests` makes for its own scanner): the
    /// wrong shape should not be modelled anywhere in the file, prose
    /// included.
    private static func tagsContainsViolations(in lines: [String]) -> [Int] {
        lines.indices.filter { lines[$0].contains("tags.contains(") }
    }

    /// The line range of a `{ … }` block anchored by the first line
    /// containing `marker` (which must itself contain the opening brace),
    /// found by counting braces until depth returns to zero. 0-based,
    /// inclusive of both the anchor line and the closing brace's line. Same
    /// approach as `PaneRenderConditionGuardTests.range(ofBlockStartingWith:in:)`.
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

    /// Same idea, but for a multi-line function CALL's parentheses rather
    /// than a `{ }` block — same trick as `HostTagsWiringGuardTests
    /// .range(ofCallStartingWith:in:)`.
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
