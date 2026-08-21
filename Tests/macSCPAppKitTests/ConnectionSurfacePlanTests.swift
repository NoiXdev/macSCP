import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `ConnectionSurfacePlan.surface(for:hostKeyPromptPending:)`
/// (connection-liveness plan, Task 6) — the plain, testable decision behind
/// which of the two "no session yet" surfaces `ContentView.detail` shows.
/// No SwiftUI rendering harness exists in this project, so nothing here can
/// prove what actually lands on screen; what it CAN prove, and does, is the
/// mapping itself for every `ConnectionLiveness?` case, crossed with the one
/// override (a pending host-key prompt) that must always win regardless of
/// liveness — see that function's own doc comment for why: TOFU's trust
/// card lives inside `ConnectionFormView`, so hiding that view during
/// `.connecting` would hide the one thing an unknown host's first connect
/// needs answered.
@Suite("Connection surface plan")
struct ConnectionSurfacePlanTests {
    @Test func connectingShowsTheConnectingSurface() {
        #expect(
            ConnectionSurfacePlan.surface(for: .connecting, hostKeyPromptPending: false)
                == .connecting)
    }

    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connected, .degraded, .lost,
    ])
    func everyOtherLivenessShowsTheForm(liveness: ConnectionLiveness?) {
        #expect(
            ConnectionSurfacePlan.surface(for: liveness, hostKeyPromptPending: false) == .form)
    }

    /// The override: even while `.connecting`, a pending host-key prompt
    /// forces the form back — that is where the SSH trust card actually
    /// renders (`ConnectionFormView.hostKeyPromptView`), and a `.connecting`
    /// surface covering it would leave the user with no way to answer it.
    @Test func aPendingHostKeyPromptAlwaysWinsOverConnecting() {
        #expect(
            ConnectionSurfacePlan.surface(for: .connecting, hostKeyPromptPending: true) == .form)
    }

    @Test func aPendingHostKeyPromptWithNoLivenessStillShowsTheForm() {
        #expect(
            ConnectionSurfacePlan.surface(for: nil, hostKeyPromptPending: true) == .form)
    }
}

/// Direct tests over `ConnectAttemptOutcome.shouldApply(livenessAtCompletion:)`
/// (connection-liveness plan, Task 6) — the guard the ad-hoc form's
/// `onConnected` closure consults before calling `ContentView.startSession`,
/// so a connect attempt abandoned by Cancel cannot resurrect a session on a
/// tab the user already backed out of. See that guard's own doc comment
/// (`ContentView+Detail.swift`) for the narrower gap it does NOT close: a
/// brand-new attempt started on the same tab before the abandoned one gives
/// up also reads `.connecting` and would still be accepted.
@Suite("Connect attempt outcome")
struct ConnectAttemptOutcomeTests {
    @Test func stillConnectingMeansApplyTheResult() {
        #expect(ConnectAttemptOutcome.shouldApply(livenessAtCompletion: .connecting))
    }

    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connected, .degraded, .lost,
    ])
    func anythingElseMeansDiscardIt(liveness: ConnectionLiveness?) {
        #expect(!ConnectAttemptOutcome.shouldApply(livenessAtCompletion: liveness))
    }
}
