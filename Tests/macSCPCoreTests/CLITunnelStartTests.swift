import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

/// The two pure pieces `macscp-cli tunnels start` is made of: the line it
/// prints for one published `TunnelState`, and the exit it leaves with when
/// the run ends.
///
/// Both live in Core rather than in the command's own file for the reason
/// `CLIErrorMapping` and `DiagnoseRendering` do: the CLI is an
/// `executableTarget` with no test target of its own, so anything that
/// decides what a user sees has to sit where a test can call it. What stays
/// in `TunnelStartCommand.swift` is the wiring — the dial, the runner, the
/// signal source, the process exit.
@Suite("CLI tunnels start rendering")
struct CLITunnelStartRenderingTests {
    /// Every case of `TunnelState`, in the order the enum declares them, so
    /// the tables below are read against a list that a new case makes
    /// visibly short rather than silently incomplete.
    ///
    /// A `reconnecting` attempt of 2 and an `active` count of 0 are values
    /// the runner really publishes (a forward is `active(0)` the moment it
    /// binds); the deltas get their own cases below.
    private static let everyState: [TunnelState] = [
        .stopped,
        .connecting,
        .active(connections: 0),
        .reconnecting(attempt: 2),
        .failed(.connectionFailed),
        .needsConfirmation,
    ]

    // MARK: - The text line

    @Test(arguments: [
        (TunnelState.stopped, "stopped"),
        (TunnelState.connecting, "connecting"),
        (TunnelState.active(connections: 0), "active"),
        (TunnelState.active(connections: 3), "active connections=3"),
        (
            TunnelState.active(connections: 0, failedConnections: 2, lastFailure: .channelOpenFailed),
            "active failed=2"
        ),
        (
            TunnelState.active(connections: 1, failedConnections: 1, lastFailure: .connectFailed),
            "active connections=1 failed=1"
        ),
        (TunnelState.reconnecting(attempt: 1), "reconnecting attempt=1"),
        (TunnelState.reconnecting(attempt: 4), "reconnecting attempt=4"),
        (TunnelState.failed(.connectionFailed), "failed"),
        (TunnelState.needsConfirmation, "needs confirmation"),
    ])
    func theTextLineNamesTheStateAndItsNumbers(state: TunnelState, expected: String) {
        #expect(TunnelStateLine.render(state, port: nil, json: false) == expected)
    }

    /// The bound port is news for a remote forward — the SERVER's port,
    /// which the profile may have asked for as 0 — and for any forward that
    /// asked for an ephemeral one. It is rendered whenever the runtime
    /// reports a port, and never invented here.
    @Test(arguments: [
        (TunnelState.active(connections: 0), "active port=2222"),
        (TunnelState.active(connections: 2), "active port=2222 connections=2"),
    ])
    func theBoundPortIsPartOfTheActiveLine(state: TunnelState, expected: String) {
        #expect(TunnelStateLine.render(state, port: 2222, json: false) == expected)
    }

    /// A port is a fact about a live forward, so it never appears on a state
    /// that has none — even when the caller hands one in.
    @Test func onlyTheActiveLineCarriesAPort() {
        for state in Self.everyState {
            if case .active = state { continue }
            let line = TunnelStateLine.render(state, port: 2222, json: false)
            #expect(!line.contains("port="), "\(line) carries a port it cannot have")
        }
    }

    // MARK: - The JSON line

    /// One object per line — the shape `tunnels list --json` already writes.
    /// DECODED rather than compared as text, so the assertion is about the
    /// fields and their names and not about the order a serializer put them
    /// in.
    @Test(arguments: [
        (TunnelState.stopped, TunnelStateJSONLine(state: "stopped")),
        (TunnelState.connecting, TunnelStateJSONLine(state: "connecting")),
        (
            TunnelState.active(connections: 0),
            TunnelStateJSONLine(state: "active", connections: 0)
        ),
        (
            TunnelState.reconnecting(attempt: 3),
            TunnelStateJSONLine(state: "reconnecting", attempt: 3)
        ),
        (
            TunnelState.failed(.connectionFailed),
            TunnelStateJSONLine(
                state: "failed", reason: "the connection failed", reasonIsGeneric: true)
        ),
        (TunnelState.needsConfirmation, TunnelStateJSONLine(state: "needsConfirmation")),
    ])
    func theJSONLineCarriesTheStateAndItsPayload(
        state: TunnelState, expected: TunnelStateJSONLine
    ) throws {
        let line = TunnelStateLine.render(state, port: nil, json: true)
        #expect(try TunnelStateJSONLine.decode(line) == expected)
    }

