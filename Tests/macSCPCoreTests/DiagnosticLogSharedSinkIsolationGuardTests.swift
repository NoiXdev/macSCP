import Foundation
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
/// first (`stripCommentsAndStrings` below), so a doc comment explaining the
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

    // MARK: - Comment-and-string blanking, raw strings included
    //
    // Adapted from `TabContextMenuWiringGuardTests`'s own copy — that
    // file's doc comment states why raw strings are PARSED here rather
    // than refused the way the shared `SwiftSource` module (`Tests/
    // macSCPCoreTests/SwiftSourceStripping.swift`) deliberately still
    // does: refusing a raw-string delimiter is right for a scan that reads
    // one file with none, and wrong for a scan that reads the whole
    // `Tests/` tree, where an ordinary raw string in an unrelated file
    // would turn this guard red with a message naming neither the file
    // nor a remedy. `PollingGuardTests.swift` copied the same reasoning
    // for the same reason — this is the third copy in this target, all
    // citing the first.

    private enum StripError: Error, CustomStringConvertible {
        case unterminatedLiteral

        var description: String {
            "unterminated string or comment literal — the scanner ran to the end of the file still inside one"
        }
    }

    /// Whether a raw-string/regex-literal opened with `hashes` hashes and
    /// `quotes` quotes ends exactly at `index`. With `quotes: 0` it answers
    /// the same question for an extended regex literal (`#/…/#`), whose
    /// closing slash the caller has already stepped over.
    private static func closesRawString(
        _ chars: [Character], at index: Int, quotes: Int, hashes: Int
    ) -> Bool {
        guard index + quotes + hashes <= chars.count else { return false }
        for offset in 0..<quotes where chars[index + offset] != "\"" { return false }
        for offset in 0..<hashes where chars[index + quotes + offset] != "#" { return false }
        return true
    }

    /// Strips `//` and `/* */` comments (nesting-aware) and `"..."`,
    /// `"""..."""`, and raw (`#"…"#`, `##"…"##`, `#"""…"""#`) string
    /// literals, replacing their content with spaces so a scan sees only
    /// code — never a sentence about code, and never a fixture string
    /// holding the identifier as data.
    private static func stripCommentsAndStrings(_ source: String) throws -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                result.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    result.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "#" {
                var j = i
                while j < chars.count, chars[j] == "#" { j += 1 }
                let hashes = j - i
                if j < chars.count, chars[j] == "/" {
                    // An extended regex literal, `#/…/#`.
                    var k = j + 1
                    var closed = false
                    while k < chars.count {
                        if chars[k] == "/",
                            closesRawString(chars, at: k + 1, quotes: 0, hashes: hashes)
                        {
                            k += 1 + hashes
                            closed = true
                            break
                        }
                        result.append(chars[k] == "\n" ? "\n" : " ")
                        k += 1
                    }
                    guard closed else { throw StripError.unterminatedLiteral }
                    result.append(" ")
                    i = k
                    continue
                }
                if j < chars.count, chars[j] == "\"" {
                    // A raw string states its own terminator: the same
                    // number of hashes, after the same number of quotes.
                    let isMultiline =
                        j + 2 < chars.count && chars[j + 1] == "\"" && chars[j + 2] == "\""
                    let quotes = isMultiline ? 3 : 1
                    var k = j + quotes
                    var closed = false
                    while k < chars.count {
                        if closesRawString(chars, at: k, quotes: quotes, hashes: hashes) {
                            k += quotes + hashes
                            closed = true
                            break
                        }
                        result.append(chars[k] == "\n" ? "\n" : " ")
                        k += 1
                    }
                    guard closed else { throw StripError.unterminatedLiteral }
                    result.append(" ")
                    i = k
                    continue
                }
                // Not a string delimiter: `#expect`, `#filePath`, `#if`.
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                guard i + 2 < chars.count else { throw StripError.unterminatedLiteral }
                i += 3
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { throw StripError.unterminatedLiteral }
                i += 1
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        guard blockCommentDepth == 0 else { throw StripError.unterminatedLiteral }
        return result
    }

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

            let stripped = try Self.stripCommentsAndStrings(raw)
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
