import Foundation
import macSCPCore
import MacSCPTestSupport
import Testing

/// Keeps the wall-clock deadline shape out of the test tree, now that
/// every poll goes through `pollUntil`. Every negative check here is
/// pinned by a positive one beside it, per CLAUDE.md "Guards that name
/// what they watch". Two shapes were the `ContinuousClock` literal this
/// suite was built to catch; two more, added for the "ceilings under
/// other spellings" plan, are the same property under a `Duration` bound
/// instead — `wait(timeout:)` and a `Task.sleep` child racing real work
/// inside a task group; two more still, added in this plan's final fix
/// round, are the same property spelled with `Date` instead of
/// `ContinuousClock` — `Date().timeIntervalSince(...) <` and
/// `.wait(until: Date(...)` (CLAUDE.md, "A wall-clock ceiling in a test
/// measures the runner").
///
/// `.timeLimit(.minutes(1))` because every check here scans every Swift
/// file under `Tests/`. The files, their text and their blanked view come
/// from `SourceCorpus`, each file read and blanked at most once per test
/// process; the patterns are compiled once per process (`CompiledPattern`)
/// rather than on every call; and the while-block scan two checks share is
/// remembered per file (`sleepingWhileBlocksByFile`).
@Suite("Polling guard", .timeLimit(.minutes(1)))
struct PollingGuardTests {
    private static var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macSCPCoreTests
            .deletingLastPathComponent()   // Tests
    }

    /// Every Swift file under Tests/, plus the two files the subprocess
    /// runner is made of, minus this guard, the helper that
    /// defines `pollUntil` itself, and three fixtures that intentionally
    /// carry shapes this guard's own checks look for —
    /// `SleepingChildRegexFixture.swift`
    /// (`noSleepingChildRacesWorkInAGroup`), `CeilingRegexFixture.swift`
    /// (`noTestAssertsAnElapsedSinceCeiling`,
    /// `noWaitTakesAWallClockDeadline`) and `FutureGetRegexFixture.swift`
    /// (`noEventLoopFutureIsAwaitedWithGet`) — kept out of the scan each
    /// exists to feed a positive check about instead.
    ///
    /// `code` is the file's `SwiftSource.blankingCommentsAndStrings` view,
    /// the one every blanked scan below reads.
    ///
    /// The runner's two files (`SubprocessRunner`, `AsyncSignal`) were test
    /// support under `Tests/macSCPCoreTests/Support/` until 2026-09-19, when
    /// they moved into `macSCPCore` so the key tools could await their
    /// children through them (the CI-starvation plan, Task 2). They are
    /// still scanned here, by name derived from their types and found by a
    /// walk of `Sources/`, so the move did not narrow what this guard reads.
    /// `runnerSources()` fails unless each name matches exactly one file.
    private static func sources() throws -> [(path: String, text: String, code: String)] {
        let urls = try runnerSources() + SourceCorpus.files(under: testsRoot).filter { url in
            let path = url.path
            return url.pathExtension == "swift"
                && !(path.hasSuffix("PollingGuardTests.swift")
                    || path.hasSuffix("PollUntil.swift")
                    || path.hasSuffix("SleepingChildRegexFixture.swift")
                    || path.hasSuffix("CeilingRegexFixture.swift")
                    || path.hasSuffix("FutureGetRegexFixture.swift"))
        }
        // All at once, so the checks here that start together share the
        // blanking file by file instead of each blanking the whole tree.
        let codes = try SourceCorpus.code(ofAll: urls)
        return try urls.indices.map { (urls[$0].path, try SourceCorpus.text(of: urls[$0]), codes[$0]) }
    }

    /// The file name `AsyncSignal`'s declaration lives in, derived from the
    /// type so a rename breaks compilation rather than an exemption.
    private static let asyncSignalFile = "/\(String(describing: AsyncSignal.self)).swift"

    /// The runner's two files, found under `Sources/` by the names their
    /// types give them — exactly one each, or this throws.
    private static func runnerSources() throws -> [URL] {
        let all = try SourceCorpus.files(under: SourceCorpus.url(of: .sources))
        return try [String(describing: SubprocessRunner.self), String(describing: AsyncSignal.self)].map { type in
            let matches = all.filter { $0.lastPathComponent == "\(type).swift" }
            guard matches.count == 1, let match = matches.first else {
                throw SourceCorpus.CorpusError.notInCorpus("exactly one \(type).swift under Sources/ (found \(matches.count))")
            }
            return match
        }
    }

    // The patterns. Each is compiled once per process, through
    // `CompiledPattern`, by the check that uses it — so a pattern edited
    // into something that does not compile fails that check, not the whole
    // test process (a `try!` static did the latter: measured in fix round 1
    // of the 2026-09-19 CI-starvation plan, `Fatal error: 'try!' expression
    // unexpectedly raised an error`, signal 5, every verdict lost).
    private static let elapsedCeilingPattern = #"elapsed\s*<=?\s*\."#
    private static let sleepingChildPattern =
        #"addTask(?:\([^)]*\))?\s*\{\s*(?:do\s*\{\s*)?(?:try\??\s+)?(?:await\s+)?Task\.sleep\(for:"#
    private static let dateCeilingPattern = #"Date\(\)\.timeIntervalSince\([^)]*\)\s*<=?"#
    private static let dateDeadlinePattern = #"\.wait\(until:\s*Date\("#
    private static let whileBlockPattern = #"\bwhile\b[^{]*\{\s*$"#
    private static let futureGetPattern = #"\w*(?:futureResult|future|Future)\s*\.get\(\)"#
    private static let bareContinuationPattern =
        #"with(?:Unsafe(?:Throwing)?|Checked(?:Throwing)?)Continuation\s*[({]"#
    private static let funcDeclarationPattern = #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\("#

    /// Positive: the helper is in use. Without this, the negative checks
    /// below could pass over an empty tree.
    @Test func theTreePollsThroughTheSharedHelper() throws {
        let callers = try Self.sources().filter { $0.text.contains("pollUntil(") }
        #expect(callers.count >= 10, "\(callers.count) files call pollUntil")
    }

    /// Negative: no test builds its own deadline from the clock.
    @Test func noTestCarriesItsOwnDeadline() throws {
        let offenders = try Self.sources().filter {
            $0.text.contains("let deadline = ContinuousClock.now")
                || $0.text.contains("ContinuousClock.now.advanced(by:")
        }.map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Negative: no elapsed-time ceiling. The floor (`>=`, `>`) is allowed.
    ///
    /// This scans prose too, not only code — CLAUDE.md "Source-scanning
    /// guards read comments too": a comment that quotes the banned shape
    /// verbatim is indistinguishable from the shape itself to this regex.
    /// A historical note in `LivenessProbeRaceTests.swift` used to spell
    /// `elapsed < .seconds(20)` to explain what an earlier version
    /// asserted; it now describes the same fact in prose instead of
    /// quoting the code, per that same rule.
    @Test func noTestAssertsAnElapsedCeiling() throws {
        let pattern = try CompiledPattern.regex(Self.elapsedCeilingPattern)
        let offenders = try Self.sources().filter {
            pattern.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil
        }.map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Positive for the two negatives above, the other way round: a floor
    /// exists in the tree, so the ceiling regex is looking at real
    /// `elapsed` comparisons, not at nothing.
    @Test func aFloorExistsSoTheCeilingCheckHasSomethingToRead() throws {
        let floors = try Self.sources().filter { $0.text.contains("elapsed >= ") || $0.text.contains("elapsed > ") }
        #expect(!floors.isEmpty)
    }

    /// Negative: no latch is waited on with a wall-clock ceiling.
    /// `AsyncSignal.wait(timeout:)` is `noTestAssertsAnElapsedCeiling`'s
    /// shape under another spelling — a `Duration` bound raced against
    /// scheduled work instead of a `ContinuousClock` literal — and the
    /// "ceilings under other spellings" plan retired every caller that
    /// was not one of three exemptions.
    ///
    /// Two exemptions are found by path: `AsyncSignalTests.swift` tests
    /// the bounded API itself (the positive below), and
    /// `AsyncSignal.swift` (in `Sources/macSCPCore` since 2026-09-19)
    /// declares `wait(timeout:)`, so its own signature spells the phrase. The third is found by neither path
    /// nor file name, per the brief for this check: `SubprocessRunnerTests.swift`
    /// keeps one bound — `started.wait(timeout: startBound)` — because
    /// there the bound IS the saturation being measured, and the comment
    /// above the call says exactly that ("the bound IS the measurement").
    /// Matching that phrase instead of the file name means a file rename
    /// cannot silently widen the exemption, and rewording the comment
    /// without also removing the wait would turn this check red rather
    /// than quietly staying green.
    @Test func noLatchIsWaitedOnWithATimeout() throws {
        let measurementSentence = "the bound IS the measurement"
        let sources = try Self.sources()

        let callers = sources.filter { $0.text.contains("wait(timeout:") }
        let offenders = callers.filter {
            !$0.path.hasSuffix("AsyncSignalTests.swift")
                && !$0.path.hasSuffix(Self.asyncSignalFile)
                && !$0.text.contains(measurementSentence)
        }.map(\.path)

        // Positive: the bounded API is still exercised directly — without
        // this, the negative above could pass over a tree with no callers
        // at all, exempt or otherwise.
        #expect(callers.contains { $0.path.hasSuffix("AsyncSignalTests.swift") })

        // Positive for the third exemption specifically: the measurement
        // sentence is actually live in `SubprocessRunnerTests.swift`,
        // beside a real `wait(timeout:)` call. Without this, that
        // exemption is proven only by the negative below failing to land
        // the file in `offenders` — which is exactly what a rewritten or
        // deleted sentence would also produce, so nothing here would
        // distinguish "the pairing holds" from "the pairing quietly broke
        // and nobody noticed because the file happened not to be scanned
        // as an offender for some other reason."
        #expect(sources.contains {
            $0.path.hasSuffix("SubprocessRunnerTests.swift")
                && $0.text.contains("wait(timeout:")
                && $0.text.contains(measurementSentence)
        })

        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Negative: no test races a sleeping sibling against real work inside
    /// a task group — `ConnectMainActorLivenessTests` and
    /// `CitadelShellIntegrationTests` both carried this shape before the
    /// "ceilings under other spellings" plan: a `group.addTask` whose
    /// first statement is `Task.sleep(for:`, standing in for the harness
    /// `.timeLimit` that already ends a hung test. Scanned over
    /// comment-and-string-blanked source, per CLAUDE.md "Source-scanning
    /// guards read comments too" — a doc comment that writes out the
    /// banned shape to explain it (as this file's own history did, for
    /// the `elapsed <` ceiling) is otherwise indistinguishable from the
    /// shape itself.
    ///
    /// The regex also matches the sleep wrapped one level inside a
    /// `do {}` — fix round 2026-09-04, docs/BACKLOG.md's "third limit" on
    /// this guard: `AsyncSignal.race(timeout:_:)`
    /// (`AsyncSignal.swift`) is exactly the sleeping-child shape
    /// this check exists to catch, but the sleep sat behind a `do {}`
    /// error handler, so the token right after `addTask`'s own brace was
    /// that wrapper rather than `Task.sleep`, and the plain regex passed
    /// over it without matching. Widening the pattern turned that miss
    /// into a real match, which is now a NAMED exemption rather than an
    /// unexamined blind spot: `AsyncSignal.swift` is excluded only
    /// when it still carries `raceExemptionSentence` beside the sleep, the
    /// same shape `noLatchIsWaitedOnWithATimeout` uses for the
    /// saturation-site exemption above — matched by sentence, not by file
    /// name, so a rewording without also removing the shape turns this
    /// check red instead of quietly staying green.
    @Test func noSleepingChildRacesWorkInAGroup() throws {
        let pattern = try CompiledPattern.regex(Self.sleepingChildPattern)
        let raceExemptionSentence = "the timeout IS the API under test here"
        let sources = try Self.sources()

        let scanned = sources.map { source -> (path: String, text: String, matched: Bool) in
            let blanked = source.code
            let range = NSRange(blanked.startIndex..., in: blanked)
            return (source.path, source.text, pattern.firstMatch(in: blanked, range: range) != nil)
        }

        let offenders = scanned.filter { $0.matched }
            .filter { !($0.path.hasSuffix(Self.asyncSignalFile) && $0.text.contains(raceExemptionSentence)) }
            .map(\.path)
        #expect(offenders.isEmpty, "\(offenders)")

        // Positive for the exemption specifically: `AsyncSignal.race` does
        // match the widened regex (it is the shape the exemption exists
        // for, not a file that happens never to trigger it) AND the
        // exemption sentence is actually live beside it. Without this, the
        // exemption is proven only by the negative above failing to land
        // the file in `offenders` — which a rewritten or deleted sentence
        // would also produce.
        #expect(scanned.contains {
            $0.path.hasSuffix(Self.asyncSignalFile)
                && $0.matched
                && $0.text.contains(raceExemptionSentence)
        })

        // Positive: the regex matches real, compiling code in both shapes
        // it exists to catch — `SleepingChildRegexFixture.swift`, excluded
        // from `sources()` above the same way this guard's own file is, so
        // the matches it demonstrates can never themselves become an
        // offender. Counted, not just non-empty, per
        // `noEventLoopFutureIsAwaitedWithGet`'s own reasoning: a count of 1
        // here would mean the `do {}`-wrapped demonstration stopped
        // matching while the plain shape stayed green.
        let fixtureURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/SleepingChildRegexFixture.swift")
        let fixtureBlanked = try SourceCorpus.code(of: fixtureURL)
        let fixtureMatches = pattern.matches(
            in: fixtureBlanked, range: NSRange(fixtureBlanked.startIndex..., in: fixtureBlanked))
        #expect(fixtureMatches.count == 2, "\(fixtureMatches.count)")
    }

    /// Negative: no test asserts an elapsed-since ceiling spelled with
    /// `Date` instead of `ContinuousClock` — `noTestAssertsAnElapsedCeiling`'s
    /// shape under the `Foundation` clock. `CLISecretSourcesTests.swift`
    /// carried exactly this (`Date().timeIntervalSince(started) < 5`,
    /// beside an outcome that was already asserted) until this plan's
    /// final fix round replaced it with a floor — `>=` compiles the same
    /// call and is deliberately let through, so the regex only rejects
    /// `<`/`<=`. Scanned over comment-and-string-blanked source, same as
    /// `noSleepingChildRacesWorkInAGroup` and per CLAUDE.md "Source-scanning
    /// guards read comments too" — a doc comment that writes out the
    /// banned shape to explain it (as this one does, above) is otherwise
    /// indistinguishable from the shape itself, on both the negative side
    /// and the positive fixture check below it.
    @Test func noTestAssertsAnElapsedSinceCeiling() throws {
        let pattern = try CompiledPattern.regex(Self.dateCeilingPattern)
        let offenders = try Self.sources().compactMap { source -> String? in
            let blanked = source.code
            let range = NSRange(blanked.startIndex..., in: blanked)
            return pattern.firstMatch(in: blanked, range: range) != nil ? source.path : nil
        }
        #expect(offenders.isEmpty, "\(offenders)")

        // Positive: the regex matches real, compiling code in this exact
        // shape — `CeilingRegexFixture.swift`, excluded from `sources()`
        // above the same way `SleepingChildRegexFixture.swift` is, so
        // the match it demonstrates can never itself become an offender.
        // Blanked the same way the negative above is, so this positive
        // proves the negative's own scanning path finds the shape, not a
        // raw-text path the negative no longer uses.
        let fixtureURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/CeilingRegexFixture.swift")
        let fixtureBlanked = try SourceCorpus.code(of: fixtureURL)
        #expect(
            pattern.firstMatch(
                in: fixtureBlanked, range: NSRange(fixtureBlanked.startIndex..., in: fixtureBlanked))
                != nil)
    }

    /// Negative: no wait takes a wall-clock deadline built from `Date` —
    /// `noTestCarriesItsOwnDeadline`'s shape under the `Foundation` clock
    /// instead of `ContinuousClock`. `NetworkTraceTests.swift`'s
    /// `BlockingGate` carried exactly this
    /// (`abandoned.wait(until: Date().addingTimeInterval(30))`, on
    /// `BlockingProbe`'s own private queue rather than the cooperative
    /// pool) until this plan's final fix round dropped the parameter: the
    /// wait now ends only when the gate opens, or — through the
    /// `AsyncSignal` that joins it — when the suite's `.timeLimit` cancels
    /// the test. Scanned over comment-and-string-blanked source, same as
    /// `noSleepingChildRacesWorkInAGroup` and per CLAUDE.md "Source-scanning
    /// guards read comments too", on both the negative side and the
    /// positive fixture check below it.
    @Test func noWaitTakesAWallClockDeadline() throws {
        let pattern = try CompiledPattern.regex(Self.dateDeadlinePattern)
        let offenders = try Self.sources().compactMap { source -> String? in
            let blanked = source.code
            let range = NSRange(blanked.startIndex..., in: blanked)
            return pattern.firstMatch(in: blanked, range: range) != nil ? source.path : nil
        }
        #expect(offenders.isEmpty, "\(offenders)")

        // Positive, same fixture as the check above, blanked the same way.
        let fixtureURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/CeilingRegexFixture.swift")
        let fixtureBlanked = try SourceCorpus.code(of: fixtureURL)
        #expect(
            pattern.firstMatch(
                in: fixtureBlanked, range: NSRange(fixtureBlanked.startIndex..., in: fixtureBlanked))
                != nil)
    }

    /// Every file that reaches `pollUntil` — directly, or through a helper
    /// function defined in a file with no suite of its own — declares a
    /// time limit, so a condition that never holds is a red, not a hang.
    ///
    /// Drafted first as a flat per-file `pollUntil(` scan, that version
    /// was red on `Tests/macSCPCoreTests/LoopbackHTTPStub.swift`: a helper
    /// file with no `@Suite`/`@Test` of its own, so no test to put a
    /// `.timeLimit` on, and it missed the four suites
    /// (`S3SessionIsolationTests`, `S3RedirectControlTests`,
    /// `S3RedirectAuthorizationMeasurementTests`,
    /// `ConnectFailureSecrecyTests`) that reach an unbounded poll only
    /// through `LoopbackHTTPStub.waitForRequests` and so contain no literal
    /// `pollUntil(` themselves. Both are fixed here structurally rather
    /// than by naming files: a file that declares neither `@Suite` nor
    /// `@Test` is a helper, and every `func` such a file declares whose
    /// body — found by brace-balancing from the parameter list, the
    /// technique `TransferQueueBarCancelGuardTests.declarationBodyRange`
    /// uses in the App target for the same reason — contains `pollUntil(`
    /// is a helper name. A suite file that calls `pollUntil(` directly, or
    /// calls one of those helper names, must carry `.timeLimit(`.
    @Test func everyCallerOfPollUntilDeclaresATimeLimit() throws {
        let sources = try Self.sources()
        let helperFiles = sources.filter { !$0.text.contains("@Suite") && !$0.text.contains("@Test") }
        let suiteFiles = sources.filter { $0.text.contains("@Suite") || $0.text.contains("@Test") }

        let helperNames = try Self.pollingHelperFunctionNames(in: helperFiles)

        let directCallers = suiteFiles.filter { $0.text.contains("pollUntil(") }
        let indirectCallers = suiteFiles.filter { file in
            !file.text.contains("pollUntil(")
                && helperNames.contains { file.text.contains("\($0)(") }
        }
        let callers = directCallers + indirectCallers
        let withoutLimit = callers.filter { !$0.text.contains(".timeLimit(") }.map(\.path)

        // Positive pairing: the helper set is not accidentally empty (it
        // must at least contain the one this check exists for), and there
        // are direct callers for the negative check to have found in the
        // first place.
        #expect(!helperNames.isEmpty)
        #expect(helperNames.contains("waitForRequests"), "\(helperNames)")
        #expect(!directCallers.isEmpty)

        #expect(withoutLimit.isEmpty, "\(withoutLimit)")
    }

    /// Negative: no `while` loop in `Tests/` waits by sleeping with its
    /// sleep's cancellation swallowed.
    ///
    /// `while <condition> { try? await Task.sleep(...) }` is a poll whose
    /// only suspension point stops suspending the moment the task is
    /// cancelled: `Task.sleep` then throws at once, `try?` discards the
    /// throw, and the loop becomes a tight spin on a cooperative-pool
    /// thread that nothing can end (CLAUDE.md, "Tests never block the
    /// cooperative pool"). `TunnelRunnerFakes.TunnelLatch.wait()` was
    /// exactly that shape, and it is entered from an already-cancelled
    /// task by design, so the spin was on the ONLY path it ever took.
    ///
    /// A condition that reads `Task.isCancelled` is not this shape: the
    /// loop's own test ends it on the first turn after cancellation, which
    /// is why three of the five `while` blocks this check finds are allowed
    /// by their condition alone (counted 2026-09-07 by this check's own
    /// scan; `everyCancellationObservingLoopIsSeen` below records the
    /// totals).
    ///
    /// Two more are allowed by a sentence instead, searched for in the 12
    /// lines above the `while` plus the block's own body — never by path,
    /// so that moving or renaming a file cannot widen the exemption, and
    /// so that removing the sentence without removing the loop turns this
    /// check red:
    ///
    /// - `TerminalPanelViewModelTests`' output stub, whose whole purpose
    ///   is a stream that does not answer cancellation ("does not observe
    ///   task cancellation").
    /// - `CitadelFileSystemIntegrationTests.waitForServerToCloseDescriptors`,
    ///   whose loop carries its own iteration bound ("bounded at roughly
    ///   two seconds") and so cannot spin without end.
    ///
    /// Scanned over comment-and-string-blanked source for the SHAPE, per
    /// CLAUDE.md "Source-scanning guards read comments too" — a doc
    /// comment quoting the forbidden loop, or a fixture holding one in a
    /// string, would otherwise BE one — and over the ORIGINAL lines for
    /// the exemption sentences, which live in comments the blanking has
    /// erased.
    @Test func noWhileLoopSwallowsItsSleepsCancellation() throws {
        let blocks = try Self.sleepingWhileBlocks()
        let offenders = blocks.filter { !$0.observesCancellation && $0.exemption == nil }
            .map { "\($0.path):\($0.line)" }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Positive for the check above, three ways: the scan finds `while`
    /// blocks that sleep at all, it finds the cancellation-observing ones
    /// its condition rule is written for, and each exemption sentence is
    /// still earning its keep. Without these, `noWhileLoopSwallowsItsSleeps
    /// Cancellation` could pass over a tree where the block finder matches
    /// nothing, or keep exempting a loop that no longer exists.
    ///
    /// Counted 2026-09-07 by running this scan over `Tests/` AFTER
    /// `TunnelLatch.wait()` stopped polling: 5 blocks, 3 of them ending on
    /// `Task.isCancelled`, 1 per exemption sentence, none left over (the
    /// latch was the sixth block and the one offender before the fix).
    /// A first draft scanned RAW source and reported 11; the six extra
    /// were `while !Task.isCancelled` loops quoted inside
    /// `LivenessProbeWiringGuardTests`\' fixture strings, which is exactly
    /// what the blanking is for.
    @Test func everyCancellationObservingLoopIsSeen() throws {
        let blocks = try Self.sleepingWhileBlocks()
        #expect(blocks.count >= 5, "\(blocks.count) sleeping while-blocks found")
        #expect(
            blocks.filter(\.observesCancellation).count >= 3,
            "\(blocks.filter(\.observesCancellation).count) end on Task.isCancelled")
        for sentence in Self.sleepExemptionSentences {
            #expect(
                blocks.contains { $0.exemption == sentence },
                "no block is exempted by \(sentence) any more")
        }
    }

    /// The two sentences that allow a swallowed sleep inside a `while`.
    private static let sleepExemptionSentences = [
        "does not observe task cancellation",
        "bounded at roughly two seconds",
    ]

    /// One `while` block whose body sleeps with the throw discarded.
    private struct SleepingWhileBlock {
        let path: String
        let line: Int
        let observesCancellation: Bool
        let exemption: String?
    }

    /// Every `while` block under `Tests/` whose body contains a
    /// `try? await Task.sleep`, with the two facts that decide whether it
    /// is allowed.
    ///
    /// Line-based, the way `noBareContinuationEscapesAwaitResumption` above
    /// pairs blanked lines with original ones: the SHAPE is read off
    /// comment-and-string-blanked source (a `{` inside a comment or a
    /// string would otherwise close the block early, and a doc comment
    /// quoting the forbidden loop would otherwise BE one), and the
    /// exemption sentence off the original lines at the same indices.
    /// `SwiftSource.blankingCommentsAndStrings` preserves line structure,
    /// so the two arrays line up; pairing them by index rather than by
    /// `String.Index` keeps that true whatever the blanking does to a
    /// line's length.
    ///
    /// The exemption context is the 12 lines above the `while` plus the
    /// block itself, with comment markers and line breaks flattened to
    /// single spaces so a sentence that wraps across two `///` lines is
    /// still one sentence. 12 lines is `continuationExemptionWindow`'s
    /// window, reused rather than picked again here.
    ///
    /// The `while` and its `{` must sit on one line. A condition wrapped
    /// across lines would go unseen — a hole named here rather than
    /// hidden, and the reason the positive below counts what the scan
    /// does find rather than trusting it to find everything.
    ///
    /// Two checks read it, and the tree does not change under a run, so each
    /// file's blocks are remembered (`sleepingWhileBlocksByFile`, a
    /// `PerKeyCache`): a check that misses a file scans it itself and never
    /// waits for the other check's scan.
    private static func sleepingWhileBlocks() throws -> [SleepingWhileBlock] {
        let sources = try Self.sources()
        return try sleepingWhileBlocksByFile.values(for: sources.map(\.path)) { index in
            Result { try scanSleepingWhileBlocks(in: sources[index]) }
        }.flatMap { try $0.get() }
    }

    private static let sleepingWhileBlocksByFile = PerKeyCache<Result<[SleepingWhileBlock], any Error>>()

    private static func scanSleepingWhileBlocks(
        in source: (path: String, text: String, code: String)
    ) throws -> [SleepingWhileBlock] {
        let pattern = try CompiledPattern.regex(Self.whileBlockPattern)
        var found: [SleepingWhileBlock] = []
        let blanked = source.code.components(separatedBy: "\n")
        let original = source.text.components(separatedBy: "\n")
        for (index, line) in blanked.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard pattern.firstMatch(in: line, range: range) != nil else { continue }
            guard let last = Self.blockEndLine(openingAt: index, in: blanked) else { continue }
            let body = blanked[index...last].joined(separator: "\n")
            guard body.contains("try? await Task.sleep") else { continue }

            let windowStart = max(0, index - Self.continuationExemptionWindow)
            let context = Self.flattened(original[windowStart...last].joined(separator: "\n"))
            found.append(
                SleepingWhileBlock(
                    path: source.path,
                    line: index + 1,
                    observesCancellation: line.contains("Task.isCancelled"),
                    exemption: Self.sleepExemptionSentences.first { context.contains($0) }))
        }
        return found
    }

    /// The index of the line carrying the `}` that closes the block opened
    /// on `first`, by counting braces from that line onwards.
    private static func blockEndLine(openingAt first: Int, in lines: [String]) -> Int? {
        var depth = 0
        for index in first..<lines.count {
            depth += lines[index].filter { $0 == "{" }.count
            depth -= lines[index].filter { $0 == "}" }.count
            if depth <= 0 { return index }
        }
        return nil
    }

    /// Comment markers and every run of whitespace flattened to one space,
    /// so a sentence a formatter wrapped across two `///` lines reads as
    /// the one sentence it is.
    private static func flattened(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                for marker in ["///", "//"] where trimmed.hasPrefix(marker) {
                    trimmed = String(trimmed.dropFirst(marker.count))
                    break
                }
                return trimmed
            }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Negative: no `EventLoopFuture` is awaited with `.get()` — the shape
    /// `awaitCancellably` (`Tests/MacSCPTestSupport/AwaitCancellably.swift`)
    /// exists to replace, per its own doc comment and
    /// `docs/BACKLOG.md` ("Wall-clock ceilings still in the tree"):
    /// `EventLoopFuture.get()` ignores task cancellation, so a future that
    /// never completes ends nothing — the calling suite's `.timeLimit`
    /// records a red and the run then parks, the same 0 % CPU shape
    /// `docs/superpowers/specs/2026-08-08-testsuite-hang-investigation.md`
    /// describes, reached from the other side.
    ///
    /// The regex matches a `.get()` preceded, across any run of
    /// whitespace including a line break, by an identifier ending
    /// `future`, `Future` or `futureResult` — `promise.futureResult` and a
    /// bare `future` local are both real shapes this tree carried; a `.`
    /// breaks `\w*`, so the match is always the LAST identifier segment
    /// before the call, never a longer qualified path. The whitespace run
    /// matters on its own: a fix-round review found `promise.futureResult`
    /// wrapped onto its own line above a lone `.get()` compiles identically
    /// to the one-line form and escaped an earlier version of this regex
    /// that required the two adjacent — `FutureGetRegexFixture`'s second
    /// demonstration is exactly that wrapped shape. `Result<Value,
    /// Error>.get()` — a same-named, unrelated stdlib API this tree also
    /// calls (`BandwidthBucketTests`, `SSHAgentClientTests`,
    /// `UpdateCheckerTests`, `HostKeyValidationTests`,
    /// `EmbeddedKeyPorterTests`, `SSHTerminalViewSizingTests`) — is not this
    /// shape and does not match: its receiver identifiers (`result`, `$0`,
    /// a `#require(...)` call result, a bare `outcome`) never end in
    /// `future`/`Future`/`futureResult`.
    ///
    /// Scanned over comment-and-string-blanked source, same as
    /// `noSleepingChildRacesWorkInAGroup` and
    /// `noTestAssertsAnElapsedSinceCeiling`, per CLAUDE.md "Source-scanning
    /// guards read comments too": `EventLoopFuture` itself ends in
    /// `Future`, so a doc comment that writes out
    /// `` `EventLoopFuture.get()` `` to explain the shape — as this
    /// check's own comment above does, and as `AwaitCancellably.swift`'s
    /// does at length — is otherwise indistinguishable from the shape
    /// itself. No exemption list is needed beyond that: every remaining
    /// `.get()` in `Tests/` that would otherwise match this regex, at the
    /// point this check was written, sits in such a comment.
    @Test func noEventLoopFutureIsAwaitedWithGet() throws {
        let pattern = try CompiledPattern.regex(Self.futureGetPattern)
        // Every match of the pattern ends in the literal `.get()`, so a file
        // whose blanked text lacks it cannot match: the regex, whose leading
        // `\w*` makes ICU retry at every character, runs only on the files
        // that could. The fixture check below runs it unfiltered, and
        // `everyFutureGetMatchEndsInTheLiteralThePrefilterReads` checks the
        // premise on the fixture's real matches.
        let offenders = try Self.sources().compactMap { source -> String? in
            let blanked = source.code
            guard Self.futureGetPrefilterAdmits(blanked) else { return nil }
            let range = NSRange(blanked.startIndex..., in: blanked)
            return pattern.firstMatch(in: blanked, range: range) != nil ? source.path : nil
        }
        #expect(offenders.isEmpty, "\(offenders)")

        // Positive: the regex matches real, compiling code in this exact
        // shape — `FutureGetRegexFixture.swift`, excluded from `sources()`
        // above the same way the other regex fixtures are, so the match it
        // demonstrates can never itself become an offender. Blanked the
        // same way the negative above is, so this positive proves the
        // negative's own scanning path finds the shape, not a raw-text
        // path the negative no longer uses.
        //
        // Counted, not just non-empty: the fixture demonstrates TWO shapes
        // — `future.get()`/`promise.futureResult.get()` on one line, and
        // `promise.futureResult` wrapped onto its own line above a lone
        // `.get()` — and a count of 1 here would mean the wrapped
        // demonstration stopped matching (the exact way the regex escaped
        // before `\s*` was added) while this positive stayed green on the
        // first shape alone.
        let fixtureURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/FutureGetRegexFixture.swift")
        let fixtureBlanked = try SourceCorpus.code(of: fixtureURL)
        let fixtureMatches = pattern.matches(
            in: fixtureBlanked, range: NSRange(fixtureBlanked.startIndex..., in: fixtureBlanked))
        #expect(fixtureMatches.count == 3, "\(fixtureMatches.count)")
    }

    /// The literal `noEventLoopFutureIsAwaitedWithGet` pre-filters files by.
    private static let futureGetLiteral = ".get()"

    /// Whether a file could hold a match of `futureGetPattern` at all:
    /// searched as UTF-16 code units, the level the pattern itself matches
    /// at, so a grapheme cluster that swallows the literal's last character
    /// cannot hide it from the filter while the pattern still sees it.
    static func futureGetPrefilterAdmits(_ text: String) -> Bool {
        (text as NSString).range(of: Self.futureGetLiteral, options: .literal).location != NSNotFound
    }

    /// The pre-filter must never skip a text the pattern matches. It once
    /// compared `Character`s while the pattern (ICU) compares UTF-16, and
    /// the two part ways on a grapheme extender right after the literal:
    /// `.get()` followed by U+0301 COMBINING ACUTE ACCENT is one `Character`
    /// ending in `)́`, so `String.contains(".get()")` answered `false` about
    /// a text the pattern matched (fix round 1, review M1).
    @Test func theFutureGetPrefilterAdmitsEveryTextThePatternMatches() throws {
        let planted = "try await promise.futureResult.get()\u{301}"
        let pattern = try CompiledPattern.regex(Self.futureGetPattern)
        let matched = pattern.firstMatch(in: planted, range: NSRange(planted.startIndex..., in: planted)) != nil
        #expect(matched)
        #expect(Self.futureGetPrefilterAdmits(planted))
    }

    /// The pre-filter's premise, measured on the pattern's own demonstration
    /// rather than only assumed from reading it: every match in the fixture
    /// ends in `futureGetLiteral`. It cannot prove that no text anywhere
    /// matches without the literal — the pattern itself says that, by ending
    /// in `\.get\(\)` — so an edit to the pattern is also an edit to read
    /// against the filter above.
    @Test func everyFutureGetMatchEndsInTheLiteralThePrefilterReads() throws {
        let fixtureURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/FutureGetRegexFixture.swift")
        let fixtureBlanked = try SourceCorpus.code(of: fixtureURL)
        let matches = try CompiledPattern.regex(Self.futureGetPattern).matches(
            in: fixtureBlanked, range: NSRange(fixtureBlanked.startIndex..., in: fixtureBlanked))
        #expect(matches.count == 3, "\(matches.count)")
        for match in matches {
            let text = Range(match.range, in: fixtureBlanked).map { String(fixtureBlanked[$0]) } ?? ""
            #expect(text.hasSuffix(Self.futureGetLiteral), "\(text)")
        }
    }

    /// Negative: no test target file outside `Tests/MacSCPTestSupport/`
    /// calls `withCheckedContinuation(`/`withCheckedThrowingContinuation(`/
    /// `withUnsafeContinuation(`/`withUnsafeThrowingContinuation(` directly,
    /// unless the sentence "the continuation IS the API under test here"
    /// appears within `continuationExemptionWindow` lines directly ABOVE
    /// that specific use — the same PROXIMITY shape
    /// `IconTooltipLintTests.hintWindow` uses (12 lines, read there for the
    /// reasoning), not a file-level exemption. A file-level version of this
    /// check shipped first (fix round 1 review, Important finding) and was
    /// too coarse: one sentence anywhere in a file exempted EVERY bare
    /// continuation in it, so a second, unrelated bare continuation added
    /// to an already-exempted file would have passed silently. Matched by
    /// sentence rather than by file name, same as
    /// `noLatchIsWaitedOnWithATimeout` and `noSleepingChildRacesWorkInAGroup`,
    /// so a rewording without also removing the shape turns this check red
    /// instead of quietly staying green.
    ///
    /// `docs/BACKLOG.md`, "A test parked on a bare continuation outlives its
    /// time limit": a bare continuation does not observe `Task`
    /// cancellation, so Swift Testing's `.timeLimit` cancels the enclosing
    /// test's task but never unparks the continuation underneath it — the
    /// "exceeded" report is not the process actually stopping, and on CI the
    /// job runs on to its own outer timeout instead of failing at the
    /// suite's stated limit. Every ordinary wait instead goes through
    /// `awaitResumption`/`awaitResumptionThrowing`
    /// (`Tests/MacSCPTestSupport/AwaitResumption.swift`), which resumes with
    /// `CancellationError` the moment the awaiting task is cancelled. The 14
    /// call sites exempted here, across 13 files (counted 2026-09-06, one
    /// file — `SSHTerminalViewSizingTests` — carries two, each with its own
    /// nearby sentence), each sit beside a comment explaining why THAT
    /// bare continuation is not this bug: a mock that deliberately never
    /// resumes to model a frozen peer or an uncancellable probe, a
    /// hand-built race that is already bounded by construction, or a body
    /// that cannot be `@Sendable` (`NSItemProvider`). The newest of them,
    /// `RemoteForwardTests`, is the first kind: a transport that ignores its
    /// own cancellation, which is what `RemoteForward.stop()`'s bound
    /// exists for.
    ///
    /// Matching is done PER LINE, on comment-and-string-blanked source (per
    /// CLAUDE.md "Source-scanning guards read comments too": several
    /// exemption doc comments quote `withCheckedContinuation` verbatim,
    /// which would otherwise look like the call itself to this regex) —
    /// blanking preserves line breaks, so a match's line number in the
    /// blanked text is the same line number in the ORIGINAL text, which is
    /// where the sentence itself lives (inside a `///`/`//` comment the
    /// blanking would otherwise erase).
    @Test func noBareContinuationEscapesAwaitResumption() throws {
        // `\s*[({]`, not a literal `\(`: every real call site in this tree
        // uses trailing-closure syntax (`withCheckedContinuation { ... }`),
        // never `withCheckedContinuation({ ... })` — a first version of this
        // pattern required the paren and matched nothing at all.
        let pattern = try CompiledPattern.regex(Self.bareContinuationPattern)
        let exemptionSentence = "the continuation IS the API under test here"

        let candidates = try Self.sources().filter { !$0.path.contains("/MacSCPTestSupport/") }

        var offenders: [String] = []
        var matchCount = 0
        for source in candidates {
            let blankedLines = source.code.components(separatedBy: "\n")
            let originalLines = source.text.components(separatedBy: "\n")
            for (index, line) in blankedLines.enumerated() {
                let lineRange = NSRange(line.startIndex..., in: line)
                guard pattern.firstMatch(in: line, range: lineRange) != nil else { continue }
                matchCount += 1
                let windowStart = max(0, index - Self.continuationExemptionWindow)
                let above = originalLines[windowStart..<index].joined(separator: "\n")
                if !above.contains(exemptionSentence) {
                    offenders.append("\(source.path):\(index + 1)")
                }
            }
        }

        #expect(offenders.isEmpty, "\(offenders)")

        // Positive: the exemption is actually exercised — without this, the
        // negative above could pass over a tree where the pattern matches
        // nothing at all, exempt or otherwise. 14 call sites match today
        // (counted 2026-09-06).
        #expect(matchCount >= 10, "\(matchCount)")
    }

    /// The proximity window `noBareContinuationEscapesAwaitResumption` scans
    /// above a bare continuation for its exemption sentence — same size as
    /// `IconTooltipLintTests.hintWindow` (12 lines), a value that lint
    /// measured against its own false-negative rate rather than one picked
    /// here independently.
    private static let continuationExemptionWindow = 12

    /// Positive for `noBareContinuationEscapesAwaitResumption`: the helper
    /// it exempts callers into actually exists and declares both entry
    /// points, and real test files call it — without this, the negative
    /// above could pass simply because nothing in the tree ever adopted the
    /// helper at all. 16 files call `awaitResumption(`/`awaitResumptionThrowing(`
    /// today (counted 2026-09-05, `grep -rl 'awaitResumption[Throwing]* {'`),
    /// outside `AwaitResumption.swift` itself.
    @Test func theAwaitResumptionHelperExistsAndIsAdopted() throws {
        let helperURL = Self.testsRoot.appendingPathComponent("MacSCPTestSupport/AwaitResumption.swift")
        let helperText = try SourceCorpus.text(of: helperURL)
        #expect(helperText.contains("public func awaitResumption<"))
        #expect(helperText.contains("public func awaitResumptionThrowing<"))

        let callers = try Self.sources().filter { source in
            !source.path.contains("/MacSCPTestSupport/")
                && (source.text.contains("awaitResumption {")
                    || source.text.contains("awaitResumptionThrowing {"))
        }
        #expect(callers.count >= 15, "\(callers.count)")
    }

    /// The name of every `func` a helper file declares whose body contains
    /// `pollUntil(`. A small local brace-balancer, not a shared one: this
    /// guard lives in Core and the model
    /// (`TransferQueueBarCancelGuardTests.declarationBodyRange`) lives in
    /// the App target's test tree, which Core's tests do not depend on.
    private static func pollingHelperFunctionNames(
        in files: [(path: String, text: String, code: String)]
    ) throws -> Set<String> {
        let funcPattern = try CompiledPattern.regex(Self.funcDeclarationPattern)
        var names: Set<String> = []
        for file in files {
            let text = file.text
            let nsrange = NSRange(text.startIndex..., in: text)
            for match in funcPattern.matches(in: text, range: nsrange) {
                guard let nameRange = Range(match.range(at: 1), in: text),
                    let wholeRange = Range(match.range, in: text)
                else { continue }
                let name = String(text[nameRange])
                // `wholeRange` ends just past the parameter list's opening
                // '(' — that character is where the brace balancer starts.
                let openParen = text.index(before: wholeRange.upperBound)
                guard let body = try? Self.functionBody(afterParametersAt: openParen, in: text) else { continue }
                if body.contains("pollUntil(") {
                    names.insert(name)
                }
            }
        }
        return names
    }

    /// Balances the parameter list's parens first — so a default argument
    /// like `every interval: Duration = .milliseconds(5)` cannot be read
    /// as closing the list early — then balances the braces of the body
    /// that follows, the same two-pass shape
    /// `TransferQueueBarCancelGuardTests.declarationBodyRange` uses.
    private static func functionBody(
        afterParametersAt openParen: String.Index, in text: String
    ) throws -> String {
        var parenDepth = 0
        var index = openParen
        while index < text.endIndex {
            if text[index] == "(" {
                parenDepth += 1
            } else if text[index] == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let afterParams = text.index(after: index)
                    guard let openBrace = text[afterParams...].firstIndex(of: "{") else {
                        throw ScanError.bodyNotFound
                    }
                    var braceDepth = 0
                    var cursor = openBrace
                    while cursor < text.endIndex {
                        if text[cursor] == "{" {
                            braceDepth += 1
                        } else if text[cursor] == "}" {
                            braceDepth -= 1
                            if braceDepth == 0 {
                                return String(text[text.index(after: openBrace)..<cursor])
                            }
                        }
                        cursor = text.index(after: cursor)
                    }
                    throw ScanError.unbalancedBraces
                }
            }
            index = text.index(after: index)
        }
        throw ScanError.bodyNotFound
    }

    private enum ScanError: Error {
        case bodyNotFound
        case unbalancedBraces
    }

    // The comment/string blanking these checks scan over used to be a
    // private copy here (`blankCommentsAndStrings`/`closesRawString`,
    // adapted from `TabContextMenuWiringGuardTests`' own raw-string-aware
    // stripper, back when the shared `SwiftSource` module still refused a
    // raw-string delimiter outright) — converged onto
    // `SwiftSource.blankingCommentsAndStrings`
    // (`Tests/MacSCPTestSupport/SwiftSourceStripping.swift`), which now
    // parses raw strings and extended regex literals the same way, per
    // docs/BACKLOG.md's "Polish: terminal resize, transfer cancel and
    // paths".

}
