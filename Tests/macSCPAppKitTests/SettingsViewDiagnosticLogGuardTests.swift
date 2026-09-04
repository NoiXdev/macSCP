import Foundation
import Testing

/// Guards the Settings → General "Diagnostic log" row (Diagnostic Log plan,
/// Task 2): the picker must be bound to `SettingsStore.diagnosticLogLevel`
/// and labelled through the `settings.general.diagnosticLog` catalogue key,
/// the "Show in Finder" button must call the row's own reveal function and
/// be labelled through `settings.general.diagnosticLog.reveal`, no `Text(`
/// in the section may take a hardcoded literal, and the four catalogues
/// must agree on every `settings.general.diagnosticLog` key. A second guard
/// in this file pins the launch wiring: `MacSCPApp.swift` — and only
/// `MacSCPApp.swift` — configures `DiagnosticLog.shared` and logs a line
/// naming `launch`. A third, added in Task 2 round 1, pins the termination
/// wiring: `AppDelegate.applicationWillTerminate` must call
/// `flushSynchronously(`, and `MacSCPApp.swift` must no longer register the
/// `NotificationCenter`-based `willTerminateNotification` observer that
/// round replaces (it could not guarantee the "app quit" line, or the rest
/// of the buffer, reached disk before the process exited).
///
/// Same shared scanner as `SettingsViewAppearanceToggleGuardTests` /
/// `SettingsSectionCatalogGuardTests`
/// (`TransferQueueBarCancelGuardTests.declarationBodyRange(of:in:)` /
/// `.declarationBody(of:in:)`, `SwiftSource.blankingComments`/
/// `.blankingCommentsAndStrings`), reused rather than copied. The
/// no-hardcoded-`Text(` check is the same shape as
/// `WhatsNewWiringGuardTests.noTextCallInTheSettingsPaneTakesAHardcodedLiteral`
/// — reused as a pattern (that helper is `private` to its own suite, so the
/// regex is rewritten here rather than shared code).
///
/// Every scan here reads STRIPPED source. Structural claims (the binding,
/// the function call) are made against the view with comments AND string
/// literals blanked; the catalogue-key/literal claims are about a literal,
/// so they read the view that blanks comments only.
///
/// Known blind spots: SOURCE TEXT only, never a rendered view — nothing
/// here confirms the picker or button actually appear on screen, that the
/// picker actually flips the stored value (`SettingsStoreTests` pins the
/// property's own round trip), or that `NSWorkspace.shared
/// .activateFileViewerSelecting` actually opens Finder.
@Suite("Settings — Diagnostic log row and launch wiring")
struct SettingsViewDiagnosticLogGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appKitDir = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    private static let settingsViewFile = appKitDir.appendingPathComponent("SettingsView.swift")
    private static let macSCPAppFile = appKitDir.appendingPathComponent("MacSCPApp.swift")

    private static let catalogLocales = ["en", "de", "fr", "pl"]

    private static func catalogPath(_ locale: String) -> String {
        "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
    }

    /// No trailing `{`, matching `SettingsViewAppearanceToggleGuardTests`'s
    /// convention: `declarationBodyRange` opens its span at the first `{`
    /// found after this text. `diagnosticLogSection` (not the whole
    /// `GeneralSettingsSection` struct) is the scan target on purpose: that
    /// struct's language picker legitimately hardcodes `Text("English")`/
    /// `"Deutsch"`/`"Français"`/`"Polski"` (proper nouns, never routed
    /// through `L10n.string(`), so a whole-struct scan for the
    /// no-hardcoded-`Text(` check below would flag those every time — see
    /// `diagnosticLogSection`'s own doc comment in `SettingsView.swift`.
    private static let sectionDeclaration = "private var diagnosticLogSection: some View"

    private static let pickerKey = "\"settings.general.diagnosticLog\""
    private static let revealKey = "\"settings.general.diagnosticLog.reveal\""

    // MARK: - Source access

    private static func views(of file: URL) throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: file, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    private static func sectionBodies() throws -> (code: String, withLiterals: String) {
        let all = try views(of: Self.settingsViewFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.sectionDeclaration, in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    // MARK: - The picker

    @Test func thePickerIsBoundToTheStoresPropertyAndLabelledThroughTheCatalogueKey() throws {
        let bodies = try Self.sectionBodies()
        #expect(bodies.code.contains("Picker("), """
            GeneralSettingsSection no longer contains a Picker( that could \
            be the diagnostic-log level control.
            """)
        #expect(bodies.code.contains("store.diagnosticLogLevel"), """
            The section must read/write store.diagnosticLogLevel -- a \
            picker bound to a different or local property would silently \
            stop reflecting or controlling the setting DiagnosticLog reads \
            at launch.
            """)
        #expect(bodies.withLiterals.contains(Self.pickerKey), """
            The picker must take its label from the \
            settings.general.diagnosticLog catalogue key, not a hardcoded \
            string a translation cannot reach.
            """)
    }

    // MARK: - The reveal button

    @Test func theRevealButtonCallsItsOwnFunctionAndIsLabelledThroughTheCatalogueKey() throws {
        let bodies = try Self.sectionBodies()
        #expect(bodies.code.contains("revealDiagnosticLogFolder()"), """
            GeneralSettingsSection no longer calls revealDiagnosticLogFolder() \
            -- the "Show in Finder" button is gone or wired to something else.
            """)
        #expect(bodies.withLiterals.contains(Self.revealKey), """
            The reveal button must take its label from the \
            settings.general.diagnosticLog.reveal catalogue key, not a \
            hardcoded string a translation cannot reach.
            """)
    }

    /// Positive anchor for both checks above: the strict view must actually
    /// be reaching the section's own declaration, or an unreadable/empty
    /// read would make the `contains` checks above pass trivially over
    /// nothing.
    @Test func theStrictViewStillContainsTheGeneralSection() throws {
        let code = try Self.views(of: Self.settingsViewFile).code
        #expect(code.contains(Self.sectionDeclaration), """
            the strict view of SettingsView.swift no longer contains \
            GeneralSettingsSection's own declaration -- the stripper or the \
            path is wrong, and the checks above are reading something other \
            than the section it names.
            """)
    }

    // MARK: - No hardcoded Text(

    /// `Text(` immediately followed (ignoring whitespace, and an optional
    /// `verbatim:` label) by a `"` -- a literal passed straight in, either
    /// as `Text("…")` or as `Text(verbatim: "…")`. `Text(L10n.string(...))`,
    /// `Text(currentVersionText)` and `Text(diagnosticLogDirectory.path(...))`
    /// all have a non-`"` character right after the `(` (or after
    /// `verbatim:`), so none of them count. Same pattern as
    /// `WhatsNewWiringGuardTests.hardcodedTextCallCount` (rewritten here
    /// rather than shared, since that one is private to its own suite).
    private static let textLiteralRegex = try! NSRegularExpression(
        pattern: #"Text\(\s*(?:verbatim:\s*)?""#)

    private static func hardcodedTextCallCount(in source: String) -> Int {
        Self.textLiteralRegex.matches(in: source, range: NSRange(source.startIndex..., in: source)).count
    }

    /// Positive anchor for the negative below (CLAUDE.md, "a negative check
    /// needs a positive beside it"): the section really does call
    /// `L10n.string(` -- the new row alone calls it six times (the picker
    /// label plus four level labels plus the reveal button, before even
    /// counting the pre-existing rows) -- so a rewrite that dropped every
    /// localized lookup could not make the negative pass by having nothing
    /// left to scan.
    @Test func theSectionCallsL10nStringAtLeastOnce() throws {
        let code = try Self.sectionBodies().code
        #expect(code.contains("L10n.string("), """
            GeneralSettingsSection no longer calls L10n.string( anywhere in \
            its declaration -- the no-hardcoded-Text check below would then \
            hold vacuously.
            """)
    }

    @Test func noTextCallInTheGeneralSectionTakesAHardcodedLiteral() throws {
        let withLiterals = try Self.sectionBodies().withLiterals
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 0, """
            GeneralSettingsSection has a Text( call whose first argument is \
            a string literal instead of going through L10n.
            """)
    }

    // MARK: - The catalogue

    private static func catalogKeys(_ locale: String) throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(Self.catalogPath(locale)))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let entries = parsed as? [String: String] else {
            throw CatalogError.unreadable(Self.catalogPath(locale))
        }
        return Set(entries.keys)
    }

    enum CatalogError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let path): return "\(path) does not parse as a strings table"
            }
        }
    }

    /// Every `settings.general.diagnosticLog` key -- the picker label, the
    /// four level labels, the reveal button and the footer hint -- must
    /// exist in all four catalogues. English is the reference the other
    /// three are diffed against, the same shape
    /// `SettingsSectionCatalogGuardTests.theSettingsTabKeysAgreeAcrossAllFourCatalogues`
    /// uses.
    @Test func theDiagnosticLogKeysAgreeAcrossAllFourCatalogues() throws {
        let english = try Self.catalogKeys("en").filter { $0.hasPrefix("settings.general.diagnosticLog") }
        #expect(english.contains("settings.general.diagnosticLog"), """
            en.lproj carries no settings.general.diagnosticLog key yet.
            """)
        #expect(english.count == 7, """
            en.lproj carries \(english.count) settings.general.diagnosticLog* \
            key(s), expected 7: the picker label, the four level labels, \
            the reveal button and the footer hint. \
            keys: \(english.sorted())
            """)
        for locale in Self.catalogLocales where locale != "en" {
            let keys = try Self.catalogKeys(locale).filter { $0.hasPrefix("settings.general.diagnosticLog") }
            #expect(keys == english, """
                \(Self.catalogPath(locale))'s settings.general.diagnosticLog* \
                keys differ from en.lproj's.
                missing here: \(english.subtracting(keys).sorted())
                extra here: \(keys.subtracting(english).sorted())
                """)
        }
    }

    // MARK: - Launch wiring

    /// `MacSCPApp.swift` must configure the sink and write a line naming
    /// `launch` -- the two facts the design's "The setting (App)" section
    /// requires ("`MacSCPApp` configures the sink at launch from the store
    /// … The first line after `configure` is `[info] app launch
    /// version=<v> build=<b>`").
    @Test func macSCPAppConfiguresTheSinkAndLogsALaunchLine() throws {
        let all = try Self.views(of: Self.macSCPAppFile)
        #expect(all.code.contains("DiagnosticLog.shared.configure("), """
            MacSCPApp.swift no longer calls DiagnosticLog.shared.configure( \
            -- the sink is never configured at launch.
            """)
        #expect(all.withLiterals.contains("launch version="), """
            MacSCPApp.swift no longer writes a line naming "launch version=" \
            -- a log file could no longer be told it starts at app launch, \
            with the build that wrote it.
            """)
    }

    /// `MacSCPApp.swift` is the ONLY file under `Sources/MacSCPAppKit` that
    /// configures the sink -- a second call site (e.g. one accidentally
    /// added to `ContentView.swift`) would race `MacSCPApp`'s own call and
    /// make the effective level depend on evaluation order rather than on
    /// `SettingsStore.diagnosticLogLevel` alone. Positive anchor for this
    /// negative sits in the test above (`MacSCPApp.swift` really does call
    /// it), so this cannot pass by finding nothing anywhere.
    @Test func noOtherFileUnderMacSCPAppKitConfiguresTheSink() throws {
        let offenders = try Self.filesCalling(
            "DiagnosticLog.shared.configure(", in: Self.appKitDir, excluding: "MacSCPApp.swift")
        #expect(offenders.isEmpty, """
            file(s) other than MacSCPApp.swift call DiagnosticLog.shared \
            .configure(: \(offenders.sorted()). The sink must be \
            configured from exactly one place.
            """)
    }

    /// `AppDelegate.applicationWillTerminate` -- installed as `NSApp
    /// .delegate` through `@NSApplicationDelegateAdaptor` (Diagnostic Log
    /// plan, Task 2 round 1) -- must call `flushSynchronously(` on the
    /// terminating thread, not `flush()` awaited from a `Task`: the finding
    /// this round fixes is that a `NotificationCenter` callback which starts
    /// a `Task` and returns has no guarantee the process outlives that
    /// `Task` ever being scheduled.
    @Test func appDelegateApplicationWillTerminateCallsFlushSynchronously() throws {
        let all = try Self.views(of: Self.macSCPAppFile)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "func applicationWillTerminate(_ notification: Notification)", in: all.code)
        let body = TransferQueueBarCancelGuardTests.slice(range, of: all.code)
        #expect(body.contains("DiagnosticLog.shared.log("), """
            AppDelegate.applicationWillTerminate no longer logs anything -- \
            a log file could no longer be told the app quit.
            """)
        #expect(body.contains("flushSynchronously("), """
            AppDelegate.applicationWillTerminate no longer calls \
            flushSynchronously( -- the buffered lines (and the "app quit" \
            line above) are no longer guaranteed to reach disk before the \
            process exits.
            """)
    }

    /// The negative beside the positive above: `MacSCPApp.swift` must no
    /// longer register a `willTerminateNotification` observer -- the
    /// mechanism this round replaces with `AppDelegate
    /// .applicationWillTerminate` precisely because it could not guarantee
    /// delivery. A file that kept BOTH would flush twice (harmless) but
    /// would also mean the old, non-guaranteeing path was never actually
    /// removed, leaving the finding this round exists to close half-fixed.
    @Test func macSCPAppNoLongerRegistersAWillTerminateNotificationObserver() throws {
        let code = try Self.views(of: Self.macSCPAppFile).code
        #expect(!code.contains("willTerminateNotification"), """
            MacSCPApp.swift still contains willTerminateNotification -- the \
            NotificationCenter-based observer this round replaces with \
            AppDelegate.applicationWillTerminate was not actually removed.
            """)
    }

    /// Scans every `.swift` file directly under `directory` (non-recursive
    /// is not enough here -- `Sources/MacSCPAppKit` has no subdirectories
    /// today, but a recursive walk costs nothing and does not go stale if
    /// one is added) for `needle` in its STRIPPED (comments and string
    /// literals blanked) source, skipping `excludedFileName`. Returns the
    /// file names (not full paths) that contain it.
    private static func filesCalling(
        _ needle: String, in directory: URL, excluding excludedFileName: String
    ) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)
        else {
            throw ScanError.directoryNotEnumerable(directory.path)
        }
        var offenders: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift", url.lastPathComponent != excludedFileName else { continue }
            let raw = try String(contentsOf: url, encoding: .utf8)
            let code = try SwiftSource.blankingCommentsAndStrings(raw)
            if code.contains(needle) {
                offenders.append(url.lastPathComponent)
            }
        }
        return offenders
    }

    enum ScanError: Error, CustomStringConvertible {
        case directoryNotEnumerable(String)
        var description: String {
            switch self {
            case .directoryNotEnumerable(let path): return "\(path) could not be enumerated"
            }
        }
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func theSelfTestNeedlesAreThingsTheRealFileActuallyContains() throws {
        let all = try Self.views(of: Self.settingsViewFile)
        #expect(all.code.contains("store.diagnosticLogLevel"), """
            the binding needle names an expression SettingsView.swift does \
            not contain
            """)
        #expect(all.withLiterals.contains(Self.pickerKey), """
            the picker catalogue-key needle names a literal \
            SettingsView.swift does not contain
            """)
        #expect(all.withLiterals.contains(Self.revealKey), """
            the reveal catalogue-key needle names a literal \
            SettingsView.swift does not contain
            """)
    }

    @Test func scannerSeesAPickerBoundToADifferentProperty() throws {
        let source = """
            \(Self.sectionDeclaration) {
                Section {
                    Picker(
                        L10n.string("settings.general.diagnosticLog", "Diagnostic log"),
                        selection: Binding(
                            get: { store.checksumAlgorithm },
                            set: { store.checksumAlgorithm = $0 }
                        )) {}
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.sectionDeclaration, in: code)
        // Positive first: a picker really is there, so the negative below
        // reports the wrong binding rather than an empty read.
        #expect(body.contains("Picker("))
        #expect(!body.contains("store.diagnosticLogLevel"), """
            the scanner must report a picker bound to a different property \
            as not wiring diagnosticLogLevel, not wave it through because a \
            Picker with the right label is present
            """)
    }

    @Test func scannerSeesAHardcodedPickerLabelInsteadOfTheCatalogueKey() throws {
        let source = """
            \(Self.sectionDeclaration) {
                Section {
                    Picker(
                        "Diagnostic log",
                        selection: Binding(
                            get: { store.diagnosticLogLevel },
                            set: { store.diagnosticLogLevel = $0 }
                        )) {}
                }
            }
            """
        let all = (code: try SwiftSource.blankingCommentsAndStrings(source),
                   withLiterals: try SwiftSource.blankingComments(source))
        let body = (
            code: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: all.code),
            withLiterals: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: all.withLiterals))
        // Positive first: the binding IS correct, so the negative below
        // reports the missing catalogue key rather than an empty read.
        #expect(body.code.contains("store.diagnosticLogLevel"))
        #expect(!body.withLiterals.contains(Self.pickerKey), """
            the scanner must report a hardcoded label as missing the \
            catalogue key, not accept it because the binding underneath is \
            correct
            """)
    }

    @Test func scannerCatchesAHardcodedTextLiteral() throws {
        let source = """
            \(Self.sectionDeclaration) {
                var body: some View {
                    Text("Diagnostic log")
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 1, """
            the scanner failed to catch a Text( call given a literal string \
            directly
            """)
    }

    @Test func scannerAcceptsTextWrappingL10nOrAHelper() throws {
        let source = """
            \(Self.sectionDeclaration) {
                var body: some View {
                    Text(L10n.string("settings.general.diagnosticLog", "Diagnostic log"))
                    Text(diagnosticLogDirectory.path(percentEncoded: false))
                }
            }
            """
        let withLiterals = try SwiftSource.blankingComments(source)
        #expect(Self.hardcodedTextCallCount(in: withLiterals) == 0, """
            the scanner must not flag Text( calls wrapping L10n.string( or a \
            computed helper as hardcoded literals
            """)
    }

    @Test func scannerFailsClosedWhenTheSectionIsGone() {
        let source = "struct SomethingElse: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sectionDeclaration, in: source)
        }
    }

    /// A synthetic `applicationWillTerminate` that only logs and awaits
    /// `flush()` -- the exact shape this round replaces -- must be caught by
    /// the positive check above, not waved through because SOME call inside
    /// it mentions `DiagnosticLog.shared`.
    @Test func scannerCatchesApplicationWillTerminateThatAwaitsFlushInsteadOfFlushingSynchronously() throws {
        let source = """
            final class AppDelegate: NSObject, NSApplicationDelegate {
                func applicationWillTerminate(_ notification: Notification) {
                    DiagnosticLog.shared.log(.info, "app", "quit")
                    Task { await DiagnosticLog.shared.flush() }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func applicationWillTerminate(_ notification: Notification)", in: code)
        // Positive first: the body really does mention DiagnosticLog.shared,
        // so the negative below reports the missing flushSynchronously(
        // call rather than an empty read.
        #expect(body.contains("DiagnosticLog.shared"))
        #expect(!body.contains("flushSynchronously("), """
            the scanner must report this pre-round-1 shape as NOT calling \
            flushSynchronously( -- it doesn't
            """)
    }

    /// The negative-check helper itself: a source that still contains
    /// `willTerminateNotification` must be caught, proving the check above
    /// is not vacuously true because nothing in the synthetic source could
    /// ever match it.
    @Test func scannerCatchesAWillTerminateNotificationObserverIfOneReappears() throws {
        let source = """
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        #expect(code.contains("willTerminateNotification"), """
            the scanner failed to catch a reintroduced \
            willTerminateNotification observer
            """)
    }

    /// The negative-file-scan helper itself, exercised against a temp
    /// directory rather than the real tree -- proves the enumerator would
    /// actually catch a second `configure(` call site, not just that none
    /// happens to exist in `Sources/MacSCPAppKit` today.
    @Test func filesCallingFindsAPlantedViolationAndSkipsTheExcludedFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-diagnosticlog-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "// no call here\nstruct A {}".write(
            to: dir.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)
        try "struct B { func f() { DiagnosticLog.shared.configure(level: .off) } }".write(
            to: dir.appendingPathComponent("Offender.swift"), atomically: true, encoding: .utf8)
        try "struct C { func f() { DiagnosticLog.shared.configure(level: .off) } }".write(
            to: dir.appendingPathComponent("MacSCPApp.swift"), atomically: true, encoding: .utf8)

        let offenders = try Self.filesCalling(
            "DiagnosticLog.shared.configure(", in: dir, excluding: "MacSCPApp.swift")
        #expect(offenders == ["Offender.swift"], """
            expected the scanner to report exactly Offender.swift, got \
            \(offenders.sorted())
            """)
    }
}
