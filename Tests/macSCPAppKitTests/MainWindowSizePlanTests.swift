import Foundation
import MacSCPTestSupport
import Testing
@testable import MacSCPAppKit

/// Guards `MainWindowSizePlan` (next build of 2026-09-17, Task 3: the main
/// window comes back at the size it was used at) and the window-geometry
/// wiring in `ContentView` that executes it.
///
/// The decisions are tested as values. What AppKit does with them is not
/// visible headless, so the "walks" below replay a session against
/// `AutosaveModel`, a stand-in for ONE AppKit fact the fix relies on: while
/// a window has a frame autosave name, every resize of it is written to the
/// user defaults, and while it has none, nothing is. The stand-in is only as
/// good as that fact; whether a relaunch really opens at the stored frame is
/// the maintainer's sight check, not something this suite can see.
///
/// Known blind spot: SOURCE TEXT only for the wiring — nothing here runs a
/// window.
@MainActor
@Suite("MainWindowSizePlan and the main window's size wiring")
struct MainWindowSizePlanTests {
    private static let browser = CGSize(width: 1400, height: 900)
    private static let form = MainWindowSizePlan.formSize
    private static let floor = MainWindowSizePlan.browserFloor

    // MARK: - Which size a connect grows to

    @Test func withoutARememberedSizeAConnectGrowsAFormWindowToTheFloor() {
        #expect(MainWindowSizePlan.connectGrowth(current: Self.form, remembered: nil) == Self.floor)
    }

