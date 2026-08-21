import Foundation
import Testing

/// Guards that every `SSHClient.connect(` call inside `CitadelFileSystem.swift`
/// passes `connectTimeout:` explicitly. Citadel's own default for that
/// parameter is `.seconds(30)` — with nothing supplied, an unresponsive host
/// hangs a connect attempt for 30 seconds no matter what
/// `SettingsStore.connectTimeoutSeconds` says, because nothing ever reaches
/// the parameter that would shorten it.
///
/// Two call sites forward `SSHClient.connect(` — the jump hop and the
/// target — and BOTH must supply the parameter: one alone would leave a
/// jump-through chain with its jump hop still stuck on Citadel's old
/// 30-second wait.
///
/// Same boundary as the project's other wiring guards (see
/// `PaneVisibilityWiringGuardTests`'s doc comment): a SOURCE-TEXT scan, not
/// a behavioral test — there is no tool here that drives an actual TCP
/// handshake against an unresponsive host. Fail-closed: an unreadable file,
/// or a call-site count that does not match what this guard expects to
/// find, is itself a failure rather than a silent pass.
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

    // MARK: - The guard

    @Test func everySSHClientConnectCallPassesConnectTimeout() throws {
        let source = try String(contentsOf: Self.citadelFileSystemFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let violations = Self.callsMissingConnectTimeout(in: lines)
        #expect(violations.isEmpty, """
            `SSHClient.connect(` call(s) without `connectTimeout:` found at 1-based \
            line(s) \(violations) in CitadelFileSystem.swift — Citadel's own 30-second \
            default silently applies there instead of the value \
            `CitadelFileSystem.connect` was handed.
            """)
    }

    /// Fail-closed check: if the scanner ever finds a DIFFERENT number of
    /// `SSHClient.connect(` call sites than the two this guard was written
    /// against (jump hop, target), the guard above could be passing for the
    /// wrong reason — nothing left to check, rather than everything checked
    /// and clean. Counted by hand against the file at the time this guard
    /// was written: exactly two.
    @Test func exactlyTwoCallSitesAreRecognized() throws {
        let source = try String(contentsOf: Self.citadelFileSystemFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let count = Self.callStartLines(in: lines).count
        #expect(count == 2, """
            expected 2 `SSHClient.connect(` call sites (jump hop + target) in \
            CitadelFileSystem.swift, found \(count) — re-anchor this guard.
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
        #expect(Self.callsMissingConnectTimeout(in: lines).count == 1)
    }

    @Test func scannerAcceptsACallCarryingConnectTimeout() {
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
        #expect(Self.callsMissingConnectTimeout(in: lines).isEmpty)
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
        #expect(Self.callsMissingConnectTimeout(in: lines).count == 1)
    }

    // MARK: - Scanner
    //
    // Deliberately line/paren-based, like the project's other wiring guards
    // (see `PaneVisibilityWiringGuardTests`'s `endLineOfCall`).

    /// 1-based line numbers where an `SSHClient.connect(` call starts.
    private static func callStartLines(in lines: [String]) -> [Int] {
        lines.indices.filter { lines[$0].contains("SSHClient.connect(") }.map { $0 + 1 }
    }

    /// 1-based line numbers of `SSHClient.connect(` calls whose argument
    /// list — from the opening paren to its matching close, however many
    /// lines it spans — does not contain `connectTimeout:`.
    private static func callsMissingConnectTimeout(in lines: [String]) -> [Int] {
        callStartLines(in: lines).compactMap { lineNumber in
            let startIndex = lineNumber - 1
            guard let endIndex = endLineOfCall(startingAt: startIndex, in: lines) else {
                return lineNumber  // unbalanced parens: fail closed, don't shrug it off
            }
            let body = lines[startIndex...endIndex].joined(separator: "\n")
            return body.contains("connectTimeout:") ? nil : lineNumber
        }
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
