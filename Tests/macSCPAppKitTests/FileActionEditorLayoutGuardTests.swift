import AppKit
import Foundation
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Holds the file-action editor to the width its sheet grants, in every
/// language the app ships.
///
/// The sheet was a fixed 520 pt, chosen against English, and a Polish
/// segmented picker (the two labels side by side, 65 characters against
/// English's 41) was wider than that. A fixed frame does not refuse content
/// that does not fit, it centres the overflow, so both edges of the sheet
/// were cut off. That arrived as a screenshot. This is the same finding
/// arriving as a red test instead: each catalogue is drawn through
/// `L10n.localeOverride`, the editor is hosted, and the width it needs is
/// compared with `FileActionEditor.sheetWidth`.
///
/// **What is measured.** `NSHostingController.sizeThatFits(in:)` with a
/// proposed width of zero returns the smallest width the content can take
/// without clipping: the longest unbreakable run of text, and every control
/// that cannot compress. That only means "needs" because the editor marks
/// each localized control that cannot wrap `.fixedSize()`; a compressible
/// control reports a small minimum and is squeezed instead, so it would pass
/// here while its labels were cut. That is the one property this guard
/// leans on, and the measurement test below proves the instrument moves with
/// the language, which a measurement of nothing would not.
///
/// **What is not measured:** the `FormRow` label column (a fixed 110 pt, in
/// which a long label is cut with an ellipsis and widens nothing), a
/// wrapped paragraph's height, and any state the two drafts below do not put
/// on screen.
///
/// The catalogues are read from disk and the locale list is the directory
/// listing, so a fifth language is measured the day its `.lproj` lands. No
/// label is spelled here.
@Suite("File action editor layout guard", .serialized)
@MainActor
struct FileActionEditorLayoutGuardTests {
    private static let resources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/Resources")

    /// Every shipped catalogue, by directory.
    private static let locales: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }.sorted()
    }()

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(
            contentsOf: resources.appendingPathComponent("\(locale).lproj/Localizable.strings"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private static func editor(_ action: FileAction?) -> FileActionEditor {
        FileActionEditor(
            existing: action,
            store: FileActionStore(directory: FileManager.default.temporaryDirectory),
            onSaved: {})
    }

    private static func variable(
        _ name: String, _ kind: SnippetVariable.Kind, _ placement: SnippetVariable.Placement
    ) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: "p", kind: kind, placement: placement,
            defaultValue: "", remembersLastValue: false)
    }

    /// The two drafts the editor is measured in: a new one, and one with a
    /// declared variable of each kind and each placement, so the variable
    /// row's own pickers are on screen.
    private static let drafts: [(name: String, action: FileAction?)] = [
        ("new", nil),
        (
            "with variables",
            FileAction(
                name: "Zip", command: "zip out.zip {{PATHS}} {{WHERE}}",
                variables: [
                    variable("WHERE", .selection(["a", "b"]), .placeholder),
                    variable("NOTE", .freeText, .environment),
                ],
                runsOn: [.remote, .local], perSelection: .onceWithEveryPath)
        ),
    ]

    /// The smallest width the editor's content can take without clipping.
    private static func requiredWidth(locale: String, action: FileAction?) -> CGFloat {
        L10n.$localeOverride.withValue(locale) {
            NSHostingController(rootView: editor(action).sheetContent)
                .sizeThatFits(in: CGSize(width: 0, height: 100_000)).width
        }
    }

    // MARK: - The guard

    @Test func theContentNeedsNoMoreThanTheSheetGrantsInEveryLanguage() {
        let granted = FileActionEditor.sheetWidth
        for locale in Self.locales {
            for draft in Self.drafts {
                let needed = Self.requiredWidth(locale: locale, action: draft.action)
                #expect(
                    needed <= granted,
                    "\(locale), \(draft.name): the content needs \(needed) pt, the sheet grants \(granted) pt")
            }
        }
    }

    // MARK: - Positive checks: the guard measures something

    @Test func everyShippedLanguageIsMeasured() {
        #expect(Set(Self.locales).isSuperset(of: ["en", "de", "fr", "pl"]), "\(Self.locales)")
        #expect(!Self.drafts.isEmpty)
    }

    /// The override is what puts a catalogue's text on screen: under it, each
    /// label this sheet is widest in comes back as that catalogue's value, not
    /// the fallback and not the process language.
    @Test func theLabelsTheMeasurementDependsOnAreTheCataloguesOwn() throws {
        let keys = [
            "fileAction.editor.titleNew", "fileAction.editor.form.perFile",
            "fileAction.editor.form.everyPath", "fileAction.editor.form.perFile.hint",
            "fileAction.editor.form.everyPath.hint", "fileAction.editor.side.remote",
            "fileAction.editor.side.local", "snippets.variables.kind.freeText",
            "snippets.variables.kind.selection", "snippets.variables.placement.placeholder",
            "snippets.variables.placement.environment",
        ]
        for locale in Self.locales {
            let catalogue = try Self.catalog(locale)
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

    /// A measurement that came back the same for every language would be a
    /// measurement of nothing (a zero, or a view that never saw the override).
    @Test func theMeasurementIsNonZeroAndMovesWithTheLanguage() {
        let widths = Self.locales.map {
            Self.requiredWidth(locale: $0, action: Self.drafts[0].action)
        }
        #expect(widths.allSatisfy { $0 > 0 }, "\(widths)")
        #expect(Set(widths).count > 1, "\(widths)")
    }
}
