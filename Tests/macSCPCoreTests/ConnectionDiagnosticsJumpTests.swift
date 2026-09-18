import Foundation
import Synchronization
import Testing

@testable import macSCPCore

/// A session behind a jump host is diagnosed through the jump: the jump is
/// checked first, from this Mac, and the target is reached THROUGH it
/// (2026-09-18, the New-features row "Diagnostics ignore the jump host").
///
/// **What is real and what is injected.** The jump's resolve, TCP ping, echo
/// and trace are the universal probes, pointed at a loopback socket this
/// suite owns — the only packets these cases send. The jump's dial, the
/// channel open through it and the target's dial are the seam
/// (`DiagnosticJumpDialer`): a fake that records what was asked of it and
/// whether the connection it handed out was closed. The rig case at the end
/// (`ConnectionDiagnosticsJumpRigTests`) runs the real dials.
///
/// No case waits on a clock: a dial that has to be in flight is parked on an
/// `AsyncSignal` and released by the case.
@Suite("ConnectionDiagnostics through a jump host")
struct ConnectionDiagnosticsJumpTests {
    /// The jump's secret in the cases that give it one. Named, and never
    /// written into an expectation: `#expect` prints the source text of what
    /// it checks (CLAUDE.md, "A value a test must not leak has two exits").
    private static let jumpSecret = "diagnostics-jump-test-passphrase"

    /// The target, as the jump would reach it. A reserved name (RFC 2606):
    /// nothing here resolves it — the fake dials never leave the process.
    private static let targetHost = "target.invalid"
    private static let targetPort = 2222

    private static let everyJumpStep = [
        DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTCP, DiagnosticStepID.jumpICMP,
        DiagnosticStepID.jumpDial, DiagnosticStepID.jumpTrace,
        DiagnosticStepID.targetTCPViaJump, DiagnosticStepID.targetDialViaJump,
    ]

    // MARK: - The order

    @Test func aJumpSessionIsWalkedJumpFirstThenTheTargetThroughIt() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let log = RunEvents()

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(
            scope: .complete,
            observer: DiagnosticRunObserver(
                onStepStarted: { id, _ in log.record("start \(id)") },
                onStep: { step in log.record("row \(step.id)") }))

