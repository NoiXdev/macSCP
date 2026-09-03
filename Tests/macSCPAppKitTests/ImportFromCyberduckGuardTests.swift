import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The App half of the Cyberduck import, held by a source scan: the menu
/// entry reaches the sheet, the sheet's controls are bound to the view
/// model, the folder is read BEFORE the sheet opens, the sheet asks nobody
/// but the view model, and every string it shows is in all four catalogs.
///
/// No test in this project renders a SwiftUI view, so what a sheet is wired
/// to can only be read off its source. That makes this suite subject to this
/// project's three rules for a scanner, and it is built to them:
///
/// 1. **A negative check needs a positive check beside it.** Every absence
///    asserted below (`.onAppear` in the sheet, `ImportPreviewPlanner` in
///    the sheet, a second `CyberduckSecretReader`) is asserted in the same
///    test as the presence it is about — the load call, the planner call,
///    the one reader. A marker that stops matching then fails loudly instead
///    of reporting an empty filter forever.
///
/// 2. **A guard that spells a symbol it could read is waiting for a
///    rename.** Two kinds of name appear here. Catalog keys are READ — from
///    `ImportPreviewPlanner.FieldKey`, from
///    `CyberduckBookmarkSource.displayNameKey`, and from the `L10n.string`
///    literals in the files themselves — never listed. Swift property names
///    cannot be turned into strings at all, so each marker that spells one
///    is paired with a KEY PATH to the same property in the same test: a
///    rename then fails to COMPILE here, rather than leaving a marker that
///    silently matches nothing.
///
/// 3. **It must not anchor on a comment.** Every file read below carries
///    doc comments naming these very symbols, so all of it goes through
///    `SwiftSource` first — the strict view for structural claims, the
///    literal-keeping view for claims about catalog keys.
///
/// `@MainActor` for one reason only: a key path to a property of a
/// main-actor-isolated type cannot be FORMED anywhere else, and those key
/// paths are what makes rule 2's compile-time half work. Nothing here awaits
/// anything, and nothing here blocks — every test reads files and compares
/// strings.
@MainActor
@Suite("Import from Cyberduck — App wiring")
struct ImportFromCyberduckGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ImportFromCyberduckGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSourceDirectory = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit")

    private static let sheetFile = "ImportFromSourceSheet.swift"
    private static let modelFile = "Presentation/ImportFromSourceViewModel.swift"
    private static let menuFile = "MacSCPApp.swift"
    private static let ownerFile = "ContentView+ExportImport.swift"
    private static let wiringFile = "ContentView+Lifecycle.swift"
    private static let presentationFile = "ContentView+Sheets.swift"
    private static let alertTextFile = "ImportFeedbackText.swift"

    // MARK: - The menu entry reaches the sheet

    /// The whole chain, in one test, because each link is worthless alone:
    /// the command exists on the bridge, the menu calls it, the window
    /// assigns it, the assignment builds a view model, and the window
    /// presents the sheet with it.
    ///
    /// `\TabCommands.importFromCyberduck` is the compile-time half of rule
    /// 2 — renaming the command breaks this line before any marker below
    /// can quietly stop matching.
    @Test func theMenuEntryReachesTheSheet() throws {
        _ = \TabCommands.importFromCyberduck

        let menu = try Self.strictSource(Self.menuFile)
        let wiring = try Self.strictSource(Self.wiringFile)
        let owner = try Self.strictSource(Self.ownerFile)
        let presentation = try Self.strictSource(Self.presentationFile)

        let bridgeDeclaresIt = menu.contains("var importFromCyberduck")
        let menuCallsIt = menu.contains("tabCommands.importFromCyberduck?(")
        let windowAssignsIt = wiring.contains("tabCommands.importFromCyberduck =")
        let ownerBuildsTheModel = owner.contains("ImportFromSourceViewModel(")
        let windowPresentsTheSheet = presentation.contains("ImportFromSourceSheet(")

        #expect(bridgeDeclaresIt)
        #expect(menuCallsIt, """
            The Sessions menu no longer calls the Cyberduck import command — the entry is there \
            and does nothing, which is exactly the state a menu item must never be in.
            """)
        #expect(windowAssignsIt, """
            No window assigns `tabCommands.importFromCyberduck`, so the menu entry's closure is \
            nil and the click vanishes.
            """)
        #expect(ownerBuildsTheModel)
        #expect(windowPresentsTheSheet)
    }

    /// The menu entry is keyed to the key window like every other entry on
    /// that bridge: without the guard, a click while Settings is in front
    /// reaches whichever window happens to answer.
    @Test func theMenuEntryIsGuardedByTheKeyWindow() throws {
        let assignment = try #require(
            Self.declarationBody(after: "tabCommands.importFromCyberduck =",
                                 in: try Self.strictSource(Self.wiringFile)))
        #expect(assignment.contains("isKeyWindow"), "\(assignment)")
    }

    // MARK: - The sheet's controls

    /// Both switches and the group picker write THROUGH the view model.
    /// A control bound to a `@State` of the sheet's own would be a second
    /// copy of the decision, and `payload()` would not see it.
    ///
    /// The three key paths are rule 2's compile-time half again.
    @Test func bothSwitchesAndTheGroupPickerAreBoundToTheViewModel() throws {
        _ = \ImportFromSourceViewModel.takeSecrets
        _ = \ImportFromSourceViewModel.takesGroupAndLabels
        _ = \ImportFromSourceViewModel.groupChoice

        let sheet = try Self.strictSource(Self.sheetFile)
        let secretsBound = sheet.contains("$model.takeSecrets")
        let labelsBound = sheet.contains("$model.takesGroupAndLabels")
        let groupBound = sheet.contains("$model.groupChoice")

        #expect(secretsBound, "the keychain switch is not bound to the view model")
        #expect(labelsBound, "the group/labels switch is not bound to the view model")
        #expect(groupBound, "the group picker is not bound to the view model")
    }

    /// The sheet renders what the view model already decided; it never asks
    /// the planner itself. Negative, with its positive anchor in the same
    /// test: the view model DOES call the planner, twice — once to preview
    /// and once to build the payload.
    @Test func theSheetAsksTheViewModelAndTheViewModelAsksThePlanner() throws {
        let sheet = try Self.strictSource(Self.sheetFile)
        let model = try Self.strictSource(Self.modelFile)

        let modelPreviews = model.contains("ImportPreviewPlanner.preview(")
        let modelBuildsThePayload = model.contains("ImportPreviewPlanner.payload(")
        let sheetPlans = sheet.contains("ImportPreviewPlanner.")
        let sheetReadsTheRows = sheet.contains("model.rows")

        #expect(modelPreviews)
        #expect(modelBuildsThePayload)
        #expect(sheetReadsTheRows)
        #expect(sheetPlans == false, """
            The sheet plans for itself. Two answers to "what would this import" is one more than \
            there can be, and the sheet's is the one nothing holds against the store.
            """)
    }

    /// Task 3's concern 3: `SessionImportPlanner` drops a `groupID` the
    /// payload does not also carry as a group, so the store's group
    /// catalogue must reach `payload(for:sessions:groups:switches:)`. A call
    /// without it does not compile today; one that regains a default would.
    @Test func theGroupCatalogueReachesThePayload() throws {
        let call = try #require(
            Self.call(to: "ImportPreviewPlanner.payload(",
                      in: try Self.strictSource(Self.modelFile)))
        #expect(call.contains("groups:"), "\(call)")
        #expect(call.contains("switches:"), "\(call)")
    }

    // MARK: - The folder is read before the sheet opens

    /// Design §4: the sheet opens on a folder that has already been read,
    /// so a folder picker can come first when Cyberduck's own folder is not
    /// there. A read triggered by the sheet appearing would run again on
    /// every re-render SwiftUI decides to make, and would have nowhere to
    /// put a failure but the sheet it is inside.
    ///
    /// Negative and positive in one test, per rule 1.
    @Test func theFolderIsReadBeforeTheSheetOpensAndNeverFromIt() throws {
        _ = \ImportFromSourceViewModel.rows

        let sheet = try Self.strictSource(Self.sheetFile)
        let owner = try Self.strictSource(Self.ownerFile)

        let ownerLoads = owner.contains(".load(source:")
        let sheetLoads = sheet.contains(".load(source:")
        let sheetReadsTheSource = sheet.contains("BookmarkSource")
        let sheetRunsOnAppear = sheet.contains(".onAppear") || sheet.contains(".task")

        #expect(ownerLoads, """
            Nothing reads the bookmark folder before the sheet is presented — re-anchor this \
            guard, or the sheet is opening on a model that was never loaded.
            """)
        #expect(sheetLoads == false, "the sheet loads the folder itself")
        #expect(sheetReadsTheSource == false, "the sheet knows about bookmark sources")
        #expect(sheetRunsOnAppear == false, """
            The sheet does work when it appears. SwiftUI decides how often that happens; reading \
            a folder is not something to do that many times.
            """)
    }

    // MARK: - Secrets

    /// The keychain is asked only when the user ticked the switch, by the
    /// one reader Core provides, from the one place that applies an import.
    /// Negative (no other App file constructs a reader) with its positive
    /// anchor (this one does) in the same test.
    @Test func theKeychainIsAskedOnlyBehindTheSwitchAndOnlyByTheApplier() throws {
        _ = \ImportFromSourceViewModel.takeSecrets

        let filesConstructingAReader = try Self.appFiles().filter { url in
            try Self.strict(String(contentsOf: url, encoding: .utf8))
                .contains("CyberduckSecretReader(")
        }.map(\.lastPathComponent)

        #expect(filesConstructingAReader == [Self.ownerFile], "\(filesConstructingAReader)")

        let owner = try Self.strictSource(Self.ownerFile)
        let readsBehindTheSwitch = owner.contains("switches.takeSecrets")
        #expect(readsBehindTheSwitch, """
            The applier reads Cyberduck's keychain items without consulting the switch — the \
            macOS consent prompt would then appear for an import nobody asked to carry secrets.
            """)
    }

    // MARK: - Catalogs

    /// Every key this feature shows, in all four catalogs — DERIVED, never
    /// listed: the `L10n.string` literals in the three files that produce
    /// its text, the nine field names read off `ImportPreviewPlanner.
    /// FieldKey`, the source's own display-name key read off
    /// `CyberduckBookmarkSource`, and the menu entry's key read out of the
    /// menu file.
    @Test func everyStringThisFeatureShowsIsInAllFourCatalogs() throws {
        var keys = Set<String>()
        for file in [Self.sheetFile, Self.modelFile, Self.alertTextFile] {
            keys.formUnion(Self.localizationKeys(in: try Self.literalSource(file)))
        }
        keys.formUnion(Self.fieldKeys)
        keys.insert(CyberduckBookmarkSource.displayNameKey)
        let menuKeys = try Self.menuKeys()
        #expect(!menuKeys.isEmpty, "the menu file names no Cyberduck import key")
        keys.formUnion(menuKeys)

        #expect(keys.count > Self.fieldKeys.count, "no sheet keys found — re-anchor this guard")

        let catalogs = try FileManager.default.contentsOfDirectory(
            atPath: Self.appSourceDirectory.appendingPathComponent("Resources")
                .path(percentEncoded: false)
        ).filter { $0.hasSuffix(".lproj") }.sorted()
        #expect(catalogs.count == 4, "\(catalogs)")

        for catalog in catalogs {
            let table = try String(
                contentsOf: Self.appSourceDirectory
                    .appendingPathComponent("Resources/\(catalog)/Localizable.strings"),
                encoding: .utf8)
            for key in keys.sorted() {
                #expect(table.contains("\"\(key)\" = "), "\(catalog) is missing \(key)")
            }
        }
    }

    /// The nine change-list keys, read off the type that composes them. A
    /// tenth added in Core without a catalog entry fails the test above
    /// without anyone having to remember this list, because there is no
    /// list.
    private static let fieldKeys: Set<String> = [
        ImportPreviewPlanner.FieldKey.host,
        ImportPreviewPlanner.FieldKey.port,
        ImportPreviewPlanner.FieldKey.username,
        ImportPreviewPlanner.FieldKey.keyPath,
        ImportPreviewPlanner.FieldKey.authKind,
        ImportPreviewPlanner.FieldKey.endpoint,
        ImportPreviewPlanner.FieldKey.bucket,
        ImportPreviewPlanner.FieldKey.name,
        ImportPreviewPlanner.FieldKey.labels,
    ]

    /// The menu entry's own key, taken out of the menu file rather than
    /// spelled here: the button that calls `importFromCyberduck` is the one
    /// whose title this is.
    private static func menuKeys() throws -> Set<String> {
        Set(localizationKeys(in: try literalSource(menuFile))
            .filter { $0.contains("importFromCyberduck") })
    }

    // MARK: - The scanner reacts

    /// Rule 3, as a fixture: a doc comment quoting the binding must not
    /// satisfy the binding check. Every file above carries comments naming
    /// these symbols.
    @Test func theScanIgnoresABindingThatOnlyAppearsInAComment() throws {
        let source = """
            struct Fake: View {
                /// The switch is bound to `$model.takeSecrets`.
                var body: some View {
                    // Toggle(isOn: $model.takeSecrets) { Text("") }
                    Text("")
                }
            }
            """
        #expect(try Self.strict(source).contains("$model.takeSecrets") == false)
    }

    /// And the other half: a binding in real code survives a literal that
    /// looks like a comment.
    @Test func theScanKeepsABindingAfterAStringThatLooksLikeAComment() throws {
        let source = """
            struct Fake: View {
                let help = "https://example.invalid/import"
                var body: some View {
                    Toggle(isOn: $model.takeSecrets) { Text("") }
                }
            }
            """
        #expect(try Self.strict(source).contains("$model.takeSecrets"))
    }

    /// The catalog scan reads keys, not default values — a default
    /// containing a dot must not be mistaken for one.
    @Test func theCatalogScanReadsKeysAndNotDefaults() {
        let source = """
            struct Fake {
                var a: String { L10n.string("import.cyberduck.title", "Import from Cyberduck") }
                var b: String { L10n.string("import.cyberduck.action", "Import") }
            }
            """
        #expect(Self.localizationKeys(in: source) == ["import.cyberduck.title",
                                                      "import.cyberduck.action"])
    }

    /// The call reader takes the whole call, however many lines it spans —
    /// `payload(for:sessions:groups:switches:)` is written over four of
    /// them, and `groups:` is not on the marker's line.
    @Test func theCallReaderTakesACallThatSpansLines() {
        let source = """
            struct Fake {
                func payload() -> Int {
                    ImportPreviewPlanner.payload(
                        for: rows,
                        sessions: sessions,
                        groups: groups,
                        switches: switches)
                }
            }
            """
        let call = Self.call(to: "ImportPreviewPlanner.payload(", in: source)
        #expect(call?.contains("groups:") == true)
        #expect(call?.hasSuffix("switches: switches)") == true)
    }

    // MARK: - Reading the tree

    /// Every Swift file under the App target, subdirectories included —
    /// `Presentation/` holds the view model, and a scan that stopped at the
    /// top level would report an empty filter over half the target.
    private static func appFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: appSourceDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func strict(_ source: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(source)
    }

    private static func strictSource(_ relativePath: String) throws -> String {
        try strict(String(
            contentsOf: appSourceDirectory.appendingPathComponent(relativePath), encoding: .utf8))
    }

    private static func literalSource(_ relativePath: String) throws -> String {
        try SwiftSource.blankingComments(String(
            contentsOf: appSourceDirectory.appendingPathComponent(relativePath), encoding: .utf8))
    }

    /// Every `L10n.string("<key>"` in source order, duplicates kept out by
    /// the caller's `Set`. Reads the KEY only — the default value that
    /// follows is text, and a dot in it is not a key.
    private static func localizationKeys(in source: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(source)
        let marker = "L10n.string(\""
        while let start = rest.range(of: marker) {
            let afterQuote = start.upperBound
            guard let end = rest[afterQuote...].firstIndex(of: "\"") else { break }
            keys.append(String(rest[afterQuote..<end]))
            rest = rest[end...]
        }
        return keys
    }

    /// The whole call that starts at `marker`, read forward until the
    /// parenthesis the marker opened balances again. Line-based reading is
    /// what rule 2 of this project's guard rules warns about: the argument
    /// worth checking is rarely on the marker's line.
    private static func call(to marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            switch source[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The braced body that follows `marker` — used for the key-window
    /// check, where the guard sits inside a closure the marker only opens.
    private static func declarationBody(after marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker),
              let open = source[start.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 1
        var index = source.index(after: open)
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
