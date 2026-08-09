import Foundation

/// Locates the Core target's string catalog resource bundle without going
/// through SwiftPM's generated `Bundle.module` accessor.
///
/// The generated `Bundle.module` calls `fatalError` if it can't find the
/// sibling resource bundle next to the executable/test binary — a real risk
/// for stripped/bare launches (e.g. a verification wrapper that copies only
/// the built binary without `.build`'s resource output alongside it). This
/// helper looks for the same bundle name SwiftPM generates for this target,
/// `macSCP_macSCPCore.bundle`, but over a WIDER candidate list than the
/// generated accessor: that one tries exactly two locations —
/// `Bundle.main.bundleURL` and a build path hardcoded at compile time — and
/// never consults `Bundle(for:)`. This helper also degrades gracefully
/// instead of crashing:
/// if none of the candidates exist, it falls back to `Bundle.main`, and
/// `string(_:)` returns the raw key text instead of trapping — every key
/// below is itself a readable (if unlocalized) fallback.
///
/// Under `swift test` the module is linked into the test runner, so
/// `Bundle(for:)` returns the `.xctest` bundle and `Bundle.main` is the
/// test helper — neither CONTAINS the resource bundle. It sits BESIDE the
/// test bundle instead, which is why the last candidate walks up one level
/// from `Bundle(for:)`'s own URL. Without it every lookup fell through to
/// `Bundle.main` and `string(_:)` returned the raw key. Assertions of the
/// form `#expect(error == CoreL10n.string(key))` still caught the WRONG key
/// even then -- both sides reduced to key text, and key A never equals key
/// B -- but nothing checked that a key maps to real text at all: a key that
/// no catalog declares passed exactly like a declared one, for several
/// milestones.
enum CoreL10n {
    private static let bundleName = "macSCP_macSCPCore.bundle"

    private final class BundleFinder {}

    static let bundle: Bundle = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
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
