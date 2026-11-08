import Foundation
import MacSCPTestSupport
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
/// **It guards a second argument of the same call since spec §5b:
/// `transferSlots:`, which sizes the FTP transfer pool and must be
/// `settingsStore.maxConcurrentTransfers` read in the same place, for the
/// same reason.** It lives here rather than in a file of its own — unlike
/// the Core-layer twin named above, which guards a differently-shaped call
/// in a different file — because it is the SAME call site and the same
/// scanner, and a second copy of this scanner would be a second thing to
/// keep in step. The file also keeps its name, which now under-describes
/// it: **4** other test files name this suite, counted 2026-11-08 with
/// `/usr/bin/grep -rlo ConnectTimeoutAppWiringGuard --include='*.swift' Tests | /usr/bin/grep -v ConnectTimeoutAppWiringGuardTests.swift`
/// (exit 0), each citing it as the shape a wiring guard takes.
///
/// That command is narrowed on purpose, and the narrowing is the
/// measurement rather than tidiness. It excludes THIS file, whose own text
/// — including the command — names the suite several times, and it excludes
/// `.md`, because prose about this guard in `docs/` and in a plan ledger
/// would otherwise move the figure without a line of code changing. The
/// wide form a first draft of this sentence used,
/// `/usr/bin/grep -rno ConnectTimeoutAppWiringGuard --include='*.swift' --include='*.md' Sources Tests docs CLAUDE.md .superpowers`,
/// printed 11 occurrences when that draft was written, and no figure is
/// quoted for it here because it does not hold still: this paragraph, a
/// `docs/BACKLOG.md` row and a task report each added to it while the
/// sentence was being corrected, and the count rose twice between two
/// runs of the same command. The figure that matters for a rename is
/// files-to-edit, which is what the narrow form counts.
///
/// The remaining three arguments are counted, not read, and the count is
/// here to catch the parser drifting rather than the code changing — the
/// call's arity is the compiler's business. So a decider argument that has
/// quietly stopped asking anybody, `certificate: .asking { _ in true }`,
/// passes this guard unchanged. Measured 2026-08-28: it passes the whole
/// test run unchanged as well. That is a gap in the project rather than in
/// this file, which is about the two settings-derived arguments; it is
/// written down here because this is the call site, and a reader who finds
/// the argument list already under a guard should not conclude that the
/// whole list is.
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
        let source = try SourceCorpus.text(of: Self.lifecycleFile)
        let lines = source.components(separatedBy: "\n")
        guard let arguments = Self.connectCallArguments(in: lines) else {
            Issue.record("""
                no `\(Self.anchor)` call found in ContentView+Lifecycle.swift — \
                re-anchor this guard.
                """)
            return
        }
        #expect(arguments.count == 5, """
            expected 5 arguments at the `\(Self.anchor)` call site in \
            ContentView+Lifecycle.swift (config, host-key decider, certificate \
            decider, connect-timeout seconds, transfer slots), found \
            \(arguments.count): \(arguments) — re-anchor this guard.
            """)
        let timeoutArgument = arguments.first { $0.hasPrefix("timeoutSeconds:") }
        #expect(timeoutArgument == "timeoutSeconds: connectTimeoutSeconds", """
            the `\(Self.anchor)` call's `timeoutSeconds:` argument is \
            \(timeoutArgument.map { "`\($0)`" } ?? "missing"), not \
            `timeoutSeconds: connectTimeoutSeconds` — a literal or a stale \
            capture there would silently stop honoring \
            `settingsStore.connectTimeoutSeconds`.
            """)
    }

    /// The same call's other settings-derived argument: spec §5b's one
    /// number, which sizes the FTP transfer pool.
    ///
    /// Looked up by LABEL rather than by position, so an argument added
    /// after it does not move the check onto something else — and so a
    /// missing argument reads as missing rather than as the neighbour.
    @Test func theConnectorClosureForwardsTheLiveTransferSlotCount() throws {
        let source = try SourceCorpus.text(of: Self.lifecycleFile)
        let lines = source.components(separatedBy: "\n")
        guard let arguments = Self.connectCallArguments(in: lines) else {
            Issue.record("""
                no `\(Self.anchor)` call found in ContentView+Lifecycle.swift — \
                re-anchor this guard.
                """)
            return
        }
        let slotsArgument = arguments.first { $0.hasPrefix("transferSlots:") }
        #expect(slotsArgument == "transferSlots: transferSlots", """
            the `\(Self.anchor)` call's `transferSlots:` argument is \
            \(slotsArgument.map { "`\($0)`" } ?? "missing"), not \
            `transferSlots: transferSlots` — a literal, \
            `SettingsStore.defaultMaxConcurrentTransfers` or a stale capture \
            there is spec §5b's defect: at the shipped default of 3 it looks \
            identical to the live read, and it is wrong at every other value \
            the user can set.
            """)
    }

    /// Fail-closed check, same reasoning as
    /// `CitadelFileSystemConnectTimeoutWiringGuardTests.exactlyTwoCallSitesAreRecognized`:
    /// if the anchor ever stops being unique, the guard above could be
    /// matching the wrong call site silently.
    @Test func theAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try SourceCorpus.text(of: Self.lifecycleFile)
        let count = source.components(separatedBy: Self.anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.anchor)` in \
            ContentView+Lifecycle.swift, found \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    /// The synthetic call every self-test below plants against, with the two
    /// settings-derived arguments spelled by the caller. The sanctioned
    /// spelling is `timeoutSeconds: connectTimeoutSeconds` and
    /// `transferSlots: transferSlots`.
    private static func planted(timeout: String, slots: String) -> [String] {
        """
        return try await BackendDescriptor.openConnection(
            config, hostKey: decider,
            certificate: .asking { candidate in await certificateBridge.ask(candidate) },
            timeoutSeconds: \(timeout),
            transferSlots: \(slots))
        """.components(separatedBy: "\n")
    }

    @Test func scannerFlagsAHardcodedLiteralTimeout() {
        let arguments = Self.connectCallArguments(
            in: Self.planted(timeout: "10", slots: "transferSlots"))
        #expect(arguments?.count == 5)
        #expect(arguments?.first { $0.hasPrefix("timeoutSeconds:") } != "timeoutSeconds: connectTimeoutSeconds")
        #expect(arguments?.first { $0.hasPrefix("transferSlots:") } == "transferSlots: transferSlots")
    }

    @Test func scannerAcceptsTheLiveLocal() {
        let arguments = Self.connectCallArguments(
            in: Self.planted(timeout: "connectTimeoutSeconds", slots: "transferSlots"))
        #expect(arguments?.count == 5)
        #expect(arguments?.first { $0.hasPrefix("timeoutSeconds:") } == "timeoutSeconds: connectTimeoutSeconds")
        #expect(arguments?.first { $0.hasPrefix("transferSlots:") } == "transferSlots: transferSlots")
    }

    @Test func scannerFlagsAStaleDifferentlyNamedCapture() {
        let arguments = Self.connectCallArguments(
            in: Self.planted(
                timeout: "capturedTimeoutFromTabCreation", slots: "capturedSlotsFromTabCreation"))
        #expect(arguments?.count == 5)
        #expect(arguments?.first { $0.hasPrefix("timeoutSeconds:") } != "timeoutSeconds: connectTimeoutSeconds")
        #expect(arguments?.first { $0.hasPrefix("transferSlots:") } != "transferSlots: transferSlots")
    }

    /// The slot spelling that looks right and is spec §5b's defect: the
    /// shipped default, which agrees with the live read at 3 and nowhere
    /// else. The timeout half of the same call is sanctioned here, so a
    /// scanner that flagged the pair for the wrong reason would show.
    @Test func scannerFlagsTheShippedDefaultAsTheSlotCount() {
        let arguments = Self.connectCallArguments(
            in: Self.planted(
                timeout: "connectTimeoutSeconds",
                slots: "SettingsStore.defaultMaxConcurrentTransfers"))
        #expect(arguments?.count == 5)
        #expect(arguments?.first { $0.hasPrefix("timeoutSeconds:") } == "timeoutSeconds: connectTimeoutSeconds")
        #expect(arguments?.first { $0.hasPrefix("transferSlots:") } != "transferSlots: transferSlots")
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
