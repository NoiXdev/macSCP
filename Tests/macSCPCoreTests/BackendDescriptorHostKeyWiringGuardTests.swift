import Foundation
import Testing

/// Reads `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`'s own
/// text and checks each of the three descriptors' `connect` closure against
/// what its OWN `capabilities.authenticatesHostKey` declares — the
/// derivation `BackendDescriptorTests
/// .authenticatesHostKeyMatchesWhichBackendsConnectClosureUsesTheDecider`
/// does NOT do. That test's own doc comment used to call itself "an
/// independent derivation of the same fact", and so did this project's own
/// fix-round report and `docs/BACKLOG.md` row — a reviewer caught it
/// (2026-09-04, fix round on `cab8c7b4`): the switch in that test is typed
/// by hand, and reads none of `BackendDescriptor.swift`. It PINS the three
/// booleans as a second copy — worth having, since a change to one must now
/// be made to the other on purpose — but a pin is not a derivation, and
/// saying so was the report's own "A report says what the diff shows"
/// failure, one layer up. This suite is the derivation that claim was
/// missing: it reads the real file.
///
/// Same boundary as this project's other wiring guards (see
/// `CitadelFileSystemConnectTimeoutWiringGuardTests`'s doc comment): a
/// SOURCE-TEXT scan, not a behavioral test. Runs over comment-and-string
/// BLANKED text (`SwiftSource.stripCommentsAndStrings`) — a doc comment
/// quoting `authenticatesHostKey: true` or `onUnknownHostKey: decider`
/// verbatim must neither trip this scan nor satisfy it (CLAUDE.md, "Source-
/// scanning guards read comments too"), and this file's own header above
/// does exactly that quoting, which is precisely why the blanking matters.
///
/// Per CLAUDE.md "Guards that name what they watch": the negative half —
/// "a `false` descriptor's closure does not forward the decider" — is
/// trivially satisfiable by a scan that finds nothing at all, so it is
/// paired with positives that are not: `exactlyThreeDescriptorsAreFoundIn
/// TheRealFile` (the scan reaches the file and finds all three, not zero)
/// and `theSSHClosureBodyMentionsItsDecider` (the one `true` descriptor's
/// closure really does name and use its parameter). Four more tests run the
/// scanner over synthetic sources and drive it through the exact parsing
/// function the guard itself calls, both directions: a closure that
/// forwards a `true`-declared decider is accepted, one that discards it is
/// flagged, a closure that forwards a `false`-declared decider is flagged,
/// and one that discards it is accepted.
@Suite("BackendDescriptor host-key wiring guard")
struct BackendDescriptorHostKeyWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/BackendDescriptorHostKeyWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `CitadelFileSystemConnectTimeoutWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let backendDescriptorFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/Capabilities/BackendDescriptor.swift")

    private static func realDescriptors() throws -> [BackendDescriptorHostKeyScan.Descriptor] {
        let source = try String(contentsOf: backendDescriptorFile, encoding: .utf8)
        let stripped = try SwiftSource.stripCommentsAndStrings(source)
        return try BackendDescriptorHostKeyScan.parse(stripped)
    }

    // MARK: - The guard

    @Test func everyDescriptorsHostKeyClaimAgreesWithWhetherItsConnectClosureForwardsTheDecider(
    ) throws {
        for descriptor in try Self.realDescriptors() {
            #expect(BackendDescriptorHostKeyScan.agrees(descriptor), """
                capabilities.authenticatesHostKey == \(descriptor.declaredAuthenticatesHostKey) \
                but its connect closure's HostKeyDecider parameter is \
                `\(descriptor.deciderParameterName)` — \
                \(descriptor.declaredAuthenticatesHostKey
                    ? "a `true` claim needs a NAMED parameter that the body actually uses"
                    : "a `false` claim needs the parameter DISCARDED (`_`, or named but unused)")
                """)
        }
    }

    // MARK: - Positive companions

    /// The scan reaches the real file and finds all three descriptors, not
    /// zero — without this, the guard above could be silently checking
    /// nothing.
    @Test func exactlyThreeDescriptorsAreFoundInTheRealFile() throws {
        let descriptors = try Self.realDescriptors()
        #expect(descriptors.count == 3, """
            expected 3 `ProtocolCapabilities(` sites (ssh, s3, webdav) in \
            BackendDescriptor.swift, found \(descriptors.count) — re-anchor this guard
            """)
    }

    /// The one descriptor declaring `true` really does name and use its
    /// decider — without this, "no closure claiming `false` forwards its
    /// decider" could be vacuously true over three closures that all
    /// discard it, `true` claim included.
    @Test func theSSHClosureBodyMentionsItsDecider() throws {
        let descriptors = try Self.realDescriptors()
        let ssh = try #require(descriptors.first { $0.declaredAuthenticatesHostKey })
        #expect(ssh.deciderParameterName != "_")
        #expect(BackendDescriptorHostKeyScan.mentionsWholeWord(
            ssh.deciderParameterName, in: ssh.closureBody))
    }

    // MARK: - Scanner self-tests (synthetic sources, driven through the
    // exact parsing function the guard itself calls)

    @Test func scannerAcceptsAClosureThatForwardsAWiredDecider() throws {
        let source = """
            ProtocolCapabilities(supportsShell: true, authenticatesHostKey: true)
            connect: { config, decider, _, timeout in
                return try await Something.connect(decider: decider)
            }
            """
        let descriptors = try BackendDescriptorHostKeyScan.parse(source)
        #expect(descriptors.count == 1)
        #expect(descriptors.allSatisfy(BackendDescriptorHostKeyScan.agrees))
    }

    /// The exact shape a mutation probe plants against the real file: the
    /// capability claims `true`, the closure still discards the decider.
    @Test func scannerFlagsAClosureThatClaimsTrueButDiscardsTheDecider() throws {
        let source = """
            ProtocolCapabilities(supportsShell: true, authenticatesHostKey: true)
            connect: { config, _, _, timeout in
                return try await Something.connect()
            }
            """
        let descriptors = try BackendDescriptorHostKeyScan.parse(source)
        #expect(descriptors.count == 1)
        #expect(!descriptors.allSatisfy(BackendDescriptorHostKeyScan.agrees))
    }

    @Test func scannerFlagsAClosureThatClaimsFalseButForwardsTheDecider() throws {
        let source = """
            ProtocolCapabilities(supportsShell: true, authenticatesHostKey: false)
            connect: { config, decider, _, timeout in
                return try await Something.connect(decider: decider)
            }
            """
        let descriptors = try BackendDescriptorHostKeyScan.parse(source)
        #expect(descriptors.count == 1)
        #expect(!descriptors.allSatisfy(BackendDescriptorHostKeyScan.agrees))
    }

    @Test func scannerAcceptsAClosureThatClaimsFalseAndDiscardsTheDecider() throws {
        let source = """
            ProtocolCapabilities(supportsShell: true, authenticatesHostKey: false)
            connect: { config, _, _, timeout in
                return try await Something.connect()
            }
            """
        let descriptors = try BackendDescriptorHostKeyScan.parse(source)
        #expect(descriptors.count == 1)
        #expect(descriptors.allSatisfy(BackendDescriptorHostKeyScan.agrees))
    }
}

/// The scanner itself, kept free of `Testing` so it can be driven by both
/// the real-file guard and its own self-tests above without either being a
/// hand-duplicated copy of the other's logic.
enum BackendDescriptorHostKeyScan {
    struct Descriptor {
        let declaredAuthenticatesHostKey: Bool
        /// The `connect` closure's SECOND parameter (after `config`) — the
        /// position `BackendDescriptor.connect`'s own stored type gives the
        /// `HostKeyDecider` argument, regardless of what a given backend
        /// happens to call it or whether it names it at all.
        let deciderParameterName: String
        /// Everything in the closure after its parameter list's `in`.
        let closureBody: String
    }

    enum ScanError: Error, CustomStringConvertible {
        case noMatchingDelimiter(String)
        case noConnectClosure(String)
        case noParameterSeparator(String)
        case tooFewParameters(String)
        case noAuthenticatesHostKeyLabel(String)

        var description: String {
            switch self {
            case .noMatchingDelimiter(let c): return "no matching close delimiter for \(c)"
            case .noConnectClosure(let c): return "no `connect: { … }` found after \(c)"
            case .noParameterSeparator(let c): return "no top-level `in` inside the closure at \(c)"
            case .tooFewParameters(let c): return "connect closure has fewer than 2 parameters at \(c)"
            case .noAuthenticatesHostKeyLabel(let c):
                return "no `authenticatesHostKey:` label inside the ProtocolCapabilities( args at \(c)"
            }
        }
    }

    /// Locates every `ProtocolCapabilities(` init site in `strippedSource`
    /// (comments and string literals already blanked by the caller) and,
    /// for each, the `connect: { … }` closure that follows it — both found
    /// by BRACE/PAREN BALANCE from the anchor, not a fixed line range, so
    /// the scan survives a descriptor growing or shrinking.
    ///
    /// Fails closed: an unbalanced delimiter, a missing `connect:` closure,
    /// a closure with no top-level `in`, fewer than two parameters, or a
    /// `ProtocolCapabilities(` argument list with no `authenticatesHostKey:`
    /// label all throw rather than silently skip that descriptor.
    static func parse(_ strippedSource: String) throws -> [Descriptor] {
        let chars = Array(strippedSource)
        let openMarker = Array("ProtocolCapabilities(")
        var results: [Descriptor] = []
        var cursor = 0
        while let matchStart = firstIndex(of: openMarker, in: chars, from: cursor) {
            let openParen = matchStart + openMarker.count - 1
            guard let closeParen = matchingDelimiter(chars, openAt: openParen, open: "(", close: ")")
            else { throw ScanError.noMatchingDelimiter("ProtocolCapabilities( at index \(openParen)") }
            let argsText = String(chars[(openParen + 1)..<closeParen])
            let declared = try declaredAuthenticatesHostKey(
                in: argsText, context: "index \(openParen)")

            guard let connectStart = firstIndex(of: Array("connect:"), in: chars, from: closeParen)
            else { throw ScanError.noConnectClosure("index \(closeParen)") }
            guard let openBrace = firstIndex(of: Array("{"), in: chars, from: connectStart)
            else { throw ScanError.noConnectClosure("index \(connectStart)") }
            guard let closeBrace = matchingDelimiter(chars, openAt: openBrace, open: "{", close: "}")
            else { throw ScanError.noMatchingDelimiter("connect closure { at index \(openBrace)") }
            let closureText = String(chars[openBrace...closeBrace])

            guard let inRange = closureText.range(of: #"\bin\b"#, options: .regularExpression)
            else { throw ScanError.noParameterSeparator("index \(openBrace)") }
            let paramListStart = closureText.index(after: closureText.startIndex)
            let paramList = closureText[paramListStart..<inRange.lowerBound]
            let params = paramList.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard params.count >= 2 else {
                throw ScanError.tooFewParameters("index \(openBrace)")
            }

            results.append(Descriptor(
                declaredAuthenticatesHostKey: declared,
                deciderParameterName: params[1],
                closureBody: String(closureText[inRange.upperBound...])))
            cursor = closeBrace + 1
        }
        return results
    }

    /// Whether `descriptor`'s declared capability agrees with what its own
    /// closure actually does with the decider: a `true` claim needs the
    /// parameter NAMED and used in the body; a `false` claim needs it
    /// discarded — `_`, or named but never mentioned.
    static func agrees(_ descriptor: Descriptor) -> Bool {
        let named = descriptor.deciderParameterName != "_"
        let used = named
            && mentionsWholeWord(descriptor.deciderParameterName, in: descriptor.closureBody)
        return descriptor.declaredAuthenticatesHostKey ? used : !used
    }

    /// Whether `word` appears in `text` as a whole identifier — a substring
    /// test would read `decider` inside a hypothetical `subDecider` too.
    static func mentionsWholeWord(_ word: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b\#(NSRegularExpression.escapedPattern(for: word))\b"#)
        else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func declaredAuthenticatesHostKey(
        in argsText: String, context: String
    ) throws -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"authenticatesHostKey:\s*(true|false)"#),
            let match = regex.firstMatch(
                in: argsText, range: NSRange(argsText.startIndex..., in: argsText)),
            let valueRange = Range(match.range(at: 1), in: argsText)
        else { throw ScanError.noAuthenticatesHostKeyLabel(context) }
        return argsText[valueRange] == "true"
    }

    /// Depth-counts from `openAt` (which must hold `open`) to the matching
    /// `close`, both single characters — no confusion from a comment or a
    /// string literal, since the caller already blanked both.
    private static func matchingDelimiter(
        _ chars: [Character], openAt: Int, open: Character, close: Character
    ) -> Int? {
        guard chars[openAt] == open else { return nil }
        var depth = 0
        var i = openAt
        while i < chars.count {
            if chars[i] == open { depth += 1 } else if chars[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func firstIndex(
        of pattern: [Character], in chars: [Character], from start: Int
    ) -> Int? {
        guard !pattern.isEmpty, start <= chars.count - pattern.count else { return nil }
        var i = start
        while i <= chars.count - pattern.count {
            if Array(chars[i..<(i + pattern.count)]) == pattern { return i }
            i += 1
        }
        return nil
    }
}
