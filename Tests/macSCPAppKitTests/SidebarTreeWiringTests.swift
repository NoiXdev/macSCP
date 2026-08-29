import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards the one rule the nested sidebar was built around: **the view
/// computes no row number.** Every gesture ends in a `SessionListViewModel`
/// call taking identities — `children(of:)`, `move(_:before:)`,
/// `move(_:intoGroup:)`, `sortChildrenByName(of:)` — and the sidebar derives
/// no place for anything.
///
/// This is not a matter of taste. `SidebarOrdering`'s own doc comment records
/// why the tab strip stopped carrying an index through its view: a number can
/// be shifted by a step, shadowed by a name, or clamped in an initializer,
/// and each of those moves a row while the surrounding code reads exactly as
/// it did. `SidebarOrderingTests` proves what the ordering functions decide
/// and never touches `SessionSidebar.swift`; a view that recomputed a
/// destination beside them would leave every one of those tests green.
///
/// `SessionSidebar` cannot be instantiated in this project (no view-render
/// harness — the boundary `SidebarFilterWiringTests`,
/// `PaneRenderConditionGuardTests` and the other guards already document), so
/// this is a SOURCE-TEXT scan over
/// `Sources/MacSCPAppKit/SessionSidebar.swift`.
///
/// **The negative check does not stand alone.** A scan for "no positional
/// token appears" is exactly the shape this project has watched go silent: it
/// starts matching nothing and reads like a check that is satisfied. So the
/// positive guards below run over the same file and fail loudly the moment
/// the calls they name move or are renamed — without them, `nothingInTheSidebarComputesARowNumber`
/// would happily pass over a file that no longer drew a sidebar at all.
///
/// Known blind spots, stated rather than discovered later:
/// - Line-based and literal. A destination computed through a helper whose
///   name contains none of the scanned tokens, or arithmetic split so no
///   single line carries a token, slips past. Aimed at the accidental
///   regression — someone "simplifying" a `ForEach` back to an enumerated
///   one — not at a hostile rewrite.
/// - Neither scan sees a violation moved into a DIFFERENT file. The positive
///   guards are what make that visible instead: a gesture rerouted elsewhere
///   stops being one of the calls named here.
@Suite("Sidebar tree wiring guard")
struct SidebarTreeWiringTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SidebarTreeWiringTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static func sourceLines() throws -> [String] {
        try String(contentsOf: Self.sourceFile, encoding: .utf8).components(separatedBy: "\n")
    }

    // MARK: - Positive: the tree is asked for, never derived

    @Test func theSidebarDrawsEachParentsChildrenAsTheDecisionHandsThemOver() throws {
        let lines = try Self.sourceLines()
        let asksForChildren = lines.contains {
            $0.contains("visibility.children(of: parentID)")
        }
        #expect(asksForChildren, """
            `SessionSidebar.swift` no longer draws `visibility.children(of: parentID)` — the \
            row order is `SidebarOrdering`'s answer, and a sidebar that assembles its own \
            list of rows is deriving one.
            """)
    }

    /// Every gesture the design names, and the call each one ends in. A
    /// gesture rewired to compute its own destination stops matching here
    /// before the negative scan below has anything to see.
    @Test func everyGestureEndsInAnOrderingCallTakingIdentities() throws {
        let lines = try Self.sourceLines()
        let expected = [
            "viewModel.move(item, before: target)",
            "viewModel.move(item, intoGroup: parentID)",
            "viewModel.sortChildrenByName(of: group.id)",
        ]
        for call in expected {
            #expect(lines.contains { $0.contains(call) }, """
                expected `SessionSidebar.swift` to contain `\(call)` — re-anchor this guard, \
                or the gesture it names now reaches the store some other way.
                """)
        }
    }

    /// The drag names its own row, and the highlight is a decision this file
    /// does not make itself — both are what keep the two drop gestures from
    /// being told apart by a coordinate.
    @Test func theDragNamesItsRowAndTheHighlightIsAskedFor() throws {
        let lines = try Self.sourceLines()
        #expect(lines.contains { $0.contains("SidebarDragPayload.text(for:") }, """
            `SessionSidebar.swift` no longer builds its drag payload through \
            `SidebarDragPayload` — a payload spelled by hand can name a row the drop cannot \
            read back.
            """)
        #expect(lines.contains { $0.contains("SidebarDragPayload.item(from:") }, """
            `SessionSidebar.swift` no longer reads its drop payload through \
            `SidebarDragPayload`.
            """)
        #expect(lines.contains { $0.contains("SidebarDropTargetPlan.build(") }, """
            `SessionSidebar.swift` no longer asks `SidebarDropTargetPlan` which row is \
            highlighted — a highlight decided in a view body is one no test reaches.
            """)
        #expect(lines.contains { $0.contains("SidebarSortMenuPlan.build(") }, """
            `SessionSidebar.swift` no longer asks `SidebarSortMenuPlan` whether the sort \
            entry is offered — this project hides what cannot act, and hides it from a \
            tested decision rather than an `if` in a menu body.
            """)
    }

    // MARK: - Negative: nothing here derives a place

    @Test func nothingInTheSidebarComputesARowNumber() throws {
        let lines = try Self.sourceLines()
        let violations = Self.positionalViolations(in: lines)
        #expect(violations.isEmpty, """
            `SessionSidebar.swift` derives a row number at line(s) \
            \(violations.map { "\($0.line + 1): \($0.marker)" }) — the sidebar must express \
            every drop as two identities and let `SidebarOrdering` derive the place. See \
            this suite's doc comment for why an index carried through a view was the defect \
            class this design removed.
            """)
    }

    // MARK: - Scanner reacts (self-tests over synthetic sources)

    @Test func scannerFlagsAnEnumeratedForEach() {
        let source = """
            ForEach(Array(visibility.children(of: parentID).enumerated()), id: \\.offset) { index, item in
                row(item)
            }
            """
        #expect(!Self.positionalViolations(in: source.components(separatedBy: "\n")).isEmpty)
    }

    @Test func scannerFlagsALookupThatYieldsAPlace() {
        let source = """
            let slot = siblings.firstIndex(of: target) ?? 0
            viewModel.move(item, to: slot)
            """
        #expect(!Self.positionalViolations(in: source.components(separatedBy: "\n")).isEmpty)
    }

    @Test func scannerFlagsAnInsertionAtAComputedSlot() {
        let source = """
            var order = siblings
            order.insert(item, at: slot)
            """
        #expect(!Self.positionalViolations(in: source.components(separatedBy: "\n")).isEmpty)
    }

    @Test func scannerFlagsARawSubscript() {
        let source = "let target = siblings[0]"
        #expect(!Self.positionalViolations(in: [source]).isEmpty)
    }

    /// The scanner's honesty check: the real shape — two identities handed
    /// to a core call — must not be flagged, or the guard would be
    /// unsatisfiable and would be weakened rather than obeyed.
    @Test func scannerAcceptsAGestureExpressedAsTwoIdentities() {
        let source = """
            private func drop(_ payload: [String], before target: SidebarItem) -> Bool {
                guard let item = SidebarDragPayload.item(from: payload) else { return false }
                return viewModel.move(item, before: target) == nil
            }
            """
        #expect(Self.positionalViolations(in: source.components(separatedBy: "\n")).isEmpty)
    }

    // MARK: - The catalogue

    /// The one string this task adds — a missing key renders as its own
    /// English default rather than failing a build, so it is checked here
    /// the same way `SidebarFilterWiringTests` checks the filter's keys.
    @Test func theSortEntryKeyResolvesFromTheCatalog() {
        #expect(
            L10n.string("sidebar.group.sortByName", "ZZ-UNRESOLVED-ZZ") != "ZZ-UNRESOLVED-ZZ",
            "key `sidebar.group.sortByName` did not resolve")
    }

    // MARK: - Scanner

    struct PositionalViolation: Equatable {
        let line: Int
        let marker: String
    }

    /// Every line carrying a token that can only exist to name a PLACE in a
    /// list. Comments are not stripped — the same deliberate choice
    /// `PaneVisibilityOwnershipGuardTests` makes for its own scanner: the
    /// wrong shape should not be modelled anywhere in the file, prose
    /// included.
    private static func positionalViolations(in lines: [String]) -> [PositionalViolation] {
        let markers = [
            "enumerated(", ".indices", "firstIndex(", "lastIndex(", ".offset",
            "insert(at:", ", at:", "remove(at:", ".startIndex", ".endIndex",
        ]
        var found: [PositionalViolation] = []
        for number in 0..<lines.count {
            let line = lines[number]
            for marker in markers where line.contains(marker) {
                found.append(PositionalViolation(line: number, marker: marker))
            }
            if Self.carriesARawSubscript(line) {
                found.append(PositionalViolation(line: number, marker: "[<number>]"))
            }
        }
        return found
    }

    /// A subscript written with a literal number — `siblings[0]` — which is
    /// a place named directly. Matched character-wise rather than with a
    /// regular expression so the rule is readable at the point it is applied.
    private static func carriesARawSubscript(_ line: String) -> Bool {
        var previous: Character?
        for character in line {
            if previous == "[", character.isNumber { return true }
            previous = character
        }
        return false
    }
}
