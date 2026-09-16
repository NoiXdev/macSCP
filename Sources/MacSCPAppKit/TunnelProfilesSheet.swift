import SwiftUI
import macSCPCore

/// The profile form's eight fields, and the one decision they carry: what
/// `TunnelProfile.Kind` they mean, or why they mean none.
///
/// A value rather than eight `@State` properties read inside a view body,
/// for the reason every other plan type in this target exists: the rules the
/// design states — "port 1–65535, host non-empty for local/remote" — are
/// then measurable without rendering anything (`TunnelProfileDraftTests`).
///
/// The two directions are one type on purpose. `init(profile:)` renders a
/// stored profile into fields and `profile(id:sessionID:)` reads them back,
/// so a field that one side forgets is a round trip the tests catch rather
/// than a value the sheet silently drops on every edit.
struct TunnelProfileDraft: Equatable {
    /// Which of the three shapes the form is filled in for. A tag rather
    /// than a `TunnelProfile.Kind`, because a half-filled form has ports
    /// that are not numbers yet — the `Kind` is what comes OUT of a valid
    /// draft, never what holds it.
    enum KindTag: String, CaseIterable, Equatable {
        case local
        case remote
        case dynamic
    }

    /// Why a draft is not a profile. One case per field the user can fix,
    /// so the sheet says which line is wrong instead of "invalid".
    ///
    /// `Error` only so it can be a `Result`'s failure — nothing throws it,
    /// and its text is chosen at the view, where the catalogue is.
    enum Invalid: Error, Equatable {
        case nameEmpty
        case listenPortInvalid
        case targetHostEmpty
        case targetPortInvalid
    }

    var name: String = ""
    var kindTag: KindTag = .local
    /// The interface the listener binds. Blank means loopback — see
    /// `resolvedBind`. The default is `TunnelSpec.defaultBind`, the same
    /// address a forwarding spec that omits its bind means, so the field
    /// prefilled here and the text a command line accepts cannot disagree
    /// about what "no bind given" is.
    var bind: String = TunnelSpec.defaultBind
    /// The port that is LISTENED on: on this Mac for `.local`/`.dynamic`, on
    /// the server for `.remote`.
    var listenPort: String = ""
    /// Where an accepted connection is taken: behind the server for
    /// `.local`, on this Mac for `.remote`, and nowhere for `.dynamic` —
    /// a SOCKS5 client names its own destination per connection.
    var targetHost: String = ""
    var targetPort: String = ""
    var autoStart: TunnelProfile.AutoStart = .off
    var reconnects: Bool = false

    init() {}

    /// The stored profile, rendered back into fields.
    init(profile: TunnelProfile) {
        name = profile.name
        autoStart = profile.autoStart
        reconnects = profile.reconnects
        switch profile.kind {
        case .local(let bind, let localPort, let host, let remotePort):
            kindTag = .local
            self.bind = bind
            listenPort = String(localPort)
            targetHost = host
            targetPort = String(remotePort)
        case .remote(let bind, let remotePort, let localHost, let localPort):
            kindTag = .remote
            self.bind = bind
            listenPort = String(remotePort)
            targetHost = localHost
            targetPort = String(localPort)
        case .dynamic(let bind, let localPort):
            kindTag = .dynamic
            self.bind = bind
            listenPort = String(localPort)
            targetHost = ""
            targetPort = ""
        }
    }

    /// Whether this kind reaches a named destination at all — the one place
    /// the form's second half is decided, read by both the validation below
    /// and the view that hides those two fields.
    var namesATarget: Bool { kindTag != .dynamic }

    /// A blank bind is the loopback default rather than a refusal: the field
    /// NARROWS who may reach the listener, and leaving it empty asks for the
    /// safe answer, not for every interface on the machine.
    private var resolvedBind: String {
        let trimmed = bind.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? TunnelSpec.defaultBind : trimmed
    }

