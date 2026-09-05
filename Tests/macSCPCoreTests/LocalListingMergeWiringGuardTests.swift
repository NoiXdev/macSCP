import Foundation
import Testing
@testable import macSCPCore

/// Task 3 (local-listing-never-blocks design, point 3) holds two wiring
/// facts in place by scanning source rather than by re-running behavior:
///
/// 1. POSITIVE — `RemoteBrowserViewModel.load()`'s own body actually calls
///    `LocalMetadataSource.metadata(for:)`. Without this, the merge tests in
///    `RemoteBrowserViewModelMetadataMergeTests.swift` are the only thing
///    standing between a silent regression (someone deletes the phase-two
///    branch, and every FAKE file system in those tests still happens to
///    behave, since a fake's `metadata(for:)` is never called from
///    production code either way) and nobody noticing.
/// 2. NEGATIVE, with a POSITIVE beside it — `LocalFileSystem.list`'s own
///    body makes no `resourceValues(` call. Task 1 moved the per-entry
///    metadata fetch out of `list`'s loop entirely; Task 2 gave it a new
///    home in `metadata(for:)`'s child tasks. The positive beside it proves
///    the scan can find a REAL `resourceValues(` call elsewhere in the same
///    file (`stat`, `item(for:)`, the bulk-prefetch read in
///    `listNamesAndKinds`) — without it, an accidentally emptied-out scan
///    (a typo in the function name, a moved file) would read exactly like a
///    passing guard (CLAUDE.md: "Guards that name what they watch" — "only a
///    NEGATIVE check can go stale in silence").
///
/// Both bodies are read via a brace-balanced extraction (parameter list
/// parens first, then the body's braces — the same two-pass shape
/// `PollingGuardTests.functionBody(afterParametersAt:in:)` and
/// `TransferQueueBarCancelGuardTests.declarationBodyRange` use for the same
/// reason elsewhere in this tree), over source with comments and string
/// literals blanked by the shared `SwiftSource.stripCommentsAndStrings`
/// (`SwiftSourceStripping.swift`) — so a comment that quotes either shape to
/// explain it can neither satisfy the positive nor trip the negative.
@Suite("Local listing merge wiring")
struct LocalListingMergeWiringGuardTests {
    private static var coreSourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // macSCPCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/macSCPCore")
    }

    private static func readStripped(_ relativePath: String) throws -> String {
        let text = try String(
            contentsOf: coreSourcesRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return try SwiftSource.stripCommentsAndStrings(text)
    }

    /// Positive: `load()`'s own body reaches `LocalMetadataSource
    /// .metadata(for:)` — the phase-two merge this task wires in.
    @Test func loadConsumesMetadataForStream() throws {
        let stripped = try Self.readStripped("Presentation/RemoteBrowserViewModel.swift")
        let body = try Self.functionBody(named: "load", in: stripped)
        #expect(body.contains("metadata(for:"), "\(body)")
    }

    /// Negative: `LocalFileSystem.list`'s own body makes no `resourceValues(`
    /// call, beside the positive that the same (stripped) file still makes
    /// one elsewhere — see this suite's own doc comment.
    @Test func listMakesNoPerEntryResourceValuesCallInItsOwnBody() throws {
        let stripped = try Self.readStripped("RemoteFS/LocalFileSystem.swift")
        let body = try Self.functionBody(named: "list", in: stripped)
        #expect(!body.contains("resourceValues("), "\(body)")

        #expect(stripped.contains("resourceValues("))
    }

    // MARK: - Brace-balanced body extraction

    private enum ScanError: Error {
        case declarationNotFound
        case bodyNotFound
        case unbalancedBraces
    }

    /// Finds the FIRST `func <name>(` declaration in `source` and returns
    /// its brace-balanced body: the parameter list's parens are balanced
    /// first (so a default-argument expression containing `(` cannot be
    /// misread as closing the list early), then the body's own braces —
    /// the same two-pass shape used elsewhere in this tree for the same
    /// reason (`PollingGuardTests.functionBody(afterParametersAt:in:)`,
    /// `TransferQueueBarCancelGuardTests.declarationBodyRange`), kept as its
    /// own small copy here rather than shared: this guard is the only
    /// caller in `macSCPCoreTests` that needs a NAMED-function lookup
    /// (`PollingGuardTests`'s own copy finds every helper `func`, not one
    /// named declaration).
    private static func functionBody(named name: String, in source: String) throws -> String {
        let pattern = try NSRegularExpression(
            pattern: #"\bfunc\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#)
        let nsrange = NSRange(source.startIndex..., in: source)
        guard let match = pattern.firstMatch(in: source, range: nsrange),
            let wholeRange = Range(match.range, in: source)
        else { throw ScanError.declarationNotFound }

        var parenDepth = 0
        var index = source.index(before: wholeRange.upperBound)
        while index < source.endIndex {
            if source[index] == "(" {
                parenDepth += 1
            } else if source[index] == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let afterParams = source.index(after: index)
                    guard let openBrace = source[afterParams...].firstIndex(of: "{") else {
                        throw ScanError.bodyNotFound
                    }
                    var braceDepth = 0
                    var cursor = openBrace
                    while cursor < source.endIndex {
                        if source[cursor] == "{" {
                            braceDepth += 1
                        } else if source[cursor] == "}" {
                            braceDepth -= 1
                            if braceDepth == 0 {
                                return String(source[source.index(after: openBrace)..<cursor])
                            }
                        }
                        cursor = source.index(after: cursor)
                    }
                    throw ScanError.unbalancedBraces
                }
            }
            index = source.index(after: index)
        }
        throw ScanError.declarationNotFound
    }
}
