import Darwin
import Foundation

/// One echo reply, as it was delivered.
struct ICMPEchoReply: Sendable, Equatable {
    /// `0` (IPv4 echo reply) or `129` (ICMPv6 echo reply).
    ///
    /// Carried rather than assumed, because it is the one field that
    /// separates a reply from this process's own outgoing request: the
    /// ICMPv6 socket receives BOTH (design §5), and they agree on the
    /// identifier, the sequence and the source.
    let type: UInt8
    /// The sequence this reply answers — the field the matcher pins.
    let sequence: UInt16
    /// The identifier AS DELIVERED, which is not necessarily the one that was
    /// sent. macOS 26.6.2 returned it unchanged (design §5), against the
    /// design's own assumption that a DGRAM ICMP socket's echoes are
    /// renumbered; both happen in the wild, so it is reported and never
    /// required.
    let identifier: UInt16
    let rtt: Duration
    /// The source address in numeric presentation form.
    let source: String
}

/// What an echo run found at one address.
enum ICMPEchoOutcome: Sendable, Equatable {
    /// `sent` requests went out and `replies` came back — possibly none,
    /// which is an ordinary answer: ICMP is dropped by ordinary firewalls,
    /// and silence says nothing about whether the service is up.
    case measured(sent: Int, replies: [ICMPEchoReply])
    /// This machine could not send at all: the socket was refused, or there
    /// is no route to the address. About the local end, never the server.
    case unavailable(String)

    var replies: [ICMPEchoReply] {
        switch self {
        case .measured(_, let replies): return replies
        case .unavailable: return []
        }
    }

    var sent: Int {
        switch self {
        case .measured(let sent, _): return sent
        case .unavailable: return 0
        }
    }
}

/// ICMP echo on an UNPRIVILEGED `SOCK_DGRAM` socket, off the cooperative pool
/// and under a deadline.
///
/// Built from the verdicts `Tests/macSCPCoreTests/ICMPSpikeTests.swift`
/// measured on macOS 26.6.2 (design §5), which is also the record of how they
/// were measured. Three of them shape the code here:
///
/// 1. **The identifier may or may not survive.** It came back unchanged on
///    26.6.2; the design had assumed the kernel renumbers it. So the matcher
///    pins the SEQUENCE and merely reports the identifier — code that
///    required a rewrite would be wrong here, code that forbade one would be
///    wrong on the machine the design's assumption came from.
/// 2. **IPv4 hands the IP header up, IPv6 does not.** The IPv4 datagram
///    arrived as 20 + 8 + payload with `version == 4` in its first nibble, so
///    the reader skips `IHL × 4` bytes; the ICMPv6 datagram starts at the
///    ICMP header.
/// 3. **The ICMPv6 socket delivers this process's own type-128 request.** A
///    reader that took the first datagram and called it the reply would time
///    the request's own trip back from `::1`, so the wait filters on type.
///
/// No privileges are needed and none are asked for: `SOCK_DGRAM` rather than
/// `SOCK_RAW` is the whole reason this step can ship. Every socket is closed
/// in a `defer` on every path.
enum ICMPEcho {
    /// How many requests one address gets, and what the report's min/avg/max
    /// are computed over.
    static let defaultProbeCount = 3

    /// The longest one request waits for its answer. The step's own budget
    /// caps the run as a whole; this caps a single probe inside it, so three
    /// probes to a silent host cannot each spend the whole step.
    static let probeTimeout = Duration.seconds(2)

    static let ipv4EchoReply: UInt8 = 0
    static let ipv4EchoRequest: UInt8 = 8
    static let ipv6EchoRequest: UInt8 = 128
    static let ipv6EchoReply: UInt8 = 129

    /// The identifier this process writes into every request it sends.
    ///
    /// A `static let` read from `getpid()` once: the value is only ever
    /// compared against what came back, and a test that wants to say
    /// "unchanged" or "rewritten" reads it here instead of spelling
    /// `getpid()` a second time.
    static let identifier = UInt16(truncatingIfNeeded: getpid())

    /// Echoes one address. Never throws: everything the kernel refuses comes
    /// back as `.unavailable` carrying `strerror`'s own sentence.
    static func probe(
        address: ResolvedAddress, count: Int = defaultProbeCount, timeout: Duration
    ) async -> ICMPEchoOutcome {
        await probeAll(addresses: [address], count: count, timeout: timeout)
            .first?.outcome ?? .measured(sent: 0, replies: [])
    }

