import Foundation
import MacSCPTestSupport
import Testing

/// Guards ONE property of `ContentView+Detail.swift`: the remote pane's
/// archive gate is built from the SAME file system the pane browses.
///
/// `RemoteArchiveRunner.init?(backend: any Sendable)` accepts any argument
/// at all, so `RemoteArchiveRunner(backend: tab)` or `(backend: session)`
/// compiles, answers `nil` forever, and no remote pane would ever offer
/// archiving again — with nothing red. The wiring cannot be instantiated
/// from a test (the same boundary `PaneRenderConditionGuardTests` documents),
/// so this is a source-text scan, over the COMMENT-FREE view of the file:
/// the gate carries a comment that names the call, and a scanner that reads
/// comments reads that one.
///
/// The positive check beside the negative one: the same file hands
/// `fileSystem: session.remoteFS` to the remote pane, which is what ties the
/// gate's argument to the pane's own object rather than only to a spelling.
@Suite("Archive gate wiring guard")
struct ArchiveGateWiringGuardTests {
    private static let sourceFile = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit/ContentView+Detail.swift")

    /// Whitespace runs collapsed to one space, so a call wrapped across
    /// lines reads the same as one written on a single line.
    private static func collapsedCode() throws -> String {
        let code = try SourceCorpus.commentFree(of: sourceFile)
        return code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    private static func arguments(ofEveryCallTo name: String, in code: String) -> [String] {
        var found: [String] = []
        var search = code.startIndex..<code.endIndex
        while let hit = code.range(of: name + "(", range: search) {
            var depth = 1
            var index = hit.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 }
                if code[index] == ")" { depth -= 1 }
                index = code.index(after: index)
            }
            found.append(
                String(code[hit.upperBound..<code.index(before: index)])
                    .trimmingCharacters(in: .whitespaces))
            search = index..<code.endIndex
        }
        return found
    }

    @Test func theRemoteGateIsBuiltFromTheRemoteFileSystemAndNothingElse() throws {
        let code = try Self.collapsedCode()
        let calls = Self.arguments(ofEveryCallTo: "RemoteArchiveRunner", in: code)
        #expect(calls == ["backend: session.remoteFS"])
    }

    /// The positive beside it: the remote pane is handed the very object the
    /// gate asks about. Without this, the spelling above could be satisfied
    /// by a gate over an object the pane does not browse.
    @Test func thePaneBrowsesTheSameObjectTheGateAsks() throws {
        let code = try Self.collapsedCode()
        #expect(code.contains("fileSystem: session.remoteFS"))
        #expect(
            code.contains(
                "supportsArchiving: RemoteArchiveRunner(backend: session.remoteFS) != nil"))
    }

    /// The local pane has no capability to read: it archives with the
    /// system's own tools, so its gate is the literal `true`.
    @Test func theLocalPaneIsAlwaysOffered() throws {
        let code = try Self.collapsedCode()
        #expect(code.contains("supportsArchiving: true"))
    }
}
