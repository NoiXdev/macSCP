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
    /// error text — see `DialSupport.dialSecret`.
    static let secretSourceFailed = "the secret source failed"
    /// The dial needs a credential, the secret chain had none, and its
    /// managed-key link found `managed_keys.json` unreadable for a key that
    /// lies in the managed key directory — `noSecret`, with the reason the
    /// chain came back empty. Only the session's own dial reports it: a
    /// jump's secret is not looked up through that link (see
    /// `DialSupport.missingSecretReason(_:secrets:)`), and says
    /// `jumpManagedKeyStoreUnreadable` below for the same fact about its own
    /// key.
    static let managedKeyStoreUnreadable =
        "the managed key store (managed_keys.json) could not be read, so the key's passphrase was not looked up"
    /// The S3 dial has no endpoint URL to probe.
    static let noEndpoint = "this session names no endpoint"
    /// The WebDAV dial has no base URL to probe.
    static let noServerURL = "this session names no server URL"

    /// The session dials through a jump host, and where that jump is could
    /// not be read: a saved connection it names is gone, a login set it names
    /// is not an SSH login, or its host is empty. The jump's first row, and
    /// nothing is reached through it.
    static let jumpUnresolvable = "the jump host could not be read from this session"
    /// Every step that goes THROUGH the jump, when the jump itself was not
    /// reached — a jump step up to its dial failed, or the dial did not open
    /// a connection. Names the jump, because the target was not measured at
    /// all and a reader must not take the row for a finding about it.
    static let jumpNotReached = "the jump host was not reached"
    /// The jump's dial needs a credential and its own slot held none — the
    /// jump's counterpart of `noSecret`, which names the session's. Said only
    /// when there is nothing to name beyond that; when the hop's lookup came
    /// back empty because the key store could not be read, the reason below
    /// is said instead (`DiagnosticJump.missingSecretReason`).
    static let noJumpSecret = "no secret available for the jump host"
    /// The jump's dial needs a credential, its own slot held none, and the
    /// hop's managed-key lookup found `managed_keys.json` unreadable for a
    /// key that lies in the managed key directory — `noJumpSecret`, with the
    /// reason the lookup came back empty. The jump's counterpart of
    /// `managedKeyStoreUnreadable`, which names the session's own.
    ///
    /// Names the file and nothing else: not the key, not its path, not a line
    /// of what the file holds. The fact is that it could not be read.
    static let jumpManagedKeyStoreUnreadable =
        "the managed key store (managed_keys.json) could not be read, so the jump host's key passphrase was not looked up"
    /// `target.tcpViaJump`'s channel open was refused with reason code 1: the
    /// jump host does not forward connections for this login at all
    /// (`AllowTcpForwarding`, a `ForceCommand`, a restricted account).
    static let jumpForwardingProhibited = "the jump host does not forward connections"
    /// The same open refused with reason code 2: the jump host tried and
    /// could not reach the target — its name did not resolve there, or
    /// nothing accepted on the port.
    static let jumpCouldNotConnect = "the jump host could not connect to the target"

    /// The target's host, as the session names it, is not something a
    /// command on the jump host may be handed: neither a host name made of
    /// RFC 1123 labels nor an IP literal (`JumpProbeHost`). Nothing was run —
    /// the check comes before any channel opens — so the row is about this
    /// session's text, not about the target.
    static let jumpProbeHostRefused =
        "the target's host is not a plain host name or IP address, so nothing was run with it on the jump host"
    /// The jump host did not run a probe's command: it refused the channel
    /// or the `exec` request, or the connection failed under it. A bastion
    /// that allows forwarding and nothing else is ordinary.
    static let jumpExecRefused = "the jump host did not run the command"
    /// The shell on the jump host could not find the tool a probe names
    /// (exit status 127). One sentence per tool, so each renders under its
    /// own key.
    static let jumpHasNoGetent = "the jump host has no getent"
    static let jumpHasNoPing = "the jump host has no ping"
    /// Neither of the two trace tools `target.traceFromJump` tries is there.
    static let jumpHasNoTraceTool = "the jump host has neither traceroute nor tracepath"
    /// The tool ran and what it printed is not an answer the probe can read
    /// — a tool that was not permitted, a forced command answering in its
    /// place, a format this diagnosis does not know. The exit status is in
    /// the row's detail.
    static let jumpResolveUnreadable = "the jump host's getent gave no answer this diagnosis can read"
    static let jumpPingUnreadable = "the jump host's ping gave no answer this diagnosis can read"
    static let jumpTraceUnreadable =
        "no trace tool on the jump host gave an answer this diagnosis can read"
    /// `getent` on the jump host answered that the name is not known there
    /// (exit status 2) — a finding about the target's name as the jump host
    /// sees it, and so `failed`.
    static let jumpCouldNotResolve = "the jump host could not resolve the target's name"
    /// `target.resolveOnJump` for a target named by an IP literal: there is
    /// no name to resolve, and a reverse lookup that found no name would
    /// read as a failure nobody had.
    static let targetIsAnAddress = "the target is an IP address, so there is no name to resolve"

    /// The throughput step's session starts at an S3 bucket list, which
    /// holds buckets and no folder a test file could be written to. About
    /// this session, not the server — so `unavailable`, and never `failed`.
    static let throughputNeedsAFolder =
        "this session starts at the bucket list, which has no folder to write a test file to"
    /// The throughput step read its payload back and it is not what was
    /// written: a different byte, or a different length. The detail says
    /// which, and where.
    static let throughputBytesDiffer = "the bytes read back are not the bytes written"
    /// The throughput step's test file could not be removed, or its removal
    /// did not answer — the one outcome that leaves something of this app's
    /// on the user's server. The detail names the file. The next run's
    /// leftover sweep tries to remove it — which a server that refused this
    /// removal may refuse again, and which cannot reach an S3 incomplete
    /// upload at all — so the panel's sentence says "tries", and "by hand".
    static let throughputFileLeftBehind = "the test file may have been left on the server"

    /// The internet speed test's service is `off`. Nothing was sent: the
    /// guard that produces this sentence runs before a request is built
    /// (`InternetSpeedProbe.measure`).
    ///
    /// Says WHAT is true and not WHERE it was chosen, because the two
    /// surfaces differ: in the app the service is a setting, on the command
    /// line it is `--speed-service off`, and a sentence naming Settings
    /// would be wrong on the surface that has none. The panel's own
    /// catalogue entry does name Settings — it is only ever shown in the
    /// app.
    static let internetSpeedOff = "the internet speed test is switched off"
    /// One leg of the internet speed test did not finish inside its bound
    /// (`DiagnosticInternetSpeedSettings.defaultLegTimeout`). `unavailable`
    /// and never `failed`: a slow line to a free third-party service is not
    /// a finding about the user's server.
    static let internetSpeedTooSlow =
        "the speed service did not finish inside this step's bound"
    /// The service answered without sending a single byte — a redirect to
    /// an empty body, a proxy's interception page of zero length. There is
    /// no rate to compute from it.
    static let internetSpeedNoBytes = "the speed service sent no bytes"
    /// The speed service answered a redirect pointing away from its own
    /// origin, and nothing was sent there
    /// (`InternetSpeedRedirectDelegate`). About the service and about this
    /// step's own rule, not about the user's server — so `unavailable`,
    /// like every other way this step declines to report a rate. The
    /// detail names both origins.
    static let internetSpeedRedirectRefused =
        "the speed service tried to send the request to another server, and it was refused"

    /// One leg of the internet speed test failed, with whatever the
    /// transport said. Composed, like `traceHopUnreachable`, so it carries
    /// no catalogue key: the service's own sentence is the content, and the
    /// panel shows such a reason exactly as it was measured.
    static func internetSpeedLegFailed(_ direction: String, _ reason: String) -> String {
        "the \(direction) leg of the speed test failed: \(reason)"
    }

    /// A refusal with any other reason code. Composed, like
    /// `traceHopUnreachable`, so it carries no catalogue key and the panel
    /// shows it as measured.
    static func jumpRefusedChannel(code: UInt32) -> String {
        "the jump host refused the channel (code \(code))"
    }

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
        managedKeyStoreUnreadable: "diagnostics.reason.managedKeyStoreUnreadable",
        noEndpoint: "diagnostics.reason.noEndpoint",
        noServerURL: "diagnostics.reason.noServerURL",
        jumpUnresolvable: "diagnostics.reason.jumpUnresolvable",
        jumpNotReached: "diagnostics.reason.jumpNotReached",
        noJumpSecret: "diagnostics.reason.noJumpSecret",
        jumpManagedKeyStoreUnreadable: "diagnostics.reason.jumpManagedKeyStoreUnreadable",
        jumpForwardingProhibited: "diagnostics.reason.jumpForwardingProhibited",
        jumpCouldNotConnect: "diagnostics.reason.jumpCouldNotConnect",
        jumpProbeHostRefused: "diagnostics.reason.jumpProbeHostRefused",
        jumpExecRefused: "diagnostics.reason.jumpExecRefused",
        jumpHasNoGetent: "diagnostics.reason.jumpHasNoGetent",
        jumpHasNoPing: "diagnostics.reason.jumpHasNoPing",
        jumpHasNoTraceTool: "diagnostics.reason.jumpHasNoTraceTool",
        jumpResolveUnreadable: "diagnostics.reason.jumpResolveUnreadable",
        jumpPingUnreadable: "diagnostics.reason.jumpPingUnreadable",
        jumpTraceUnreadable: "diagnostics.reason.jumpTraceUnreadable",
        jumpCouldNotResolve: "diagnostics.reason.jumpCouldNotResolve",
        targetIsAnAddress: "diagnostics.reason.targetIsAnAddress",
        throughputNeedsAFolder: "diagnostics.reason.throughputNeedsAFolder",
        throughputBytesDiffer: "diagnostics.reason.throughputBytesDiffer",
        throughputFileLeftBehind: "diagnostics.reason.throughputFileLeftBehind",
        internetSpeedOff: "diagnostics.reason.internetSpeedOff",
        internetSpeedTooSlow: "diagnostics.reason.internetSpeedTooSlow",
        internetSpeedNoBytes: "diagnostics.reason.internetSpeedNoBytes",
        internetSpeedRedirectRefused: "diagnostics.reason.internetSpeedRedirectRefused",
        ICMPEcho.noIPv6RouteReason: "diagnostics.reason.noIPv6Route",
        NetworkTrace.ipv6UnmeasuredReason: "diagnostics.reason.ipv6TraceUnmeasured",
        NetworkTrace.notIPv4Reason: "diagnostics.reason.traceNeedsIPv4",
    ]
}
