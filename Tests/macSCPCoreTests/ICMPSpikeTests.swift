import Darwin
import Foundation
import MacSCPTestSupport
import Testing

/// The ICMP spike of `docs/superpowers/plans/2026-09-03-connection-tools-spike.md`.
///
/// It answers §5 of `docs/superpowers/specs/2026-09-02-connection-tools-design.md`
/// — whether an UNPRIVILEGED process on this machine can (a) send an ICMP
/// echo request and read the reply through a `SOCK_DGRAM` ICMP socket, and
/// (b)/(c) whether that same socket is handed the ICMP time-exceeded message
/// a TTL-limited UDP probe provokes. The verdicts decide which rows §2.3
/// (ICMP echo) and §2.5 (network trace) of the design get. The file stays in
/// the tree, gated, as the record of HOW it was measured; it is not a check
/// of product behaviour, and it never fails on a "no" — a "no" is a green
/// test with a printed verdict.
///
/// Run it alone and read stdout:
/// `MACSCP_NETSPIKE=1 swift test --filter ICMPSpikeTests`
///
/// **Where the packets go.** Loopback only (`127.0.0.1`, `::1`) for the echo
/// measurement. For the time-exceeded measurement, one UDP datagram to
/// TEST-NET-1 `192.0.2.1:33434` with `IP_TTL=1` and — only when a global IPv6
/// route exists — one to `2001:db8::1` (RFC 3849 documentation prefix) with
/// hop limit 1. A hop limit of one means the datagram dies at the LAN's first
/// router, which answers it; nothing leaves the local network. No other
/// destination is ever contacted.
///
/// **Why the reader filters on this file's own payload (added 2026-09-03).**
/// `.serialized` orders a suite's own cases; Swift Testing still runs
/// DIFFERENT suites in parallel, and an unfiltered `MACSCP_NETSPIKE=1 swift
/// test` — exactly what a maintainer runs to refresh this record — enables
/// `ICMPEchoTests` at the same time. An unprivileged ICMP DGRAM socket is not
/// demultiplexed (measured 2026-09-03: a second socket's reply, and another
/// PROCESS's `ping` replies, are both handed to a socket that did not ask for
/// them), so a reader that accepted any datagram of the right type could
/// print another suite's reply — or a stray `ping` — into the file whose
/// whole purpose is to be the measurement record. Every `accept` below
/// therefore also requires `Spike.payload` to come back in the datagram: for
/// the echo cases as the echoed data, and for the time-exceeded cases inside
/// the quoted original datagram — but there only when the quote is long
/// enough to have carried it, because RFC 792 lets a router quote the IP
/// header and eight bytes and no payload (see `quoteMatchesSpikeProbe`). The
/// verdicts stay measurements of replies to THIS file's own requests, without
/// turning a minimal-quoting router into a false "no".
///
/// **Why every socket call sits inside `onDedicatedQueue`.** `poll` and
/// `recvfrom` block the thread they run on, and Swift Testing runs tests on
/// the cooperative pool, which is exactly as wide as the machine has cores
/// (CLAUDE.md, "Tests never block the cooperative pool"). Each measurement
/// therefore runs its whole socket sequence on a `DispatchQueue` created for
/// it and is awaited through a continuation, so the pool thread is suspended,
/// never parked. Every wait is bounded at 2 s and every descriptor is closed
/// in a `defer`.
@Suite(
    "ICMPSpike",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_NETSPIKE"] == "1"),
    .serialized
)
struct ICMPSpikeTests {
    // MARK: - The measurements