    /// The runner's own sentence, where it has one, is the `reason` — the
    /// log's text, fuller than the kind's summary for a free-text failure —
    /// and `reasonIsGeneric` says so: `false`, since the runner supplied it
    /// and the line did not fall back to the kind's own.
    @Test func theJSONReasonIsTheRunnersSentenceWhenGiven() throws {
        let line = TunnelStateLine.render(
            .failed(.bindFailed), port: nil, reason: "the server did not answer", json: true)
        #expect(
            try TunnelStateJSONLine.decode(line)
                == TunnelStateJSONLine(
                    state: "failed", reason: "the server did not answer", reasonIsGeneric: false))
    }

    /// No reason from the runner: the line falls back to the kind's own
    /// sentence and marks it generic, so a script reading `reason` alone
    /// cannot mistake it for detail the runner actually had.
    @Test func theJSONReasonIsGenericWhenNoneIsGiven() throws {
        let line = TunnelStateLine.render(.failed(.connectionFailed), port: nil, json: true)
        #expect(
            try TunnelStateJSONLine.decode(line)
                == TunnelStateJSONLine(
                    state: "failed", reason: "the connection failed", reasonIsGeneric: true))
    }

    /// A reason the runner gave is specific even when its text equals the
    /// kind's own sentence word for word — `TunnelRunner`'s
    /// loss-without-reconnects path writes exactly this
    /// (`lastFailureReason = kind.sentence`, `TunnelRunner.swift`'s `.lost`
    /// arm). The flag answers whether the line FELL BACK to the kind's
    /// sentence because the runner held none, not whether two strings
    /// happen to match (coordinator ruling, 2026-09-18, Task 3 fix round 1;
    /// until then this test pinned `true`).
    @Test func aRunnerReasonIsSpecificEvenWhenItEqualsTheKindsSentence() throws {
        let line = TunnelStateLine.render(
            .failed(.connectionLost), port: nil, reason: "connection lost", json: true)
        #expect(
            try TunnelStateJSONLine.decode(line)
                == TunnelStateJSONLine(
                    state: "failed", reason: "connection lost", reasonIsGeneric: false))
    }

    /// The three local-bind causes with a case of their own, rendered as
    /// the runner renders them: the reason is `DialSupport.reason(for:)` of
    /// the failure (`TunnelRunner.swift`'s `.failed` arm), which for these
    /// three IS the kind's sentence — and names the port, or the address and
    /// the errno. A runner reason, so `false`.
    @Test(arguments: [
        TunnelFailure.bindAddressUnavailable(address: "192.0.2.1"),
        .bindPermissionDenied(port: 80),
        .portInUse(port: 8080),
    ])
    func aLocalBindCauseWithARunnerReasonIsNotGeneric(_ failure: TunnelFailure) throws {
        let kind = DialSupport.failureKind(for: failure)
        let reason = DialSupport.reason(for: failure)
        let line = TunnelStateLine.render(.failed(kind), port: nil, reason: reason, json: true)
        #expect(
            try TunnelStateJSONLine.decode(line)
                == TunnelStateJSONLine(state: "failed", reason: reason, reasonIsGeneric: false))
    }

    /// The `failed` object's key set, pinned: `state`, `reason` and
    /// `reasonIsGeneric`, nothing else — a script that reads any other key
    /// off it has a wrong assumption, not a missing feature.
    @Test func theFailedObjectsKeySetIsPinned() throws {
        let line = TunnelStateLine.render(.failed(.connectionFailed), port: nil, json: true)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(object?.isEmpty == false, "decoded no object at all")
        #expect(Set(object?.keys.map { $0 } ?? []) == ["state", "reason", "reasonIsGeneric"])
    }

    /// A connection the forward could not carry is news the runner
    /// publishes as a new `active` state, so the line it prints says what
    /// changed — otherwise a failure would print the previous line again.
    /// The kind is not rendered: `failed` on stderr is where a sentence goes,
    /// and the tunnel has not failed.
    @Test func theJSONActiveLineCarriesTheFailedCount() throws {
        let line = TunnelStateLine.render(
            .active(connections: 0, failedConnections: 3, lastFailure: .pumpFailed),
            port: 2222, json: true)
        #expect(
            try TunnelStateJSONLine.decode(line)
                == TunnelStateJSONLine(
                    state: "active", connections: 0, port: 2222, failedConnections: 3,
                    degraded: true))
    }

    /// The mark a script reads for "this forwarding is not carrying
    /// anything any more" (maintainer answer, 2026-09-19): an ADDED key,
    /// written only once the last three connections in a row failed, and
    /// left out below that — the same shape `failedConnections` has.
    @Test func theJSONActiveLineMarksAForwardingThatKeepsFailing() throws {
        let belowTheThreshold = TunnelStateLine.render(
            .active(connections: 0, failedConnections: TunnelState.failuresBeforeDegraded - 1,
                lastFailure: .channelOpenFailed),
            port: 2222, json: true)
        #expect(try TunnelStateJSONLine.decode(belowTheThreshold).degraded == nil)

        let atTheThreshold = TunnelStateLine.render(
            .active(connections: 0, failedConnections: TunnelState.failuresBeforeDegraded,
                lastFailure: .channelOpenFailed),
            port: 2222, json: true)
        #expect(try TunnelStateJSONLine.decode(atTheThreshold).degraded == true)
    }

    /// The text form carries the same fact as the JSON one — the two are
    /// one rendering read twice, so a person watching `tunnels start` sees
    /// what a `jq` consumer switches on.
    @Test func theTextActiveLineMarksAForwardingThatKeepsFailing() {
        let belowTheThreshold = TunnelState.active(
            connections: 0, failedConnections: TunnelState.failuresBeforeDegraded - 1,
            lastFailure: .channelOpenFailed)
        #expect(!TunnelStateLine.render(belowTheThreshold, port: nil, json: false).contains("degraded"))

        let atTheThreshold = TunnelState.active(
            connections: 1, failedConnections: TunnelState.failuresBeforeDegraded,
            lastFailure: .channelOpenFailed)
        #expect(
            TunnelStateLine.render(atTheThreshold, port: nil, json: false)
                == "active connections=1 failed=\(TunnelState.failuresBeforeDegraded) degraded")
    }

    @Test func theJSONActiveLineCarriesTheBoundPort() throws {
        let line = TunnelStateLine.render(.active(connections: 0), port: 2222, json: true)
        #expect(
            try TunnelStateJSONLine.decode(line)
                == TunnelStateJSONLine(state: "active", connections: 0, port: 2222))
    }

    /// A `jq` consumer switches on `state`, so its spelling is the Swift
    /// case name — the same rule `DiagnoseRendering.outcomeKey` follows, and
    /// the reason the JSON says `needsConfirmation` where the column says
    /// `needs confirmation`.
    @Test func everyStateRendersOneDecodableObject() throws {
        for state in Self.everyState {
            let decoded = try TunnelStateJSONLine.decode(
                TunnelStateLine.render(state, port: nil, json: true))
            #expect(!decoded.state.isEmpty, "\(state) rendered no state name")
        }
    }
}

