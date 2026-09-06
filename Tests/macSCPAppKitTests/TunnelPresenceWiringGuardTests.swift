import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Where Task 7's four surfaces are wired, read from source: the launch
/// path, the sidebar row's glyph, the two session-less menus, and the line
/// the login-item seam draws around `SMAppService` (port-forwarding plan,
/// Task 7).
///
/// These are claims about CALL SITES, and a call site cannot be counted from
/// a running program. Nothing in this target renders a view — the boundary
/// every other guard here states — so what a launch does and what a row draws
/// are checked as text, over the COMMENT-BLANKED source (CLAUDE.md,
/// "Source-scanning guards read comments too"): this file's own prose names
/// several of the needles it looks for, and so does the code it scans.
///
/// Every negative check below has a positive beside it naming the thing it
/// scans (CLAUDE.md, "Guards that name what they watch"): a `!contains` over
/// a span that no longer exists reads exactly like a check that is satisfied.
@Suite("Tunnel presence wiring guard")
struct TunnelPresenceWiringGuardTests {

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TunnelPresenceWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appKitRoot = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
    private static let testsRoot = repoRoot.appendingPathComponent("Tests")
    private static let sourcesRoot = repoRoot.appendingPathComponent("Sources")
    private static let appFile = appKitRoot.appendingPathComponent("MacSCPApp.swift")
    private static let sidebarFile = appKitRoot.appendingPathComponent("SessionSidebar.swift")
    private static let dockFile = appKitRoot.appendingPathComponent("TunnelDockPresence.swift")
    private static let loginFile = appKitRoot.appendingPathComponent("LoginItem.swift")
    private static let plansFile = appKitRoot.appendingPathComponent("TunnelStatusPlans.swift")
    private static let sheetFile = appKitRoot.appendingPathComponent("TunnelAutostartSheet.swift")
    private static let menuBarFile = appKitRoot.appendingPathComponent("MenuBarController.swift")

    /// Every App-layer file that starts a forwarding with no window behind
    /// it: the two session-less menus' shared builder, and the autostart
    /// overlay. Both are places a host-key question could not be drawn, so
    /// both must hand in `.refusing` — see
    /// `theBlockStartsOnlyWithARefusingDecider`.
    private static let windowlessStartFiles = [dockFile, sheetFile]

    private static func text(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    private static func strict(_ file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try text(of: file))
    }

