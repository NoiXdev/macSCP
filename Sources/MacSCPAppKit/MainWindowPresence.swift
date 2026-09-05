import Foundation

/// Whether any main window is left for the Settings window's "Manage Data"
/// entries to route into (Detachable Tabs plan, Task 2 fix round 2).
///
/// Those three entries — logins, server certificates, hidden imports —
/// present sheets that belong to a MAIN window, never to the Settings
/// window itself (see `SettingsWindowBridge`). With no main window open
/// they have nowhere to go, so they are greyed rather than left to swallow
/// the click.
///
/// **Why this is a function and not `window != nil`.** It used to be the
/// latter, per window, and every window's close wrote `false` — so closing
/// one window of several greyed those entries while other windows were
/// still open and perfectly able to present the sheets. Presence is a fact
/// about the APP, so it is derived from `TabRegistry.windowCount`, which
/// counts the windows currently holding at least one tab.
///
/// **Why the closing window has to say so.** A window announces its close
/// through `NSWindow.willCloseNotification`, and at that moment it has not
/// released its tabs yet — teardown runs first, asynchronously, and only
/// then does `TabRegistry.release(_:from:)` drop them. So the count still
/// includes the window that is going away, and the window asking has to
/// exclude itself.
enum MainWindowPresence {
    /// `windowCount` is `TabRegistry.windowCount`, read as it stands.
    /// `closingOneOfThem` is true only when the caller is a window on its
    /// way out and is therefore still counted.
    ///
    /// A count of zero with a window claiming to close answers `false`
    /// rather than going negative and reading as something else: it is the
    /// same "no main window" either way, and a subtraction that can wrap
    /// past zero is not a thing to leave in a decision.
    static func remains(windowCount: Int, closingOneOfThem: Bool) -> Bool {
        let remaining = closingOneOfThem ? windowCount - 1 : windowCount
        return remaining > 0
    }
}
