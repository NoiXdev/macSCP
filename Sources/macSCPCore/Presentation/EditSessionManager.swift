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
        /// The single in-flight write-back for this edit, or `nil` when none is
        /// running. Serializes write-backs per edit: a debounced save that
        /// fires while this is non-nil does NOT enqueue a second upload.
        var uploadTask: Task<Void, Never>?
        /// A save arrived while `uploadTask` was in flight — the edit is dirty.
        /// When the in-flight upload finishes, exactly one fresh upload is
        /// enqueued (which naturally reads the latest file content) and this is
        /// cleared. Coalesces any number of saves during one upload into one.
        var uploadPending = false

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
    /// remotePath → in-progress download+register `Task`, reserved
    /// SYNCHRONOUSLY (before any `await`) by the first `beginEditing` caller
    /// for that path. A second, overlapping call for the SAME remotePath
    /// (e.g. a fast double-double-click before the first download finishes)
    /// finds the entry already here and awaits the SAME task instead of
    /// starting a second download/watcher — this is what closes the race
    /// that `editByRemotePath` alone (only populated AFTER the download)
    /// leaves open. Removed once the task settles, success or failure.
    private var inFlightDownloads: [String: Task<URL, Error>] = [:]

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

    /// Removes the entire `macscp-edit` temp tree at app launch (M6a). Only
    /// `stopAll` cleans a session's subtree, so hard-killed app runs leave
    /// orphaned directories behind forever. At launch no edit can be active
    /// (single-instance app, sessions start later), so sweeping the whole
    /// tree is safe. Idempotent; a missing tree is a no-op. `root` is
    /// injectable (M6b) so tests sweep an isolated directory instead of the
    /// process-wide real temp root.
    public static func sweepOrphanedTempDirectories(
        root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-edit", isDirectory: true)
    ) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Public API

    /// Downloads the remote file into the session temp dir via the queue
    /// (`enqueueAndWait`), registers a debounced file watcher, and returns the
    /// local URL for the caller to open. Re-invoking for an already-active
    /// `remotePath` returns the existing local URL (no second download/watcher).
    ///
    /// Two overlapping calls for the SAME remotePath (e.g. a fast
    /// double-double-click before the first download finishes) also collapse
    /// into one download/watcher: the SECOND caller finds the FIRST caller's
    /// reservation in `inFlightDownloads` (made synchronously, before the
    /// first `await`) and awaits that same `Task`'s result instead of racing
    /// it. Without this, the "already editing" check above — populated only
    /// AFTER the download completes — has a window where both calls pass it.
    public func beginEditing(
        remotePath: String, fileName: String,
        source: any RemoteFileSystem, destinationForUploads: any RemoteFileSystem
    ) async throws -> URL {
        // Already editing this remote path: hand back the existing local copy.
        if let existingID = editByRemotePath[remotePath],
           let existing = activeEdits.first(where: { $0.id == existingID }) {
            return existing.localURL
        }

        // A download for this remotePath is already in flight: await its
        // result instead of starting a second one. Checked and (below)
        // reserved synchronously — no `await` between the check and the
        // reservation — so there is no window for a third caller to slip
        // through either.
        if let inFlight = inFlightDownloads[remotePath] {
            return try await inFlight.value
        }

        let task = Task { @MainActor [weak self] () -> URL in
            guard let self else { throw CancellationError() }
            defer { self.inFlightDownloads[remotePath] = nil }
            return try await self.downloadAndRegister(
                remotePath: remotePath, fileName: fileName,
                source: source, destinationForUploads: destinationForUploads)
        }
        inFlightDownloads[remotePath] = task

        return try await task.value
    }

    /// The actual download + registration, run inside the reserved
    /// `inFlightDownloads` task. Throws on download failure — no edit/watcher
    /// is registered in that case (and the reservation is removed by the
    /// caller's `defer`, so a retry can start fresh with no ghost `ActiveEdit`).
    private func downloadAndRegister(
        remotePath: String, fileName: String,
        source: any RemoteFileSystem, destinationForUploads: any RemoteFileSystem
    ) async throws -> URL {
        // Per-file temp directory: <sessionDir>/<hash(remotePath)>/.
        let fileDirectory = sessionDirectory
            .appendingPathComponent(Self.pathHash(remotePath), isDirectory: true)
        try FileManager.default.createDirectory(
            at: fileDirectory, withIntermediateDirectories: true)
        let localURL = fileDirectory.appendingPathComponent(fileName, isDirectory: false)

        // Download through the queue so it appears in the transfer bar.
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
            // Cancel the serialization waiter task and drop the dirty flag so no
            // orphaned write-back is enqueued after teardown. The task is likely
            // suspended on the queue's waiter continuation (which ignores task
            // cancellation); when that upload eventually settles the task
            // resumes, but `finishUpload` finds no watcher and does nothing.
            watcher.uploadTask?.cancel()
            watcher.uploadPending = false
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

    /// Serializes write-backs per edit (conflict check bypassed). At most one
    /// write-back is in flight for a given edit at any time: if one is already
    /// running, this only marks the edit dirty (`uploadPending`) and returns —
    /// it does NOT enqueue a second job to the same remote path. The in-flight
    /// upload's completion (`finishUpload`) then enqueues exactly one fresh
    /// upload if the edit went dirty, which picks up the latest file content.
    /// Without this, two saves more than one debounce interval apart could run
    /// two uploads to the same path concurrently, and whichever finished last
    /// — not the last-SAVED version — would win.
    private func triggerUpload(editID: UUID) {
        guard let watcher = watchers[editID] else { return }
        if watcher.uploadTask != nil {
            watcher.uploadPending = true
            return
        }
        startUpload(for: watcher)
    }

    /// Enqueues one write-back and awaits its completion through the queue's
    /// waiter API (same machinery the download uses via `enqueueAndWait`),
    /// then routes into `finishUpload`. Failures are irrelevant to
    /// serialization — the queue surfaces them in the bar; we only need to
    /// learn the upload settled so the next coalesced save can proceed.
    private func startUpload(for watcher: Watcher) {
        let editID = watcher.editID
        let fileName = watcher.fileName
        let localURL = watcher.localURL
        let destination = watcher.uploadDestination
        let remoteDirectory = watcher.remoteDirectory
        watcher.uploadPending = false
        watcher.uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.queue.enqueueEditUploadAndWait(
                fileName: fileName, localURL: localURL,
                source: self.localFS, destination: destination,
                remoteDirectory: remoteDirectory)
            self.finishUpload(editID: editID)
        }
    }

    /// The in-flight write-back for `editID` has settled. Clears the in-flight
    /// marker and, if a save arrived meanwhile (`uploadPending`), enqueues
    /// exactly one fresh upload. A no-op once the edit has been stopped
    /// (`stopAll` removed the watcher) — so no orphaned upload is started.
    private func finishUpload(editID: UUID) {
        guard let watcher = watchers[editID] else { return }
        watcher.uploadTask = nil
        if watcher.uploadPending {
            startUpload(for: watcher)
        }
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
