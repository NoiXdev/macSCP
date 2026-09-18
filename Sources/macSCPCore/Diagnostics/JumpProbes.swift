import Darwin
import Foundation

// The three steps of a jump walk that are measured ON the jump host rather
// than through it: the jump host's name resolution of the target, its ping,
// and its trace — each a command run there over an `exec` channel on the
// connection `jump.dial` opened (Task 7 of the 2026-09-18 jump-and-groups
// plan). Everything a command line is built from and everything its output
// is read into lives in this file, so the rule for both is stated once.
//
// **When a command runs at all.** Only inside a diagnosis the user started:
// these steps are entries in `ConnectionDiagnostics.targetHalf`, walked by
// `run(scope:observer:)` and nothing else, and only once the jump was
// reached.
//
// **What reaches the jump host's shell.** A fixed tool and fixed options,
// then the target's host — validated first (`JumpProbeHost`), then passed as
// ONE single-quoted word (`PosixQuoting.singleQuoted`). A host that fails the
// check is refused before any channel opens, and the row says so.
//
// **What comes back into the report.** Only what a reader below parsed out
// of standard output: IP literals, counts and round-trip times, each checked
// on the way in. The jump host's own words — a banner, an error, a forced
// command's message — reach no row; an output that does not parse is
// `unavailable`, and its detail names the exit status and nothing else. What
// does reach a row passes `DiagnosticStep.init`'s userinfo filter like every
// other row, and an error is rendered through `DialSupport.reason(for:)`, the
// report's one credential-free sentence per error.

// MARK: - The host a command may be handed

/// A target host that may be handed to a command on the jump host: a host
/// name made of RFC 1123 labels, or an IPv4 or IPv6 literal. Nothing else is
/// constructible, so a `JumpProbeCommand` cannot be built around anything
/// else.
///
/// **The rule.** An IP literal is text made ONLY of `0-9 a-f A-F : .` that
/// `inet_pton(3)` then accepts for its family. The character set is the
/// boundary, not `inet_pton`: Darwin's accepts an IPv6 zone with ANY suffix
/// — `::1%$(id)`, `::1%;id` and `::1%a'b c` all return 1 (measured in the
/// 2026-09-18 review of this file) — and only the set, which has no `%`,
/// refuses them. The same check admits the addresses the readers below copy
/// out of tool output, so it guards the report's rows too. A host name is at
/// most 253 characters of dot-separated labels, each 1 to 63 ASCII letters,
/// digits or hyphens, neither starting nor ending with a hyphen; no empty
/// label, so no leading, trailing or doubled dot. Compared on Unicode scalars
/// and ASCII ranges, never `Character.isLetter`, which would let `é` in.
///
/// Why validate when the host is quoted anyway: the quoting keeps the shell
/// from reading the host as syntax, and the check keeps the TOOL from reading
/// it as anything but a host — a leading `-` is an option to `ping` however
/// it is quoted, and a label rule has no leading `-` to offer. Either alone
/// would be one mistake away from a command on somebody's bastion.
struct JumpProbeHost: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case name
        case ipv4
        case ipv6
    }

    let text: String
    let kind: Kind

    init?(_ host: String) {
        if let kind = Self.addressKind(of: host) {
            self.text = host
            self.kind = kind
        } else if Self.isHostName(host) {
            self.text = host
            self.kind = .name
        } else {
            return nil
        }
    }

    /// `.ipv4` or `.ipv6` for an IP literal, `nil` for anything else. Also
    /// how a tool's output is read: an address a reader keeps passes here
    /// first.
    static func addressKind(of text: String) -> Kind? {
        guard !text.isEmpty,
            text.unicodeScalars.allSatisfy({ addressScalars.contains($0) })
        else { return nil }
        if presentable(text, family: AF_INET) { return .ipv4 }
        if presentable(text, family: AF_INET6) { return .ipv6 }
        return nil
    }

    private static let addressScalars = Set("0123456789abcdefABCDEF:.".unicodeScalars)

    private static func presentable(_ text: String, family: Int32) -> Bool {
        var storage = in6_addr()
        return text.withCString { inet_pton(family, $0, &storage) } == 1
    }

    private static func isHostName(_ text: String) -> Bool {
        guard (1...253).contains(text.unicodeScalars.count) else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            let scalars = Array(label.unicodeScalars)
            guard (1...63).contains(scalars.count), scalars.first != "-", scalars.last != "-"
            else { return false }
            return scalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                    || ("0"..."9").contains(scalar) || scalar == "-"
            }
        }
    }
}

