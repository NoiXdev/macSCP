import Foundation

/// The fixed sentences a diagnostic step reports as its reason, and the
/// catalogue key each of them renders under in the panel.
///
/// ## Why the sentences are symbols
///
/// `DiagnosticOutcome.failed/unavailable/skipped` carry free text, because
/// most of what fills them is not fixed at all — a `strerror`, a server's own
/// message, an `NSError`'s sentence. A handful ARE fixed, and those are the
/// ones a localized panel can render in the reader's language. Written as
/// literals at their emission sites they would have to be written a second
/// time in the table below, and a reworded sentence would then quietly stop
/// matching: the row would keep drawing, in English, with nothing red.
/// `ICMPEcho.noIPv6RouteReason` and `NetworkTrace`'s two already said as
/// much in their own doc comments; this type is where they were pointing.
///
/// ## Why the table lives in Core and not in the App
///
/// Core spells the step keys already (`DiagnosticStepID.titleKey(for:)`,
/// `DialProbes`' three per-backend keys), and for the same reason: the key is
/// a name for a row, and the row is Core's. What Core does NOT do is resolve
/// one — no catalog is read here, no bundle is touched. The App looks the key
/// up and passes the English sentence as its own fallback, so a reason with
/// no key, and a key missing from a catalog, both come out as the English
/// that was measured.
public enum DiagnosticReason {
    /// The endpoint could not be read off the session's field values at all.
    static let noHost = "this session names no host"
    /// Resolution produced no address, so the probes that need one did not
    /// run. Reported by the TCP, ICMP and trace steps alike.
    static let nothingToProbe = "nothing resolved to probe"
    /// The dial needs a credential and the secret source had none for this
    /// session.
    static let noSecret = "no secret available for this session"
    /// The secret source itself failed. Deliberately not the source's own
    /// error text — see `DiagnosticContribution.sshConnect`.
    static let secretSourceFailed = "the secret source failed"
    /// The S3 dial has no endpoint URL to probe.
    static let noEndpoint = "this session names no endpoint"
    /// The WebDAV dial has no base URL to probe.
    static let noServerURL = "this session names no server URL"

    /// The fixed half of the marker a trace's DETAIL line carries when the
    /// step's budget, and not the path, ended the walk.
    ///
    /// Without it a `*` row is byte-identical whether a router declined to
    /// answer or the trace simply stopped looking, and the report is a
    /// copy-and-paste artifact someone reads as a statement about the path.
    static let stoppedByBudget = "stopped by the budget"

    /// The whole marker up to the number, spelled ONCE: the composer below
    /// appends the hop to it, and the reader below takes the hop back off it.
    /// Two functions over one spelling, so a reworded marker cannot leave the
    /// panel matching a sentence Core no longer writes.
    private static let budgetMarkerPrefix = "\(stoppedByBudget) after hop "

    /// That marker, naming the last hop the walk actually measured. `0` says
    /// the budget ran out before any hop was measured at all.
    static func traceStoppedByBudget(afterHop hop: Int) -> String {
        budgetMarkerPrefix + "\(hop)"
    }

    /// The fixed half of the marker a trace's detail line carries when the
    /// walk ran out of HOPS rather than out of budget.
    ///
    /// The same reasoning as `stoppedByBudget`, for the other of the two ways
    /// a trace stops looking: thirty answering hops and no arrival is a walk
    /// that reached its own limit, and a row that stayed silent about it read
    /// as a path that simply ended.
    static let hopLimitReached = "hop limit reached"

    private static let hopLimitMarkerPrefix = "\(hopLimitReached) after hop "

    /// That marker, naming the last hop the walk measured.
    static func traceHopLimitReached(afterHop hop: Int) -> String {
        hopLimitMarkerPrefix + "\(hop)"
    }

