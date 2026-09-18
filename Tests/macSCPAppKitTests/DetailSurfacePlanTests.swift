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
/// Fix round 1: the failure half is decided on
/// `ConnectionViewModel.unacknowledgedFailure` rather than on the form's
/// state and verdict. The failure cases below therefore produce their
/// marker through a real `ConnectionViewModel` and hand the plan what the
/// window's resolver hands it, so the chain from the failure to the
/// surface is what is checked, not a hand-written Bool. That the form then
/// raises the text is `FormFailureAlertPlanTests`' claim; that the view
/// switches on this answer and on nothing else is
/// `DetailSurfaceWiringGuardTests`'.
@Suite("Detail surface plan", .timeLimit(.minutes(1)))
@MainActor
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
        describesLostConnection: Bool = false,
        unacknowledgedFailure: Bool = false,
        formMode: ConnectionViewModel.FormMode = .new,
        overviewSession: StoredSession? = selected
    ) -> DetailSurface {
        DetailSurfacePlan.surface(
            liveness: liveness, hostKeyPromptPending: hostKeyPromptPending,
            connectAttemptFailed: connectAttemptFailed,
            describesLostConnection: describesLostConnection,
            unacknowledgedFailure: unacknowledgedFailure,
            formMode: formMode, overviewSession: overviewSession)
    }

    /// The form's facts as `ContentView.detailSurface(for:)` reads them.
    private static func surface(of form: ConnectionViewModel, liveness: ConnectionLiveness? = nil) -> DetailSurface {
        surface(
            liveness: liveness, hostKeyPromptPending: form.hostKeyPrompt != nil,
            unacknowledgedFailure: form.unacknowledgedFailure != nil, formMode: form.mode)
    }

    private static func form(
        _ connector: @escaping ConnectionViewModel.Connector = { _, _ in throw CancellationError() }
    ) -> ConnectionViewModel {
        let form = ConnectionViewModel(connector: connector)
        form.host = "target.invalid"
        form.port = "22"
        form.username = "tim"
        form.password = "secret-value"
        return form
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

    /// A rejected host key, a missing key passphrase: the attempt stopped at
    /// a question only a person can answer, and the text saying so is on
    /// the form.
    @Test func aNeedsPersonFailureShowsTheFormNotTheOverview() async {
        let rejected = Self.form { _, _ in throw HostKeyError.rejectedByUser }
        _ = await rejected.connect()
        #expect(rejected.lastFailureKind == .needsPerson)
        #expect(Self.surface(of: rejected) == .form)

        let passphrase = Self.form { _, _ in throw SSHKeyError.passphraseRequired }
        _ = await passphrase.connect()
        #expect(passphrase.lastFailureKind == .needsPerson)
        #expect(Self.surface(of: passphrase) == .form)
    }

    /// A refusal decided before any dial: the form's own validation, and
    /// the App's refusal through `showFailure` (a login set or jump session
    /// that no longer resolves, a `fillForm` throw).
    @Test func aPreDialRefusalShowsTheFormNotTheOverview() async {
        let validation = Self.form()
        validation.host = ""
        _ = await validation.connect()
        #expect(Self.surface(of: validation) == .form)

        let appRefusal = Self.form()
        appRefusal.showFailure(message: "refused")
        #expect(Self.surface(of: appRefusal) == .form)
    }

    /// The one update in which the mirror has not yet caught up: the
    /// failure and the cleared prompt arrive together, while `tab.liveness`
    /// still reads `.connecting`. Answering `.connecting` here would drop
    /// the form, and it would come back already failed. Read BEFORE the
    /// mirror runs, which is the whole point of this case.
    @Test func aHostKeyRejectWithLivenessStillConnectingShowsTheForm() async {
        let form = Self.form { _, _ in throw HostKeyError.rejectedByUser }
        _ = await form.connect()
        #expect(form.hostKeyPrompt == nil)
        #expect(Self.surface(of: form, liveness: .connecting) == .form)
    }

    /// On a tab describing a dropped connection the mirror sends the same
    /// failure to the lost surface, so the lag keeps its old answer rather
    /// than flashing the form for one update.
    @Test func aLaggingConnectingOnALostTabStaysConnecting() {
        #expect(Self.surface(
            liveness: .connecting, describesLostConnection: true, unacknowledgedFailure: true)
            == .connecting)
    }

    // MARK: - The positive partners

    /// Without this the checks above would pass over a plan that had
    /// stopped offering the overview at all.
    @Test func anIdleUnconnectedTabWithASelectionShowsTheOverview() {
        #expect(Self.surface() == .overview(Self.selected))
    }

    /// Once the person has dismissed the text, the overview comes back —
    /// the form does not stay on a failure that has been read, and clicking
    /// another row shows that row again.
    @Test func dismissingTheFailureBringsTheOverviewBack() throws {
        let form = Self.form()
        form.showFailure(message: "refused")
        #expect(Self.surface(of: form) == .form)
        let id = try #require(form.unacknowledgedFailure)
        form.acknowledgeFailure(id)
        #expect(Self.surface(of: form) == .overview(Self.selected))
    }

    // MARK: - Everything else is as it was

    /// A dial that failed on the wire has its own surface; once the person
    /// has left it ("Edit" clears `connectFailure`), its text has been read
    /// and nothing holds the overview back.
    @Test func aWireFailureAlreadyShownElsewhereDoesNotHoldTheOverviewBack() async {
        let form = Self.form { _, _ in throw RemoteFSError.connectionFailed(reason: "unreachable") }
        _ = await form.connect()
        #expect(form.lastFailureKind == .other)
        #expect(Self.surface(of: form) == .overview(Self.selected))
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
