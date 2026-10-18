import Foundation
import MacSCPTestSupport
import Testing

/// A view that bounds its own size declares the bound as a value
/// (`BoundedView.bound`) and applies it with `.sheetBound(Self.bound)`. It
/// does not spell the size at the root of its body. This scan keeps it so:
/// the three spellings the marker replaced (`.frame(width:)`,
/// `.frame(width:height:)`, `.frame(minWidth:maxWidth:)`) were the reason no
/// single search found every view that clips, and a clipping defect reached
/// the maintainer as a screenshot instead of a red test.
///
/// "Root" is read off the indentation, as `scripts/sheet-bound-inventory`
/// reads it: a modifier at eight spaces is a modifier of a `body` (or of a
/// computed view property) at the first level of a type. A `.frame` nested
/// deeper bounds a control inside the view, which is not what this scan is
/// about.
///
/// Both halves read the blanked code view, so a comment that quotes a
/// spelling neither trips the negative half nor satisfies the positive one.
@Suite("Bound declaration scan")
struct BoundDeclarationScanTests {
    private static let appKitSources: URL = SourceCorpus.url(of: .sources)
        .appendingPathComponent("MacSCPAppKit", isDirectory: true)

    /// The three spellings, anchored at the root-level indentation.
    private static let rootLevelSpellings: [(name: String, pattern: String)] = [
        ("width", #"^        \.frame\(width: \d+\)$"#),
        ("width+height", #"^        \.frame\(width: \d+, height: \d+\)$"#),
        ("capped", #"^        \.frame\(minWidth: \d+, maxWidth: \d+\)$"#),
    ]

    /// Every Swift file under the app's own sources, blanked of comments and
    /// string literals, paired with its name.
    private static func blankedSources() throws -> [(name: String, code: String)] {
        let urls = try SourceCorpus.files(under: appKitSources).filter { $0.pathExtension == "swift" }
        let code = try SourceCorpus.code(ofAll: urls)
        return zip(urls, code).map { ($0.lastPathComponent, $1) }
    }

    @Test func noViewSpellsASizeLiteralAtItsRoot() throws {
        let sources = try Self.blankedSources()
        var offenders: [String] = []
        for (name, code) in sources {
            for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for spelling in Self.rootLevelSpellings
                where line.range(of: spelling.pattern, options: .regularExpression) != nil {
                    offenders.append("\(name):\(index + 1) \(spelling.name) \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.count) root-level size literals:\n\(offenders.joined(separator: "\n"))")
    }

    /// The positive half of the test above. A check that something is ABSENT
    /// passes on an empty corpus, so this one requires the corpus to hold
    /// what it is expected to hold: a type that is known to bound itself, and
    /// as many applications of the marker as there are bounded views.
    @Test func theScanSeesTheFileItClaimsToRead() throws {
        let sources = try Self.blankedSources()
        #expect(!sources.isEmpty)
        let editor = try #require(sources.first { $0.name == "FileActionEditor.swift" })
        #expect(editor.code.contains("FileActionEditor"))

        let marker = ".sheetBound(Self.bound)"
        let applications = sources.reduce(0) { $0 + $1.code.components(separatedBy: marker).count - 1 }
        #expect(applications >= 33, "\(applications) applications of the marker")

        // Every application needs a declaration beside it: the marker names
        // `Self.bound`, which only a conformer provides.
        let declaration = "static let bound: SheetBound"
        let declarations = sources.reduce(0) { $0 + $1.code.components(separatedBy: declaration).count - 1 }
        #expect(declarations >= 33, "\(declarations) declarations of a bound")

        // And the negative half's patterns do match what they are written to
        // match, so a pattern that has gone stale cannot pass in silence.
        let samples = [
            "        .frame(width: 420)", "        .frame(width: 640, height: 480)",
            "        .frame(minWidth: 420, maxWidth: 460)",
        ]
        for (spelling, sample) in zip(Self.rootLevelSpellings, samples) {
            #expect(sample.range(of: spelling.pattern, options: .regularExpression) != nil, "\(spelling.name)")
        }
    }
}
