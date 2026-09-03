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
    /// Whether the remote has bracketed paste (mode 2004) on, as the local
    /// emulator has observed it. Set by the terminal view, the same way
    /// `onOutput` is; `nil` while no view is attached, which reads as "off"
    /// — the conservative answer, since it only ever costs a refusal or a
    /// line-by-line send, never an unexpected execution.
    public var bracketedPasteQuery: (() -> Bool)?
    /// `bracketedPasteQuery`'s answer, defaulting to `false`.
    public var remoteWantsBracketedPaste: Bool { bracketedPasteQuery?() ?? false }
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

    /// Delivery callbacks belonging to the bytes in `pendingBytes`, kept
    /// beside them because the buffer is a flat byte array: several buffered
    /// `send(_:onDelivered:)` calls merge into one, so their callbacks
    /// cannot be recovered from it. Discarded together with the bytes
    /// wherever an open attempt gives up -- a caller that never got its
    /// bytes out must not be told they went.
    private var pendingDeliveries: [@MainActor () -> Void] = []

    /// A terminal geometry, so the two properties below are one value that
    /// can be compared in one step rather than two ints that can drift apart.
    private struct Geometry: Equatable {
        let cols: Int
        let rows: Int
    }

    /// The geometry the surface last reported while no shell existed yet,
    /// replayed the moment one does — the resize counterpart of
    /// `pendingBytes`, and for the same reason.
    ///
    /// The app's order is open-then-layout: `toggle()` sets `isVisible` and
    /// calls `openIfNeeded()` in one synchronous step, and the panel renders
    /// its surface for `.opening` as well as `.running`. So SwiftTerm reports
    /// the mount's geometry -- its only report for that mount, since
    /// `sizeChanged` fires again only when the COMPUTED geometry changes --
    /// while `shell` is still `nil`. Dropping it left the remote PTY at
    /// `openIfNeeded()`'s hardcoded 80x24 for the rest of the shell's life
    /// while the emulator drew the window's real size: long lines wrapped
    /// wrong and full-screen programs painted an 80x24 screen. The `.ended`
    /// -> "Reopen" path arrives here too: that branch of the panel's `switch`
    /// tears the surface down, so Reopen mounts a fresh one, which reports
    /// its geometry with `openIfNeeded()` having already set `.opening`.
    ///
    /// Belongs to ONE open attempt, exactly like `pendingBytes`: cleared when
    /// an open starts, when one fails, when the shell ends, and on
    /// `shutdown()`. A single value rather than a list -- only the latest
    /// geometry is worth sending.
    private var pendingSize: Geometry?

    /// The geometry the CURRENT shell last ACKNOWLEDGED -- written when
    /// `shell.resize` returns, not when it is queued, and only if the shell
    /// it was sent to is still this panel's -- or `nil` while none has got
    /// through to it.
    ///
    /// It is what a new report is compared against, and it is deliberately
    /// not "the geometry the shell was opened at": comparing against the
    /// open-time 80x24 would skip the send for a window whose laid-out
    /// geometry happens to be exactly 80x24 -- a shell that then never hears
    /// a size, and a pin that stays red after a correct fix. Reset with the
    /// shell, since a new shell starts at its own open-time geometry and
    /// knows nothing of what the previous one was told.
    private var lastSentSize: Geometry?

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
        discardPendingInput()
        forgetGeometry()
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
                // Before the bytes, not beside them: `flushPendingBytes()`
                // can start a full-screen program (a menu snippet buffered
                // by `ContentView.sendSnippet`, which opens the panel and
                // sends in one step), and one that starts before the
                // window-change starts at 80x24 and has to take a SIGWINCH
                // afterwards. Both go through `sendTask`, so this order is
                // the delivery order and not just the call order.
                flushPendingSize(to: shell)
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
                discardPendingInput()
                forgetGeometry()
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
        discardPendingInput()
        forgetGeometry()
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

    /// Drops buffered input AND the callbacks that belong to it. One helper
    /// rather than two assignments at each site, so a later drop path cannot
    /// clear the bytes and leave a callback behind that would then report a
    /// delivery which never happened.
    private func discardPendingInput() {
        pendingBytes = []
        pendingDeliveries = []
    }

    /// Forgets both geometries, because the shell they describe is starting,
    /// failing or ending.
    ///
    /// Deliberately NOT folded into `discardPendingInput()`, which it
    /// otherwise accompanies: that one has five call sites and this has the
    /// same four lifecycle ones, but the fifth is `flushPendingBytes()`,
    /// where `discardPendingInput()` means "the buffer is spent". Clearing
    /// `lastSentSize` there would erase what the shell had just been told,
    /// one line after it was told.
    ///
    /// `pendingSize` goes for `pendingBytes`' reason -- a geometry held for an
    /// attempt that failed must not reach a shell opened later at a different
    /// window size. `lastSentSize` goes because it describes a shell that is
    /// gone: the next one starts at its own open-time geometry, having been
    /// told nothing.
    private func forgetGeometry() {
        pendingSize = nil
        lastSentSize = nil
    }

    /// Sends the geometry `resize(cols:rows:)` held while the shell was
    /// opening, if there is one and it is not what the shell was last told.
    ///
    /// Called from the same synchronous step that sets `.running`, directly
    /// after `self.shell` is assigned and after the generation check -- so it
    /// can neither run before the shell exists nor write to a shell that
    /// `shutdown()` has already disowned.
    private func flushPendingSize(to shell: any RemoteShell) {
        guard let size = pendingSize else { return }
        pendingSize = nil
        guard size != lastSentSize else { return }
        sendWindowChange(size, to: shell)
    }

    /// Queues an SSH window-change on the SAME chain as `send(_:)`.
    ///
    /// Not a free `Task`: one would race the buffered bytes flushed beside
    /// it, and the loser of that race is a full-screen program started at
    /// the wrong size. Chaining also keeps two window-changes in order, so
    /// the last one issued is the last one the remote sees. The cost of the
    /// chain is that a window-change waits behind every queued `send` --
    /// against a stalled connection it does not go out at all, where a free
    /// `Task` would have tried. That is the deliberate trade: the shell's
    /// size is worth nothing if the program that reads it started at the
    /// wrong one.
    ///
    /// What `cancelPendingSends()` does for that chain is narrower than it
    /// looks, and the narrow version is what the identity check below rests
    /// on. It drops the view model's REFERENCE (`sendTask` names only the
    /// tail; the earlier links are reachable only as each successor's
    /// captured `previous`) and flags that tail as cancelled. It does not
    /// stop anything: a `Task<Void, Never>`'s `value` never returns early,
    /// and a real `shell.resize` is awaiting a NIO future that does not
    /// observe cancellation at all. So a window-change queued for a shell
    /// that has since ended still goes out and still comes back -- possibly
    /// while a LATER shell is opening. Its bytes can never reach that later
    /// shell (each queued call carries its own shell reference), but its
    /// bookkeeping could, which is what `self.shell === shell` refuses.
    ///
    /// `lastSentSize` is therefore written under two conditions, not one:
    ///
    /// 1. only after the send RETURNS, never at queue time. Recording it up
    ///    front would remember a window-change that threw as delivered, and
    ///    the dedup in `resize(cols:rows:)` would then swallow the next
    ///    report of that same geometry -- leaving the remote at a size nobody
    ///    can correct, since `sizeChanged` fires only on a CHANGE and will
    ///    not report it again. The error itself stays swallowed, as on the
    ///    `send(_:)` path beside it: a resize failure is not worth ending a
    ///    session over, and a channel broken enough to matter ends the read
    ///    loop on its own;
    /// 2. only if the shell it was sent to is still the panel's shell. The
    ///    write sits after an `await`, so it is no longer inside the
    ///    synchronous step that owns the shell -- the same discipline every
    ///    other post-`await` write in this file follows (the open task has
    ///    its generation check, the read loop has one too). Without it, a
    ///    100x30 window-change stalling across an end and a Reopen writes
    ///    `lastSentSize` while `shell` is `nil`, the remounted surface holds
    ///    the same unchanged 100x30 in `pendingSize`, and the next shell's
    ///    `flushPendingSize` dedups against a size that shell was never told
    ///    -- keeping its open-time 80x24 for life, which is the very defect
    ///    this class was changed to fix.
    ///
    /// The trade in moving the write behind the `await`: two IDENTICAL
    /// reports issued before the first returns no longer dedup against each
    /// other, so both go out. Harmless -- one `WindowChangeRequest` sets the
    /// same PTY dimensions twice, costing one extra `SIGWINCH` and one extra
    /// redraw -- and rare, since `sizeChanged` fires only on a change, so it
    /// takes a `flushPendingSize` racing a report in the same tick.
    private func sendWindowChange(_ size: Geometry, to shell: any RemoteShell) {
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            do {
                try await shell.resize(cols: size.cols, rows: size.rows)
                // Attributed to the shell it was sent to, never to whatever
                // the panel has become while it was in flight -- see 2. above.
                if self.shell === shell { lastSentSize = size }
            } catch {
                // Swallowed, and deliberately NOT recorded as sent -- see
                // 1. above. The next report of this geometry is sent again.
            }
        }
    }

    /// Sends what `send(_:)` buffered while the shell was opening.
    ///
    /// Called from the same synchronous step that sets `.running`, so no
    /// later `send(_:)` can slip in front of the buffered bytes: order is
    /// preserved without touching the `sendTask` chain, which takes over from
    /// here. The one thing that IS ahead of them in that chain is the
    /// window-change `flushPendingSize(to:)` queues one line earlier, which
    /// is the point of doing it there.
    ///
    /// (The first two paragraphs sat on `discardPendingInput()` below, which
    /// they do not describe, until 2026-09-03.)
    private func flushPendingBytes() {
        guard !pendingBytes.isEmpty else { return }
        let buffered = pendingBytes
        let deliveries = pendingDeliveries
        discardPendingInput()
        if deliveries.isEmpty {
            send(buffered)
        } else {
            send(buffered) { for fire in deliveries { fire() } }
        }
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
    public func send(_ bytes: [UInt8], onDelivered: (@MainActor () -> Void)? = nil) {
        guard let shell else {
            if state == .opening {
                pendingBytes.append(
                    contentsOf: bytes.prefix(Self.maxPendingBytes - pendingBytes.count))
                if let onDelivered { pendingDeliveries.append(onDelivered) }
            }
            return
        }
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            do {
                try await shell.send(bytes)
                onDelivered?()
            } catch {
                // Swallowed as before -- a send error ends the read loop
                // anyway. It is deliberately NOT a delivery: the callback
                // exists so a caller can record what actually went out.
            }
        }
    }

    /// Reports a new terminal size (SSH window-change).
    ///
    /// While the shell is still opening the geometry is HELD and sent as soon
    /// as it runs (see `pendingSize`) -- the app lays the surface out after
    /// it has started opening, so this is the normal case for the first
    /// report of every mount, not an edge one. In every other shell-less
    /// state (`.closed`, `.ended`) it is dropped: nothing is on its way that
    /// could deliver it, and holding it would mean replaying a stale geometry
    /// into a shell opened much later. The guard stays a guard either way --
    /// no task is ever queued against a nil shell.
    public func resize(cols: Int, rows: Int) {
        let size = Geometry(cols: cols, rows: rows)
        guard let shell else {
            if state == .opening { pendingSize = size }
            return
        }
        guard size != lastSentSize else { return }
        sendWindowChange(size, to: shell)
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
        discardPendingInput()
        forgetGeometry()
        replayBuffer = []
        replayBytes = 0
        state = .closed
        isVisible = false
    }
}
