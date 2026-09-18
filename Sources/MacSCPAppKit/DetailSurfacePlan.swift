import Foundation
import macSCPCore

/// What an unconnected tab's detail pane shows (jump-and-groups plan, Task
/// 1): one of the three attempt surfaces, the read-only session overview,
/// or the connection form.
///
/// `ConnectionAttemptSurface`'s three attempt cases, plus the overview.
/// The overview carries the session it describes, so the view that renders
/// it has nothing left to look up — and so nothing left to decide.
enum DetailSurface: Equatable {
    /// "Connecting…" with a Cancel control (`ConnectingAttemptView`).
    case connecting
    /// A connection that existed and dropped (`LostConnectionView`).
    case lost
    /// An attempt that failed on the wire (`ConnectFailureView`).
    case failed
    /// The connection form — also the only place TOFU's trust card is
    /// rendered, and where a `.needsPerson` failure's text is shown.
    case form
    /// The stored session the sidebar (or a restored tab) points at,
    /// described read-only (`SessionOverviewView`).
    case overview(StoredSession)
}

/// The one decision behind `DetailSurface` — pulled out of the view body
/// in `ContentView+Detail.swift`, where it used to be an if/else chain,
/// for the reason every other decision on that branch was: nothing in this
/// project can render a view in a test, and a plain function can be
/// crossed with every input.
///
/// Takes plain values. `ContentView.detailSurface(for:)` is the one place
/// they are read off a tab; this type never sees the tab or the window.
enum DetailSurfacePlan {
    /// The attempt surfaces answer first, exactly as
    /// `ConnectionSurfacePlan.surface` decides them — including its rule
    /// that a pending host-key prompt forces the form from every liveness.
    /// A connecting, lost or failed tab is describing an ATTEMPT, and an
    /// overview of the session it was attempting would replace an
    /// explanation with a description.
    ///
    /// One exception to that order (fix round 1): a `.connecting` answer
    /// while `unacknowledgedFailure` is set, on a tab not describing a
    /// dropped connection, is `.form`. That combination is the one update
    /// in which `ConnectAttemptLivenessMirror` has not caught up — the
    /// failure (and, for a rejected key, the cleared prompt) is already
    /// written, `tab.liveness` still reads `.connecting` until the mirror's
    /// change handler runs. Answering `.connecting` there drops the form
    /// that was showing the trust card, and it comes back one update later
    /// already failed. A NEW attempt cannot produce it: `connect()` moves
    /// the state to `.connecting`, and the marker reads `nil` whenever the
    /// state is not `.failed`. On a tab describing a dropped connection the
    /// mirror sends the failure to the lost surface instead, so the lag
    /// keeps its old answer there rather than flashing the form.
    ///
    /// Only where the answer is the form may the overview stand in for it,
    /// and only when nothing on the form is waiting for a person:
    ///
    /// * no host-key prompt is pending. The trust card is rendered inside
    ///   the form and nowhere else, and the dial is suspended on it; an
    ///   overview in its place is a connect that waits for an answer
    ///   nobody can see. This was the maintainer's report of 2026-09-18 —
    ///   every sidebar connect selects its row first, so the selection was
    ///   always there to cover the card. `ConnectionSurfacePlan` already
    ///   answers `.form` for a pending prompt; this repeats the fact here
    ///   because `.form` alone does not say WHY, and the overview may only
    ///   replace a form that is idle.
    /// * no failure is unacknowledged (`ConnectionViewModel
    ///   .unacknowledgedFailure`, whose doc comment says which failures set
    ///   it and why `.other` does not). Its text is on the form, raised by
    ///   `FormFailureAlertPlan`; once the person dismisses it the overview
    ///   returns, so a read failure does not keep the tab on the form.
    /// * `formMode` is `.new` — an `.edit` form holds a draft of some
    ///   session, and an overview would drop it out of sight. Every edit
    ///   route ends at `ConnectionViewModel.beginEditing`, so the form's
    ///   own mode covers them all;
    /// * there is a session to describe (`overviewSession`, the tab's own
    ///   restored pointer or the window's sidebar selection).
    static func surface(
        liveness: ConnectionLiveness?, hostKeyPromptPending: Bool, connectAttemptFailed: Bool,
        describesLostConnection: Bool, unacknowledgedFailure: Bool,
        formMode: ConnectionViewModel.FormMode, overviewSession: StoredSession?
    ) -> DetailSurface {
        switch ConnectionSurfacePlan.surface(
            for: liveness, hostKeyPromptPending: hostKeyPromptPending,
            connectAttemptFailed: connectAttemptFailed)
        {
        case .connecting:
            return unacknowledgedFailure && !describesLostConnection ? .form : .connecting
        case .lost: return .lost
        case .failed: return .failed
        case .form:
            guard let overviewSession, formMode == .new, !hostKeyPromptPending, !unacknowledgedFailure
            else { return .form }
            return .overview(overviewSession)
        }
    }
}
