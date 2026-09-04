import Foundation
import Testing

/// Keeps `String(describing:)` out of `Sources/macSCPCore/Diagnostics/`.
///
/// `bd6ec81f` closed the one route this module had for it — the
/// `RemoteFSError` arm of `DialSupport.reason(for:)`, which used to render
/// an arbitrary case by describing it, and could hand a diagnosis row an
/// endpoint's userinfo that way (`docs/BACKLOG.md`, "Diagnostics: error
/// text as a leak route"). That fix is a `switch`, not a rule; nothing
/// stops the next case, the next file, or a differently-shaped error from
/// reaching for `String(describing:)` again the same way
/// `SSHPrivateKeyLoader` once did (see the `unsupportedFormat` comment in
/// `DialProbes.swift`, which names it as "the one place that broke it").
/// This suite is that rule, checked rather than remembered.
///
/// Source-scanning, like this project's other wiring guards, and scoped
/// the same way: read `SwiftSourceStripping.swift`'s doc comment on why a
/// scan runs over comment-and-string-BLANKED text (a comment or a quoted
/// example must neither trip the check nor satisfy it) before a "why is
/// this guard reading raw text" question.
///
/// Two checks, per CLAUDE.md "Guards that name what they watch": a
/// NEGATIVE one (`noDiagnosticsFileDescribesAnErrorValue`, `!contains`, the
/// kind that goes stale in silence — a renamed directory or an emptied file
/// list would satisfy it exactly as well as a clean tree) paired with two
/// POSITIVE ones that pin the scan is reading something real:
/// `theScanReachesTheDirectoryItGuards` (the file count and `DialProbes.swift`'s
/// presence) and `theRuleIsStatedInDialProbesOwnDocComment` (the unblanked
/// file still carries the prose that states the rule this suite enforces,
/// so the negative check is known to be reading the right file and not an
/// empty stand-in for it). A fourth test, `theScanCatchesAPlantedDescribingCall`,
/// plants the violation into an in-memory source and drives it through the
/// exact scanning function the guard itself calls — not a second, hand-written
/// copy of the same logic that could drift from what the guard actually runs.
///
/// Counted 2026-09-04 at HEAD `79f4aaa0`: 11 `.swift` files sit directly
/// under `Sources/macSCPCore/Diagnostics/` (no subdirectories) —
/// `BlockingProbe.swift`, `ConnectionDiagnostics.swift`,
/// `ContributionProbes.swift`, `DiagnosticReason.swift`,
/// `DiagnosticReport.swift`, `DiagnosticStep.swift`, `DialProbes.swift`,
/// `HostResolver.swift`, `ICMPEcho.swift`, `NetworkTrace.swift`,
/// `TCPPing.swift`. None of them carries a raw-string delimiter
/// (`#"…"#`) at HEAD — `grep -rln '#"' Sources/macSCPCore/Diagnostics/`
/// matches only `DiagnosticStep.swift`, and by hand that hit is the
/// character literal `"#"` inside an ordinary plain string (`character ==
/// "#" || character.isWhitespace`), not an opening raw-string delimiter —
/// so `SwiftSource.stripCommentsAndStrings` reads every file here without
/// throwing.
@Suite("Diagnostics no String(describing:) guard", .timeLimit(.minutes(1)))
struct DiagnosticsNoDescribingGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPCoreTests/DiagnosticsNoDescribingGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `CitadelFileSystemConnectTimeoutWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let diagnosticsDirectory = repoRoot
        .appendingPathComponent("Sources/macSCPCore/Diagnostics")

    private static let dialProbesFile = diagnosticsDirectory
        .appendingPathComponent("DialProbes.swift")

    /// The text the guard forbids. No closing paren: `String(describing:`
    /// catches every argument shape (`String(describing: error)`,
    /// `String(describing: someValue)`, a multi-line call), the same way
    /// this project's other source guards anchor on a label rather than a
    /// whole call.
    private static let needle = "String(describing:"

    /// The clause `DialSupport.reason(for:)`'s doc comment uses to state
    /// the rule this suite enforces — prose, not the code it describes, so
    /// this positive check cannot be satisfied by a commented-out example
    /// of the very thing the negative check forbids (CLAUDE.md,
    /// "Source-scanning guards read comments too"). Read at
    /// `DialProbes.swift:157` at HEAD; a single source line, so it survives
    /// a plain (unblanked, unstripped) substring match without needing to
    /// join lines.
    private static let ruleClause =
        "to `localizedDescription` and never `String(describing:)`, because"

    // MARK: - The guard

    /// Every `.swift` file directly under `Sources/macSCPCore/Diagnostics/`,
    /// blanked of comments and strings, must not contain `String(describing:`.
    @Test func noDiagnosticsFileDescribesAnErrorValue() throws {
        let files = try Self.diagnosticsSwiftFiles()
        let namedSources = try files.map {
            (name: $0.lastPathComponent, source: try String(contentsOf: $0, encoding: .utf8))
        }
        let offenders = try Self.offendersDescribingAnErrorValue(in: namedSources)
        #expect(offenders.isEmpty, """
            `String(describing:` found (after blanking comments and strings) in: \
            \(offenders.joined(separator: ", ")) — an arbitrary error's stored \
            properties can carry configuration text (an endpoint's userinfo, a \
            path) straight into a diagnosis row. Map the case to a fixed \
            sentence instead, the way `DialSupport.reason(for:)`'s `RemoteFSError` \
            arm does since `bd6ec81f`.
            """)
    }

    /// The floor beneath the negative check above: the scan must actually be
    /// reaching real files, not an empty or misnamed directory. At least
    /// five — the tree carries 11 at HEAD — and `DialProbes.swift`
    /// specifically, since it is the file the rule's own doc comment lives
    /// in and the file Task 1 changed.
    @Test func theScanReachesTheDirectoryItGuards() throws {
        let files = try Self.diagnosticsSwiftFiles()
        #expect(files.count >= 5, """
            only \(files.count) `.swift` file(s) found under \
            Sources/macSCPCore/Diagnostics/ — the scan is not reaching the \
            directory it is meant to guard (11 at HEAD `79f4aaa0`).
            """)
        #expect(files.contains { $0.lastPathComponent == "DialProbes.swift" }, """
            DialProbes.swift not found under Sources/macSCPCore/Diagnostics/ — \
            the scan is reading the wrong directory.
            """)
    }

    /// The second positive check: the UNBLANKED `DialProbes.swift` still
    /// carries the prose that states the rule, so the negative check above
    /// is known to be reading the right file's actual content and not a
    /// stand-in that happens to contain no matches for any reason.
    @Test func theRuleIsStatedInDialProbesOwnDocComment() throws {
        let source = try String(contentsOf: Self.dialProbesFile, encoding: .utf8)
        #expect(source.contains(Self.ruleClause), """
            DialProbes.swift no longer states the rule this suite enforces \
            ("\(Self.ruleClause)") — either the doc comment moved or was \
            reworded; re-anchor `ruleClause` on whatever replaced it.
            """)
    }

    // MARK: - Scanner self-test (synthetic source, so the scanner cannot
    // silently pass just because the real tree happens to be clean today)

    /// Plants `String(describing: error)` into an in-memory copy and drives
    /// it through the exact function `noDiagnosticsFileDescribesAnErrorValue`
    /// calls — proving the check is sensitive to the thing it exists to
    /// catch, not merely quiet because nothing under `Diagnostics/` trips it
    /// right now.
    @Test func theScanCatchesAPlantedDescribingCall() throws {
        let planted = """
            import Foundation

            enum PlantedDialSupport {
                static func reason(for error: any Error) -> String {
                    // a comment mentioning String(describing:) must not itself
                    // trip the scan — only the call below should
                    String(describing: error)
                }
            }
            """
        let offenders = try Self.offendersDescribingAnErrorValue(
            in: [(name: "Planted.swift", source: planted)])
        #expect(offenders == ["Planted.swift"])
    }

    /// A quoted or commented mention of the needle must survive as neither —
    /// the companion case to the self-test above, pinning that the scanner
    /// blanks before it searches rather than merely finding the call by
    /// accident.
    @Test func aQuotedOrCommentedMentionDoesNotTripTheScan() throws {
        let clean = """
            import Foundation

            enum CleanDialSupport {
                /// Never `String(describing:)` — see the module's own rule.
                static func reason(for error: any Error) -> String {
                    let example = "String(describing: error)"
                    return example.isEmpty ? "" : "fixed sentence"
                }
            }
            """
        let offenders = try Self.offendersDescribingAnErrorValue(
            in: [(name: "Clean.swift", source: clean)])
        #expect(offenders.isEmpty)
    }

    // MARK: - Scanner

    /// Every `.swift` file directly under `Sources/macSCPCore/Diagnostics/`
    /// (no subdirectories at HEAD), sorted for a stable failure message.
    private static func diagnosticsSwiftFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: Self.diagnosticsDirectory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    }

    /// The names (not the full source) of every entry in `namedSources`
    /// whose blanked text contains `needle`. Fails closed: a source this
    /// stripper cannot parse (an unrecognized raw-string delimiter, an
    /// unterminated literal) throws rather than being silently skipped, so
    /// a file the scan cannot read is a test failure, not a pass by
    /// omission.
    private static func offendersDescribingAnErrorValue(
        in namedSources: [(name: String, source: String)]
    ) throws -> [String] {
        try namedSources.compactMap { name, source in
            let stripped = try SwiftSource.stripCommentsAndStrings(source)
            return stripped.contains(Self.needle) ? name : nil
        }
    }
}
