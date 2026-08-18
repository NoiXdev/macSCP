import Foundation
import Observation
import macSCPCore

struct BrowserSession {
    /// Identifies this tab's edit-session temp subtree (M5e/T4) — shared
    /// with `editManager`'s `sessionID` so both name the same directory.
    let id: UUID
    let localFS: LocalFileSystem
    let remoteFS: any RemoteFileSystem
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
    let terminal: TerminalPanelViewModel
    /// Owns "open in external editor" sessions for remote files double-clicked
    /// in this tab. Lifecycle is UI-owned like everything else here: see
    /// `ContentView.teardown(_:)`'s ordering (`stopAll` after `cancelAll`,
    /// before `terminal.shutdown`).
    let editManager: EditSessionManager
}

/// One window tab (M8a): bundles what used to be window-wide state, per
/// tab. Reference type — background tabs stay alive in `TabsViewModel`
/// while only the active tab is mounted.
@MainActor
@Observable
final class SessionTab: Identifiable {
    let id = UUID()
    let connectionViewModel: ConnectionViewModel
    var session: BrowserSession?
    let transferQueue = TransferQueueViewModel()
    let conflictBridge = ConflictPromptBridge()
    /// Drives the certificate-trust prompt for this tab's WebDAV/S3 connect
    /// attempts (M21/T10) — see `CertificatePromptBridge`'s own doc comment
    /// for why it is constructed OUTSIDE this initializer and simply handed
    /// in, unlike `conflictBridge` above.
    let certificateBridge: CertificatePromptBridge
    /// Drives the "send credentials unencrypted?" confirmation for this
    /// tab's connect attempts (M21/T10): `true` while
    /// `PlaintextTransportGate.requiresConfirmation` is true and the App is
    /// waiting for the user's answer. Same single-continuation shape as
    /// `CertificatePromptBridge` above, but plain properties on the tab
    /// itself rather than a separate bridge type: the dialog needs no
    /// candidate payload (its text is the same for every plaintext
    /// endpoint), so there is nothing a separate type would encapsulate that
    /// isn't already just "is one pending, and how do I resolve it".
    var plaintextConfirmationPending = false
    private var plaintextContinuation: CheckedContinuation<Bool, Never>?
    /// Set by the connector closure right before dispatching a connect whose
    /// transport is plaintext AND the user just confirmed the risk dialog;
    /// reset to `false` at the START of every connect attempt (before the
    /// gate is even consulted), so a previous connect's confirmation — even
    /// an ad-hoc one, which has no audit trail to write it into (see
    /// `attachAuditRecorder`'s own doc comment) — can never leak into a
    /// later, unrelated connect's audit record. Consumed (read and reset) by
    /// `ContentView.attachAuditRecorder`, the one place a `sessionID` (and
    /// with it, an `AuditRecorder` to write to) exists.
    var pendingPlaintextConfirmation = false
    /// Whether the transfer bar is shown for this tab (M11o). Per-tab and
    /// in-memory, mirroring `TerminalPanelViewModel.isVisible` — the toolbar
    /// icon / menu / ⌘⇧Y toggle it, and a newly enqueued transfer auto-reveals
    /// it (see `ContentView`). Not persisted.
    var transfersPanelVisible = false
    /// Whether the local/remote file panes are shown (P2 terminal-chrome
    /// milestone, Task 3). Per-tab and in-memory, mirroring
    /// `transfersPanelVisible` above — not persisted, and not reset across
    /// reconnects on this tab, same as that flag.
    ///
    /// This is HALF of `PaneVisibility`'s two facts (`showsFiles`); the
    /// other half, `showsTerminal`, is deliberately not a second stored
    /// property here. `TerminalPanelViewModel.isVisible` — the terminal
    /// panel's own, pre-existing visibility flag — already answers that
    /// question and stays its only owner; `paneToggleState(for:
    /// terminalIsVisible:hasShell:)` and `applyFilesToggleClick(
    /// terminalIsVisible:hasShell:)` below both take it as a parameter,
    /// read fresh from `session.terminal.isVisible` at the call site,
    /// instead of mirroring it into a property this type also owns and
    /// could drift out of sync with.
    var showsFiles = true
    /// Display name while connected (stored session name or "user@host") —
    /// drives the window title of the ACTIVE tab and the tab's own label.
    var titleName: String?
    /// Transient error from a failed "open in editor" attempt (M5e/T4) —
    /// cleared on the next successful open or dismissed via its close button.
    var editErrorMessage: String?
    /// Stored session this tab is connected to (sidebar highlight).
    var activeStoredSessionID: UUID?
    /// Per-session audit recorder (M9b) — set only when this tab connects to
    /// a STORED session (never for an ad-hoc connect), alongside
    /// `activeStoredSessionID`; nilled in `teardown(_:)` after the final
    /// `recordDisconnected()` call. See `ContentView.attachAuditRecorder`.
    var auditRecorder: AuditRecorder?
    var isReconnecting = false
    /// Last-seen value of `transferQueue.totalFailureCount` while this tab was
    /// active — the attention indicator (T4) lights up when
    /// `totalFailureCount` exceeds it. `totalFailureCount` is monotonic (it
    /// never decreases, unlike the old item-based `failedCount`), so this
    /// watermark correctly detects a NEW failure even after a background
    /// tab's completed items were swept by `clearCompleted()` (M8a T5 review,
    /// finding 2).
    var seenFailureCount = 0

