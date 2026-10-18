import AppKit
import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Holds every view that bounds its own size to what that bound grants, in
/// every language the app ships.
///
/// This replaces `FileActionEditorLayoutGuardTests`, which measured one view.
/// The defect it was written for — a sheet fixed at a width chosen against
/// English, with a Polish label wider than that, so a fixed frame centred the
/// overflow and cut off both edges — reached the maintainer as a screenshot
/// because thirty-two other views had the same shape and no measurement at
/// all. `BoundedViewRegistry` pairs each conformer with the state that puts
/// its widest and tallest content up; this suite hosts each one under every
/// `.lproj` catalogue and compares what it needs with what it grants.
///
/// **What is measured.** `NSHostingController.sizeThatFits(in:)` offered a
/// width of zero returns the smallest width the content can take without
/// clipping: the longest unbreakable run of text, and every control that
/// cannot compress. That is a figure for "needs" only where a localized
/// control that cannot wrap is marked `.fixedSize()`; a compressible control
/// reports a small minimum and is squeezed instead, so it passes here while
/// its labels are cut. Making those controls rigid is the rest of this plan,
/// and this guard is the net that catches a rigid control which no longer
/// fits.
///
/// **What is not measured.** Any state the registry does not put on screen;
/// a wrapped paragraph's height in a view whose bound fixes no height (there
/// is nothing to compare it against); and a fixed-width label column such as
/// `FormRow`'s, in which a long label is cut with an ellipsis and widens
/// nothing.
///
/// The locale list is the `.lproj` directory listing, so a fifth language is
/// measured the day its catalogue lands. No locale code and no display
/// string is spelled here.
@Suite("Bounded view layout guard", .serialized)
@MainActor
struct BoundedViewLayoutGuardTests {

    // MARK: - Measuring through the seam

    /// The width an entry's content needs, measured with the view's own
    /// bound suspended.
    ///
    /// The suspension is the whole instrument: hosted whole, a bounded view
    /// reports its bound and nothing else, so the comparison below would be
    /// a number against itself. `theSeamIsWhatLetsTheGuardGoRed` measures
    /// both ways and pins the difference.
    private static func neededWidth(_ entry: BoundedViewEntry, _ locale: String) -> CGFloat {
        SheetBound.$isSuspendedForMeasurement.withValue(true) {
            LayoutMeasure.minimumWidth(locale: locale, of: entry.content)
        }
    }

