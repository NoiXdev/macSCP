import Foundation
import Testing

@testable import macSCPCore

/// The three probes a diagnosis runs ON a jump host (2026-09-18, Task 7 of the
/// jump-and-groups plan), taken apart: which target hosts may be handed to a
/// command there at all, the command lines they become, and how each tool's
/// output is read. The walk that runs them is `ConnectionDiagnosticsJumpTests`.
///
/// Every tool output here is `JumpProbeSamples`, which says for each one
/// where it was recorded — or that it was constructed, where nothing here
/// could record it.
@Suite("Jump-host probes: the host, the command line, the reading")
struct JumpProbeTests {
    // MARK: - Which hosts may reach a command line

    @Test(arguments: [
        ("target.invalid", JumpProbeHost.Kind.name),
        ("sshd2", .name),
        ("x", .name),
        ("a-b.c-d.invalid", .name),
        ("UPPER.Case.invalid", .name),
        ("0day.invalid", .name),
        (String(repeating: "a", count: 63) + ".invalid", .name),
        ("10.0.0.5", .ipv4),
        ("172.20.0.2", .ipv4),
        ("::1", .ipv6),
        ("2001:db8::5", .ipv6),
        ("::ffff:10.0.0.5", .ipv6),
    ])
    func aHostNameOrAnIPLiteralIsAccepted(host: String, kind: JumpProbeHost.Kind) throws {
        let accepted = try #require(JumpProbeHost(host), "refused \(host)")
        #expect(accepted.text == host)
        #expect(accepted.kind == kind)
    }

