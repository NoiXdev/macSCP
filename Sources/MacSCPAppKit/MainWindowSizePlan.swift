import Foundation

/// Every decision about the main window's size across a disconnect, a
/// connect and a relaunch (next build of 2026-09-17, Task 3). `ContentView`
/// executes the answers against its `NSWindow` in `growToBrowserSize()`,
/// `shrinkIfPristine()`, `applyFrameAutosave(to:)`,
/// `applyFrameAutosaveKeepingItsDisplay(to:)` and
/// `handleWindowDidEndLiveResize(_:)` — five functions, counted in the pass
/// that writes this; nothing here touches a window, so every answer is a
/// value `MainWindowSizePlanTests` can check. A decision left inline in
/// `ContentView` instead is a decision nothing measures: the launch-time
/// gate `restoresAtLaunch(nameBefore:nameNow:)` spent one commit there, and
/// deleting it left the whole suite green (review round 1).
///
/// **What went wrong before**, read from the code (not reproduced in a
/// running app): the primary window's frame autosave name stays set for its
/// whole life, and AppKit writes a named window's frame to the user
/// defaults whenever it moves or resizes. A disconnect that left one
/// unconnected tab shrank the window to the form size, so that shrink was
/// the frame the autosave kept, and the size the window had been used at
/// lived only in `ContentView.lastBrowserSize`, in-memory `@State`. A
/// relaunch therefore opened at the form size, and a connect grew it to the
/// floor rather than to the size it had been used at.
///
/// **The fix, in two halves.**
/// 1. The autosave is suspended for the shrink (the name is set to the
///    empty string before the window is resized) and resumed by the next
///    connect of that window, which saves the grown frame under the name
///    first and puts the frame back if setting the name moved the window.
///    So the autosave only ever holds a frame the window had while it was
///    not shrunk to the form.
/// 2. The browser size is persisted in `SettingsStore.mainWindowBrowserSize`
///    — at the shrink, and whenever the user finishes dragging the connected
///    window's edge, never in full screen — and a connect of the primary window grows to it. That
///    covers the launch that did not come back at the autosaved frame, and
///    it is the size the in-memory value used to be for one run only.
///
/// Primary window only. A window opened by a move has no autosave name (see
/// `applyFrameAutosave(to:)`) and keeps its remembered size in memory, as
/// every window did before.
enum MainWindowSizePlan {
    /// The compact size a window with one unconnected tab shrinks to. Its
    /// width is also that window's minimum width, and its height every
    /// window's minimum height (`ContentView.windowChrome(_:)`).
    static let formSize = CGSize(width: 700, height: 460)

    /// The smallest size a connect grows a window to, whatever was
    /// remembered. Its width is also the minimum width of a window that is
    /// not in the one-unconnected-tab state.
    static let browserFloor = CGSize(width: 930, height: 620)

    /// The browser size a connect grows toward. The primary window prefers
    /// the persisted size, which is at least as recent as the in-memory one:
    /// both are written by the same shrink, and only the persisted one is
    /// also written by a drag and survives a relaunch.
    static func rememberedBrowserSize(
        isPrimaryWindow: Bool, inMemory: CGSize?, persisted: CGSize?
    ) -> CGSize? {
        guard isPrimaryWindow else { return inMemory }
        return persisted ?? inMemory
    }

    /// The size a connect resizes the window to, or `nil` to leave it.
    ///
    /// Gated on the window's GEOMETRY, not on tab connectivity (M8a/T3
    /// review): a second form tab plus a manually resized window must not
    /// let a later connect yank the window back down. The target is at least
    /// `browserFloor`, and never smaller than the current frame in either
    /// dimension, so a connect only ever grows the window.
    static func connectGrowth(current: CGSize, remembered: CGSize?) -> CGSize? {
        let target = CGSize(
            width: max(remembered?.width ?? 0, browserFloor.width),
            height: max(remembered?.height ?? 0, browserFloor.height))
        guard current.width < target.width || current.height < target.height else { return nil }
        return CGSize(
            width: max(target.width, current.width), height: max(target.height, current.height))
    }

    /// What a shrink to `formSize` does, or `nil` for no shrink.
    struct Shrink: Equatable {
        /// The size the window had, kept in memory as `lastBrowserSize`.
        let browserSize: CGSize
        /// Whether `browserSize` is also written to
        /// `SettingsStore.mainWindowBrowserSize`.
        let persistsBrowserSize: Bool
        /// Whether the frame autosave is (or stays) suspended before the
        /// resize, so the form size is not written as the window's frame.
        let suspendsFrameAutosave: Bool
    }

    /// Only a window left with a single unconnected tab shrinks, and only
    /// when it is larger than the form in some dimension (M8a/T3).
    ///
    /// An already-suspended primary window was already shrunk once and not
    /// connected since, so what it measures now is a form window the user
    /// dragged larger — not a browser size, and not persisted. Nor is a
    /// size measured in full screen (fix round 1): that is the screen's
    /// size, not one the user chose for the window.
    static func shrink(
        current: CGSize, isPristine: Bool, isPrimaryWindow: Bool, isFullScreen: Bool,
        frameAutosaveSuspended: Bool
    ) -> Shrink? {
        guard isPristine, current.width > formSize.width || current.height > formSize.height
        else { return nil }
        return Shrink(
            browserSize: current,
            persistsBrowserSize: isPrimaryWindow && !frameAutosaveSuspended && !isFullScreen,
            suspendsFrameAutosave: isPrimaryWindow)
    }

    /// Whether a connect resumes the primary window's frame autosave.
    static func resumesFrameAutosave(isPrimaryWindow: Bool, frameAutosaveSuspended: Bool) -> Bool {
        isPrimaryWindow && frameAutosaveSuspended
    }