/// One `--json` line of `tunnels start`, decoded. A `Decodable` type rather
/// than a dictionary walked with `as?`, for the reason
/// `CLIListedItem` gives: a renamed key is a decode error naming the key,
/// where a dictionary walk silently answers `nil`.
struct TunnelStateJSONLine: Decodable, Equatable {
    var state: String
    var connections: Int?
    var attempt: Int?
    var port: Int?
    var reason: String?
    var reasonIsGeneric: Bool?
    var failedConnections: Int?
    var degraded: Bool?

    init(
        state: String, connections: Int? = nil, attempt: Int? = nil, port: Int? = nil,
        reason: String? = nil, reasonIsGeneric: Bool? = nil, failedConnections: Int? = nil,
        degraded: Bool? = nil
    ) {
        self.state = state
        self.connections = connections
        self.attempt = attempt
        self.port = port
        self.reason = reason
        self.reasonIsGeneric = reasonIsGeneric
        self.failedConnections = failedConnections
        self.degraded = degraded
    }

    static func decode(_ line: String) throws -> TunnelStateJSONLine {
        try JSONDecoder().decode(TunnelStateJSONLine.self, from: Data(line.utf8))
    }
}

/// What the process leaves with, and what it says on the way out.
@Suite("CLI tunnels start exit")
struct CLITunnelStartExitTests {
    /// The states that end the run, and the states that do not. `nil` is
    /// "keep printing" — the loop's own continue signal.
    @Test(arguments: [
        (TunnelState.stopped, CLIExitCode.success),
        (TunnelState.failed(.connectionFailed), CLIExitCode.connection),
        (TunnelState.needsConfirmation, CLIExitCode.hostKeyUnknown),
    ])
    func aTerminalStateHasItsOwnExitCode(state: TunnelState, expected: CLIExitCode) {
        #expect(TunnelExit.code(for: state) == expected)
    }

