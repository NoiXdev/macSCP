import Foundation
import SwiftUI

/// App-wide localization lookup for `Resources/{en,de}.lproj/Localizable.strings`.
///
/// Generalized from the Settings-tab-only `SettingsResources` helper
/// (M5c/T3) to cover every user-visible string in the App layer (M5i/T1):
/// `SettingsView` now draws from this single source instead of keeping its
/// own copy.
///
/// Locates the resource bundle without going through SwiftPM's generated
/// `Bundle.module` accessor: `Bundle.module` calls `fatalError` if it can't
/// find the sibling resource bundle next to the executable. That's a real
/// risk for stripped/bare launches — e.g. a verification wrapper that copies
/// only the built binary into an `.app` shell without `.build`'s resource
/// output alongside it. This lookup instead degrades gracefully: if the
/// resource bundle isn't where we expect, we fall back to `Bundle.main`, and
/// every call site supplies its own English `defaultValue`, so the UI still
/// renders (in English) instead of crashing.
enum L10n {
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

    /// Looks up `key` in `Localizable.strings`; `defaultValue` is both the
    /// English source text (used to seed `en.lproj`) and the fallback
    /// returned if the resource bundle can't be located (see `bundle`
    /// above) or the key is otherwise missing from the table.
    static func string(_ key: String, _ defaultValue: String) -> String {
        NSLocalizedString(key, bundle: bundle, value: defaultValue, comment: "")
    }

    /// `Text` convenience for SwiftUI call sites.
    static func text(_ key: String, _ defaultValue: String) -> Text {
        Text(string(key, defaultValue))
    }
}