    /// (a) IPv4 — `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`, one echo
    /// request to `127.0.0.1`, one bounded read. Records the identifier and
    /// sequence AS DELIVERED, because whether the number that comes back is
    /// the number that went out is precisely what was open: the design
    /// assumed macOS renumbers a DGRAM ICMP socket's echoes, and this
    /// measurement found it UNCHANGED on 26.6.2 (three runs, design §5). A
    /// matcher may therefore read the identifier but must not require it —
    /// `ICMPEcho` pins the sequence instead.
    @Test func unprivilegedICMPv4EchoReachesLoopback() async throws {
        let result = try await Self.onDedicatedQueue("macscp.spike.icmp4-echo") {
            Self.measureEcho(
                family: AF_INET,
                proto: Int32(IPPROTO_ICMP),
                destination: Endpoint(ipv4: Spike.loopbackV4, port: 0),
                requestType: Spike.icmpV4EchoRequest,
                replyType: Spike.icmpV4EchoReply,
                computeChecksumLocally: true
            )
        }
        Self.report("(a) IPv4 echo -> \(Spike.loopbackV4)", result)
        #expect(result.verdict.isEmpty == false)
    }

    /// (a) IPv6 — the same through `IPPROTO_ICMPV6` to `::1`. The kernel owns
    /// the ICMPv6 checksum (it needs the pseudo-header), so the request goes
    /// out with a zero there.
    @Test func unprivilegedICMPv6EchoReachesLoopback() async throws {
        let result = try await Self.onDedicatedQueue("macscp.spike.icmp6-echo") {
            Self.measureEcho(
                family: AF_INET6,
                proto: Int32(IPPROTO_ICMPV6),
                destination: Endpoint(ipv6: Spike.loopbackV6, port: 0),
                requestType: Spike.icmpV6EchoRequest,
                replyType: Spike.icmpV6EchoReply,
                computeChecksumLocally: false
            )
        }
        Self.report("(a) IPv6 echo -> \(Spike.loopbackV6)", result)
        #expect(result.verdict.isEmpty == false)
    }

    /// (b) IPv4 time-exceeded — a UDP datagram with `IP_TTL = 1` toward
    /// TEST-NET-1, and the question the network trace hangs on: does the
    /// unprivileged ICMP DGRAM socket receive the router's time-exceeded
    /// message? The UDP socket is `connect`ed (which sends nothing) so that
    /// the kernel has somewhere to report an error at all, and both exits are
    /// read afterwards: `getsockopt(SO_ERROR)` and a non-blocking `recvfrom`.
    /// `SO_RECVERR`, Linux's third exit, does not exist here.
    @Test func timeExceededForTTLLimitedIPv4Probe() async throws {
        let result = try await Self.onDedicatedQueue("macscp.spike.icmp4-ttl") {
            Self.measureTimeExceeded(
                family: AF_INET,
                icmpProto: Int32(IPPROTO_ICMP),
                destination: Endpoint(ipv4: Spike.testNetV4, port: Spike.probePort),
                hopLimit: HopLimitOption(level: Int32(IPPROTO_IP), name: IP_TTL),
                expectedType: Spike.icmpV4TimeExceeded
            )
        }
        Self.report("(b) IPv4 TTL=1 -> \(Spike.testNetV4):\(Spike.probePort)", result)
        #expect(result.verdict.isEmpty == false)
    }

    /// (c) IPv6 time-exceeded — the same with `IPV6_UNICAST_HOPS = 1` toward
    /// the documentation prefix, but only if this machine has a global IPv6
    /// route. The route is probed by `connect`ing an unconnected UDP socket,
    /// which puts no packet on the wire; without a route the verdict is
    /// "no IPv6 route, unmeasured" and nothing is sent.
    @Test func timeExceededForHopLimitedIPv6Probe() async throws {
        let result = try await Self.onDedicatedQueue("macscp.spike.icmp6-hoplimit") {
            let destination = Endpoint(ipv6: Spike.documentationV6, port: Spike.probePort)
            guard let route = Self.probeIPv6Route(to: destination) else {
                return Self.measureTimeExceeded(
                    family: AF_INET6,
                    icmpProto: Int32(IPPROTO_ICMPV6),
                    destination: destination,
                    hopLimit: HopLimitOption(level: Int32(IPPROTO_IPV6), name: IPV6_UNICAST_HOPS),
                    expectedType: Spike.icmpV6TimeExceeded
                )
            }
            return SpikeResult(
                verdict: "no IPv6 route, unmeasured (\(route))",
                detail: ["route probe: \(route)", "nothing sent"]
            )
        }
        Self.report("(c) IPv6 hop limit 1 -> \(Spike.documentationV6):\(Spike.probePort)", result)
        #expect(result.verdict.isEmpty == false)
    }