    /// The height an entry's content needs at `width`, measured with the
    /// bound suspended and the content made vertically rigid.
    ///
    /// Without `.fixedSize(horizontal: false, vertical: true)` the figure is
    /// not a height the view needs: offered a height of zero, wrapping text
    /// truncates to one line and reports that, the same figure at any width
    /// (`LayoutMeasureTests.minimumHeightGrowsAsTheProposedWidthShrinks`
    /// measures 16.0 pt at both 120 and 600 pt for a paragraph that really
    /// needs 384.0 and 80.0). A comparison of ~16 pt against a granted 440 pt
    /// is green for every view whatever its content, which is a guard that
    /// cannot go red. `theHeightHalfMeasuresRigidContent` is the positive
    /// check that this one does.
    ///
    /// **Corrected 2026-10-18, fix round 2.** The two lines above read:
    ///
    /// > `theHeightMeasurementMovesWithTheProposedWidth` is the
    /// > positive check that this one does.
    ///
    /// That test cannot establish it. Removing this `.fixedSize` through
    /// `scripts/mutation-probe`, with no bound narrowed, leaves it green —
    /// a flow-layout entry's bare height still grows when the proposed width
    /// is cut to a third, so "it moved" cannot tell a needed height from a
    /// squeezed one. `theHeightHalfMeasuresRigidContent` compares the two
    /// measurements directly and is the one test that plant turns red.
    ///
    /// Measured on the registry itself, 2026-10-18, German, at each entry's
    /// granted width: rigid against bare, `WhatsNewSheet` 236.0 against
    /// 109.0, `TagFilterSheet` 188.24 against 132.0, `HiddenImportsSheet`
    /// 207.0 against 191.0 — and every other entry that grants a height the
    /// same figure both ways, because its tallest element is a `List` or a
    /// `ScrollView` rather than a paragraph. The difference is the whole
    /// comparison for the first three: narrowing `WhatsNewSheet`'s granted
    /// height to 150 through `scripts/mutation-probe` is RED with this
    /// `.fixedSize` and GREEN with it dropped, which is the same plant
    /// read twice.
    private static func neededHeight(
        _ entry: BoundedViewEntry, _ locale: String, at width: CGFloat
    ) -> CGFloat {
        SheetBound.$isSuspendedForMeasurement.withValue(true) {
            LayoutMeasure.minimumHeight(locale: locale, at: width) {
                entry.content().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The guard

    @Test func noViewNeedsMoreThanItsBoundGrantsInAnyLanguage() {
        for entry in BoundedViewRegistry.all {
            for locale in LayoutMeasure.shippedLocales {
                let width = Self.neededWidth(entry, locale)
                #expect(
                    width <= entry.bound.grantedWidth,
                    """
                    \(entry.typeName), \(entry.stateName), \(locale): \
                    needs \(width) pt, granted \(entry.bound.grantedWidth) pt
                    """)
                if let grantedHeight = entry.bound.grantedHeight {
                    let height = Self.neededHeight(
                        entry, locale, at: entry.bound.grantedWidth)
                    #expect(
                        height <= grantedHeight,
                        """
                        \(entry.typeName), \(entry.stateName), \(locale): \
                        needs \(height) pt tall, granted \(grantedHeight) pt
                        """)
                }
            }
        }
    }

    // MARK: - Positive checks: the guard measures something

    /// Every shipped catalogue is in the list the guard loops over, and the
    /// registry is not empty. A locale list that went empty, or a registry
    /// that lost its entries, would make the guard above pass by measuring
    /// nothing at all.
    @Test func everyShippedLanguageIsMeasured() {
        let locales = LayoutMeasure.shippedLocales
        #expect(Set(locales).isSuperset(of: ["en", "de", "fr", "pl"]), "\(locales)")
        #expect(!BoundedViewRegistry.all.isEmpty)
    }

    /// A measurement that came back zero, or the same figure for every
    /// language, would be a measurement of nothing: a view that never saw
    /// the override, or an instrument that answers before it has drawn
    /// anything.
    ///
    /// **The across-the-registry half of this is weak, and the named half
    /// below it is why that is tolerable.** Counted 2026-10-18 with this
    /// suite's own committed reporter, `MACSCP_BOUND_FIGURES=1 swift test
    /// --filter BoundedViewFigureReportTests`: **32 of the 38 entries report
    /// the same minimum width in all four catalogues**, so "at least one
    /// entry moved" can be satisfied by `AuditLogSheet` alone while every
    /// other view goes flat. The deleted `FileActionEditorLayoutGuardTests`
    /// pinned THAT view's width to move, and this check inherits that
    /// obligation explicitly rather than hoping the registry-wide version
    /// covers it: `FileActionEditor` is the view whose rigid controls the
    /// whole guard was written for, and it is exactly the view Tasks 8 to 10
    /// could flatten without any other entry noticing.
    @Test func theRegistryMeasuresSomething() {
        var movesWithTheLanguage = false
        var editorEntries = 0
        let editorName = String(describing: FileActionEditor.self)
        for entry in BoundedViewRegistry.all {
            let widths = LayoutMeasure.shippedLocales.map { Self.neededWidth(entry, $0) }
            #expect(widths.allSatisfy { $0 > 0 }, "\(entry.typeName), \(entry.stateName): \(widths)")
            if Set(widths).count > 1 { movesWithTheLanguage = true }
            // The inherited obligation, on every entry of that one type.
            // Measured 2026-10-18: 411.0 / 364.0 / 370.0 / 405.0 for `de`,
            // `en`, `fr`, `pl`, for both drafts.
            if entry.typeName == editorName {
                editorEntries += 1
                #expect(
                    Set(widths).count > 1,
                    "\(entry.typeName), \(entry.stateName): one width in every catalogue, \(widths)")
            }
        }
        #expect(movesWithTheLanguage, "no entry's width changed with the catalogue")
        #expect(editorEntries > 0, "the registry has no \(editorName) entry to hold to that")
    }

