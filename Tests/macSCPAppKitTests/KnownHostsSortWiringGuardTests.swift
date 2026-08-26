import Foundation
import Testing

@testable import MacSCPAppKit

/// Guards that the known-hosts sheet actually ASKS `KnownHostsSorting`.
///
/// `KnownHostsSortingTests` proves what each column's rule is. Nothing in
/// it would notice the sheet handing `Table` its unsorted rows, or two
/// columns being given the same comparator key by copy-paste — both leave
/// the rules correct and dead. That is what this suite is for, and it is
/// the whole of what it claims.
///
/// It is a source-text scan, like this project's other wiring guards:
/// `KnownHostsSheet` cannot be driven from a test here, so nothing below
/// says that clicking a header sorts anything — only that the sheet is
/// wired to the rules rather than around them. The scans fail closed: a
/// reformat that splits a scanned construct across lines reads as a
/// MISSING wire rather than a compliant one.
///
/// Where the property could be violated from, which is what picked these
/// anchors:
///
/// - The sorted rows are computed and then not used — `Table(filteredRows…)`
///   beside an unread `sortedRows`. → **Guard A**, which follows the
///   argument `Table` is actually given back to its declaration.
/// - `Table` sorts but never publishes the user's clicks back, so a header
///   click does nothing. → **Guard B**, the `sortOrder` binding.
/// - A second column is given a key another column already has, leaving
///   the first column unsortable. → **Guard C**, one occurrence per key.
/// - A column is added later with no comparator at all. → **Guard D**,
///   which counts columns against `KnownHostSortKey.allCases` rather than
///   against a number written here.
/// - Two columns trade comparators, so the Host header sorts by port and
///   the Port header by host. Guards C and D both stay green through that:
///   every key is still used once and every column still has one. →
///   **Guard E**, which pairs each column's title with its comparator.
@Suite("Known-hosts sort wiring guard")
struct KnownHostsSortWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/KnownHostsSortWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as the
    /// precedent guard suites).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sheetFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/KnownHostsSheet.swift")

    private static func sheetSource() throws -> String {
        try String(contentsOf: sheetFile, encoding: .utf8)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// **Guard A** — the rows `Table` is given come out of
    /// `KnownHostsSorting.sorted`.
    ///
    /// Written as "follow the argument", not as a match on one spelling of
    /// the call: the argument `Table` receives is read off the source, its
    /// declaration is located by that name, and the sort call has to be
    /// inside that declaration's body. Renaming the property keeps the
    /// guard working; unhooking it does not.
    @Test func theTableIsFedTheSortedRows() throws {
        let source = try Self.sheetSource()
        let lines = source.components(separatedBy: "\n")

        let tableLines = lines.filter { $0.contains("Table(") }
        #expect(tableLines.count == 1, """
            Expected exactly one `Table(` in KnownHostsSheet.swift, found \(tableLines.count) — \
            this guard follows a single table's first argument.
            """)
        guard let tableLine = tableLines.first else { return }

        let afterParen = tableLine.components(separatedBy: "Table(")[1]
        let argument = afterParen.components(separatedBy: ",")[0]
            .trimmingCharacters(in: .whitespaces)
        #expect(!argument.isEmpty)

        guard let declarationIndex = lines.firstIndex(where: { $0.contains("var \(argument):") })
        else {
            Issue.record("No declaration of `\(argument)` — the table's rows come from nowhere this guard can follow.")
            return
        }

        // The declaration's body: from its line to the first line that is
        // the property's own closing brace at the type's member indentation.
        let body = lines[declarationIndex...]
            .prefix { !$0.hasPrefix("    }") }
            .joined(separator: "\n")
        #expect(body.contains("KnownHostsSorting.sorted("), """
            `\(argument)` is what the table draws, and its body never calls \
            `KnownHostsSorting.sorted` — every column rule below it is dead.
            """)
    }

    /// **Guard B** — the table publishes header clicks back into the
    /// sheet's own state. Without the binding the columns still declare
    /// comparators and nothing ever changes.
    @Test func theTablePublishesTheUsersSortOrderBack() throws {
        let source = try Self.sheetSource()
        #expect(source.contains("sortOrder: $sortOrder"))
        #expect(source.contains("@State private var sortOrder: [KnownHostComparator]"))
    }

    /// **Guard C** — every sort key is spelled onto exactly one column.
    /// Driven off `allCases`, so the classic copy-paste (two columns, one
    /// key, one column silently unsortable) fails here, and so does a key
    /// the sheet forgot.
    @Test func everyKeyIsUsedByExactlyOneColumn() throws {
        let source = try Self.sheetSource()
        for key in KnownHostSortKey.allCases {
            let spelling = "KnownHostComparator(key: .\(key.rawValue))"
            #expect(Self.occurrences(of: spelling, in: source) == 1, """
                `\(spelling)` appears \(Self.occurrences(of: spelling, in: source)) times in \
                KnownHostsSheet.swift — every key belongs to exactly one column.
                """)
        }
    }

    /// **Guard D** — as many columns as there are keys, and a comparator on
    /// each. A sixth column added without one would leave a header the user
    /// can click to no effect; here it is a failing test instead.
    ///
    /// The count comes from `allCases`, not from a number written into this
    /// file: a column and its key are added together or not at all.
    @Test func everyColumnCarriesAComparator() throws {
        let source = try Self.sheetSource()
        let columns = Self.occurrences(of: "TableColumn(", in: source)
        let comparators = Self.occurrences(of: "sortUsing: KnownHostComparator(", in: source)
        #expect(columns == KnownHostSortKey.allCases.count)
        #expect(comparators == columns, """
            \(columns) columns but \(comparators) comparators — a column without one is a \
            header that sorts nothing.
            """)
    }

    /// **Guard E** — each column carries the comparator for ITS OWN field.
    ///
    /// Guards C and D count keys and columns, and two columns that simply
    /// TRADE comparators keep both counts right: every key is used once,
    /// every column has one, and the Host header sorts by port. This is the
    /// guard for that swap.
    ///
    /// The pairing is readable from the source because a column's title key
    /// and its sort key are spelled alike — `knownHosts.column.port` and
    /// `.port`. Each `TableColumn(` opens a segment that runs to the next
    /// one, and a column's title and its comparator both sit inside its own
    /// segment.
    ///
    /// That shared spelling is this guard's assumption, so it fails closed
    /// on a renamed title key: rename one and rename the `KnownHostSortKey`
    /// case with it, or teach this test the new pairing.
    @Test func eachColumnCarriesItsOwnFieldsComparator() throws {
        let source = try Self.sheetSource()
        let segments = source.components(separatedBy: "TableColumn(").dropFirst()

        var comparatorOfColumn: [String: String] = [:]
        for segment in segments {
            let titles = KnownHostSortKey.allCases.filter {
                segment.contains("\"knownHosts.column.\($0.rawValue)\"")
            }
            let comparators = KnownHostSortKey.allCases.filter {
                segment.contains("KnownHostComparator(key: .\($0.rawValue))")
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

        for key in KnownHostSortKey.allCases {
            #expect(comparatorOfColumn[key.rawValue] == key.rawValue, """
                The `knownHosts.column.\(key.rawValue)` column sorts using \
                `\(comparatorOfColumn[key.rawValue] ?? "no")` — a column sorts by its own field.
                """)
        }
    }
}