    @Test func withARememberedSizeAConnectGrowsAFormWindowToIt() {
        #expect(MainWindowSizePlan.connectGrowth(current: Self.form, remembered: Self.browser)
            == Self.browser)
    }

    /// A remembered size below the floor does not make a connected window
    /// smaller than a connected window may be.
    @Test func aRememberedSizeBelowTheFloorGrowsToTheFloorInThatDimension() {
        let narrow = CGSize(width: 800, height: 1000)
        #expect(MainWindowSizePlan.connectGrowth(current: Self.form, remembered: narrow)
            == CGSize(width: Self.floor.width, height: 1000))
    }

    /// A connect only ever grows: a window already at least the target in
    /// both dimensions is left alone, and one larger in one dimension keeps
    /// that dimension.
    @Test func aConnectNeverShrinksTheWindow() {
        #expect(MainWindowSizePlan.connectGrowth(current: Self.browser, remembered: Self.browser) == nil)
        #expect(MainWindowSizePlan.connectGrowth(
            current: CGSize(width: 2000, height: 500), remembered: Self.browser)
            == CGSize(width: 2000, height: 900))
    }

    /// The primary window's remembered size is the persisted one — it is
    /// what survives a relaunch — and the in-memory one only stands in when
    /// nothing was persisted yet.
    @Test func thePrimaryWindowRemembersThePersistedSize() {
        let inMemory = CGSize(width: 1000, height: 700)
        #expect(MainWindowSizePlan.rememberedBrowserSize(
            isPrimaryWindow: true, inMemory: nil, persisted: Self.browser) == Self.browser)
        #expect(MainWindowSizePlan.rememberedBrowserSize(
            isPrimaryWindow: true, inMemory: inMemory, persisted: Self.browser) == Self.browser)
        #expect(MainWindowSizePlan.rememberedBrowserSize(
            isPrimaryWindow: true, inMemory: inMemory, persisted: nil) == inMemory)
    }

    /// A window opened by a move persists nothing and reads nothing
    /// persisted: the persisted size is the primary window's.
    @Test func aSecondaryWindowRemembersOnlyItsOwnSize() {
        let inMemory = CGSize(width: 1000, height: 700)
        #expect(MainWindowSizePlan.rememberedBrowserSize(
            isPrimaryWindow: false, inMemory: nil, persisted: Self.browser) == nil)
        #expect(MainWindowSizePlan.rememberedBrowserSize(
            isPrimaryWindow: false, inMemory: inMemory, persisted: Self.browser) == inMemory)
    }

    // MARK: - What a shrink does

    @Test func onlyAPristineWindowLargerThanTheFormShrinks() {
        #expect(MainWindowSizePlan.shrink(
            current: Self.browser, isPristine: false, isPrimaryWindow: true, isFullScreen: false,
            frameAutosaveSuspended: false) == nil)
        #expect(MainWindowSizePlan.shrink(
            current: Self.form, isPristine: true, isPrimaryWindow: true, isFullScreen: false,
            frameAutosaveSuspended: false) == nil)
    }

    /// The primary window, shrinking from its browser size: the size is
    /// persisted, and the autosave is suspended BEFORE the shrink so the
    /// form size is never written as the window's frame.
    @Test func thePrimaryWindowPersistsItsBrowserSizeAndSuspendsTheAutosave() {
        #expect(MainWindowSizePlan.shrink(
            current: Self.browser, isPristine: true, isPrimaryWindow: true, isFullScreen: false,
            frameAutosaveSuspended: false)
            == .init(browserSize: Self.browser, persistsBrowserSize: true, suspendsFrameAutosave: true))
    }

    /// Already suspended means already shrunk once: what the window is at
    /// now is a form window the user dragged larger, not a browser size, so
    /// it does not replace the persisted one.
    @Test func aSecondShrinkWhileSuspendedPersistsNothing() {
        let draggedForm = CGSize(width: 800, height: 500)
        #expect(MainWindowSizePlan.shrink(
            current: draggedForm, isPristine: true, isPrimaryWindow: true, isFullScreen: false,
            frameAutosaveSuspended: true)
            == .init(browserSize: draggedForm, persistsBrowserSize: false, suspendsFrameAutosave: true))
    }

    @Test func aSecondaryWindowShrinksWithoutPersistingOrSuspending() {
        #expect(MainWindowSizePlan.shrink(
            current: Self.browser, isPristine: true, isPrimaryWindow: false, isFullScreen: false,
            frameAutosaveSuspended: false)
            == .init(browserSize: Self.browser, persistsBrowserSize: false, suspendsFrameAutosave: false))
    }

    // MARK: - The autosave and the live-resize recording

    @Test func theAutosaveNameIsEmptyExactlyWhileSuspended() {
        #expect(MainWindowSizePlan.frameAutosaveName(frameAutosaveSuspended: false, primaryName: "p") == "p")
        #expect(MainWindowSizePlan.frameAutosaveName(frameAutosaveSuspended: true, primaryName: "p") == "")
    }

    @Test func aConnectResumesTheAutosaveOnlyForASuspendedPrimaryWindow() {
        #expect(MainWindowSizePlan.resumesFrameAutosave(isPrimaryWindow: true, frameAutosaveSuspended: true))
        #expect(!MainWindowSizePlan.resumesFrameAutosave(isPrimaryWindow: true, frameAutosaveSuspended: false))
        #expect(!MainWindowSizePlan.resumesFrameAutosave(isPrimaryWindow: false, frameAutosaveSuspended: true))
    }

    /// A drag of the window's edge is the size a user chose — recorded only
    /// for the primary window, only while its active tab shows a connected
    /// browser (fix round 1: not merely "not pristine", which two unconnected
    /// form tabs also are), never in full screen, and only while the autosave
    /// is writing too, so the two never disagree.
    @Test func onlyAConnectedPrimaryWindowWithItsAutosaveOnRecordsALiveResize() {
        #expect(MainWindowSizePlan.persistsLiveResize(
            isPrimaryWindow: true, isActiveTabConnected: true, isFullScreen: false,
            frameAutosaveSuspended: false))
        #expect(!MainWindowSizePlan.persistsLiveResize(
            isPrimaryWindow: true, isActiveTabConnected: false, isFullScreen: false,
            frameAutosaveSuspended: false))
        #expect(!MainWindowSizePlan.persistsLiveResize(
            isPrimaryWindow: true, isActiveTabConnected: true, isFullScreen: false,
            frameAutosaveSuspended: true))
        #expect(!MainWindowSizePlan.persistsLiveResize(
            isPrimaryWindow: false, isActiveTabConnected: true, isFullScreen: false,
            frameAutosaveSuspended: false))
    }

    /// Full screen (fix round 1): a Split View divider drag can end a live
    /// resize, and its size is the screen's, not one the user chose.
    @Test func aLiveResizeInFullScreenIsNotRecorded() {
        #expect(!MainWindowSizePlan.persistsLiveResize(
            isPrimaryWindow: true, isActiveTabConnected: true, isFullScreen: true,
            frameAutosaveSuspended: false))
    }

    /// Full screen (fix round 1): a disconnect there still shrinks the way it
    /// always did, but the full-screen size is not persisted as the browser
    /// size.
    @Test func aShrinkInFullScreenPersistsNothing() {
        #expect(MainWindowSizePlan.shrink(
            current: Self.browser, isPristine: true, isPrimaryWindow: true, isFullScreen: true,
            frameAutosaveSuspended: false)
            == .init(browserSize: Self.browser, persistsBrowserSize: false, suspendsFrameAutosave: true))
    }

    /// Re-setting the autosave name applies the stored frame at once, placed
    /// on `NSScreen.main` rather than on the window's own screen (measured by
    /// the Task 3 reviewer): a window on one display jumped to the other.
    /// The frame the window had before the name was set wins back.
    @Test func aFrameMovedByResumingTheAutosaveIsRestored() {
        let before = CGRect(x: 100, y: 200, width: 1400, height: 900)
        let movedToMain = CGRect(x: 1540, y: 200, width: 1400, height: 900)
        #expect(MainWindowSizePlan.frameToRestore(beforeResume: before, afterResume: movedToMain)
            == before)
        #expect(MainWindowSizePlan.frameToRestore(beforeResume: before, afterResume: before) == nil)
    }

    // MARK: - Walks: what quit stores, what a relaunch connects to

    /// The one AppKit fact, modelled: with a name, every frame change is
    /// written; without one, nothing is. `saveFrame` is
    /// `NSWindow.saveFrame(usingName:)`, which writes regardless.
    private struct AutosaveModel {
        var suspended = false
        var stored: CGSize?
        var frame: CGSize
        var persisted: CGSize?

        mutating func resize(to size: CGSize) {
            frame = size
            if !suspended { stored = size }
        }

        /// What `ContentView.shrinkIfPristine()` does, in its order.
        mutating func disconnectLastTab() {
            guard let shrink = MainWindowSizePlan.shrink(
                current: frame, isPristine: true, isPrimaryWindow: true, isFullScreen: false,
                frameAutosaveSuspended: suspended)
            else { return }
            if shrink.persistsBrowserSize { persisted = shrink.browserSize }
            if shrink.suspendsFrameAutosave { suspended = true }
            resize(to: MainWindowSizePlan.formSize)
        }

        /// What `ContentView.growToBrowserSize()` does, in its order.
        mutating func connect() {
            let remembered = MainWindowSizePlan.rememberedBrowserSize(
                isPrimaryWindow: true, inMemory: nil, persisted: persisted)
            if let grown = MainWindowSizePlan.connectGrowth(current: frame, remembered: remembered) {
                resize(to: grown)
            }
            if MainWindowSizePlan.resumesFrameAutosave(
                isPrimaryWindow: true, frameAutosaveSuspended: suspended) {
                stored = frame
                suspended = false
            }
        }

        /// A drag of the window edge while connected.
        mutating func userResize(to size: CGSize) {
            resize(to: size)
            if MainWindowSizePlan.persistsLiveResize(
                isPrimaryWindow: true, isActiveTabConnected: true, isFullScreen: false,
                frameAutosaveSuspended: suspended) {
                persisted = size
            }
        }
    }

    /// (a) Quit while connected: the autosave holds the browser frame.
    @Test func quitWhileConnectedStoresTheBrowserSize() {
        var window = AutosaveModel(frame: Self.form)
        window.connect()
        window.userResize(to: Self.browser)
        #expect(window.stored == Self.browser)
        #expect(window.persisted == Self.browser)
    }

    /// (b) Quit after a disconnect shrank the window: before the fix the
    /// autosave held 700×460 and nothing held the browser size.
    @Test func quitAfterAShrinkStillStoresTheBrowserSize() {
        var window = AutosaveModel(frame: Self.form)
        window.connect()
        window.userResize(to: Self.browser)
        window.disconnectLastTab()
        #expect(window.frame == Self.form)
        #expect(window.stored == Self.browser)
        #expect(window.persisted == Self.browser)
    }

    /// (c) A connect after a relaunch — started from the form size, the one
    /// case where the stored frame does not already carry the size — grows
    /// to the persisted browser size, not to the floor; and the autosave is
    /// writing again afterwards.
    @Test func aConnectAfterARelaunchGrowsToThePersistedSize() {
        var window = AutosaveModel(frame: Self.form)
        window.connect()
        window.userResize(to: Self.browser)
        window.disconnectLastTab()
        var relaunched = AutosaveModel(frame: Self.form, persisted: window.persisted)
        relaunched.connect()
        #expect(relaunched.frame == Self.browser)
        #expect(relaunched.stored == Self.browser)
    }

    /// A shrink, then a connect in the same run: the autosave comes back on
    /// with the grown frame, so a later drag is written again.
    @Test func aConnectAfterAShrinkResumesTheAutosave() {
        var window = AutosaveModel(frame: Self.form)
        window.connect()
        window.userResize(to: Self.browser)
        window.disconnectLastTab()
        window.connect()
        #expect(!window.suspended)
        let wider = CGSize(width: 1600, height: 900)
        window.userResize(to: wider)
        #expect(window.stored == wider)
        #expect(window.persisted == wider)
    }

    // MARK: - Source guards

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sourceDir = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
    private static let contentViewFile = sourceDir.appendingPathComponent("ContentView.swift")
    private static let lifecycleFile = sourceDir.appendingPathComponent("ContentView+Lifecycle.swift")
    private static let detailFile = sourceDir.appendingPathComponent("ContentView+Detail.swift")

    private static func code(of url: URL) throws -> String {
        try SourceCorpus.code(of: url)
    }

    private static func body(of anchor: String, in url: URL) throws -> String {
        let source = try code(of: url)
        return try #require(TabsWindowLifecycleTests.body(after: anchor, in: source), """
            \(url.lastPathComponent) no longer declares \(anchor) — re-anchor this guard.
            """)
    }

    private static func occurrences(of needle: String) throws -> Int {
        let files = try SourceCorpus.children(of: sourceDir)
        var count = 0
        for file in files where file.pathExtension == "swift" {
            count += try code(of: file).components(separatedBy: needle).count - 1
        }
        return count
    }

    private static func offset(of needle: String, in body: String) -> String.Index? {
        body.range(of: needle)?.lowerBound
    }

    @Test func theConnectPathGrowsThroughThePlan() throws {
        let grow = try Self.body(of: "func growToBrowserSize() {", in: Self.lifecycleFile)
        #expect(grow.contains("MainWindowSizePlan.rememberedBrowserSize("))
        #expect(grow.contains("MainWindowSizePlan.connectGrowth("))
        #expect(grow.contains("MainWindowSizePlan.resumesFrameAutosave("))
        let resize = try #require(Self.offset(of: "resizeWindow(", in: grow))
        let save = try #require(Self.offset(of: "saveFrame(usingName:", in: grow))
        let resume = try #require(Self.offset(of: "applyFrameAutosave(", in: grow))
        #expect(resize < save, "the grown frame must be the one saved before the autosave resumes")
        #expect(save < resume, "the frame is saved before the name is set again")
        // Fix round 1: the frame is captured before the name is set again
        // and put back after it, through the plan, without animation.
        let capture = try #require(Self.offset(of: "= window.frame", in: grow))
        let decide = try #require(Self.offset(of: "MainWindowSizePlan.frameToRestore(", in: grow))
        let restore = try #require(Self.offset(of: "window.setFrame(", in: grow))
        #expect(save < capture && capture < resume,
            "the frame must be captured after the save and before the name is set again")
        #expect(resume < decide && decide < restore,
            "the restore must be decided and applied after the name is set again")
        let contentView = try Self.code(of: Self.contentViewFile)
        #expect(contentView.contains("growToBrowserSize()"),
            "ContentView.swift's connect path no longer calls growToBrowserSize()")
    }

    @Test func theShrinkGoesThroughThePlanAndSuspendsBeforeItResizes() throws {
        let shrink = try Self.body(of: "func shrinkIfPristine() {", in: Self.lifecycleFile)
        #expect(shrink.contains("MainWindowSizePlan.shrink("))
        let persist = try #require(Self.offset(of: "mainWindowBrowserSize = ", in: shrink))
        let suspend = try #require(Self.offset(of: "frameAutosaveSuspended = true", in: shrink))
        let apply = try #require(Self.offset(of: "applyFrameAutosave(", in: shrink))
        let resize = try #require(Self.offset(of: "resizeWindow(", in: shrink))
        #expect(persist < resize)
        #expect(suspend < apply, "the suspension must reach the window before the shrink")
        #expect(apply < resize, "a shrink with the autosave still on writes the form size")
    }

    @Test func theAutosaveNameComesFromThePlan() throws {
        let autosave = try Self.body(
            of: "func applyFrameAutosave(to window: NSWindow?) {", in: Self.lifecycleFile)
        #expect(autosave.contains("MainWindowSizePlan.frameAutosaveName("))
        #expect(autosave.contains("setFrameAutosaveName("))
    }

    @Test func aLiveResizeIsRecordedThroughThePlan() throws {
        let handler = try Self.body(
            of: "func handleWindowDidEndLiveResize(_ notification: Notification) {",
            in: Self.lifecycleFile)
        #expect(handler.contains("MainWindowSizePlan.persistsLiveResize("))
        #expect(handler.contains("mainWindowBrowserSize = "))
        let detail = try Self.code(of: Self.detailFile)
        #expect(detail.contains("NSWindow.didEndLiveResizeNotification"))
        #expect(detail.contains("handleWindowDidEndLiveResize"))
    }

    /// The primary-window property's name, read from its declaration rather
    /// than spelled: `var <name>: Bool { seed == nil }`.
    private static func primaryWindowProperty() throws -> String {
        let source = try code(of: contentViewFile)
        let pattern = try CompiledPattern.regex(#"var (\w+): Bool \{ seed == nil \}"#)
        let match = try #require(pattern.firstMatch(
            in: source, range: NSRange(source.startIndex..., in: source)), """
                ContentView.swift no longer declares the primary-window property as \
                `var …: Bool { seed == nil }` — re-anchor this guard.
                """)
        let name = try #require(Range(match.range(at: 1), in: source))
        return String(source[name])
    }

    /// Fix round 1: every `isPrimaryWindow:` argument in the three executing
    /// bodies passes the real property. A hard-coded `true` there made a
    /// secondary window's drag write the saved size with every value test
    /// still green. Positive (the label appears the expected number of
    /// times, each followed by the property) beside negative (no literal).
    /// Full screen is read from the window in the two saving paths.
    @Test func thePlanIsAskedAboutTheRealWindow() throws {
        let property = try Self.primaryWindowProperty()
        let bodies: [(anchor: String, labels: Int)] = [
            ("func shrinkIfPristine() {", 1),
            ("func growToBrowserSize() {", 2),
            ("func handleWindowDidEndLiveResize(_ notification: Notification) {", 1),
        ]
        let literal = try CompiledPattern.regex(#"isPrimaryWindow:\s*(true|false)\b"#)
        for (anchor, labels) in bodies {
            let body = try Self.body(of: anchor, in: Self.lifecycleFile)
            let passed = body.components(separatedBy: "isPrimaryWindow: \(property)").count - 1
            let spelled = body.components(separatedBy: "isPrimaryWindow:").count - 1
            let literals = literal.numberOfMatches(
                in: body, range: NSRange(body.startIndex..., in: body))
            #expect(spelled == labels, "\(anchor): \(spelled) isPrimaryWindow: labels")
            #expect(passed == labels, "\(anchor): \(passed) of \(labels) pass \(property)")
            #expect(literals == 0, "\(anchor) hard-codes isPrimaryWindow:")
        }
        for anchor in [
            "func shrinkIfPristine() {",
            "func handleWindowDidEndLiveResize(_ notification: Notification) {",
        ] {
            let body = try Self.body(of: anchor, in: Self.lifecycleFile)
            #expect(body.contains("isFullScreen:") && body.contains("styleMask.contains(.fullScreen)"),
                "\(anchor) no longer tells the plan whether the window is in full screen")
        }
    }

    /// The negatives, each with its positive beside it: the persisted size
    /// has exactly the two writers pinned above, the frame is saved by name
    /// in one place, and no call site resizes the window to a size it
    /// spelled itself instead of asking the plan.
    @Test func nothingElseWritesTheSizeOrResizesTheWindow() throws {
        #expect(try Self.occurrences(of: "mainWindowBrowserSize = ") == 2)
        #expect(try Self.occurrences(of: "saveFrame(usingName:") == 1)
        #expect(try Self.occurrences(of: "lastBrowserSize = ") == 1)
        // Declaration plus the two callers above.
        #expect(try Self.occurrences(of: "resizeWindow(") == 3)
        let literalResize = try CompiledPattern.regex(#"resizeWindow\(\s*toWidth:\s*[0-9]"#)
        var literalCalls = 0
        let files = try SourceCorpus.children(of: Self.sourceDir)
        for file in files where file.pathExtension == "swift" {
            let code = try Self.code(of: file)
            literalCalls += literalResize.numberOfMatches(
                in: code, range: NSRange(code.startIndex..., in: code))
        }
        #expect(literalCalls == 0)
        let chrome = try Self.code(of: Self.detailFile)
        #expect(chrome.contains("MainWindowSizePlan.formSize.width"),
            "the window's minimum size no longer reads the plan's form size")
    }
}