    var isConnected: Bool { session != nil }

    var displayTitle: String {
        titleName ?? L10n.string("tabs.newConnection", "New Connection")
    }

    /// Wires the tab-owned queue on construction: shared limiter, initial
    /// concurrency, and the conflict decider onto the tab's OWN bridge —
    /// exactly once per tab (no re-wiring per connect).
    init(
        connectionViewModel: ConnectionViewModel,
        certificateBridge: CertificatePromptBridge,
        limiter: BandwidthLimiter,
        maxConcurrent: Int
    ) {
        self.connectionViewModel = connectionViewModel
        self.certificateBridge = certificateBridge
        transferQueue.limiter = limiter
        transferQueue.maxConcurrent = maxConcurrent
        let bridge = conflictBridge
        transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }
    }

    /// Decider side of the plaintext-transport confirmation (M21/T10):
    /// presents the dialog and suspends until `resolvePlaintextConfirmation`
    /// answers it. Cancellation-safe, same shape as
    /// `CertificatePromptBridge.ask(_:)`.
    func confirmPlaintext() async -> Bool {
        plaintextConfirmationPending = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    plaintextConfirmationPending = false
                    continuation.resume(returning: false)
                    return
                }
                plaintextContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePlaintextConfirmation(confirmed: false)
            }
        }
    }

    /// Called by the UI once the user answers the plaintext confirmation.
    func resolvePlaintextConfirmation(confirmed: Bool) {
        guard let continuation = plaintextContinuation else { return }
        plaintextContinuation = nil
        plaintextConfirmationPending = false
        continuation.resume(returning: confirmed)
    }

    /// Resets `pendingPlaintextConfirmation` — called by the connector
    /// closure at the START of every connect attempt, before the gate is
    /// even consulted. A plain `@MainActor`-isolated method (not a direct
    /// property write from the closure) so the cross-actor call goes through
    /// the normal `await`-hop instead of a bare assignment, which the
    /// connector closure — a `@Sendable` value handed to Core — cannot
    /// perform directly. See the property's own doc comment.
    func resetPendingPlaintextConfirmation() { pendingPlaintextConfirmation = false }

    /// Marks that this connect's plaintext confirmation was answered "yes" —
    /// called by the connector closure right before dispatching the actual
    /// connect. Same "isolated method, not a bare write" reasoning as
    /// `resetPendingPlaintextConfirmation()` above.
    func markPlaintextConfirmed() { pendingPlaintextConfirmation = true }

    /// The Files/Terminal toolbar toggle pair (P2 terminal-chrome milestone,
    /// Task 3): assembles this tab's `PaneVisibility` from `showsFiles` and
    /// `terminalIsVisible` (always `session.terminal.isVisible` at the call
    /// site — see `showsFiles`'s doc comment on why that is a parameter
    /// here, not a second stored property) and asks IT for `toggle`'s
    /// on/enabled state. Read by both toolbar buttons, so neither
    /// re-derives the lock rule (the last visible half cannot be turned
    /// off) or the `hasShell` rule on its own.
    func paneToggleState(
        for toggle: PaneToggle, terminalIsVisible: Bool, hasShell: Bool
    ) -> PaneToggleState {
        PaneVisibility(showsFiles: showsFiles, showsTerminal: terminalIsVisible)
            .toggleState(for: toggle, hasShell: hasShell)
    }

    /// Applies a click on the Files toggle: flips `showsFiles` through
    /// `PaneVisibility.applyingClick`, which folds in the same lock and
    /// `hasShell` rule `paneToggleState` reads above, so a click that would
    /// otherwise empty the window is a no-op inside the model itself,
    /// not a check reimplemented here.
    ///
    /// The computed result's `showsTerminal` is intentionally never written
    /// back to the terminal panel: `TerminalPanelViewModel.isVisible` only
    /// ever changes through its own `toggle()`/`openIfNeeded()`, which own
    /// the shell's lifecycle (opening/closing it), and a bare bool write
    /// here would bypass that. In practice this loses nothing —
    /// `applyingClick`'s `.files` branch can only fold `showsTerminal` DOWN
    /// to `false`, and only when `hasShell` is `false` — a state
    /// `terminalIsVisible` can never be `true` to begin with, since every
    /// call site that could set it to `true` refuses first when the backend
    /// has no shell (see `ContentView.presentTerminalUnavailable`) — so
    /// there is nothing this would ever need to write back.
    func applyFilesToggleClick(terminalIsVisible: Bool, hasShell: Bool) {
        let next = PaneVisibility(showsFiles: showsFiles, showsTerminal: terminalIsVisible)
            .applyingClick(on: .files, hasShell: hasShell)
        showsFiles = next.showsFiles
    }
}
