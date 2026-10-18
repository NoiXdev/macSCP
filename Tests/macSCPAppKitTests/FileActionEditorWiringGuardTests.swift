import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Guards the wiring of the file-action editor (file-actions plan, 2026-10-12,
/// Task 11) where a unit test cannot reach: the editor asking the gate, its
/// controls binding the action's fields, the sheet reaching the store and the
/// codec, the menu route, and every string it shows being in all four
/// catalogues.
///
/// Structural claims read `SourceCorpus.code` (comments AND string literals
/// blanked), catalogue-key claims read `SourceCorpus.commentFree`. Every
/// negative check has a positive check beside it naming the thing it scans.
///
/// Known blind spot: SOURCE TEXT only. That the sheet and the editor render,
/// that the picker flips the form and that Save greys out are sight checks,
/// and Task 12 assigns them to the maintainer.
@Suite("File action editor wiring guard")
struct FileActionEditorWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static func code(_ name: String) throws -> String {
        try SourceCorpus.code(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func literals(_ name: String) throws -> String {
        try SourceCorpus.commentFree(of: path("Sources/MacSCPAppKit/\(name)"))
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let data = try Data(
            contentsOf: path("Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private static let locales = ["en", "de", "fr", "pl"]

    private static let editorFile = "FileActionEditor.swift"
    private static let sheetFile = "FileActionsSheet.swift"
    private static let presentationFile = "FileActionsPresentation.swift"
    private static let surfaceFiles = [editorFile, sheetFile, presentationFile]

    // MARK: - The editor

    /// The editor's one job beyond data entry is to refuse legibly: the gate
    /// is asked as the author types, and Save is held back while it has an
    /// answer. The command that is judged is the one that would be stored.
    @Test func theEditorAsksTheGateAndHoldsSaveBackWhileItHasAnAnswer() throws {
        let editor = try Self.code(Self.editorFile)
        #expect(editor.contains("FileActionTemplate.firstProblem("))
        #expect(editor.contains("FileActionAuthoring.normalizedCommand("))
        #expect(editor.contains(".disabled(isSaveDisabled)"))
        #expect(editor.contains("problem != nil"))
        #expect(editor.contains("fileActionProblemText(for:"))
    }

    @Test func thePickerBindsThePerSelectionFormAndTheTogglesBindTheSides() throws {
        let editor = try Self.code(Self.editorFile)
        // `RadioChoice` offers one radio per case of the type it is bound to,
        // so binding it to `$perSelection` is what puts every
        // `FileActionPerSelection` case on screen.
        #expect(editor.contains("RadioChoice("))
        #expect(editor.contains("selection: $perSelection"))
        // Two checkboxes, one per side, each folded into the action's `runsOn`.
        #expect(editor.components(separatedBy: "CheckboxRow(").count - 1 >= 2)
        #expect(editor.contains("runsOn:"))
        #expect(editor.contains("BrowserPaneSide.allCases"))
        #expect(editor.contains("perSelection:"))
    }

    /// The preview shows what the CONFIRMATION sheet will show, from the one
    /// planner, on each side the action runs on. It does not reuse
    /// `SnippetDryRunSheet`, which captions its command with
    /// "snippets.dryRun.command" ("Would go to the shell", `SnippetDryRunSheet
    /// .swift`) and is fed by `SnippetDryRun.describing`: one resolved command
    /// on its way into a shell, which is false of a local-only action, whose
    /// plan is an argv with no shell at all.
    @Test func thePreviewIsThePlannersOwnOutputAndNotASnippetShapedDescription() throws {
        let editor = try Self.code(Self.editorFile)
        #expect(editor.contains("FileActionPlanner.plan("))
        #expect(editor.contains("FileActionPlanDisplay.lines(for:"))
        #expect(editor.contains("SnippetDryRun.describing(") == false)
    }

    /// Both surfaces that show a plan say where it goes, from the plan.
    @Test func thePreviewAndTheConfirmationSheetSayWhereThePlanGoes() throws {
        let editor = try Self.code(Self.editorFile)
        let sheet = try Self.code("FileActionConfirmSheet.swift")
        #expect(editor.contains("fileActionDestinationText(for: plan)"))
        #expect(sheet.contains("fileActionDestinationText(for: plan)"))
        let presentation = try Self.code(Self.presentationFile)
        let start = try #require(presentation.range(of: "func fileActionDestinationText("))
        let body = String(presentation[start.lowerBound...])
        // Read off the plan's case: the function takes a plan and no action,
        // and has no catch-all.
        #expect(body.contains("switch plan {"))
        #expect(body.prefix(400).contains("runsOn") == false)
        #expect(body.prefix(400).contains("default:") == false)
    }

    /// The command field is the snippet editor's, with its highlighting and
    /// its caret-aware insert.
    @Test func theCommandIsEditedInTheSnippetCommandEditor() throws {
        let editor = try Self.code(Self.editorFile)
        #expect(editor.contains("SnippetCommandEditor("))
        #expect(editor.contains("SnippetCommandEditorController"))
        #expect(editor.contains("VariableDraft"))
        // The reserved names are offered as the form supplies them, read
        // rather than spelled.
        #expect(editor.contains("FileActionTemplate.names(fitting:"))
    }

    // MARK: - The sheet

    @Test func theSheetReadsAndWritesTheStoreAndNothingElse() throws {
        let sheet = try Self.code(Self.sheetFile)
        #expect(sheet.contains("FileActionsLoad(reading:"))
        #expect(sheet.contains("store.remove(id:"))
        let editor = try Self.code(Self.editorFile)
        #expect(editor.contains("store.save("))
        // The two kinds stay apart: the snippet store is not reachable from
        // either file, and the positives above name the one that is.
        for source in [sheet, editor] {
            #expect(source.contains("SnippetStore") == false)
            #expect(source.contains("SnippetExportCodec") == false)
        }
    }

    @Test func importAndExportGoThroughTheActionsCodecOnly() throws {
        let sheet = try Self.code(Self.sheetFile)
        #expect(sheet.contains("FileActionExportCodec.encode("))
        #expect(sheet.contains("FileActionExportCodec.probe("))
        #expect(sheet.contains("FileActionExportCodec.decode("))
        #expect(sheet.contains("ExportedFileAction.init"))
        #expect(sheet.contains("SnippetExportCodec") == false)
    }

    /// An import is the one route by which an action reaches the store
    /// without the editor having looked at it, so it is reviewed before it
    /// is saved, and the user is told what was refused. `probe` THROWS for a
    /// foreign file, so the catch is for `SessionExportError`.
    @Test func anImportIsReviewedBeforeItIsStoredAndAForeignFileIsACaughtThrow() throws {
        let sheet = try Self.code(Self.sheetFile)
        #expect(sheet.contains("FileActionAuthoring.review("))
        #expect(sheet.contains("catch let error as SessionExportError"))
        // Within the function that applies an import: the review comes
        // first, and the save is a loop over what it ACCEPTED. A save
        // elsewhere in the file (the duplicate button's) is a different path.
        let start = try #require(sheet.range(of: "func applyImport("))
        let applied = String(sheet[start.lowerBound...])
        let review = try #require(applied.range(of: "FileActionAuthoring.review("))
        let save = try #require(applied.range(of: "store.save("))
        #expect(review.lowerBound < save.lowerBound, "a save is reached before the review")
        #expect(applied.contains("in review.accepted"), "the save is not over the accepted ones")
        let presentation = try Self.code(Self.presentationFile)
        #expect(presentation.contains("fileActionImportResultText("))
    }

    /// Names come from the store, and the store can hold an imported one. A
    /// name is drawn through the marker renderer or not at all.
    @Test func everyNameIsDrawnThroughTheMarkerRenderer() throws {
        let sheet = try Self.code(Self.sheetFile)
        #expect(sheet.contains("FileActionPlanDisplay.attributed("))
        #expect(sheet.contains("FileActionPlanDisplay.visible("))
        #expect(sheet.contains("Text(action.name)") == false)
        #expect(sheet.contains("Text(verbatim: action.name)") == false)
        let presentation = try Self.code(Self.presentationFile)
        #expect(presentation.contains("FileActionPlanDisplay.visible("))
    }

    // MARK: - The menu route

    @Test func theMenuItemReachesTheSheetWithoutAConnection() throws {
        let commands = try Self.code("MacSCPCommands.swift")
        #expect(commands.contains("tabCommands?.showFileActions?()"))
        let commandLiterals = try Self.literals("MacSCPCommands.swift")
        #expect(commandLiterals.contains("\"menu.fileActions.manage\""))
        let app = try Self.code("MacSCPApp.swift")
        #expect(app.contains("var showFileActions: (() -> Void)?"))
        let sheets = try Self.code("ContentView+Sheets.swift")
        #expect(sheets.contains("FileActionsSheet("))
        #expect(sheets.contains("func presentFileActions()"))
        let lifecycle = try Self.code("ContentView+Lifecycle.swift")
        #expect(lifecycle.contains("tabCommands.showFileActions = presentFileActions"))
    }

    /// Writing an action needs no server: the item sits next to the one for
    /// snippets and is not tied to a connection.
    ///
    /// **Scanned FORWARDS from the call.** A SwiftUI disablement attaches
    /// AFTER the trailing closure, so the span that can hold one runs from the
    /// call to the end of the builder that contains the button, and then over
    /// the use of that builder, where `snippetMenuItems.disabled(...)` could
    /// also be written. (The `CommandMenu` itself has no `disabled` member:
    /// a plant there does not compile, so there is nothing to scan for.) A
    /// span read backwards from the call holds only the label argument and
    /// can never match. The positive half of each span is that it was found
    /// and reaches what it should; the plants for this check (a
    /// `.disabled(...)` on the button, and one on the builder's use) are
    /// recorded in the commit that fixed it.
    @Test func theMenuItemIsNotDisabledByAConnectionAnywhereAfterTheButton() throws {
        let commands = try Self.code("MacSCPCommands.swift")
        let call = try #require(commands.range(of: "tabCommands?.showFileActions?()"))
        let afterCall = String(commands[call.upperBound...])

        // The button's own modifiers and everything after it up to the end of
        // the `@ViewBuilder` body that holds it (the closing brace at four
        // spaces of indent).
        let builderEnd = try #require(afterCall.range(of: "\n    }\n"))
        let toEndOfBuilder = String(afterCall[..<builderEnd.lowerBound])
        #expect(toEndOfBuilder.contains("}"), "the span did not reach the button's closing brace")
        #expect(toEndOfBuilder.contains(".disabled(") == false)
        #expect(toEndOfBuilder.contains("isActiveTabConnected") == false)

        // The use of the builder in the Terminal menu: the line it stands on
        // and the line after it, where a modifier would be written.
        let use = try #require(commands.range(of: "            snippetMenuItems\n"))
        let afterUse = String(commands[use.upperBound...])
        let nextLine = afterUse.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        #expect(nextLine.contains("}"), "the line after the use is not the menu's end: \(nextLine)")
        #expect(nextLine.contains(".disabled(") == false)
    }

    /// The span reads what it should: planted on a copy of the real source, a
    /// `.disabled` on the button or on the builder's use is found by the same
    /// scan.
    @Test func theScanFindsADisablementPlantedOnTheButtonOrTheBuildersUse() throws {
        let commands = try Self.code("MacSCPCommands.swift")
        let call = "tabCommands?.showFileActions?()"
        let onButton = commands.replacingOccurrences(
            of: call + "\n        }\n", with: call + "\n        }\n        .disabled(!connected)\n")
        #expect(onButton != commands, "the button plant did not apply")
        let spanAfterButton = try #require(
            onButton.range(of: call).map { String(onButton[$0.upperBound...]) })
        let builderEnd = try #require(spanAfterButton.range(of: "\n    }\n"))
        #expect(String(spanAfterButton[..<builderEnd.lowerBound]).contains(".disabled("))

        let onUse = commands.replacingOccurrences(
            of: "            snippetMenuItems\n",
            with: "            snippetMenuItems\n            .disabled(!connected)\n")
        #expect(onUse != commands, "the use plant did not apply")
        let use = try #require(onUse.range(of: "            snippetMenuItems\n"))
        let afterUse = String(onUse[use.upperBound...])
        let line = afterUse.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        #expect(line.contains(".disabled("))
    }

    // MARK: - The catalogues

    /// Every string the three surfaces show: the keys read out of the
    /// source, so a key spelled into this test would be a second copy of a
    /// name.
    private static func keysWithDefaults(in file: String) throws -> [(key: String, fallback: String)] {
        let text = try literals(file)
        let pattern =
            "L10n\\.(?:string|text)\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        let regex = try NSRegularExpression(pattern: pattern)
        let all = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: all).compactMap { match in
            guard let key = Range(match.range(at: 1), in: text),
                let fallback = Range(match.range(at: 2), in: text)
            else { return nil }
            return (String(text[key]), String(text[fallback]))
        }
    }

    private static func allKeysWithDefaults() throws -> [(key: String, fallback: String)] {
        try surfaceFiles.flatMap { try keysWithDefaults(in: $0) }
    }

    /// The keys this task added, by prefix: the three surfaces also reuse
    /// keys that already existed (`common.close`, `snippets.variables.name`
    /// and the like), which are checked below like any other.
    private static func ownKeys() throws -> Set<String> {
        Set(try allKeysWithDefaults().map(\.key).filter { $0.hasPrefix("fileAction.") })
    }

    /// Counted on 2026-10-12, on the three files as committed, with
    /// `/usr/bin/grep -o -h -E '"fileAction\.[A-Za-z.]+"' Sources/MacSCPAppKit/FileActionsSheet.swift Sources/MacSCPAppKit/FileActionEditor.swift Sources/MacSCPAppKit/FileActionsPresentation.swift | sort -u | wc -l`
    /// which printed 43 (47 before `sort -u`: four keys are used at more than
    /// one call site). `-o` and a unique sort, because a key and its call
    /// sometimes sit on different lines and one line can hold two keys. The
    /// task also added one key outside the prefix, `menu.fileActions.manage`,
    /// which this command does not see.
    ///
    /// Both figures were re-measured on 2026-10-12, by running the command
    /// above after this sentence was written; the change since the last
    /// measurement is one key, `fileAction.problem.commandControlCharacter`.
    /// Withdrawn, quoted: this comment read "which printed 42 (46 before
    /// `sort -u`", and `ownKeyCount` was 42.
    ///
    /// Withdrawn too, and not merely incremented: the comment went on "so
    /// each catalogue grew by 43 lines in this task: 40 first (39 plus the
    /// menu key), 2 for the two [...] captions in fix round 1, and 1 for the
    /// empty command's sentence in fix round 2." (the elided words are the
    /// caption label, quoted there with inner double quotes). That figure is
    /// about how much each CATALOGUE grew across one task, which nothing
    /// here derives and no command beside it measured, so incrementing it
    /// would have carried an uncheckable number forward. What is checkable
    /// is the command above and the count it prints.
    private static let ownKeyCount = 43

    @Test func theScanReachesTheKeysAndTheirCountIsTheCountedOne() throws {
        let own = try Self.ownKeys()
        #expect(own.isEmpty == false, "the scan found no fileAction key at all")
        #expect(own.count == Self.ownKeyCount)
    }

    @Test func everyKeyTheSurfacesUseIsPresentAndNonEmptyInAllFourCatalogues() throws {
        let used = Set(try Self.allKeysWithDefaults().map(\.key))
        #expect(used.isEmpty == false)
        for locale in Self.locales {
            let entries = try Self.catalog(locale)
            for key in used {
                #expect((entries[key] ?? "").isEmpty == false, "\(locale) has no \(key)")
            }
        }
    }

    /// The inline default is what a missing bundle falls back to, so it must
    /// be the `en` value to the byte. Compared, not asserted twice: the same
    /// key used in two places must carry the same default in both.
    @Test func everyInlineDefaultEqualsTheEnglishCatalogueValue() throws {
        let english = try Self.catalog("en")
        let uses = try Self.allKeysWithDefaults()
        #expect(uses.isEmpty == false)
        for use in uses {
            #expect(use.fallback == english[use.key], "the default of \(use.key) drifted")
        }
    }

    /// No `fileAction.` key sits in a catalogue without being used by some
    /// source file, so a sentence cannot be orphaned by a rename.
    @Test func noFileActionKeyIsOrphaned() throws {
        var source = ""
        let directory = Self.path("Sources/MacSCPAppKit")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(files.isEmpty == false)
        for file in files { source += try SourceCorpus.commentFree(of: file) }
        for locale in Self.locales {
            for key in try Self.catalog(locale).keys where key.hasPrefix("fileAction.") {
                #expect(source.contains("\"\(key)\""), "\(locale) carries \(key), which nothing uses")
            }
        }
    }

    @Test func theFormatSentencesKeepTheirPlaceholdersInEveryLanguage() throws {
        let formats = try Self.allKeysWithDefaults().filter { $0.fallback.contains("%") }
        #expect(formats.isEmpty == false)
        // Counted PER KIND: `%lld` takes an Int and `%@` an object, so a
        // translation that swaps one for the other keeps the total equal and
        // still makes `String(format:)` read an Int as a pointer.
        let integer = try NSRegularExpression(pattern: "%(?:\\d+\\$)?lld")
        let object = try NSRegularExpression(pattern: "%(?:\\d+\\$)?@")
        func count(_ regex: NSRegularExpression, _ text: String) -> Int {
            regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        #expect(formats.contains { count(integer, $0.fallback) > 0 }, "no %lld sentence was scanned")
        #expect(formats.contains { count(object, $0.fallback) > 0 }, "no %@ sentence was scanned")
        for locale in Self.locales {
            let entries = try Self.catalog(locale)
            for use in formats {
                let value = entries[use.key] ?? ""
                #expect(
                    count(integer, value) == count(integer, use.fallback),
                    "\(locale) \(use.key) changed its %lld count")
                #expect(
                    count(object, value) == count(object, use.fallback),
                    "\(locale) \(use.key) changed its %@ count")
            }
        }
    }

    /// The German catalogue addresses the user as du. `GermanAddressFormTests`
    /// holds the whole catalogue off the polite forms; this pins that the
    /// problem sentences, which tell the author what to do, are written as
    /// addressed to a person.
    @Test func theGermanProblemSentencesAddressTheUserAsDu() throws {
        let german = try Self.catalog("de")
        let problems = german.filter { $0.key.hasPrefix("fileAction.problem.") }
        #expect(problems.isEmpty == false)
        for (key, value) in problems {
            #expect(value.contains(" du "), "\(key) does not address the user as du")
        }
    }

    @Test func theFrenchEntriesThisTaskAddedUseTheTypographicApostrophe() throws {
        let french = try Self.catalog("fr")
        for key in try Self.ownKeys() {
            #expect((french[key] ?? "").contains("'") == false, "fr \(key) has a straight apostrophe")
        }
        // The positive beside the negative: sentences without any apostrophe
        // would pass the loop above as "typographic". These two carry one by
        // construction ("d’environnement", "n’y"), and so does at least one
        // key overall.
        #expect((french["fileAction.problem.environmentLocal"] ?? "").contains("\u{2019}"))
        #expect((french["fileAction.problem.noCommand"] ?? "").contains("\u{2019}"))
        let carrying = try Self.ownKeys().filter { (french[$0] ?? "").contains("\u{2019}") }
        #expect(carrying.count > 10, "only \(carrying.count) fr entries carry a typographic apostrophe")
    }
}
