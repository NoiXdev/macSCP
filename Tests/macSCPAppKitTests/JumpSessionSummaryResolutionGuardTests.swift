import Foundation
import MacSCPTestSupport
import Testing

/// Guards what the connection form's session-mode jump summary reads on every
/// render (fix round 1 of the technical backlog's Task 5).
///
/// `ConnectionFormView.jumpSessionSummary` is computed in `body`, so it runs on
/// every keystroke in the form. It shows host, port, user and auth kind and no
/// secret. Since `561fc589` the connect path's jump resolutions fall back to a
/// managed key's own Keychain slot — a read of `managed_keys.json` and a second
/// Keychain item, and on a re-signed build a possible consent prompt, per
/// render. The summary must therefore resolve through
/// `SessionListViewModel.resolvedJumpEndpoint(for:)`, which reads no secret.
///
/// The forbidden tokens are DERIVED, not listed: every function in
/// `SessionListViewModel.swift` and `SessionListViewModel+Submit.swift` whose
/// body calls the fallback (`withManagedKeyPassphrase(`,
/// `LoginResolver.fallingBackToManagedKeyPassphrase(` or
/// `ManagedKeyPassphrase.resolve(`), and — repeated until nothing new is
/// found — every function there that calls one of those. A resolver renamed or
/// added later is read, not remembered. The negative ("the summary calls none
/// of them") stands beside two positives: the derivation finds the connect
/// path's two public resolutions, and the summary resolves the jump at all.
@Suite("Jump session summary resolution guard")
struct JumpSessionSummaryResolutionGuardTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let formFile = repoRoot.appendingPathComponent("Sources/MacSCPAppKit/ConnectionFormView.swift")
    private static let coreFiles = [
        repoRoot.appendingPathComponent("Sources/macSCPCore/Presentation/SessionListViewModel.swift"),
        repoRoot.appendingPathComponent("Sources/macSCPCore/Presentation/SessionListViewModel+Submit.swift"),
    ]
    private static let summaryAnchor = "var jumpSessionSummary:"
    private static let fallbackCalls = [
        "withManagedKeyPassphrase(", "fallingBackToManagedKeyPassphrase(", "ManagedKeyPassphrase.resolve(",
    ]

    private enum ScanError: Error { case anchorNotFound, unbalancedBraces }

    @Test func theSummaryResolvesTheJumpWithoutTheManagedKeyFallback() throws {
        var core = ""
        for file in Self.coreFiles { core += try Self.blanked(file) + "\n" }
        let forbidden = Self.fallbackResolvingTokens(inBlanked: core)
        #expect(forbidden.contains("resolvedJump(") && forbidden.contains("resolvedJumpLogin("), """
            the derivation no longer finds the connect path's jump resolutions among the \
            functions that reach the managed-key fallback — it read \(forbidden.sorted()), so \
            the check below would search for the wrong names.
            """)

        let summary = try Self.body(after: Self.summaryAnchor, inBlanked: try Self.blanked(Self.formFile))
        #expect(summary.contains("resolvedJumpEndpoint("), """
            `jumpSessionSummary` no longer resolves the jump through `resolvedJumpEndpoint(` — \
            either it shows nothing, or it resolves through some other call this guard does not read.
            """)
        let used = forbidden.filter { Self.callsToken($0, in: summary) }
        #expect(used.isEmpty, """
            `jumpSessionSummary` calls \(used.sorted()), which reach the managed-key fallback — \
            every render of the form would read the key store and a second Keychain item.
            """)
    }

    // MARK: - Scanner self-tests

    private static let coreFixture = """
        func resolvedJump(for session: StoredSession) throws -> ResolvedJump? {
            var resolved = try LoginResolver.resolveJump(spec: jump)
            resolved.login = withManagedKeyPassphrase(resolved.login)
            return resolved
        }
        func resolveJumpSession(form: ConnectionViewModel) -> SubmitRefusal? {
            guard let resolved = try? resolvedJump(for: synthetic) else { return nil }
            return nil
        }
        func resolvedJumpEndpoint(for session: StoredSession) throws -> ResolvedJump? {
            try LoginResolver.resolveJump(spec: jump, secrets: NoSecrets())
        }
        """

    @Test func theDerivationFollowsCallersTransitively() throws {
        let tokens = Self.fallbackResolvingTokens(inBlanked: try SwiftSource.blankingCommentsAndStrings(Self.coreFixture))
        #expect(tokens.contains("resolvedJump("))
        #expect(tokens.contains("resolveJumpSession("))
        #expect(tokens.contains("resolvedJumpEndpoint(") == false)
    }

    @Test func aCallIsReadAsAWholeName() {
        #expect(Self.callsToken("resolvedJump(", in: "x.resolvedJump(for: s)"))
        #expect(Self.callsToken("resolvedJump(", in: "x.resolvedJumpEndpoint(for: s)") == false)
        #expect(Self.callsToken("resolvedJump(", in: "x.unresolvedJump(for: s)") == false)
    }

    @Test func theBodyReaderFailsClosedOnAMissingAnchor() {
        #expect(throws: ScanError.self) { try Self.body(after: Self.summaryAnchor, inBlanked: "struct X {}") }
    }

    // MARK: - Scanner

    private static func blanked(_ file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: file, encoding: .utf8))
    }

    /// `name(` for every function in `source` whose body calls the fallback,
    /// directly or through another function found here, plus the fallback
    /// calls themselves.
    private static func fallbackResolvingTokens(inBlanked source: String) -> Set<String> {
        let functions = functionBodies(inBlanked: source)
        var tokens = Set(fallbackCalls)
        var grew = true
        while grew {
            grew = false
            for (name, body) in functions where !tokens.contains(name + "(") {
                if tokens.contains(where: { callsToken($0, in: body) }) {
                    tokens.insert(name + "(")
                    grew = true
                }
            }
        }
        return tokens
    }

    /// Name and body of every `func` in `source`.
    private static func functionBodies(inBlanked source: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var searchStart = source.startIndex
        while let keyword = source.range(of: "func ", range: searchStart..<source.endIndex) {
            searchStart = keyword.upperBound
            let rest = source[keyword.upperBound...]
            let name = String(rest.prefix { isIdentifierCharacter($0) })
            guard !name.isEmpty, let brace = rest.firstIndex(of: "{"),
                  let body = try? balancedSpan(from: brace, in: source)
            else { continue }
            result.append((name, body))
        }
        return result
    }

    /// Whether `source` calls `token` (`name(` or a qualified `A.name(`) as a
    /// whole name — `resolvedJump(` is not found inside `unresolvedJump(`.
    private static func callsToken(_ token: String, in source: String) -> Bool {
        var searchStart = source.startIndex
        while let found = source.range(of: token, range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            if found.lowerBound == source.startIndex
                || !isIdentifierCharacter(source[source.index(before: found.lowerBound)]) {
                return true
            }
        }
        return false
    }

    private static func body(after anchor: String, inBlanked source: String) throws -> String {
        guard let found = source.range(of: anchor),
              let brace = source[found.upperBound...].firstIndex(of: "{")
        else { throw ScanError.anchorNotFound }
        return try balancedSpan(from: brace, in: source)
    }

    private static func balancedSpan(from openBrace: String.Index, in source: String) throws -> String {
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[openBrace...index]) }
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
