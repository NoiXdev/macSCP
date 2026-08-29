import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Guards the wiring of what the sidebar shows — the host-tag filter
/// (P3a/T6; a set of tags plus a join since E2), the search that narrows
/// within it (D3), and the setting that hides the filter altogether (E1) —
/// the same "the method is right and is not wired in" shape
/// `PaneRenderConditionGuardTests`, `PaneVisibilityWiringGuardTests`, and
/// `HostTagsWiringGuardTests` already exist to catch.
/// `SidebarVisibility.compute`/`availableTags` and `SidebarTagFilter`'s own
/// answers are already pinned by `SidebarVisibilityTests` and
/// `SidebarTagFilterTests` without ever
/// touching `SessionSidebar.swift` — a `compute` that is correct in
/// isolation but silently not called, or called and then re-checked against
/// `session.tags` a second time in the view, would leave every one of those
/// tests green. This suite is the wiring check those cannot be.
///
/// `SessionSidebar` cannot be instantiated in this project (no view-render
/// harness — the same boundary `PaneRenderConditionGuardTests` and the other
/// three precedents already document), so, like them, this is a SOURCE-TEXT
/// scan over `Sources/MacSCPAppKit/SessionSidebar.swift` — and, for the
/// guards E2 added, over `Sources/MacSCPAppKit/SidebarTagFilterBar.swift`,
/// where the two drawings of the filter live — not a rendered-view
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
///   combines a `.tags` property read, the filter, and `contains(`, which
///   catches that shape (and the original one, which is a subset of it)
///   without also flagging the legitimate `tags:`/`$tagFilter` parameter
///   uses in the filter bar's own construction (see
///   `scannerIgnoresTheLegitimateChipRowConstruction` below).
///
/// Known blind spots, stated up front rather than discovered later (the same
/// honesty the four precedent guards hold themselves to):
/// - Line-based and literal. A check spelled without a literal `contains(`
///   — e.g. `.tags.firstIndex(of: tagFilter…) != nil`, or one split so no
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
/// - Guards 8 and 9 name the spellings the sidebar uses today
///   (`sheetSearchPredicate(text: searchText, isRegex: searchIsRegex)`,
///   `search: searchPredicate`, `SidebarFolderDisclosure.…`). Renaming a
///   local fails them loudly rather than silently, which is the intended
///   direction; neither can tell a call reached through a wrapper from one
///   that never happens.
/// - Guard 9's `collapsedGroups` scans are line-based like the rest: a write
///   spelled through an alias, or one moved into another file, is not seen.
///   The one-assignment count beside them is what fails when the binding is
///   restructured at all.
/// - `theTagFilterNeverRoutesThroughPersistenceOrSettingsStore` (Guard 5)
///   reads the declaration line and greps for `SettingsStore`/`@AppStorage`
///   co-occurring with `tagFilter` on the same line. A persistence path
///   that never spells either word on a line mentioning `tagFilter` (e.g.
///   an intermediate variable renamed before being handed to a store) would
///   not be recognized. What the SETTING does is a different question, and
///   Guards 10 and 11 are where it is asked: the setting says whether the
///   filter is OFFERED, never what is selected.
/// - Guards 11 and 12 scan for a threshold written into the view as a
///   number. They derive that number from
///   `SidebarTagFilter.dialogTagThreshold` /
///   `SidebarTagFilter.joinChoiceMinimumTags` rather than spelling it, so
///   moving either constant moves the scan with it — but they see only a
///   comparison whose digits sit on the same line as a `.count`, which is
///   the accidental shape ("just inline the six"), not every possible one.
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

    /// Where the sidebar is built, and therefore the only place the setting
    /// can be handed to it.
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    /// The two drawings of the filter (E2). A separate file, and therefore a
    /// separate read: every scan above is `SessionSidebar.swift`'s, and a
    /// scan that silently covered a second file would make its own failure
    /// messages wrong about where a violation sits.
    private static let barFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SidebarTagFilterBar.swift")

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
        let violations = Self.sessionTagsAgainstTheFilterViolations(in: lines)
        #expect(violations.isEmpty, """
            `SessionSidebar.swift` compares session tags against `tagFilter` directly at \
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

    /// The brief's fallback rule: when a selected tag's last carrier is
    /// deleted or retagged away from it, that tag must be dropped from the
    /// filter rather than left pointing at something nothing can ever match
    /// again. `SidebarTagFilterTests.aTagNobodyCarriesAnymoreIsDroppedAndTheRestStays`
    /// already proves what `resolved(in:)` decides; nothing there touches
    /// `SessionSidebar`, so a deleted `.onChange(of: viewModel.sessions)`
    /// call — the method right, unwired, the exact shape every guard in this
    /// phase exists to catch — would leave that test green while a stale
    /// filter silently persists on screen after its own tag disappears.
    @Test func bodyFallsBackTheTagFilterWhenSessionsChange() throws {
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
        let assignsResolvedFilter = onChange.contains {
            lines[$0].trimmingCharacters(in: .whitespaces)
                == "tagFilter = tagFilter.resolved(in: sessions)"
        }
        #expect(assignsResolvedFilter, """
            `.onChange(of: viewModel.sessions)` no longer assigns \
            `tagFilter.resolved(in: sessions)` to `tagFilter` — a session-list change (e.g. \
            a selected tag's last carrier deleted) would leave a now-unmatchable tag \
            selected instead of being dropped from the filter.
            """)
    }

    // MARK: - Guard 5: the filter stays a view-local, never persisted

    /// The brief is explicit that the filter is a VIEW, not a setting: "Der
    /// Filter ist eine Sicht, keine Einstellung" — deliberately not
    /// persisted, never routed through `SettingsStore`. That is a brief
    /// requirement, not a rendering detail, and — unlike the tap-behavior
    /// and per-case-copy claims this task's report accepted as genuinely
    /// unobservable — it is checkable with the same source-scanning idiom
    /// the rest of this suite already uses.
    @Test func theTagFilterNeverRoutesThroughPersistenceOrSettingsStore() throws {
        let lines = try Self.sourceLines()
        let declarationLines = lines.filter { $0.contains("var tagFilter") }
        #expect(declarationLines.count == 1, """
            expected exactly one `tagFilter` declaration in SessionSidebar.swift, found \
            \(declarationLines.count) — re-anchor this guard.
            """)
        if let declaration = declarationLines.first {
            let trimmed = declaration.trimmingCharacters(in: .whitespaces)
            #expect(trimmed.hasPrefix("@State private var tagFilter: SidebarTagFilter"), """
                `tagFilter` is no longer declared as plain `@State private var tagFilter: \
                SidebarTagFilter` (found `\(trimmed)`) — a wrapper like `@AppStorage` would \
                persist the filter across relaunches, which the brief explicitly rules out.
                """)
        }
        let touchesSettingsStore = lines.contains {
            $0.contains("tagFilter") && $0.contains("SettingsStore")
        }
        #expect(!touchesSettingsStore, """
            a line mentions both `tagFilter` and `SettingsStore` — WHAT is selected must \
            never be routed through the settings layer; it resets to "no filter" on every \
            relaunch. The setting says only whether the filter is offered at all (E1), \
            which reaches this view as the plain `showsTagFilterBar` fact.
            """)
        let touchesAppStorage = lines.contains {
            $0.contains("tagFilter") && $0.contains("AppStorage")
        }
        #expect(!touchesAppStorage, """
            a line mentions both `tagFilter` and `AppStorage` — that would persist the \
            filter selection, which the brief explicitly rules out ("a view, not a setting").
            """)
    }

    // MARK: - Guard 6: the `TagList` independence claim

    /// Pins the claim `TagList`'s doc comment states as design intent: a
    /// host tag hides no snippet. `SessionSidebar` is the one place
    /// `tagFilter` (which sessions the tag filter shows) and `snippets`
    /// (what a row's "Snippet" submenu offers) are both in scope — see
    /// `SidebarVisibility.compute`'s own doc comment for why the claim could
    /// not be pinned in Core, where `Snippet` and the tag filter never meet.
    ///
    /// The regression this guards against: a caller "helpfully" threading
    /// the tag filter into the `snippets` list handed to a row's trigger
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
            reads something derived from `tagFilter` or `session.tags`, a host tag would be \
            hiding snippets from a row's "Snippet" submenu, which `TagList`'s doc comment \
            says must never happen.
            """)
    }

    // MARK: - Guard 7: the new catalog keys resolve

    /// Every key the filter surfaces draw, the row's and the dialog's alike
    /// — a missing key would render as its own literal string in the UI
    /// rather than fail a build, same guard shape as
    /// `SessionRowSnippetMenuPlanTests.theSnippetSubmenuNoticesResolveFromTheCatalog`.
    @Test func theNewFilterKeysResolveFromTheCatalog() {
        for key in [
            "sidebar.filter.all", "sidebar.empty.noSessions", "sidebar.empty.noMatches",
            "sidebar.empty.clearFilter", "sidebar.filter.button",
            "sidebar.filter.button.selected %lld", "sidebar.filter.join.all",
            "sidebar.filter.join.any", "sidebar.filter.join.help",
            "settings.general.tagFilter", "settings.general.tagFilter.footer",
        ] {
            #expect(L10n.string(key, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ", "key `\(key)` did not resolve")
        }
    }

    // MARK: - Guard 8: the search reaches the same one decision

    /// The sidebar search (D3) is a second criterion inside
    /// `SidebarVisibility.compute`, not a second filtering path.
    /// `SidebarVisibilityTests` proves what the criterion decides without
    /// ever touching this file; a sidebar that compiled a predicate and then
    /// filtered its own rows with it — or never handed it over at all —
    /// would leave every one of those tests green.
    @Test func theSearchIsCompiledOnceAndHandedToTheOneDecision() throws {
        let lines = try Self.sourceLines()
        guard let compileStart = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains("sheetSearchPredicate(")
        }), let compileCall = Self.range(ofCallStartingAt: compileStart, in: lines) else {
            Issue.record("""
                `SessionSidebar.swift` no longer compiles its search through \
                `sheetSearchPredicate(...)` — that helper is where an INVALID regular \
                expression becomes a matches-everything predicate plus an error text, which \
                is what keeps a half-typed pattern from emptying the sidebar.
                """)
            return
        }
        for argument in ["text: searchText", "isRegex: searchIsRegex"] {
            #expect(compileCall.contains { lines[$0].contains(argument) }, """
                the sidebar compiles a search predicate that is not its own field's \
                (`\(argument)` is not among the arguments) — re-anchor this guard, or the \
                field on screen and the query being filtered with have come apart.
                """)
        }
        // Anchored on the CALL, not the first line naming it: this file's
        // own doc comments spell `SidebarVisibility.compute(tagFilter:)` in
        // prose, parentheses included, above the call itself.
        guard let start = Self.computeCallSites(in: lines).first,
            let call = Self.range(ofCallStartingAt: start, in: lines)
        else {
            Issue.record("`SidebarVisibility.compute(` call not found — re-anchor this guard")
            return
        }
        let handsOverTheSearch = call.contains {
            lines[$0].contains("search: searchPredicate")
        }
        #expect(handsOverTheSearch, """
            `SidebarVisibility.compute(...)` is no longer handed `search: searchPredicate` — \
            a search the one decision never receives is a second filtering path or no \
            filtering at all.
            """)
    }

    /// The design reuses `SheetSearchField` as it stands, regex toggle and
    /// error display included — a second search field would be a second
    /// build of the same thing, and the error display is the half that keeps
    /// an invalid pattern honest on screen.
    @Test func theSidebarDrawsTheSharedSearchFieldRatherThanOneOfItsOwn() throws {
        let lines = try Self.sourceLines()
        #expect(lines.contains { $0.contains("SheetSearchField(") }, """
            `SessionSidebar.swift` no longer draws `SheetSearchField` — the sidebar must \
            reuse the sheets' field rather than grow a second one.
            """)
        #expect(lines.contains { $0.contains("errorText: searchError") }, """
            the sidebar's search field no longer shows `searchError` — an invalid regular \
            expression would then filter nothing and say nothing.
            """)
    }

    // MARK: - Guard 9: the remembered collapse state is not written while searching

    /// The condition the maintainer's ruling rests on (D3): the search
    /// OVERLAYS the collapse state, it does not overwrite it.
    /// `SidebarFolderDisclosureTests` proves the decision; this is the check
    /// that the view asks it instead of keeping its own `insert`/`remove`
    /// beside it — the exact shape that would write during a search while
    /// that suite stayed green.
    ///
    /// The negative half (no direct mutation) does not stand alone: the
    /// count and the two named calls above it fail loudly the moment the
    /// binding is rewritten or renamed, so a scan that stopped recognizing
    /// anything cannot report an all-clear.
    @Test func theCollapseStateIsWrittenOnlyThroughTheTestedDecision() throws {
        let lines = try Self.sourceLines()
        for call in ["SidebarFolderDisclosure.isOpen(", "SidebarFolderDisclosure.collapsed("] {
            #expect(lines.contains { $0.contains(call) }, """
                `SessionSidebar.swift` no longer calls `\(call)...)` — the folder's open state \
                and what the triangle writes are both decisions with tests; a binding that \
                decides either one itself has none.
                """)
        }
        let writes = lines.filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("collapsedGroups = ")
        }
        #expect(writes.count == 1, """
            expected exactly one assignment to `collapsedGroups` in SessionSidebar.swift, found \
            \(writes.count) — the remembered collapse state has one writer, and it is the one \
            that can refuse to write while a search is on.
            """)
        let mutatesDirectly = lines.filter {
            $0.contains("collapsedGroups.insert(") || $0.contains("collapsedGroups.remove(")
        }
        #expect(mutatesDirectly.isEmpty, """
            `SessionSidebar.swift` mutates `collapsedGroups` directly — that write cannot be \
            withheld during a search, which is what would leave the user's folders permanently \
            unfolded after they typed.
            """)
    }

    // MARK: - Guard 10: the setting hides the bar, and switching it off clears

    /// E1, both halves. The setting hides the FILTER — so the bar is gated on
    /// it — and switching it off CLEARS what was selected, because a sidebar
    /// that goes on filtering with its control gone looks exactly like a
    /// sidebar that lost entries. `SettingsStoreTests` proves the setting
    /// persists and `SidebarTagFilterTests` proves what `cleared()` returns;
    /// neither notices a view that reads the setting and never acts on it.
    @Test func theFilterBarIsGatedOnTheSettingAndSwitchingItOffClearsTheFilter() throws {
        let lines = try Self.sourceLines()
        let gate = lines.contains {
            $0.trimmingCharacters(in: .whitespaces)
                == "if showsTagFilterBar, !availableTags.isEmpty {"
        }
        #expect(gate, """
            `SessionSidebar.swift` no longer gates the filter bar on \
            `showsTagFilterBar` beside the has-any-tags check — either the setting stopped \
            hiding the bar, or the bar started drawing over a store with no tags in it.
            """)
        guard let onChange = Self.range(
            ofBlockStartingWith: ".onChange(of: showsTagFilterBar) { _, isShown in", in: lines)
        else {
            Issue.record("""
                `.onChange(of: showsTagFilterBar)` not found — switching the filter off would \
                leave its selection filtering invisibly, which is the one thing E1 rules out.
                """)
            return
        }
        let clears = onChange.contains {
            lines[$0].trimmingCharacters(in: .whitespaces)
                == "if !isShown { tagFilter = tagFilter.cleared() }"
        }
        #expect(clears, """
            `.onChange(of: showsTagFilterBar)` no longer clears `tagFilter` when the setting \
            goes off — a filter whose control is gone would go on narrowing the list with \
            nothing on screen to explain it.
            """)
    }

    /// The empty state's one button clears BOTH narrowings — the file's own
    /// comment says so, and this is what holds it to it. A button that
    /// cleared only the search would leave the list just as empty, which
    /// reads as the button doing nothing.
    @Test func theEmptyStateButtonClearsTheTagFilterAndTheSearchTogether() throws {
        let lines = try Self.sourceLines()
        guard let row = Self.range(
            ofBlockStartingWith: "private func emptyStateRow(", in: lines)
        else {
            Issue.record("`emptyStateRow(` not found — re-anchor this guard")
            return
        }
        for assignment in ["tagFilter = tagFilter.cleared()", "searchText = \"\""] {
            #expect(row.contains { lines[$0].trimmingCharacters(in: .whitespaces) == assignment }, """
                `emptyStateRow` no longer contains `\(assignment)` — its one button has to \
                clear both narrowings, or it leaves the list as empty as it found it.
                """)
        }
    }

    /// The other half of E1, one file over: the sidebar reacts to
    /// `showsTagFilterBar`, and this is what says the value it reacts to is
    /// the user's setting rather than a constant. `SettingsStoreTests` would
    /// stay green for a `showsTagFilterBar: true` at the call site — the
    /// setting would persist perfectly and reach nothing.
    @Test func theSidebarIsHandedTheSettingItselfRatherThanAConstant() throws {
        let lines = try String(contentsOf: Self.detailFile, encoding: .utf8)
            .components(separatedBy: "\n")
        let handsOverTheSetting = lines.contains {
            $0.trimmingCharacters(in: .whitespaces)
                == "showsTagFilterBar: settingsStore.sidebarTagFilterEnabled"
        }
        #expect(handsOverTheSetting, """
            `ContentView+Detail.swift` no longer hands the sidebar \
            `showsTagFilterBar: settingsStore.sidebarTagFilterEnabled` — the setting would \
            then be stored, shown in Settings, and read by nothing.
            """)
    }

    // MARK: - Guard 11: which drawing applies is Core's answer, not the view's

    /// The threshold is a number the design says no test can place
    /// correctly, which is exactly why it must sit in ONE place. A view that
    /// compared the tag count against a literal instead would still behave
    /// correctly today and would silently disagree with Core the day the
    /// constant moves.
    ///
    /// The negative scan does not stand alone: the call it accompanies is
    /// asserted present first, so a scan that stopped recognizing anything
    /// cannot report an all-clear.
    @Test func theBarAsksCoreWhichDrawingAppliesRatherThanCountingItself() throws {
        let barLines = try Self.barSourceLines()
        #expect(barLines.contains { $0.contains("SidebarTagFilter.presentation(availableTagCount:") }, """
            `SidebarTagFilterBar.swift` no longer asks \
            `SidebarTagFilter.presentation(availableTagCount:)` which drawing applies — the \
            threshold would then live in a SwiftUI body, where moving it is not a decision \
            anyone can see.
            """)
        for drawing in ["case .bar:", "case .dialog:"] {
            #expect(barLines.contains { $0.trimmingCharacters(in: .whitespaces) == drawing }, """
                `SidebarTagFilterBar.swift` no longer renders `\(drawing)` — one of the two \
                drawings the threshold chooses between is gone.
                """)
        }
        let violations = Self.linesComparingACountAgainst(
            SidebarTagFilter.dialogTagThreshold, in: barLines)
            + Self.linesComparingACountAgainst(
                SidebarTagFilter.dialogTagThreshold, in: try Self.sourceLines())
        #expect(violations.isEmpty, """
            a filter view compares a count against \(SidebarTagFilter.dialogTagThreshold) \
            itself — the threshold is `SidebarTagFilter.dialogTagThreshold`'s to state, and \
            a second copy of it drifts the day the first one moves.
            """)
    }

    // MARK: - Guard 12: the join appears only where it means something

    /// Both surfaces that offer the join gate on the same Core answer, and
    /// neither counts to two itself. With fewer than two tags selected the
    /// two positions pick out the same sessions, so a visible switch would
    /// change nothing when flipped — the case this project's "show only what
    /// is possible" rule exists for.
    @Test func bothFilterSurfacesGateTheJoinOnTheOneDecision() throws {
        let barLines = try Self.barSourceLines()
        let gates = barLines.filter { $0.contains("filter.showsJoinChoice") }
        #expect(gates.count == 2, """
            expected `SidebarTagFilterBar.swift` to gate the join on \
            `filter.showsJoinChoice` in BOTH the row and the dialog, found \
            \(gates.count) such gate(s) — the two surfaces would then disagree about when \
            the choice is offered.
            """)
        let violations = Self.linesComparingACountAgainst(
            SidebarTagFilter.joinChoiceMinimumTags, in: barLines)
        #expect(violations.isEmpty, """
            `SidebarTagFilterBar.swift` compares a count against \
            \(SidebarTagFilter.joinChoiceMinimumTags) itself — when the join becomes a \
            question is `SidebarTagFilter.showsJoinChoice`'s answer, and a view repeating it \
            is a second copy of the same rule.
            """)
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
                    importedHostsCount: importedHosts.count, tagFilter: tagFilter,
                    search: searchPredicate)
                List {
                    ForEach(viewModel.sessions.filter { tagFilter.isEmpty || $0.tags.contains(tagFilter) }) { session in
                        EmptyView()
                    }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(!Self.sessionTagsAgainstTheFilterViolations(in: lines).isEmpty)
    }

    /// The reviewer's exact mutation (fix round 1): a re-derivation with a
    /// `)` sitting between `tags` and `.contains(`, which the original
    /// literal-substring scanner missed entirely.
    @Test func scannerFlagsTheReviewersSetTagsContainsMutation() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, tagFilter: tagFilter,
                    search: searchPredicate)
                ForEach(visibility.children(of: nil)) { item in
                    Section {
                        ForEach(sessionsOf(item).filter { s in
                            tagFilter.isEmpty || Set(s.tags).contains(tagFilter)
                        }) { s in
                            EmptyView()
                        }
                    } header: { EmptyView() }
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(!Self.sessionTagsAgainstTheFilterViolations(in: lines).isEmpty)
    }

    @Test func scannerAcceptsTheAssembledVisibilityReadsWithNoTagsComparison() {
        let source = """
            var body: some View {
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, tagFilter: tagFilter,
                    search: searchPredicate)
                List {
                    rows(under: nil, visibility: visibility)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.sessionTagsAgainstTheFilterViolations(in: lines).isEmpty)
    }

    /// The scanner's own honesty check: the filter bar's real construction
    /// (`tags: availableTags, filter: $tagFilter`) uses the PARAMETER LABEL
    /// `tags:`, never the property access `.tags`, and must not be mistaken
    /// for a violation just because both words "tags" and "tagFilter" appear
    /// on the line.
    @Test func scannerIgnoresTheLegitimateChipRowConstruction() {
        let line = "                SidebarTagFilterBar(tags: availableTags, filter: $tagFilter)"
        #expect(Self.sessionTagsAgainstTheFilterViolations(in: [line]).isEmpty)
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
                    importedHostsCount: importedHosts.count, tagFilter: tagFilter,
                    search: searchPredicate)
                let second = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: 0, tagFilter: .none, search: nil)
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
                    importedHostsCount: importedHosts.count, tagFilter: tagFilter,
                    search: searchPredicate)
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
    /// The regression Guard 11 exists to catch: the threshold inlined into
    /// the view, where it goes on agreeing with Core until somebody moves
    /// the constant.
    @Test func scannerFlagsAThresholdCountedInTheView() {
        let source = """
            var body: some View {
                if tags.count >= 6 {
                    HostTagFilterDialogButton(tags: tags, filter: $filter)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(!Self.linesComparingACountAgainst(6, in: lines).isEmpty)
    }

    /// And the compliant shape it must not flag: the count is handed to the
    /// type that owns the threshold, never compared here.
    @Test func scannerAcceptsACountHandedToTheDecision() {
        let source = """
            var body: some View {
                switch SidebarTagFilter.presentation(availableTagCount: tags.count) {
                case .bar: HostTagFilterRow(tags: tags, filter: $filter)
                case .dialog: HostTagFilterDialogButton(tags: tags, filter: $filter)
                }
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.linesComparingACountAgainst(6, in: lines).isEmpty)
        #expect(Self.linesComparingACountAgainst(2, in: lines).isEmpty)
    }

    @Test func scannerIgnoresComputeMentionedInAComment() {
        let source = """
            var body: some View {
                // See `SidebarVisibility.compute`'s own doc comment for the rules.
                let visibility = SidebarVisibility.compute(
                    sessions: viewModel.sessions, groups: viewModel.groups,
                    importedHostsCount: importedHosts.count, tagFilter: tagFilter,
                    search: searchPredicate)
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

    private static func barSourceLines() throws -> [String] {
        try String(contentsOf: Self.barFile, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Every non-comment line that puts a `.count` and the digits of
    /// `threshold` together — the shape of a view that decided to compare
    /// against the number itself instead of asking the type that owns it.
    ///
    /// The number is DERIVED from the constant rather than spelled here, so
    /// moving the constant moves this scan with it; a literal would be a
    /// second copy of exactly the thing the scan exists to forbid.
    private static func linesComparingACountAgainst(
        _ threshold: Int, in lines: [String]
    ) -> [Int] {
        let digits = String(threshold)
        return lines.indices.filter { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            return trimmed.contains(".count") && trimmed.contains(digits)
        }
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
    /// `tags:` parameter label in `SidebarTagFilterBar(tags: ..., filter:
    /// $tagFilter)` does not match), `tagFilter`, and `contains(` — the
    /// structural signature of "compare some session's tags against the
    /// filter directly" regardless of exact spelling
    /// (`session.tags.contains(tagFilter)`, `Set(s.tags).contains(…)`,
    /// …). Comments are not stripped (same deliberate choice
    /// `PaneVisibilityOwnershipGuardTests` makes for its own scanner): the
    /// wrong shape should not be modelled anywhere in the file, prose
    /// included. Requiring all three markers on one line is what keeps this
    /// from flagging `SessionSidebar.swift`'s own explanatory comments,
    /// which mention `session.tags` and `tagFilter` separately but never
    /// alongside `contains(`.
    private static func sessionTagsAgainstTheFilterViolations(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let line = lines[index]
            return line.contains(".tags") && line.contains("tagFilter") && line.contains("contains(")
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
        return range(ofCallStartingAt: start, in: lines)
    }

    /// The same parenthesis walk from a line a caller has already chosen —
    /// for the calls whose own name also appears in prose above them, where
    /// "the first line containing the marker" is a doc comment.
    private static func range(ofCallStartingAt start: Int, in lines: [String]) -> ClosedRange<Int>? {
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
