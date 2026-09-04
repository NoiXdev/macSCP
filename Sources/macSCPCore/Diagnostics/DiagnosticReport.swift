import Foundation

/// The whole diagnosis, in the order it was measured, plus what it was
/// pointed at and which build measured it.
///
/// Both renderings are English and unlocalized, on purpose. This is what the
/// user pastes into a bug report — the same audience the command-line tool
/// writes for — and a row that arrives translated is a row the person reading
/// the report cannot search for. The PANEL is localized: it renders each
/// step's `titleKey` through the App's catalogs, which is why the renderings
/// below print the step's stable `id` and never resolve a key.
public struct DiagnosticReport: Sendable, Equatable {
    /// What the diagnosis was pointed at, or `nil` when it never got that
    /// far.
    ///
    /// Optional because there is exactly one report with nothing to name: the
    /// walk that stops at the first row because the session's form carries no
    /// host (`ConnectionDiagnostics.run`'s `noHost` guard). That case used to
    /// be carried as `Endpoint(host: "", port: 0)`, which `Endpoint.text`
    /// renders as `:0` — a value nobody measured, in the one artifact whose
    /// whole job is to be quoted into a bug report. The panel hid it because
    /// it reads its own endpoint and not the report's; the pasteboard did
    /// not.
    ///
    /// `nil` rather than a "no endpoint" sentence, so the renderers below
    /// omit the header LINE: an absent line cannot be misread as a
    /// measurement, and the one row the report does carry already says why
    /// the walk stopped.
    public let endpoint: Endpoint?
    public let steps: [DiagnosticStep]
    /// The build that measured this. Passed in by the App
    /// (`CFBundleShortVersionString`); Core never reads the bundle itself —
    /// see `GitHubReleaseFetcher`'s note for the same rule.
    public let appVersion: String

    /// Whether the walk that produced this finished, and how it ended when it
    /// did not.
    ///
    /// A report is pasted into an issue, and a PARTIAL one — copied while the
    /// diagnosis is still running, or after it was cancelled — has rows that
    /// were never measured rather than rows that were measured and found
    /// absent. Those two read identically once the text leaves the panel, so
    /// the renderers say which this is.
    public enum Completion: Sendable, Equatable {
        /// The walk reached its end. Every row it was going to measure is
        /// here.
        case complete
        /// A snapshot of a walk that is still walking, taken so the rows
        /// already on screen can be copied before the slowest step returns.
        case running
        /// The walk was stopped. `afterSteps` is how many rows it had
        /// finished — carried in the case so the marker can name it without
        /// the renderer having to assume that the list it is printing is the
        /// whole of what was measured.
        case cancelled(afterSteps: Int)
    }

    public let completion: Completion

    /// Which steps the walk was asked for. `.complete` in every report until
    /// a caller says otherwise, and rendered only when it is not.
    public let scope: DiagnosticScope

    /// The yes/no question, for a caller that does not care which of the two
    /// partial cases it is looking at.
    public var isComplete: Bool { completion == .complete }

    /// No redaction pass here, unlike `DiagnosticStep.init`, and that is a
    /// decision rather than an omission: besides the steps, this prints
    /// `endpoint.text`, `appVersion`, and — for a scoped walk — the scope's
    /// `rawValue`, which is one of a closed set of spellings this module
    /// wrote and can carry nothing a user typed. An endpoint's host
    /// comes either from `URL.host()` (which never carries userinfo) or from
    /// SSH's own host field, where an `alice@server.lan` a user typed is a
    /// user name and not a credential — and carries no `://` for
    /// `withoutUserinfo` to act on anyway.
    public init(
        endpoint: Endpoint?, steps: [DiagnosticStep], appVersion: String,
        completion: Completion = .complete, scope: DiagnosticScope = .complete
    ) {
        self.endpoint = endpoint
        self.steps = steps
        self.appVersion = appVersion
        self.completion = completion
        self.scope = scope
    }

    private static let title = "macSCP connection diagnostics"

    /// The one line that marks an unfinished walk, and says which of the two
    /// ways it is unfinished. English, like the rest of this rendering: the
    /// report's audience is whoever reads the issue, not whoever pasted it
    /// (see this type's own doc comment).
    ///
    /// `nil` for a finished walk, which needs no marker at all: the rows are
    /// the whole measurement, and a line saying so would be noise in every
    /// report anyone ever pastes.
    ///
    /// Internal rather than private since `macscp-cli diagnose` prints its
    /// rows as they land and has no `plainText()` to put a header on:
    /// `DiagnoseRendering.completionRow(for:)` prints THIS line after the
    /// last row, so the terminal and the pasted report mark an unfinished
    /// walk with the same words rather than with two spellings of it.
    static func marker(for completion: Completion) -> String? {
        switch completion {
        case .complete:
            return nil
        case .running:
            return "(run in progress)"
        case .cancelled(let afterSteps):
            let rows = afterSteps == 1 ? "1 step" : "\(afterSteps) steps"
            return "(cancelled after \(rows))"
        }
    }

    /// What a scoped report calls itself in the header, or `nil` for the
    /// complete walk.
    ///
    /// Absent rather than "Scope: complete", for the reason `marker(for:)` is
    /// absent on a finished walk: a line that is in every report anyone ever
    /// pastes says nothing about the one they are reading, and the reports
    /// that came before this parameter existed have to keep rendering
    /// identically or every pinned rendering becomes a question.
    ///
    /// The scope's own `rawValue`, never a second spelling of it: the App
    /// builds its catalogue keys from the same string, and a renamed case
    /// would otherwise leave this line naming a scope that no longer exists.
    private static func scopeName(for scope: DiagnosticScope) -> String? {
        scope == .complete ? nil : scope.rawValue
    }

