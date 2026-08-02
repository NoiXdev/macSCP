import Foundation

/// How a naming collision during an import is resolved.
/// Mirrors the transfer queue's `ConflictResolution` (M5b) so the two
/// conflict systems read as siblings rather than as two inventions.
public enum ImportConflictResolution: Equatable, Sendable {
    case skip, replace, rename
}

/// Describes a concrete naming collision for the `ImportConflictDecider`:
/// an incoming item's name already matches something in the existing store.
public struct ImportConflict: Equatable, Sendable {
    public var itemName: String
    /// A stable identifier for what kind of item collided (e.g. "session",
    /// "login set", "group") — NOT display text. Core does not know the UI
    /// language; the app maps this to a localized string.
    public var kindLabel: String

    public init(itemName: String, kindLabel: String) {
        self.itemName = itemName
        self.kindLabel = kindLabel
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
