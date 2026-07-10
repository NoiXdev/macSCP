import Foundation

/// Locates the Core target's string catalog resource bundle without going
/// through SwiftPM's generated `Bundle.module` accessor.
///
/// The generated `Bundle.module` calls `fatalError` if it can't find the
/// sibling resource bundle next to the executable/test binary — a real risk
/// for stripped/bare launches (e.g. a verification wrapper that copies only
/// the built binary without `.build`'s resource output alongside it). This
/// helper mirrors `Bundle.module`'s own candidate search (`Bundle.main`,
/// `Bundle(for:)`, and the bundle name SwiftPM generates for this target,
/// `macSCP_macSCPCore.bundle`), but degrades gracefully instead of crashing:
/// if none of the candidates exist, it falls back to `Bundle.main`, and
/// `string(_:)` returns the raw key text instead of trapping — every key
/// below is itself a readable (if unlocalized) fallback. In the test target
/// `Bundle.module`'s own search succeeds normally, so tests exercise the
/// same lookup as production code.
enum CoreL10n {
    private static let bundleName = "macSCP_macSCPCore.bundle"

    private final class BundleFinder {}

    static let bundle: Bundle = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
        ].compactMap { $0 }

        for candidate in candidates {
            let bundleURL = candidate.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: bundleURL.path),
                let bundle = Bundle(url: bundleURL)
            {
                return bundle
            }
        }
        return .main
    }()

    /// Looks up `key` in `Localizable.strings`; `key` itself (the stable
    /// `core.*` identifier, doubling as its own English-ish fallback text)
    /// is returned unchanged if no localized value is found. Keys with
    /// format placeholders (`%@`, `%lld`, …) are meant to be passed through
    /// `String(format:)` at the call site along with the substitution
    /// arguments.
    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
