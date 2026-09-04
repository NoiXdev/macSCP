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
/// TWO negative checks, because one spelling of the rule is invisible to
/// the other's text:
///
/// - `noDiagnosticsFileDescribesAnErrorValue` reads text with comments AND
///   string literals blanked, and catches the call written as a statement.
/// - `noDiagnosticsFileBuildsASentenceOutOfAnErrorValue` reads text with
///   only the comments blanked, and catches the call written INSIDE a
///   sentence. It has to: a literal is blanked as one span, from its
///   opening quote to its closing one, so everything a sentence
///   interpolates disappears along with it. A sentence that describes an
///   error, or that interpolates an error value bare, is therefore
///   unreachable for the first check by construction rather than by
///   accident — and interpolating bare is the cheaper of the two to write,
///   since it needs no named call at all. The forbidden names are the exact
///   two an error value is usually bound to, plus every identifier whose
///   name ends in the type's own; `DialProbes.swift`'s `protocolError`
///   comment names the bare spelling as the one a neighbouring module
///   builds its payload with.
///
/// Per CLAUDE.md "Guards that name what they watch", each negative has
/// positives beside it: `theScanReachesTheDirectoryItGuards` (the file count
/// and `DialProbes.swift`'s presence) and
/// `theRuleIsStatedInDialProbesOwnDocComment` (the unblanked file still
/// carries the prose that states the rule this suite enforces, so a negative
/// check is known to be reading the right file and not an empty stand-in for
/// it) hold for both, and the second negative also matches its own patterns
/// against a fixture of real compiling code
/// (`Tests/MacSCPTestSupport/ErrorInterpolationFixture.swift`, which this
/// guard never enumerates — it reads one directory under
/// `Sources/macSCPCore/`). Four further tests run on in-memory sources and
/// drive them through the exact scanning functions the guard itself calls —
/// not a second, hand-written copy of the same logic that could drift from
/// what the guard actually runs. Counted as four in the pass that writes
/// this line: two plant a violation and expect it caught
/// (`theScanCatchesAPlantedDescribingCall`,
/// `theScanCatchesAPlantedSentenceBuiltFromAnError`), and two pin what must
/// stay legal — a quoted or commented mention of either shape
/// (`aQuotedOrCommentedMentionDoesNotTripTheScan`), and an ordinary
/// interpolation of a host, a path or an operation's own name
/// (`anOrdinaryInterpolationDoesNotTripTheScan`), without which the second
/// negative check would be a rule nobody could keep. Eight `@Test`s in all.
///
/// Counted 2026-09-04 at HEAD `6e16b677`: 11 `.swift` files sit under
/// `Sources/macSCPCore/Diagnostics/`, all of them directly in it, none in a
/// subdirectory — `BlockingProbe.swift`, `ConnectionDiagnostics.swift`,
/// `ContributionProbes.swift`, `DiagnosticReason.swift`,
/// `DiagnosticReport.swift`, `DiagnosticStep.swift`, `DialProbes.swift`,
/// `HostResolver.swift`, `ICMPEcho.swift`, `NetworkTrace.swift`,
/// `TCPPing.swift`. The enumeration is recursive all the same, so a file
/// filed into a future subdirectory is guarded on the day it lands rather
/// than on the day someone remembers this scan exists.
///
/// None of the 11 carries a raw-string delimiter (`#"…"#`) at HEAD —
/// `grep -rln '#"' Sources/macSCPCore/Diagnostics/` matches only
/// `DiagnosticStep.swift`, and by hand that hit is a one-character plain
/// string literal, one of the four delimiters a private helper there
/// compares a character against when deciding where a URL's authority ends
/// (a path separator, a query marker, a fragment marker, and whitespace as
/// the fourth test). It is not an opening raw-string delimiter, so both
/// stripping modes read every file here without throwing.
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

    /// The second negative check, over text that keeps its string literals:
    /// no file here builds a SENTENCE out of an error value, whether by
    /// describing it or by interpolating it bare. The first check cannot see
    /// either — a blanked literal takes its interpolations with it.
    @Test func noDiagnosticsFileBuildsASentenceOutOfAnErrorValue() throws {
        let files = try Self.diagnosticsSwiftFiles()
        let namedSources = try files.map {
            (name: $0.lastPathComponent, source: try String(contentsOf: $0, encoding: .utf8))
        }
        let offenders = try Self.offendersInterpolatingAnErrorValue(in: namedSources)
        #expect(offenders.isEmpty, """
            a sentence built out of an error value (after blanking comments \
            only) in: \(offenders.joined(separator: ", ")) — describing an \
            error, or interpolating one bare, prints its stored properties \
            into a row written to be pasted into a public issue. Map the case \
            to a fixed sentence instead, the way `DialSupport.reason(for:)`'s \
            `RemoteFSError` arm does since `bd6ec81f`.
            """)

        // Positive beside it: both shapes match real, compiling code —
        // `ErrorInterpolationFixture.swift` under `Tests/MacSCPTestSupport/`,
        // which this guard never enumerates, so the match it demonstrates
        // can never itself be read back as an offender. Driven through the
        // same function the negative above calls, so what is proven
        // sensitive is the guard's own scanning path.
        let fixture = try String(contentsOf: Self.interpolationFixtureFile, encoding: .utf8)
        let fixtureOffenders = try Self.offendersInterpolatingAnErrorValue(
            in: [(name: "ErrorInterpolationFixture.swift", source: fixture)])
        #expect(fixtureOffenders == ["ErrorInterpolationFixture.swift"], """
            the fixture no longer matches either forbidden shape — the second \
            negative check above is scanning for something nothing in the tree \
            can produce any more; re-anchor it on whatever replaced the shapes.
            """)
    }

    /// The floor beneath both negative checks above: the scan must actually
    /// be reaching real files, not an empty or misnamed directory. At least
    /// five — the tree carries 11 at HEAD — and `DialProbes.swift`
    /// specifically, since it is the file the rule's own doc comment lives
    /// in and the file Task 1 changed.
    @Test func theScanReachesTheDirectoryItGuards() throws {
        let files = try Self.diagnosticsSwiftFiles()
        #expect(files.count >= 5, """
            only \(files.count) `.swift` file(s) found under \
            Sources/macSCPCore/Diagnostics/ — the scan is not reaching the \
            directory it is meant to guard (11 at HEAD `6e16b677`).
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

    /// The companion self-test for the second negative check: each forbidden
    /// shape, planted into an in-memory source, is caught — and a comment
    /// naming either one is not, which is the difference between a check
    /// that reads sentences and one that reads prose about sentences.
    @Test func theScanCatchesAPlantedSentenceBuiltFromAnError() throws {
        let described = """
            enum PlantedDescribing {
                static func reason(for error: any Error) -> String {
                    return "the connection failed: \\(String(describing: error))"
                }
            }
            """
        let bare = """
            enum PlantedBare {
                static func reason(for error: any Error) -> String {
                    return "the connection failed: \\(error)"
                }
            }
            """
        let suffixed = """
            enum PlantedSuffixed {
                static func reason(for dialError: any Error) -> String {
                    return "the connection failed: \\(dialError)"
                }
            }
            """
        let commented = """
            enum CleanCommented {
                // `SSHAgentClient` builds its payload as "\\(error)", and
                // `SSHPrivateKeyLoader` as "\\(String(describing: error))" —
                // both named here, neither written here.
                static func reason(for error: any Error) -> String {
                    _ = error
                    return "the connection failed"
                }
            }
            """
        #expect(
            try Self.offendersInterpolatingAnErrorValue(
                in: [(name: "Describing.swift", source: described)]) == ["Describing.swift"])
        #expect(
            try Self.offendersInterpolatingAnErrorValue(
                in: [(name: "Bare.swift", source: bare)]) == ["Bare.swift"])
        #expect(
            try Self.offendersInterpolatingAnErrorValue(
                in: [(name: "Suffixed.swift", source: suffixed)]) == ["Suffixed.swift"])
        #expect(
            try Self.offendersInterpolatingAnErrorValue(
                in: [(name: "Commented.swift", source: commented)]).isEmpty)
    }

    /// A sentence that interpolates something that is not an error value must
    /// stay legal — the module's own rows are built out of hosts, paths and
    /// durations, and a check that rejected every interpolation would be a
    /// rule nobody could keep.
    @Test func anOrdinaryInterpolationDoesNotTripTheScan() throws {
        let clean = """
            enum CleanRows {
                static func row(host: String, path: String, operation: Operation) -> String {
                    return "no key file at \\(path) for \\(host): \\(operation.rawValue)"
                }
            }
            """
        let offenders = try Self.offendersInterpolatingAnErrorValue(
            in: [(name: "Clean.swift", source: clean)])
        #expect(offenders.isEmpty)
    }

    // MARK: - Scanner

    /// Every `.swift` file under `Sources/macSCPCore/Diagnostics/`,
    /// RECURSIVELY — all 11 sit directly in it at HEAD, and the recursion is
    /// what keeps that from being load-bearing: a file filed into a
    /// subdirectory later would otherwise leave the guarded module through a
    /// change that never touches this suite. Sorted for a stable failure
    /// message.
    private static func diagnosticsSwiftFiles() throws -> [URL] {
        guard
            let walk = FileManager.default.enumerator(
                at: Self.diagnosticsDirectory, includingPropertiesForKeys: nil)
        else {
            // Fails closed, like the stripper: an unreadable directory is a
            // scan that checked nothing, and reporting it as zero offenders
            // would read exactly like a clean tree.
            throw EnumerationError.directoryUnreadable
        }
        return walk.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// Raised when the guarded directory cannot be walked at all.
    private enum EnumerationError: Error {
        case directoryUnreadable
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

    /// The names of every entry whose COMMENT-stripped text (literals kept)
    /// builds a sentence out of an error value: either by describing one
    /// inside an interpolation, or by interpolating a value bound to one of
    /// the forbidden names bare. Fails closed the same way its sibling does.
    private static func offendersInterpolatingAnErrorValue(
        in namedSources: [(name: String, source: String)]
    ) throws -> [String] {
        try namedSources.compactMap { name, source in
            let text = try SwiftSource.stripComments(source)
            if text.contains(Self.describingInterpolation) { return name }
            let bareInterpolation = try NSRegularExpression(pattern: Self.bareInterpolationPattern)
            let range = NSRange(text.startIndex..., in: text)
            let matched = bareInterpolation.matches(in: text, range: range).contains {
                guard let identifier = Range($0.range(at: 1), in: text) else { return false }
                return Self.namesAnErrorValue(String(text[identifier]))
            }
            return matched ? name : nil
        }
    }

    /// The describing call as it appears inside a sentence — the opening of
    /// an interpolation followed by the call, so a `String(describing:)`
    /// written as a statement stays the other check's business and this one
    /// reports only what actually reaches a rendered row.
    private static let describingInterpolation = "\\(String(describing:"

    /// An interpolation of a single bare identifier: the opening of an
    /// interpolation, one identifier, the closing paren, and nothing else
    /// between them. A member access (`\(operation.rawValue)`) or a call
    /// therefore does not match — those are values this module renders on
    /// purpose, and only the error value itself is forbidden.
    private static let bareInterpolationPattern = #"\\\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)"#

    /// The two exact names an error value is bound to in this module,
    /// counted as two in the pass that writes this line: the name every
    /// `catch` binds by default, and its short form.
    private static let errorValueNames: Set<String> = ["error", "err"]

    /// The suffix half of the rule: any identifier ENDING in the error
    /// type's own name — `dialError`, `loaderError`, `underlyingError` —
    /// names an error value under a longer spelling, and a check anchored on
    /// the two exact names above would buy every one of them.
    private static let errorValueNameSuffix = "Error"

    private static func namesAnErrorValue(_ identifier: String) -> Bool {
        Self.errorValueNames.contains(identifier)
            || identifier.hasSuffix(Self.errorValueNameSuffix)
    }

    /// Real compiling code in both forbidden shapes, for the second negative
    /// check's positive. Under `Tests/MacSCPTestSupport/`, which this guard
    /// never enumerates.
    private static let interpolationFixtureFile = repoRoot
        .appendingPathComponent("Tests/MacSCPTestSupport/ErrorInterpolationFixture.swift")
}