// MARK: - The command lines

/// One command line a diagnosis is willing to have run on a jump host.
///
/// The initializer is private, so the only values of this type in the whole
/// package are the ones the factories below build — a fixed tool, fixed
/// options with numbers this file computes, and a `JumpProbeHost` as one
/// single-quoted word. `DiagnosticJumpConnection.run(_:into:)` and
/// `SSHForwardingConnection.standardOutput(of:into:)` take this and not a
/// `String`, the argument `ChecksumCommandLine` makes for the checksum
/// channel: on the diagnosis's jump connection, no other text reaches the
/// jump host, in a test double no less than in production. That is a claim
/// about this path only — the exec plumbing underneath
/// (`SSHClient.collectingStandardOutput(of:limit:onStandardOutput:)`) is
/// internal and takes any `String`.
struct JumpProbeCommand: Sendable, Equatable {
    /// Which tool the line runs — the name the row's detail uses for it.
    enum Tool: String, Sendable, Equatable, CaseIterable {
        case getent
        case ping
        case traceroute
        case tracepath
    }

    let tool: Tool
    /// The line as the jump host's shell will see it.
    let text: String

    /// How much standard output one probe may send before it is no answer.
    /// The longest legitimate one is a trace: thirty `traceroute` rows of
    /// well under a hundred bytes each. 16 KiB is several times that, and
    /// far from anything a far side could use to fill this process's memory.
    static let maxStandardOutputBytes = 16 * 1024

    private init(tool: Tool, options: [String], host: JumpProbeHost) {
        self.tool = tool
        self.text = ([tool.rawValue] + options + [PosixQuoting.singleQuoted(host.text)])
            .joined(separator: " ")
    }

    /// `getent hosts`: the name as the jump host's own resolver answers it —
    /// `/etc/hosts`, DNS, whatever its NSS says — which is what its
    /// `direct-tcpip` connect to the target used.
    static func resolve(_ host: JumpProbeHost) -> JumpProbeCommand {
        JumpProbeCommand(tool: .getent, options: ["hosts"], host: host)
    }

    /// Which option gives `ping` its overall deadline.
    ///
    /// **Why a deadline at all** (fix round 1 of Task 7): without one, a
    /// `ping -c 3` that heard fewer than three answers lingers about ten
    /// seconds after its last request — measured on the rig: BusyBox's
    /// `ping -c 3` to a silent address took 12.1 s — so its run overran the
    /// 5 s step budget and a "2/3 replies" never reached the row, which
    /// read as silence instead.
    ///
    /// **Why no count** beside it: BusyBox ignores `-w` once `-c` is given
    /// (`ping -c 3 -w 4` took 12.1 s there as well; `ping -w 4` took 4.1 s).
    /// A deadline alone makes iputils and BusyBox send one request a second
    /// until it passes, then print their statistics — `-w 4` sent four.
    enum PingDeadline: Sendable, Equatable {
        /// `-w <seconds>`: iputils' and BusyBox's deadline (their own help,
        /// read 2026-09-18). Tried first.
        case w
        /// `-t <seconds>`: BSD's "timeout, in seconds, before ping exits"
        /// (macOS `ping(8)`). Tried only when `-w` was refused as a usage
        /// error — never first, because to iputils and BusyBox `-t` is the
        /// TTL, and `-t 3` would silently stop the requests three hops out.
        case t
    }

    /// Echo requests until `deadlineSeconds` have passed
    /// (`pingDeadlineSeconds(budget:)`), with the deadline option `flag`
    /// names. No wait option (`-W`): it is milliseconds per packet to BSD
    /// and seconds to BusyBox and iputils, so one value is wrong on one of
    /// them.
    static func ping(
        _ host: JumpProbeHost, deadlineSeconds: Int, flag: PingDeadline
    ) -> JumpProbeCommand {
        let option = flag == .w ? "-w" : "-t"
        return JumpProbeCommand(
            tool: .ping, options: [option, String(deadlineSeconds)], host: host)
    }