    // MARK: - Echo

    private static func measureEcho(
        family: Int32,
        proto: Int32,
        destination: Endpoint?,
        requestType: UInt8,
        replyType: UInt8,
        computeChecksumLocally: Bool
    ) -> SpikeResult {
        var detail: [String] = []
        guard let destination else {
            return SpikeResult(verdict: "no — destination unparseable", detail: detail)
        }

        let descriptor = socket(family, SOCK_DGRAM, proto)
        let socketErrno = errno
        guard descriptor >= 0 else {
            detail.append("socket(SOCK_DGRAM, \(proto)) = -1, \(Self.describe(socketErrno))")
            return SpikeResult(verdict: "no — socket refused", detail: detail)
        }
        defer { close(descriptor) }
        detail.append("socket(SOCK_DGRAM, \(proto)) = \(descriptor) (no privileges, uid \(getuid()))")

        let identifier = UInt16(truncatingIfNeeded: getpid())
        let sequence: UInt16 = 1
        let packet = echoRequest(
            type: requestType,
            identifier: identifier,
            sequence: sequence,
            payload: Array(Spike.payload.utf8),
            computeChecksum: computeChecksumLocally
        )
        detail.append("sent identifier=\(identifier) sequence=\(sequence) bytes=\(packet.count)")

        let start = DispatchTime.now()
        let sent = destination.withSockaddr { address, length in
            packet.withUnsafeBytes { buffer in
                sendto(descriptor, buffer.baseAddress, buffer.count, 0, address, length)
            }
        }
        let sendErrno = errno
        guard sent >= 0 else {
            detail.append("sendto = -1, \(Self.describe(sendErrno))")
            return SpikeResult(verdict: "no — send refused", detail: detail)
        }
        detail.append("sendto = \(sent)")

        let deadline = start + .milliseconds(Spike.waitMilliseconds)
        let received = waitForMessage(
            descriptor: descriptor,
            family: family,
            start: start,
            deadline: deadline,
            detail: &detail,
            accept: { $0.type == replyType && $0.carriesSpikePayload }
        )
        guard let received else {
            detail.append("nothing matching arrived within \(Spike.waitMilliseconds) ms")
            return SpikeResult(verdict: "no — no echo reply inside 2 s", detail: detail)
        }
        detail.append("reply after \(Self.format(received.elapsedMilliseconds)) ms: \(received.message)")
        let idText = received.message.identifier.map(String.init) ?? "n/a"
        let seqText = received.message.sequence.map(String.init) ?? "n/a"
        let rewritten = received.message.identifier == identifier ? "unchanged" : "rewritten by the kernel"
        return SpikeResult(
            verdict: """
                yes — echo reply in \(Self.format(received.elapsedMilliseconds)) ms, \
                type=\(received.message.type) code=\(received.message.code), \
                identifier sent=\(identifier) delivered=\(idText) (\(rewritten)), \
                sequence=\(seqText)
                """,
            detail: detail
        )
    }

    // MARK: - Time exceeded

