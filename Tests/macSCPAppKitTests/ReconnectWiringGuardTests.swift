import Foundation
import Testing

/// Guards the load-bearing security decision of the connection-liveness
/// plan's recovery section: **every connection macSCP opens goes through
/// the one shared connect path**, so TOFU stays a hard stop, the keychain
/// and login-set rules in `ContentView.fillForm(_:from:)` always run, the
/// plaintext confirmation is always asked, and the hand-off locks always
/// apply.
///
/// **This suite is an allow-list, not a deny-list, and that inversion is
/// the whole point.** Its first version asked "does `ContentView
/// .reconnect(_:)` call `connect(in:stored:)`?" — anchored on the function
/// its author had just written. The reviewer defeated it in one line by
/// dialing from somewhere else entirely: `ReconnectRunner`'s mount in
/// `ContentView+Detail.swift` reaches the shared path through
/// `onAttempt: { reconnect($0) }`, and replacing THAT with a direct dial
/// compiled and left the whole suite green while bypassing `fillForm`, the
/// teardown, both hand-off locks, `startSession` and the audit recorder.
/// A guard anchored on the code its author was thinking about cannot see
/// the site its author was not thinking about.
///
/// So the question here is inverted. Not "does this one function
/// delegate?" but: **where can a connection be dialed, or a session be
/// handed to a tab, anywhere in the App layer — and is every such place on
/// the short list below?** A new dial anywhere in `Sources/MacSCPAppKit`
/// now turns this suite red by default, including in a file nobody thought
/// to anchor on. The same inversion this project already applied to the
/// snippet gate, for the same measured reason: an allow-list makes "nobody
/// thought of it" fail closed, a deny-list makes it pass.
///
/// The scan runs over comment- and string-stripped source, so neither a doc
/// comment nor a log line naming a call can satisfy or trip it — a mutation
/// that deleted a real call and left the prose behind is how an earlier
/// guard on this branch passed while broken.
///
/// Fail-closed throughout: an unreadable file, a missing anchor, an
/// unbalanced brace, a walk that finds implausibly few files, and a
/// sanctioned site that no longer exists are all failures.
@Suite("Reconnect wiring guard")
struct ReconnectWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func file(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    /// Both GUI targets. `MacSCPMain` is a ten-line entry point today, and
    /// including it costs nothing — the point of an allow-list is that
    /// "nobody thought to look there" is not a way through it.
    ///
    /// `Sources/MacSCPCLI` is deliberately NOT scanned: it is a separate
    /// program with no tabs, no lost surface and no reconnect policy, and
    /// its own connect path is not this property. Sanctioning its dial
    /// sites here would mean vouching for code this suite is not about.
    private static let scannedRoots = [
        repoRoot.appendingPathComponent("Sources/MacSCPAppKit"),
        repoRoot.appendingPathComponent("Sources/MacSCPMain"),
    ]

    // MARK: - The choke points, and who is allowed to be at one

    /// What the scan looks for. Deliberately generous: a token that never
    /// appears costs nothing, and the cost of a missing one is a dial
    /// nobody sees. Grouped by what they are a choke point FOR.
    ///
    /// Dialing:
    /// - `.connect(` — every dial the App can start today spells this:
    ///   the form's `viewModel.connect()`, `connect(in:stored:)`'s
    ///   `form.connect()`, and the connector closure's
    ///   `BackendDescriptor.descriptor(for:).connect(`.
    /// - the concrete backends and their transports — naming one in the App
    ///   layer means going around `BackendDescriptor` altogether.
    /// - `import Citadel` / `import NIO` — the App layer imports neither
    ///   today, and a hand-rolled dial would need one.
    ///
    /// Handing a session to a tab, which is the choke point a dial the
    /// tokens above somehow missed would still have to pass:
    /// - `startSession(`, `BrowserSession(`, `tab.session =`.
    ///
    /// Two more, guarding this task's own structural claims rather than the
    /// dial: `LostConnectionContent(` (the error view's content must come
    /// from `LostConnectionPlan`, which is what keeps a host name or a
    /// server message off that surface) and `dot(.red` (the attention dot
    /// must be rendered in exactly one place, the one that consults
    /// `TabIndicatorPlan`).
    private static let chokePointTokens = [
        ".connect(",
        "CitadelFileSystem", "SSHClient", "SFTPClient", "S3FileSystem", "WebDAVFileSystem",
        "import Citadel", "import NIO",
        "startSession(", "BrowserSession(", "tab.session =",
        "LostConnectionContent(", "dot(.red",
    ]

    private struct SanctionedSite {
        /// Repo-relative path.
        let file: String
        /// The line as it must read after comment/string stripping and
        /// whitespace normalization.
        let code: String
        /// How many times that exact line may appear in that file. Always
        /// `1` today — the field exists so a SECOND line spelled identically
        /// to a sanctioned one cannot smuggle a dial in under its allowance.
        let occurrences: Int
        let reason: String
    }

    /// Eleven entries, counted while writing this sentence. Adding a
    /// twelfth is a deliberate edit here, with a reason, which is the
    /// entire mechanism: a new dial cannot become invisible by being
    /// somewhere nobody anchored on.
    private static let sanctionedSites: [SanctionedSite] = [
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift",
            code: "return try await BackendDescriptor.descriptor(for: config.kind).connect(",
            occurrences: 1,
            reason: "The connector closure `ContentView.makeTab` builds — the ONE place the App layer reaches a backend, with the host-key decider, the certificate decider and the plaintext gate already applied around it."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ConnectionFormView.swift",
            code: "if let fs = await viewModel.connect() {",
            occurrences: 1,
            reason: "The connection form's own Connect button — the ad-hoc path, which hands its result to `ContentView.handleAdHocConnected`."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "if let fs = await form.connect() {",
            occurrences: 1,
            reason: "`ContentView.connect(in:stored:)` — the stored-session path, after `fillForm(_:from:)` has applied the keychain, login-set and managed-key rules. This is the dial `reconnect(_:)` reaches."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "func startSession(",
            occurrences: 1,
            reason: "The hand-off function's own declaration."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "tab.session = BrowserSession(",
            occurrences: 1,
            reason: "Inside `startSession` — the only construction of a `BrowserSession` in the App layer."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "startSession(in: tab, with: fs, startPath: home)",
            occurrences: 1,
            reason: "`handleAdHocConnected` — the ad-hoc path's hand-off, behind its own attempt-token check."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "startSession(in: tab, with: fs, storedName: stored.name, startPath: home)",
            occurrences: 1,
            reason: "`connect(in:stored:)` — the stored-session path's hand-off, behind its own attempt-token check."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift",
            code: "tab.session = nil",
            occurrences: 1,
            reason: "`teardown(_:)` releasing the session — the only other writer of that property."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "return LostConnectionContent(",
            occurrences: 1,
            reason: "`LostConnectionPlan.content` — the only builder of the error view's content, which is what keeps that surface to a fixed set of catalog keys (see `ReconnectPlanTests`)."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "LostConnectionView(",
            occurrences: 1,
            reason: "`ContentView.detail`'s lost branch — the only site that renders the error view."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/TabStripView.swift",
            code: "case .attention: dot(.red, pulse: false)",
            occurrences: 1,
            reason: "`TabItemView.body` — the only site that draws the attention dot, and it draws it from `TabIndicatorPlan`'s answer, which is where the `.lost` suppression lives."),
    ]

    // MARK: - The allow-list scan

    /// The claim: no line anywhere under `Sources/MacSCPAppKit` touches a
    /// choke point except the sanctioned ones. This is the test the
    /// reviewer's mutation trips — the dial it added sits in
    /// `ContentView+Detail.swift`, which has sanctioned lines of its own,
    /// but not that one.
    @Test func everyChokePointInTheAppLayerIsSanctioned() throws {
        var unsanctioned: [String] = []
        for file in try Self.appSwiftFiles() {
            let relative = Self.relativePath(of: file)
            let stripped = Self.stripCommentsAndStrings(
                try String(contentsOf: file, encoding: .utf8))
            for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = Self.normalized(String(line))
                guard Self.chokePointTokens.contains(where: { code.contains($0) }) else { continue }
                let sanctioned = Self.sanctionedSites.contains {
                    $0.file == relative && $0.code == code
                }
                if !sanctioned { unsanctioned.append("\(relative): \(code)") }
            }
        }
        #expect(unsanctioned.isEmpty, """
            unsanctioned choke point(s) in the App layer:
            \(unsanctioned.joined(separator: "\n"))

            A connection may only be dialed, and a session may only be handed to a tab, at a \
            site on `sanctionedSites`. Every other path must go through \
            `ContentView.connect(in:stored:)` — that is what keeps TOFU a hard stop, the \
            keychain and login-set rules applied, the plaintext confirmation asked and the \
            hand-off locks in force. If this line really is a new sanctioned path, add it to \
            the list WITH a reason, and expect that addition to be read as the security \
            decision it is.
            """)
    }

    /// The other half, without which the list rots into fiction: every
    /// allowance must still match, and match exactly as many lines as it
    /// claims. A count of 0 means the code moved and the allowance is now
    /// a lie; a count of 2 means a second line spelled identically to a
    /// sanctioned one is riding on its allowance.
    @Test func everySanctionedSiteStillExistsExactlyAsOftenAsDeclared() throws {
        for site in Self.sanctionedSites {
            let stripped = Self.stripCommentsAndStrings(
                try String(contentsOf: Self.file(site.file), encoding: .utf8))
            let matches = stripped
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { Self.normalized(String($0)) == site.code }
                .count
            #expect(matches == site.occurrences, """
                `\(site.code)` appears \(matches) time(s) in \(site.file), expected \
                \(site.occurrences). Sanctioned for: \(site.reason)
                """)
        }
    }

    /// The walk itself has to be believable, or both tests above pass by
    /// scanning nothing. Checked against a floor and a known member rather
    /// than an exact count, so adding a source file is not a test edit.
    @Test func theScanActuallyReachesTheAppLayer() throws {
        let files = try Self.appSwiftFiles()
        #expect(files.count >= 30, """
            only \(files.count) Swift files found under Sources/MacSCPAppKit — the walk is \
            not reaching the App layer, and the allow-list scan above is scanning nothing.
            """)
        #expect(files.contains { $0.lastPathComponent == "ContentView.swift" })
        #expect(files.contains { $0.lastPathComponent == "TabStripView.swift" })
        #expect(files.contains { $0.lastPathComponent == "Main.swift" }, """
            the second scanned root (Sources/MacSCPMain) is not being reached.
            """)
    }

    /// The last gap in the "this surface can only show fixed catalog keys"
    /// claim, found by asking where the property could be violated FROM
    /// rather than whether the lines just written still say what they said:
    /// `LostConnectionContent` covers what is passed IN, and the allow-list
    /// above pins that the plan is its only builder — but the view could
    /// still render a string of its own. Every `L10n.string(` in
    /// `LostConnectionView` must take its arguments from `content`, never a
    /// literal.
    ///
    /// Checked on stripped source, where a string literal has become a
    /// space: a hardcoded label reads as `L10n.string( , )`, while
    /// `L10n.string(content.title.key, …)` still starts with an identifier
    /// character. So the test is simply that no `L10n.string(` is followed
    /// by whitespace.
    @Test func theLostSurfaceRendersNoStringOfItsOwn() throws {
        let body = try Self.strippedBody(
            after: "private struct LostConnectionView: View", in: Self.detailFile)
        #expect(body.contains("L10n.string("), "the surface renders no localized text at all?")
        #expect(!body.contains("L10n.string( "), """
            `LostConnectionView` passes a string literal to `L10n.string(`. Every string on \
            this surface has to come through `LostConnectionContent`, or the guarantee that \
            it can only show a fixed, enumerated set of catalog keys — and therefore no host \
            name, server message or typed value — covers only the part that happens to go \
            through the plan.
            """)
    }

    /// Self-test on synthetic source: the scan must actually reject a dial
    /// it has not been told about, and accept the sanctioned spelling.
    @Test func theScanRejectsAnUnknownDialAndAcceptsASanctionedOne() {
        let sanctioned = SanctionedSite(
            file: "Fake.swift", code: "if let fs = await form.connect() {", occurrences: 1,
            reason: "self-test")
        let lines = Self.stripCommentsAndStrings("""
            // if let fs = await form.connect() {
            if let fs = await form.connect() {
            Task { _ = await tab.connectionViewModel.connect() }
            """)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.normalized(String($0)) }
            .filter { code in Self.chokePointTokens.contains { code.contains($0) } }
        #expect(lines.count == 2, "the commented-out line must not count; found \(lines)")
        #expect(lines.contains(sanctioned.code))
        #expect(lines.contains { $0 != sanctioned.code }, """
            the unsanctioned dial must survive stripping and be visible to the scan.
            """)
    }

    // MARK: - Delegation claims
    //
    // Narrower than the scan above and kept alongside it: the scan proves
    // nothing dials outside the sanctioned sites, these prove the surfaces
    // and the schedule still ASK the plain functions whose behaviour
    // `ReconnectPlanTests` pins.

    private static let reconnectAnchor = "func reconnect(_ tab: SessionTab)"
    private static let lostBranchAnchor = "// Lost surface branch (connection-liveness plan, Task 7)"
    private static let runnerAnchor = "struct ReconnectRunner: View"
    private static let runnerMountAnchor = "// Unattended reconnect (Task 7)"
    private static let mirrorWriteAnchor = "// Liveness mirror write (connection-liveness plan, Task 7)"
    private static let indicatorAnchor = "private var indicator: TabIndicatorPlan.Indicator"

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    private static let contentViewFile = file("Sources/MacSCPAppKit/ContentView.swift")
    private static let detailFile = file("Sources/MacSCPAppKit/ContentView+Detail.swift")
    private static let tabStripFile = file("Sources/MacSCPAppKit/TabStripView.swift")

    @Test func theReconnectDialsThroughTheSharedConnect() throws {
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: Self.contentViewFile)
        #expect(body.contains("connect(in: tab, stored: stored)"), """
            `ContentView.reconnect(_:)` no longer calls `connect(in:stored:)`.
            """)
    }

    /// The site the first version of this suite missed entirely: the
    /// schedule reaches the shared path through this mount's `onAttempt`,
    /// not through anything in `reconnect(_:)`'s own neighbourhood.
    @Test func theRunnerMountRoutesItsAttemptThroughReconnect() throws {
        let body = try Self.strippedBody(after: Self.runnerMountAnchor, in: Self.detailFile)
        #expect(body.contains("onAttempt: { reconnect($0) }"), """
            the `ReconnectRunner` mount no longer routes its attempt through `reconnect(_:)`. \
            This is the line the reviewer replaced with a direct dial: it compiled, it \
            bypassed `fillForm`, the teardown, both hand-off locks, `startSession` and the \
            audit recorder, and the suite stayed green.
            """)
    }

    @Test func theLostBranchRendersThePlansContent() throws {
        let body = try Self.strippedBody(after: Self.lostBranchAnchor, in: Self.detailFile)
        #expect(body.contains("surface == .lost"), """
            the lost branch no longer tests `surface == .lost` — the surface choice must stay \
            `ConnectionSurfacePlan.surface`'s answer.
            """)
        #expect(body.contains("LostConnectionPlan.content("), """
            the lost branch no longer asks `LostConnectionPlan.content(`.
            """)
    }

    @Test func theLostBranchRoutesBothButtonsToTheirRealHandlers() throws {
        let body = try Self.strippedBody(after: Self.lostBranchAnchor, in: Self.detailFile)
        #expect(body.contains("reconnect(tab)"), """
            the lost surface's Reconnect button no longer calls `reconnect(tab)`.
            """)
        #expect(body.contains("dismissLostConnection(tab)"), """
            the lost surface's dismissal no longer calls `dismissLostConnection(tab)` — \
            clearing only one of `liveness`/`lostConnection` inline would leave either the \
            surface up or an unattended schedule running behind the form.
            """)
    }

    @Test func theRunnerAsksTheReconnectPlan() throws {
        let body = try Self.strippedBody(after: Self.runnerAnchor, in: Self.detailFile)
        #expect(body.contains("ReconnectPlan.step("), """
            `ReconnectRunner` no longer calls `ReconnectPlan.step(` — a schedule \
            reimplemented inside this view would drift from the behaviours \
            `ReconnectPlanTests` pins, including the rule that an attempt needing a person is \
            never repeated unattended.
            """)
        #expect(body.contains("Task.sleep"), """
            `ReconnectRunner` no longer sleeps — an attempt fired without the backoff the \
            plan hands it is a retry storm, not a schedule.
            """)
    }

    @Test func theRunnerCountsTheAttemptAndFiresIt() throws {
        let body = try Self.strippedBody(after: Self.runnerAnchor, in: Self.detailFile)
        #expect(body.contains("automaticAttempts += 1"), """
            `ReconnectRunner` no longer counts the attempt — `ReconnectPlan.step` paces \
            itself by that count.
            """)
        #expect(body.contains("onAttempt(tab)"), """
            `ReconnectRunner` no longer calls `onAttempt(tab)` — the schedule would run and \
            nothing would be dialed.
            """)
    }

    @Test func theLivenessMirrorAsksItsPlan() throws {
        let body = try Self.strippedBody(after: Self.mirrorWriteAnchor, in: Self.detailFile)
        #expect(body.contains("ConnectAttemptLivenessPlan.write("), """
            `ConnectAttemptLivenessMirror` no longer asks `ConnectAttemptLivenessPlan.write(`.
            """)
        #expect(body.contains("tab.lostConnection?.reason = reason"), """
            the mirror no longer writes back the reason the plan derived — the reconnect \
            schedule reads `lostConnection.reason`, so without this write an attempt that \
            stopped at a host key or a passphrase would keep being repeated unattended.
            """)
    }

    @Test func theTabIndicatorAsksItsPlanAndHandsItTheLiveness() throws {
        let body = try Self.strippedBody(after: Self.indicatorAnchor, in: Self.tabStripFile)
        #expect(body.contains("TabIndicatorPlan.indicator("), """
            `TabItemView.indicator` no longer calls `TabIndicatorPlan.indicator(`.
            """)
        #expect(body.contains("liveness: tab.liveness,"), """
            `TabItemView.indicator` no longer threads `tab.liveness` into the plan.
            """)
    }

    /// A substring check on `liveness: tab.liveness` is satisfied by
    /// `liveness: tab.liveness == .lost ? nil : tab.liveness`, which passes
    /// the plan a value that can never trigger the suppression — the
    /// "keep the spelling, change the behaviour" shape this branch has been
    /// bitten by repeatedly. The real body contains no `?` at all: no
    /// ternary, no optional chaining, no optional type. Banning the
    /// character is crude, and deliberately so — if this property ever
    /// genuinely needs one, that is a change worth stopping at.
    @Test func theTabIndicatorPassesItsArgumentsUnconditioned() throws {
        let body = try Self.strippedBody(after: Self.indicatorAnchor, in: Self.tabStripFile)
        #expect(!body.contains("?"), """
            `TabItemView.indicator` now contains a `?`. A ternary or an optional here can \
            neutralize a value while still spelling out the argument that carries it — check \
            what is actually reaching `TabIndicatorPlan` before widening this guard.
            """)
        #expect(!body.contains("return .attention"), """
            `TabItemView.indicator` decides `.attention` itself again — that is the \
            pre-Task-7 body, which had no way to know about `.lost`.
            """)
    }

    @Test(arguments: [
        (reconnectAnchor, "Sources/MacSCPAppKit/ContentView.swift"),
        (lostBranchAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (runnerAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (runnerMountAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (mirrorWriteAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (indicatorAnchor, "Sources/MacSCPAppKit/TabStripView.swift"),
    ])
    func everyAnchorAppearsExactlyOnceInItsRealFile(anchor: String, relativePath: String) throws {
        let source = try String(contentsOf: Self.file(relativePath), encoding: .utf8)
        let count = source.components(separatedBy: anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(anchor)` in \(relativePath), found \(count) — \
            re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.strippedBody(after: Self.reconnectAnchor, in: "func somethingElse() {}")
        }
    }

    /// The exact mutation that defeated an earlier guard on this branch: a
    /// comment naming the call, with the real call deleted, must not
    /// satisfy the check.
    @Test func scannerIsNotFooledByACommentNamingTheCall() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                // Goes through connect(in: tab, stored: stored), the shared path.
                dialSomethingElse()
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
    }

    @Test func scannerIsNotFooledByAStringLiteralNamingTheCall() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                log("connect(in: tab, stored: stored)")
                dialSomethingElse()
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
    }

    @Test func stripperSelfTestRemovesLineAndBlockCommentsAndStringLiterals() {
        let source = #"""
            let a = "ReconnectPlan.step(" // ReconnectPlan.step(
            /* ReconnectPlan.step( */ let b = 1
            let c = """
                ReconnectPlan.step(
                """
            ReconnectPlan.step(
            """#
        let stripped = Self.stripCommentsAndStrings(source)
        #expect(stripped.components(separatedBy: "ReconnectPlan.step(").count - 1 == 1, """
            expected exactly 1 real occurrence of `ReconnectPlan.step(` to survive stripping; \
            found \(stripped.components(separatedBy: "ReconnectPlan.step(").count - 1).
            """)
    }

    /// The stripper must not swallow line breaks, or the allow-list scan
    /// would see one enormous line and match nothing.
    @Test func stripperKeepsLineStructure() {
        let stripped = Self.stripCommentsAndStrings("""
            let a = 1 /* a
            comment across lines */
            let b = "text"
            """)
        #expect(stripped.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
    }

    // MARK: - Scanner

    private static func appSwiftFiles() throws -> [URL] {
        var files: [URL] = []
        for root in scannedRoots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { throw ScanError.anchorNotFound }
            files += walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL) -> String {
        let root = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"
        return file.path.hasPrefix(root)
            ? String(file.path.dropFirst(root.count)) : file.path
    }

    /// Collapses every run of whitespace to one space and trims — so an
    /// allow-list entry survives reindentation and line rewrapping without
    /// surviving an actual change to the code on the line.
    private static func normalized(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func strippedBody(after anchor: String, in file: URL) throws -> String {
        let source = try String(contentsOf: file, encoding: .utf8)
        return try strippedBody(after: anchor, in: source)
    }

    /// Strips comments and string literals FIRST, then counts braces from
    /// the first `{` of the remaining text to its match, returning
    /// everything from the anchor through that close — the header included,
    /// since several claims are about a call in a `switch` subject or an
    /// `if` condition. Stripping first matters: a brace inside a comment
    /// would otherwise shift where the scanner believes the block ends.
    /// The anchor is found in the RAW source, because some anchors are `//`
    /// comments a global strip would delete first.
    private static func strippedBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let stripped = stripCommentsAndStrings(String(source[anchorRange.upperBound...]))
        guard let openBraceIndex = stripped.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        var depth = 0
        var index = openBraceIndex
        while index < stripped.endIndex {
            let character = stripped[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[stripped.startIndex...index])
                }
            }
            index = stripped.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    /// Strips `//` and `/* */` comments and both `"..."` and `"""..."""`
    /// string literals, preserving line breaks so the allow-list scan can
    /// still work line by line. Measured necessary, not theoretical: a
    /// mutation that deleted a real call from this project's source once
    /// passed a guard because the surrounding doc comment named the method
    /// in prose.
    ///
    /// Handles `\"`-escaped quotes and nested `/* */` comments. Does not
    /// parse string interpolation — `\(...)` inside a literal is treated as
    /// string content, which can only make a check find LESS text, never
    /// invent a match that was not code.
    private static func stripCommentsAndStrings(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                result.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    result.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                i = min(i + 3, chars.count)
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                i = min(i + 1, chars.count)
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }
}
