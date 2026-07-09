import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    let onConnected: (any RemoteFileSystem) -> Void

    @State private var showKeyImporter = false

    private var isConnecting: Bool { viewModel.state == .connecting }

    /// Das Feld, dessen Validierung zuletzt fehlschlug — bekommt die rote Umrandung.
    private var failedField: ConnectionViewModel.Field? {
        if case .failed(_, let field) = viewModel.state { return field }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neue Verbindung")
                .font(.title2.bold())

            Form {
                TextField("Host", text: $viewModel.host, prompt: Text("server.example.com"))
                    .errorHighlight(failedField == .host)
                TextField("Port", text: $viewModel.port)
                    .errorHighlight(failedField == .port)
                TextField("Benutzername", text: $viewModel.username)
                    .errorHighlight(failedField == .username)
                Picker("Authentifizierung", selection: $viewModel.authChoice) {
                    Text("Passwort").tag(ConnectionViewModel.AuthChoice.password)
                    Text("SSH-Key").tag(ConnectionViewModel.AuthChoice.privateKey)
                }
                .pickerStyle(.segmented)
                if viewModel.authChoice == .password {
                    SecureField("Passwort", text: $viewModel.password)
                        .errorHighlight(failedField == .password)
                } else {
                    HStack(spacing: 6) {
                        TextField("Key-Pfad", text: $viewModel.keyPath,
                                  prompt: Text("~/.ssh/id_ed25519"))
                            .errorHighlight(failedField == .keyPath)
                        Button("…") { showKeyImporter = true }
                            .help("Key-Datei auswählen")
                    }
                    SecureField("Passphrase (optional)", text: $viewModel.password)
                        .errorHighlight(failedField == .password)
                }
                Toggle("Als Session speichern", isOn: $viewModel.shouldSaveSession)
                if viewModel.shouldSaveSession {
                    TextField("Session-Name", text: $viewModel.saveName,
                              prompt: Text("z.B. hetzner-web"))
                        .errorHighlight(failedField == .saveName)
                }
            }
            .disabled(isConnecting)

            if case .failed(let message, _) = viewModel.state {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Verbinden") {
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
    /// Rote Umrandung für das Formularfeld, dessen Validierung fehlschlug.
    func errorHighlight(_ active: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.red, lineWidth: active ? 1.5 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