    private static func measureTimeExceeded(
        family: Int32,
        icmpProto: Int32,
        destination: Endpoint?,
        hopLimit: HopLimitOption,
        expectedType: UInt8
    ) -> SpikeResult {
        var detail: [String] = []
        guard let destination else {
            return SpikeResult(verdict: "no — destination unparseable", detail: detail)
        }

        // The listening socket must exist before the probe goes out.
        let icmpDescriptor = socket(family, SOCK_DGRAM, icmpProto)
        let icmpErrno = errno
        guard icmpDescriptor >= 0 else {
            detail.append("icmp socket(SOCK_DGRAM, \(icmpProto)) = -1, \(Self.describe(icmpErrno))")
            return SpikeResult(verdict: "no — icmp socket refused", detail: detail)
        }
        defer { close(icmpDescriptor) }
        detail.append("icmp socket(SOCK_DGRAM, \(icmpProto)) = \(icmpDescriptor)")

        let udpDescriptor = socket(family, SOCK_DGRAM, Int32(IPPROTO_UDP))
        let udpErrno = errno
        guard udpDescriptor >= 0 else {
            detail.append("udp socket = -1, \(Self.describe(udpErrno))")
            return SpikeResult(verdict: "no — udp socket refused", detail: detail)
        }
        defer { close(udpDescriptor) }

        var hops: Int32 = 1
        let optionResult = setsockopt(
            udpDescriptor,
            hopLimit.level,
            hopLimit.name,
            &hops,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let optionErrno = errno
        guard optionResult == 0 else {
            detail.append("setsockopt(hop limit 1) = -1, \(Self.describe(optionErrno))")
            return SpikeResult(verdict: "no — hop limit could not be set", detail: detail)
        }
        detail.append("setsockopt(hop limit) = 1")

        // `connect` on an unconnected UDP socket puts no packet on the wire;
        // it only fixes the peer, which is what lets the kernel report an
        // asynchronous ICMP error on this socket at all.
        let connectResult = destination.withSockaddr { address, length in
            connect(udpDescriptor, address, length)
        }
        let connectErrno = errno
        guard connectResult == 0 else {
            detail.append("connect = -1, \(Self.describe(connectErrno))")
            return SpikeResult(verdict: "no — no route to the probe destination", detail: detail)
        }
        detail.append("connect = 0 (no packet sent)")

        let start = DispatchTime.now()
        let payload = Array(Spike.payload.utf8)
        let sent = payload.withUnsafeBytes { buffer in
            send(udpDescriptor, buffer.baseAddress, buffer.count, 0)
        }
        let sendErrno = errno
        guard sent >= 0 else {
            detail.append("send = -1, \(Self.describe(sendErrno))")
            return SpikeResult(verdict: "no — probe could not be sent", detail: detail)
        }
        detail.append("send = \(sent) bytes with hop limit 1")

        let deadline = start + .milliseconds(Spike.waitMilliseconds)
        let received = waitForMessage(
            descriptor: icmpDescriptor,
            family: family,
            start: start,
            deadline: deadline,
            detail: &detail,
            accept: { $0.type == expectedType && $0.quoteMatchesSpikeProbe }
        )
        if let received {
            detail.append("time-exceeded after \(Self.format(received.elapsedMilliseconds)) ms: \(received.message)")
        } else {
            detail.append("nothing matching arrived within \(Spike.waitMilliseconds) ms")
        }

        // Both of the UDP socket's own exits, read after the wait. The log
        // above is chronological: these two lines are read AFTER the 2 s
        // window closed, which is what makes them comparable with it.
        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        let optionRead = getsockopt(udpDescriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
        let optionReadErrno = errno
        if optionRead == 0 {
            let text = socketError == 0 ? "0 (no error)" : "\(socketError) (\(Self.strerror(socketError)))"
            detail.append("getsockopt(SO_ERROR) = \(text)")
        } else {
            detail.append("getsockopt(SO_ERROR) = -1, \(Self.describe(optionReadErrno))")
        }

        var scratch = [UInt8](repeating: 0, count: 256)
        let readBack = scratch.withUnsafeMutableBytes { buffer in
            recv(udpDescriptor, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
        }
        let readBackErrno = errno
        if readBack >= 0 {
            detail.append("recv(MSG_DONTWAIT) = \(readBack) bytes")
        } else {
            detail.append("recv(MSG_DONTWAIT) = -1, \(Self.describe(readBackErrno))")
        }
        let socketErrorSummary = optionRead == 0 ? "SO_ERROR=\(socketError)" : "SO_ERROR unreadable"

        guard let received else {
            return SpikeResult(
                verdict: "no — no ICMP time-exceeded on the DGRAM socket inside 2 s; \(socketErrorSummary)",
                detail: detail
            )
        }
        return SpikeResult(
            verdict: """
                yes — time-exceeded type=\(received.message.type) code=\(received.message.code) \
                from \(received.message.source) after \(Self.format(received.elapsedMilliseconds)) ms; \
                \(socketErrorSummary)
                """,
            detail: detail
        )
    }

    /// Returns a description of WHY there is no usable global IPv6 route, or
    /// `nil` when there is one. Sends nothing: `connect` on an unconnected
    /// UDP socket only consults the routing table.
    private static func probeIPv6Route(to destination: Endpoint?) -> String? {
        guard let destination else { return "destination unparseable" }
        let descriptor = socket(AF_INET6, SOCK_DGRAM, Int32(IPPROTO_UDP))
        let socketErrno = errno
        guard descriptor >= 0 else { return "socket = -1, \(Self.describe(socketErrno))" }
        defer { close(descriptor) }
        let result = destination.withSockaddr { address, length in
            connect(descriptor, address, length)
        }
        let connectErrno = errno
        guard result == 0 else { return "connect = -1, \(Self.describe(connectErrno))" }
        return nil
    }

    // MARK: - Socket plumbing

    /// Runs the whole blocking socket sequence on a queue of its own and
    /// suspends the caller on a continuation, so no cooperative-pool thread
    /// is ever parked in `poll` or `recvfrom`.
    private static func onDedicatedQueue(
        _ label: String,
        _ body: @escaping @Sendable () -> SpikeResult
    ) async throws -> SpikeResult {
        let queue = DispatchQueue(label: label)
        return try await awaitResumption { (continuation: CheckedContinuation<SpikeResult, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Bounded read loop: polls for what is left of the 2 s budget, parses
    /// each datagram, and returns the first one `accept` takes. Datagrams it
    /// does not take are written to `detail` rather than dropped silently —
    /// on a busy machine an unrelated ICMP message is exactly what a
    /// single-shot read would mistake for the answer.
    private static func waitForMessage(
        descriptor: Int32,
        family: Int32,
        start: DispatchTime,
        deadline: DispatchTime,
        detail: inout [String],
        accept: (ICMPMessage) -> Bool
    ) -> (message: ICMPMessage, elapsedMilliseconds: Double)? {
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { return nil }
            let remaining = (deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(max(remaining, 1)))
            let pollErrno = errno
            if ready < 0 {
                if pollErrno == EINTR { continue }
                detail.append("poll = -1, \(Self.describe(pollErrno))")
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
            guard count > 0 else {
                detail.append("recvfrom = \(count), \(Self.describe(receiveErrno))")
                return nil
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            guard let message = ICMPMessage(
                bytes: Array(buffer[0..<count]),
                family: family,
                source: Self.text(of: source)
            ) else {
                detail.append("unparseable datagram of \(count) bytes")
                continue
            }
            if accept(message) { return (message, elapsed) }
            detail.append("ignored after \(Self.format(elapsed)) ms: \(message)")
        }
    }

    // MARK: - Packets

    private static func echoRequest(
        type: UInt8,
        identifier: UInt16,
        sequence: UInt16,
        payload: [UInt8],
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

    /// One ICMP or ICMPv6 message as it was delivered.
    ///
    /// `ipHeaderIncluded` is itself a measurement: a DGRAM ICMP socket may or
    /// may not hand the IPv4 header up with the payload, and a reader that
    /// assumes the wrong one reads the type byte out of the wrong place.
    private struct ICMPMessage: CustomStringConvertible {
        var byteCount: Int
        var ipHeaderIncluded: Bool
        var type: UInt8
        var code: UInt8
        var identifier: UInt16?
        var sequence: UInt16?
        var quoted: String?
        var source: String
        /// Whether `Spike.payload` appears anywhere after the ICMP header —
        /// as the echoed data for an echo reply, and inside the quoted
        /// original datagram for a time-exceeded message. Searched rather
        /// than read at a fixed offset because the quote carries the original
        /// IP and UDP headers ahead of it, and their lengths are the router's
        /// business, not this file's.
        var carriesSpikePayload: Bool
        /// How many bytes of the original datagram this message quotes.
        var quotedByteCount: Int

        /// Whether a time-exceeded message's QUOTE can be this file's probe.
        ///
        /// Not the same test as `carriesSpikePayload`, and deliberately
        /// weaker: RFC 792 requires a time-exceeded message to quote only
        /// "Internet Header + 64 bits of the original datagram" — the IP
        /// header plus the UDP ports, length and checksum, and **no payload
        /// at all**. A router that quotes the minimum can never return
        /// `Spike.payload`, so demanding it would turn verdict (b) into a
        /// false "no — no ICMP time-exceeded …" on such a network, in the
        /// file whose whole purpose is to be the measurement record. The
        /// router measured here (2026-09-03) quoted 45 bytes and did return
        /// it; that is a fact about that router, not about routers.
        ///
        /// So: the quote must be long enough to carry the UDP ports at all,
        /// and the marker is required only when the quote is long enough to
        /// have carried it. Where it is not, the message is accepted on its
        /// type — and a "no" verdict on this path has to be read together
        /// with the `ignored after … ms:` lines above it, which is where a
        /// datagram this reader turned away is written down.
        var quoteMatchesSpikeProbe: Bool {
            guard quotedByteCount >= Self.minimumQuotedBytes else { return false }
            guard quotedByteCount >= Self.minimumQuotedBytes + Spike.payload.utf8.count else {
                return true
            }
            return carriesSpikePayload
        }

        /// The smallest quote RFC 792 requires: a 20-byte IP header without
        /// options, plus the 8 bytes that carry the UDP ports.
        static let minimumQuotedBytes = 28

        init?(bytes: [UInt8], family: Int32, source: String) {
            byteCount = bytes.count
            self.source = source
            var offset = 0
            var carriesHeader = false
            if family == AF_INET, let first = bytes.first, first >> 4 == 4 {
                let headerLength = Int(first & 0x0F) * 4
                if headerLength >= 20, bytes.count > headerLength {
                    offset = headerLength
                    carriesHeader = true
                }
            }
            ipHeaderIncluded = carriesHeader
            guard bytes.count >= offset + 8 else { return nil }
            type = bytes[offset]
            code = bytes[offset + 1]
            let isEcho = type == Spike.icmpV4EchoReply || type == Spike.icmpV4EchoRequest
                || type == Spike.icmpV6EchoReply || type == Spike.icmpV6EchoRequest
            if isEcho {
                identifier = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
                sequence = UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
            }
            let quotedBytes = bytes.count - (offset + 8)
            quotedByteCount = max(0, quotedBytes)
            quoted = quotedBytes > 0 ? "\(quotedBytes) bytes of the original datagram" : nil
            carriesSpikePayload = ICMPMessage.contains(
                Array(Spike.payload.utf8), in: bytes, from: offset + 8)
        }

        /// Whether `marker` appears in `bytes` at or after `start`.
        private static func contains(_ marker: [UInt8], in bytes: [UInt8], from start: Int)
            -> Bool
        {
            guard !marker.isEmpty, start >= 0, bytes.count >= start + marker.count else {
                return false
            }
            for offset in start...(bytes.count - marker.count)
            where Array(bytes[offset..<(offset + marker.count)]) == marker {
                return true
            }
            return false
        }

        var description: String {
            let idText = identifier.map { "identifier=\($0)" } ?? "identifier=n/a"
            let seqText = sequence.map { "sequence=\($0)" } ?? "sequence=n/a"
            let quotedText = quoted.map { ", quoting \($0)" } ?? ""
            return "type=\(type) code=\(code) \(idText) \(seqText) from \(source), "
                + "\(byteCount) bytes, ip header included=\(ipHeaderIncluded)\(quotedText)"
        }
    }

    // MARK: - Addresses

    private struct HopLimitOption {
        var level: Int32
        var name: Int32
    }

    private struct Endpoint {
        private var storage = sockaddr_storage()
        private var length: socklen_t = 0

        init?(ipv4 text: String, port: UInt16) {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, text, &address.sin_addr) == 1 else { return nil }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            Endpoint.store(address, into: &storage)
        }

        init?(ipv6 text: String, port: UInt16) {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, text, &address.sin6_addr) == 1 else { return nil }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            Endpoint.store(address, into: &storage)
        }

        private static func store<Address>(_ address: Address, into storage: inout sockaddr_storage) {
            withUnsafeBytes(of: address) { source in
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyMemory(from: source)
                }
            }
        }

        func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
            var copy = storage
            let size = length
            return withUnsafePointer(to: &copy) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    body(address, size)
                }
            }
        }
    }

    private static func text(of storage: sockaddr_storage) -> String {
        var copy = storage
        var characters = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = Int32(copy.ss_family)
        let converted: UnsafePointer<CChar>? = withUnsafePointer(to: &copy) { pointer -> UnsafePointer<CChar>? in
            switch family {
            case AF_INET:
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                    var raw = address.pointee.sin_addr
                    return inet_ntop(AF_INET, &raw, &characters, socklen_t(INET6_ADDRSTRLEN))
                }
            case AF_INET6:
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                    var raw = address.pointee.sin6_addr
                    return inet_ntop(AF_INET6, &raw, &characters, socklen_t(INET6_ADDRSTRLEN))
                }
            default:
                return nil
            }
        }
        guard converted != nil else { return "unknown family \(family)" }
        return characters.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { String(cString: $0) } ?? "unreadable"
        }
    }

    // MARK: - Reporting

    private struct SpikeResult: Sendable {
        var verdict: String
        var detail: [String]
    }

    private static func describe(_ code: Int32) -> String {
        "errno=\(code) (\(strerror(code)))"
    }

    private static func strerror(_ code: Int32) -> String {
        Darwin.strerror(code).map { String(cString: $0) } ?? "unknown"
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func report(_ title: String, _ result: SpikeResult) {
        print("=== ICMP spike \(title) — macOS \(osVersion)")
        for line in result.detail { print("    \(line)") }
        print("=== VERDICT \(title): \(result.verdict)")
    }

    private enum Spike {
        static let waitMilliseconds = 2000
        static let loopbackV4 = "127.0.0.1"
        static let loopbackV6 = "::1"
        /// RFC 5737 TEST-NET-1. With `IP_TTL = 1` the datagram dies at the
        /// LAN's first router; it never leaves the local network.
        static let testNetV4 = "192.0.2.1"
        /// RFC 3849 documentation prefix, sent with hop limit 1.
        static let documentationV6 = "2001:db8::1"
        static let probePort: UInt16 = 33434
        static let payload = "macSCP-icmp-spike"

        static let icmpV4EchoReply: UInt8 = 0
        static let icmpV4EchoRequest: UInt8 = 8
        static let icmpV4TimeExceeded: UInt8 = 11
        static let icmpV6TimeExceeded: UInt8 = 3
        static let icmpV6EchoRequest: UInt8 = 128
        static let icmpV6EchoReply: UInt8 = 129
    }
}
