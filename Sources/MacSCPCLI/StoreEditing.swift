import ArgumentParser
import Foundation
import macSCPCore

/// Where the store-WRITING session verbs (`sessions add`, `sessions edit`,
/// `sessions rm`) find their files, and the rules they share about names,
/// group paths and deletion order.
///
/// It is the only file under `Sources/MacSCPCLI` that writes either store,
/// and `CLISessionsStoreEditingGuardTests` holds it to that by reading the
/// call sites out of the sources rather than from a list — a stray `upsert`
/// in a listing path is red there rather than quietly allowed.
///
/// **No secret passes through here.** These verbs write host names, ports,
/// user names, bucket names and tags; a password, a key passphrase and an S3
/// secret key are none of those, and there is no flag, no prompt and no
/// keychain call in this file that could carry one. The same guard scans it
/// for exactly that.
enum StoreEditing {
    /// The same store `sessions list` opens, and by the same route:
    /// `SessionStore.defaultDirectory`, which `MACSCP_STORAGE_DIRECTORY`
    /// redirects for the tests that drive the built binary.
    static func sessionStore() -> SessionStore {
        SessionStore(directory: SessionStore.defaultDirectory)
    }

    /// `tunnels.json` sits beside `sessions-v2.json` in that same directory
    /// (`TunnelStore.fileURL`), so both stores take the one location.
    static func tunnelStore() -> TunnelStore {
        TunnelStore(directory: SessionStore.defaultDirectory)
    }

    /// Which stored session a typed name means.
    ///
    /// `SessionNameRule.conflict(_:among:excluding:matching:)` with
    /// `.caseInsensitive` — the command line's own matching, chosen
    /// explicitly the way that rule requires. "Which session does this name
    /// collide with" and "which session does this name address" are the same
    /// question asked from two sides, and answering them with two spellings
    /// is how `sessions add prod` and `sessions edit Prod` end up disagreeing
    /// about whether `Prod` exists.
    static func session(named name: String, in sessions: [StoredSession]) -> StoredSession? {
        SessionNameRule.conflict(name, among: sessions, matching: .caseInsensitive)
    }

    /// The session `name` addresses, or a usage error naming what was typed.
    static func requireSession(named name: String) throws -> StoredSession {
        guard let session = session(named: name, in: try sessionStore().all()) else {
            throw ValidationError("no session named \(name)")
        }
        return session
    }

    /// Refuses a name another session already carries. `excluding` is the
    /// session being renamed, which cannot collide with itself.
    static func requireNameIsFree(
        _ name: String, excluding: UUID? = nil, in sessions: [StoredSession]
    ) throws {
        guard let clash = SessionNameRule.conflict(
            name, among: sessions, excluding: excluding, matching: .caseInsensitive)
        else { return }
        throw ValidationError("a session named \(clash.name) already exists — use `sessions edit`")
    }

    /// `"Work / Prod"` split back into `["Work", "Prod"]` — the inverse of
    /// what `SessionCatalog.Row.groupPath` joins, separator included, so what
    /// `sessions --json` prints can be pasted straight back into `--group`.
    ///
    /// Pure, so `validate()` can refuse a malformed path before `run()`
    /// creates anything: half a group tree written and then an error is a
    /// worse answer than exit 64.
    static func groupPathSegments(_ path: String) throws -> [String] {
        let segments = path
            .components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !segments.contains(where: \.isEmpty) else {
            throw ValidationError(#"--group has an empty segment; write the path as "A / B""#)
        }
        return segments
    }

    /// The id of the group at `path`, creating the groups along it that are
    /// missing. An existing group is matched case-insensitively among its own
    /// siblings, so `--group "work"` files into `Work` rather than making a
    /// second folder beside it.
    static func ensureGroup(atPath path: String, in store: SessionStore) throws -> UUID {
        var groups = try store.allGroups()
        var parentID: UUID?
        for name in try groupPathSegments(path) {
            if let existing = groups.first(where: {
                $0.parentID == parentID && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                parentID = existing.id
                continue
            }
            let group = StoredGroup(
                name: name, parentID: parentID,
                position: groups.filter { $0.parentID == parentID }.count)
            try store.upsertGroup(group)
            groups.append(group)
            parentID = group.id
        }
        guard let parentID else {
            throw ValidationError("--group names no group at all")
        }
        return parentID
    }

    /// Where a newly added session sits among its siblings: last, which is
    /// what appending to a list means. `position` is renumbered on every
    /// reorder in the app, so a value that merely sorts after the existing
    /// siblings is all this owes it.
    static func nextPosition(inGroup groupID: UUID?, store: SessionStore) throws -> Int {
        let siblings = try store.all().filter { $0.groupID == groupID }.count
        let folders = try store.allGroups().filter { $0.parentID == groupID }.count
        return siblings + folders
    }

    /// Writes a session, new or changed.
    static func save(_ session: StoredSession) throws {
        try sessionStore().upsert(session)
    }

    /// How many port forwardings the session carries — the number `rm`'s
    /// question names, so a person deleting a session knows what else goes
    /// with it.
    static func forwardingCount(for session: StoredSession) -> Int {
        tunnelStore().profiles(for: session.id).count
    }

    /// Deletes a session and everything that belongs to it.
    ///
    /// The PROFILES GO FIRST, and the order is the point: a session removed
    /// while its forwarding profiles remain leaves rows addressing a session
    /// id nothing resolves any more — invisible in the app's sheet, still in
    /// `tunnels.json`, and re-attached to whatever session a future id
    /// collision hands them. The app reaches these same two calls through its
    /// registered `TunnelManager.deletionObserver`, which additionally stops
    /// the running tunnels; the command line has no runners of its own to
    /// stop.
    ///
    /// The keychain entry is NOT touched — this tool never opens the
    /// keychain, in either direction — and `rm --verbose` says so out loud
    /// rather than leaving it to be discovered.
    static func deleteSession(_ session: StoredSession) throws {
        try tunnelStore().deleteAll(for: session.id)
        try sessionStore().delete(id: session.id)
    }
}
