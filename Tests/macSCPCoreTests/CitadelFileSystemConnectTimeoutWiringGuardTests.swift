import Foundation
import Testing

/// Guards that every `SSHClient.connect(` call inside `CitadelFileSystem.swift`
/// actually FORWARDS the caller's `connectTimeout` — not merely that the
/// label `connectTimeout:` appears.
///
/// A first version of this guard checked only for the label
/// (`body.contains("connectTimeout:")`), which a fix-round review broke by
/// re-spelling the original bug: hardcoding `connectTimeout: .seconds(30)`
/// at both call sites satisfied that check exactly as well as threading the
/// real parameter through, while silently reintroducing Citadel's old
/// 30-second default — the literal is precisely the defect this task exists
/// to remove. So the check here is on VALUE, not label: the argument passed
/// for `connectTimeout:` must be the identifier `connectTimeout` (the
/// function's own parameter, passed straight through), not a literal, not a
/// differently-named local.
///
/// Both hops now dial through one funnel,
/// `connectWithRegisteredAlgorithms` (added so that registering the custom
/// host-key algorithms cannot come apart from the dial — see
/// `CitadelFileSystemHostKeyAlgorithmWiringGuardTests`). So the timeout has
/// two legs to travel, and this guard checks both: the funnel's own
/// `SSHClient.connect(` must forward the funnel's `connectTimeout`, and each
/// of the two hops must forward its own. One leg alone would leave a
/// jump-through chain with its jump hop still stuck on Citadel's old
/// 30-second wait.
///
/// Same boundary as the project's other wiring guards (see
/// `PaneVisibilityWiringGuardTests`'s doc comment): a SOURCE-TEXT scan, not
/// a behavioral test — there is no tool here that drives an actual TCP
/// handshake against an unresponsive host. Fail-closed: an unreadable file,
/// or a call-site count that does not match what this guard expects to
/// find, is itself a failure rather than a silent pass.
///
/// The App-layer leg of the same wiring — that `ContentView+Lifecycle.swift`
/// forwards a LIVE `settingsStore.connectTimeoutSeconds`, not a literal, to
/// `BackendDescriptor.connect(...)` — is guarded separately, in
/// `Tests/macSCPAppKitTests/ConnectTimeoutAppWiringGuardTests.swift`: it
/// scans a different file with a different (positional, unlabeled) call
/// shape, so it is not a natural extension of the scanner below.
@Suite("CitadelFileSystem connect-timeout wiring guard")
struct CitadelFileSystemConnectTimeoutWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/CitadelFileSystemConnectTimeoutWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `PaneVisibilityWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let citadelFileSystemFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/SSH/CitadelFileSystem.swift")

    /// The funnel every hop dials through. Its own declaration line is not a
    /// call site and is skipped by the scanner (see `callStartLines`).
    private static let funnelCall = "connectWithRegisteredAlgorithms("

    /// Both legs the caller's timeout has to survive: the hops that call the
    /// funnel, and the funnel's own dial.
    private static let dialNeedles = ["SSHClient.connect(", funnelCall]

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: citadelFileSystemFile, encoding: .utf8)
            .components(separatedBy: "\n")
    }

    // MARK: - The guard

    @Test func everyDialForwardsTheCallersConnectTimeout() throws {
        let lines = try Self.sourceLines()
        for needle in Self.dialNeedles {
            let violations = Self.callsNotForwardingConnectTimeout(in: lines, calling: needle)
            #expect(violations.isEmpty, """
                `\(needle)` call(s) not forwarding the caller's own \
                `connectTimeout` value found at 1-based line(s) \(violations) in \
                CitadelFileSystem.swift — either the `connectTimeout:` label is \
                missing (Citadel's own 30-second default silently applies) or it \
                carries something other than the `connectTimeout` parameter \
                itself (a hardcoded literal defeats `SettingsStore.connectTimeoutSeconds`
                exactly as effectively as an absent label does).
                """)
        }
    }

    /// Fail-closed check: if the scanner ever finds DIFFERENT numbers of call
    /// sites than the shape this guard was written against, the test above
    /// could be passing for the wrong reason — nothing left to check, rather
    /// than everything checked and clean. Counted by hand against the file at
    /// the time this guard was re-anchored on the funnel: one dial inside
    /// `connectWithRegisteredAlgorithms`, and two hops calling it (jump,
    /// target).
    ///
    /// This is also the check that noticed the funnel arriving: it was the
    /// one test that failed the moment the two dials became one.
    @Test func theCallSiteCountsAreTheOnesThisGuardWasWrittenAgainst() throws {
        let lines = try Self.sourceLines()
        let dials = Self.callStartLines(in: lines).count
        let hops = Self.callStartLines(in: lines, calling: Self.funnelCall).count
        #expect(dials == 1, """
            expected 1 `SSHClient.connect(` call site (inside \
            `connectWithRegisteredAlgorithms`) in CitadelFileSystem.swift, \
            found \(dials) — re-anchor this guard.
            """)
        #expect(hops == 2, """
            expected 2 `\(Self.funnelCall)` call sites (jump hop + target) in \
            CitadelFileSystem.swift, found \(hops) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerFlagsACallMissingConnectTimeout() {
        let source = """
            SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: method,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                group: group ?? .singleton
            )
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.callStartLines(in: lines).count == 1)
        #expect(Self.callsNotForwardingConnectTimeout(in: lines).count == 1)
    }

    @Test func scannerAcceptsACallForwardingTheParameter() {
        let source = """
            SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: method,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: connectTimeout,
                group: group ?? .singleton
            )
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.callStartLines(in: lines).count == 1)
        #expect(Self.callsNotForwardingConnectTimeout(in: lines).isEmpty)
    }

    /// The exact regression a fix-round review found: the label present,
    /// but a hardcoded literal instead of the caller's own value.
    @Test func scannerFlagsAHardcodedLiteralEvenThoughTheLabelIsPresent() {
        let source = """
            SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: method,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                group: group ?? .singleton,
                connectTimeout: .seconds(30)
            )
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.callStartLines(in: lines).count == 1)
        #expect(Self.callsNotForwardingConnectTimeout(in: lines).count == 1)
    }

    /// A differently-named local passed under the `connectTimeout:` label
    /// is just as much a break as a literal — the guard must not accept
    /// merely "some identifier", only the actual parameter.
    @Test func scannerFlagsADifferentlyNamedIdentifier() {
        let source = """
            SSHClient.connect(
                host: host,
                group: group ?? .singleton,
                connectTimeout: someUnrelatedTimeout
            )
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.callsNotForwardingConnectTimeout(in: lines).count == 1)
    }

    @Test func scannerHandlesTwoCallsIndependently() {
        let source = """
            func a() {
                SSHClient.connect(
                    host: jump.host,
                    connectTimeout: connectTimeout,
                    group: group ?? .singleton
                )
            }
            func b() {
                SSHClient.connect(
                    host: config.host,
                    group: group ?? .singleton
                )
            }
            """
        let lines = source.components(separatedBy: "\n")
        #expect(Self.callStartLines(in: lines).count == 2)
        #expect(Self.callsNotForwardingConnectTimeout(in: lines).count == 1)
    }

    // MARK: - Scanner
    //
    // Deliberately line/paren-based, like the project's other wiring guards
    // (see `PaneVisibilityWiringGuardTests`'s `endLineOfCall`).

    /// 1-based line numbers where a call to `needle` starts. A line
    /// declaring the funnel is not a call of it, so `func ` lines are
    /// skipped — that the declaration exists at all is asserted by
    /// `CitadelFileSystemHostKeyAlgorithmWiringGuardTests`, which fails
    /// closed when it cannot find it.
    private static func callStartLines(
        in lines: [String], calling needle: String = "SSHClient.connect("
    ) -> [Int] {
        lines.indices
            .filter { lines[$0].contains(needle) && !lines[$0].contains("func ") }
            .map { $0 + 1 }
    }

    /// 1-based line numbers of `SSHClient.connect(` calls whose
    /// `connectTimeout:` argument is either absent or is not exactly the
    /// bare identifier `connectTimeout` — from the opening paren to its
    /// matching close, however many lines the call spans.
    private static func callsNotForwardingConnectTimeout(
        in lines: [String], calling needle: String = "SSHClient.connect("
    ) -> [Int] {
        callStartLines(in: lines, calling: needle).compactMap { lineNumber in
            let startIndex = lineNumber - 1
            guard let endIndex = endLineOfCall(startingAt: startIndex, in: lines) else {
                return lineNumber  // unbalanced parens: fail closed, don't shrug it off
            }
            let body = lines[startIndex...endIndex].joined(separator: "\n")
            guard let value = timeoutArgumentValue(in: body) else {
                return lineNumber  // no `connectTimeout:` label at all
            }
            return value == "connectTimeout" ? nil : lineNumber
        }
    }

    /// The trimmed text of the argument passed under the `connectTimeout:`
    /// label inside `body` (a call's full text, opening paren through
    /// matching close), or `nil` if the label does not appear at all.
    /// Depth-counts from right after the label so a nested call like
    /// `.seconds(30)` is captured whole rather than truncated at its own
    /// `(`/`)`; stops at the first comma at the call's own top level, or at
    /// the argument list's own closing bracket if `connectTimeout:` is the
    /// last argument.
    private static func timeoutArgumentValue(in body: String) -> String? {
        guard let labelRange = body.range(of: "connectTimeout:") else { return nil }
        var depth = 0
        var value = ""
        var index = labelRange.upperBound
        while index < body.endIndex {
            let character = body[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                if depth == 0 { break }  // closes the ENCLOSING call, not a nested one
                depth -= 1
            } else if character == "," && depth == 0 {
                break
            }
            value.append(character)
            index = body.index(after: index)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parenthesis-counts from `index` (which must contain the call's
    /// opening `(`) across as many following lines as needed until depth
    /// returns to zero, returning the line index where that happens.
    private static func endLineOfCall(startingAt index: Int, in lines: [String]) -> Int? {
        var depth = 0
        var sawOpenParen = false
        for lineIndex in index..<lines.count {
            for character in lines[lineIndex] {
                if character == "(" { depth += 1; sawOpenParen = true }
                if character == ")" { depth -= 1 }
            }
            if sawOpenParen && depth <= 0 {
                return lineIndex
            }
        }
        return nil
    }
}
