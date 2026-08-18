import Foundation
import Testing
import macSCPCore
@testable import MacSCPAppKit

/// Covers the decisions the Terminal menu and the snippets sheet make about
/// snippets BEFORE any view is involved: what a read of the store yielded,
/// which snippets a tag filter chip passes, and when the sheet counts as
/// "filtered" for its empty-state wording.
///
/// It does not cover the views themselves — no test in this repo renders
/// `SnippetsSheet` or a `CommandMenu`, so nothing here proves that a menu
/// item appears or that the sheet's error line is visible. What it does
/// prove is that the values those views are handed distinguish an empty
/// store from an unreadable one, and route the right snippets to the right
/// filter chip.
@Suite("Snippets presentation")
struct SnippetsPresentationTests {
    private func makeStore() -> (SnippetStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-snippets-app-\(UUID().uuidString)")
        return (SnippetStore(directory: dir), dir)
    }

    @Test func aMissingStoreLoadsAsAnEmptyList() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let load = SnippetsLoad(reading: store)

        #expect(load == .loaded([]))
        #expect(!load.isUnreadable)
    }

    @Test func aSavedSnippetLoads() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))
        try store.save(snippet)

        #expect(SnippetsLoad(reading: store) == .loaded([snippet]))
    }

    /// The whole point: a file that exists and cannot be decoded is NOT an
    /// empty list. One hand-edited multi-line command is enough to get there
    /// — the same file shape `aHandEditedMultiLineCommandDoesNotDecode`
    /// makes `SnippetStore.all()` throw on.
    @Test func anUndecodableStoreIsUnreadableRatherThanEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"[{"id":"\#(UUID().uuidString)","name":"x","command":"a\nb","runsImmediately":false}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("snippets.json"))

        let load = SnippetsLoad(reading: store)

        #expect(load == .unreadable)
        #expect(load.isUnreadable)
        // Still empty to list — a caller that only enumerates needs no case.
        #expect(load.snippets.isEmpty)
        #expect(load != .loaded([]))
    }

    /// The Terminal menu's remaining two snippet-related notices come from
    /// the catalog, not from a literal baked into a view — a missing key
    /// would otherwise show up as a mangled menu entry rather than a failing
    /// test (same guard shape as
    /// `KeyboardShortcutsCatalogTests.everyLabelKeyResolves`).
    ///
    /// TEMPORARY (Terminal-Snippets, Task 1 → Task 5): this used to also
    /// cover `menu.snippets.executingItem`, the marker for an executing
    /// snippet's `SnippetMenuEntry.title(for:)` — both that key and that
    /// type are gone now (see `Snippet`'s doc comment on why the
    /// insert-or-execute decision moved to the trigger; `SnippetMenuEntry`
    /// had no purpose left once every title was the bare name).
    @Test func theTerminalMenuNoticesResolveFromTheCatalog() {
        #expect(
            L10n.string("menu.snippets.unreadable", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
        #expect(L10n.string("snippets.load.error", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }

    // MARK: - SnippetTagFilter

    @Test func allMatchesEverySnippetRegardlessOfTags() throws {
        let tagged = try #require(Snippet(name: "a", command: "a", tags: ["x"]))
        let untagged = try #require(Snippet(name: "b", command: "b"))

        #expect(SnippetTagFilter.all.matches(tagged))
        #expect(SnippetTagFilter.all.matches(untagged))
    }

    @Test func tagMatchesOnlyASnippetCarryingThatExactTag() throws {
        let docker = try #require(Snippet(name: "a", command: "a", tags: ["Docker"]))
        let other = try #require(Snippet(name: "b", command: "b", tags: ["compose"]))

        #expect(SnippetTagFilter.tag("Docker").matches(docker))
        #expect(!SnippetTagFilter.tag("Docker").matches(other))
    }

    /// `Snippet.tags` keeps case exactly as typed (see that type's doc
    /// comment) — a filter chip built from one stored tag must not also
    /// match a differently-cased tag that happens to be a different snippet
    /// entirely as far as the store is concerned.
    @Test func tagComparesCaseSensitively() throws {
        let lowercase = try #require(Snippet(name: "a", command: "a", tags: ["docker"]))

        #expect(!SnippetTagFilter.tag("Docker").matches(lowercase))
    }

    @Test func untaggedMatchesOnlyASnippetWithNoTagsAtAll() throws {
        let untagged = try #require(Snippet(name: "a", command: "a"))
        let tagged = try #require(Snippet(name: "b", command: "b", tags: ["x"]))

        #expect(SnippetTagFilter.untagged.matches(untagged))
        #expect(!SnippetTagFilter.untagged.matches(tagged))
    }

    // MARK: - snippetsAreFiltered

    @Test func neitherSearchNorTagFilterActiveIsNotFiltered() {
        #expect(!snippetsAreFiltered(searchText: "", tagFilter: .all))
    }

    @Test func nonEmptySearchTextCountsAsFiltered() {
        #expect(snippetsAreFiltered(searchText: "df", tagFilter: .all))
    }

    @Test func aNonAllTagFilterCountsAsFilteredEvenWithNoSearchText() {
        #expect(snippetsAreFiltered(searchText: "", tagFilter: .tag("Docker")))
        #expect(snippetsAreFiltered(searchText: "", tagFilter: .untagged))
    }

    // MARK: - snippetsCanExport

    @Test func exportIsEnabledWhenTheStoreLoadedAndAtLeastOneRowIsVisible() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))
        #expect(snippetsCanExport(load: .loaded([snippet]), visibleSnippets: [snippet]))
    }

    @Test func exportIsDisabledWhenNoRowIsVisibleEvenIfTheStoreLoaded() {
        #expect(!snippetsCanExport(load: .loaded([]), visibleSnippets: []))
    }

    /// The requirement this task is built around: an unreadable store must
    /// never offer an export, even in a hypothetical future where
    /// `visibleSnippets` is computed some other way and is no longer
    /// incidentally empty for `.unreadable` — this pins the state, not just
    /// today's derivation of it.
    @Test func exportIsDisabledForAnUnreadableStoreEvenIfVisibleSnippetsWereNonEmpty() throws {
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))
        #expect(!snippetsCanExport(load: .unreadable, visibleSnippets: [snippet]))
    }

    // MARK: - applySnippetImportPlan (P3b/T4)

    /// A fresh (non-colliding) planned snippet is written as a new entry.
    @Test func applySnippetImportPlanAddsAFreshSnippet() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))
        let plan = SnippetImportPlan(
            snippetsToImport: [PlannedSnippet(snippet: snippet, replacesExisting: false)])

        let applied = applySnippetImportPlan(plan, to: store)

        #expect(applied == SnippetImportApplyResult(imported: 1, storeFailures: 0))
        #expect(try store.all() == [snippet])
    }

    /// The task's central requirement: a planned snippet with
    /// `replacesExisting: true` carries the ORIGINAL id
    /// (`SnippetImportPlanner` assigns it that way — see
    /// `SnippetImportPlannerTests.replaceKeepsTheExistingIDSoTheStoreOverwritesRatherThanDuplicates`),
    /// and `SnippetStore.save` writes over an existing id rather than
    /// appending (see its own doc comment and
    /// `SnippetStoreTests.savingTheSameIdTwiceReplaces`). This test proves
    /// the GLUE between those two facts: applying a replace plan must leave
    /// exactly one entry behind, with the new content — not two.
    @Test func applySnippetImportPlanReplacesRatherThanDuplicating() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = try #require(Snippet(name: "Prod", command: "echo old"))
        try store.save(existing)
        let replacement = try #require(
            Snippet(id: existing.id, name: "Prod", command: "echo new"))
        let plan = SnippetImportPlan(
            snippetsToImport: [PlannedSnippet(snippet: replacement, replacesExisting: true)],
            replaced: ["Prod"])

        let applied = applySnippetImportPlan(plan, to: store)

        #expect(applied == SnippetImportApplyResult(imported: 1, storeFailures: 0))
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all == [replacement])
    }

    /// Cancellation applies nothing: `SnippetImportPlanner.plan` returns
    /// `snippetsToImport: []` for a cancelled run (see its own doc
    /// comment), so this function — which writes exactly what
    /// `plan.snippetsToImport` holds — writes nothing for one either,
    /// leaving whatever already existed untouched.
    @Test func applySnippetImportPlanWritesNothingForACancelledPlan() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = try #require(Snippet(name: "Existing", command: "true"))
        try store.save(existing)

        let applied = applySnippetImportPlan(SnippetImportPlan(cancelled: true), to: store)

        #expect(applied == SnippetImportApplyResult(imported: 0, storeFailures: 0))
        #expect(try store.all() == [existing])
    }

    /// A write that fails is counted rather than crashing the import or
    /// silently dropping the failure.
    @Test func applySnippetImportPlanCountsAWriteFailureRatherThanCrashing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-snippets-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // `dir` is a plain file, not a directory: `SnippetStore.save`'s
        // `persist` calls `createDirectory(at: directory,...)`, which
        // throws — the same technique
        // `SessionListViewModelTests.applyImportReportsOnlyActuallyWrittenSessionsAndSkipsOrphanedPassword`
        // uses to simulate an unwritable store.
        try Data("blocked".utf8).write(to: dir)
        let store = SnippetStore(directory: dir)
        let snippet = try #require(Snippet(name: "Disk", command: "df -h"))
        let plan = SnippetImportPlan(
            snippetsToImport: [PlannedSnippet(snippet: snippet, replacesExisting: false)])

        let applied = applySnippetImportPlan(plan, to: store)

        #expect(applied == SnippetImportApplyResult(imported: 0, storeFailures: 1))
    }

    // MARK: - snippetImportErrorText (P3b/T4)

    /// An import that failed and says nothing is indistinguishable from one
    /// that silently did nothing — same guard shape as
    /// `ImportFeedbackTextTests.everyExportErrorHasText`.
    @Test func everySnippetImportErrorHasText() {
        for error in SessionExportError.allTestCases {
            #expect(!snippetImportErrorText(for: error).isEmpty, "\(error) has no message")
        }
    }

    /// `.unsupportedVersion` is the one case this mapping names precisely
    /// (reusing the shared "newer app" text) — it must read differently
    /// from the generic wrong-kind-file/corrupted bucket the other four
    /// cases share.
    @Test func unsupportedVersionReadsDifferentlyFromTheGenericBucket() {
        let versionText = snippetImportErrorText(for: .unsupportedVersion(2))
        let genericText = snippetImportErrorText(for: .notAnExportFile)
        #expect(versionText != genericText)
    }

    /// `.notAnExportFile`, `.passwordRequired`, `.wrongPasswordOrCorrupted`,
    /// and `.randomnessUnavailable` all share the one generic refusal text —
    /// deliberately, since only `.notAnExportFile` (a session or login-set
    /// file, or a corrupted one) and `.unsupportedVersion` can actually
    /// reach this format; the rest are defensive-only (see
    /// `snippetImportErrorText`'s own doc comment).
    @Test func theGenericBucketCoversEveryCaseExceptUnsupportedVersion() {
        let genericCases: [SessionExportError] = [
            .notAnExportFile, .passwordRequired, .wrongPasswordOrCorrupted, .randomnessUnavailable,
        ]
        let texts = Set(genericCases.map(snippetImportErrorText(for:)))
        #expect(texts.count == 1, "the defensive cases should all read the same")
    }

    // MARK: - snippetImportResultText (P3b/T4)

    /// The base "imported" line must vary with the count — a constant-return
    /// function would pass an emptiness check but not this.
    @Test func snippetImportResultTextVariesWithTheImportedCount() {
        let plan = SnippetImportPlan()
        let few = snippetImportResultText(
            plan: plan, applied: SnippetImportApplyResult(imported: 1, storeFailures: 0))
        let many = snippetImportResultText(
            plan: plan, applied: SnippetImportApplyResult(imported: 30, storeFailures: 0))
        #expect(few != many)
    }

    /// The replaced/renamed line is added only when the plan actually
    /// resolved a collision.
    @Test func snippetImportResultTextAddsAResolvedLineOnlyWhenNeeded() {
        let applied = SnippetImportApplyResult(imported: 1, storeFailures: 0)
        let clean = snippetImportResultText(plan: SnippetImportPlan(), applied: applied)
        let resolved = snippetImportResultText(
            plan: SnippetImportPlan(replaced: ["Prod"]), applied: applied)

        #expect(clean.components(separatedBy: "\n").count == 1)
        #expect(resolved.components(separatedBy: "\n").count == 2)
    }

    /// The store-failures line is added only when a write actually failed.
    @Test func snippetImportResultTextAddsAFailureLineOnlyWhenAWriteFailed() {
        let plan = SnippetImportPlan()
        let clean = snippetImportResultText(
            plan: plan, applied: SnippetImportApplyResult(imported: 1, storeFailures: 0))
        let withFailure = snippetImportResultText(
            plan: plan, applied: SnippetImportApplyResult(imported: 1, storeFailures: 1))

        #expect(clean.components(separatedBy: "\n").count == 1)
        #expect(withFailure.components(separatedBy: "\n").count == 2)
    }
}
