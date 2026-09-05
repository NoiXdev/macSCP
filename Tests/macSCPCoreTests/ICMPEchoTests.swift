import Darwin
import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// The ICMP echo step, built from the verdicts `ICMPSpikeTests` measured
/// (design §5, macOS 26.6.2): an unprivileged `SOCK_DGRAM` ICMP socket sends
/// an echo request and receives the reply on both families, the IPv4 socket
/// hands the IP header up with the payload and the IPv6 socket does not, and
/// the ICMPv6 socket ALSO delivers this process's own outgoing request.
///
/// **Where the packets go.** Loopback only — `127.0.0.1` and `::1`. Nothing
/// is gated, because an unprivileged ICMP socket to loopback needs neither
/// the rig nor a route off the machine. `2001:db8::1` is NAMED by the
/// routeless case and never sent to: that case measures the route first and
/// returns without calling the subject when one exists.
///
/// **Why the suite is serialized.** The two injection cases put datagrams
/// into a socket space that is not demultiplexed (see
/// `aForeignEchoReplyIsNotCountedAsThisProbesAnswer`) under sequences chosen
/// by hand, so two of them running at once could take each other's. The
/// probing cases are safe on their own — each socket's payload nonce is
/// unique — but serializing the suite is cheaper than reasoning about which
/// half needs it.
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

    /// RFC 3849's documentation prefix — an address that is not routed on the
    /// public internet and that the routeless case never sends to.
    private static let documentationV6 = "2001:db8::1"

    // MARK: - IPv4

    /// The reply's TYPE is what pins the IPv4 header skip: an echo reply is
    /// type 0, and a reader that forgot to skip `ihl * 4` bytes would read
    /// the first byte of the IP header instead — `0x45`, i.e. 69.
    @Test func anEchoToIPv4LoopbackIsAnsweredByAnEchoReply() async throws {
        let address = try #require(await Self.loopback("127.0.0.1"))
        let outcome = await ICMPEcho.probe(address: address, count: 1, timeout: .seconds(2))
        let reply = try #require(outcome.replies.first, "no echo reply from 127.0.0.1: \(outcome)")

        #expect(outcome.sent == 1)
        #expect(reply.type == ICMPEcho.ipv4EchoReply)
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

    /// Three probes, three round-trip times, three consecutive sequences.
    ///
    /// The expectation is DERIVED from the first reply's own sequence, never
    /// written as `[1, 2, 3]`: the base is drawn at random per socket, so a
    /// literal would be pinning a numbering that changes every run — and
    /// pinning `1, 2, 3` is what let every pinger on the machine collide with
    /// this one in the first place.
    @Test func threeProbesProduceThreeRoundTripTimes() async throws {
        let address = try #require(await Self.loopback("127.0.0.1"))
        let outcome = await ICMPEcho.probe(address: address, count: 3, timeout: .seconds(5))
        let base = try #require(outcome.replies.first?.sequence, "no reply: \(outcome)")

        #expect(outcome.sent == 3)
        #expect(outcome.replies.count == 3)
        #expect(outcome.replies.map(\.sequence) == (0..<3).map { base &+ UInt16($0) })
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
        #expect(reply.rtt > .zero)
    }

    // MARK: - A datagram this probe never provoked

    /// **Measured 2026-09-03, and the reason this case exists.** An
    /// unprivileged ICMP DGRAM socket is not demultiplexed: it is handed every
    /// echo reply the machine receives. Two experiments, both on `127.0.0.1`:
    /// a second socket in this process sent an echo with identifier 4242 and
    /// sequence 77, and the *first* socket was handed the reply; and a plain
    /// `ping -c 3 127.0.0.1` in a separate process put three replies into a
    /// listening socket that had sent nothing at all.
    ///
    /// So "type and sequence" is not a match — a user with `ping` running in
    /// Terminal while they press Diagnose would have collected someone else's
    /// replies and read `3/3 replies` for a host that answered nothing. Only
    /// the echoed payload distinguishes them, and RFC 792 requires the reply
    /// to return it.
    ///
    /// The wait runs on a queue of its own: it polls and reads, which parks
    /// the thread it is on (CLAUDE.md, "Tests never block the cooperative
    /// pool").
    @Test func aForeignEchoReplyIsNotCountedAsThisProbesAnswer() async throws {
        let ours = ICMPEcho.probePayload()
        let theirs = Array("not-this-probes-payload".utf8)
        let result = try await Self.onOwnQueue { Self.injectForeignReply(ours: ours, theirs: theirs) }

        // The positive anchor, and it has to come first: the foreign datagram
        // really did reach OUR socket, and the wait really does return a reply
        // when it is asked for that datagram's own payload. Without this the
        // negative below would be satisfied by a socket that received nothing.
        #expect(result.acceptedWhenAskedForTheirPayload)
        #expect(result.rejectedWhenAskedForOurPayload)
    }

    /// A datagram carrying THIS probe's payload but an earlier probe's
    /// sequence is a late answer to that earlier request, and counting it for
    /// this one would time probe 2 from probe 1's flight.
    ///
    /// The sequence half of the match therefore needs a case of its own: with
    /// the payload check in place, no other case here can distinguish a
    /// matcher that checks the sequence from one that does not — on loopback
    /// each reply arrives long before the next request goes out, so a
    /// mismatch never occurs by accident.
    @Test func aReplyWithAnEarlierProbesSequenceIsNotCountedForThisOne() async throws {
        let ours = ICMPEcho.probePayload()
        let result = try await Self.onOwnQueue { Self.injectStaleSequence(payload: ours) }

        // Anchor first, same reasoning as above: the datagram reaches this
        // socket and IS returned when the wait expects the sequence it
        // carries.
        #expect(result.acceptedForItsOwnSequence)
        #expect(result.rejectedForAnotherSequence)
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
    /// sentence the panel will render, and **nothing is sent**.
    ///
    /// Ungated, and it still never leaves loopback, because the precondition
    /// is MEASURED before anything is sent — the spike file's own rule, that
    /// a "no" is a green test with a printed verdict. The destination is RFC
    /// 3849's documentation prefix; this machine had no route to it on
    /// 2026-09-03 (spike verdict (c)). On a machine that does have one, the
    /// case prints that and returns without calling the subject at all, so no
    /// packet goes anywhere in either branch.
    ///
    /// The precondition uses the TEST's own `connect` probe, not the
    /// subject's: deciding the expectation with the code under test would
    /// make the case tautological and would undo the mutation probe that pins
    /// the route check. `connect` on an unconnected UDP socket sends nothing.
    ///
    /// **The anchor is a counted `sendto`, not `outcome.sent`.**
    /// `ICMPEchoOutcome.sent` is `0` for every `.unavailable` by
    /// construction, so reading it back after asserting the case is
    /// `.unavailable` says nothing at all: move the route check below the
    /// send loop and three packets leave for `2001:db8::1` with both of those
    /// expectations still green. `TransmitLog` counts the datagrams the
    /// subject actually hands to `sendto`, and the loopback half below counts
    /// the same way — a counter that cannot rise would prove nothing either.
    @Test func anIPv6AddressWithNoRouteIsUnavailableAndSendsNothing() async throws {
        let address = try #require(await Self.loopback(Self.documentationV6))
        switch try await Self.onOwnQueue({ Self.routeVerdict(for: Self.documentationV6) }) {
        case .routed:
            print(
                "ICMPEcho: this machine has a route to \(Self.documentationV6) — the routeless "
                    + "branch is unmeasured here, and nothing was sent")
            return
        case .cannotMeasure(let reason):
            print("ICMPEcho: the routeless branch is unmeasured here (\(reason)); nothing was sent")
            return
        case .noRoute:
            break
        }

        let routeless = TransmitLog()
        let outcome = await ICMPEcho.probe(
            address: address, count: 3, timeout: .seconds(2), onTransmit: routeless.observer)
        #expect(outcome == .unavailable(ICMPEcho.noIPv6RouteReason))
        #expect(routeless.count == 0)

        // The positive companion, in the same case so neither can be read
        // without the other: the same counter, the same probe count, an
        // address that IS routed — and three datagrams.
        let loopback = TransmitLog()
        let reachable = try #require(await Self.loopback("127.0.0.1"))
        _ = await ICMPEcho.probe(
            address: reachable, count: 3, timeout: .seconds(2), onTransmit: loopback.observer)
        #expect(loopback.count == 3)
    }

    /// The nonce is drawn per SOCKET, and that is the half of the reply check
    /// the marker does not cover.
    ///
    /// Nothing about an outcome can see it: a payload that round-trips looks
    /// identical whether it was drawn once per probe or once per process. So
    /// this reads the datagrams themselves — two probes' payloads must
    /// differ, one probe's three must agree, and all of them must carry the
    /// marker.
    ///
    /// Without it, hoisting `probePayload()` to a `static let` — an
    /// obvious-looking cleanup, 26 bytes saved per probe — keeps every other
    /// case in this file green and reinstates C-1 in full for the multi-window
    /// build CLAUDE.md has planned: two panels diagnosing at once, each
    /// matching the other's replies, each reporting `3/3 replies` for a host
    /// that answered nothing.
    @Test func twoProbesDrawDifferentNoncesAndOneProbeKeepsItsOwn() async throws {
        let address = try #require(await Self.loopback("127.0.0.1"))
        let first = TransmitLog()
        let second = TransmitLog()
        _ = await ICMPEcho.probe(
            address: address, count: 3, timeout: .seconds(2), onTransmit: first.observer)
        _ = await ICMPEcho.probe(
            address: address, count: 3, timeout: .seconds(2), onTransmit: second.observer)

        let firstPayloads = first.payloads
        let secondPayloads = second.payloads
        // The anchor: there are datagrams to compare, and they carry the
        // marker — which is what separates macSCP from every other pinger,
        // and which nothing else in this file reads.
        #expect(firstPayloads.count == 3)
        #expect(secondPayloads.count == 3)
        #expect((firstPayloads + secondPayloads).allSatisfy { $0.starts(with: ICMPEcho.payloadMarker) })

        // One socket: all three probes carry the same payload, so a reply to
        // any of them is recognisable as this probe's.
        #expect(Set(firstPayloads).count == 1)
        #expect(Set(secondPayloads).count == 1)
        // Two sockets: different payloads, so neither can match the other's
        // replies.
        #expect(firstPayloads.first != secondPayloads.first)
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
                DiagnosticStepID.dial, DiagnosticStepID.trace,
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

    /// What one foreign-injection run found.
    private struct ForeignInjection: Sendable {
        /// The wait returned nothing when it was told to expect OUR payload.
        var rejectedWhenAskedForOurPayload = false
        /// The same datagram WAS returned when the wait was told to expect the
        /// foreign payload — the proof that it reached this socket at all.
        var acceptedWhenAskedForTheirPayload = false
    }

    /// Sends an echo request from a SECOND socket and asks the first socket's
    /// wait for it twice: once expecting this probe's payload, once expecting
    /// the foreign one. Two sends, because a wait consumes the datagram it
    /// rejects.
    ///
    /// Blocking, and only ever called from `onOwnQueue`.
    private static func injectForeignReply(ours: [UInt8], theirs: [UInt8]) -> ForeignInjection {
        var result = ForeignInjection()
        let listener = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_ICMP))
        guard listener >= 0 else { return result }
        defer { Darwin.close(listener) }
        let foreignSequence: UInt16 = 0xBEEF

        // The wait is asked for OUR payload; the datagram carries theirs.
        guard send(payload: theirs, sequence: foreignSequence) else { return result }
        result.rejectedWhenAskedForOurPayload = wait(
            on: listener, sequence: foreignSequence, payload: ours) == nil

        // The same datagram, and this time the wait is asked for the payload
        // it actually carries.
        guard send(payload: theirs, sequence: foreignSequence) else { return result }
        result.acceptedWhenAskedForTheirPayload = wait(
            on: listener, sequence: foreignSequence, payload: theirs) != nil
        return result
    }

    /// What one stale-sequence run found.
    private struct StaleSequence: Sendable {
        var rejectedForAnotherSequence = false
        var acceptedForItsOwnSequence = false
    }

    /// Sends this probe's own payload under one sequence and asks the wait
    /// for it under another, then under its own. Blocking; only ever called
    /// from `onOwnQueue`.
    private static func injectStaleSequence(payload: [UInt8]) -> StaleSequence {
        var result = StaleSequence()
        let listener = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_ICMP))
        guard listener >= 0 else { return result }
        defer { Darwin.close(listener) }
        let earlier: UInt16 = 0x1000
        let current: UInt16 = 0x1001

        guard send(payload: payload, sequence: earlier) else { return result }
        result.rejectedForAnotherSequence = wait(
            on: listener, sequence: current, payload: payload) == nil

        guard send(payload: payload, sequence: earlier) else { return result }
        result.acceptedForItsOwnSequence = wait(
            on: listener, sequence: earlier, payload: payload) != nil
        return result
    }

    /// One echo request to `127.0.0.1` from a socket of its own — the "other
    /// pinger on the machine". Built by the production packet writer so the
    /// checksum is not a second implementation.
    private static func send(payload: [UInt8], sequence: UInt16) -> Bool {
        let sender = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_ICMP))
        guard sender >= 0 else { return false }
        defer { Darwin.close(sender) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let packet = ICMPEcho.request(
            type: ICMPEcho.ipv4EchoRequest, identifier: 0xFEED, sequence: sequence,
            payload: payload, computeChecksum: true)
        let written = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                packet.withUnsafeBytes { buffer in
                    sendto(
                        sender, buffer.baseAddress, buffer.count, 0, target,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return written >= 0
    }

    private static func wait(
        on descriptor: Int32, sequence: UInt16, payload: [UInt8]
    ) -> ICMPEchoReply? {
        let now = ContinuousClock().now
        return ICMPEcho.waitForReply(
            descriptor: descriptor, family: AF_INET, replyType: ICMPEcho.ipv4EchoReply,
            sequence: sequence, payload: payload, started: now,
            deadline: now.advanced(by: .milliseconds(500)))
    }

    /// What this machine's routing table says about an IPv6 address.
    ///
    /// Three answers, not two, because the subject distinguishes them: a
    /// REFUSED IPv6 socket is not a routing fact, and reporting it as one
    /// would make the routeless case red against
    /// `.unavailable("Address family not supported by protocol family")` on a
    /// runner with IPv6 switched off at the socket layer — an assertion about
    /// the machine, which is what this case was rewritten to stop making.
    private enum RouteVerdict {
        case noRoute
        case routed
        /// No IPv6 socket here at all; the question cannot be asked.
        case cannotMeasure(String)
    }

    /// The test's OWN route probe, independent of the subject's: `connect` on
    /// an unconnected UDP socket consults the routing table and sends nothing.
    /// Deliberately a second implementation of those few lines — using
    /// `ICMPEcho`'s would decide the expectation with the code under test.
    private static func routeVerdict(for host: String) -> RouteVerdict {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, Int32(IPPROTO_UDP))
        let socketErrno = errno
        guard descriptor >= 0 else {
            return .cannotMeasure("no IPv6 socket: \(String(cString: strerror(socketErrno)))")
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(33434).bigEndian
        guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else {
            return .cannotMeasure("\(host) is not an IPv6 literal")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return connected == 0 ? .routed : .noRoute
    }

    /// Counts the datagrams a probe hands to `sendto`, and keeps their bytes.
    ///
    /// `@unchecked Sendable` over a lock: the observer is called on the
    /// probe's own queue and read from the test's task, which is exactly the
    /// crossing `Sendable` is asking about.
    private final class TransmitLog: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []

        var observer: ICMPEcho.TransmitObserver {
            { [self] packet in
                lock.lock()
                packets.append(packet)
                lock.unlock()
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return packets.count
        }

        /// The echoed data of each datagram: everything past the eight-byte
        /// ICMP header this side writes.
        var payloads: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return packets.map { Array($0.dropFirst(8)) }
        }
    }

    /// Runs a blocking socket sequence on a queue of its own and suspends the
    /// caller on a continuation, so no cooperative-pool thread is parked in
    /// `poll` or `recvfrom`.
    private static func onOwnQueue<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async throws -> T {
        try await awaitResumption { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue(label: "macscp.tests.icmp-echo").async {
                continuation.resume(returning: body())
            }
        }
    }

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
