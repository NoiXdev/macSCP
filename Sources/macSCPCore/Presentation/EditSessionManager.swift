import Foundation
import Observation

/// Manages "open in external editor" edit sessions for one window/session.
///
/// A single window owns one `EditSessionManager`. `beginEditing` downloads a
/// remote file into a per-session temp directory (via the transfer QUEUE, so
/// the download shows up in the bar), registers a debounced file-system watcher
/// on the local copy, and returns the local URL for the caller to open in an
/// editor. Every save the editor makes is detected by the watcher and uploaded
/// back to the remote — with the queue's conflict check bypassed, because
/// writing back is the user's explicit intent.
///
/// Lifecycle is UI-owned (no `deinit` cleanup, matching the rest of the app):
/// the caller MUST invoke `stopAll` in its teardown to cancel the watchers and
/// delete the session temp directory.
///
/// Temp layout (see the M5e plan's Global Constraints):
/// `FileManager.temporaryDirectory/macscp-edit/<sessionUUID>/<hash(remotePath)>/<fileName>`.
@Observable
@MainActor
public final class EditSessionManager {
    public struct ActiveEdit: Identifiable, Equatable {
        public let id: UUID
        public let remotePath: String
        public let localURL: URL
        public let fileName: String
    }

    public private(set) var activeEdits: [ActiveEdit] = []

    // MARK: - Dependencies / configuration

    private let sessionID: UUID
    private let queue: TransferQueueViewModel
    /// The local file system used for the temp download destination AND as the
    /// source of edit write-back uploads. Stateless, so a single instance is
    /// fine.
    private let localFS = LocalFileSystem()
    /// Debounce interval: several file events in a row coalesce into ONE upload.
    private let debounceInterval: Duration
    /// Injectable sleep hook — lets tests drive the debounce/retry timing
    /// deterministically instead of waiting on the real clock.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Root temp directory for this session's edits, created lazily.
    private let sessionDirectory: URL

    // MARK: - Watcher state

    /// Per-edit watcher: the DispatchSource layer is kept THIN — the event
    /// handler only hops to the MainActor and calls `handleFileEvent`. All the
    /// debounce/reopen logic lives in directly-testable manager methods.
    private final class Watcher {
        let editID: UUID
        let localURL: URL
        let fileName: String
        let remoteDirectory: String
        let uploadDestination: any RemoteFileSystem
        var source: (any DispatchSourceFileSystemObject)?
        var debounceTask: Task<Void, Never>?
        var reopenTask: Task<Void, Never>?

        init(
            editID: UUID, localURL: URL, fileName: String,
            remoteDirectory: String, uploadDestination: any RemoteFileSystem
        ) {
            self.editID = editID
            self.localURL = localURL
            self.fileName = fileName
            self.remoteDirectory = remoteDirectory
            self.uploadDestination = uploadDestination
        }
    }

