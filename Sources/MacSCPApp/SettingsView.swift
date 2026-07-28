import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// The app's Settings window content, opened via Cmd-, or the app menu's
/// "Settings…" item (the `Settings` scene is wired up in MacSCPApp.swift).
///
/// Structured as a `TabView` with a "General" tab (M7a/T4), a "Transfers"
/// tab, and an "Open with" tab (M5e/T2); future tabs slot in the same way.
struct SettingsView: View {
    var store: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.general", "General"),
                        systemImage: "gearshape")
                }

            TransfersSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.transfers", "Transfers"),
                        systemImage: "arrow.up.arrow.down")
                }

            OpenWithSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.openWith", "Open with"),
                        systemImage: "doc.badge.gearshape")
                }
        }
        .frame(width: 460, height: 360)
    }
}

/// General app options (M7a): the hidden-files toggle, plus (M9c) the
/// auto-refresh toggle and its interval.
private struct GeneralSettingsTab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Toggle(
                L10n.string("settings.general.showHidden", "Show hidden files"),
                isOn: $store.showHiddenFiles)
            Text(L10n.string(
                "settings.general.showHiddenHint",
                "Applies to both panes. Shortcut: ⌘⇧."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                L10n.string("settings.general.autoRefresh", "Auto-refresh remote view"),
                isOn: $store.autoRefreshEnabled)
            Stepper(
                value: Binding(
                    get: { store.autoRefreshIntervalSeconds },
                    set: { store.autoRefreshIntervalSeconds = $0 }
                ),
                in: 2...300
            ) {
                Text(String(
                    format: L10n.string(
                        "settings.general.autoRefreshInterval %lld", "Every %lld seconds"),
                    store.autoRefreshIntervalSeconds))
            }
            .disabled(!store.autoRefreshEnabled)
        }
        .padding(20)
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

/// The "Open with" settings tab (M5e/T2): the default editor used for remote
/// files without a matching extension rule, and per-extension overrides.
private struct OpenWithSettingsTab: View {
    var store: SettingsStore

    /// Which `.fileImporter` is currently active: the default-editor picker,
    /// or the picker for a specific extension rule (new or existing).
    private enum ActivePicker: Identifiable {
        case defaultEditor
        case rule(extension: String)

        var id: String {
            switch self {
            case .defaultEditor: return "defaultEditor"
            case .rule(let ext): return "rule:\(ext)"
            }
        }
    }

    @State private var activePicker: ActivePicker?
    /// Drives the shared `.fileImporter`. Kept separate from `activePicker`
    /// because SwiftUI resets the `isPresented` binding before invoking the
    /// completion handler — deriving presentation from `activePicker` would
    /// nil the picker context out from under the handler and drop the
    /// selection.
    @State private var importerPresented = false
    /// The extension being typed into the "add rule" row.
    @State private var newRuleExtension: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(appDisplayName(forPath: store.defaultEditorPath))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("settings.openWith.choose", "Choose…")) {
                        activePicker = .defaultEditor
                        importerPresented = true
                    }
                    Button(L10n.string("settings.openWith.reset", "Reset")) {
                        store.defaultEditorPath = nil
                    }
                    .disabled(store.defaultEditorPath == nil)
                }
            } header: {
                Text(L10n.string("settings.openWith.defaultEditor.header", "Default editor"))
            }

            Section {
                let sortedAssociations = store.fileAssociations.sorted { $0.key < $1.key }
                ForEach(sortedAssociations, id: \.key) { extensionKey, appPath in
                    HStack {
                        Text(".\(extensionKey)")
                            .frame(width: 60, alignment: .leading)
                        Text(appDisplayName(forPath: appPath))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            var associations = store.fileAssociations
                            associations[extensionKey] = ""
                            store.fileAssociations = associations
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))
                    }
                }

                LabeledContent(L10n.string("settings.openWith.rules.extension", "Extension")) {
                    HStack {
                        TextField(
                            L10n.string("settings.openWith.rules.extensionPlaceholder", "php"),
                            text: $newRuleExtension
                        )
                        .frame(width: 60)
                        Button(L10n.string("settings.openWith.rules.chooseApp", "Choose app…")) {
                            activePicker = .rule(extension: newRuleExtension)
                            importerPresented = true
                        }
                        .disabled(newRuleExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text(L10n.string("settings.openWith.rules.header", "Rules"))
            } footer: {
                Text(L10n.string(
                    "settings.openWith.rules.footer",
                    "Rules take precedence over the default editor; the system association is the fallback."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        // `.fileImporter` has no public `directoryURL`/initial-location
        // parameter, so we can't force `/Applications` as the start
        // directory here. The standard Open panel is used as-is; macOS
        // remembers the last-used directory across launches, so in
        // practice it lands on `/Applications` after the first use.
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.application]
        ) { result in
            defer { activePicker = nil }
            guard case .success(let url) = result, let picker = activePicker else { return }
            switch picker {
            case .defaultEditor:
                store.defaultEditorPath = url.path(percentEncoded: false)
            case .rule(let ext):
                var associations = store.fileAssociations
                associations[ext] = url.path(percentEncoded: false)
                store.fileAssociations = associations
                newRuleExtension = ""
            }
        }
    }

    /// Resolves a stored app path to a user-facing display name, or the
    /// "system default" placeholder when no path is set.
    private func appDisplayName(forPath path: String?) -> String {
        guard let path, !path.isEmpty else {
            return L10n.string("settings.openWith.systemDefault", "System default")
        }
        return FileManager.default.displayName(atPath: path)
    }
}
