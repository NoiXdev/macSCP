import Foundation
import Testing
@testable import macSCPCore

/// Builds a step with only the fields a given test cares about — every
/// other field gets a value that would visibly fail a row/JSON assertion if
/// it leaked in where it shouldn't (never used where a test expects it to
/// be absent).
private func makeStep(
    id: String = "dial", outcome: DiagnosticOutcome = .ok, detail: String = "",
    durationMs: Int = 0, table: DiagnosticTable? = nil
) -> DiagnosticStep {
    DiagnosticStep(
        id: id, titleKey: DiagnosticStepID.titleKey(for: id), started: Date(),
        duration: .milliseconds(durationMs), outcome: outcome, detail: detail, table: table)
}

@Suite("DiagnoseRendering.textRows")
struct DiagnoseRenderingTextRowsTests {
    @Test func aFailedStepRendersTheOutcomeWordAndTheReason() throws {
        let step = makeStep(id: "dial", outcome: .failed("connection refused"))
        let rows = DiagnoseRendering.textRows(for: step)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.contains("failed"))
        #expect(row.contains("connection refused"))
    }

    @Test func aFailedStepsRowCarriesBothTheReasonAndTheStepsOwnDetail() throws {
        let step = makeStep(id: "dial", outcome: .failed("refused"), detail: "203.0.113.5:22")
        let row = try #require(DiagnoseRendering.textRows(for: step).first)
        #expect(row.contains("refused"))
        #expect(row.contains("203.0.113.5:22"))
    }

    @Test func anOkStepWithNoDetailRendersWithoutTrailingWhitespace() throws {
        let step = makeStep(id: "resolve", outcome: .ok)
        let row = try #require(DiagnoseRendering.textRows(for: step).first)
        #expect(row.contains("ok"))
        #expect(row.last != " ")
    }

    @Test func theIDAndOutcomeWordFieldsArePaddedForColumnAlignment() throws {
        let step = makeStep(id: "tcp", outcome: .ok)
        let row = try #require(DiagnoseRendering.textRows(for: step).first)
        // "tcp" (3 chars) padded to width 14, "ok" (2 chars) padded to width
        // 11, each field then followed by a two-space separator.
        let expectedPrefix = "tcp" + String(repeating: " ", count: 11) + "  "
            + "ok" + String(repeating: " ", count: 9) + "  "
        #expect(row.hasPrefix(expectedPrefix))
    }

    @Test func timedOutRendersAsTwoWordsWithNoReason() throws {
        let step = makeStep(id: "dial", outcome: .timedOut)
        let row = try #require(DiagnoseRendering.textRows(for: step).first)
        #expect(row.contains("timed out"))
    }

    @Test func aTraceStepWithTwoHopsRendersThreeRowsTotal() {
        let table = DiagnosticTable(
            columns: DiagnosticTraceColumn.all,
            rows: [
                ["1", "10.0.0.1", "2.0 ms", DiagnosticTraceColumn.answered],
                ["2", "10.0.0.2", "3.5 ms", DiagnosticTraceColumn.destination],
            ])
        let step = makeStep(id: "trace", outcome: .ok, detail: "2 hops", table: table)
        let rows = DiagnoseRendering.textRows(for: step)
        #expect(rows.count == 3)
    }

    @Test func theHopRowsAreIndentedUnderTheSteps() throws {
        let table = DiagnosticTable(
            columns: DiagnosticTraceColumn.all,
            rows: [["1", "10.0.0.1", "2.0 ms", DiagnosticTraceColumn.answered]])
        let step = makeStep(id: "trace", outcome: .ok, table: table)
        let rows = DiagnoseRendering.textRows(for: step)
        let hopRow = try #require(rows.dropFirst().first)
        #expect(hopRow.hasPrefix(" "))
        #expect(hopRow.contains("10.0.0.1"))
    }

    @Test func aStepWithNoTableRendersExactlyOneRow() {
        let step = makeStep(id: "resolve", outcome: .ok)
        #expect(DiagnoseRendering.textRows(for: step).count == 1)
    }
}

