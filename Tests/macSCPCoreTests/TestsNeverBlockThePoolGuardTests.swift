import Foundation
import Testing

/// Holds the whole test corpus to CLAUDE.md's "Tests never block the
/// cooperative pool": Swift Testing runs every test on the cooperative pool,
/// that pool is exactly as wide as the machine has cores, and a test that
/// blocks one of its threads takes that share of the package's concurrency
/// away from the other three thousand tests. On the three-core CI runner
/// three such tests were enough to sit at 0 % CPU until the timeout; ten
/// local cores hid it completely. The measurement is
/// `docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`.
///
/// The scan is a NEGATIVE check — it wants to find nothing — and CLAUDE.md's
/// "Guards that name what they watch" is explicit that only a negative check
/// can go stale in silence. So it does not stand alone:
///
/// - `theRunnerExists` pins `SubprocessRunner.run` at COMPILE time, by
///   binding it to a function value. Rename or reshape it and this file stops
///   compiling; there is no spelling here that can quietly stop matching.
/// - `everyCLISuiteRunsItsChildThroughTheRunner` names the four suites by
///   TYPE and derives their file names and the call text from those types,
///   so the same rename breaks the anchor rather than emptying it.
/// - `everyAllowlistEntryIsStillNeeded` fails on an entry whose file no
///   longer carries the pattern it excuses. The allowlist can only shrink,
///   which is what Task 1b does to it.
/// - `theScannerSeesCodeAndIgnoresComments` plants both kinds of occurrence
///   in a synthetic source and requires exactly one of them to be found.
/// - `theGuardsOwnSourceCarriesEveryPatternItLooksFor` reads THIS file off
///   disk through the same enumeration the scan uses and requires every
///   pattern to turn up in it, so "the scan found nothing" can never mean
///   "the scan read nothing".
@Suite("Tests never block the cooperative pool")
struct TestsNeverBlockThePoolGuardTests {
    /// The blocking waits forbidden in a test target, as measured by the grep
    /// in `.superpowers/sdd/2026-09-03-subprocess-runner-async/task-1-brief.md`.
    ///
    /// `DispatchGroup` is here whole rather than as `.wait(`: the only reason
    /// a test in this corpus ever built one was to block on it, and the
    /// non-blocking alternative (`notify(queue:)`) appears nowhere. Matching
    /// the type name refuses the shape instead of one spelling of the wait.
    enum BlockingWait: String, CaseIterable, Sendable {
        case waitUntilExit = "waitUntilExit()"
        case dispatchSemaphore = "DispatchSemaphore"
        case dispatchGroup = "DispatchGroup"
        case syncShutdownGracefully = "syncShutdownGracefully("
        case futureResultWait = "futureResult.wait()"
        case threadSleep = "Thread.sleep"
        case usleep = "usleep("
    }

    /// Files that still carry a blocking wait `Task 1b` did not convert,
    /// keyed by their path under `Tests/`.
    ///
    /// The seventeen files the 2026-09-03 grep found (after the long waits
    /// were converted) came down to two: Task 1b replaced every
    /// `Process`/`waitUntilExit()` short child wait in `macSCPCoreTests`
    /// with `SubprocessRunner.run` — fifteen files, thirteen of them a test
    /// suite plus `Support/InstalledKey.swift` and `Support/SpawnedAgent.swift`.
    /// A third was added later by the diagnostics trace, so the list holds
    /// **three** entries; none of them is Task 1b's to remove, and each says
    /// why in its own comment.
    ///
    /// `everyAllowlistEntryIsStillNeeded` below is what keeps the list
    /// honest: an entry whose file no longer carries its pattern is a
    /// failure, not a leftover.
    static let allowed: [String: Set<BlockingWait>] = [
        // Not a subprocess wait: a deliberate main-thread block, planted on
        // a `DispatchQueue.global()` thread to prove the connect path does
        // not need the main actor. Blocking is the measurement there.
        "macSCPCoreTests/ConnectMainActorLivenessTests.swift": [.usleep],

        // `Docker.run`: sub-second docker calls behind `defer`, unbounded by
        // contract. Sub-second is what they measure — `docker ps`, `rm -f`,
        // `pause` — but nothing in the code says so, and `pruneLeftovers`'s
        // retry loop calls three of them per iteration for up to fifteen
        // seconds, so the reduction there is real but partial. Converting
        // needs a shared test-support target: this file is in
        // `macSCPAppKitTests`, which cannot see `SubprocessRunner`, and its
        // six `defer`-bound teardowns cannot host an `await`. Task 1b
        // decision.
        "macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift":
            [.dispatchGroup, .waitUntilExit],

        // Not a wait on a cooperative-pool thread and not convertible into
        // one: `anOuterMarginOverrunKeepsTheHopsTheWalkHadMeasured` has to
        // overrun `BlockingProbe`'s margin, which is a real Dispatch timer,
        // and the only place it can do that from is the body `BlockingProbe`
        // runs on its OWN private queue — the same queue the production walk
        // parks in `poll` on. The case's other fixture used to sleep too and
        // no longer does: it drives the walk over an injected clock instead
        // (`NetworkTrace.walk(now:)`), which is why this entry names one
        // pattern and not two.
        "macSCPCoreTests/NetworkTraceTests.swift": [.threadSleep],
    ]

