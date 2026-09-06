import SwiftUI
import macSCPCore

/// "Forwardings at launch": the login item, and every profile in the app that
/// starts without being asked (port-forwarding plan, Task 7).
///
/// **It belongs to no session and to no window**, which is why it is reached
/// from the Window menu and from Settings › General rather than from a
/// sidebar row: its subject is the whole app's autostart, across every stored
/// connection.
///
/// **Nothing here prompts for a host key.** Every start from this sheet hands
/// in `.refusing`, exactly as a launch does — these are the profiles that are
/// meant to come up with nobody looking, and a sheet that asked the question
/// here would be pinning the answer for a moment that has none. A profile
/// whose session has an unknown key comes to rest at `.needsConfirmation`,
/// and the way out of that is connecting that session once, by hand, in a
/// window (design, "Limits, stated").
struct TunnelAutostartSheet: View {
    let manager: TunnelManager
    let onClose: () -> Void

    /// The login item's own state. Built here rather than handed in: it holds
    /// no app state, and both routes into this sheet want the same fresh read
    /// of what the system currently says.
    @State private var loginItem = LoginItemModel()
    /// The rows, read once per appearance rather than per redraw — see
    /// `TunnelManager.reloadAutoStartProfiles()`.
    @State private var profiles: [TunnelProfile] = []
    /// Connection names by id, for the column that says which connection a
    /// forwarding belongs to. Read from the same store the runners dial
    /// through; a profile whose session is gone shows an em dash rather than
    /// a raw id.
    @State private var sessionNames: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("tunnel.autostart.title", "Forwardings at launch")).font(.headline)

            loginItemBlock

            Divider()

            if profiles.isEmpty {
                Text(L10n.string(
                    "tunnel.autostart.empty", "No forwarding is set to start on its own."))
                    .font(.callout)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                profileTable
            }

            Text(L10n.string(
                "tunnel.autostart.footer",
                "\"At launch\" starts a forwarding every time macSCP opens. \"At login\" starts one "
                    + "only when macOS itself opened macSCP at login. Neither ever asks a question: "
                    + "a connection whose host key is not known yet waits until you connect it once "
                    + "by hand. macSCP cannot always tell whether macOS started it as a login item; "
                    + "if a forwarding does not start by itself, start it once from the menu."))
                .font(.caption)
                .foregroundStyle(DesignTokens.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.string("common.close", "Close")) { onClose() }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { refresh() }
    }

    // MARK: - The login item

    @ViewBuilder
    private var loginItemBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                L10n.string("tunnel.autostart.loginItem", "Open macSCP at login"),
                isOn: Binding(
                    get: { loginItem.isOn },
                    // The setter asks the SERVICE and never writes the model's
                    // own idea of the answer — see `LoginItemModel` for the
                    // `.requiresApproval` case this exists for.
                    set: { loginItem.setEnabled($0) }))

            Text(Self.statusText(loginItem.status))
                .font(.caption)
                .foregroundStyle(DesignTokens.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = loginItem.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    /// What the system says, in one sentence per status. `.requiresApproval`
    /// names the place the user has to go, because nothing in this app can
    /// grant it.
    static func statusText(_ status: LoginItemStatus) -> String {
        switch status {
        case .enabled:
            return L10n.string(
                "tunnel.autostart.loginItem.enabled", "macOS opens macSCP at login.")
        case .notRegistered:
            return L10n.string(
                "tunnel.autostart.loginItem.notRegistered",
                "macOS does not open macSCP at login.")
        case .requiresApproval:
            return L10n.string(
                "tunnel.autostart.loginItem.requiresApproval",
                "macSCP has asked. Allow it in System Settings › General › Login Items.")
        case .notFound:
            return L10n.string(
                "tunnel.autostart.loginItem.notFound",
                "macOS did not accept this build as a login item. A build that is not signed for "
                    + "distribution cannot register one.")
        case .unknown:
            return L10n.string(
                "tunnel.autostart.loginItem.unknown",
                "macOS reported a state this version of macSCP does not know.")
        }
    }

    // MARK: - The table

    private var profileTable: some View {
        Table(profiles) {
            TableColumn(L10n.string("tunnel.column.name", "Name")) { profile in
                Text(profile.name)
            }
            TableColumn(L10n.string("tunnel.autostart.column.session", "Connection")) { profile in
                Text(sessionNames[profile.sessionID] ?? "—")
            }
            TableColumn(L10n.string("tunnel.column.autoStart", "Starts")) { profile in
                Text(TunnelProfilesSheet.autoStartLabel(profile.autoStart))
            }
            TableColumn(L10n.string("tunnel.column.state", "State")) { profile in
                // The failure sentence is Core's own, shown verbatim — the
                // same rule the profile sheet's state column follows.
                Text(TunnelProfilesSheet.stateLabel(manager.state(of: profile.id)))
            }
            TableColumn(L10n.string("tunnel.column.action", "Action")) { profile in
                if TunnelManager.Aggregate.isRunning(manager.state(of: profile.id)) {
                    Button(L10n.string("tunnel.action.stop", "Stop")) {
                        Task { await manager.stop(profile) }
                    }
                } else {
                    Button(L10n.string("tunnel.action.start", "Start")) {
                        Task { await manager.start(profile, decider: .refusing) }
                    }
                }
            }
        }
        .frame(minHeight: 200)
    }

    // MARK: - Reading

    /// Re-reads everything this sheet shows: the login item's real status, the
    /// autostart rows (which also refreshes the manager's mirror), and the
    /// connection names those rows are labelled with.
    private func refresh() {
        loginItem.refresh()
        profiles = manager.reloadAutoStartProfiles()
        let store = SessionStore(directory: SessionStore.defaultDirectory)
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:` (fix round
        // 1): the latter TRAPS on a duplicate key, and `sessions-v2.json` is a
        // file on disk — a hand-edited or half-merged one can carry two
        // records with the same id. A name column is not worth a crash, so the
        // first record wins and the sheet opens.
        sessionNames = Dictionary(
            ((try? store.all()) ?? []).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
    }
}
