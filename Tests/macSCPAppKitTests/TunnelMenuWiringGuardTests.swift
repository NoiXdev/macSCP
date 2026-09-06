import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The session row's "Port forwarding" submenu, the sheet behind it, and the
/// one boundary both of them are on the safe side of: neither dials
/// (port-forwarding plan, Task 6).
///
/// Two kinds of check live here, and the split is deliberate.
///
/// - **Values.** Which sessions may carry a forwarding at all is
///   `SessionRowTunnelMenuPlan.build`'s answer, so it is driven directly.
///   That is the SSH-only rule, and it is measured, not read out of a view.
/// - **Source.** That the row draws what the plan says, that every entry
///   takes its title from the catalogue, and that nothing but the manager
///   starts a runner, are claims about text — `SessionSidebar` cannot be
///   instantiated in this project (no render harness, the boundary every
///   other guard in this target states) and a call site cannot be counted
///   from a running program.
///
/// Every source scan reads the COMMENT-BLANKED view (CLAUDE.md,
/// "Source-scanning guards read comments too"): this file's own prose names
/// each needle, and so does the code it scans. Catalogue-key claims read the
/// comments-only view instead — blanking the literals would delete the very
/// thing being checked — sliced at the range found in the strict one, which
/// is safe because both views preserve the raw source's length.
@Suite("Tunnel menu wiring guard")
struct TunnelMenuWiringGuardTests {

    // MARK: - Values: who may carry a forwarding

    private static func sshSession(jump: StoredSession.JumpSpec? = nil, loginSetID: UUID? = nil)
        -> StoredSession
    {
        StoredSession(
            name: "web", loginSetID: loginSetID, kind: .ssh,
            ssh: StoredSSHConfig(host: "example.invalid", username: "tester", jump: jump))
    }

    private static func profile(session: UUID) -> TunnelProfile {
        TunnelProfile(
            sessionID: session, name: "web",
            kind: .local(bind: "127.0.0.1", localPort: 8080, host: "internal", remotePort: 80))
    }

    /// The positive: a plain SSH session offers the submenu, with one entry
    /// per stored profile.
    @Test func aPlainSSHSessionOffersTheSubmenu() {
        let session = Self.sshSession()
        let profile = Self.profile(session: session.id)
        let plan = SessionRowTunnelMenuPlan.build(
            for: session, profiles: [profile], state: { _ in .stopped })

        #expect(plan.isShown)
        #expect(plan.entries.map(\.profile) == [profile])
        #expect(plan.entries.allSatisfy { !$0.isRunning })
    }

    /// The negative, and the three reasons for it. A backend with no
    /// `direct-tcpip` at all, and the two shapes `StoredSessionConnectionConfig
    /// .build(for:secret:)` refuses — a jump host and a login set — which a
    /// forwarding's own dial goes through.
    @Test func aSessionThatCouldNotCarryOneIsOfferedNothing() {
        let profileless = UUID()
        let cases: [(String, StoredSession)] = [
            ("S3", StoredSession(name: "bucket", kind: .s3)),
            ("WebDAV", StoredSession(name: "drive", kind: .webdav)),
            (
                "a jump host",
                Self.sshSession(jump: StoredSession.JumpSpec(host: "bastion", username: "tester"))
            ),
            ("a login set", Self.sshSession(loginSetID: profileless)),
        ]
        for (why, session) in cases {
            let plan = SessionRowTunnelMenuPlan.build(
                for: session, profiles: [Self.profile(session: session.id)],
                state: { _ in .stopped })
            #expect(plan == .hidden, "a session with \(why) was offered a forwarding submenu")
            #expect(plan.entries.isEmpty)
        }
    }

