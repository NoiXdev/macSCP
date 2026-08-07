import Foundation

/// How a naming collision during an import is resolved.
/// Mirrors the transfer queue's `ConflictResolution` (M5b) so the two
/// conflict systems read as siblings rather than as two inventions.
public enum ImportConflictResolution: Equatable, Sendable {
    case skip, replace, rename
}

/// Describes a concrete collision for the `ImportConflictDecider`. Two
/// planners share this type and collide on DIFFERENT things:
/// `LoginSetImportPlanner` keys on the incoming item's NAME (M19);
/// `SessionImportPlanner` keys on the CONNECTION — the identifying fields
/// `BackendDescriptor` declares for that session's kind, the host/port/
/// username triple for `.ssh`, other fields for `.s3`/`.webdav` (M23/P3).
/// `reason` says which applies to a given conflict, so a caller (the sheet,
/// a test) never has to assume one story fits both — a single "name already
/// exists" message told the name story for both and was itself the defect
/// this type now guards against (M23/P3 T3).
public struct ImportConflict: Equatable, Sendable {
    public var itemName: String
    /// A stable identifier for what kind of item collided (e.g. "session",
    /// "login set", "group") — NOT display text. Core does not know the UI
    /// language; the app maps this to a localized string.
    public var kindLabel: String
    /// What made this a collision. See the type doc above for which planner
    /// produces which case.
    public var reason: Reason

    /// Defaults to `.name` so call sites that only exercise the arbiter's
    /// own mechanics (asking, stickiness, cancellation — none of which reads
    /// `reason`) do not have to spell one out.
    public init(itemName: String, kindLabel: String, reason: Reason = .name) {
        self.itemName = itemName
        self.kindLabel = kindLabel
        self.reason = reason
    }

    public enum Reason: Equatable, Sendable {
        /// The incoming item's name is already taken.
        case name
        /// A stored item already points at the same place. `existing`
        /// identifies it the way the sidebar does (`BackendDescriptor.
        /// displaySummary`), so the user can tell which of their connections
        /// is about to be replaced — never the incoming item's own name,
        /// which is what made the old shared message misleading.
        case sameConnection(existing: String)
    }
}

/// UI decider. Returning nil means "cancel the import" (the caller applies
/// nothing). `applyToAll == true` sets the decision as a rule for the rest
/// of the import run.
public typealias ImportConflictDecider =
    @Sendable (ImportConflict) async -> (resolution: ImportConflictResolution, applyToAll: Bool)?

/// Holds the "apply to all" rule for ONE import run, mirroring the transfer
/// queue's `queueRule` (M5b). Both import planners (sessions and login sets)
/// go through this so the two flows cannot drift apart.
public actor ImportConflictArbiter {
    private let decider: ImportConflictDecider
    private var rule: ImportConflictResolution?
    public private(set) var isCancelled = false

    public init(decider: @escaping ImportConflictDecider) {
        self.decider = decider
    }

    /// Resolves one conflict: returns the active rule if one is set, asks
    /// the decider otherwise, and remembers the answer as the rule when
    /// `applyToAll` is true.
    ///
    /// Returns nil once the user has cancelled — from that point on, every
    /// call returns nil without asking the decider again, and the caller
    /// must apply nothing for the remaining conflicts.
    ///
    /// Concurrency contract: callers MAY call `resolve` concurrently for
    /// different conflicts — e.g. an import planner resolving several items
    /// in parallel. Actor isolation does NOT span the `await decider(...)`
    /// suspension below, so two concurrent calls can both observe
    /// `rule == nil` / `isCancelled == false` before either has answered,
    /// and both will invoke `decider`. Callers must therefore NOT assume
    /// `decider` is asked at most once per overlapping pair of calls. What
    /// IS guaranteed: every call re-checks `isCancelled` and `rule`
    /// immediately after its own `decider` invocation returns, before
    /// applying its own answer — so cancellation always wins (a call whose
    /// own decider answered normally still returns nil if some other call
    /// cancelled in the meantime) and an `applyToAll` rule set by another
    /// call always wins over this call's own answer, even if this call
    /// started first and is only now resuming. "Don't ask again" is a
    /// promise about the RETURNED resolution and the terminal cancelled
    /// state, not about how many times `decider` is invoked under overlap.
    public func resolve(_ conflict: ImportConflict) async -> ImportConflictResolution? {
        if isCancelled { return nil }
        if let rule { return rule }
        guard let decision = await decider(conflict) else {
            isCancelled = true
            return nil
        }
        // Re-check: a concurrent call may have cancelled or set the rule
        // while this call's own `decider` invocation was suspended above
        // (actor isolation does not span that suspension point). Both win
        // over this call's own, now-stale answer.
        if isCancelled { return nil }
        if let rule { return rule }
        if decision.applyToAll { rule = decision.resolution }
        return decision.resolution
    }
}
