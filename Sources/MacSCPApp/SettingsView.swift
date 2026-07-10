import SwiftUI
import macSCPCore

/// The app's Settings window content, opened via Cmd-, or the app menu's
/// "Settings…" item (the `Settings` scene is wired up in MacSCPApp.swift).
///
/// Deliberately structured as a `TabView` with a single tab today so future
/// tabs (e.g. Terminal, General) slot in without reworking the scene or this
/// view.
struct SettingsView: View {
    var store: SettingsStore

    var body: some View {
        TabView {
            TransfersSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.transfers", "Transfers"),
                        systemImage: "arrow.up.arrow.down")
                }
        }
        .frame(width: 460, height: 260)
    }
}

/// The single "Transfers" settings tab: concurrency and bandwidth limits.
private struct TransfersSettingsTab: View {
    var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: Binding(
                        get: { store.maxConcurrentTransfers },
                        set: { store.maxConcurrentTransfers = $0 }
                    ),
                    in: 1...8
                ) {
                    HStack {
                        Text(L10n.string("settings.maxConcurrent.label", "Maximum concurrent transfers"))
                        Spacer()
                        Text("\(store.maxConcurrentTransfers)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text(L10n.string(
                    "settings.maxConcurrent.footer",
                    "Applies to new transfers; running ones are unaffected."))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(L10n.string("settings.bandwidth.upload", "Upload")) {
                    TextField(
                        "0", value: Binding(
                            get: { store.uploadLimitKBs },
                            set: { store.uploadLimitKBs = $0 }
                        ), format: .number
                    )
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent(L10n.string("settings.bandwidth.download", "Download")) {
                    TextField(
                        "0", value: Binding(
                            get: { store.downloadLimitKBs },
                            set: { store.downloadLimitKBs = $0 }
                        ), format: .number
                    )
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                }
            } header: {
                Text(L10n.string("settings.bandwidth.header", "Bandwidth limit upload/download"))
            } footer: {
                Text(L10n.string("settings.bandwidth.footer", "0 = unlimited"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
