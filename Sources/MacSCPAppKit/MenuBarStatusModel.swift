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
    /// Snapshot of the KEY window's tabs, kept in sync by `ContentView`
    /// through `publish(tabs:from:focusTab:showMainWindow:)`.
    private(set) var tabs: [SessionTab] = []
    /// Raise that window and activate the tab with this id.
    private(set) var focusTab: (UUID) -> Void = { _ in }
    /// Raise that window without forcing a specific tab.
    private(set) var showMainWindow: () -> Void = {}
    /// Which window published what is showing right now, so a DIFFERENT
    /// window closing cannot wipe it (Detachable Tabs plan, Task 2 fix
    /// round 2). `nil` before anything has been published, and again after
    /// the publishing window has closed.
    private(set) var publishingWindow: WindowID?

    /// Replaces everything the status item shows, and records which window
    /// it came from.
    ///
    /// One call rather than four assignments because the four values are
    /// one answer: the tabs, the two ways to raise the window they belong
    /// to, and the window itself. Setting the list from one window and the
    /// closures from another is a state this app has no use for, and making
    /// it unrepresentable costs nothing.
    func publish(
        tabs: [SessionTab], from window: WindowID,
        focusTab: @escaping (UUID) -> Void, showMainWindow: @escaping () -> Void
    ) {
        self.tabs = tabs
        self.focusTab = focusTab
        self.showMainWindow = showMainWindow
        publishingWindow = window
    }

    /// Empties the status item if `window` is the one that filled it, and
    /// leaves it alone otherwise.
    ///
    /// Called from every window's close path. Clearing is right even though
    /// another window may still be open: whichever window becomes key next
    /// publishes its own tabs from `ContentView.publishToMenuBarIfKey()`,
    /// and an empty item for that moment is honest, while a list of a
    /// closed window's tabs — with closures that would try to raise it — is
    /// not.
    func clearIfPublished(by window: WindowID) {
        guard publishingWindow == window else { return }
        tabs = []
        focusTab = { _ in }
        showMainWindow = {}
        publishingWindow = nil
    }

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
