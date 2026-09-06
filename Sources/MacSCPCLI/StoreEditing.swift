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

    /// Refuses a name no session may carry: an empty one, or one another
    /// session already has. `excluding` is the session being renamed, which
    /// cannot collide with itself.
    ///
    /// EMPTY first, and it is not a theoretical case: `sessions add ""` and
    /// `edit web --rename ""` both wrote `name: ""` before this check existed
    /// (round-1 review, I2). A session with no name is addressable by
    /// nothing — every other command takes it as `name:/path`, and `edit`
    /// and `rm` match by it — and the conflict rule below cannot catch it,
    /// since two empty names collide with each other but the FIRST one has
    /// nothing to collide with. Trimmed, because `SessionNameRule.asSaved` is
    /// what a name means here: a name of three spaces is the empty name.
    static func requireNameIsFree(
        _ name: String, excluding: UUID? = nil, in sessions: [StoredSession]
    ) throws {
        guard !SessionNameRule.asSaved(name).isEmpty else {
            throw ValidationError("a session needs a name")
        }
        guard let clash = SessionNameRule.conflict(
            name, among: sessions, excluding: excluding, matching: .caseInsensitive)
        else { return }
        throw ValidationError("a session named \(clash.name) already exists — use `sessions edit`")
    }

    /// `"Work / Prod"` split back into `["Work", "Prod"]` — the inverse of
    /// what `SessionCatalog.Row.groupPath` joins, separator included, so what
    /// `sessions --json` prints can be pasted straight back into `--group`.
    ///
    /// The inverse is AMBIGUOUS, and knowingly so: a group whose own name
    /// contains `" / "` is read here as two levels, exactly as
    /// `SessionCatalog.groupNames`' doc comment says of splitting a rendered
    /// path apart. The catalog avoids the ambiguity by never splitting (it
    /// reads every group's own `name` instead); a command line has nothing
    /// but the string a person typed, so it splits and lives with the one
    /// case it cannot tell apart. Such a group can still be filed into from
    /// the app, and a session already in one keeps its place — only naming it
    /// with `--group` is out of reach.
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
                position: try nextPosition(under: parentID, store: store))
            try store.upsertGroup(group)
            groups.append(group)
            parentID = group.id
        }
        // Unreachable, and named rather than force-unwrapped: the loop above
        // runs at least once for every input `groupPathSegments` accepts —
        // `components(separatedBy:)` never returns an empty array, and an
        // empty segment throws there — so `parentID` is always set by the
        // time this is read. It stays as a throw because that is what a
        // future `groupPathSegments` returning nothing should produce here,
        // rather than a crash or a silent file at the top level.
        guard let parentID else {
            throw ValidationError("--group names no group at all")
        }
        return parentID
    }

    /// Where something newly filed under `parentID` sits among its siblings:
    /// last, which is what appending to a list means.
    ///
    /// SESSIONS AND GROUPS ARE COUNTED TOGETHER because they share one
    /// numbering: `SidebarOrdering.children(of:in:)` sorts a group's folders
    /// and sessions against each other by `position`, breaking a tie by
    /// putting folders first. Counting only one of the two — as the group
    /// creation below did in round 1 — hands out a number an existing sibling
    /// of the other kind already has, which is a tie, decided by a rule about
    /// something else entirely.
    ///
    /// `position` is renumbered on every reorder in the app, so a value that
    /// merely sorts after the existing siblings is all this owes it.
    static func nextPosition(under parentID: UUID?, store: SessionStore) throws -> Int {
        let sessions = try store.all().filter { $0.groupID == parentID }.count
        let groups = try store.allGroups().filter { $0.parentID == parentID }.count
        return sessions + groups
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
