import SwiftUI
import macSCPCore

struct ConnectionFormView: View {
    @Bindable var viewModel: ConnectionViewModel
    let onConnected: (any RemoteFileSystem) -> Void

    private var isConnecting: Bool { viewModel.state == .connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neue Verbindung")
                .font(.title2.bold())

            Form {
                TextField("Host", text: $viewModel.host, prompt: Text("server.example.com"))
                TextField("Port", text: $viewModel.port)
                TextField("Benutzername", text: $viewModel.username)
                SecureField("Passwort", text: $viewModel.password)
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
    }
}
