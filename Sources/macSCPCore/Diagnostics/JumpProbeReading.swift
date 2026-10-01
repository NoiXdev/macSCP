import Foundation

// Everything a jump-host probe's output is read into: the values a row
// carries, the transcript each chunk of standard output is appended to, and
// the readers that parse what `getent`, `ping`, `traceroute` and `tracepath`
// printed. Split out of `JumpProbes.swift` on 2026-10-01 with its text
// unchanged; the rule these readers serve — what comes back into the report —
// is stated once, in `JumpProbes.swift`, beside the three steps that run them.

// MARK: - Reading what the tools printed

/// One address `getent` answered.
struct JumpResolvedAddress: Sendable, Equatable {
    let family: ResolvedAddress.Family
    let text: String
}

/// What a `ping` printed about itself: where it pinged, how many requests it
/// sent and heard back, and — when any came back — the tool's own minimum,
/// average and maximum round trip.
struct JumpPingSummary: Sendable, Equatable {
    let address: String?
    let sent: Int
    let received: Int
    let min: Duration?
    let average: Duration?
    let max: Duration?
}

/// How a probe's command came to its end — what a reader may conclude from
/// the rows it printed.
enum JumpProbeCompletion: Sendable, Equatable {
    /// The command ended with this exit status.
    case exited(Int)
    /// The step's budget ran out while the command was still running: what
    /// it had printed by then is all there is, and the walk it describes
    /// stopped LOOKING rather than ended.
    case cut
}

/// What one step's commands have printed so far, kept as it arrives — so a
/// step its budget abandons can still report what it measured
/// (`DiagnosticJumpStep.cut`).
///
/// One per step (`DiagnosticJumpStep.Context.forStep(budget:)`). `begin(_:)`
/// starts a command's output afresh, so a trace that fell back to
/// `tracepath` holds `tracepath`'s and not `traceroute`'s. The exec
/// plumbing appends from its own task, and the budget's cut reads from the
/// walk's, hence the lock.
final class JumpProbeTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var tool: JumpProbeCommand.Tool?
    private var bytes: [UInt8] = []

    init() {}

    /// The next command's output starts here; what the last one printed is
    /// dropped.
    func begin(_ tool: JumpProbeCommand.Tool) {
        lock.withLock {
            self.tool = tool
            bytes = []
        }
    }

    func append(_ chunk: [UInt8]) {
        lock.withLock { bytes.append(contentsOf: chunk) }
    }

    /// The command that was running, and what it had printed — `nil` when
    /// no command had started.
    var current: (tool: JumpProbeCommand.Tool, standardOutput: String)? {
        lock.withLock {
            guard let tool else { return nil }
            return (tool, String(decoding: bytes, as: UTF8.self))
        }
    }
}

