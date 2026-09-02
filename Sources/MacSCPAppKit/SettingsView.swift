import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// One row in the Settings window's sidebar (M18/T7). Each case owns its own
/// SF Symbol and localized title, and maps 1:1 to a section `struct` rendered
/// in the detail column by `SettingsView.body`'s `switch`.
enum SettingsSection: Hashable {
    case general
    case appearance
    case transfers
    case openWith
    case terminal
    case shortcuts
    case cli
    case manageData
    case ssh
    case s3

    var title: String {
        switch self {
        case .general: return L10n.string("settings.tab.general", "General")
        case .appearance: return L10n.string("settings.section.appearance", "View")
        case .transfers: return L10n.string("settings.tab.transfers", "Transfers")
        case .openWith: return L10n.string("settings.tab.openWith", "Open with")
        case .terminal: return L10n.string("settings.tab.terminal", "Terminal")
        case .shortcuts: return L10n.string("settings.tab.shortcuts", "Shortcuts")
        case .cli: return L10n.string("settings.section.cli", "Command Line")
        case .manageData: return L10n.string("settings.section.manageData", "Manage Data")
        case .ssh: return L10n.string("settings.section.ssh", "SSH")
        case .s3: return L10n.string("settings.section.s3", "S3")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "eye"
        case .transfers: return "arrow.up.arrow.down"
        case .openWith: return "doc.badge.gearshape"
        case .terminal: return "terminal"
        case .shortcuts: return "keyboard"
        case .cli: return "chevron.left.forwardslash.chevron.right"
        case .manageData: return "archivebox"
        case .ssh: return "key"
        case .s3: return "cloud"
        }
    }
}

/// The app's Settings window content, opened via Cmd-, or the app menu's
/// "Settings…" item (the `Settings` scene is wired up in MacSCPApp.swift).
///
/// Structured as a `NavigationSplitView` (M18/T7) with a sidebar `List` over
/// `SettingsSection` and a detail column that renders the matching section
/// `struct`: "General" (M7a/T4, split from the former "General" tab in
/// M18/T7), "View" (the other half of that split), "Transfers", "Open with"
/// (M5e/T2), "Terminal" (M9d), a read-only "Shortcuts" overview (M11q),
/// "Command Line" (the `macscp-cli` shortcut installer), "Manage Data" (the
/// five management overlays in one list), and two protocol-specific sections
/// grouped under "Protocols" — "SSH" and "S3" (M18/T7). The former tab-bar
/// layout and its "SSH Keys" tab (M17/T4) are gone; key management now lives
/// entirely in the standalone `SSHKeysSheet` (M18/T5), reachable from the
/// Sessions menu, the connection form's "Manage keys…" link, and this
/// window's "Manage Data" section (it left the "SSH" section when that
/// section was created).
struct SettingsView: View {
    var store: SettingsStore
    /// App-global update-check state (M11h/T2) — same `UpdateCheckModel`
    /// instance the app menu's "Check for Updates…" item drives, threaded
    /// through from `MacSCPApp` like `store` above, so the General section's
    /// "Check Now" button reuses the one existing check path instead of
    /// starting a second one.
    var updateModel: UpdateCheckModel
    /// The language in effect when this process launched (M11p) — threaded
    /// through from `MacSCPApp.init` to `GeneralSettingsSection`, which
    /// compares it against the live `store.selectedLanguage` to decide
    /// whether to show the relaunch button.
    var launchLanguage: AppLanguage
    /// Command bridge to the main window (M8a/T4), threaded through for the
    /// "Manage Data" section only: two of its five entries must reach the
    /// sheets the main window already presents rather than open a second
    /// copy here (see `ManageDataSettingsSection`).
    var tabCommands: TabCommands

    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(
                    [
                        SettingsSection.general, .appearance, .transfers,
                        .openWith, .terminal, .shortcuts, .cli, .manageData,
                    ], id: \.self
                ) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }

                Section(L10n.string("settings.section.protocols", "Protocols")) {
                    ForEach([SettingsSection.ssh, .s3], id: \.self) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            // Fixed sidebar width (M11n lesson: SwiftUI layout containers can
            // spin in a `_sizeThatFits` loop on macOS 26 if left to negotiate
            // an intrinsic width against the detail column) — verified with
            // an idle-CPU smoke test after this change (see task report).
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general:
                    GeneralSettingsSection(store: store, updateModel: updateModel, launchLanguage: launchLanguage)
                case .appearance:
                    AppearanceSettingsSection(store: store)
                case .transfers:
                    TransfersSettingsTab(store: store)
                case .openWith:
                    OpenWithSettingsTab(store: store)
                case .terminal:
                    TerminalSettingsTab(store: store)
                case .shortcuts:
                    ShortcutsSettingsTab()
                case .cli:
                    CLISettingsSection()
                case .manageData:
                    ManageDataSettingsSection(tabCommands: tabCommands)
                case .ssh:
                    SSHSettingsSection(store: store)
                case .s3:
                    S3SettingsSection(store: store)
                }
            }
            .navigationSplitViewColumnWidth(min: 460, ideal: 500)
        }
        .navigationSplitViewStyle(.balanced)
        // Widened for the sidebar layout (was 460×460 for the flat TabView,
        // M9d). 680 gives the sidebar its fixed 180pt plus ~500pt for the
        // widest detail content (the Terminal section's Form + live
        // preview). Height raised from the old 460 to 620: the tallest
        // section is "View" (hidden files + 6 file-column toggles + the
        // tag-filter row + the auto-refresh row), which measurably scrolled
        // at 480 — 620 was reached by measuring that section's real rendered
        // height in a dev build and adding headroom, per the idle-CPU-smoke
        // task step. The tag-filter row (E1) was added to that section
        // afterwards and has NOT been re-measured against the headroom; if
        // "View" scrolls, this frame is where that is decided.
        .frame(width: 680, height: 620)
    }
}

