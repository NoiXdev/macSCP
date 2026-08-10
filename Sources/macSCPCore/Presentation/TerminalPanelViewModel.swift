import Foundation
import Observation

/// State and lifecycle of the collapsible terminal panel.
/// Owns the shell's read loop; the view only provides presentation/input.
@Observable @MainActor
public final class TerminalPanelViewModel {
    public enum PanelState: Equatable {
        /// No shell (initial, or after shutdown).
        case closed
        case opening
        case running
        /// Shell ended; message only on error (nil = normal end).
        case ended(String?)
    }

    public typealias ShellOpener = @Sendable (
        _ terminal: String, _ cols: Int, _ rows: Int
    ) async throws -> any RemoteShell

    public private(set) var state: PanelState = .closed
    public var isVisible = false
    /// Set by the view; receives output bytes on the MainActor.
    public var onOutput: (([UInt8]) -> Void)?
    /// Most recently received output chunks (max. 256 KiB) — replayed when the
    /// panel is shown again, so ⌘T doesn't discard the visible screen.
    public private(set) var replayBuffer: [[UInt8]] = []

    private static let maxReplayBytes = 256 * 1024
    private var replayBytes = 0

    /// Keystrokes handed to `send(_:)` while the shell was still opening,
    /// replayed in order the moment it is running.
    ///
    /// Without this, everything sent between `openIfNeeded()` and the shell
    /// coming up is dropped on `send(_:)`'s `guard let shell` — which is what
    /// a menu-triggered terminal snippet hits on a tab whose panel was never
    /// opened, since that path has to open the panel first and cannot wait
    /// for it. Typing into the panel during `.opening` reaches the same
    /// guard.
    ///
    /// Belongs to ONE open attempt: cleared when an open starts, when one
    /// fails, when the shell ends, and on `shutdown()`. Capped like
    /// `replayBuffer` above — bytes past the cap are dropped rather than
    /// growing without bound behind an open that never completes.
    private var pendingBytes: [UInt8] = []
    private static let maxPendingBytes = 64 * 1024

    private let openShell: ShellOpener
    private var shell: (any RemoteShell)?
    private var readTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// Chains all `send()` calls into a FIFO queue (see `send(_:)`).
    private var sendTask: Task<Void, Never>?
    /// Counts up every `openIfNeeded()`/`shutdown()` cycle. An in-flight
    /// `openShell(...)` or a late-ending read loop may only write
    /// `state`/`shell` if its captured generation is still current — otherwise
    /// it would overwrite a newer state (in particular a `shutdown()`).
    private var generation = 0

    public init(openShell: @escaping ShellOpener) {
        self.openShell = openShell
    }

    /// Show/hide the panel; opens the shell on show, if none is running.
    public func toggle() {
        isVisible.toggle()
        if isVisible { openIfNeeded() }
    }

    /// Opens the shell if none is running (also for "reopen" after `.ended`).
    public func openIfNeeded() {
        switch state {
        case .opening, .running: return
        case .closed, .ended: break
        }
        state = .opening
        replayBuffer = []
        replayBytes = 0
        pendingBytes = []
        cancelPendingSends()
        generation += 1
        let myGeneration = generation
        openTask = Task {
            do {
                let shell = try await openShell("xterm-256color", 80, 24)
                // `shutdown()` may have run while the `await` above was in
                // flight. In that case this shell belongs to nobody anymore —
                // close it instead of letting it run as an orphan or
                // overwriting `state`.
                guard self.generation == myGeneration else {
                    await shell.close()
                    return
                }
                self.shell = shell
                state = .running
                flushPendingBytes()
                let readGeneration = myGeneration
                readTask = Task { [weak self] in
                    do {
                        for try await chunk in shell.output {
                            self?.bufferForReplay(chunk)
                            self?.onOutput?(chunk)
                        }
                        self?.finishShell(message: nil, generation: readGeneration)
                    } catch {
                        self?.finishShell(
                            message: String(
                                format: CoreL10n.string("core.terminal.shellEnded %@"),
                                error.localizedDescription),
                            generation: readGeneration
                        )
                    }
                }
            } catch {
                guard self.generation == myGeneration else { return }
                shell = nil
                // Defensive, not load-bearing — and the difference matters
                // enough to write down, because an earlier comment here
                // claimed the opposite. The only reader of `pendingBytes` is
                // `flushPendingBytes()`, which runs on the success path
                // above, right after `openIfNeeded()` has cleared the buffer
                // itself; nothing between this `catch` and the next open can
                // reach these bytes either way. What this line does buy is
                // releasing up to `maxPendingBytes` now instead of at the
                // next `openIfNeeded()`/`shutdown()`. The `.ended` message
                // below is what actually tells the user the input is gone.
                pendingBytes = []
                state = .ended(String(
                    format: CoreL10n.string("core.terminal.openFailed %@"),
                    error.localizedDescription))
            }
        }
    }

