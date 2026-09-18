import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `TabTitlePlan.title(…)` (jump-and-groups plan, Task
/// 3): one case per state a tab can be in, plus the precedence between
/// them and the maintainer decision that only the active tab takes the
/// overview's name.
///
/// The defect these pin: the tab strip read `SessionTab.displayTitle`,
/// which knows only "connected or not", so a tab editing, dialing or
/// describing a session said "New Connection". That the strip and the
/// window title draw this plan's answer is `TabTitleWiringGuardTests`'
/// claim, not this suite's.
@Suite("Tab title plan", .timeLimit(.minutes(1)))
@MainActor
struct TabTitlePlanTests {
    private static let target = StoredSession(
        name: "target", kind: .ssh,
        ssh: StoredSSHConfig(host: "target.invalid", username: "tim", authKind: .agent))
    private static let edited = StoredSession(
        name: "edited", kind: .ssh,
        ssh: StoredSSHConfig(host: "edited.invalid", username: "tim", authKind: .agent))
    private static let selected = StoredSession(
        name: "selected", kind: .ssh,
        ssh: StoredSSHConfig(host: "selected.invalid", username: "tim", authKind: .agent))
    private static let sessions = [target, edited, selected]

    /// Every input at the value an idle, unconnected, ACTIVE tab on the
    /// plain form has; each test moves the ones it is about.
    private static func title(
        connectedName: String? = nil,
        liveness: ConnectionLiveness? = nil,
        lostConnection: LostConnection? = nil,
        connectFailure: ConnectFailure? = nil,
        unacknowledgedFailure: Bool = false,
        attemptOrigin: UUID? = nil,
        formMode: ConnectionViewModel.FormMode = .new,
        surface: DetailSurface = .form,
        isActive: Bool = true,
        sessions: [StoredSession] = sessions
    ) -> TabTitle {
        TabTitlePlan.title(
            connectedName: connectedName, liveness: liveness, lostConnection: lostConnection,
            connectFailure: connectFailure, unacknowledgedFailure: unacknowledgedFailure,
            attemptOrigin: attemptOrigin, formMode: formMode, surface: surface,
            isActive: isActive, sessions: sessions)
    }

    // MARK: - One case per state

    @Test func aConnectedTabIsTitledByItsSession() {
        #expect(Self.title(connectedName: "prod-web", liveness: .connected) == .named("prod-web"))
    }

    @Test func aConnectingTabIsTitledByTheSessionItDials() {
        #expect(Self.title(
            liveness: .connecting, attemptOrigin: Self.target.id, surface: .connecting)
            == .named("target"))
    }

    /// The dial waits on the trust card, which is on the form — the surface
    /// is `.form`, and the tab is still about the session being dialed.
    @Test func aConnectingTabWaitingOnAHostKeyIsStillTitledByItsTarget() {
        #expect(Self.title(
            liveness: .connecting, attemptOrigin: Self.target.id, surface: .form)
            == .named("target"))
    }

    @Test func aFailedTabIsTitledByTheSessionItFailedToReach() {
        #expect(Self.title(
            connectFailure: ConnectFailure(storedSessionID: Self.target.id), surface: .failed)
            == .named("target"))
    }

    /// A rejected host key or a missing passphrase: no failed surface, the
    /// text is on the form, and the tab still names what it was dialing.
    /// Produced through a real form, so the marker and the origin are the
    /// ones the failure actually leaves.
    @Test func aFailureStillUnreadOnTheFormKeepsItsTargetsName() async {
        let form = ConnectionViewModel(connector: { _, _ in throw HostKeyError.rejectedByUser })
        form.host = "target.invalid"
        form.port = "22"
        form.username = "tim"
        _ = await form.connect(origin: Self.target.id)
        #expect(form.unacknowledgedFailure != nil)
        #expect(Self.title(
            unacknowledgedFailure: form.unacknowledgedFailure != nil,
            attemptOrigin: form.attemptOrigin, surface: .form) == .named("target"))
    }

    @Test func aLostTabIsTitledByTheSessionThatDropped() {
        #expect(Self.title(
            liveness: .lost,
            lostConnection: LostConnection(reason: .probeGaveUp, storedSessionID: Self.target.id),
            surface: .lost) == .named("target"))
    }

    /// The mode is produced by `beginEditing`, the one door every edit
    /// route ends at, rather than written by hand.
    @Test func anEditingTabIsTitledByTheSessionItEdits() {
        let form = ConnectionViewModel(connector: { _, _ in throw CancellationError() })
        form.beginEditing(Self.edited)
        #expect(Self.title(formMode: form.mode) == .named("edited"))
    }

    @Test func theActiveTabShowingTheOverviewIsTitledByTheShownSession() {
        #expect(Self.title(surface: .overview(Self.selected)) == .named("selected"))
    }

    @Test func aTabWithNothingToNameIsANewConnection() {
        #expect(Self.title() == .newConnection)
    }

    // MARK: - The maintainer decision

    /// The overview's session is the window's sidebar selection for every
    /// unrestored tab, so a background tab's surface resolves to the same
    /// overview the active one shows. It is not showing it, and keeps its
    /// own name — here, none.
    @Test func anInactiveTabDoesNotTakeTheOverviewsName() {
        #expect(Self.title(surface: .overview(Self.selected), isActive: false) == .newConnection)
    }

    /// …but its own attempt, edit or connection still names it.
    @Test func anInactiveTabKeepsItsOwnAttemptsName() {
        #expect(Self.title(
            connectFailure: ConnectFailure(storedSessionID: Self.target.id), surface: .failed,
            isActive: false) == .named("target"))
        #expect(Self.title(formMode: .edit(sessionID: Self.edited.id), isActive: false) == .named("edited"))
        #expect(Self.title(connectedName: "prod-web", isActive: false) == .named("prod-web"))
    }

    // MARK: - Precedence

    /// A connected tab never shows the form or the overview, so nothing
    /// else may name it.
    @Test func theConnectedNameWinsOverEveryOtherFact() {
        #expect(Self.title(
            connectedName: "prod-web", liveness: .connected,
            connectFailure: ConnectFailure(storedSessionID: Self.target.id),
            formMode: .edit(sessionID: Self.edited.id), surface: .overview(Self.selected))
            == .named("prod-web"))
    }

    /// A dropped connection redialing names the session that dropped, not
    /// a fresh origin.
    @Test func aLostConnectionWinsOverTheFormsOrigin() {
        #expect(Self.title(
            liveness: .connecting,
            lostConnection: LostConnection(reason: .reconnectFailed, storedSessionID: Self.target.id),
            attemptOrigin: Self.edited.id, surface: .connecting) == .named("target"))
    }

    /// An attempt is what the tab is about while it runs.
    @Test func anAttemptWinsOverTheEditedSession() {
        #expect(Self.title(
            liveness: .connecting, attemptOrigin: Self.target.id,
            formMode: .edit(sessionID: Self.edited.id), surface: .connecting) == .named("target"))
    }

    /// An origin left over from an attempt that is over does not speak for
    /// the tab: with no dial in flight and no unread failure, the overview
    /// the pane shows names it.
    @Test func aStaleOriginDoesNotOutliveItsAttempt() {
        #expect(Self.title(attemptOrigin: Self.target.id, surface: .overview(Self.selected))
            == .named("selected"))
    }

    // MARK: - Nothing to resolve

    /// An ad-hoc attempt has no stored session; the tab falls to the next
    /// rule, not to the name of some other session.
    @Test func anAdHocAttemptHasNoName() {
        #expect(Self.title(liveness: .connecting, attemptOrigin: nil, surface: .connecting) == .newConnection)
        #expect(Self.title(connectFailure: ConnectFailure(storedSessionID: nil), surface: .failed)
            == .newConnection)
        #expect(Self.title(
            liveness: .lost, lostConnection: LostConnection(reason: .probeGaveUp, storedSessionID: nil),
            surface: .lost) == .newConnection)
    }

    /// A session deleted while a tab still points at it names nothing.
    @Test func aDeletedSessionNamesNothing() {
        #expect(Self.title(
            connectFailure: ConnectFailure(storedSessionID: Self.target.id), surface: .failed,
            sessions: []) == .newConnection)
        #expect(Self.title(formMode: .edit(sessionID: Self.edited.id), sessions: []) == .newConnection)
    }

    /// An empty name is not a title.
    @Test func anEmptyNameDoesNotAnswer() {
        let unnamed = StoredSession(
            name: "", kind: .ssh,
            ssh: StoredSSHConfig(host: "unnamed.invalid", username: "tim", authKind: .agent))
        #expect(Self.title(connectedName: "") == .newConnection)
        #expect(Self.title(surface: .overview(unnamed), sessions: [unnamed]) == .newConnection)
    }

    // MARK: - The two renderings

    @Test func theStripAndTheWindowRenderTheSameName() {
        #expect(TabTitle.named("prod-web").tabLabel == "prod-web")
        #expect(TabTitle.named("prod-web").windowTitle == "macSCP — prod-web")
    }

    /// The strip's label is the catalogue's; the window says the app's
    /// name, as an unconnected window always has.
    @Test func newConnectionRendersTheCatalogueLabelAndTheBareAppName() {
        #expect(TabTitle.newConnection.tabLabel
            == L10n.string("tabs.newConnection", "ZZ-UNRESOLVED-ZZ"))
        #expect(TabTitle.newConnection.tabLabel.isEmpty == false)
        #expect(TabTitle.newConnection.windowTitle == "macSCP")
    }

    /// `displayTitle`, the fallback for callers with no window state,
    /// renders through the same type, so the two cannot spell the
    /// fallback differently.
    @Test func displayTitleRendersThroughTheSameType() {
        let tab = SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in throw CancellationError() }),
            certificateBridge: CertificatePromptBridge(), limiter: BandwidthLimiter(), maxConcurrent: 1)
        #expect(tab.displayTitle == TabTitle.newConnection.tabLabel)
        tab.titleName = "prod-web"
        #expect(tab.displayTitle == TabTitle.named("prod-web").tabLabel)
    }
}
