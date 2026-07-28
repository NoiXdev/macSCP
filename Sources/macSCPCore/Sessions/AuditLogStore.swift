import Foundation

/// Per-session audit log persistence (M9b). One JSON file per stored
/// session under `audit/`, rolling cap of the newest 1000 entries.
/// EVERY method is throw-free by design: a broken log must never disturb
/// a transfer or file action (spec M9b §2) — write errors are swallowed,
/// a corrupt file reads as empty and is recovered by the next append.
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
            cache[sessionID] = []
            persist([], for: sessionID)
        }
    }

    public func deleteLog(for sessionID: UUID) {
        queue.sync {
            loaded.insert(sessionID)
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
        cache[sessionID] = (try? JSONDecoder().decode([AuditEvent].self, from: data)) ?? []
    }

    /// Must only be called from a block already running on `queue`.
    private func persist(_ events: [AuditEvent], for sessionID: UUID) {
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
