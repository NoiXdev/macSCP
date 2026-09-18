import Foundation
import MacSCPTestSupport
import Testing

/// Diagnostic-log plan, final fix round 2. The re-review traced an
/// intermittent empty-file read (`.superpowers/sdd/2026-09-04-diagnostic-log/final-fix-report.md`,
/// round 1's unexplained flake) to `DiagnosticLog.shared` being a
/// process-wide singleton: `currentFileURL` reads its LIVE `directory`/
/// `fileDayKey` at call time, and another suite's own `configure(...)` on
/// that same instance can overwrite either between one test's `await
/// flush()` and its subsequent read — landing the read on a file nothing
/// it wrote ever touched. `flush()` itself was never the bug (`markFlushed`
/// only runs after the synchronous write completes).
///
/// The fix moved every functional test that does not NEED the live
/// singleton onto its own, private `DiagnosticLog()` instance
/// (`DiagnosticLogTests.swift`) — no singleton, no cross-suite exposure —
/// and confined every test that DOES need it, because the production code
/// under test calls `DiagnosticLog.shared` directly and cannot be pointed
/// at anything else, to ONE `.serialized` suite,
/// `DiagnosticLogSharedSinkTests.swift`, where each test reads back a path
/// it computes itself rather than asking the live singleton what its
/// current file is.
///
/// This guard holds that split in place. NEGATIVE: no `.swift` file under
/// `Tests/` other than `DiagnosticLogSharedSinkTests.swift` mentions
/// `DiagnosticLog.shared` AS CODE — comments and string literals blanked
/// first (`SwiftSource.blankingCommentsAndStrings`), so a doc comment explaining the
/// split (this one included) cannot trip the check, and neither can a
/// guard that holds the identifier only as SCAN-TARGET DATA rather than
/// calling it —
/// `DiagnosticLogSecrecyGuardTests` matches call sites by the literal text
/// `"DiagnosticLog.shared.log("`, and `SettingsViewDiagnosticLogGuardTests`
/// matches `"DiagnosticLog.shared.configure("`/`"DiagnosticLog.shared.log("`
/// the same way — both spellings live inside Swift string literals in
/// those two files, never as a bare identifier expression, so blanking
/// strings removes them from what this scan sees, same as it would for
/// any other file's fixture text.
///
/// POSITIVE beside it, the other half of "Guards that name what they
/// watch" (CLAUDE.md): the one allowed file really does carry the
/// identifier at least 3 times (one per production code path it drives —
/// `ConnectionViewModel` (two tests), `LocalFileSystem`, `TransferEngine`,
/// `RemoteBrowserViewModel`) and its own `@Suite` attribute carries
/// `.serialized`. Without both, an accidentally emptied or
/// accidentally-parallel "allowed" file would satisfy the negative while
/// reopening the exact race this split exists to close.
@Suite("DiagnosticLog shared-sink isolation guard")
struct DiagnosticLogSharedSinkIsolationGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPCoreTests/DiagnosticLogSharedSinkIsolationGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let testsRoot = repoRoot.appendingPathComponent("Tests")

    /// The one file this guard lets mention `DiagnosticLog.shared` as code.
    private static let allowedFileName = "DiagnosticLogSharedSinkTests.swift"

    private static let marker = "DiagnosticLog.shared"

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// The `@Suite(...)` attribute's own argument list, paren-balanced —
    /// the same brace/paren-counting shape `DiagnosticLogSecrecyGuardTests
    /// .callSites` uses for a call's argument list, applied here to an
    /// attribute's instead. `nil` when the text has no `@Suite(` at all,
    /// or when its parens never balance (an unparseable file — treated as
    /// "not carrying `.serialized`" by the caller, never as "carrying" it).
    private static func suiteAttributeArguments(in strippedText: String) -> String? {
        guard let markerRange = strippedText.range(of: "@Suite(") else { return nil }
        let chars = Array(strippedText)
        var i = strippedText.distance(from: strippedText.startIndex, to: markerRange.upperBound)
        let start = i
        var depth = 1
        while i < chars.count, depth > 0 {
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" { depth -= 1 }
            i += 1
        }
        guard depth == 0 else { return nil }
        return String(chars[start..<(i - 1)])
    }

    /// Every paren-balanced argument list following an occurrence of
    /// `marker` (which must end in `"("`) in `strippedText` — one entry per
    /// call site, in source order, reusing `suiteAttributeArguments`'s own
    /// depth-counting shape against an arbitrary call rather than an
    /// attribute. A call whose parens never balance is skipped, the same
    /// as that function does, rather than guessed at.
    private static func callArgumentLists(of marker: String, in strippedText: String) -> [String] {
        let chars = Array(strippedText)
        let markerChars = Array(marker)
        guard !markerChars.isEmpty, chars.count >= markerChars.count else { return [] }
        var results: [String] = []
        var i = 0
        while i <= chars.count - markerChars.count {
            guard Array(chars[i..<(i + markerChars.count)]) == markerChars else {
                i += 1
                continue
            }
            var j = i + markerChars.count
            let start = j
            var depth = 1
            while j < chars.count, depth > 0 {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" { depth -= 1 }
                j += 1
            }
            guard depth == 0 else {
                i += 1
                continue
            }
            results.append(String(chars[start..<(j - 1)]))
            i = j
        }
        return results
    }

    // The comment/string blanking this guard scans over used to be a
    // private copy here (`stripCommentsAndStrings`/`closesRawString`,
    // adapted from `TabContextMenuWiringGuardTests`' own raw-string-aware
    // stripper — this was the third copy in `macSCPCoreTests`/
    // `macSCPAppKitTests` combined, after `PollingGuardTests`' and that
    // one, all citing the first for why raw strings are PARSED here
    // rather than refused) — converged onto
    // `SwiftSource.blankingCommentsAndStrings`
    // (`Tests/MacSCPTestSupport/SwiftSourceStripping.swift`), which parses
    // raw strings and extended regex literals the same way, per
    // docs/BACKLOG.md's "Polish: terminal resize, transfer cancel and
    // paths".


    @Test("no file other than the shared-sink suite mentions DiagnosticLog.shared as code")
    func onlyTheSharedSinkSuiteFileTouchesTheSingleton() throws {
        var offenders: [String] = []
        var allowedFileMentionCount = 0
        var allowedFileIsSerialized = false
        var sawAllowedFile = false

        for file in Self.swiftFiles(under: Self.testsRoot) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            // Cheap pre-filter: stripping can only ever REMOVE occurrences
            // (a comment or string literal blanked to spaces), never
            // create one — so a file whose raw bytes never mention the
            // marker at all cannot hold a real one either, and the
            // (comparatively expensive, raw-string-aware) stripper below
            // never has to run on the other several hundred files under
            // `Tests/` that do not.
            guard raw.contains(Self.marker) else { continue }

            let stripped = try SwiftSource.blankingCommentsAndStrings(raw)
            let count = stripped.components(separatedBy: Self.marker).count - 1

            if file.lastPathComponent == Self.allowedFileName {
                sawAllowedFile = true
                allowedFileMentionCount = count
                allowedFileIsSerialized =
                    Self.suiteAttributeArguments(in: stripped)?.contains(".serialized") ?? false
                continue
            }
            guard count > 0 else { continue }
            offenders.append("\(file.lastPathComponent) (\(count))")
        }

        #expect(offenders.isEmpty, """
            file(s) other than \(Self.allowedFileName) call DiagnosticLog.shared directly: \
            \(offenders.sorted().joined(separator: ", "))
            """)

        // Positives beside the negative above (CLAUDE.md, "Guards that
        // name what they watch"): a missing, emptied, or accidentally
        // parallel "allowed" file would satisfy the negative above while
        // reopening the exact race this split exists to close.
        #expect(sawAllowedFile, "\(Self.allowedFileName) was not found under Tests/")
        #expect(allowedFileMentionCount >= 3, """
            \(Self.allowedFileName) mentions DiagnosticLog.shared only \
            \(allowedFileMentionCount) time(s) as code — expected at least 3, one per \
            production code path it drives
            """)
        #expect(allowedFileIsSerialized, """
            \(Self.allowedFileName)'s @Suite must carry .serialized — it is the one file \
            left free to touch the process-wide singleton, and its tests must not race \
            each other on it
            """)
    }

    /// `configure`'s own `directory:` parameter defaults to
    /// `DiagnosticLog.defaultDirectory` — the maintainer's REAL
    /// `~/Library/Logs/macSCP` — so a call in this suite that names only
    /// `level:` (typically its own cleanup, `configure(level: .off)`) points
    /// the process-wide singleton at the real log folder for as long as
    /// nothing else reconfigures it. `TunnelRunner`/`TransferEngine`/
    /// `LocalFileSystem`/`ConnectionViewModel`/`RemoteBrowserViewModel` log
    /// through `DiagnosticLog.shared` unconditionally from production code,
    /// and this suite's twelve tests run WHILE dozens of other suites
    /// (`TunnelRunnerTests`, `TunnelStoreTests`, `TransferEngineTests`, …)
    /// exercise those same paths concurrently, uncoordinated with this
    /// `.serialized` suite's own configure/defer cycle: `DiagnosticLog.log`
    /// checks `state.level` and appends the formatted line to
    /// `state.buffer` in two SEPARATE lock acquisitions, so a line admitted
    /// under one directory can still be appended — and later drained —
    /// under whatever directory a `configure(...)` call in between left
    /// live. Found by observing test-shaped lines (`path=/ziel/…`, a tunnel
    /// named `web-<hex>`) accumulate in the real
    /// `~/Library/Logs/macSCP/macSCP-<date>.log` files (docs/BACKLOG.md,
    /// "The maintainer's real diagnostic log folder holds lines shaped like
    /// test fixtures").
    ///
    /// So: every `DiagnosticLog.shared.configure(...)` call in the one file
    /// allowed to make one, including every cleanup call, names an explicit
    /// `directory:` — never the real default, not even for an instant.
    @Test("every DiagnosticLog.shared.configure( call in the shared-sink suite names an explicit directory")
    func everyConfigureCallNamesAnExplicitDirectory() throws {
        guard
            let file = Self.swiftFiles(under: Self.testsRoot).first(where: {
                $0.lastPathComponent == Self.allowedFileName
            })
        else {
            Issue.record("\(Self.allowedFileName) was not found under Tests/")
            return
        }
        let raw = try String(contentsOf: file, encoding: .utf8)
        let stripped = try SwiftSource.blankingCommentsAndStrings(raw)
        let calls = Self.callArgumentLists(of: "DiagnosticLog.shared.configure(", in: stripped)

        // Positive beside the negative below (CLAUDE.md, "Guards that name
        // what they watch"): a renamed or vanished call site would
        // otherwise satisfy the negative by finding nothing to check.
        #expect(calls.count >= 12, """
            found only \(calls.count) DiagnosticLog.shared.configure( call(s) in \
            \(Self.allowedFileName) — expected at least 12
            """)

        let missingDirectory = calls.filter { !$0.contains("directory:") }
        #expect(missingDirectory.isEmpty, """
            \(missingDirectory.count) of \(calls.count) DiagnosticLog.shared.configure( \
            calls in \(Self.allowedFileName) omit an explicit directory: argument — \
            configure's own directory parameter defaults to DiagnosticLog.defaultDirectory, \
            the maintainer's real ~/Library/Logs/macSCP, so a call that omits it (even a \
            cleanup call(level: .off)) points the process-wide singleton at the real log \
            folder for as long as nothing else reconfigures it, and a concurrently running \
            suite's own DiagnosticLog.shared.log(...) call can land a line there before the \
            next configure(...) call moves the singleton to a temp directory again.
            """)
    }
}
