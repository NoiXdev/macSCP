import Foundation
import Testing

@testable import MacSCPAppKit

/// The sidebar's "Duplicate" entry: that it exists, that it decides nothing,
/// and that it is never drawn dead.
///
/// `SessionSidebar` cannot be instantiated in this project — there is no
/// view-render harness, the boundary `SidebarTreeWiringTests` and the other
/// guards in this target already state — so this is a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/SessionSidebar.swift`, with the same known blind
/// spots that suite lists: it is line-based and literal, and it sees nothing
/// moved into another file.
///
/// What it is FOR is the split the design draws: what a copy carries is
/// `SessionDuplication`'s answer (pinned in `SessionDuplicationTests`), and
/// the menu entry's whole job is to ask for one and put the selection on
/// what came back. An entry that built its own copy — a `StoredSession(...)`
/// assembled in a menu body, a name derived beside `freeName` — would leave
/// every one of those Core tests green.
@Suite("Sidebar duplicate entry wiring guard")
struct SidebarDuplicateEntryWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SidebarDuplicateEntryWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: Self.sourceFile, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Every line that speaks of duplicating, in either capitalization —
    /// what the two positive checks below look for their anchors in. It is
    /// deliberately NOT what the disabled scan reads; see that test for why
    /// a check for something absent cannot be pointed at a filter like this
    /// one.
    private static func duplicateLines() throws -> [String] {
        try sourceLines().filter { $0.contains("uplicate") }
    }

    // MARK: - Positive: the entry is there, and it asks rather than decides

    @Test func theRowOffersTheEntryAndForwardsIt() throws {
        let lines = try Self.duplicateLines()
        #expect(lines.contains { $0.contains("L10n.string(\"sidebar.duplicate\"") }, """
            `SessionSidebar.swift` no longer draws a "Duplicate" entry from the \
            `sidebar.duplicate` catalogue key — re-anchor this guard, or the entry the \
            design puts beside Rename and Delete is gone.
            """)
        #expect(lines.contains { $0.contains("onDuplicate()") }, """
            the "Duplicate" entry no longer forwards through the row's `onDuplicate` \
            callback — a row that acts on the store directly is one no test reaches.
            """)
    }

    @Test func theSidebarAsksCoreForTheCopyAndSelectsWhatComesBack() throws {
        let lines = try Self.duplicateLines()
        #expect(lines.contains { $0.contains("viewModel.duplicateSession(") }, """
            `SessionSidebar.swift` no longer asks `SessionListViewModel.duplicateSession(_:)` \
            for the copy — what a copy carries, and which Keychain slots it must NOT reach, \
            is a decision in Core, not in a menu action.
            """)
        #expect(lines.contains { $0.contains("onDuplicate: { duplicate(session) }") }, """
            the session row's `onDuplicate` is no longer wired to this file's `duplicate(_:)` \
            handler.
            """)
        // The one thing the handler adds to the Core call, and the reason
        // the entry is worth having: the copy is shown, not merely written.
        // `moveSelection(to:)` is the sidebar's single spelling of "point at
        // this row" — a raw `selectedSessionID = ` here would leave the
        // keyboard on the old row, which is the drift that method exists to
        // prevent.
        let handler = try Self.sourceLines()
        #expect(handler.contains { $0.contains("moveSelection(to: copy)") }, """
            duplicating no longer moves the sidebar's selection onto the copy — the design \
            asks for the copy to be visible as what was just created.
            """)
    }

    /// The catalogue actually answers the key the entry reads. Asked through
    /// `L10n` rather than by parsing a `.lproj` file, so this checks the
    /// lookup the running app performs; that the other three catalogues
    /// declare the same key is `LocalizationParityTests`' standing job, not
    /// a second list here.
    @Test func theEntrysKeyResolvesInTheCatalogue() {
        #expect(L10n.string("sidebar.duplicate", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ")
    }

    // MARK: - Negative: nothing about it is ever greyed out

    /// This project shows only what is possible, and duplicating a stored
    /// session is always possible — there is no state in which the entry has
    /// a reason to be drawn dead.
    ///
    /// Scanned over the entry's whole STATEMENT — its `Button` line plus the
    /// modifier lines chained onto it — rather than over lines that mention
    /// duplicating. The first spelling of this check did the latter, and a
    /// planted `.disabled(session.kind != .ssh)` sailed straight through it:
    /// a SwiftUI modifier sits on its own line and names the entry nowhere,
    /// so the filter simply never looked at it. A scan for something ABSENT
    /// has to be told where absent means, or it reports success over the one
    /// place the violation goes.
    ///
    /// The `#require` is the positive check beside it: on a file whose
    /// "Duplicate" entry has moved or gone, this fails at the lookup instead
    /// of passing over an empty scan.
    @Test func theEntryIsNeverDisabled() throws {
        let lines = try Self.sourceLines()
        let entry = try #require(
            lines.firstIndex { $0.contains("L10n.string(\"sidebar.duplicate\"") },
            "no \"Duplicate\" entry to scan — re-anchor this guard")
        var statement = [lines[entry]]
        var next = entry + 1
        while next < lines.count,
              lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            statement.append(lines[next])
            next += 1
        }
        let gated = statement.filter { $0.contains(".disabled(") }
        #expect(gated.isEmpty, """
            the "Duplicate" entry is gated: \(gated). This project hides what cannot act \
            instead of greying it out — and duplicating a stored connection can always act.
            """)
    }
}
