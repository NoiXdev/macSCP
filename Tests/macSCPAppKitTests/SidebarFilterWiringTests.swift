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
/// Fix round 1 (coordinator review) tightened two of these guards after the
/// reviewer found each one's detection narrower than its own failure
/// message claimed:
/// - Guard 1 originally matched only the literal spelling `let visibility =
///   SidebarVisibility.compute(`. A second, differently-named call — `let
///   second = SidebarVisibility.compute(...)` — left it green while the
///   message claimed the question "must be asked in ONE place." It now
///   counts every non-comment call to `SidebarVisibility.compute(`,
///   regardless of what it is assigned to.
/// - Guard 2 originally matched only the literal substring `tags.contains(`.
///   `Set(s.tags).contains(activeTag!)` — a re-derivation with a `)` between
///   `tags` and `.contains(` — left it green. It now flags any line that
///   combines a `.tags` property read, `activeTag`, and `contains(`, which
///   catches that shape (and the original one, which is a subset of it)
///   without also flagging the legitimate `tags:`/`$activeTag` parameter
///   uses in `HostTagFilterRow`'s own construction (see
///   `scannerIgnoresTheLegitimateChipRowConstruction` below).
///
/// Known blind spots, stated up front rather than discovered later (the same
/// honesty the four precedent guards hold themselves to):
/// - Line-based and literal. A check spelled without a literal `contains(`
///   — e.g. `.tags.firstIndex(of: activeTag) != nil`, or one split so no
///   single line carries all three markers — would still slip past Guard 2.
///   A rename of `SidebarVisibility` itself, or a call reached through a
///   local alias, would slip past Guard 1. Aimed at the accidental
///   regression (someone "simplifying" a section back to a direct check, or
///   adding a second computation while extending nearby code), not a
///   hostile rewrite.
/// - Both scans are file-wide, not scoped to `body` — broader than the
///   precedents' single-function scope, because this file's decision-
///   reading is split across `body`, `importedSection`, and
///   `emptyStateRow`. That breadth is also the scans' only precision: they
///   cannot say WHICH function a violation sits in, only that the file
///   contains one. Neither sees a violation moved to a DIFFERENT file
///   entirely.
/// - Guard 1 counts CALLS, not assignments — it does not verify every
///   downstream read in `body` actually names the local that call's result
///   was bound to, rather than some other `visibility` shadowing it. Guard
///   3 narrows that gap for the specific reads it lists, the same way
///   `PaneRenderConditionGuardTests.detailAssemblesVisibilityFromEffectivePaneVisibility`
///   narrows the equivalent gap for `detail`.
/// - `sessionRowsPassTheFullUnfilteredSnippetListRegardlessOfTheActiveTagFilter`
///   (the `TagList` independence pin) only checks the literal argument text
///   `snippets: snippets,` at the one `SessionRow(...)` call site that
///   exists today. A second call site constructing a `SessionRow` some
///   other way — or a rename of the `snippets` property — would not be
///   recognized as either compliant or a violation; it would simply not be
///   seen.
/// - `activeTagNeverRoutesThroughPersistenceOrSettingsStore` (Guard 5) reads
///   the declaration line and greps for `SettingsStore`/`@AppStorage`
///   co-occurring with `activeTag` on the same line. A persistence path
///   that never spells either word on a line mentioning `activeTag` (e.g.
///   an intermediate variable renamed before being handed to a store) would
///   not be recognized.
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
        let callSites = Self.computeCallSites(in: lines)
        #expect(callSites.count == 1, """
            expected exactly one call to `SidebarVisibility.compute(...)` in \
            SessionSidebar.swift, found \(callSites.count) at line(s) \
            \(callSites.map { $0 + 1 }) — the sidebar must ask this question in ONE \
            place; a second call under any variable name recomputes it instead of \
            reading the one true answer.
            """)
    }

    // MARK: - Guard 2: nothing re-derives the filter from raw tags

    @Test func sidebarNeverComparesSessionTagsDirectlyAgainstTheActiveFilter() throws {
        let lines = try Self.sourceLines()
        let violations = Self.sessionTagsAgainstActiveTagViolations(in: lines)
        #expect(violations.isEmpty, """
            `SessionSidebar.swift` compares session tags against `activeTag` directly at \
            line(s) \(violations.map { $0 + 1 }) instead of reading the decision off \
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
            "rows(under: nil, visibility: visibility)",
            "if visibility.showsImportedSection {",
            "switch visibility.emptiness {",
        ]
        for expected in expectedReads {
            let found = body.contains { lines[$0].contains(expected) }
            #expect(found, "expected `body` to contain `\(expected)`, but it does not — re-anchor this guard")
        }
        // The tree itself is drawn one level at a time outside `body`, so
        // the read that decides WHICH rows appear is checked file-wide —
        // `SidebarTreeWiringTests` is where that read's own guard lives.
        let asksTheDecisionForItsRows = lines.contains {
            $0.contains("visibility.children(of: parentID)")
        }
        #expect(asksTheDecisionForItsRows, """
            expected `SessionSidebar.swift` to draw `visibility.children(of: parentID)` — \
            re-anchor this guard.
            """)
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

    // MARK: - Guard 5: `activeTag` stays a view-local, never persisted

    /// The brief is explicit that the filter is a VIEW, not a setting: "Der
    /// Filter ist eine Sicht, keine Einstellung" — deliberately not
    /// persisted, never routed through `SettingsStore`. That is a brief
    /// requirement, not a rendering detail, and — unlike the tap-behavior
    /// and per-case-copy claims this task's report accepted as genuinely
    /// unobservable — it is checkable with the same source-scanning idiom
    /// the rest of this suite already uses.
    @Test func activeTagNeverRoutesThroughPersistenceOrSettingsStore() throws {
        let lines = try Self.sourceLines()
        let declarationLines = lines.filter { $0.contains("var activeTag") }
        #expect(declarationLines.count == 1, """
            expected exactly one `activeTag` declaration in SessionSidebar.swift, found \
            \(declarationLines.count) — re-anchor this guard.
            """)
        if let declaration = declarationLines.first {
            let trimmed = declaration.trimmingCharacters(in: .whitespaces)
            #expect(trimmed.hasPrefix("@State private var activeTag: String?"), """
                `activeTag` is no longer declared as plain `@State private var activeTag: \
                String?` (found `\(trimmed)`) — a wrapper like `@AppStorage` would persist \
                the filter across relaunches, which the brief explicitly rules out.
                """)
        }
        let touchesSettingsStore = lines.contains {
            $0.contains("activeTag") && $0.contains("SettingsStore")
        }
        #expect(!touchesSettingsStore, """
            a line mentions both `activeTag` and `SettingsStore` — the filter must never be \
            routed through the settings layer; it resets to "no filter" on every relaunch.
            """)
        let touchesAppStorage = lines.contains {
            $0.contains("activeTag") && $0.contains("AppStorage")
        }
        #expect(!touchesAppStorage, """
            a line mentions both `activeTag` and `AppStorage` — that would persist the \
            filter selection, which the brief explicitly rules out ("a view, not a setting").
            """)
    }

    // MARK: - Guard 6: the `TagList` independence claim

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

    // MARK: - Guard 7: the new catalog keys resolve

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
    /// the assembled decision.
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
        #expect(!Self.sessionTagsAgainstActiveTagViolations(in: lines).isEmpty)
    }

    /// The reviewer's exact mutation (fix round 1): a re-derivation with a
    /// `)` sitting between `tags` and `.contains(`, which the original
    /// literal-substring scanner missed entirely.
    @Test func scannerFlagsTheReviewersSetTagsContainsMutation() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
                ForEach(visibility.children(of: nil)) { item in
                    Section {
                        ForEach(sessionsOf(item).filter { s in
                            activeTag == nil || Set(s.tags).contains(activeTag!)
                        }) { s in
                            EmptyView()
                        }
                    } header: { EmptyView() }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(!Self.sessionTagsAgainstActiveTagViolations(in: lines).isEmpty)
    }

    @Test func scannerAcceptsTheAssembledVisibilityReadsWithNoTagsComparison() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
                List {
                    rows(under: nil, visibility: visibility)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.sessionTagsAgainstActiveTagViolations(in: lines).isEmpty)
    }

    /// The scanner's own honesty check: `HostTagFilterRow`'s real
    /// construction (`tags: availableTags, selection: $activeTag`) uses the
    /// PARAMETER LABEL `tags:`, never the property access `.tags`, and must
    /// not be mistaken for a violation just because both words "tags" and
    /// "activeTag" appear on the line.
    @Test func scannerIgnoresTheLegitimateChipRowConstruction() {
        let line = "                HostTagFilterRow(tags: availableTags, selection: $activeTag)"
        #expect(Self.sessionTagsAgainstActiveTagViolations(in: [line]).isEmpty)
    }

    /// The reviewer's other exact mutation (fix round 1): a second call to
    /// `SidebarVisibility.compute(...)`, bound to a DIFFERENT name than
    /// `visibility` — the original scanner's literal `let visibility = ...`
    /// match could not see this at all.
    @Test func scannerFlagsASecondComputeCallUnderADifferentName() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
                let second = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: 0, activeTag: nil)
                List {
                    rows(under: nil, visibility: visibility)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.computeCallSites(in: lines).count == 2)
    }

    @Test func scannerAcceptsASingleComputeCall() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
                List {
                    rows(under: nil, visibility: visibility)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.computeCallSites(in: lines).count == 1)
    }

    /// A doc comment mentioning `SidebarVisibility.compute` in prose (this
    /// file has several, e.g. `` `SidebarVisibility.compute`'s own doc
    /// comment `` above) must not be counted as a call — only Guard 1's
    /// real target, a compiled statement, is.
    @Test func scannerIgnoresComputeMentionedInAComment() {
        let source = """
            var body: some View {
                // See `SidebarVisibility.compute`'s own doc comment for the rules.
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, activeTag: activeTag)
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.computeCallSites(in: lines).count == 1)
    }

    // MARK: - Scanner
    //
    // Deliberately line-based, like the four precedent guards' scanners.

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: Self.sourceFile, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Every line, EXCLUDING `//`/`///` comment lines, that starts a call to
    /// `SidebarVisibility.compute(` — regardless of what the result is
    /// assigned to, or whether it is assigned at all. Counting lines rather
    /// than parenthesis-matched call spans is sufficient here: the literal
    /// substring `SidebarVisibility.compute(` occurs exactly once per call,
    /// on the call's own start line, never on a continuation line.
    private static func computeCallSites(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            return trimmed.contains("SidebarVisibility.compute(")
        }
    }

    /// Every line combining a `.tags` PROPERTY READ (dot-prefixed, so the
    /// `tags:` parameter label in `HostTagFilterRow(tags: ..., selection:
    /// $activeTag)` does not match), `activeTag`, and `contains(` — the
    /// structural signature of "compare some session's tags against the
    /// active filter directly" regardless of exact spelling
    /// (`session.tags.contains(activeTag)`, `Set(s.tags).contains(activeTag!)`,
    /// …). Comments are not stripped (same deliberate choice
    /// `PaneVisibilityOwnershipGuardTests` makes for its own scanner): the
    /// wrong shape should not be modelled anywhere in the file, prose
    /// included. Requiring all three markers on one line is what keeps this
    /// from flagging `SessionSidebar.swift`'s own explanatory comments,
    /// which mention `session.tags` and `activeTag` separately but never
    /// alongside `contains(`.
    private static func sessionTagsAgainstActiveTagViolations(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let line = lines[index]
            return line.contains(".tags") && line.contains("activeTag") && line.contains("contains(")
        }
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
