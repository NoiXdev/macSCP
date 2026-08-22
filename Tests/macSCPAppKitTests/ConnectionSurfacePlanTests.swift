import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `ConnectionSurfacePlan.surface(for:hostKeyPromptPending:)`
/// (connection-liveness plan, Task 6) — the plain, testable decision behind
/// which of the two "no session yet" surfaces `ContentView.detail` shows.
/// No SwiftUI rendering harness exists in this project, so nothing here can
/// prove what actually lands on screen; what it CAN prove, and does, is the
/// mapping itself, crossed properly: all five `ConnectionLiveness?` values
/// (the four real cases plus `nil`) against BOTH values of
/// `hostKeyPromptPending` — ten combinations, all ten covered below, not a
/// sampled subset. Fix round 2, review-measured: an earlier version of this
/// file claimed "crossed with" while only exercising `pending: true` for
/// two of the five liveness values (`.connecting` and `nil`); this is the
/// corrected version, not a rephrased claim over the same coverage.
///
/// Task 7 moved `.lost` out of the "everything else shows the form" group
/// into its own surface; the ten combinations are unchanged in number and
/// still all covered.
@Suite("Connection surface plan")
struct ConnectionSurfacePlanTests {
    @Test func connectingShowsTheConnectingSurface() {
        #expect(
            ConnectionSurfacePlan.surface(for: .connecting, hostKeyPromptPending: false)
                == .connecting)
    }

    /// The lost-connection surface (connection-liveness plan, Task 7) — the
    /// error view with its "Reconnect" control, not the form. Before this
    /// task `.lost` fell into the group below and showed the plain form,
    /// which is exactly the behaviour this task replaces.
    @Test func lostShowsTheLostSurface() {
        #expect(ConnectionSurfacePlan.surface(for: .lost, hostKeyPromptPending: false) == .lost)
    }

    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connected, .degraded,
    ])
    func everyOtherLivenessShowsTheFormWhenNoPromptIsPending(liveness: ConnectionLiveness?) {
        #expect(
            ConnectionSurfacePlan.surface(for: liveness, hostKeyPromptPending: false) == .form)
    }

    /// The override, now tested against all five liveness values instead of
    /// two: even while `.connecting`, a pending host-key prompt forces the
    /// form back — that is where the SSH trust card actually renders
    /// (`ConnectionFormView.hostKeyPromptView`), and a `.connecting` surface
    /// covering it would leave the user with no way to answer it. The other
    /// four values passing this same check is not a redundant restatement:
    /// `ConnectionSurfacePlan.surface`'s own implementation returns `.form`
    /// on this branch BEFORE it ever reads `liveness` at all, so this suite
    /// pins that the guard is first and unconditional, not merely that
    /// `.connecting` happens to also satisfy some liveness-dependent path
    /// that reaches the same answer by coincidence.
    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connecting, .connected, .degraded, .lost,
    ])
    func aPendingHostKeyPromptAlwaysShowsTheFormRegardlessOfLiveness(liveness: ConnectionLiveness?) {
        #expect(ConnectionSurfacePlan.surface(for: liveness, hostKeyPromptPending: true) == .form)
    }
}
