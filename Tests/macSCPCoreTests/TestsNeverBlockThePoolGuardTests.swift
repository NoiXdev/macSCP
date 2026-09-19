import Foundation
import macSCPCore
import MacSCPTestSupport
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
///   The runner lives in `macSCPCore` at `package` scope since 2026-09-19
///   (the CI-starvation plan, Task 2), so production code awaits its
///   children through the same runner the tests do.
/// - `everyCLISuiteRunsItsChildThroughTheRunner` names the four suites by
///   TYPE and derives their file names and the call text from those types,
///   so the same rename breaks the anchor rather than emptying it.
/// - `everyAllowlistEntryIsStillNeeded` fails on an entry whose file no
///   longer carries the pattern it excuses. The allowlist can only shrink,
///   which is what Task 1b does to it.
/// - `theScannerSeesCodeAndIgnoresComments` plants both kinds of occurrence
///   in a synthetic source and requires exactly one of them to be found.
/// - `theGuardsOwnSourceCarriesEveryPatternItLooksFor` reads THIS file
///   through the same corpus listing the scan uses and requires every
///   pattern to turn up in it, so "the scan found nothing" can never mean
///   "the scan read nothing".
///
/// ## `Sources/` too, for one pattern
///
/// The scan above covers `Tests/` only, and the 2026-09-19 measurement
/// (CI run 35405472152) found the pool held from the other side: some 800
/// samples of test threads parked in a child-process wait inside
/// `SSHKeyGenerator` and `SSHKeyImporter`, reached from key tests that
/// were themselves clean. Those now await `SubprocessRunner.run`, and
/// `noSourceWaitsForAChildOutsideTheRunner` holds all of `Sources/` to
/// that for `BlockingWait.waitUntilExit` — the one pattern that is always
/// a wait for a child, and for which the runner is the replacement. The
/// other patterns stay `Tests/`-only: `Sources/` blocks on purpose in
/// places that run off the pool by design (a semaphore inside a
/// synchronous protocol requirement, say), and each of those would need
/// its own reading before it could be allowlisted here. The two files the
/// runner is made of moved out of `Tests/` in the same change and are
/// still scanned for EVERY pattern, as they were before the move.
/// Positives beside it: `everySourcesAllowlistEntryIsStillNeeded`,
/// `theKeyToolsAwaitTheRunner`, and `theSourcesScanReadsCodeNotProse`.
///
/// ## No second runner
///
/// `SSHKeyConverter` awaited `ssh-keygen` with its own small continuation
/// wrapper around `Process.terminationHandler` until 2026-09-19 (Task 3 of
/// the small-follow-ups plan) — it never parked a thread, so it carried none
/// of the `BlockingWait` patterns above and the `Sources/` scan never saw
/// it, but it was still a second place a child's exit was awaited, which is
/// exactly what `SubprocessRunner` exists to be the only one of (recorded in
/// `docs/BACKLOG.md`, "Task 2's deferred minors: the async key-tool
/// surface"). `noSourceImplementsASecondTerminationHandlerRunner` holds all
/// of `Sources/`, `SubprocessRunner.swift` itself excepted, to assigning no
/// `.terminationHandler =` of its own. Positive beside it:
/// `theKeyToolsAwaitTheRunner`, extended the same day to require
/// `SSHKeyConverter.swift` to call `SubprocessRunner.run(` too.
@Suite("Tests never block the cooperative pool")
struct TestsNeverBlockThePoolGuardTests {
    /// The blocking waits forbidden in a test target, as measured by the grep
    /// in `.superpowers/sdd/2026-09-03-subprocess-runner-async/task-1-brief.md`.
    ///
    /// `DispatchGroup` is here whole rather than as `.wait(`: the only reason
    /// a test in this corpus ever built one was to block on it, and the
    /// non-blocking alternative (`notify(queue:)`) appears nowhere. Matching
    /// the type name refuses the shape instead of one spelling of the wait.
    ///
    /// `NSCondition` is here for the same reason and was added on
    /// 2026-09-03, after a review found the enum blind to a primitive this
    /// corpus had just started using: a commit removed a `Thread.sleep`
    /// allowlist entry and replaced the sleep with a condition-variable wait,
    /// so the list below shrank while the scan's reach did. A condition
    /// variable has no non-blocking spelling at all — its whole API is a
    /// thread parked until a broadcast — so the type name is the shape.
    ///
    /// Counted the same day: this corpus carries no `pthread_cond` and no
    /// `os_unfair_lock`, so neither is listed. A case for a primitive that
    /// occurs nowhere would be a negative check with nothing behind it, and
    /// `theGuardsOwnSourceCarriesEveryPatternItLooksFor` is the only thing
    /// that would ever exercise it.
    enum BlockingWait: String, CaseIterable, Sendable {
        case waitUntilExit = "waitUntilExit()"
        case dispatchSemaphore = "DispatchSemaphore"
        case dispatchGroup = "DispatchGroup"
        case syncShutdownGracefully = "syncShutdownGracefully("
        case futureResultWait = "futureResult.wait()"
        case threadSleep = "Thread.sleep"
        case usleep = "usleep("
        case nsCondition = "NSCondition"
    }

