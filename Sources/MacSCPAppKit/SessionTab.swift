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
    /// Whether this session's local/remote file panes are shown (P2
    /// terminal-chrome milestone; moved here from `SessionTab` by the
    /// whole-phase review's Fix 1).
    ///
    /// It lives on the SESSION, not on the tab, because that is what makes
    /// "a connect with nothing saved starts from the default" true on EVERY
    /// connect path rather than on the paths someone remembered to reset.
    /// Every connect builds a fresh `BrowserSession` (`ContentView.
    /// startSession` is the only place one is constructed), so this starts
    /// at `true` again by construction — exactly like the terminal half,
    /// whose `TerminalPanelViewModel.isVisible` is `false` again for the
    /// same structural reason. The two halves were asymmetric before: this
    /// one outlived the session on the tab, and a stale `false` survived a
    /// disconnect into the next, unrelated connection.
    ///
    /// Read and written through `SessionTab.showsFiles`, never directly —
    /// see that property.
    var showsFiles = true
    /// Owns "open in external editor" sessions for remote files double-clicked
    /// in this tab. Lifecycle is UI-owned like everything else here: see
    /// `ContentView.teardown(_:)`'s ordering (`stopAll` after `cancelAll`,
    /// before `terminal.shutdown`).
    let editManager: EditSessionManager
    /// The remote home-directory path resolved once at connect (connection-
    /// liveness plan, Task 4). `ContentView.startSession`'s two callers
    /// already run `homeDirectoryPath()` before building this session and
    /// hand the result in as `startPath` — storing it here too lets the
    /// liveness probe `stat` it without a second round trip to find its own
    /// target.
    let homePath: String
}

