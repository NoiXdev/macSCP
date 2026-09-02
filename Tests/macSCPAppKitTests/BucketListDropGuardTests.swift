import Foundation
import Testing
import macSCPCore

/// Guards the half of "a bucket row opens, nothing else" that no Core test
/// can reach: the pane's DROP target (2026-09-02, Task 4).
///
/// The menu and the keyboard both run through one Core predicate
/// (`BrowserContextMenu.entries`), and `BrowserContextMenuTests` /
/// `BrowserKeyCommandTests` hold them to it. The drop is the third door, and
/// it is a SwiftUI modifier — this project renders no view in a test, so
/// this is a source scan, the same arrangement as
/// `GenerateKeyCaptionWiringGuardTests` and `SheetFacetWiringGuardTests`.
///
/// What it exists to catch: dropping a local folder onto the bucket list
/// makes `TransferEngine` call `createDirectory("/<name>")`, which
/// `S3FileSystem` refuses (`RemoteFSError.bucketLevelRefused`) and the queue
/// then explains. Correct, and still not the behaviour the design asks for:
/// the pane must decline the drop and never highlight for it, so nothing is
/// queued in the first place.
///
/// Every check below is POSITIVE — it requires something to be present.
/// That is deliberate: a `!contains` here would start matching nothing the
/// moment the modifier or the property is renamed, and read exactly like a
/// check that is satisfied (CLAUDE.md, "Guards that name what they watch").
@Suite("Bucket-list drop wiring")
struct BucketListDropGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/BucketListDropGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let paneSourceFile =
        repoRoot.appendingPathComponent("Sources/MacSCPAppKit/BrowserPane.swift")

    /// Doc comments in this file NAME the property the scans below look
    /// for, so an unstripped read would find the prose and call it wiring —
    /// the exact collision CLAUDE.md records ("Source-scanning guards read
    /// comments too").
    private static func strippedSource() throws -> String {
        SheetFacetWiringGuardTests.strippingLineComments(
            try String(contentsOf: paneSourceFile, encoding: .utf8))
    }

    /// The pane's own gate, and the fact that it asks Core rather than
    /// re-deciding. Also the positive anchor for both region scans below:
    /// without it, a pane that dropped the gate entirely would leave them
    /// scanning for a name that exists nowhere.
    @Test func theDropGateExistsAndAsksTheScopeForItsAnswer() throws {
        let source = try Self.strippedSource()

        #expect(source.contains("private var \(Self.gate): Bool"), """
            BrowserPane.swift no longer declares `\(Self.gate)`. Either the \
            drop gate was renamed — rename it here too — or it was removed, \
            in which case a local folder can be dropped onto the bucket list \
            again and this guard has nothing left to watch.
            """)
        #expect(source.contains("scope.\(Self.gate)"), """
            BrowserPane's drop gate no longer reads `BrowserScope.\(Self.gate)`; \
            a second copy of the rule has appeared in the App layer.
            """)
    }

    /// The drop HANDLER consults it — so a folder dropped on the bucket list
    /// is declined before a single transfer is queued.
    @Test func theDropHandlerConsultsTheGate() throws {
        let source = try Self.strippedSource()
        let region = try Self.region(after: ".onDrop(of: [.fileURL]", in: source, length: 300)

        #expect(region.contains(Self.gate), """
            the .onDrop handler does not mention `\(Self.gate)` within 300 \
            characters of the modifier: \(region)
            """)
    }

    /// …and so does the HIGHLIGHT, so the pane never invites a drop it is
    /// going to refuse. Two doors, two checks: a gate wired into only the
    /// handler still lights the border up under the user's cursor.
    @Test func theDropHighlightConsultsTheGateToo() throws {
        let source = try Self.strippedSource()
        let region = try Self.region(after: ".strokeBorder(tint", in: source, length: 200)

        #expect(region.contains(Self.gate), """
            the drop highlight does not mention `\(Self.gate)` within 200 \
            characters of `.strokeBorder(tint`: \(region)
            """)
    }

    /// The table gets the same scope, so the menu and the keyboard are
    /// gated by the value this pane computed rather than by a default that
    /// silently says "ordinary".
    @Test func theFileTableIsHandedThisPanesScope() throws {
        let source = try Self.strippedSource()

        #expect(source.contains("scope: scope"), """
            BrowserPane no longer forwards its `scope` to RemoteFileTableView, \
            so the context menu and the keyboard fall back to \
            `BrowserScope.ordinary` and a bucket row offers everything again.
            """)
    }

    /// The gate's name, in one place. Spelled rather than derived because
    /// it names a PRIVATE property of a SwiftUI view, which no test can
    /// reach through the type system — the compile-time half is the
    /// reference below, which stops compiling if Core's own property is
    /// renamed out from under the App's.
    private static let gate = "acceptsDroppedFiles"

    /// Fails loudly when `marker` is absent, rather than returning an empty
    /// region that every `contains` below would then report as a miss with
    /// a misleading message — or, worse, that a `!contains` would report as
    /// satisfied.
    private static func region(
        after marker: String, in source: String, length: Int
    ) throws -> String {
        let markerRange = try #require(source.range(of: marker), """
            BrowserPane.swift no longer contains "\(marker)" — this guard is \
            pointed at a region that does not exist.
            """)
        let end = source.index(
            markerRange.upperBound, offsetBy: length, limitedBy: source.endIndex)
            ?? source.endIndex
        return String(source[markerRange.upperBound..<end])
    }

    /// The compile-time half of `gate`: Core's property is referenced by
    /// name here, so renaming it breaks this file rather than leaving the
    /// scans above quietly looking for a string nothing writes any more.
    @Test func coreStillOffersTheRuleTheAppLayerAsksFor() {
        #expect(BrowserScope.ordinary.acceptsDroppedFiles)
        #expect(!BrowserScope(rootIsContainerList: true, currentPath: "/").acceptsDroppedFiles)
    }
}
