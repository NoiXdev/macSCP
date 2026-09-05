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
    private static let detailFile = sourceDir.appendingPathComponent("ContentView+Detail.swift")
    private static let storeFile = sourceDir
        .appendingPathComponent("WindowRestorationStore.swift")

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
    /// decision, the per-window setup pass that runs the restoration, the
    /// code that opens the restored windows, and the code that builds a
    /// restored tab.
    ///
    /// `performWindowSetup()` was missing from the first version of this
    /// list (fix round 1) — it is the body that CALLS the other three, so
    /// a connect planted between them would have been scanned by nothing.
    private static let launchBodies: [(name: String, declaration: String, file: URL)] = [
        ("MacSCPApp.init", "init()", appFile),
        ("performWindowSetup()", "func performWindowSetup()", lifecycleFile),
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
        #expect(body.contains("consumeAtLaunch("), """
            MacSCPApp.init no longer calls consumeAtLaunch( — a seed file \
            must be consumed by the launch that finds it, in both \
            directions (read then deleted while restoring, deleted unread \
            while not), or a launch can see two generations of windows at \
            once.
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
        #expect(body.contains("restoredSessionID"), """
            makeRestoredTab(from:) no longer points the tab at its stored \
            session — a restored tab must come back showing that session's \
            overview, one click from connecting. (Fix round 1 replaced a \
            beginEditing( prefill here, which put the form in edit mode and \
            offered "Save & connect" instead.)
            """)
        #expect(body.contains("restoredPaneVisibility"), """
            makeRestoredTab(from:) no longer carries the described pane \
            visibility onto the tab — a disconnected tab has no panes yet, \
            so this is the only place the description can be kept until the \
            tab connects.
            """)
    }

    // MARK: - The file is written at quit, and only there

    /// The ruling this round exists for. ⌘Q closes no windows, so the
    /// windows a `willClose` handler can describe are exactly the ones
    /// restoration is NOT about.
    @Test func theQuitSweepDescribesEveryOpenWindowAndReplacesTheFile() throws {
        let body = try Self.body("func writeRestorationSeeds()", in: Self.appFile)
        #expect(body.contains("TabRegistry.shared.describeAllWindows()"), """
            writeRestorationSeeds() no longer asks the registry to describe \
            the open windows — there is nothing left that knows which \
            windows exist at quit.
            """)
        #expect(body.contains(".replace("), """
            writeRestorationSeeds() no longer replaces the file — a quit \
            must write what was on screen, whole.
            """)
        #expect(body.contains("restoresWindows"), """
            writeRestorationSeeds() no longer reads the setting — every quit \
            would write a file whether or not the user asked for restoration.
            """)
    }

    /// Positive beside the negative below: `applicationWillTerminate` is
    /// what runs it, so the write really is on the one path that is
    /// guaranteed to run when the app ends.
    @Test func terminatingIsWhatRunsTheWrite() throws {
        let body = try Self.body(
            "func applicationWillTerminate(_ notification: Notification)", in: Self.appFile)
        #expect(body.contains("writeRestorationSeeds()"), """
            applicationWillTerminate no longer calls writeRestorationSeeds() \
            — nothing would ever describe the windows that were open.
            """)
    }

    /// NEGATIVE, with the two positives above beside it: no window writes
    /// the restoration file on its own close path, and nothing appends to
    /// it anywhere. Both are how the first version of this feature
    /// described the wrong set of windows.
    @Test func noWindowWritesTheRestorationFileWhenItCloses() throws {
        let lifecycle = try Self.code(of: Self.lifecycleFile)
        for forbidden in ["restorationStore.append(", "restorationStore.replace(",
                          "writeRestorationSeedOnClose("] {
            #expect(!lifecycle.contains(forbidden), """
                ContentView+Lifecycle.swift contains \(forbidden) — the \
                restoration file is written once, at quit, from the windows \
                still registered. A window writing it as it closes describes \
                exactly the windows restoration is not about, because ⌘Q \
                closes none of them.
                """)
        }
        let store = try Self.code(of: Self.storeFile)
        #expect(!store.contains("func append("), """
            WindowRestorationStore still offers append( — the file describes \
            one quit and is replaced whole; an append is how a session's \
            deliberately closed windows piled up in it.
            """)
    }

    /// A closing window stops being one to bring back — the other half of
    /// the ruling above, and the reason a describer is unregistered rather
    /// than left to answer at quit for a window that is gone.
    @Test func aClosingWindowStopsDescribingItself() throws {
        let body = try Self.body("func handleWindowWillClose(", in: Self.lifecycleFile)
        #expect(body.contains("unregisterWindowDescriber(for: windowID)"), """
            handleWindowWillClose no longer unregisters this window's \
            describer — a window the user closed would still be described at \
            quit, and restored at the next launch.
            """)
    }

    /// Positive beside `aClosingWindowStopsDescribingItself`: the window
    /// registers a describer in the first place, on the setup pass.
    @Test func anAppearingWindowRegistersItsDescriber() throws {
        let body = try Self.body("func performWindowSetup()", in: Self.lifecycleFile)
        #expect(body.contains("registerWindowDescriber("), """
            performWindowSetup() no longer registers this window's describer \
            — the quit sweep would find no windows to describe at all.
            """)
    }

    // MARK: - A restored tab shows its own session's overview

    /// The overview branch resolves per TAB before it resolves per
    /// WINDOW (fix round 1). Without that, N restored tabs would all show
    /// whichever session the one window-wide sidebar selection names — or,
    /// with no selection, an empty form.
    @Test func theOverviewBranchResolvesTheTabsOwnSessionFirst() throws {
        let detail = try Self.code(of: Self.detailFile)
        #expect(detail.contains("overviewSession(for: tab)"), """
            ContentView+Detail.swift's overview branch no longer resolves \
            the session per tab — a restored window's tabs would all show \
            the window's one sidebar selection instead of the session each \
            of them was restored pointing at.
            """)
        let resolver = try Self.body(
            "func overviewSession(for tab: SessionTab) -> StoredSession?",
            in: Self.contentViewFile)
        #expect(resolver.contains("tab.restoredSessionID"), """
            overviewSession(for:) no longer reads the tab's restored \
            pointer, so it can only ever answer with the window's own \
            sidebar selection.
            """)
        #expect(resolver.contains("overviewSession"), """
            overviewSession(for:) no longer falls back to the window's \
            selection — every tab made any other way must keep behaving \
            exactly as it did before restoration existed.
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
        #expect(body.contains("restoredSessionID = nil"), """
            connect(in:stored:paneVisibility:) no longer clears the tab's \
            restoredSessionID — a later disconnect would put the restored \
            session's overview back instead of this window's own sidebar \
            selection.
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
