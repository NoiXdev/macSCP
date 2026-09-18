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
    /// Only where that answer is the form may the overview stand in for
    /// it, and only when nothing on the form is waiting for a person:
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
    /// * the form holds no failure a person must read
    ///   (`formHoldsTextAPersonMustRead`);
    /// * `formMode` is `.new` — an `.edit` form holds a draft of some
    ///   session, and an overview would drop it out of sight. Every edit
    ///   route ends at `ConnectionViewModel.beginEditing`, so the form's
    ///   own mode covers them all;
    /// * there is a session to describe (`overviewSession`, the tab's own
    ///   restored pointer or the window's sidebar selection).
    static func surface(
        liveness: ConnectionLiveness?, hostKeyPromptPending: Bool, connectAttemptFailed: Bool,
        formState: ConnectionViewModel.State, failureKind: ConnectFailureKind?,
        formMode: ConnectionViewModel.FormMode, overviewSession: StoredSession?
    ) -> DetailSurface {
        switch ConnectionSurfacePlan.surface(
            for: liveness, hostKeyPromptPending: hostKeyPromptPending,
            connectAttemptFailed: connectAttemptFailed)
        {
        case .connecting: return .connecting
        case .lost: return .lost
        case .failed: return .failed
        case .form:
            guard let overviewSession, formMode == .new, !hostKeyPromptPending,
                  !formHoldsTextAPersonMustRead(formState: formState, failureKind: failureKind)
            else { return .form }
            return .overview(overviewSession)
        }
    }

    /// Whether the form's `.failed` state is text nobody has read yet.
    ///
    /// Every verdict except `.other`. `.needsPerson` is, by
    /// `ConnectFailureKind`'s own definition, an attempt stopped at
    /// something only a person can answer — a rejected or changed host key,
    /// a missing or wrong key passphrase — and it is also the verdict of
    /// every refusal decided before the dial (a login set or jump session
    /// that no longer resolves, a schema violation, a `fillForm` throw),
    /// which `ConnectionViewModel.showFailure` and the form's own
    /// validation publish as `.needsPerson` by construction.
    /// On a tab with no dropped connection to describe,
    /// `ConnectAttemptLivenessPlan.write` sends all of these to the form
    /// (`.clear`) precisely because the form is where their text is shown.
    ///
    /// `.other` is the one verdict with a surface of its own: a dial that
    /// failed on the wire is described by the failed-connect surface (or,
    /// on a tab whose connection dropped, the lost surface), which
    /// `ConnectionSurfacePlan` answers before the form is considered. Its
    /// text reaches the form only after the person has left that surface —
    /// "Edit" clears `connectFailure` — so it has been read, and holding
    /// the overview back for it would change what that surface's own exit
    /// has always led to.
    ///
    /// A `.failed` state with NO verdict counts as unread. `fail(_:kind:)`
    /// is the only writer of `.failed` and always writes one, so the
    /// combination does not arise from the view model; this plan takes
    /// plain values, and the direction to err in is showing a failure
    /// rather than covering it.
    static func formHoldsTextAPersonMustRead(
        formState: ConnectionViewModel.State, failureKind: ConnectFailureKind?
    ) -> Bool {
        guard case .failed = formState else { return false }
        return failureKind != .other
    }
}