@Suite("DiagnoseRendering.jsonObject")
struct DiagnoseRenderingJSONObjectTests {
    @Test func carriesDurationMsAsAnIntegerAndOmitsReasonForOk() {
        let step = makeStep(id: "resolve", outcome: .ok, durationMs: 7)
        let object = DiagnoseRendering.jsonObject(for: step)
        #expect(object["durationMs"] as? Int == 7)
        #expect(object["reason"] == nil)
    }

    @Test func omitsReasonForTimedOutToo() {
        let step = makeStep(id: "dial", outcome: .timedOut)
        let object = DiagnoseRendering.jsonObject(for: step)
        #expect(object["reason"] == nil)
        #expect(object["outcome"] as? String == "timedOut")
    }

    @Test func carriesReasonForFailedUnavailableAndSkipped() {
        #expect(DiagnoseRendering.jsonObject(for: makeStep(outcome: .failed("x")))["reason"] as? String == "x")
        #expect(
            DiagnoseRendering.jsonObject(for: makeStep(outcome: .unavailable("y")))["reason"] as? String == "y")
        #expect(
            DiagnoseRendering.jsonObject(for: makeStep(outcome: .skipped("z")))["reason"] as? String == "z")
    }

    @Test func carriesIDAndDetail() {
        let step = makeStep(id: "tcp", outcome: .ok, detail: "203.0.113.5:22")
        let object = DiagnoseRendering.jsonObject(for: step)
        #expect(object["id"] as? String == "tcp")
        #expect(object["detail"] as? String == "203.0.113.5:22")
    }

    @Test func omitsHopsWhenTheStepHasNoTable() {
        let step = makeStep(id: "resolve", outcome: .ok)
        #expect(DiagnoseRendering.jsonObject(for: step)["hops"] == nil)
    }

    /// Documents the deviation from the brief's guessed `hop`/`address`/
    /// `rttMs` keys: `DiagnosticTable`'s cells are already-formatted
    /// strings, so `rttMs` (a number) cannot be built without re-parsing
    /// text the table's own producer composed — this pins what the type
    /// actually allows instead: one string per column, keyed by the
    /// column's derived name, `outcome` included since the table carries a
    /// fourth column the brief's guess did not.
    @Test func hopsCarryOneEntryPerRowKeyedByTheTablesOwnColumns() throws {
        let table = DiagnosticTable(
            columns: DiagnosticTraceColumn.all,
            rows: [["1", "10.0.0.1", "2.0 ms", DiagnosticTraceColumn.answered]])
        let step = makeStep(id: "trace", outcome: .ok, table: table)
        let hops = try #require(DiagnoseRendering.jsonObject(for: step)["hops"] as? [[String: String]])
        #expect(hops.count == 1)
        let hop = try #require(hops.first)
        #expect(hop["hop"] == "1")
        #expect(hop["address"] == "10.0.0.1")
        #expect(hop["rtt"] == "2.0 ms")
        #expect(hop["outcome"] == DiagnosticTraceColumn.answered)
    }
}

@Suite("DiagnoseRendering.jsonSummary")
struct DiagnoseRenderingJSONSummaryTests {
    @Test func completionRendersAsOneOfTheThreeFixedWords() {
        let complete = DiagnosticReport(endpoint: nil, steps: [], appVersion: "1.0")
        let running = DiagnosticReport(
            endpoint: nil, steps: [], appVersion: "1.0", completion: .running)
        let cancelled = DiagnosticReport(
            endpoint: nil, steps: [], appVersion: "1.0", completion: .cancelled(afterSteps: 2))
        #expect(DiagnoseRendering.jsonSummary(for: complete)["completion"] as? String == "complete")
        #expect(DiagnoseRendering.jsonSummary(for: running)["completion"] as? String == "running")
        #expect(DiagnoseRendering.jsonSummary(for: cancelled)["completion"] as? String == "cancelled")
    }

    @Test func endpointIsNullWhenTheReportHasNone() {
        let report = DiagnosticReport(endpoint: nil, steps: [], appVersion: "1.0")
        #expect(DiagnoseRendering.jsonSummary(for: report)["endpoint"] is NSNull)
    }

