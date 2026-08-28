import Foundation
import Testing

/// Guards the App-layer leg of the connect-timeout wiring:
/// `ContentView+Lifecycle.swift`'s connector closure must forward the local
/// `connectTimeoutSeconds` — read fresh from `settingsStore` at the moment
/// the closure actually runs, not hoisted to a stale capture at tab-creation
/// time — as `BackendDescriptor.openConnection(...)`'s `timeoutSeconds:`
/// argument, rather than a hardcoded literal.
///
/// The argument carries a label since dialing moved behind
/// `openConnection`, but the label is not what this guard is about: an
/// `Int` literal or a stale capture passed under the right label compiles
/// exactly as cleanly as the real local does and looks identical to
/// call-site code review. `CitadelFileSystemConnectTimeoutWiringGuardTests`
/// already guards that `CitadelFileSystem.swift` forwards its OWN
/// `connectTimeout` parameter honestly; this is the twin guard one layer
/// up, over a differently-shaped call, which is why it lives in its own
/// file rather than as another case in that scanner.
///
/// Same boundary as the project's other wiring guards (see
/// `PaneVisibilityWiringGuardTests`'s doc comment): a SOURCE-TEXT scan, not
/// a behavioral test. Fail-closed: an unreadable file, an unrecognized call
/// shape, or an argument count other than 4 all count as failures.
///
/// The other three arguments are counted, not read, and the count is here
/// to catch the parser drifting rather than the code changing — the
/// call's arity is the compiler's business. So a decider argument that has
/// quietly stopped asking anybody, `certificate: .asking { _ in true }`,
/// passes this guard unchanged. Measured 2026-08-28: it passes the whole
/// test run unchanged as well. That is a gap in the project rather than in
/// this file, which is about the timeout; it is written down here because
/// this is the call site, and a reader who finds the argument list already
/// under a guard should not conclude that the whole list is.
@Suite("App-layer connect-timeout wiring guard")
struct ConnectTimeoutAppWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ConnectTimeoutAppWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `PaneVisibilityWiringGuardTests`, which lives beside this file).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let lifecycleFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")

    /// The exact substring that anchors the one dial this guard is about —
    /// unique in the file (checked by
    /// `theAnchorAppearsExactlyOnceInTheRealFile` below). Since dialing
    /// moved behind Core's one public entry point, the anchor names that
    /// entry point rather than the closure it reaches, which also stops it
    /// matching `ConnectionViewModel.connect()`'s zero-argument call
    /// elsewhere in the same file.
    private static let anchor = ".openConnection("

    // MARK: - The guard

    @Test func theConnectorClosureForwardsTheLiveConnectTimeout() throws {
        let source = try String(contentsOf: Self.lifecycleFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        guard let arguments = Self.connectCallArguments(in: lines) else {
            Issue.record("""
                no `\(Self.anchor)` call found in ContentView+Lifecycle.swift — \
                re-anchor this guard.
                """)
            return
        }
        #expect(arguments.count == 4, """
            expected 4 arguments at the `\(Self.anchor)` call site in \
            ContentView+Lifecycle.swift (config, host-key decider, certificate \
            decider, connect-timeout seconds), found \(arguments.count): \
            \(arguments) — re-anchor this guard.
            """)
        #expect(arguments.last == "timeoutSeconds: connectTimeoutSeconds", """
            the `\(Self.anchor)` call's last argument is \
            \(arguments.last.map { "`\($0)`" } ?? "missing"), not \
            `timeoutSeconds: connectTimeoutSeconds` — a literal or a stale \
            capture there would silently stop honoring \
            `settingsStore.connectTimeoutSeconds`.
            """)
    }

    /// Fail-closed check, same reasoning as
    /// `CitadelFileSystemConnectTimeoutWiringGuardTests.exactlyTwoCallSitesAreRecognized`:
    /// if the anchor ever stops being unique, the guard above could be
    /// matching the wrong call site silently.
    @Test func theAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.lifecycleFile, encoding: .utf8)
        let count = source.components(separatedBy: Self.anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.anchor)` in \
            ContentView+Lifecycle.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerFlagsAHardcodedLiteralTimeout() {
        let source = """
            return try await BackendDescriptor.openConnection(
                config, hostKey: decider,
                certificate: .asking { candidate in await certificateBridge.ask(candidate) },
                timeoutSeconds: 10)
            """
        let lines = source.components(separatedBy: "\n")
        let arguments = Self.connectCallArguments(in: lines)
        #expect(arguments?.count == 4)
        #expect(arguments?.last != "timeoutSeconds: connectTimeoutSeconds")
    }

    @Test func scannerAcceptsTheLiveLocal() {
        let source = """
            return try await BackendDescriptor.openConnection(
                config, hostKey: decider,
                certificate: .asking { candidate in await certificateBridge.ask(candidate) },
                timeoutSeconds: connectTimeoutSeconds)
            """
        let lines = source.components(separatedBy: "\n")
        let arguments = Self.connectCallArguments(in: lines)
        #expect(arguments?.count == 4)
        #expect(arguments?.last == "timeoutSeconds: connectTimeoutSeconds")
    }

    @Test func scannerFlagsAStaleDifferentlyNamedCapture() {
        let source = """
            return try await BackendDescriptor.openConnection(
                config, hostKey: decider,
                certificate: .asking { candidate in await certificateBridge.ask(candidate) },
                timeoutSeconds: capturedTimeoutFromTabCreation)
            """
        let lines = source.components(separatedBy: "\n")
        let arguments = Self.connectCallArguments(in: lines)
        #expect(arguments?.count == 4)
        #expect(arguments?.last != "timeoutSeconds: connectTimeoutSeconds")
    }

    // MARK: - Scanner
    //
    // Anchors on the anchor substring itself (not the whole line) so
    // depth-counting starts at THAT call's own opening paren, unconfused by
    // any sub-expression that may precede it on the same line.

    /// The full call text from the anchor's own opening paren through its
    /// matching close, however many lines it spans, or `nil` if the anchor
    /// is not found.
    private static func connectCallText(in lines: [String]) -> String? {
        guard let lineIndex = lines.firstIndex(where: { $0.contains(anchor) }) else { return nil }
        guard let anchorRange = lines[lineIndex].range(of: anchor) else { return nil }
        var collected = String(lines[lineIndex][anchorRange.lowerBound...])
        var depth = 0
        var sawOpenParen = false
        func scan(_ text: String) -> Bool {
            for character in text {
                if character == "(" { depth += 1; sawOpenParen = true }
                if character == ")" { depth -= 1 }
            }
            return sawOpenParen && depth <= 0
        }
        if scan(collected) { return collected }
        var nextLine = lineIndex + 1
        while nextLine < lines.count {
            collected += "\n" + lines[nextLine]
            if scan(lines[nextLine]) { return collected }
            nextLine += 1
        }
        return nil
    }

    /// The anchored call's own top-level, comma-separated arguments,
    /// trimmed. `nil` if the anchor is not found in `lines` at all.
    private static func connectCallArguments(in lines: [String]) -> [String]? {
        guard let text = connectCallText(in: lines) else { return nil }
        guard let openParenIndex = text.firstIndex(of: "(") else { return [] }
        var depth = 0
        var current = ""
        var arguments: [String] = []
        var index = text.index(after: openParenIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                current.append(character)
            } else if character == ")" || character == "]" || character == "}" {
                if depth == 0 { break }  // the call's own closing paren
                depth -= 1
                current.append(character)
            } else if character == "," && depth == 0 {
                arguments.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { arguments.append(last) }
        return arguments
    }
}
