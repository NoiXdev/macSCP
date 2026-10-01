import Darwin

// Everything a command line for a jump-host probe is built from: the target
// host a command may be handed, and the command lines themselves. Split out of
// `JumpProbes.swift` on 2026-10-01 with its text unchanged; the rule these two
// types serve — what reaches the jump host's shell, and when — is stated once,
// in `JumpProbes.swift`, beside the three steps that run them.

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
/// 2026-09-18 review of `JumpProbes.swift`, which held this type until the
/// split of 2026-10-01) — and only the set, which has no `%`, refuses them.
/// The same check admits the addresses the readers in
/// `JumpProbeReading.swift` copy out of tool output, so it guards the
/// report's rows too. A host name is at most 253 characters of dot-separated
/// labels, each 1 to 63 ASCII letters, digits or hyphens, neither starting
/// nor ending with a hyphen; no empty label, so no leading, trailing or
/// doubled dot. Compared on Unicode scalars and ASCII ranges, never
/// `Character.isLetter`, which would let `é` in.
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
