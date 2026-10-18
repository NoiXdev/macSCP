import Foundation
import SwiftUI
import Testing

@testable import MacSCPAppKit

/// Prints what every container in `ResizableContainerFloorTests` measures,
/// so that a figure quoted in a commit message or a comment travels with the
/// command that produced it.
///
/// **GATED behind `MACSCP_FLOOR_FIGURES=1` and skipped by default**, and it
/// asserts nothing; `ResizableContainerFloorTests` is the check.
///
/// ```
/// MACSCP_FLOOR_FIGURES=1 swift test --filter ResizableContainerFloorReportTests
/// ```
///
/// One line per container per state: the minimum width in each catalogue,
/// then what the window leaves it. Measured the way the check measures it.
@Suite(
    "Resizable container floor figures", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["MACSCP_FLOOR_FIGURES"] == "1",
        "a measurement record, not a check; run with MACSCP_FLOOR_FIGURES=1"))
@MainActor
struct ResizableContainerFloorReportTests {
    @Test func everyContainersFiguresAgainstItsCeiling() {
        for container in ResizableContainerFloorTests.containers {
            let figures = LayoutMeasure.shippedLocales.map { locale in
                SheetBound.$isSuspendedForMeasurement.withValue(container.suspendsBound) {
                    "\(locale) \(LayoutMeasure.minimumWidth(locale: locale, of: container.content))"
                }
            }
            report(
                "\(container.typeName) [\(container.stateName)] "
                    + "\(figures.joined(separator: " ")) of \(container.ceiling)")
        }
    }

    /// The same two places `BoundedViewFigureReportTests.report` writes to,
    /// and for the same reason.
    private func report(_ text: String) {
        print("floorfigures: " + text)
        Issue.record(Comment(rawValue: text), severity: .warning)
    }
}