    @Test func endpointCarriesHostAndPortWhenPresent() throws {
        let report = DiagnosticReport(
            endpoint: Endpoint(host: "example.test", port: 22), steps: [], appVersion: "1.0")
        let endpoint = try #require(DiagnoseRendering.jsonSummary(for: report)["endpoint"] as? [String: Any])
        #expect(endpoint["host"] as? String == "example.test")
        #expect(endpoint["port"] as? Int == 22)
    }

    @Test func stepsCarryOneJSONObjectPerStepInOrder() {
        let report = DiagnosticReport(
            endpoint: nil, steps: [makeStep(id: "resolve"), makeStep(id: "tcp")], appVersion: "1.0")
        let steps = DiagnoseRendering.jsonSummary(for: report)["steps"] as? [[String: Any]]
        #expect(steps?.map { $0["id"] as? String } == ["resolve", "tcp"])
    }
}

/// The text form's counterpart to `jsonSummary`'s `completion` field: one
/// line after the last row, or none.
@Suite("DiagnoseRendering.completionRow")
struct DiagnoseRenderingCompletionRowTests {
    /// A finished walk prints nothing extra — a `--scope ping` that came back
    /// clean is three rows and no fourth line.
    @Test func aCompleteWalkHasNoRow() {
        let report = DiagnosticReport(endpoint: nil, steps: [], appVersion: "1.0")
        #expect(DiagnoseRendering.completionRow(for: report) == nil)
    }

    /// The words are the report's own, not a second spelling composed here —
    /// asserted against `DiagnosticReport.marker(for:)` rather than against a
    /// literal, so a reworded marker cannot leave the terminal and the pasted
    /// report saying two different things.
    @Test(arguments: [DiagnosticReport.Completion.running, .cancelled(afterSteps: 2)])
    func anUnfinishedWalkPrintsTheReportsOwnMarker(completion: DiagnosticReport.Completion) throws {
        let report = DiagnosticReport(
            endpoint: nil, steps: [], appVersion: "1.0", completion: completion)
        let row = try #require(DiagnoseRendering.completionRow(for: report))
        #expect(row == DiagnosticReport.marker(for: completion))
    }

    /// The positive anchor for the `nil` above: the marker really is absent
    /// for `.complete` at the source, so the `nil` means "no marker" and not
    /// "this function returns nothing".
    @Test func theReportItselfMarksOnlyTheUnfinishedWalks() {
        #expect(DiagnosticReport.marker(for: .complete) == nil)
        #expect(DiagnosticReport.marker(for: .running) != nil)
        #expect(DiagnosticReport.marker(for: .cancelled(afterSteps: 1)) != nil)
    }
}

@Suite("DiagnoseRendering.exitCode")
struct DiagnoseRenderingExitCodeTests {
    @Test func isSuccessForOkSkippedAndUnavailable() {
        let report = DiagnosticReport(
            endpoint: nil,
            steps: [
                makeStep(id: "a", outcome: .ok),
                makeStep(id: "b", outcome: .skipped("no host configured")),
                makeStep(id: "c", outcome: .unavailable("not built on this platform")),
            ], appVersion: "1.0")
        #expect(DiagnoseRendering.exitCode(for: report) == .success)
    }

    @Test func isDiagnosisWhenAnyStepTimedOut() {
        let report = DiagnosticReport(
            endpoint: nil,
            steps: [makeStep(id: "a", outcome: .ok), makeStep(id: "b", outcome: .timedOut)],
            appVersion: "1.0")
        #expect(DiagnoseRendering.exitCode(for: report) == .diagnosis)
    }

    @Test func isDiagnosisWhenAnyStepFailed() {
        let report = DiagnosticReport(
            endpoint: nil,
            steps: [makeStep(id: "a", outcome: .failed("refused"))], appVersion: "1.0")
        #expect(DiagnoseRendering.exitCode(for: report) == .diagnosis)
    }

    @Test func diagnosisRawValueIsSixteen() {
        #expect(CLIExitCode.diagnosis.rawValue == 16)
    }
}
