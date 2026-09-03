import Darwin
import Foundation
import Testing

@testable import macSCPCore

/// The universal half of the connection diagnosis — name resolution, the TCP
/// ping and the backend's own dial — plus the report they render into. The
/// echo and the trace have suites of their own (`ICMPEchoTests`,
/// `NetworkTraceTests`); what is checked here is the walk and the rendering,
/// and the walk's own order is asserted rather than counted.
///
/// **Where the packets go.** Loopback only, except for two gated cases: the
/// Docker rig on `127.0.0.1` (`MACSCP_ITEST=1`) and TEST-NET-1 `192.0.2.1`
/// for the timeout case (`MACSCP_NETSPIKE=1`), whose SYN dies at the first
/// hop. No other destination is ever contacted.
///
/// **Why no test parks a thread.** Every socket call the subject makes runs
/// on a `DispatchQueue` of its own and is awaited through a continuation
/// (CLAUDE.md, "Tests never block the cooperative pool"); the tests here only
/// `await`. The one place a test touches a socket directly — `LoopbackSocket`
/// below — calls `socket`/`bind`/`listen`/`close`, none of which block.
@Suite("ConnectionDiagnostics")
struct ConnectionDiagnosticsTests {
    /// The secret the SSH dial cases hand the runner. Named rather than
    /// written into an expectation: `#expect` reports the SOURCE TEXT of the
    /// expression it checks, so a secret spelled inside one leaks through the
    /// failure message — the very thing those cases exist to forbid
    /// (CLAUDE.md, "A value a test must not leak has two exits").
    private static let dialSecret = "diagnostics-test-passphrase"

    /// The two halves of a credential typed into a URL. Named for the same
    /// reason `dialSecret` is: neither may be written inside an `#expect`.
    private static let userinfoKey = "AKIADIAGNOSTICSTESTKEY"
    private static let userinfoSecret = "wJalrDiagnosticsTestSecretValue"

    /// Secrets carrying a character RFC 3986 permits UNENCODED inside
    /// userinfo. Each one used to end the authority scan before the `@`, so
    /// the span had no separator to cut at and was copied out whole — the
    /// entire credential, through the helper written to prevent exactly that.
    ///
    /// Named, and reported by INDEX below, for the reason `dialSecret` is
    /// named: a value written into an expectation — or into a failure
    /// message — leaks at the moment someone is reading.
    private static let subDelimiterSecrets = [
        "se)cret", "se'cret", "se]cret", "se,cret", "se\"cret", "se(cret", "se;cret",
    ]

    /// Stands in for whatever a foreign key-parsing error captured. No sentence
    /// this module prints may carry it.
    private static let loaderErrorSentinel = "CITADEL-INTERNAL-BUFFER-CONTENTS"

    // MARK: - Resolve