/// General app options (M7a/T4; split from the former, overloaded
/// `GeneralSettingsTab` in M18/T7): the language switcher, the menu-bar icon
/// toggle, and the update-check section. Appearance-related options (hidden
/// files, file-list columns, auto-refresh) moved to `AppearanceSettingsSection`.
private struct GeneralSettingsSection: View {
    @Bindable var store: SettingsStore
    /// Read-only here: the toggle two lines below already binds
    /// `store.updateCheckEnabled` directly; this is only consulted for
    /// `isChecking` (button disabled state / spinner) and passed through to
    /// `check(manual:settingsStore:)` — the exact same call the app-menu
    /// item makes (see `MacSCPApp.body`'s `CommandGroup(after: .appInfo)`).
    var updateModel: UpdateCheckModel
    /// The language in effect when this process launched (M11p) — compared
    /// against the live `store.selectedLanguage` below to decide whether the
    /// relaunch button is shown (a language change only takes effect on a
    /// fresh launch).
    var launchLanguage: AppLanguage

    /// The running build's short version string, read the same way
    /// `UpdateCheckModel.check` and the system "About macSCP" panel do
    /// (`CFBundleShortVersionString` off `Bundle.main`) — App layer only,
    /// Core stays bundle-free.
    private var currentVersionText: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? L10n.string("settings.general.currentVersion.unknown", "Unknown")
    }

    /// The persisted `lastUpdateCheck` timestamp, formatted for the user's
    /// locale (`Date.formatted(date:time:)`, not a fixed pattern — unlike
    /// e.g. `KnownHostsSheet`'s pinned `dd.MM.yyyy`, there's no cross-user
    /// display like a table column here, so the locale-native form reads
    /// better), or an honest "never checked" sentence when nil. `store` is
    /// `@Bindable`/`@Observable`, so this recomputes live right after a
    /// check completes and writes the new timestamp.
    private var lastCheckedText: String {
        guard let lastCheck = store.lastUpdateCheck else {
            return L10n.string("settings.general.lastChecked.never", "Never checked for updates yet.")
        }
        return String(
            format: L10n.string("settings.general.lastChecked %@", "Last checked: %@"),
            lastCheck.formatted(date: .abbreviated, time: .shortened))
    }

    var body: some View {
        Form {
            // Language switcher (M11p): overrides `AppleLanguages` on the
            // NEXT launch (`MacSCPApp.init`) — the bundle's localized tables
            // are cached after first use, so a relaunch button appears while
            // the picker's live selection differs from what was actually
            // applied at launch.
            Section {
                Picker(
                    L10n.string("settings.general.language.header", "Language"),
                    selection: $store.selectedLanguage
                ) {
                    Text(L10n.string("settings.general.language.system", "System"))
                        .tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.en)
                    Text("Deutsch").tag(AppLanguage.de)
                    Text("Français").tag(AppLanguage.fr)
                    Text("Polski").tag(AppLanguage.pl)
                }
                if store.selectedLanguage != launchLanguage {
                    Button(L10n.string("settings.general.language.relaunch", "Relaunch macSCP")) {
                        AppRelauncher.relaunch()
                    }
                }
            } footer: {
                Text(L10n.string(
                    "settings.general.language.footer",
                    "Takes effect after a relaunch."))
                    .foregroundStyle(.secondary)
            }

            // Menu-bar status item toggle (M11n): the AppKit
            // `MenuBarController` observes this same `store.menuBarEnabled`
            // and installs/removes the `NSStatusItem` live.
            Section {
                Toggle(
                    L10n.string("settings.general.menubar", "Show menu bar icon"),
                    isOn: $store.menuBarEnabled)
            }

            Section {
                Toggle(
                    L10n.string("settings.general.updateCheck", "Automatically check for updates"),
                    isOn: $store.updateCheckEnabled)

                LabeledContent(L10n.string("settings.general.currentVersion", "Current version")) {
                    Text(currentVersionText)
                        .foregroundStyle(.secondary)
                }

                // "Check Now" (M11h/T2): calls the SAME `check(manual:
                // settingsStore:)` the app-menu item calls, with the same
                // `isChecking` guard/disabled condition — no second check
                // path. The pass/fail/no-update RESULT is presented by the
                // existing machinery inside `check` itself (the in-window
                // `.alert` in `ContentView` while a window is mounted, or
                // its `NSAlert` fallback when every window is closed and
                // only Settings is open) — nothing new is added here for
                // that; this row only surfaces the persistent facts (version,
                // last-checked) and the trigger.
                HStack {
                    Text(lastCheckedText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await updateModel.check(manual: true, settingsStore: store) }
                    } label: {
                        if updateModel.isChecking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.string("settings.general.checkingNow", "Checking…"))
                            }
                        } else {
                            Text(L10n.string("settings.general.checkNow", "Check Now"))
                        }
                    }
                    .buttonStyle(.polished)
                    .disabled(updateModel.isChecking)
                }
            } footer: {
                Text(L10n.string(
                    "settings.general.updateCheckHint",
                    "Asks GitHub for the latest version at most once a day. No data about you is transmitted."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// "View" options (M18/T7; split out of the former `GeneralSettingsTab`):
/// the hidden-files toggle, the file-list column checkboxes (M11m/T2), the
/// sidebar tag-filter toggle (E1), and the auto-refresh toggle/interval
/// (M9c).
private struct AppearanceSettingsSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    L10n.string("settings.general.showHidden", "Show hidden files"),
                    isOn: $store.showHiddenFiles)
            } footer: {
                Text(L10n.string(
                    "settings.general.showHiddenHint",
                    "Applies to both panes. Shortcut: ⌘⇧."))
                    .foregroundStyle(.secondary)
            }

            // File-list columns (M11m/T2): one checkbox per toggleable
            // `FileColumn` — `name` is excluded (`FileColumn.isToggleable`
            // is `false` only for it), so it never gets a row here and stays
            // permanently shown, matching `SettingsStore.visibleColumns`'s
            // own always-includes-`name` guarantee. Titles are the SAME
            // localized strings the table's own column headers use
            // (`FileColumn.localizedTitle`, `RemoteFileTableView.swift`), so
            // a box's label always matches what the user sees atop the
            // table it controls.
            Section {
                ForEach(FileColumn.allCases.filter(\.isToggleable), id: \.self) { column in
                    Toggle(column.localizedTitle, isOn: Binding(
                        get: { store.visibleColumns.contains(column) },
                        set: { isOn in
                            var columns = store.visibleColumns
                            if isOn {
                                columns.insert(column)
                            } else {
                                columns.remove(column)
                            }
                            store.visibleColumns = columns
                        }
                    ))
                }
            } header: {
                Text(L10n.string("settings.general.columns.header", "File List Columns"))
            } footer: {
                Text(L10n.string(
                    "settings.general.columns.footer",
                    "Applies to both panes. Name is always shown."))
                    .foregroundStyle(.secondary)
            }

            // The sidebar's tag filter (E1). It hides the FILTER, not the
            // tags: they stay assignable and visible while a connection is
            // edited, so switching this off gives up one way of narrowing the
            // list and takes nothing else away — which is also why switching
            // it back on can hold no surprise. `SessionSidebar` clears an
            // active filter as this goes off.
            Section {
                Toggle(
                    L10n.string("settings.general.tagFilter", "Show tag filter in the sidebar"),
                    isOn: $store.sidebarTagFilterEnabled)
            } footer: {
                Text(L10n.string(
                    "settings.general.tagFilter.footer",
                    "Tags stay assignable while editing a connection."))
                    .foregroundStyle(.secondary)
            }

            Section {
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// The single "Transfers" section: concurrency limit, bandwidth limits, and
/// the checksum procedure — computing a checksum reads the whole file on the
/// far side, so it is asked for and cancelled like any other transfer. The
/// S3 presigned-link-expiry section moved to the protocol-specific
/// `S3SettingsSection` in M18/T7.
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

            // NOTE (bandwidth-row duplicate-value bug, fixed): `TextField(_
            // titleKey:value:format:)`'s title is NOT a placeholder inside a
            // `Form` styled `.formStyle(.grouped)` - macOS renders it as a
            // permanent label next to the field (same treatment as
            // `Toggle`/`Picker`/`Stepper` titles). The previous code passed
            // "0" as the title, so the row showed "Upload  0  <field: 0>" -
            // the literal "0" label duplicating the real (also-zero-by-
            // default) bound value. Fix: empty title (the outer
            // `LabeledContent` already supplies "Upload"/"Download" as the
            // row label) plus an explicit "KB/s" unit suffix.
            Section {
                LabeledContent(L10n.string("settings.bandwidth.upload", "Upload")) {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: Binding(
                                get: { store.uploadLimitKBs },
                                set: { store.uploadLimitKBs = $0 }
                            ), format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        // Empty title (grouped-Form label trap) — restore the
                        // VoiceOver label explicitly (M9d final review).
                        .accessibilityLabel(L10n.string("settings.bandwidth.upload", "Upload"))
                        // Unit abbreviation, not prose - no localization key
                        // needed (see SettingsView doc comment / task notes).
                        Text(verbatim: "KB/s")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L10n.string("settings.bandwidth.download", "Download")) {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: Binding(
                                get: { store.downloadLimitKBs },
                                set: { store.downloadLimitKBs = $0 }
                            ), format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(L10n.string("settings.bandwidth.download", "Download"))
                        Text(verbatim: "KB/s")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.string("settings.bandwidth.header", "Bandwidth limit upload/download"))
            } footer: {
                Text(L10n.string("settings.bandwidth.footer", "0 = unlimited"))
                    .foregroundStyle(.secondary)
            }

            // Checksums live here because computing one IS a transfer: it
            // reads the whole file on the far side, takes minutes on a
            // large one, and is asked for and cancelled like any other.
            //
            // The order is `ChecksumAlgorithm.allCases`, which starts at
            // the preferred one, and the marker on the other two is read
            // off `isCryptographicallyBroken` rather than from a list kept
            // here — so an algorithm added later arrives already labelled
            // or already unlabelled, whichever it deserves, without this
            // view being told about it.
            Section {
                Picker(
                    L10n.string("settings.checksum.algorithm", "Checksum algorithm"),
                    selection: Binding(
                        get: { store.checksumAlgorithm },
                        set: { store.checksumAlgorithm = $0 }
                    )
                ) {
                    ForEach(ChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(label(for: algorithm)).tag(algorithm)
                    }
                }
            } header: {
                Text(L10n.string("settings.checksum.header", "Checksums"))
            } footer: {
                Text(L10n.string(
                    "settings.checksum.footer",
                    """
                    SHA-256 is the default. MD5 and SHA-1 are offered because a figure \
                    published elsewhere is often one of them: they serve to compare a file \
                    against such a figure, never as proof that two files are the same.
                    """))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// A broken procedure is still offered — it is what a published figure
    /// is often written in — but it is not offered as an equal. The suffix
    /// is what says so in the list itself, where the choice is made, rather
    /// than only in the footer below it.
    private func label(for algorithm: ChecksumAlgorithm) -> String {
        guard algorithm.isCryptographicallyBroken else { return algorithm.displayName }
        return algorithm.displayName + " — " + L10n.string(
            "settings.checksum.forComparisonOnly", "for comparison only")
    }
}

/// The "Open with" section (M5e/T2): the default editor used for remote
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

    /// Mirrors `SettingsStore`'s private extension normalization (trim,
    /// strip one leading dot, lowercase) so the Choose-app button gates on
    /// what the store would actually KEEP — "." trims non-empty but
    /// normalizes to empty and would be silently dropped (M9d final review).
    private var normalizedNewRuleExtension: String {
        var trimmed = newRuleExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed.lowercased()
    }

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
                        // `.accessibilityLabel` and `.help` are different affordances,
                        // not a duplication: the former labels the control for
                        // VoiceOver, the latter produces the hover tooltip. Both are
                        // needed and intentionally share the same key.
                        .accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))
                        .help(L10n.string("settings.openWith.rules.remove", "Remove"))
                    }
                }

                // ROOT CAUSE (button-looked-disabled bug, fixed): as with
                // the bandwidth rows above, a `TextField`'s title is a
                // permanent label in a `.formStyle(.grouped)` Form, NOT an
                // empty-state placeholder. Passing the example text "php" as
                // the title made it appear PERMANENTLY next to the field -
                // identical whether or not the user had typed anything -
                // so an untouched, still-empty field looked already filled
                // in with "php". The "Choose app..." disabled condition
                // below was always correct (it reflects the real, empty
                // `newRuleExtension`); the field's misleading label just
                // masked that nothing had actually been typed. Fix: empty
                // title + the real `prompt:` parameter, which IS a true
                // dimmed hint shown only while the field is empty and
                // disappears once real text is entered.
                LabeledContent(L10n.string("settings.openWith.rules.extension", "Extension")) {
                    HStack {
                        TextField(
                            "", text: $newRuleExtension,
                            prompt: Text(L10n.string("settings.openWith.rules.extensionPlaceholder", "php"))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .accessibilityLabel(L10n.string("settings.openWith.rules.extension", "Extension"))
                        Button(L10n.string("settings.openWith.rules.chooseApp", "Choose app…")) {
                            activePicker = .rule(extension: newRuleExtension)
                            importerPresented = true
                        }
                        // Gate on the NORMALIZED value (M9d final review):
                        // "." trims to non-empty but normalizes to empty, so
                        // the store's setter would silently drop the rule.
                        .disabled(normalizedNewRuleExtension.isEmpty)
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

/// The "Terminal" section (M9d): font family/size and cursor style/blink,
/// with a live preview. The external-terminal-target picker moved to the
/// protocol-specific `SSHSettingsSection` in M18/T7. `@Bindable` (like
/// `GeneralSettingsSection`) so the controls below can bind directly to
/// `$store.*`.
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
        VStack(spacing: 16) {
            Form {
                Section {
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
                }

                Section {
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
                }
            }
            .formStyle(.grouped)

            // Preview: fixed, unlocalized sample text (a shell prompt reads
            // the same in every locale) rendered with the chosen font/size,
            // on the same colors the real terminal uses. Kept outside the
            // Form/Section grid (it isn't a label/control row) but aligned
            // to the same horizontal inset as the grouped sections above.
            Text(verbatim: "deploy@web-01:~ $ ls -la")
                .font(previewFont)
                .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: DesignTokens.terminalBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

/// Read-only keyboard-shortcuts overview (M11q) — renders
/// `KeyboardShortcutsCatalog` as one grouped, non-interactive list.
private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            ForEach(KeyboardShortcutsCatalog.groups) { group in
                Section(L10n.string(group.titleKey, group.titleDefault)) {
                    ForEach(group.rows) { row in
                        HStack {
                            Text(L10n.string(row.labelKey, row.labelDefault))
                            Spacer()
                            Text(row.shortcut)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The "SSH" protocol section (M18/T7): the external-terminal target picker
/// (moved out of the former "Terminal" tab).
///
/// It used to carry a second, one-button section linking to `SSHKeysSheet`;
/// that link moved to "Manage Data", which gathers all five management
/// overlays in one list. External-terminal target was, for a while, the
/// only setting left here — Task 9 ended that by adding three more
/// sections below it: connect timeout, keep-alive probing, and reconnect
/// behaviour, all four settings (Task 9's connect timeout and reconnect
/// behaviour, plus keep-alive's two settings since 2026-09-02) read
/// straight off `SettingsStore` and bind directly, the same way
/// `autoRefreshEnabled`/`autoRefreshIntervalSeconds` do above.
private struct SSHSettingsSection: View {
    @Bindable var store: SettingsStore
    /// Drives the custom-terminal-app picker (M11d/T2) — same
    /// `.fileImporter` pattern as `OpenWithSettingsTab`'s default-editor
    /// picker.
    @State private var showCustomAppPicker = false

    /// Display name for `store.customTerminalAppPath`, or a placeholder when
    /// none is chosen yet — same idea as `OpenWithSettingsTab.appDisplayName`
    /// but with terminal-specific wording ("no app chosen" instead of
    /// "system default": there IS no system default terminal app).
    private var customAppDisplayName: String {
        guard let path = store.customTerminalAppPath, !path.isEmpty else {
            return L10n.string("settings.terminal.target.noneChosen", "No app chosen")
        }
        return FileManager.default.displayName(atPath: path)
    }

    var body: some View {
        Form {
            // External terminal (M11d/T2): which app a session's shell
            // opens in. Both routes to a shell (toggle the built-in
            // panel, or open externally) stay reachable from the
            // "Terminal" menu regardless of this choice — it only picks
            // what ⌘T/the toolbar button do (footer below).
            Section {
                Picker(
                    L10n.string("settings.terminal.target", "Open sessions in"),
                    selection: $store.terminalTarget
                ) {
                    Text(L10n.string("settings.terminal.target.builtIn", "Built-in Terminal"))
                        .tag(TerminalTarget.builtIn)
                    Text(L10n.string("settings.terminal.target.terminalApp", "Terminal"))
                        .tag(TerminalTarget.terminalApp)
                    Text(L10n.string("settings.terminal.target.iTerm", "iTerm"))
                        .tag(TerminalTarget.iTerm)
                    Text(L10n.string("settings.terminal.target.custom", "Custom App…"))
                        .tag(TerminalTarget.custom)
                }

                if store.terminalTarget == .custom {
                    HStack {
                        Text(customAppDisplayName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.string("settings.openWith.choose", "Choose…")) {
                            showCustomAppPicker = true
                        }
                    }
                }
            } header: {
                Text(L10n.string("settings.terminal.target.header", "External Terminal"))
            } footer: {
                // Two short, factual notes (review finding, M11d fix
                // round 1, second sentence): the first is the existing
                // "both routes stay reachable" note; the second makes
                // the `.builtIn` fallback visible — otherwise a user who
                // set a custom app but left this picker on "Built-in"
                // has no way to know the menu item quietly uses Terminal
                // instead of their configured app.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(
                        "settings.terminal.target.footer",
                        "Both ways to open a session stay available from the Terminal menu, "
                            + "regardless of this setting."))
                    Text(L10n.string(
                        "settings.terminal.target.builtInFallback.footer",
                        "When \u{201C}Built-in\u{201D} is selected, that menu item opens your "
                            + "custom app if one is set, otherwise Terminal."))
                }
                .foregroundStyle(.secondary)
            }

            // Connect timeout (Task 9): bounds the dial itself, before a
            // session exists to show liveness for at all.
            Section {
                Stepper(
                    value: Binding(
                        get: { store.connectTimeoutSeconds },
                        set: { store.connectTimeoutSeconds = $0 }
                    ),
                    in: 5...120
                ) {
                    Text(String(
                        format: L10n.string(
                            "settings.connection.timeout %lld", "Give up after %lld seconds"),
                        store.connectTimeoutSeconds))
                }
            } header: {
                Text(L10n.string("settings.connection.timeout.header", "Connect Timeout"))
            } footer: {
                // Honest about scope: measured against the vendored Citadel
                // source (see `SettingsStore.connectTimeoutSeconds`'s own
                // doc comment) — a jump host's second hop has no TCP
                // connect step of its own for this setting to bound, and
                // its handshake wait is Citadel's own fixed 10s instead. An
                // earlier draft of this text overstated coverage and was
                // corrected after that measurement.
                Text(L10n.string(
                    "settings.connection.timeout.footer",
                    "Bounds how long macSCP waits for the first hop to answer before giving "
                        + "up. Through a jump host, only that first hop is covered — the "
                        + "second hop runs through a fixed timeout this setting cannot "
                        + "change."))
                    .foregroundStyle(.secondary)
            }

            // Keep-Alive (Task 9; rebound to two settings 2026-09-02):
            // `keepAliveEnabled` and `keepAliveIntervalSeconds` are each
            // their own persisted setting now, so the toggle and stepper
            // bind straight to `store`, the same shape as the auto-refresh
            // toggle/stepper above.
            Section {
                Toggle(
                    L10n.string(
                        "settings.connection.keepAlive", "Check the connection while idle"),
                    isOn: $store.keepAliveEnabled)
                Stepper(
                    value: Binding(
                        get: { store.keepAliveIntervalSeconds },
                        set: { store.keepAliveIntervalSeconds = $0 }
                    ),
                    in: 15...600
                ) {
                    Text(String(
                        format: L10n.string(
                            "settings.connection.keepAliveInterval %lld", "Every %lld seconds"),
                        store.keepAliveIntervalSeconds))
                }
                .disabled(!store.keepAliveEnabled)
            } header: {
                Text(L10n.string("settings.connection.keepAlive.header", "Keep-Alive"))
            } footer: {
                // Turning the toggle off no longer touches the interval at
                // all (2026-09-02: two settings, not one sentinel) — the
                // stepper's own value just sits there, disabled, until the
                // toggle is switched back on. No "remembered while off,
                // lost on relaunch" hedge to write here any more: there is
                // nothing transient to describe.
                Text(String(
                    format: L10n.string(
                        "settings.connection.keepAlive.footer %lld",
                        "While on, macSCP checks an idle connection every %lld seconds. Off "
                            + "keeps the interval for when you turn it back on."),
                    store.keepAliveIntervalSeconds))
                    .foregroundStyle(.secondary)
            }

            // Reconnect behaviour (Task 9): what happens once a connection
            // is found gone.
            Section {
                Picker(
                    L10n.string("settings.connection.reconnect", "When a connection is lost"),
                    selection: $store.reconnectBehaviour
                ) {
                    Text(L10n.string("settings.connection.reconnect.offerOnly", "Offer to reconnect"))
                        .tag(ReconnectBehaviour.offerOnly)
                    Text(L10n.string(
                        "settings.connection.reconnect.onceThenAsk", "Reconnect once, then ask"))
                        .tag(ReconnectBehaviour.onceThenAsk)
                    Text(L10n.string(
                        "settings.connection.reconnect.automatic", "Reconnect automatically"))
                        .tag(ReconnectBehaviour.automatic)
                }
            } header: {
                Text(L10n.string("settings.connection.reconnect.header", "Reconnect"))
            } footer: {
                // The host-key sentence holds regardless of which option is
                // picked (architecture invariant: a key mismatch is a hard
                // stop, never auto-accepted) — stated here so "automatic"
                // does not read as "no confirmation ever".
                Text(L10n.string(
                    "settings.connection.reconnect.footer",
                    "\u{201C}Offer to reconnect\u{201D} waits for a click. "
                        + "\u{201C}Reconnect once, then ask\u{201D} retries automatically one "
                        + "time, then falls back to asking. \u{201C}Reconnect "
                        + "automatically\u{201D} keeps retrying on its own. A changed host key "
                        + "always stops and asks, no matter which option is selected."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(
            isPresented: $showCustomAppPicker,
            allowedContentTypes: [.application]
        ) { result in
            guard case .success(let url) = result else { return }
            store.customTerminalAppPath = url.path(percentEncoded: false)
        }
    }
}

/// The "Manage Data" section: one list of shortcuts to the five management
/// overlays, which were previously split between the Sessions menu (all
/// five) and the "SSH" section (keys only). The Sessions menu keeps every
/// entry it had, ⇧⌘K/⇧⌘L included — this is a second door, not a
/// replacement.
///
/// Two of the five open HERE, as sheets on the Settings window, the way
/// `SSHKeysSheet` already did from the "SSH" section. `KnownHostsSheet`
/// builds its own `KnownHostsStore` over a fixed directory — a stateless
/// read-modify-write struct addressed by `(host, port)`, rebuilt on every
/// connect — and the main window shows nothing derived from it, so a copy
/// here cannot leave the other window stale. `SSHKeysSheet` is presented
/// here because it always has been (this section only inherited it from the
/// "SSH" section); note that the connection form's key picker
/// (`ManagedKeysLoad.connectableKeys()`) IS derived state, so
/// deleting a key here can leave an open form holding a dead
/// `managedKeyID` — pre-existing behaviour, unchanged by this section.
///
/// The other three — logins, server certificates and hidden imports — are
/// NOT presented here; they route through `TabCommands` to the main window's
/// own presentation of the same sheet, which keeps the existing view model
/// and refresh wiring intact. Logins and hidden imports edit state the main
/// window's sidebar is a live view of, and a sheet in THIS window is modal
/// only to THIS window, so the main window would stay clickable next to a
/// stale sidebar. Server certificates are routed for the trust decision
/// rather than the data. See `ContentView.presentLoginSetsFromSettings()`
/// and `presentServerCertificatesFromSettings()` for the full reasoning.
///
/// Those three are `.disabled` while no main window EXISTS
/// (`TabCommands.hasMainWindow`): they have nowhere to go then, and a row
/// that swallows a click is worse here than in the Sessions menu, where the
/// user is at least standing in a window. A minimized window or a hidden app
/// leaves them enabled on purpose — the handlers raise the window before
/// presenting, so the action works from either state.
///
/// The per-session audit log is deliberately absent: `AuditLogSheet` takes a
/// `StoredSession` and is opened from that session's sidebar row. There is no
/// all-sessions audit view for a global list to link to, and inventing a
/// session picker here would be a new feature, not a shortcut.
private struct ManageDataSettingsSection: View {
    var tabCommands: TabCommands
    /// The two overlays this window presents itself — same `@State` flag +
    /// `.sheet(isPresented:)` pattern the "SSH" section used for keys before
    /// this section existed.
    @State private var showSSHKeysSheet = false
    @State private var showKnownHostsSheet = false
    /// State for the leftover-credential cleanup (M27/T3): a confirmation
    /// gate and the fixed-text report shown after `runReap()` returns.
    @State private var confirmingReap = false
    @State private var reapResult: String?

    var body: some View {
        Form {
            Section {
                Button {
                    showSSHKeysSheet = true
                } label: {
                    Label(L10n.string("menu.sshKeys", "SSH Keys…"), systemImage: "key")
                }
                Button {
                    tabCommands.showLoginsFromSettings?()
                } label: {
                    Label(
                        L10n.string("menu.logins", "Logins…"),
                        systemImage: "person.badge.key")
                }
                .disabled(!tabCommands.hasMainWindow)
                Button {
                    showKnownHostsSheet = true
                } label: {
                    Label(
                        L10n.string("menu.knownHosts", "Known Hosts…"),
                        systemImage: "lock.shield")
                }
                Button {
                    tabCommands.showServerCertificatesFromSettings?()
                } label: {
                    Label(
                        L10n.string("menu.serverCertificates", "Server Certificates…"),
                        systemImage: "checkmark.seal")
                }
                .disabled(!tabCommands.hasMainWindow)
                Button {
                    tabCommands.showHiddenImportsFromSettings?()
                } label: {
                    // Same count-suffixed title as the Sessions-menu entry,
                    // from the same helper — the count is the only signal
                    // that anything is hidden at all.
                    Label(
                        hiddenImportsMenuTitle(count: tabCommands.hiddenImportsCount),
                        systemImage: "eye.slash")
                }
                .disabled(!tabCommands.hasMainWindow)
            } footer: {
                // Two lines, the second only when it applies: where the
                // routed entries land, said BEFORE the window changes under
                // the user, and — when they are greyed out — why. A disabled
                // row shows no tooltip, so this footer is the only place that
                // explanation can live.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(
                        "settings.manageData.footer",
                        "Logins, server certificates and hidden imports open in the main "
                            + "window, where the state they change belongs."))
                    if !tabCommands.hasMainWindow {
                        Text(L10n.string(
                            "settings.manageData.needsMainWindow",
                            "They are unavailable while no main window is open."))
                    }
                }
                .foregroundStyle(.secondary)
            }
            // Leftover-credential cleanup (M27/T3): its own section, separate
            // from the shortcuts above, because it runs an action here rather
            // than opening a sheet in the main window.
            Section {
                Button(L10n.string("manageData.reapSecrets.button", "Remove leftover credentials…")) {
                    confirmingReap = true
                }
                .confirmationDialog(
                    L10n.string("manageData.reapSecrets.confirmTitle", "Remove leftover credentials?"),
                    isPresented: $confirmingReap, titleVisibility: .visible
                ) {
                    Button(
                        L10n.string("manageData.reapSecrets.confirmAction", "Remove"),
                        role: .destructive, action: runReap)
                } message: {
                    Text(L10n.string(
                        "manageData.reapSecrets.confirmMessage",
                        "Only credentials no saved connection, login set or key refers to "
                            + "are removed. This action cannot be undone."))
                }
                if let reapResult {
                    Text(reapResult).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.string(
                    "manageData.reapSecrets.explanation",
                    "Upgrading from version 1.0 could leave credentials in the keychain "
                        + "that nothing uses any more."))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showSSHKeysSheet) {
            SSHKeysSheet()
        }
        .sheet(isPresented: $showKnownHostsSheet) {
            KnownHostsSheet(store: KnownHostsStore(directory: SessionStore.defaultDirectory))
        }
    }

    /// Runs `LegacyJumpSecretSweep` and reports the outcome in fixed text.
    ///
    /// **Deliberately no removal count in the success text.**
    /// `KeychainSecretStore.deletePassword` maps `errSecItemNotFound` to
    /// success, so `Result.removed` counts successful delete calls, not
    /// entries that were actually there. The legacy file that seeds the
    /// candidate set stays on disk as M23's downgrade snapshot, so it does
    /// not shrink after a run — a second run against an already-clean
    /// keychain would report the same number. A count nobody can trust is
    /// worse than none, so only `failed` (a real, observed event) is shown.
    ///
    /// The failure path names no cause: a store read failure could be
    /// anything from a permissions problem to a corrupt file, the user
    /// cannot act on the distinction, and the report's job here is to say
    /// plainly that nothing was removed.
    private func runReap() {
        let sweep = LegacyJumpSecretSweep(
            sessions: SessionStore(directory: SessionStore.defaultDirectory),
            loginSets: LoginSetStore(directory: SessionStore.defaultDirectory),
            keys: ManagedKeyStore(directory: SessionStore.defaultDirectory),
            secrets: KeychainSecretStore())
        do {
            let result = try sweep.run()
            var text = L10n.string("manageData.reapSecrets.result", "Cleanup finished.")
            if result.failed > 0 {
                text += "\n" + String(
                    format: L10n.string(
                        "manageData.reapSecrets.resultFailures %lld", "Could not be removed: %lld"),
                    result.failed)
            }
            reapResult = text
        } catch {
            reapResult = L10n.string(
                "manageData.reapSecrets.failed",
                "The leftover credentials could not be checked. Nothing was removed.")
        }
    }
}

/// The "S3" protocol section (M18/T7): the default presigned-link expiry
/// (moved out of the former "Transfers" tab) — home for future S3-specific
/// settings.
private struct S3SettingsSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            // S3 share links (M14/T5): the default expiry `PresignedURLSheet`
            // pre-fills when generating a presigned GET/PUT link — the sheet
            // itself lets a link override this per generation.
            Section {
                Picker(
                    L10n.string("settings.transfers.presignedExpiry", "Default share-link expiry"),
                    selection: $store.presignedDefaultExpiry
                ) {
                    Text(L10n.string("presigned.expiry.15min", "15 Minutes")).tag(PresignedExpiry.fifteenMinutes)
                    Text(L10n.string("presigned.expiry.1h", "1 Hour")).tag(PresignedExpiry.oneHour)
                    Text(L10n.string("presigned.expiry.1d", "1 Day")).tag(PresignedExpiry.oneDay)
                    Text(L10n.string("presigned.expiry.7d", "7 Days")).tag(PresignedExpiry.sevenDays)
                }
            } header: {
                Text(L10n.string("settings.transfers.presignedExpiry.header", "S3 Share Links"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// The command-line companion's install section. Deliberately thin: every
/// decision — does the shortcut exist, does it still point at THIS app copy,
/// is the path occupied by something that must not be overwritten — is made by
/// `CLIToolInstaller` in Core and covered by `CLIToolInstallerTests`. This view
/// only renders the resulting state and calls `install()`.
///
/// **The app never escalates.** `install()` writes a symlink into the user's
/// own `~/.local/bin`; nothing here runs a shell, invokes `sudo`, or asks for
/// an authorization right. The `/usr/local/bin` alternative is offered as
/// COPYABLE TEXT that the user runs themselves.
///
/// **No PATH check, on purpose.** `ProcessInfo.processInfo.environment["PATH"]`
/// is the APP's `PATH` — a GUI process launched from Finder inherits a minimal
/// `launchd` environment that has no relationship to the user's `.zshrc`, so
/// deciding "not on your PATH" from it would be a confident falsehood shown to
/// the user. The only accurate reading would come from starting a login shell,
/// which can hang on a slow or broken profile and would freeze this window. So
/// the requirement is stated plainly in the footer instead of pretended to be
/// verified, and macSCP never edits a shell profile to "fix" it.
private struct CLISettingsSection: View {
    private let installer: CLIToolInstaller

    @State private var state: CLIInstallState
    @State private var errorMessage: String?

    init() {
        // `scripts/package-app` puts `macscp-cli` NEXT TO the app binary in
        // `Contents/MacOS/`, so the running executable's own directory finds
        // it without hardcoding `/Applications` — which keeps a copy run from
        // `~/Downloads`, or a plain `swift run` build, honest about what it
        // would be linking to.
        let toolURL = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "macSCP"))
            .deletingLastPathComponent()
            .appendingPathComponent(CLIToolInstaller.toolName)
        let installer = CLIToolInstaller(toolURL: toolURL)
        self.installer = installer
        // Seeded synchronously so the section never flashes a wrong status
        // for one frame before `onAppear` runs.
        _state = State(initialValue: installer.state())
    }

    /// `~`-abbreviated for display; the full path stays selectable.
    private func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private var linkPath: String {
        display(installer.linkURL.path(percentEncoded: false))
    }

    private var statusTitle: String {
        switch state {
        case .notInstalled:
            return L10n.string("settings.cli.status.notInstalled", "Not installed.")
        case .installed:
            return String(
                format: L10n.string("settings.cli.status.installed %@", "Installed at %@"),
                linkPath)
        case .stale:
            return L10n.string(
                "settings.cli.status.stale",
                "Installed, but pointing at a different copy of macSCP.")
        case .occupied:
            return String(
                format: L10n.string(
                    "settings.cli.status.occupied %@",
                    "Something that is not a shortcut already exists at %@."),
                linkPath)
        case .translocated:
            return L10n.string(
                "settings.cli.status.translocated",
                "macSCP is running from a temporary location.")
        }
    }

    private var statusDetail: String? {
        switch state {
        case .notInstalled, .installed:
            return nil
        case .stale(let target):
            // `nil` when the link's destination could not be read at all —
            // then the headline stands alone rather than naming a path we do
            // not actually know.
            return target.map {
                String(
                    format: L10n.string(
                        "settings.cli.status.stale.detail %@", "Currently points at: %@"),
                    display($0))
            }
        case .occupied:
            return L10n.string(
                "settings.cli.status.occupied.detail",
                "macSCP will not overwrite it. Move or remove it yourself, then install.")
        case .translocated:
            return L10n.string(
                "settings.cli.status.translocated.detail",
                "macOS runs apps opened from a disk image or the Downloads folder from a temporary copy that disappears on quit. Move macSCP to your Applications folder, open it from there, and install again.")
        }
    }

    /// Colour carries no information on its own here — the sentence above
    /// says the same thing in words — so a colour-blind reader loses nothing.
    private var statusColor: Color {
        switch state {
        case .installed: return .green
        case .stale, .occupied, .translocated: return .orange
        case .notInstalled: return .primary
        }
    }

    /// `nil` in the two states with nothing to do: already correct, or
    /// blocked by a file only the user may remove.
    private var actionTitle: String? {
        switch state {
        case .notInstalled: return L10n.string("settings.cli.install", "Install")
        case .stale: return L10n.string("settings.cli.repair", "Repair")
        // `.translocated` joins them: the fix is to move the app, not to
        // press a button here — offering one would only create a link into a
        // mount that is about to disappear.
        case .installed, .occupied, .translocated: return nil
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .foregroundStyle(statusColor)
                    if let statusDetail {
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let actionTitle {
                    HStack {
                        Spacer()
                        Button(actionTitle) { install() }
                    }
                }
            } header: {
                Text(L10n.string("settings.cli.header", "Command-Line Tool"))
            } footer: {
                Text(
                    L10n.string(
                        "settings.cli.footer",
                        "Creates a shortcut named macscp-cli in ~/.local/bin. Commands in that folder are only found if it is part of your shell's PATH — macSCP does not change your shell configuration."
                    ))
            }

            Section {
                Text(
                    L10n.string(
                        "settings.cli.systemWide.intro",
                        "To install into /usr/local/bin instead, copy this command and run it in a terminal:"
                    ))
                .fixedSize(horizontal: false, vertical: true)

                Text(installer.systemWideInstallCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button(L10n.string("settings.cli.systemWide.copy", "Copy Command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            installer.systemWideInstallCommand, forType: .string)
                    }
                }
            } header: {
                Text(L10n.string("settings.cli.systemWide.header", "System-Wide Installation"))
            } footer: {
                Text(
                    L10n.string(
                        "settings.cli.systemWide.footer",
                        "That folder belongs to the system, so the command asks for your administrator password. macSCP never requests administrator rights itself."
                    ))
            }
        }
        .formStyle(.grouped)
        .padding()
        // Re-read on every appearance: the shortcut can change while the app
        // runs (the user moves the .app, or removes the link in a terminal).
        .onAppear { state = installer.state() }
        .alert(
            L10n.string("settings.cli.error.title", "Installation failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func install() {
        do {
            try installer.install()
        } catch CLIInstallError.appIsTranslocated {
            // Same reasoning as `pathOccupied` below: the button is not
            // offered in that state, and the refreshed status explains the
            // situation and the remedy better than an alert would.
            errorMessage = nil
        } catch CLIInstallError.pathOccupied {
            // Unreachable from the button (it is hidden in `.occupied`), but
            // the path could be taken between the last refresh and the click.
            // The refreshed status below then explains it in place, so no
            // alert is needed — the raw error would only repeat it worse.
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = installer.state()
    }
}