    /// BSD `ping`'s answer to an option it does not know: `EX_USAGE`, 64,
    /// with the usage on standard error and nothing on standard output
    /// (macOS 26.6.2's `ping -w`, recorded 2026-09-18). The one answer
    /// after which `ping` is tried again with `PingDeadline.t`.
    static let usageExitStatus = 64

    /// The deadline `ping` gets inside a step budget: three seconds — the
    /// three requests the probe has always sent, one a second — or, in a
    /// budget too small for that, the budget less two seconds, whole
    /// seconds, at least one. The two seconds are the exec round trip and
    /// the tool's own last second — BusyBox's `-w 3` returned after 3.08 to
    /// 3.11 s over SSH on the rig — so the tool prints its statistics before
    /// the budget cuts it. Capped rather than grown with the budget: a wider
    /// budget is room for a slow machine, not a reason to ping for longer
    /// (a 20 s budget would otherwise send eighteen, as it did in the rig
    /// suite before the cap).
    static func pingDeadlineSeconds(budget: Duration) -> Int {
        min(3, max(1, Int(budget.seconds) - 2))
    }

    /// Numeric (`-n`: no reverse lookups, and addresses a reader can check),
    /// one probe per hop (`-q 1`), and one second per silent hop (`-w 1`) —
    /// the local trace's own `NetworkTrace.hopTimeout`. BusyBox's and BSD's
    /// `traceroute` both take `-w` in seconds, with defaults of 3 s and 5 s
    /// (their own help and manual, read 2026-09-18, and both ran with
    /// `-w 1` here); the Linux `traceroute` package is not on any machine
    /// available here and was not measured. At 3 to 5 s a silent hop, the
    /// trace's budget would run out a handful of hops in.
    ///
    /// And at most `maxHops` hops (`-m`, `tracerouteMaxHops(budget:)`), so
    /// that a walk into silence ends inside the trace's budget with the hops
    /// it measured and a hop-limit marker, rather than being cut off by the
    /// budget.
    static func traceroute(_ host: JumpProbeHost, maxHops: Int) -> JumpProbeCommand {
        JumpProbeCommand(
            tool: .traceroute,
            options: ["-n", "-q", "1", "-w", "1", "-m", String(maxHops)], host: host)
    }

    /// The hop limit that keeps a `traceroute -q 1 -w 1` inside `budget`:
    /// one second per hop is its worst case where hops are probed one after
    /// another (BusyBox, BSD), so the whole seconds of the budget less three
    /// — the exec round trip, the tool's own name lookup, and the last hop's
    /// second — and never more than 30, the local trace's own limit
    /// (`NetworkTrace.defaultMaxHops`; also the Linux and BusyBox tools'
    /// default, where BSD's is 64). 17 inside the default 20 s budget.
    ///
    /// The one source of the limit: the command is built with it, and the
    /// reader is handed the same value (`JumpProbeReading.traceroute(_:target:
    /// maxHops:completion:)`) — no reader assumes any tool's default.
    static func tracerouteMaxHops(budget: Duration) -> Int {
        min(NetworkTrace.defaultMaxHops, max(1, Int(budget.seconds) - 3))
    }

    /// The fallback where `traceroute` is missing or gave no answer:
    /// iputils' `tracepath` needs no raw socket, which is exactly what a
    /// login that may not run `traceroute` lacks.
    static func tracepath(_ host: JumpProbeHost) -> JumpProbeCommand {
        JumpProbeCommand(tool: .tracepath, options: ["-n"], host: host)
    }
}

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

// MARK: - The three steps