    /// The catalogue key and hop number of whichever marker `row` is, or
    /// `nil` when it is an ordinary measured hop.
    ///
    /// Public because the PANEL needs it: a marker rides inside a step's
    /// detail line, which the panel prints, and a localized panel has to find
    /// it among the measured hop rows before it can render a key for it. Core
    /// does the finding, because Core did the composing — the alternative is
    /// the App spelling these sentences a second time, which is the thing
    /// this whole type exists to prevent.
    ///
    /// One reader for both markers rather than one per marker: the panel then
    /// gains nothing to change when a third arrives, and cannot render one of
    /// them and print the other in English.
    public static func marker(in row: String) -> (key: String, hop: Int)? {
        for (prefix, key) in [
            (budgetMarkerPrefix, stoppedByBudgetKey),
            (hopLimitMarkerPrefix, hopLimitReachedKey),
        ] where row.hasPrefix(prefix) {
            guard let hop = Int(row.dropFirst(prefix.count)) else { return nil }
            return (key, hop)
        }
        return nil
    }

    /// The reason a trace step reports when a router on the path answered
    /// destination-unreachable with a code of its own — a policy block, most
    /// often — rather than the destination answering port-unreachable.
    ///
    /// Composed, so it carries no catalogue key: the numbers are the whole
    /// content, and `key(for:)` matches a WHOLE reason. That is the same
    /// treatment the TCP step's `refused` already gets, and the panel shows
    /// such a sentence exactly as it was measured.
    static func traceHopUnreachable(code: UInt8, hop: Int) -> String {
        "unreachable (code \(code)) at hop \(hop)"
    }

    /// The catalogue key the budget marker renders under.
    ///
    /// Declared beside `table` rather than in it, because the sentence
    /// carries a hop number and `key(for:)` matches a whole reason. The
    /// catalogue entry is a format with one `%@`, the way
    /// `diagnostics.duration` already is.
    ///
    /// Looked up by `DiagnosticsPresentation.detail(of:)`, which walks the
    /// detail line's rows through `marker(in:)` and substitutes the hop
    /// number into the localized format. Everything else in that line is
    /// copied through byte for byte — the addresses and timings are the
    /// artifact somebody pastes into a bug report — and a marker is the
    /// exception because it is not a measurement.
    public static let stoppedByBudgetKey = "diagnostics.reason.traceStoppedByBudget"

    /// The catalogue key the hop-limit marker renders under — `stoppedByBudgetKey`'s
    /// twin, for the same reason and with the same one `%@`.
    public static let hopLimitReachedKey = "diagnostics.reason.traceHopLimitReached"

    /// The catalogue key `reason` renders under, or `nil` for a reason this
    /// module did not compose — a `strerror`, a server's message — which the
    /// panel shows as it is.
    public static func key(for reason: String) -> String? { table[reason] }

    /// Every key this type hands out — the table's, and the two marker keys
    /// that sit outside it because their sentences carry a hop number — so a
    /// catalogue check can require all of them without enumerating them a
    /// second time.
    ///
    /// The marker keys were missing here while nothing called this property,
    /// which is exactly how a promise like "every key" goes wrong;
    /// `ConnectionDiagnosticsTests
    /// .everyReasonKeyTheTypeHandsOutIsExactlyWhatTheCatalogCarries` is now
    /// the caller, and it compares against the catalogue rather than against
    /// this type.
    public static var allKeys: [String] {
        (table.values + [stoppedByBudgetKey, hopLimitReachedKey]).sorted()
    }

    /// The three sentences that are NOT declared above are declared where
    /// they were measured, and are referenced here rather than copied: the
    /// two trace ones in `NetworkTrace`, the route one in `ICMPEcho`.
    private static let table: [String: String] = [
        noHost: "diagnostics.reason.noHost",
        nothingToProbe: "diagnostics.reason.nothingResolvedToProbe",
        noSecret: "diagnostics.reason.noSecret",
        secretSourceFailed: "diagnostics.reason.secretSourceFailed",
        noEndpoint: "diagnostics.reason.noEndpoint",
        noServerURL: "diagnostics.reason.noServerURL",
        ICMPEcho.noIPv6RouteReason: "diagnostics.reason.noIPv6Route",
        NetworkTrace.ipv6UnmeasuredReason: "diagnostics.reason.ipv6TraceUnmeasured",
        NetworkTrace.notIPv4Reason: "diagnostics.reason.traceNeedsIPv4",
    ]
}
