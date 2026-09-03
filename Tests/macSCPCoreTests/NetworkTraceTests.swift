import Darwin
import Foundation
import Testing

@testable import macSCPCore

/// The IPv4 network trace, built from the verdict `ICMPSpikeTests` measured
/// (design §5, macOS 26.6.2): a UDP datagram with `IP_TTL = 1` toward
/// TEST-NET-1 produces ICMP **type 11 code 0** on an unprivileged ICMP DGRAM
/// socket, and the UDP socket's own `SO_ERROR` says only `EHOSTUNREACH` — it
/// carries no hop address, so the ICMP socket is what identifies the hop.
///
/// One more shape was measured here on 2026-09-03, and it is what the
/// destination half of the trace rests on: a UDP datagram to `127.0.0.1:33434`
/// is answered by the kernel's own **type 3 code 3** (port unreachable), 56
/// bytes with the IP header, quoting the original IP header plus the first
/// eight bytes of the UDP datagram — which is where both port numbers live.
///
/// **Where the packets go.** Loopback only, except in the two cases gated
/// `MACSCP_NETSPIKE=1`, which send to `192.0.2.1` (RFC 5737 TEST-NET-1) with
/// a TTL of 1 and 2. A TTL that small means the datagram dies at the LAN's
/// first routers; nothing ever leaves the local network, and no real remote
/// host is contacted anywhere in this file.
///
/// **Why the suite is serialized.** Its cases share a socket space that is not
/// demultiplexed — every ICMP message the machine receives is handed to every
/// unprivileged ICMP DGRAM socket (measured 2026-09-03,
/// `ICMPEchoTests.aForeignEchoReplyIsNotCountedAsThisProbesAnswer`). The
/// injection case below chooses its ports by hand, so two of them at once
/// could take each other's answers.
///
/// **Why no test parks a thread.** `NetworkTrace` runs its whole socket
/// sequence on a `DispatchQueue` of its own and is awaited through a
/// continuation (CLAUDE.md, "Tests never block the cooperative pool"); the
/// cases only `await`, and the one case that drives the socket directly does
/// it inside `onOwnQueue`.
@Suite("NetworkTrace", .serialized)
struct NetworkTraceTests {
    /// RFC 5737 TEST-NET-1, reached only with a TTL of 1 or 2.
    private static let testNetV4 = "192.0.2.1"

    // MARK: - The destination

    /// Loopback answers port-unreachable at the first hop, so the trace ends
    /// there — with `maxHops` set to three, which is what makes "ends" a
    /// measurement rather than a coincidence: a trace that did not stop at the
    /// destination would report three hops, since 127.0.0.1 answers every
    /// probe port the same way.
    @Test func theDestinationEndsTheTraceAtTheFirstHop() async throws {
        let address = try #require(await Self.resolve("127.0.0.1"))
        let outcome = await NetworkTrace.trace(
            address: address, maxHops: 3, timeout: .seconds(3))

        #expect(outcome.hops.count == 1)
        #expect(outcome.reachedDestination)
        let hop = try #require(outcome.hops.first, "no hop measured: \(outcome)")
        #expect(hop.ttl == 1)
        guard case .unreachable(let source, let rtt, let code) = hop.outcome else {
            Issue.record("loopback did not answer unreachable: \(hop.outcome)")
            return
        }
        #expect(source == "127.0.0.1")
        #expect(rtt > .zero)
        #expect(code == NetworkTrace.portUnreachableCode)
    }

    // MARK: - The hops in between

    /// The first router on the path answers the TTL-1 probe with
    /// time-exceeded, and the trace has an address and a round-trip time for
    /// it — the whole point of the step.
    ///
    /// The address itself is deliberately NOT asserted and never printed: it
    /// is the site's own first hop, this repository is public, and design §5
    /// keeps that address out of the record for the same reason. What is
    /// asserted is that there IS one.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_NETSPIKE"] == "1"))
    func aTTLOneProbeIsAnsweredByTheFirstHop() async throws {
        let address = try #require(await Self.resolve(Self.testNetV4))
        let outcome = await NetworkTrace.trace(
            address: address, maxHops: 1, timeout: .seconds(3))

        #expect(outcome.hops.count == 1)
        // The destination was never reached — the datagram died one hop out —
        // and a trace that claimed otherwise would be reporting a route it
        // did not measure.
        #expect(outcome.reachedDestination == false)
        let hop = try #require(outcome.hops.first, "no hop measured: \(outcome)")
        guard case .forwarded(let source, let rtt) = hop.outcome else {
            Issue.record("the first hop did not report time-exceeded: \(hop.outcome)")
            return
        }
        #expect(source.isEmpty == false)
        #expect(rtt > .zero)
    }

