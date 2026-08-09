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
///
/// That graceful fallback also hid a failure under `swift test`: none of the
/// three `Bundle.main`-derived candidates points anywhere near the test
/// runner's build directory, so the lookup settled for `Bundle.main` and
/// every `string(_:_:)` call returned its own `defaultValue`. The UI strings
/// looked fine (they are the English source text) and nothing went red, so
/// App-layer text was effectively untested. The last candidate closes that
/// hole: under `swift test` `Bundle(for:)` resolves to the `.xctest` bundle,
/// and the resource bundle sits next to it rather than inside it, so we walk
/// up one level. In a real `.app` that candidate is never even reached:
/// `scripts/package-app` copies `macSCP_MacSCPAppKit.bundle` into
/// `Contents/Resources/`, which is exactly `Bundle.main.resourceURL`, so the
/// second candidate matches and the loop returns before the fourth is built.
enum L10n {
    private final class BundleFinder {}

    static let bundle: Bundle = {
        let bundleName = "macSCP_MacSCPAppKit.bundle"
        let candidates = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for directory in candidates {
            let candidate = directory.appendingPathComponent(bundleName)
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
