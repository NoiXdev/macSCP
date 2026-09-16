import Foundation
import macSCPCore

/// The question "Convert key…" asks when the failed attempt's stored session
/// takes its login from a LOGIN SET (maintainer decision 1 of 2026-09-16).
///
/// Everything the confirmation needs is captured when the import finishes,
/// for the reason `ImportKeyTarget` captures its tab: the dialog is answered
/// later, and the active tab, the set list and the usage count can all have
/// moved by then.
struct LoginSetRepointRequest: Identifiable, Equatable {
    let id = UUID()
    /// The tab whose failed attempt the conversion was for — the one
    /// `ImportKeyTarget` carried, never the tab active when the dialog is
    /// answered.
    let tab: SessionTab
    let key: ManagedKey
    /// The converted key's file, already resolved in the window's own
    /// `managedKeyStore`.
    let keyPath: String
    let set: LoginSet
    /// How many sessions reference the set, read when the request is made.
    let usageCount: Int

    /// Identity, not value: two requests are the same presentation or none.
    /// `SessionTab` is a reference type with no equality of its own, so
    /// synthesis is not available, and comparing presentations by content
    /// would call two separate conversions "the same".
    static func == (lhs: LoginSetRepointRequest, rhs: LoginSetRepointRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// Whether a finished conversion asks to update a login set, and with what.
///
/// Only an SSH private-key set qualifies: it is the one kind of set whose key
/// path a converted key can replace. A password or agent set has no key path
/// to re-point, and a set of another protocol carries no SSH login — the
/// resolver refuses to bind one to an SSH session (`kindMismatch`), so no
/// failed SSH attempt can have used it.
enum LoginSetRepointPlan {
    /// nil when the failed attempt's stored session is not bound to a set, the set no
    /// longer exists, or the set is not an SSH private-key set. The caller,
    /// `ContentView.convertedKeyImported(_:for:)`, asks this only for a stored
    /// session that HAS a set, and answers nil with the attempt-only route —
    /// the route every set-bound session took before this question existed.
    ///
    /// `usageCount` is called once, for the set the request names, and only
    /// when a request is made.
    /// The set `id` names as it stands in `sets` NOW, or nil when it is gone
    /// or no longer an SSH private-key set (Task 2 fix round 1) — the re-read
    /// `ContentView.repointLoginSet(_:)` makes at confirm time, because the
    /// dialog can stay open while another window edits or deletes the set.
    static func currentSet(id: UUID, in sets: [LoginSet]) -> LoginSet? {
        guard let set = sets.first(where: { $0.id == id }), qualifies(set) else { return nil }
        return set
    }

    /// The one kind of set a converted key can be written into.
    private static func qualifies(_ set: LoginSet) -> Bool {
        set.kind == .ssh && set.authKind == .privateKey
    }

    static func request(
        session: StoredSession?, sets: [LoginSet], usageCount: (UUID) -> Int,
        key: ManagedKey, keyPath: String, tab: SessionTab
    ) -> LoginSetRepointRequest? {
        guard let setID = session?.loginSetID, let set = currentSet(id: setID, in: sets)
        else { return nil }
        return LoginSetRepointRequest(
            tab: tab, key: key, keyPath: keyPath, set: set, usageCount: usageCount(set.id))
    }
}