    // MARK: - The negative check

    @Test func noTestSourceCarriesAnUnallowedBlockingWait() throws {
        var violations: [String] = []
        for file in try Self.testSources() where file != Self.ownRelativePath {
            let source = Self.strippingComments(try String(contentsOf: Self.url(for: file), encoding: .utf8))
            let excused = Self.allowed[file] ?? []
            for pattern in BlockingWait.allCases
            where source.contains(pattern.rawValue) && !excused.contains(pattern) {
                violations.append("\(file): \(pattern.rawValue)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            a test source blocks a cooperative-pool thread. Await the child \
            through `SubprocessRunner.run` (Tests/macSCPCoreTests/Support), or \
            — if the wait is short and its conversion belongs to a later pass \
            — add it to `allowed` with the reason:
            \(violations.sorted().joined(separator: "\n"))
            """)
    }

    // MARK: - Positive anchors

    /// Compile-time, not textual: if `run` is renamed, moved or reshaped,
    /// this binding stops compiling. A guard that only spelled the name
    /// would go on passing while the thing it names had gone.
    @Test func theRunnerExists() throws {
        let run:
            (URL, [String], [String: String]?, URL?, Data?, Duration) async throws
            -> SubprocessResult = SubprocessRunner.run
        _ = run

        let file = "macSCPCoreTests/Support/\(String(describing: SubprocessRunner.self)).swift"
        #expect(try Self.testSources().contains(file), "\(file) is not where the scan can see it")
        let source = try String(contentsOf: Self.url(for: file), encoding: .utf8)
        #expect(source.contains("enum \(String(describing: SubprocessRunner.self))"))
    }

    /// The four suites that drove `macscp-cli` through a blocking harness
    /// now drive it through the runner. Both the file to read and the call to
    /// look for are derived from types, so a rename breaks compilation here
    /// rather than turning the check into one that matches nothing.
    @Test func everyCLISuiteRunsItsChildThroughTheRunner() throws {
        let suites: [Any.Type] = [
            CLIRootHelpTests.self,
            CLIRoundtripITests.self,
            CLISessionNameCompletionTests.self,
            CLISessionsJSONRoundtripTests.self,
        ]
        let call = "\(String(describing: SubprocessRunner.self)).run("
        for suite in suites {
            let file = "macSCPCoreTests/\(String(describing: suite)).swift"
            let source = Self.strippingComments(
                try String(contentsOf: Self.url(for: file), encoding: .utf8))
            #expect(source.contains(call), "\(file) does not call \(call)")
        }
    }

    /// An allowlist entry is a claim that a file still carries that wait.
    /// When it stops being true the entry goes, and until it does this fails
    /// — which is how the list shrinks to empty instead of rotting into a
    /// permission nobody needs any more.
    @Test func everyAllowlistEntryIsStillNeeded() throws {
        let present = Set(try Self.testSources())
        for (file, patterns) in Self.allowed {
            guard present.contains(file) else {
                Issue.record("allowlisted file \(file) no longer exists — drop the entry")
                continue
            }
            let source = Self.strippingComments(
                try String(contentsOf: Self.url(for: file), encoding: .utf8))
            for pattern in patterns where !source.contains(pattern.rawValue) {
                Issue.record("\(file) no longer carries \(pattern.rawValue) — drop it from `allowed`")
            }
        }
    }

    /// The sensitivity measurement: a violation written as code is found, the
    /// same text written as a comment is not.
    ///
    /// The second half is not hypothetical. `SSHPrivateKeyLoaderTests` has a
    /// doc comment naming `futureResult.wait()` and `syncShutdownGracefully()`
    /// as the very things it explains the absence of, and this file quotes
    /// nothing in prose for the same reason — CLAUDE.md, "Source-scanning
    /// guards read comments too".
    @Test func theScannerSeesCodeAndIgnoresComments() {
        for pattern in BlockingWait.allCases {
            let asCode = Self.strippingComments("let x = foo.\(pattern.rawValue)\n")
            #expect(asCode.contains(pattern.rawValue), "a code occurrence of \(pattern) was lost")

            let asLineComment = Self.strippingComments("    // \(pattern.rawValue) is forbidden\n")
            #expect(
                asLineComment.contains(pattern.rawValue) == false,
                "a `//` comment naming \(pattern) survived the stripper")

            let asDocComment = Self.strippingComments("/// see \(pattern.rawValue)\n")
            #expect(
                asDocComment.contains(pattern.rawValue) == false,
                "a `///` comment naming \(pattern) survived the stripper")
        }
    }

    /// Proves the scan reads real files rather than an empty corpus: this
    /// file is reached through the same enumeration, and every pattern the
    /// scan looks for is in it (as the `BlockingWait` cases above).
    @Test func theGuardsOwnSourceCarriesEveryPatternItLooksFor() throws {
        let files = try Self.testSources()
        #expect(files.contains(Self.ownRelativePath))
        // Measured 2026-09-03: 318 `.swift` files under `Tests/`
        // (`find Tests -name '*.swift' | wc -l`). A lower bound rather than
        // the number, so adding a test file is not a failure — but an
        // enumeration that collapses is. This count has already drifted
        // twice in this branch (316 -> 317 -> 318); it is written down as a
        // measurement of the moment, not a fact to keep in sync.
        #expect(files.count > 200, "the scan enumerated only \(files.count) files")

        let source = Self.strippingComments(
            try String(contentsOf: Self.url(for: Self.ownRelativePath), encoding: .utf8))
        for pattern in BlockingWait.allCases {
            #expect(source.contains(pattern.rawValue), "\(pattern) is not in the guard's own source")
        }
    }

    // MARK: - Reading the corpus

    /// `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/<this file>.swift`;
    /// two `deletingLastPathComponent()` calls reach `Tests/` regardless of
    /// `swift test`'s working directory (same trick as
    /// `LocalizableStringsTests`).
    ///
    /// Kept as a String with any trailing separator removed:
    /// `deletingLastPathComponent()` leaves one behind, and a doubled `/` in
    /// the prefix matched no file at all — a scan over an empty corpus, which
    /// is exactly the silent pass this guard must not be able to have.
    private static let testsRootPath: String = {
        var path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }()

    private static let testsRoot = URL(fileURLWithPath: testsRootPath, isDirectory: true)

    /// This file, as the scan addresses it. Excluded from the scan because
    /// `BlockingWait`'s raw values are the patterns themselves;
    /// `theGuardsOwnSourceCarriesEveryPatternItLooksFor` turns that exclusion
    /// into a measurement rather than a blind spot.
    private static let ownRelativePath = String(
        URL(fileURLWithPath: #filePath).path(percentEncoded: false)
            .dropFirst(testsRootPath.count + 1))

    private static func url(for relativePath: String) -> URL {
        testsRoot.appendingPathComponent(relativePath)
    }

    /// Every `.swift` file under `Tests/`, as paths relative to it.
    private static func testSources() throws -> [String] {
        let prefix = testsRootPath + "/"
        guard let walker = FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: nil)
        else { throw GuardError("cannot enumerate \(testsRootPath)") }
        return walker.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            let path = url.path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }
    }

    /// Blanks out lines that are wholly a comment.
    ///
    /// Whole lines only, deliberately. Cutting from a mid-line `//` would
    /// truncate string literals that contain one — a URL is the obvious case
    /// — and every byte lost that way is a violation this guard could no
    /// longer see. A trailing comment left standing can at worst raise a
    /// false alarm, which is loud, and this guard is a negative check: the
    /// failure mode it must not have is the quiet one.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    return ""
                }
                return line
            }
            .joined(separator: "\n")
    }

    private struct GuardError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
