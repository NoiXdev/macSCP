import Darwin
import Foundation
import Testing

@testable import macSCPCore

/// The ICMP echo step, built from the verdicts `ICMPSpikeTests` measured
/// (design §5, macOS 26.6.2): an unprivileged `SOCK_DGRAM` ICMP socket sends
/// an echo request and receives the reply on both families, the IPv4 socket
/// hands the IP header up with the payload and the IPv6 socket does not, and
/// the ICMPv6 socket ALSO delivers this process's own outgoing request.
///
/// **Where the packets go.** Loopback only — `127.0.0.1` and `::1`. No other
/// destination is ever contacted, and nothing here is gated because an
/// unprivileged ICMP socket to loopback needs neither the rig nor a route off
/// the machine.
///
/// **Why the suite is serialized.** Every case here opens an ICMP socket in
/// the same process and matches replies by sequence, so two cases running at
/// once could each take the other's answer. Serialized rather than made
/// unique by identifier: the identifier is exactly the field the verdict says
/// an implementation must not depend on.
///
/// **Why no test parks a thread.** `ICMPEcho` runs its whole socket sequence
/// on a `DispatchQueue` of its own and is awaited through a continuation
/// (CLAUDE.md, "Tests never block the cooperative pool"); the tests only
/// `await`.
@Suite("ICMPEcho", .serialized)
struct ICMPEchoTests {
    /// A family no `socket` call can serve — past Darwin's `AF_MAX`, so the
    /// kernel refuses with `EAFNOSUPPORT` and the step has a real errno to
    /// report rather than a synthetic sentence.
    private static let unsupportedFamily: Int32 = 255

    // MARK: - IPv4

    /// The reply's TYPE is what pins the IPv4 header skip: an echo reply is
    /// type 0, and a reader that forgot to skip `ihl * 4` bytes would read
    /// the first byte of the IP header instead — `0x45`, i.e. 69.
    @Test func anEchoToIPv4LoopbackIsAnsweredWithTheSentSequence() async throws {
        let address = try #require(await Self.loopback("127.0.0.1"))
        let outcome = await ICMPEcho.probe(address: address, count: 1, timeout: .seconds(2))
        let reply = try #require(outcome.replies.first, "no echo reply from 127.0.0.1: \(outcome)")

        #expect(outcome.sent == 1)
        #expect(reply.type == ICMPEcho.ipv4EchoReply)
        #expect(reply.sequence == 1)
        #expect(reply.rtt > .zero)
        #expect(reply.source == "127.0.0.1")

        // The identifier is RECORDED, never required. It came back unchanged
        // on macOS 26.6.2 (design §5) and the design had assumed it would be
        // rewritten; a case that demanded either answer would be red on the
        // machine that gives the other one.
        print(
            "ICMPEcho identifier: sent \(ICMPEcho.identifier), delivered \(reply.identifier) "
                + "(\(reply.identifier == ICMPEcho.identifier ? "unchanged" : "rewritten"))")
    }

    @Test func threeProbesProduceThreeRoundTripTimes() async throws {
        let address = try #require(await Self.loopback("127.0.0.1"))
        let outcome = await ICMPEcho.probe(address: address, count: 3, timeout: .seconds(5))

        #expect(outcome.sent == 3)
        #expect(outcome.replies.map(\.sequence) == [1, 2, 3])
        #expect(outcome.replies.allSatisfy { $0.rtt > .zero })
    }

    // MARK: - IPv6

    /// The ICMPv6 socket receives this process's OWN outgoing request as well
    /// as the reply, and the two agree on every other field a matcher could
    /// use — same identifier, same sequence, same source `::1`. The type is
    /// the only thing that tells them apart, so it is the thing asserted:
    /// 129 is the reply, 128 is the request coming back at us.
    @Test func anEchoToIPv6LoopbackIsAnsweredByAReplyAndNotByItsOwnRequest() async throws {
        let address = try #require(await Self.loopback("::1"))
        let outcome = await ICMPEcho.probe(address: address, count: 1, timeout: .seconds(2))
        let reply = try #require(outcome.replies.first, "no echo reply from ::1: \(outcome)")

        #expect(reply.type == ICMPEcho.ipv6EchoReply)
        #expect(reply.type != ICMPEcho.ipv6EchoRequest)
        #expect(reply.sequence == 1)
        #expect(reply.rtt > .zero)
    }

    // MARK: - What this machine cannot do

    /// A socket the kernel refuses is about THIS machine, not about the
    /// server, so it is `unavailable` carrying the kernel's own sentence —
    /// and it leaves the step by returning, never by throwing.
    @Test func anUnsupportedAddressFamilyIsUnavailableRatherThanThrowing() async {
        let outcome = await ICMPEcho.probe(
            address: Self.unsupportedFamilyAddress(), count: 3, timeout: .seconds(2))

        guard case .unavailable(let reason) = outcome else {
            Issue.record("an unsupported family did not report unavailable: \(outcome)")
            return
        }
        #expect(reason == String(cString: strerror(EAFNOSUPPORT)))
        #expect(outcome.replies.isEmpty)
    }

