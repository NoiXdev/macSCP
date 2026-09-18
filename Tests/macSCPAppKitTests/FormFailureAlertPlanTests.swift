import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// `FormFailureAlertPlan` (jump-and-groups plan, Task 1, fix round 1): when
/// the connection form raises its failure alert — the one place the form
/// shows a `.failed` state's text.
///
/// Why this exists: the alert used to be raised only by a state CHANGE seen
/// by a mounted form. The paths that send a failure a person must read to
/// the form mounted it into a state that was already `.failed` — replacing
/// the session overview after a pre-dial refusal, or "Connecting…" after a
/// missing passphrase and, for the one update `tab.liveness` lagged, after
/// a rejected key (measured in fix round 1's red run; `DetailSurfacePlan`
/// now keeps the form through that update) — so the text never appeared.
///
/// Driven with a real `ConnectionViewModel`, so the marker the decision
/// reads is the one the failure actually wrote. That the form calls these
/// two functions at all is `DetailSurfaceWiringGuardTests`' claim.
@Suite("Form failure alert plan")
@MainActor
struct FormFailureAlertPlanTests {
    private func refusedForm(_ message: String = "refused") -> ConnectionViewModel {
        let form = ConnectionViewModel(connector: { _, _ in throw CancellationError() })
        form.showFailure(message: message)
        return form
    }

    private func onAppear(_ form: ConnectionViewModel) -> FormFailureAlert? {
        FormFailureAlertPlan.onAppear(state: form.state, unacknowledgedFailure: form.unacknowledgedFailure)
    }

    /// The fix: a form that mounts into an unread failure raises it.
    @Test func aFormMountingIntoAnUnreadFailureRaisesItsText() throws {
        let form = refusedForm("the login set is gone")
        let alert = try #require(onAppear(form), "the failure's text never reaches the person")
        #expect(alert.message == "the login set is gone")
        #expect(alert.failureID == form.unacknowledgedFailure)
    }

    /// Dismissal acknowledges, and an acknowledged failure is never raised
    /// again — not on a tab switch, not after "Edit".
    @Test func aDismissedFailureIsNeverRaisedAgain() throws {
        let form = refusedForm()
        let alert = try #require(onAppear(form))
        let id = try #require(alert.failureID)
        form.acknowledgeFailure(id)
        #expect(onAppear(form) == nil)
    }

    /// A wire failure's text belongs to the failed-connect surface; a form
    /// mounted after the person left that surface raises nothing, as
    /// before.
    @Test func aWireFailureIsNotRaisedOnMount() async {
        let form = ConnectionViewModel(connector: { _, _ in
            throw RemoteFSError.connectionFailed(reason: "unreachable")
        })
        form.host = "target.invalid"
        form.port = "22"
        form.username = "tim"
        form.password = "secret-value"
        _ = await form.connect()
        #expect(form.lastFailureKind == .other)
        #expect(onAppear(form) == nil)
    }

    @Test func anIdleFormRaisesNothingOnMount() {
        let form = ConnectionViewModel(connector: { _, _ in throw CancellationError() })
        #expect(onAppear(form) == nil)
    }

    /// A mounted form keeps raising every transition into `.failed`, wire
    /// failures included — the behaviour the change handler always had —
    /// and hands the marker along so dismissing acknowledges this failure.
    @Test func aTransitionIntoAFailureIsRaisedAsBefore() throws {
        let form = refusedForm("refused")
        let alert = try #require(
            FormFailureAlertPlan.onChange(to: form.state, unacknowledgedFailure: form.unacknowledgedFailure))
        #expect(alert.message == "refused")
        #expect(alert.failureID == form.unacknowledgedFailure)

        let wire = FormFailureAlertPlan.onChange(
            to: .failed(message: "unreachable", field: nil), unacknowledgedFailure: nil)
        #expect(wire == FormFailureAlert(message: "unreachable", failureID: nil))
        #expect(FormFailureAlertPlan.onChange(to: .connecting, unacknowledgedFailure: nil) == nil)
    }
}