    /// Files that still carry a blocking wait `Task 1b` did not convert,
    /// keyed by their path under `Tests/`.
    ///
    /// The seventeen files the 2026-09-03 grep found (after the long waits
    /// were converted) came down to two: Task 1b replaced every
    /// `Process`/`waitUntilExit()` short child wait in `macSCPCoreTests`
    /// with `SubprocessRunner.run` — fifteen files, thirteen of them a test
    /// suite plus `Support/InstalledKey.swift` and `Support/SpawnedAgent.swift`.
    /// The diagnostics trace added a third later and then took it back:
    /// `anOuterMarginOverrunKeepsTheHopsTheWalkHadMeasured` parked on a
    /// `Thread.sleep` to outlast an outer margin, and now parks on a gate the
    /// margin itself opens.
    ///
    /// That last one was recorded as a shrink and was not one, which is worth
    /// keeping written down: the wait did not go away, it moved to
    /// `NSCondition` — a primitive `BlockingWait` did not list, so the entry
    /// could be deleted while the scan stopped seeing the file at all. The
    /// enum learned the primitive on 2026-09-03 and the file is back on this
    /// list, with the reason it is excused rather than the reason it was
    /// removed. **Three** entries remain, counted here in this edit; none is
    /// Task 1b's to remove, and each says why in its own comment.
    ///
    /// `everyAllowlistEntryIsStillNeeded` below is what keeps the list
    /// honest: an entry whose file no longer carries its pattern is a
    /// failure, not a leftover.
    static let allowed: [String: Set<BlockingWait>] = [
        // Not a subprocess wait: a deliberate block, held so the main actor
        // can be watched NOT stalling while a dial holds a thread. Blocking
        // is the measurement there.
        //
        // Corrected 2026-09-03 by reading rather than remembering: this entry
        // used to say the block was planted on a `DispatchQueue.global()`
        // thread. That file contains no Dispatch queue at all — the one
        // caller of its blocking helper sits inside an injected `@Sendable`
        // async connector, i.e. on a cooperative-pool thread, which the case
        // itself says. The excusal stands (600 ms, capped for exactly this
        // reason, with the rest of the dial a suspension); the old reason
        // did not, and `everyAllowlistEntryIsStillNeeded` checks the pattern,
        // never the prose beside it.
        "macSCPCoreTests/ConnectMainActorLivenessTests.swift": [.usleep],

        // `Docker.run`: sub-second docker calls behind `defer`, unbounded by
        // contract. Sub-second is what they measure — `docker ps`, `rm -f`,
        // `pause` — but nothing in the code says so, and `pruneLeftovers`'s
        // retry loop calls three of them per iteration for up to fifteen
        // seconds, so the reduction there is real but partial. Task 1b left
        // it for two reasons. One is gone: this file is in
        // `macSCPAppKitTests`, which could not see `SubprocessRunner` while
        // the runner was a `macSCPCoreTests` file — it has been a `package`
        // type in `macSCPCore` since 2026-09-19. The other stands: its six
        // `defer`-bound teardowns cannot host an `await`.
        "macSCPAppKitTests/LivenessProbeDropIntegrationTests.swift":
            [.dispatchGroup, .waitUntilExit],

        // `BlockingGate`, and the one call that waits on it, park on
        // `BlockingProbe`'s own queue — never the cooperative pool. Read,
        // 2026-09-03, rather than assumed: `NetworkTrace.run` hands its walk
        // closure to `BlockingProbe.run`, whose body runs inside
        // `DispatchQueue(label:).async` (`BlockingProbe.swift`), a queue
        // created for that one call. The gate's wait is therefore on a
        // private Dispatch thread, which is exactly where the `Thread.sleep`
        // it replaced ran.
        //
        // It stays on this list rather than being converted because the
        // closure it sits in is SYNCHRONOUS by contract — `BlockingProbe`
        // exists to run blocking probe code off the pool, and its parameter
        // is not `async`, so there is no `await` to convert the wait into.
        // The call carries no deadline of its own (a `Date`-based one used
        // to; retired 2026-09-04 as a wall-clock ceiling under another
        // spelling) — it blocks until the gate opens, and the case that
        // joins it asserts that the gate was opened, ending on time through
        // the suite's own `.timeLimit` rather than through this wait.
        "macSCPCoreTests/NetworkTraceTests.swift": [.nsCondition],
    ]

