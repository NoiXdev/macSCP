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
    let onConnected: (any RemoteFileSystem) -> Void

    @State private var showKeyImporter = false
    /// Failure message currently shown as an alert. Deliberately separate
    /// from `viewModel.state` so dismissing the alert keeps the `.failed`
    /// state (and with it the red field highlight) intact.
    @State private var alertMessage: String?

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
        .frame(minWidth: 420)
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
    }

    @ViewBuilder
    private var formContent: some View {
            Text(isEditMode
                ? L10n.string("connection.editTitle", "Edit session")
                : L10n.string("connection.title", "New connection"))
                .font(.title2.bold())

            Form {
                TextField(
                    L10n.string("connection.field.host", "Host"), text: $viewModel.host,
                    prompt: Text(L10n.string("connection.field.host.placeholder", "server.example.com"))
                )
                    .errorHighlight(failedField == .host)
                TextField(L10n.string("connection.field.port", "Port"), text: $viewModel.port)
                    .errorHighlight(failedField == .port)
                TextField(L10n.string("connection.field.username", "Username"), text: $viewModel.username)
                    .errorHighlight(failedField == .username)
                Picker(L10n.string("connection.field.authMethod", "Authentication"), selection: Binding(
                    get: { viewModel.authChoice },
                    set: { viewModel.selectAuthChoice($0) }
                )) {
                    Text(L10n.string("connection.auth.password", "Password"))
                        .tag(ConnectionViewModel.AuthChoice.password)
                    Text(L10n.string("connection.auth.privateKey", "SSH key"))
                        .tag(ConnectionViewModel.AuthChoice.privateKey)
                }
                .pickerStyle(.segmented)
                if viewModel.authChoice == .password {
                    SecureField(
                        L10n.string("connection.auth.password", "Password"), text: $viewModel.password,
                        prompt: isEditMode
                            ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                            : nil
                    )
                        .errorHighlight(failedField == .password)
                } else {
                    HStack(spacing: 6) {
                        TextField(
                            L10n.string("connection.field.keyPath", "Key path"), text: $viewModel.keyPath,
                            prompt: Text(L10n.string(
                                "connection.field.keyPath.placeholder", "~/.ssh/id_ed25519"))
                        )
                            .errorHighlight(failedField == .keyPath)
                        // "…" is a pure symbol (ellipsis "browse" affordance), not
                        // natural-language text — identical in every locale, so it
                        // stays a literal rather than a catalog key.
                        Button("…") { showKeyImporter = true }
                            .help(L10n.string("connection.field.keyPath.browseHelp", "Choose key file"))
                    }
                    SecureField(
                        L10n.string("connection.field.passphrase", "Passphrase (optional)"),
                        text: $viewModel.password,
                        prompt: isEditMode
                            ? Text(L10n.string("connection.field.password.unchanged", "unchanged"))
                            : nil
                    )
                        .errorHighlight(failedField == .password)
                }
                if !isEditMode {
                    Toggle(
                        L10n.string("connection.saveToggle", "Save as session"),
                        isOn: $viewModel.shouldSaveSession)
                }
                if isEditMode || viewModel.shouldSaveSession {
                    TextField(
                        L10n.string("connection.field.saveName", "Session name"), text: $viewModel.saveName,
                        prompt: Text(L10n.string("connection.field.saveName.placeholder", "e.g. hetzner-web"))
                    )
                        .errorHighlight(failedField == .saveName)
                    Picker(
                        L10n.string("connection.field.group", "Group"),
                        selection: $viewModel.selectedGroupID
                    ) {
                        Text(L10n.string("sidebar.noGroup", "No group")).tag(UUID?.none)
                        ForEach(groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                }
            }
            .disabled(isConnecting)

            HStack {
                Spacer()
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                if isEditMode {
                    Button(L10n.string("common.back", "Back")) {
                        onCancelEdit()
                    }
                    Button(L10n.string("common.save", "Save")) {
                        if let session = viewModel.validateForEditSave() {
                            onSaveEdited(session, viewModel.password.isEmpty ? nil : viewModel.password)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    Button(L10n.string("connection.saveAndConnect", "Save & connect")) {
                        if let session = viewModel.validateForEditSave() {
                            onSaveEdited(session, viewModel.password.isEmpty ? nil : viewModel.password)
                            onConnectEdited(session)
                        } else if case .failed(let message, _) = viewModel.state {
                            alertMessage = message
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.string("connection.connect", "Connect")) {
                        Task {
                            if let fs = await viewModel.connect() {
                                onConnected(fs)
                            } else if case .failed(let message, _) = viewModel.state {
                                alertMessage = message
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting)
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
                Button(L10n.string("connection.hostkey.trust", "Trust & connect")) {
                    viewModel.resolveHostKeyPrompt(trust: true)
                }
                .keyboardShortcut(.defaultAction)
            }
    }
}

private extension View {
    /// Red outline for the form field whose validation failed. The stroke
    /// sits 4pt outside the row's bounds so label and field content keep
    /// breathing room instead of touching the border.
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
