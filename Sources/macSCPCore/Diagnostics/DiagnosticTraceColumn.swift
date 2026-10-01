// The trace table's column keys and cell words. Split out of
// `ConnectionDiagnostics.swift` on 2026-10-01 with its text unchanged, into a
// file of its own rather than beside the trace step, because the App reads
// these keys from well outside the diagnosis.

/// The trace table's four columns — as catalogue keys, which is what a
/// `DiagnosticTable` carries — and the words its cells are written in.
///
/// The keys are here rather than in the App because the table is Core's, the
/// same rule `DiagnosticStepID.titleKey(for:)` and `DiagnosticReason`'s table
/// already keep: Core names a row, the App resolves the name, and no catalog
/// is read on this side.
///
/// The CELL words are English and unlocalized in Core, like every other word
/// the report prints (`DiagnosticOutcome.label` states why); the panel maps
/// them through `diagnostics.trace.outcome.*`. They are constants and not
/// literals at all three arms of `traceTable(_:)`'s switch — `.forwarded`,
/// `.unreachable` and `.timedOut` — for the same reason the reasons are: a
/// reworded word has to break the mapping loudly rather than quietly stop
/// matching.
public enum DiagnosticTraceColumn {
    public static let hop = "diagnostics.trace.column.hop"
    public static let address = "diagnostics.trace.column.address"
    public static let rtt = "diagnostics.trace.column.rtt"
    public static let outcome = "diagnostics.trace.column.outcome"

    /// Every column key, in the order the cells are written, so a catalogue
    /// check can require all four without enumerating them a second time.
    public static let all = [hop, address, rtt, outcome]

    /// A router on the path answered, and the walk went on past it.
    public static let answered = "answered"
    /// The hop was given its full `NetworkTrace.hopTimeout` and answered
    /// nothing. It is a measurement, not a gap — see `TraceHopOutcome
    /// .timedOut`, which is the only thing that produces this row.
    public static let silent = "silent"
    /// The address the trace was aimed at answered: the path ends here.
    public static let destination = "destination"

    /// Anything else that answered destination-unreachable, naming the code
    /// it sent — a policy block most often, and a finding about the path.
    public static func unreachable(code: UInt8) -> String { "unreachable (code \(code))" }

    /// What the address column says for a hop that answered nothing. The
    /// traceroute spelling, and the one this project's hop rows have always
    /// used.
    public static let noAddress = "*"
    /// What the RTT column says for the same hop: there is no round trip to
    /// report, and an empty cell reads as a number that went missing.
    public static let noRTT = "—"
}
