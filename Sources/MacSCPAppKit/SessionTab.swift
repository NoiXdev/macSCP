import Foundation
import Observation
import SwiftUI
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
    /// What the user has asked this session to compute, one ledger per pane
    /// (2026-09-02, review I2). The checksum column reads these and nothing
    /// else.
    ///
    /// They live on the SESSION for the same reason `showsFiles` does, and
    /// the argument is stronger here: every value in one cost a server-side
    /// hash of a whole file, and the pane that showed it is remounted by
    /// things that have nothing to do with the file — switching tabs (the
    /// detail subtree carries `.id(tab.id)`, deliberately, so no pane state
    /// crosses tabs), hiding the Files pane, entering terminal-only mode. As
    /// view state those digests died on every one of those; here they die
    /// only with the connection they were computed over, which is the one
    /// event that makes them meaningless.
    ///
    /// Two, not one: two panes are two file systems, and a path means
    /// nothing across them. A shared ledger could show a local file the
    /// digest of a remote file of the same size and date.
    var localChecksums = ChecksumLedger()
    var remoteChecksums = ChecksumLedger()
    /// Which of this connection's buckets have Object Lock, read once each and
    /// kept (`ObjectLockStateCache`), or `nil` when the connection is not one
    /// that has bucket settings at all.
    ///
    /// It lives on the SESSION for the reason `localChecksums` does: what it
    /// holds is true of the connection it was read over and of no other, so it
    /// dies with that connection and a reconnect starts from nothing. Set once
    /// by `ContentView.startSession`.
    var objectLockStates: ObjectLockStateCache?
    /// Which versioning state each of this connection's buckets is in, read
    /// once each and kept (`BucketVersioningCache`), or `nil` when the
    /// connection has no bucket settings. The sibling of `objectLockStates`
    /// above and for the same reason: it is true of this connection and of no
    /// other, so it dies with it. Set once by `ContentView.startSession`.
    var bucketVersioning: BucketVersioningCache?
    /// Whether THIS CONNECTION will take a permission change: the answer to
    /// `PermissionsAvailability.isOffered(for:on:)`, written once after the
    /// connection opened (`SessionTab.recordPermissionEditing`).
    ///
    /// On the SESSION for the reason `objectLockStates` is: it is true of this
    /// connection and no other, so it dies with it and a reconnect asks again.
    /// And held rather than computed, because the one place that reads it is a
    /// SwiftUI body (`ContentView+Detail`'s `supportsPermissions:`), which is
    /// synchronous, while the question may be a round trip -- FTP's
    /// `SITE CHMOD` is a per-server extension (`PermissionEditingProbe`).
    ///
    /// **`true` until the connection has answered, and that direction is
    /// deliberate.** It is today's behaviour: the editor is offered per
    /// protocol, and the capability read beside this value
    /// (`PermissionsAvailability.isOffered(for:)`) still has the final say for
    /// a backend with no POSIX model. An answer can therefore only take an
    /// offer away, never add one -- the same asymmetry the Core function has,
    /// and for the same reason (an inconclusive probe answers `true` there, so
    /// a transient failure does not hide a working editor).
    var permissionEditing = true

    /// The cache for a connection over `fileSystem`: one when it has the
    /// bucket-settings capability, `nil` when it does not -- the question
    /// `objectLockStates(for:)` answers for the lock cache, asked of the same
    /// capability.
    @MainActor
    static func bucketVersioning(for fileSystem: Any) -> BucketVersioningCache? {
        (fileSystem as? any S3BucketSettings).map(BucketVersioningCache.init(settings:))
    }

    /// The cache for a connection over `fileSystem`: one when it has the
    /// bucket-settings capability (queried with `as?`, like every optional
    /// capability), `nil` when it does not.
    ///
    /// Its own function so that the question "does this connection get one"
    /// has a test, and so that `startSession` carries one call and not a
    /// condition of its own. Without the cache the "Object Lock…" row and the
    /// two file actions are live and open nothing, which is the failure the
    /// connection menu's guards exist to rule out.
    @MainActor
    static func objectLockStates(for fileSystem: Any) -> ObjectLockStateCache? {
        (fileSystem as? any S3BucketSettings).map(ObjectLockStateCache.init(settings:))
    }
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
    /// The session slot, and the one place a `BrowserSession` can be put on
    /// this tab. `let`, so the slot itself cannot be swapped out.
    ///
    /// Its `session` is `private(set)` inside `SessionInstallation.swift`,
    /// which is what makes `installSession(_:over:kind:)` below the only
    /// install: a write from here, or from anywhere else in the App layer,
    /// does not compile. See that type's doc comment for why the boundary is
    /// a file and what it does not cover.
    ///
    /// **`private`, which is the second half of that boundary, and it was
    /// measured.** The property on the slot was already unwritable from
    /// outside `SessionInstallation.swift`; the SLOT was internal, so the
    /// type's own internal members — `install(_:over:kind:)`, `clear()`,
    /// `cancelPermissionProbe()` and the four field setters — could be called
    /// from any file in the App target, which is half of the operation the
    /// slot's own doc comment says no caller can take half of. Two one-line
    /// plants in `ContentView.startSession`, each with the sanctioned
    /// `tab.installSession(built, over: fs, kind: form.kind)` left PRESENT and
    /// byte-identical inside a never-taken `if`, were GREEN against 162 tests
    /// before this word: `tab.installation.install(built, over:
    /// LocalFileSystem(), kind: .ssh)` put a session on the tab while asking
    /// a connection it is not over, and `tab.installation.clear()` took one
    /// off with `TabTeardown`'s `tab.clearSession()` untouched. With
    /// `private` both are refused by the compiler at the plant's own line
    /// (`'installation' is inaccessible due to 'private' protection level`),
    /// and the cost is nothing: the only use of this property from outside
    /// the type's own members is in this same file, and it is
    /// `checksumLedgerBinding(for:)`'s `self.installation.setChecksums(…)`.
    ///
    /// The command that says so, and the reason it is spelled as an ABSENCE
    /// rather than as a count. Run from the repository root:
    ///
    ///     /usr/bin/grep -rno '\.installation\b' Sources Tests | /usr/bin/grep -v 'SessionTab.swift'
    ///
    /// prints nothing and exits 1 — no file but this one reaches the
    /// property. The control that says the pattern can match at all is
    /// `/usr/bin/grep -o '\.installation\b' <<< 'x.installation.y' | wc -l`,
    /// which prints 1. A TOTAL for that pattern is deliberately not written
    /// here: the fix round that added this word first wrote one, and the
    /// figure was false by the time the paragraph stating it was finished,
    /// because this comment quotes both plants and the command itself.
    /// Classified per match rather than per line, every match outside the
    /// one named above is prose. CLAUDE.md's third point under "A number
    /// travels with the command that produced it", arriving inside the
    /// sentence that cites it.
    ///
    /// A legitimate cross-file use would get a named method on `SessionTab`
    /// that forwards, the way `installSession`, `clearSession`,
    /// `cancelPermissionProbe` and `attachBucketCaches` already do — never a
    /// widened scan, and never `internal` again.
    private let installation = SessionInstallation()
    /// This tab's session, read-only from here. Installed through
    /// `installSession(_:over:kind:)`, released through `clearSession()`, and
    /// changed one field at a time through the named setters on
    /// `SessionInstallation` that `showsFiles`, `checksumLedgerBinding(for:)`
    /// and `attachBucketCaches(objectLockStates:bucketVersioning:)` forward
    /// to.
    ///
    /// (Withdrawn wording, verbatim: "changed in place through
    /// `changeSession(_:)`." No such member has ever existed in this tree.
    /// `change(_: (inout BrowserSession) -> Void)` was the general mutator
    /// fix round 2 wrote, measured GREEN against a quiet install spelled
    /// `changeSession { $0 = built }`, and withdrew for the four field
    /// setters — and the withdrawal swept the type's own file without
    /// sweeping this one, which forwards to it. The sentence that was left
    /// here pointed the next contributor at the hole that round closed.)
    var session: BrowserSession? { installation.session }
    let transferQueue = TransferQueueViewModel()
    let conflictBridge = ConflictPromptBridge()
    /// The folder comparisons running or finished on this tab's connection
    /// (diff view, Task 7). The tab owns them, not a window: each one walks
    /// the session's own file systems, so it belongs where the connection
    /// does, and `TabTeardown.run(_:reason:)` ends every one of them with
    /// the rest of the tab's work. A comparison window is a view onto one
    /// of these, resolved through the tab; see `Comparison`.
    ///
    /// Only `startComparison(...)` appends to it.
    private(set) var comparisons: [Comparison] = []

    /// How many `TabTeardown.run` calls on this tab have not reached their
    /// end. A counter and not a flag, because two routes into a teardown
    /// (a window close and the quit) can overlap, and the first to finish
    /// must not reopen the tab to comparisons while the other is still
    /// taking the connection down. Written only by `TabTeardown.run`.
    var tearDownsInFlight = 0

    /// Whether a teardown of this tab is running. `tab.session` stays
    /// non-nil until that teardown's last assignment, with several
    /// suspension points before it, so "no session" does not say it.
    var isTearingDown: Bool { tearDownsInFlight > 0 }
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
    /// an ad-hoc one — can never leak into a later, unrelated connect's
    /// audit record. (Corrected: this clause used to read "an ad-hoc one,
    /// which has no audit trail to write it into (see
    /// `attachAuditRecorder`'s own doc comment)". An ad-hoc connect does have
    /// one: `startSession` calls `attachAuditRecorder` for every connect, and
    /// an unsaved one logs under `AdHocAudit.sessionID`, M31. The doc comment
    /// the withdrawn clause cited had been rewritten to say so.) Consumed
    /// (read and reset) by
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
            installation.setShowsFiles(newValue)
        }
    }
    /// Display name while connected (stored session name or "user@host").
    /// The tab strip and the window title read it through
    /// `ContentView.tabTitle(for:)`, where it is the first rule of
    /// `TabTitlePlan.title`; `displayTitle` below reads it directly.
    var titleName: String?
    /// Transient error from a failed "open in editor" attempt (M5e/T4) —
    /// cleared on the next successful open or dismissed via its close button.
    var editErrorMessage: String?
    /// Stored session this tab is connected to (sidebar highlight).
    var activeStoredSessionID: UUID?
    /// The pane visibility this tab was DESCRIBED with, when it came back
    /// from a restored window (Detachable Tabs plan, Task 5) — `nil` for
    /// every tab that was made any other way.
    ///
    /// It has to wait here rather than being applied when the tab is
    /// built, because a restored tab is disconnected: `showsFiles` writes
    /// through to `BrowserSession.showsFiles` and there is no session, and
    /// the terminal half belongs to a `TerminalPanelViewModel` that no
    /// shell is behind. The first moment there is anything to apply it to
    /// is the connect, which reads it through
    /// `WindowRestorationPlan.paneVisibility(override:restored:stored:)`
    /// and clears it there — one use, so a later connect on the same tab
    /// gets the ordinary answer.
    var restoredPaneVisibility: PaneVisibility?
    /// The stored session this tab was pointed at when it came back from a
    /// restored window (Detachable Tabs plan, Task 5 fix round 1) — `nil`
    /// for every tab that was made any other way.
    ///
    /// Per TAB, deliberately, where `ContentView.overviewSessionID` is per
    /// WINDOW. The window-wide one matches where the sidebar is: one
    /// sidebar, one selection. A restored window has N tabs that were each
    /// pointed at a different session, and one window-wide pointer could
    /// only show them all the same overview — so the overview branch in
    /// `ContentView+Detail.swift` reads this FIRST and falls back to the
    /// sidebar's selection.
    ///
    /// An id, not a `StoredSession`, for the same reason
    /// `overviewSessionID` is one: it is resolved against the live list on
    /// every render, so a session deleted or renamed since the description
    /// was written disappears or updates without a second clearing rule.
    ///
    /// Cleared in the two places this tab stops being "a restored pointer
    /// at a session": when it connects (`ContentView.connect(in:stored:
    /// paneVisibility:)`, alongside `restoredPaneVisibility`), and when
    /// the sidebar reports a new selection, which is the user pointing
    /// this window's front tab somewhere else.
    var restoredSessionID: UUID?
    /// Per-session audit recorder (M9b) — set when this tab connects, to the
    /// stored session's log or, for an unsaved connection, to the fixed ad-hoc
    /// log (`AdHocAudit`, M31); nilled in `teardown(_:)` after the final
    /// `recordDisconnected()` call, and when the sidebar deletes the stored
    /// session under an open tab (`ContentView+Detail.swift`). See
    /// `ContentView.attachAuditRecorder`.
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

    /// This tab's "transfer failed" notification state (next build of
    /// 2026-09-17, Task 7; a latch since fix round 1): the failures it has
    /// answered for, and whether a posted notification is still unseen —
    /// see `ErrorNotificationPlan.TransferFailureLatch` and
    /// `ContentView.notifyTransferFailures()`. On the tab rather than on a
    /// window, so a tab that moves to another window does not notify again
    /// about failures it already had.
    var transferFailureLatch = ErrorNotificationPlan.TransferFailureLatch()

    var isConnected: Bool { session != nil }

    /// The task asking this tab's connection whether it will take a
    /// permission change, started by `installSession(_:over:kind:)`. Kept so
    /// a test can await it, so a second install can cancel the first, and so
    /// `TabTeardown.run(_:reason:)` can cancel it; not observable state.
    ///
    /// Owned by teardown since fix round 2 of Task 8 (Ruling T8.9). This said
    /// here that it was "not owned by teardown (it ends when the question is
    /// answered, and its write is refused for any session but the one it was
    /// asked about)", and both halves of that parenthesis are still true —
    /// but they are about the WRITE, and the re-review measured the DIAL. See
    /// `SessionInstallation.cancelPermissionProbe()`.
    var permissionProbe: Task<Void, Never>? { installation.permissionProbe }

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
    ///   unconditionally, for its five other callers (`disconnectToForm`,
    ///   `performClose`, `performCloseOthers`, the reconnect-in-place branch
    ///   of `connect(in:stored:)`, and Cancel's `onCancel` in
    ///   `ContentView+Detail.swift`; recounted at the tab-context-menu
    ///   plan's final review) — every one of them is a deliberate "leave
    ///   this connection", with nothing left for a stale dot to describe.
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

    /// Why the last liveness probe on this tab's current session failed, or
    /// `nil` when it came back alive or none has failed yet (lost-connection
    /// cause, 2026-09-19).
    ///
    /// Two writers: `LivenessProbeStep.perform` writes each probe's answer
    /// here, under the same guard as its `liveness` write, and
    /// `ContentView.startSession` clears it for a fresh session.
    /// `ContentView.handleLivenessGiveUp(_:)` reads it — the probe that
    /// failed last is the one the give-up follows — into its log line and
    /// into `LostConnection.probeFailure`.
    var lastProbeFailure: LivenessProbeFailure?

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

    /// This tab's failed connect ATTEMPT (failed-connect surface plan,
    /// Task 3) — the sibling of `lostConnection` above, and deliberately a
    /// separate value rather than a fifth `ConnectionLiveness` case: a
    /// connection that never existed is a different thing from one that
    /// dropped, and the tab-strip dot reads `liveness` for a tab that has
    /// no connection either way.
    ///
    /// Three writers, counted while writing this sentence:
    /// - `ConnectAttemptLivenessMirror` SETS it, from
    ///   `ConnectAttemptLivenessPlan.write`'s `.failedConnect` answer, and
    ///   clears it on `.connecting` (a new attempt speaks for the tab now)
    ///   and on `.clear`.
    /// - `ContentView.dismissConnectFailure(_:)` clears it — the way off
    ///   this surface back to the form, from the surface's own Edit control
    ///   and from the sidebar commands that fill the form.
    /// - `ContentView.teardown(_:reason:)` clears it, for the same reason
    ///   it clears `liveness` and `lostConnection`: every caller of that
    ///   function is leaving this connection on purpose.
    ///
    /// The third one was missing until review round 1, and the sentence
    /// that stood here is why. It argued that `teardown(_:)` cannot matter
    /// because "a tab whose session is being torn down HAD a session, so
    /// its next failure is a `lostConnection`, not this" — true of the
    /// tab's next failure, and irrelevant to the one already on record.
    /// `performClose` tears a tab down and, on the LAST tab, does not
    /// remove it; the failed-connect surface therefore survived its own
    /// Close button, measured, while the window shrank around it. A
    /// premise that is true about the future and silently read as a claim
    /// about the present is the shape of that mistake.
    ///
    /// `ContentView.newConnection()` and `formTarget()` reach it only
    /// THROUGH `dismissConnectFailure(_:)`, which is why they are not a
    /// fourth and fifth writer.
    var connectFailure: ConnectFailure?

    /// One snippet this tab is to run as soon as it has a session and a
    /// shell (session overview plan, Task 3).
    ///
    /// The overview's Run has to do three things in order — connect, wait
    /// for the terminal, send — and only the first is synchronous. This is
    /// the hand-off between them: `ContentView.runSnippetAfterConnecting`
    /// writes it, `ContentView.deliverPendingSnippetRun(on:)` reads and
    /// clears it. It lives on the TAB rather than on the window, for the
    /// same reason `reconnectAttempt` does: the connect it belongs to is one
    /// tab's, and a window-wide value would fire against whichever tab
    /// happened to reach a shell first.
    ///
    /// It carries the stored session it was armed for, so a tab that ends up
    /// connected to something else drops it instead of running a command
    /// against a host the user did not pick.
    struct PendingSnippetRun: Equatable {
        let snippet: Snippet
        let storedSessionID: UUID
    }

    /// Three writers, RECOUNTED in fix round 1 (there were four, and
    /// `jumpToOpenSession`'s clear went away with the reason for it — a
    /// snippet asked for while the already-open query is up rides on the
    /// REQUEST until an answer, so no tab holds one to clear):
    /// - `ContentView.startWithoutAsking(_:paneVisibility:pendingSnippet:
    ///   createsBucket:)` SETS it, on the tab the tab rule just picked, and
    ///   only when that tab is not already dialling.
    /// - `ContentView.deliverPendingSnippetRun(on:)` clears it — before the
    ///   send, so a repeated observation cannot repeat the command, and on
    ///   every outcome that is not a send (no session, another session, a
    ///   shell that will not open).
    /// - `ContentView.teardown(_:reason:)` clears it, for the same reason it
    ///   clears `liveness`, `lostConnection` and `connectFailure`: every
    ///   caller of that function is leaving this connection on purpose.
    var pendingSnippetRun: PendingSnippetRun?

    /// A request for the create-bucket sheet, made by the connection
    /// manager's "Connect and Create Bucket…" entry (S3 metadata plan, Task 6;
    /// spec 6.6): "open this sheet on this tab once it is connected and
    /// showing its bucket list". `nil` for every tab that was not opened for
    /// that, which is every tab but the one such a start picked.
    ///
    /// It lives on the TAB, for the reason `pendingSnippetRun` does: the
    /// connect it belongs to is one tab's, and a window-wide value would open
    /// the sheet over whichever tab happened to finish first. It carries the
    /// stored session it was armed for, so a tab that ends up connected to
    /// something else drops it rather than offer to create a bucket in an
    /// account the user did not pick.
    ///
    /// Three writers:
    /// - `ContentView.startWithoutAsking(_:paneVisibility:pendingSnippet:
    ///   createsBucket:)` SETS it, on the tab the tab rule just picked, and
    ///   only when that tab is not already dialling.
    /// - `ContentView.deliverPendingCreateBucket(on:)` clears it -- before the
    ///   hand-off, so a repeated observation cannot open a second sheet, and
    ///   on every outcome that is not a hand-off (no session, another
    ///   session, a bucket list that failed to load).
    /// - `TabTeardown.run(_:reason:)` clears it, because every route into the
    ///   teardown is leaving this connection on purpose.
    var pendingCreateBucket: PendingCreateBucket?

    struct PendingCreateBucket: Equatable {
        let storedSessionID: UUID
    }

    /// "Connected or not": the connected name, or "New Connection". The
    /// tab strip and the window title no longer read this — they draw
    /// `ContentView.tabTitle(for:)`, which also names a tab that is
    /// dialing, editing or showing a session's overview. It stays for the
    /// seven reads outside those two, counted 2026-09-18: four with no
    /// window state to hand that plan (`MenuBarController`'s two, the
    /// status menu's item title and attributed title; `CrossSessionTargets
    /// .targets`; the audit sink in `ContentView.attachAuditRecorder`,
    /// which resolves through `TabRegistry` and captures nothing of the
    /// window), two that only ever see a connected tab (the terminal panel
    /// header, `ContentView.saveAsSession(from:)`), and
    /// `ContentView.showDiagnostics(for:)`'s `.tab` case, which can see an
    /// unconnected one. Rendered through `TabTitle`, so the fallback is
    /// spelled once.
    var displayTitle: String {
        (titleName.map(TabTitle.named) ?? .newConnection).tabLabel
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

    /// Which of the session's two file systems a comparison side reads.
    /// The caller names a side of THIS tab's session and never hands in a
    /// file system, so a comparison cannot be pointed at a connection the
    /// tab does not own.
    enum ComparisonSide {
        case local
        case remote
    }

    /// Creates a comparison over two sides of this tab's session, keeps it in
    /// `comparisons` and starts its walk. `nil` when the tab has no session:
    /// with nothing connected there is nothing to walk, and `TabTeardown`
    /// ends comparisons together with the session they ran over.
    ///
    /// Also `nil` while a teardown of this tab is running. `endComparisons()`
    /// runs early in that teardown and the connection is closed several
    /// suspension points later, so a comparison started in between would
    /// walk a connection being closed and sit in `comparisons` with nobody
    /// left to end it. The refusal states the rule once, where a second
    /// `endComparisons()` at the end would be a cleanup that happens to work.
    ///
    /// `kind` is handed straight to `Comparison.init` and decides nothing
    /// here: two folders to walk, or two files the user picked. It is
    /// defaulted to `.folders`, which is what every caller that predates the
    /// file pair asked for — and without it no `.filePair` could ever be
    /// created, since this is the App's only construction of a `Comparison`.
    @discardableResult
    func startComparison(
        left: ComparisonSide, leftRoot: String,
        right: ComparisonSide, rightRoot: String,
        algorithm: ChecksumAlgorithm,
        kind: Comparison.Kind = .folders,
        leftVersion: Comparison.VersionRef? = nil
    ) -> Comparison? {
        guard let session, !isTearingDown else { return nil }
        // A version on the left is resolved against THIS session's remote
        // side, through the version capability; a request carries the ids and
        // never a connection. A session whose remote has no such capability
        // starts nothing.
        var versionSide: Comparison.VersionSide?
        if let leftVersion {
            guard let source = session.remoteFS as? any ObjectVersionProvider else { return nil }
            versionSide = Comparison.VersionSide(reference: leftVersion, source: source)
        }
        func system(_ side: ComparisonSide) -> any RemoteFileSystem {
            switch side {
            case .local: session.localFS
            case .remote: session.remoteFS
            }
        }
        let comparison = Comparison(
            left: system(left), leftRoot: leftRoot,
            right: system(right), rightRoot: rightRoot,
            algorithm: algorithm,
            transferQueue: transferQueue,
            kind: kind,
            versionSide: versionSide)
        comparisons.append(comparison)
        comparison.start()
        return comparison
    }

    /// How a window finds the comparison its seed names.
    func comparison(id: UUID) -> Comparison? {
        comparisons.first { $0.id == id }
    }

    /// Stops listing one comparison, and does nothing else to it: no cancel,
    /// no release. The caller is the window that showed it, closing, and it
    /// has already done both (`ComparisonWindowModel.windowClosed()`);
    /// `endComparisons()` is the call that ends comparisons.
    ///
    /// Why the tab forgets at all: a comparison the user closed is finished
    /// business. Left in `comparisons`, cancelled and released, it would let
    /// a window opened later from the same seed find it and say "session
    /// closed" about a session that is open. Forgotten, such a seed resolves
    /// to nothing, which is true: that comparison was closed.
    func forgetComparison(id: UUID) {
        comparisons.removeAll { $0.id == id }
    }

    /// Cancels every comparison, releases its file systems and forgets it.
    /// Called by `TabTeardown` and by nothing else; see the call there.
    ///
    /// What is forgotten is the tab's reference. A window that already holds
    /// a comparison keeps its rows, progress and outcome; it no longer has a
    /// connection to fetch with (`Comparison.releaseFileSystems()`).
    func endComparisons() {
        for comparison in comparisons {
            comparison.cancel()
            comparison.releaseFileSystems()
        }
        comparisons.removeAll()
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

    /// Applies a click on the Files toggle: flips `showsFiles` through
    /// `effectivePaneVisibility(...).applyingClick`, which folds in the
    /// same lock and `hasShell` rule `paneToggleState` reads above, so a
    /// click that would otherwise empty the window is a no-op inside the
    /// model itself, not a check reimplemented here.
    ///
    /// Called by the Files toolbar button and by the tab context menu's
    /// `.pane(.files, _)` entry (`ContentView.togglePane`); neither of them
    /// re-derives the lock.
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
    func applyFilesToggleClick(terminalIsVisible: Bool, hasShell: Bool) {
        let next = effectivePaneVisibility(terminalIsVisible: terminalIsVisible, hasShell: hasShell)
            .applyingClick(on: .files, hasShell: hasShell)
        showsFiles = next.showsFiles
    }
}

extension SessionTab {
    /// A write path to one side's checksum ledger, naming the session it
    /// belongs to at the moment it is made (re-review N2).
    ///
    /// The naming is the whole point. A digest arrives long after it was
    /// asked for — that is what a hash of a large file over a connection
    /// is — and the surfaces that ask do not stop when the pane goes away:
    /// the info sheet's compute runs in an unstructured task nothing
    /// cancels, and a row of a run that is already awaiting still finishes.
    /// A write that resolved `session` at the moment it lands would
    /// therefore drop a digest of the OLD connection's bytes into the ledger
    /// of whatever session happens to be current, i.e. into the new one
    /// after a reconnect — and two hosts can easily hold a file at the same
    /// path with the same size and the same whole-second timestamp.
    ///
    /// So both halves compare `id` first: a stale binding writes nothing,
    /// and reads as empty rather than as the new connection's values. This
    /// is the same defence, for the same reason, that the liveness probe
    /// already applies to its own in-flight answers.
    ///
    /// It exists as a named method rather than as two closure literals at
    /// the call sites so that "the pane's ledger comes from a session" is a
    /// property a test can hold — and does, in `SessionTabTests` — instead
    /// of a shape someone has to re-read a view body to check.
    func checksumLedgerBinding(
        for side: BrowserPaneSide, in session: BrowserSession
    ) -> Binding<ChecksumLedger> {
        let sessionID = session.id
        return Binding(
            get: { [weak self] in
                guard let current = self?.session, current.id == sessionID else {
                    return ChecksumLedger()
                }
                switch side {
                case .local: return current.localChecksums
                case .remote: return current.remoteChecksums
                }
            },
            set: { [weak self] newValue in
                guard let self, self.session?.id == sessionID else { return }
                self.installation.setChecksums(newValue, for: side)
            })
    }

    /// Installs `built` as this tab's session and asks its connection whether
    /// it will take a permission change (Ruling T7.1 of the FTP plan).
    ///
    /// **The one way a connect installs a session, so that the asking cannot
    /// be left out.** It used to be a `Task` written beside the assignment in
    /// `ContentView.startSession`, held by substring scans; a plant that wrapped
    /// the task in a condition that is never true left both scanned strings in
    /// place and was GREEN against the whole suite (Task 8 review, finding 3).
    /// A scan cannot see whether a statement is reached. Here the install and
    /// the ask are one function a test drives, and the plant is RED.
    ///
    /// The probe is started, not awaited: a server that answers `SITE HELP`
    /// slowly must not hold the browser back, and until the answer lands the
    /// editor is offered as it always was. The handle is kept so a test can
    /// await it, and so a second install can cancel the first's wait; the
    /// answer is written only to the session it was asked about
    /// (`recordPermissionEditing`), which is what makes a late first answer
    /// harmless to the second session.
    func installSession(
        _ built: BrowserSession, over fileSystem: any RemoteFileSystem, kind: ConnectionKind
    ) {
        installation.install(built, over: fileSystem, kind: kind)
    }

    /// Cancels the permission probe without releasing the session.
    ///
    /// `TabTeardown.run(_:reason:)`'s own cancel, beside the three other
    /// activities of the same shape it ends there and before the stage that
    /// closes the connection. Synchronous, and awaits nothing. See
    /// `SessionInstallation.cancelPermissionProbe()` for what a probe that
    /// outlives the connection does.
    func cancelPermissionProbe() {
        installation.cancelPermissionProbe()
    }

    /// Releases this tab's session, and the permission probe with it.
    ///
    /// The named clear path, in place of the `tab.session = nil` that
    /// `TabTeardown.run(_:reason:)` used to write: the property is no longer
    /// writable from outside `SessionInstallation.swift`, and an exemption
    /// for one writer would have been the hole this round closed.
    func clearSession() {
        installation.clear()
    }

    /// The two bucket caches `ContentView.startSession` attaches right after
    /// the install (`BrowserSession.objectLockStates`, `.bucketVersioning`).
    ///
    /// Named pass-throughs rather than a general mutator, for the reason
    /// `SessionInstallation`'s own "per-field writes" comment measured: a
    /// mutator taking `inout BrowserSession` is a second way to install one.
    func attachBucketCaches(
        objectLockStates: ObjectLockStateCache?, bucketVersioning: BucketVersioningCache?
    ) {
        installation.setObjectLockStates(objectLockStates)
        installation.setBucketVersioning(bucketVersioning)
    }

    /// Asks the connection whether it will take a permission change, and
    /// records the answer on the session it was asked for (Ruling T7.1 of the
    /// FTP plan).
    ///
    /// The question is `PermissionsAvailability.isOffered(for:on:)`: the
    /// capability first, then the connection's own probe where it has one --
    /// for FTP, whether the server has `SITE CHMOD`. It is asked once, as
    /// the session starts, and the answer lands on
    /// `BrowserSession.permissionEditing`, where the synchronous view body
    /// can read it.
    ///
    /// **The write is refused unless the session is still the one that was
    /// asked about.** The probe may be a round trip, and a tab can be torn
    /// down and reconnected inside it; an answer about the old connection
    /// written onto the new one would hide, or offer, an editor on a server
    /// the question was never put to. `id` is compared, as
    /// `checksumLedgerBinding` compares it, for the same reason.
    ///
    /// Not awaited by the connect: a server that answers `SITE HELP` slowly
    /// must not hold the browser back, and until the answer arrives the
    /// editor is offered as it always was.
    func recordPermissionEditing(
        of fileSystem: any RemoteFileSystem, kind: ConnectionKind, forSession sessionID: UUID
    ) async {
        await installation.recordPermissionEditing(
            of: fileSystem, kind: kind, forSession: sessionID)
    }
}
