import SwiftUI
import macSCPCore

/// App-wide bridge that feeds the menu-bar status item (M11n). It holds NO
/// connection state of its own — `ContentView` mirrors its `tabsModel.tabs`
/// into `tabs` and sets the window-raising closures, exactly like
/// `TabCommands`. The panel and label read the (`@Observable`) `SessionTab`
/// members directly, so SwiftUI updates them live during transfers without a
/// timer.
@MainActor
@Observable
final class MenuBarStatusModel {
    /// Snapshot of the window's tabs, kept in sync by `ContentView`.
    var tabs: [SessionTab] = []
    /// Raise the main window and activate the tab with this id.
    var focusTab: (UUID) -> Void = { _ in }
    /// Raise the main window without forcing a specific tab.
    var showMainWindow: () -> Void = {}

    /// True while any tab is actively transferring — drives the label's
    /// idle/active icon.
    var anyTransferActive: Bool {
        tabs.contains { ($0.transferQueue.activitySummary?.runningCount ?? 0) > 0 }
    }

    /// Number of currently connected tabs — the panel header counter.
    var connectedCount: Int {
        tabs.filter(\.isConnected).count
    }
}
