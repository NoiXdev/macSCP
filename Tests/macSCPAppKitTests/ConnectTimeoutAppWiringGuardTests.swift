import Foundation
import Testing

/// Guards the App-layer leg of the connect-timeout wiring:
/// `ContentView+Lifecycle.swift`'s connector closure must forward the local
/// `connectTimeoutSeconds` — read fresh from `settingsStore` at the moment
/// the closure actually runs, not hoisted to a stale capture at tab-creation
/// time — to `BackendDescriptor.descriptor(for:).connect(...)`'s fourth,
/// unlabeled argument, rather than a hardcoded literal.
///
/// `BackendDescriptor.connect`'s closure type takes plain, unlabeled
/// positional arguments (it is a stored property of closure type, not a
/// function declaration), so a literal there compiles exactly as cleanly as
/// the real local does and looks identical to `Int`-typed call-site code
/// review. `CitadelFileSystemConnectTimeoutWiringGuardTests` already guards
/// that `CitadelFileSystem.swift` forwards its OWN `connectTimeout`
/// parameter honestly; this is the twin guard one layer up, over a
/// differently-shaped (positional, not labeled) call, which is why it lives
/// in its own file rather than as another case in that scanner.
///
/// Same boundary as the project's other wiring guards (see
/// `PaneVisibilityWiringGuardTests`'s doc comment): a SOURCE-TEXT scan, not
/// a behavioral test. Fail-closed: an unreadable file, an unrecognized call
/// shape, or an argument count other than 4 all count as failures.
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

    /// The exact substring that anchors the one `.connect(` call this guard
    /// is about — unique in the file (checked by
    /// `theAnchorAppearsExactlyOnceInTheRealFile` below), and specific
    /// enough (`.connect(`, not merely `connect`) that it does not also
    /// match `ConnectionViewModel.connect()`'s zero-argument call elsewhere
    /// in the same file.
    private static let anchor = ".connect("

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
            ContentView+Lifecycle.swift (config, decider, certificate decider, \
            connect-timeout seconds), found \(arguments.count): \(arguments) — \
            re-anchor this guard.
            """)
        #expect(arguments.last == "connectTimeoutSeconds", """
            the `\(Self.anchor)` call's last argument is \
            \(arguments.last.map { "`\($0)`" } ?? "missing"), not the identifier \
            `connectTimeoutSeconds` — a literal or a stale capture there would \
            silently stop honoring `settingsStore.connectTimeoutSeconds`.
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
            return try await BackendDescriptor.descriptor(for: config.kind).connect(
                config, decider, { candidate in await certificateBridge.ask(candidate) },
                10)
            """
        let lines = source.components(separatedBy: "\n")
        let arguments = Self.connectCallArguments(in: lines)
        #expect(arguments?.count == 4)
        #expect(arguments?.last != "connectTimeoutSeconds")
    }

    @Test func scannerAcceptsTheLiveLocal() {
        let source = """
            return try await BackendDescriptor.descriptor(for: config.kind).connect(
                config, decider, { candidate in await certificateBridge.ask(candidate) },
                connectTimeoutSeconds)
            """
        let lines = source.components(separatedBy: "\n")
        let arguments = Self.connectCallArguments(in: lines)
        #expect(arguments?.count == 4)
        #expect(arguments?.last == "connectTimeoutSeconds")
    }

    @Test func scannerFlagsAStaleDifferentlyNamedCapture() {
        let source = """
            return try await BackendDescriptor.descriptor(for: config.kind).connect(
                config, decider, { candidate in await certificateBridge.ask(candidate) },
                capturedTimeoutFromTabCreation)
            """
        let lines = source.components(separatedBy: "\n")
        let arguments = Self.connectCallArguments(in: lines)
        #expect(arguments?.last != "connectTimeoutSeconds")
    }

    // MARK: - Scanner
    //
    // Anchors on the `.connect(` substring itself (not the whole line) so
    // depth-counting starts at THAT call's own opening paren, unconfused by
    // the `descriptor(for: config.kind)` sub-expression immediately before
    // it on the real line.

    /// The full call text from `.connect(`'s own opening paren through its
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

    /// The `.connect(...)` call's own top-level, comma-separated arguments,
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
