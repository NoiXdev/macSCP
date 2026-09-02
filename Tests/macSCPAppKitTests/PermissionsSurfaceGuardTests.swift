import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The stretch `PermissionsPresentationTests` cannot reach: that the
/// capability actually ARRIVES at the sheet. The value can decide
/// perfectly and the surface still show an editor on an object store, by
/// one pane forgetting to read the flag, or by the pane reading it and
/// never handing it on. Neither edit shows up in a test of the value.
///
/// Built to the rules in `CLAUDE.md`, after `ChecksumSurfaceGuardTests`:
/// every check requires something PRESENT; the names come off the types
/// where a type exists to read them from; the one name spelled here is
/// pinned by a positive check that the sheet still has it.
@Suite("Permissions surface")
struct PermissionsSurfaceGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/PermissionsSurfaceGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let detailPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"
    private static let panePath = "Sources/MacSCPAppKit/BrowserPane.swift"
    private static let sheetsPath = "Sources/MacSCPAppKit/BrowserSheets.swift"
    private static let tablePath = "Sources/MacSCPAppKit/RemoteFileTableView.swift"

    /// The file's CODE, with every `//` line comment cut away, for the
    /// reason `ChecksumSurfaceGuardTests.source(_:)` gives: this project's
    /// comments quote the code they describe, and a scanner cannot tell
    /// prose from a call.
    ///
    /// `ContentView+Detail.swift` holds two string literals containing
    /// `//` (an `http://` and an `https://` in one sentence about a
    /// plaintext password); the cut lands mid-literal there, and nothing
    /// this suite looks for stands on those lines.
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

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// How many times `text` reads a member of the type named `name` —
    /// `Name.member`, with the dot allowed to start the next line, which
    /// is how a long argument wraps. Measured: the first wiring of the
    /// local pane wrapped exactly there, and a needle of `Name.` counted
    /// it as no reading at all.
    private static func memberReadings(of name: String, in text: String) throws -> Int {
        let pattern = NSRegularExpression.escapedPattern(for: name) + "\\s*\\."
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The argument list of the first call to `name(` in `text`: from that
    /// opening parenthesis to the one that balances it. Closures inside
    /// carry their own balanced parentheses, so depth counting is enough.
    private static func argumentList(ofCallTo name: String, in text: String) -> Substring? {
        guard let start = text.range(of: name + "(") else { return nil }
        var depth = 0
        var index = start.upperBound
        index = text.index(before: index)   // the `(` itself
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return text[start.upperBound..<index] }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Every pane the detail view builds states whether permissions are
    /// offered, by reading the availability — the remote pane off the
    /// capability, the local pane off the local file system's declaration.
    /// The count is derived from the file, not written here: as many
    /// readings as there are panes built.
    @Test func everyPaneReadsThePermissionsAvailability() throws {
        let detail = try Self.source(Self.detailPath)
        let panes = Self.occurrences(of: String(describing: BrowserPane.self) + "(", in: detail)
        #expect(panes >= 1, """
            \(Self.detailPath) builds no \(BrowserPane.self) at all, so the check below \
            would be comparing two zeros.
            """)

        let readings = try Self.memberReadings(of: String(describing: PermissionsAvailability.self), in: detail)
        #expect(readings == panes, """
            \(Self.detailPath) builds \(panes) pane(s) and reads \
            \(PermissionsAvailability.self) \(readings) time(s). A pane built without \
            reading it falls back to the property's default, and the default is not \
            an answer about that pane's backend.
            """)
    }

    /// The sheet has a stored property by this name. Spelled once, here,
    /// and pinned by reflection so that renaming it turns this red instead
    /// of leaving the check below matching nothing.
    private static let supportsPermissionsLabel = "supportsPermissions"

    @MainActor
    private static func aSheet() -> InfoPermissionsSheet {
        InfoPermissionsSheet(
            item: RemoteFileItem(name: "a", path: "/a", kind: .file),
            onApply: { _ in nil },
            onApplyRecursively: { _, _, _ in PermissionsTreeResult() },
            checksumAlgorithm: .preferred,
            supportsChecksum: false,
            onComputeChecksum: { .unavailableOnThisConnection },
            supportsPermissions: false)
    }

    /// The pane hands the sheet what it was told. `BrowserPane` is the one
    /// place that constructs the sheet, and it is exactly where the flag
    /// could be read for the menu and then dropped on the way to the
    /// editor.
    @MainActor
    @Test func thePaneHandsTheSheetWhatItWasTold() throws {
        let labels = Mirror(reflecting: Self.aSheet()).children.compactMap(\.label)
        #expect(labels.contains(Self.supportsPermissionsLabel), """
            \(InfoPermissionsSheet.self) has no stored property named \
            `\(Self.supportsPermissionsLabel)` — the check below is looking for an \
            argument the sheet no longer takes.
            """)

        let pane = try Self.source(Self.panePath)
        let call = String(describing: InfoPermissionsSheet.self)
        let arguments = try #require(Self.argumentList(ofCallTo: call, in: pane), """
            \(Self.panePath) never constructs \(call).
            """)
        // The Bool is computed first so a failure reports it, not the whole
        // argument list (`#expect` prints the source and value of what it
        // checks).
        let handedOn = arguments.contains(Self.supportsPermissionsLabel + ":")
        #expect(handedOn, """
            \(Self.panePath) constructs \(call) without passing \
            `\(Self.supportsPermissionsLabel)`, so the sheet decides from its default \
            rather than from the pane's backend.
            """)
    }

    /// The pane hands the TABLE the same flag, because the table is where
    /// the menu entry's title is chosen — and the title is the one place
    /// left where "Permissions" could be promised on a backend that has
    /// none. Same argument-list scan as above, same pinned name.
    @MainActor
    @Test func thePaneHandsTheTableWhatItWasTold() throws {
        let labels = Mirror(reflecting: Self.aSheet()).children.compactMap(\.label)
        #expect(labels.contains(Self.supportsPermissionsLabel))

        let pane = try Self.source(Self.panePath)
        let call = String(describing: RemoteFileTableView.self)
        let arguments = try #require(Self.argumentList(ofCallTo: call, in: pane), """
            \(Self.panePath) never constructs \(call).
            """)
        let handedOn = arguments.contains(Self.supportsPermissionsLabel + ":")
        #expect(handedOn, """
            \(Self.panePath) constructs \(call) without passing \
            `\(Self.supportsPermissionsLabel)`, so the menu titles the entry from the \
            table's default rather than from the pane's backend.
            """)
    }

    /// The table titles the entry through the presentation's function,
    /// so the title `PermissionsPresentationTests` pins is the one shown.
    @Test func theTableTitlesTheEntryThroughThePresentation() throws {
        let call = String(describing: PermissionsPresentation.self) + ".infoMenuTitle("
        let table = try Self.source(Self.tablePath)
        let titlesThroughIt = table.contains(call)
        #expect(titlesThroughIt, """
            \(Self.tablePath) never calls \(call). Whatever the entry is titled, it is \
            not the title the presentation tests hold.
            """)
    }

    /// The sheet decides through the value, not with an `if` of its own
    /// over the bits — so the decision `PermissionsPresentationTests` pins
    /// is the one the view makes.
    @Test func theSheetDecidesThroughThePresentation() throws {
        let call = String(describing: PermissionsPresentation.self) + ".of("
        let sheets = try Self.source(Self.sheetsPath)
        let decidesThroughIt = sheets.contains(call)
        #expect(decidesThroughIt, """
            \(Self.sheetsPath) never calls \(call). Whatever the sheet shows in the \
            permissions block, it is not the decision the presentation tests hold.
            """)
    }
}
