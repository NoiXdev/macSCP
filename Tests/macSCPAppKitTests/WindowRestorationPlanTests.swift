import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// The pure half of window restoration (Detachable Tabs plan, Task 5):
/// every decision the feature takes, with no file, no window and no clock
/// in it.
///
/// The decisions live in a value type precisely so the setting's whole
/// meaning — off means nothing is written and nothing is read — can be
/// pinned without a launch. `WindowRestorationStoreTests` then pins that
/// the file follows the decision, and the source guards pin that the app
/// asks it rather than re-deriving it.
@Suite("WindowRestorationPlan — what the setting decides")
@MainActor
struct WindowRestorationPlanTests {
    private static func describedWindow(
        isPrimary: Bool, keepOnTop: Bool = false, sessions: Int = 1
    ) -> WindowSeed {
        WindowSeed(
            tabs: (0..<sessions).map { _ in
                TabSeed(sessionID: UUID(), paneVisibility: .filesOnly)
            },
            keepOnTop: keepOnTop, isPrimary: isPrimary)
    }

    // MARK: - The two file decisions

    @Test func nothingIsWrittenWhileTheSettingIsOff() {
        #expect(WindowRestorationPlan.shouldWrite(flag: false) == false)
    }

    @Test func aClosingWindowIsWrittenWhileTheSettingIsOn() {
        #expect(WindowRestorationPlan.shouldWrite(flag: true))
    }

    @Test func nothingIsReadWhileTheSettingIsOff() {
        #expect(WindowRestorationPlan.shouldRead(flag: false) == false)
    }

    @Test func theFileIsReadWhileTheSettingIsOn() {
        #expect(WindowRestorationPlan.shouldRead(flag: true))
    }

    // MARK: - Which description belongs to which window

    @Test func theSettingOffOpensNoWindowAndRestoresNoPrimary() {
        let stored = [Self.describedWindow(isPrimary: true), Self.describedWindow(isPrimary: false)]
        #expect(WindowRestorationPlan.seedsToOpen(flag: false, stored: stored).isEmpty)
        #expect(WindowRestorationPlan.primarySeed(flag: false, stored: stored) == nil)
    }

    @Test func thePrimaryDescriptionIsTheOneMarkedPrimary() {
        let primary = Self.describedWindow(isPrimary: true, keepOnTop: true)
        let other = Self.describedWindow(isPrimary: false)
        let stored = [other, primary]
        #expect(WindowRestorationPlan.primarySeed(flag: true, stored: stored) == primary)
    }

    @Test func everyOtherDescriptionOpensAWindowOfItsOwn() {
        let primary = Self.describedWindow(isPrimary: true)
        let first = Self.describedWindow(isPrimary: false)
        let second = Self.describedWindow(isPrimary: false)
        let opened = WindowRestorationPlan.seedsToOpen(
            flag: true, stored: [primary, first, second])
        #expect(opened == [first, second], """
            the windows to open are every stored description EXCEPT the \
            primary one, in the order they were written — the primary \
            window is not opened, it is the one already on screen
            """)
    }

    /// A file written by a launch that never had a primary window on
    /// screen (or one whose primary marker was lost) must still restore
    /// what it can, rather than opening nothing.
    @Test func aFileWithNoPrimaryDescriptionOpensEveryWindowItNames() {
        let first = Self.describedWindow(isPrimary: false)
        let second = Self.describedWindow(isPrimary: false)
        #expect(WindowRestorationPlan.primarySeed(flag: true, stored: [first, second]) == nil)
        #expect(WindowRestorationPlan.seedsToOpen(flag: true, stored: [first, second])
            == [first, second])
    }

    /// Two primary markers cannot happen from one run — one window is
    /// seedless — but a hand-edited or half-written file can carry them.
    /// The first wins and the rest open as ordinary windows, so no
    /// description is silently dropped.
    @Test func aSecondPrimaryDescriptionOpensAsAnOrdinaryWindow() {
        let first = Self.describedWindow(isPrimary: true, keepOnTop: true)
        let second = Self.describedWindow(isPrimary: true)
        #expect(WindowRestorationPlan.primarySeed(flag: true, stored: [first, second]) == first)
        #expect(WindowRestorationPlan.seedsToOpen(flag: true, stored: [first, second]) == [second])
    }

    // MARK: - Which pane visibility a restored tab connects with

    /// A restored tab is disconnected: it has no panes yet, so the
    /// visibility it was described with cannot be applied to anything
    /// until it connects. This is where it lands — ahead of the stored
    /// session's own saved value, behind an explicit override (the
    /// sidebar's "Open Terminal", which asks for a specific shape).
    @Test func anExplicitOverrideWinsOverEverything() {
        #expect(WindowRestorationPlan.paneVisibility(
            override: .terminalOnly, restored: .bothVisible, stored: .filesOnly)
            == PaneVisibility.terminalOnly)
    }

    @Test func aRestoredTabConnectsWithTheVisibilityItWasDescribedWith() {
        #expect(WindowRestorationPlan.paneVisibility(
            override: nil, restored: .bothVisible, stored: .filesOnly)
            == PaneVisibility.bothVisible)
    }

    @Test func anOrdinaryTabConnectsWithTheStoredSessionsOwnVisibility() {
        #expect(WindowRestorationPlan.paneVisibility(
            override: nil, restored: nil, stored: .bothVisible)
            == PaneVisibility.bothVisible)
    }

    // MARK: - Read once, at launch, and never again

    @Test func theLaunchHandsThePrimaryDescriptionOverExactlyOnce() {
        let primary = Self.describedWindow(isPrimary: true, keepOnTop: true)
        let launch = WindowRestorationLaunch(
            flag: true, stored: [primary, Self.describedWindow(isPrimary: false)])
        #expect(launch.takePrimarySeed() == primary)
        #expect(launch.takePrimarySeed() == nil, """
            a primary window that appears a second time (the user closed it \
            and something opened another) must not rebuild the same tabs \
            again — the description was consumed by the first one
            """)
    }

    @Test func theLaunchHandsTheWindowsToOpenOverExactlyOnce() {
        let other = Self.describedWindow(isPrimary: false)
        let launch = WindowRestorationLaunch(
            flag: true, stored: [Self.describedWindow(isPrimary: true), other])
        #expect(launch.takeSeedsToOpen() == [other])
        #expect(launch.takeSeedsToOpen().isEmpty)
    }

    @Test func aLaunchWithTheSettingOffHasNothingToHandOver() {
        let launch = WindowRestorationLaunch(
            flag: false,
            stored: [Self.describedWindow(isPrimary: true), Self.describedWindow(isPrimary: false)])
        #expect(launch.takePrimarySeed() == nil)
        #expect(launch.takeSeedsToOpen().isEmpty)
    }
}
