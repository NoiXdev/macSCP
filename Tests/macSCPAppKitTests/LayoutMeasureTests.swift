import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Holds `LayoutMeasure` itself to account: the harness every later layout
/// guard reads its figures from.
///
/// The editor's sheet content is the reference view because the committed
/// guard already reports a width for it in each language; the harness has to
/// reproduce that figure or it is a second, different instrument. That guard
/// was `FileActionEditorLayoutGuardTests` when this was written and is
/// `BoundedViewLayoutGuardTests` now, whose `FileActionEditor` entry reports
/// the same 411 pt in German that `theGermanFigureIsTheOneTheCommittedGuardReports`
/// pins below.
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

    /// The one hard figure in this branch, and the first test a different
    /// machine will fail.
    ///
    /// **411 pt, measured 2026-10-18 on Darwin 27.0.0 (macOS 27.0.1, build
    /// 26A434, arm64), Swift 6.4.** It reproduces two ways, and they are the
    /// same measurement read from two instruments:
    ///
    /// ```
    /// swift test --filter theGermanFigureIsTheOneTheCommittedGuardReports
    /// MACSCP_BOUND_FIGURES=1 swift test --filter BoundedViewFigureReportTests
    /// ```
    ///
    /// the second of which prints, among its forty lines,
    /// `boundfigures: FileActionEditor [a new draft] wide de 411.0/843.0 …`.
    /// The point of pinning it is that the two agree: this harness and the
    /// guard that every other layout figure comes from are one instrument, not
    /// two.
    ///
    /// **What to do when it goes red.** A text measurement is a property of the
    /// system font, the text engine and the OS version, so a run on macos-15 —
    /// which no CI run has made (`docs/BACKLOG.md`, the row beginning "Every
    /// layout figure the guards hold was measured on Darwin 27") — may well
    /// report a different number. The ruling, from the plan's own dispatch:
    /// **a red here is answered by re-measuring and recording the new figure
    /// with its date and platform, never by reverting the component.** The
    /// figure is evidence about the host, not a requirement on the view; what
    /// IS a requirement is measured by `BoundedViewLayoutGuardTests`, which
    /// compares each view's need with what it grants and needs no constant.
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

    // MARK: - The two measurements the later tasks lean on

    /// A bare segmented picker is compressible: its minimum is below its
    /// ideal in at least one catalogue (measured 2026-10-17 for these two
    /// labels in `pl`: minimum 173.5, ideal 219.0). Under `.fixedSize()` it
    /// cannot compress, so ideal and minimum agree. The relationship is what
    /// the rigidity check reads; the numbers are only why this test exists.
    @Test func idealWidthExceedsTheMinimumOfACompressibleControlAndEqualsItOnceRigid() {
        func picker() -> some View {
            Picker("", selection: .constant(false)) {
                L10n.text("snippets.variables.kind.freeText", "Free text").tag(false)
                L10n.text("snippets.variables.kind.selection", "Choice").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        let bare = LayoutMeasure.shippedLocales.map {
            (
                LayoutMeasure.minimumWidth(locale: $0) { picker() },
                LayoutMeasure.idealWidth(locale: $0) { picker() }
            )
        }
        #expect(bare.contains { $0.1 > $0.0 }, "\(bare)")
        for locale in LayoutMeasure.shippedLocales {
            let minimum = LayoutMeasure.minimumWidth(locale: locale) { picker().fixedSize() }
            let ideal = LayoutMeasure.idealWidth(locale: locale) { picker().fixedSize() }
            #expect(minimum == ideal, "\(locale): minimum \(minimum), ideal \(ideal)")
        }
    }

    /// A wrapping paragraph needs more height the narrower it is offered, but
    /// only once it is vertically rigid. Measured 2026-10-18 (a 12-fold
    /// repeated sentence, `en`): a bare `Text` reports 16.0 at both 120 and
    /// 600 pt, because a proposed height of zero lets it truncate to one line;
    /// with `.fixedSize(horizontal: false, vertical: true)` it reports 384.0
    /// at 120 pt and 80.0 at 600 pt. So `minimumHeight` is, like
    /// `minimumWidth`, a figure for "needs" only on content that marks what
    /// cannot compress. The bare half is pinned so that a change to it is
    /// discovered rather than assumed.
    @Test func minimumHeightGrowsAsTheProposedWidthShrinks() {
        func paragraph() -> some View {
            Text(String(repeating: "a long sentence that has to wrap ", count: 12))
        }
        func rigid() -> some View {
            paragraph().fixedSize(horizontal: false, vertical: true)
        }
        let narrow = LayoutMeasure.minimumHeight(locale: "en", at: 120) { rigid() }
        let generous = LayoutMeasure.minimumHeight(locale: "en", at: 600) { rigid() }
        #expect(generous > 0, "\(generous)")
        #expect(narrow > generous, "narrow \(narrow), generous \(generous)")

        let bareNarrow = LayoutMeasure.minimumHeight(locale: "en", at: 120) { paragraph() }
        let bareGenerous = LayoutMeasure.minimumHeight(locale: "en", at: 600) { paragraph() }
        #expect(bareNarrow == bareGenerous, "narrow \(bareNarrow), generous \(bareGenerous)")
    }
}
