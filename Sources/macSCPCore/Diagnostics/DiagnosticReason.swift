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

    /// The catalogue key `reason` renders under, or `nil` for a reason this
    /// module did not compose — a `strerror`, a server's message — which the
    /// panel shows as it is.
    public static func key(for reason: String) -> String? { table[reason] }

    /// Every key this type hands out, so a catalogue check can require all of
    /// them without enumerating them a second time.
    public static var allKeys: [String] { table.values.sorted() }

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