    private var watchers: [UUID: Watcher] = [:]
    /// remotePath → active edit id, for the "already editing" dedup.
    private var editByRemotePath: [String: UUID] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - sessionID: identifies this window's temp subtree.
    ///   - queue: the window's transfer queue (download + write-back uploads).
    ///   - debounceInterval: coalescing window for file events (default 500 ms).
    ///   - sleep: injectable sleep hook (default `Task.sleep`); tests override it
    ///     to make debounce/reopen deterministic.
    public init(
        sessionID: UUID,
        queue: TransferQueueViewModel,
        debounceInterval: Duration = .milliseconds(500),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sessionID = sessionID
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.sleep = sleep
        self.sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-edit", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    // MARK: - Public API

    /// Downloads the remote file into the session temp dir via the queue
    /// (`enqueueAndWait`), registers a debounced file watcher, and returns the
    /// local URL for the caller to open. Re-invoking for an already-active
    /// `remotePath` returns the existing local URL (no second download/watcher).
    public func beginEditing(
        remotePath: String, fileName: String,
        source: any RemoteFileSystem, destinationForUploads: any RemoteFileSystem
    ) async throws -> URL {
        // Already editing this remote path: hand back the existing local copy.
        if let existingID = editByRemotePath[remotePath],
           let existing = activeEdits.first(where: { $0.id == existingID }) {
            return existing.localURL
        }

        // Per-file temp directory: <sessionDir>/<hash(remotePath)>/.
        let fileDirectory = sessionDirectory
            .appendingPathComponent(Self.pathHash(remotePath), isDirectory: true)
        try FileManager.default.createDirectory(
            at: fileDirectory, withIntermediateDirectories: true)
        let localURL = fileDirectory.appendingPathComponent(fileName, isDirectory: false)

        // Download through the queue so it appears in the transfer bar. Throws
        // on failure — no edit/watcher is registered in that case.
        try await queue.enqueueAndWait(
            fileName: fileName, direction: .download,
            source: source, sourcePath: remotePath,
            destination: localFS, destinationDirectory: fileDirectory.path(percentEncoded: false))

        let edit = ActiveEdit(
            id: UUID(), remotePath: remotePath, localURL: localURL, fileName: fileName)
        activeEdits.append(edit)
        editByRemotePath[remotePath] = edit.id

        let watcher = Watcher(
            editID: edit.id, localURL: localURL, fileName: fileName,
            remoteDirectory: RemotePath.parent(of: remotePath),
            uploadDestination: destinationForUploads)
        watchers[edit.id] = watcher
        startDispatchSource(for: watcher)

        return localURL
    }

    /// Stops all watchers and deletes the session temp directory. Idempotent.
    ///
    /// Ordering (binding): watchers are stopped FIRST, then the temp directory
    /// is removed. Any edit-upload already RUNNING in the queue is left
    /// untouched — it may still be reading the file; if that file is deleted
    /// out from under it, that upload just ends as a normal `.failed` item
    /// (accepted, documented).
    public func stopAll() async {
        for watcher in watchers.values {
            watcher.debounceTask?.cancel()
            watcher.reopenTask?.cancel()
            watcher.source?.cancel()   // cancel handler closes the fd
            watcher.source = nil
        }
        watchers.removeAll()
        editByRemotePath.removeAll()
        activeEdits.removeAll()
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    // MARK: - DispatchSource layer (kept thin)

    /// Opens an `O_EVTONLY` descriptor on the local file and wires a
    /// file-system-object source that, on any event, hops to the MainActor and
    /// routes into `dispatchEvent`. If the file can't be opened for watching,
    /// the edit still exists (the download succeeded) — it just won't
    /// auto-upload; the caller can retry `beginEditing` later.
    private func startDispatchSource(for watcher: Watcher) {
        let path = watcher.localURL.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        let editID = watcher.editID
        source.setEventHandler { [weak self] in
            let flags = source.data
            // The handler runs on the main queue == MainActor executor.
            MainActor.assumeIsolated {
                self?.dispatchEvent(editID: editID, flags: flags)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        watcher.source = source
        source.resume()
    }

    /// Raw event router (thin): editors do ATOMIC saves (write a temp file, then
    /// rename it over the original), which unlinks the inode our fd points at —
    /// surfacing as `.rename`/`.delete`. On those we reopen the fd at the SAME
    /// path to keep watching the new file, and still treat the event as a
    /// change. Every event feeds the debounce.
    func dispatchEvent(editID: UUID, flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.rename) || flags.contains(.delete) {
            reopenDispatchSource(editID: editID)
        }
        handleFileEvent(editID: editID)
    }

    /// Cancels the stale source and reopens an `O_EVTONLY` fd at the same path,
    /// retrying briefly because after an atomic rename-swap the replacement file
    /// may not be in place for a beat. Bounded retry with the injectable sleep.
    private func reopenDispatchSource(editID: UUID) {
        guard let watcher = watchers[editID] else { return }
        watcher.source?.cancel()   // cancel handler closes the old fd
        watcher.source = nil
        watcher.reopenTask?.cancel()
        let path = watcher.localURL.path(percentEncoded: false)
        watcher.reopenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<50 {
                // The edit may have been stopped meanwhile.
                guard let current = self.watchers[editID] else { return }
                let fd = open(path, O_EVTONLY)
                if fd >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: [.write, .rename, .delete, .extend],
                        queue: .main)
                    source.setEventHandler { [weak self] in
                        let flags = source.data
                        MainActor.assumeIsolated {
                            self?.dispatchEvent(editID: editID, flags: flags)
                        }
                    }
                    source.setCancelHandler { close(fd) }
                    current.source = source
                    source.resume()
                    return
                }
                if (try? await self.sleep(.milliseconds(20))) == nil { return }
            }
        }
    }

    // MARK: - Debounce + upload (directly testable)

    /// Records a detected change and (re)arms the debounce timer. Several calls
    /// in quick succession collapse into a single upload: each call cancels the
    /// pending debounce task, so only the LAST one survives to fire the upload.
    /// A no-op once the edit has been stopped (`stopAll`).
    func handleFileEvent(editID: UUID) {
        guard let watcher = watchers[editID] else { return }
        watcher.debounceTask?.cancel()
        let interval = debounceInterval
        watcher.debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Cancellation-aware wait: a newer event cancels this task, so it
            // must NOT fire the upload. `sleep` is the real `Task.sleep` (which
            // throws on cancel) by default, but even a non-throwing test hook is
            // covered by the `isCancelled` guard below.
            do { try await self.sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            self.triggerUpload(editID: editID)
        }
    }

    /// Enqueues the write-back upload for this edit (conflict check bypassed).
    private func triggerUpload(editID: UUID) {
        guard let watcher = watchers[editID] else { return }
        queue.enqueueEditUpload(
            fileName: watcher.fileName, localURL: watcher.localURL,
            source: localFS, destination: watcher.uploadDestination,
            remoteDirectory: watcher.remoteDirectory)
    }

    // MARK: - Helpers

    /// Deterministic, filesystem-safe hash of a remote path (FNV-1a 64-bit,
    /// hex). Pure function, so the SAME remote path always maps to the same
    /// temp subdirectory — the basis of the `beginEditing` dedup and cleanup.
    static func pathHash(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
