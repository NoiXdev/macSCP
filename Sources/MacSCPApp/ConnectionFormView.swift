import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    let onConnected: (any RemoteFileSystem) -> Void

    @State private var showKeyImporter = false

    private var isConnecting: Bool { viewModel.state == .connecting }

    /// The field whose validation failed most recently — gets the red outline.
    private var failedField: ConnectionViewModel.Field? {
        if case .failed(_, let field) = viewModel.state { return field }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("connection.title", "New connection"))
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
                    SecureField(L10n.string("connection.auth.password", "Password"), text: $viewModel.password)
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
                        text: $viewModel.password
                    )
                        .errorHighlight(failedField == .password)
                }
                Toggle(
                    L10n.string("connection.saveToggle", "Save as session"),
                    isOn: $viewModel.shouldSaveSession)
                if viewModel.shouldSaveSession {
                    TextField(
                        L10n.string("connection.field.saveName", "Session name"), text: $viewModel.saveName,
                        prompt: Text(L10n.string("connection.field.saveName.placeholder", "e.g. hetzner-web"))
                    )
                        .errorHighlight(failedField == .saveName)
                }
            }
            .disabled(isConnecting)

            if case .failed(let message, _) = viewModel.state {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let prompt = viewModel.hostKeyPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L10n.string(
                        "connection.hostkey.first", "First connection to %@"), prompt.candidate.host))
                        .font(.headline)
                    Text(String(format: L10n.string(
                        "connection.hostkey.fingerprintLabel", "Fingerprint (%@):"), prompt.candidate.keyType))
                        .font(.callout)
                    Text(prompt.candidate.fingerprintSHA256)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button(L10n.string("common.cancel", "Cancel")) {
                            viewModel.resolveHostKeyPrompt(trust: false)
                        }
                        Button(L10n.string("connection.hostkey.trust", "Trust & connect")) {
                            viewModel.resolveHostKeyPrompt(trust: true)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(L10n.string("connection.connect", "Connect")) {
                    Task {
                        if let fs = await viewModel.connect() {
                            onConnected(fs)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                viewModel.keyPath = url.path(percentEncoded: false)
            }
        }
    }
}

private extension View {
    /// Red outline for the form field whose validation failed.
    func errorHighlight(_ active: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.red, lineWidth: active ? 1.5 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
