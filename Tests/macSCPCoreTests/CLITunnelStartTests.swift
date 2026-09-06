import Foundation
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
        .failed(reason: "connection refused"),
        .needsConfirmation,
    ]

    // MARK: - The text line

    @Test(arguments: [
        (TunnelState.stopped, "stopped"),
        (TunnelState.connecting, "connecting"),
        (TunnelState.active(connections: 0), "active"),
        (TunnelState.active(connections: 3), "active connections=3"),
        (TunnelState.reconnecting(attempt: 1), "reconnecting attempt=1"),
        (TunnelState.reconnecting(attempt: 4), "reconnecting attempt=4"),
        (TunnelState.failed(reason: "connection refused"), "failed"),
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
            TunnelState.failed(reason: "connection refused"),
            TunnelStateJSONLine(state: "failed", reason: "connection refused")
        ),
        (TunnelState.needsConfirmation, TunnelStateJSONLine(state: "needsConfirmation")),
    ])
    func theJSONLineCarriesTheStateAndItsPayload(
        state: TunnelState, expected: TunnelStateJSONLine
    ) throws {
        let line = TunnelStateLine.render(state, port: nil, json: true)
        #expect(try TunnelStateJSONLine.decode(line) == expected)
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

    init(
        state: String, connections: Int? = nil, attempt: Int? = nil, port: Int? = nil,
        reason: String? = nil
    ) {
        self.state = state
        self.connections = connections
        self.attempt = attempt
        self.port = port
        self.reason = reason
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
        (TunnelState.failed(reason: "connection refused"), CLIExitCode.connection),
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
            TunnelState.failed(reason: "host key mismatch"), CLIExitCode.hostKeyMismatch,
            CLIExitCode.hostKeyMismatch
        ),
        (
            TunnelState.failed(reason: "connection refused"), CLIExitCode.connection,
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
            TunnelExit.code(for: .failed(reason: "something else"), dialFailure: dialFailure)
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
            TunnelExit.note(for: .failed(reason: "connection refused"))
                == "Error: connection refused")
    }

    /// The runner already mapped the very error the dial threw
    /// (`DialSupport.reason(for:)`), and that sentence is the one its log
    /// line carries — so a `failed` says the same thing on stderr as in the
    /// diagnostic log, whatever the dial's own message was.
    @Test func aFailureKeepsItsOwnReasonEvenWhenTheDialSuppliedAMessage() {
        #expect(
            TunnelExit.note(for: .failed(reason: "connection refused"), dialMessage: "Error: other")
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
/// A source-text scan, like this project's other wiring guards, with one
/// difference worth stating: the function it requires is NOT spelled here.
/// It is walked out of `LsCommand.swift` — the calls that command makes, the
/// calls those make, until a function is reached whose declaration returns a
/// `HostKeyDecider`. So renaming that function, or routing `ls` through a
/// different one, moves this guard with it instead of leaving it pinned to a
/// name nothing uses any more (CLAUDE.md, "Guards that name what they
/// watch", rule 2).
///
/// The negative — the new file builds no decider of its own — has three
/// positives beside it: the walk found exactly one such function, that
/// function really does construct a decider, and the new file really does
/// call it. Without those, a walk that found nothing would report the
/// absence of a violation it never looked for.
@Suite("CLI tunnels start decider guard")
struct CLITunnelStartDeciderGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let cliDirectory = repoRoot.appendingPathComponent("Sources/MacSCPCLI")
    private static let lsCommandFile = cliDirectory.appendingPathComponent("LsCommand.swift")
    private static let startCommandFile = cliDirectory
        .appendingPathComponent("TunnelStartCommand.swift")

    /// The two ways a decider gets built by hand. Both are forbidden in the
    /// new file: the first constructs the type, the second reaches its one
    /// factory.
    private static let deciderConstructions = ["HostKeyDecider(", ".asking {"]

    private static func constructionsFound(in source: String) -> [String] {
        deciderConstructions.filter { source.contains($0) }
    }

    /// The one derivation, run once per test that needs it: the walk out of
    /// `LsCommand.swift` and the single decider builder it reaches.
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

    // MARK: - Positive: the walk lands on a real decider builder

    @Test func theWalkFromLsReachesExactlyOneDeciderBuilder() throws {
        let derived = try Self.derivedBuilder()
        #expect(derived.walk.visitedCount > 1, "the walk never left LsCommand.swift")
    }

    @Test func thatBuilderIsTheOneThatActuallyConstructsADecider() throws {
        let derived = try Self.derivedBuilder()
        let body = try #require(
            derived.walk.body(of: derived.name), "no body found for \(derived.name)")
        #expect(!Self.constructionsFound(in: body).isEmpty, """
            \(derived.name) returns a HostKeyDecider without constructing one \
            — the walk landed on a forwarder, so the negative check below is \
            watching the wrong function.
            """)
    }

    @Test func theStartCommandCallsThatSameBuilder() throws {
        #expect(FileManager.default.fileExists(atPath: Self.startCommandFile.path))
        let derived = try Self.derivedBuilder()
        let source = try String(contentsOf: Self.startCommandFile, encoding: .utf8)
        #expect(source.contains("TunnelRunner("), """
            TunnelStartCommand.swift no longer builds a TunnelRunner( — the \
            positive anchor has nothing to confirm the scanner is reading a \
            real implementation.
            """)
        #expect(source.contains("\(derived.name)("), """
            TunnelStartCommand.swift does not call \(derived.name)( — the \
            host-key decision has to be made by the same function ls makes it \
            with, not by a second one.
            """)
    }

    // MARK: - Negative: it builds none of its own

    @Test func theStartCommandConstructsNoDeciderOfItsOwn() throws {
        let source = try String(contentsOf: Self.startCommandFile, encoding: .utf8)
        let found = Self.constructionsFound(in: source)
        #expect(found.isEmpty, """
            TunnelStartCommand.swift names \(found) — a decider built here \
            answers the TOFU question with its own policy instead of the one \
            --accept-new/--non-interactive select.
            """)
    }

    @Test func theScannerFlagsAPlantedDecider() {
        let fixture = """
            struct FixtureStart {
                func decider() -> HostKeyDecider {
                    if accepting { return HostKeyDecider(alwaysAccepting: true) }
                    return .asking { _ in true }
                }
            }
            """
        #expect(Self.constructionsFound(in: fixture) == ["HostKeyDecider(", ".asking {"], """
            expected the scanner to flag the planted decider, found \
            \(Self.constructionsFound(in: fixture)) instead.
            """)
    }

    @Test func theScannerAcceptsAFixtureThatAsksForOne() {
        let fixture = """
            struct FixtureStart {
                func run() async throws {
                    let decider = makeSomeDecider(policy: options.hostKeyPolicy)
                }
            }
            """
        #expect(Self.constructionsFound(in: fixture).isEmpty)
    }
}

/// A call graph over the command-line target's own sources, built by text.
///
/// Deliberately crude — it knows about `func` declarations and about
/// identifiers followed by `(` — because what it is asked is crude: which
/// functions can be reached from one command's own file. It is a test
/// fixture, not a parser, and every question put to it is checked for having
/// found something at all.
struct CLISourceWalk {
    /// Function name → the text from its `func` line to the next line that
    /// starts a new declaration at column 0 (a top-level function's closing
    /// brace is such a line, so its slice is exactly its body). A METHOD's
    /// slice runs to the end of the type that declares it, which is wide
    /// rather than wrong: the walk only ever asks what a slice CALLS.
    private var slices: [String: String] = [:]
    /// The `func` line of each function, so a return type can be read
    /// without finding the declaration again.
    private var declarations: [String: String] = [:]
    private(set) var visitedCount = 0

    init(directory: URL) throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        guard !files.isEmpty else {
            throw CLISourceWalkError.noSources(directory.path(percentEncoded: false))
        }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            Self.eachFunction(in: source) { name, declaration, slice in
                slices[name] = slice
                declarations[name] = declaration
            }
        }
    }

    func body(of name: String) -> String? { slices[name] }

    /// The functions reachable from `file` whose declaration returns a
    /// `HostKeyDecider`.
    mutating func deciderBuilders(reachableFrom file: URL) throws -> Set<String> {
        let source = try String(contentsOf: file, encoding: .utf8)
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

    /// Calls `body` once per `func` declaration, with its name, its `func`
    /// line and the slice that follows it.
    private static func eachFunction(
        in source: String, _ body: (String, String, String) -> Void
    ) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("func "), let name = functionName(in: trimmed) else { continue }
            var end = index + 1
            while end < lines.count, !startsADeclaration(lines[end]) { end += 1 }
            body(name, String(line), lines[index..<end].joined(separator: "\n"))
        }
    }

    /// Whether a line at column 0 begins something new — the end of the
    /// slice before it. `}` is included because a top-level function's
    /// closing brace sits there, which is exactly where its body ends.
    private static func startsADeclaration(_ line: Substring) -> Bool {
        for prefix in ["func ", "struct ", "enum ", "extension ", "protocol ", "///", "}"] {
            if line.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func functionName(in declaration: String) -> String? {
        let afterKeyword = declaration.dropFirst("func ".count)
        let name = afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

enum CLISourceWalkError: Error {
    case noSources(String)
}
