import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The four pure decisions Task 7 draws from: the Dock badge's label, the
/// sidebar glyph, which autostart moments a launch may run, and which
/// profiles the session-less menus list (port-forwarding plan, Task 7).
///
/// Nothing here renders, dials, or touches AppKit. Every one of these is a
/// function over values precisely so the surfaces built on top of them —
/// a Dock tile, a sidebar row, two menus — need no render harness to be
/// measured.
@Suite("Tunnel status plans")
struct TunnelStatusPlanTests {

    private static func profile(
        _ name: String, autoStart: TunnelProfile.AutoStart = .off,
        session: UUID = UUID()
    ) -> TunnelProfile {
        TunnelProfile(
            sessionID: session, name: name,
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80),
            autoStart: autoStart)
    }

    /// A forwarding whose last three connections in a row failed, folded
    /// through `TunnelStatePlan` rather than built by hand: the threshold is
    /// Core's, and this suite reads it rather than spelling a number.
    private static func degraded() -> TunnelState {
        failing(TunnelState.failuresBeforeDegraded)
    }

    /// One below it — the negative beside every positive here.
    private static func failingButHealthy() -> TunnelState {
        failing(TunnelState.failuresBeforeDegraded - 1)
    }

    private static func failing(_ count: Int) -> TunnelState {
        var state = TunnelState.active(connections: 0)
        for _ in 0..<count {
            state = TunnelStatePlan.next(state, on: .connectionFailed(.channelOpenFailed))
        }
        return state
    }

    // MARK: - The Dock badge

    /// The three cases the design names, in the order they outrank each
    /// other.
    @Test func theBadgeCountsWhatIsUpAndShoutsWhatIsBroken() {
        #expect(DockBadgePlan.label(activeCount: 0, failedCount: 0, degradedRun: 0) == nil)
        #expect(DockBadgePlan.label(activeCount: 3, failedCount: 0, degradedRun: 0) == "3")
        #expect(DockBadgePlan.label(activeCount: 0, failedCount: 1, degradedRun: 0) == "!")
    }

    /// The precedence, on its own: a failure is reported even while other
    /// forwardings are up, because a badge reading "2" over a third one that
    /// is down would be the good news drawn over the bad one.
    @Test func aFailureOutranksTheCount() {
        #expect(DockBadgePlan.label(activeCount: 2, failedCount: 1, degradedRun: 0) == "!")
        #expect(DockBadgePlan.label(activeCount: 9, failedCount: 4, degradedRun: 0) == "!")
    }

    /// A forwarding whose last three connections all failed is up, and is
    /// carrying nothing: the badge stops reporting it as one of the good
    /// ones (maintainer answer, 2026-09-19) — and says how many failed in a
    /// row rather than the `"!"` a DOWN forwarding gets (coordinator
    /// ruling, 2026-09-20, fix round 1). `NSDockTile` draws its badge red
    /// whatever it says, so the text is this surface's only channel and the
    /// two states may not share it.
    ///
    /// **The run carries a `"!"` of its own** (fix round 2): a bare `"3"`
    /// is also what three healthy forwardings read as, and the Dock has no
    /// second channel to tell the two apart with.
    @Test func aForwardingThatKeepsFailingSaysHowManyNotWhy() {
        #expect(DockBadgePlan.label(activeCount: 2, failedCount: 0, degradedRun: 3) == "3!")
        #expect(DockBadgePlan.label(activeCount: 1, failedCount: 0, degradedRun: 0) == "1")
        #expect(DockBadgePlan.label(activeCount: 3, failedCount: 0, degradedRun: 0) == "3")
    }

    /// One case per state, on the badge, so no state can change what the
    /// Dock says without a case here changing with it. The healthy count
    /// and the marked run are the pair the ruling is about: `"3"` and
    /// `"3!"` over the same number.
    @Test(arguments: [
        (TunnelState.stopped, String?.none),
        (.connecting, nil),
        (.active(connections: 0), "1"),
        (.reconnecting(attempt: 2), nil),
        (.needsConfirmation, nil),
        (.failed(.connectionFailed), "!"),
    ])
    func everyStateHasItsOwnBadgeLabel(_ state: TunnelState, _ expected: String?) {
        #expect(DockBadgePlan.label(states: [state]) == expected)
    }

    /// The seventh reading, which is not a case.
    @Test func aForwardingThatKeepsFailingIsBadgedWithItsMarkedRun() {
        #expect(
            DockBadgePlan.label(states: [Self.degraded()])
                == "\(TunnelState.failuresBeforeDegraded)!")
    }

    /// A failure still outranks it, and that is the mixed case's rule: a
    /// forwarding that is DOWN is the news, whatever else is happening.
    @Test func aFailureOutranksAForwardingThatKeepsFailing() {
        #expect(DockBadgePlan.label(activeCount: 2, failedCount: 1, degradedRun: 7) == "!")
    }

    /// Several forwardings failing at once: the badge shows the LONGEST run,
    /// never their sum — no forwarding failed six connections in a row, and
    /// a badge saying so would be reporting something that did not happen.
    @Test func severalFailingForwardingsShowTheLongestRun() {
        let three = Self.failing(3)
        let five = Self.failing(5)
        #expect(DockBadgePlan.label(states: [three, five]) == "5!")
        #expect(DockBadgePlan.label(states: [five, three]) == "5!")
    }

    /// The states form of the same answer, folded through the plan so the
    /// badge is measured over what the report stream produces.
    @Test func theBadgeReadsAForwardingThatKeepsFailingFromItsState() {
        #expect(DockBadgePlan.label(states: [Self.degraded(), .active(connections: 4)]) == "3!")
        #expect(DockBadgePlan.label(states: [Self.failingButHealthy(), .active(connections: 4)]) == "2")
    }

    /// The states form, which is what the controller actually calls: the
    /// count is the number of ACTIVE tunnels, not of connections carried.
    @Test func theBadgeCountsTunnelsNotConnections() {
        let states: [TunnelState] = [
            .active(connections: 7), .active(connections: 0), .stopped,
        ]
        #expect(DockBadgePlan.label(states: states) == "2")
        #expect(DockBadgePlan.label(states: []) == nil)
        #expect(DockBadgePlan.label(states: [.stopped, .stopped]) == nil)
    }

    /// A `.needsConfirmation` tunnel is a question, not a failure: no `"!"`,
    /// and nothing counted.
    @Test func aWaitingTunnelIsNotAFailedOne() {
        #expect(DockBadgePlan.label(states: [.needsConfirmation]) == nil)
        #expect(DockBadgePlan.label(states: [.needsConfirmation, .active(connections: 0)]) == "1")
    }

    // MARK: - The sidebar glyph

    /// The four cases the brief names, including the one that draws nothing
    /// at all.
    @Test func theGlyphSaysWhichOfTheFourAnswersThisSessionIs() {
        #expect(TunnelGlyphPlan.glyph(states: []) == nil)
        #expect(
            TunnelGlyphPlan.glyph(states: [.stopped])
                == TunnelGlyphPlan.Glyph(
                    tint: .grey, symbol: TunnelGlyphPlan.forwardingSymbol, text: nil))
        #expect(
            TunnelGlyphPlan.glyph(states: [.active(connections: 0)])
                == TunnelGlyphPlan.Glyph(
                    tint: .green, symbol: TunnelGlyphPlan.forwardingSymbol, text: "1"))
        #expect(
            TunnelGlyphPlan.glyph(states: [.failed(.portInUse(port: 8080))])
                == TunnelGlyphPlan.Glyph(
                    tint: .red, symbol: TunnelGlyphPlan.forwardingSymbol, text: "!"))
    }

    /// Red outranks green, and the count gives way to the `"!"` — the same
    /// precedence the Dock badge has, because both read one aggregate.
    @Test func theWorstStatePicksTheColour() {
        let mixed: [TunnelState] = [
            .active(connections: 2), .failed(.connectionFailed),
        ]
        #expect(TunnelGlyphPlan.glyph(states: mixed)?.tint == .red)
        #expect(TunnelGlyphPlan.glyph(states: mixed)?.text == "!")

        let waiting: [TunnelState] = [.active(connections: 1), .needsConfirmation]
        #expect(TunnelGlyphPlan.glyph(states: waiting)?.tint == .amber)
        #expect(TunnelGlyphPlan.glyph(states: waiting)?.text == "1")
    }

    /// Orange, not green, once the last three connections in a row failed —
    /// and green again after the next one that is carried (maintainer
    /// answer, 2026-09-19). The same amber a `.connecting` forwarding
    /// draws: the maintainer asked for orange, and the palette has one.
    @Test func aForwardingThatKeepsFailingStopsDrawingGreen() {
        #expect(TunnelGlyphPlan.glyph(states: [Self.failingButHealthy()])?.tint == .green)
        #expect(TunnelGlyphPlan.glyph(states: [Self.degraded()])?.tint == .amber)

        let recovered = TunnelStatePlan.next(Self.degraded(), on: .connectionAccepted)
        #expect(TunnelGlyphPlan.glyph(states: [recovered])?.tint == .green)
    }

    /// One session, two forwardings: the one that keeps failing decides the
    /// colour even when a healthy one — or one that has failed less — was
    /// read first. Both orders, because the aggregate's tie-break is where
    /// a rule like this goes wrong.
    @Test func theForwardingThatKeepsFailingDecidesTheColour() {
        let healthyFirst: [TunnelState] = [.active(connections: 3), Self.degraded()]
        let degradedFirst: [TunnelState] = [Self.degraded(), .active(connections: 3)]
        #expect(TunnelGlyphPlan.glyph(states: healthyFirst)?.tint == .amber)
        #expect(TunnelGlyphPlan.glyph(states: degradedFirst)?.tint == .amber)

        let oneFailureFirst: [TunnelState] = [Self.failingButHealthy(), Self.degraded()]
        #expect(TunnelGlyphPlan.glyph(states: oneFailureFirst)?.tint == .amber)
    }

    /// One case per state, pinning what a reader sees WITHOUT the colour:
    /// the symbol and the text beside it (coordinator ruling, 2026-09-20,
    /// fix round 1). The two symbol names are read from the plan rather
    /// than spelled again here; `theWarningSymbolIsAWarning` below is the
    /// one place either name is written down.
    @Test(arguments: [
        (TunnelState.stopped, TunnelGlyphPlan.forwardingSymbol, String?.none),
        (.connecting, TunnelGlyphPlan.forwardingSymbol, nil),
        (.active(connections: 0), TunnelGlyphPlan.forwardingSymbol, "1"),
        (.reconnecting(attempt: 2), TunnelGlyphPlan.forwardingSymbol, nil),
        (.needsConfirmation, TunnelGlyphPlan.forwardingSymbol, nil),
        (.failed(.connectionFailed), TunnelGlyphPlan.forwardingSymbol, "!"),
    ])
    func everyStateDrawsItsOwnSymbolAndText(
        _ state: TunnelState, _ symbol: String, _ text: String?
    ) {
        let glyph = TunnelGlyphPlan.glyph(states: [state])
        #expect(glyph?.symbol == symbol)
        #expect(glyph?.text == text)
    }

    /// The seventh reading, which is not a case: a forwarding that keeps
    /// failing draws the warning symbol and says how many failed in a row.
    @Test func aForwardingThatKeepsFailingDrawsAWarningAndItsRun() {
        let glyph = TunnelGlyphPlan.glyph(states: [Self.degraded()])
        #expect(glyph?.symbol == TunnelGlyphPlan.warningSymbol)
        #expect(glyph?.text == "\(TunnelState.failuresBeforeDegraded)!")
    }

    /// The two symbols, written down once: a warning triangle for a
    /// forwarding that is up and carrying nothing, the forwarding arrows
    /// for everything else. Sight-checkable, and the anchor every other
    /// case above reads instead of spelling a name.
    @Test func theWarningSymbolIsAWarning() {
        #expect(TunnelGlyphPlan.forwardingSymbol == "arrow.left.arrow.right")
        #expect(TunnelGlyphPlan.warningSymbol == "exclamationmark.triangle.fill")
    }

    /// **Neither surface tells the two apart by colour alone.** The glyph's
    /// colour DOES differ (the positive, first) — and with the colour taken
    /// away, the symbol and the text still differ, on the glyph and on the
    /// Dock badge, whose red is AppKit's and not ours to choose. This is
    /// the file's own "colour never alone" invariant, stated for the pair
    /// that came closest to breaking it.
    @Test func aFailingForwardingAndAFailedOneDifferWithoutColour() {
        let failing = TunnelGlyphPlan.glyph(states: [Self.degraded()])
        let failed = TunnelGlyphPlan.glyph(states: [.failed(.connectionFailed)])
        #expect(failing != nil && failed != nil)
        #expect(failing?.tint != failed?.tint)

        func withoutColour(_ glyph: TunnelGlyphPlan.Glyph?) -> [String?] {
            [glyph?.symbol, glyph?.text]
        }
        #expect(withoutColour(failing) != withoutColour(failed))
        #expect(
            DockBadgePlan.label(states: [Self.degraded()])
                != DockBadgePlan.label(states: [.failed(.connectionFailed)]))
    }

    /// A failure still outranks it: a forwarding that is DOWN is worse news
    /// than one that is up and carrying nothing.
    @Test func aFailedForwardingStillOutranksAFailingOne() {
        #expect(
            TunnelGlyphPlan.glyph(states: [Self.degraded(), .failed(.connectionFailed)])?.tint
                == .red)
    }

    /// The coalescing the hand-off asks for: a successful reconnect passes
    /// `.reconnecting(k)` → `.connecting` → `.active(0)`, and the middle
    /// state must not be a third appearance. Asserted as an EQUALITY between
    /// the two glyphs rather than by naming a colour, so it stays true if the
    /// colour of both ever changes together.
    @Test func theTransientConnectingStateDoesNotFlash() {
        let reconnecting = TunnelGlyphPlan.glyph(states: [.reconnecting(attempt: 3)])
        let connecting = TunnelGlyphPlan.glyph(states: [.connecting])
        #expect(reconnecting != nil)
        #expect(reconnecting == connecting)

        // The Dock badge's half of the same claim.
        #expect(
            DockBadgePlan.label(states: [.reconnecting(attempt: 3)])
                == DockBadgePlan.label(states: [.connecting]))
    }

    /// The glyph a session with several stopped profiles draws: grey, and
    /// still no count — "stopped" is a fact worth a mark, "0" is not a
    /// number worth drawing.
    @Test func severalStoppedForwardingsStillDrawNoCount() {
        #expect(
            TunnelGlyphPlan.glyph(states: [.stopped, .stopped, .stopped])
                == TunnelGlyphPlan.Glyph(
                    tint: .grey, symbol: TunnelGlyphPlan.forwardingSymbol, text: nil))
    }

    // MARK: - Which moments a launch runs

    @Test func anOrdinaryLaunchRunsAppStartOnly() {
        #expect(LaunchAutoStartPlan.moments(launchedAsLoginItem: false) == [.appStart])
    }

    /// A login launch runs BOTH: "at app start" means every launch, and a
    /// login launch is one.
    @Test func aLoginLaunchRunsBothMoments() {
        #expect(LaunchAutoStartPlan.moments(launchedAsLoginItem: true) == [.appStart, .login])
    }

    // MARK: - The session-less menu block

    /// A running profile is listed however it was started; a stopped one is
    /// listed only when it asked to start on its own.
    @Test func theBlockListsWhatIsRunningOrAsksToStartItself() {
        let running = Self.profile("running")
        let manual = Self.profile("manual")
        let atLaunch = Self.profile("at launch", autoStart: .appStart)
        let atLogin = Self.profile("at login", autoStart: .login)
        let entries = TunnelMenuBlockPlan.entries(
            profiles: [running, manual, atLaunch, atLogin],
            state: { id in id == running.id ? .active(connections: 1) : .stopped })

        #expect(entries.map(\.profile.name) == ["running", "at launch", "at login"])
        #expect(entries.first?.isRunning == true)
        #expect(entries.dropFirst().allSatisfy { !$0.isRunning })
    }

    /// "Running" is the manager's own predicate, so a reconnecting profile —
    /// which holds a retry on its way to a connection — is listed and is
    /// checkable.
    @Test func runningMeansWhatTheManagerMeansByIt() {
        let reconnecting = Self.profile("reconnecting")
        let entries = TunnelMenuBlockPlan.entries(
            profiles: [reconnecting], state: { _ in .reconnecting(attempt: 2) })

        #expect(entries.map(\.profile.name) == ["reconnecting"])
        #expect(entries.first?.isRunning == true)
    }

    /// **The alarm is listed where the user sees it** (fix round 1, review
    /// finding I-5). `DockBadgePlan` counts failures over EVERY profile, so a
    /// manually started forwarding with `autoStart == .off` that fails puts
    /// `"!"` on the Dock — while a block that listed only running-or-autostart
    /// profiles answered "No forwardings set up" and a header of zero. The
    /// badge shouted about something the menu behind it denied existed.
    ///
    /// So the block lists exactly what the badge can shout about as well:
    /// `.failed` and `.needsConfirmation`, neither of which is running.
    @Test func aFailedManualProfileIsListedBecauseTheBadgeShoutsAboutIt() {
        let failed = Self.profile("failed")
        let waiting = Self.profile("waiting")
        let entries = TunnelMenuBlockPlan.entries(
            profiles: [failed, waiting],
            state: { id in
                id == failed.id
                    ? .failed(.connectionFailed)
                    : .needsConfirmation
            })

        #expect(entries.map(\.profile.name) == ["failed", "waiting"])
        #expect(entries.allSatisfy { !$0.isRunning })
    }

    /// The negative beside it, and the reason the rule is not "list
    /// everything": a stopped forwarding nobody asked to autostart puts
    /// nothing on the badge, so it has nothing to explain here. It is reached
    /// from its own session's row.
    @Test func aStoppedManualProfileIsStillNotListed() {
        let manual = Self.profile("manual")
        #expect(TunnelMenuBlockPlan.entries(profiles: [manual], state: { _ in .stopped }).isEmpty)
    }

    /// The property behind both, stated once: whatever the badge marks with
    /// `"!"`, the block lists. Driven over every state rather than over the
    /// two the cases above name, so a seventh `TunnelState` cannot be added
    /// on one side of this only — plus the reading that is not a case,
    /// `.active` that keeps failing, which the badge marks since
    /// 2026-09-19 and the block lists because it is running.
    @Test func everyStateTheBadgeShoutsAboutIsListedInTheBlock() {
        let states: [TunnelState] = [
            .stopped, .connecting, .active(connections: 0), Self.degraded(),
            .reconnecting(attempt: 1), .failed(.connectionFailed), .needsConfirmation,
        ]
        for state in states {
            let manual = Self.profile("manual")
            let listed = !TunnelMenuBlockPlan.entries(
                profiles: [manual], state: { _ in state }).isEmpty
            let shouted = DockBadgePlan.label(states: [state])?.contains("!") == true
            #expect(
                !shouted || listed,
                "the badge marks \(state) with \"!\" and the block lists nothing for it")
        }
    }

    /// Nothing configured, nothing listed — the case the Dock menu draws its
    /// "no forwardings" line for.
    @Test func nothingConfiguredListsNothing() {
        #expect(TunnelMenuBlockPlan.entries(profiles: [], state: { _ in .stopped }).isEmpty)
    }
}
