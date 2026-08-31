import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The one property `ChecksumDisplayTests` cannot reach: that the view
/// actually shows what the display computed.
///
/// `ChecksumDisplay.of(_:)` can be perfect and the surface still lie, by
/// rendering the digest and dropping the sentence beside it. That is not a
/// hypothetical edit — it is the smallest, most plausible one, because the
/// digest is the thing somebody asked for and the sentence looks like
/// decoration. This project has no SwiftUI rendering harness (the boundary
/// its other wiring guards document), so the check reads source.
///
/// It is built to the two rules in `CLAUDE.md`:
///
/// - **Every check here is positive.** It requires something to be
///   PRESENT, so it fails loudly the moment what it names moves, instead
///   of quietly matching nothing. The one negative check below stands
///   beside a positive one over the same file.
/// - **Nothing spells a symbol it could read.** The properties come off
///   `Mirror`, and the view's name off the type. Rename either and this
///   guard follows it rather than going silent.
@Suite("Checksum surface")
struct ChecksumSurfaceGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ChecksumSurfaceGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The file's CODE, with every `//` comment cut away.
    ///
    /// Stripping is not tidiness, it is the whole difference between a
    /// guard and a comment that runs. Measured: with the raw text, moving
    /// the info sheet off `ChecksumResultView` and onto its own `Text` left
    /// this suite green — because a doc comment in that file mentions the
    /// view by name, and `contains` cannot tell prose from a call. Every
    /// check below therefore reads this, and every check below looks for a
    /// CALL (`Name(`) rather than a name.
    ///
    /// Line comments only. Neither file scanned here holds a string literal
    /// containing `//` (checked in the pass that writes this), and a block
    /// comment in either would be stripped by nothing — so a `/* … */`
    /// mentioning one of these names could still satisfy a check. The way
    /// out of that is the call-shape requirement, not a second parser.
    private static func source(_ relativePath: String) throws -> String {
        let raw = try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static let viewsPath = "Sources/MacSCPAppKit/ChecksumViews.swift"
    private static let sheetsPath = "Sources/MacSCPAppKit/BrowserSheets.swift"

    /// A multipart ETag, because it is the value whose qualification
    /// carries the whole point — and because reflecting over any
    /// `ChecksumDisplay` yields the same property names.
    private static func multipartDisplay() throws -> ChecksumDisplay {
        let etag = try #require(
            FileChecksum.objectStorageETag("\"\(String(repeating: "b", count: 32))-3\""))
        return ChecksumDisplay.of(.checksum(etag))
    }

    /// Every part the display computes is read by the view that renders
    /// it. Add a fourth part and this fails until the view shows it;
    /// delete the line that renders the qualification and it fails at
    /// once.
    ///
    /// The floor of three is a claim about `ChecksumDisplay`, counted in
    /// the pass that writes this sentence: `value`, `qualification`,
    /// `severity`. It is here so an empty reflection — a `Mirror` that
    /// stopped seeing anything — cannot satisfy the loop by iterating
    /// nothing.
    @Test func theViewReadsEveryPartOfTheDisplay() throws {
        let properties = Mirror(reflecting: try Self.multipartDisplay())
            .children.compactMap(\.label)
        #expect(properties.count >= 3, """
            reflection over ChecksumDisplay found \(properties.count) stored propert(ies). \
            The loop below can only guard what this list holds, so a list that shrank is \
            this guard going quiet rather than the display getting simpler.
            """)

        let source = try Self.source(Self.viewsPath)
        for property in properties {
            #expect(source.contains(".\(property)"), """
                \(Self.viewsPath) never reads `.\(property)`. The display computes it and \
                the view drops it — which for `qualification` means a digest shown with \
                nothing said about where it came from, and for a multipart ETag that is a \
                number presented as a file's checksum when it is not one.
                """)
        }
    }

    /// The info sheet renders the checksum THROUGH that view rather than
    /// formatting a digest itself. The view's name is read off the type,
    /// so renaming it moves this check with it.
    @Test func theInfoSheetGoesThroughTheChecksumView() throws {
        let call = String(describing: ChecksumResultView.self) + "("
        let sheets = try Self.source(Self.sheetsPath)

        #expect(sheets.contains(call), """
            \(Self.sheetsPath) never CALLS \(call). The info sheet is where one file's \
            checksum is asked for, and it is the surface most likely to grow its own \
            Text(…) over half the display — which is exactly the rendering that omits the \
            provenance.
            """)
    }

    /// No surface formats a digest for itself. The positive check above it
    /// is what keeps this from being a filter that matches nothing: a file
    /// that stopped mentioning the view at all would pass a bare
    /// "does not contain" every time.
    @Test func noSurfaceReachesPastTheDisplayIntoTheValue() throws {
        for path in [Self.viewsPath, Self.sheetsPath] {
            let source = try Self.source(path)
            #expect(source.contains(String(describing: ChecksumResultView.self) + "("), """
                \(path) no longer calls the checksum view at all, so the check below is \
                reading a file that has nothing to do with checksums any more.
                """)
            #expect(!source.contains(".hex"), """
                \(path) reads a checksum's raw hex. Everything a surface shows about a \
                checksum comes from ChecksumDisplay, precisely so that reaching the digest \
                and reaching the sentence beside it are the same act.
                """)
        }
    }
}