    // MARK: - The negative check

    @Test func noTestSourceCarriesAnUnallowedBlockingWait() throws {
        var violations: [String] = []
        for file in try Self.testSources() where file != Self.ownRelativePath {
            let source = Self.strippingComments(try SourceCorpus.text(of: Self.url(for: file)))
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
            through `SubprocessRunner.run` (Sources/macSCPCore/Subprocess), or \
            — if the wait is short and its conversion belongs to a later pass \
            — add it to `allowed` with the reason:
            \(violations.sorted().joined(separator: "\n"))
            """)
    }

    // MARK: - Positive anchors

    /// Compile-time, not textual: if `run` is renamed, moved or reshaped,
    /// this binding stops compiling. A guard that only spelled the name
    /// would go on passing while the thing it names had gone.
    ///
    /// It has done exactly that twice, and the last trailing parameter is
    /// the newer one: `onStarted` — the child's pid, handed over once so a
    /// caller can SIGNAL a child rather than only read it — was added on
    /// 2026-09-06 for `CLIMatrix.runUntilLine`, and this binding was the
    /// only thing in the tree that stopped compiling when it landed.
    @Test func theRunnerExists() throws {
        let run:
            (
                URL, [String], [String: String]?, URL?, Data?, Duration,
                (@Sendable (Data) -> Void)?, (@Sendable (Data) -> Void)?,
                (@Sendable (Int32) -> Void)?
            )
            async throws -> SubprocessResult = SubprocessRunner.run
        _ = run

        let file = try Self.runnerFile(named: String(describing: SubprocessRunner.self))
        let source = try SourceCorpus.code(of: file)
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
                try SourceCorpus.text(of: Self.url(for: file)))
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
                try SourceCorpus.text(of: Self.url(for: file)))
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
        // Measured 2026-09-03: 331 `.swift` files under `Tests/`
        // (`find Tests -name '*.swift' | wc -l`). A lower bound rather than
        // the number, so adding a test file is not a failure — but an
        // enumeration that collapses is. Measured over every commit that
        // touched this file, the count went 314 -> 316 -> 318 -> 331 (three
        // changes; the plan that wrote 331 changed it once); it is
        // written down as a measurement of the moment, not a fact to keep in
        // sync, and re-running the command above is the only way to state it.
        #expect(files.count > 200, "the scan enumerated only \(files.count) files")

        let source = Self.strippingComments(
            try SourceCorpus.text(of: Self.url(for: Self.ownRelativePath)))
        for pattern in BlockingWait.allCases {
            #expect(source.contains(pattern.rawValue), "\(pattern) is not in the guard's own source")
        }
    }

    // MARK: - Sources: a child is awaited through the runner

    /// `Sources/` files, keyed by their path under `Sources/`, that still
    /// wait for a child with `BlockingWait.waitUntilExit`.
    ///
    /// One entry, counted 2026-09-19 in this edit. It is not a key tool, and
    /// converting it is not this change's to do: `PasswordCommandSecretSource`
    /// implements `SecretSource.secret(for:)`, which is synchronous, so there
    /// is no `await` to turn its wait into without changing that protocol for
    /// every source that implements it. Both of its waits come after the
    /// child's stdout has been drained or the child has been signalled — a
    /// short wait for a reap, not for the command's work — but that is a
    /// reading of the code, not a measurement of which thread it runs on.
    static let sourcesAllowed: [String: Set<BlockingWait>] = [
        "macSCPCore/Sessions/CLISecretSources.swift": [.waitUntilExit],
    ]

    /// The negative: no `Sources/` file waits for a child with a blocking
    /// wait outside the allowlist; the runner's own files carry no blocking
    /// wait of any kind. Read from the corpus's code view
    /// (`SwiftSource.blankingCommentsAndStrings`), so a comment that names
    /// the wait — the runner's own doc comment does — is not a call.
    ///
    /// Only files whose RAW text mentions a pattern are blanked and read:
    /// blanking can only remove an occurrence (a comment or literal turned to
    /// spaces), never create one, so a file whose bytes never spell the
    /// pattern cannot hold it as code either. Measured 2026-09-19 without
    /// this pre-filter: blanking every `Sources/` file cost this test about
    /// 2.5 s of pool thread-time per run (`SwiftSource.blank` leaves); with
    /// it, the two runner files and the handful that mention the wait are
    /// blanked. `theSourcesScanReadsCodeNotProse` keeps one of those in view.
    @Test func noSourceWaitsForAChildOutsideTheRunner() throws {
        let runnerFiles = try Self.runnerFiles()
        let candidates = try Self.sourceFiles().filter { file in
            try runnerFiles.contains(file.url)
                || SourceCorpus.text(of: file.url).contains(BlockingWait.waitUntilExit.rawValue)
        }
        // Positive for the pre-filter: it keeps the runner's files and the
        // allowlisted one, so it cannot have emptied the scan.
        #expect(candidates.count >= runnerFiles.count + Self.sourcesAllowed.count, "\(candidates.map(\.relative))")
        let files = candidates
        let codes = try SourceCorpus.code(ofAll: files.map(\.url))
        var violations: [String] = []
        for (file, code) in zip(files, codes) {
            let patterns: [BlockingWait] = runnerFiles.contains(file.url)
                ? BlockingWait.allCases : [.waitUntilExit]
            let excused = Self.sourcesAllowed[file.relative] ?? []
            for pattern in patterns
            where code.contains(pattern.rawValue) && !excused.contains(pattern) {
                violations.append("\(file.relative): \(pattern.rawValue)")
            }
        }
        #expect(
            violations.isEmpty,
            """
            a source file waits for a child by blocking its thread. Await it \
            through `SubprocessRunner.run` (Sources/macSCPCore/Subprocess):
            \(violations.sorted().joined(separator: "\n"))
            """)
    }

    /// Positive for the scan's reach: it enumerated `Sources/` rather than
    /// nothing, and the runner's two files are among what it read.
    /// Measured 2026-09-19: 387 `.swift` files under `Sources/` after this
    /// change (`find Sources -name '*.swift' | wc -l`). A lower bound, for
    /// the reason `theGuardsOwnSourceCarriesEveryPatternItLooksFor` gives
    /// for its own.
    @Test func theSourcesScanReadsTheWholeTree() throws {
        let files = try Self.sourceFiles().map(\.url)
        #expect(files.count > 300, "the Sources scan enumerated only \(files.count) files")
        for runner in try Self.runnerFiles() {
            #expect(files.contains(runner), "\(runner.lastPathComponent) is not in the Sources scan")
        }
    }

    /// An entry is a claim that its file still carries the wait. It is also
    /// the scan's proof that it sees a real call in `Sources/`: the entry
    /// can only be satisfied by the same code view the negative reads.
    @Test func everySourcesAllowlistEntryIsStillNeeded() throws {
        let files = Dictionary(uniqueKeysWithValues: try Self.sourceFiles().map { ($0.relative, $0.url) })
        for (file, patterns) in Self.sourcesAllowed {
            guard let url = files[file] else {
                Issue.record("allowlisted source \(file) no longer exists — drop the entry")
                continue
            }
            let code = try SourceCorpus.code(of: url)
            for pattern in patterns where !code.contains(pattern.rawValue) {
                Issue.record("\(file) no longer carries \(pattern.rawValue) — drop it from `sourcesAllowed`")
            }
        }
    }

    /// The positive the negative's replacement rests on: all three key tools
    /// call the runner. File names and the call text are derived from the
    /// types, so a rename breaks compilation here instead of emptying the
    /// check. `SSHKeyConverter` joined the other two on 2026-09-19 (Task 3
    /// of the small-follow-ups plan), and is also
    /// `noSourceImplementsASecondTerminationHandlerRunner`'s positive below.
    @Test func theKeyToolsAwaitTheRunner() throws {
        let call = "\(String(describing: SubprocessRunner.self)).run("
        let files = try Self.sourceFiles()
        for tool in [
            String(describing: SSHKeyGenerator.self),
            String(describing: SSHKeyImporter.self),
            String(describing: SSHKeyConverter.self),
        ] {
            let matches = files.filter { $0.url.lastPathComponent == "\(tool).swift" }
            #expect(matches.count == 1, "\(tool).swift: \(matches.count) files")
            for match in matches {
                #expect(try SourceCorpus.code(of: match.url).contains(call), "\(match.relative) does not call \(call)")
            }
        }
    }

    /// The negative pinned by the positive above: no `Sources/` file other
    /// than the runner's own implements a second, hand-rolled wait for a
    /// child by assigning its own `Process.terminationHandler`.
    /// `SSHKeyConverter` did exactly that until this same change — a small
    /// continuation wrapper that never parked a thread, so it carried none
    /// of the `BlockingWait` patterns `noSourceWaitsForAChildOutsideTheRunner`
    /// scans for and that scan never caught it. It was still a second
    /// runner, which is what this holds `Sources/` to having none of.
    ///
    /// The runner's own file is excluded by identity (the URL the walk
    /// found it at), not by a second spelling of its name, so renaming
    /// `SubprocessRunner.swift` cannot quietly widen this check's blind
    /// spot — `runnerFile(named:)` would fail to resolve it first, and
    /// every other test that calls it would fail too.
    @Test func noSourceImplementsASecondTerminationHandlerRunner() throws {
        let pattern = "terminationHandler ="
        let runnerFile = try Self.runnerFile(named: String(describing: SubprocessRunner.self))
        let candidates = try Self.sourceFiles().filter { file in
            try file.url != runnerFile
                && SourceCorpus.text(of: file.url).contains(pattern)
        }
        let codes = try SourceCorpus.code(ofAll: candidates.map(\.url))
        var violations: [String] = []
        for (file, code) in zip(candidates, codes) where code.contains(pattern) {
            violations.append(file.relative)
        }
        #expect(
            violations.isEmpty,
            """
            a source file outside SubprocessRunner.swift assigns its own \
            `.terminationHandler =` — a second, hand-rolled wait for a child \
            process. Await it through `SubprocessRunner.run` \
            (Sources/macSCPCore/Subprocess) instead:
            \(violations.sorted().joined(separator: "\n"))
            """)
    }

    /// Sensitivity: the Sources scan reads code, not prose. The runner's own
    /// doc comment names the blocking wait it replaces, so the file's raw
    /// text carries the pattern while its code view must not — which proves
    /// both that the file is read and that the comment is not what is read.
    @Test func theSourcesScanReadsCodeNotProse() throws {
        let file = try Self.runnerFile(named: String(describing: SubprocessRunner.self))
        let pattern = BlockingWait.waitUntilExit.rawValue
        #expect(try SourceCorpus.text(of: file).contains(pattern))
        #expect(try SourceCorpus.code(of: file).contains(pattern) == false)
    }

    /// `Sources/` under the package root, as `SourceCorpus` holds it.
    private static let sourcesRoot = SourceCorpus.url(of: .sources)

    /// Every `.swift` file under `Sources/`, with its path relative to it.
    private static func sourceFiles() throws -> [(relative: String, url: URL)] {
        let prefix = SourceCorpus.key(sourcesRoot) + "/"
        return try SourceCorpus.files(under: sourcesRoot).compactMap { url in
            guard url.pathExtension == "swift" else { return nil }
            let key = SourceCorpus.key(url)
            guard key.hasPrefix(prefix) else { return nil }
            return (String(key.dropFirst(prefix.count)), url)
        }
    }

    /// The one `Sources/` file named `<type>.swift`, found by walking rather
    /// than by a spelled directory, so the runner can move inside `Sources/`
    /// without this going blind — and fails if there is not exactly one.
    private static func runnerFile(named type: String) throws -> URL {
        let matches = try sourceFiles().filter { $0.url.lastPathComponent == "\(type).swift" }
        guard matches.count == 1, let match = matches.first else {
            throw RunnerFileMissing(type: type, found: matches.map(\.relative))
        }
        return match.url
    }

    /// The two files the runner is made of — the two that moved out of
    /// `Tests/` and keep the full-pattern scan they had there.
    private static func runnerFiles() throws -> [URL] {
        [
            try runnerFile(named: String(describing: SubprocessRunner.self)),
            try runnerFile(named: String(describing: AsyncSignal.self)),
        ]
    }

    private struct RunnerFileMissing: Error, CustomStringConvertible {
        let type: String
        let found: [String]
        var description: String { "expected exactly one \(type).swift under Sources/, found \(found)" }
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

    /// Every `.swift` file under `Tests/`, as paths relative to it — listed
    /// and later read through `SourceCorpus`, the tree's shared listing and
    /// per-file cache, which throws where the walk it replaced did.
    private static func testSources() throws -> [String] {
        let prefix = testsRootPath + "/"
        return try SourceCorpus.files(under: testsRoot).compactMap { url in
            guard url.pathExtension == "swift" else { return nil }
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
}
