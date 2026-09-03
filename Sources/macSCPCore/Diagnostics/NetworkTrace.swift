import Darwin
import Foundation

/// What answered at one hop of a trace.
enum TraceHopOutcome: Sendable, Equatable {
    /// A router on the path answered ICMP time-exceeded (type 11): the probe
    /// reached this address and no further.
    case forwarded(address: String, rtt: Duration)
    /// Something answered ICMP destination-unreachable (type 3). `code`
    /// `NetworkTrace.portUnreachableCode` from the destination itself is the
    /// ordinary end of a trace — nothing listens on the probe port, which is
    /// how traceroute has always known it arrived. Any other code, or any
    /// other source, is a refusal somewhere on the way, and it ends the trace
    /// as well.
    case unreachable(address: String, rtt: Duration, code: UInt8)
    /// Nothing answered inside this hop's deadline — the `*` row. It does NOT
    /// end the trace: routers that decline to send ICMP errors are ordinary,
    /// and the hops past them are still worth measuring.
    case timedOut
}

/// One hop's row.
struct NetworkTraceHop: Sendable, Equatable {
    /// The TTL the probe carried, which is the hop's number.
    let ttl: Int
    let outcome: TraceHopOutcome

    /// The row as the report prints it — `1 10.0.0.1 3.4 ms` or `2 *`.
    ///
    /// Composed here rather than at the runner, so the report and the panel
    /// cannot drift into two spellings of the same hop.
    var text: String {
        switch outcome {
        case .forwarded(let address, let rtt):
            return "\(ttl) \(address) \(DurationText.milliseconds(rtt))"
        case .unreachable(let address, let rtt, let code):
            let reason =
                code == NetworkTrace.portUnreachableCode
                ? "port unreachable" : "unreachable code \(code)"
            return "\(ttl) \(address) \(DurationText.milliseconds(rtt)) \(reason)"
        case .timedOut:
            return "\(ttl) *"
        }
    }
}

/// What a trace run found.
enum NetworkTraceOutcome: Sendable, Equatable {
    /// The hops that were probed, in order, together with the address the
    /// trace was aimed at — carried so `reachedDestination` can be derived
    /// rather than stored beside the hops as a second copy of the same fact.
    case measured(hops: [NetworkTraceHop], destination: String)
    /// This machine could not trace at all: the socket was refused, there is
    /// no route, or the address is not one this step can probe. About the
    /// local end, never the server.
    case unavailable(String)

    var hops: [NetworkTraceHop] {
        switch self {
        case .measured(let hops, _): return hops
        case .unavailable: return []
        }
    }

    /// Whether the trace ended because the DESTINATION answered.
    ///
    /// The test is the answering address, not the ICMP code: the destination
    /// is the destination because it is the address the trace was aimed at,
    /// and a refusal from some router in between carries a type-3 code too. A
    /// source that does not match is reported as what it is — an unreachable
    /// row — and never as an arrival.
    var reachedDestination: Bool {
        guard case .measured(let hops, let destination) = self,
            case .unreachable(let address, _, _) = hops.last?.outcome
        else { return false }
        return address == destination
    }
}

/// One ICMP error message that answered a trace probe.
struct TraceAnswer: Sendable, Equatable {
    /// `11` (time exceeded) or `3` (destination unreachable).
    let type: UInt8
    let code: UInt8
    /// The answering address in numeric presentation form.
    let source: String
    let rtt: Duration
}

