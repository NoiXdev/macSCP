import SwiftUI
import macSCPCore

/// Locates the string catalog's resource bundle without going through
/// SwiftPM's generated `Bundle.module` accessor.
///
/// `Bundle.module` calls `fatalError` if it can't find the sibling resource
/// bundle next to the executable. That's a real risk for stripped/bare
/// launches — e.g. a verification wrapper that copies only the built binary
/// into an `.app` shell without `.build`'s resource output alongside it.
/// This lookup instead degrades gracefully: if the resource bundle isn't
/// where we expect, we fall back to `Bundle.main`, and every call site below
/// supplies its own English `defaultValue`, so the UI still renders (in
/// English) instead of crashing.
private enum SettingsResources {
    static let bundle: Bundle = {
        let bundleName = "macSCP_MacSCPApp.bundle"
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent(bundleName),
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path),
                let bundle = Bundle(url: candidate)
            {
                return bundle
            }
        }
        return .main
    }()

    /// Looks up `key` in the string catalog; `key` doubles as the English
    /// fallback if no translated (or bundled) value can be found.
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }
}

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
                        SettingsResources.string("Transfers"),
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
                        Text(SettingsResources.string("Maximum concurrent transfers"))
                        Spacer()
                        Text("\(store.maxConcurrentTransfers)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text(SettingsResources.string("Applies to new transfers; running ones are unaffected."))
                    .foregroundStyle(.secondary)
            }

            Section {
                // "Upload"/"Download" are identical in English and German,
                // so they're plain literals rather than catalog entries —
                // only the strings listed in the M5c/T3 brief are cataloged.
                LabeledContent("Upload") {
                    TextField(
                        "0", value: Binding(
                            get: { store.uploadLimitKBs },
                            set: { store.uploadLimitKBs = $0 }
                        ), format: .number
                    )
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent("Download") {
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
                Text(SettingsResources.string("Bandwidth limit upload/download"))
            } footer: {
                Text(SettingsResources.string("0 = unlimited"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