    /// A checkmark means running, and "running" is the manager's own
    /// predicate — a `.failed` profile is unchecked, so clicking it starts it
    /// again, which is the state table's own `.failed → .start`.
    @Test func onlyARunningProfileIsChecked() {
        let session = Self.sshSession()
        let running = Self.profile(session: session.id)
        let failed = Self.profile(session: session.id)
        let plan = SessionRowTunnelMenuPlan.build(
            for: session, profiles: [running, failed],
            state: { id in
                id == running.id ? .active(connections: 1) : .failed(reason: "port 8080 is in use")
            })

        #expect(plan.entries.first(where: { $0.id == running.id })?.isRunning == true)
        #expect(plan.entries.first(where: { $0.id == failed.id })?.isRunning == false)
    }

    // MARK: - Source: where the files are

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/TunnelMenuWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appKitRoot = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
    private static let sidebarFile = appKitRoot.appendingPathComponent("SessionSidebar.swift")
    private static let sheetFile = appKitRoot.appendingPathComponent("TunnelProfilesSheet.swift")
    private static let managerFile = appKitRoot.appendingPathComponent("TunnelManager.swift")
    private static let sheetsFile = appKitRoot.appendingPathComponent("ContentView+Sheets.swift")
    private static let contentViewFile = appKitRoot.appendingPathComponent("ContentView.swift")

    /// The submenu's own statement, anchored on the one line that decides
    /// whether it is drawn at all. Carries no string literal, so it is found
    /// in the strict view and holds up in either.
    private static let submenuAnchor = "if case .shown(let tunnelEntries) = tunnelPlan"

    private static func text(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    /// The submenu's body in both views: code only, and code plus literals.
    /// One range, sliced twice — see this suite's header for why that is
    /// safe.
    private static func submenuBodies() throws -> (strict: String, withLiterals: String) {
        let raw = try text(of: sidebarFile)
        let strict = try SwiftSource.blankingCommentsAndStrings(raw)
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: submenuAnchor, in: strict)
        return (
            TransferQueueBarCancelGuardTests.slice(range, of: strict),
            TransferQueueBarCancelGuardTests.slice(
                range, of: try SwiftSource.blankingComments(raw))
        )
    }

    // MARK: - Source: the row draws what the plan says