    /// A hop nothing answers is a `*` row, and it does NOT end the trace: only
    /// `maxHops` or the destination does. With `maxHops` 2 toward TEST-NET-1
    /// the first hop answers and the second is silent (measured 2026-09-03:
    /// the TTL-2 datagram produced nothing within a second and left
    /// `SO_ERROR` at 0), so the trace reports both rows and stops on the hop
    /// count.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_NETSPIKE"] == "1"))
    func aSilentHopIsAStarAndTheTraceRunsOnToMaxHops() async throws {
        let address = try #require(await Self.resolve(Self.testNetV4))
        let outcome = await NetworkTrace.trace(
            address: address, maxHops: 2, timeout: .seconds(5))

        #expect(outcome.hops.count == 2)
        #expect(outcome.hops.map(\.ttl) == [1, 2])
        // The positive anchor for the silence below: the trace really did
        // measure something, so a `*` at hop 2 is a hop that answered nothing
        // rather than a trace that sent nothing.
        if case .timedOut = outcome.hops[0].outcome {
            Issue.record("the first hop was silent too — nothing here is measured")
            return
        }
        #expect(outcome.hops[1].outcome == .timedOut)
        #expect(outcome.reachedDestination == false)
    }

    /// Arrival is decided by the ANSWERING ADDRESS, not by the ICMP code: a
    /// router in the middle can answer destination-unreachable with code 3 of
    /// its own, and a trace that read the code alone would report a route it
    /// never completed.
    ///
    /// A value case rather than a probe, because the situation it pins cannot
    /// be provoked on loopback — the only address that answers there is the
    /// destination — and because the rule is a derivation over hops, which is
    /// exactly the shape a value case measures without a socket.
    @Test func anUnreachableFromSomeOtherAddressIsNotAnArrival() {
        let answered = TraceHopOutcome.unreachable(
            address: "10.0.0.1", rtt: .milliseconds(1), code: NetworkTrace.portUnreachableCode)
        let hop = NetworkTraceHop(ttl: 4, outcome: answered)

        // The anchor: the very same hop IS an arrival when it is the address
        // the trace was aimed at. Without it the two negatives below would be
        // satisfied by a rule that never says "arrived" at all.
        #expect(
            NetworkTraceOutcome.measured(hops: [hop], destination: "10.0.0.1")
                .reachedDestination)
        #expect(
            NetworkTraceOutcome.measured(hops: [hop], destination: "203.0.113.9")
                .reachedDestination == false)
        // And a hop that merely forwarded is never an arrival, whatever
        // address it came from.
        let forwarded = NetworkTraceHop(
            ttl: 4, outcome: .forwarded(address: "10.0.0.1", rtt: .milliseconds(1)))
        #expect(
            NetworkTraceOutcome.measured(hops: [forwarded], destination: "10.0.0.1")
                .reachedDestination == false)
    }

    // MARK: - What this step cannot do

    /// The trace probe is IPv4 only, and it says so instead of opening an
    /// IPv6 socket it has no measurement for. `::1` is resolved and never
    /// sent to: the guard is read before any socket is opened.
    @Test func anIPv6AddressIsUnavailableRatherThanTraced() async throws {
        let address = try #require(await Self.resolve("::1"))
        let outcome = await NetworkTrace.trace(
            address: address, maxHops: 1, timeout: .seconds(2))

        #expect(outcome == .unavailable(NetworkTrace.notIPv4Reason))
        #expect(outcome.hops.isEmpty)
    }

    // MARK: - An answer this probe never provoked

    /// An unprivileged ICMP DGRAM socket is handed every ICMP message the
    /// machine receives — measured 2026-09-03 for echo replies
    /// (`ICMPEchoTests.aForeignEchoReplyIsNotCountedAsThisProbesAnswer`), and
    /// the same is true of the error messages this step reads. A second UDP
    /// socket sending to a port of its own provokes a real port-unreachable
    /// that lands in THIS trace's socket, and counting it would give a hop an
    /// address and a time it never measured.
    ///
    /// What separates them is the quoted datagram's two port numbers, and
    /// both halves are checked here: the destination port (which is this
    /// hop's, `33434 + hop - 1`) and the source port (which is this probe
    /// socket's own, kernel-assigned — the half that separates two traces
    /// running at once, in this process or in `ICMPSpikeTests` alongside it,
    /// since those pick the same destination port).
    @Test func aForeignPortUnreachableIsNotCountedAsThisProbesAnswer() async throws {
        let result = await Self.onOwnQueue { Self.injectForeignUnreachable() }

        // The anchors come first, and they have to: without them the two
        // rejections below would be satisfied by a socket that received
        // nothing at all.
        #expect(result.acceptedForItsOwnPorts)
        #expect(result.rejectedForAnotherDestinationPort)
        #expect(result.rejectedForAnotherSourcePort)
    }

    // MARK: - The step in the runner

    @Test func theRunnerPutsTheTraceAfterTheDialAndBeforeTheContributions() async throws {
        let listener = try #require(TraceLoopbackListener.listening())
        defer { listener.close() }

        let report = await ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port)),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(5)
        ).run()

        #expect(
            report.steps.map(\.id) == [
                DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
                DiagnosticStepID.dial, DiagnosticStepID.trace, "probe.after",
            ])
        let trace = try #require(report.steps.first { $0.id == DiagnosticStepID.trace })
        #expect(trace.outcome == .ok)
        #expect(trace.titleKey == "diagnostics.step.trace")
        #expect(trace.detail.hasPrefix("1 127.0.0.1 "))
        #expect(trace.detail.contains("port unreachable"))
    }

    /// Nothing resolved means nothing to trace — `skipped`, the same sentence
    /// the TCP and echo steps use, because it is the same situation.
    @Test func aTraceWithNothingResolvedIsSkipped() async {
        let report = await ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "not-a-numeric-address", port: 22)),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(2)
        ).run()

        guard let trace = report.steps.first(where: { $0.id == DiagnosticStepID.trace }) else {
            Issue.record("no trace step in \(report.steps.map(\.id))")
            return
        }
        guard case .skipped = trace.outcome else {
            Issue.record("an unresolved host did not skip the trace: \(trace.outcome)")
            return
        }
    }

    /// A host that resolves only to IPv6 gets the sentence the design's §5
    /// verdict (c) earned: the IPv6 trace was never measured, because the
    /// machine that measured everything else had no route to try it on. The
    /// row says that rather than reporting a failure it did not observe.
    ///
    /// `::1` is the endpoint and nothing is traced to it — the step reads the
    /// resolved families and returns before any probe socket exists.
    @Test func anIPv6OnlyEndpointReportsTheTraceAsUnmeasured() async throws {
        let listener = try #require(TraceLoopbackListener.listening())
        defer { listener.close() }
        let report = await ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(endpoint: Endpoint(host: "::1", port: listener.port)),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(3)
        ).run()

        let trace = try #require(report.steps.first { $0.id == DiagnosticStepID.trace })
        #expect(trace.outcome == .unavailable(NetworkTrace.ipv6UnmeasuredReason))
        // The positive anchor: the resolve step really did produce an IPv6
        // address, so the row above is the IPv6 branch and not a lookup that
        // failed.
        let resolve = try #require(report.steps.first { $0.id == DiagnosticStepID.resolve })
        #expect(resolve.detail.contains("IPv6 ::1"))
    }

    // MARK: - Fixtures

    /// What one foreign-unreachable run found.
    private struct ForeignUnreachable: Sendable {
        /// The same datagram IS returned when the wait is asked for the ports
        /// it actually carries — the proof it reached this socket at all.
        var acceptedForItsOwnPorts = false
        /// Nothing is returned when the wait expects another hop's
        /// destination port.
        var rejectedForAnotherDestinationPort = false
        /// Nothing is returned when the wait expects another probe socket's
        /// source port.
        var rejectedForAnotherSourcePort = false
    }

    /// Provokes a REAL port-unreachable from the kernel by sending to a
    /// loopback port nothing listens on, then asks the trace's wait for it
    /// three times: once with a foreign destination port, once with a foreign
    /// source port, and once with the pair the datagram actually carries.
    /// Three sends, because a wait consumes the datagram it rejects.
    ///
    /// Blocking, and only ever called from `onOwnQueue`.
    private static func injectForeignUnreachable() -> ForeignUnreachable {
        var result = ForeignUnreachable()
        let listener = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_ICMP))
        guard listener >= 0 else { return result }
        defer { Darwin.close(listener) }

        // A port outside the trace's own range, so a stray trace elsewhere on
        // the machine cannot be what this case reads.
        let foreignPort: UInt16 = 33_999

        guard let first = provokeUnreachable(port: foreignPort) else { return result }
        result.rejectedForAnotherDestinationPort = wait(
            on: listener, sourcePort: first, destinationPort: NetworkTrace.port(forHop: 1)) == nil

        guard let second = provokeUnreachable(port: foreignPort) else { return result }
        result.rejectedForAnotherSourcePort = wait(
            on: listener, sourcePort: second &+ 1, destinationPort: foreignPort) == nil

        guard let third = provokeUnreachable(port: foreignPort) else { return result }
        result.acceptedForItsOwnPorts = wait(
            on: listener, sourcePort: third, destinationPort: foreignPort) != nil
        return result
    }

    /// Sends one UDP datagram to a loopback port nothing listens on and
    /// returns the source port the kernel assigned it, so the caller can name
    /// the pair the resulting ICMP message quotes. The socket is closed
    /// afterwards; the message has already been generated by then — measured
    /// at 0.087 ms on 2026-09-03, and the wait below allows 500.
    private static func provokeUnreachable(port: UInt16) -> UInt16? {
        let sender = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        guard sender >= 0 else { return nil }
        defer { Darwin.close(sender) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sender, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sender, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let payload = Array("macSCP-trace-fixture".utf8)
        let written = payload.withUnsafeBytes { send(sender, $0.baseAddress, $0.count, 0) }
        guard written >= 0 else { return nil }
        return UInt16(bigEndian: assigned.sin_port)
    }

    private static func wait(
        on descriptor: Int32, sourcePort: UInt16, destinationPort: UInt16
    ) -> TraceAnswer? {
        let now = ContinuousClock().now
        return NetworkTrace.waitForAnswer(
            descriptor: descriptor, sourcePort: sourcePort, destinationPort: destinationPort,
            started: now, deadline: now.advanced(by: .milliseconds(500)))
    }

    /// Runs a blocking socket sequence on a queue of its own and suspends the
    /// caller on a continuation, so no cooperative-pool thread is parked in
    /// `poll` or `recvfrom`.
    private static func onOwnQueue<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue(label: "macscp.tests.network-trace").async {
                continuation.resume(returning: body())
            }
        }
    }

    private static func resolve(_ host: String) async -> ResolvedAddress? {
        guard
            case .resolved(let addresses) = await HostResolver.resolve(
                host: host, port: 0, timeout: .seconds(2))
        else { return nil }
        return addresses.first
    }

    /// A descriptor that answers the endpoint, dials a constant and
    /// contributes one step after it, so the trace's PLACE in the walk is what
    /// the runner case reads.
    private static func probeDescriptor(endpoint: Endpoint) -> BackendDescriptor {
        BackendDescriptor(
            kind: .s3,
            capabilities: BackendDescriptor.descriptor(for: .s3).capabilities,
            connectionSchema: ConnectionFieldSchema(fields: [], presets: []),
            credentialSchema: ConnectionFieldSchema(fields: [], presets: []),
            makeConfig: { _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            displaySummary: { _ in "" },
            apply: { _, _ in },
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: { _ in false },
            fileActions: [],
            endpoint: { _ in endpoint },
            dial: constant(id: DiagnosticStepID.dial, detail: "dialled"),
            diagnostics: [constant(id: "probe.after", detail: "after")])
    }

    private static func constant(id: String, detail: String) -> DiagnosticContribution {
        let key = DiagnosticStepID.titleKey(for: id)
        return DiagnosticContribution(id: id, titleKey: key) { _, _ in
            DiagnosticStepTimer(id: id, titleKey: key).finish(.ok, detail)
        }
    }
}

/// A listening loopback TCP socket, so the runner's TCP step has a port that
/// accepts while the trace step is what the case is actually reading.
private struct TraceLoopbackListener {
    let descriptor: Int32
    let port: Int

    func close() { Darwin.close(descriptor) }

    static func listening() -> TraceLoopbackListener? {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return TraceLoopbackListener(
            descriptor: descriptor, port: Int(UInt16(bigEndian: assigned.sin_port)))
    }
}