/// An IPv4 network trace on UNPRIVILEGED sockets, off the cooperative pool and
/// under a deadline.
///
/// One UDP socket per hop carrying `IP_TTL`, and one ICMP `SOCK_DGRAM` socket
/// receiving the errors they provoke. No raw socket, no privileged helper, no
/// entitlement — which is the whole reason this step can ship. Every
/// descriptor is closed in a `defer` on every path.
///
/// Built from three measurements:
///
/// 1. **The ICMP DGRAM socket receives time-exceeded** (design §5 verdict (b),
///    macOS 26.6.2): a UDP datagram to `192.0.2.1:33434` with `IP_TTL = 1`
///    produced ICMP type 11 code 0 there after 3.3–4.0 ms, 73 bytes with the
///    IP header, quoting the original datagram. The UDP socket's own
///    `SO_ERROR` said `EHOSTUNREACH` — which does not distinguish
///    time-exceeded from unreachable and carries no hop address, so the ICMP
///    socket is what identifies a hop and the UDP socket is only the probe.
/// 2. **The destination answers port-unreachable** (measured 2026-09-03): the
///    same datagram to `127.0.0.1:33434` produced type 3 code 3 from
///    `127.0.0.1` after 0.087 ms, 56 bytes, quoting the original IP header
///    plus the first eight bytes of the UDP datagram — which is exactly where
///    both port numbers sit.
/// 3. **The socket is not demultiplexed** (measured 2026-09-03 for echo
///    replies, `ICMPEcho`'s finding 4, and it holds for error messages too).
///    Every ICMP message the machine receives is handed to every unprivileged
///    ICMP DGRAM socket, so an answer counts only when the datagram it quotes
///    is this probe's own: the destination port (this hop's, and no other
///    hop's) AND the source port the kernel assigned this probe socket (this
///    trace's, and no other trace's — including `ICMPSpikeTests` running
///    alongside, which aims at the same destination port).
///
/// IPv4 only, and it says so rather than guessing: design §5 verdict (c) could
/// not measure the IPv6 path, because the machine that measured everything
/// else had no global IPv6 route and nothing was sent.
enum NetworkTrace {
    /// How far the trace walks before giving up. Traceroute's own default, and
    /// the step's shared deadline usually stops it long before this does.
    static let defaultMaxHops = 30

    /// The longest ONE hop waits for its answer. The step's own budget caps
    /// the walk as a whole; this caps a single hop inside it, so a run of
    /// silent routers cannot each spend the whole step.
    static let hopTimeout = Duration.seconds(1)

    /// The first hop's destination port. Traceroute's base, chosen for the
    /// same reason: nothing listens there, so the destination answers with
    /// port-unreachable instead of accepting the datagram.
    static let basePort: UInt16 = 33434

    static let timeExceededType: UInt8 = 11
    static let destinationUnreachableType: UInt8 = 3
    static let portUnreachableCode: UInt8 = 3

    /// The sentence this step reports for an address it cannot probe.
    ///
    /// A symbol rather than a spelling: the test compares against it and Task
    /// 4 maps it to `diagnostics.reason.traceNeedsIPv4`, so a reworded
    /// sentence has one place to change rather than three.
    static let notIPv4Reason = "the network trace needs an IPv4 address"

    /// The sentence the runner reports for a host that resolves only to IPv6.
    ///
    /// Not "failed" and not "no route": the IPv6 trace was never measured at
    /// all (design §5 verdict (c) — the measuring machine had no global IPv6
    /// route, and nothing was sent), and a row that claimed a failure would be
    /// reporting an observation nobody made.
    static let ipv6UnmeasuredReason =
        "IPv6 trace unmeasured: no route on the machine that measured it"

    /// The destination port hop `hop` probes.
    ///
    /// Distinct per hop so a late answer to hop 1 cannot be counted for hop 2,
    /// and derived here so a test names the port by asking rather than by
    /// spelling `33434` a second time. Hop 1 gets the base itself, which is
    /// what makes the destination case reproducible against
    /// `127.0.0.1:33434`.
    static func port(forHop hop: Int) -> UInt16 {
        basePort &+ UInt16(truncatingIfNeeded: max(0, hop - 1))
    }