    /// The profile these fields describe, or the first reason they describe
    /// none.
    ///
    /// `id` and `sessionID` come from the caller: the sheet keeps a profile's
    /// identity across an edit (so the store updates rather than duplicates),
    /// and a profile belongs to the session whose sheet is open.
    func profile(id: UUID, sessionID: UUID) -> Result<TunnelProfile, Invalid> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.nameEmpty) }
        guard let listening = Self.port(listenPort) else { return .failure(.listenPortInvalid) }

        let kind: TunnelProfile.Kind
        if namesATarget {
            let host = targetHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return .failure(.targetHostEmpty) }
            guard let target = Self.port(targetPort) else { return .failure(.targetPortInvalid) }
            kind = kindTag == .local
                ? .local(bind: resolvedBind, localPort: listening, host: host, remotePort: target)
                : .remote(
                    bind: resolvedBind, remotePort: listening, localHost: host, localPort: target)
        } else {
            kind = .dynamic(bind: resolvedBind, localPort: listening)
        }

        return .success(TunnelProfile(
            id: id, sessionID: sessionID, name: trimmedName, kind: kind,
            autoStart: autoStart, reconnects: reconnects))
    }

    /// A port number, or `nil`. `0` is refused here rather than read as "let
    /// the system choose": the design's form validates 1–65535, and a remote
    /// forward on a server-chosen port is refused one layer down anyway
    /// (`CitadelFileSystem`'s port-0 refusal, and the fork debt behind it).
    private static func port(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
            (1...65535).contains(value)
        else { return nil }
        return value
    }
}

/// Which of the window's two forwarding sheets is up — at most ONE, which is
/// the whole point of the type (fix round 1).
///
/// Round 1 attached two `.sheet` modifiers to the same view. macOS SwiftUI
/// presents one sheet per presenter: the second modifier's sheet never
/// appeared, so a host-key question raised by the profile sheet's own Start
/// button was invisible, its dial parked on a continuation nobody could
/// resolve, and `TunnelRunner.stop()` — which waits for that run task —
/// would have held the quit behind it.
///
/// So the window presents one sheet chosen from both sources, and the
/// profile sheet presents the prompt ITSELF when it is the one up (a sheet
/// on a sheet is an ordinary nested presentation; two sheets on one view are
/// not). The precedence below is what makes that split work: while the
/// profile sheet is open the window keeps showing it, and the question is
/// the sheet's own to draw.
enum TunnelSheetItem: Identifiable, Equatable {
    case profiles(StoredSession)
    case hostKey(HostKeyCandidate)

    /// Stable per presented thing: the session's id, or the candidate's full
    /// identity (host, port, key type and the PUBLIC key). A public key is
    /// not a secret; nothing here carries one.
    var id: String {
        switch self {
        case .profiles(let session): return "profiles:\(session.id.uuidString)"
        case .hostKey(let candidate):
            return "hostkey:\(candidate.host):\(candidate.port):\(candidate.keyType):"
                + candidate.publicKeyBase64
        }
    }
}

/// The choice above, as a value — so "the prompt never replaces the profile
/// sheet" is measured rather than read out of a view body.
enum TunnelSheetPlan {
    static func item(
        profilesSession: StoredSession?, hostKeyCandidate: HostKeyCandidate?
    ) -> TunnelSheetItem? {
        if let profilesSession { return .profiles(profilesSession) }
        if let hostKeyCandidate { return .hostKey(hostKeyCandidate) }
        return nil
    }
}

/// The port-forwarding profiles of one connection: the table of what exists
/// and the form that edits one (port-forwarding plan, Task 6; design,
/// "The profile overlay").
///
/// **This sheet dials nothing.** Start and stop go to `TunnelManager`, which
/// owns the runner; the sheet holds the window's host-key decider only to
/// hand it on. That split is what `TunnelMenuWiringGuardTests` reads: a
/// sheet that connected for itself would answer the TOFU question in a place
/// no test reaches.
struct TunnelProfilesSheet: View {
    let session: StoredSession
    let manager: TunnelManager
    /// The window's answer to an unknown host key — the same decider the
    /// context menu hands in. Never `.refusing` here: someone is looking at
    /// this sheet, so they can be asked.
    let decider: HostKeyDecider
    /// The bridge that decider asks, so the question can be drawn HERE while
    /// this sheet is up — see `TunnelSheetItem` for why the window cannot
    /// draw it at the same time.
    let bridge: TunnelHostKeyPromptBridge
    let onClose: () -> Void