extension DiagnosticJumpStep {
    /// The jump host's own resolver, asked for the target's name.
    ///
    /// Beside `target.tcpViaJump` in the `.tcp` phase — so under `.ping` as
    /// well as `.complete` — because that step's one refusal,
    /// `jumpCouldNotConnect`, cannot say whether the name failed there or the
    /// port; this row can. `failed` only for the one answer that is a finding
    /// about the name, `getent`'s exit status 2. Nothing to salvage when the
    /// budget cuts it: a half-printed address table is no answer.
    static let resolveOnJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetResolveOnJump, phase: .tcp
    ) { context, timer in
        guard let host = JumpProbeHost(context.target.host) else {
            return timer.finish(.unavailable(DiagnosticReason.jumpProbeHostRefused), "")
        }
        guard host.kind == .name else {
            return timer.finish(.skipped(DiagnosticReason.targetIsAnAddress), "")
        }
        let output: RemoteCommandOutput
        switch await JumpProbeRun.run(.resolve(host), in: context) {
        case .answered(let answered): output = answered
        case .overran(let detail):
            return timer.finish(.unavailable(DiagnosticReason.jumpResolveUnreadable), detail)
        case .notRun(let detail):
            return timer.finish(.unavailable(DiagnosticReason.jumpExecRefused), detail)
        }
        if output.exitStatus == JumpProbeRun.commandNotFound {
            return timer.finish(.unavailable(DiagnosticReason.jumpHasNoGetent), "")
        }
        if output.exitStatus == 0,
            let addresses = JumpProbeReading.addresses(inGetentOutput: output.standardOutput)
        {
            let detail = addresses.map { "\($0.family.rawValue) \($0.text)" }
                .joined(separator: ", ")
            return timer.finish(.ok, detail)
        }
        // `getent`'s own status for "not found in the database". Only with
        // nothing printed: a status 2 above an answer is not that answer.
        if output.exitStatus == 2,
            output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return timer.finish(.failed(DiagnosticReason.jumpCouldNotResolve), "")
        }
        return timer.finish(
            .unavailable(DiagnosticReason.jumpResolveUnreadable),
            JumpProbeRun.exitDetail(.getent, output.exitStatus))
    }

    /// Echo requests from the jump host until a deadline inside the step
    /// budget (`JumpProbeCommand.pingDeadlineSeconds(budget:)`): `-w`
    /// first, and `-t` only when `-w` came back as a usage error — BSD's
    /// `ping`, which has no `-w` (`JumpProbeCommand.PingDeadline`).
    ///
    /// Chosen by trying rather than by asking the jump host what it runs:
    /// the tool's own answer is the one thing that says which options it
    /// takes, a system name would not (a Linux jump host may run BusyBox's
    /// `ping` or iputils', and `uname` says nothing about which), and only a
    /// BSD jump host pays the second exec.
    ///
    /// Any reply is `ok` — the target answers from there, and a lost packet
    /// is in the detail as `2/3 replies`. Silence is `timedOut`, as the local
    /// echo reports it: a firewall that drops ICMP says nothing about whether
    /// the target serves. The detail line is the local echo's shape, with
    /// the tool's own figures. Cut by the budget, it reports the replies it
    /// had printed (`cut`).
    static let icmpFromJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetICMPFromJump, phase: .icmp,
        cut: { context, timer in
            guard let (tool, printed) = context.transcript.current, tool == .ping,
                let host = JumpProbeHost(context.target.host)
            else { return timer.finish(.timedOut, "") }
            if let summary = JumpProbeReading.ping(printed) {
                return JumpProbeRun.pingRow(summary, host: host, timer: timer)
            }
            guard let partial = JumpProbeReading.pingReplies(inPartialOutput: printed),
                !partial.replies.isEmpty
            else { return timer.finish(.timedOut, "") }
            let times = partial.replies
            let average = times.reduce(Duration.zero, +) / times.count
            return timer.finish(
                .ok,
                "\(partial.address ?? host.text) \(times.count) replies before the step's "
                    + "budget ran out, min \(DurationText.milliseconds(times.min() ?? .zero)), "
                    + "avg \(DurationText.milliseconds(average)), "
                    + "max \(DurationText.milliseconds(times.max() ?? .zero))")
        }
    ) { context, timer in
        guard let host = JumpProbeHost(context.target.host) else {
            return timer.finish(.unavailable(DiagnosticReason.jumpProbeHostRefused), "")
        }
        let seconds = JumpProbeCommand.pingDeadlineSeconds(budget: context.budget)
        var output = RemoteCommandOutput(standardOutput: "", exitStatus: 0)
        for flag in [JumpProbeCommand.PingDeadline.w, .t] {
            let command = JumpProbeCommand.ping(host, deadlineSeconds: seconds, flag: flag)
            switch await JumpProbeRun.run(command, in: context) {
            case .answered(let answered): output = answered
            case .overran(let detail):
                return timer.finish(.unavailable(DiagnosticReason.jumpPingUnreadable), detail)
            case .notRun(let detail):
                return timer.finish(.unavailable(DiagnosticReason.jumpExecRefused), detail)
            }
            let refusedTheOption =
                output.exitStatus == JumpProbeCommand.usageExitStatus
                && output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            if !refusedTheOption { break }
        }
        if output.exitStatus == JumpProbeRun.commandNotFound {
            return timer.finish(.unavailable(DiagnosticReason.jumpHasNoPing), "")
        }
        guard let summary = JumpProbeReading.ping(output.standardOutput) else {
            return timer.finish(
                .unavailable(DiagnosticReason.jumpPingUnreadable),
                JumpProbeRun.exitDetail(.ping, output.exitStatus))
        }
        return JumpProbeRun.pingRow(summary, host: host, timer: timer)
    }

    /// The path from the jump host to the target: `traceroute`, limited to
    /// the hops its budget can hold (`JumpProbeCommand
    /// .tracerouteMaxHops(budget:)`), and `tracepath` when `traceroute` is
    /// missing or gave no answer this can read. Raced against the TRACE
    /// budget (`Budget.trace`), as `jump.trace` is. Its row is
    /// `jump.trace`'s: the same outcome rules, the same hop table and
    /// markers (`ConnectionDiagnostics.traceOutcome`, `traceTable`,
    /// `traceDetail`), and a first detail line naming the tool. Cut by the
    /// budget, it reports the hops it had printed, marked as stopped by the
    /// budget (`cut`).
    ///
    /// In the `.trace` phase — so the `.trace` scope now dials the jump
    /// host, where before it measured only from this Mac
    /// (`ConnectionDiagnostics.needsJumpConnection(_:)`).
    static let traceFromJump = DiagnosticJumpStep(
        id: DiagnosticStepID.targetTraceFromJump, phase: .trace, budget: .trace,
        cut: { context, timer in
            guard let (tool, printed) = context.transcript.current,
                let host = JumpProbeHost(context.target.host),
                let outcome = JumpProbeRun.readTrace(
                    printed, by: tool, target: host,
                    maxHops: JumpProbeCommand.tracerouteMaxHops(budget: context.budget),
                    completion: .cut)
            else { return timer.finish(.timedOut, "") }
            return JumpProbeRun.traceRow(outcome, by: tool, timer: timer)
        }
    ) { context, timer in
        guard let host = JumpProbeHost(context.target.host) else {
            return timer.finish(.unavailable(DiagnosticReason.jumpProbeHostRefused), "")
        }
        var attempts: [String] = []
        var anyToolThere = false
        let maxHops = JumpProbeCommand.tracerouteMaxHops(budget: context.budget)
        for command in [JumpProbeCommand.traceroute(host, maxHops: maxHops), .tracepath(host)] {
            let output: RemoteCommandOutput
            switch await JumpProbeRun.run(command, in: context) {
            case .answered(let answered): output = answered
            case .overran(let detail):
                // A tool that printed too much is a tool that is there.
                anyToolThere = true
                attempts.append(detail)
                continue
            case .notRun(let detail):
                // A jump host that runs no command runs neither.
                return timer.finish(.unavailable(DiagnosticReason.jumpExecRefused), detail)
            }
            if let outcome = JumpProbeRun.readTrace(
                output.standardOutput, by: command.tool, target: host, maxHops: maxHops,
                completion: .exited(output.exitStatus))
            {
                return JumpProbeRun.traceRow(outcome, by: command.tool, timer: timer)
            }
            if output.exitStatus != JumpProbeRun.commandNotFound { anyToolThere = true }
            attempts.append(JumpProbeRun.exitDetail(command.tool, output.exitStatus))
        }
        return timer.finish(
            .unavailable(
                anyToolThere
                    ? DiagnosticReason.jumpTraceUnreadable : DiagnosticReason.jumpHasNoTraceTool),
            attempts.joined(separator: "; "))
    }
}

