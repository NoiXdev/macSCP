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
    /// The sequence this reply answers. One of the two fields the matcher
    /// pins — the other is the echoed payload, which is what makes the
    /// datagram this probe's rather than merely this machine's.
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
/// were measured, plus one measured on 2026-09-03 while fixing the matcher.
/// Four findings shape the code here:
///
/// 1. **The identifier may or may not survive.** It came back unchanged on
///    26.6.2; the design had assumed the kernel renumbers it. So the matcher
///    never reads it and merely reports it — code that required a rewrite
///    would be wrong here, code that forbade one would be wrong on the
///    machine the design's assumption came from.
/// 2. **IPv4 hands the IP header up, IPv6 does not.** The IPv4 datagram
///    arrived as 20 + 8 + payload with `version == 4` in its first nibble, so
///    the reader skips `IHL × 4` bytes; the ICMPv6 datagram starts at the
///    ICMP header.
/// 3. **The ICMPv6 socket delivers this process's own type-128 request.** A
///    reader that took the first datagram and called it the reply would time
///    the request's own trip back from `::1`, so the wait filters on type.
/// 4. **The socket is not demultiplexed at all** (2026-09-03). It is handed
///    every echo reply the machine receives — another socket's, and another
///    PROCESS's `ping`. So a reply counts only when it echoes this probe's
///    own payload back: a marker naming the app, plus a nonce drawn per
///    socket. Without it, a user pinging in Terminal while they press
///    Diagnose collects someone else's replies as the answer of a host that
///    answered nothing.
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

    /// The marker every request this app sends carries, and the first half of
    /// what a reply has to bring back to be counted.
    ///
    /// ASCII, and it names the app so anyone reading a packet capture knows
    /// what sent it.
    static let payloadMarker = Array("macSCP-diagnostics".utf8)

    /// How many random bytes follow the marker.
    private static let nonceByteCount = 8

    /// One probe run's payload: the marker, then a nonce drawn fresh for this
    /// socket.
    ///
    /// The nonce is what separates two macSCP diagnoses running at the same
    /// time; the marker is what separates macSCP from every other pinger on
    /// the machine. Both are needed — see `waitForReply`.
    static func probePayload() -> [UInt8] {
        payloadMarker + (0..<nonceByteCount).map { _ in UInt8.random(in: .min ... .max) }
    }

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
        if isIPv6, let reason = ipv6RouteFailure(to: address) { return .unavailable(reason) }

        let descriptor = socket(
            family, SOCK_DGRAM, isIPv6 ? Int32(IPPROTO_ICMPV6) : Int32(IPPROTO_ICMP))
        let socketErrno = errno
        guard descriptor >= 0 else { return .unavailable(String(cString: strerror(socketErrno))) }
        defer { close(descriptor) }

        let requestType = isIPv6 ? ipv6EchoRequest : ipv4EchoRequest
        let replyType = isIPv6 ? ipv6EchoReply : ipv4EchoReply
        let payload = probePayload()
        // A random base, not 1. Sequences 1, 2, 3 are what every pinger on the
        // machine sends, so a fixed start makes this socket's expectation
        // collide with the whole world's; a random base makes a collision a
        // 1-in-65536 accident rather than the normal case. It is a narrowing,
        // not the guard: the payload check below is.
        let sequenceBase = UInt16.random(in: 0 ... .max)
        let clock = ContinuousClock()
        var replies: [ICMPEchoReply] = []
        var sent = 0

        for index in 0..<count {
            guard clock.now < deadline else { break }
            let sequence = sequenceBase &+ UInt16(truncatingIfNeeded: index)
            // The ICMPv6 checksum covers a pseudo-header the kernel owns, so
            // it is left at zero and the kernel fills it in; the IPv4 one is
            // this side's job.
            let packet = request(
                type: requestType, identifier: identifier, sequence: sequence,
                payload: payload, computeChecksum: !isIPv6)
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
                sequence: sequence, payload: payload, started: started,
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

    /// The sentence the step reports when the routing table has no route to
    /// an IPv6 address.
    ///
    /// A symbol, not a spelling: the test compares against it and Task 4 will
    /// map it to `diagnostics.reason.noIPv6Route`, so a reworded sentence has
    /// one place to change rather than three.
    static let noIPv6RouteReason = "no IPv6 route"

    /// Why there is no usable route to this IPv6 address, or `nil` when there
    /// is one.
    ///
    /// Sends nothing: `connect` on an unconnected UDP socket only consults
    /// the table. This is how the spike established that its machine had no
    /// global IPv6 route without putting a packet anywhere, and it is why the
    /// step can say so instead of waiting out a deadline for an answer that
    /// was never coming.
    ///
    /// A refused SOCKET is reported as itself, with `strerror`'s sentence:
    /// a machine with IPv6 disabled at the socket layer has no routing
    /// problem, and a row that called it one would send the reader after the
    /// wrong thing.
    private static func ipv6RouteFailure(to address: ResolvedAddress) -> String? {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, Int32(IPPROTO_UDP))
        let socketErrno = errno
        guard descriptor >= 0 else { return String(cString: strerror(socketErrno)) }
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
                let connected = mutable.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, length)
                }
                return connected == 0 ? nil : noIPv6RouteReason
            }
        }
    }

    /// Polls for what is left of this probe's budget and returns the first
    /// datagram that is an echo REPLY carrying the sequence just sent AND
    /// echoing this probe's own payload back.
    ///
    /// Anything else is skipped and the loop keeps waiting rather than
    /// returning: on the ICMPv6 socket the very first datagram is normally
    /// this process's own request coming back (design §5), so a single-shot
    /// read would answer with the wrong packet every time.
    ///
    /// **Why the payload is part of the match.** Measured 2026-09-03: an
    /// unprivileged ICMP DGRAM socket is not demultiplexed at all. A second
    /// socket in this process pinged `127.0.0.1` and the FIRST socket was
    /// handed the reply; a `ping` in a separate process put three replies
    /// into a socket that had sent nothing. Type and sequence therefore say
    /// only "somebody on this machine got an echo reply", and a user
    /// debugging a connection with `ping` open in Terminal would have had
    /// those replies counted as the answer of a host that answered nothing.
    /// RFC 792 and RFC 4443 require a reply to return the request's data, so
    /// the marker plus this socket's nonce is what makes a datagram ours —
    /// the marker against every other pinger, the nonce against a second
    /// macSCP diagnosis.
    ///
    /// The identifier is deliberately NOT part of the match — see the type's
    /// note. It is the field the verdict says an implementation may read and
    /// must not depend on, which is exactly why the payload does this work
    /// instead.
    static func waitForReply(
        descriptor: Int32, family: Int32, replyType: UInt8, sequence: UInt16,
        payload: [UInt8], started: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
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
            let receiveErrno = errno
            if count < 0, receiveErrno == EINTR { continue }
            guard count > 0 else { return nil }
            let elapsed = started.duration(to: clock.now)
            guard
                let header = ICMPHeader(bytes: buffer, count: count, family: family),
                header.type == replyType, header.sequence == sequence,
                echoes(payload, in: buffer, count: count, at: header.payloadOffset)
            else { continue }
            return ICMPEchoReply(
                type: header.type, sequence: header.sequence, identifier: header.identifier,
                rtt: elapsed, source: text(of: source, length: sourceLength))
        }
    }

    // MARK: - The packet

    static func request(
        type: UInt8, identifier: UInt16, sequence: UInt16, payload: [UInt8],
        computeChecksum: Bool
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

    /// Whether the datagram returns `payload` byte for byte at the offset
    /// where the echoed data begins.
    ///
    /// Compared here rather than sliced out and handed around: `bytes` is the
    /// full 2048-byte receive buffer whose tail is stale, so the length has to
    /// be checked against `count` — what `recvfrom` actually filled — before
    /// any byte past the header is read.
    private static func echoes(
        _ payload: [UInt8], in bytes: [UInt8], count: Int, at offset: Int
    ) -> Bool {
        guard count >= offset + payload.count else { return false }
        for (index, byte) in payload.enumerated() where bytes[offset + index] != byte {
            return false
        }
        return true
    }

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
        /// Where the echoed data begins — the header's own offset plus its
        /// eight bytes. Carried out of the parser because the payload check
        /// needs the same IP-header skip the header did, and re-deriving it
        /// would be a second copy of that rule.
        let payloadOffset: Int

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
            payloadOffset = offset + 8
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
