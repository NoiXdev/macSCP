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
        Snippet(name: name, command: command)
    }

    /// Takes stored snippets and maps them the way the export does, so a
    /// test still reads as "this is what the file carries" without every
    /// case spelling out the conversion.
    private func payload(_ snippets: [Snippet]) -> SnippetExportPayload {
        SnippetExportPayload(snippets: snippets.map(ExportedSnippet.init))
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

    /// Export writes variable declarations and `decode` reads them back, but
    /// `makeSnippet` used to omit `variables:` — and since `Snippet`'s
    /// initializer defaults it to `[]`, the omission compiled and the
    /// declarations vanished on the last step of the round trip. A review
    /// measured it: the export file carried the declaration, `decode`
    /// returned one, the planner returned none.
    @Test func anImportedSnippetKeepsItsVariableDeclarations() async {
        let variable = SnippetVariable(
            name: "DB", prompt: "Which database?", kind: .freeText, placement: .placeholder,
            defaultValue: "staging", remembersLastValue: true)
        let incoming = Snippet(
            name: "Dump", command: "mysqldump {{DB}}", tags: ["db"], variables: [variable])

        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([incoming]), arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.snippetsToImport.map(\.snippet.variables) == [[variable]])
    }

    /// The same carry-over on the renaming path, where a fresh `Snippet` is
    /// built for a second reason — a collision — and could just as easily
    /// drop the field again.
    @Test func aRenamedImportKeepsItsVariableDeclarations() async {
        let variable = SnippetVariable(
            name: "DB", prompt: "Which database?", kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
        let incoming = Snippet(name: "Dump", command: "mysqldump {{DB}}", variables: [variable])

        let plan = await SnippetImportPlanner.plan(
            existing: [snippet("Dump")], incoming: payload([incoming]),
            arbiter: arbiterAnswering(.rename))

        #expect(plan.renamed == ["Dump (2)"])
        #expect(plan.snippetsToImport.map(\.snippet.variables) == [[variable]])
    }

    /// The opposite carry-over, and the reason `ExportedSnippet` exists:
    /// `Snippet.skipsPlaceholderPlacementCheck` must NOT survive the trip.
    /// Asserted on all three paths a planned snippet is built on — fresh,
    /// renamed, and replacing — because each one constructs its own
    /// `Snippet` and any of them could start passing the field along.
    ///
    /// The exporting side sets the waiver here, so the test is not passing
    /// merely because nothing ever set it. What stops it is structural: the
    /// export type does not name the field, so `ExportedSnippet.init(_:)`
    /// has nothing to copy and `makeSnippet` has nothing to read.
    @Test func anImportNeverCarriesThePlacementCheckWaiver() async {
        let waived = Snippet(
            name: "Dump", command: "[ -f {{PATH}} ]", skipsPlaceholderPlacementCheck: true)
        #expect(waived.skipsPlaceholderPlacementCheck)

        let fresh = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([waived]), arbiter: arbiterThatMustNotBeAsked())
        #expect(fresh.snippetsToImport.map(\.snippet.skipsPlaceholderPlacementCheck) == [false])

        let renamed = await SnippetImportPlanner.plan(
            existing: [snippet("Dump")], incoming: payload([waived]),
            arbiter: arbiterAnswering(.rename))
        #expect(renamed.renamed == ["Dump (2)"])
        #expect(renamed.snippetsToImport.map(\.snippet.skipsPlaceholderPlacementCheck) == [false])

        // The replacing path takes an EXISTING snippet's id — and here that
        // existing snippet has the waiver on. It is not inherited either:
        // what lands in the store is built from the file's fields.
        let existingWaived = Snippet(
            name: "Dump", command: "echo old", skipsPlaceholderPlacementCheck: true)
        let replacing = await SnippetImportPlanner.plan(
            existing: [existingWaived], incoming: payload([waived]),
            arbiter: arbiterAnswering(.replace))
        #expect(replacing.replaced == ["Dump"])
        #expect(replacing.snippetsToImport.map(\.snippet.skipsPlaceholderPlacementCheck) == [false])
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

    /// `ExportedSnippet.id` is FILE-LOCAL: it names nothing outside the file
    /// it came from, so an import must never adopt it as a store id — a
    /// second import of the same file would otherwise overwrite the snippet
    /// the first one created, without the user ever being asked. The
    /// rekeying is the one `SessionImportPlanner` performs on
    /// `ExportedSession.id`, and the Replace path (pinned by
    /// `replaceKeepsTheExistingIDSoTheStoreOverwritesRatherThanDuplicates`)
    /// is the only one that reuses an id at all — an EXISTING snippet's,
    /// never the file's.
    ///
    /// Nothing else in this suite would notice: every other case builds its
    /// incoming snippets with ids nobody looks at, so an id carried straight
    /// through would leave all of them green.
    @Test func theFilesOwnIDIsNeverAdoptedAsTheImportedID() async {
        let fileID = UUID()
        let incoming = SnippetExportPayload(snippets: [
            ExportedSnippet(id: fileID, name: "Clean up", command: "docker system prune -f")
        ])

        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: incoming, arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.snippetsToImport.count == 1)
        #expect(plan.snippetsToImport[0].snippet.id != fileID)
        #expect(plan.snippetsToImport[0].snippet.command == "docker system prune -f")
    }

    /// A file written before tags or declarations reached the format carries
    /// neither key, which decodes as `nil` rather than as a failure. The
    /// default is applied HERE, at import — `Snippet`'s own `[]` for both —
    /// so a decoded payload still says what the file said.
    @Test func aFileThatNamesNeitherTagsNorDeclarationsImportsWithTheStoredDefaults() async {
        let incoming = SnippetExportPayload(snippets: [
            ExportedSnippet(id: UUID(), name: "Disk", command: "df -h")
        ])

        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: incoming, arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.snippetsToImport.count == 1)
        #expect(plan.snippetsToImport[0].snippet.tags == [])
        #expect(plan.snippetsToImport[0].snippet.variables == [])
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
        let existing = [Snippet(id: existingID, name: "Prod", command: "echo hi")]
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

    /// Import agrees with the editor about names. `SnippetEditorView`
    /// refuses to save a whitespace-only name (its Save button is disabled
    /// on the trimmed-empty check), but a hand-edited file can carry one —
    /// `Snippet`'s initializer performs no validation of its own; it just
    /// stores what it is given. Such an entry would otherwise import as a
    /// blank row in the sheet and a blank Terminal-menu entry, so the
    /// planner drops it before it can become one, and counts it so the
    /// applier's result text can say so.
    ///
    /// Two of them in one file would ALSO both key on the empty string, and
    /// the second would have raised a conflict sheet asking the user about
    /// an item with no name at all — hence the drop happens before the
    /// collision key is computed, which `arbiterThatMustNotBeAsked` pins.
    @Test func aNamelessSnippetIsDroppedRatherThanImportedOrArbitrated() async {
        let nameless = Snippet(name: "   ", command: "echo one")
        let alsoNameless = Snippet(name: "", command: "echo two")
        let real = snippet("Prod")

        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([nameless, alsoNameless, real]),
            arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.snippetsToImport.map(\.snippet.name) == ["Prod"])
        #expect(plan.namelessDiscarded == 2)
        #expect(plan.skipped.isEmpty)
        #expect(!plan.cancelled)
    }

    /// The counter-probe to the test above: a file whose every entry has a
    /// name reports zero, so the count cannot be a constant and the app's
    /// result alert (`snippetImportResultText`) stays a single line for an
    /// ordinary import.
    @Test func namelessDiscardedIsZeroWhenEveryImportedSnippetHasAName() async {
        let plan = await SnippetImportPlanner.plan(
            existing: [], incoming: payload([snippet("Prod")]),
            arbiter: arbiterThatMustNotBeAsked())

        #expect(plan.namelessDiscarded == 0)
    }

    @Test func tagsRideAlongUnchangedThroughEveryResolution() async {
        let taggedIncoming = Snippet(name: "Prod", command: "echo hi", tags: ["ops", "prod"])
        let existing = [snippet("Prod")]
        let plan = await SnippetImportPlanner.plan(
            existing: existing, incoming: payload([taggedIncoming]),
            arbiter: arbiterAnswering(.rename))

        #expect(plan.snippetsToImport[0].snippet.tags == ["ops", "prod"])
    }
}
