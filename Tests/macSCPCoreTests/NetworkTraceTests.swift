import Darwin
import Foundation
import Testing

@testable import macSCPCore

/// A one-shot gate a BLOCKING body can park on until something else opens it.
///
/// The blocking twin of `AsyncSignal`, and it exists for the one place an
/// `await` cannot go: the walk body `NetworkTrace.run` hands to
/// `BlockingProbe` is a synchronous closure running on that probe's own
/// private queue. It is not a cooperative-pool thread — the same thread the
/// `Thread.sleep` this replaces held — so parking it breaks no rule of
/// CLAUDE.md's "Tests never block the cooperative pool"; what it does break
/// is the habit of guessing a duration.
///
/// `NSCondition`, not a semaphore or a dispatch group: those two are the
/// spellings `TestsNeverBlockThePoolGuardTests` forbids outright, and this
/// needs neither a count nor a group — one flag, and every waiter released
/// when it flips.
///
/// `wait(until:)` takes a deadline that is a NET, not the property: it is
/// there so a seam that stops being called fails the case in half a minute
/// instead of parking a thread for the life of the process. `wasOpened` is
/// what a test asserts on, and it distinguishes the two.
final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false

    /// Safe from any thread, and idempotent.
    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }

    /// Whether `open()` was ever called — readable without waiting, and true
    /// by the time the call that opened the gate has returned.
    var wasOpened: Bool {
        condition.lock()
        defer { condition.unlock() }
        return opened
    }

    /// Blocks until the gate opens or `deadline` passes.
    func wait(until deadline: Date) {
        condition.lock()
        defer { condition.unlock() }
        while !opened {
            if !condition.wait(until: deadline) { return }
        }
    }
}

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

    /// RFC 5737 TEST-NET-3, which the value cases NAME and never open a socket
    /// to. It stands in for "the destination this walk was aimed at" wherever
    /// an outcome is built by hand.
    private static let documentationV4 = "203.0.113.9"

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
            NetworkTraceOutcome.measured(
                hops: [hop], destination: "10.0.0.1", ending: .answered
            ).reachedDestination)
        #expect(
            NetworkTraceOutcome.measured(
                hops: [hop], destination: Self.documentationV4, ending: .answered
            ).reachedDestination == false)
        // And a hop that merely forwarded is never an arrival, whatever
        // address it came from.
        let forwarded = NetworkTraceHop(
            ttl: 4, outcome: .forwarded(address: "10.0.0.1", rtt: .milliseconds(1)))
        #expect(
            NetworkTraceOutcome.measured(
                hops: [forwarded], destination: "10.0.0.1", ending: .hopLimit
            ).reachedDestination == false)
    }

    // MARK: - The budget, and what ended the walk

    /// A walk the STEP'S BUDGET ends is not a walk that found the end of the
    /// path, and the detail line has to say which it was.
    ///
    /// Measured through a fake hop source AND a fake clock rather than a
    /// network: the property is about the walk's endings, a real path that
    /// ends on a budget needs a slow route nobody can guarantee, and a
    /// fixture that provoked it by sleeping would be measuring the runner
    /// (CLAUDE.md, "Tests never block the cooperative pool", and the ceilings
    /// this project has already had to remove). The fake hop source says how
    /// much time each hop took; nothing here waits for any.
    ///
    /// The anchor comes first, and it is the same fake with room to run: five
    /// hops, ended by the hop limit, and NO marker. Without it the marker
    /// below would be satisfied by a walk that always claims the budget ended
    /// it.
    @Test func aWalkTheBudgetEndsSaysSoAndDropsTheHopItCouldNotMeasure() {
        let roomy = Self.fakeWalk(
            budget: .seconds(5), hopCost: .milliseconds(2), answering: 5, maxHops: 5)
        #expect(roomy.ending == .hopLimit)
        #expect(roomy.hops.map(\.ttl) == [1, 2, 3, 4, 5])
        #expect(
            ConnectionDiagnostics.traceDetail(roomy)
                .contains(DiagnosticReason.stoppedByBudget) == false)

        // Three hops of 1.5 s answer inside a 5 s budget; the fourth starts
        // with half a second left, which is less than a hop's own second.
        let cut = Self.fakeWalk(
            budget: .seconds(5), hopCost: .milliseconds(1500), answering: 3, maxHops: 5)
        #expect(cut.ending == .budget)
        // Hop 4 answered nothing, but it was never given its second — a `*`
        // row there would claim a measurement nobody made, which is the whole
        // finding. Only the three that were fully waited for are reported.
        #expect(cut.hops.map(\.ttl) == [1, 2, 3])
        #expect(
            ConnectionDiagnostics.traceDetail(cut)
                .hasSuffix(DiagnosticReason.traceStoppedByBudget(afterHop: 3)))
        // A hop DID answer, so the step is not the deadline's answer.
        #expect(ConnectionDiagnostics.traceOutcome(cut) == .ok)
    }

    /// The kernel refusing a hop mid-walk is not the hop limit and not a
    /// silence: it is a local failure, it ends the walk, and `strerror`'s own
    /// sentence has to reach the report.
    ///
    /// Before this it returned `.hopLimit` — an ending whose doc comment says
    /// thirty probes went out — and the reason string was dropped on the
    /// floor. A laptop that changes network mid-diagnosis is the ordinary way
    /// to provoke it.
    @Test func aKernelRefusalEndsTheWalkAsARefusalAndKeepsWhatItMeasured() {
        let refusal = "No route to host"
        let outcome = Self.fakeWalk(
            budget: .seconds(20), hopCost: .milliseconds(2), answering: 10,
            refusingFrom: 4, refusal: refusal, maxHops: 10)

        #expect(outcome.ending == .refused(refusal))
        // The hops it did measure survive, which is the half a plain
        // `.unavailable` would have thrown away.
        #expect(outcome.hops.map(\.ttl) == [1, 2, 3])
        #expect(ConnectionDiagnostics.traceOutcome(outcome) == .failed(refusal))
        let detail = ConnectionDiagnostics.traceDetail(outcome)
        #expect(detail.hasPrefix("1 10.0.0.1 "))
        // Neither marker: the trace did not stop looking and did not run out
        // of hops.
        #expect(detail.contains(DiagnosticReason.stoppedByBudget) == false)
        #expect(detail.contains(DiagnosticReason.hopLimitReached) == false)
    }

    /// A receiving socket that fails is a fact about THIS machine, and every
    /// hop after it would otherwise print `*` in microseconds — thirty rows
    /// claiming a silent path, drawn entirely from a local error.
    ///
    /// The anchor comes first and is the same call on a WORKING socket with
    /// nothing arriving: that is a silence, and it must still read as one.
    ///
    /// **Which of the two failure exits this reaches, measured 2026-09-03.**
    /// `poll` on a closed descriptor does not return `-1`: it returns 1 with
    /// `POLLNVAL` in `revents`, so the wait proceeds to `recvfrom`, which
    /// answers `EBADF` — and that is the exit pinned here (planting `.silent`
    /// in the `recvfrom` branch turns this case red; planting it in the
    /// `poll` branch does not). The `poll` branch stays unpinned: its
    /// remaining errnos are `EINVAL`, `EFAULT` and `ENOMEM`, none of which is
    /// reachable through this signature. Both exits return `.failed` with
    /// `strerror`'s own sentence, so the shape they produce is the same one.
    @Test func aBrokenReceivingSocketIsAFailureAndNeverASilentHop() async {
        let result = await Self.onOwnQueue { Self.waitOnASocketAndOnABrokenOne() }

        #expect(result.openSocketIsSilent)
        #expect(result.brokenSocketFails)
        // `strerror`'s own sentence, not a synthetic one — the same contract
        // every other local-end refusal in this module keeps.
        #expect(result.failureReason == String(cString: strerror(EBADF)))
    }

    /// The outcome→step mapping, over outcomes built by hand.
    ///
    /// The same shape as `anUnreachableFromSomeOtherAddressIsNotAnArrival`,
    /// and for the same reason: none of these four situations can be provoked
    /// on loopback, where the only address that answers is the destination and
    /// the only code it sends is 3.
    @Test func theStepMappingSeparatesAnArrivalFromABudgetAndFromARefusal() {
        let answered = NetworkTraceHop(
            ttl: 1, outcome: .forwarded(address: "10.0.0.1", rtt: .milliseconds(2)))
        let silent = NetworkTraceHop(ttl: 1, outcome: .timedOut)
        let arrival = NetworkTraceHop(
            ttl: 2,
            outcome: .unreachable(
                address: Self.documentationV4, rtt: .milliseconds(3),
                code: NetworkTrace.portUnreachableCode))
        let refusal = NetworkTraceHop(
            ttl: 4,
            outcome: .unreachable(address: "10.0.0.1", rtt: .milliseconds(3), code: 13))

        // The anchor: an ordinary arrival is `.ok` and carries no marker.
        let reached = NetworkTraceOutcome.measured(
            hops: [answered, arrival], destination: Self.documentationV4, ending: .answered)
        #expect(ConnectionDiagnostics.traceOutcome(reached) == .ok)
        #expect(
            ConnectionDiagnostics.traceDetail(reached)
                .contains(DiagnosticReason.stoppedByBudget) == false)

        // The budget with nothing answered is the deadline's answer, and says
        // so twice — in the badge and in the marker.
        let nothing = NetworkTraceOutcome.measured(
            hops: [silent], destination: Self.documentationV4, ending: .budget)
        #expect(ConnectionDiagnostics.traceOutcome(nothing) == .timedOut)
        #expect(
            ConnectionDiagnostics.traceDetail(nothing)
                .hasSuffix(DiagnosticReason.traceStoppedByBudget(afterHop: 1)))

        // The budget with a hop that answered is a partial measurement, not a
        // failure to measure.
        let partial = NetworkTraceOutcome.measured(
            hops: [answered], destination: Self.documentationV4, ending: .budget)
        #expect(ConnectionDiagnostics.traceOutcome(partial) == .ok)

        // The hop limit is the trace's own limit, not the path's end. Same
        // rule as the budget: hops that answered were measured, so the row is
        // `.ok`, and the detail says what stopped the walk.
        let limited = NetworkTraceOutcome.measured(
            hops: [answered], destination: Self.documentationV4, ending: .hopLimit)
        #expect(ConnectionDiagnostics.traceOutcome(limited) == .ok)
        #expect(
            ConnectionDiagnostics.traceDetail(limited)
                .hasSuffix(DiagnosticReason.traceHopLimitReached(afterHop: 1)))

        // The marker names the last row's own TTL, not the number of rows.
        // They differ only if a hop is ever dropped from the middle — which
        // nothing does today, and which is why the review could name this and
        // no fixture could see it. A gap in the hop numbers is the cheapest
        // way to make the two answers disagree.
        let gapped = NetworkTraceOutcome.measured(
            hops: [answered, NetworkTraceHop(ttl: 5, outcome: answered.outcome)],
            destination: Self.documentationV4, ending: .budget)
        #expect(
            ConnectionDiagnostics.traceDetail(gapped)
                .hasSuffix(DiagnosticReason.traceStoppedByBudget(afterHop: 5)))

        let limitedInSilence = NetworkTraceOutcome.measured(
            hops: [silent], destination: Self.documentationV4, ending: .hopLimit)
        #expect(ConnectionDiagnostics.traceOutcome(limitedInSilence) == .timedOut)

        // A router answering with a code of its own is a finding ABOUT THE
        // PATH — a policy block reads as one, not as a slow network.
        let refused = NetworkTraceOutcome.measured(
            hops: [answered, refusal], destination: Self.documentationV4, ending: .answered)
        let outcome = ConnectionDiagnostics.traceOutcome(refused)
        #expect(outcome == .failed(DiagnosticReason.traceHopUnreachable(code: 13, hop: 4)))
        // Derived above, so the two numbers are read here: a sentence that
        // dropped either would still equal the builder's own output.
        guard case .failed(let reason) = outcome else {
            Issue.record("a mid-path refusal did not fail the step: \(outcome)")
            return
        }
        #expect(reason.contains("13"))
        #expect(reason.contains("hop 4"))

        // And the refusal is read BEFORE the budget. The one path that
        // reaches here with both is the outer margin abandoning a walk that
        // had already ended at a refusal: `run`'s fallback labels the ending
        // `.budget` from the collector, and a mapping that tested the budget
        // first would badge a policy block `ok` and claim the trace merely
        // stopped looking.
        let abandonedAfterRefusal = NetworkTraceOutcome.measured(
            hops: [answered, refusal], destination: Self.documentationV4, ending: .budget)
        #expect(
            ConnectionDiagnostics.traceOutcome(abandonedAfterRefusal)
                == .failed(DiagnosticReason.traceHopUnreachable(code: 13, hop: 4)))
    }

    /// The OUTER deadline — the margin `BlockingProbe` is given on top of the
    /// walk's own budget — must not throw away the hops the walk had already
    /// measured. Before the collector, an overrun there printed an empty
    /// detail line for a walk that had eight hops.
    ///
    /// The abandonment is FORCED here, not raced. It used to be raced: the
    /// walk slept 400 ms and the outer margin fired at 250 ms
    /// (`NetworkTrace.run`'s `timeout + .milliseconds(250)`, with
    /// `timeout: .zero`), so the property rested on a 150 ms window between
    /// a Dispatch timer and a sleep — and a busy machine erases it in either
    /// direction. It reddened on ambient load alone, on this branch and at
    /// its branch point, most recently in Task 4's round-3 full run
    /// (`(outcome.ending → .hopLimit) == .budget`); it is also inside one of
    /// the four suites that lost their verdict in CI run 33741778350.
    ///
    /// So the walk parks on a gate that only the abandonment opens. The
    /// margin cannot lose, because the thing it is racing does not finish
    /// until the margin has already won. What is asserted is what was
    /// asserted before — the hops survive, and the ending names the budget —
    /// with no duration compared against any other duration anywhere in the
    /// case.
    @Test(.timeLimit(.minutes(1)))
    func anOuterMarginOverrunKeepsTheHopsTheWalkHadMeasured() async {
        let measured = NetworkTraceHop(
            ttl: 1, outcome: .forwarded(address: "10.0.0.1", rtt: .milliseconds(2)))
        let collector = TraceHopCollector()
        let abandoned = BlockingGate()
        let walkReturned = AsyncSignal()
        let outcome = await NetworkTrace.run(
            destination: Self.documentationV4, timeout: .zero, collector: collector,
            onAbandon: { abandoned.open() }
        ) { _, collected in
            collected.append(measured)
            // Parked on `BlockingProbe`'s OWN private queue and never on the
            // cooperative pool — the same place the `Thread.sleep` this
            // replaces ran, which is why neither needed a different spelling
            // to be honest. The difference is that a sleep guesses how long
            // the margin will take and this waits until it has happened.
            //
            // The value returned below is the one that gets dropped, which is
            // the point of the case.
            abandoned.wait(until: Date().addingTimeInterval(30))
            walkReturned.signal()
            return .measured(
                hops: collected.hops, destination: Self.documentationV4, ending: .hopLimit)
        }

        // The positive check beside the two below: without it they would also
        // pass on a run where the walk was released by the gate's own net
        // rather than by the margin, and a seam that had stopped being called
        // would read exactly like a seam that works.
        #expect(abandoned.wasOpened, "the outer margin never reported an abandonment")
        #expect(outcome.hops == [measured])
        // And it is honest about why it is short: the budget, not the path.
        #expect(outcome.ending == .budget)

        // Read first, healed second: the walk is joined only after every
        // assertion, so nothing it does on the way out can supply a value one
        // of them wanted. It also leaves no thread parked behind the case.
        _ = await walkReturned.wait()
    }

    /// The trace spends the budget it was HANDED, and not the one every other
    /// step gets.
    ///
    /// The anchor is the same endpoint with room to walk: loopback answers at
    /// hop 1 and the row is `.ok`. The starved run then hands the trace no
    /// budget at all while leaving `stepTimeout` generous — and no budget is
    /// what it takes, because loopback answers in a tenth of a millisecond and
    /// any positive budget is enough for it. That is exactly what makes this a
    /// plumbing check rather than a race: the row can only come out cut if the
    /// value the trace used is the value the trace was given.
    @Test func theTraceSpendsItsOwnBudgetRatherThanTheStepTimeout() async throws {
        let reached = try #require(await Self.traceStep(budget: .seconds(3)))
        #expect(reached.outcome == .ok)
        #expect(reached.detail.hasPrefix("1 127.0.0.1 "))

        let cut = try #require(await Self.traceStep(budget: .zero))
        #expect(cut.outcome == .timedOut)
        #expect(cut.detail == DiagnosticReason.traceStoppedByBudget(afterHop: 0))
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
        let result = NetworkTrace.waitForAnswer(
            descriptor: descriptor, sourcePort: sourcePort, destinationPort: destinationPort,
            started: now, deadline: now.advanced(by: .milliseconds(500)))
        guard case .answered(let answer) = result else { return nil }
        return answer
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

    /// One whole diagnosis against loopback, with a generous `stepTimeout` and
    /// the trace budget under test, returning the trace's row.
    ///
    /// A listener of its OWN per run, and that is not tidiness: a listening
    /// socket nobody accepts from holds a backlog of one, so a second run
    /// against the same listener has its SYN dropped and the TCP step spends
    /// the whole `stepTimeout` — measured at exactly 5.004 s before this was
    /// split, in a case that has nothing to do with TCP.
    private static func traceStep(budget: Duration) async -> DiagnosticStep? {
        guard let listener = TraceLoopbackListener.listening() else { return nil }
        defer { listener.close() }
        let report = await ConnectionDiagnostics(
            descriptor: probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port)),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(5),
            traceTimeout: budget
        ).run()
        return report.steps.first { $0.id == DiagnosticStepID.trace }
    }

    /// Drives `NetworkTrace.walk` over a fake hop source and a fake clock:
    /// the first `answering` hops report time-exceeded and the rest report
    /// nothing, and every one of them costs `hopCost` on the clock.
    ///
    /// No thread waits for any of it. The clock reads a base instant plus
    /// whatever the fake source says has elapsed, so a hop that "takes" a
    /// second and a half costs this case nothing and reads the same on every
    /// machine — which is the point, since what is pinned is the walk's
    /// arithmetic against its deadline and not the runner's scheduling. It is
    /// also what makes the injected clock load-bearing: with the real one,
    /// every hop below costs microseconds and the same walk runs to
    /// `maxHops`.
    private static func fakeWalk(
        budget: Duration, hopCost: Duration, answering: Int,
        refusingFrom: Int? = nil, refusal: String = "refused", maxHops: Int
    ) -> NetworkTraceOutcome {
        let base = ContinuousClock().now
        var elapsed = Duration.zero
        return NetworkTrace.walk(
            destination: documentationV4, maxHops: maxHops,
            deadline: base.advanced(by: budget), collector: TraceHopCollector(),
            now: { base.advanced(by: elapsed) }
        ) { ttl, _ in
            elapsed += hopCost
            if let refusingFrom, ttl >= refusingFrom { return .refused(refusal) }
            guard ttl <= answering else { return .measured(.timedOut) }
            return .measured(.forwarded(address: "10.0.0.1", rtt: .milliseconds(2)))
        }
    }

    /// What one broken-socket run found.
    private struct SocketFailure: Sendable {
        /// A working socket with nothing arriving is a silence — the anchor,
        /// without which the failure below could be satisfied by a wait that
        /// never succeeds at anything.
        var openSocketIsSilent = false
        var brokenSocketFails = false
        /// The sentence the failure carried, so the case can require the
        /// kernel's own rather than a synthetic one.
        var failureReason = ""
    }

    /// Waits on a live ICMP socket nothing answers, then on a descriptor that
    /// has been closed. Blocking; only ever called from `onOwnQueue`.
    private static func waitOnASocketAndOnABrokenOne() -> SocketFailure {
        var result = SocketFailure()
        let live = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_ICMP))
        guard live >= 0 else { return result }
        // Nothing is sent, so nothing this wait wants can arrive. A foreign
        // ICMP message would be skipped by the port match and the wait would
        // keep waiting, which is the same answer.
        if case .silent = wait(on: live, forMilliseconds: 100) { result.openSocketIsSilent = true }
        Darwin.close(live)

        // The same descriptor, now closed: `poll` answers `EBADF` at once.
        guard case .failed(let reason) = wait(on: live, forMilliseconds: 100) else {
            return result
        }
        result.brokenSocketFails = true
        result.failureReason = reason
        return result
    }

    private static func wait(on descriptor: Int32, forMilliseconds ms: Int) -> TraceWaitResult {
        let now = ContinuousClock().now
        return NetworkTrace.waitForAnswer(
            descriptor: descriptor, sourcePort: 1, destinationPort: NetworkTrace.basePort,
            started: now, deadline: now.advanced(by: .milliseconds(ms)))
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
