import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// The app's Settings window content, opened via Cmd-, or the app menu's
/// "Settings…" item (the `Settings` scene is wired up in MacSCPApp.swift).
///
/// Structured as a `TabView` with a "General" tab (M7a/T4), a "Transfers"
/// tab, an "Open with" tab (M5e/T2), and a "Terminal" tab (M9d); future tabs
/// slot in the same way.
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

            TerminalSettingsTab(store: store)
                .tabItem {
                    Label(
                        L10n.string("settings.tab.terminal", "Terminal"),
                        systemImage: "terminal")
                }
        }
        .frame(width: 460, height: 420)
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

/// The "Terminal" settings tab (M9d): font family/size and cursor
/// style/blink, with a live preview. `@Bindable` (like `GeneralSettingsTab`)
/// so the controls below can bind directly to `$store.*`.
private struct TerminalSettingsTab: View {
    @Bindable var store: SettingsStore

    /// One selectable fixed-pitch font family in the font popup.
    ///
    /// `family` is what's shown to the user; `fontName` is the RESOLVABLE
    /// PostScript name that gets persisted to `SettingsStore
    /// .terminalFontName` and later fed to `NSFont(name:size:)` (both here,
    /// for the preview, and in `SSHTerminalView.resolvedFont()`). The two
    /// are NOT interchangeable: for many families (e.g. "Courier New") the
    /// family name itself doesn't resolve via `NSFont(name:)` — its regular
    /// face's PostScript name is "CourierNewPSMT" — so storing the family
    /// name would silently fail to resolve and fall back to the system
    /// font, in both the preview and the live terminal.
    private struct FontChoice: Identifiable, Hashable {
        let family: String
        let fontName: String
        var id: String { fontName }
    }

    /// Fixed-pitch families, deduplicated and sorted alphabetically.
    ///
    /// `NSFontManager.availableFontNames(with:)` — bridged from AppKit's
    /// `availableFontNamesWithTraits:` — returns PostScript NAMES, not
    /// family names, so several names typically map to the same family
    /// (regular/bold/italic/bold-italic). One representative name per
    /// family is kept — preferring a plain face (no "Bold"/"Italic"/
    /// "Oblique" in the PostScript name) when the family has one, since
    /// that reads as the "normal" weight in the preview.
    private static var fixedPitchFontChoices: [FontChoice] {
        let names = (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .sorted()
        var byFamily: [String: String] = [:]
        for name in names {
            guard let font = NSFont(name: name, size: 12), let family = font.familyName else { continue }
            let isPlainFace =
                !name.localizedCaseInsensitiveContains("bold")
                && !name.localizedCaseInsensitiveContains("italic")
                && !name.localizedCaseInsensitiveContains("oblique")
            if byFamily[family] == nil || isPlainFace {
                byFamily[family] = name
            }
        }
        return byFamily.map { FontChoice(family: $0.key, fontName: $0.value) }
            .sorted { $0.family < $1.family }
    }

    /// Mirrors `SSHTerminalView.resolvedFont()` for the preview row: the
    /// configured font at the configured size, or the system monospaced
    /// font when unconfigured/unresolvable.
    private var previewFont: Font {
        if let name = store.terminalFontName,
            NSFont(name: name, size: CGFloat(store.terminalFontSize)) != nil
        {
            return .custom(name, size: CGFloat(store.terminalFontSize))
        }
        return .system(size: CGFloat(store.terminalFontSize), design: .monospaced)
    }

    var body: some View {
        Form {
            Picker(
                L10n.string("settings.terminal.font", "Font"),
                selection: $store.terminalFontName
            ) {
                Text(L10n.string("settings.terminal.systemFont", "System (SF Mono)"))
                    .tag(String?.none)
                ForEach(Self.fixedPitchFontChoices) { choice in
                    Text(choice.family)
                        .tag(String?(choice.fontName))
                }
            }

            Stepper(value: $store.terminalFontSize, in: 9...24) {
                Text(String(
                    format: L10n.string("settings.terminal.size %lld", "Size: %lld pt"),
                    store.terminalFontSize))
            }

            Picker(
                L10n.string("settings.terminal.cursor", "Cursor"),
                selection: $store.terminalCursorStyle
            ) {
                Text(L10n.string("settings.terminal.cursor.block", "Block"))
                    .tag(TerminalCursorStyle.block)
                Text(L10n.string("settings.terminal.cursor.bar", "Bar"))
                    .tag(TerminalCursorStyle.bar)
                Text(L10n.string("settings.terminal.cursor.underline", "Underline"))
                    .tag(TerminalCursorStyle.underline)
            }
            .pickerStyle(.segmented)

            Toggle(
                L10n.string("settings.terminal.cursorBlink", "Blinking"),
                isOn: $store.terminalCursorBlink)

            // Preview: fixed, unlocalized sample text (a shell prompt reads
            // the same in every locale) rendered with the chosen font/size,
            // on the same colors the real terminal uses.
            Text(verbatim: "deploy@web-01:~ $ ls -la")
                .font(previewFont)
                .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: DesignTokens.terminalBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .formStyle(.grouped)
        .padding()
    }
}