    @Test(arguments: [
        TunnelState.connecting,
        TunnelState.active(connections: 0),
        TunnelState.active(connections: 7),
        TunnelState.reconnecting(attempt: 1),
    ])
    func aRunningStateEndsNothing(state: TunnelState) {
        #expect(TunnelExit.code(for: state) == nil)
    }

    /// The dial's own error is what tells 10 from 11 and 12 from 13: the
    /// state says only that a person is needed, or that the run is over.
    /// `CLIErrorMapping.exitCode(for:)` is what produced these codes at the
    /// call site — this is the refinement, not a second mapping.
    @Test(arguments: [
        // A session with no stored secret: `needsConfirmation`, but the
        // work item is a credential, not a host key.
        (TunnelState.needsConfirmation, CLIExitCode.auth, CLIExitCode.auth),
        // The unknown key it usually is.
        (
            TunnelState.needsConfirmation, CLIExitCode.hostKeyUnknown,
            CLIExitCode.hostKeyUnknown
        ),
        // A MISMATCH is never a confirmation — it reaches `failed`, and it
        // keeps its own code there.
        (
            TunnelState.failed(.hostKeyMismatch(host: "server.test")), CLIExitCode.hostKeyMismatch,
            CLIExitCode.hostKeyMismatch
        ),
        (
            TunnelState.failed(.connectionFailed), CLIExitCode.connection,
            CLIExitCode.connection
        ),
    ])
    func theDialsOwnErrorRefinesTheCode(
        state: TunnelState, dialFailure: CLIExitCode, expected: CLIExitCode
    ) {
        #expect(TunnelExit.code(for: state, dialFailure: dialFailure) == expected)
    }