    private static func body(_ declaration: String, in file: URL) throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(
            of: declaration, in: try strict(file))
    }

    // MARK: - The launch path

    /// **The one place a launch starts a forwarding.** Deleting this call is
    /// the whole feature quietly not happening: every autostart profile stays
    /// stopped, nothing fails, and no other test in this tree notices —
    /// `TunnelManagerTests` drives `startAutoStart(_:)` directly and would
    /// stay green over an app that never calls it.
    ///
    /// Positive first (the callback exists, and the manager declares the
    /// method), then the call, then the count: exactly one caller in the
    /// whole App target, and it is this one.
    @Test func theLaunchStartsTheAutostartProfilesAndNothingElseDoes() throws {
        let app = try Self.strict(Self.appFile)
        #expect(
            app.contains("func applicationDidFinishLaunching("),
            "the delegate has no launch callback any more — re-anchor this guard")

        let launch = try Self.body(
            "func applicationDidFinishLaunching(_ notification: Notification)", in: Self.appFile)
        #expect(
            launch.contains("LaunchAutoStartPlan.moments("),
            "the launch no longer asks which autostart moments it may run")
        #expect(
            launch.contains("startAutoStart("),
            """
            the launch no longer starts the autostart forwardings: every profile set to \
            "At launch" would stay stopped, silently, with nothing failing anywhere.
            """)
        #expect(
            launch.contains("LoginLaunchDetector.launchedAtLogin("),
            "the launch no longer asks whether it was a login launch")

        let callers = try Self.appKitFiles().filter { file in
            try Self.strict(file).contains(".startAutoStart(")
        }.map(\.lastPathComponent).sorted()
        #expect(
            callers == ["MacSCPApp.swift"],
            "the autostart is started from \(callers), expected MacSCPApp.swift alone")
    }

    /// The launch never answers a host-key question for itself. It hands
    /// nothing to `startAutoStart(_:)` but the moment; the decider is that
    /// method's own `.refusing`, and a decider spelled HERE would be a second
    /// answer to the TOFU question in the one place nobody is looking.
    ///
    /// The positive above it is the call this negative is scoped to.
    @Test func theLaunchNeverDecidesAHostKey() throws {
        let launch = try Self.body(
            "func applicationDidFinishLaunching(_ notification: Notification)", in: Self.appFile)
        #expect(launch.contains("startAutoStart("), "re-anchor: the launch starts nothing")
        for forbidden in ["decider:", "HostKeyDecider", "TunnelConnection.connect("] {
            #expect(
                !launch.contains(forbidden),
                "the launch path names \"\(forbidden)\" — the autostart's decider is not the launch's to pick")
        }
    }

    /// The badge is armed at launch too, and by the controller rather than by
    /// a write to `NSApp.dockTile` from the delegate.
    @Test func theLaunchArmsTheDockBadge() throws {
        let launch = try Self.body(
            "func applicationDidFinishLaunching(_ notification: Notification)", in: Self.appFile)
        #expect(
            launch.contains("DockBadgeController("),
            "the launch no longer builds the Dock-badge controller — the badge would never appear")
        #expect(launch.contains(".start()"), "the Dock-badge controller is built and never started")
        #expect(
            !launch.contains("dockTile"),
            "the launch writes the Dock tile itself instead of through DockBadgeController")
    }

    // MARK: - The Dock menu

    /// The Dock menu draws the shared block and nothing it composed itself,
    /// and it dials nothing.
    @Test func theDockMenuDrawsTheSharedBlockAndDialsNothing() throws {
        let app = try Self.strict(Self.appFile)
        #expect(
            app.contains("func applicationDockMenu("),
            "the delegate offers no Dock menu any more — re-anchor this guard")

        let menu = try Self.body(
            "func applicationDockMenu(_ sender: NSApplication)", in: Self.appFile)
        #expect(
            menu.contains("TunnelMenuBlockController("),
            "the Dock menu no longer uses the shared forwarding block")
        #expect(menu.contains(".items()"), "the Dock menu builds a block and adds none of it")
        for forbidden in ["connect(", "TunnelRunner(", "manager.start("] {
            #expect(
                !menu.contains(forbidden),
                "the Dock menu reaches a host itself (\"\(forbidden)\") instead of asking the manager")
        }
    }

    /// The menu-bar item draws the same block — one builder, two menus, which
    /// is the only thing that keeps them from drifting.
    @Test func theMenuBarItemDrawsTheSameBlock() throws {
        let menuBar = try Self.strict(Self.menuBarFile)
        #expect(
            menuBar.contains("func menuNeedsUpdate("),
            "the menu-bar controller no longer rebuilds its menu — re-anchor this guard")
        let update = try Self.body("func menuNeedsUpdate(_ menu: NSMenu)", in: Self.menuBarFile)
        #expect(
            update.contains("tunnelBlock.items()"),
            "the menu-bar item no longer carries the forwarding block")
        #expect(
            !update.contains("TunnelMenuBlockPlan."),
            "the menu-bar item composes the block itself instead of using the shared builder")
    }

    /// **Every start from a session-less menu refuses an unknown host key.**
    /// Neither menu belongs to a window, so there is nowhere to draw the
    /// question; the design's answer is `.needsConfirmation` and a manual
    /// connect, never an accept-anything path.
    ///
    /// Positive: the block starts something at all. Negative: it starts it
    /// with no other decider than `.refusing`.
    /// Three surfaces, not one (fix round 1, review finding I-3): the
    /// autostart overlay is on this side of the boundary too, and round 0's
    /// version scanned only `TunnelDockPresence.swift` — so an
    /// `.asking { _ in true }` in the sheet stayed green.
    @Test func theBlockStartsOnlyWithARefusingDecider() throws {
        // Each file gets its own positive, so a file that stopped starting
        // anything cannot satisfy the count below by contributing zero to
        // both sides of it.
        for file in Self.windowlessStartFiles {
            let source = try Self.strict(file)
            #expect(
                source.contains("manager.start("),
                "\(file.lastPathComponent) starts nothing any more — re-anchor this guard")
            #expect(
                source.contains("decider: .refusing"),
                "\(file.lastPathComponent) no longer refuses unknown host keys")

            let starts = TransferQueueBarCancelGuardTests.occurrenceCount(
                of: "manager.start(", in: source)
            let refusals = TransferQueueBarCancelGuardTests.occurrenceCount(
                of: "decider: .refusing", in: source)
            #expect(
                starts == refusals,
                """
                \(starts) start(s) in \(file.lastPathComponent) but \(refusals) `.refusing` \
                decider(s): one of them asks a question in a place with no window to draw it in.
                """)
            for forbidden in ["TunnelConnection.connect(", "TunnelRunner(", "HostKeyCandidate("] {
                #expect(
                    !source.contains(forbidden),
                    "\(file.lastPathComponent) dials for itself (\"\(forbidden)\")")
            }
        }
    }

    /// The block's membership rule is the plan's, not a second filter written
    /// into the builder.
    @Test func theBlockAsksThePlanWhichProfilesItLists() throws {
        let dock = try Self.strict(Self.dockFile)
        #expect(
            dock.contains("TunnelMenuBlockPlan.entries("),
            "the forwarding block no longer asks the plan which profiles it lists")
        #expect(
            !dock.contains("autoStart != .off"),
            "the forwarding block re-spells the plan's membership rule instead of asking it")
    }

    // MARK: - The Dock badge

    /// The badge's text is the plan's. A controller that composed `"!"` or a
    /// count itself would be a second reading of the same states, and the two
    /// would disagree the first time one of them changed.
    @Test func theBadgeControllerReadsThePlanAndComposesNothing() throws {
        let dock = try Self.strict(Self.dockFile)
        #expect(
            dock.contains("DockBadgePlan.label("),
            "the Dock badge no longer reads its label from the plan")
        let withLiterals = try SwiftSource.blankingComments(try Self.text(of: Self.dockFile))
        #expect(
            !withLiterals.contains("badge = \"!\""),
            "the Dock badge controller composes its own failure marker")

        // And the plan is the only place the marker is spelled at all.
        let planLiterals = try SwiftSource.blankingComments(try Self.text(of: Self.plansFile))
        #expect(
            planLiterals.contains("return \"!\""),
            "the badge plan no longer returns a failure marker — re-anchor this guard")
    }

    // MARK: - The sidebar glyph

    /// **The row draws what the plan says and picks no colour of its own.**
    ///
    /// The negative is scoped to the glyph's own span, because the row DOES
    /// name a design token elsewhere — the active-tab dot two lines above it
    /// — and a file-wide scan would be satisfied by that one forever.
    @Test func theRowDrawsTheGlyphThePlanDecided() throws {
        let sidebar = try Self.strict(Self.sidebarFile)
        #expect(
            sidebar.contains("TunnelGlyphPlan.glyph("),
            "the session row no longer builds a forwarding glyph — re-anchor this guard")
        #expect(
            TransferQueueBarCancelGuardTests.occurrenceCount(
                of: "TunnelGlyphPlan.glyph(", in: sidebar) == 1,
            "the forwarding glyph is built in more than one place in SessionSidebar.swift")

        let glyph = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "if let glyph = tunnelGlyph", in: sidebar)
        #expect(
            glyph.contains("glyph.tint.color"),
            "the glyph is drawn without the tint the plan chose")
        #expect(glyph.contains("glyph.text"), "the glyph draws a colour with no text beside it")
        for forbidden in ["DesignTokens.", "Color.", ".red", ".green", ".orange"] {
            #expect(
                !glyph.contains(forbidden),
                """
                the row picks the forwarding glyph's colour itself (\"\(forbidden)\") instead of \
                reading the tint `TunnelGlyphPlan` chose.
                """)
        }
    }

    /// The glyph is drawn in BOTH densities, which here means: it is not
    /// wrapped in a compact-mode branch. `SessionSidebarCompactRowGuardTests`
    /// forbids `if !isCompact` anywhere in the row; this states the property
    /// for the glyph specifically, and pairs it with the positive that the
    /// glyph is in the row at all.
    @Test func theGlyphIsDrawnInBothDensities() throws {
        let sidebar = try Self.strict(Self.sidebarFile)
        #expect(sidebar.contains("if let glyph = tunnelGlyph"), "the row draws no glyph any more")
        let glyph = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "if let glyph = tunnelGlyph", in: sidebar)
        #expect(
            !glyph.contains("isCompact"),
            "the forwarding glyph is gated on the sidebar's density")
    }

    /// The tooltip shows the state's own sentence — for a failure, the reason
    /// Core audited, shown verbatim. A row that re-mapped it would put a
    /// second spelling of the same finding in the app.
    @Test func theTooltipReadsTheStateLabelRatherThanRewritingIt() throws {
        let sidebar = try Self.strict(Self.sidebarFile)
        let tooltip = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private var tunnelTooltip: String", in: sidebar)
        #expect(
            tooltip.contains("TunnelProfilesSheet.stateLabel("),
            "the glyph's tooltip no longer reads the state's own sentence")
        #expect(
            !tooltip.contains("case .failed"),
            "the glyph's tooltip re-maps the failure reason instead of showing it verbatim")
    }

    // MARK: - The login-item seam

    /// **`SMAppService` is touched in exactly one file, and no test names
    /// `mainApp` at all.** A test that registered the real login item would
    /// write one for whoever ran `swift test`, and `unregister()` would
    /// remove one the user may have set themselves.
    ///
    /// The positive is the half that matters here: the seam's own file DOES
    /// reach the service. Without it, a tree that had deleted the whole
    /// feature would satisfy the scan of the tests below.
    @Test func onlyTheSeamTouchesTheServiceAndNoTestDoes() throws {
        // Every file under `Sources/`, not only the App target's (fix round
        // 1): a use in Core would otherwise hide from this scan entirely, and
        // Core is the layer that must stay free of app-bundle machinery.
        let production = try Self.sourceFiles().filter { file in
            try Self.strict(file).contains("SMAppService.mainApp")
        }.map(\.lastPathComponent).sorted()
        #expect(
            production == ["LoginItem.swift"],
            "`SMAppService.mainApp` is reached from \(production), expected LoginItem.swift alone")

        let seam = try Self.strict(Self.loginFile)
        for needle in [".register()", ".unregister()", ".status"] {
            #expect(
                seam.contains("SMAppService.mainApp\(needle)"),
                "the seam no longer calls `SMAppService.mainApp\(needle)`")
        }

        let offenders = try Self.testFiles().filter { file in
            try Self.strict(file).contains("SMAppService.mainApp")
        }.map(\.lastPathComponent).sorted()
        #expect(
            offenders.isEmpty,
            """
            \(offenders) reach `SMAppService.mainApp`: a test run would register or remove a real \
            login item for whoever ran it. Drive `LoginItemRegistering` with a fake instead.
            """)

        // The positive beside that negative: the fake route exists and is
        // used, so the scan above is not passing over a suite that dropped
        // the subject entirely.
        let seamUsers = try Self.testFiles().filter { file in
            try Self.strict(file).contains("LoginItemRegistering")
        }.map(\.lastPathComponent).sorted()
        #expect(
            seamUsers.contains("LoginItemTests.swift"),
            "nothing in the tests drives the login-item seam any more — re-anchor this guard")
    }

    /// The model never invents the answer: the status is re-read from the
    /// service after every change rather than mirrored from the click.
    @Test func theModelReReadsTheStatusRatherThanMirroringTheClick() throws {
        let seam = try Self.strict(Self.loginFile)
        let setter = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func setEnabled(_ enabled: Bool)", in: seam)
        #expect(setter.contains("service.register()"), "re-anchor: the setter registers nothing")
        #expect(setter.contains("refresh()"), "the login-item setter no longer re-reads the status")
        #expect(
            !setter.contains("status ="),
            "the login-item setter assigns a status instead of re-reading it from the service")
    }

    // MARK: - The catalogue

    /// Every `tunnel.*` and `settings.general.tunnelAutostart*` key Task 7's
    /// surfaces read, derived from their source rather than listed here — a
    /// list would be a second copy of the same names, and the one that goes
    /// stale.
    @Test func everyKeyTheseSurfacesReadResolvesInTheCatalogue() throws {
        let files = [
            Self.sheetFile, Self.dockFile, Self.loginFile, Self.sidebarFile,
            appKitFile("MacSCPCommands.swift"), appKitFile("SettingsView.swift"),
        ]
        var keys: Set<String> = []
        for file in files {
            let source = try SwiftSource.blankingComments(try Self.text(of: file))
            // `\s*` after the parenthesis: several of these calls wrap, and a
            // pattern demanding the quote right after it silently finds a
            // subset — the trap `TunnelMenuWiringGuardTests` documents.
            let pattern = #"L10n\.string\(\s*"((?:tunnel|settings\.general\.tunnelAutostart)[^"]*)""#
            for match in source.ranges(of: try Regex(pattern)) {
                let call = String(source[match])
                guard let start = call.range(of: "\"") else { continue }
                let rest = call[start.upperBound...]
                guard let end = rest.range(of: "\"") else { continue }
                keys.insert(String(rest[..<end.lowerBound]))
            }
        }
        // 26, RECOUNTED on 2026-09-06 (fix round 1) by running this test's own
        // regex over those six files and reading back what it found — round 0
        // wrote 25 from a hand count and missed `tunnel.menu` in
        // `SessionSidebar.swift`, which is the failure mode CLAUDE.md's
        // "Writing a number … means counting them in that same moment" names.
        // The floor is lower so adding a key is not a test edit, and high
        // enough that a pattern which stopped matching most of them fails here.
        #expect(keys.count >= 24, "found \(keys.count) keys — re-anchor this guard")
        for key in keys.sorted() {
            #expect(
                L10n.string(key, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
                "the catalogue answers nothing for \"\(key)\"")
        }
        // The two new surfaces are actually among them — otherwise the floor
        // above could be met by the sidebar's existing menu keys alone.
        #expect(keys.contains("tunnel.autostart.title"))
        #expect(keys.contains("tunnel.dock.running %lld"))
        #expect(keys.contains("tunnel.glyph.tooltip %@"))
    }

    // MARK: - File lists

    private static func appKitFile(_ name: String) -> URL {
        appKitRoot.appendingPathComponent(name)
    }

    private func appKitFile(_ name: String) -> URL { Self.appKitFile(name) }

    /// Every `.swift` file of the App target, found rather than listed.
    private static func appKitFiles() throws -> [URL] {
        try swiftFiles(under: appKitRoot)
    }

    /// Every `.swift` file under `Tests/`, found rather than listed.
    private static func testFiles() throws -> [URL] {
        try swiftFiles(under: testsRoot)
    }

    /// Every `.swift` file under `Sources/` — all four targets, not just the
    /// App's.
    private static func sourceFiles() throws -> [URL] {
        try swiftFiles(under: sourcesRoot)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