    /// The height the guard compares is the height of RIGID content, and
    /// this is the check that notices when it stops being.
    ///
    /// `theHeightMeasurementMovesWithTheProposedWidth` below does not notice:
    /// measured 2026-10-18 through `scripts/mutation-probe`, narrowing
    /// `WhatsNewSheet`'s granted height to 150 is RED with `neededHeight`'s
    /// `.fixedSize(horizontal: false, vertical: true)` and GREEN without it,
    /// and that GREEN was a verdict over the whole suite — so a 236-pt
    /// content inside a 150-pt bound went unreported while every other check
    /// here, that one included, stayed satisfied. A flow-layout entry's BARE
    /// height still grows when the proposed width is cut to a third, which is
    /// why "it moved" cannot tell the two apart.
    ///
    /// So: at each entry's own granted width, compare the figure the guard
    /// uses against the same measurement without the modifier. Rigid is never
    /// the smaller of the two, and for at least one entry it is strictly
    /// larger. Measured the same day, German: `WhatsNewSheet` 236.0 against
    /// 109.0, `TagFilterSheet` 188.24 against 132.0, `HiddenImportsSheet`
    /// 207.0 against 191.0, every other height-granting entry equal both
    /// ways. The rigid figure comes from `neededHeight` itself rather than
    /// from a second copy of that expression, so removing the modifier there
    /// collapses this comparison instead of leaving it comparing a copy with
    /// itself.
    ///
    /// No entry is named: the registry is filtered to those that grant a
    /// height, and which of them carries a wrapping paragraph is read off the
    /// measurement rather than spelled.
    @Test func theHeightHalfMeasuresRigidContent() {
        let entries = BoundedViewRegistry.all.filter { $0.bound.grantedHeight != nil }
        #expect(!entries.isEmpty, "no entry grants a height, so the height half measures nothing")
        var rigidExceedsBare = false
        for entry in entries {
            let granted = entry.bound.grantedWidth
            let rigid = Self.neededHeight(entry, "de", at: granted)
            let bare = SheetBound.$isSuspendedForMeasurement.withValue(true) {
                LayoutMeasure.minimumHeight(locale: "de", at: granted, of: entry.content)
            }
            #expect(
                rigid >= bare,
                "\(entry.typeName), \(entry.stateName): rigid \(rigid) below bare \(bare)")
            if rigid > bare { rigidExceedsBare = true }
        }
        #expect(rigidExceedsBare, """
            no entry's height grew when its content was made vertically rigid, so the guard's \
            height half is measuring what the content can be squeezed to
            """)
    }

    /// The height half moves with the width it is offered, which is what
    /// makes the height comparison in the guard a comparison of anything.
    /// Offered a third of its granted width, content that wraps needs more
    /// height than at the full width.
    ///
    /// Not every entry can show that — a sheet whose tallest element is a
    /// `List` or a `ScrollView` reports the same height at any width — so
    /// the per-entry check is that the figure is positive, and the
    /// across-entries check is that at least one entry's figure moved.
    ///
    /// It does NOT establish that the figure is a height the content needs
    /// rather than one it can be squeezed to; `theHeightHalfMeasuresRigidContent`
    /// above is the check for that.
    ///
    /// **What fix round 1 withdrew, corrected in round 2.** The sentence it
    /// overstated is `neededHeight`'s, not this one's, and it reads, verbatim:
    ///
    /// > `theHeightMeasurementMovesWithTheProposedWidth` is the
    /// > positive check that this one does.
    ///
    /// — "this one" being the height half's ability to go red. Round 1 wrote
    /// here instead that the comment "used to claim this one refused `a height
    /// half that reports a truncated single line`", and **that quotation was
    /// never in this file**. One command settles it, and it is pinned to a
    /// commit so that this paragraph cannot change its answer:
    ///
    /// ```
    /// git show 7a6fcb78:Tests/macSCPAppKitTests/BoundedViewLayoutGuardTests.swift \
    ///   | grep -c 'truncated single line'
    /// ```
    ///
    /// prints `0` — `7a6fcb78` being the commit round 1 was written against.
    /// A `git log -S'truncated single line' --all` taken the same day, before
    /// this correction, named exactly one commit: `812078ce`, the one that
    /// claimed to be withdrawing the phrase. That second command is NOT
    /// pinned and will answer differently from here on, because the
    /// paragraph you are reading quotes the phrase in order to name it.
    ///
    /// Where the phrase really came from: the task's own report, in a table
    /// cell describing this test, which the round-1 review quoted and
    /// attributed to this comment — and round 1 repeated the attribution
    /// without reading the file. A quote nobody can find is worse than no
    /// quote: it cannot be checked, and it borrows a reader's trust. It is
    /// the failure the quoting rule exists to prevent, committed by the
    /// correction applying that rule.
    @Test func theHeightMeasurementMovesWithTheProposedWidth() {
        let entries = BoundedViewRegistry.all.filter { $0.bound.grantedHeight != nil }
        #expect(!entries.isEmpty, "no entry grants a height, so the height half measures nothing")
        var movesWithTheWidth = false
        for entry in entries {
            let granted = entry.bound.grantedWidth
            let atGranted = Self.neededHeight(entry, "en", at: granted)
            let atNarrow = Self.neededHeight(entry, "en", at: granted / 3)
            #expect(atGranted > 0, "\(entry.typeName), \(entry.stateName): \(atGranted)")
            if atNarrow > atGranted { movesWithTheWidth = true }
        }
        #expect(movesWithTheWidth, "no entry's height changed with the proposed width")
    }

    /// Not a check on the views: a pin on the behaviour that decides what
    /// nine of the registry's entries are able to show.
    ///
    /// Eight listing sheets read their rows in `.onAppear`, and
    /// `NSHostingController.sizeThatFits` lays a view out without ever
    /// appearing it. Measured 2026-10-18 on `SnippetsSheet`: a store seeded
    /// with two snippets and an empty store report the same width and the
    /// same height. The seeded store really does hold them — that is the
    /// positive half, and without it this test would pass just as happily
    /// over two empty directories.
    ///
    /// So those entries measure each sheet's chrome and its empty-state
    /// sentence, not a row. If SwiftUI ever runs `.onAppear` here, every one
    /// of those figures changes and this test is where that is noticed.
    @Test func aSheetThatLoadsItsRowsOnAppearIsMeasuredEmpty() throws {
        let seeded = try Self.directory()
        let empty = try Self.directory()
        defer {
            try? FileManager.default.removeItem(at: seeded)
            try? FileManager.default.removeItem(at: empty)
        }
        let store = SnippetStore(directory: seeded)
        try store.save(Snippet(name: "the first stored snippet", command: "echo one"))
        try store.save(Snippet(name: "the second stored snippet", command: "echo two"))
        // Read out of the `#expect` and into a `let`: `#expect(try …)` over a
        // call the macro cannot see as throwing warns, and CI counts warnings.
        let seededSnippets = try store.all()
        let emptySnippets = try SnippetStore(directory: empty).all()
        #expect(seededSnippets.count == 2)
        #expect(emptySnippets.isEmpty)

        func measure(_ directory: URL) -> (width: CGFloat, height: CGFloat) {
            func sheet() -> SnippetsSheet {
                SnippetsSheet(
                    store: SnippetStore(directory: directory), rememberedValue: { _, _ in nil })
            }
            return SheetBound.$isSuspendedForMeasurement.withValue(true) {
                (
                    LayoutMeasure.minimumWidth(locale: "en", of: sheet),
                    LayoutMeasure.minimumHeight(
                        locale: "en", at: SnippetsSheet.bound.grantedWidth
                    ) { sheet().fixedSize(horizontal: false, vertical: true) }
                )
            }
        }
        let withRows = measure(seeded)
        let withoutRows = measure(empty)
        #expect(withRows.width > 0 && withRows.height > 0, "\(withRows)")
        #expect(withRows == withoutRows, "seeded \(withRows), empty \(withoutRows)")
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-view-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A view registered in two states must really be in two states.
    ///
    /// Two entries that measure identically in every catalogue, on every
    /// figure the instrument reports, are one state entered twice: the
    /// second costs a measurement and tests nothing, and its `stateName`
    /// says something about the view that is not true. Found this way on
    /// 2026-10-18, before this check existed: `FileActionConfirmSheet`'s
    /// "a remote plan over two files" and "a refused plan with nothing
    /// selected" both reported 76.0 pt minimum and the same four ideals,
    /// because the action they were planned from was refused by
    /// `FileActionTemplate.firstProblem` and both rendered that one refusal.
    ///
    /// Both widths, because one is not enough: the two `FileActionEditor`
    /// drafts share a minimum width (411.0 pt in German for each) and are
    /// told apart only by their ideal (843.0 against 1268.0), the variable
    /// row being what the second adds.
    ///
    /// And the height too, because two widths are not enough either: once
    /// `SnippetEditorView`'s placement-check checkbox was held at its ideal,
    /// that one control set the minimum width of both its states and the two
    /// ideals came out equal, so a new snippet and a stored one with two
    /// declarations tied on both widths. They still differ in height, the
    /// declarations being extra rows. The height is measured at the entry's
    /// own granted width, as the guard measures it.
    @Test func entriesOfOneTypeMeasureDifferentStates() {
        let byType = Dictionary(grouping: BoundedViewRegistry.all, by: \.typeName)
        var checkedAPair = false
        for (typeName, entries) in byType where entries.count > 1 {
            checkedAPair = true
            var seen: [[CGFloat]: String] = [:]
            for entry in entries {
                let shape = LayoutMeasure.shippedLocales.flatMap { locale -> [CGFloat] in
                    let minimum = Self.neededWidth(entry, locale)
                    let ideal = SheetBound.$isSuspendedForMeasurement.withValue(true) {
                        LayoutMeasure.idealWidth(locale: locale, of: entry.content)
                    }
                    let height = Self.neededHeight(
                        entry, locale, at: entry.bound.grantedWidth)
                    return [minimum, ideal, height]
                }
                if let twin = seen[shape] {
                    Issue.record("""
                        \(typeName): \(entry.stateName) and \(twin) measure the same in every \
                        catalogue (\(shape)), so one of them is not the state it names
                        """)
                }
                seen[shape] = entry.stateName
            }
        }
        #expect(checkedAPair, "no type is registered in two states, so this compared nothing")
    }

    /// The seam is what the two measurements above lean on, and it is the
    /// one thing whose failure would be silent: with it broken, every entry
    /// would report its own bound, every comparison would be a number
    /// against itself, and the suite would be green for any content.
    ///
    /// Measured 2026-10-18 on `FileActionEditor` under the German
    /// catalogue: hosted whole it reports 520.0 pt, which is its bound;
    /// through the seam, 411.0 pt, which is what its content needs. 411 is
    /// the figure the deleted `FileActionEditorLayoutGuardTests` reported
    /// for the same view, and `LayoutMeasureTests` pins it independently of
    /// the registry.
    ///
    /// The seam figure is compared for INEQUALITY with the bound rather than
    /// for being below it, so that this test stays a statement about the
    /// instrument. Under the `de`-only overflow plant of 2026-10-18 the
    /// editor's content needed 713.0 pt inside a 520 pt bound; a `<` here
    /// went red alongside the guard, reporting the view's defect a second
    /// time in a test whose subject is the seam.
    @Test func theSeamIsWhatLetsTheGuardGoRed() throws {
        let entry = try #require(
            BoundedViewRegistry.all.first { $0.typeName == String(describing: FileActionEditor.self) },
            "the registry has no FileActionEditor entry")
        let whole = LayoutMeasure.minimumWidth(locale: "de", of: entry.content)
        let throughTheSeam = Self.neededWidth(entry, "de")
        #expect(whole == entry.bound.grantedWidth, "\(whole)")
        #expect(throughTheSeam != whole, "seam \(throughTheSeam), whole \(whole)")
        // The same view the deleted guard measured, by the path it measured
        // it: the registry's entry is not a differently-built stand-in.
        let direct = LayoutMeasure.minimumWidth(locale: "de") {
            BoundedViewRegistry.fileActionEditor(existing: nil).sheetContent
        }
        #expect(throughTheSeam == direct, "seam \(throughTheSeam), sheetContent \(direct)")
    }

    /// The override is what puts a catalogue's text on screen: under it,
    /// each label a measurement depends on comes back as that catalogue's
    /// own value, not the fallback and not the process language.
    ///
    /// The keys are the ones the deleted guard listed for the file-action
    /// editor, kept because that view is still the registry's reference
    /// entry and because a catalogue that lost one of them would change a
    /// measured width without anything else noticing.
    @Test func theLabelsTheMeasurementDependsOnAreTheCataloguesOwn() throws {
        let keys = [
            "fileAction.editor.titleNew", "fileAction.editor.form.perFile",
            "fileAction.editor.form.everyPath", "fileAction.editor.form.perFile.hint",
            "fileAction.editor.form.everyPath.hint", "fileAction.editor.side.remote",
            "fileAction.editor.side.local", "snippets.variables.kind.freeText",
            "snippets.variables.kind.selection", "snippets.variables.placement.placeholder",
            "snippets.variables.placement.environment",
        ]
        for locale in LayoutMeasure.shippedLocales {
            let catalogue = try Self.catalogue(locale)
            for key in keys {
                let expected = try #require(catalogue[key], "\(locale) lacks \(key)")
                let looked = L10n.$localeOverride.withValue(locale) {
                    L10n.string(key, "no such label")
                }
                let matches = looked == expected && !expected.isEmpty
                #expect(matches, "\(locale): \(key)")
            }
        }
    }

    private static let resources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/Resources")

    private static func catalogue(_ locale: String) throws -> [String: String] {
        let data = try Data(
            contentsOf: resources.appendingPathComponent("\(locale).lproj/Localizable.strings"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