    /// Traces one address. Never throws: everything the kernel refuses comes
    /// back as `.unavailable` carrying `strerror`'s own sentence.
    ///
    /// - Parameter timeout: the whole walk's budget, which is the step's. With
    ///   30 hops at a second each the hop deadlines alone would allow far
    ///   more, so this is what actually bounds a trace across a slow path.
    static func trace(
        address: ResolvedAddress, maxHops: Int = defaultMaxHops, timeout: Duration
    ) async -> NetworkTraceOutcome {
        // The outer deadline carries the same 250 ms margin `ICMPEcho` gives
        // its own, and for the same reason: at exactly `timeout` it could beat
        // the inner loop to hops the inner loop already measured, and
        // `BlockingProbe` returning `nil` would throw them away microseconds
        // before they arrived.
        let outcome = await BlockingProbe.run(
            label: "dev.noidee.macscp.diagnostics.trace",
            timeout: timeout + .milliseconds(250)
        ) {
            walk(
                address: address, maxHops: maxHops,
                deadline: ContinuousClock().now.advanced(by: timeout))
        }
        return outcome ?? .measured(hops: [], destination: address.text)
    }

    // MARK: - The socket sequence

    /// Blocking. Only ever called on `BlockingProbe`'s private queue.
    private static func walk(
        address: ResolvedAddress, maxHops: Int, deadline: ContinuousClock.Instant
    ) -> NetworkTraceOutcome {
        // The family the BYTES declare, not the record's label: what is opened
        // has to be what is dialled, and the label is a second copy of that
        // fact (`ProbeSocketAddress.family`).
        guard address.socketAddress.family == AF_INET else { return .unavailable(notIPv4Reason) }

        // The listening socket must exist before the first probe goes out, and
        // it is ONE socket for the whole walk: a socket opened per hop could
        // miss an answer provoked by the hop before it.
        let icmp = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_ICMP))
        let icmpErrno = errno
        guard icmp >= 0 else { return .unavailable(String(cString: strerror(icmpErrno))) }
        defer { close(icmp) }

        let clock = ContinuousClock()
        var hops: [NetworkTraceHop] = []
        for ttl in 1...max(1, maxHops) {
            guard clock.now < deadline else { break }
            let result = probe(
                ttl: ttl, destination: address.socketAddress, icmp: icmp, deadline: deadline)
            switch result {
            case .refused(let reason):
                // A refusal on the FIRST hop is a statement about this machine
                // (no socket, no route) and gets the local-end outcome. After
                // a hop has been measured it is not: the walk has findings,
                // and they are reported.
                guard hops.isEmpty else {
                    return .measured(hops: hops, destination: address.text)
                }
                return .unavailable(reason)
            case .measured(let outcome):
                hops.append(NetworkTraceHop(ttl: ttl, outcome: outcome))
                // Only an ICMP unreachable ends the walk early. A `*` does
                // not: a router that declines to answer is ordinary, and the
                // hops past it still matter.
                if case .unreachable = outcome {
                    return .measured(hops: hops, destination: address.text)
                }
            }
        }
        return .measured(hops: hops, destination: address.text)
    }

    /// One hop: a UDP socket of its own, carrying this hop's TTL and aimed at
    /// this hop's port, and then the wait for whatever ICMP error it provokes.
    ///
    /// Blocking. Only ever called on `BlockingProbe`'s private queue.
    private static func probe(
        ttl: Int, destination: ProbeSocketAddress, icmp: Int32,
        deadline: ContinuousClock.Instant
    ) -> HopProbeResult {
        let udp = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        let socketErrno = errno
        guard udp >= 0 else { return .refused(String(cString: strerror(socketErrno))) }
        defer { close(udp) }

        var limit = Int32(ttl)
        let option = setsockopt(
            udp, Int32(IPPROTO_IP), IP_TTL, &limit, socklen_t(MemoryLayout<Int32>.size))
        let optionErrno = errno
        guard option == 0 else { return .refused(String(cString: strerror(optionErrno))) }

        // `connect` on an unconnected UDP socket puts no packet on the wire —
        // it consults the routing table and fixes the peer — and it is also
        // what assigns the source port this hop is matched by.
        let port = port(forHop: ttl)
        let connected = withDestination(destination, port: port) { pointer, length in
            connect(udp, pointer, length)
        }
        let connectErrno = errno
        guard connected == 0 else { return .refused(String(cString: strerror(connectErrno))) }
        guard let sourcePort = localPort(of: udp) else {
            return .refused("the probe socket reports no source port")
        }

        let started = ContinuousClock().now
        let written = probePayload.withUnsafeBytes { buffer in
            send(udp, buffer.baseAddress, buffer.count, 0)
        }
        let sendErrno = errno
        guard written >= 0 else { return .refused(String(cString: strerror(sendErrno))) }

        guard
            let answer = waitForAnswer(
                descriptor: icmp, sourcePort: sourcePort, destinationPort: port,
                started: started,
                deadline: min(started.advanced(by: hopTimeout), deadline))
        else { return .measured(.timedOut) }

        guard answer.type == timeExceededType else {
            return .measured(
                .unreachable(address: answer.source, rtt: answer.rtt, code: answer.code))
        }
        return .measured(.forwarded(address: answer.source, rtt: answer.rtt))
    }

    /// How one hop's probe ended: with a hop row, or with the kernel refusing
    /// to send it at all. A type rather than `Result`, because the failure
    /// side is `strerror`'s sentence and `String` is not an `Error`.
    private enum HopProbeResult {
        case measured(TraceHopOutcome)
        case refused(String)
    }

    /// What every probe datagram carries. ASCII, and it names the app so
    /// anyone reading a packet capture knows what sent it. Nothing MATCHES on
    /// it — the quoted port pair does that, and a router is only obliged to
    /// quote eight bytes of the datagram, which is the UDP header and none of
    /// this.
    private static let probePayload = Array("macSCP-diagnostics-trace".utf8)

    /// Polls for what is left of this hop's budget and returns the first ICMP
    /// error message that quotes THIS probe's datagram.
    ///
    /// Anything else is skipped and the loop keeps waiting rather than
    /// returning: the socket is handed every ICMP message the machine receives
    /// (see the type's finding 3), so a single-shot read would answer with
    /// another socket's — or another process's — message, and give this hop an
    /// address and a round-trip time it never measured.
    ///
    /// Both quoted ports are required. The destination port separates this hop
    /// from the trace's other hops; the source port, which the kernel assigns
    /// per probe socket, separates this trace from every other trace on the
    /// machine — they all aim at 33434 and up.
    static func waitForAnswer(
        descriptor: Int32, sourcePort: UInt16, destinationPort: UInt16,
        started: ContinuousClock.Instant, deadline: ContinuousClock.Instant
    ) -> TraceAnswer? {
        let clock = ContinuousClock()
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return nil }
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(
                &watched, 1, Int32(max(1, min(remaining.milliseconds.rounded(), 60_000))))
            let pollErrno = errno
            if ready < 0 {
                if pollErrno == EINTR { continue }
                return nil
            }
            if ready == 0 { return nil }

            var buffer = [UInt8](repeating: 0, count: 2048)
            var source = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    buffer.withUnsafeMutableBytes { raw in
                        recvfrom(descriptor, raw.baseAddress, raw.count, 0, address, &sourceLength)
                    }
                }
            }
            let receiveErrno = errno
            if count < 0, receiveErrno == EINTR { continue }
            guard count > 0 else { return nil }
            let elapsed = started.duration(to: clock.now)
            guard
                let message = ICMPErrorMessage(bytes: buffer, count: count),
                message.type == timeExceededType || message.type == destinationUnreachableType,
                message.quotedSourcePort == sourcePort,
                message.quotedDestinationPort == destinationPort
            else { continue }
            return TraceAnswer(
                type: message.type, code: message.code,
                source: text(of: source, length: sourceLength), rtt: elapsed)
        }
    }

    // MARK: - The packet

    /// An ICMP error message and the two port numbers of the UDP datagram it
    /// quotes.
    ///
    /// Every offset is derived from a length field that was itself checked
    /// against `count` — what `recvfrom` actually filled — because the receive
    /// buffer is reused at full length and its tail is stale zeroes. A parser
    /// that indexed past `count` would read them and call the result a match.
    private struct ICMPErrorMessage {
        let type: UInt8
        let code: UInt8
        let quotedSourcePort: UInt16
        let quotedDestinationPort: UInt16

        /// The IP protocol number of the quoted datagram this parser accepts.
        /// A quoted TCP or ICMP datagram has no UDP header to read, and its
        /// bytes at the same offsets would parse into port numbers that mean
        /// something else entirely.
        private static let udpProtocol: UInt8 = 17

        init?(bytes: [UInt8], count: Int) {
            // The IPv4 ICMP socket delivers the IP header too (measured: 56
            // and 68 bytes beginning `45 …`). Detected rather than assumed, so
            // a kernel that changes its mind is read correctly either way —
            // and the detection cannot misfire, since an ICMP type of 3 or 11
            // has a first nibble of 0.
            var offset = 0
            if count > 0, bytes[0] >> 4 == 4 {
                let headerLength = Int(bytes[0] & 0x0F) * 4
                guard headerLength >= 20, count > headerLength else { return nil }
                offset = headerLength
            }
            // The ICMP header: type, code, checksum, and four bytes this
            // message class leaves unused. The quoted datagram follows.
            guard count >= offset + 8 else { return nil }
            type = bytes[offset]
            code = bytes[offset + 1]

            let quote = offset + 8
            guard count > quote, bytes[quote] >> 4 == 4 else { return nil }
            let quotedHeaderLength = Int(bytes[quote] & 0x0F) * 4
            guard quotedHeaderLength >= 20, count >= quote + quotedHeaderLength else {
                return nil
            }
            // Byte 9 of an IPv4 header is the protocol field.
            guard bytes[quote + 9] == Self.udpProtocol else { return nil }

            // RFC 792 obliges the sender to quote the original header plus 64
            // bits of its data — exactly the UDP header — so these four bytes
            // are the most a trace may ever rely on, and they are all it needs.
            let udp = quote + quotedHeaderLength
            guard count >= udp + 4 else { return nil }
            quotedSourcePort = UInt16(bytes[udp]) << 8 | UInt16(bytes[udp + 1])
            quotedDestinationPort = UInt16(bytes[udp + 2]) << 8 | UInt16(bytes[udp + 3])
        }
    }

    // MARK: - Addresses

    /// Calls `body` with this address and `port` substituted into it.
    ///
    /// The port HAS to be substituted rather than passed through: an address a
    /// diagnosis carries can have port 0 (the resolve step is free not to set
    /// one), and every hop needs a port of its own regardless. The same lesson
    /// `ICMPEcho.routeProbePort` records, where port 0 made `connect` report a
    /// routable address as routeless.
    ///
    /// Only ever called after the caller has established `AF_INET`, which is
    /// what makes the rebind to `sockaddr_in` sound.
    private static func withDestination<R>(
        _ address: ProbeSocketAddress, port: UInt16,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R {
        address.withSockaddr { pointer, length in
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { destination in
                destination.copyMemory(
                    from: UnsafeRawBufferPointer(
                        start: UnsafeRawPointer(pointer),
                        count: min(Int(length), destination.count)))
            }
            return withUnsafeMutablePointer(to: &storage) { mutable in
                mutable.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_port = port.bigEndian
                }
                return mutable.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, length)
                }
            }
        }
    }

    /// The source port `connect` assigned this socket — half of what makes an
    /// ICMP error THIS probe's rather than merely this machine's.
    private static func localPort(of descriptor: Int32) -> UInt16? {
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = UInt16(bigEndian: storage.sin_port)
        return port == 0 ? nil : port
    }

    /// The numeric presentation form of an answering address — `getnameinfo`
    /// with `NI_NUMERICHOST`, the same spelling `HostResolver` and `ICMPEcho`
    /// use, so one address prints the same way everywhere in a report.
    private static func text(of storage: sockaddr_storage, length: socklen_t) -> String {
        var copy = storage
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let resolved = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &name, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
            }
        }
        guard resolved == 0 else { return "unknown" }
        return String(
            decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
