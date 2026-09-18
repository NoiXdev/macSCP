import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `DetailSurfacePlan.surface(…)` (jump-and-groups plan,
/// Task 1) — the one decision behind what an unconnected tab's detail pane
/// shows: Connecting, the lost or failed surface, the session overview, or
/// the connection form.
///
/// The defect these pin: the overview used to be chosen whenever the
/// connection surface answered `.form` and the form was in `.new` mode. The
/// form is also where TOFU's trust card and the text of every
/// `.needsPerson` failure and pre-dial refusal live, so a sidebar connect —
/// which always selects its row first — covered exactly the question the
/// dial was waiting on. The maintainer met it as "a second session through
/// the same jump returns to the session info": the target behind the jump
/// was new, its host key unknown, and the card sat under the overview.
///
/// No view is rendered here; what these prove is the mapping. That the view
/// switches on this answer and on nothing else is
/// `DetailSurfaceWiringGuardTests`' claim.
@Suite("Detail surface plan")
struct DetailSurfacePlanTests {
    private static let selected = StoredSession(
        name: "selected", kind: .ssh,
        ssh: StoredSSHConfig(host: "target.invalid", username: "tim", authKind: .agent))

    /// Every input at the value an idle, unconnected tab with a sidebar
    /// selection has; each test moves the one it is about.
    private static func surface(
        liveness: ConnectionLiveness? = nil,
        hostKeyPromptPending: Bool = false,
        connectAttemptFailed: Bool = false,
        formState: ConnectionViewModel.State = .idle,
        failureKind: ConnectFailureKind? = nil,
        formMode: ConnectionViewModel.FormMode = .new,
        overviewSession: StoredSession? = selected
    ) -> DetailSurface {
        DetailSurfacePlan.surface(
            liveness: liveness, hostKeyPromptPending: hostKeyPromptPending,
            connectAttemptFailed: connectAttemptFailed, formState: formState,
            failureKind: failureKind, formMode: formMode, overviewSession: overviewSession)
    }

    // MARK: - What the overview must never cover

    /// The maintainer's report. The dial is suspended in the host-key
    /// decider; the only way on is the trust card, and the card is inside
    /// the form. Crossed with every liveness, because
    /// `ConnectionSurfacePlan` already forces `.form` for a pending prompt
    /// from every one of them — including `.connecting`, which is where a
    /// sidebar dial actually is when the prompt arrives.
    @Test(arguments: [Optional<ConnectionLiveness>.none, .connecting, .connected, .degraded, .lost])
    func aPendingHostKeyPromptIsNeverCoveredByTheOverview(liveness: ConnectionLiveness?) {
        #expect(Self.surface(liveness: liveness, hostKeyPromptPending: true) == .form)
    }

    /// A rejected or changed host key, a missing or wrong key passphrase:
    /// the attempt stopped at a question only a person can answer, and the
    /// text saying so is on the form.
    @Test func aNeedsPersonFailureShowsTheFormNotTheOverview() {
        #expect(Self.surface(
            formState: .failed(message: "stopped", field: nil), failureKind: .needsPerson) == .form)
    }

    /// A refusal decided before any dial — a login set that no longer
    /// resolves, a jump whose source session is gone, a schema violation.
    /// `showFailure` and the form's own validation publish these as
    /// `.needsPerson` by construction, usually with a field to outline; the
    /// verdict-less spelling is covered too, because a `.failed` form with
    /// no verdict is not one this plan may assume was already read.
    @Test(arguments: [ConnectFailureKind?.some(.needsPerson), nil])
    func aPreDialRefusalShowsTheFormNotTheOverview(kind: ConnectFailureKind?) {
        #expect(Self.surface(
            formState: .failed(message: "refused", field: .jumpSession), failureKind: kind) == .form)
    }

    // MARK: - The positive partner

    /// Without this the three checks above would pass over a plan that had
    /// stopped offering the overview at all.
    @Test func anIdleUnconnectedTabWithASelectionShowsTheOverview() {
        #expect(Self.surface() == .overview(Self.selected))
    }

    // MARK: - Everything else is as it was

    /// A dial that failed on the wire has its own surface; once the person
    /// has left it ("Edit" clears `connectFailure`), its text has been read
    /// and the form's `.failed` state no longer holds the overview back.
    @Test func anOtherFailureAlreadyShownElsewhereDoesNotHoldTheOverviewBack() {
        #expect(Self.surface(
            formState: .failed(message: "refused", field: nil), failureKind: .other)
            == .overview(Self.selected))
    }

    @Test func anEditingFormIsNeverReplacedByTheOverview() {
        #expect(Self.surface(formMode: .edit(sessionID: Self.selected.id)) == .form)
    }

    @Test func noSelectionShowsTheForm() {
        #expect(Self.surface(overviewSession: nil) == .form)
    }

    /// The three attempt surfaces answer before the overview is considered,
    /// exactly as `ConnectionSurfacePlan` answers them.
    @Test func theAttemptSurfacesAnswerFirst() {
        #expect(Self.surface(liveness: .connecting) == .connecting)
        #expect(Self.surface(liveness: .lost) == .lost)
        #expect(Self.surface(connectAttemptFailed: true) == .failed)
    }
}