    @Test func theRowAsksThePlanAndDecidesNothingItself() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(try Self.text(of: Self.sidebarFile))
        #expect(
            strict.contains("SessionRowTunnelMenuPlan.build("),
            "the session row no longer builds a tunnel menu plan — re-anchor this guard")

        let body = try Self.submenuBodies().strict
        #expect(body.count > 200, "the scanned submenu span is too small to be the submenu")

        // The negative, with the positive above it: the submenu itself must
        // read no fact about the session that the plan already read. A
        // `session.kind` or a `jump` test HERE would be a second, unmeasured
        // copy of the visibility rule — the exact shape this project keeps
        // paying for.
        for forbidden in ["session.kind", ".jump", "loginSetID"] {
            #expect(
                !body.contains(forbidden),
                "the submenu decides visibility itself (\"\(forbidden)\") instead of asking the plan")
        }
    }

    /// Every entry that carries a TITLE reads it from the catalogue. The one
    /// entry that does not is the per-profile row, whose label is the
    /// profile's own name — user data, which is never localized and never
    /// spelled here.
    @Test func everyTitledEntryReadsItsTitleFromTheCatalogue() throws {
        let lines = try Self.submenuBodies().withLiterals.components(separatedBy: "\n")
        let titled = lines.filter { $0.contains("Button(") || $0.contains("Menu(") }
        #expect(titled.count >= 4, "the submenu's titled entries are gone — re-anchor this guard")
        for line in titled {
            #expect(
                line.contains("L10n.string("),
                "a submenu entry carries a title that is not a catalogue lookup: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// Every `tunnel.*` key this task's three surfaces read, derived from
    /// their source rather than listed here — a list would be a second copy
    /// of the same names, and the one that goes stale.
    ///
    /// Resolution is asked through `L10n` itself, so this checks the lookup
    /// the running app performs. That the other three catalogues declare the
    /// same keys is `LocalizationParityTests`' standing job.
    @Test func everyTunnelKeyResolvesInTheCatalogue() throws {
        var keys: Set<String> = []
        for file in [Self.sidebarFile, Self.sheetFile,
                     Self.appKitRoot.appendingPathComponent("TunnelHostKeyPrompt.swift")] {
            let source = try SwiftSource.blankingComments(try Self.text(of: file))
            // `\s*` after the parenthesis, and it is load-bearing: a
            // `L10n.string(` whose key sits on the NEXT line is how six of
            // these keys are written (the call wraps), and a pattern
            // demanding the quote immediately after the parenthesis found 42
            // of the 48 while reporting success — counted 2026-09-06 against
            // the catalogue.
            for match in source.ranges(of: try Regex(#"L10n\.string\(\s*"(tunnel\.[^"]+)""#)) {
                let call = String(source[match])
                guard let start = call.range(of: "\"") else { continue }
                let rest = call[start.upperBound...]
                guard let end = rest.range(of: "\"") else { continue }
                keys.insert(String(rest[..<end.lowerBound]))
            }
        }
        // 48 as counted on 2026-09-06 — every `tunnel.*` key in the
        // catalogue. The floor is lower than the count so that adding one
        // key is not a test edit, and high enough that a pattern which
        // silently stopped matching most of them (see above) fails here.
        #expect(keys.count >= 45, "found \(keys.count) tunnel keys — re-anchor this guard")
        for key in keys.sorted() {
            #expect(
                L10n.string(key, "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
                "the catalogue answers nothing for \"\(key)\"")
        }
    }

    /// The two effects the ROW holds are fired in exactly two places, and
    /// both are inside the submenu.
    ///
    /// This is the property `SessionRowActivationWiringTests`' Guard K holds
    /// for the sidebar's other three host-reaching effects by a different
    /// route: it forbids the ROW to declare one at all, because those three
    /// act on the session the row already names and can therefore be
    /// forwarded as an input. A forwarding entry cannot — it acts on ONE
    /// PROFILE of that session, which no `SessionRowInput` carries — so the
    /// row holds the effects, and what is guarded instead is where they are
    /// fired: any other function of `SessionSidebar.swift` (a tap handler, a
    /// hover, `activate`) firing one would be a dial reachable by a gesture.
    ///
    /// Positive first: each firing exists exactly once. A scan for
    /// "nowhere outside the submenu" over a file that fires neither would
    /// pass while the feature was gone.
    @Test func aForwardingIsStartedOnlyFromInsideTheSubmenu() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(try Self.text(of: Self.sidebarFile))
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: Self.submenuAnchor, in: strict)

        for needle in ["SessionRowTunnelActivation.start(", "SessionRowTunnelActivation.startAll("] {
            let positions = Self.positions(of: needle, in: strict)
            #expect(
                positions.count == 1,
                "`\(needle)` is fired \(positions.count) time(s) in SessionSidebar.swift, expected 1")
            for position in positions {
                #expect(
                    range.contains(position),
                    """
                    `\(needle)` is fired outside the "Port forwarding" submenu — a forwarding \
                    dials the user's host, and a firing anywhere else in this file is one a \
                    gesture can reach.
                    """)
            }
        }
    }

    /// Every character index at which `needle` starts, over the whole text.
    private static func positions(of needle: String, in text: String) -> [Int] {
        text.ranges(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }

    // MARK: - Source: only the manager starts a runner

    /// One place in the App layer calls a runner's `start(decider:)`, and it
    /// is the manager. Anywhere else would be a tunnel nothing tracks: no
    /// mirrored state, no entry in `runningCount`, and nothing for the quit
    /// chain's `stopAll()` to stop.
    ///
    /// Positive: the manager IS in the set. A scan that found nothing at all
    /// would otherwise report success over an empty answer.
    @Test func theManagerIsTheOnlyCallerOfARunnersStart() throws {
        // `.start(decider:` — with the leading dot, which is the CALL and
        // not the declaration (fix round 1). The needle without it was also
        // matched by `func start(decider: HostKeyDecider) async` in the
        // protocol at the top of `TunnelManager.swift`, so the positive
        // below was satisfied by the declaration alone: deleting the real
        // call would have left this guard green.
        let callers = try Self.appKitFiles().filter { file in
            try SwiftSource.blankingCommentsAndStrings(try Self.text(of: file))
                .contains(".start(decider:")
        }.map(\.lastPathComponent).sorted()

        #expect(
            callers.contains("TunnelManager.swift"),
            "nothing in the App layer starts a runner any more — re-anchor this guard")
        #expect(
            callers == ["TunnelManager.swift"],
            "a runner is started outside TunnelManager: \(callers)")
    }

    /// The dial the manager builds resolves its secret through the APP's
    /// chain — the wiring, not the function.
    ///
    /// `TunnelSecretSourcesTests` measures what `TunnelSecretSources.chain`
    /// answers; nothing measured that `liveRunner` calls it, so putting
    /// `secretSources(for:passwordCommand:)` back at the dial left the whole
    /// suite green (measured 2026-09-06). The negative is the half that
    /// matters — the CLI chain must not come back — and the positive beside
    /// it names what has to be there instead.
    ///
    /// The span is the `connect` closure, anchored on the line that builds
    /// the runner. `liveRunner` itself cannot be the anchor: its parameter
    /// list carries a default closure argument, so a brace-balanced read
    /// from the first `{` after the declaration scans that default value.
    @Test func theDialResolvesItsSecretThroughTheAppsOwnChain() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(try Self.text(of: Self.managerFile))
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: "return TunnelRunner(profile: profile, connect:", in: strict)
        let body = TransferQueueBarCancelGuardTests.slice(range, of: strict)

        #expect(
            body.contains("TunnelConnection.connect("),
            "the scanned span is not the runner's dial — re-anchor this guard")
        #expect(
            body.contains("TunnelSecretSources.chain("),
            "the forwarding's dial no longer resolves its secret through the App's own chain")
        #expect(
            !body.contains("secretSources(for:"),
            """
            the forwarding's dial is back on the command line's secret chain: it reads \
            MACSCP_PASSWORD ahead of the keychain and cannot reach a managed key's own \
            passphrase slot at all.
            """)
    }

    /// The sheet asks the manager and dials nothing itself — the same
    /// boundary, one surface further out. A sheet that connected for itself
    /// would answer the TOFU question in a place no test reaches, and would
    /// hold a connection no `stopAll()` knows about.
    ///
    /// The negative reads the strict view (a comment ABOUT `connect(` must
    /// not satisfy it), and the two positives beside it assert that the file
    /// being scanned is one that acts at all.
    @Test func theSheetAsksTheManagerAndDialsNothing() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(try Self.text(of: Self.sheetFile))
        #expect(strict.contains("manager.start("), "the sheet no longer starts anything")
        #expect(strict.contains("manager.stop("), "the sheet no longer stops anything")
        for forbidden in ["TunnelConnection.connect(", "CitadelFileSystem.connect(", "TunnelRunner("] {
            #expect(
                !strict.contains(forbidden),
                "the profile sheet dials for itself (\"\(forbidden)\")")
        }
    }

    // MARK: - One sheet at a time

    /// The window presents ONE forwarding sheet, and which one is a value.
    ///
    /// Round 1 attached two `.sheet` modifiers to the same view: macOS
    /// SwiftUI presents one per presenter, so the second never appeared —
    /// and the one that never appeared was the host-key question, whose
    /// dial then parked on a continuation nobody could resolve.
    @Test func theSheetPlanNeverPresentsTwoThingsAtOnce() {
        let session = Self.sshSession()
        let candidate = HostKeyCandidate(
            host: "example.invalid", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "")

        #expect(TunnelSheetPlan.item(profilesSession: nil, hostKeyCandidate: nil) == nil)
        #expect(
            TunnelSheetPlan.item(profilesSession: session, hostKeyCandidate: nil)
                == .profiles(session))
        #expect(
            TunnelSheetPlan.item(profilesSession: nil, hostKeyCandidate: candidate)
                == .hostKey(candidate))
        // The precedence that makes the split work: while the profile sheet
        // is up it keeps the window, and the question is drawn inside it.
        #expect(
            TunnelSheetPlan.item(profilesSession: session, hostKeyCandidate: candidate)
                == .profiles(session),
            "a host-key question took the window away from the open profile sheet")
    }

    /// Distinct ids, so `.sheet(item:)` re-presents when the thing on screen
    /// actually changes — and a candidate's id carries its full identity
    /// (host, port, key type, public key), never a secret.
    @Test func theSheetItemsAreIdentifiedApart() {
        let session = Self.sshSession()
        let first = HostKeyCandidate(
            host: "one.invalid", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "AAAA")
        let second = HostKeyCandidate(
            host: "one.invalid", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "BBBB")
        let ids = [
            TunnelSheetItem.profiles(session).id,
            TunnelSheetItem.hostKey(first).id,
            TunnelSheetItem.hostKey(second).id,
        ]
        #expect(Set(ids).count == 3)
    }

    /// The window's side of it, read from source: exactly one `.sheet` shows
    /// either, and both live inside it.
    @Test func theWindowPresentsBothForwardingSheetsThroughOnePresentation() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(
            try Self.text(of: Self.sheetsFile))
        for needle in ["TunnelProfilesSheet(", "TunnelHostKeyPromptView("] {
            #expect(
                Self.positions(of: needle, in: strict).count == 1,
                "`\(needle)` is presented \(Self.positions(of: needle, in: strict).count) times by the window, expected 1")
        }
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: ".sheet(item: tunnelSheetBinding)", in: strict)
        for needle in ["TunnelProfilesSheet(", "TunnelHostKeyPromptView("] {
            for position in Self.positions(of: needle, in: strict) {
                #expect(
                    range.contains(position),
                    """
                    `\(needle)` is presented by a second `.sheet` on the window — macOS \
                    SwiftUI presents one sheet per presenter, so one of them never appears.
                    """)
            }
        }
    }

    /// The sheet's side: while the profile sheet has the window, it is the
    /// one that draws the question — nested inside itself, which is an
    /// ordinary presentation and not a second sheet on one presenter.
    @Test func theProfileSheetDrawsTheQuestionWhileItIsUp() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(try Self.text(of: Self.sheetFile))
        #expect(
            Self.positions(of: "TunnelHostKeyPromptView(", in: strict).count == 1,
            "the profile sheet no longer draws the host-key question it can raise")
        #expect(
            strict.contains("bridge.resolve(trust: false)"),
            "dismissing the profile sheet's question no longer refuses it — the dial would park")
    }

    // MARK: - A deleted session

    /// The App-level half of the Task 1 hand-off: the window registers the
    /// MANAGER's observer (which stops the runners) on the session list it
    /// builds. The Core half — that `delete(_:)` tells its observers at all
    /// — is `TunnelStoreTests`'.
    @Test func theWindowRegistersTheManagersDeletionObserver() throws {
        let strict = try SwiftSource.blankingCommentsAndStrings(
            try Self.text(of: Self.contentViewFile))
        #expect(
            strict.contains("SessionListViewModel("),
            "ContentView no longer builds a session list — re-anchor this guard")
        #expect(
            strict.contains("addDeletionObserver(TunnelManager.shared.deletionObserver)"),
            """
            the window no longer registers the tunnel manager's deletion observer: a deleted \
            session would keep its forwardings running, with no menu left to stop them from.
            """)
    }

    /// Every `.swift` file of the App target, found rather than listed.
    private static func appKitFiles() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: appKitRoot, includingPropertiesForKeys: nil)
        let nested = try contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap {
                try FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: nil)
            }
        return (contents + nested).filter { $0.pathExtension == "swift" }
    }
}