    @Test func resolveFindsALoopbackAddressForLocalhost() async {
        let outcome = await HostResolver.resolve(host: "localhost", port: 22, timeout: .seconds(2))
        guard case .resolved(let addresses) = outcome else {
            Issue.record("localhost did not resolve: \(outcome)")
            return
        }
        // Both families where the machine has both, the one it has otherwise
        // — what is pinned is that every address IS loopback and that the
        // family is labelled from the address record rather than guessed.
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { $0.text == "127.0.0.1" || $0.text == "::1" })
        #expect(addresses.allSatisfy { ($0.family == .ipv4) == ($0.text == "127.0.0.1") })
    }

    @Test func resolveOfANumericAddressCarriesItsFamily() async {
        let outcome = await HostResolver.resolve(host: "127.0.0.1", port: 2222, timeout: .seconds(2))
        guard case .resolved(let addresses) = outcome else {
            Issue.record("127.0.0.1 did not resolve: \(outcome)")
            return
        }
        #expect(addresses.map(\.text) == ["127.0.0.1"])
        #expect(addresses.map(\.family) == [.ipv4])
    }

    /// A `getaddrinfo` failure, provoked WITHOUT a lookup: `AI_NUMERICHOST`
    /// forbids name resolution, so a non-numeric host is refused from the
    /// resolver's own tables and no query is ever put on the wire. A test
    /// that used an unresolvable NAME would send a DNS query off the machine
    /// for the sake of an error string.
    @Test func resolveReportsTheResolverErrorAsFailed() async {
        let outcome = await HostResolver.resolve(
            host: "not-a-numeric-address", port: 22, timeout: .seconds(2),
            flags: AI_NUMERICHOST)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected a resolver failure, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }

    /// The bare literal an IPv6 endpoint reader must hand `getaddrinfo`. A
    /// bracketed one is rejected, which would report a reachable server as a
    /// name that does not resolve.
    @Test func resolveAcceptsABareIPv6LiteralAndRejectsABracketedOne() async {
        let bare = await HostResolver.resolve(host: "::1", port: 9000, timeout: .seconds(2))
        guard case .resolved(let addresses) = bare else {
            Issue.record("::1 did not resolve: \(bare)")
            return
        }
        #expect(addresses.map(\.text) == ["::1"])
        let bracketed = await HostResolver.resolve(
            host: "[::1]", port: 9000, timeout: .seconds(2))
        guard case .failed = bracketed else {
            Issue.record("a bracketed literal resolved after all: \(bracketed)")
            return
        }
    }

    // MARK: - TCP ping

    @Test func tcpPingIsAcceptedByAListeningLoopbackSocket() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }

        let address = try #require(await Self.loopbackAddress(port: listener.port))
        let outcome = await TCPPing.probe(address: address, timeout: .seconds(2))
        guard case .accepted = outcome else {
            Issue.record("a listening socket refused the probe: \(outcome)")
            return
        }
    }

    @Test func tcpPingToAClosedLoopbackPortIsRefused() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let address = try #require(await Self.loopbackAddress(port: port))
        let outcome = await TCPPing.probe(address: address, timeout: .seconds(2))
        guard case .refused = outcome else {
            Issue.record("a closed port did not refuse the probe: \(outcome)")
            return
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func tcpPingIsAcceptedByTheRigsSSHPort() async throws {
        let address = try #require(await Self.loopbackAddress(port: 2222))
        let outcome = await TCPPing.probe(address: address, timeout: .seconds(2))
        guard case .accepted = outcome else {
            Issue.record("the rig's sshd refused the probe: \(outcome)")
            return
        }
    }

    /// TEST-NET-1 with no route: the SYN dies at the first hop and nothing
    /// answers, so the probe must give up on ITS OWN deadline rather than on
    /// the kernel's (75 s on Darwin).
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MACSCP_NETSPIKE"] == "1"))
    func tcpPingToAnUnroutableAddressTimesOutInsideTheStepTimeout() async throws {
        let outcome = await HostResolver.resolve(host: "192.0.2.1", port: 22, timeout: .seconds(2))
        guard case .resolved(let addresses) = outcome, let address = addresses.first else {
            Issue.record("192.0.2.1 did not parse: \(outcome)")
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        let result = await TCPPing.probe(address: address, timeout: .seconds(1))
        let elapsed = started.duration(to: clock.now)
        #expect(result == .timedOut)
        #expect(elapsed < .seconds(5))
    }

    // MARK: - The runner

    /// The whole walk, in the order the report prints it.
    ///
    /// The name deliberately does not enumerate the steps: the runner has
    /// gained two since it was written (the echo, then the trace), and a name
    /// that lists them is a comment that runs. The list itself is below, where
    /// a failure prints it.
    @Test func theRunnerWalksTheUniversalStepsInTheOrderTheReportPrints() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }

        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port),
                dial: Self.constantContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe",
                    outcome: .ok, detail: "dialled")))

        #expect(
            report.steps.map(\.id) == [
                DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
                DiagnosticStepID.dial, DiagnosticStepID.trace,
            ])
        #expect(report.steps.map(\.outcome) == [.ok, .ok, .ok, .ok, .ok])
        #expect(report.endpoint == Endpoint(host: "127.0.0.1", port: listener.port))
    }

    @Test func theRunnerRunsTheDescriptorsContributionsAfterTheDial() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: Self.constantContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe",
                    outcome: .ok, detail: "dialled"),
                diagnostics: [
                    Self.constantContribution(
                        id: "probe.first", titleKey: "diagnostics.step.probe",
                        outcome: .ok, detail: "first"),
                    Self.constantContribution(
                        id: "probe.second", titleKey: "diagnostics.step.probe",
                        outcome: .unavailable("nothing to measure"), detail: "second"),
                ]))

        #expect(
            report.steps.map(\.id) == [
                DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
                DiagnosticStepID.dial, DiagnosticStepID.trace, "probe.first", "probe.second",
            ])
        // The closed port is the tcp step's own outcome, and it does NOT stop
        // the walk: a refused port is a finding, not an abort.
        #expect(report.steps[1].outcome != .ok)
    }

    @Test func aStepThatOverrunsTheTimeoutIsReportedAsTimedOut() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let clock = ContinuousClock()
        let started = clock.now
        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: DiagnosticContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe"
                ) { _, _ in
                    let timer = DiagnosticStepTimer(
                        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                    try? await Task.sleep(for: .seconds(30))
                    return timer.finish(.ok, "never reached")
                }),
            stepTimeout: .milliseconds(200))
        let elapsed = started.duration(to: clock.now)

        // The dial by NAME, not by position: the trace step runs after it,
        // so `last` reads a row this case says nothing about.
        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        #expect(dial.outcome == .timedOut)
        // No wall-clock ceiling: on the three-core CI runner this step took
        // 20.68 s to come back (run 33727757421) while the outcome was
        // already `.timedOut` — a ceiling there measures the runner, not
        // the deadline. The outcome carries the property: without a
        // deadline the fake completes and the step reads `.ok`.
        _ = elapsed
    }

    /// A cancelled walk ends with the steps it had — and the report SAYS it
    /// was cancelled, and after how many.
    ///
    /// Both halves in one case because the second is what makes the first
    /// readable. The report is pasted into an issue, and until 2026-09-03 a
    /// cancelled walk built its report through the same helper the natural
    /// return used: the rows were right and the label claimed a finished
    /// diagnosis, so a reader of the issue could not tell the trace and the
    /// dial from steps that had been measured and found absent. Nothing about
    /// the rows had to be wrong for the artifact to mislead.
    @Test func cancellationMidRunEndsWithTheStepsSoFarAndSaysItWasCancelled() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let gate = Gate()
        let diagnostics = ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: DiagnosticContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe"
                ) { _, _ in
                    let timer = DiagnosticStepTimer(
                        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                    await gate.open()
                    try? await Task.sleep(for: .seconds(30))
                    return timer.finish(.ok, "never reached")
                }),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(30))

        let task = Task { await diagnostics.run() }
        await gate.opened()
        task.cancel()
        let report = await task.value

        #expect(
            report.steps.map(\.id) == [
                DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
            ])
        // Three, because the dial is where the park is: the resolve, the TCP
        // ping and the echo finish before it and the cancellation lands on
        // the guard around it. Written as a literal rather than as
        // `report.steps.count`, which a report of no steps labelled
        // `afterSteps: 0` would also satisfy.
        #expect(report.completion == .cancelled(afterSteps: 3))
        #expect(report.isComplete == false)
        #expect(report.plainText().contains("(cancelled after 3 steps)"), """
            the pasted report must name the cancel, or its missing rows read as steps that             were measured and found absent: \(report.plainText())
            """)
        #expect(report.markdown().contains("(cancelled after 3 steps)"))
    }

    /// Every step reaches the observer AS IT FINISHES — not in a batch at the
    /// end — in the order the report ends up printing.
    ///
    /// The seam exists because the report used to arrive as one value at the
    /// end. The trace's budget is 20 s, so an internet-facing host whose last
    /// hops are firewalled left the panel showing a spinner for 21+ seconds
    /// with four finished rows already measured and nowhere to put them.
    ///
    /// **How "as it finishes" is told apart from "all at the end".** A check
    /// that only reads the delivered ids, or even how many had arrived when
    /// the last one did, is satisfied by a run that walks the whole thing and
    /// then flushes — measured, by planting exactly that. So the dial counts
    /// its own runs, and every observation records how many dials had happened
    /// when it fired: under incremental delivery the resolve step arrives
    /// before the dial has run at all, and under a flush it arrives after.
    @Test func everyStepReachesTheObserverAsItFinishes() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let dials = Ticker()
        let diagnostics = ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port),
                dial: DiagnosticContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe"
                ) { _, _ in
                    let timer = DiagnosticStepTimer(
                        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                    await dials.tick()
                    return timer.finish(.ok, "dialled")
                }),
            values: FieldValues(), secrets: nil)

        let observed = StepLog()
        let report = await diagnostics.run(
            onStep: { step in await observed.append(step.id, marked: await dials.count) })

        let seen = await observed.entries
        #expect(seen.map(\.id) == report.steps.map(\.id), """
            the observer must see every step the report carries, in the same order — got \
            \(seen.map(\.id)) against \(report.steps.map(\.id))
            """)
        #expect(seen.first?.marker == 0, """
            the resolve step must arrive BEFORE the dial has run — it arrived after \
            \(seen.first?.marker ?? -1) dial(s), which is what a walk that publishes \
            everything at the end looks like
            """)
        #expect(seen.first(where: { $0.id == DiagnosticStepID.dial })?.marker == 1, """
            …and the dial's own row must arrive after it: \(seen)
            """)
    }

    /// A cancelled run publishes what it measured to the observer too — the
    /// partial walk is the answer to "where did it get stuck", and it must
    /// not exist only in the returned value.
    @Test func theObserverSeesTheStepsOfACancelledRun() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let gate = Gate()
        let observed = StepLog()
        let diagnostics = ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: DiagnosticContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe"
                ) { _, _ in
                    let timer = DiagnosticStepTimer(
                        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                    await gate.open()
                    try? await Task.sleep(for: .seconds(30))
                    return timer.finish(.ok, "never reached")
                }),
            values: FieldValues(), secrets: nil, stepTimeout: .seconds(30))

        let task = Task { await diagnostics.run(onStep: { await observed.append($0.id) }) }
        await gate.opened()
        task.cancel()
        let report = await task.value

        #expect(await observed.ids == report.steps.map(\.id))
        #expect(await observed.ids == [
            DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
        ])
    }

    /// The observer-less spelling still produces the whole report — it is
    /// what the CLI and every other caller use.
    @Test func theObserverlessRunStillProducesTheWholeReport() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port), dial: nil))
        #expect(report.steps.map(\.id) == [
            DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
            DiagnosticStepID.trace,
        ])
        // The positive half of the case above: a walk that reached its end
        // carries no marker, so the marker means something when it is there.
        #expect(report.completion == .complete)
        #expect(report.plainText().contains("cancelled") == false)
        #expect(report.plainText().contains("run in progress") == false)
    }

    /// Even the one step a session with no endpoint produces reaches the
    /// observer: the panel draws rows from what it is told, so a row the
    /// report carries and the observer never saw is a row nobody sees.
    @Test func theEndpointlessRunStillTellsTheObserverItsOneStep() async {
        let observed = StepLog()
        let diagnostics = ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(endpoint: nil, dial: nil),
            values: FieldValues(), secrets: nil)
        let report = await diagnostics.run(onStep: { await observed.append($0.id) })
        #expect(await observed.ids == report.steps.map(\.id))
        #expect(await observed.ids == [DiagnosticStepID.resolve])
    }

    @Test func aDescriptorThatNamesNoEndpointProbesNothing() async {
        let report = await Self.run(
            descriptor: Self.probeDescriptor(endpoint: nil, dial: nil))
        #expect(report.steps.map(\.id) == [DiagnosticStepID.resolve])
        guard case .unavailable = report.steps.first?.outcome else {
            Issue.record("expected an unavailable resolve step, got \(String(describing: report.steps.first))")
            return
        }
    }

    // MARK: - Scope

    /// A scope runs the steps it names and NO others — and a step outside it
    /// leaves no row at all.
    ///
    /// A skipped row would have been the cheaper design and is the wrong one:
    /// `skipped` already means "this step was asked for and could not be
    /// measured" (the ping with nothing to probe), so a scope that produced
    /// skipped rows would put "you did not ask for this" and "this could not
    /// be answered" in the same column of a pasted report.
    ///
    /// **What the tickers are for.** The ids alone cannot tell a dial that
    /// never ran from a dial that ran and had its row dropped — both give a
    /// report without a dial row, and the second still spends the dial's
    /// whole budget, which is the entire point of asking for one probe. So
    /// the dial and the contribution count their own runs, and the counts are
    /// read after the walk rather than inside it.
    @Test func eachScopeRunsExactlyTheStepsItNames() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let endpoint = Endpoint(host: "127.0.0.1", port: listener.port)

        let whole = await Self.scopedWalk(.complete, endpoint: endpoint)
        let ping = await Self.scopedWalk(.ping, endpoint: endpoint)
        let trace = await Self.scopedWalk(.trace, endpoint: endpoint)
        let dial = await Self.scopedWalk(.dial, endpoint: endpoint)
        let contributions = await Self.scopedWalk(.contributions, endpoint: endpoint)

        #expect(whole.ids == [
            DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
            DiagnosticStepID.dial, DiagnosticStepID.trace, Self.contributionID,
        ], "the complete walk must be exactly what it was before the scope existed: \(whole.ids)")
        #expect(ping.ids == [
            DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
        ], "the ping scope resolves and probes the port: \(ping.ids)")
        #expect(trace.ids == [DiagnosticStepID.resolve, DiagnosticStepID.trace], """
            the trace scope resolves and walks the path: \(trace.ids)
            """)
        #expect(dial.ids == [DiagnosticStepID.resolve, DiagnosticStepID.dial], """
            the dial scope resolves and dials: \(dial.ids)
            """)
        #expect(contributions.ids == [DiagnosticStepID.resolve, Self.contributionID], """
            the contributions scope resolves and asks the backend: \(contributions.ids)
            """)

        // The positive half of the four counts below: both recorders DO run
        // under the complete walk, so a zero elsewhere means "not run" rather
        // than "never wired".
        #expect(whole.dials == 1)
        #expect(whole.contributions == 1)
        #expect(dial.dials == 1)
        #expect(contributions.contributions == 1)
        #expect(ping.dials == 0, "the ping scope ran the dial \(ping.dials) time(s)")
        #expect(ping.contributions == 0, """
            the ping scope ran the backend's contribution \(ping.contributions) time(s)
            """)
        #expect(trace.dials == 0, "the trace scope ran the dial \(trace.dials) time(s)")
        #expect(contributions.dials == 0, """
            the contributions scope ran the dial \(contributions.dials) time(s)
            """)
        #expect(dial.contributions == 0, """
            the dial scope ran the backend's contribution \(dial.contributions) time(s)
            """)

        // The observer is the panel's only source of rows, so a scope that
        // filtered the returned report and not the seam would draw steps the
        // report does not carry.
        #expect(ping.observed == ping.ids)
        #expect(trace.observed == trace.ids)
        #expect(dial.observed == dial.ids)
        #expect(contributions.observed == contributions.ids)
        #expect(whole.observed == whole.ids)
    }

    /// A scoped report says so where it is read: in the value, and in the
    /// header of both renderings — the text a user pastes into an issue.
    ///
    /// A partial measurement that does not announce itself is the same defect
    /// `Completion` exists for: three rows and no dial row read as "the dial
    /// was never reached" to everyone but the person who chose the scope.
    @Test func aScopedReportNamesItsScopeAndACompleteOneAddsNoLine() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let endpoint = Endpoint(host: "127.0.0.1", port: listener.port)

        let ping = await Self.scopedWalk(.ping, endpoint: endpoint).report
        let whole = await Self.scopedWalk(.complete, endpoint: endpoint).report

        #expect(ping.scope == .ping)
        #expect(ping.plainText().contains("Scope: ping"), """
            the plain text carries no scope header: \(ping.plainText())
            """)
        #expect(ping.markdown().contains("- **Scope:** ping"), """
            the Markdown carries no scope header: \(ping.markdown())
            """)
        #expect(whole.scope == .complete)
        // Byte for byte what it rendered before: a line in every report
        // anyone ever pastes, saying the thing that is true of all of them,
        // is the noise `Completion`'s marker is written to avoid.
        #expect(whole.plainText().contains("Scope") == false, """
            the complete walk's plain text gained a scope line: \(whole.plainText())
            """)
        #expect(whole.markdown().contains("Scope") == false, """
            the complete walk's Markdown gained a scope line: \(whole.markdown())
            """)
    }

    /// The spellings that name no scope mean the complete walk — the App's
    /// Run button and the CLI both reach the runner that way — and the walk
    /// that stops at the missing host still says which scope it was asked
    /// for.
    @Test func aRunThatNamesNoScopeIsTheCompleteOne() async {
        let diagnostics = ConnectionDiagnostics(
            descriptor: Self.probeDescriptor(endpoint: nil, dial: nil),
            values: FieldValues(), secrets: nil)
        let watched = await diagnostics.run(onStep: { _ in })
        let silent = await diagnostics.run()
        let scoped = await diagnostics.run(scope: .ping)

        #expect(watched.scope == .complete)
        #expect(silent.scope == .complete)
        #expect(scoped.scope == .ping)
        #expect(scoped.steps.map(\.id) == [DiagnosticStepID.resolve])
    }

    // MARK: - The report

    @Test func plainTextRendersEveryStepOnceWithItsDurationAndOutcome() async throws {
        let report = try await Self.multiOutcomeReport()
        let text = report.plainText()
        let lines = text.split(separator: "\n").map(String.init)

        // Each step gets exactly ONE line, and that line — not merely the
        // document — carries its outcome and a duration. Counting words over
        // the whole text would be satisfied by a renderer that printed three
        // rows for one step and none for another: a detail line legitimately
        // contains "ms" too, which is how this check first passed while
        // measuring nothing.
        for step in report.steps {
            let own = lines.filter { $0.hasPrefix("\(step.id) —") }
            #expect(own.count == 1)
            #expect(own.first?.contains(step.outcome.label) == true)
            #expect(own.first?.contains(" ms") == true)
        }
        #expect(text.contains("127.0.0.1:"))
        #expect(report.steps.map(\.outcome).contains(.timedOut))
    }

    @Test func markdownRendersEveryStepOnceWithItsDurationAndOutcome() async throws {
        let report = try await Self.multiOutcomeReport()
        let markdown = report.markdown()
        let rows = markdown.split(separator: "\n").map(String.init).filter { $0.hasPrefix("|") }

        // One header row, one separator row, one row per step — plus, since
        // 2026-09-03, the rows of every step that carries a table of its own
        // (the trace's hops), which are Markdown rows too. Counted off the
        // tables that are there rather than assumed absent: a run against
        // loopback measures one hop and would otherwise make this arithmetic
        // wrong for a reason that has nothing to do with the property.
        let tableRows = report.steps.compactMap(\.table).reduce(0) { $0 + $1.rows.count + 2 }
        #expect(rows.count == report.steps.count + 2 + tableRows)
        for step in report.steps {
            let own = rows.filter { $0.hasPrefix("| `\(step.id)` |") }
            #expect(own.count == 1)
            #expect(own.first?.contains(step.outcome.label) == true)
            #expect(own.first?.contains(" ms |") == true)
        }
        #expect(report.steps.map(\.outcome).contains(.timedOut))
    }

    // MARK: - A step that carries a table

    /// A step's table is rendered under its row: aligned columns in the plain
    /// text, a Markdown table in the Markdown — and a step without one
    /// renders exactly as it did before.
    ///
    /// Pinned on a report built by hand, with a fixed duration, because the
    /// property under test is the LAYOUT: a walk that produced the three
    /// rows below takes a path with a silent hop in the middle of it, which
    /// no fixture can arrange, and a measured duration would make the pinned
    /// text unpinnable.
    ///
    /// The column headers are the last component of each catalogue key, not a
    /// second spelling of the words: the report is English and unlocalized
    /// (this type's own doc comment), the panel resolves the same keys
    /// through its catalogs, and a renamed key must not leave one of the two
    /// naming a column the other does not have.
    @Test func aStepsTableRendersAsAlignedColumnsAndAsAMarkdownTable() {
        let hops = DiagnosticTable(
            columns: [
                DiagnosticTraceColumn.hop, DiagnosticTraceColumn.address,
                DiagnosticTraceColumn.rtt, DiagnosticTraceColumn.outcome,
            ],
            rows: [
                ["1", "10.0.0.1", "2.0 ms", "answered"],
                ["2", "*", "—", "silent"],
                ["3", "203.0.113.9", "12.5 ms", "destination"],
            ])
        let trace = DiagnosticStep(
            id: DiagnosticStepID.trace,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.trace),
            started: Date(timeIntervalSince1970: 0), duration: .milliseconds(12),
            outcome: .ok, detail: DiagnosticReason.traceHopLimitReached(afterHop: 3),
            table: hops)
        let report = DiagnosticReport(
            endpoint: Endpoint(host: "example.test", port: 22),
            steps: [Self.constantStep(id: DiagnosticStepID.tcp), trace],
            appVersion: "test")

        // The table sits directly under its own step's line, so a reader can
        // tell whose measurement it is without counting rows.
        let plain = report.plainText()
        let plainTable = [
            "trace — ok — 12.0 ms — hop limit reached after hop 3",
            "    hop  address      rtt      outcome",
            "    1    10.0.0.1     2.0 ms   answered",
            "    2    *            —        silent",
            "    3    203.0.113.9  12.5 ms  destination",
        ].joined(separator: "\n")
        #expect(plain.contains(plainTable), """
            the plain text does not carry the hop table in aligned columns \
            under its step: \(plain)
            """)

        let markdown = report.markdown()
        let markdownTable = [
            "## `trace`",
            "",
            "| hop | address | rtt | outcome |",
            "| --- | --- | --- | --- |",
            "| 1 | 10.0.0.1 | 2.0 ms | answered |",
            "| 2 | * | — | silent |",
            "| 3 | 203.0.113.9 | 12.5 ms | destination |",
        ].joined(separator: "\n")
        #expect(markdown.contains(markdownTable), """
            the Markdown does not carry the hop table as a table of its own: \
            \(markdown)
            """)

        // The step that carries no table gains nothing at all — neither a
        // section of its own nor an indented block under its line.
        #expect(markdown.contains("## `\(DiagnosticStepID.tcp)`") == false)
        #expect(plain.contains("\(DiagnosticStepID.tcp) — ok — ") )
        #expect(plain.split(separator: "\n").filter { $0.hasPrefix("    ") }.count == 4)
    }

    /// A cell is free text like a detail line, and gets the same escaping: a
    /// `|` in one would otherwise split the row it sits in.
    @Test func aTableCellWithABarInItCannotSplitItsMarkdownRow() {
        let step = DiagnosticStep(
            id: DiagnosticStepID.trace, titleKey: "diagnostics.step.trace",
            started: Date(timeIntervalSince1970: 0), duration: .milliseconds(1),
            outcome: .ok, detail: "",
            table: DiagnosticTable(
                columns: [DiagnosticTraceColumn.hop, DiagnosticTraceColumn.address],
                rows: [["1", "a|b"]]))
        let markdown = DiagnosticReport(
            endpoint: nil, steps: [step], appVersion: "test"
        ).markdown()

        #expect(markdown.contains("| 1 | a\\|b |"), "\(markdown)")
    }

    /// Two steps that differ only in their table are two different steps —
    /// the view model diffs rows by equality, and a table that changed while
    /// the step compared equal would leave the old grid on screen.
    @Test func aStepsTableIsPartOfItsIdentity() {
        func step(_ table: DiagnosticTable?) -> DiagnosticStep {
            DiagnosticStep(
                id: DiagnosticStepID.trace, titleKey: "diagnostics.step.trace",
                started: Date(timeIntervalSince1970: 0), duration: .milliseconds(1),
                outcome: .ok, detail: "", table: table)
        }
        let one = DiagnosticTable(columns: ["c"], rows: [["1"]])
        let other = DiagnosticTable(columns: ["c"], rows: [["2"]])

        #expect(step(one) == step(one))
        #expect(step(one) != step(other))
        #expect(step(one) != step(nil))
        #expect(step(nil) == step(nil))
    }

    /// A cell is stripped of URL userinfo on the way in, exactly like the
    /// detail line beside it — the rule lives in the one initializer every
    /// step passes through, and a table added later must not become the
    /// second place a credential can reach a pasted report.
    @Test func aTableCellIsStrippedOfUserinfoLikeEveryOtherFreeTextOnAStep() {
        let secret = "s3cr3t"
        let step = DiagnosticStep(
            id: "probe", titleKey: "diagnostics.step.probe",
            started: Date(timeIntervalSince1970: 0), duration: .milliseconds(1),
            outcome: .ok, detail: "",
            table: DiagnosticTable(
                columns: ["c"], rows: [["https://key:\(secret)@example.test/bucket"]]))
        // Computed before the expectation, and never written into one: an
        // `#expect` reports the source text of what it checks, so a secret
        // spelled inside one leaks through the failure message (CLAUDE.md,
        // "A value a test must not leak has two exits").
        let cell = step.table?.rows.first?.first ?? ""
        let leaks = cell.contains(secret)

        #expect(leaks == false)
        #expect(cell == "https://example.test/bucket")
    }

    /// One marker line per way of being unfinished, and none for a finished
    /// walk. On a report built by hand: what is under test is the rendering
    /// of the label, and every walk that could produce one of these takes a
    /// socket and a clock to provoke.
    ///
    /// The singular is not decoration. "cancelled after 1 steps" is the kind
    /// of line that makes a reader distrust the rest of the artifact, and one
    /// step measured before a cancel is the ordinary case — the resolve
    /// finishes in milliseconds and everything after it can hang.
    @Test func eachKindOfUnfinishedWalkGetsItsOwnMarkerAndAFinishedOneGetsNone() {
        let steps = [
            Self.constantStep(id: DiagnosticStepID.resolve),
            Self.constantStep(id: DiagnosticStepID.tcp),
        ]
        func rendered(_ completion: DiagnosticReport.Completion) -> (String, String) {
            let report = DiagnosticReport(
                endpoint: Endpoint(host: "example.test", port: 22), steps: steps,
                appVersion: "test", completion: completion)
            return (report.plainText(), report.markdown())
        }

        let (completeText, completeMarkdown) = rendered(.complete)
        #expect(completeText.contains("(cancelled") == false, """
            a finished report carries no marker at all — a line in every report anyone \
            pastes is a line nobody reads: \(completeText)
            """)
        #expect(completeText.contains("(run in progress)") == false)
        #expect(completeMarkdown.contains("(cancelled") == false)
        #expect(completeMarkdown.contains("(run in progress)") == false)

        let (runningText, runningMarkdown) = rendered(.running)
        #expect(runningText.contains("(run in progress)"))
        #expect(runningMarkdown.contains("- **(run in progress)**"))

        let (twoText, twoMarkdown) = rendered(.cancelled(afterSteps: 2))
        #expect(twoText.contains("(cancelled after 2 steps)"))
        #expect(twoMarkdown.contains("- **(cancelled after 2 steps)**"))

        let (oneText, _) = rendered(.cancelled(afterSteps: 1))
        #expect(oneText.contains("(cancelled after 1 step)"), """
            one step is singular: \(oneText)
            """)
    }

    @Test func theReportCarriesTheAppVersionItWasGiven() async {
        let report = await Self.run(
            descriptor: Self.probeDescriptor(endpoint: nil, dial: nil), appVersion: "9.9.9")
        #expect(report.appVersion == "9.9.9")
    }

    // MARK: - The SSH dial

    /// The dial fails (nothing listens on the port), and what it reports must
    /// carry no trace of the secret it authenticated with — not in the step,
    /// not in either rendering of the report.
    @Test func theSSHDialNeverPutsTheSecretInTheReport() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        var values = FieldValues()
        values[SSHField.host] = "127.0.0.1"
        values[SSHField.port] = String(port)
        values[SSHField.username] = "testuser"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue

        let secret = Self.dialSecret
        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: values,
            secrets: FixedSecretSource(value: secret), sessionID: UUID(),
            stepTimeout: .seconds(10)
        ).run()

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        guard case .failed = dial.outcome else {
            Issue.record("a closed port did not fail the SSH dial: \(dial.outcome)")
            return
        }
        let inStep = report.steps.contains { $0.detail.contains(secret) }
        let inPlainText = report.plainText().contains(secret)
        let inMarkdown = report.markdown().contains(secret)
        #expect(inStep == false)
        #expect(inPlainText == false)
        #expect(inMarkdown == false)
    }

    @Test func theSSHDialIsSkippedWhenNoSecretIsAvailable() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        var values = FieldValues()
        values[SSHField.host] = "127.0.0.1"
        values[SSHField.port] = String(port)
        values[SSHField.username] = "testuser"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue

        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: values, secrets: nil,
            stepTimeout: .seconds(10)
        ).run()

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        guard case .skipped = dial.outcome else {
            Issue.record("a dial without a secret was not skipped: \(dial.outcome)")
            return
        }
    }

    // MARK: - No URL userinfo reaches the report

    /// A user may type `https://KEY:SECRET@host:9000` into the S3 endpoint
    /// field — the repository already records that shape as ordinary input
    /// that nothing in the schema strips (`ConnectFailureSecrecyTests`). A
    /// report is pasted into public issues, so no step may carry it, whether
    /// the URL reaches the row as a detail or inside a failure reason.
    @Test func aURLWithUserinfoNeverReachesTheReport() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let key = Self.userinfoKey
        let secret = Self.userinfoSecret
        let dressed = "https://\(key):\(secret)@127.0.0.1:9000/bucket"
        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: Self.constantContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe",
                    outcome: .failed("could not reach \(dressed)"),
                    detail: "HTTP 200 on \(dressed)")))

        let plainText = report.plainText()
        let markdown = report.markdown()
        let keyInPlainText = plainText.contains(key)
        let secretInPlainText = plainText.contains(secret)
        let keyInMarkdown = markdown.contains(key)
        let secretInMarkdown = markdown.contains(secret)
        #expect(keyInPlainText == false)
        #expect(secretInPlainText == false)
        #expect(keyInMarkdown == false)
        #expect(secretInMarkdown == false)
        // The positive anchor: the row is still there and still names the
        // server, so the four checks above measure redaction and not an
        // empty report.
        #expect(plainText.contains("127.0.0.1:9000"))
    }

    @Test func theURLHelperRendersHostPortAndPathOnly() throws {
        let key = Self.userinfoKey
        let secret = Self.userinfoSecret
        let url = try #require(URL(string: "https://\(key):\(secret)@minio.example.test:9000/seed"))
        let rendered = URLText.hostPortPath(of: url)
        let leaks = rendered.contains(key) || rendered.contains(secret)
        #expect(leaks == false)
        #expect(rendered == "minio.example.test:9000/seed")
    }

    /// The real S3 dial, on its failure path (nothing listens), with the
    /// credential in the endpoint. Covers the half the synthetic step above
    /// cannot: whatever `URLSession` puts in the error text.
    @Test func theS3DialWithACredentialInItsEndpointLeaksNeither() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let key = Self.userinfoKey
        let secret = Self.userinfoSecret
        var values = FieldValues()
        values[S3Field.endpoint] = "http://\(key):\(secret)@127.0.0.1:\(port)"

        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .s3), values: values, secrets: nil,
            stepTimeout: .seconds(10)
        ).run()

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        let plainText = report.plainText()
        let markdown = report.markdown()
        let leaksInStep = dial.detail.contains(key) || dial.detail.contains(secret)
        let leaksInPlainText = plainText.contains(key) || plainText.contains(secret)
        let leaksInMarkdown = markdown.contains(key) || markdown.contains(secret)
        #expect(leaksInStep == false)
        #expect(leaksInPlainText == false)
        #expect(leaksInMarkdown == false)
        // The anchor: the dial ran and reported the refusal it met.
        guard case .failed = dial.outcome else {
            Issue.record("a closed port did not fail the S3 dial: \(dial.outcome)")
            return
        }
    }

    @Test func theStripperCutsAnAuthorityWhoseCredentialCarriesASubDelimiter() {
        var leakingIndices: [Int] = []
        var hostlessIndices: [Int] = []
        for (index, secret) in Self.subDelimiterSecrets.enumerated() {
            let stripped = URLText.withoutUserinfo(
                "connect failed: https://\(Self.userinfoKey):\(secret)@minio.example.test:9000/seed")
            if stripped.contains(secret) || stripped.contains(Self.userinfoKey) {
                leakingIndices.append(index)
            }
            // The positive companion: what survives still names the server,
            // so an empty result cannot satisfy the check above.
            if !stripped.contains("minio.example.test:9000/seed") {
                hostlessIndices.append(index)
            }
        }
        #expect(leakingIndices.isEmpty)
        #expect(hostlessIndices.isEmpty)
    }

    /// An IPv6 literal has to survive the same scan: its brackets are part of
    /// the authority, not the end of it.
    @Test func theStripperLeavesAnIPv6AuthorityAloneAndStillCutsItsCredential() {
        #expect(
            URLText.withoutUserinfo("no route to https://[::1]:9000/x")
                == "no route to https://[::1]:9000/x")
        let secret = Self.userinfoSecret
        let stripped = URLText.withoutUserinfo(
            "no route to https://\(Self.userinfoKey):\(secret)@[::1]:9000/x")
        let leaks = stripped.contains(secret) || stripped.contains(Self.userinfoKey)
        #expect(leaks == false)
        #expect(stripped == "no route to https://[::1]:9000/x")
    }

    // MARK: - A failure the user can act on

    /// The four commonest SSH dial failures are typed enums with no
    /// `LocalizedError` conformance, so bridging them to `NSError` yields
    /// "The operation couldn't be completed. (macSCPCore.HostKeyError error
    /// 0.)" — nothing about host keys at all, in the row the code calls the
    /// answer to "why does this not connect". (`0` because `NSError.code` is
    /// the case index and `mismatch` is declared first; that is the number
    /// the observed red carried.)
    @Test(arguments: [
        (AnyDialError(HostKeyError.mismatch(host: "h", expected: "SHA256:a", presented: "SHA256:b")), "host key"),
        (AnyDialError(HostKeyError.rejectedByUser), "host key"),
        (AnyDialError(SSHKeyError.fileNotFound(path: "/tmp/id_ed25519")), "/tmp/id_ed25519"),
        (AnyDialError(SSHKeyError.passphraseRequired), "passphrase"),
        (AnyDialError(SSHKeyError.wrongPassphrase), "passphrase"),
        (AnyDialError(SSHKeyError.unsupportedFormat(reason: "bad header")), "key file"),
        (AnyDialError(SSHKeyError.typeNotLoadable(algorithm: "ssh-dss")), "ssh-dss"),
        (AnyDialError(SSHKeyError.pemNotSupported), "PEM"),
        (AnyDialError(AgentError.socketUnavailable), "agent"),
        (AnyDialError(AgentError.noIdentities), "agent"),
        (AnyDialError(AgentError.noUsableIdentities), "agent"),
        (AnyDialError(AgentError.refused), "agent"),
        (AnyDialError(AgentError.protocolError(reason: "short frame")), "ssh-agent"),
    ])
    fileprivate func theDialNamesATypedSSHFailureRatherThanBridgingIt(
        error: AnyDialError, fragment: String
    ) {
        let reason = DialSupport.reason(for: error.wrapped)
        #expect(reason.lowercased().contains(fragment.lowercased()))
        // What it must NOT be: Foundation's sentence for an `Error` with no
        // `LocalizedError` conformance. Compared rather than pattern-matched,
        // so a change in Foundation's wording cannot quietly satisfy this.
        #expect(reason != (error.wrapped as NSError).localizedDescription)
    }

    /// The anchor for the negative half above: an error the mapping does NOT
    /// know still gets Foundation's sentence rather than nothing.
    @Test func anUnknownErrorStillFallsBackToItsBridgedDescription() {
        let error = CocoaError(.fileNoSuchFile)
        #expect(DialSupport.reason(for: error) == (error as NSError).localizedDescription)
    }

    /// A key-parsing failure is reported by NAME, never by re-exporting the
    /// text of the error the loader got back — that error came out of a call
    /// the passphrase was handed to, and `String(describing:)` prints an
    /// arbitrary error's stored properties.
    @Test func aLoaderErrorsOwnDescriptionNeverReachesTheReport() async throws {
        let sentinel = Self.loaderErrorSentinel
        let port = try #require(LoopbackSocket.closedPort())
        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: Self.constantContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe",
                    outcome: .failed(
                        DialSupport.reason(for: SSHKeyError.unsupportedFormat(reason: sentinel))),
                    detail: DialSupport.reason(
                        for: AgentError.protocolError(reason: sentinel)))))

        let inPlainText = report.plainText().contains(sentinel)
        let inMarkdown = report.markdown().contains(sentinel)
        #expect(inPlainText == false)
        #expect(inMarkdown == false)
        // The positive companion: both sentences are still there and still
        // name what failed, so the two checks above measure redaction rather
        // than an empty row.
        #expect(report.plainText().contains("key file"))
        #expect(report.plainText().contains("ssh-agent"))
    }

    // MARK: - The deadline bounds the clock

    /// A probe that never honours cancellation must not hold the step past
    /// its deadline. `withTaskGroup` awaits its children, so the earlier
    /// group-based race bounded only the reported ROW: a wedged dial (Citadel
    /// carries an uncancellable 15 s `openSFTP` timer) left the user waiting
    /// well past the budget.
    ///
    /// Asserted as an ORDERING, not as a stopwatch reading. The subject's
    /// deadline fires on a Dispatch timer and is punctual, but RESUMING this
    /// test's task afterwards needs a cooperative-pool thread, and under the
    /// full suite that queueing cost was measured at 0.7 s, 1.4 s and once
    /// 5.9 s — so any tight time bound here measures the scheduler, not the
    /// property. What is actually claimed is "the step returned while the
    /// probe was still running", and `probeFinished` says exactly that.
    @Test func aProbeThatIgnoresCancellationDoesNotHoldTheStepPastItsDeadline() async throws {
        let port = try #require(LoopbackSocket.closedPort())
        let probeFinished = Gate()
        let clock = ContinuousClock()
        let started = clock.now
        let report = await Self.run(
            descriptor: Self.probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: DiagnosticContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe"
                ) { _, _ in
                    let timer = DiagnosticStepTimer(
                        id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                    await Self.uncancellableWait(seconds: 12)
                    await probeFinished.open()
                    return timer.finish(.ok, "never reported")
                }),
            stepTimeout: .seconds(1))
        let stillRunning = await probeFinished.isClosed
        let elapsed = started.duration(to: clock.now)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        #expect(dial.outcome == .timedOut)
        #expect(stillRunning)
        // No wall-clock backstop: the three-core CI runner returned this
        // step after 20.67 s (run 33727757421) with `stillRunning` true —
        // the probe itself was starved past its own 12 s. `stillRunning`
        // and the companion below carry the property; the clock does not.
        _ = elapsed
        // The positive companion for `stillRunning`, which is a check that
        // something has NOT happened: a `Gate` that never opened would
        // satisfy it vacuously. Waiting for the abandoned probe to reach its
        // own end proves the gate can open at all — and, incidentally, that
        // the probe really did keep running after the step returned.
        await probeFinished.opened()
        let openedInTheEnd = await probeFinished.isClosed == false
        #expect(openedInTheEnd)
    }

    /// A wait that cannot be cancelled, and that parks no cooperative-pool
    /// thread doing it: the timer runs on a Dispatch queue and the caller is
    /// suspended on a continuation until it fires.
    private static func uncancellableWait(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    // MARK: - The S3 and WebDAV dials, against the rig

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theS3DialReachesTheRigsMinIO() async throws {
        var values = FieldValues()
        values[S3Field.endpoint] = "http://127.0.0.1:19000"
        values[S3Field.bucket] = "macscp-seed"
        values[S3Field.region] = "us-east-1"

        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .s3), values: values, secrets: nil,
            stepTimeout: .seconds(10)
        ).run()

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        #expect(dial.outcome == .ok)
        // The unsigned HEAD is refused by MinIO, and that refusal IS the
        // measurement: an HTTP status means the endpoint answered.
        #expect(dial.detail.contains("HTTP"))
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"))
    func theWebDAVDialReachesTheRigsApache() async throws {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "http://127.0.0.1:18080/"

        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .webdav), values: values, secrets: nil,
            stepTimeout: .seconds(10)
        ).run()

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.dial })
        #expect(dial.outcome == .ok)
        #expect(dial.detail.contains("HTTP"))
    }

    // MARK: - The reason catalogue

    /// `DiagnosticReason.allKeys` promises "every key this type hands out",
    /// and until now nothing called it — so it could omit one and stay green.
    /// It did: `stoppedByBudgetKey` sits outside `table` because its sentence
    /// carries a number, and `allKeys` read only `table`.
    ///
    /// The English catalogue is the positive anchor, and it has to be
    /// something OUTSIDE this type: a check that derived both sides from
    /// `DiagnosticReason` would be an identity. The catalogue is where the
    /// keys are actually consumed, and `DiagnosticsDoorsGuardTests` already
    /// holds the other three languages to the same list, so equality here is
    /// equality with all four.
    @Test func everyReasonKeyTheTypeHandsOutIsExactlyWhatTheCatalogCarries() throws {
        let catalog = try String(
            contentsOf: Self.repositoryURL(
                "Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8)
        let inCatalog = Set(
            Self.matches(of: #""(diagnostics\.reason\.[A-Za-z0-9._]+)""#, in: catalog))

        // The anchor: the scan read a catalogue that has these keys at all. A
        // set comparison between two empty sets would pass while measuring
        // nothing.
        #expect(inCatalog.count > 1, "en.lproj carries no diagnostics.reason keys")
        #expect(Set(DiagnosticReason.allKeys) == inCatalog, """
            DiagnosticReason.allKeys and en.lproj disagree.
            only in allKeys: \(Set(DiagnosticReason.allKeys).subtracting(inCatalog).sorted())
            only in the catalog: \(inCatalog.subtracting(Set(DiagnosticReason.allKeys)).sorted())
            """)
    }

    /// `#filePath` is `<repoRoot>/Tests/macSCPCoreTests/<this file>`, so two
    /// `deletingLastPathComponent()` calls reach `Tests/` and a third the
    /// root — the same walk `TestsNeverBlockThePoolGuardTests` makes.
    private static func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    /// First capture group of every match, in source order.
    private static func matches(of pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let found = Range(match.range(at: 1), in: source)
            else { return nil }
            return String(source[found])
        }
    }

    // MARK: - Fixtures

    /// A report whose steps' outcomes differ, so a renderer that prints one
    /// label for all of them cannot pass. The count is deliberately not
    /// written into the name: the runner gains steps (the echo did), and a
    /// fixture called `threeStepReport` producing four is a comment that
    /// runs.
    private static func multiOutcomeReport() async throws -> DiagnosticReport {
        let port = try #require(LoopbackSocket.closedPort())
        return await run(
            descriptor: probeDescriptor(
                endpoint: Endpoint(host: "127.0.0.1", port: port),
                dial: constantContribution(
                    id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe",
                    outcome: .timedOut, detail: "gave up")))
    }

    /// A session that names no host is reported with NO endpoint, and both
    /// renderings leave the header line out rather than printing one nobody
    /// measured.
    ///
    /// The path had no test at all until 2026-09-03, and what it did was
    /// visible only from the pasteboard: the runner's `noHost` guard built
    /// its one-row report around `Endpoint(host: "", port: 0)`, which renders
    /// as `:0`. The panel never showed it — the panel reads its OWN endpoint,
    /// which is nil for such a session — so the fabricated header reached
    /// only the text a user pastes into a bug report, which is the one
    /// audience the report exists for.
    ///
    /// Positive beside negative, per CLAUDE.md's rule about checks that want
    /// to find nothing: the same two renderers are run over a report that DOES
    /// name an endpoint, and are required to print the header there. Without
    /// that half, "no endpoint line" would also be satisfied by renderers
    /// that had lost the line entirely.
    @Test func aWalkWithNoHostCarriesNoEndpointAndPrintsNoHeaderForOne() async throws {
        let report = await Self.run(descriptor: Self.probeDescriptor(endpoint: nil, dial: nil))

        #expect(report.endpoint == nil)
        let only = try #require(report.steps.first)
        #expect(report.steps.count == 1)
        #expect(only.id == DiagnosticStepID.resolve)
        #expect(only.outcome == .unavailable(DiagnosticReason.noHost))

        let text = report.plainText()
        let markdown = report.markdown()
        #expect(text.contains("Endpoint:") == false, """
            the endpointless report printed a header for an endpoint it does not have: \
            \(text)
            """)
        #expect(markdown.contains("Endpoint:") == false, """
            the endpointless report printed a Markdown header for an endpoint it does not \
            have: \(markdown)
            """)
        // The rest of the header is still there — omitting the endpoint is
        // not omitting the report.
        #expect(text.contains("App version: test"))
        #expect(markdown.contains("- **App version:** test"))
        #expect(text.contains(DiagnosticReason.noHost))
        #expect(markdown.contains(DiagnosticReason.noHost))

        let named = DiagnosticReport(
            endpoint: Endpoint(host: "example.test", port: 22), steps: report.steps,
            appVersion: "test")
        #expect(named.plainText().contains("Endpoint: example.test:22"), """
            the plain-text renderer prints no endpoint header at all — the check above \
            cannot mean what it says: \(named.plainText())
            """)
        #expect(named.markdown().contains("- **Endpoint:** `example.test:22`"), """
            the Markdown renderer prints no endpoint header at all: \(named.markdown())
            """)
    }

    private static func run(
        descriptor: BackendDescriptor, stepTimeout: Duration = .seconds(5),
        appVersion: String = "test"
    ) async -> DiagnosticReport {
        await ConnectionDiagnostics(
            descriptor: descriptor, values: FieldValues(), secrets: nil,
            stepTimeout: stepTimeout, appVersion: appVersion
        ).run()
    }

    /// A descriptor that answers only the two questions the runner asks it.
    /// Everything else throws or returns empty: a runner that reached for one
    /// of them would be reaching past the seam.
    private static func probeDescriptor(
        endpoint: Endpoint?, dial: DiagnosticContribution?,
        diagnostics: [DiagnosticContribution] = []
    ) -> BackendDescriptor {
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
            endpoint: { _ in endpoint }, dial: dial, diagnostics: diagnostics)
    }

    /// One finished row, with nothing measured — the renderer cases need rows
    /// to print and care about none of their contents.
    private static func constantStep(id: String) -> DiagnosticStep {
        DiagnosticStepTimer(id: id, titleKey: DiagnosticStepID.titleKey(for: id))
            .finish(.ok, "")
    }

    private static func constantContribution(
        id: String, titleKey: String, outcome: DiagnosticOutcome, detail: String
    ) -> DiagnosticContribution {
        DiagnosticContribution(id: id, titleKey: titleKey) { _, _ in
            DiagnosticStepTimer(id: id, titleKey: titleKey).finish(outcome, detail)
        }
    }

    /// The id of the backend contribution every scoped walk below carries.
    /// Not one of `DiagnosticStepID`'s constants: a contribution's id comes
    /// from the backend, and a scope that only knew the universal ids would
    /// have nothing to decide about.
    private static let contributionID = "probe-contribution"

    /// What one scoped walk produced: the report's rows, the rows the
    /// observer was handed, and how often each side of the seam actually ran.
    private struct ScopedWalk {
        let report: DiagnosticReport
        let observed: [String]
        let dials: Int
        let contributions: Int

        var ids: [String] { report.steps.map(\.id) }
    }

    /// Runs one scope against a listening loopback port, with a dial and a
    /// contribution that record every call.
    private static func scopedWalk(
        _ scope: DiagnosticScope, endpoint: Endpoint
    ) async -> ScopedWalk {
        let dials = Ticker()
        let contributions = Ticker()
        let observed = StepLog()
        let diagnostics = ConnectionDiagnostics(
            descriptor: probeDescriptor(
                endpoint: endpoint,
                dial: recordingContribution(id: DiagnosticStepID.dial, ticker: dials),
                diagnostics: [recordingContribution(id: contributionID, ticker: contributions)]),
            values: FieldValues(), secrets: nil, appVersion: "test")
        let report = await diagnostics.run(
            scope: scope, onStep: { step in await observed.append(step.id) })
        return ScopedWalk(
            report: report, observed: await observed.ids,
            dials: await dials.count, contributions: await contributions.count)
    }

    /// A contribution that succeeds and counts the fact that it was asked.
    private static func recordingContribution(
        id: String, ticker: Ticker
    ) -> DiagnosticContribution {
        DiagnosticContribution(id: id, titleKey: "diagnostics.step.probe") { _, _ in
            let timer = DiagnosticStepTimer(id: id, titleKey: "diagnostics.step.probe")
            await ticker.tick()
            return timer.finish(.ok, "")
        }
    }

    private static func loopbackAddress(port: Int) async -> ResolvedAddress? {
        guard case .resolved(let addresses) = await HostResolver.resolve(
            host: "127.0.0.1", port: port, timeout: .seconds(2))
        else { return nil }
        return addresses.first
    }

}

/// Carries one typed error as a test argument, so the heterogeneous literal
/// below infers a concrete element type. NOT because `any Error` is
/// unsendable — `Error` refines `Sendable` in the standard library, which is
/// why this declaration compiles without `@unchecked` under Swift 6 — an
/// earlier version of this comment claimed otherwise.
fileprivate struct AnyDialError: Sendable {
    let wrapped: any Error
    init(_ wrapped: any Error) { self.wrapped = wrapped }
}

/// A `SecretSource` that answers the same value for any session — the test
/// stand-in for the Keychain the App hands the runner.
private struct FixedSecretSource: SecretSource {
    let label = "test"
    let value: String
    func secret(for _: UUID) throws -> String? { value }
}

/// One-shot signal: the dial contribution opens it, the test waits for it,
/// so a cancellation lands while the dial is genuinely in flight rather than
/// at whatever point a sleep happened to leave it.
/// Records the steps an observer is handed, each with a marker read at the
/// moment it arrived.
///
/// The marker is the load-bearing half: the ids alone are the same list under
/// incremental delivery and under a flush at the end, and so is "how many had
/// arrived when the last one did". What differs is how far the WALK had got
/// when each row was handed over.
private actor StepLog {
    struct Entry: Equatable { let id: String; let marker: Int }

    private(set) var entries: [Entry] = []
    var ids: [String] { entries.map(\.id) }

    func append(_ id: String, marked marker: Int = 0) {
        entries.append(Entry(id: id, marker: marker))
    }
}

/// Counts how many times something has happened, so an observation can record
/// what the run had reached when it fired.
private actor Ticker {
    private(set) var count = 0
    func tick() { count += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func opened() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Whether nothing has opened it yet — read by the deadline case, which
    /// asks "was the probe still running when the step returned?".
    var isClosed: Bool { !isOpen }
}

/// A loopback TCP socket a test owns, for the two ends of the ping: one that
/// listens (accepted) and one whose port was released (refused).
private struct LoopbackSocket {
    let descriptor: Int32
    let port: Int

    func close() { Darwin.close(descriptor) }

    /// Binds `127.0.0.1:0`, listens, and reports the port the kernel chose.
    static func listening() -> LoopbackSocket? {
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
        return LoopbackSocket(
            descriptor: descriptor, port: Int(UInt16(bigEndian: assigned.sin_port)))
    }

    /// A port nothing listens on: bind one, learn its number, give it back.
    static func closedPort() -> Int? {
        guard let socket = listening() else { return nil }
        socket.close()
        return socket.port
    }
}
