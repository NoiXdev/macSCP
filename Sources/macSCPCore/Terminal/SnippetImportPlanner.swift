import Foundation

/// A snippet resolved for import: its final `Snippet` (fresh or
/// carried-over id, possibly renamed) plus whether this replaces something
/// already in the store.
public struct PlannedSnippet: Equatable, Sendable {
    public var snippet: Snippet
    /// True when this replaces an existing snippet — the applier must save
    /// over that snippet's id rather than adding a new one.
    public var replacesExisting: Bool

    public init(snippet: Snippet, replacesExisting: Bool) {
        self.snippet = snippet
        self.replacesExisting = replacesExisting
    }
}

/// The result of planning a snippet import. Pure data — applying it
/// (writing to `SnippetStore`) is the app's job.
public struct SnippetImportPlan: Equatable, Sendable {
    public var snippetsToImport: [PlannedSnippet]
    public var skipped: [String]
    public var replaced: [String]
    public var renamed: [String]
    /// How many incoming snippets were dropped for having no name at all
    /// (see `SnippetImportPlanner.plan`). A COUNT rather than a list,
    /// because the only thing there is to say about such an entry is that
    /// it existed — it has no name to list it under.
    public var namelessDiscarded: Int
    public var cancelled: Bool

    public init(
        snippetsToImport: [PlannedSnippet] = [], skipped: [String] = [],
        replaced: [String] = [], renamed: [String] = [], namelessDiscarded: Int = 0,
        cancelled: Bool = false
    ) {
        self.snippetsToImport = snippetsToImport
        self.skipped = skipped
        self.replaced = replaced
        self.renamed = renamed
        self.namelessDiscarded = namelessDiscarded
        self.cancelled = cancelled
    }
}

/// Plans an import of snippets against the current store, resolving name
/// collisions through the shared `ImportConflictArbiter` (M19) — the same
/// arbiter `LoginSetImportPlanner` drives, so both import flows read as
/// siblings and share one conflict sheet. Pure aside from that one `await`:
/// no store or file access happens here — the app applies the returned plan.
///
/// The collision key is the trimmed, case-insensitive name — the same rule
/// `LoginSetImportPlanner` uses, even though a snippet's TAGS are
/// deliberately case-sensitive (`TagList.normalized`). A snippet's *name*
/// plays the role a login set's name plays, not the role a tag plays, and
/// the two import flows are meant to feel identical.
///
/// An incoming snippet whose name is empty after trimming is DROPPED before
/// anything else happens to it, and counted in `namelessDiscarded`. Import
/// thereby agrees with the editor, which refuses to save such a name
/// (`SnippetEditorView.isSaveDisabled`); only a hand-edited file can carry
/// one, since `Snippet`'s initializer performs no validation of its own.
/// The drop lives HERE rather than in `Snippet` or in the applier: adding
/// name validation to `Snippet` would make an existing store file holding a
/// blank name fail to decode, turning a cosmetic problem into a store the
/// sheet reports as unreadable, and the applier is too late — by then this
/// planner would already have keyed two such entries on the same empty
/// string and asked the user to resolve a conflict over an item with no
/// name.
///
/// `takenNames` is seeded from `existing` and grown with every name this run
/// commits to (imported-unchanged, replaced, or renamed), so two renamed
/// snippets from the same file cannot collide with each other. An existing
/// snippet may be REPLACED at most once per run (`replacedExistingIDs`
/// below) — a second collision against an already-claimed id falls through
/// to the same fresh-id-and-rename fallback used when there is nothing on
/// record to replace at all. Cancellation discards the whole run, including
/// whatever was already planned before the cancelling conflict.
///
/// Items are walked SEQUENTIALLY (a plain `for` loop, no `TaskGroup`/`async
/// let`), for the same reason documented on `LoginSetImportPlanner`: at most
/// one `arbiter.resolve` call is ever in flight from this planner, so the
/// concurrent-call residual `ImportConflictArbiter.resolve` documents (its
/// decider can be invoked more than once per overlapping pair of calls)
/// never applies here.
public enum SnippetImportPlanner {
    /// Stable identifier passed as `ImportConflict.kindLabel` — NOT display
    /// text (Core has no UI language). The app maps this to its localized
    /// string.
    public static let kindLabel = "snippet"