    /// Which stored profile the form is editing, or `nil` while it describes
    /// a new one.
    @State private var editingID: UUID?
    @State private var draft = TunnelProfileDraft()
    @State private var selection: UUID?
    @State private var errorMessage: String?

    private var profiles: [TunnelProfile] { manager.profiles(for: session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("tunnel.sheet.title", "Port forwarding")).font(.headline)
            Text(session.name).font(.caption).foregroundStyle(DesignTokens.inkSecondary)

            profileTable

            HStack {
                Button(L10n.string("tunnel.action.new", "New forwarding")) { beginNew() }
                Button(L10n.string("tunnel.action.delete", "Delete"), role: .destructive) {
                    Task { await deleteSelected() }
                }
                .disabled(selection == nil)
                Spacer()
            }

            Divider()
            form

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Text(L10n.string(
                "tunnel.help.unsupportedSessions",
                "Forwardings are not available for connections that use a jump host or a saved login: a forwarding opens its own connection, and that path supports neither."))
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The limit the activation reload accepts (CLI sessions and
            // tunnels plan, Task 5): the app re-reads `tunnels.json` when it
            // becomes active, so a profile the CLI edited shows its new
            // values here at once — but the runner behind a RUNNING
            // forwarding is keyed by profile id and is deliberately left
            // alone, so what it forwards is still what it was started with.
            // Said here because this table is where the two can be seen to
            // disagree.
            Text(L10n.string(
                "tunnel.help.externalEdits",
                "A forwarding edited outside the app keeps running as it was until you stop and start it."))
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { onClose() }
                    .buttonStyle(.polished)
                Button(L10n.string("tunnel.action.save", "Save")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.polishedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .onChange(of: selection) { _, newValue in loadSelection(newValue) }
        // The unknown-host-key question for a forwarding STARTED FROM HERE.
        // Nested inside this sheet on purpose: the window is already
        // presenting this one, and a second sheet on the same presenter
        // would simply never appear (`TunnelSheetItem`). Dismissing it any
        // way but by answering refuses, so no dial is left on a
        // continuation nothing resolves.
        .sheet(
            isPresented: Binding(
                get: { bridge.currentCandidate != nil },
                set: { isPresented in if !isPresented { bridge.resolve(trust: false) } })
        ) {
            if let candidate = bridge.currentCandidate {
                TunnelHostKeyPromptView(
                    candidate: candidate,
                    onTrust: { bridge.resolve(trust: true) },
                    onCancel: { bridge.resolve(trust: false) })
            }
        }
    }

    // MARK: - The table

    private var profileTable: some View {
        Table(profiles, selection: $selection) {
            TableColumn(L10n.string("tunnel.column.name", "Name")) { profile in
                Text(profile.name)
            }
            TableColumn(L10n.string("tunnel.column.kind", "Kind")) { profile in
                Text(Self.kindLabel(profile.kind))
            }
            TableColumn(L10n.string("tunnel.column.listen", "Listens on")) { profile in
                Text(Self.listenLabel(profile.kind))
            }
            TableColumn(L10n.string("tunnel.column.target", "Target")) { profile in
                Text(Self.targetLabel(profile.kind))
            }
            TableColumn(L10n.string("tunnel.column.autoStart", "Starts")) { profile in
                Text(Self.autoStartLabel(profile.autoStart))
            }
            TableColumn(L10n.string("tunnel.column.state", "State")) { profile in
                // The failure sentence is `DialSupport.reason(for:)`'s own,
                // shown verbatim — re-mapping it here would put a second
                // spelling of the same finding in the app.
                Text(Self.stateLabel(manager.state(of: profile.id)))
            }
            TableColumn(L10n.string("tunnel.column.action", "Action")) { profile in
                if TunnelManager.Aggregate.isRunning(manager.state(of: profile.id)) {
                    Button(L10n.string("tunnel.action.stop", "Stop")) {
                        Task { await manager.stop(profile) }
                    }
                } else {
                    Button(L10n.string("tunnel.action.start", "Start")) {
                        Task { await manager.start(profile, decider: decider) }
                    }
                }
            }
        }
        .frame(minHeight: 180)
        .overlay {
            if profiles.isEmpty {
                Text(L10n.string("tunnel.empty", "No forwardings for this connection yet."))
                    .font(.callout)
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
        }
    }

    // MARK: - The form

    @ViewBuilder
    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text(L10n.string("tunnel.form.name", "Name"))
                TextField("", text: $draft.name)
            }
            GridRow {
                Text(L10n.string("tunnel.form.kind", "Kind"))
                Picker("", selection: $draft.kindTag) {
                    ForEach(TunnelProfileDraft.KindTag.allCases, id: \.self) { tag in
                        Text(Self.kindTagLabel(tag)).tag(tag)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            GridRow {
                Text(L10n.string("tunnel.form.bind", "Listen address"))
                HStack(spacing: 8) {
                    TextField("", text: $draft.bind).frame(width: 160)
                    Text(L10n.string("tunnel.form.listenPort", "Port"))
                    TextField("", text: $draft.listenPort).frame(width: 90)
                }
            }
            if draft.namesATarget {
                GridRow {
                    Text(L10n.string("tunnel.form.targetHost", "Target host"))
                    HStack(spacing: 8) {
                        TextField("", text: $draft.targetHost).frame(width: 160)
                        Text(L10n.string("tunnel.form.targetPort", "Port"))
                        TextField("", text: $draft.targetPort).frame(width: 90)
                    }
                }
            }
            GridRow {
                Text(L10n.string("tunnel.form.autoStart", "Start automatically"))
                Picker("", selection: $draft.autoStart) {
                    ForEach(TunnelProfile.AutoStart.allCases, id: \.self) { when in
                        Text(Self.autoStartLabel(when)).tag(when)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            GridRow {
                Text(L10n.string("tunnel.form.reconnects", "Reconnect"))
                Toggle(
                    L10n.string(
                        "tunnel.form.reconnects.footer",
                        "Dial again after the connection drops, backing off 2, 4, 8 … up to 60 seconds"),
                    isOn: $draft.reconnects)
            }
        }
    }

    // MARK: - Actions

    private func beginNew() {
        editingID = nil
        selection = nil
        draft = TunnelProfileDraft()
        errorMessage = nil
    }

    private func loadSelection(_ id: UUID?) {
        guard let id, let profile = profiles.first(where: { $0.id == id }) else { return }
        editingID = id
        draft = TunnelProfileDraft(profile: profile)
        errorMessage = nil
    }

    private func save() async {
        switch draft.profile(id: editingID ?? UUID(), sessionID: session.id) {
        case .failure(let reason):
            errorMessage = Self.message(for: reason)
        case .success(let profile):
            do {
                try await manager.save(profile)
                editingID = profile.id
                selection = profile.id
                errorMessage = nil
            } catch {
                errorMessage = Self.writeFailureMessage(for: error, during: .save)
            }
        }
    }

    private func deleteSelected() async {
        guard let selection, let profile = profiles.first(where: { $0.id == selection }) else {
            return
        }
        do {
            try await manager.remove(profile)
            self.selection = nil
            beginNew()
        } catch {
            errorMessage = Self.writeFailureMessage(for: error, during: .delete)
        }
    }

    // MARK: - Text

    /// Which write failed.
    enum WriteAction {
        case save, delete
    }

    /// The line under the form when a save or a delete threw.
    ///
    /// An unreadable `tunnels.json` gets its own sentence, naming the file,
    /// for either action: the store refused the write and changed nothing,
    /// and the one thing the person can do is inspect that file. The
    /// generic lines would print this error's `localizedDescription`, which
    /// for a Swift enum is a type name and a case number.
    static func writeFailureMessage(for error: any Error, during action: WriteAction) -> String {
        if case TunnelStoreError.unreadable(let path) = error {
            return String(
                format: L10n.string(
                    "tunnel.store.unreadable",
                    "The forwarding list could not be read, so it was not changed. Check %@."),
                path)
        }
        switch action {
        case .save:
            return String(
                format: L10n.string("tunnel.error.save %@", "Could not save: %@"),
                error.localizedDescription)
        case .delete:
            return String(
                format: L10n.string("tunnel.error.delete %@", "Could not delete: %@"),
                error.localizedDescription)
        }
    }

    private static func message(for reason: TunnelProfileDraft.Invalid) -> String {
        switch reason {
        case .nameEmpty:
            return L10n.string("tunnel.error.name", "Give the forwarding a name.")
        case .listenPortInvalid:
            return L10n.string(
                "tunnel.error.listenPort", "The listening port must be between 1 and 65535.")
        case .targetHostEmpty:
            return L10n.string("tunnel.error.targetHost", "Name the host this forwarding reaches.")
        case .targetPortInvalid:
            return L10n.string(
                "tunnel.error.targetPort", "The target port must be between 1 and 65535.")
        }
    }

    static func kindTagLabel(_ tag: TunnelProfileDraft.KindTag) -> String {
        switch tag {
        case .local: return L10n.string("tunnel.kind.local", "Local (-L)")
        case .remote: return L10n.string("tunnel.kind.remote", "Remote (-R)")
        case .dynamic: return L10n.string("tunnel.kind.dynamic", "Dynamic (SOCKS5)")
        }
    }

    static func kindLabel(_ kind: TunnelProfile.Kind) -> String {
        switch kind {
        case .local: return kindTagLabel(.local)
        case .remote: return kindTagLabel(.remote)
        case .dynamic: return kindTagLabel(.dynamic)
        }
    }

    /// Where the listener sits — this Mac for `.local`/`.dynamic`, the
    /// server for `.remote`. Pure data interpolation, identical in every
    /// locale.
    static func listenLabel(_ kind: TunnelProfile.Kind) -> String {
        switch kind {
        case .local(let bind, let localPort, _, _): return "\(bind):\(localPort)"
        case .remote(let bind, let remotePort, _, _): return "\(bind):\(remotePort)"
        case .dynamic(let bind, let localPort): return "\(bind):\(localPort)"
        }
    }

    static func targetLabel(_ kind: TunnelProfile.Kind) -> String {
        switch kind {
        case .local(_, _, let host, let remotePort): return "\(host):\(remotePort)"
        case .remote(_, _, let localHost, let localPort): return "\(localHost):\(localPort)"
        case .dynamic: return L10n.string("tunnel.target.negotiated", "Chosen per connection")
        }
    }

    static func autoStartLabel(_ when: TunnelProfile.AutoStart) -> String {
        switch when {
        case .off: return L10n.string("tunnel.autoStart.off", "By hand")
        case .appStart: return L10n.string("tunnel.autoStart.appStart", "At launch")
        case .login: return L10n.string("tunnel.autoStart.login", "At login")
        }
    }

    /// The state, as one line. `.failed` carries the sentence Core already
    /// audited (`DialSupport.reason(for:)`) and it is shown as it is — the
    /// hand-off from Task 5 is explicit that it must never be re-mapped.
    ///
    /// **That sentence is English on every localized surface, by
    /// construction**, and the four places it reaches are this column, the
    /// autostart sheet's state column, the Dock menu's tooltip and the
    /// sidebar glyph's tooltip. It cannot be localized from here: `TunnelState
    /// .failed(reason:)` carries the rendered text and not the case it was
    /// rendered from, so the App has nothing left to map — a translation
    /// would have to guess the failure back out of its own message. Recorded
    /// as a limit in the port-forwarding design and as a row in
    /// `docs/BACKLOG.md` (Interface), whose fix shape is a typed failure on
    /// the state, mapped through `L10n` here.
    static func stateLabel(_ state: TunnelState) -> String {
        switch state {
        case .stopped: return L10n.string("tunnel.state.stopped", "Stopped")
        case .connecting: return L10n.string("tunnel.state.connecting", "Connecting…")
        case .active(let connections):
            return connections == 0
                ? L10n.string("tunnel.state.active", "Active")
                : String(
                    format: L10n.string("tunnel.state.activeConnections %lld", "Active (%lld)"),
                    connections)
        case .reconnecting(let attempt):
            return String(
                format: L10n.string("tunnel.state.reconnecting %lld", "Reconnecting, attempt %lld"),
                attempt)
        case .failed(let reason): return reason
        case .needsConfirmation:
            return L10n.string(
                "tunnel.state.needsConfirmation", "Connect this session once by hand")
        }
    }
}
