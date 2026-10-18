import Foundation
import SwiftUI
import Testing
import macSCPCore

import MacSCPTestSupport

@testable import MacSCPAppKit

/// Holds `LayoutMeasure` itself to account: the harness every later layout
/// guard reads its figures from.
///
/// The editor's sheet content is the reference view because the committed
/// guard (`FileActionEditorLayoutGuardTests`) already reports a width for it
/// in each language; the harness has to reproduce that figure or it is a
/// second, different instrument.
@Suite("Layout measure", .serialized)
@MainActor
struct LayoutMeasureTests {
    private static func editor() -> FileActionEditor {
        FileActionEditor(
            existing: nil,
            store: FileActionStore(directory: FileManager.default.temporaryDirectory),
            onSaved: {})
    }

    @Test func everyShippedCatalogueIsListed() {
        let locales = LayoutMeasure.shippedLocales
        #expect(Set(locales).isSuperset(of: ["en", "de", "fr", "pl"]), "\(locales)")
    }

    @Test func theMeasurementMovesWithTheLanguage() {
        let widths = LayoutMeasure.shippedLocales.map { locale in
            LayoutMeasure.minimumWidth(locale: locale) { Self.editor().sheetContent }
        }
        #expect(widths.allSatisfy { $0 > 0 }, "\(widths)")
        #expect(Set(widths).count > 1, "\(widths)")
    }

    @Test func theGermanFigureIsTheOneTheCommittedGuardReports() {
        let width = LayoutMeasure.minimumWidth(locale: "de") { Self.editor().sheetContent }
        #expect(width == 411, "\(width)")
    }

    /// Not a test of the harness: a pin on a SwiftUI behaviour that makes a
    /// wrong USE of it silent. Labels on a view's top level resolve at
    /// construction; labels inside nested closures resolve at render. A view
    /// built outside the override therefore carries the process language's
    /// top-level labels into a measurement taken inside it, and the figure
    /// comes back plausible and wrong. If SwiftUI changes this, this test
    /// goes red and the closure-taking signature can be revisited.
    @Test func buildingOutsideTheOverrideUnderMeasures() {
        let outside = Self.editor().sheetContent
        let wrong = LayoutMeasure.minimumWidth(locale: "de") { outside }
        let right = LayoutMeasure.minimumWidth(locale: "de") { Self.editor().sheetContent }
        #expect(wrong < right, "outside \(wrong), inside \(right)")
    }
}
