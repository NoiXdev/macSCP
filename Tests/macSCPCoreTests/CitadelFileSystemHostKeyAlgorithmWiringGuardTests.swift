import Foundation
import Testing
@testable import macSCPCore

/// Guards that a hop cannot be dialed without macSCP's custom host-key
/// algorithms being registered first.
///
/// NIOSSH builds its key-exchange offer out of a process-global registry, so
/// a dial that ran before `HostKeyAlgorithms.registerOnce()` would simply
/// stop offering `rsa-sha2-512` — and every RSA-only server would fail with
/// `keyExchangeNegotiationFailure`. The only automated proof of the offer
/// itself lives in `HostKeyTypeIntegrationTests`, which needs the Docker rig
/// and which CI does not run: deleting the registration left the entire
/// ungated suite green, because `RSASHA2HostKeyTests` registers for itself.
/// That gap is what this file closes.
///
/// The property is held STRUCTURALLY rather than by scanning for a call
/// beside a call: `CitadelFileSystem` funnels both hops through one private
/// `connectWithRegisteredAlgorithms`, and what is checked here is that the
/// funnel is still the only way out. A scan is still a scan — same boundary
/// as the project's other wiring guards (`PaneVisibilityWiringGuardTests`) —
/// but the thing it has to keep true is now one line in one function instead
/// of a habit at every call site.
///
/// Fail-closed throughout: an unreadable file, a funnel that cannot be
/// found, or counts other than the ones counted by hand here (one dial
/// inside the funnel, two hops calling it) are failures rather than silent
/// passes. The negative check — nothing dials outside the funnel — is never
/// alone: it is stated as an equality against the inside count, which is
/// itself pinned to one.
@Suite("CitadelFileSystem host-key algorithm registration guard")
struct CitadelFileSystemHostKeyAlgorithmWiringGuardTests {
    /// `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/<this file>`; three
    /// `deletingLastPathComponent()` calls recover the repo root regardless
    /// of `swift test`'s working directory (same trick as
    /// `CitadelFileSystemConnectTimeoutWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let citadelFileSystemFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/SSH/CitadelFileSystem.swift")

    /// Read off the type rather than spelled: renaming the enum moves this
    /// needle with it. The method name cannot be read the same way, so
    /// `theRegistrationEntryPointExistsUnderTheNameTheScannerSearchesFor`
    /// holds it with a reference that stops compiling if it is renamed.
    private static let registrationCall = "\(String(describing: HostKeyAlgorithms.self)).registerOnce("

    /// The registration as a STATEMENT, which is the only form that runs
    /// where it is written. A planted `defer { … }` kept the call textually
    /// above the dial while running it after — a line-order check bought
    /// that, and this is what it did not: the line has to BE the call.
    private static let registrationStatement = "\(registrationCall))"