    public func plainText() -> String {
        var lines = [Self.title]
        if let endpoint { lines.append("Endpoint: \(endpoint.text)") }
        if let name = Self.scopeName(for: scope) { lines.append("Scope: \(name)") }
        lines.append("App version: \(appVersion)")
        if let marker = Self.marker(for: completion) { lines.append(marker) }
        lines.append("")
        for step in steps {
            var line = "\(step.id) — \(step.outcome.label) — \(Self.duration(step.duration))"
            if !step.detail.isEmpty { line += " — \(step.detail)" }
            lines.append(line)
            if let table = step.table { lines.append(contentsOf: Self.aligned(table)) }
        }
        return lines.joined(separator: "\n")
    }

    /// A table as indented, aligned columns, directly under its own step's
    /// line — so a reader can tell whose measurement it is without counting
    /// rows, and so the columns line up in the monospaced places this text
    /// gets pasted into.
    ///
    /// Padded to the widest cell in each column, the last one not at all:
    /// trailing spaces on every row would be invisible here and visible in
    /// whatever the text is pasted into.
    private static func aligned(_ table: DiagnosticTable) -> [String] {
        let rows = [table.columns.map(Self.header)] + table.rows
        let widths = (0..<table.columns.count).map { column in
            rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            let cells = row.enumerated().map { index, cell -> String in
                // The last cell of the row is never padded, and neither is
                // one in a row longer than the header — a ragged row is a
                // producer's bug, and reading past `widths` would be this
                // renderer's.
                guard index < row.count - 1, index < widths.count else { return cell }
                // Counted in Characters, and padded by hand for that reason:
                // `padding(toLength:)` counts UTF-16 units, so one cell with
                // an astral scalar in it would misalign the whole column.
                return cell + String(repeating: " ", count: max(0, widths[index] - cell.count))
            }
            return Self.tableIndent + cells.joined(separator: "  ")
        }
    }

    /// What a table's rows are set in from the step's own line.
    private static let tableIndent = "    "

    /// The English word a column key prints as: the key's last component.
    ///
    /// Derived rather than spelled a second time. A `DiagnosticTable` carries
    /// catalogue keys because the panel resolves them
    /// (`DiagnosticTable`'s own doc comment), this rendering is English by
    /// design, and a renamed key must not leave the report naming a column
    /// the panel no longer has. The lowercase that falls out of the key is
    /// the register the rest of this rendering is already in — `step.id` and
    /// `DiagnosticOutcome.label` are both printed as they are spelled.
    ///
    /// Internal, not private: `DiagnoseRendering` derives the same column
    /// names for the CLI's JSON `hops` field and reuses this rather than
    /// spelling the same `.split(separator: ".").last` a second time.
    static func header(_ key: String) -> String {
        String(key.split(separator: ".").last ?? Substring(key))
    }

    public func markdown() -> String {
        var lines = ["# \(Self.title)", ""]
        if let endpoint { lines.append("- **Endpoint:** `\(endpoint.text)`") }
        if let name = Self.scopeName(for: scope) { lines.append("- **Scope:** \(name)") }
        lines.append("- **App version:** \(appVersion)")
        if let marker = Self.marker(for: completion) { lines.append("- **\(marker)**") }
        lines.append(contentsOf: [
            "",
            "| Step | Outcome | Duration | Detail |",
            "| --- | --- | --- | --- |",
        ])
        for step in steps {
            lines.append(
                "| `\(step.id)` | \(Self.cell(step.outcome.label)) "
                    + "| \(Self.duration(step.duration)) | \(Self.cell(step.detail)) |")
        }
        // Each table gets a section of its own BELOW the steps, headed by the
        // step that measured it: Markdown has no nested table, and a grid
        // spliced into the middle of the steps table would end it there.
        for step in steps {
            guard let table = step.table else { continue }
            lines.append(contentsOf: ["", "## `\(step.id)`", ""])
            lines.append(Self.row(table.columns.map(Self.header)))
            lines.append(Self.row(table.columns.map { _ in "---" }))
            lines.append(contentsOf: table.rows.map(Self.row))
        }
        return lines.joined(separator: "\n")
    }

    /// One Markdown row, every cell escaped the way a detail cell is.
    private static func row(_ cells: [String]) -> String {
        "| " + cells.map(Self.cell).joined(separator: " | ") + " |"
    }

    private static func duration(_ duration: Duration) -> String {
        DurationText.milliseconds(duration)
    }

    /// A detail line is free text (an error reason, a server's header), and a
    /// `|` or a newline in it would split the row it sits in.
    ///
    /// Decided one `Unicode.Scalar` at a time, not with
    /// `replacingOccurrences`: that matches on grapheme clusters and on
    /// canonical equivalence, so a bar carrying a combining mark is one
    /// cluster that the search misses while Markdown still reads the bar.
    /// Same reasoning, and the same shape, as `ShellScalar` on the snippet
    /// path — `noCoreFileEscapesAMetacharacterWithReplacingOccurrences` holds
    /// every file in Core to it.
    private static func cell(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "|":
                escaped.append("\\")
                escaped.append(scalar)
            case "\n", "\r":
                escaped.append(" ")
            default:
                escaped.append(scalar)
            }
        }
        return String(escaped)
    }
}
