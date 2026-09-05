import Foundation
import Testing
@testable import MacSCPAppKit

/// The wiring around window restoration (Detachable Tabs plan, Task 5):
/// what the launch path may contain, what the closing path must do, and
/// what may ever reach `windows.json`.
///
/// Everything here is a SOURCE scan — it proves what is written, never
/// what a running app does. That is the standing blind spot of every
/// wiring guard in this target, and the maintainer's sight check is the
/// first real evidence for the scene behaviour.
///
/// Two of the checks below are negative ("the launch path calls no
/// `connect(`"), and CLAUDE.md's rule for those applies twice over: each
/// carries a positive beside it that pins the body it scans is really
/// there, and a second positive that pins the forbidden identifiers exist
/// in this project at all — a `connect(` scan that has quietly stopped
/// matching anything anywhere would otherwise read exactly like a launch
/// that does not connect.
@Suite("Window restoration — launch, close and secrecy wiring")
struct WindowRestorationWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceDir = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    private static let appFile = sourceDir.appendingPathComponent("MacSCPApp.swift")
    private static let lifecycleFile = sourceDir
        .appendingPathComponent("ContentView+Lifecycle.swift")
    private static let contentViewFile = sourceDir.appendingPathComponent("ContentView.swift")
    private static let seedFile = sourceDir.appendingPathComponent("WindowSeed.swift")

    private static func code(of url: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: url, encoding: .utf8))
    }

    private static func body(_ declaration: String, in url: URL) throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(
            of: declaration, in: try code(of: url))
    }

    /// The three ways this app starts a connection or runs something on
    /// one. Spelled once, scanned in every launch body below.
    private static let connectingCalls = ["connect(", "connectFromSidebar(", "runSnippet("]

    /// Every declaration the launch path is made of: the once-per-process
    /// decision, the code that opens the restored windows, and the code
    /// that builds a restored tab.
    private static let launchBodies: [(name: String, declaration: String, file: URL)] = [
        ("MacSCPApp.init", "init()", appFile),
        ("openRestoredWindows()", "func openRestoredWindows()", lifecycleFile),
        ("restoreDescribedWindow()", "func restoreDescribedWindow()", lifecycleFile),
        ("makeRestoredTab(from:)", "func makeRestoredTab(from described: TabSeed)", lifecycleFile),
    ]

    // MARK: - No automatic login at launch

    /// The plan's global constraint, as a check: restoring a window puts
    /// tabs on screen and touches no network and no secret. The first
    /// connect is the user's click.
    @Test func theLaunchPathStartsNoConnection() throws {
        for entry in Self.launchBodies {
            let body = try Self.body(entry.declaration, in: entry.file)
            for call in Self.connectingCalls {
                #expect(!body.contains(call), """
                    \(entry.name) contains \(call) — restoration must bring \
                    windows and tabs back DISCONNECTED. Nothing on the \
                    launch path may dial a host or run a snippet; the first \
                    connect is the user's click.
                    """)
            }
        }
    }

    /// Positive beside the scan above, part one: each body it names is
    /// really found and really has content. Without this the negative
    /// would be satisfied by four empty strings.
    @Test func everyLaunchBodyTheScanNamesIsThere() throws {
        for entry in Self.launchBodies {
            let body = try Self.body(entry.declaration, in: entry.file)
            #expect(!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, """
                \(entry.name) resolved to an empty body — the declaration \
                text moved, and theLaunchPathStartsNoConnection is reading \
                nothing rather than the launch path
                """)
        }
    }

    /// Positive beside the scan above, part two: the identifiers it
    /// forbids are identifiers this project actually uses. A rename would
    /// otherwise leave the negative matching nothing anywhere, which is
    /// the silent-staleness shape CLAUDE.md names.
    @Test func theForbiddenCallsAreCallsThisProjectMakesElsewhere() throws {
        let contentView = try Self.code(of: Self.contentViewFile)
        for call in Self.connectingCalls {
            #expect(contentView.contains(call), """
                ContentView.swift no longer contains \(call) — the launch \
                scan is forbidding an identifier that has been renamed, and \
                is therefore forbidding nothing
                """)
        }
    }

    // MARK: - The launch really does read the seeds

    @Test func theLaunchReadsTheSeedFileAndConsumesIt() throws {
        let body = try Self.body("init()", in: Self.appFile)
        #expect(body.contains("WindowRestorationStore("), """
            MacSCPApp.init no longer builds a WindowRestorationStore — there \
            is nothing for the launch to restore from.
            """)
        #expect(body.contains("readAndClear("), """
            MacSCPApp.init no longer calls readAndClear( — a seed file must \
            be consumed by the launch that reads it, or every later launch \
            reopens the same windows.
            """)
        #expect(body.contains("WindowRestorationLaunch("), """
            MacSCPApp.init no longer builds the WindowRestorationLaunch the \
            windows read their descriptions from.
            """)
    }

    @Test func thePrimaryWindowIsWhatOpensTheOtherRestoredOnes() throws {
        let body = try Self.body("func openRestoredWindows()", in: Self.lifecycleFile)
        #expect(body.contains("takeSeedsToOpen()"), """
            openRestoredWindows() no longer asks the launch which windows to \
            open — openWindow(value:) cannot be called from MacSCPApp.init, \
            and this is the earliest place it can.
            """)
        #expect(body.contains("openWindow(value:"), """
            openRestoredWindows() no longer calls openWindow(value:) — the \
            restored windows other than the primary one would never appear.
            """)
    }

    @Test func aRestoredTabIsBuiltWithItsSessionShownAndNothingDialed() throws {
        let body = try Self.body(
            "func makeRestoredTab(from described: TabSeed)", in: Self.lifecycleFile)
        #expect(body.contains("beginEditing("), """
            makeRestoredTab(from:) no longer prefills the tab's form from the \
            stored session — a restored tab must come back showing the \
            session it had, one click from connecting.
            """)
        #expect(body.contains("restoredPaneVisibility"), """
            makeRestoredTab(from:) no longer carries the described pane \
            visibility onto the tab — a disconnected tab has no panes yet, \
            so this is the only place the description can be kept until the \
            tab connects.
            """)
    }

    // MARK: - The closing window writes what it held

    @Test func aClosingWindowWritesItsSeedBeforeItTearsAnythingDown() throws {
        let body = try Self.body("func handleWindowWillClose(", in: Self.lifecycleFile)
        guard let write = body.range(of: "writeRestorationSeedOnClose()"),
            let release = body.range(of: "releaseHeldTabsOnClose()")
        else {
            Issue.record("""
                handleWindowWillClose no longer calls both \
                writeRestorationSeedOnClose() and releaseHeldTabsOnClose() — \
                the seed write is gone, or the close path is.
                """)
            return
        }
        #expect(write.lowerBound < release.lowerBound, """
            the seed must be written BEFORE the teardown starts: \
            teardown(_:reason:) clears a tab's activeStoredSessionID, so a \
            seed written afterwards would describe every tab as having no \
            session at all.
            """)
    }

    @Test func theSeedWriteAsksTheSettingAndTheStore() throws {
        let body = try Self.body("func writeRestorationSeedOnClose()", in: Self.lifecycleFile)
        #expect(body.contains("settingsStore.restoresWindows"), """
            writeRestorationSeedOnClose() no longer reads \
            settingsStore.restoresWindows — a window would write its seed \
            whether or not the user asked for restoration.
            """)
        #expect(body.contains("restorationStore.append("), """
            writeRestorationSeedOnClose() no longer appends to the store — \
            nothing would reach windows.json.
            """)
    }

    // MARK: - The described pane visibility lands somewhere

    /// The connect path is the only place a described visibility can be
    /// applied, because a restored tab has no panes until it connects.
    /// The precedence itself is `WindowRestorationPlan.paneVisibility`'s
    /// (pinned in `WindowRestorationPlanTests`); this pins that connect
    /// asks it rather than re-deriving it.
    @Test func connectResolvesPaneVisibilityThroughThePlan() throws {
        let body = try Self.body("func connect(", in: Self.contentViewFile)
        #expect(body.contains("WindowRestorationPlan.paneVisibility("), """
            connect(in:stored:paneVisibility:) no longer resolves the pane \
            visibility through WindowRestorationPlan — a restored tab would \
            come up with the stored session's saved panes instead of the \
            ones its window was closed with.
            """)
        #expect(body.contains("restoredPaneVisibility = nil"), """
            connect(in:stored:paneVisibility:) no longer clears the tab's \
            restoredPaneVisibility — the description would keep overriding \
            every later connect on that tab, including one the user made \
            after changing the panes.
            """)
    }

    // MARK: - What may ever reach windows.json

    /// The seed types hold identifiers and booleans. This reads the two
    /// struct bodies and checks every stored property's TYPE against an
    /// allowed set, so a property of any other type — a password, a
    /// `FieldValues`, a `StoredSession` — fails here rather than in a
    /// review someone had to remember to do.
    ///
    /// It can read the bodies this strictly because `WindowSeed.swift`
    /// keeps its initializers in extensions: the two struct bodies hold
    /// stored properties and nothing else.
    @Test func theSeedTypesStoreIdentifiersAndBooleansOnly() throws {
        let allowed: Set<String> = ["UUID", "UUID?", "[UUID]", "[TabSeed]", "Bool", "PaneVisibility"]
        let code = try Self.code(of: Self.seedFile)
        for declaration in ["struct WindowSeed: Codable, Hashable, Sendable",
                            "struct TabSeed: Codable, Hashable, Sendable"] {
            let body = try TransferQueueBarCancelGuardTests.declarationBody(
                of: declaration, in: code)
            let properties = Self.storedProperties(in: body)
            #expect(!properties.isEmpty, """
                \(declaration) resolved to no stored properties at all — the \
                type check below is reading nothing
                """)
            for property in properties {
                #expect(allowed.contains(property.type), """
                    \(declaration) stores \(property.name) of type \
                    \(property.type), which is not one of the identifier and \
                    boolean types a window seed may hold \
                    (\(allowed.sorted().joined(separator: ", "))). windows.json \
                    is not a secret store and must never become one.
                    """)
            }
        }
    }

    /// Positive beside the scan above: the properties this task's seeds
    /// are supposed to carry are all found by the same reader, so an
    /// allowed-type check that matched nothing cannot pass as one that
    /// matched everything.
    @Test func theSeedReaderFindsEveryPropertyTheSeedsAreMadeOf() throws {
        let code = try Self.code(of: Self.seedFile)
        let window = Self.storedProperties(
            in: try TransferQueueBarCancelGuardTests.declarationBody(
                of: "struct WindowSeed: Codable, Hashable, Sendable", in: code))
        #expect(Set(window.map(\.name)) == ["id", "tabIDs", "tabs", "keepOnTop", "isPrimary"])
        let tab = Self.storedProperties(
            in: try TransferQueueBarCancelGuardTests.declarationBody(
                of: "struct TabSeed: Codable, Hashable, Sendable", in: code))
        #expect(Set(tab.map(\.name)) == ["sessionID", "paneVisibility"])
    }

    /// `let`/`var` declarations with an explicit type annotation, as
    /// (name, type) pairs. A default value (`= .filesOnly`) is dropped;
    /// the type is everything between the colon and the `=` or the end of
    /// the line.
    private static func storedProperties(in body: String) -> [(name: String, type: String)] {
        body.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("let ") || line.hasPrefix("var ") else { return nil }
            let withoutKeyword = String(line.dropFirst(4))
            guard let colon = withoutKeyword.firstIndex(of: ":") else { return nil }
            let name = withoutKeyword[..<colon].trimmingCharacters(in: .whitespaces)
            var type = String(withoutKeyword[withoutKeyword.index(after: colon)...])
            if let equals = type.firstIndex(of: "=") { type = String(type[..<equals]) }
            return (name, type.trimmingCharacters(in: .whitespaces))
        }
    }
}