/// Running one probe command over the jump connection, what its failure to
/// answer means for a row, and the rows two steps share between finishing
/// and being cut — stated once for the three steps above.
private enum JumpProbeRun {
    /// POSIX shells' exit status for a command they could not find, whatever
    /// their wording (`ChecksumCommandExitFailure` measures the same).
    static let commandNotFound = 127

    /// What running a command came to, each with the detail its row
    /// carries.
    enum Result {
        /// The command ran; its output and exit status are there to read.
        case answered(RemoteCommandOutput)
        /// The command ran and printed past `JumpProbeCommand
        /// .maxStandardOutputBytes`: the tool is there, and gave no answer
        /// this can read. The step's own "unreadable" reason.
        case overran(String)
        /// The jump host did not run it — it refused the channel or the
        /// `exec` request, or the connection failed under it.
        /// `jumpExecRefused`, and not the tool's fault or the target's.
        case notRun(String)
    }

    /// Runs `command` over the step's connection, its output going into the
    /// step's transcript as it arrives.
    static func run(
        _ command: JumpProbeCommand, in context: DiagnosticJumpStep.Context
    ) async -> Result {
        context.transcript.begin(command.tool)
        do {
            return .answered(try await context.connection.run(command, into: context.transcript))
        } catch is RemoteCommandOutputTooLarge {
            return .overran(
                "\(command.tool.rawValue) printed more than "
                    + "\(JumpProbeCommand.maxStandardOutputBytes) bytes")
        } catch {
            // The report's one rendering of an error (`DialSupport
            // .reason(for:)`), never the error's own text.
            return .notRun(DialSupport.reason(for: error))
        }
    }

