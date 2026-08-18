import Foundation
import Testing
@testable import macSCPCore

/// Records which item names the decider was actually asked about, in order
/// (mirrors `DeciderCallLog` in `LoginSetImportPlannerTests.swift`,
/// duplicated per that file's established convention so this suite has no
/// cross-file dependency on it).
private actor DeciderCallLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

/// Captures the whole `ImportConflict` a decider was handed, so a test can
/// assert on its `reason` and `kindLabel` without the app being able to see
/// them (Core has no UI language; the app maps `kindLabel` to localized
/// text).
private actor CapturedConflict {
    private(set) var value: ImportConflict?
    func record(_ value: ImportConflict) { self.value = value }
}

@Suite("SnippetImportPlanner")
struct SnippetImportPlannerTests {
    private func snippet(_ name: String, _ command: String = "echo hi") -> Snippet {
        Snippet(name: name, command: command)!
    }

    private func payload(_ snippets: [Snippet]) -> SnippetExportPayload {
        SnippetExportPayload(snippets: snippets)
    }

    /// An arbiter whose decider fails the test if it is ever asked —
    /// for scenarios where nothing should collide.
    private func arbiterThatMustNotBeAsked() -> ImportConflictArbiter {
        ImportConflictArbiter { _ in
            Issue.record("decider must not be asked")
            return nil
        }
    }

    /// An arbiter that always answers the same fixed resolution, or — when
    /// `resolution` is nil — always cancels (mirroring how `nil` from the
    /// decider means "cancel the import", per `ImportConflictDecider`'s
    /// doc comment). Optionally logs every conflict's item name, and can set
    /// `applyToAll` for tests that check stickiness.
    private func arbiterAnswering(
        _ resolution: ImportConflictResolution?, applyToAll: Bool = false, log: DeciderCallLog? = nil
    ) -> ImportConflictArbiter {
        ImportConflictArbiter { conflict in
            if let log { await log.record(conflict.itemName) }
            guard let resolution else { return nil }
            return (resolution, applyToAll)
        }
    }

    @Test func aFreshNameImportsWithoutAskingAnybody() async {
        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([snippet("Clean up")]),
            arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.snippetsToImport.map(\.snippet.name) == ["Clean up"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.replaced.isEmpty)
        #expect(plan.renamed.isEmpty)
        #expect(!plan.cancelled)
        #expect(!plan.snippetsToImport[0].replacesExisting)
    }

    @Test func aNameCollidingOnlyByCaseAndWhitespaceStillCollides() async {
        let plan = await SnippetImportPlanner.plan(
            existing: [snippet("Clean up")],
            incoming: payload([snippet("  clean UP ")]),
            arbiter: arbiterAnswering(.skip))

        #expect(plan.snippetsToImport.isEmpty)
        #expect(plan.skipped == ["clean UP"])
    }

    @Test func cancellingDiscardsEverythingIncludingWhatWasAlreadyPlanned() async {
        let plan = await SnippetImportPlanner.plan(
            existing: [snippet("B")],
            incoming: payload([snippet("A"), snippet("B")]),
            arbiter: arbiterAnswering(nil))

        #expect(plan.cancelled)
        #expect(plan.snippetsToImport.isEmpty) // "A" was already planned
        #expect(plan.skipped.isEmpty)
        #expect(plan.replaced.isEmpty)
        #expect(plan.renamed.isEmpty)
    }

    /// Two incoming entries share a name that also collides with an
    /// existing snippet; both get "renamed" by the decider. The names
    /// actually handed out must differ from each other — not merely from
    /// the existing name — otherwise the second rename would silently
    /// collide with the first.
    @Test func twoRenamedSnippetsFromOneFileDoNotCollideWithEachOther() async {
        let existing = [snippet("Deploy")]
        let plan = await SnippetImportPlanner.plan(
            existing: existing,
            incoming: payload([snippet("Deploy"), snippet("deploy")]),
            arbiter: arbiterAnswering(.rename))

        #expect(plan.snippetsToImport.count == 2)
        let names = plan.snippetsToImport.map(\.snippet.name)
        // Compared under the planner's OWN collision key (trimmed,
        // case-insensitive) — a case-sensitive comparison would stay green
        // even if both renames landed on colliding names like "Deploy (2)"
        // vs "deploy (2)".
        let normalizedNames = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        #expect(normalizedNames.count == 2)
        #expect(!normalizedNames.contains("deploy"))
        #expect(plan.renamed.count == 2)
        #expect(Set(plan.renamed) == Set(names))
    }

    @Test func detectsCollisionsByTrimmedCaseInsensitiveName() async {
        let existing = [snippet("  Prod  ")]
        let log = DeciderCallLog()
        let plan = await SnippetImportPlanner.plan(
            existing: existing, incoming: payload([snippet("PROD")]),
            arbiter: arbiterAnswering(.skip, log: log))

        #expect(await log.names == ["PROD"])
        #expect(plan.skipped == ["PROD"])
    }

    @Test func aSnippetConflictReportsTheTrimmedNameAndTheStableKindLabel() async {
        let existing = [snippet("Prod")]
        let captured = CapturedConflict()
        let arbiter = ImportConflictArbiter { conflict in
            await captured.record(conflict)
            return (.skip, false)
        }
        _ = await SnippetImportPlanner.plan(
            existing: existing, incoming: payload([snippet("  Prod  ")]), arbiter: arbiter)

        #expect(await captured.value?.itemName == "Prod")
        #expect(await captured.value?.reason == .name)
        // A literal, not a reference to the constant: a typo in the
        // planner's `kindLabel` must fail this test rather than pass by
        // both sides drifting together.
        #expect(await captured.value?.kindLabel == "snippet")
    }