    /// Every address in turn, on ONE queue hop and against ONE shared
    /// deadline — the same shape as `TCPPing.probeAll`, and for the same
    /// reason: a host with four addresses may not spend four times the step's
    /// budget.
    static func probeAll(
        addresses: [ResolvedAddress], count: Int = defaultProbeCount, timeout: Duration
    ) async -> [(address: ResolvedAddress, outcome: ICMPEchoOutcome)] {
        // The outer deadline is a backstop for a syscall that overruns, and it
        // is given a margin so it cannot beat the inner loop to an answer the
        // inner loop already has: `BlockingProbe` returning `nil` would throw
        // away real measurements a few microseconds before they arrived.
        let outcome = await BlockingProbe.run(
            label: "dev.noidee.macscp.diagnostics.icmp",
            timeout: timeout + .milliseconds(250)
        ) {
            let deadline = ContinuousClock().now.advanced(by: timeout)
            return addresses.map { address in
                (address, echo(address: address, count: count, deadline: deadline))
            }
        }
        return outcome ?? addresses.map { ($0, .measured(sent: 0, replies: [])) }
    }

    // MARK: - The socket sequence

    /// Blocking. Only ever called on `BlockingProbe`'s private queue.
    private static func echo(
        address: ResolvedAddress, count: Int, deadline: ContinuousClock.Instant
    ) -> ICMPEchoOutcome {
        // The family the BYTES declare, not the one the record is labelled
        // with: what is opened has to match what is dialled.
        let family = address.socketAddress.family
        let isIPv6 = family == AF_INET6

        // No route means nothing to measure and nothing to send. `connect` on
        // an unconnected UDP socket only consults the routing table — it puts
        // no packet on the wire — which is how the spike established that this
        // machine has no global IPv6 route without contacting anything.
        if isIPv6, !hasIPv6Route(to: address) { return .unavailable("no IPv6 route") }

        let descriptor = socket(
            family, SOCK_DGRAM, isIPv6 ? Int32(IPPROTO_ICMPV6) : Int32(IPPROTO_ICMP))
        let socketErrno = errno
        guard descriptor >= 0 else { return .unavailable(String(cString: strerror(socketErrno))) }
        defer { close(descriptor) }

        let requestType = isIPv6 ? ipv6EchoRequest : ipv4EchoRequest
        let replyType = isIPv6 ? ipv6EchoReply : ipv4EchoReply
        let clock = ContinuousClock()
        var replies: [ICMPEchoReply] = []
        var sent = 0

        for index in 0..<count {
            guard clock.now < deadline else { break }
            let sequence = UInt16(truncatingIfNeeded: index + 1)
            // The ICMPv6 checksum covers a pseudo-header the kernel owns, so
            // it is left at zero and the kernel fills it in; the IPv4 one is
            // this side's job.
            let packet = request(
                type: requestType, identifier: identifier, sequence: sequence,
                computeChecksum: !isIPv6)
            let started = clock.now
            let written = address.socketAddress.withSockaddr { pointer, length in
                packet.withUnsafeBytes { buffer in
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, pointer, length)
                }
            }
            let sendErrno = errno
            guard written >= 0 else {
                // A refused send on the FIRST probe is a statement about this
                // machine (no route, no permission) and gets the local-end
                // outcome. After a probe has already gone out it is not: the
                // run has measurements, and they are reported.
                guard sent == 0 else { return .measured(sent: sent, replies: replies) }
                return .unavailable(String(cString: strerror(sendErrno)))
            }
            sent += 1
            if let reply = waitForReply(
                descriptor: descriptor, family: family, replyType: replyType,
                sequence: sequence, started: started,
                deadline: min(started.advanced(by: probeTimeout), deadline))
            {
                replies.append(reply)
            }
        }
        return .measured(sent: sent, replies: replies)
    }

    /// The port the route probe dials.
    ///
    /// A port has to be substituted, not merely passed through: an address a
    /// diagnosis carries can have port 0 (ICMP has no ports, so the resolve
    /// step is free not to set one), and `connect` refuses port 0 with
    /// `EADDRNOTAVAIL` — measured here on 2026-09-03, and it reported `::1`
    /// as routeless. Any nonzero port asks the routing table the same
    /// question; 33434 is traceroute's, the one the spike's probe used.
    private static let routeProbePort: UInt16 = 33434

    /// Whether the routing table has a route to this IPv6 address.
    ///
    /// Sends nothing: `connect` on an unconnected UDP socket only consults
    /// the table. This is how the spike established that its machine had no
    /// global IPv6 route without putting a packet anywhere, and it is why the
    /// step can say "no IPv6 route" instead of waiting out a deadline for an
    /// answer that was never coming.
    private static func hasIPv6Route(to address: ResolvedAddress) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, Int32(IPPROTO_UDP))
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return address.socketAddress.withSockaddr { pointer, length in
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { destination in
                destination.copyMemory(
                    from: UnsafeRawBufferPointer(
                        start: UnsafeRawPointer(pointer),
                        count: min(Int(length), destination.count)))
            }
            return withUnsafeMutablePointer(to: &storage) { mutable in
                mutable.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_port = routeProbePort.bigEndian
                }
                return mutable.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, length)
                } == 0
            }
        }
    }

    /// Polls for what is left of this probe's budget and returns the first
    /// datagram that is an echo REPLY carrying the sequence just sent.
    ///
    /// Anything else is skipped and the loop keeps waiting rather than
    /// returning: on the ICMPv6 socket the very first datagram is normally
    /// this process's own request coming back (design §5), so a single-shot
    /// read would answer with the wrong packet every time.
    ///
    /// The identifier is deliberately NOT part of the match — see the type's
    /// note. Two diagnoses running at once in one process therefore match
    /// only on type and sequence; they are told apart by nothing else, which
    /// is the price of not depending on a field the kernel may rewrite.
    private static func waitForReply(
        descriptor: Int32, family: Int32, replyType: UInt8, sequence: UInt16,
        started: ContinuousClock.Instant, deadline: ContinuousClock.Instant
    ) -> ICMPEchoReply? {
        let clock = ContinuousClock()
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return nil }
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, Int32(max(1, min(remaining.milliseconds.rounded(), 60_000))))
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
            guard count > 0 else { return nil }
            let elapsed = started.duration(to: clock.now)
            guard
                let header = ICMPHeader(bytes: buffer, count: count, family: family),
                header.type == replyType, header.sequence == sequence
            else { continue }
            return ICMPEchoReply(
                type: header.type, sequence: header.sequence, identifier: header.identifier,
                rtt: elapsed, source: text(of: source, length: sourceLength))
        }
    }

    // MARK: - The packet

    private static func request(
        type: UInt8, identifier: UInt16, sequence: UInt16, computeChecksum: Bool
    ) -> [UInt8] {
        var packet: [UInt8] = [type, 0, 0, 0]
        packet.append(UInt8(truncatingIfNeeded: identifier >> 8))
        packet.append(UInt8(truncatingIfNeeded: identifier))
        packet.append(UInt8(truncatingIfNeeded: sequence >> 8))
        packet.append(UInt8(truncatingIfNeeded: sequence))
        packet.append(contentsOf: payload)
        guard computeChecksum else { return packet }
        let checksum = internetChecksum(packet)
        packet[2] = UInt8(truncatingIfNeeded: checksum >> 8)
        packet[3] = UInt8(truncatingIfNeeded: checksum)
        return packet
    }

    /// Something to carry, so the round trip measures a datagram of a
    /// realistic size rather than a bare header. ASCII, and it names the app
    /// so anyone reading a capture knows what sent it.
    private static let payload = Array("macSCP-diagnostics".utf8)

    private static func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// The eight bytes of an echo header, found at whatever offset this
    /// family delivers them.
    private struct ICMPHeader {
        let type: UInt8
        let identifier: UInt16
        let sequence: UInt16

        /// - Parameter count: how many of `bytes` `recvfrom` filled. The
        ///   buffer is reused at full length, so the tail is stale zeroes and
        ///   reading past `count` would parse them.
        init?(bytes: [UInt8], count: Int, family: Int32) {
            var offset = 0
            // The IPv4 socket delivers the IP header too; the IPv6 one does
            // not (design §5). Detected rather than assumed, so a kernel that
            // changes its mind is read correctly either way.
            if family == AF_INET, count > 0, bytes[0] >> 4 == 4 {
                let headerLength = Int(bytes[0] & 0x0F) * 4
                guard headerLength >= 20, count > headerLength else { return nil }
                offset = headerLength
            }
            guard count >= offset + 8 else { return nil }
            type = bytes[offset]
            identifier = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
            sequence = UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        }
    }

    /// The numeric presentation form of a source address — `getnameinfo` with
    /// `NI_NUMERICHOST`, the same spelling `HostResolver` uses, so the two
    /// halves of a report print one address the same way.
    private static func text(of storage: sockaddr_storage, length: socklen_t) -> String {
        var copy = storage
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let resolved = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &name, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
            }
        }
        guard resolved == 0 else { return "unknown" }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
