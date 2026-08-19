import Foundation

/// Per-session audit log persistence (M9b). One JSON file per stored
/// session under `audit/`, rolling cap of the newest 1000 entries.
/// EVERY method is throw-free by design: a broken log must never disturb
/// a transfer or file action (spec M9b §2) — write errors are swallowed,
/// a file whose JSON structure is unreadable reads as empty and is
/// recovered by the next append. A file that parses but has individual
/// entries a newer app version wrote (an unrecognized `AuditEvent.Kind`)
/// decodes everything else and skips only those entries — and future
/// writes are held back for that session so those entries survive on disk
/// until a version that understands them reads the file again.
///
/// A class since M9b/T4 (review finding 2): `append` used to be a
/// synchronous read-decode-append-encode-write round trip on the caller's
/// thread — on the MainActor, a burst of transfer completions (or a large
/// folder transfer) could block the UI for seconds. All disk I/O now runs
/// on a private serial `DispatchQueue`; an in-memory `[UUID: [AuditEvent]]`
/// cache (lazily loaded from disk per session on first touch) is the single
/// source of truth while the store is alive, so `events(for:)` never has to
/// re-read a file that a pending `append` hasn't finished writing yet.
/// `@unchecked Sendable` because the queue is the actual synchronization
/// mechanism — `cache`/`loaded` are only ever touched from blocks submitted
/// to it (async from `append`, sync from every other method), never
/// directly from a caller's thread.
///
/// Reference semantics are intentional here (unlike the pre-M9b/T4 struct):
/// every holder (`SessionListViewModel`, every `AuditRecorder`) must share
/// ONE cache and ONE serial queue per session directory, not independent
/// copies — a `struct` would have silently defeated the cache.
public final class AuditLogStore: @unchecked Sendable {
    static let maxEntriesPerSession = 1000

    private let directory: URL
    private let queue = DispatchQueue(label: "dev.noidee.macscp.auditlog")
    /// In-memory mirror of each session's on-disk log. Only ever read/written
    /// from blocks running ON `queue`.
    private var cache: [UUID: [AuditEvent]] = [:]
    /// Sessions whose on-disk file has already been consulted this run —
    /// distinguishes "never loaded" from "loaded and genuinely empty", so a
    /// session with zero events isn't re-read from disk on every call.
    private var loaded: Set<UUID> = []
    /// Sessions where `loadIfNeeded` found at least one array entry it could
    /// not decode (typically an event `Kind` written by a newer app
    /// version). `cache[sessionID]` only holds what THIS process could
    /// decode, so persisting it would drop the undecodable entries from disk
    /// for good; `persist` checks this set and skips the write while a
    /// session is flagged. Cleared by `clear`/`deleteLog`, which intentionally
    /// replace the whole on-disk history rather than append to it.
    private var partiallyRead: Set<UUID> = []

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        SessionStore.defaultDirectory.appendingPathComponent("audit", isDirectory: true)
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    /// Appends `event` for `sessionID`, capped at `maxEntriesPerSession`.
    /// Cheap on the caller: only a closure hand-off to `queue`, no disk I/O
    /// on this thread. The cache and the on-disk file are updated together,
    /// on `queue`, so a later `events(for:)`/`clear`/`deleteLog` (which use
    /// `queue.sync`) always observes a state consistent with every `append`
    /// submitted before it — FIFO ordering on a serial queue is the flush.
    public func append(_ event: AuditEvent, for sessionID: UUID) {
        queue.async { [self] in
            loadIfNeeded(sessionID)
            var events = cache[sessionID] ?? []
            events.append(event)
            if events.count > Self.maxEntriesPerSession {
                events.removeFirst(events.count - Self.maxEntriesPerSession)
            }
            cache[sessionID] = events
            persist(events, for: sessionID)
        }
    }

    /// Rare call (sheet open, delete) — `queue.sync` naturally waits for
    /// every `append` submitted before it to finish, so the returned events
    /// are always current.
    public func events(for sessionID: UUID) -> [AuditEvent] {
        queue.sync {
            loadIfNeeded(sessionID)
            return cache[sessionID] ?? []
        }
    }

    public func clear(for sessionID: UUID) {
        queue.sync {
            loaded.insert(sessionID)
            partiallyRead.remove(sessionID)  // explicit reset: the whole file is being replaced
            cache[sessionID] = []
            persist([], for: sessionID)
        }
    }

    public func deleteLog(for sessionID: UUID) {
        queue.sync {
            loaded.insert(sessionID)
            partiallyRead.remove(sessionID)  // explicit reset: the file is going away entirely
            cache[sessionID] = []
            try? FileManager.default.removeItem(at: fileURL(for: sessionID))
        }
    }

    /// Populates `cache[sessionID]` from disk on first touch. Must only be
    /// called from a block already running on `queue`.
    private func loadIfNeeded(_ sessionID: UUID) {
        guard !loaded.contains(sessionID) else { return }
        loaded.insert(sessionID)
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else {
            cache[sessionID] = []
            return
        }
        // Decode element-by-element via `FailableEvent` rather than
        // `[AuditEvent].self` directly: a single entry this process's `Kind`
        // doesn't recognize (raw-value enum, so an unknown case throws)
        // would otherwise fail the whole array and read the entire session
        // as empty. If the top-level JSON itself is malformed (not an
        // array at all), this still fails outright and falls back to empty,
        // same as before -- there is no array to salvage entries from.
        guard let wrapped = try? JSONDecoder().decode([FailableEvent].self, from: data) else {
            cache[sessionID] = []
            return
        }
        let decoded = wrapped.compactMap(\.event)
        if decoded.count < wrapped.count {
            partiallyRead.insert(sessionID)
        }
        cache[sessionID] = decoded
    }

    /// Must only be called from a block already running on `queue`.
    private func persist(_ events: [AuditEvent], for sessionID: UUID) {
        // `events` reflects only what this process could decode. If
        // `loadIfNeeded` found undecodable entries for this session, writing
        // `events` now would permanently drop them from disk the moment
        // this session's next append fires -- even though a version that
        // understands the newer `Kind` could still read them. Skip the
        // write and leave the file untouched; the in-memory cache (and so
        // `events(for:)`) still reflects every entry this process decoded,
        // plus anything appended since.
        guard !partiallyRead.contains(sessionID) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(events).write(to: fileURL(for: sessionID), options: .atomic)
        } catch {
            // Deliberately silent (spec M9b §2): logging must never break
            // the flow it observes.
        }
    }
}

/// Decodes a single array element permissively: a genuinely malformed JSON
/// object (e.g. a missing required field) still fails outright, but an
/// unrecognized `AuditEvent.Kind` raw value -- the shape a future app
/// version's log entry takes today -- only fails this one wrapped decode
/// instead of aborting the whole array. `event` is `nil` when the
/// underlying `AuditEvent` could not be decoded.
private struct FailableEvent: Decodable {
    let event: AuditEvent?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        event = try? container.decode(AuditEvent.self)
    }
}
