import Foundation

/// A login set resolved for import: its final `LoginSet` (fresh or
/// carried-over id, possibly renamed) plus whatever secret material rides
/// along, gated by the payload's `includesSecrets`/`includesKeyFiles` flags.
public struct PlannedLoginSet: Equatable, Sendable {
    public var set: LoginSet
    public var secret: String?
    public var embeddedKey: EmbeddedKey?
    /// True when this replaces an existing set — the applier must also
    /// overwrite that set's Keychain secret.
    public var replacesExisting: Bool

    public init(set: LoginSet, secret: String?, embeddedKey: EmbeddedKey?, replacesExisting: Bool) {
        self.set = set
        self.secret = secret
        self.embeddedKey = embeddedKey
        self.replacesExisting = replacesExisting
    }
}

/// The result of planning a login-set import. Pure data — applying it
/// (writing to the store and the Keychain) is the app's job.
public struct LoginSetImportPlan: Equatable, Sendable {
    public var setsToImport: [PlannedLoginSet]
    public var skipped: [String]
    public var replaced: [String]
    public var renamed: [String]
    public var cancelled: Bool

    public init(
        setsToImport: [PlannedLoginSet] = [], skipped: [String] = [],
        replaced: [String] = [], renamed: [String] = [], cancelled: Bool = false
    ) {
        self.setsToImport = setsToImport
        self.skipped = skipped
        self.replaced = replaced
        self.renamed = renamed
        self.cancelled = cancelled
    }
}

/// Plans an import of login sets against the current store, resolving name
/// collisions through the shared `ImportConflictArbiter` (M19) — the same
/// arbiter the session importer's conflict UI drives, so both flows read as
/// siblings. Pure aside from that one `await`: no store, Keychain or file
/// access happens here — the app applies the returned plan.
///
/// Items are walked SEQUENTIALLY (a plain `for` loop, no `TaskGroup`/`async
/// let`), so at most one `arbiter.resolve` call is ever in flight from this
/// planner. `ImportConflictArbiter.resolve` documents a residual: under
/// genuinely CONCURRENT calls its decider can be invoked more than once
/// before a rule exists (actor isolation does not span the `await
/// decider(...)` suspension). Walking sequentially means this planner never
/// creates that overlap, so the residual never applies here.
public enum LoginSetImportPlanner {
    /// Stable identifier passed as `ImportConflict.kindLabel` — NOT display
    /// text (Core has no UI language). The app maps this to its localized
    /// string.
    public static let kindLabel = "loginSet"

    public static func plan(
        existing: [LoginSet], incoming: LoginSetExportPayload, arbiter: ImportConflictArbiter
    ) async -> LoginSetImportPlan {
        // Collision key: trimmed, case-insensitive name. Seeded with the
        // existing store's names and grown with every name this run commits
        // to (imported-unchanged, replaced, or renamed) — otherwise two
        // renamed sets from the same file could collide with each other.
        var takenNames = Set(existing.map { normalizedKey($0.name) })
        var setsToImport: [PlannedLoginSet] = []
        var skipped: [String] = []
        var replaced: [String] = []
        var renamed: [String] = []

        // Names are never enforced unique in the store, so `existing` can
        // legitimately contain two entries that collide under
        // `normalizedKey` (e.g. "Prod" and "prod"), and a single existing
        // entry can also be the collision target of more than one incoming
        // set (e.g. incoming "Prod" and "prod" both matching the store's one
        // "Prod"). Either way, an existing set may be REPLACED at most
        // once per run — tracked here so a second collision against an
        // already-claimed id falls through to the same fresh-id-and-rename
        // fallback used when there is nothing on record to replace at all.
        var replacedExistingIDs: Set<UUID> = []

        for fileSet in incoming.sets {
            let trimmedName = fileSet.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(fileSet.name)
            let secret = incoming.includesSecrets ? fileSet.secret : nil
            let embeddedKey = incoming.includesKeyFiles ? fileSet.embeddedKey : nil

            guard takenNames.contains(key) else {
                takenNames.insert(key)
                setsToImport.append(PlannedLoginSet(
                    set: makeSet(from: fileSet, id: UUID(), name: trimmedName),
                    secret: secret, embeddedKey: embeddedKey, replacesExisting: false))
                continue
            }

            guard let resolution = await arbiter.resolve(
                // Login sets collide on the NAME (the `key` above IS the
                // name, normalized) — `.name` is the true reason here, not
                // the `ImportConflict` default (M23/P3 T3).
                ImportConflict(itemName: trimmedName, kindLabel: kindLabel, reason: .name)
            ) else {
                // Cancellation applies nothing at all — discard whatever was
                // accumulated so far in this run, not just the remainder.
                return LoginSetImportPlan(cancelled: true)
            }

            switch resolution {
            case .skip:
                skipped.append(trimmedName)

            case .replace:
                if let match = existing.first(where: {
                    normalizedKey($0.name) == key && !replacedExistingIDs.contains($0.id)
                }) {
                    replacedExistingIDs.insert(match.id)
                    setsToImport.append(PlannedLoginSet(
                        set: makeSet(from: fileSet, id: match.id, name: trimmedName),
                        secret: secret, embeddedKey: embeddedKey, replacesExisting: true))
                    replaced.append(trimmedName)
                } else {
                    // Either the collision was against a name already
                    // claimed earlier in THIS run (e.g. an in-file duplicate
                    // or an earlier rename) and there is nothing on record
                    // to replace, OR every existing set under this name has
                    // already been claimed by a previous replace in this
                    // same run. Fall back to a fresh id under a unique name
                    // rather than replacing a set that does not exist, or
                    // double-binding two incoming sets to the same id.
                    let uniqueName = uniqueName(for: trimmedName, avoiding: takenNames)
                    takenNames.insert(normalizedKey(uniqueName))
                    setsToImport.append(PlannedLoginSet(
                        set: makeSet(from: fileSet, id: UUID(), name: uniqueName),
                        secret: secret, embeddedKey: embeddedKey, replacesExisting: false))
                    renamed.append(uniqueName)
                }

            case .rename:
                let uniqueName = uniqueName(for: trimmedName, avoiding: takenNames)
                takenNames.insert(normalizedKey(uniqueName))
                setsToImport.append(PlannedLoginSet(
                    set: makeSet(from: fileSet, id: UUID(), name: uniqueName),
                    secret: secret, embeddedKey: embeddedKey, replacesExisting: false))
                renamed.append(uniqueName)
            }
        }

        return LoginSetImportPlan(
            setsToImport: setsToImport, skipped: skipped, replaced: replaced,
            renamed: renamed, cancelled: false)
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

    private static func makeSet(from fileSet: ExportedLoginSet, id: UUID, name: String) -> LoginSet {
        LoginSet(
            id: id, name: name, username: fileSet.username,
            authKind: fileSet.authKind, keyPath: fileSet.keyPath,
            kind: fileSet.kind, accessKeyID: fileSet.accessKeyID)
    }
}
