import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Prints what every registry entry measures, so that a figure quoted in a
/// commit message, a comment or a backlog row travels with the command that
/// produced it.
///
/// **GATED behind `MACSCP_BOUND_FIGURES=1` and skipped by default**, and it
/// asserts nothing. `BoundedViewLayoutGuardTests` is the check — it compares
/// each figure with what the view grants and is red when one is over. This
/// suite is the record: the same measurements, printed, with the slack each
/// view has left.
///
/// ```
/// MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests
/// ```
///
/// Four figures per entry per catalogue:
///
/// - **minimum** — `LayoutMeasure.minimumWidth`, what the content can be
///   squeezed to without clipping. This is the figure the guard compares,
///   and on a view whose localized controls still compress it is far below
///   what the view wants.
/// - **ideal** — `LayoutMeasure.idealWidth`, what the content would take if
///   nothing pushed back. The gap between the two is how much squeezing the
///   view is currently absorbing, which is what the rigidity work of this
///   plan's later tasks converts into a width the bound has to hold.
/// - **height** — only where the bound grants one, measured at the granted
///   width with the content made vertically rigid, as the guard measures it.
/// - **granted** — the bound's own figures, read off the type.
///
/// Measured through `SheetBound.isSuspendedForMeasurement`, because a
/// bounded view hosted whole reports its bound and nothing else.
@Suite(
    "Bounded view figures", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["MACSCP_BOUND_FIGURES"] == "1",
        "a measurement record, not a check; run with MACSCP_BOUND_FIGURES=1"))
@MainActor
struct BoundedViewFigureReportTests {
    @Test func everyEntrysFiguresAgainstItsBound() {
        for entry in BoundedViewRegistry.all {
            var parts: [String] = []
            for locale in LayoutMeasure.shippedLocales {
                let figures = SheetBound.$isSuspendedForMeasurement.withValue(true) {
                    (
                        minimum: LayoutMeasure.minimumWidth(locale: locale, of: entry.content),
                        ideal: LayoutMeasure.idealWidth(locale: locale, of: entry.content)
                    )
                }
                parts.append("\(locale) \(figures.minimum)/\(figures.ideal)")
            }
            var height = ""
            if let grantedHeight = entry.bound.grantedHeight {
                let figures = LayoutMeasure.shippedLocales.map { locale in
                    "\(locale) \(Self.rigidHeight(entry, locale))"
                }
                height = " | tall \(figures.joined(separator: " ")) of \(grantedHeight)"
            }
            report(
                "\(entry.typeName) [\(entry.stateName)] "
                    + "wide \(parts.joined(separator: " ")) of \(entry.bound.grantedWidth)"
                    + height)
        }
    }

    private static func rigidHeight(_ entry: BoundedViewEntry, _ locale: String) -> CGFloat {
        SheetBound.$isSuspendedForMeasurement.withValue(true) {
            LayoutMeasure.minimumHeight(locale: locale, at: entry.bound.grantedWidth) {
                entry.content().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One entry, one line, in both places a reader looks — the same split
    /// `FileDiffCostTests.report` makes, and for the same reason: `print`
    /// reaches the build log a CI run is read from, the warning-severity
    /// issue reaches the test report a local run is read from, and neither
    /// reds a suite whose job is to report.
    private func report(_ text: String) {
        print("boundfigures: " + text)
        Issue.record(Comment(rawValue: text), severity: .warning)
    }
}
