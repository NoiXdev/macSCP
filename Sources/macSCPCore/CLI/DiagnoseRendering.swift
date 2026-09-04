import Foundation

/// Turns a `DiagnosticStep`/`DiagnosticReport` into what `macscp-cli
/// diagnose` prints: text rows, JSON objects, and an exit code.
///
/// This module renders no reason text of its own — every word in a row
/// (`DiagnosticOutcome`'s cases, `DiagnosticStep.detail`,
/// `DiagnosticTable`'s cells) is Core's own data, carried through, not
/// composed here. That keeps the CLI's story identical to the panel's and
/// the pasted report's: three renderers of the same measurement, never a
/// fourth thing that happened to be measured differently.
public enum DiagnoseRendering {
    /// The word `textRows` and `jsonObject` print for an outcome that has no
    /// reason text of its own — `ok` and `timedOut`.
    private static func word(_ outcome: DiagnosticOutcome) -> String {
        switch outcome {
        case .ok: return "ok"
        case .failed: return "failed"
        case .timedOut: return "timed out"
        case .unavailable: return "unavailable"
        case .skipped: return "skipped"
        }
    }

    /// The programmatic spelling `jsonObject`'s `outcome` field uses —
    /// `timedOut`, not `word`'s two-word `"timed out"`. A CLI's JSON is read
    /// by a script that switches on this value, not by a person; matching
    /// the Swift case name lets that script's own enum mirror it verbatim.
    private static func outcomeKey(_ outcome: DiagnosticOutcome) -> String {
        switch outcome {
        case .ok: return "ok"
        case .failed: return "failed"
        case .timedOut: return "timedOut"
        case .unavailable: return "unavailable"
        case .skipped: return "skipped"
        }
    }

    /// The free text an outcome carries, or `nil` for the two cases that
    /// carry none (`ok`, `timedOut`). Shared by the text row's detail column
    /// and the JSON object's `reason` field, so the two renderers never
    /// disagree about which outcomes have a reason.
    private static func reason(_ outcome: DiagnosticOutcome) -> String? {
        switch outcome {
        case .ok, .timedOut: return nil
        case .failed(let reason): return reason
        case .unavailable(let reason): return reason
        case .skipped(let reason): return reason
        }
    }

    /// `id`, padded with spaces to width 14 — wide enough for every id the
    /// runner writes itself (`DiagnosticStepID`) with room for a
    /// contribution's own, without truncating one that runs longer.
    private static let idColumnWidth = 14
    /// `word(_:)`'s longest case, `"unavailable"`, sets the width; nothing is
    /// truncated if a future case's word runs longer.
    private static let outcomeColumnWidth = 11
    /// What a hop row is indented under its step's own row.
    private static let hopIndent = "    "