    /// The autosave name the primary window carries: its own, or the empty
    /// string while suspended — which is how AppKit is told a window has no
    /// autosave name.
    static func frameAutosaveName(frameAutosaveSuspended: Bool, primaryName: String) -> String {
        frameAutosaveSuspended ? "" : primaryName
    }

    /// Whether the size a user finished dragging the window to is persisted:
    /// the primary window, its active tab showing a connected browser, not
    /// in full screen, with its autosave writing.
    ///
    /// "Connected", not "not pristine" (fix round 1): two unconnected form
    /// tabs are not pristine either, and a drag there measures a form
    /// window. It is the fact the grow path answers to — a connect is what
    /// grows the window. Full screen is excluded because a Split View
    /// divider drag can end a live resize at a size the screen chose.
    static func persistsLiveResize(
        isPrimaryWindow: Bool, isActiveTabConnected: Bool, isFullScreen: Bool,
        frameAutosaveSuspended: Bool
    ) -> Bool {
        isPrimaryWindow && isActiveTabConnected && !isFullScreen && !frameAutosaveSuspended
    }

    /// The frame to put the window back at after its autosave name was set
    /// again, or `nil` when setting it left the window where it was.
    ///
    /// Measured by the Task 3 reviewer: setting a name that has a frame
    /// stored under it applies that frame at once, placed relative to
    /// `NSScreen.main` rather than the window's own screen — a window on the
    /// built-in display jumped to the external one. Saving the frame first
    /// keeps the SIZE; only putting the frame back keeps the DISPLAY.
    static func frameToRestore(beforeResume: CGRect, afterResume: CGRect) -> CGRect? {
        beforeResume == afterResume ? nil : beforeResume
    }

    /// The user defaults key AppKit keeps a named window's frame under —
    /// the key `ContentView.resizeWindow(toWidth:height:)`'s doc comment
    /// already names for `macSCP.primary`.
    ///
    /// Reading the defaults is the only way to learn the stored frame
    /// WITHOUT applying it: `NSWindow` offers `setFrameUsingName(_:)` and
    /// `setFrameAutosaveName(_:)`, both of which move the window, and no
    /// getter.
    static func frameDefaultsKey(autosaveName: String) -> String {
        "NSWindow Frame \(autosaveName)"
    }

    /// The window frame in one of AppKit's autosave descriptors, or `nil`
    /// when there is none to read.
    ///
    /// The descriptor is `"x y w h sx sy sw sh"`: the window's frame
    /// followed by the frame the screen had when it was saved. Only the
    /// first four are read — which display the frame belongs to is answered
    /// in `launchFrameToRestore` against the screens attached NOW, not
    /// against the one recorded then, because a display's coordinates move
    /// when the arrangement changes.
    ///
    /// A descriptor with a token that is not a number is refused rather
    /// than parsed past: skipping the token would read the next number as
    /// this field and place the window somewhere nobody chose.
    static func storedFrame(descriptor: String?) -> CGRect? {
        guard let descriptor else { return nil }
        let tokens = descriptor.split(whereSeparator: \.isWhitespace)
        let numbers = tokens.compactMap { Double($0) }
        guard numbers.count == tokens.count, numbers.count >= 4 else { return nil }
        guard numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Whether setting the autosave name just now can have applied a stored
    /// frame — i.e. whether `launchFrameToRestore` below has anything to
    /// decide about.
    ///
    /// AppKit applies the stored frame when a window is given a NON-EMPTY
    /// autosave name it did not already carry, and only then. Both halves
    /// are load-bearing, and each was planted on its own against the tree
    /// that had this decision inline (review round 1), with the whole suite
    /// green either way:
    ///
    /// - Without `nameNow != nameBefore` every ordinary body update looks
    ///   like a restore, because `WindowAccessor` calls back on each one.
    ///   A user who drags the primary window then has it snapped back to
    ///   the stored frame on the next repaint.
    /// - Without `!nameNow.isEmpty` the shrink's suspension counts as one,
    ///   and setting the empty name applies no frame at all.
    ///
    /// Four ordered pairs can be asked about, counted in the pass that
    /// writes this: `ContentView.applyFrameAutosave(to:)` sets nothing but
    /// `frameAutosaveName`'s two answers, so each name is the primary one
    /// or the empty string.
    static func restoresAtLaunch(nameBefore: String, nameNow: String) -> Bool {
        nameNow != nameBefore && !nameNow.isEmpty
    }

    /// The frame to put the window back at after its autosave name was set
    /// for the FIRST time — at launch — or `nil` to leave it where AppKit
    /// put it.
    ///
    /// The same AppKit fact as `frameToRestore` above, one resolution
    /// earlier: setting a name that has a frame stored under it applies
    /// that frame placed relative to `NSScreen.main`, so a launch while
    /// another app holds focus on the other display opens the window there.
    /// `frameToRestore` can hand back the frame the window had a moment
    /// ago; a window that has just been created has only the placeholder
    /// frame AppKit chose for it, which says nothing about where the user
    /// keeps this window. So "its own display" here is the STORED frame's
    /// display, and the frame to put back is the stored frame itself.
    ///
    /// `nil` in the three cases where the stored frame is not the better
    /// answer: nothing is stored (a first launch); AppKit applied the
    /// stored frame unchanged, so the window is already there; and no
    /// attached screen shows any part of the stored frame, which means the
    /// display it was saved on is gone and AppKit's placement is the only
    /// visible one.
    static func launchFrameToRestore(
        stored: CGRect?, applied: CGRect, screens: [CGRect]
    ) -> CGRect? {
        guard let stored, stored != applied else { return nil }
        guard screens.contains(where: { $0.intersects(stored) }) else { return nil }
        return stored
    }
}
