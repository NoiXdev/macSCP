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
    /// Display name while connected (stored session name or "user@host") —
    /// drives the window title of the ACTIVE tab and the tab's own label.
    var titleName: String?
    /// Transient error from a failed "open in editor" attempt (M5e/T4) —
    /// cleared on the next successful open or dismissed via its close button.
    var editErrorMessage: String?
    /// Stored session this tab is connected to (sidebar highlight).
    var activeStoredSessionID: UUID?
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
        limiter: BandwidthLimiter,
        maxConcurrent: Int
    ) {
        self.connectionViewModel = connectionViewModel
        transferQueue.limiter = limiter
        transferQueue.maxConcurrent = maxConcurrent
        let bridge = conflictBridge
        transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }
    }
}