/// One window tab (M8a): bundles what used to be window-wide state, per
/// tab. Reference type — background tabs stay alive in `TabsViewModel`
/// while only the active tab is mounted. Per-window scope: this type and
/// everything it stores (`liveness` included) belongs to one window's tab,
/// never to an app-wide singleton — this project's standing invariant for
/// connection/session state.
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
    /// milestone, Task 3). In-memory and per SESSION: the value itself lives
    /// on `BrowserSession.showsFiles` and this is the only way in and out of
    /// it. Unlike `transfersPanelVisible` above — which is genuinely per-tab
    /// and deliberately survives a reconnect — a hidden files pane belongs
    /// to the connection the user hid it in.
    ///
    /// That storage location is the whole point (whole-phase review, Fix 1):
    /// a connect with no saved state starts from the default on EVERY
    /// connect path, including the ad-hoc one that never reaches
    /// `ContentView.restorePaneVisibility`, because a fresh session cannot
    /// carry the previous one's value in the first place. There is no reset
    /// call a future connect path could forget to make. `ContentView.
    /// restorePaneVisibility` still writes the SAVED value in afterwards for
    /// a stored session — that write lands on the new session and is kept.
    ///
    /// While no session is attached this reads the default; a write in that
    /// state is a programming error and trips `assertionFailure` rather than
    /// being dropped silently (re-review, item 4). With nothing connected
    /// there are no panes to show or hide, and both writers (the Files
    /// toolbar button and `applyRestoredPaneVisibility`) run only on a
    /// connected tab — a write that arrives anyway means a new call site got
    /// the order wrong, which is exactly the "it compiles and does nothing"
    /// shape this phase has already paid for twice. In release builds the
    /// write is still dropped rather than trapping: a lost pane preference
    /// is not worth killing the app over.
    ///
    /// This is HALF of `PaneVisibility`'s two facts (`showsFiles`); the
    /// other half, `showsTerminal`, is deliberately not a second stored
    /// property here. `TerminalPanelViewModel.isVisible` — the terminal
    /// panel's own, pre-existing visibility flag — already answers that
    /// question and stays its only owner; `effectivePaneVisibility(
    /// terminalIsVisible:hasShell:)` below takes it as a parameter, read
    /// fresh from `session.terminal.isVisible` at the call site, instead of
    /// mirroring it into a property this type also owns and could drift
    /// out of sync with. This raw value, taken alone, is NOT the render
    /// decision — see `effectivePaneVisibility`'s doc comment for why
    /// reading it directly (as `ContentView+Detail.swift` used to) can
    /// disagree with the toolbar.
    var showsFiles: Bool {
        get { session?.showsFiles ?? true }
        set {
            guard session != nil else {
                assertionFailure("pane visibility written on a tab with no session")
                return
            }
            session?.showsFiles = newValue
        }
    }
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
    /// Identifies the current reconnect attempt for THIS tab (connection-
    /// liveness plan, Task 6 fix round 1) — the App-layer counterpart of
    /// `ConnectionViewModel.currentAttempt` (Core), for the identical
    /// reason: `isReconnecting` locks the sidebar and rejects a double-
    /// click reconnect (`ContentView.connect(in:stored:)`'s own top-of-
    /// function guard), and it must be released the moment Cancel runs —
    /// see `ConnectingAttemptView`'s `onCancel` in `ContentView+Detail
    /// .swift` — not only once the abandoned attempt's own wrapping `Task`
    /// finally reaches its `defer`. Reassigned both there and at the start
    /// of `connect(in:stored:)`, so a Task whose own attempt is no longer
    /// current cannot clear a NEWER attempt's `isReconnecting` flag out
    /// from under it when its own deferred cleanup finally runs.
    var reconnectAttempt = UUID()
    /// Last-seen value of `transferQueue.totalFailureCount` while this tab was
    /// active — the attention indicator (T4) lights up when
    /// `totalFailureCount` exceeds it. `totalFailureCount` is monotonic (it
    /// never decreases, unlike the old item-based `failedCount`), so this
    /// watermark correctly detects a NEW failure even after a background
    /// tab's completed items were swept by `clearCompleted()` (M8a T5 review,
    /// finding 2).
    var seenFailureCount = 0

    var isConnected: Bool { session != nil }

    /// This tab's connection liveness (Task 4; fix round 1 moved it here
    /// from `BrowserSession`). `nil` before the first connect attempt.
    ///
    /// Stored directly on the TAB, not on the session, and that is the
    /// whole fix: `ContentView.teardown(_:)` nils `session`, and if
    /// `liveness` had stayed a read-through onto `session?.liveness` (as it
    /// did before fix round 1), tearing a session down would ALWAYS have
    /// erased its own liveness in the same breath — `.lost`, the state
    /// `ContentView.handleLivenessGiveUp(_:)` sets after calling
    /// `teardown(_:)`, could never have been observed by anything that
    /// reads this property afterward. `.lost` is precisely the state in
    /// which there is no session anymore, so the value has to be able to
    /// outlive the session it describes.
    ///
    /// Seven writers, recounted while writing this sentence, at the
    /// whole-branch final review's finding I-1, which split the probe's own
    /// write off into a function that can refuse it (six as of Task 7, five
    /// as of Task 6 fix round 1, four as of Task 4 fix round 3) —
    /// `LivenessGiveUpOrderingTests` pins the second of these by mutation,
    /// since a comment describing this order is exactly what went stale
    /// between fix rounds 1 and 2 (a swapped pair of statements in a file
    /// this list does not name):
    /// - `ContentView.startSession` resets this to `.connected` on every
    ///   fresh connect.
    /// - `ContentView.handleLivenessGiveUp(_:)` sets `.lost` AFTER calling
    ///   `teardown(_:)`, not before — seeing `.lost` at all depends on that
    ///   order.
    /// - `ContentView.teardown(_:)` itself resets this to `nil`
    ///   unconditionally, for its four other callers (`disconnectToForm`,
    ///   `performClose`, the reconnect-in-place branch of `connect(in:
    ///   stored:)`, and Cancel's `onCancel` in `ContentView+Detail.swift`,
    ///   connection-liveness plan Task 6) — every one of them is a
    ///   deliberate "leave this connection", with nothing left for a stale
    ///   dot to describe.
    /// - `ContentView.dismissLostConnection(_:)` (Task 7) resets it to
    ///   `nil` when the user leaves the lost surface for the form, and
    ///   clears `lostConnection` in the same breath.
    /// - `LivenessProbeRunner`'s probe loop writes `.connected` directly
    ///   for a lap it SKIPPED because the queue was busy — running traffic
    ///   is its own proof, and no probe was issued to answer for it.
    /// - `LivenessProbeStep.perform` writes `.connected`/`.degraded` for a
    ///   probe that actually ran — but only if the probing task is still
    ///   live and still on the same session, since the race it waits on
    ///   cannot be cut short and would otherwise answer for a connection
    ///   that is already gone. See that type's own doc comment.
    /// - `ConnectAttemptLivenessMirror` (Task 6, extended in Task 7) writes
    ///   `.connecting` when this tab's own `connectionViewModel.state`
    ///   reaches `.connecting`, and, on `.failed` while this tab has no
    ///   session, either `.lost` again (when `lostConnection` says this tab
    ///   is describing a dropped connection) or `nil`. Which of the two is
    ///   `ConnectAttemptLivenessPlan.write`'s answer, not the view's — see
    ///   that type's doc comment in `ContentView+Detail.swift`.
    ///
    /// No getter/setter indirection the way `showsFiles` has: `showsFiles`
    /// is per-SESSION and needs the session to route writes into,
    /// `liveness` is per-TAB and is exactly what must keep working once the
    /// session it was describing is gone.
    var liveness: ConnectionLiveness?

    /// What the lost-connection surface describes and offers while
    /// `liveness` is `.lost` (connection-liveness plan, Task 7).
    ///
    /// Separate from `liveness` and not derived from it: `.lost` says THAT
    /// the connection is gone, this says what happened and — the part that
    /// cannot be recovered afterwards — WHICH stored session to redial.
    /// `ContentView.teardown(_:)` clears `activeStoredSessionID` along with
    /// the session itself, so by the time `.lost` is written there is no
    /// longer anything on this tab naming the connection that just dropped;
    /// `ContentView.handleLivenessGiveUp(_:)` captures it BEFORE calling
    /// teardown and writes this afterwards, in the same order and for the
    /// same reason `.lost` itself is written afterwards.
    ///
    /// Seven writers, counted while writing this sentence (the first
    /// version of this comment named four of them, which is how a reviewer
    /// found it):
    /// - `ContentView.handleLivenessGiveUp(_:)` opens an episode, after
    ///   `teardown(_:)` has run and for the same reason `.lost` is written
    ///   there rather than before it.
    /// - `ContentView.teardown(_:)` clears it, unconditionally, for its
    ///   other callers — every one of them a deliberate "leave this
    ///   connection", with no drop left to describe.
    /// - `ContentView.startSession` clears it: the tab has a live session
    ///   again, so the record of the one that dropped goes with it, attempt
    ///   counter included.
    /// - `ContentView.dismissLostConnection(_:)` clears it together with
    ///   `liveness`, when the user leaves the surface for the form.
    /// - `ContentView.connect(in:stored:)` clears it when the connect names
    ///   a DIFFERENT stored session — the user has moved on, and that
    ///   attempt's failure belongs to what they just asked for.
    /// - `ConnectAttemptLivenessMirror` writes back the `reason` a failed
    ///   attempt earned (`ConnectAttemptLivenessPlan.write`'s answer), in
    ///   the same step as the `liveness` it explains.
    /// - `ReconnectRunner` increments `automaticAttempts`, before the dial
    ///   it is about to start.
    ///
    /// Five of those seven also write `liveness`, in the same step, and
    /// the overlap was recounted here rather than carried over:
    /// `handleLivenessGiveUp`, `teardown`, `startSession`,
    /// `dismissLostConnection` and the mirror. That is what keeps the two
    /// values from drifting into describing different realities. The two
    /// that do not — `connect(in:stored:)`'s conditional clear and the
    /// runner's counter — touch nothing `liveness` describes.
    var lostConnection: LostConnection?

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

    /// THE single rule (P2 terminal-chrome milestone, Task 3 review round
    /// 1): the one place this tab assembles a `PaneVisibility` out of
    /// `showsFiles` and `terminalIsVisible` (always `session.terminal.
    /// isVisible` at the call site — see `showsFiles`'s doc comment on why
    /// that is a parameter here, not a second stored property).
    /// `terminalIsVisible` is folded with `hasShell` first, exactly the way
    /// `PaneVisibility.toggleState` folds it internally, and the result
    /// goes through `PaneVisibility`'s repairing initializer — so this
    /// NEVER returns "neither visible", regardless of what `showsFiles`
    /// and `terminalIsVisible` happen to be right now.
    ///
    /// `paneToggleState` (the toolbar's answer) and `detail`'s two render
    /// conditions in `ContentView+Detail.swift` both read THIS, instead of
    /// two independent raw booleans that only happen to agree most of the
    /// time. Before this method existed, `detail` read `tab.showsFiles`/
    /// `session.terminal.isVisible` directly: hide Files while Terminal is
    /// shown (allowed), disconnect (`shutdown()` sets `isVisible = false`,
    /// nothing resets `showsFiles`), reconnect (a fresh
    /// `TerminalPanelViewModel` defaults `isVisible` to `false` again) —
    /// now BOTH raw booleans are `false`, the repair never ran because
    /// nothing ever constructed a `PaneVisibility` from them, and the
    /// `VSplitView` rendered neither half while the toolbar's Files button
    /// (which DID go through the repair via `paneToggleState`) showed
    /// itself as on-and-locked. Routing both the toolbar and the render
    /// through this one method closes that gap: they can no longer
    /// disagree, because they are no longer two computations.
    ///
    /// The repair stayed necessary after Fix 1 moved `showsFiles` onto the
    /// session (a `hasShell` fold and a hand-edited stored value can still
    /// produce "neither visible"), but it is no longer the only thing
    /// standing between a reconnect and an empty window: the sequence above
    /// no longer PRODUCES two stale `false`s, because the fresh session
    /// brings a fresh `showsFiles` with it. Fix 1 exists because relying on
    /// the repair there was masking the stale value rather than clearing it
    /// — with the terminal half back on screen, the mask came off and the
    /// file panes disappeared for a user who never hid them.
    func effectivePaneVisibility(terminalIsVisible: Bool, hasShell: Bool) -> PaneVisibility {
        PaneVisibility(showsFiles: showsFiles, showsTerminal: terminalIsVisible && hasShell)
    }

    /// `toggle`'s on/enabled state, read from `effectivePaneVisibility`
    /// above rather than assembling its own `PaneVisibility` — see that
    /// method's doc comment for why there must be only one assembly point.
    func paneToggleState(
        for toggle: PaneToggle, terminalIsVisible: Bool, hasShell: Bool
    ) -> PaneToggleState {
        effectivePaneVisibility(terminalIsVisible: terminalIsVisible, hasShell: hasShell)
            .toggleState(for: toggle, hasShell: hasShell)
    }

    /// Applies a click on the Files toggle: flips `showsFiles` through
    /// `effectivePaneVisibility(...).applyingClick`, which folds in the
    /// same lock and `hasShell` rule `paneToggleState` reads above, so a
    /// click that would otherwise empty the window is a no-op inside the
    /// model itself, not a check reimplemented here.
    ///
    /// The computed result's `showsTerminal` is intentionally never written
    /// back to the terminal panel: `toggle()` is the one call that changes
    /// `TerminalPanelViewModel.isVisible` from outside that type, and it
    /// owns the shell's lifecycle (opening it on the way in) — a bare bool
    /// write here would bypass that. Stated precisely, because an earlier
    /// version of this comment was not (whole-phase review, Fix 3): the type
    /// itself also writes `isVisible` in `shutdown()`, which is its own
    /// business; `openIfNeeded()` never writes it at all; and until Fix 3
    /// `ContentView.triggerSnippet` DID write it directly, which made the
    /// old wording ("only ever changes through its own `toggle()`/
    /// `openIfNeeded()`") false at the moment it was written. No App-layer
    /// call site writes it directly today. This is safe even if some OTHER call site
    /// ever set `terminalIsVisible` to `true` while `hasShell` is `false`
    /// (today, every call site that could do that refuses first — see
    /// `ContentView.presentTerminalUnavailable` — but that is a fact about
    /// those call sites, established by reading them, not pinned by a test
    /// here): `effectivePaneVisibility` folds `terminalIsVisible &&
    /// hasShell` before this ever runs, so a stray `true` with no shell
    /// behind it already reads as `false` by the time `applyingClick` sees
    /// it, the same way it would for `paneToggleState` or the render.
    /// Applies a stored session's SAVED pane visibility to this tab and
    /// answers whether the terminal panel has to be revealed for it
    /// (P2 terminal-chrome milestone; whole-phase re-review, item 2).
    ///
    /// The decision lives here, not in `ContentView.restorePaneVisibility`,
    /// for the reason this whole phase is about: a decision that only exists
    /// inside a SwiftUI view is a decision no test can reach — this project
    /// has no view-instantiation tool, so the restore path had source
    /// scanners and nothing else. What stays in `ContentView` is the part
    /// that is not a decision: calling `TerminalPanelViewModel.toggle()` on
    /// the session it just built.
    ///
    /// Answering a `Bool` rather than opening the terminal itself keeps this
    /// type's existing rule intact — it never writes
    /// `TerminalPanelViewModel.isVisible`, see `applyFilesToggleClick`
    /// below.
    ///
    /// `saved.showsFiles` is written RAW, as everywhere else in this type;
    /// the terminal half goes through `effectivePaneVisibility`, the single
    /// assembly point, which folds in `hasShell` — so a session saved with a
    /// terminal on a backend that no longer has one opens no terminal, and
    /// files are promoted back on by the repair.
    ///
    /// A session with no recorded preference does not reach this with
    /// "both visible": `StoredSession` resolves a missing key to
    /// `PaneVisibility.filesOnly` (maintainer ruling, see that constant), so
    /// an old `sessions.json` opens no shell on its next connect.
    func applyRestoredPaneVisibility(_ saved: PaneVisibility, hasShell: Bool) -> Bool {
        showsFiles = saved.showsFiles
        return effectivePaneVisibility(
            terminalIsVisible: saved.showsTerminal, hasShell: hasShell).showsTerminal
    }

    func applyFilesToggleClick(terminalIsVisible: Bool, hasShell: Bool) {
        let next = effectivePaneVisibility(terminalIsVisible: terminalIsVisible, hasShell: hasShell)
            .applyingClick(on: .files, hasShell: hasShell)
        showsFiles = next.showsFiles
    }
}