    /// An IPv6 address this machine has no route to is `unavailable` with the
    /// sentence the panel will render, and **nothing is sent**: the route
    /// probe is a `connect` on an unconnected UDP socket, which only consults
    /// the routing table.
    ///
    /// Gated, and the gate is the point. The destination is RFC 3849's
    /// documentation prefix, the same one the spike's (c) case uses, and the
    /// case asserts a property of THE MACHINE — that it has no global IPv6
    /// route, which is what verdict (c) recorded here on 2026-09-03. On a
    /// machine that does have one, the route probe succeeds and this becomes
    /// a measurement of something else entirely; `MACSCP_NETSPIKE=1` is the
    /// declaration that the runner knows what its network does.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSCP_NETSPIKE"] == "1"))
    func anIPv6AddressWithNoRouteIsUnavailableAndSendsNothing() async throws {
        let address = try #require(await Self.loopback("2001:db8::1"))
        let outcome = await ICMPEcho.probe(address: address, count: 3, timeout: .seconds(2))
        #expect(outcome == .unavailable("no IPv6 route"))
        // The positive anchor for that sentence: nothing went out, which is
        // what separates "no route" from "sent and heard nothing back".
        #expect(outcome.sent == 0)
    }

    // MARK: - The step in the runner

    @Test func theRunnerPutsTheEchoBetweenTheTCPPingAndTheDial() async throws {
        let listener = try #require(LoopbackListener.listening())
        defer { listener.close() }

        let report = await ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port)),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(5)
        ).run()

        #expect(
            report.steps.map(\.id) == [
                DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
                DiagnosticStepID.dial,
            ])
        let icmp = try #require(report.steps.first { $0.id == DiagnosticStepID.icmp })
        #expect(icmp.outcome == .ok)
        #expect(icmp.titleKey == "diagnostics.step.icmp")
        // Three probes, and the three numbers the row promises.
        #expect(icmp.detail.hasPrefix("127.0.0.1 3/3 replies"))
        #expect(icmp.detail.contains("min "))
        #expect(icmp.detail.contains("avg "))
        #expect(icmp.detail.contains("max "))
    }

    /// Nothing resolved means nothing to echo — `skipped`, which says "there
    /// was no probe to run", not `failed`, which would say the server is at
    /// fault for a lookup that never produced an address.
    @Test func anEchoWithNothingResolvedIsSkipped() async {
        let report = await ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "not-a-numeric-address", port: 22)),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(2)
        ).run()

        guard let icmp = report.steps.first(where: { $0.id == DiagnosticStepID.icmp }) else {
            Issue.record("no icmp step in \(report.steps.map(\.id))")
            return
        }
        guard case .skipped = icmp.outcome else {
            Issue.record("an unresolved host did not skip the echo: \(icmp.outcome)")
            return
        }
    }

    // MARK: - Fixtures

    private static func loopback(_ host: String) async -> ResolvedAddress? {
        guard
            case .resolved(let addresses) = await HostResolver.resolve(
                host: host, port: 0, timeout: .seconds(2))
        else { return nil }
        return addresses.first
    }

    /// A resolved address whose BYTES declare a family no kernel serves. The
    /// label stays `.ipv4`, which is the point: `ICMPEcho` asks the socket
    /// address itself what to open, not the record's label.
    private static func unsupportedFamilyAddress() -> ResolvedAddress {
        var storage = sockaddr_storage()
        storage.ss_len = UInt8(MemoryLayout<sockaddr_in>.size)
        storage.ss_family = sa_family_t(truncatingIfNeeded: Self.unsupportedFamily)
        let socketAddress = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                ProbeSocketAddress($0, length: socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ResolvedAddress(family: .ipv4, text: "127.0.0.1", socketAddress: socketAddress)
    }

    /// A descriptor that answers the endpoint and dials a constant, so the
    /// step ORDER is what the runner test reads and not a real connect.
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
            dial: DiagnosticContribution(
                id: DiagnosticStepID.dial, titleKey: "diagnostics.step.dial"
            ) { _, _ in
                DiagnosticStepTimer(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.dial"
                ).finish(.ok, "dialled")
            },
            diagnostics: [])
    }
}

/// A listening loopback TCP socket, so the runner's TCP step has something to
/// accept it while the ICMP step is what the case is actually reading.
private struct LoopbackListener {
    let descriptor: Int32
    let port: Int

    func close() { Darwin.close(descriptor) }

    static func listening() -> LoopbackListener? {
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
        return LoopbackListener(
            descriptor: descriptor, port: Int(UInt16(bigEndian: assigned.sin_port)))
    }
}
