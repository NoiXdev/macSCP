import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over
/// `ConnectionSurfacePlan.surface(for:hostKeyPromptPending:connectAttemptFailed:)`
/// (connection-liveness plan, Task 6) — the plain, testable decision behind
/// which "no session yet" surface `ContentView.detail` shows.
/// No SwiftUI rendering harness exists in this project, so nothing here can
/// prove what actually lands on screen; what it CAN prove, and does, is the
/// mapping itself, crossed properly: all five `ConnectionLiveness?` values
/// (the four real cases plus `nil`) against BOTH values of
/// `hostKeyPromptPending` AND both values of `connectAttemptFailed` — twenty
/// combinations, all twenty covered below, not a sampled subset. Fix round 2,
/// review-measured: an earlier version of this file claimed "crossed with"
/// while only exercising `pending: true` for two of the five liveness values
/// (`.connecting` and `nil`); this is the corrected version, not a rephrased
/// claim over the same coverage.
///
/// Task 7 moved `.lost` out of the "everything else shows the form" group
/// into its own surface. The failed-connect surface plan's Task 3 then split
/// the `nil` arm — a connect attempt that failed on the wire used to land
/// there and show the form, which is the behaviour it replaces — and added
/// `connectAttemptFailed`, doubling the cross from ten combinations to
/// twenty.
@Suite("Connection surface plan")
struct ConnectionSurfacePlanTests {
    /// Every `ConnectionLiveness?` this decision can be asked about: the
    /// four real cases plus "no attempt yet".
    private static let everyLiveness: [ConnectionLiveness?] = [
        nil, .connecting, .connected, .degraded, .lost,
    ]

    @Test func connectingShowsTheConnectingSurface() {
        #expect(
            ConnectionSurfacePlan.surface(
                for: .connecting, hostKeyPromptPending: false, connectAttemptFailed: false)
                == .connecting)
    }

    /// The lost-connection surface (connection-liveness plan, Task 7) — the
    /// error view with its "Reconnect" control, not the form. Before that
    /// task `.lost` fell into the group below and showed the plain form,
    /// which is exactly the behaviour it replaced.
    @Test func lostShowsTheLostSurface() {
        #expect(
            ConnectionSurfacePlan.surface(
                for: .lost, hostKeyPromptPending: false, connectAttemptFailed: false)
                == .lost)
    }

    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connected, .degraded,
    ])
    func everyOtherLivenessShowsTheFormWhenNoPromptIsPending(liveness: ConnectionLiveness?) {
        #expect(
            ConnectionSurfacePlan.surface(
                for: liveness, hostKeyPromptPending: false, connectAttemptFailed: false)
                == .form)
    }

    /// The override, tested against all five liveness values rather than
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
    ///
    /// Crossed with `connectAttemptFailed` since the failed-connect surface
    /// plan's Task 3 added it, for the same reason and against the same
    /// mistake: a failed attempt whose host-key prompt is up must show the
    /// card, not an explanation of the failure with the question hidden
    /// behind it.
    @Test(arguments: ConnectionSurfacePlanTests.everyLiveness, [true, false])
    func aPendingHostKeyPromptAlwaysShowsTheFormRegardlessOfLiveness(
        liveness: ConnectionLiveness?, connectAttemptFailed: Bool
    ) {
        #expect(
            ConnectionSurfacePlan.surface(
                for: liveness, hostKeyPromptPending: true,
                connectAttemptFailed: connectAttemptFailed) == .form)
    }

    // MARK: - The failed-connect surface (failed-connect surface plan, Task 3)

    /// The task's whole point: an attempt that failed leaves `liveness` at
    /// `nil`, which used to mean "show the form" — the maintainer's
    /// complaint, being handed the entry mask again as if nothing had been
    /// asked for.
    @Test func aFailedAttemptShowsTheFailedSurface() {
        #expect(
            ConnectionSurfacePlan.surface(
                for: nil, hostKeyPromptPending: false, connectAttemptFailed: true)
                == .failed)
    }

    /// The other direction, without which the test above is satisfied by a
    /// plan that answers `.failed` for everything: no failed attempt on
    /// record still means the form.
    @Test func noFailedAttemptStillMeansTheForm() {
        #expect(
            ConnectionSurfacePlan.surface(
                for: nil, hostKeyPromptPending: false, connectAttemptFailed: false)
                == .form)
    }

    /// A reconnect that fails from the LOST surface must return to the
    /// surface that explains the drop, not be reclassified as a fresh
    /// failure — `ConnectAttemptLivenessPlan.write` keeps such a tab at
    /// `.lost` (`ReconnectPlanTests`), and this pins that the surface plan
    /// agrees even with a failure also on record. Without the ordering this
    /// checks, the "Reconnect" button, the reason text and the unattended
    /// schedule's own explanation would all vanish the first time an
    /// automatic retry failed.
    @Test func lostOutranksAFailedAttempt() {
        #expect(
            ConnectionSurfacePlan.surface(
                for: .lost, hostKeyPromptPending: false, connectAttemptFailed: true)
                == .lost)
    }

    /// A dial in flight outranks the failure the previous one left, so a
    /// Retry from this very surface shows "Connecting…" rather than sitting
    /// on the explanation of the attempt before it.
    @Test func connectingOutranksAFailedAttempt() {
        #expect(
            ConnectionSurfacePlan.surface(
                for: .connecting, hostKeyPromptPending: false, connectAttemptFailed: true)
                == .connecting)
    }

    /// A live session's tab does not render this area at all
    /// (`ContentView.detail` reaches the surface choice only while
    /// `tab.session == nil`), and a failure left on record must not start
    /// speaking for a tab that is connected or merely mid-probe.
    @Test(arguments: [ConnectionLiveness.connected, .degraded])
    func aLiveConnectionIsNeverDescribedByAFailedAttempt(liveness: ConnectionLiveness) {
        #expect(
            ConnectionSurfacePlan.surface(
                for: liveness, hostKeyPromptPending: false, connectAttemptFailed: true)
                == .form)
    }
}
