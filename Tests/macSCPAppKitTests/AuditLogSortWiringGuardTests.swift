import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Guards that the audit-log sheet actually ASKS `AuditLogSorting`, and
/// asks it about the rows and the text the user is looking at.
///
/// `AuditLogSortingTests` proves what each column's rule is. Nothing in it
/// would notice the sheet handing `Table` its unsorted events, two columns
/// being given the same comparator key by copy-paste, or the Detail cell
/// drawing one text while the Detail column sorts another — all of which
/// leave the rules correct and dead or, worse, correct and lying.
///
/// It is a source-text scan, like this project's other wiring guards:
/// `AuditLogSheet` cannot be driven from a test here, so nothing below says
/// that clicking a header sorts anything — only that the sheet is wired to
/// the rules rather than around them. The scans fail closed: a reformat
/// that splits a scanned construct across lines reads as a MISSING wire
/// rather than a compliant one.
///
/// Where the property could be violated from, which is what picked these
/// anchors — derived by walking the path from "the store hands over events"
/// to "the table draws a row":
///
/// - The sorted events are computed and then not used — `Table(filteredEvents…)`
///   beside an unread `sortedEvents`. → **Guard A**.
/// - `Table` sorts but never publishes the user's clicks back, so a header
///   click does nothing. → **Guard B**.
/// - A second column is given a key another column already has, leaving the
///   first column unsortable. → **Guard C**.
/// - A column is added later with no comparator at all. → **Guard D**.
/// - Two columns trade comparators, so the Time header sorts by detail.
///   Guards C and D both stay green through that. → **Guard E**.
/// - The sort is moved back in front of the filter and the search, so what
///   is ordered is not what is shown. → **Guard F**.
/// - The export keeps its own order and no longer writes out what the user
///   sees. → **Guard G**.
/// - A cell is changed to draw text the sort does not key on (or the other
///   way round), so a column orders rows by something invisible.
///   → **Guard H**.
/// - The footer keeps reading its total off the property that used to mean
///   "the whole log" and now means "the rows on screen". → **Guard I**.
@Suite("Audit-log sort wiring guard")
struct AuditLogSortWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/AuditLogSortWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sheetFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/AuditLogSheet.swift")

    private static func sheetSource() throws -> String {
        try String(contentsOf: sheetFile, encoding: .utf8)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The first argument of `call` on the line that contains it, e.g.
    /// `Table(` → `sortedEvents`. `nil` when the call is not on one line,
    /// which is the fail-closed direction: an unfollowable wire reads as a
    /// missing one.
    private static func firstArgument(of call: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let line = lines.first(where: { $0.contains(call) }) else { return nil }
        let argument = line.components(separatedBy: call)[1]
            .components(separatedBy: CharacterSet(charactersIn: ",)"))[0]
            .trimmingCharacters(in: .whitespaces)
        return argument.isEmpty ? nil : argument
    }

    /// The body of the COMPUTED property called `name`: from its
    /// declaration to the first line that is the property's own closing
    /// brace at the type's member indentation.
    ///
    /// Computed only — the declaration has to open a brace on its own line.
    /// A stored property has no body, and matching one anyway would return
    /// everything down to the next member's closing brace, i.e. some
    /// unrelated member's text under this member's name. That is how a
    /// guard reports a wire it never followed.
    private static func propertyBody(_ name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard
            let index = lines.firstIndex(where: {
                $0.contains("var \(name):") && $0.hasSuffix("{")
            })
        else { return nil }
        return lines[index...].prefix { !$0.hasPrefix("    }") }.joined(separator: "\n")
    }

    /// The body of the function called `name`, delimited the same way.
    private static func functionBody(_ name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }
        return lines[index...].prefix { !$0.hasPrefix("    }") }.joined(separator: "\n")
    }

    /// The `Table` call's own text: from the call to the brace that closes
    /// its column list, located by counting braces rather than by
    /// indentation.
    private static func tableBlock(in source: String) -> String? {
        guard let call = source.range(of: "Table(") else { return nil }
        var depth = 0
        var opened = false
        var index = call.upperBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
                opened = true
            } else if character == "}" {
                depth -= 1
                if opened && depth == 0 { return String(source[call.upperBound...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// One text block per table column: each `TableColumn(` opens a segment
    /// that runs to the next one, so a column's title, its comparator and
    /// its cell all sit inside its own segment.
    ///
    /// Cut out of the table block first, and that bound is the whole point.
    /// Split on `TableColumn(` over the raw file and the LAST column's
    /// segment runs to the end of it — so it sees every later mention of
    /// the text that column is supposed to draw, and a cell that stopped
    /// drawing it still reads as wired. Measured, not imagined: with the
    /// unbounded split, a Detail cell rewritten to draw the stored `detail`
    /// left every test in this file green, because `searchString` further
    /// down the file still named `AuditEventText.detail`.
    private static func columnSegments(in source: String) -> [String] {
        guard let block = tableBlock(in: source) else { return [] }
        return Array(block.components(separatedBy: "TableColumn(").dropFirst())
    }

    /// **Guard A** — the events `Table` is given come out of
    /// `AuditLogSorting.sorted`.
    ///
    /// Written as "follow the argument", not as a match on one spelling of
    /// the call: the argument `Table` receives is read off the source, its
    /// declaration is located by that name, and the sort call has to be
    /// inside that declaration's body. Renaming the property keeps the
    /// guard working; unhooking it does not.
    @Test func theTableIsFedTheSortedEvents() throws {
        let source = try Self.sheetSource()
        #expect(Self.occurrences(of: "Table(", in: source) == 1, """
            This guard follows a single table's first argument, and \
            AuditLogSheet.swift no longer contains exactly one `Table(`.
            """)
        guard let argument = Self.firstArgument(of: "Table(", in: source) else {
            Issue.record("Could not read the table's first argument.")
            return
        }
        guard let body = Self.propertyBody(argument, in: source) else {
            Issue.record("No declaration of `\(argument)` — the table's rows come from nowhere this guard can follow.")
            return
        }
        #expect(body.contains("AuditLogSorting.sorted("), """
            `\(argument)` is what the table draws, and its body never calls \
            `AuditLogSorting.sorted` — every column rule below it is dead.
            """)
    }

    /// **Guard B** — the table publishes header clicks back into the
    /// sheet's own state. Without the binding the columns still declare
    /// comparators and nothing ever changes.
    @Test func theTablePublishesTheUsersSortOrderBack() throws {
        let source = try Self.sheetSource()
        #expect(source.contains("sortOrder: $sortOrder"))
        #expect(source.contains("@State private var sortOrder: [AuditEventComparator]"))
    }

    /// **Guard C** — every sort key is spelled onto exactly one column.
    /// Driven off `allCases`, so the classic copy-paste (two columns, one
    /// key, one column silently unsortable) fails here, and so does a key
    /// the sheet forgot.
    @Test func everyKeyIsUsedByExactlyOneColumn() throws {
        let source = try Self.sheetSource()
        for key in AuditSortKey.allCases {
            let spelling = "AuditEventComparator(key: .\(key.rawValue))"
            #expect(Self.occurrences(of: spelling, in: source) == 1, """
                `\(spelling)` appears \(Self.occurrences(of: spelling, in: source)) times in \
                AuditLogSheet.swift — every key belongs to exactly one column.
                """)
        }
    }

    /// **Guard D** — as many columns as there are keys, and a comparator on
    /// each. A column added without one would leave a header the user can
    /// click to no effect; here it is a failing test instead.
    ///
    /// The count comes from `allCases`, not from a number written into this
    /// file: a column and its key are added together or not at all.
    @Test func everyColumnCarriesAComparator() throws {
        let source = try Self.sheetSource()
        let columns = Self.occurrences(of: "TableColumn(", in: source)
        let comparators = Self.occurrences(of: "sortUsing: AuditEventComparator(", in: source)
        #expect(columns == AuditSortKey.allCases.count)
        #expect(comparators == columns, """
            \(columns) columns but \(comparators) comparators — a column without one is a \
            header that sorts nothing.
            """)
    }

    /// **Guard E** — each column carries the comparator for ITS OWN field.
    ///
    /// Guards C and D count keys and columns, and two columns that simply
    /// TRADE comparators keep both counts right: every key is used once,
    /// every column has one, and the Time header sorts by detail. This is
    /// the guard for that swap.
    ///
    /// The pairing is readable from the source because a column's title key
    /// and its sort key are spelled alike — `audit.column.detail` and
    /// `.detail`. That shared spelling is this guard's assumption, so it
    /// fails closed on a renamed title key: rename one and rename the
    /// `AuditSortKey` case with it, or teach this test the new pairing.
    @Test func eachColumnCarriesItsOwnFieldsComparator() throws {
        let source = try Self.sheetSource()

        var comparatorOfColumn: [String: String] = [:]
        for segment in Self.columnSegments(in: source) {
            let titles = AuditSortKey.allCases.filter {
                segment.contains("\"audit.column.\($0.rawValue)\"")
            }
            let comparators = AuditSortKey.allCases.filter {
                segment.contains("AuditEventComparator(key: .\($0.rawValue))")
            }
            #expect(titles.count == 1, """
                A table column names \(titles.count) of the known column titles — this guard \
                pairs a column with its comparator by that title.
                """)
            #expect(comparators.count == 1, """
                A table column names \(comparators.count) comparators — exactly one belongs \
                on each column.
                """)
            guard let title = titles.first, let comparator = comparators.first else { continue }
            comparatorOfColumn[title.rawValue] = comparator.rawValue
        }

        for key in AuditSortKey.allCases {
            #expect(comparatorOfColumn[key.rawValue] == key.rawValue, """
                The `audit.column.\(key.rawValue)` column sorts using \
                `\(comparatorOfColumn[key.rawValue] ?? "no")` — a column sorts by its own field.
                """)
        }
    }

    /// **Guard F** — the sort is applied to the FILTER RESULT, so what is
    /// ordered is exactly what is on screen.
    ///
    /// Followed rather than matched: the property `Table` draws is located,
    /// the first argument it hands `AuditLogSorting.sorted` is read off,
    /// and THAT property's body has to be the one applying the segment
    /// filter and the search predicate. Moving the sort back in front of
    /// the filter breaks the chain here.
    @Test func theSortIsAppliedToTheFilterResult() throws {
        let source = try Self.sheetSource()
        guard let drawn = Self.firstArgument(of: "Table(", in: source),
            let drawnBody = Self.propertyBody(drawn, in: source),
            let sorted = Self.firstArgument(of: "AuditLogSorting.sorted(", in: drawnBody)
        else {
            Issue.record("Could not follow the table's rows into `AuditLogSorting.sorted`.")
            return
        }
        guard let filteredBody = Self.propertyBody(sorted, in: source) else {
            Issue.record("`\(sorted)` is what gets sorted, and this file declares no such property.")
            return
        }
        #expect(filteredBody.contains("matchesFilter("), """
            `\(sorted)` is what gets sorted and it does not apply the segment filter — the \
            table would be ordering rows it is not showing.
            """)
        #expect(filteredBody.contains("predicate.matches("), """
            `\(sorted)` is what gets sorted and it does not apply the search predicate.
            """)
    }

    /// **Guard G** — the text export writes out the order on screen.
    ///
    /// The export's own doc comment promises "exactly what's currently on
    /// screen". Once the user can reorder the table, that promise includes
    /// the ORDER, and an export left keyed on the unsorted filter result
    /// would quietly break it while every column rule stayed correct.
    @Test func theExportFollowsTheOrderOnScreen() throws {
        let source = try Self.sheetSource()
        guard let drawn = Self.firstArgument(of: "Table(", in: source),
            let exportBody = Self.functionBody("performExport", in: source)
        else {
            Issue.record("Could not locate the table's rows or `performExport`.")
            return
        }
        #expect(exportBody.contains("\(drawn).map("), """
            `performExport` does not map over `\(drawn)`, the rows the table draws — the export \
            no longer writes out what the user is looking at.
            """)
    }

    /// **Guard H** — the cells draw the same text the sort keys on.
    ///
    /// The Event column compares a localized label and the Detail column
    /// compares the drawn detail with its error suffix. Both live in
    /// `AuditEventText` so there is one spelling of each; a cell that
    /// formatted its own would let the column order rows by something the
    /// user cannot see, with every rule test still green.
    ///
    /// Checked per column segment, not once per file, so it is the CELL
    /// that has to use the shared text and not some unrelated call site —
    /// and once more for `searchString`, the third reader of the same text:
    /// a search that matched a detail the cell is not drawing would find
    /// rows the user cannot see the match in.
    @Test func theCellsDrawTheTextTheSortKeysOn() throws {
        let source = try Self.sheetSource()
        let spellings = [
            "kind": "AuditEventText.kindLabel(",
            "detail": "AuditEventText.detail(",
        ]
        let segments = Self.columnSegments(in: source)
        #expect(segments.count == AuditSortKey.allCases.count, """
            \(segments.count) column segments were found inside the table — with none of them \
            this guard checks no cell at all.
            """)
        for segment in segments {
            for (column, spelling) in spellings where segment.contains("\"audit.column.\(column)\"") {
                #expect(segment.contains(spelling), """
                    The `audit.column.\(column)` cell does not draw `\(spelling)` — the column \
                    would sort on text the cell is not showing.
                    """)
            }
        }
        guard let searchBody = Self.functionBody("searchString", in: source) else {
            Issue.record("No `searchString` to check — the search no longer mirrors the row.")
            return
        }
        for spelling in spellings.values {
            #expect(searchBody.contains(spelling), """
                `searchString` does not use `\(spelling)` — the search would match text the row \
                is not drawing.
                """)
        }

        // And the sheet keeps no second spelling of either text: the kind
        // label's catalogue key and the error suffix belong to
        // `AuditEventText` alone.
        #expect(!source.contains("L10n.string(\"audit.kind."))
        #expect(!source.contains("func kindLabel("))
        #expect(!source.contains("func detailText("))
    }

    /// **Guard I** — the footer's total still counts the whole log.
    ///
    /// A consequence of Guard F's decision rather than of the sorting
    /// itself: `sortedEvents` used to mean "the whole log, newest first"
    /// and now means "the rows on screen". The footer read its total off
    /// that name, so leaving it alone would have made the caption say
    /// "N of N" forever, with every sort rule correct and every other test
    /// green.
    @Test func theFooterTotalCountsTheWholeLog() throws {
        let source = try Self.sheetSource()
        guard let drawn = Self.firstArgument(of: "Table(", in: source),
            let footerBody = Self.propertyBody("footerText", in: source)
        else {
            Issue.record("Could not locate the table's rows or `footerText`.")
            return
        }
        #expect(footerBody.contains("events.count"))
        #expect(!footerBody.contains("\(drawn).count"), """
            The footer's total counts `\(drawn)`, the rows on screen — the caption would read \
            "N of N" whatever the user filtered.
            """)
    }
}