    private static let dialCall = "SSHClient.connect("
    private static let funnelName = "connectWithRegisteredAlgorithms"
    private static let funnelDeclaration = "func \(funnelName)("
    private static let funnelCall = "\(funnelName)("

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: citadelFileSystemFile, encoding: .utf8)
            .components(separatedBy: "\n")
    }

    // MARK: - The guard

    /// Inside the funnel: registration, then the dial, one of each.
    @Test func theFunnelRegistersBeforeItDials() throws {
        let lines = try Self.sourceLines()
        let body = try #require(
            Self.funnelBodyLineNumbers(in: lines),
            "no `\(Self.funnelDeclaration)` in CitadelFileSystem.swift — re-anchor this guard")
        let registrations = Self.lineNumbers(matching: Self.registrationStatement, in: lines, within: body)
        let dials = Self.lineNumbers(containing: Self.dialCall, in: lines, within: body)

        #expect(registrations.count == 1, """
            expected exactly one line in the funnel that IS             `\(Self.registrationStatement)`, got \(registrations) — a call             wrapped in `defer`, a closure or a branch reads as registered             here while running somewhere else.
            """)
        #expect(dials.count == 1, "expected one `\(Self.dialCall)` in the funnel, got \(dials)")
        guard let registration = registrations.first, let dial = dials.first else { return }
        #expect(registration < dial, """
            the funnel dials at line \(dial) before registering at line \
            \(registration) — the key-exchange offer is built from the \
            registry at dial time, so a registration after it changes nothing.
            """)
    }

    /// Nothing dials outside the funnel. Stated as an equality rather than
    /// as "zero elsewhere": a `!contains` that stops matching reads exactly
    /// like a `!contains` that is satisfied, whereas this cannot pass while
    /// the funnel's own dial has gone missing.
    @Test func theFunnelIsTheOnlyPlaceThatDials() throws {
        let lines = try Self.sourceLines()
        let body = try #require(Self.funnelBodyLineNumbers(in: lines))
        let insideTheFunnel = Self.lineNumbers(containing: Self.dialCall, in: lines, within: body)
        let everywhere = Self.lineNumbers(containing: Self.dialCall, in: lines)

        #expect(insideTheFunnel.count == 1)
        #expect(everywhere == insideTheFunnel, """
            `\(Self.dialCall)` outside `\(Self.funnelName)` at line(s) \
            \(everywhere.filter { !insideTheFunnel.contains($0) }) — a hop \
            dialed there would negotiate without macSCP's custom host-key \
            algorithms.
            """)
    }

    /// The other half of the funnel's reason to exist: both hops still go
    /// through it. Counted by hand against the file when this guard was
    /// written — the jump hop and the target.
    @Test func bothHopsCallTheFunnel() throws {
        let lines = try Self.sourceLines()
        let body = try #require(Self.funnelBodyLineNumbers(in: lines))
        let callers = Self.lineNumbers(containing: Self.funnelCall, in: lines)
            .filter { !body.contains($0) }

        #expect(callers.count == 2, "expected 2 hops calling `\(Self.funnelCall)`, found \(callers)")
    }

    /// The scanner searches for a string; this is what keeps that string
    /// honest. `HostKeyAlgorithms.registerOnce` is referenced here as a
    /// value, so renaming it fails the BUILD rather than quietly emptying
    /// the needle above — and the type half of the needle is read off the
    /// type itself.
    @Test func theRegistrationEntryPointExistsUnderTheNameTheScannerSearchesFor() {
        let entryPoint: () -> Void = HostKeyAlgorithms.registerOnce
        _ = entryPoint

        #expect(Self.registrationCall == "HostKeyAlgorithms.registerOnce(")
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // pass merely because the real file moved or failed to read)

    private static let syntheticFunnel = """
        private static func connectWithRegisteredAlgorithms(host: String) async throws -> SSHClient {
            HostKeyAlgorithms.registerOnce()
            return try await SSHClient.connect(host: host)
        }
        """

    @Test func scannerAcceptsTheFunnelShape() {
        let lines = Self.syntheticFunnel.components(separatedBy: "\n")
        let body = Self.funnelBodyLineNumbers(in: lines)

        #expect(body == [1, 2, 3, 4])
        #expect(Self.lineNumbers(matching: Self.registrationStatement, in: lines, within: body!) == [2])
        #expect(Self.lineNumbers(containing: Self.dialCall, in: lines, within: body!) == [3])
    }

    @Test func scannerSeesADialPlantedOutsideTheFunnel() {
        let source = """
            func somethingElse() async throws -> SSHClient {
                try await SSHClient.connect(host: "h")
            }
            \(Self.syntheticFunnel)
            """
        let lines = source.components(separatedBy: "\n")
        let body = Self.funnelBodyLineNumbers(in: lines)!
        let everywhere = Self.lineNumbers(containing: Self.dialCall, in: lines)

        #expect(everywhere.count == 2)
        #expect(everywhere != Self.lineNumbers(containing: Self.dialCall, in: lines, within: body))
    }

    @Test func scannerSeesARegistrationMovedAfterTheDial() {
        let source = """
            private static func connectWithRegisteredAlgorithms(host: String) async throws -> SSHClient {
                let client = try await SSHClient.connect(host: host)
                HostKeyAlgorithms.registerOnce()
                return client
            }
            """
        let lines = source.components(separatedBy: "\n")
        let body = Self.funnelBodyLineNumbers(in: lines)!

        let registration = Self.lineNumbers(matching: Self.registrationStatement, in: lines, within: body)[0]
        let dial = Self.lineNumbers(containing: Self.dialCall, in: lines, within: body)[0]
        #expect(registration > dial)
    }

    @Test func scannerDoesNotCountACommentedOutRegistration() {
        let source = """
            private static func connectWithRegisteredAlgorithms(host: String) async throws -> SSHClient {
                // HostKeyAlgorithms.registerOnce()
                return try await SSHClient.connect(host: host)
            }
            """
        let lines = source.components(separatedBy: "\n")
        let body = Self.funnelBodyLineNumbers(in: lines)!

        #expect(Self.lineNumbers(matching: Self.registrationStatement, in: lines, within: body).isEmpty)
        // Positive control: the same scan over the same shape, uncommented.
        let real = Self.syntheticFunnel.components(separatedBy: "\n")
        #expect(Self.lineNumbers(matching: Self.registrationStatement, in: real,
                                 within: Self.funnelBodyLineNumbers(in: real)!).count == 1)
    }

    /// The probe that found the hole this guard used to have: `defer` keeps
    /// the registration on a line above the dial and runs it after.
    @Test func scannerDoesNotCountADeferredRegistration() {
        let source = """
            private static func connectWithRegisteredAlgorithms(host: String) async throws -> SSHClient {
                defer { HostKeyAlgorithms.registerOnce() }
                return try await SSHClient.connect(host: host)
            }
            """
        let lines = source.components(separatedBy: "\n")
        let body = Self.funnelBodyLineNumbers(in: lines)!

        #expect(Self.lineNumbers(matching: Self.registrationStatement, in: lines, within: body).isEmpty)
        // Positive control, so an empty result cannot be an empty scan: the
        // same needle, matched as a substring, does find that line.
        #expect(Self.lineNumbers(containing: Self.registrationCall, in: lines, within: body) == [2])
    }

    @Test func scannerFindsNoFunnelWhenItIsGone() {
        let source = """
            func connectHop() async throws -> SSHClient {
                try await SSHClient.connect(host: "h")
            }
            """
        #expect(Self.funnelBodyLineNumbers(in: source.components(separatedBy: "\n")) == nil)
    }

    // MARK: - Scanner
    //
    // Line/brace-based, like the project's other wiring guards.

    /// The 1-based line numbers spanned by the funnel, its declaration line
    /// through the line where its brace depth returns to zero. `nil` when
    /// the declaration is not in `lines` at all, so a caller can fail closed.
    private static func funnelBodyLineNumbers(in lines: [String]) -> [Int]? {
        guard let start = lines.indices.first(where: { lines[$0].contains(funnelDeclaration) }) else {
            return nil
        }
        var depth = 0
        var sawOpenBrace = false
        for index in start..<lines.count {
            for character in lines[index] {
                if character == "{" { depth += 1; sawOpenBrace = true }
                if character == "}" { depth -= 1 }
            }
            if sawOpenBrace, depth <= 0 {
                return Array((start + 1)...(index + 1))
            }
        }
        return nil
    }

    /// 1-based line numbers whose whole trimmed text IS `statement`,
    /// optionally restricted to a set of line numbers. Whole-line equality,
    /// not containment: it is what rejects a call wrapped in something that
    /// defers or conditions it.
    private static func lineNumbers(
        matching statement: String, in lines: [String], within range: [Int]? = nil
    ) -> [Int] {
        lines.indices
            .filter { lines[$0].trimmingCharacters(in: .whitespaces) == statement }
            .map { $0 + 1 }
            .filter { range?.contains($0) ?? true }
    }

    /// 1-based line numbers containing `needle`, optionally restricted to a
    /// set of line numbers.
    ///
    /// Comment lines do not count. A scanner that read them would accept a
    /// commented-out registration as a registration — this project writes
    /// long explanatory comments AND scans source, and the two have collided
    /// here before (CLAUDE.md, "Source-scanning guards read comments too").
    /// Only whole-line comments are dropped; a trailing `//` after real code
    /// leaves the code on the line, where it belongs.
    private static func lineNumbers(
        containing needle: String, in lines: [String], within range: [Int]? = nil
    ) -> [Int] {
        lines.indices
            .filter { !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { lines[$0].contains(needle) }
            .map { $0 + 1 }
            .filter { range?.contains($0) ?? true }
    }
}
