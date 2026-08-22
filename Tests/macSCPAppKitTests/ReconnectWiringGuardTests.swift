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

    private static let sourcesDirectory = repoRoot.appendingPathComponent("Sources")

    /// The GUI targets this suite scans, BY NAME — but never as the last
    /// word on what exists. Round 2 hardcoded this list, and the reviewer
    /// walked past it by adding a whole new target: `Sources/MacSCPPanels`,
    /// containing a `BackendDescriptor` connect with an accept-anything
    /// host-key decider, made a dependency of the shipped `MacSCPMain`. The
    /// suite stayed green, and the walk's own floor test stayed true
    /// throughout, because a floor cannot notice what it was never pointed
    /// at.
    ///
    /// So the roots are DERIVED and this list is only one half of a
    /// partition. `everySourceDirectoryIsScannedOrExplicitlyExcluded` reads
    /// what is actually on disk under `Sources/`, and
    /// `everyPackageTargetIsScannedOrExplicitlyExcluded` reads what
    /// `Package.swift` actually declares; a directory or target in neither
    /// list fails both. A guard that scans less than it thinks is worse
    /// than one that scans nothing, because it reports success.
    private static let scannedRootNames = ["MacSCPAppKit", "MacSCPMain"]

    private struct ExcludedRoot {
        let name: String
        let reason: String
    }

    /// Not scanned, on purpose, each with the reason that makes it a
    /// decision rather than an oversight. An exclusion is as much a
    /// security statement as a sanctioned site, and is meant to be read as
    /// one.
    private static let excludedRoots: [ExcludedRoot] = [
        ExcludedRoot(
            name: "macSCPCore",
            reason: "Core is where the dial legitimately lives — every backend's `connect` is defined there. The property this suite guards is that the APP reaches those through one path, so scanning Core would mean sanctioning the implementation this suite exists to funnel access to."),
        ExcludedRoot(
            name: "MacSCPCLI",
            reason: "A separate program with no tabs, no lost surface and no reconnect policy. Its own connect path is a different property; sanctioning its dial sites here would mean vouching for code this suite is not about."),
    ]

    private static var scannedRoots: [URL] {
        scannedRootNames.map { sourcesDirectory.appendingPathComponent($0) }
    }

    // MARK: - The choke points, and who is allowed to be at one

    /// What counts as touching a choke point — expressed as patterns over
    /// the THING, not as literal spellings of it.
    ///
    /// Round 2 got this half wrong, and the reviewer measured it: the sites
    /// were an allow-list, but the detector was still thirteen literal
    /// substrings, which is a deny-list wearing an allow-list's clothes.
    /// `let dial = connectionViewModel.connect` followed by
    /// `Task { _ = await dial() }` bypassed `fillForm`, both hand-off locks,
    /// `startSession` and the audit recorder — and passed, because the
    /// token was `.connect(` and the evasion has no paren. Every entry here
    /// was re-read with that question: does this describe a thing, or one
    /// way of writing it?
    ///
    /// What changed, and why:
    /// - `.connect(` → `\.connect\b`. A member named `connect`, applied or
    ///   merely referenced. `.connected`/`.connecting` do not match (the
    ///   word boundary), and catalog keys naming it are string literals the
    ///   stripper has already blanked.
    /// - the five concrete backend/transport type names → two patterns for
    ///   the CATEGORY. Any `…FileSystem` that is not the protocol
    ///   (`RemoteFileSystem`) or the one legitimate local one
    ///   (`LocalFileSystem`), and any `SSH…Client`/`SFTP…Client`. A fourth
    ///   backend added to Core is caught without anyone remembering to add
    ///   it here.
    /// - `import Citadel`/`import NIO` → deleted, and replaced by
    ///   `permittedImports` below. Naming forbidden modules is the same
    ///   deny-list mistake one level down; every import in these targets is
    ///   now allow-listed instead.
    /// - `startSession(`/`BrowserSession(`/`LostConnectionContent(`/
    ///   `LostConnectionView(` → the paren is dropped or made part of a
    ///   construction pattern that also accepts `.init`, so a reference or
    ///   an `.init` spelling cannot slip past.
    /// - `tab.session =` → a pattern for WRITING that property through any
    ///   receiver (`self.session =`, `activeTab.session =`) or none, while
    ///   excluding the `if let session =` bindings that merely read it.
    ///
    /// `dot(.red` → `\bdot\s*\(\s*\.red\b` is the one entry that stays
    /// tied to a helper's name, and it is worth being honest about: a
    /// renamed helper would evade it. It is a belt, not the guarantee. What
    /// actually keeps the `.lost` suppression working is `TabIndicatorPlan`
    /// plus `ReconnectPlanTests` and
    /// `theTabIndicatorPassesItsArgumentsUnconditioned`.
    private struct ChokePoint {
        let pattern: String
        /// What the pattern is looking for, in words — this is what a
        /// failure message tells the reader they have just done.
        let describes: String
    }

    private static let chokePoints: [ChokePoint] = [
        ChokePoint(
            pattern: #"\.connect\b"#,
            describes: "obtaining a connection"),
        ChokePoint(
            pattern: #"\b(?!RemoteFileSystem\b)(?!LocalFileSystem\b)\w*FileSystem\b"#,
            describes: "naming a concrete remote backend"),
        ChokePoint(
            pattern: #"\b(?:SSH|SFTP)\w*Client\b"#,
            describes: "naming a transport client"),
        ChokePoint(
            pattern: #"\bstartSession\b"#,
            describes: "installing a session on a tab"),
        ChokePoint(
            pattern: #"\bBrowserSession\s*(?:\(|\.init\b)"#,
            describes: "constructing a session"),
        ChokePoint(
            pattern: #"\.session\s*=(?!=)|(?<!let )(?<!var )(?<![A-Za-z0-9_.])session\s*=(?!=)"#,
            describes: "writing a tab's session property"),
        ChokePoint(
            pattern: #"\bLostConnectionContent\s*(?:\(|\.init\b)"#,
            describes: "building the lost-connection surface's content"),
        ChokePoint(
            pattern: #"\bLostConnectionView\s*(?:\(|\.init\b)"#,
            describes: "rendering the lost-connection surface"),
        ChokePoint(
            pattern: #"\bdot\s*\(\s*\.red\b"#,
            describes: "drawing the attention dot"),
    ]

    /// Every module these targets may import. An allow-list for the same
    /// reason the sites are one: a hand-rolled dial has to reach a
    /// transport somehow, and naming the libraries it must NOT use is a
    /// list that fails open on the first one nobody thought of.
    ///
    /// Ten entries, counted while writing this sentence. Adding an eleventh
    /// is a deliberate edit, which is the point — `import Citadel`,
    /// `import NIOCore` or `import Network` appearing in the App layer is
    /// exactly the change that should stop a reader.
    private static let permittedImports: Set<String> = [
        "AppKit", "Combine", "Foundation", "MacSCPAppKit", "Observation",
        "SwiftTerm", "SwiftUI", "UniformTypeIdentifiers", "macSCPCore", "os",
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
        let detectors = try Self.chokePointDetectors()
        var unsanctioned: [String] = []
        for file in try Self.appSwiftFiles() {
            let relative = Self.relativePath(of: file)
            let stripped = Self.stripCommentsAndStrings(
                try String(contentsOf: file, encoding: .utf8))
            for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = Self.normalized(String(line))
                guard let describes = Self.chokePoint(in: code, detectors: detectors)
                else { continue }
                let sanctioned = Self.sanctionedSites.contains {
                    $0.file == relative && $0.code == code
                }
                if !sanctioned { unsanctioned.append("\(relative): \(code)   [\(describes)]") }
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

    /// Derives the roots from the filesystem rather than trusting the list:
    /// every directory under `Sources/` must be either scanned or
    /// explicitly excluded with a reason. This is what a new target cannot
    /// walk past — the reviewer's `Sources/MacSCPPanels`, with its
    /// accept-anything host-key decider, is a directory that is in neither
    /// list, so it fails here whether or not anyone remembered this suite.
    ///
    /// Both directions are checked: an unknown directory fails, and a name
    /// on either list that no longer exists on disk fails too, so neither
    /// list can rot into a claim about code that is gone.
    @Test func everySourceDirectoryIsScannedOrExplicitlyExcluded() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: Self.sourcesDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        let directories = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent)

        #expect(directories.count >= 2, """
            only \(directories.count) director(ies) found under Sources/ — this check is not \
            reading the directory it is meant to derive the roots from.
            """)

        let known = Set(Self.scannedRootNames).union(Self.excludedRoots.map(\.name))
        let unknown = Set(directories).subtracting(known)
        #expect(unknown.isEmpty, """
            director(ies) under Sources/ that this suite neither scans nor excludes: \
            \(unknown.sorted()).

            A new target is invisible to a hardcoded root list — which is exactly how a target \
            containing a `BackendDescriptor` connect with an accept-anything host-key decider \
            was added, made a dependency of the shipped app, and left this suite green. Add it \
            to `scannedRootNames` (and expect to sanction whatever it dials), or to \
            `excludedRoots` WITH a reason that says why its connect path is not this property.
            """)

        let missing = known.subtracting(directories)
        #expect(missing.isEmpty, """
            \(missing.sorted()) are named by this suite but no longer exist under Sources/ — \
            an allowance for code that is gone is a lie about the code.
            """)
    }

    /// The second, independent derivation: `Package.swift`'s own non-test
    /// targets. A target could in principle live outside `Sources/` (SwiftPM
    /// takes a `path:`), which the filesystem check above would never see.
    ///
    /// Read from the RAW manifest, comments included. A commented-out target
    /// therefore demands coverage it does not need — a false positive, which
    /// is the safe direction for this check and cheaper than parsing Swift.
    @Test func everyPackageTargetIsScannedOrExplicitlyExcluded() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: #"\.(?:executableTarget|target)\(\s*name:\s*"([^"]+)""#)
        let range = NSRange(manifest.startIndex..., in: manifest)
        var targets: Set<String> = []
        for match in regex.matches(in: manifest, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: manifest) else { continue }
            targets.insert(String(manifest[nameRange]))
        }

        #expect(targets.count >= 2, """
            only \(targets.count) target(s) parsed out of Package.swift — the manifest scan is \
            not reading what it thinks it is.
            """)

        let known = Set(Self.scannedRootNames).union(Self.excludedRoots.map(\.name))
        let unknown = targets.subtracting(known)
        #expect(unknown.isEmpty, """
            Package.swift declares target(s) this suite neither scans nor excludes: \
            \(unknown.sorted()). See `everySourceDirectoryIsScannedOrExplicitlyExcluded` for \
            what to do about it — this check exists because a target's sources need not live \
            under Sources/ at all.
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

    /// Self-test on synthetic source: the scan must reject a dial it has
    /// not been told about, accept the sanctioned spelling, and — the case
    /// round 2 shipped broken — see a dial spelled as an UNAPPLIED method
    /// reference, which has no paren anywhere.
    @Test func theScanSeesEveryWayADialCanBeSpelled() throws {
        let detectors = try Self.chokePointDetectors()
        let flagged = Self.stripCommentsAndStrings("""
            // if let fs = await form.connect() {
            let harmless = tab.liveness == .connected
            let alsoHarmless = surface == .connecting
            if let fs = await form.connect() {
            Task { _ = await tab.connectionViewModel.connect() }
            let dial = tab.connectionViewModel.connect
            let fs = try await CitadelFileSystem.connect(config, decider)
            let client = SSHClient.self
            tab.session = BrowserSession.init(id: id)
            """)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.normalized(String($0)) }
            .filter { Self.chokePoint(in: $0, detectors: detectors) != nil }

        #expect(!flagged.contains { $0.contains("harmless") }, """
            `.connected`/`.connecting` must not match the `connect` pattern, or every liveness \
            comparison in the App layer would need a sanction: \(flagged)
            """)
        #expect(flagged.contains("let dial = tab.connectionViewModel.connect"), """
            an unapplied method reference is invisible to the scan — this is the exact evasion \
            round 2 shipped, where the only difference from a caught line was a paren.
            """)
        #expect(flagged.contains("if let fs = await form.connect() {"))
        #expect(flagged.contains("Task { _ = await tab.connectionViewModel.connect() }"))
        #expect(flagged.contains("let fs = try await CitadelFileSystem.connect(config, decider)"))
        #expect(flagged.contains("let client = SSHClient.self"))
        #expect(flagged.contains("tab.session = BrowserSession.init(id: id)"), """
            an `.init` spelling must be seen the same as a `(` one.
            """)
        #expect(flagged.count == 6, "expected exactly the six real hits, found \(flagged)")
    }

    /// Nothing may enter these targets that is not on `permittedImports` —
    /// a hand-rolled dial has to reach a transport somehow, and this is the
    /// door it would come through.
    @Test func everyImportIsPermitted() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])import\s+([A-Za-z_][\w.]*)"#)
        var seen: Set<String> = []
        var forbidden: [String] = []
        for file in try Self.appSwiftFiles() {
            let stripped = Self.stripCommentsAndStrings(
                try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(stripped.startIndex..., in: stripped)
            for match in regex.matches(in: stripped, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: stripped) else { continue }
                let module = String(stripped[nameRange])
                seen.insert(module)
                if !Self.permittedImports.contains(module) {
                    forbidden.append("\(Self.relativePath(of: file)): import \(module)")
                }
            }
        }
        #expect(forbidden.isEmpty, """
            module(s) imported into the GUI targets that are not on the allow-list:
            \(forbidden.joined(separator: "\n"))

            A transport library reaching the App layer is how a dial that goes around \
            `ContentView.connect(in:stored:)` gets built. If this really is a new dependency \
            of the App layer, add it to `permittedImports` and expect that addition to be \
            read as the decision it is.
            """)
        let stale = Self.permittedImports.subtracting(seen)
        #expect(stale.isEmpty, """
            \(stale.sorted()) are on `permittedImports` but imported nowhere. An allowance for \
            something that does not exist is a lie about the code — remove them.
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

    /// Compiled once per test that needs them, and `throws` rather than
    /// force-unwrapping: a pattern that fails to compile must fail the
    /// calling test loudly, not take the whole run down with it.
    private static func chokePointDetectors() throws -> [(regex: NSRegularExpression, describes: String)] {
        try chokePoints.map { (try NSRegularExpression(pattern: $0.pattern), $0.describes) }
    }

    /// What choke point this line touches, if any — the description, so a
    /// failure message can say what was just done rather than which
    /// substring matched.
    private static func chokePoint(
        in line: String, detectors: [(regex: NSRegularExpression, describes: String)]
    ) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for detector in detectors
        where detector.regex.firstMatch(in: line, range: range) != nil {
            return detector.describes
        }
        return nil
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
