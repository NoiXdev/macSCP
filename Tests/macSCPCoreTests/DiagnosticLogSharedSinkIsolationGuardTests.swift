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
}
