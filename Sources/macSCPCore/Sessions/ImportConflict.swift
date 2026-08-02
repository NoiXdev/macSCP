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
    public func resolve(_ conflict: ImportConflict) async -> ImportConflictResolution? {
        if isCancelled { return nil }
        if let rule { return rule }
        guard let decision = await decider(conflict) else {
            isCancelled = true
            return nil
        }
        if decision.applyToAll { rule = decision.resolution }
        return decision.resolution
    }
}
