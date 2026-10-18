import AppKit
import Foundation
import SwiftUI

@testable import MacSCPAppKit

/// Measures a view's width and height in each language the app ships in.
///
/// **Why every function takes a closure and never a view.** `build` is
/// invoked INSIDE `L10n.$localeOverride.withValue(locale)`. SwiftUI resolves
/// the labels on a view's top level when the view is constructed and the
/// labels inside nested closures when it is rendered, so a view built before
/// the override is entered carries the process language's top-level labels
/// into a measurement taken under it: the figure comes back plausible and
/// wrong. `LayoutMeasureTests.buildingOutsideTheOverrideUnderMeasures` pins
/// that behaviour, so a change to it is discovered rather than assumed.
///
/// **What a figure means.** `NSHostingController.sizeThatFits(in:)` answers
/// "what would you take if offered this much?". Offered zero width it
/// returns the smallest width the content can take without clipping: the
/// longest unbreakable run of text, and every control that cannot compress.
/// A compressible control reports a small minimum and is squeezed instead,
/// so a view must mark each localized control that cannot wrap `.fixedSize()`
/// for the figure to mean "needs".
///
/// This lives in the test-support target but imports `MacSCPAppKit` through
/// `@testable`, because `L10n.localeOverride` is internal to the app layer.
/// That works because every build `swift test` makes is built testable.
@MainActor
public enum LayoutMeasure {
    private static let resources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/Resources")

    /// Every shipped catalogue, read from the `.lproj` directory listing
    /// under `Sources/MacSCPAppKit/Resources`, sorted. No locale is spelled
    /// here, so a fifth language is measured the day its `.lproj` lands.
    public static var shippedLocales: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    /// The smallest width the content can take without clipping.
    public static func minimumWidth<V: View>(
        locale: String, of build: @MainActor () -> V
    ) -> CGFloat {
        L10n.$localeOverride.withValue(locale) {
            NSHostingController(rootView: build())
                .sizeThatFits(in: CGSize(width: 0, height: 100_000)).width
        }
    }

    /// The smallest height the content can take at `width` without clipping.
    public static func minimumHeight<V: View>(
        locale: String, at width: CGFloat, of build: @MainActor () -> V
    ) -> CGFloat {
        L10n.$localeOverride.withValue(locale) {
            NSHostingController(rootView: build())
                .sizeThatFits(in: CGSize(width: width, height: 0)).height
        }
    }

    /// The width the content would take if nothing pushed back.
    public static func idealWidth<V: View>(
        locale: String, of build: @MainActor () -> V
    ) -> CGFloat {
        L10n.$localeOverride.withValue(locale) {
            NSHostingController(rootView: build().fixedSize(horizontal: true, vertical: false))
                .sizeThatFits(in: CGSize(width: 0, height: 100_000)).width
        }
    }
}
