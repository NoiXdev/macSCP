import Foundation
import macSCPCore

/// The connection form's failure alert, as the form presents it: the text,
/// and the failure it belongs to, so dismissing the alert can acknowledge
/// that failure and no other (`ConnectionViewModel.acknowledgeFailure`).
///
/// `failureID` is `nil` for a failure nobody has to acknowledge — a wire
/// failure, which has the failed-connect surface of its own.
struct FormFailureAlert: Equatable {
    let message: String
    let failureID: UUID?
}

/// When the connection form raises its failure alert (jump-and-groups plan,
/// Task 1, fix round 1) — the one place the form shows a `.failed` state's
/// text.
///
/// Two moments, one decision each:
///
/// * **A state change** while the form is mounted: every transition into
///   `.failed`, as the form has always done. Wire failures included — an
///   ad-hoc connect's own validation, a Save refused on the spot.
/// * **The form appearing** into a state that is already `.failed`: only
///   while that failure is unacknowledged. This is the fix. The paths that
///   send a failure a person must read to a form that was not on screen
///   mount it already failed — a pre-dial refusal replacing the session
///   overview, a missing passphrase replacing "Connecting…" — and a change
///   handler never sees a change it was not mounted for. (A rejected host
///   key is the one such failure raised by the change handler: the form is
///   already mounted for the trust card, and `DetailSurfacePlan` keeps it
///   through the update in which `tab.liveness` still lags.)
///
/// Raising on appear only while unacknowledged is what keeps the alert from
/// coming back: once the person dismisses it the marker is gone, so a tab
/// switch or "Edit" remounts the form silently. And the two moments never
/// raise the same failure twice in one mount: `onAppear` runs once, at the
/// mount; `onChange` runs only for transitions after it.
enum FormFailureAlertPlan {
    static func onAppear(
        state: ConnectionViewModel.State, unacknowledgedFailure: UUID?
    ) -> FormFailureAlert? {
        guard case .failed(let message, _) = state, let unacknowledgedFailure else { return nil }
        return FormFailureAlert(message: message, failureID: unacknowledgedFailure)
    }

    static func onChange(
        to state: ConnectionViewModel.State, unacknowledgedFailure: UUID?
    ) -> FormFailureAlert? {
        guard case .failed(let message, _) = state else { return nil }
        return FormFailureAlert(message: message, failureID: unacknowledgedFailure)
    }
}
