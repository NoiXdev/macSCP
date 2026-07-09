import SwiftUI
import macSCPCore

/// Linke Spalte: gespeicherte Sessions. Klick verbindet, Kontextmenü löscht,
/// der Phosphor-Punkt markiert die aktive Verbindung.
struct SessionSidebar: View {
    let viewModel: SessionListViewModel
    let importedHosts: [SSHConfigHost]
    let activeSessionID: UUID?
    let interactionsDisabled: Bool
    let onSelect: (StoredSession) -> Void
    let onDelete: (StoredSession) -> Void
    let onNew: () -> Void
    let onSelectImported: (SSHConfigHost) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SESSIONS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            List {
                Button(action: onNew) {
                    Label("Neue Verbindung", systemImage: "plus")
                }
                .buttonStyle(.plain)

                ForEach(viewModel.sessions) { session in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(session.id == activeSessionID
                                  ? DesignTokens.statusPhosphor
                                  : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Text(session.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(session) }
                    .contextMenu {
                        Button("Löschen", role: .destructive) {
                            onDelete(session)
                        }
                    }
                    .help("\(session.username)@\(session.host):\(String(session.port))")
                }

                if !importedHosts.isEmpty {
                    Section {
                        ForEach(importedHosts, id: \.alias) { host in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(host.alias)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectImported(host) }
                            .help("Aus ~/.ssh/config — füllt das Formular (Geheimnisse werden nicht importiert)")
                        }
                    } header: {
                        Text("IMPORTIERT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(8)
            }
        }
        .disabled(interactionsDisabled)
    }
}