    @Test func replaceKeepsTheExistingIDSoTheStoreOverwritesRatherThanDuplicates() async {
        let existing = [snippet("Prod", "echo old")]
        let plan = await SnippetImportPlanner.plan(
            existing: existing, incoming: payload([snippet("Prod", "echo new")]),
            arbiter: arbiterAnswering(.replace))

        #expect(plan.snippetsToImport.count == 1)
        #expect(plan.snippetsToImport[0].snippet.id == existing[0].id)
        #expect(plan.snippetsToImport[0].snippet.command == "echo new")
        #expect(plan.snippetsToImport[0].replacesExisting)
        #expect(plan.replaced == ["Prod"])
    }

    @Test func renameGivesAUniqueNameAndAFreshID() async {
        let existing = [snippet("Prod")]
        let plan = await SnippetImportPlanner.plan(
            existing: existing, incoming: payload([snippet("Prod")]),
            arbiter: arbiterAnswering(.rename))

        #expect(plan.snippetsToImport.count == 1)
        #expect(plan.snippetsToImport[0].snippet.name != existing[0].name)
        #expect(plan.snippetsToImport[0].snippet.id != existing[0].id)
        #expect(!plan.snippetsToImport[0].replacesExisting)
        #expect(plan.renamed == [plan.snippetsToImport[0].snippet.name])
    }

    /// Names are never enforced unique in the store, so an export can
    /// legitimately contain "Prod" and "prod" — two DIFFERENT incoming
    /// snippets that both collide, under case-insensitive matching, with the
    /// SAME existing snippet. Both cannot be bound to that existing
    /// snippet's id: the second must fall back to a fresh id under a unique
    /// name instead of silently overwriting whatever the first one just
    /// wrote. This is the precedent's "replaced at most once per run"
    /// property.
    @Test func replaceNeverBindsTwoIncomingSnippetsToTheSameExistingID() async {
        let existingID = UUID()
        let existing = [Snippet(id: existingID, name: "Prod", command: "echo hi")!]
        let plan = await SnippetImportPlanner.plan(
            existing: existing,
            incoming: payload([snippet("Prod", "echo alice"), snippet("prod", "echo bob")]),
            arbiter: arbiterAnswering(.replace, applyToAll: true))

        #expect(plan.snippetsToImport.count == 2)
        let ids = plan.snippetsToImport.map(\.snippet.id)
        #expect(Set(ids).count == 2) // no two planned snippets may share an id
        #expect(ids.contains(existingID)) // the first collision still replaces the real snippet

        let commands = Set(plan.snippetsToImport.map(\.snippet.command))
        #expect(commands == ["echo alice", "echo bob"]) // neither incoming snippet is silently dropped

        let replacing = plan.snippetsToImport.filter(\.replacesExisting)
        #expect(replacing.count == 1)
        #expect(replacing[0].snippet.id == existingID)
    }

    /// The defensive fallback (nothing on record to replace) is reachable
    /// with an EMPTY store too: two identically-named snippets in the same
    /// incoming file collide with each other, not with anything existing.
    /// A `.replace` decision landing in `renamed` — not `replaced` — is
    /// deliberate, since the summary UI reads those arrays.
    @Test func replaceOfAnInFileDuplicateWithNoExistingMatchFallsBackToRename() async {
        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([snippet("A"), snippet("A")]),
            arbiter: arbiterAnswering(.replace, applyToAll: true))

        #expect(plan.snippetsToImport.map(\.snippet.name) == ["A", "A (2)"])
        #expect(plan.renamed == ["A (2)"])
        #expect(plan.replaced.isEmpty)
        #expect(plan.snippetsToImport.map(\.replacesExisting) == [false, false])
    }

    @Test func applyToAllStopsAskingAndAppliesTheSameResolution() async {
        let existing = [snippet("Prod")]
        let log = DeciderCallLog()
        let plan = await SnippetImportPlanner.plan(
            existing: existing,
            incoming: payload([snippet("Prod"), snippet("prod")]),
            arbiter: arbiterAnswering(.skip, applyToAll: true, log: log))

        #expect(plan.skipped == ["Prod", "prod"])
        #expect(plan.snippetsToImport.isEmpty)
        #expect(await log.names.count == 1) // second collision used the sticky rule, not a fresh ask
    }

    @Test func importedNameIsTrimmedOfSurroundingWhitespace() async {
        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([snippet("  Prod  ")]),
            arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.snippetsToImport[0].snippet.name == "Prod")
    }

    @Test func tagsRideAlongUnchangedThroughEveryResolution() async {
        let taggedIncoming = Snippet(name: "Prod", command: "echo hi", tags: ["ops", "prod"])!
        let existing = [snippet("Prod")]
        let plan = await SnippetImportPlanner.plan(
            existing: existing, incoming: payload([taggedIncoming]),
            arbiter: arbiterAnswering(.rename))

        #expect(plan.snippetsToImport[0].snippet.tags == ["ops", "prod"])
    }
}
