import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// The invariant `ConnectionActionContext.configuredBucket` rests on: **a tab's
/// connection form is never edited while that tab has a session.**
///
/// The toolbar's "Versioning…" row reads the bucket out of
/// `tab.connectionViewModel.values` (`connectionActionContext(in:session:)`),
/// because the file system does not expose the bucket it was dialled with. The
/// copy equals the live connection's bucket only if nothing writes the form
/// between the dial and the click. Three facts in three places make that so,
/// and this suite pins each so that breaking one is red rather than silent --
/// the consequence of the copy going wrong is an irreversible write on a
/// bucket the person was not looking at (turning versioning on can never be
/// undone):
///
/// 1. `formTarget()` hands a connected tab's form-filling actions a FRESH tab
///    instead (`ContentView.swift`).
/// 2. The detail pane constructs `ConnectionFormView` only in the arm taken
///    while `tab.session == nil` (`ContentView+Detail.swift`).
/// 3. `connect(in:stored:)` tears an existing session down BEFORE it fills the
///    form (`ContentView.swift`).
///
/// These are reads of source, so each negative-looking property has a positive
/// beside it: every anchor is `#require`d, so a renamed or moved symbol fails
/// by name instead of passing over nothing. The scans read `SourceCorpus.code`,
/// with comments and string literals blanked, so the prose that describes the
/// invariant cannot satisfy or trip them. Names that the compiler can supply
/// are read from the types.
///
/// What this does NOT pin: every other writer of `values` is reachable only
/// through those three (the review that established the invariant enumerated
/// them), so a NEW writer that bypasses all three would not be seen here. A
/// Core member exposing the connection's own bucket would delete the copy and
/// with it this suite's reason to exist.
@Suite("Connected tab form invariant")
struct ConnectedTabFormInvariantTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func code(_ relativePath: String) throws -> String {
        try SourceCorpus.code(of: repoRoot.appendingPathComponent(relativePath))
    }

    // MARK: - 1. A connected tab's form is not the target

    @Test func formTargetGivesAConnectedTabAFreshOneInstead() throws {
        let source = try Self.code("Sources/MacSCPAppKit/ContentView.swift")
        let body = try #require(SourceSpan.body(after: "func formTarget(", in: source))
        // The condition is EXACTLY "this tab is connected" -- `&& false` or
        // any other narrowing leaves the tokens present and the property gone.
        let guardClause = try #require(
            body.firstMatch(of: #/if\s+(\w+)\.isConnected\s*\{(?<inner>[^}]*)\}/#))
        #expect(guardClause.output.inner.contains("makeTab("))
        // And it is the FIRST thing the function decides, before the path
        // that returns the existing tab.
        let returnsExisting = try #require(body.range(of: "return tab"))
        let fresh = try #require(body.range(of: "makeTab("))
        #expect(fresh.lowerBound < returnsExisting.lowerBound)
    }

    // MARK: - 2. The form is mounted only without a session

    /// The one construction of the form sits in an arm that follows the
    /// session arm's closing brace, introduced by `else`: it cannot be on
    /// screen for a tab that has a session. The set of files constructing it
    /// is read, so a second place that mounts it (a sheet over a connected
    /// tab, say) is a red naming the file.
    @Test func theFormIsConstructedOnlyInTheArmWithoutASession() throws {
        let name = String(describing: ConnectionFormView.self)
        let constructor = try Regex("(?:^|\\W)\(name)\\(")

        let sources = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit", isDirectory: true)
        let swiftFiles = try SourceCorpus.files(under: sources).filter { $0.pathExtension == "swift" }
        let codes = try SourceCorpus.code(ofAll: swiftFiles)
        var constructing: [String] = []
        for (url, text) in zip(swiftFiles, codes)
        where url.lastPathComponent != "\(name).swift" && !text.matches(of: constructor).isEmpty {
            constructing.append(url.lastPathComponent)
        }
        #expect(constructing == ["ContentView+Detail.swift"], "\(constructing)")

        let detail = try Self.code("Sources/MacSCPAppKit/ContentView+Detail.swift")
        let sessionArm = try #require(detail.range(of: "if let session = tab.session {"))
        let open = try #require(detail[sessionArm.lowerBound...].firstIndex(of: "{"))
        let close = try #require(SourceSpan.closingBrace(from: open, in: detail))
        let afterArm = detail[detail.index(after: close)...].drop { $0.isWhitespace }
        #expect(afterArm.hasPrefix("else"), "the session arm is not followed by an else")

        let constructions = detail.matches(of: constructor)
        #expect(!constructions.isEmpty)
        for construction in constructions {
            #expect(
                construction.range.lowerBound > close,
                "the form is constructed inside the arm that has a session")
        }
    }

    // MARK: - 3. A session is torn down before the form is filled

    @Test func connectTearsTheOldSessionDownBeforeItFillsTheForm() throws {
        let source = try Self.code("Sources/MacSCPAppKit/ContentView.swift")
        let body = try #require(SourceSpan.body(after: "func connect(", in: source))
        let teardown = try #require(
            body.firstMatch(of: #/if\s+tab\.isConnected\s*\{\s*await\s+teardown\(/#))
        let fill = try #require(body.range(of: "fillForm("))
        #expect(teardown.range.lowerBound < fill.lowerBound)
    }
}