    /// A code the dial's error mapped to that is not one of the four this
    /// command can mean is ignored, not passed through: `tunnels start`
    /// answers with the M20 set for a forwarding, and a `remote` (14) or
    /// `conflict` (15) arriving from a mapping written for file operations
    /// would tell a script something about a path this command never
    /// touched.
    @Test(arguments: [CLIExitCode.remote, .conflict, .diagnosis, .usage, .success])
    func aCodeThisCommandCannotMeanLeavesTheStateAnswering(dialFailure: CLIExitCode) {
        #expect(
            TunnelExit.code(for: .failed(.unknown), dialFailure: dialFailure)
                == .connection)
        #expect(
            TunnelExit.code(for: .needsConfirmation, dialFailure: dialFailure)
                == .hostKeyUnknown)
    }

    /// A clean stop is a clean stop: SIGINT arrives, `stop()` publishes
    /// `.stopped`, and whatever a dial failed with earlier — a retry that
    /// never came back, say — does not turn a requested teardown into a
    /// failure.
    @Test func aStopIsSuccessfulWhateverTheDialFailedWithBefore() {
        #expect(TunnelExit.code(for: .stopped, dialFailure: .connection) == .success)
        #expect(TunnelExit.code(for: .stopped, dialFailure: .hostKeyMismatch) == .success)
    }

    @Test func aRunningStateEndsNothingEvenWithADialFailureOnFile() {
        #expect(TunnelExit.code(for: .connecting, dialFailure: .connection) == nil)
        #expect(TunnelExit.code(for: .reconnecting(attempt: 2), dialFailure: .connection) == nil)
    }

    // MARK: - The sentence on stderr

    @Test func aFailureSaysWhatTheRunnerMapped() {
        #expect(
            TunnelExit.note(for: .failed(.connectionFailed), reason: "connection refused")
                == "Error: connection refused")
    }

    /// Without the runner's sentence, the kind's own English.
    @Test func aFailureWithoutTheRunnersSentenceSaysTheKindsOwn() {
        #expect(
            TunnelExit.note(for: .failed(.portInUse(port: 8080)))
                == "Error: port 8080 is already in use")
    }

    /// The runner already mapped the very error the dial threw
    /// (`DialSupport.reason(for:)`), and that sentence is the one its log
    /// line carries — so a `failed` says the same thing on stderr as in the
    /// diagnostic log, whatever the dial's own message was.
    @Test func aFailureKeepsItsOwnReasonEvenWhenTheDialSuppliedAMessage() {
        #expect(
            TunnelExit.note(
                for: .failed(.connectionFailed), dialMessage: "Error: other",
                reason: "connection refused")
                == "Error: connection refused")
    }

    @Test func anUnexplainedConfirmationNamesTheHostKeyAndTheFlag() {
        #expect(
            TunnelExit.note(for: .needsConfirmation)
                == "Error: host key unknown; rerun with --accept-new")
    }

    @Test func aConfirmationPrefersTheDialsOwnMessage() {
        let message = "Error: no secret available (checked --password-command, "
            + "the environment, and the keychain)"
        #expect(TunnelExit.note(for: .needsConfirmation, dialMessage: message) == message)
    }

    @Test(arguments: [
        TunnelState.stopped, .connecting, .active(connections: 0), .reconnecting(attempt: 1),
    ])
    func nothingIsSaidOnStderrForAStateThatIsNotAFailure(state: TunnelState) {
        #expect(TunnelExit.note(for: state) == nil)
        #expect(TunnelExit.note(for: state, dialMessage: "Error: ignored") == nil)
    }
}