    public static func plan(
        existing: [Snippet], incoming: SnippetExportPayload, arbiter: ImportConflictArbiter
    ) async -> SnippetImportPlan {
        var takenNames = Set(existing.map { normalizedKey($0.name) })
        var snippetsToImport: [PlannedSnippet] = []
        var skipped: [String] = []
        var replaced: [String] = []
        var renamed: [String] = []
        var namelessDiscarded = 0

        // Names are never enforced unique in the store, so `existing` can
        // legitimately contain two entries that collide under
        // `normalizedKey`, and a single existing entry can also be the
        // collision target of more than one incoming snippet. Either way,
        // an existing snippet may be REPLACED at most once per run —
        // tracked here so a second collision against an already-claimed id
        // falls through to the same fresh-id-and-rename fallback used when
        // there is nothing on record to replace at all.
        var replacedExistingIDs: Set<UUID> = []

        for fileSnippet in incoming.snippets {
            let trimmedName = fileSnippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Before the collision key, so two nameless entries never meet
            // as a conflict the user is asked about (see the type doc).
            guard !trimmedName.isEmpty else {
                namelessDiscarded += 1
                continue
            }
            let key = normalizedKey(fileSnippet.name)

            guard takenNames.contains(key) else {
                takenNames.insert(key)
                snippetsToImport.append(PlannedSnippet(
                    snippet: makeSnippet(from: fileSnippet, id: UUID(), name: trimmedName),
                    replacesExisting: false))
                continue
            }

            guard let resolution = await arbiter.resolve(
                // Snippets collide on the NAME (the `key` above IS the name,
                // normalized) — `.name` is the true reason here.
                ImportConflict(itemName: trimmedName, kindLabel: kindLabel, reason: .name)
            ) else {
                // Cancellation applies nothing at all — discard whatever was
                // accumulated so far in this run, not just the remainder.
                return SnippetImportPlan(cancelled: true)
            }

            switch resolution {
            case .skip:
                skipped.append(trimmedName)

            case .replace:
                if let match = existing.first(where: {
                    normalizedKey($0.name) == key && !replacedExistingIDs.contains($0.id)
                }) {
                    replacedExistingIDs.insert(match.id)
                    snippetsToImport.append(PlannedSnippet(
                        snippet: makeSnippet(from: fileSnippet, id: match.id, name: trimmedName),
                        replacesExisting: true))
                    replaced.append(trimmedName)
                } else {
                    // Either this collision was against a name already
                    // claimed earlier in THIS run (an in-file duplicate or
                    // an earlier rename) and there is nothing on record to
                    // replace, OR every existing snippet under this name has
                    // already been claimed by a previous replace in this
                    // same run. Fall back to a fresh id under a unique name
                    // rather than replacing a snippet that does not exist,
                    // or double-binding two incoming snippets to one id.
                    let uniqueName = uniqueName(for: trimmedName, avoiding: takenNames)
                    takenNames.insert(normalizedKey(uniqueName))
                    snippetsToImport.append(PlannedSnippet(
                        snippet: makeSnippet(from: fileSnippet, id: UUID(), name: uniqueName),
                        replacesExisting: false))
                    renamed.append(uniqueName)
                }

            case .rename:
                let uniqueName = uniqueName(for: trimmedName, avoiding: takenNames)
                takenNames.insert(normalizedKey(uniqueName))
                snippetsToImport.append(PlannedSnippet(
                    snippet: makeSnippet(from: fileSnippet, id: UUID(), name: uniqueName),
                    replacesExisting: false))
                renamed.append(uniqueName)
            }
        }

        return SnippetImportPlan(
            snippetsToImport: snippetsToImport, skipped: skipped, replaced: replaced,
            renamed: renamed, namelessDiscarded: namelessDiscarded, cancelled: false)
    }

    private static func normalizedKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Appends " (2)", " (3)", … until the candidate no longer collides with
    /// `taken` (which already carries every name committed so far this run).
    private static func uniqueName(for name: String, avoiding taken: Set<String>) -> String {
        var suffix = 2
        var candidate = "\(name) (\(suffix))"
        while taken.contains(normalizedKey(candidate)) {
            suffix += 1
            candidate = "\(name) (\(suffix))"
        }
        return candidate
    }

    /// Rebuilds `fileSnippet` under a possibly-new id and name, carrying its
    /// command and tags over unchanged.
    private static func makeSnippet(from fileSnippet: Snippet, id: UUID, name: String) -> Snippet {
        Snippet(id: id, name: name, command: fileSnippet.command, tags: fileSnippet.tags)
    }
}