    /// Pads `text` with trailing spaces to `width`, counting `Character`s —
    /// not `padding(toLength:)`, which counts UTF-16 units and would
    /// misalign a column under an astral scalar the same way
    /// `DiagnosticReport.aligned`'s own hand-rolled padding avoids. Never
    /// truncates: a value wider than `width` is printed whole, ragged.
    private static func padRight(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    /// One text row: `<id padded to 14>  <outcome word padded to 11>
    /// <duration>  <detail>`, where `<detail>` is the outcome's own reason
    /// text (for `failed`/`unavailable`/`skipped`) followed by
    /// `step.detail`, joined by `" — "` when both are present — the same
    /// separator `DiagnosticReport.plainText()` uses between the outcome
    /// label and the detail line. The trailing detail column is omitted
    /// entirely, not padded, when there is nothing to put in it: a fixed
    /// row of trailing spaces would be invisible here and visible wherever
    /// this text gets pasted.
    ///
    /// A trace step's hops (`step.table`) follow as indented rows below the
    /// step's own row — one row per hop, aligned to each other's column
    /// widths, with no header row: this is a terse CLI line, not the
    /// full report's table.
    public static func textRows(for step: DiagnosticStep) -> [String] {
        let idField = padRight(step.id, to: idColumnWidth)
        let outcomeField = padRight(word(step.outcome), to: outcomeColumnWidth)
        let durationField = DurationText.milliseconds(step.duration)
        var line = "\(idField)  \(outcomeField)  \(durationField)"
        let detail = detailColumn(for: step)
        if !detail.isEmpty { line += "  \(detail)" }

        var rows = [line]
        if let table = step.table {
            rows.append(contentsOf: alignedHopRows(table))
        }
        return rows
    }

    /// `reason(step.outcome)` and `step.detail`, combined the way
    /// `DiagnosticReport.plainText()` combines the outcome label and the
    /// detail line.
    private static func detailColumn(for step: DiagnosticStep) -> String {
        switch (reason(step.outcome), step.detail.isEmpty) {
        case (nil, true): return ""
        case (nil, false): return step.detail
        case (let reason?, true): return reason
        case (let reason?, false): return "\(reason) — \(step.detail)"
        }
    }

    /// A trace's hop rows, indented and column-aligned to each other — the
    /// same padding `DiagnosticReport.aligned(_:)` does for the pasted
    /// report, minus the header row: `textRows` prints one row per hop, no
    /// more, so a trace step with two hops renders exactly three lines in
    /// total (its own row, then two).
    private static func alignedHopRows(_ table: DiagnosticTable) -> [String] {
        let rows = table.rows
        guard !rows.isEmpty else { return [] }
        let widths = (0..<table.columns.count).map { column in
            rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            let cells = row.enumerated().map { index, cell -> String in
                guard index < row.count - 1, index < widths.count else { return cell }
                return padRight(cell, to: widths[index])
            }
            return hopIndent + cells.joined(separator: "  ")
        }
    }

    /// One JSON object per step: `id`, `outcome`, `reason` (absent for
    /// `ok`/`timedOut`), `durationMs` (an integer), `detail`, and — for the
    /// trace step only — `hops`.
    ///
    /// **`hops`'s shape is not what the brief guessed, and this is the
    /// documented deviation the brief calls for.** The brief's contract
    /// named three keys per hop, `hop`/`address`/`rttMs` — a numeric
    /// millisecond field. But `DiagnosticStep.table` is a `DiagnosticTable`,
    /// and its cells are already-formatted strings
    /// (`ConnectionDiagnostics.traceTable(_:)` writes `"2.0 ms"` or the
    /// literal `"—"` through `DurationText.milliseconds`/
    /// `DiagnosticTraceColumn.noRTT`), not a `Duration` this renderer could
    /// reformat as a number — re-parsing formatted text back into a number
    /// is exactly what `DiagnosticTable`'s own doc comment says a renderer
    /// must not do to another renderer's cells. The table also carries a
    /// fourth column, `outcome`, that the brief's three-key guess did not
    /// anticipate at all. So each hop is rendered generically from the
    /// table's own columns — `DiagnosticReport.header(_:)`'s derivation
    /// (a column key's last dotted component) applied to each of
    /// `DiagnosticTraceColumn.all`, giving `hop`, `address`, `rtt`,
    /// `outcome` — every value a `String`, matching what the table actually
    /// carries. `hop` and `address` match the brief's contract; `rtt`
    /// replaces the un-buildable `rttMs`; `outcome` is the addition the
    /// brief's guess omitted.
    public static func jsonObject(for step: DiagnosticStep) -> [String: Any] {
        var object: [String: Any] = [
            "id": step.id,
            "outcome": outcomeKey(step.outcome),
            "durationMs": Int(step.duration.milliseconds.rounded()),
            "detail": step.detail,
        ]
        if let reason = reason(step.outcome) {
            object["reason"] = reason
        }
        if let table = step.table {
            object["hops"] = jsonHops(table)
        }
        return object
    }

    private static func jsonHops(_ table: DiagnosticTable) -> [[String: String]] {
        let keys = table.columns.map(DiagnosticReport.header)
        return table.rows.map { row in
            var hop: [String: String] = [:]
            for (index, key) in keys.enumerated() where row.indices.contains(index) {
                hop[key] = row[index]
            }
            return hop
        }
    }

    /// What `jsonSummary`'s `completion` field prints for each of
    /// `DiagnosticReport.Completion`'s three cases. `cancelled`'s
    /// `afterSteps` count is dropped here — the brief's contract fixes
    /// exactly the three words `"complete"` / `"running"` / `"cancelled"`,
    /// and `steps.count` already tells a JSON reader how many rows landed.
    private static func completionKey(_ completion: DiagnosticReport.Completion) -> String {
        switch completion {
        case .complete: return "complete"
        case .running: return "running"
        case .cancelled: return "cancelled"
        }
    }

    /// The final object: `completion`, `endpoint` (`{host, port}` or
    /// `null`), `steps` (one `jsonObject(for:)` per step, in order).
    public static func jsonSummary(for report: DiagnosticReport) -> [String: Any] {
        let endpointField: Any
        if let endpoint = report.endpoint {
            endpointField = ["host": endpoint.host, "port": endpoint.port]
        } else {
            endpointField = NSNull()
        }
        return [
            "completion": completionKey(report.completion),
            "endpoint": endpointField,
            "steps": report.steps.map(jsonObject(for:)),
        ]
    }

    /// The one line that says a walk did not finish, or `nil` for one that
    /// did — `DiagnosticReport.marker(for:)`, carried through verbatim, not
    /// reformatted here.
    ///
    /// The text form prints this after the last row. `plainText()` puts the
    /// same line in its HEADER, which a CLI that prints rows the moment they
    /// land cannot do: by the time the walk's completion is known, the rows
    /// are already on the terminal. So the line moves to the end, and it is
    /// the only thing about this rendering that the pasted report does
    /// differently.
    ///
    /// `nil` for a complete walk, so a finished `--scope ping` prints its
    /// three rows and nothing else — the same argument `marker(for:)` makes
    /// for the report: a line that appears in every run says nothing about
    /// the one being read.
    public static func completionRow(for report: DiagnosticReport) -> String? {
        DiagnosticReport.marker(for: report.completion)
    }

    /// `.success` when every step is `ok`, `skipped`, or `unavailable`;
    /// `.diagnosis` when any step is `failed` or `timedOut` — the two
    /// outcomes that say something is actually wrong with the server or the
    /// path to it, as opposed to "this build/session had nothing to run
    /// here" (`DiagnosticOutcome`'s own doc comment draws the same line).
    public static func exitCode(for report: DiagnosticReport) -> CLIExitCode {
        let foundAProblem = report.steps.contains { step in
            switch step.outcome {
            case .failed, .timedOut: return true
            case .ok, .unavailable, .skipped: return false
            }
        }
        return foundAProblem ? .diagnosis : .success
    }
}