/// `tunnels start` is the second command in this tool that decides a host
/// key, and it must decide it the way the first one does.
///
/// A source-text scan, like this project's other wiring guards, with two
/// differences worth stating.
///
/// The function it requires is NOT spelled here. It is walked out of
/// `LsCommand.swift` — the calls that command makes, the calls those make,
/// until a function is reached whose declaration returns a `HostKeyDecider`.
/// So renaming that function, or routing `ls` through a different one, moves
/// this guard with it instead of leaving it pinned to a name nothing uses
/// any more (CLAUDE.md, "Guards that name what they watch", rule 2).
///
/// And the scan is SCOPED to the body of the function that composes the
/// dial, found by the type it constructs (`TunnelRunner(`) rather than by
/// name. A whole-file scan is what round 1 shipped, and it was satisfied by
/// the file's own doc comment naming the builder in prose — CLAUDE.md,
/// "Source-scanning guards read comments too", exactly. Inside that body the
/// positive is the argument itself (`decider: <derived name>(`) and the
/// negative is every spelling that would answer the question elsewhere.
@Suite("CLI tunnels start decider guard")
struct CLITunnelStartDeciderGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let cliDirectory = repoRoot.appendingPathComponent("Sources/MacSCPCLI")
    private static let lsCommandFile = cliDirectory.appendingPathComponent("LsCommand.swift")
    private static let startCommandFile = cliDirectory
        .appendingPathComponent("TunnelStartCommand.swift")

    /// Every way a decider could be produced without asking the shared
    /// builder: the two constructions, the two spellings of its one factory,
    /// and the two ready-made deciders Core vends. Any of them inside the
    /// body that composes the dial means the TOFU question is answered
    /// there, past `--accept-new`/`--non-interactive`.
    ///
    /// `.refusing` is the one round 1 could not have caught: it constructs
    /// nothing and reads as a perfectly ordinary argument. The list holds
    /// only spellings a file in this target can WRITE: `HostKeyDecider`'s
    /// `init` is private, so `HostKeyDecider(` and `HostKeyDecider.init(`
    /// would not compile here and stay in the list only as the loud form
    /// of that fact; `.accepting` is not a member of the type and was
    /// dropped (round-1 re-review, 2026-09-06). Whitespace is stripped
    /// before matching, so `.asking  {` and `.asking (` are the same
    /// spelling as their compact forms.
    private static let deciderSpellings = [
        "HostKeyDecider(", "HostKeyDecider.init(", ".asking{", ".asking(",
        ".refusing",
    ]

    private static func spellingsFound(in source: String) -> [String] {
        let compact = source.filter { !$0.isWhitespace }
        return deciderSpellings.filter { compact.contains($0) }
    }

    /// The walk out of `LsCommand.swift` and the single decider builder it
    /// reaches.
    private static func derivedBuilder() throws -> (walk: CLISourceWalk, name: String) {
        var walk = try CLISourceWalk(directory: cliDirectory)
        let builders = try walk.deciderBuilders(reachableFrom: lsCommandFile)
        let name = try #require(builders.sorted().first, """
            the walk out of LsCommand.swift reaches no function returning a \
            HostKeyDecider; this guard has no name to derive.
            """)
        #expect(builders.count == 1, """
            the walk reaches \(builders.sorted()) — this guard needs exactly \
            one builder to derive the name from.
            """)
        return (walk, name)
    }

    /// The body of the one function in `TunnelStartCommand.swift` that
    /// builds the runner — the function that dials, found by what it
    /// constructs rather than by its name.
    private static func composingBody() throws -> (source: String, body: String) {
        let source = try SourceCorpus.text(of: startCommandFile)
        let composing = CLISourceWalk.functionSlices(in: source)
            .filter { $0.body.contains("TunnelRunner(") }
        #expect(composing.count == 1, """
            \(composing.count) functions in TunnelStartCommand.swift construct a \
            TunnelRunner( — this guard needs exactly one body to scan.
            """)
        let body = try #require(composing.first?.body, """
            no function in TunnelStartCommand.swift constructs a TunnelRunner( — \
            the file is not the implementation this guard thinks it is.
            """)
        #expect(body.count < source.count, "the slice swallowed the whole file")
        return (source, body)
    }

    // MARK: - Positive: the walk lands on a real decider builder

    @Test func theWalkFromLsReachesExactlyOneDeciderBuilder() throws {
        let derived = try Self.derivedBuilder()
        #expect(derived.walk.visitedCount > 1, "the walk never left LsCommand.swift")
    }

    @Test func thatBuilderIsTheOneThatActuallyConstructsADecider() throws {
        let derived = try Self.derivedBuilder()
        let body = try #require(
            derived.walk.body(of: derived.name), "no body found for \(derived.name)")
        #expect(!Self.spellingsFound(in: body).isEmpty, """
            \(derived.name) returns a HostKeyDecider without naming one — the \
            walk landed on a forwarder, so the negative check below is \
            watching the wrong function.
            """)
    }

    /// The positive: the decider handed to the run is the derived builder's
    /// own return value, at the argument itself.
    ///
    /// Anchored on `decider: <name>(` rather than on `start(decider: <name>(`
    /// because the `start(decider:)` call moved into Core with the loop
    /// (`TunnelForegroundRun.drive`): the command's remaining job is to
    /// COMPOSE, and the decider is one of the arguments it composes with.
    /// The anchor is therefore where the choice is actually made.
    @Test func theComposedRunIsHandedTheDerivedBuildersDecider() throws {
        #expect(FileManager.default.fileExists(atPath: Self.startCommandFile.path))
        let derived = try Self.derivedBuilder()
        let scanned = try Self.composingBody()
        #expect(scanned.body.contains("decider: \(derived.name)("), """
            the function that builds the TunnelRunner does not pass \
            decider: \(derived.name)( — the host-key decision has to be made \
            by the same function ls makes it with, not by a second one.
            """)
    }

    // MARK: - Negative: it answers the question nowhere else

    @Test func theComposingBodyNamesNoDeciderOfItsOwn() throws {
        let scanned = try Self.composingBody()
        let found = Self.spellingsFound(in: scanned.body)
        #expect(found.isEmpty, """
            the function that builds the TunnelRunner names \(found) — a \
            decider chosen there answers the TOFU question with its own \
            policy instead of the one --accept-new/--non-interactive select.
            """)
    }

    @Test(arguments: [
        "let decider = HostKeyDecider(alwaysAccepting: true)",
        "let decider = HostKeyDecider .init(alwaysAccepting: true)",
        "return .asking { _ in true }",
        "return .asking({ _ in true })",
        "await runner.start(decider: .refusing)",
        "let decider = HostKeyDecider.init(alwaysAccepting: true)",
    ])
    func theScannerFlagsEverySpellingOfAPlantedDecider(planted: String) {
        let fixture = """
            struct FixtureStart {
                static func hold() async {
                    let runner = TunnelRunner(profile: profile, connect: connect)
                    \(planted)
                }
            }
            """
        #expect(!Self.spellingsFound(in: fixture).isEmpty, """
            the scanner did not flag \(planted).
            """)
    }

    @Test func theScannerAcceptsAFixtureThatAsksForOne() {
        let fixture = """
            struct FixtureStart {
                static func hold() async {
                    let runner = TunnelRunner(profile: profile, connect: connect)
                    await drive(runner: runner, decider: makeSomeDecider(policy: policy))
                }
            }
            """
        #expect(Self.spellingsFound(in: fixture).isEmpty)
    }

    /// The slicer's own sensitivity: a second function in the same fixture
    /// must not be read as part of the first. Round 1's slicer ended a
    /// METHOD's body at the next declaration in column 0 — the closing brace
    /// of the type — so every method of a struct shared one slice, and
    /// scoping a scan to "the body that composes the dial" would have
    /// scanned every sibling method with it.
    @Test func theSlicerEndsAMethodAtItsOwnClosingBrace() {
        let fixture = """
            struct FixtureStart {
                static func hold() async {
                    let runner = TunnelRunner(profile: profile, connect: connect)
                }

                static func interrupts() -> AsyncStream<Void> {
                    .asking { _ in true }
                }
            }
            """
        let slices = CLISourceWalk.functionSlices(in: fixture)
        #expect(slices.map(\.name) == ["hold", "interrupts"])
        let composing = slices.filter { $0.body.contains("TunnelRunner(") }
        #expect(composing.count == 1)
        #expect(Self.spellingsFound(in: composing[0].body).isEmpty, """
            the slice of hold reaches into interrupts — a body-scoped scan \
            would be reading a sibling method.
            """)
    }
}

/// A call graph over the command-line target's own sources, built by text.
///
/// Deliberately crude — it knows about `func` declarations and about
/// identifiers followed by `(` — because what it is asked is crude: which
/// functions can be reached from one command's own file, and what one
/// function's body says. It is a test fixture, not a parser, and every
/// question put to it is checked for having found something at all.
struct CLISourceWalk {
    /// Function name → the text of its body.
    private var slices: [String: String] = [:]
    /// The `func` line of each function, so a return type can be read
    /// without finding the declaration again.
    private var declarations: [String: String] = [:]
    private(set) var visitedCount = 0

    init(directory: URL) throws {
        let files = try SourceCorpus.children(of: directory)
            .filter { $0.pathExtension == "swift" }
        guard !files.isEmpty else {
            throw CLISourceWalkError.noSources(directory.path(percentEncoded: false))
        }
        for file in files {
            let source = try SourceCorpus.text(of: file)
            for slice in Self.functionSlices(in: source) {
                slices[slice.name] = slice.body
                declarations[slice.name] = slice.declaration
            }
        }
    }

    func body(of name: String) -> String? { slices[name] }

    /// The functions reachable from `file` whose declaration returns a
    /// `HostKeyDecider`.
    mutating func deciderBuilders(reachableFrom file: URL) throws -> Set<String> {
        let source = try SourceCorpus.text(of: file)
        var frontier = Array(Self.calledNames(in: source))
        var seen = Set<String>()
        var builders = Set<String>()
        while let name = frontier.popLast() {
            guard seen.insert(name).inserted else { continue }
            guard let slice = slices[name] else { continue }
            visitedCount += 1
            if declarations[name]?.contains("-> HostKeyDecider") == true {
                builders.insert(name)
            }
            frontier.append(contentsOf: Self.calledNames(in: slice))
        }
        return builders
    }

    /// Every `<identifier>(` in `source` whose identifier starts lowercase.
    /// Type constructions are skipped by that rule and method calls are
    /// kept, which is harmless either way: a name with no `func` declaration
    /// in this target is simply not in `slices` and ends the branch.
    static func calledNames(in source: String) -> Set<String> {
        var names = Set<String>()
        var current = ""
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
                continue
            }
            if character == "(", !current.isEmpty, current.first?.isLowercase == true {
                names.insert(current)
            }
            current = ""
        }
        return names
    }

    /// One entry per `func` declaration: its name, its `func` line, and the
    /// text from that line to the end of its body.
    ///
    /// The end is found by INDENTATION: a body ends at the first line
    /// indented no deeper than the `func` keyword that begins something else
    /// — a closing brace, another declaration, a doc comment, an attribute.
    /// A top-level function therefore ends at its own `}` in column 0, and a
    /// method at its own `}` at the type's member indentation, so two
    /// methods of one type get two slices. (Round 1 ended every slice at
    /// column 0, which gave every method of a struct the same slice, running
    /// to the end of the type.)
    static func functionSlices(
        in source: String
    ) -> [(name: String, declaration: String, body: String)] {
        var found: [(name: String, declaration: String, body: String)] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let name = functionName(in: trimmed) else { continue }
            let indent = line.prefix { $0 == " " }.count
            var end = index + 1
            while end < lines.count, !endsABody(lines[end], deeperThan: indent) { end += 1 }
            found.append(
                (name, String(line), lines[index...min(end, lines.count - 1)]
                    .joined(separator: "\n")))
        }
        return found
    }

    /// Whether `line` is where a body indented under `indent` ends: a
    /// non-empty line at the same indentation or shallower that closes a
    /// brace or begins something new.
    private static func endsABody(_ line: Substring, deeperThan indent: Int) -> Bool {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= indent else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if functionName(in: trimmed) != nil { return true }
        for prefix in ["}", "struct ", "enum ", "extension ", "protocol ", "///", "@"] {
            if trimmed.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// The name declared by `trimmed`, or `nil` where it declares no
    /// function.
    ///
    /// The modifiers are read rather than assumed away: `static func hold`
    /// is a declaration and `let f = funcs(…)` is not, and a check for the
    /// bare prefix `func ` answers wrongly on both. Round 1 used that bare
    /// prefix and saw no `static` method in the tree at all — which is every
    /// method on `TunnelStartCommand`.
    private static let modifiers: Set<String> = [
        "public", "package", "open", "internal", "private", "fileprivate", "static", "class",
        "final", "mutating", "nonmutating", "nonisolated", "override", "required",
    ]

    private static func functionName(in trimmed: String) -> String? {
        guard let keyword = trimmed.range(of: "func ") else { return nil }
        let before = trimmed[..<keyword.lowerBound]
            .split(separator: " ").map(String.init)
        guard before.allSatisfy({ modifiers.contains($0) }) else { return nil }
        let name = trimmed[keyword.upperBound...]
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

enum CLISourceWalkError: Error {
    case noSources(String)
}