    static func exitDetail(_ tool: JumpProbeCommand.Tool, _ status: Int) -> String {
        "\(tool.rawValue) exited with status \(status)"
    }

    /// A ping's row from its statistics: `ok` on any reply, `timedOut` on
    /// none.
    static func pingRow(
        _ summary: JumpPingSummary, host: JumpProbeHost, timer: DiagnosticStepTimer
    ) -> DiagnosticStep {
        var detail = "\(summary.address ?? host.text) \(summary.received)/\(summary.sent) replies"
        if let low = summary.min, let average = summary.average, let high = summary.max {
            detail += ", min \(DurationText.milliseconds(low))"
                + ", avg \(DurationText.milliseconds(average))"
                + ", max \(DurationText.milliseconds(high))"
        }
        return timer.finish(summary.received > 0 ? .ok : .timedOut, detail)
    }

    /// The trace tool's output read by its own reader; `nil` for a tool that
    /// is not a trace tool.
    static func readTrace(
        _ output: String, by tool: JumpProbeCommand.Tool, target: JumpProbeHost,
        maxHops: Int, completion: JumpProbeCompletion
    ) -> NetworkTraceOutcome? {
        switch tool {
        case .traceroute:
            return JumpProbeReading.traceroute(
                output, target: target, maxHops: maxHops, completion: completion)
        case .tracepath:
            return JumpProbeReading.tracepath(output, target: target, completion: completion)
        case .getent, .ping:
            return nil
        }
    }

    /// A trace's row, `jump.trace`'s own shape, with the tool named first.
    static func traceRow(
        _ outcome: NetworkTraceOutcome, by tool: JumpProbeCommand.Tool,
        timer: DiagnosticStepTimer
    ) -> DiagnosticStep {
        let marker = ConnectionDiagnostics.traceDetail(outcome)
        let detail = (["measured with \(tool.rawValue)"] + [marker])
            .filter { !$0.isEmpty }.joined(separator: "; ")
        return timer.finish(
            ConnectionDiagnostics.traceOutcome(outcome), detail,
            table: ConnectionDiagnostics.traceTable(outcome))
    }
}
