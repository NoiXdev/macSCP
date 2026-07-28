import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    /// Groups offered by the group picker (edit mode, and new mode once
    /// `shouldSaveSession` is on) — passed in by `ContentView` from
    /// `SessionListViewModel.groups`.
    var groups: [StoredGroup] = []
    /// Edit mode "Save": persists the edited session (see `newSecret`'s
    /// empty-means-unchanged rule below), then leaves edit mode.
    var onSaveEdited: (StoredSession, String?) -> Void = { _, _ in }
    /// Edit mode "Back": discards the edit and returns to the browser/idle
    /// state without touching the stored session.
    var onCancelEdit: () -> Void = {}
    /// Edit mode "Save & connect": called after `onSaveEdited` with the
    /// validated session — `ContentView` reconnects via `connectStored`,
    /// which reloads the secret from the keychain (covers "empty password
    /// means unchanged" automatically).
    var onConnectEdited: (StoredSession) -> Void = { _ in }
    /// `async` (M9d): the caller resolves the remote home directory before
    /// building the browser session, so it needs to `await` inside here.
    let onConnected: (any RemoteFileSystem) async -> Void

    @State private var showKeyImporter = false
    /// True while `onConnected` runs after a successful connect (M9d final
    /// review): the connect closure is async now (home-directory lookup), so
    /// the view model's `.idle` state alone would re-enable the Connect
    /// button while `tab.session` is still nil — a second click in that
    /// window would open and LEAK a second SSH connection.
    @State private var isHandingOff = false
    /// Failure message currently shown as an alert. Deliberately separate
    /// from `viewModel.state` so dismissing the alert keeps the `.failed`
    /// state (and with it the red field highlight) intact.
    @State private var alertMessage: String?
    /// Drives the TOFU prompt's "Manage known hosts…" footnote (M10a/T2).
    /// Local `@State` sheet with its own `KnownHostsStore` instance, rather
    /// than a callback bubbled up to `ContentView` — `ConnectionFormView`
    /// already knows the store's fixed directory (same one the connector in
    /// `ContentView.makeTab` uses), so a callback would only add an extra
    /// closure parameter threaded through `SessionTab`/`ContentView` for no
    /// behavioral gain. The trust prompt underneath is unaffected either
    /// way — it's driven by `viewModel.hostKeyPrompt`, not by this sheet.
    @State private var showKnownHostsSheet = false

    private var isConnecting: Bool { viewModel.state == .connecting }

    private var isEditMode: Bool {
        if case .edit = viewModel.mode { return true }
        return false
    }

    /// The field whose validation failed most recently — gets the red outline.
    private var failedField: ConnectionViewModel.Field? {
        if case .failed(_, let field) = viewModel.state { return field }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // While the host-key prompt is pending, the form is hidden
            // entirely — the trust decision is the only thing on screen.
            if let prompt = viewModel.hostKeyPrompt {
                hostKeyPromptView(prompt)
            } else {
                formContent
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 460)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                viewModel.keyPath = url.path(percentEncoded: false)
            }
        }
        .alert(
            L10n.string("connection.error.title", "Connection failed"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        // Opened from the TOFU prompt's footnote below — kept at the outer
        // `body` level (like the alert above) so it presents over whichever
        // sub-view (`hostKeyPromptView` or `formContent`) is currently shown,
        // and so the prompt underneath stays mounted and functional while
        // the sheet is up.
        .sheet(isPresented: $showKnownHostsSheet) {
            KnownHostsSheet(store: KnownHostsStore(directory: SessionStore.defaultDirectory))
        }
    }

    @ViewBuilder
    private var formContent: some View {
            Text(isEditMode
                ? L10n.string("connection.editTitle", "Edit session")
                : L10n.string("connection.title", "New connection"))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                let hostLabel = L10n.string("connection.field.host", "Host")
                FormRow(label: hostLabel) {
                    TextField(
                        hostLabel, text: $viewModel.host,
                        prompt: Text(L10n.string("connection.field.host.placeholder", "server.example.com"))
                    )
                }
                .errorHighlight(failedField == .host)

                let portLabel = L10n.string("connection.field.port", "Port")
                FormRow(label: portLabel) {
                    // Empty prompts: outside a Form the title parameter would
                    // surface as an in-field placeholder and duplicate the
                    // FormRow label — the titles stay for accessibility only.
                    TextField(
                        portLabel, text: $viewModel.port,
                        prompt: Text(verbatim: ""))
                }
                .errorHighlight(failedField == .port)

                let usernameLabel = L10n.string("connection.field.username", "Username")
                FormRow(label: usernameLabel) {
                    TextField(
                        usernameLabel, text: $viewModel.username,
                        prompt: Text(verbatim: ""))
                }
                .errorHighlight(failedField == .username)

                let authMethodLabel = L10n.string("connection.field.authMethod", "Authentication")
                FormRow(label: authMethodLabel) {
                    Picker(authMethodLabel, selection: Binding(
                        get: { viewModel.authChoice },
                        set: { viewModel.selectAuthChoice($0) }
                    )) {
                        Text(L10n.string("connection.auth.password", "Password"))
                            .tag(ConnectionViewModel.AuthChoice.password)
                        Text(L10n.string("connection.auth.privateKey", "SSH key"))
                            .tag(ConnectionViewModel.AuthChoice.privateKey)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if viewModel.authChoice == .password {
                    let passwordLabel = L10n.string("connection.auth.password", "Password")
                    FormRow(label: passwordLabel) {
                        SecureField(
                            passwordLabel, text: $viewModel.password,
                            prompt: isEditMode
                                ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                : Text(verbatim: "")
                        )
                    }
                    .errorHighlight(failedField == .password)
                } else {
                    let keyPathLabel = L10n.string("connection.field.keyPath", "Key path")
                    FormRow(label: keyPathLabel) {
                        HStack(spacing: 6) {
                            TextField(
                                keyPathLabel, text: $viewModel.keyPath,
                                prompt: Text(L10n.string(
                                    "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519"))
                            )
                            // "…" is a pure symbol (ellipsis "browse" affordance), not
                            // natural-language text — identical in every locale, so it
                            // stays a literal rather than a catalog key.
                            Button("…") { showKeyImporter = true }
                                .buttonStyle(.polished)
                                .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                        }
                    }
                    .errorHighlight(failedField == .keyPath)

                    let passphraseLabel = L10n.string("connection.field.passphrase", "Passphrase (optional)")
                    FormRow(label: passphraseLabel) {
                        SecureField(
                            passphraseLabel,
                            text: $viewModel.password,
                            prompt: isEditMode
                                ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                                : Text(verbatim: "")
                        )
                    }
                    .errorHighlight(failedField == .password)
                }

                if !isEditMode {
                    FormRow(label: "") {
                        Toggle(
                            L10n.string("connection.saveToggle", "Save as session"),
                            isOn: $viewModel.shouldSaveSession)
                    }
                }

                if isEditMode || viewModel.shouldSaveSession {
                    let saveNameLabel = L10n.string("connection.field.saveName", "Session name")
                    FormRow(label: saveNameLabel) {
                        TextField(
                            saveNameLabel, text: $viewModel.saveName,
                            prompt: Text(L10n.string("connection.field.saveName.placeholder", "e.g. hetzner-web"))
                        )
                    }
                    .errorHighlight(failedField == .saveName)

                    let groupLabel = L10n.string("connection.field.group", "Group")
                    FormRow(label: groupLabel) {
                        Picker(
                            groupLabel,
                            selection: $viewModel.selectedGroupID
                        ) {
                            Text(L10n.string("sidebar.noGroup", "No group")).tag(UUID?.none)
                            ForEach(groups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isConnecting)

            HStack {
                Spacer()
                if isConnecting || isHandingOff {
                    ProgressView()
                        .controlSize(.small)
                }
                if isEditMode {
                    Button(L10n.string("common.back", "Back")) {
                        onCancelEdit()
                    }
                    .buttonStyle(.polished)
                    Button(L10n.string("common.save", "Save")) {
                        if let session = viewModel.validateForEditSave() {
                            onSaveEdited(session, viewModel.password.isEmpty ? nil : viewModel.password)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    .buttonStyle(.polished)
                    Button(L10n.string("connection.saveAndConnect", "Save & connect")) {
                        if let session = viewModel.validateForEditSave() {
                            onSaveEdited(session, viewModel.password.isEmpty ? nil : viewModel.password)
                            onConnectEdited(session)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.polishedProminent)
                } else {
                    Button(L10n.string("connection.connect", "Connect")) {
                        Task {
                            if let fs = await viewModel.connect() {
                                isHandingOff = true
                                await onConnected(fs)
                                isHandingOff = false
                            } else if case .failed(let message, _) = viewModel.state {
                                alertMessage = message
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting || isHandingOff)
                    .buttonStyle(.polishedProminent)
                }
            }
    }

    /// Full-pane trust decision for an unknown host key (M3c). Presentation
    /// only — the TOFU semantics (explicit consent, mismatch never reaches
    /// this prompt) live in the validator and stay untouched.
    @ViewBuilder
    private func hostKeyPromptView(_ prompt: ConnectionViewModel.HostKeyPrompt) -> some View {
            Text(String(format: L10n.string(
                "connection.hostkey.first", "First connection to %@"), prompt.candidate.host))
                .font(.title2.bold())
            Text(String(format: L10n.string(
                "connection.hostkey.fingerprintLabel", "Fingerprint (%@):"), prompt.candidate.keyType))
                .font(.callout)
            Text(prompt.candidate.fingerprintSHA256)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(L10n.string("common.back", "Back")) {
                    viewModel.resolveHostKeyPrompt(trust: false)
                }
                .buttonStyle(.polished)
                Button(L10n.string("connection.hostkey.trust", "Trust & connect")) {
                    viewModel.resolveHostKeyPrompt(trust: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.polishedProminent)
            }
            // Discreet footnote (M10a/T2, mockup section 4): quick access to
            // inspect what is already trusted without abandoning the pending
            // prompt. (This prompt only exists on the UNKNOWN-key path — a
            // rotated key is a mismatch hard stop and never reaches it.)
            Button(L10n.string("tofu.manageKnownHosts", "Manage known hosts…")) {
                showKnownHostsSheet = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(DesignTokens.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Mockup form row (M5k): fixed 110pt right-aligned label column in
/// inkSecondary, 10pt gap to the field. The visible label lives here;
/// the wrapped controls keep their own label parameters for accessibility —
/// which is why the visible label is hidden from VoiceOver (M6a): without
/// that, every row is announced twice. The label also dims with the row's
/// enabled state, matching the system Form behavior the grid replaced.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .opacity(isEnabled ? 1 : 0.5)
                .frame(width: 110, alignment: .trailing)
                .accessibilityHidden(true)
            content
        }
    }
}

private extension View {
    /// Red outline for the form row whose validation failed. The stroke
    /// wraps label AND field, sitting 10pt horizontally / 5pt vertically
    /// outside the row's bounds so the content keeps breathing room.
    func errorHighlight(_ active: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.red, lineWidth: active ? 1.5 : 0)
                .padding(.horizontal, -10)
                .padding(.vertical, -5)
        )
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
