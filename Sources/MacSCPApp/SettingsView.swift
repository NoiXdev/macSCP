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
    /// App-global update-check state (M11h/T2) — same `UpdateCheckModel`
    /// instance the app menu's "Check for Updates…" item drives, threaded
    /// through from `MacSCPApp` like `store` above, so the General tab's
    /// "Check Now" button reuses the one existing check path instead of
    /// starting a second one.
    var updateModel: UpdateCheckModel

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store, updateModel: updateModel)
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
        // Height bumped 420 -> 460 for this M9d polish pass: switching
        // General/Terminal to Section-based `.formStyle(.grouped)` (in line
        // with Transfers/Open-with) adds header/footer/inter-section
        // spacing that flat un-sectioned rows didn't need, and the
        // Terminal tab's live preview sits below two Sections - rendered
        // measurements showed content coming within ~30-40pt of the old
        // 420pt frame BEFORE subtracting the native tab-strip's own height,
        // so 420 was too tight going forward.
        .frame(width: 460, height: 460)
    }
}

/// General app options (M7a): the hidden-files toggle, plus (M9c) the
/// auto-refresh toggle and its interval, and (M11h/T2) the manual
/// "Check Now" update section below the automatic-check toggle.
private struct GeneralSettingsTab: View {
    @Bindable var store: SettingsStore
    /// Read-only here: the toggle two lines below already binds
    /// `store.updateCheckEnabled` directly; this is only consulted for
    /// `isChecking` (button disabled state / spinner) and passed through to
    /// `check(manual:settingsStore:)` — the exact same call the app-menu
    /// item makes (see `MacSCPApp.body`'s `CommandGroup(after: .appInfo)`).
    var updateModel: UpdateCheckModel

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

            // Menu-bar status item toggle (M11n): the AppKit
            // `MenuBarController` observes this same `store.menuBarEnabled`
            // and installs/removes the `NSStatusItem` live.
            Section {
                Toggle(
                    L10n.string("settings.general.menubar", "Show menu bar icon"),
                    isOn: $store.menuBarEnabled)
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
                        .accessibilityLabel(L10n.string("settings.openWith.rules.remove", "Remove"))
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

/// The "Terminal" settings tab (M9d): font family/size and cursor
/// style/blink, with a live preview. `@Bindable` (like `GeneralSettingsTab`)
/// so the controls below can bind directly to `$store.*`.
private struct TerminalSettingsTab: View {
    @Bindable var store: SettingsStore
    /// Drives the custom-terminal-app picker (M11d/T2) — same
    /// `.fileImporter` pattern as `OpenWithSettingsTab`'s default-editor
    /// picker.
    @State private var showCustomAppPicker = false

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
            }
            .formStyle(.grouped)
            .fileImporter(
                isPresented: $showCustomAppPicker,
                allowedContentTypes: [.application]
            ) { result in
                guard case .success(let url) = result else { return }
                store.customTerminalAppPath = url.path(percentEncoded: false)
            }

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
