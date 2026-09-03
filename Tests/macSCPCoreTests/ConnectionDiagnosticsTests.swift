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

    @Test func cancellationMidRunEndsWithTheStepsSoFar() async throws {
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

        // One header row, one separator row, one row per step.
        #expect(rows.count == report.steps.count + 2)
        for step in report.steps {
            let own = rows.filter { $0.hasPrefix("| `\(step.id)` |") }
            #expect(own.count == 1)
            #expect(own.first?.contains(step.outcome.label) == true)
            #expect(own.first?.contains(" ms |") == true)
        }
        #expect(report.steps.map(\.outcome).contains(.timedOut))
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

    private static func constantContribution(
        id: String, titleKey: String, outcome: DiagnosticOutcome, detail: String
    ) -> DiagnosticContribution {
        DiagnosticContribution(id: id, titleKey: titleKey) { _, _ in
            DiagnosticStepTimer(id: id, titleKey: titleKey).finish(outcome, detail)
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