/// Reads the probes' standard output. Every function answers `nil` for
/// anything it cannot read in full, and keeps nothing but what it checked:
/// addresses through `JumpProbeHost.addressKind(of:)`, numbers through their
/// own parsers.
///
/// The formats are the ones recorded in `JumpProbeSamples` (the test
/// target's): glibc's and musl's `getent`; BusyBox's, iputils' and BSD's
/// `ping`; BusyBox's and BSD's `traceroute`. `tracepath` and the Linux
/// `traceroute` package are on no machine available here and were not
/// recorded: their readers follow the shape of the recorded rows and the
/// tools' documented output, and are tested on constructed samples.
enum JumpProbeReading {
    /// `getent hosts`: one line per address, the address first, names
    /// after. Every non-empty line must read, or the output is no answer — a
    /// banner above a real line included.
    static func addresses(inGetentOutput output: String) -> [JumpResolvedAddress]? {
        var addresses: [JumpResolvedAddress] = []
        for line in lines(of: output) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, fields.count >= 2,
                let kind = JumpProbeHost.addressKind(of: String(first))
            else { return nil }
            let address = JumpResolvedAddress(
                family: kind == .ipv6 ? .ipv6 : .ipv4, text: String(first))
            if !addresses.contains(address) { addresses.append(address) }
        }
        return addresses.isEmpty ? nil : addresses
    }

    /// `ping -c`: the statistics line is required —
    /// `3 packets transmitted, 3 packets received` (BusyBox, BSD) or
    /// `3 packets transmitted, 3 received` (iputils) — and the round-trip
    /// line is read when there is one: `round-trip min/avg/max = …` (BusyBox),
    /// `round-trip min/avg/max/stddev = …` (BSD), `rtt min/avg/max/mdev = …`
    /// (iputils), by the names it gives its own columns. The address is the
    /// one in parentheses on the `PING` line, when it is an IP literal.
    static func ping(_ output: String) -> JumpPingSummary? {
        var address: String?
        var counts: (sent: Int, received: Int)?
        var times: (min: Duration, average: Duration, max: Duration)?
        for line in lines(of: output) {
            if line.hasPrefix("PING "), address == nil,
                let open = line.firstIndex(of: "("),
                let close = line[open...].firstIndex(of: ")")
            {
                let inside = String(line[line.index(after: open)..<close])
                if JumpProbeHost.addressKind(of: inside) != nil { address = inside }
            } else if line.contains(" packets transmitted, ") {
                counts = pingCounts(line)
            } else if line.contains("min/avg/max"), line.contains(" = ") {
                times = pingTimes(line)
            }
        }
        guard let counts, counts.received <= counts.sent, counts.sent > 0 else { return nil }
        let heard = counts.received > 0 ? times : nil
        return JumpPingSummary(
            address: address, sent: counts.sent, received: counts.received,
            min: heard?.min, average: heard?.average, max: heard?.max)
    }

    /// A `ping` the budget cut off before its statistics: the address on its
    /// `PING` line and the round trip of every reply line it printed —
    /// `… time=0.040 ms`, the shape BusyBox, iputils and BSD all print. `nil`
    /// when there is no `PING` line at all, which is no ping output.
    static func pingReplies(
        inPartialOutput output: String
    ) -> (address: String?, replies: [Duration])? {
        var sawPing = false
        var address: String?
        var replies: [Duration] = []
        for line in lines(of: output, completion: .cut) {
            if line.hasPrefix("PING ") {
                sawPing = true
                if let open = line.firstIndex(of: "("),
                    let close = line[open...].firstIndex(of: ")")
                {
                    let inside = String(line[line.index(after: open)..<close])
                    if JumpProbeHost.addressKind(of: inside) != nil { address = inside }
                }
            } else if line.contains(" bytes from "),
                let time = line.range(of: " time=")
            {
                let words = line[time.upperBound...].split(whereSeparator: \.isWhitespace)
                guard words.count >= 2, words[1] == "ms",
                    let rtt = milliseconds(String(words[0]))
                else { continue }
                replies.append(rtt)
            }
        }
        return sawPing ? (address, replies) : nil
    }

    /// `traceroute -n -q 1`: an optional header (`traceroute to NAME (ADDR),
    /// N hops max, …` — recorded on standard output from BusyBox and on
    /// standard error from BSD, so often absent), then one row per hop:
    /// `N  ADDR  RTT ms`, optionally followed by an `!` annotation, or
    /// `N  *`.
    ///
    /// Read into the local trace's own `NetworkTraceOutcome`, so the row, the
    /// table and the markers are the ones `jump.trace` gets
    /// (`ConnectionDiagnostics.traceOutcome/traceTable/traceDetail`):
    ///
    /// - A row with an annotation is destination-unreachable with that code.
    /// - The last row, when it answered with no annotation, is where the
    ///   tool stopped because it ARRIVED — `traceroute` ends at the
    ///   destination, an unreachable, or its hop limit — unless that row
    ///   sits at the hop limit and is not the named destination. So it
    ///   becomes the destination's port-unreachable, and the destination is
    ///   the header's address, or that row's when there is no header.
    /// - A last row at the hop limit ends the walk `.hopLimit`.
    ///
    /// **The hop limit is `maxHops`, the one the command was built with**
    /// (fix round 2) — never an assumed default, and never the header's
    /// count, which is only there on some systems. BSD writes the header to
    /// standard error, which is dropped, so a header-less walk at the
    /// probe's `-m 17` used to be read against an assumed 30: its answered
    /// seventeenth hop read as arriving, and a router was reported as the
    /// target. A last row at `maxHops` that is not the literal target or the
    /// header's address is the hop limit.
    /// - Anything else — a walk that stopped at a silent hop short of the
    ///   limit, hop numbers out of order, a row that is not a row — is no
    ///   answer.
    ///
    /// **The exit status decides "arrived"** (fix round 1): only a walk that
    /// exited 0 may end on a plain row that is not the named destination.
    /// BusyBox's `traceroute` exits 1 when a send fails mid-walk, and a walk
    /// that ended there would otherwise report the last router as the
    /// target. Any other end is no answer — unless the row IS the header's
    /// destination, which says so itself. A walk the budget `cut` ends
    /// `.budget`, with the rows it had.
    static func traceroute(
        _ output: String, target: JumpProbeHost, maxHops: Int, completion: JumpProbeCompletion
    ) -> NetworkTraceOutcome? {
        var header: (destination: String, maxHops: Int)?
        var rows: [TraceRow] = []
        for line in lines(of: output, completion: completion) {
            if line.hasPrefix("traceroute to "), header == nil, rows.isEmpty {
                guard let read = tracerouteHeader(line) else { return nil }
                header = read
                continue
            }
            guard let row = tracerouteRow(line), row.ttl == (rows.last?.ttl ?? 0) + 1 else {
                return nil
            }
            rows.append(row)
        }
        return walk(
            rows, destination: header?.destination ?? literal(target),
            maxHops: maxHops, completion: completion,
            arrivedWithoutAnnotation: { row, maxHops, destination in
                row.address == destination
                    || (completion == .exited(0) && row.ttl < maxHops)
            })
    }

    /// `tracepath -n`: `N?: [LOCALHOST]  pmtu …` first (skipped), then
    /// `N:  ADDR  RTTms` rows — a hop may be printed more than once as the
    /// tool retries it, and the first is kept — `N:  no reply` for silence,
    /// `reached` on the row that is the destination, and `Too many hops`
    /// when it ran out.
    static func tracepath(
        _ output: String, target: JumpProbeHost, completion: JumpProbeCompletion
    ) -> NetworkTraceOutcome? {
        var rows: [TraceRow] = []
        var reached: String?
        var ranOutOfHops = false
        for line in lines(of: output, completion: completion) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Too many hops") { ranOutOfHops = true; continue }
            if trimmed.hasPrefix("Resume:") { continue }
            guard let colon = trimmed.firstIndex(of: ":"),
                let ttl = Int(trimmed[..<colon].trimmingCharacters(in: ["?"])), ttl > 0
            else { return nil }
            let rest = trimmed[trimmed.index(after: colon)...]
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if rest.first == "[LOCALHOST]" { continue }
            if ttl == rows.last?.ttl { continue }
            guard ttl == (rows.last?.ttl ?? 0) + 1 else { return nil }
            if rest == ["no", "reply"] {
                rows.append(TraceRow(ttl: ttl, answer: nil))
                continue
            }
            guard let address = rest.first, JumpProbeHost.addressKind(of: address) != nil,
                let rtt = rest.dropFirst().lazy.compactMap(tracepathRTT).first
            else { return nil }
            let code = rest.dropFirst().lazy.compactMap(unreachableCode).first
            rows.append(
                TraceRow(ttl: ttl, answer: TraceRow.Answer(address: address, rtt: rtt, code: code)))
            if rest.contains("reached") { reached = address }
        }
        return walk(
            rows, destination: reached ?? literal(target),
            // Its hop limit only when it SAID it ran out: `tracepath` is run
            // without `-m`, and no default of its is assumed here.
            maxHops: ranOutOfHops ? (rows.last?.ttl ?? 0) : Int.max,
            completion: completion,
            arrivedWithoutAnnotation: { row, _, destination in row.address == destination })
    }

    // MARK: The pieces

    /// One hop as either tool printed it: silent (`answer == nil`), or an
    /// address and round trip with the ICMP unreachable code its annotation
    /// named, if any.
    private struct TraceRow {
        struct Answer {
            let address: String
            let rtt: Duration
            let code: UInt8?
        }

        let ttl: Int
        let answer: Answer?

        var address: String? { answer?.address }
    }

    /// The rows as a walk: every answered row is `forwarded` except an
    /// annotated one (`unreachable` with its code) and the last one when
    /// `arrivedWithoutAnnotation` says the tool stopped there because it
    /// arrived (`unreachable` with port-unreachable — how the local trace
    /// records its own destination). `nil` when the rows do not end a walk —
    /// except under `.cut`, where a walk that neither arrived nor reached its
    /// limit ends `.budget`: the trace stopped looking, and says so.
    private static func walk(
        _ rows: [TraceRow], destination: String?, maxHops: Int,
        completion: JumpProbeCompletion,
        arrivedWithoutAnnotation: (TraceRow, Int, String?) -> Bool
    ) -> NetworkTraceOutcome? {
        guard let last = rows.last else { return nil }
        var hops: [NetworkTraceHop] = []
        var destination = destination
        for (index, row) in rows.enumerated() {
            guard let answer = row.answer else {
                hops.append(NetworkTraceHop(ttl: row.ttl, outcome: .timedOut))
                continue
            }
            if let code = answer.code {
                hops.append(
                    NetworkTraceHop(
                        ttl: row.ttl,
                        outcome: .unreachable(
                            address: answer.address, rtt: answer.rtt, code: code)))
            } else if index == rows.count - 1,
                arrivedWithoutAnnotation(row, maxHops, destination)
            {
                destination = destination ?? answer.address
                hops.append(
                    NetworkTraceHop(
                        ttl: row.ttl,
                        outcome: .unreachable(
                            address: answer.address, rtt: answer.rtt,
                            code: NetworkTrace.portUnreachableCode)))
            } else {
                hops.append(
                    NetworkTraceHop(
                        ttl: row.ttl,
                        outcome: .forwarded(address: answer.address, rtt: answer.rtt)))
            }
        }
        let ending: NetworkTraceEnding
        if case .unreachable = hops.last?.outcome {
            ending = .answered
        } else if last.ttl >= maxHops {
            ending = .hopLimit
        } else if completion == .cut {
            ending = .budget
        } else {
            return nil
        }
        return .measured(hops: hops, destination: destination ?? "", ending: ending)
    }

    private static func literal(_ host: JumpProbeHost) -> String? {
        host.kind == .name ? nil : host.text
    }

    /// `traceroute to NAME (ADDR), N hops max, …`
    private static func tracerouteHeader(_ line: String) -> (destination: String, maxHops: Int)? {
        guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")")
        else { return nil }
        let address = String(line[line.index(after: open)..<close])
        guard JumpProbeHost.addressKind(of: address) != nil else { return nil }
        let words = line[close...].split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard let hopsWord = words.firstIndex(of: "hops"), hopsWord > words.startIndex,
            let maxHops = Int(words[words.index(before: hopsWord)]), maxHops > 0
        else { return nil }
        return (address, maxHops)
    }

    /// `N  ADDR  RTT ms [!X]` or `N  *`.
    private static func tracerouteRow(_ line: String) -> TraceRow? {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, let ttl = Int(first), ttl > 0, words.count >= 2 else {
            return nil
        }
        if words.dropFirst().allSatisfy({ $0 == "*" }) {
            return TraceRow(ttl: ttl, answer: nil)
        }
        guard words.count >= 4, JumpProbeHost.addressKind(of: words[1]) != nil,
            words[3] == "ms", let rtt = milliseconds(words[2])
        else { return nil }
        let annotations = words.dropFirst(4)
        var code: UInt8?
        for annotation in annotations {
            guard let read = unreachableCode(annotation) else { return nil }
            code = read
        }
        return TraceRow(ttl: ttl, answer: TraceRow.Answer(address: words[1], rtt: rtt, code: code))
    }

    /// A traceroute or tracepath annotation as the ICMP destination-
    /// unreachable code it stands for (RFC 792, RFC 1812), or `nil` when the
    /// word is not one. `!<n>` names the code itself.
    private static func unreachableCode(_ word: String) -> UInt8? {
        guard word.hasPrefix("!"), word.count >= 2 else { return nil }
        let body = word.dropFirst()
        if let number = UInt8(body) { return number }
        switch body.first {
        case "N": return 0
        case "H": return 1
        case "P": return 2
        case "F": return 4
        case "S": return 5
        case "X": return 13
        case "V": return 14
        case "C": return 15
        default: return nil
        }
    }

    /// tracepath's `0.402ms`.
    private static func tracepathRTT(_ word: String) -> Duration? {
        guard word.hasSuffix("ms") else { return nil }
        return milliseconds(String(word.dropLast(2)))
    }

    /// `3 packets transmitted, 3 packets received, …` or
    /// `3 packets transmitted, 3 received, …`.
    private static func pingCounts(_ line: String) -> (sent: Int, received: Int)? {
        let parts = line.split(separator: ",").map {
            $0.split(whereSeparator: \.isWhitespace)
        }
        guard parts.count >= 2, parts[0].count >= 3, parts[0][1] == "packets",
            parts[0][2] == "transmitted", let sent = Int(parts[0][0]),
            let receivedWord = parts[1].firstIndex(of: "received"),
            receivedWord > parts[1].startIndex,
            let received = Int(parts[1][parts[1].startIndex])
        else { return nil }
        return (sent, received)
    }

    /// `NAMES = VALUES ms`, where NAMES is `min/avg/max[/…]`.
    private static func pingTimes(
        _ line: String
    ) -> (min: Duration, average: Duration, max: Duration)? {
        guard let equals = line.range(of: " = ") else { return nil }
        let names = line[..<equals.lowerBound].split(whereSeparator: \.isWhitespace).last?
            .split(separator: "/").map(String.init) ?? []
        let valueWords = line[equals.upperBound...].split(whereSeparator: \.isWhitespace)
        guard valueWords.count == 2, valueWords[1] == "ms" else { return nil }
        let values = valueWords[0].split(separator: "/").map(String.init)
        guard names.count == values.count,
            let min = names.firstIndex(of: "min").flatMap({ milliseconds(values[$0]) }),
            let average = names.firstIndex(of: "avg").flatMap({ milliseconds(values[$0]) }),
            let max = names.firstIndex(of: "max").flatMap({ milliseconds(values[$0]) })
        else { return nil }
        return (min, average, max)
    }

    /// A tool's millisecond figure as a `Duration`, or `nil` for anything
    /// that is not a finite, non-negative decimal.
    private static func milliseconds(_ text: String) -> Duration? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            let value = Double(text), value.isFinite, value >= 0
        else { return nil }
        return .nanoseconds(Int64((value * 1_000_000).rounded()))
    }

    /// The non-empty lines of an output, each without its line ending. For
    /// a `cut` output, a last line with no line ending yet is dropped: the
    /// tool was still writing it.
    private static func lines(
        of output: String, completion: JumpProbeCompletion = .exited(0)
    ) -> [String] {
        var text = Substring(output)
        if completion == .cut, let lastBreak = text.lastIndex(where: \.isNewline) {
            text = text[...lastBreak]
        } else if completion == .cut {
            text = ""
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