    /// Appends `chunk` to the replay buffer and drops the oldest chunks until
    /// back under `maxReplayBytes`.
    private func bufferForReplay(_ chunk: [UInt8]) {
        replayBuffer.append(chunk)
        replayBytes += chunk.count
        while replayBytes > Self.maxReplayBytes, !replayBuffer.isEmpty {
            replayBytes -= replayBuffer.removeFirst().count
        }
    }

    private func finishShell(message: String?, generation readGeneration: Int) {
        // A read loop from an older generation (e.g. after `shutdown()`) may
        // not overwrite a state that's already been set since.
        guard generation == readGeneration else { return }
        shell = nil
        readTask = nil
        pendingBytes = []
        cancelPendingSends()
        state = .ended(message)
    }

    /// Drops the `send()` chain, because the calls queued in it are aimed at
    /// a shell that is gone.
    ///
    /// Called wherever the current shell stops being the one `send()` should
    /// reach: when an open starts, when the shell ends, and on `shutdown()`.
    /// Without it the chain outlives its shell, and the first `send()` after
    /// a reopen has to wait behind a `send` to the closed one before it can
    /// run — a delay, not a misdelivery, since the queued calls carry their
    /// own shell reference and can never reach the new one.
    ///
    /// Cancelled rather than awaited: a `send` that hangs must not hold up
    /// the reopen (`shutdown()` states the same reason for the same call).
    private func cancelPendingSends() {
        sendTask?.cancel()
        sendTask = nil
    }

    /// Sends what `send(_:)` buffered while the shell was opening.
    ///
    /// Called from the same synchronous step that sets `.running`, so no
    /// later `send(_:)` can slip in front of the buffered bytes: order is
    /// preserved without touching the `sendTask` chain, which takes over from
    /// here.
    private func flushPendingBytes() {
        guard !pendingBytes.isEmpty else { return }
        let buffered = pendingBytes
        pendingBytes = []
        send(buffered)
    }

    /// Sends keyboard bytes to the shell. Calls are chained in FIFO order —
    /// independent tasks per call would NOT guarantee that (fast keystrokes
    /// or a paste could otherwise arrive out of order). Send errors end the
    /// read loop anyway.
    ///
    /// While the shell is still opening the bytes are held and sent as soon
    /// as it runs (see `pendingBytes`). In every other shell-less state
    /// (`.closed`, `.ended`) they are dropped: nothing is on its way that
    /// could ever deliver them.
    public func send(_ bytes: [UInt8]) {
        guard let shell else {
            if state == .opening {
                pendingBytes.append(
                    contentsOf: bytes.prefix(Self.maxPendingBytes - pendingBytes.count))
            }
            return
        }
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            try? await shell.send(bytes)
        }
    }

    /// Reports a new terminal size (SSH window-change).
    public func resize(cols: Int, rows: Int) {
        guard let shell else { return }
        Task { try? await shell.resize(cols: cols, rows: rows) }
    }

    /// Closes the shell and resets the panel (disconnect/session switch).
    /// Idempotent; returns only once the channel is closed — including any
    /// still-running `openIfNeeded()`, so no in-flight open can write
    /// `state`/`shell` afterwards or resurrect a shell.
    public func shutdown() async {
        // Increment first: any still-running openIfNeeded()/finishShell()
        // continuation recognizes from its captured (now stale) generation
        // that it may no longer write anything.
        generation += 1

        openTask?.cancel()
        await openTask?.value
        openTask = nil

        readTask?.cancel()
        readTask = nil

        if let shell {
            await shell.close()
        }
        shell = nil
        // Don't wait on `sendTask`: the `send()` calls chained into it target
        // the just-closed shell and may simply run out or no-op — otherwise
        // `shutdown()` could block on a hanging `send()`.
        cancelPendingSends()
        pendingBytes = []
        replayBuffer = []
        replayBytes = 0
        state = .closed
        isVisible = false
    }
}