    /// Everything else is refused, before any channel opens. The first group
    /// is what a shell would read as syntax — the reason the check exists;
    /// the second is what RFC 1123 does not allow in a label; the third is
    /// what looks like an address and is not one.
    @Test(arguments: [
        // Shell syntax.
        "target.invalid;id", "target.invalid; rm -rf ~", "$(id)", "target$(id).invalid",
        "`id`", "a`id`b", "'", "target'.invalid", "a'b", "\"quoted\"", "a\"b", "a b",
        "a\tb", "target.invalid\nid", "a|b", "a&b", "a>b", "a<b", "a\\b", "*", "a*b", "?",
        "~", "a/b", "{a,b}", "a#b", "a=b", "$HOME", "a\u{0}b",
        // A leading `-`, which a tool would read as an option.
        "-oProxyCommand=id", "-c", "-", "-host.invalid",
        // Not RFC 1123.
        "", "host-.invalid", "a..b", ".a", "a.", "under_score.invalid", "héllo.invalid",
        "例え.invalid", String(repeating: "a", count: 64) + ".invalid",
        Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: "."),
        // Not an address.
        "::1%lo0", "[::1]", "10.0.0.5;id", "1:2", "::1 ",
    ])
    func anythingElseIsRefused(host: String) {
        #expect(JumpProbeHost(host) == nil, "accepted \(host.debugDescription)")
    }

    // MARK: - The command lines

    @Test func eachProbeHandsTheHostOverAsOneSingleQuotedArgument() throws {
        let name = try #require(JumpProbeHost("target.invalid"))
        #expect(JumpProbeCommand.resolve(name).text == "getent hosts 'target.invalid'")
        #expect(JumpProbeCommand.ping(name).text == "ping -c 3 'target.invalid'")
        #expect(
            JumpProbeCommand.traceroute(name).text
                == "traceroute -n -q 1 -w 1 'target.invalid'")
        #expect(JumpProbeCommand.tracepath(name).text == "tracepath -n 'target.invalid'")

        let address = try #require(JumpProbeHost("2001:db8::5"))
        #expect(JumpProbeCommand.ping(address).text == "ping -c 3 '2001:db8::5'")
        #expect(JumpProbeCommand.resolve(address).tool == .getent)
        #expect(JumpProbeCommand.traceroute(address).tool == .traceroute)
    }

    /// For every accepted host and every probe: the host is the last word,
    /// quoted by `PosixQuoting` — the project's one quoting rule — and the
    /// line holds no other quote at all.
    @Test(arguments: ["target.invalid", "sshd2", "10.0.0.5", "::1", "::ffff:10.0.0.5"])
    func theHostIsTheLastWordAndTheOnlyQuotedOne(host: String) throws {
        let accepted = try #require(JumpProbeHost(host))
        let quoted = PosixQuoting.singleQuoted(host)
        for command in [
            JumpProbeCommand.resolve(accepted), .ping(accepted), .traceroute(accepted),
            .tracepath(accepted),
        ] {
            #expect(command.text.hasSuffix(" " + quoted), "\(command.text)")
            #expect(command.text.filter { $0 == "'" }.count == 2, "\(command.text)")
        }
    }

    // MARK: - Reading getent

    @Test func getentsAddressesAreRead() {
        #expect(
            JumpProbeReading.addresses(
                inGetentOutput: JumpProbeSamples.rigGetentOverSSH.standardOutput)
                == [JumpResolvedAddress(family: .ipv4, text: "172.20.0.2")])
        #expect(
            JumpProbeReading.addresses(
                inGetentOutput: JumpProbeSamples.rigGetentLocalhost.standardOutput)
                == [JumpResolvedAddress(family: .ipv6, text: "::1")])
        #expect(
            JumpProbeReading.addresses(
                inGetentOutput: JumpProbeSamples.debianGetentLocalhost.standardOutput)
                == [JumpResolvedAddress(family: .ipv6, text: "::1")])
        // One address per line, each once.
        #expect(
            JumpProbeReading.addresses(
                inGetentOutput: "10.0.0.5        a.invalid\n2001:db8::5 a.invalid\n10.0.0.5 b\n")
                == [
                    JumpResolvedAddress(family: .ipv4, text: "10.0.0.5"),
                    JumpResolvedAddress(family: .ipv6, text: "2001:db8::5"),
                ])
    }

    /// Nothing, or anything that is not an address table, is no answer — a
    /// forced command's banner above a real line included: the probe reads
    /// the jump host's own words nowhere into the report.
    @Test(arguments: [
        JumpProbeSamples.rigGetentMissing.standardOutput,
        "",
        "This account may only forward connections.\n",
        "Welcome\n172.20.0.2  sshd2\n",
        "localhost 172.20.0.2\n",
    ])
    func getentOutputThatIsNotAnAddressTableIsNotRead(output: String) {
        #expect(JumpProbeReading.addresses(inGetentOutput: output) == nil)
    }

    // MARK: - Reading ping

    @Test func pingsSummaryIsReadInEachOfTheThreeDialects() {
        // BusyBox, over SSH on the rig.
        #expect(
            JumpProbeReading.ping(JumpProbeSamples.rigPingOverSSH.standardOutput)
                == JumpPingSummary(
                    address: "172.20.0.2", sent: 3, received: 3,
                    min: .nanoseconds(40_000), average: .nanoseconds(166_000),
                    max: .nanoseconds(407_000)))
        // iputils.
        #expect(
            JumpProbeReading.ping(JumpProbeSamples.debianPingLoopback.standardOutput)
                == JumpPingSummary(
                    address: "127.0.0.1", sent: 3, received: 3,
                    min: .nanoseconds(17_000), average: .nanoseconds(20_000),
                    max: .nanoseconds(25_000)))
        // BSD.
        #expect(
            JumpProbeReading.ping(JumpProbeSamples.macOSPingLoopback.standardOutput)
                == JumpPingSummary(
                    address: "127.0.0.1", sent: 3, received: 3,
                    min: .nanoseconds(55_000), average: .nanoseconds(91_000),
                    max: .nanoseconds(128_000)))
        // Silence: counted, with no round trip to report.
        #expect(
            JumpProbeReading.ping(JumpProbeSamples.rigPingSilent.standardOutput)
                == JumpPingSummary(
                    address: "192.0.2.1", sent: 3, received: 0,
                    min: nil, average: nil, max: nil))
    }

    @Test(arguments: [
        JumpProbeSamples.debianPingNoRoute.standardOutput,
        "",
        "This account may only forward connections.\n",
        "3 packets transmitted, 4 packets received, 0% packet loss\n",
    ])
    func pingOutputWithoutAReadableSummaryIsNotRead(output: String) {
        #expect(JumpProbeReading.ping(output) == nil)
    }

    // MARK: - Reading traceroute

    @Test func aTracerouteThatReachedItsTargetInOneHop() throws {
        let host = try #require(JumpProbeHost("sshd2"))
        let outcome = try #require(
            JumpProbeReading.traceroute(
                JumpProbeSamples.rigTracerouteToSshd2.standardOutput, target: host))
        #expect(
            outcome
                == .measured(
                    hops: [
                        NetworkTraceHop(
                            ttl: 1,
                            outcome: .unreachable(
                                address: "172.20.0.2", rtt: .nanoseconds(2_000),
                                code: NetworkTrace.portUnreachableCode))
                    ],
                    destination: "172.20.0.2", ending: .answered))
        #expect(ConnectionDiagnostics.traceOutcome(outcome) == .ok)
        #expect(
            ConnectionDiagnostics.traceTable(outcome)?.rows == [
                ["1", "172.20.0.2", "0.0 ms", DiagnosticTraceColumn.destination]
            ])
    }

    /// The rig's gateway answers, then three silent hops, and `-m 4` ends the
    /// walk: a measured path the tool stopped following, and the row says so.
    @Test func aTracerouteThatRanOutOfHops() throws {
        let host = try #require(JumpProbeHost("192.0.2.1"))
        let outcome = try #require(
            JumpProbeReading.traceroute(
                JumpProbeSamples.rigTracerouteSilentTail.standardOutput, target: host))
        #expect(
            outcome
                == .measured(
                    hops: [
                        NetworkTraceHop(
                            ttl: 1,
                            outcome: .forwarded(address: "172.20.0.1", rtt: .nanoseconds(4_000))),
                        NetworkTraceHop(ttl: 2, outcome: .timedOut),
                        NetworkTraceHop(ttl: 3, outcome: .timedOut),
                        NetworkTraceHop(ttl: 4, outcome: .timedOut),
                    ],
                    destination: "192.0.2.1", ending: .hopLimit))
        #expect(ConnectionDiagnostics.traceOutcome(outcome) == .ok)
        #expect(
            ConnectionDiagnostics.traceDetail(outcome)
                == DiagnosticReason.traceHopLimitReached(afterHop: 4))
    }

    /// BSD `traceroute` writes its header to standard error, so what is kept
    /// starts at hop 1 and names no destination. A walk the tool ended on a
    /// row that answered, before any hop limit, ended at its destination.
    @Test func aTracerouteWithoutItsHeaderLine() throws {
        let host = try #require(JumpProbeHost("target.invalid"))
        let outcome = try #require(
            JumpProbeReading.traceroute(
                JumpProbeSamples.macOSTracerouteLoopback.standardOutput, target: host))
        #expect(outcome.reachedDestination)
        #expect(
            ConnectionDiagnostics.traceTable(outcome)?.rows == [
                ["1", "127.0.0.1", "0.3 ms", DiagnosticTraceColumn.destination]
            ])
    }

    @Test func aTracerouteThroughARouter() throws {
        let host = try #require(JumpProbeHost("target.invalid"))
        let outcome = try #require(
            JumpProbeReading.traceroute(
                JumpProbeSamples.constructedTracerouteTwoHops.standardOutput, target: host))
        #expect(ConnectionDiagnostics.traceOutcome(outcome) == .ok)
        #expect(
            ConnectionDiagnostics.traceTable(outcome)?.rows == [
                ["1", "10.0.0.1", "0.4 ms", DiagnosticTraceColumn.answered],
                ["2", "10.0.0.5", "0.9 ms", DiagnosticTraceColumn.destination],
            ])
    }

    /// `!X` is ICMP code 13, administratively prohibited: a finding about the
    /// path, reported the way the local trace reports one.
    @Test func aTracerouteStoppedByAProhibitingRouter() throws {
        let host = try #require(JumpProbeHost("target.invalid"))
        let outcome = try #require(
            JumpProbeReading.traceroute(
                JumpProbeSamples.constructedTracerouteProhibited.standardOutput, target: host))
        #expect(
            ConnectionDiagnostics.traceOutcome(outcome)
                == .failed(DiagnosticReason.traceHopUnreachable(code: 13, hop: 2)))
    }

    @Test(arguments: [
        JumpProbeSamples.rigTracerouteAsTestuserOverSSH.standardOutput,
        "",
        "This account may only forward connections.\n",
        "traceroute to sshd2 (172.20.0.2), 30 hops max, 46 byte packets\n",
        " 1  not-an-address  0.1 ms\n",
        " 1  10.0.0.1  ms\n",
        " 2  10.0.0.1  0.1 ms\n 1  10.0.0.2  0.1 ms\n",
    ])
    func tracerouteOutputThatIsNotAWalkIsNotRead(output: String) throws {
        let host = try #require(JumpProbeHost("target.invalid"))
        #expect(JumpProbeReading.traceroute(output, target: host) == nil)
    }

    // MARK: - Reading tracepath

    @Test func aTracepathThatReachedItsTarget() throws {
        let host = try #require(JumpProbeHost("target.invalid"))
        let outcome = try #require(
            JumpProbeReading.tracepath(
                JumpProbeSamples.constructedTracepathReached.standardOutput, target: host))
        #expect(
            outcome
                == .measured(
                    hops: [
                        NetworkTraceHop(
                            ttl: 1,
                            outcome: .forwarded(address: "10.0.0.1", rtt: .nanoseconds(402_000))),
                        NetworkTraceHop(ttl: 2, outcome: .timedOut),
                        NetworkTraceHop(
                            ttl: 3,
                            outcome: .unreachable(
                                address: "10.0.0.5", rtt: .nanoseconds(1_117_000),
                                code: NetworkTrace.portUnreachableCode)),
                    ],
                    destination: "10.0.0.5", ending: .answered))
        #expect(ConnectionDiagnostics.traceOutcome(outcome) == .ok)
    }

    @Test(arguments: [
        JumpProbeSamples.rigTracepathOverSSH.standardOutput,
        "",
        "This account may only forward connections.\n",
        " 1?: [LOCALHOST]     pmtu 1500\n",
    ])
    func tracepathOutputThatIsNotAWalkIsNotRead(output: String) throws {
        let host = try #require(JumpProbeHost("target.invalid"))
        #expect(JumpProbeReading.tracepath(output, target: host) == nil)
    }

    // MARK: - The budgets

    /// The trace from the jump host walks up to thirty hops and gets the
    /// trace's budget; every other step of the target half is one probe and
    /// gets the step's. Before this, every target step raced the step budget
    /// and the trace's never reached this half.
    @Test func eachStepOfTheTargetHalfIsRacedAgainstItsOwnBudget() {
        let step = Duration.seconds(5)
        let trace = Duration.seconds(20)
        let budgets = ConnectionDiagnostics.targetHalf.map {
            "\($0.id) \($0.budget.duration(step: step, trace: trace))"
        }
        #expect(budgets == [
            "\(DiagnosticStepID.targetTCPViaJump) 5.0 seconds",
            "\(DiagnosticStepID.targetResolveOnJump) 5.0 seconds",
            "\(DiagnosticStepID.targetICMPFromJump) 5.0 seconds",
            "\(DiagnosticStepID.targetDialViaJump) 5.0 seconds",
            "\(DiagnosticStepID.targetTraceFromJump) 20.0 seconds",
        ])
        #expect(DiagnosticJumpStep.Budget.step.duration(step: step, trace: trace) == step)
        #expect(DiagnosticJumpStep.Budget.trace.duration(step: step, trace: trace) == trace)
    }
}
