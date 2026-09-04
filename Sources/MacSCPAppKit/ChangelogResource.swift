import Foundation

/// Reads the changelog a packaging script copies into the app bundle
/// (`scripts/package-app` and the dev-build recipe both run `cp
/// CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"` right after the
/// resource-bundle copies) — What's New plan, Task 2.
///
/// Deliberately `Bundle.main`, never `Bundle.module`: `Bundle.module` only
/// ever resolves inside a TARGET's own SwiftPM resource bundle
/// (`macSCP_MacSCPAppKit.bundle`), and `CHANGELOG.md` is not built into
/// that bundle at all — `Package.swift` cannot declare a resource outside
/// its target's own directory, and copying it under `Sources/` would drift
/// from the root `CHANGELOG.md` the release tooling actually writes. The
/// file the packaging scripts place sits directly in the app's own
/// `Contents/Resources/`, which is exactly what `Bundle.main` resolves to
/// in a real `.app`.
///
/// Under `swift test`/`swift run` there is no `.app` bundle and therefore
/// no copied file — `Bundle.main.url(forResource:withExtension:)` returns
/// `nil` there, which is why `WhatsNewModelTests` exercises
/// `WhatsNewModel`'s decision directly with markdown strings instead of
/// going through this loader.
enum ChangelogResource {
    static func load() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
