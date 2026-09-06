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

    // MARK: - The Dock badge

    /// The three cases the design names, in the order they outrank each
    /// other.
    @Test func theBadgeCountsWhatIsUpAndShoutsWhatIsBroken() {
        #expect(DockBadgePlan.label(activeCount: 0, failedCount: 0) == nil)
        #expect(DockBadgePlan.label(activeCount: 3, failedCount: 0) == "3")
        #expect(DockBadgePlan.label(activeCount: 0, failedCount: 1) == "!")
    }

    /// The precedence, on its own: a failure is reported even while other
    /// forwardings are up, because a badge reading "2" over a third one that
    /// is down would be the good news drawn over the bad one.
    @Test func aFailureOutranksTheCount() {
        #expect(DockBadgePlan.label(activeCount: 2, failedCount: 1) == "!")
        #expect(DockBadgePlan.label(activeCount: 9, failedCount: 4) == "!")
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
                == TunnelGlyphPlan.Glyph(tint: .grey, text: nil))
        #expect(
            TunnelGlyphPlan.glyph(states: [.active(connections: 0)])
                == TunnelGlyphPlan.Glyph(tint: .green, text: "1"))
        #expect(
            TunnelGlyphPlan.glyph(states: [.failed(reason: "port 8080 is in use")])
                == TunnelGlyphPlan.Glyph(tint: .red, text: "!"))
    }

    /// Red outranks green, and the count gives way to the `"!"` — the same
    /// precedence the Dock badge has, because both read one aggregate.
    @Test func theWorstStatePicksTheColour() {
        let mixed: [TunnelState] = [
            .active(connections: 2), .failed(reason: "the host refused the connection"),
        ]
        #expect(TunnelGlyphPlan.glyph(states: mixed)?.tint == .red)
        #expect(TunnelGlyphPlan.glyph(states: mixed)?.text == "!")

        let waiting: [TunnelState] = [.active(connections: 1), .needsConfirmation]
        #expect(TunnelGlyphPlan.glyph(states: waiting)?.tint == .amber)
        #expect(TunnelGlyphPlan.glyph(states: waiting)?.text == "1")
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
                == TunnelGlyphPlan.Glyph(tint: .grey, text: nil))
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
    /// checkable, while a failed one that never asked to autostart is not
    /// listed at all.
    @Test func runningMeansWhatTheManagerMeansByIt() {
        let reconnecting = Self.profile("reconnecting")
        let failed = Self.profile("failed")
        let entries = TunnelMenuBlockPlan.entries(
            profiles: [reconnecting, failed],
            state: { id in
                id == reconnecting.id
                    ? .reconnecting(attempt: 2)
                    : .failed(reason: "the host refused the connection")
            })

        #expect(entries.map(\.profile.name) == ["reconnecting"])
        #expect(entries.first?.isRunning == true)
    }

    /// Nothing configured, nothing listed — the case the Dock menu draws its
    /// "no forwardings" line for.
    @Test func nothingConfiguredListsNothing() {
        #expect(TunnelMenuBlockPlan.entries(profiles: [], state: { _ in .stopped }).isEmpty)
    }
}