        #expect(report.steps.map(\.id) == Self.everyJumpStep)
        #expect(report.steps.map(\.outcome) == Array(repeating: .ok, count: 7), """
            \(report.plainText())
            """)
        // The channel was opened to the TARGET, over the jump connection, and
        // the target's dial carried the jump.
        #expect(rig.events == [
            "connect 127.0.0.1:\(listener.port)",
            "probe \(Self.targetHost):\(Self.targetPort)",
            "dialTarget \(Self.targetHost):\(Self.targetPort) via 127.0.0.1:\(listener.port)",
            "disconnect",
        ])
        // Every step announced itself before its row, the jump's as much as
        // the universal ones.
        let expectedEvents = Self.everyJumpStep.flatMap { ["start \($0)", "row \($0)"] }
        #expect(log.events == expectedEvents)
        #expect(report.endpoint == Endpoint(host: Self.targetHost, port: Self.targetPort))
        #expect(report.jump == Endpoint(host: "127.0.0.1", port: listener.port))
    }

    /// Each scope, mapped onto both halves. The three the brief names —
    /// `.ping`, `.trace`, `.dial` — plus the two that were already there.
    ///
    /// `.ping` opens the jump connection even though it measures no login:
    /// `target.tcpViaJump` is how "is anything there" is asked of a target
    /// behind a bastion, and the channel it opens needs an authenticated
    /// connection to the jump. The dial row says so rather than the ping
    /// opening a connection nobody sees.
    @Test(arguments: DiagnosticScope.allCases)
    func eachScopeRunsItsStepsOnBothHalves(scope: DiagnosticScope) async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let contributions = Ticker()

        let report = await Self.diagnostics(
            jumpPort: listener.port, rig: rig, contribution: contributions
        ).run(scope: scope)

        let expected: [String]
        switch scope {
        case .complete:
            expected = Self.everyJumpStep + [Self.contributionID]
        case .ping:
            expected = [
                DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTCP, DiagnosticStepID.jumpICMP,
                DiagnosticStepID.jumpDial, DiagnosticStepID.targetTCPViaJump,
            ]
        case .trace:
            expected = [DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpTrace]
        case .dial:
            expected = [
                DiagnosticStepID.jumpResolve, DiagnosticStepID.jumpDial,
                DiagnosticStepID.targetDialViaJump,
            ]
        case .contributions:
            expected = [DiagnosticStepID.jumpResolve, Self.contributionID]
        }
        #expect(report.steps.map(\.id) == expected, "\(scope.rawValue): \(report.steps.map(\.id))")
        #expect(report.scope == scope)

        // A connection is opened exactly when a step needs one, and every one
        // that was opened was closed.
        let opensAConnection = expected.contains(DiagnosticStepID.jumpDial)
        #expect(rig.count("connect") == (opensAConnection ? 1 : 0))
        #expect(rig.count("disconnect") == rig.count("connect"))
        #expect(await contributions.count == (expected.contains(Self.contributionID) ? 1 : 0))
    }

    /// A session without a jump is the walk it always was, and never touches
    /// a jump dial.
    @Test func aSessionWithoutAJumpKeepsTheWalkItHad() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        var values = Self.targetValues()
        values[SSHField.host] = "127.0.0.1"
        values[SSHField.port] = String(listener.port)

        let report = await ConnectionDiagnostics(
            descriptor: Self.descriptor(dial: Self.okDial()), values: values, secrets: nil,
            jump: nil, jumpDialer: rig.dialer, appVersion: "test"
        ).run()

        #expect(report.steps.map(\.id) == [
            DiagnosticStepID.resolve, DiagnosticStepID.tcp, DiagnosticStepID.icmp,
            DiagnosticStepID.dial, DiagnosticStepID.trace,
        ])
        #expect(rig.events.isEmpty, "a walk without a jump dialled one: \(rig.events)")
        #expect(report.jump == nil)
        #expect(!report.plainText().contains("Jump host"))
    }

    // MARK: - The jump not reached

    /// Every way the jump can fail to be reached leaves every `target.` step
    /// `skipped` with a reason naming the jump — the target was not measured,
    /// and a row that said `failed` would be a finding about a machine
    /// nobody reached.
    @Test(arguments: JumpFailure.allCases)
    func whenTheJumpIsNotReachedEveryTargetStepIsSkippedNamingTheJump(
        failure: JumpFailure
    ) async throws {
        let listener = try #require(LoopbackSocket.listening())
        let closedPort = try #require(LoopbackSocket.closedPort())
        defer { listener.close() }
        let rig = JumpRig()
        var jump = Self.agentJump(port: listener.port)
        switch failure {
        case .jumpDialFails:
            rig.connectError = RemoteFSError.authenticationFailed
        case .jumpPortRefused:
            jump = Self.agentJump(port: closedPort)
        case .jumpUnresolvable:
            jump = .unresolvable()
        case .jumpSecretMissing:
            jump = DiagnosticJump(
                endpoint: Endpoint(host: "127.0.0.1", port: listener.port),
                login: .init(username: "testuser", authKind: .password, keyPath: nil),
                secret: { nil })
        }

        let report = await Self.diagnostics(jump: jump, rig: rig).run()

        let targetSteps = report.steps.filter { $0.id.hasPrefix("target.") }
        #expect(targetSteps.map(\.id) == [
            DiagnosticStepID.targetTCPViaJump, DiagnosticStepID.targetDialViaJump,
        ], "\(failure): \(report.steps.map(\.id))")
        for step in targetSteps {
            #expect(step.outcome == .skipped(DiagnosticReason.jumpNotReached), """
                \(failure): \(step.id) came back \(step.outcome)
                """)
        }
        // Nothing went through a jump that was not reached.
        #expect(rig.count("probe") == 0)
        #expect(rig.count("dialTarget") == 0)
        #expect(rig.count("disconnect") == rig.count("connect"), "\(failure): \(rig.events)")

        switch failure {
        case .jumpDialFails:
            let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
            #expect(dial.outcome == .failed(DialSupport.reason(for: RemoteFSError.authenticationFailed)))
        case .jumpPortRefused:
            let tcp = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpTCP })
            #expect(tcp.outcome == .failed("refused"))
        case .jumpUnresolvable:
            #expect(report.steps.first?.id == DiagnosticStepID.jumpResolve)
            #expect(report.steps.first?.outcome == .unavailable(DiagnosticReason.jumpUnresolvable))
            #expect(rig.count("connect") == 0)
            #expect(report.jump == nil)
        case .jumpSecretMissing:
            let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
            #expect(dial.outcome == .skipped(DiagnosticReason.noJumpSecret))
            #expect(rig.count("connect") == 0)
        }
    }

    enum JumpFailure: String, CaseIterable, CustomTestStringConvertible {
        case jumpDialFails, jumpPortRefused, jumpUnresolvable, jumpSecretMissing
        var testDescription: String { rawValue }
    }

    /// A refused channel is the target's finding, not the jump's: the dial
    /// through the jump still runs, and the connection is still closed.
    @Test func aRefusedChannelIsReportedAndTheTargetDialStillRuns() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        rig.probeError = RemoteFSError.connectionFailed(reason: "refused")

        let report = await Self.diagnostics(jumpPort: listener.port, rig: rig).run()

        let tcp = try #require(report.steps.first { $0.id == DiagnosticStepID.targetTCPViaJump })
        #expect(tcp.outcome == .failed(DialSupport.reason(for: RemoteFSError.connectionFailed(reason: ""))))
        #expect(rig.count("dialTarget") == 1)
        #expect(rig.events.last == "disconnect")
    }

    // MARK: - The connection closed on every path

    /// Cancelled while the target's dial is in flight: the report stops
    /// there, and the jump connection is closed before `run` returns.
    // `.timeLimit` as a hang bound only (CLAUDE.md, "A wall-clock ceiling
    // in a test measures the runner"): nothing below asserts on elapsed
    // time, and a signal that is never raised must end the case rather
    // than the run.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledWalkStillClosesTheJumpConnection() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let release = AsyncSignal()
        rig.parkTargetDial(until: release)
        defer { release.signal() }
        let diagnostics = Self.diagnostics(jumpPort: listener.port, rig: rig, stepTimeout: .seconds(60))

        let task = Task { await diagnostics.run() }
        #expect(await rig.targetDialEntered.wait() == .signalled)
        task.cancel()
        let report = await task.value

        // Read before the park is released, so nothing the abandoned dial
        // does afterwards can make these true (CLAUDE.md, "Tests that watch
        // a defect heal").
        let closedBeforeReturn = rig.count("disconnect")
        #expect(closedBeforeReturn == 1, "\(rig.events)")
        #expect(report.completion == .cancelled(afterSteps: 6))
        #expect(report.steps.map(\.id) == Array(Self.everyJumpStep.prefix(6)))
    }

    /// The jump's dial loses its deadline, and its connection arrives after
    /// the walk has moved on: nobody is left to use it, so it is closed the
    /// moment it arrives rather than held open until the process exits.
    // `.timeLimit` as a hang bound only (CLAUDE.md, "A wall-clock ceiling
    // in a test measures the runner"): nothing below asserts on elapsed
    // time, and a signal that is never raised must end the case rather
    // than the run.
    @Test(.timeLimit(.minutes(1)))
    func aJumpConnectionThatArrivesAfterItsDeadlineIsClosed() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        let release = AsyncSignal()
        rig.parkJumpDial(until: release)

        let report = await Self.diagnostics(
            jumpPort: listener.port, rig: rig, stepTimeout: .milliseconds(200)
        ).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        #expect(dial.outcome == .timedOut)
        #expect(report.steps.last?.outcome == .skipped(DiagnosticReason.jumpNotReached))
        // Snapshot before the late connection is let through.
        let closedBeforeArrival = rig.count("disconnect")
        #expect(closedBeforeArrival == 0)

        release.signal()
        #expect(await rig.disconnected.wait() == .signalled)
        #expect(rig.count("disconnect") == 1)
        #expect(rig.count("dialTarget") == 0)
    }

    // MARK: - The dial carries the jump

    /// `SSHFieldSchema.makeConfig` returns a config whose jump is always nil
    /// — it takes one secret, and a jump has a second — so the target's dial
    /// through the jump is only a dial through the jump if the hop is
    /// attached after it. Pinned twice: on the builder, and on what the walk
    /// actually hands its dialer.
    @Test func theTargetDialThroughAJumpCarriesTheJump() async throws {
        var values = Self.targetValues()
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        let jump = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: 2222),
            login: .init(username: "jumpuser", authKind: .password, keyPath: nil),
            secret: { Self.jumpSecret })

        let config = try jump.targetConfig(
            values: values, targetSecret: "target", jumpSecret: Self.jumpSecret)

        let hop = try #require(config.jump, "the target's dial config dropped the jump")
        #expect(hop.host == "127.0.0.1")
        #expect(hop.port == 2222)
        #expect(hop.username == "jumpuser")
        let carriesTheJumpSecret: Bool
        if case .password(let secret) = hop.auth { carriesTheJumpSecret = secret == Self.jumpSecret }
        else { carriesTheJumpSecret = false }
        #expect(carriesTheJumpSecret)
        #expect(config.host == Self.targetHost)
        #expect(config.port == Self.targetPort)

        // And through the walk: what the dialer was handed.
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        let rig = JumpRig()
        _ = await Self.diagnostics(jumpPort: listener.port, rig: rig).run(scope: .dial)
        #expect(rig.targetDialJumps == ["127.0.0.1:\(listener.port)"])
    }

    /// The jump's own dial fails against a port nothing listens on, with a
    /// password secret in hand. Neither the rows nor either rendering may
    /// carry it. The real dials, not the fake: the secret has to have been
    /// handed to a transport for its absence to mean anything.
    @Test func theJumpsSecretNeverReachesTheReport() async throws {
        let closedPort = try #require(LoopbackSocket.closedPort())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-kh-diag-jump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = Self.jumpSecret
        let jump = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: closedPort),
            login: .init(username: "testuser", authKind: .password, keyPath: nil),
            secret: { secret })

        let report = await ConnectionDiagnostics(
            descriptor: .descriptor(for: .ssh), values: Self.targetValues(), secrets: nil,
            jump: jump, jumpDialer: .live(knownHosts: KnownHostsStore(directory: directory)),
            stepTimeout: .seconds(10), appVersion: "test"
        ).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        guard case .failed = dial.outcome else {
            Issue.record("a closed port did not fail the jump's dial: \(dial.outcome)")
            return
        }
        let inStep = report.steps.contains { step in
            step.detail.contains(secret) || step.outcome.label.contains(secret)
        }
        let inPlainText = report.plainText().contains(secret)
        let inMarkdown = report.markdown().contains(secret)
        #expect(inStep == false)
        #expect(inPlainText == false)
        #expect(inMarkdown == false)
    }

    // MARK: - A refused channel, read

    @Test func aRefusalsReasonCodeIsReadOutOfNIOSSHsDescription() {
        #expect(DirectTCPIPRejection.reasonCode(
            inDescription: "NIOSSHError.channelSetupRejected: Reason: 1 open failed") == 1)
        #expect(DirectTCPIPRejection.reasonCode(
            inDescription: "NIOSSHError.channelSetupRejected: Reason: 2 Connection refused") == 2)
        #expect(DirectTCPIPRejection.reasonCode(
            inDescription: "NIOSSHError.channelSetupRejected: Reason: 4 ") == 4)
        #expect(DirectTCPIPRejection.reasonCode(inDescription: "NIOSSHError.protocolViolation") == nil)
        // An error that is not a refused channel is no rejection at all.
        #expect(DirectTCPIPRejection(RemoteFSError.authenticationFailed) == nil)
    }

    /// Each code the row can meet, and the sentence it gets: the two a user
    /// can act on are told apart, any other is named by its number, and an
    /// error that is not a refusal is rendered the way every dial error is.
    ///
    /// The codes are literals, RFC 4254 §5.1's own numbers, and not the
    /// type's constants: a case that read the constants would stay green
    /// with the two swapped (measured — only the rig case went red).
    @Test func aRefusedChannelIsReportedByItsReasonCode() {
        let prohibited = DirectTCPIPRejection(reasonCode: 1)
        let unreachable = DirectTCPIPRejection(reasonCode: 2)
        #expect(DirectTCPIPRefusal.reason(for: prohibited) == DiagnosticReason.jumpForwardingProhibited)
        #expect(DirectTCPIPRefusal.reason(for: unreachable) == DiagnosticReason.jumpCouldNotConnect)
        #expect(DirectTCPIPRefusal.reason(for: DirectTCPIPRejection(reasonCode: 4))
            == DiagnosticReason.jumpRefusedChannel(code: 4))
        let other = RemoteFSError.authenticationFailed
        #expect(DirectTCPIPRefusal.reason(for: other) == DialSupport.reason(for: other))
    }

    // MARK: - Where the jump comes from

    /// A stored session's jump, in each of its three modes, resolved without
    /// reading a secret until the dial asks — and then reading the slot the
    /// connect reads.
    @Test func aStoredJumpIsResolvedAsTheConnectResolvesItAndReadsItsSlotOnlyWhenAsked() throws {
        let store = CountingSecretStore()
        let keys = ManagedKeyStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("macscp-keys-diag-\(UUID().uuidString)"))
        let secretID = UUID()
        store.put(Self.jumpSecret, for: secretID)
        let manual = StoredSession(
            id: UUID(), name: "behind",
            ssh: StoredSSHConfig(
                host: Self.targetHost, username: "testuser",
                jump: .init(host: "bastion.invalid", port: 2200, username: "hop", secretID: secretID)))

        let jump = try #require(DiagnosticJump.stored(
            for: manual, sets: [], sessions: [manual], secrets: store, keys: keys))
        #expect(jump.endpoint == Endpoint(host: "bastion.invalid", port: 2200))
        #expect(jump.login == .init(username: "hop", authKind: .password, keyPath: nil))
        #expect(store.reads == 0, "building the jump read a secret")
        let answered = try jump.secret() == Self.jumpSecret
        #expect(answered)
        #expect(store.readSlots == [secretID])

        // Session mode: the referenced saved connection's host and slot.
        let bastion = StoredSession(
            id: UUID(), name: "bastion",
            ssh: StoredSSHConfig(host: "jump.invalid", port: 2022, username: "ops"))
        store.put(Self.jumpSecret, for: bastion.id)
        let referencing = StoredSession(
            id: UUID(), name: "via",
            ssh: StoredSSHConfig(
                host: Self.targetHost, username: "testuser",
                jump: .init(host: "", username: "", sessionID: bastion.id)))
        let viaSession = try #require(DiagnosticJump.stored(
            for: referencing, sets: [], sessions: [bastion, referencing], secrets: store, keys: keys))
        #expect(viaSession.endpoint == Endpoint(host: "jump.invalid", port: 2022))
        #expect(viaSession.login.username == "ops")
        _ = try viaSession.secret()
        #expect(store.readSlots.last == bastion.id)

        // A reference to a connection that is gone: unresolvable, not a
        // direct dial.
        let dangling = try #require(DiagnosticJump.stored(
            for: referencing, sets: [], sessions: [referencing], secrets: store, keys: keys))
        #expect(dangling.endpoint == nil)

        // No jump, no jump.
        let direct = StoredSession(
            id: UUID(), name: "direct", ssh: StoredSSHConfig(host: Self.targetHost, username: "u"))
        #expect(DiagnosticJump.stored(
            for: direct, sets: [], sessions: [direct], secrets: store, keys: keys) == nil)
    }

    /// A tab's jump: where and who from the form, the secret from the stored
    /// session behind it — never the form's typed one.
    @Test func aFormsJumpTakesItsFieldsFromTheFormAndItsSecretFromTheStoredJump() throws {
        var values = Self.targetValues()
        values[SSHField.jump, SSHJumpField.host] = " bastion.invalid "
        values[SSHField.jump, SSHJumpField.port] = "2200"
        values[SSHField.jump, SSHJumpField.username] = "hop"
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue
        values[SSHField.jump, SSHJumpField.password] = "typed-into-the-form"

        #expect(DiagnosticJump.form(values, isEnabled: false, stored: nil) == nil)

        let stored = DiagnosticJump(
            endpoint: Endpoint(host: "bastion.invalid", port: 2200),
            login: .init(username: "hop", authKind: .password, keyPath: nil),
            secret: { Self.jumpSecret })
        let jump = try #require(DiagnosticJump.form(values, isEnabled: true, stored: stored))
        #expect(jump.endpoint == Endpoint(host: "bastion.invalid", port: 2200))
        #expect(jump.login == .init(username: "hop", authKind: .password, keyPath: nil))
        let fromStored = try jump.secret() == Self.jumpSecret
        #expect(fromStored)

        let unsaved = try #require(DiagnosticJump.form(values, isEnabled: true, stored: nil))
        let noSecret = try unsaved.secret() == nil
        #expect(noSecret, "a tab with no stored jump read the form's typed secret")
    }

    /// The stored jump's secret goes only to the stored jump (fix round 1 of
    /// Task 6, the coordinator's ruling on the review's Minor 4).
    ///
    /// The form's jump can be edited and not saved — another host, port,
    /// user or auth kind — while the secret still comes from the stored
    /// session's slot. Sent as it was, the stored bastion's password would go
    /// to whatever host the form now names. So it is handed over only when
    /// all four equal the stored jump's, and otherwise the jump has no secret
    /// to offer, which its dial reports as `noJumpSecret`.
    ///
    /// Whether the secret came back is computed into a `Bool` before any
    /// expectation reads it: the value itself is never in an expression
    /// `#expect` could print.
    @Test(arguments: FormJumpEdit.allCases)
    func aFormsJumpGetsTheStoredSecretOnlyWhenItIsTheStoredJump(edit: FormJumpEdit) throws {
        var values = Self.targetValues()
        values[SSHField.jump, SSHJumpField.host] = "bastion.invalid"
        values[SSHField.jump, SSHJumpField.port] = "2200"
        values[SSHField.jump, SSHJumpField.username] = "hop"
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue
        switch edit {
        case .none: break
        case .host: values[SSHField.jump, SSHJumpField.host] = "elsewhere.invalid"
        case .port: values[SSHField.jump, SSHJumpField.port] = "2201"
        case .username: values[SSHField.jump, SSHJumpField.username] = "someone-else"
        case .authKind:
            values[SSHField.jump, SSHJumpField.authKind] =
                StoredSession.AuthKind.privateKey.rawValue
            values[SSHField.jump, SSHJumpField.keyPath] = "/tmp/key.invalid"
        }
        let secret = Self.jumpSecret
        let stored = DiagnosticJump(
            endpoint: Endpoint(host: "bastion.invalid", port: 2200),
            login: .init(username: "hop", authKind: .password, keyPath: nil),
            secret: { secret })

        let jump = try #require(DiagnosticJump.form(values, isEnabled: true, stored: stored))

        let answered = try jump.secret()
        let gotTheStoredSecret = answered == secret
        let gotNothing = answered == nil
        if edit == .none {
            #expect(gotTheStoredSecret, "the form names the stored jump, and got no secret")
        } else {
            #expect(gotNothing, "the form's jump differs in its \(edit), and got a secret")
        }
    }

    enum FormJumpEdit: String, CaseIterable, CustomTestStringConvertible {
        case none, host, port, username, authKind
        var testDescription: String { rawValue }
    }

    /// The same rule through the walk: a form whose jump differs from the
    /// stored one dials nothing, and the jump's login row says there was no
    /// secret for it — the reason a missing secret has always had.
    @Test func aFormsEditedJumpIsNotDialledWithTheStoredSecret() async throws {
        let listener = try #require(LoopbackSocket.listening())
        defer { listener.close() }
        var values = Self.targetValues()
        values[SSHField.jump, SSHJumpField.host] = "127.0.0.1"
        values[SSHField.jump, SSHJumpField.port] = String(listener.port)
        values[SSHField.jump, SSHJumpField.username] = "edited-not-saved"
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue
        let secret = Self.jumpSecret
        let stored = DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: listener.port),
            login: .init(username: "testuser", authKind: .password, keyPath: nil),
            secret: { secret })
        let jump = try #require(DiagnosticJump.form(values, isEnabled: true, stored: stored))
        let rig = JumpRig()

        let report = await Self.diagnostics(jump: jump, rig: rig).run(scope: .dial)

        let dial = try #require(report.steps.first { $0.id == DiagnosticStepID.jumpDial })
        #expect(dial.outcome == .skipped(DiagnosticReason.noJumpSecret))
        #expect(rig.count("connect") == 0, "\(rig.events)")
    }

    // MARK: - The report names both halves

    @Test func theReportNamesTheJumpInBothRenderingsAndTheJSON() throws {
        let step = DiagnosticStepTimer(
            id: DiagnosticStepID.jumpDial,
            titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.jumpDial)
        ).finish(.ok, "")
        let report = DiagnosticReport(
            endpoint: Endpoint(host: Self.targetHost, port: Self.targetPort),
            jump: Endpoint(host: "127.0.0.1", port: 2222), steps: [step], appVersion: "test")

        #expect(report.plainText().contains("Jump host: 127.0.0.1:2222"), "\(report.plainText())")
        #expect(report.markdown().contains("- **Jump host:** `127.0.0.1:2222`"), "\(report.markdown())")
        let summary = DiagnoseRendering.jsonSummary(for: report)
        let jump = try #require(summary["jump"] as? [String: Any])
        #expect(jump["host"] as? String == "127.0.0.1")
        #expect(jump["port"] as? Int == 2222)
        // The keys it had before are all still there.
        #expect(Set(summary.keys).isSuperset(of: ["completion", "endpoint", "steps"]))

        let direct = DiagnosticReport(endpoint: nil, steps: [step], appVersion: "test")
        #expect(DiagnoseRendering.jsonSummary(for: direct)["jump"] is NSNull)
    }

    // MARK: - Fixtures

    private static let contributionID = "probe-contribution"

    /// The target's field values: agent auth, so no case needs the target's
    /// secret unless it sets one.
    private static func targetValues() -> FieldValues {
        var values = SSHFieldSchema.defaults
        values[SSHField.host] = targetHost
        values[SSHField.port] = String(targetPort)
        values[SSHField.username] = "testuser"
        values[SSHField.authKind] = StoredSession.AuthKind.agent.rawValue
        return values
    }

    /// A jump on loopback, logging in through the agent — nothing to look up.
    private static func agentJump(port: Int) -> DiagnosticJump {
        DiagnosticJump(
            endpoint: Endpoint(host: "127.0.0.1", port: port),
            login: .init(username: "testuser", authKind: .agent, keyPath: nil),
            secret: { nil })
    }

    private static func diagnostics(
        jumpPort: Int, rig: JumpRig, contribution: Ticker? = nil,
        stepTimeout: Duration = .seconds(5)
    ) -> ConnectionDiagnostics {
        diagnostics(
            jump: agentJump(port: jumpPort), rig: rig, contribution: contribution,
            stepTimeout: stepTimeout)
    }

    private static func diagnostics(
        jump: DiagnosticJump, rig: JumpRig, contribution: Ticker? = nil,
        stepTimeout: Duration = .seconds(5)
    ) -> ConnectionDiagnostics {
        ConnectionDiagnostics(
            descriptor: descriptor(
                dial: okDial(),
                diagnostics: contribution.map { [recordingContribution(ticker: $0)] } ?? []),
            values: targetValues(), secrets: nil, jump: jump, jumpDialer: rig.dialer,
            stepTimeout: stepTimeout, appVersion: "test")
    }

    /// SSH's own endpoint, and a dial and contributions the case chooses. A
    /// walk through a jump must not run this dial — `target.dialViaJump` is
    /// its dial — which the order cases would show as an extra `dial` row.
    private static func descriptor(
        dial: DiagnosticContribution?, diagnostics: [DiagnosticContribution] = []
    ) -> BackendDescriptor {
        let ssh = BackendDescriptor.descriptor(for: .ssh)
        return BackendDescriptor(
            kind: .ssh, capabilities: ssh.capabilities,
            connectionSchema: ssh.connectionSchema, credentialSchema: ssh.credentialSchema,
            makeConfig: ssh.makeConfig, displaySummary: ssh.displaySummary, apply: ssh.apply,
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: { _ in false },
            fileActions: [],
            endpoint: ssh.endpoint, dial: dial, diagnostics: diagnostics)
    }

    private static func okDial() -> DiagnosticContribution {
        DiagnosticContribution(id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe") { _, _ in
            DiagnosticStepTimer(id: DiagnosticStepID.dial, titleKey: "diagnostics.step.probe")
                .finish(.ok, "")
        }
    }

    private static func recordingContribution(ticker: Ticker) -> DiagnosticContribution {
        DiagnosticContribution(id: contributionID, titleKey: "diagnostics.step.probe") { _, _ in
            let timer = DiagnosticStepTimer(id: contributionID, titleKey: "diagnostics.step.probe")
            await ticker.tick()
            return timer.finish(.ok, "")
        }
    }
}

// MARK: - The fake jump

/// The seam's fake: hands out a connection that records what it is asked,
/// and records what the walk dialled. Every event lands in one list, in the
/// order it happened, so "closed after the last step" is an assertion about
/// the list rather than two counters.
final class JumpRig: Sendable {
    private struct State {
        var events: [String] = []
        var targetDialJumps: [String] = []
        var connectError: (any Error)?
        var probeError: (any Error)?
        var jumpDialPark: AsyncSignal?
        var targetDialPark: AsyncSignal?
    }

    private let state = Mutex(State())
    /// Raised when the target's dial is entered — the moment a cancelling
    /// case cancels.
    let targetDialEntered = AsyncSignal()
    /// Raised when a connection this rig handed out is closed.
    let disconnected = AsyncSignal()

    var events: [String] { state.withLock { $0.events } }
    var targetDialJumps: [String] { state.withLock { $0.targetDialJumps } }

    var connectError: (any Error)? {
        get { state.withLock { $0.connectError } }
        set { state.withLock { $0.connectError = newValue } }
    }

    var probeError: (any Error)? {
        get { state.withLock { $0.probeError } }
        set { state.withLock { $0.probeError = newValue } }
    }

    func count(_ prefix: String) -> Int {
        events.filter { $0 == prefix || $0.hasPrefix(prefix + " ") }.count
    }

    func record(_ event: String) { state.withLock { $0.events.append(event) } }

    func parkJumpDial(until signal: AsyncSignal) { state.withLock { $0.jumpDialPark = signal } }
    func parkTargetDial(until signal: AsyncSignal) { state.withLock { $0.targetDialPark = signal } }

    var dialer: DiagnosticJumpDialer {
        DiagnosticJumpDialer(
            connectJump: { config, _ in
                // Parked in an unstructured task, so the wait does NOT
                // honour the dial's cancellation: the shape of a transport
                // that finishes its connect whatever the caller wanted,
                // which is what makes a late connection possible at all.
                if let park = self.state.withLock({ $0.jumpDialPark }) {
                    await Task { _ = await park.wait() }.value
                }
                if let error = self.connectError { throw error }
                self.record("connect \(config.host):\(config.port)")
                return FakeJumpConnection(rig: self)
            },
            dialTarget: { config, _ in
                let hop = config.jump.map { "\($0.host):\($0.port)" } ?? "none"
                self.state.withLock { $0.targetDialJumps.append(hop) }
                self.record("dialTarget \(config.host):\(config.port) via \(hop)")
                self.targetDialEntered.signal()
                if let park = self.state.withLock({ $0.targetDialPark }) { _ = await park.wait() }
            })
    }
}

private struct FakeJumpConnection: DiagnosticJumpConnection {
    let rig: JumpRig

    func probeDirectTCPIP(host: String, port: Int) async throws {
        rig.record("probe \(host):\(port)")
        if let error = rig.probeError { throw error }
    }

    func disconnect() async {
        rig.record("disconnect")
        rig.disconnected.signal()
    }
}

/// Collects observer events in the order they came.
private final class RunEvents: Sendable {
    private let state = Mutex<[String]>([])
    var events: [String] { state.withLock { $0 } }
    func record(_ event: String) { state.withLock { $0.append(event) } }
}

private actor Ticker {
    private(set) var count = 0
    func tick() { count += 1 }
}

/// A `SecretStore` that holds what the case puts in it and records every slot
/// read, so "no secret is read until the dial asks" is a count.
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private var slots: [UUID] = []

    var reads: Int { lock.withLock { slots.count } }
    var readSlots: [UUID] { lock.withLock { slots } }

    func put(_ value: String, for id: UUID) { lock.withLock { values[id] = value } }

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.withLock { values[sessionID] = password }
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.withLock {
            slots.append(sessionID)
            return values[sessionID]
        }
    }

    func deletePassword(for sessionID: UUID) throws {
        _ = lock.withLock { values.removeValue(forKey: sessionID) }
    }
}
